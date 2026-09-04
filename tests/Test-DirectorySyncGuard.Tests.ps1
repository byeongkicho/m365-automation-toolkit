# Pester 5 tests for Test-DirectorySyncGuard.ps1
#
# Run locally: Invoke-Pester -Path ./tests/Test-DirectorySyncGuard.Tests.ps1
# Pure logic — no Graph connection required.
#
# Context: every script in this toolkit was written against a cloud-only tenant.
# In a hybrid tenant, Graph accepts a write to a synced user, the script logs
# success, and Entra Connect reverts the value on the next cycle. For offboarding
# that means the log says "account disabled" and the leaver signs in the next
# morning. These tests lock in the distinction between "the call succeeded" and
# "the change will still be there in 30 minutes".

BeforeAll {
    . (Resolve-Path (Join-Path $PSScriptRoot '..' 'modules/M365Helper/Test-DirectorySyncGuard.ps1'))

    function New-SyncedUser   { [PSCustomObject]@{ DisplayName='Synced User'; OnPremisesSyncEnabled = $true } }
    function New-CloudUser    { [PSCustomObject]@{ DisplayName='Cloud User';  OnPremisesSyncEnabled = $null } }
    # A user fetched without onPremisesSyncEnabled in -Property: the property is
    # absent entirely, which is NOT the same as it being null.
    function New-UnknownUser  { [PSCustomObject]@{ DisplayName='Unknown User' } }
}

Describe 'Test-UserIsSynced' {

    It 'identifies a synced user' {
        $r = Test-UserIsSynced -User (New-SyncedUser)
        $r.IsSynced | Should -BeTrue
        $r.IsKnown  | Should -BeTrue
    }

    It 'identifies a cloud-only user' {
        $r = Test-UserIsSynced -User (New-CloudUser)
        $r.IsSynced | Should -BeFalse
        $r.IsKnown  | Should -BeTrue
    }

    It 'reports IsKnown=false when the property was never requested' {
        # The whole point: a missing flag must not be read as "cloud-only".
        $r = Test-UserIsSynced -User (New-UnknownUser)
        $r.IsKnown  | Should -BeFalse
        $r.IsSynced | Should -BeFalse
        $r.Reason   | Should -Match 'not requested'
    }
}

Describe 'Test-DirectorySyncGuard' {

    It 'lets every field through for a cloud-only user' {
        $r = Test-DirectorySyncGuard -User (New-CloudUser) -Fields @('DisplayName','Department')
        $r.Verdict           | Should -Be 'Proceed'
        $r.WillPersist.Count | Should -Be 2
        $r.WillBeOverwritten | Should -BeNullOrEmpty
    }

    It 'blocks when every requested field is on-prem authoritative' {
        $r = Test-DirectorySyncGuard -User (New-SyncedUser) -Fields @('DisplayName','Department','JobTitle')
        $r.Verdict                 | Should -Be 'Block'
        $r.WillBeOverwritten.Count | Should -Be 3
        $r.Reason                  | Should -Match 'reverts'
    }

    It 'allows cloud-manageable fields on a synced user' {
        # UsageLocation has no on-prem counterpart in the default attribute flow,
        # so licensing still works for synced users.
        $r = Test-DirectorySyncGuard -User (New-SyncedUser) -Fields @('UsageLocation')
        $r.Verdict     | Should -Be 'Proceed'
        $r.WillPersist | Should -Contain 'UsageLocation'
    }

    It 'splits a mixed write instead of failing all or nothing' {
        $r = Test-DirectorySyncGuard -User (New-SyncedUser) -Fields @('Department','UsageLocation')
        $r.Verdict           | Should -Be 'ProceedPartial'
        $r.WillPersist       | Should -Contain 'UsageLocation'
        $r.WillBeOverwritten | Should -Contain 'Department'
    }

    It 'returns Unknown rather than guessing when sync state was not fetched' {
        $r = Test-DirectorySyncGuard -User (New-UnknownUser) -Fields @('AccountEnabled')
        $r.Verdict | Should -Be 'Unknown'
        $r.Reason  | Should -Match '-Property'
    }
}

Describe 'Get-OffboardingSyncImpact' {

    It 'flags offboarding a synced user as ineffective and Critical' {
        $r = Get-OffboardingSyncImpact -User (New-SyncedUser)
        $r.IsEffective      | Should -BeFalse
        $r.Severity         | Should -Be 'Critical'
        $r.IneffectiveSteps | Should -Contain 'Disable account (AccountEnabled)'
        $r.Guidance         | Should -Match 'on-premises AD'
    }

    It 'confirms offboarding is authoritative for a cloud-only user' {
        $r = Get-OffboardingSyncImpact -User (New-CloudUser)
        $r.IsEffective | Should -BeTrue
        $r.Severity    | Should -Be 'None'
    }

    It 'does not claim effectiveness it cannot verify' {
        $r = Get-OffboardingSyncImpact -User (New-UnknownUser)
        $r.Severity | Should -Be 'Unknown'
    }

    It 'does not list session revocation as ineffective' {
        # Revoking sessions is a cloud-side operation and does take effect;
        # claiming otherwise would be as wrong as the bug this guards against.
        $r = Get-OffboardingSyncImpact -User (New-SyncedUser)
        ($r.IneffectiveSteps -join ' ') | Should -Not -Match 'session|Session'
        $r.Guidance | Should -Match 'Revoking sessions still works'
    }
}
