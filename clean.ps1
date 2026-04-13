# Short wrapper: delete all demo users
$root = $PSScriptRoot
& "$root/scripts/01-bulk-onboarding/Remove-BulkEntraUsers.ps1" -CsvPath "$root/demo-data/new-hires-2026-05.csv" -Force
