# Dry-run wrapper for Invoke-UserOnboarding (v2, default)
$root = $PSScriptRoot
& "$root/scripts/01-bulk-onboarding/Invoke-UserOnboarding.ps1" -CsvPath "$root/demo-data/new-hires-2026-05.csv" -DryRun
