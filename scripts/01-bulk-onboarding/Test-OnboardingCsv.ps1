<#
.SYNOPSIS
    Pre-flight validation for the onboarding CSV.

.DESCRIPTION
    Validates schema, duplicates, naming conventions, and value whitelists
    before any user is created. Returns a list of errors. If empty, the CSV
    is safe to feed into New-BulkEntraUsers.ps1.

    Designed to run in CI on every PR that touches a CSV.

.PARAMETER CsvPath
    Path to the onboarding CSV.

.PARAMETER ValidDepartments
    Whitelist of allowed Department values. Defaults to a sample list.

.OUTPUTS
    PSCustomObject with .IsValid (bool) and .Errors (string[]).

.EXAMPLE
    $result = ./Test-OnboardingCsv.ps1 -CsvPath ../../demo-data/new-hires-2026-05.csv
    if (-not $result.IsValid) { $result.Errors | ForEach-Object { Write-Error $_ } }
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$CsvPath,

    [Parameter(Mandatory = $false)]
    [string[]]$ValidDepartments = @('Engineering', 'Sales', 'HR', 'Finance', 'Marketing', 'Operations', 'Legal')
)

$errors = @()
$requiredColumns = @('DisplayName', 'MailNickname', 'GivenName', 'Surname', 'Department', 'JobTitle', 'UsageLocation')
$validCountries = @('KR', 'US', 'JP', 'GB', 'DE', 'FR', 'SG', 'AU', 'CA')

if (-not (Test-Path $CsvPath)) {
    return [PSCustomObject]@{
        IsValid = $false
        Errors  = @("CSV file not found: $CsvPath")
    }
}

$users = @(Import-Csv $CsvPath)

if ($users.Count -eq 0) {
    return [PSCustomObject]@{
        IsValid = $false
        Errors  = @('CSV is empty')
    }
}

# 1. Schema check
$actualColumns = $users[0].PSObject.Properties.Name
foreach ($col in $requiredColumns) {
    if ($col -notin $actualColumns) {
        $errors += "Missing required column: $col"
    }
}

if ($errors.Count -gt 0) {
    return [PSCustomObject]@{
        IsValid = $false
        Errors  = $errors
    }
}

# 2. Duplicate MailNickname within the CSV
$dupes = $users | Group-Object MailNickname | Where-Object Count -gt 1
foreach ($d in $dupes) {
    $errors += "Duplicate MailNickname in CSV: $($d.Name) (appears $($d.Count) times)"
}

# 3. Per-row validation
for ($i = 0; $i -lt $users.Count; $i++) {
    $u = $users[$i]
    $row = $i + 2  # +2: 1 for header, 1 for 0-index

    # Required field non-empty
    foreach ($col in $requiredColumns) {
        if ([string]::IsNullOrWhiteSpace($u.$col)) {
            $errors += "Row ${row}: empty value in column '$col'"
        }
    }

    # MailNickname format (lowercase letters, digits, dots only)
    # NOTE: -cnotmatch (case-sensitive) is required here. PowerShell's
    # default -notmatch is case-insensitive, which would silently allow
    # MailNicknames like "JOHN.SMITH" to pass this regex despite the
    # intent being lowercase-only. Caught by Pester unit test.
    if ($u.MailNickname -and $u.MailNickname -cnotmatch '^[a-z0-9.]+$') {
        $errors += "Row ${row}: invalid MailNickname '$($u.MailNickname)' (use lowercase letters, digits, dots)"
    }

    # MailNickname length
    if ($u.MailNickname -and $u.MailNickname.Length -gt 64) {
        $errors += "Row ${row}: MailNickname '$($u.MailNickname)' exceeds 64 characters"
    }

    # Department whitelist
    if ($u.Department -and $u.Department -notin $ValidDepartments) {
        $errors += "Row ${row}: invalid Department '$($u.Department)' (allowed: $($ValidDepartments -join ', '))"
    }

    # UsageLocation: ISO 3166-1 alpha-2
    if ($u.UsageLocation -and $u.UsageLocation -notin $validCountries) {
        $errors += "Row ${row}: invalid UsageLocation '$($u.UsageLocation)' (allowed: $($validCountries -join ', '))"
    }
}

return [PSCustomObject]@{
    IsValid = ($errors.Count -eq 0)
    Errors  = $errors
    RowCount = $users.Count
}
