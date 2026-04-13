# Offboarding dry-run wrapper (CSV)
$root = $PSScriptRoot
& "$root/scripts/03-offboarding/Invoke-UserOffboarding.ps1" -CsvPath "$root/demo-data/offboarding-list.csv" -DryRun
