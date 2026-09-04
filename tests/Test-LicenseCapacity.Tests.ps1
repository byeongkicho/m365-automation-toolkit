# Pester 5 tests for Test-LicenseCapacity.ps1
#
# Run locally: Invoke-Pester -Path ./tests/Test-LicenseCapacity.Tests.ps1
# Pure logic — no Graph connection required. Get-MgSubscribedSku output is
# simulated, including the nested PrepaidUnits object Graph actually returns.
#
# Context: the onboarding script read the SKU catalog for SkuId only and never
# asked whether seats were left. Graph does not fail a bulk run when a tenant
# runs out of seats — it fails one user at a time, partway through, so the run
# half-succeeds and the operator hears about it from the users. These tests lock
# in the seat math, especially the two ways a naive check overcounts:
# grace-period seats and a suspended subscription.

BeforeAll {
    . (Resolve-Path (Join-Path $PSScriptRoot '..' 'modules/M365Helper/Test-LicenseCapacity.ps1'))

    function New-FakeSku {
        param(
            [string]$PartNumber,
            [int]$Enabled,
            [int]$Consumed,
            [int]$Warning = 0,
            [string]$CapabilityStatus = 'Enabled'
        )
        [PSCustomObject]@{
            SkuPartNumber    = $PartNumber
            SkuId            = "sku-$PartNumber"
            ConsumedUnits    = $Consumed
            CapabilityStatus = $CapabilityStatus
            PrepaidUnits     = [PSCustomObject]@{
                Enabled = $Enabled; Warning = $Warning; Suspended = 0
            }
        }
    }
}

Describe 'Get-LicenseCapacity' {

    It 'computes available seats as Enabled minus Consumed' {
        $r = Get-LicenseCapacity -SubscribedSku @(New-FakeSku -PartNumber 'ENTERPRISEPACK' -Enabled 300 -Consumed 250)
        $r.Available | Should -Be 50
        $r.Status | Should -BeNullOrEmpty -Because 'capacity records carry Note, not Status'
    }

    It 'clamps to zero when Consumed exceeds Enabled instead of reporting a negative' {
        # Seats removed from a subscription while still assigned. A negative here
        # would read as capacity in any downstream arithmetic.
        $r = Get-LicenseCapacity -SubscribedSku @(New-FakeSku -PartNumber 'E3' -Enabled 10 -Consumed 14)
        $r.Available | Should -Be 0
    }

    It 'does NOT count grace-period seats as available' {
        # Graph accepts assignments against Warning seats, then they stop working.
        $r = Get-LicenseCapacity -SubscribedSku @(New-FakeSku -PartNumber 'E3' -Enabled 100 -Consumed 100 -Warning 25)
        $r.Available  | Should -Be 0
        $r.GraceSeats | Should -Be 25
        $r.Note       | Should -Match 'grace period'
    }

    It 'marks a suspended subscription as not assignable even when seats look free' {
        $r = Get-LicenseCapacity -SubscribedSku @(New-FakeSku -PartNumber 'E3' -Enabled 500 -Consumed 0 -CapabilityStatus 'Suspended')
        $r.Available    | Should -Be 500
        $r.IsAssignable | Should -BeFalse
        $r.Note         | Should -Match 'suspended'
    }

    It 'treats an unknown CapabilityStatus as assignable rather than silently blocking' {
        $r = Get-LicenseCapacity -SubscribedSku @(New-FakeSku -PartNumber 'E3' -Enabled 10 -Consumed 1 -CapabilityStatus '')
        $r.IsAssignable | Should -BeTrue
    }

    It 'returns nothing for an empty catalog without throwing' {
        { Get-LicenseCapacity -SubscribedSku @() } | Should -Not -Throw
    }
}

Describe 'Test-LicenseCapacity' {

    BeforeAll {
        $script:Cap = Get-LicenseCapacity -SubscribedSku @(
            New-FakeSku -PartNumber 'ENTERPRISEPACK'  -Enabled 300 -Consumed 250
            New-FakeSku -PartNumber 'DESKLESSPACK'    -Enabled 100 -Consumed 40
            New-FakeSku -PartNumber 'EMSPREMIUM'      -Enabled 50  -Consumed 0 -CapabilityStatus 'Suspended'
        )
    }

    It 'reports OK and IsSatisfied when every SKU fits' {
        $r = Test-LicenseCapacity -Capacity $script:Cap -Required @{ ENTERPRISEPACK = 50; DESKLESSPACK = 60 }
        $r.IsSatisfied | Should -BeTrue
        ($r.Rows | Where-Object Status -ne 'OK').Count | Should -Be 0
    }

    It 'reports the exact shortfall, not just a boolean' {
        # 300-seat batch against 50 free seats — the case this module exists for.
        $r = Test-LicenseCapacity -Capacity $script:Cap -Required @{ ENTERPRISEPACK = 300 }
        $r.IsSatisfied | Should -BeFalse
        $row = $r.Rows | Where-Object SkuPartNumber -eq 'ENTERPRISEPACK'
        $row.Status    | Should -Be 'Insufficient'
        $row.Available | Should -Be 50
        $row.Shortfall | Should -Be 250
    }

    It 'passes when the request exactly matches available seats' {
        $r = Test-LicenseCapacity -Capacity $script:Cap -Required @{ ENTERPRISEPACK = 50 }
        $r.IsSatisfied | Should -BeTrue
        ($r.Rows | Where-Object SkuPartNumber -eq 'ENTERPRISEPACK').Shortfall | Should -Be 0
    }

    It 'separates "tenant does not own this SKU" from "out of seats"' {
        # A CSV typo and a capacity problem need different fixes.
        $r = Test-LicenseCapacity -Capacity $script:Cap -Required @{ SPE_E5 = 1 }
        $row = $r.Rows | Where-Object SkuPartNumber -eq 'SPE_E5'
        $row.Status | Should -Be 'NotInTenant'
        $row.Detail | Should -Match 'no subscription'
    }

    It 'blocks a suspended SKU even though its seat count looks sufficient' {
        $r = Test-LicenseCapacity -Capacity $script:Cap -Required @{ EMSPREMIUM = 5 }
        $r.IsSatisfied | Should -BeFalse
        $row = $r.Rows | Where-Object SkuPartNumber -eq 'EMSPREMIUM'
        $row.Status    | Should -Be 'NotAssignable'
        $row.Shortfall | Should -Be 5
    }

    It 'evaluates every requested SKU rather than stopping at the first failure' {
        # The operator should see the whole picture in one run.
        $r = Test-LicenseCapacity -Capacity $script:Cap -Required @{
            ENTERPRISEPACK = 300; DESKLESSPACK = 10; SPE_E5 = 1
        }
        $r.Rows.Count | Should -Be 3
        ($r.Rows | Where-Object Status -eq 'OK').SkuPartNumber | Should -Be 'DESKLESSPACK'
    }
}
