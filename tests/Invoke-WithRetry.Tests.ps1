# Pester 5 tests for Invoke-WithRetry.ps1
#
# Run locally: Invoke-Pester -Path ./tests/Invoke-WithRetry.Tests.ps1
# These tests are pure logic — no real Graph calls. The throttle exception is
# simulated by throwing an ErrorRecord whose ErrorDetails contains "code":"429".

BeforeAll {
    $script:HelperPath = Resolve-Path (Join-Path $PSScriptRoot '..' 'modules/M365Helper/Invoke-WithRetry.ps1')
    . $script:HelperPath
}

Describe 'Invoke-WithRetry' {

    Context 'Success path' {

        It 'returns the value from the script block' {
            $result = Invoke-WithRetry -ScriptBlock { return 42 }
            $result | Should -Be 42
        }

        It 'invokes the script block exactly once on first-try success' {
            $script:CallCount = 0
            $null = Invoke-WithRetry -ScriptBlock {
                $script:CallCount++
                return 'ok'
            }
            $script:CallCount | Should -Be 1
        }

        It 'handles return values of different shapes' {
            (Invoke-WithRetry -ScriptBlock { return @(1, 2, 3) }) -is [array] | Should -BeTrue
            (Invoke-WithRetry -ScriptBlock { return @{a=1; b=2} }) -is [hashtable] | Should -BeTrue
            Invoke-WithRetry -ScriptBlock { return $null } | Should -BeNullOrEmpty
        }
    }

    Context 'Non-throttling exceptions' {

        It 're-throws non-throttling errors immediately, with no retry' {
            $script:Attempts = 0
            $action = {
                Invoke-WithRetry -ScriptBlock {
                    $script:Attempts++
                    throw 'permanent failure'
                } -InitialDelaySec 0
            }
            $action | Should -Throw
            $script:Attempts | Should -Be 1
        }

        It 're-throws non-throttling status codes immediately' {
            $script:Attempts = 0
            $action = {
                Invoke-WithRetry -ScriptBlock {
                    $script:Attempts++
                    $err = [System.Management.Automation.ErrorRecord]::new(
                        [Exception]::new('Forbidden'),
                        '403', 'PermissionDenied', $null
                    )
                    $err.ErrorDetails = '"code":"403"'
                    throw $err
                } -InitialDelaySec 0
            }
            $action | Should -Throw
            $script:Attempts | Should -Be 1
        }
    }

    Context 'Throttling (429 / 503) retry' {

        It 'retries on 429 and eventually succeeds' {
            $script:Attempts = 0
            $result = Invoke-WithRetry -ScriptBlock {
                $script:Attempts++
                if ($script:Attempts -lt 3) {
                    $err = [System.Management.Automation.ErrorRecord]::new(
                        [Exception]::new('Throttled'),
                        '429', 'OperationStopped', $null
                    )
                    $err.ErrorDetails = '"code":"429"'
                    throw $err
                }
                return 'success'
            } -MaxRetries 5 -InitialDelaySec 0
            $result | Should -Be 'success'
            $script:Attempts | Should -Be 3
        }

        It 'retries on 503 (treated as throttling)' {
            $script:Attempts = 0
            $result = Invoke-WithRetry -ScriptBlock {
                $script:Attempts++
                if ($script:Attempts -lt 2) {
                    $err = [System.Management.Automation.ErrorRecord]::new(
                        [Exception]::new('Service Unavailable'),
                        '503', 'OperationStopped', $null
                    )
                    $err.ErrorDetails = '"code":"503"'
                    throw $err
                }
                return 'recovered'
            } -MaxRetries 3 -InitialDelaySec 0
            $result | Should -Be 'recovered'
            $script:Attempts | Should -Be 2
        }

        It 'gives up and re-throws after MaxRetries' {
            $script:Attempts = 0
            $action = {
                Invoke-WithRetry -ScriptBlock {
                    $script:Attempts++
                    $err = [System.Management.Automation.ErrorRecord]::new(
                        [Exception]::new('Always throttled'),
                        '429', 'OperationStopped', $null
                    )
                    $err.ErrorDetails = '"code":"429"'
                    throw $err
                } -MaxRetries 2 -InitialDelaySec 0
            }
            $action | Should -Throw
            # initial attempt + 2 retries = 3 calls
            $script:Attempts | Should -Be 3
        }
    }
}
