# Demo: pre-flight validation catches a deliberately broken CSV
$root = $PSScriptRoot
$result = & "$root/scripts/01-bulk-onboarding/Test-OnboardingCsv.ps1" -CsvPath "$root/demo-data/csv-invalid-example.csv"

Write-Host ""
Write-Host "=== Validation Result ===" -ForegroundColor Cyan
Write-Host "IsValid: $($result.IsValid)" -ForegroundColor $(if ($result.IsValid) { 'Green' } else { 'Red' })
Write-Host "Errors found: $($result.Errors.Count)"
Write-Host ""
$result.Errors | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
Write-Host ""
