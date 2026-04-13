<#
.SYNOPSIS
    Production-style bulk user onboarding with validation, retry, idempotency,
    license assignment, and manager/group reconciliation.

.DESCRIPTION
    v2 of New-BulkEntraUsers.ps1. Implements senior-engineer best practices:

    1. Pre-flight CSV validation (Test-OnboardingCsv)
    2. Retry with exponential backoff on throttling (Invoke-WithRetry)
    3. Idempotent reconciliation: CREATE if missing, UPDATE if drifted, NO-OP if identical
    4. License assignment via SkuPartNumber lookup
    5. Manager assignment + departmental group membership

.PARAMETER CsvPath
    CSV with columns: DisplayName, MailNickname, GivenName, Surname, Department,
    JobTitle, UsageLocation, ManagerUPN (optional), LicenseSkuPartNumber (optional)

.PARAMETER Domain
    UPN suffix. Auto-resolved from tenant if omitted.

.PARAMETER DryRun
    Show what would happen without making changes.

.PARAMETER SkipValidation
    Bypass pre-flight CSV validation (not recommended).

.EXAMPLE
    ./Invoke-UserOnboarding.ps1 -CsvPath ../../demo-data/new-hires-2026-05.csv -DryRun

.EXAMPLE
    ./Invoke-UserOnboarding.ps1 -CsvPath ../../demo-data/new-hires-2026-05.csv
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$CsvPath,

    [Parameter(Mandatory = $false)]
    [string]$Domain,

    [Parameter(Mandatory = $false)]
    [switch]$DryRun,

    [Parameter(Mandatory = $false)]
    [switch]$SkipValidation
)

$ErrorActionPreference = 'Stop'
$startTime = Get-Date

# Load helper module
. (Join-Path $PSScriptRoot '../../modules/M365Helper/Invoke-WithRetry.ps1')

Write-Host ""
Write-Host "=== User Onboarding (v2) ===" -ForegroundColor Cyan
Write-Host "CSV:    $CsvPath"
Write-Host "DryRun: $($DryRun.IsPresent)"
Write-Host ""

# --- 0. Connection check ---
if (-not (Get-MgContext)) {
    Write-Error "Not connected to Graph. Run ./setup/Connect-M365.ps1 first."
    exit 1
}

# --- 1. Pre-flight validation ---
if (-not $SkipValidation) {
    Write-Host "Running pre-flight validation..." -ForegroundColor Yellow
    $validation = & (Join-Path $PSScriptRoot 'Test-OnboardingCsv.ps1') -CsvPath $CsvPath
    if (-not $validation.IsValid) {
        Write-Host "Validation FAILED:" -ForegroundColor Red
        $validation.Errors | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
        exit 1
    }
    Write-Host "Validation OK ($($validation.RowCount) rows)" -ForegroundColor Green
    Write-Host ""
}

# --- 2. Resolve domain ---
if (-not $Domain) {
    $org = Invoke-WithRetry { Get-MgOrganization }
    $Domain = ($org.VerifiedDomains | Where-Object { $_.IsDefault }).Name
    Write-Host "Domain: $Domain" -ForegroundColor Gray
}

# --- 3. Pre-fetch SKU catalog (for license lookup) ---
$skuCatalog = @{}
try {
    $skus = Invoke-WithRetry { Get-MgSubscribedSku }
    foreach ($sku in $skus) {
        $skuCatalog[$sku.SkuPartNumber] = $sku.SkuId
    }
    Write-Host "Available licenses: $($skuCatalog.Count) SKUs" -ForegroundColor Gray
}
catch {
    Write-Warning "Could not fetch SKU catalog. License assignment will be skipped. ($($_.Exception.Message))"
}

$users = Import-Csv $CsvPath
Write-Host "Processing $($users.Count) users..." -ForegroundColor Gray

# Pre-load all Dept-* groups into a hashtable. Avoids the eventual-consistency
# trap on the displayName filter index, which can fail to return a freshly-
# created group for several seconds.
#
# Eventual consistency hits us in two directions:
#   - CREATE: a new group may not appear in the filter index for 1-3s
#   - DELETE: a deleted group may still appear in the filter index for 10-30s
# We mitigate by sorting by CreatedDateTime ASC and keeping only the OLDEST
# group per displayName (matches the dedupe-groups.ps1 behavior).
$groupCache = @{}
try {
    $existingGroups = Invoke-WithRetry {
        Get-MgGroup -Filter "startsWith(displayName, 'Dept-')" `
                    -Property Id,DisplayName,CreatedDateTime `
                    -All -ErrorAction Stop
    }
    $existingGroups |
        Sort-Object CreatedDateTime |
        ForEach-Object {
            if (-not $groupCache.ContainsKey($_.DisplayName)) {
                $groupCache[$_.DisplayName] = $_
            }
        }
    Write-Host "Cached $($groupCache.Count) existing Dept-* groups" -ForegroundColor Gray
}
catch {
    Write-Warning "Could not pre-load groups: $($_.Exception.Message)"
}

Write-Host ""

# --- 4. Reconciliation loop ---
$results = @()
$createdCount = 0
$updatedCount = 0
$noopCount = 0
$failCount = 0

foreach ($u in $users) {
    $upn = "$($u.MailNickname)@$Domain"
    $actions = @()

    $result = [PSCustomObject]@{
        DisplayName       = $u.DisplayName
        UserPrincipalName = $upn
        Status            = $null
        Actions           = $null
        Message           = $null
        Timestamp         = (Get-Date).ToString('o')
    }

    try {
        # ---- Check if user exists ----
        $existing = Invoke-WithRetry {
            Get-MgUser -Filter "userPrincipalName eq '$upn'" `
                       -Property Id,DisplayName,GivenName,Surname,Department,JobTitle,UsageLocation,AccountEnabled `
                       -ErrorAction SilentlyContinue
        }

        if (-not $existing) {
            # ===== CREATE =====
            if ($DryRun) {
                $result.Status = 'WouldCreate'
                $actions += 'create'
            }
            else {
                $tempPassword = -join ((65..90) + (97..122) + (48..57) + @(33,35,36,37,38,64) |
                    Get-Random -Count 16 | ForEach-Object { [char]$_ })

                $newUser = Invoke-WithRetry {
                    New-MgUser -AccountEnabled:$true `
                               -DisplayName $u.DisplayName `
                               -MailNickname $u.MailNickname `
                               -UserPrincipalName $upn `
                               -GivenName $u.GivenName `
                               -Surname $u.Surname `
                               -Department $u.Department `
                               -JobTitle $u.JobTitle `
                               -UsageLocation $u.UsageLocation `
                               -PasswordProfile @{
                                   ForceChangePasswordNextSignIn = $true
                                   Password = $tempPassword
                               }
                }
                $existing = $newUser
                $result.Status = 'Created'
                $actions += 'create'
                $createdCount++
            }
        }
        else {
            # ===== Check for drift =====
            $drift = @{}
            $fields = @('DisplayName','GivenName','Surname','Department','JobTitle','UsageLocation')
            foreach ($f in $fields) {
                if ($existing.$f -ne $u.$f) {
                    $drift[$f] = $u.$f
                }
            }

            if ($drift.Count -gt 0) {
                if ($DryRun) {
                    $result.Status = 'WouldUpdate'
                    $actions += "update:$($drift.Keys -join ',')"
                }
                else {
                    Invoke-WithRetry {
                        Update-MgUser -UserId $existing.Id @drift
                    }
                    $result.Status = 'Updated'
                    $actions += "update:$($drift.Keys -join ',')"
                    $updatedCount++
                }
            }
            else {
                $result.Status = 'NoOp'
                $noopCount++
            }
        }

        # ---- License assignment (skip if dry-run) ----
        if (-not $DryRun -and $u.PSObject.Properties['LicenseSkuPartNumber'] -and $u.LicenseSkuPartNumber) {
            $skuId = $skuCatalog[$u.LicenseSkuPartNumber]
            if ($skuId) {
                try {
                    $currentLicenses = Invoke-WithRetry { Get-MgUserLicenseDetail -UserId $existing.Id }
                    $alreadyHas = $currentLicenses | Where-Object { $_.SkuId -eq $skuId }
                    if (-not $alreadyHas) {
                        Invoke-WithRetry {
                            Set-MgUserLicense -UserId $existing.Id `
                                              -AddLicenses @(@{ SkuId = $skuId }) `
                                              -RemoveLicenses @()
                        }
                        $actions += "license:$($u.LicenseSkuPartNumber)"
                    }
                }
                catch {
                    $actions += "license-failed:$($_.Exception.Message)"
                }
            }
            else {
                $actions += "license-unknown:$($u.LicenseSkuPartNumber)"
            }
        }

        # ---- Manager assignment ----
        if (-not $DryRun -and $u.PSObject.Properties['ManagerUPN'] -and $u.ManagerUPN) {
            try {
                $manager = Invoke-WithRetry {
                    Get-MgUser -Filter "userPrincipalName eq '$($u.ManagerUPN)'" -ErrorAction SilentlyContinue
                }
                if ($manager) {
                    Invoke-WithRetry {
                        Set-MgUserManagerByRef -UserId $existing.Id `
                                               -BodyParameter @{ "@odata.id" = "https://graph.microsoft.com/v1.0/users/$($manager.Id)" }
                    }
                    $actions += "manager:$($u.ManagerUPN)"
                }
                else {
                    $actions += "manager-not-found:$($u.ManagerUPN)"
                }
            }
            catch {
                $actions += "manager-failed:$($_.Exception.Message)"
            }
        }

        # ---- Departmental group membership ----
        # Real-world Graph API gotcha: group creation has eventual consistency.
        # A freshly-created group's ID is returned immediately, but read/write
        # to its members can return 404 for 1-3 seconds afterwards (especially
        # in regional data centers like Korea Central). We work around this by:
        #   1. Skipping the membership read for freshly-created groups
        #      (we know they are empty)
        #   2. Wrapping the add call in a dedicated retry loop that treats
        #      404 as transient for up to 5 attempts
        if (-not $DryRun -and $u.Department) {
            try {
                $groupName = "Dept-$($u.Department)"
                $justCreated = $false

                # Look up in the in-memory cache first to avoid the lagging
                # filter index. Only call New-MgGroup if not seen this run.
                $group = $groupCache[$groupName]
                if (-not $group) {
                    $group = Invoke-WithRetry {
                        New-MgGroup -DisplayName $groupName `
                                    -MailEnabled:$false `
                                    -MailNickname "dept-$($u.Department.ToLower())" `
                                    -SecurityEnabled:$true `
                                    -ErrorAction Stop
                    }
                    $groupCache[$groupName] = $group  # cache it for the next user
                    $justCreated = $true
                    $actions += "group-created:$groupName"
                }

                # Membership check (skip for freshly created groups)
                $isMember = $false
                if (-not $justCreated) {
                    $members = Invoke-WithRetry {
                        Get-MgGroupMember -GroupId $group.Id -All -ErrorAction Stop
                    }
                    $isMember = [bool]($members | Where-Object { $_.Id -eq $existing.Id })
                }

                if (-not $isMember) {
                    # Add member with self-healing retry. Two failure modes:
                    #   1. Propagation lag right after group creation (transient)
                    #   2. Stale cache pointing at a deleted group (need refetch)
                    $addAttempts = 0
                    $maxAddAttempts = 5
                    $added = $false
                    $refetched = $false

                    while (-not $added -and $addAttempts -lt $maxAddAttempts) {
                        $addAttempts++
                        try {
                            New-MgGroupMember -GroupId $group.Id `
                                              -DirectoryObjectId $existing.Id `
                                              -ErrorAction Stop
                            $added = $true
                        }
                        catch {
                            $msg = $_.Exception.Message
                            if ($msg -match 'does not exist|ResourceNotFound|Request_ResourceNotFound') {
                                # First attempt at self-healing: refetch the
                                # group by name. The cache may be holding a
                                # group that was deleted before this run.
                                if (-not $refetched) {
                                    $refetched = $true
                                    Write-Verbose "Cache stale for $groupName, refetching"
                                    $fresh = Invoke-WithRetry {
                                        Get-MgGroup -Filter "displayName eq '$groupName'" `
                                                    -Property Id,DisplayName,CreatedDateTime `
                                                    -ErrorAction Stop
                                    }
                                    $fresh = $fresh | Sort-Object CreatedDateTime | Select-Object -First 1
                                    if ($fresh -and $fresh.Id -ne $group.Id) {
                                        $group = $fresh
                                        $groupCache[$groupName] = $fresh
                                        continue  # retry immediately with the new id
                                    }
                                }
                                # Otherwise treat as propagation lag
                                $delay = $addAttempts * 2
                                Write-Verbose "Group propagation lag, retry $addAttempts/$maxAddAttempts in ${delay}s"
                                Start-Sleep -Seconds $delay
                            } else {
                                throw
                            }
                        }
                    }

                    if ($added) {
                        $actions += "group-added:$groupName"
                    } else {
                        $actions += "group-add-timeout:$groupName"
                    }
                }
            }
            catch {
                $firstLine = $_.Exception.Message -split "`n" | Select-Object -First 1
                $actions += "group-failed:$firstLine"
            }
        }

        if ($actions.Count -eq 0) { $actions += 'noop' }
        $result.Actions = $actions -join '; '

        $color = switch ($result.Status) {
            'Created'     { 'Green' }
            'Updated'     { 'Cyan' }
            'NoOp'        { 'Gray' }
            'WouldCreate' { 'Green' }
            'WouldUpdate' { 'Cyan' }
            default       { 'White' }
        }
        Write-Host "  [$($result.Status)] $($u.DisplayName) -- $($result.Actions)" -ForegroundColor $color
    }
    catch {
        $result.Status = 'Failed'
        $result.Message = $_.Exception.Message
        $failCount++
        Write-Host "  [FAIL] $($u.DisplayName) -- $($_.Exception.Message)" -ForegroundColor Red
    }

    $results += $result
}

# --- 5. Audit log ---
$logDir = Join-Path $PSScriptRoot '../../logs'
if (-not (Test-Path $logDir)) { New-Item -Path $logDir -ItemType Directory -Force | Out-Null }
$logFile = Join-Path $logDir "onboarding-v2-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"

$auditLog = [PSCustomObject]@{
    Version       = '2.0'
    RunTimestamp  = $startTime.ToString('o')
    DurationSec   = [math]::Round(((Get-Date) - $startTime).TotalSeconds, 2)
    CsvPath       = $CsvPath
    Domain        = $Domain
    DryRun        = $DryRun.IsPresent
    TotalUsers    = $users.Count
    CreatedCount  = $createdCount
    UpdatedCount  = $updatedCount
    NoOpCount     = $noopCount
    FailCount     = $failCount
    Results       = $results
}

$auditLog | ConvertTo-Json -Depth 5 | Out-File $logFile -Encoding utf8

# --- 6. Summary ---
$duration = [math]::Round(((Get-Date) - $startTime).TotalSeconds, 2)

Write-Host ""
Write-Host "=== Summary ===" -ForegroundColor Cyan
Write-Host "  Total:    $($users.Count)"
Write-Host "  Created:  $createdCount" -ForegroundColor Green
Write-Host "  Updated:  $updatedCount" -ForegroundColor Cyan
Write-Host "  NoOp:     $noopCount" -ForegroundColor Gray
Write-Host "  Failed:   $failCount" -ForegroundColor $(if ($failCount -gt 0) { 'Red' } else { 'Gray' })
Write-Host "  Duration: ${duration}s"
Write-Host "  Log:      $logFile"
Write-Host ""

if ($failCount -gt 0) { exit 1 }
