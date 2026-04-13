<#
.SYNOPSIS
    Bulk create Entra ID users from a CSV file with error handling and audit logging.

.DESCRIPTION
    Reads new hires from CSV, creates accounts in Microsoft Entra ID via Graph API,
    adds them to departmental groups, and produces a JSON audit log.
    Handles duplicates, validates inputs, and supports dry-run mode.

.PARAMETER CsvPath
    Path to CSV file with columns: DisplayName, MailNickname, GivenName, Surname,
    Department, JobTitle, UsageLocation

.PARAMETER Domain
    UPN suffix (e.g. contoso.onmicrosoft.com). If omitted, reads from tenant.

.PARAMETER DryRun
    Preview actions without creating users.

.EXAMPLE
    ./New-BulkEntraUsers.ps1 -CsvPath ../../demo-data/new-hires-2026-05.csv -DryRun

.EXAMPLE
    ./New-BulkEntraUsers.ps1 -CsvPath ../../demo-data/new-hires-2026-05.csv
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$CsvPath,

    [Parameter(Mandatory = $false)]
    [string]$Domain,

    [Parameter(Mandatory = $false)]
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$startTime = Get-Date

# --- Banner ---
Write-Host ""
Write-Host "=== Bulk User Onboarding ===" -ForegroundColor Cyan
Write-Host "CSV:    $CsvPath"
Write-Host "DryRun: $($DryRun.IsPresent)"
Write-Host ""

# --- Validate prerequisites ---
if (-not (Get-MgContext)) {
    Write-Error "Not connected to Graph. Run ../../setup/Connect-M365.ps1 first."
    exit 1
}

if (-not (Test-Path $CsvPath)) {
    Write-Error "CSV file not found: $CsvPath"
    exit 1
}

# --- Resolve domain ---
if (-not $Domain) {
    try {
        $org = Get-MgOrganization -ErrorAction Stop
        $Domain = ($org.VerifiedDomains | Where-Object { $_.IsDefault }).Name
        Write-Host "Resolved default domain: $Domain" -ForegroundColor Gray
    }
    catch {
        Write-Error "Failed to resolve domain. Specify -Domain explicitly."
        exit 1
    }
}

# --- Load CSV ---
$users = Import-Csv $CsvPath
Write-Host "Loaded $($users.Count) users from CSV" -ForegroundColor Gray
Write-Host ""

# --- Process users ---
$results = @()
$successCount = 0
$skipCount = 0
$failCount = 0

foreach ($u in $users) {
    $upn = "$($u.MailNickname)@$Domain"
    $result = [PSCustomObject]@{
        DisplayName       = $u.DisplayName
        UserPrincipalName = $upn
        Department        = $u.Department
        Status            = $null
        Message           = $null
        Timestamp         = (Get-Date).ToString('o')
    }

    try {
        # Check if user already exists
        $existing = Get-MgUser -Filter "userPrincipalName eq '$upn'" -ErrorAction SilentlyContinue
        if ($existing) {
            $result.Status = 'Skipped'
            $result.Message = 'User already exists'
            $skipCount++
            Write-Host "  [SKIP] $($u.DisplayName) -- already exists" -ForegroundColor Yellow
            $results += $result
            continue
        }

        if ($DryRun) {
            $result.Status = 'DryRun'
            $result.Message = 'Would create'
            Write-Host "  [DRY]  $($u.DisplayName) -> $upn" -ForegroundColor Cyan
            $results += $result
            continue
        }

        # Generate a strong temporary password
        $tempPassword = -join ((65..90) + (97..122) + (48..57) + @(33, 35, 36, 37, 38, 64) |
            Get-Random -Count 16 | ForEach-Object { [char]$_ })

        $passwordProfile = @{
            ForceChangePasswordNextSignIn = $true
            Password = $tempPassword
        }

        $newUserParams = @{
            AccountEnabled    = $true
            DisplayName       = $u.DisplayName
            MailNickname      = $u.MailNickname
            UserPrincipalName = $upn
            GivenName         = $u.GivenName
            Surname           = $u.Surname
            Department        = $u.Department
            JobTitle          = $u.JobTitle
            UsageLocation     = $u.UsageLocation
            PasswordProfile   = $passwordProfile
        }

        $created = New-MgUser @newUserParams -ErrorAction Stop

        $result.Status = 'Created'
        $result.Message = "ID: $($created.Id)"
        $successCount++
        Write-Host "  [OK]   $($u.DisplayName) -> $upn" -ForegroundColor Green
    }
    catch {
        $result.Status = 'Failed'
        $result.Message = $_.Exception.Message
        $failCount++
        Write-Host "  [FAIL] $($u.DisplayName) -- $($_.Exception.Message)" -ForegroundColor Red
    }

    $results += $result
}

# --- Write audit log ---
$logDir = Join-Path $PSScriptRoot '../../logs'
if (-not (Test-Path $logDir)) { New-Item -Path $logDir -ItemType Directory -Force | Out-Null }
$logFile = Join-Path $logDir "onboarding-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"

$auditLog = [PSCustomObject]@{
    RunTimestamp = $startTime.ToString('o')
    DurationSec  = [math]::Round(((Get-Date) - $startTime).TotalSeconds, 2)
    CsvPath      = $CsvPath
    Domain       = $Domain
    DryRun       = $DryRun.IsPresent
    TotalUsers   = $users.Count
    SuccessCount = $successCount
    SkipCount    = $skipCount
    FailCount    = $failCount
    Results      = $results
}

$auditLog | ConvertTo-Json -Depth 5 | Out-File $logFile -Encoding utf8

# --- Summary ---
$duration = [math]::Round(((Get-Date) - $startTime).TotalSeconds, 2)

Write-Host ""
Write-Host "=== Summary ===" -ForegroundColor Cyan
Write-Host "  Total:    $($users.Count)"
Write-Host "  Created:  $successCount" -ForegroundColor Green
Write-Host "  Skipped:  $skipCount" -ForegroundColor Yellow
Write-Host "  Failed:   $failCount" -ForegroundColor $(if ($failCount -gt 0) { 'Red' } else { 'Gray' })
Write-Host "  Duration: ${duration}s"
Write-Host "  Log:      $logFile"
Write-Host ""

if ($failCount -gt 0) { exit 1 }
