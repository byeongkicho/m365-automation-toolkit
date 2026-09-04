<#
.SYNOPSIS
    Guard against writing cloud values that an on-premises directory owns.

.DESCRIPTION
    Why this exists: this toolkit was built and tested against a cloud-only
    tenant, where every user is mastered in Entra ID. Most tenants that would
    actually run it are hybrid -- users are synchronized from on-premises AD by
    Entra Connect, and for those users the on-premises directory is the source
    of authority for most attributes.

    The failure mode is not an error. It is worse than an error:

      Update-MgUser -AccountEnabled:$false   ->  Graph accepts it
      script logs "[1] Account disabled"     ->  operator believes offboarding ran
      next sync cycle (~30 min by default)   ->  on-prem value wins, account is live again

    So the offboarding log says success while the leaver can sign in the next
    morning. Nothing in the toolkit detected this, because nothing asked whether
    the user was synced. onPremisesSyncEnabled appeared 0 times in the codebase.

    These functions are pure -- they classify a user object Graph already
    returned. Callers must request onPremisesSyncEnabled in -Property, since
    Graph omits it otherwise and an absent value would read as "cloud-only".

.NOTES
    Field classification follows the default Entra Connect attribute flow.
    Deliberately conservative: a field is only listed as cloud-manageable when
    it is cloud-only by nature. Anything else is treated as on-prem authoritative,
    because wrongly promising a write will succeed is the expensive direction of
    this error.

    Not modeled here (documented rather than guessed):
      - custom Entra Connect rules can change which attributes flow
      - "password hash sync" and "password writeback" alter password behavior
      - directories where sync has been disabled leave stale onPremisesSyncEnabled
#>

# Attributes Entra Connect flows from on-premises AD by default. Writing these
# in the cloud for a synced user is at best a no-op and at worst a lie in the log.
$script:OnPremAuthoritativeFields = @(
    'DisplayName', 'GivenName', 'Surname', 'Department', 'JobTitle',
    'AccountEnabled', 'UserPrincipalName', 'MailNickname', 'OfficeLocation',
    'BusinessPhones', 'MobilePhone', 'StreetAddress', 'City', 'State',
    'PostalCode', 'Country', 'EmployeeId'
)

# Cloud-only by nature: these have no on-premises counterpart in the default
# attribute flow, so they remain manageable for synced users.
$script:CloudManageableFields = @(
    'UsageLocation', 'AssignedLicenses', 'PreferredLanguage'
)

function Test-UserIsSynced {
    <#
        .SYNOPSIS
            Reports whether a user is mastered on-premises, and whether we actually know.
        .PARAMETER User
            A user object from Get-MgUser. Must have been fetched with
            onPremisesSyncEnabled in -Property.
        .OUTPUTS
            IsSynced / IsKnown. IsKnown is false when the property was never
            requested -- absence of the flag is not evidence of a cloud-only user.
    #>
    param([Parameter(Mandatory)]$User)

    $hasProperty = $null -ne $User.PSObject.Properties['OnPremisesSyncEnabled']
    $value = if ($hasProperty) { $User.OnPremisesSyncEnabled } else { $null }

    # Graph returns null for cloud-only users and true for synced ones. It never
    # returns false in practice, but treat false as cloud-only if it appears.
    [PSCustomObject]@{
        IsSynced = ($value -eq $true)
        IsKnown  = $hasProperty
        Reason   = if (-not $hasProperty) {
                       'onPremisesSyncEnabled was not requested -- cannot tell; add it to -Property'
                   } elseif ($value -eq $true) {
                       'user is synchronized from on-premises AD'
                   } else {
                       'cloud-only user'
                   }
    }
}

function Test-DirectorySyncGuard {
    <#
        .SYNOPSIS
            Splits an intended field write into what will stick and what will not.
        .PARAMETER User
            User object from Get-MgUser (with onPremisesSyncEnabled).
        .PARAMETER Fields
            The field names the caller is about to write.
        .OUTPUTS
            Verdict (Proceed / ProceedPartial / Block / Unknown), plus the
            per-field split. Callers decide; this only reports.
    #>
    param(
        [Parameter(Mandatory)]$User,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Fields
    )

    $sync = Test-UserIsSynced -User $User

    if (-not $sync.IsKnown) {
        return [PSCustomObject]@{
            Verdict = 'Unknown'; IsSynced = $false
            WillPersist = @($Fields); WillBeOverwritten = @()
            Reason = $sync.Reason
        }
    }

    if (-not $sync.IsSynced) {
        return [PSCustomObject]@{
            Verdict = 'Proceed'; IsSynced = $false
            WillPersist = @($Fields); WillBeOverwritten = @()
            Reason = $sync.Reason
        }
    }

    $overwritten = @($Fields | Where-Object { $_ -in $script:OnPremAuthoritativeFields })
    $persist     = @($Fields | Where-Object { $_ -notin $script:OnPremAuthoritativeFields })

    $verdict = if ($overwritten.Count -eq 0)   { 'Proceed' }
               elseif ($persist.Count -eq 0)   { 'Block' }
               else                            { 'ProceedPartial' }

    [PSCustomObject]@{
        Verdict           = $verdict
        IsSynced          = $true
        WillPersist       = $persist
        WillBeOverwritten = $overwritten
        Reason            = if ($overwritten.Count -gt 0) {
                                "on-premises AD is authoritative for: $($overwritten -join ', ') -- the next sync cycle reverts them"
                            } else {
                                'requested fields are cloud-manageable for a synced user'
                            }
    }
}

function Get-OffboardingSyncImpact {
    <#
        .SYNOPSIS
            States which offboarding steps a synced user actually neutralizes.
        .DESCRIPTION
            Offboarding is the case where a silent revert is a security incident,
            not an inconvenience, so it gets its own explicit answer rather than
            leaving the caller to interpret a field list.
        .PARAMETER User
            User object from Get-MgUser (with onPremisesSyncEnabled).
    #>
    param([Parameter(Mandatory)]$User)

    $sync = Test-UserIsSynced -User $User

    if (-not $sync.IsKnown) {
        return [PSCustomObject]@{
            IsSynced = $false; IsEffective = $true; Severity = 'Unknown'
            IneffectiveSteps = @()
            Guidance = $sync.Reason
        }
    }
    if (-not $sync.IsSynced) {
        return [PSCustomObject]@{
            IsSynced = $false; IsEffective = $true; Severity = 'None'
            IneffectiveSteps = @()
            Guidance = 'cloud-only user -- disabling the account in Entra ID is authoritative'
        }
    }

    # Session revocation is a cloud-side operation and does take effect. It is
    # not listed as ineffective -- but it only buys time: an account that comes
    # back enabled can simply sign in again and mint new tokens.
    [PSCustomObject]@{
        IsSynced         = $true
        IsEffective      = $false
        Severity         = 'Critical'
        IneffectiveSteps = @('Disable account (AccountEnabled)')
        Guidance         = 'disable the account in on-premises AD (and let it sync), or the leaver is re-enabled at the next sync cycle. Revoking sessions still works but only until the account is used to sign in again.'
    }
}
