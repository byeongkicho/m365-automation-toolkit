<#
.SYNOPSIS
    License capacity pre-flight for bulk onboarding.

.DESCRIPTION
    Why this exists: the onboarding script already looks up the SKU catalog with
    Get-MgSubscribedSku, but it only reads SkuId -- it never asks whether there
    are seats left. Graph does not fail the whole run when seats run out; it
    fails one user at a time, midway through the batch, with a per-call error.
    A 300-user run against 250 seats therefore creates 250 users, then 50
    accounts that exist but have no license -- and the operator finds out from
    the users, not from the script.

    Capacity is checked BEFORE any user is created, so the run either proceeds
    knowing it fits or stops before mutating the tenant.

    Both functions are pure: they take the objects Graph already returned rather
    than calling Graph themselves, so they unit-test without a live connection.
    Same reason Get-CheckStatus.ps1 was extracted.

.NOTES
    Seat math is deliberately conservative.

    PrepaidUnits has three states and only ONE of them is assignable:
      Enabled   -- paid and active. Assignable.
      Warning   -- the subscription expired and is inside its grace period. Graph
                   still accepts assignments, so a naive check counts these as
                   available -- and the seats stop working when the grace period
                   ends. Reported separately as a warning, never counted.
      Suspended -- not assignable. Data is retained, access is not.

    CapabilityStatus gates the whole SKU regardless of seat math.
#>

function Get-LicenseCapacity {
    <#
        .SYNOPSIS
            Turns Get-MgSubscribedSku output into per-SKU seat availability.
        .PARAMETER SubscribedSku
            The objects returned by Get-MgSubscribedSku.
        .OUTPUTS
            One record per SKU: SkuPartNumber, SkuId, Enabled, Consumed,
            Available, IsAssignable, GraceSeats, Note.
    #>
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$SubscribedSku
    )

    foreach ($sku in $SubscribedSku) {
        $enabled   = [int]$sku.PrepaidUnits.Enabled
        $warning   = [int]$sku.PrepaidUnits.Warning
        $consumed  = [int]$sku.ConsumedUnits
        $status    = [string]$sku.CapabilityStatus

        # Enabled seats are the only ones we count. Consumed can exceed Enabled
        # when seats were removed from the subscription, so clamp at zero rather
        # than reporting a negative that would read as "some capacity".
        $available = [Math]::Max(0, $enabled - $consumed)

        # An empty CapabilityStatus means Graph did not tell us. Treat unknown as
        # assignable but say so, rather than silently blocking a valid SKU.
        $assignable = [string]::IsNullOrWhiteSpace($status) -or $status -eq 'Enabled' -or $status -eq 'Warning'

        $notes = @()
        if ($status -eq 'Warning')   { $notes += 'subscription in grace period -- seats stop working when it ends' }
        if ($status -eq 'Suspended') { $notes += 'subscription suspended -- assignment will fail' }
        if ($status -eq 'LockedOut') { $notes += 'subscription locked out -- tenant cannot manage these seats' }
        if ($warning -gt 0)          { $notes += "$warning seat(s) in grace period, not counted as available" }

        [PSCustomObject]@{
            SkuPartNumber = [string]$sku.SkuPartNumber
            SkuId         = [string]$sku.SkuId
            Enabled       = $enabled
            Consumed      = $consumed
            Available     = $available
            GraceSeats    = $warning
            IsAssignable  = $assignable
            Note          = ($notes -join '; ')
        }
    }
}

function Test-LicenseCapacity {
    <#
        .SYNOPSIS
            Compares what a CSV asks for against what the tenant can actually give.
        .PARAMETER Capacity
            Output of Get-LicenseCapacity.
        .PARAMETER Required
            Hashtable of SkuPartNumber -> seat count needed by this run.
        .OUTPUTS
            A record per requested SKU with Shortfall, plus IsSatisfied for the run.
            Callers decide whether a shortfall stops the run; this only reports.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Capacity,
        [Parameter(Mandatory)][hashtable]$Required
    )

    $byName = @{}
    foreach ($c in $Capacity) { $byName[$c.SkuPartNumber] = $c }

    $rows = foreach ($name in $Required.Keys) {
        $need = [int]$Required[$name]
        $cap  = $byName[$name]

        if ($null -eq $cap) {
            # Asking for a SKU the tenant does not own is a CSV error, not a
            # capacity problem. Distinguished so the operator fixes the right thing.
            [PSCustomObject]@{
                SkuPartNumber = $name; Required = $need; Available = 0
                Shortfall = $need; Status = 'NotInTenant'
                Detail = 'tenant has no subscription for this SKU'
            }
            continue
        }

        if (-not $cap.IsAssignable) {
            [PSCustomObject]@{
                SkuPartNumber = $name; Required = $need; Available = $cap.Available
                Shortfall = $need; Status = 'NotAssignable'
                Detail = $cap.Note
            }
            continue
        }

        $short = [Math]::Max(0, $need - $cap.Available)
        [PSCustomObject]@{
            SkuPartNumber = $name
            Required      = $need
            Available     = $cap.Available
            Shortfall     = $short
            Status        = if ($short -gt 0) { 'Insufficient' } else { 'OK' }
            Detail        = $cap.Note
        }
    }

    $rows = @($rows)
    [PSCustomObject]@{
        IsSatisfied = -not ($rows | Where-Object { $_.Status -ne 'OK' })
        Rows        = $rows
    }
}
