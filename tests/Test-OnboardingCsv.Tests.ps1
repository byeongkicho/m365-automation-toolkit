# Pester 5 tests for Test-OnboardingCsv.ps1
#
# Run locally: Invoke-Pester -Path ./tests/Test-OnboardingCsv.Tests.ps1
# These tests are pure logic — no Microsoft Graph calls. Safe in CI.

BeforeAll {
    $script:ScriptPath = Resolve-Path (Join-Path $PSScriptRoot '..' 'scripts/01-bulk-onboarding/Test-OnboardingCsv.ps1')
}

Describe 'Test-OnboardingCsv' {

    BeforeEach {
        $script:TempDir = New-Item -ItemType Directory -Path (Join-Path ([System.IO.Path]::GetTempPath()) "csv-tests-$(Get-Random)") -Force
    }

    AfterEach {
        if (Test-Path $script:TempDir.FullName) {
            Remove-Item -Recurse -Force $script:TempDir.FullName
        }
    }

    function New-TestCsv {
        param([string]$Content, [string]$Name = 'test.csv')
        $path = Join-Path $script:TempDir.FullName $Name
        $Content | Set-Content -Path $path -Encoding utf8
        return $path
    }

    Context 'Schema validation' {

        It 'accepts a complete valid CSV' {
            $csv = New-TestCsv @'
DisplayName,MailNickname,GivenName,Surname,Department,JobTitle,UsageLocation
Test User,test.user,Test,User,Engineering,Engineer,KR
'@
            $result = & $script:ScriptPath -CsvPath $csv
            $result.IsValid | Should -BeTrue
            $result.Errors.Count | Should -Be 0
            $result.RowCount | Should -Be 1
        }

        It 'fails when a required column is missing' {
            $csv = New-TestCsv @'
DisplayName,MailNickname
Test User,test.user
'@
            $result = & $script:ScriptPath -CsvPath $csv
            $result.IsValid | Should -BeFalse
            $result.Errors | Where-Object { $_ -match 'Missing required column' } | Should -Not -BeNullOrEmpty
        }

        It 'fails for an empty CSV (header only)' {
            $csv = New-TestCsv 'DisplayName,MailNickname,GivenName,Surname,Department,JobTitle,UsageLocation'
            $result = & $script:ScriptPath -CsvPath $csv
            $result.IsValid | Should -BeFalse
            $result.Errors[0] | Should -Match 'empty'
        }

        It 'fails when the CSV file does not exist' {
            $result = & $script:ScriptPath -CsvPath '/nonexistent/path.csv'
            $result.IsValid | Should -BeFalse
            $result.Errors[0] | Should -Match 'not found'
        }
    }

    Context 'Duplicate detection' {

        It 'detects duplicate MailNickname within the CSV' {
            $csv = New-TestCsv @'
DisplayName,MailNickname,GivenName,Surname,Department,JobTitle,UsageLocation
User One,john.smith,John,Smith,Engineering,Engineer,KR
User Two,john.smith,Jane,Doe,Marketing,Manager,KR
'@
            $result = & $script:ScriptPath -CsvPath $csv
            $result.IsValid | Should -BeFalse
            $result.Errors | Where-Object { $_ -match 'Duplicate' } | Should -Not -BeNullOrEmpty
        }
    }

    Context 'Per-row validation' {

        It 'rejects an empty required field' {
            $csv = New-TestCsv @'
DisplayName,MailNickname,GivenName,Surname,Department,JobTitle,UsageLocation
,test.user,Test,User,Engineering,Engineer,KR
'@
            $result = & $script:ScriptPath -CsvPath $csv
            $result.IsValid | Should -BeFalse
            $result.Errors | Where-Object { $_ -match "DisplayName" } | Should -Not -BeNullOrEmpty
        }

        It 'rejects MailNickname with uppercase letters' {
            $csv = New-TestCsv @'
DisplayName,MailNickname,GivenName,Surname,Department,JobTitle,UsageLocation
Test User,JOHN.SMITH,Test,User,Engineering,Engineer,KR
'@
            $result = & $script:ScriptPath -CsvPath $csv
            $result.IsValid | Should -BeFalse
            $result.Errors | Where-Object { $_ -match 'MailNickname' } | Should -Not -BeNullOrEmpty
        }

        It 'rejects MailNickname with special characters' {
            $csv = New-TestCsv @'
DisplayName,MailNickname,GivenName,Surname,Department,JobTitle,UsageLocation
Test User,john_smith,Test,User,Engineering,Engineer,KR
'@
            $result = & $script:ScriptPath -CsvPath $csv
            $result.IsValid | Should -BeFalse
            $result.Errors | Where-Object { $_ -match 'MailNickname' } | Should -Not -BeNullOrEmpty
        }

        It 'rejects unknown Department' {
            $csv = New-TestCsv @'
DisplayName,MailNickname,GivenName,Surname,Department,JobTitle,UsageLocation
Test User,test.user,Test,User,Astrology,Engineer,KR
'@
            $result = & $script:ScriptPath -CsvPath $csv
            $result.IsValid | Should -BeFalse
            $result.Errors | Where-Object { $_ -match 'Department' } | Should -Not -BeNullOrEmpty
        }

        It 'rejects an invalid UsageLocation' {
            $csv = New-TestCsv @'
DisplayName,MailNickname,GivenName,Surname,Department,JobTitle,UsageLocation
Test User,test.user,Test,User,Engineering,Engineer,XX
'@
            $result = & $script:ScriptPath -CsvPath $csv
            $result.IsValid | Should -BeFalse
            $result.Errors | Where-Object { $_ -match 'UsageLocation' } | Should -Not -BeNullOrEmpty
        }

        It 'rejects MailNickname longer than 64 characters' {
            $longName = 'a' * 65
            $csv = New-TestCsv @"
DisplayName,MailNickname,GivenName,Surname,Department,JobTitle,UsageLocation
Test User,$longName,Test,User,Engineering,Engineer,KR
"@
            $result = & $script:ScriptPath -CsvPath $csv
            $result.IsValid | Should -BeFalse
            $result.Errors | Where-Object { $_ -match '64' } | Should -Not -BeNullOrEmpty
        }
    }

    Context 'Custom ValidDepartments override' {

        It 'accepts a department that is in the override list' {
            $csv = New-TestCsv @'
DisplayName,MailNickname,GivenName,Surname,Department,JobTitle,UsageLocation
Test User,test.user,Test,User,Astrology,Astrologer,KR
'@
            $result = & $script:ScriptPath -CsvPath $csv -ValidDepartments @('Astrology', 'Magic')
            $result.IsValid | Should -BeTrue
        }
    }

    Context 'Multiple errors aggregation' {

        It 'reports all errors, not just the first' {
            $csv = New-TestCsv @'
DisplayName,MailNickname,GivenName,Surname,Department,JobTitle,UsageLocation
,BAD_NAME,Test,User,Astrology,Engineer,XX
'@
            $result = & $script:ScriptPath -CsvPath $csv
            $result.IsValid | Should -BeFalse
            $result.Errors.Count | Should -BeGreaterOrEqual 3
        }
    }
}
