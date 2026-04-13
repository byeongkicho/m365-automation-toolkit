<#
.SYNOPSIS
    Bulk delete Entra ID users created from a CSV file.

.DESCRIPTION
    Removes users matching the MailNickname column in the CSV from Microsoft Entra ID.
    Used to clean up demo data or roll back failed onboarding runs.
    Supports dry-run mode and produces an audit log.

.PARAMETER CsvPath
    Path to CSV file with the same format used by New-BulkEntraUsers.ps1.
    Required column: MailNickname

.PARAMETER Domain
    UPN suffix. If omitted, reads from tenant.

.PARAMETER DryRun
    Preview deletions without removing users.

.PARAMETER Force
    Skip confirmation prompt.

.EXAMPLE
    ./Remove-BulkEntraUsers.ps1 -CsvPath ../../demo-data/new-hires-2026-05.csv -DryRun

.EXAMPLE
    ./Remove-BulkEntraUsers.ps1 -CsvPath ../../demo-data/new-hires-2026-05.csv -Force
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
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$startTime = Get-Date

Write-Host ""
Write-Host "=== Bulk User Removal ===" -ForegroundColor Cyan
Write-Host "CSV:    $CsvPath"
Write-Host "DryRun: $($DryRun.IsPresent)"
Write-Host ""

if (-not (Get-MgContext)) {
    Write-Error "Not connected to Graph. Run ../../setup/Connect-M365.ps1 first."
    exit 1
}

if (-not (Test-Path $CsvPath)) {
    Write-Error "CSV file not found: $CsvPath"
    exit 1
}

# Resolve domain
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

$users = Import-Csv $CsvPath
Write-Host "Loaded $($users.Count) users from CSV" -ForegroundColor Gray
Write-Host ""

# Confirmation prompt unless -Force or -DryRun
if (-not $DryRun -and -not $Force) {
    Write-Host "WARNING: This will permanently delete $($users.Count) users from $Domain" -ForegroundColor Red
    $confirm = Read-Host "Type 'DELETE' to confirm"
    if ($confirm -ne 'DELETE') {
        Write-Host "Cancelled." -ForegroundColor Yellow
        exit 0
    }
    Write-Host ""
}

$results = @()
$deletedCount = 0
$notFoundCount = 0
$failCount = 0

foreach ($u in $users) {
    $upn = "$($u.MailNickname)@$Domain"
    $result = [PSCustomObject]@{
        DisplayName       = $u.DisplayName
        UserPrincipalName = $upn
        Status            = $null
        Message           = $null
        Timestamp         = (Get-Date).ToString('o')
    }

    try {
        $existing = Get-MgUser -Filter "userPrincipalName eq '$upn'" -ErrorAction SilentlyContinue
        if (-not $existing) {
            $result.Status = 'NotFound'
            $result.Message = 'User does not exist'
            $notFoundCount++
            Write-Host "  [SKIP] $($u.DisplayName) -- not found" -ForegroundColor Yellow
            $results += $result
            continue
        }

        if ($DryRun) {
            $result.Status = 'DryRun'
            $result.Message = 'Would delete'
            Write-Host "  [DRY]  $($u.DisplayName) -> $upn" -ForegroundColor Cyan
            $results += $result
            continue
        }

        Remove-MgUser -UserId $existing.Id -ErrorAction Stop

        $result.Status = 'Deleted'
        $result.Message = "ID: $($existing.Id)"
        $deletedCount++
        Write-Host "  [OK]   $($u.DisplayName) deleted" -ForegroundColor Green
    }
    catch {
        $result.Status = 'Failed'
        $result.Message = $_.Exception.Message
        $failCount++
        Write-Host "  [FAIL] $($u.DisplayName) -- $($_.Exception.Message)" -ForegroundColor Red
    }

    $results += $result
}

# Audit log
$logDir = Join-Path $PSScriptRoot '../../logs'
if (-not (Test-Path $logDir)) { New-Item -Path $logDir -ItemType Directory -Force | Out-Null }
$logFile = Join-Path $logDir "removal-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"

$auditLog = [PSCustomObject]@{
    RunTimestamp  = $startTime.ToString('o')
    DurationSec   = [math]::Round(((Get-Date) - $startTime).TotalSeconds, 2)
    CsvPath       = $CsvPath
    Domain        = $Domain
    DryRun        = $DryRun.IsPresent
    TotalUsers    = $users.Count
    DeletedCount  = $deletedCount
    NotFoundCount = $notFoundCount
    FailCount     = $failCount
    Results       = $results
}

$auditLog | ConvertTo-Json -Depth 5 | Out-File $logFile -Encoding utf8

$duration = [math]::Round(((Get-Date) - $startTime).TotalSeconds, 2)

Write-Host ""
Write-Host "=== Summary ===" -ForegroundColor Cyan
Write-Host "  Total:    $($users.Count)"
Write-Host "  Deleted:  $deletedCount" -ForegroundColor Green
Write-Host "  NotFound: $notFoundCount" -ForegroundColor Yellow
Write-Host "  Failed:   $failCount" -ForegroundColor $(if ($failCount -gt 0) { 'Red' } else { 'Gray' })
Write-Host "  Duration: ${duration}s"
Write-Host "  Log:      $logFile"
Write-Host ""

if ($failCount -gt 0) { exit 1 }
