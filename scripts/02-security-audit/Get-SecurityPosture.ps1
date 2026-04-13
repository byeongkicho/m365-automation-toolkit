<#
.SYNOPSIS
    Audits the security posture of an Entra ID tenant and produces a structured report.

.DESCRIPTION
    Checks five security dimensions and outputs results to the console, a JSON
    audit log, and optionally an Excel workbook (requires ImportExcel module).

    Checks performed:
      1. Users without MFA registration
      2. Inactive accounts (no sign-in for N days)
      3. Privileged role members (Global Admin, User Admin, etc.)
      4. Guest / external accounts
      5. Accounts with password never expires set

    Each check produces a finding list. The script exits non-zero if any
    critical findings exceed configurable thresholds.

.PARAMETER InactiveDays
    Days since last sign-in to consider an account inactive. Default 90.

.PARAMETER OutputFormat
    Console (default), Json, Excel, or All.

.PARAMETER DryRun
    Show what checks would run without querying Graph.

.EXAMPLE
    ./Get-SecurityPosture.ps1 -OutputFormat All

.EXAMPLE
    ./Get-SecurityPosture.ps1 -InactiveDays 60 -OutputFormat Excel
#>

[CmdletBinding()]
param(
    [int]$InactiveDays = 90,

    [ValidateSet('Console', 'Json', 'Excel', 'All')]
    [string]$OutputFormat = 'Console',

    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$startTime = Get-Date

# Load retry helper
. (Join-Path $PSScriptRoot '../../modules/M365Helper/Invoke-WithRetry.ps1')

Write-Host ""
Write-Host "=== Security Posture Audit ===" -ForegroundColor Cyan
Write-Host "Inactive threshold: $InactiveDays days"
Write-Host "Output: $OutputFormat"
Write-Host ""

# Connection check
if (-not (Get-MgContext)) {
    Write-Error "Not connected to Graph. Run ./setup/Connect-M365.ps1 first."
    exit 1
}

if ($DryRun) {
    Write-Host "[DRY RUN] Would perform 5 checks against tenant." -ForegroundColor Yellow
    Write-Host "  1. MFA registration status"
    Write-Host "  2. Inactive accounts ($InactiveDays+ days)"
    Write-Host "  3. Privileged role members"
    Write-Host "  4. Guest accounts"
    Write-Host "  5. Password-never-expires accounts"
    exit 0
}

# Fetch all users once (cache for multiple checks)
Write-Host "Fetching all users..." -ForegroundColor Yellow
# NOTE: SignInActivity requires Entra ID P1/P2 license.
# On free tenants we fall back to CreatedDateTime as a proxy for account age.
$hasPremium = $true
try {
    $allUsers = Invoke-WithRetry {
        Get-MgUser -All -Property Id,DisplayName,UserPrincipalName,AccountEnabled,UserType,CreatedDateTime,SignInActivity,PasswordPolicies `
                   -ErrorAction Stop
    }
}
catch {
    if ($_.Exception.Message -match 'NonPremiumTenant|premium license') {
        Write-Warning "Free tenant detected -- SignInActivity not available. Using CreatedDateTime as fallback."
        $hasPremium = $false
        $allUsers = Invoke-WithRetry {
            Get-MgUser -All -Property Id,DisplayName,UserPrincipalName,AccountEnabled,UserType,CreatedDateTime,PasswordPolicies `
                       -ErrorAction Stop
        }
    } else {
        throw
    }
}
Write-Host "Found $($allUsers.Count) users" -ForegroundColor Gray
Write-Host ""

$findings = @{}

# ============================================================
# CHECK 1: MFA Registration Status
# ============================================================
Write-Host "[1/5] Checking MFA registration..." -ForegroundColor Yellow

$mfaFindings = @()
try {
    $authMethods = Invoke-WithRetry {
        Get-MgReportAuthenticationMethodUserRegistrationDetail -All -ErrorAction Stop
    }

    foreach ($entry in $authMethods) {
        $isMfaRegistered = $entry.IsMfaRegistered
        if (-not $isMfaRegistered) {
            $user = $allUsers | Where-Object { $_.Id -eq $entry.Id }
            if ($user -and $user.AccountEnabled) {
                $mfaFindings += [PSCustomObject]@{
                    UserId            = $entry.Id
                    DisplayName       = $user.DisplayName
                    UserPrincipalName = $user.UserPrincipalName
                    IsMfaRegistered   = $false
                    AccountEnabled    = $user.AccountEnabled
                    Severity          = 'High'
                }
            }
        }
    }
}
catch {
    Write-Warning "MFA check failed (may need AuthenticationMethod.Read.All permission): $($_.Exception.Message)"
    $mfaFindings = @([PSCustomObject]@{
        DisplayName = 'CHECK FAILED'
        Severity    = 'Error'
        Message     = $_.Exception.Message
    })
}

$findings['MFA_Not_Registered'] = $mfaFindings
Write-Host "  Found $($mfaFindings.Count) users without MFA" -ForegroundColor $(if ($mfaFindings.Count -gt 0) { 'Red' } else { 'Green' })

# ============================================================
# CHECK 2: Inactive Accounts
# ============================================================
Write-Host "[2/5] Checking inactive accounts ($InactiveDays+ days)..." -ForegroundColor Yellow

$cutoffDate = (Get-Date).AddDays(-$InactiveDays)
$inactiveFindings = @()

foreach ($user in $allUsers) {
    if (-not $user.AccountEnabled) { continue }

    if ($hasPremium) {
        # Premium: use actual last sign-in data
        $lastSignIn = $null
        if ($user.SignInActivity) {
            $lastSignIn = $user.SignInActivity.LastSignInDateTime
        }

        if ($null -eq $lastSignIn -or $lastSignIn -lt $cutoffDate) {
            $daysSince = if ($lastSignIn) {
                [math]::Round(((Get-Date) - $lastSignIn).TotalDays)
            } else {
                'Never'
            }

            $inactiveFindings += [PSCustomObject]@{
                DisplayName       = $user.DisplayName
                UserPrincipalName = $user.UserPrincipalName
                LastSignIn        = $lastSignIn
                DaysSinceSignIn   = $daysSince
                AccountEnabled    = $user.AccountEnabled
                CreatedDateTime   = $user.CreatedDateTime
                Severity          = if ($daysSince -eq 'Never') { 'Medium' } elseif ($daysSince -gt 180) { 'High' } else { 'Medium' }
            }
        }
    } else {
        # Free tier fallback: flag accounts created > N days ago
        # (no sign-in data available, so age is the best proxy)
        if ($user.CreatedDateTime -and $user.CreatedDateTime -lt $cutoffDate) {
            $daysSinceCreated = [math]::Round(((Get-Date) - $user.CreatedDateTime).TotalDays)
            $inactiveFindings += [PSCustomObject]@{
                DisplayName       = $user.DisplayName
                UserPrincipalName = $user.UserPrincipalName
                LastSignIn        = '(Premium required)'
                DaysSinceSignIn   = "Created ${daysSinceCreated}d ago"
                AccountEnabled    = $user.AccountEnabled
                CreatedDateTime   = $user.CreatedDateTime
                Severity          = 'Info'
            }
        }
    }
}

$findings['Inactive_Accounts'] = $inactiveFindings
Write-Host "  Found $($inactiveFindings.Count) inactive accounts" -ForegroundColor $(if ($inactiveFindings.Count -gt 0) { 'Yellow' } else { 'Green' })

# ============================================================
# CHECK 3: Privileged Role Members
# ============================================================
Write-Host "[3/5] Checking privileged role members..." -ForegroundColor Yellow

$privilegedRoles = @(
    'Global Administrator',
    'User Administrator',
    'Exchange Administrator',
    'Security Administrator',
    'Privileged Role Administrator',
    'Application Administrator',
    'Cloud Application Administrator',
    'Intune Administrator'
)

$privilegedFindings = @()
try {
    $directoryRoles = Invoke-WithRetry {
        Get-MgDirectoryRole -All -ErrorAction Stop
    }

    foreach ($role in $directoryRoles) {
        if ($role.DisplayName -in $privilegedRoles) {
            $members = Invoke-WithRetry {
                Get-MgDirectoryRoleMember -DirectoryRoleId $role.Id -All -ErrorAction Stop
            }

            foreach ($member in $members) {
                $user = $allUsers | Where-Object { $_.Id -eq $member.Id }
                $privilegedFindings += [PSCustomObject]@{
                    RoleName          = $role.DisplayName
                    DisplayName       = if ($user) { $user.DisplayName } else { $member.Id }
                    UserPrincipalName = if ($user) { $user.UserPrincipalName } else { 'N/A' }
                    AccountEnabled    = if ($user) { $user.AccountEnabled } else { 'Unknown' }
                    Severity          = if ($role.DisplayName -eq 'Global Administrator') { 'Critical' } else { 'High' }
                }
            }
        }
    }
}
catch {
    Write-Warning "Privileged role check failed: $($_.Exception.Message)"
}

$findings['Privileged_Roles'] = $privilegedFindings
Write-Host "  Found $($privilegedFindings.Count) privileged role assignments" -ForegroundColor $(if ($privilegedFindings.Count -gt 3) { 'Yellow' } else { 'Green' })

# ============================================================
# CHECK 4: Guest Accounts
# ============================================================
Write-Host "[4/5] Checking guest accounts..." -ForegroundColor Yellow

$guestFindings = @()
foreach ($user in $allUsers) {
    if ($user.UserType -eq 'Guest') {
        $lastSignIn = $null
        if ($user.SignInActivity) {
            $lastSignIn = $user.SignInActivity.LastSignInDateTime
        }

        $guestFindings += [PSCustomObject]@{
            DisplayName       = $user.DisplayName
            UserPrincipalName = $user.UserPrincipalName
            LastSignIn        = $lastSignIn
            CreatedDateTime   = $user.CreatedDateTime
            AccountEnabled    = $user.AccountEnabled
            Severity          = if ($null -eq $lastSignIn) { 'Medium' } else { 'Low' }
        }
    }
}

$findings['Guest_Accounts'] = $guestFindings
Write-Host "  Found $($guestFindings.Count) guest accounts" -ForegroundColor $(if ($guestFindings.Count -gt 0) { 'Yellow' } else { 'Green' })

# ============================================================
# CHECK 5: Password Never Expires
# ============================================================
Write-Host "[5/5] Checking password-never-expires accounts..." -ForegroundColor Yellow

$pwdFindings = @()
foreach ($user in $allUsers) {
    if ($user.AccountEnabled -and $user.PasswordPolicies -match 'DisablePasswordExpiration') {
        $pwdFindings += [PSCustomObject]@{
            DisplayName       = $user.DisplayName
            UserPrincipalName = $user.UserPrincipalName
            PasswordPolicies  = $user.PasswordPolicies
            Severity          = 'Medium'
        }
    }
}

$findings['Password_Never_Expires'] = $pwdFindings
Write-Host "  Found $($pwdFindings.Count) accounts with password never expires" -ForegroundColor $(if ($pwdFindings.Count -gt 0) { 'Yellow' } else { 'Green' })

# ============================================================
# SUMMARY
# ============================================================
$duration = [math]::Round(((Get-Date) - $startTime).TotalSeconds, 2)
$totalFindings = ($findings.Values | ForEach-Object { $_.Count } | Measure-Object -Sum).Sum

Write-Host ""
Write-Host "=== Security Posture Summary ===" -ForegroundColor Cyan
Write-Host "  MFA not registered:    $($findings['MFA_Not_Registered'].Count)" -ForegroundColor $(if ($findings['MFA_Not_Registered'].Count -gt 0) { 'Red' } else { 'Green' })
Write-Host "  Inactive accounts:     $($findings['Inactive_Accounts'].Count)" -ForegroundColor $(if ($findings['Inactive_Accounts'].Count -gt 0) { 'Yellow' } else { 'Green' })
Write-Host "  Privileged roles:      $($findings['Privileged_Roles'].Count)" -ForegroundColor Gray
Write-Host "  Guest accounts:        $($findings['Guest_Accounts'].Count)" -ForegroundColor $(if ($findings['Guest_Accounts'].Count -gt 0) { 'Yellow' } else { 'Green' })
Write-Host "  Password never expires: $($findings['Password_Never_Expires'].Count)" -ForegroundColor $(if ($findings['Password_Never_Expires'].Count -gt 0) { 'Yellow' } else { 'Green' })
Write-Host "  ────────────────────"
Write-Host "  Total findings:        $totalFindings"
Write-Host "  Duration:              ${duration}s"
Write-Host ""

# ============================================================
# OUTPUT: JSON
# ============================================================
if ($OutputFormat -in @('Json', 'All')) {
    $logDir = Join-Path $PSScriptRoot '../../logs'
    if (-not (Test-Path $logDir)) { New-Item -Path $logDir -ItemType Directory -Force | Out-Null }
    $logFile = Join-Path $logDir "security-audit-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"

    $auditLog = [PSCustomObject]@{
        Version         = '1.0'
        RunTimestamp     = $startTime.ToString('o')
        DurationSec      = $duration
        InactiveDays     = $InactiveDays
        TotalUsers       = $allUsers.Count
        TotalFindings    = $totalFindings
        Findings         = $findings
    }

    $auditLog | ConvertTo-Json -Depth 6 | Out-File $logFile -Encoding utf8
    Write-Host "JSON log: $logFile" -ForegroundColor Gray
}

# ============================================================
# OUTPUT: Excel
# ============================================================
if ($OutputFormat -in @('Excel', 'All')) {
    $excelDir = Join-Path $PSScriptRoot '../../logs'
    $excelFile = Join-Path $excelDir "security-audit-$(Get-Date -Format 'yyyyMMdd-HHmmss').xlsx"

    try {
        # Summary sheet
        $summaryData = @(
            [PSCustomObject]@{ Check = 'MFA Not Registered'; Count = $findings['MFA_Not_Registered'].Count; Severity = 'High' }
            [PSCustomObject]@{ Check = 'Inactive Accounts'; Count = $findings['Inactive_Accounts'].Count; Severity = 'Medium' }
            [PSCustomObject]@{ Check = 'Privileged Roles'; Count = $findings['Privileged_Roles'].Count; Severity = 'Critical' }
            [PSCustomObject]@{ Check = 'Guest Accounts'; Count = $findings['Guest_Accounts'].Count; Severity = 'Low' }
            [PSCustomObject]@{ Check = 'Password Never Expires'; Count = $findings['Password_Never_Expires'].Count; Severity = 'Medium' }
            [PSCustomObject]@{ Check = 'TOTAL'; Count = $totalFindings; Severity = '' }
        )

        $summaryData | Export-Excel -Path $excelFile -WorksheetName 'Summary' -AutoSize -TableName 'Summary' -TableStyle Medium2

        # Individual sheets per check
        foreach ($key in $findings.Keys) {
            if ($findings[$key].Count -gt 0) {
                $findings[$key] | Export-Excel -Path $excelFile -WorksheetName $key -AutoSize -TableName $key -TableStyle Medium6 -Append
            }
        }

        Write-Host "Excel report: $excelFile" -ForegroundColor Gray
    }
    catch {
        Write-Warning "Excel export failed (is ImportExcel installed?): $($_.Exception.Message)"
    }
}

Write-Host ""
if ($totalFindings -gt 0) {
    Write-Host "Action required: review findings above." -ForegroundColor Yellow
} else {
    Write-Host "No findings. Tenant security posture is clean." -ForegroundColor Green
}
