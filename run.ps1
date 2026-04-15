<#
.SYNOPSIS
    Single entry point for all M365 Automation Toolkit operations.
.EXAMPLE
    ./run.ps1 onboard -DryRun
    ./run.ps1 onboard
    ./run.ps1 audit
    ./run.ps1 offboard -DryRun
    ./run.ps1 offboard
    ./run.ps1 validate
    ./run.ps1 clean
    ./run.ps1 dedupe-groups
#>
param(
    [Parameter(Mandatory=$true, Position=0)]
    [ValidateSet('onboard','audit','offboard','validate','clean','dedupe-groups')]
    [string]$Command,
    [switch]$DryRun
)

$root = $PSScriptRoot
switch ($Command) {
    'onboard' {
        $params = @{ CsvPath = "$root/demo-data/new-hires-2026-05.csv" }
        if ($DryRun) { $params['DryRun'] = $true }
        & "$root/scripts/01-bulk-onboarding/Invoke-UserOnboarding.ps1" @params
    }
    'audit' {
        $params = @{ OutputFormat = if ($DryRun) { 'Console' } else { 'All' } }
        if ($DryRun) { $params['DryRun'] = $true }
        & "$root/scripts/02-security-audit/Get-SecurityPosture.ps1" @params
    }
    'offboard' {
        $params = @{ CsvPath = "$root/demo-data/offboarding-list.csv" }
        if ($DryRun) { $params['DryRun'] = $true }
        & "$root/scripts/03-offboarding/Invoke-UserOffboarding.ps1" @params
    }
    'validate' {
        $result = & "$root/scripts/01-bulk-onboarding/Test-OnboardingCsv.ps1" -CsvPath "$root/demo-data/csv-invalid-example.csv"
        Write-Host "`nIsValid: $($result.IsValid)" -ForegroundColor $(if ($result.IsValid) {'Green'} else {'Red'})
        $result.Errors | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
    }
    'clean' {
        & "$root/scripts/01-bulk-onboarding/Remove-BulkEntraUsers.ps1" -CsvPath "$root/demo-data/new-hires-2026-05.csv" -Force
    }
    'dedupe-groups' {
        & "$root/scripts/01-bulk-onboarding/Remove-DuplicateGroups.ps1"
    }
}
