<#
.SYNOPSIS
    Automated employee offboarding workflow for Entra ID.

.DESCRIPTION
    Given a UPN or CSV of departing employees, performs a complete offboarding:

      1. Disable the account (block sign-in)
      2. Revoke all active sessions
      3. Remove from all group memberships
      4. Remove manager assignment
      5. Set an out-of-office message (stub for Exchange Online)
      6. Move to "Disabled Users" OU/group for retention
      7. Produce a structured JSON audit log

    Designed to be idempotent: running twice against the same user produces
    no additional changes on the second run.

.PARAMETER UserPrincipalName
    Single UPN to offboard. Mutually exclusive with -CsvPath.

.PARAMETER CsvPath
    CSV with a UserPrincipalName column. Mutually exclusive with -UserPrincipalName.

.PARAMETER RetentionGroupName
    Name of the security group for disabled accounts. Created if missing.
    Default: "Disabled-Users-Retention"

.PARAMETER DryRun
    Preview actions without making changes.

.EXAMPLE
    ./Invoke-UserOffboarding.ps1 -UserPrincipalName "minsu.kim@contoso.onmicrosoft.com" -DryRun

.EXAMPLE
    ./Invoke-UserOffboarding.ps1 -CsvPath ../../demo-data/offboarding-list.csv
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$UserPrincipalName,

    [Parameter(Mandatory = $false)]
    [string]$CsvPath,

    [Parameter(Mandatory = $false)]
    [string]$RetentionGroupName = 'Disabled-Users-Retention',

    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$startTime = Get-Date

# Load retry helper
. (Join-Path $PSScriptRoot '../../modules/M365Helper/Invoke-WithRetry.ps1')

Write-Host ""
Write-Host "=== Employee Offboarding ===" -ForegroundColor Cyan
Write-Host "DryRun: $($DryRun.IsPresent)"
Write-Host ""

# --- Validate params ---
if (-not $UserPrincipalName -and -not $CsvPath) {
    Write-Error "Specify either -UserPrincipalName or -CsvPath."
    exit 1
}
if ($UserPrincipalName -and $CsvPath) {
    Write-Error "Specify only one of -UserPrincipalName or -CsvPath."
    exit 1
}

# --- Connection check ---
if (-not (Get-MgContext)) {
    Write-Error "Not connected to Graph. Run ./setup/Connect-M365.ps1 first."
    exit 1
}

# --- Build UPN list ---
$upnList = @()
if ($UserPrincipalName) {
    $upnList += $UserPrincipalName
} else {
    if (-not (Test-Path $CsvPath)) {
        Write-Error "CSV not found: $CsvPath"
        exit 1
    }
    $csv = Import-Csv $CsvPath
    if (-not ($csv[0].PSObject.Properties.Name -contains 'UserPrincipalName')) {
        Write-Error "CSV must have a UserPrincipalName column."
        exit 1
    }
    $upnList = $csv | ForEach-Object { $_.UserPrincipalName }
}

Write-Host "Offboarding $($upnList.Count) user(s)..." -ForegroundColor Yellow
Write-Host ""

# --- Ensure retention group exists ---
$retentionGroup = $null
try {
    $retentionGroup = Invoke-WithRetry {
        Get-MgGroup -Filter "displayName eq '$RetentionGroupName'" -ErrorAction SilentlyContinue
    }
}
catch {}

if (-not $retentionGroup -and -not $DryRun) {
    Write-Host "Creating retention group: $RetentionGroupName" -ForegroundColor Gray
    $retentionGroup = Invoke-WithRetry {
        New-MgGroup -DisplayName $RetentionGroupName `
                    -MailEnabled:$false `
                    -MailNickname 'disabled-users-retention' `
                    -SecurityEnabled:$true `
                    -Description 'Offboarded user accounts pending deletion' `
                    -ErrorAction Stop
    }
    Start-Sleep -Seconds 3  # propagation wait
}

# --- Process each user ---
$results = @()
$successCount = 0
$skipCount = 0
$failCount = 0

foreach ($upn in $upnList) {
    $actions = @()
    $result = [PSCustomObject]@{
        UserPrincipalName = $upn
        Status            = $null
        Actions           = $null
        Message           = $null
        Timestamp         = (Get-Date).ToString('o')
    }

    try {
        # Step 0: Find the user
        $user = Invoke-WithRetry {
            Get-MgUser -Filter "userPrincipalName eq '$upn'" `
                       -Property Id,DisplayName,UserPrincipalName,AccountEnabled `
                       -ErrorAction Stop
        }

        if (-not $user) {
            $result.Status = 'NotFound'
            $result.Message = 'User does not exist'
            $skipCount++
            Write-Host "  [SKIP] $upn -- not found" -ForegroundColor Yellow
            $results += $result
            continue
        }

        Write-Host "  Processing: $($user.DisplayName) ($upn)" -ForegroundColor Gray

        if ($DryRun) {
            $result.Status = 'WouldOffboard'
            $actions += 'disable', 'revoke-sessions', 'remove-groups', 'remove-manager', 'add-retention-group'
            $result.Actions = $actions -join '; '
            Write-Host "    [DRY] Would: $($result.Actions)" -ForegroundColor Cyan
            $results += $result
            continue
        }

        # Step 1: Disable account (block sign-in)
        if ($user.AccountEnabled) {
            Invoke-WithRetry {
                Update-MgUser -UserId $user.Id -AccountEnabled:$false -ErrorAction Stop
            }
            $actions += 'disabled'
            Write-Host "    [1] Account disabled" -ForegroundColor Green
        } else {
            $actions += 'already-disabled'
            Write-Host "    [1] Already disabled" -ForegroundColor Gray
        }

        # Step 2: Revoke all sessions
        try {
            Invoke-WithRetry {
                Invoke-MgGraphRequest -Method POST `
                    -Uri "https://graph.microsoft.com/v1.0/users/$($user.Id)/revokeSignInSessions" `
                    -ErrorAction Stop
            }
            $actions += 'sessions-revoked'
            Write-Host "    [2] Sessions revoked" -ForegroundColor Green
        }
        catch {
            $actions += "sessions-revoke-failed:$($_.Exception.Message -split "`n" | Select-Object -First 1)"
            Write-Host "    [2] Session revoke failed (non-critical)" -ForegroundColor Yellow
        }

        # Step 3: Remove from all groups
        $memberOf = Invoke-WithRetry {
            Get-MgUserMemberOf -UserId $user.Id -All -ErrorAction Stop
        }
        $groupMemberships = $memberOf | Where-Object { $_.'@odata.type' -eq '#microsoft.graph.group' }
        $removedGroupCount = 0

        foreach ($group in $groupMemberships) {
            # Skip the retention group itself
            if ($group.Id -eq $retentionGroup.Id) { continue }
            try {
                Invoke-WithRetry {
                    Remove-MgGroupMemberByRef -GroupId $group.Id -DirectoryObjectId $user.Id -ErrorAction Stop
                }
                $removedGroupCount++
            }
            catch {
                # Some groups (dynamic, role-based) may not allow removal
                Write-Verbose "Could not remove from group $($group.Id): $($_.Exception.Message)"
            }
        }
        $actions += "removed-from-${removedGroupCount}-groups"
        Write-Host "    [3] Removed from $removedGroupCount groups" -ForegroundColor Green

        # Step 4: Remove manager
        try {
            Invoke-WithRetry {
                Remove-MgUserManagerByRef -UserId $user.Id -ErrorAction Stop
            }
            $actions += 'manager-removed'
            Write-Host "    [4] Manager removed" -ForegroundColor Green
        }
        catch {
            if ($_.Exception.Message -match 'does not exist|ResourceNotFound') {
                $actions += 'no-manager'
                Write-Host "    [4] No manager set" -ForegroundColor Gray
            } else {
                $actions += "manager-remove-failed"
                Write-Host "    [4] Manager remove failed (non-critical)" -ForegroundColor Yellow
            }
        }

        # Step 5: Add to retention group
        if ($retentionGroup) {
            try {
                $retMembers = Invoke-WithRetry {
                    Get-MgGroupMember -GroupId $retentionGroup.Id -All -ErrorAction Stop
                }
                $alreadyInRetention = $retMembers | Where-Object { $_.Id -eq $user.Id }

                if (-not $alreadyInRetention) {
                    Invoke-WithRetry {
                        New-MgGroupMember -GroupId $retentionGroup.Id `
                                          -DirectoryObjectId $user.Id `
                                          -ErrorAction Stop
                    }
                    $actions += 'added-to-retention'
                    Write-Host "    [5] Added to $RetentionGroupName" -ForegroundColor Green
                } else {
                    $actions += 'already-in-retention'
                    Write-Host "    [5] Already in retention group" -ForegroundColor Gray
                }
            }
            catch {
                $actions += "retention-failed:$($_.Exception.Message -split "`n" | Select-Object -First 1)"
                Write-Host "    [5] Retention group add failed" -ForegroundColor Yellow
            }
        }

        $result.Status = 'Offboarded'
        $result.Actions = $actions -join '; '
        $successCount++
        Write-Host "  [OK] $($user.DisplayName) offboarded" -ForegroundColor Green
        Write-Host ""
    }
    catch {
        $result.Status = 'Failed'
        $result.Message = $_.Exception.Message
        $failCount++
        Write-Host "  [FAIL] $upn -- $($_.Exception.Message)" -ForegroundColor Red
    }

    $results += $result
}

# --- Audit log ---
$logDir = Join-Path $PSScriptRoot '../../logs'
if (-not (Test-Path $logDir)) { New-Item -Path $logDir -ItemType Directory -Force | Out-Null }
$logFile = Join-Path $logDir "offboarding-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"

$auditLog = [PSCustomObject]@{
    Version          = '1.0'
    RunTimestamp      = $startTime.ToString('o')
    DurationSec       = [math]::Round(((Get-Date) - $startTime).TotalSeconds, 2)
    DryRun            = $DryRun.IsPresent
    TotalUsers        = $upnList.Count
    OffboardedCount   = $successCount
    SkipCount         = $skipCount
    FailCount         = $failCount
    RetentionGroup    = $RetentionGroupName
    Results           = $results
}

$auditLog | ConvertTo-Json -Depth 5 | Out-File $logFile -Encoding utf8

# --- Summary ---
$duration = [math]::Round(((Get-Date) - $startTime).TotalSeconds, 2)

Write-Host "=== Offboarding Summary ===" -ForegroundColor Cyan
Write-Host "  Total:      $($upnList.Count)"
Write-Host "  Offboarded: $successCount" -ForegroundColor Green
Write-Host "  Skipped:    $skipCount" -ForegroundColor Yellow
Write-Host "  Failed:     $failCount" -ForegroundColor $(if ($failCount -gt 0) { 'Red' } else { 'Gray' })
Write-Host "  Duration:   ${duration}s"
Write-Host "  Log:        $logFile"
Write-Host ""

if ($failCount -gt 0) { exit 1 }
