<#PSScriptInfo
.VERSION 1.0.0
.GUID 7c3e9a52-4b1d-4e8f-9a6b-2d5f8c1e0b47
.AUTHOR Sean Reigle
.COPYRIGHT (c) 2026 Sean Reigle. Released under the MIT License.
.TAGS Entra EntraID AzureAD MicrosoftGraph DeploymentRings Intune Autopatch PSEdition_Core
.LICENSEURI https://github.com/seanreiglegh/EntraDeploymentRings/blob/main/LICENSE
.PROJECTURI https://github.com/seanreiglegh/EntraDeploymentRings
.RELEASENOTES See CHANGELOG.md and the revision history in this file.
#>

#Requires -Version 7.2

# =============================================================================
#  Invoke-EntraDeploymentRings.ps1
#  Revision: 1.0
#
#  Creates and maintains Microsoft Entra ID security groups that act as
#  user deployment rings for staggered software / configuration rollouts.
#
#  ---------------------------------------------------------------------------
#  PREREQUISITES
#  ---------------------------------------------------------------------------
#  Runtime
#    - PowerShell 7.2 or later (Windows, Linux or macOS). Windows PowerShell
#      5.1 is NOT supported.
#    - Module: Microsoft.Graph.Authentication 2.0.0 or later. This is the ONLY
#      Graph module required; all calls go through Invoke-MgGraphRequest.
#        Install-Module Microsoft.Graph.Authentication -Scope CurrentUser
#    - Optional: Az.Accounts, only when sending to Log Analytics while using
#      -AuthMode Interactive or ExistingConnection (used to obtain the
#      Azure Monitor token). Not needed for app-only or managed identity auth.
#
#  Licensing
#    - Microsoft Entra ID P1 or P2 in the tenant when the sign-in inactivity
#      rule is enabled (-InactiveSignInDays > 0). The signInActivity property
#      is not returned on free tenants.
#
#  Microsoft Graph permissions (application permissions for app-only and
#  managed identity; delegated scopes for interactive sign-in)
#    - User.Read.All                 read users and their attributes
#    - AuditLog.Read.All             read signInActivity (sign-in rule only)
#    - GroupMember.ReadWrite.All     read ring groups and edit membership
#    - Creating the ring groups (-CreateGroupsOnly / -CreateMissingGroups)
#      only, never for scheduled runs:
#        app or managed identity:    Group.Create (+ GroupMember.ReadWrite.All
#                                    to find existing groups). Do NOT grant
#                                    Group.ReadWrite.All as an application
#                                    permission: it can change and delete
#                                    every group and reach Microsoft 365 group
#                                    content. Groups created this way have no
#                                    owner (see docs/Setup.md).
#        interactive sign-in:        Group.ReadWrite.All (Group.Create is not
#                                    available as a delegated scope); access is
#                                    still capped by the account's role.
#    - Interactive users additionally need an Entra role that can read
#      sign-in activity and manage groups (for example Groups Administrator
#      plus Reports Reader).
#    - Step-by-step setup of the app registration, certificate, managed
#      identity and admin consent: docs/Setup.md. All parameters and
#      behaviour: docs/Configuration.md. Reports and safety:
#      docs/Operations.md. Report columns and reasons: docs/Reports.md.
#      Worked scenarios: docs/Examples.md. Security and hardening:
#      docs/Security.md (read before production use). Removal:
#      docs/Decommission.md.
#
#  Email notifications (optional)
#    - Mail.Send (application, or delegated for interactive runs). Scope it
#      to the sender mailbox with Exchange Online RBAC for Applications - an
#      unscoped Mail.Send grant can send as ANY mailbox. See docs/Security.md.
#
#  Microsoft Teams notifications (optional)
#    - A Teams Workflows webhook URL ("When a Teams webhook request is
#      received" template). Office 365 connector webhooks were retired by
#      Microsoft in 2026 and are not supported. Outbound HTTPS from the
#      runner to the workflow URL is required.
#
#  Log Analytics (optional)
#    - A Data Collection Rule (DCR) and custom table EntraDeploymentRings_CL.
#      See infra/loganalytics-dcr.bicep and docs/LogAnalytics.md.
#    - The identity running the script needs "Monitoring Metrics Publisher"
#      on the DCR.
#    - Uses the Logs Ingestion API. The legacy HTTP Data Collector API was
#      retired by Microsoft on 14 September 2026 and is intentionally not used.
#
#  ---------------------------------------------------------------------------
#  REVISION HISTORY (most recent first)
#  ---------------------------------------------------------------------------
#  1.0   2026-11-01  Sean Reigle
#        - First public release.
#        - Rings: weighted computed rings plus First and Last (managed by
#          hand) and Inactive (automatic); precedence Inactive > Last > First
#          > computed; every in-scope user in exactly one ring. Sticky
#          placement (Hash or Balance): users keep their ring; -InitialRun /
#          -Rebalance re-place everyone once.
#        - Inactive: disabled accounts (-DisabledUserAction), employeeType and
#          company name 'Former', UPN patterns such as {user}.former@{domain},
#          and no successful sign-in for N days with a new-user grace period;
#          each rule configurable or off.
#        - Scope: employee type, user type, licence, exclusion groups and UPN
#          patterns (SVC-{user}@{domain}); out-of-scope users in First/Last
#          are reported, never removed.
#        - Safety: -WhatIf, -Preflight, change-limit circuit breaker, ownership
#          marker on every group, groups created only with -CreateGroupsOnly
#          or -CreateMissingGroups, orphan-ring protection, removals before
#          additions.
#        - Network test before every run; logged sign-in, ring-group reading,
#          user reading and membership-change progress.
#        - Plain-language explanations for Graph 401/403 (operation, needed
#          permission, token contents, fix, request-id) and sign-in failures
#          (full inner error chain, timeout detection).
#        - Least privilege: GroupMember.ReadWrite.All for scheduled runs;
#          Group.Create (apps) or Group.ReadWrite.All (signed-in users) only to
#          create groups.
#        - Certificate expiry warning; Teams (Workflows) and email
#          notifications with counts only; CSV and JSON reports with
#          retention; optional Log Analytics (Logs Ingestion API, Bicep DCR).
#        - Auth: Interactive, Certificate, ClientSecret, ManagedIdentity,
#          ExistingConnection; Global, USGov, USGovDoD and China clouds.
# =============================================================================

<#
.SYNOPSIS
    Creates and maintains Microsoft Entra ID deployment-ring security groups.

.DESCRIPTION
    Builds a set of cloud-only, assigned-membership security groups that divide
    in-scope users into deployment rings:

      {Base}-First      Manually managed. Users placed here by an admin are
                        removed from the computed rings. Never edited by
                        this script (see -RemoveInactiveFromManualRings).
      {Base}-Ring01..NN Computed rings, sized by -RingWeights. Managed by
                        this script.
      {Base}-Last       Manually managed, same rules as First.
      {Base}-Inactive   Managed by this script. Users who match the
                        inactivity rules. Optional.

    Every in-scope user ends up in exactly one ring. Precedence is:
    Inactive > Last > First > computed ring.

    Assignment is sticky. A user who already belongs to a computed ring stays
    there on later runs, even when tenant size changes. Only users without a
    ring (new users, users returning from Inactive, First or Last, users in a
    ring that no longer exists) are placed:

      Hash     (default) A SHA-256 hash of the user's object ID picks the
               ring. The same user always maps to the same ring, so a user
               returning from Inactive lands back in the ring they had.
      Balance  The user goes to the ring furthest below its weighted target.
               Keeps ring sizes closer to target as people join and leave,
               but a returning user can land in a different ring.

    -Rebalance (or its synonym -InitialRun) discards stickiness for one run,
    re-places every computed user with the current weights and skips the
    change-limit circuit breaker. Use it for the first run, after changing
    weights or ring count, or to re-seed groups populated by hand. Both are
    accepted on the command line only, never from a configuration file.

    The script creates missing ring groups only when -CreateMissingGroups is
    given. Otherwise a missing group stops the run before any change.

    Groups are identified by display name AND a marker tag in the group
    description. A group with a matching name but no marker is never touched;
    the run stops with an error instead.

.PARAMETER ConfigPath
    Path to a JSON configuration file. Keys match parameter names. Parameters
    given on the command line override values from the file. Secrets
    (ClientSecret) are not accepted in the file.

.PARAMETER GroupNameBase
    Prefix for all group names, for example "SG-Deploy-Win". Required.

.PARAMETER RingCount
    Number of computed rings, NOT counting First, Last and Inactive. 1-50.

.PARAMETER RingWeights
    Percentage of computed users for each ring, one value per ring, in ring
    order. Must sum to 100 (a tolerance of 0.01 allows 33.33,33.33,33.34).
    Example for 5 rings: 1,5,15,30,49. Omit for equal sizes.

.PARAMETER AssignmentMode
    How users without a ring are placed: Hash (default) or Balance.

.PARAMETER HashSeed
    Seed mixed into the hash. Defaults to GroupNameBase. Changing it changes
    where NEW users land; existing members are not moved.

.PARAMETER Rebalance
    Ignore current computed-ring membership, re-place every computed user
    with the current weights and skip the change-limit circuit breaker.
    Inactive, Last and First precedence still apply. Command line only.
    Combine with -AssignmentMode Balance for ring sizes that match the
    weights exactly instead of statistically.

.PARAMETER InitialRun
    Synonym for -Rebalance; changes are labelled 'InitialRun' in the report
    instead of 'Rebalance'. Command line only.

.PARAMETER Preflight
    Check everything without planning or changing anything: configuration,
    certificate, sign-in, Graph permissions, reading users (and sign-in
    activity), every ring group and its marker, exclusion groups, the report
    folder, and Log Analytics, Teams and email (each sends one test message).
    Returns a summary whose Checks list shows Pass, Warn, Fail or Skip for
    each item. Command line only.

.PARAMETER CreateGroupsOnly
    Create any missing ring groups, then stop. No users are read, no
    membership is changed and the change limit doesn't apply. Groups that
    already exist are checked (marker, cloud-only, security, assigned
    membership) and left untouched. An app or managed identity needs only
    Group.Create plus GroupMember.ReadWrite.All (or GroupMember.Read.All);
    an interactive sign-in needs Group.ReadWrite.All, because Group.Create
    is application-only. Either way the identity doesn't need
    User.Read.All, AuditLog.Read.All or Reports Reader. Use it to create the
    rings and assign policies to them while they're empty, then fill them
    with -InitialRun. Implies -CreateMissingGroups. Respects -WhatIf. Can't
    be combined with -Rebalance, -InitialRun, -Preflight or
    -RetireOrphanRings. Command line only.

.PARAMETER CreateMissingGroups
    Create any ring group that does not exist yet. Off by default: a missing
    group stops the run before any change, so a typo in GroupNameBase or a
    deleted group can never silently create a new ring set. Needs
    Group.Create for an app or managed identity (never grant it
    Group.ReadWrite.All), or Group.ReadWrite.All for an interactive sign-in.

.PARAMETER EnableInactiveRing
    Create and maintain the Inactive ring. Default $true. When $false the
    inactivity rules are not evaluated and no Inactive group is managed.

.PARAMETER InactiveSignInDays
    A user is inactive when their last SUCCESSFUL sign-in is older than this
    many days. 0 disables the sign-in rule. Default 90.

.PARAMETER NewUserGraceDays
    A user who has never signed in is only considered inactive once their
    account is older than this many days. Default 30.

.PARAMETER InactiveCompanyNames
    Case-insensitive -like patterns matched against companyName. A match
    makes the user inactive. Default 'Former'. Empty array disables the rule.

.PARAMETER InactiveEmployeeTypes
    Case-insensitive -like patterns matched against employeeType. A match
    keeps the user in scope (even though the value is not listed in
    IncludeEmployeeTypes) and puts them in the Inactive ring. Default
    'Former', for offboarding processes that set employeeType to Former.
    Empty array disables the rule.

.PARAMETER InactiveUpnPatterns
    UPN templates that make a user INACTIVE (moved to the Inactive ring)
    rather than excluded. Same syntax as -ExcludeUpnPatterns, for example
    '{user}.former@{domain}'. Empty (default) disables the rule. When a UPN
    matches both lists, -ExcludeUpnPatterns wins.

.PARAMETER IncludeEmployeeTypes
    Only users whose employeeType matches one of these values (case-
    insensitive) are in scope. Default 'Employee','Contingent Worker'.
    Empty array includes all employee types.

.PARAMETER IncludeUserTypes
    userType values in scope. Default 'Member' (guests excluded).

.PARAMETER DisabledUserAction
    What to do with disabled accounts:
      Inactive (default)  put them in the Inactive ring
      Exclude             keep them out of every ring
    Disabled users must still pass the other scope rules (user type,
    employee type, license, exclusions). When EnableInactiveRing is off,
    disabled users are always excluded.

.PARAMETER RequireAssignedLicense
    Only users with at least one assigned license are in scope.

.PARAMETER ExcludeGroupIds
    Object IDs of groups whose members (transitive) are out of scope, for
    example break-glass or service accounts.

.PARAMETER ExcludeUpnPatterns
    UPN templates for users who are out of scope. Matching is against the
    whole UPN and case-insensitive. Placeholders:
      {user}    one or more characters, no '@'
      {domain}  one or more characters, no '@'
      *         any characters (including none)
      ?         exactly one character
    Examples: '{user}.former@{domain}', 'SVC-{user}@{domain}',
    'admin-{user}@contoso.com', '*#EXT#@*'.

.PARAMETER ReportExcludedInManualRings
    Report users who are out of scope (excluded by user type, employee type,
    license, exclusion group, UPN pattern, or not returned by Graph) but are
    members of First or Last, as ExcludedUserInManualRing conflicts. Default
    $true. The script never removes them; First and Last are managed by hand.

.PARAMETER RemoveInactiveFromManualRings
    Remove inactive users from the First and Last groups (direct members
    only). Off by default; without it such users are reported as conflicts.

.PARAMETER RetireOrphanRings
    When RingCount has been reduced, empty the managed ring groups above the
    new count and re-place their members. Without it the run stops. The
    retired groups are emptied, not deleted.

.PARAMETER MaxChangePercent
    Circuit breaker. Abort when membership changes exceed this percentage of
    current managed membership. Default 10. Not enforced for the first
    population of empty groups, or with -Rebalance / -InitialRun.

.PARAMETER MaxChangeFloor
    The breaker only trips when the number of changes also exceeds this
    count, so small tenants are not blocked by routine churn. Default 25.

.PARAMETER BypassChangeLimit
    Apply changes even when the circuit breaker trips.

.PARAMETER AuthMode
    Interactive, Certificate, ClientSecret, ManagedIdentity or
    ExistingConnection (reuse a Connect-MgGraph session already open).

.PARAMETER TenantId
    Tenant ID or primary domain. Required for Certificate and ClientSecret.

.PARAMETER ClientId
    Application (client) ID for Certificate and ClientSecret.

.PARAMETER CertificateThumbprint
    Thumbprint of a certificate with private key in the CurrentUser or
    LocalMachine "My" store.

.PARAMETER CertificateExpiryWarningDays
    With -AuthMode Certificate: warn when the certificate expires within this
    many days. Default 30; 0 turns the warning off. The warning is logged,
    recorded in the summary, and sent to Teams and email when
    CertificateExpiring is in TeamsNotifyOn / EmailNotifyOn (the default),
    even if the run succeeded. An expired certificate always stops the run.

.PARAMETER ClientSecret
    Client secret as a SecureString. Prefer Certificate or ManagedIdentity.

.PARAMETER ManagedIdentityClientId
    Client ID of a user-assigned managed identity. Omit for system-assigned.

.PARAMETER GraphEnvironment
    Global (default), USGov, USGovDoD or China.

.PARAMETER ReportDirectory
    Folder for the report files. Default ./reports.

.PARAMETER ReportFormat
    Which report files to write:
      Csv   one row per change or conflict (for review in Excel)
      Json  the run summary object (for tooling and run-to-run comparison)
      Both  (default)

.PARAMETER ReportRetentionDays
    Delete this ring set's report files older than this many days, after the
    new report is written. 0 (default) keeps everything. Only files named
    EntraDeploymentRings_<base>_<yyyyMMdd-HHmmss>_<run>.csv / .summary.json
    for THIS GroupNameBase are ever removed; nothing else in the folder is
    touched. Honours -WhatIf and -Confirm.

.PARAMETER SkipReport
    Do not write report files (and do not prune).

.PARAMETER TeamsWebhookUrl
    Microsoft Teams Workflows webhook URL. When set, an Adaptive Card is
    posted for the run results listed in -TeamsNotifyOn. Treat the URL as a
    secret: anyone holding it can post to the channel. It is never written to
    logs or reports. Cards contain counts and reasons only, never user names.

.PARAMETER TeamsNotifyOn
    Run results that trigger a Teams notification. Any of: Failed,
    BlockedByChangeLimit, CompletedWithErrors, CertificateExpiring, Success,
    WhatIf. Default: Failed, BlockedByChangeLimit, CompletedWithErrors,
    CertificateExpiring.
    Preview (-WhatIf) runs notify only when WhatIf is listed.

.PARAMETER EmailTo
    One or more recipient addresses. When set (with -EmailFrom), an HTML
    summary is emailed for the run results listed in -EmailNotifyOn. Sent
    through Microsoft Graph with the script's identity (needs Mail.Send).
    Contains counts only; no report is attached.

.PARAMETER EmailFrom
    Mailbox the email is sent from (UPN or SMTP address), for example a
    shared mailbox such as deployment-rings@contoso.com. Required with
    -EmailTo.

.PARAMETER EmailNotifyOn
    Run results that trigger an email. Same values and default as
    -TeamsNotifyOn: Failed, BlockedByChangeLimit, CompletedWithErrors,
    CertificateExpiring (add Success or WhatIf if wanted).

.PARAMETER LogIngestionEndpoint
    Logs ingestion endpoint of the DCR (or of a DCE). Setting this together
    with LogDcrImmutableId enables Log Analytics logging.

.PARAMETER LogDcrImmutableId
    Immutable ID of the Data Collection Rule (dcr-...).

.PARAMETER LogStreamName
    DCR stream name. Default Custom-EntraDeploymentRings_CL.

.PARAMETER LogTokenAudience
    Azure Monitor token audience. Derived from GraphEnvironment when empty.

.EXAMPLE
    ./Invoke-EntraDeploymentRings.ps1 -ConfigPath ./config/prod.json -Preflight

    Check sign-in, permissions, groups, the certificate and every configured
    notification channel without changing anything. Run it before the first
    run, after renewing the certificate, and after changing permissions.

.EXAMPLE
    ./Invoke-EntraDeploymentRings.ps1 -GroupNameBase 'SG-Deploy-Users' -RingCount 5 -CreateGroupsOnly -WhatIf
    ./Invoke-EntraDeploymentRings.ps1 -GroupNameBase 'SG-Deploy-Users' -RingCount 5 -CreateGroupsOnly

    Create the ring groups only (preview first). Assign policies to the
    empty groups, then fill them with -InitialRun.

.EXAMPLE
    ./Invoke-EntraDeploymentRings.ps1 -GroupNameBase 'SG-Deploy' -RingCount 4 `
        -RingWeights 5,15,30,50 -CreateMissingGroups -WhatIf

    Preview the first run interactively. Nothing is created or changed; the
    CSV report shows every planned change.

.EXAMPLE
    ./Invoke-EntraDeploymentRings.ps1 -ConfigPath ./config/prod.json `
        -AuthMode Certificate -TenantId contoso.onmicrosoft.com `
        -ClientId 00000000-0000-0000-0000-000000000000 `
        -CertificateThumbprint 0123456789ABCDEF0123456789ABCDEF01234567

    Scheduled app-only run using a configuration file.

.EXAMPLE
    ./Invoke-EntraDeploymentRings.ps1 -ConfigPath ./config/prod.json -InitialRun -WhatIf

    Preview a full re-seed of every computed ring using the configured
    weights. Drop -WhatIf to apply it; the change limit is not enforced.

.EXAMPLE
    ./Invoke-EntraDeploymentRings.ps1 -GroupNameBase 'SG-Deploy' -RingCount 4 `
        -ExcludeUpnPatterns '{user}.former@{domain}', 'SVC-{user}@{domain}'

    Keep departed-user and service accounts out of every ring.

.EXAMPLE
    ./Invoke-EntraDeploymentRings.ps1 -ConfigPath ./config/prod.json `
        -InactiveUpnPatterns '{user}.former@{domain}' -ExcludeUpnPatterns 'SVC-{user}@{domain}'

    Park renamed departed users (jane.doe.former@contoso.com) in the Inactive
    ring, and keep service accounts out entirely.

.EXAMPLE
    ./Invoke-EntraDeploymentRings.ps1 -ConfigPath ./config/prod.json `
        -TeamsWebhookUrl $env:EDR_TEAMS_WEBHOOK -TeamsNotifyOn Failed, BlockedByChangeLimit, CompletedWithErrors, CertificateExpiring, Success

    Post a Teams card after every run, including successful ones.

.EXAMPLE
    ./Invoke-EntraDeploymentRings.ps1 -ConfigPath ./config/prod.json -AuthMode ManagedIdentity

    Azure Automation runbook (PowerShell 7.2+ runtime) with a system-assigned
    managed identity.

.OUTPUTS
    PSCustomObject. One run summary per execution.

.NOTES
    Revision: 1.0. See the PREREQUISITES and REVISION HISTORY sections at the
    top of this file.

    Only USER members of managed groups are evaluated. Devices or nested
    groups placed in a ring group are left alone.

.LINK
    https://github.com/seanreiglegh/EntraDeploymentRings

.LINK
    https://github.com/seanreiglegh/EntraDeploymentRings/blob/main/docs/Configuration.md
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [string]   $ConfigPath,
    [string]   $GroupNameBase,
    [int]      $RingCount,
    [double[]] $RingWeights,
    [ValidateSet('Hash', 'Balance')]
    [string]   $AssignmentMode = 'Hash',
    [string]   $HashSeed,
    [switch]   $Rebalance,
    [switch]   $InitialRun,
    [switch]   $Preflight,
    [switch]   $CreateGroupsOnly,
    [switch]   $CreateMissingGroups,

    [bool]     $EnableInactiveRing = $true,
    [int]      $InactiveSignInDays = 90,
    [int]      $NewUserGraceDays = 30,
    [string[]] $InactiveCompanyNames = @('Former'),
    [string[]] $InactiveUpnPatterns = @(),
    [string[]] $InactiveEmployeeTypes = @('Former'),

    [string[]] $IncludeEmployeeTypes = @('Employee', 'Contingent Worker'),
    [string[]] $IncludeUserTypes = @('Member'),
    [ValidateSet('Inactive', 'Exclude')]
    [string]   $DisabledUserAction = 'Inactive',
    [switch]   $RequireAssignedLicense,
    [string[]] $ExcludeGroupIds = @(),
    [string[]] $ExcludeUpnPatterns = @(),
    [switch]   $RemoveInactiveFromManualRings,
    [bool]     $ReportExcludedInManualRings = $true,
    [switch]   $RetireOrphanRings,

    [double]   $MaxChangePercent = 10,
    [int]      $MaxChangeFloor = 25,
    [switch]   $BypassChangeLimit,

    [ValidateSet('Interactive', 'Certificate', 'ClientSecret', 'ManagedIdentity', 'ExistingConnection')]
    [string]   $AuthMode = 'Interactive',
    [string]   $TenantId,
    [string]   $ClientId,
    [string]   $CertificateThumbprint,
    [int]      $CertificateExpiryWarningDays = 30,
    [securestring] $ClientSecret,
    [string]   $ManagedIdentityClientId,
    [ValidateSet('Global', 'USGov', 'USGovDoD', 'China')]
    [string]   $GraphEnvironment = 'Global',

    [string]   $ReportDirectory = './reports',
    [ValidateSet('Csv', 'Json', 'Both')]
    [string]   $ReportFormat = 'Both',
    [int]      $ReportRetentionDays = 0,
    [switch]   $SkipReport,

    [string]   $TeamsWebhookUrl,
    [ValidateSet('Failed', 'BlockedByChangeLimit', 'CompletedWithErrors', 'CertificateExpiring', 'Success', 'WhatIf')]
    [string[]] $TeamsNotifyOn = @('Failed', 'BlockedByChangeLimit', 'CompletedWithErrors', 'CertificateExpiring'),

    [string[]] $EmailTo = @(),
    [string]   $EmailFrom,
    [ValidateSet('Failed', 'BlockedByChangeLimit', 'CompletedWithErrors', 'CertificateExpiring', 'Success', 'WhatIf')]
    [string[]] $EmailNotifyOn = @('Failed', 'BlockedByChangeLimit', 'CompletedWithErrors', 'CertificateExpiring'),

    [string]   $LogIngestionEndpoint,
    [string]   $LogDcrImmutableId,
    [string]   $LogStreamName = 'Custom-EntraDeploymentRings_CL',
    [string]   $LogTokenAudience
)

Set-StrictMode -Version 3.0

$script:ScriptRevision = '1.0'
$script:MarkerProduct  = 'EntraDeploymentRings'
$script:GraphApi       = 'v1.0'
$script:BatchSize      = 20     # Graph $batch and members@odata.bind limit
$script:UserProgressEvery = 2000   # log a "users read so far" line every this many users
$script:NetworkTimeoutSeconds = 15 # per endpoint, for the network test before sign-in
$script:ApplyProgressEvery = 2000  # log an "applied so far" line every this many membership changes
$script:MgSupportsWhatIf = $null

#region ---------- Logging ---------------------------------------------------

function Write-RingLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Message,
        [ValidateSet('Info', 'Warning', 'Verbose')] [string] $Level = 'Info'
    )
    $line = '{0:u}  {1}' -f [datetime]::UtcNow, $Message
    switch ($Level) {
        'Warning' { Write-Warning $line }
        'Verbose' { Write-Verbose $line }
        default   { Write-Information $line -InformationAction Continue }
    }
}

#endregion

#region ---------- Configuration ---------------------------------------------

function Get-RingKey {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [int] $Index)
    'Ring{0:D2}' -f $Index
}

function Get-RingGroupName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Base,
        [Parameter(Mandatory)] [string] $Key
    )
    "$Base-$Key"
}

function Get-RingMarker {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Base,
        [Parameter(Mandatory)] [string] $Key
    )
    "[$($script:MarkerProduct):$($Base):$($Key)]"
}

function Get-NormalizedWeights {
    <#
        Validates percentage weights (must sum to 100) and returns one
        fraction per ring, summing to 1. Null or empty input means equal
        weights.
    #>
    [CmdletBinding()]
    [OutputType([double[]])]
    param(
        [double[]] $Weights,
        [Parameter(Mandatory)] [int] $RingCount
    )
    if (-not $Weights -or $Weights.Count -eq 0) {
        return , [double[]](1..$RingCount | ForEach-Object { 1.0 / $RingCount })
    }
    if ($Weights.Count -ne $RingCount) {
        throw "RingWeights has $($Weights.Count) value(s) but RingCount is $RingCount. Supply exactly one weight per computed ring."
    }
    foreach ($w in $Weights) {
        if ($w -le 0 -or [double]::IsNaN($w) -or [double]::IsInfinity($w)) {
            throw "RingWeights values must be positive numbers. Found '$w'."
        }
    }
    $sum = [double]($Weights | Measure-Object -Sum).Sum
    if ([math]::Abs($sum - 100.0) -gt 0.01) {
        throw ("RingWeights are percentages and must add up to 100; '{0}' adds up to {1}." -f ($Weights -join ','), [math]::Round($sum, 4))
    }
    return , [double[]]($Weights | ForEach-Object { $_ / $sum })
}

function Get-GraphCloudInfo {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Environment)
    switch ($Environment) {
        'Global'   { @{ Graph = 'https://graph.microsoft.com';      Login = 'https://login.microsoftonline.com'; Monitor = 'https://monitor.azure.com' } }
        'USGov'    { @{ Graph = 'https://graph.microsoft.us';       Login = 'https://login.microsoftonline.us';  Monitor = 'https://monitor.azure.us' } }
        'USGovDoD' { @{ Graph = 'https://dod-graph.microsoft.us';   Login = 'https://login.microsoftonline.us';  Monitor = 'https://monitor.azure.us' } }
        'China'    { @{ Graph = 'https://microsoftgraph.chinacloudapi.cn'; Login = 'https://login.chinacloudapi.cn'; Monitor = 'https://monitor.azure.cn' } }
        default    { throw "Unknown GraphEnvironment '$Environment'." }
    }
}

function Read-RingConfigFile {
    <#
        Reads a JSON configuration file and returns a hashtable of
        parameter-name -> value.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string[]] $AllowedNames
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Configuration file '$Path' was not found."
    }
    try {
        $json = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    }
    catch {
        throw "Configuration file '$Path' is not valid JSON: $($_.Exception.Message)"
    }
    $result = @{}
    foreach ($key in $json.Keys) {
        if ($key -like '$*' -or $key -like '_*') { continue }   # $schema, _comment
        if ($key -in @('ClientSecret', 'ConfigPath')) {
            throw "Configuration key '$key' is not allowed in a configuration file. Pass secrets at run time (for example from Key Vault or an Automation credential)."
        }
        if ($key -in @('InitialRun', 'Rebalance')) {
            throw "Configuration key '$key' is not allowed in a configuration file: a scheduled job would reshuffle every user on every run. Pass -$key on the command line for the one run that needs it."
        }
        if ($key -ieq 'CreateGroupsOnly') {
            throw "Configuration key 'CreateGroupsOnly' is not allowed in a configuration file: a scheduled job would never fill the rings. Pass -CreateGroupsOnly on the command line for the run that creates them."
        }
        if ($key -ieq 'Preflight') {
            throw "Configuration key 'Preflight' is not allowed in a configuration file: a scheduled job would only ever check, never apply. Pass -Preflight on the command line."
        }
        $match = $AllowedNames | Where-Object { $_ -ieq $key } | Select-Object -First 1
        if (-not $match) {
            throw "Unknown configuration key '$key' in '$Path'. Valid keys: $($AllowedNames -join ', ')."
        }
        $result[$match] = $json[$key]
    }
    return $result
}

function ConvertTo-UpnPatternRegex {
    <#
        Converts a UPN template such as 'SVC-{user}@{domain}' into an
        anchored, case-insensitive regex. {user} and {domain} match one or
        more characters other than '@'; * and ? are wildcards.
    #>
    [CmdletBinding()]
    [OutputType([regex])]
    param([Parameter(Mandatory)] [string] $Pattern)
    $p = $Pattern.Trim()
    if (-not $p) { throw 'ExcludeUpnPatterns cannot contain an empty pattern.' }
    foreach ($m in [regex]::Matches($p, '\{([^{}]*)\}')) {
        if ($m.Groups[1].Value -notin 'user', 'domain') {
            throw "ExcludeUpnPatterns value '$Pattern' uses unknown placeholder '$($m.Value)'. Supported: {user}, {domain}, * and ?."
        }
    }
    if ($p -match '[{}]' -and ($p -replace '\{(user|domain)\}', '') -match '[{}]') {
        throw "ExcludeUpnPatterns value '$Pattern' has an unbalanced '{' or '}'."
    }
    $ic = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    $rx = [regex]::Escape($p)                                # { becomes \{, } is left as is
    $rx = [regex]::Replace($rx, '\\\{(user|domain)}', '[^@]+', $ic)
    $rx = $rx.Replace('\*', '.*').Replace('\?', '.')
    return [regex]::new("^$rx`$", $ic -bor [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)
}

function ConvertTo-RingSettings {
    <#
        Validates raw parameter values and returns the immutable settings
        object used by the rest of the script.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [hashtable] $Values)

    function Get-Value([string] $Name, $Default = $null) {
        if ($Values.ContainsKey($Name) -and $null -ne $Values[$Name]) { return $Values[$Name] }
        return $Default
    }
    function Get-StringArray([string] $Name, [string[]] $Default) {
        if (-not $Values.ContainsKey($Name)) { return , [string[]]$Default }
        $v = $Values[$Name]
        if ($null -eq $v) { return , [string[]]@() }
        return , [string[]]@($v | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { ([string]$_).Trim() })
    }

    $base = [string](Get-Value 'GroupNameBase')
    if ([string]::IsNullOrWhiteSpace($base)) { throw 'GroupNameBase is required.' }
    $base = $base.Trim()
    if ($base.Length -gt 200) { throw 'GroupNameBase must be 200 characters or fewer.' }
    if ($base -match '[\[\]:]') { throw "GroupNameBase cannot contain '[', ']' or ':' (they are used in the group marker tag)." }

    $ringCount = [int](Get-Value 'RingCount' 0)
    if ($ringCount -lt 1 -or $ringCount -gt 50) { throw 'RingCount must be between 1 and 50 (First, Last and Inactive are not counted).' }

    $rawWeights = Get-Value 'RingWeights'
    $weights = Get-NormalizedWeights -Weights ([double[]]@($rawWeights | Where-Object { $null -ne $_ })) -RingCount $ringCount

    $mode = [string](Get-Value 'AssignmentMode' 'Hash')
    if ($mode -notin 'Hash', 'Balance') { throw "AssignmentMode must be 'Hash' or 'Balance'." }

    $inactiveDays = [int](Get-Value 'InactiveSignInDays' 90)
    if ($inactiveDays -lt 0 -or $inactiveDays -gt 3650) { throw 'InactiveSignInDays must be between 0 (disabled) and 3650.' }
    $graceDays = [int](Get-Value 'NewUserGraceDays' 30)
    if ($graceDays -lt 0 -or $graceDays -gt 3650) { throw 'NewUserGraceDays must be between 0 and 3650.' }

    $maxPct = [double](Get-Value 'MaxChangePercent' 10)
    if ($maxPct -lt 0 -or $maxPct -gt 100) { throw 'MaxChangePercent must be between 0 and 100.' }
    $floor = [int](Get-Value 'MaxChangeFloor' 25)
    if ($floor -lt 0) { throw 'MaxChangeFloor cannot be negative.' }

    $auth = [string](Get-Value 'AuthMode' 'Interactive')
    $validAuth = 'Interactive', 'Certificate', 'ClientSecret', 'ManagedIdentity', 'ExistingConnection'
    if ($auth -notin $validAuth) { throw "AuthMode must be one of: $($validAuth -join ', ')." }
    $tenant = [string](Get-Value 'TenantId' '')
    $client = [string](Get-Value 'ClientId' '')
    $thumb  = [string](Get-Value 'CertificateThumbprint' '')
    $secret = Get-Value 'ClientSecret'
    switch ($auth) {
        'Certificate' {
            if (-not $tenant -or -not $client -or -not $thumb) { throw 'AuthMode Certificate requires TenantId, ClientId and CertificateThumbprint.' }
        }
        'ClientSecret' {
            if (-not $tenant -or -not $client -or $null -eq $secret) { throw 'AuthMode ClientSecret requires TenantId, ClientId and ClientSecret.' }
            if ($secret -isnot [securestring]) { throw 'ClientSecret must be a SecureString.' }
        }
    }

    $envName = [string](Get-Value 'GraphEnvironment' 'Global')
    $cloud = Get-GraphCloudInfo -Environment $envName

    $excludeIds = Get-StringArray 'ExcludeGroupIds' @()
    foreach ($id in $excludeIds) {
        $parsedGuid = [guid]::Empty
        if (-not [guid]::TryParse($id, [ref]$parsedGuid)) { throw "ExcludeGroupIds value '$id' is not a GUID." }
    }

    $upnPatterns = Get-StringArray 'ExcludeUpnPatterns' @()
    $upnRules = [object[]]@(foreach ($pat in $upnPatterns) { [pscustomobject]@{ Pattern = $pat; Regex = ConvertTo-UpnPatternRegex -Pattern $pat } })

    $initialRun = [bool](Get-Value 'InitialRun' $false)
    $createOnly = [bool](Get-Value 'CreateGroupsOnly' $false)
    if ($createOnly) {
        $clash = @(
            if ($initialRun) { '-InitialRun' }
            if ([bool](Get-Value 'Rebalance' $false)) { '-Rebalance' }
            if ([bool](Get-Value 'Preflight' $false)) { '-Preflight (it already reports missing groups; preview with -CreateGroupsOnly -WhatIf instead)' }
            if ([bool](Get-Value 'RetireOrphanRings' $false)) { '-RetireOrphanRings' }
        )
        if ($clash.Count) { throw "-CreateGroupsOnly only creates groups, so it can't be combined with $($clash -join ', ')." }
    }
    $certWarnDays = [int](Get-Value 'CertificateExpiryWarningDays' 30)
    if ($certWarnDays -lt 0 -or $certWarnDays -gt 365) { throw 'CertificateExpiryWarningDays must be between 0 (off) and 365.' }

    $teamsUrl = [string](Get-Value 'TeamsWebhookUrl' '')
    if ($teamsUrl -and $teamsUrl -notmatch '^https://') { throw 'TeamsWebhookUrl must be an https:// URL.' }
    $validNotify = 'Failed', 'BlockedByChangeLimit', 'CompletedWithErrors', 'CertificateExpiring', 'Success', 'WhatIf'
    $parseNotify = {
        param([string] $Name)
        [string[]]@(foreach ($v in (Get-StringArray $Name @('Failed', 'BlockedByChangeLimit', 'CompletedWithErrors', 'CertificateExpiring'))) {
            $m = $validNotify | Where-Object { $_ -ieq $v } | Select-Object -First 1
            if (-not $m) { throw "$Name value '$v' is not valid. Use: $($validNotify -join ', ')." }
            $m
        })
    }
    $teamsNotifyOn = & $parseNotify 'TeamsNotifyOn'

    $emailTo = Get-StringArray 'EmailTo' @()
    $emailFrom = ([string](Get-Value 'EmailFrom' '')).Trim()
    $emailPattern = '^[^@\s]+@[^@\s]+\.[^@\s]+$'
    foreach ($addr in $emailTo) { if ($addr -notmatch $emailPattern) { throw "EmailTo value '$addr' is not a valid email address." } }
    if ($emailTo.Count -gt 0 -and -not $emailFrom) { throw 'EmailFrom is required when EmailTo is set (the mailbox the notification is sent from).' }
    if ($emailFrom -and $emailFrom -notmatch $emailPattern) { throw "EmailFrom value '$emailFrom' is not a valid email address." }
    if ($emailFrom -and $emailTo.Count -eq 0) { Write-RingLog -Level Warning 'EmailFrom is set but EmailTo is empty; no email will be sent.' }
    $emailNotifyOn = & $parseNotify 'EmailNotifyOn'

    $laEndpoint = [string](Get-Value 'LogIngestionEndpoint' '')
    $laDcr      = [string](Get-Value 'LogDcrImmutableId' '')
    if ([bool]$laEndpoint -xor [bool]$laDcr) {
        throw 'Log Analytics logging needs both LogIngestionEndpoint and LogDcrImmutableId.'
    }
    if ($laEndpoint -and $laEndpoint -notmatch '^https://') { throw 'LogIngestionEndpoint must be an https:// URL.' }
    $laAudience = [string](Get-Value 'LogTokenAudience' '')
    if (-not $laAudience) { $laAudience = $cloud.Monitor }

    $reportFormat = [string](Get-Value 'ReportFormat' 'Both')
    $matchedFormat = @('Csv', 'Json', 'Both') | Where-Object { $_ -ieq $reportFormat } | Select-Object -First 1
    if (-not $matchedFormat) { throw "ReportFormat must be 'Csv', 'Json' or 'Both'." }
    $retention = [int](Get-Value 'ReportRetentionDays' 0)
    if ($retention -lt 0 -or $retention -gt 3650) { throw 'ReportRetentionDays must be between 0 (keep all) and 3650.' }

    $seed = [string](Get-Value 'HashSeed' '')
    if ([string]::IsNullOrWhiteSpace($seed)) { $seed = $base }

    $enableInactive = [bool](Get-Value 'EnableInactiveRing' $true)
    $disabledAction = [string](Get-Value 'DisabledUserAction' 'Inactive')
    $matchedAction = @('Inactive', 'Exclude') | Where-Object { $_ -ieq $disabledAction } | Select-Object -First 1
    if (-not $matchedAction) { throw "DisabledUserAction must be 'Inactive' or 'Exclude'." }
    if ($matchedAction -eq 'Inactive' -and -not $enableInactive) {
        Write-RingLog -Level Warning 'DisabledUserAction is Inactive but EnableInactiveRing is off; disabled users will be excluded instead.'
        $matchedAction = 'Exclude'
    }
    $companyPatterns = Get-StringArray 'InactiveCompanyNames' @('Former')
    $inactiveUpnPatterns = Get-StringArray 'InactiveUpnPatterns' @()
    $inactiveUpnRules = [object[]]@(foreach ($pat in $inactiveUpnPatterns) { [pscustomobject]@{ Pattern = $pat; Regex = ConvertTo-UpnPatternRegex -Pattern $pat } })
    if ($enableInactive -and $inactiveDays -eq 0 -and $companyPatterns.Count -eq 0 -and $inactiveUpnPatterns.Count -eq 0) {
        Write-RingLog -Level Warning 'EnableInactiveRing is on but every inactivity rule is disabled; the Inactive ring will stay empty.'
    }
    if (-not $enableInactive -and $inactiveUpnPatterns.Count -gt 0) {
        Write-RingLog -Level Warning 'InactiveUpnPatterns is set but EnableInactiveRing is off; matching users are placed in computed rings.'
    }
    foreach ($dup in ($inactiveUpnPatterns | Where-Object { $p = $_; $upnPatterns | Where-Object { $_ -ieq $p } })) {
        Write-RingLog -Level Warning "UPN pattern '$dup' is in both ExcludeUpnPatterns and InactiveUpnPatterns; exclusion wins, so matching users will NOT go to Inactive."
    }

    [pscustomobject]@{
        GroupNameBase                 = $base
        RingCount                     = $ringCount
        RingWeights                   = $weights
        RingKeys                      = [string[]](1..$ringCount | ForEach-Object { Get-RingKey -Index $_ })
        AssignmentMode                = $mode
        HashSeed                      = $seed
        Rebalance                     = ([bool](Get-Value 'Rebalance' $false) -or $initialRun)
        InitialRun                    = $initialRun
        CreateMissingGroups           = ([bool](Get-Value 'CreateMissingGroups' $false) -or $createOnly)
        CreateGroupsOnly              = $createOnly
        Preflight                     = [bool](Get-Value 'Preflight' $false)
        EnableInactiveRing            = $enableInactive
        InactiveSignInDays            = $inactiveDays
        NewUserGraceDays              = $graceDays
        InactiveCompanyNames          = $companyPatterns
        InactiveEmployeeTypes         = Get-StringArray 'InactiveEmployeeTypes' @('Former')
        InactiveUpnPatterns           = $inactiveUpnPatterns
        InactiveUpnRules              = $inactiveUpnRules
        IncludeEmployeeTypes          = Get-StringArray 'IncludeEmployeeTypes' @('Employee', 'Contingent Worker')
        IncludeUserTypes              = Get-StringArray 'IncludeUserTypes' @('Member')
        DisabledUserAction            = $matchedAction
        RequireAssignedLicense        = [bool](Get-Value 'RequireAssignedLicense' $false)
        ExcludeGroupIds               = $excludeIds
        ExcludeUpnPatterns            = $upnPatterns
        ExcludeUpnRules               = $upnRules
        RemoveInactiveFromManualRings = [bool](Get-Value 'RemoveInactiveFromManualRings' $false)
        ReportExcludedInManualRings   = [bool](Get-Value 'ReportExcludedInManualRings' $true)
        RetireOrphanRings             = [bool](Get-Value 'RetireOrphanRings' $false)
        MaxChangePercent              = $maxPct
        MaxChangeFloor                = $floor
        BypassChangeLimit             = [bool](Get-Value 'BypassChangeLimit' $false)
        AuthMode                      = $auth
        TenantId                      = $tenant
        ClientId                      = $client
        CertificateThumbprint         = $thumb
        CertificateExpiryWarningDays  = $certWarnDays
        ClientSecret                  = $secret
        ManagedIdentityClientId       = [string](Get-Value 'ManagedIdentityClientId' '')
        GraphEnvironment              = $envName
        Cloud                         = $cloud
        ReportDirectory               = [string](Get-Value 'ReportDirectory' './reports')
        SkipReport                    = [bool](Get-Value 'SkipReport' $false)
        ReportFormat                  = $matchedFormat
        ReportRetentionDays           = $retention
        TeamsWebhookUrl               = $teamsUrl
        TeamsNotifyOn                 = $teamsNotifyOn
        EmailTo                       = $emailTo
        EmailFrom                     = $emailFrom
        EmailNotifyOn                 = $emailNotifyOn
        EmailEnabled                  = ($emailTo.Count -gt 0)
        LogAnalyticsEnabled           = [bool]$laEndpoint
        LogIngestionEndpoint          = $laEndpoint.TrimEnd('/')
        LogDcrImmutableId             = $laDcr
        LogStreamName                 = [string](Get-Value 'LogStreamName' 'Custom-EntraDeploymentRings_CL')
        LogTokenAudience              = $laAudience.TrimEnd('/')
        NeedsSignInActivity           = ($enableInactive -and $inactiveDays -gt 0 -and -not $createOnly)
    }
}

#endregion

#region ---------- Ring math (pure functions) --------------------------------

function Get-HashFraction {
    <#
        Deterministic value in [0,1) derived from SHA-256(seed|objectId).
        Uses the top 53 bits so the result is exactly representable.
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param(
        [Parameter(Mandatory)] [string] $Seed,
        [Parameter(Mandatory)] [string] $ObjectId
    )
    $bytes = [System.Text.Encoding]::UTF8.GetBytes(("{0}|{1}" -f $Seed, $ObjectId).ToLowerInvariant())
    $hash  = [System.Security.Cryptography.SHA256]::HashData($bytes)
    # Read the first 8 bytes big-endian so results are identical on every platform.
    [byte[]]$first8 = $hash[0..7]
    if ([BitConverter]::IsLittleEndian) { [array]::Reverse($first8) }
    $u64   = [BitConverter]::ToUInt64($first8, 0)
    return [double]($u64 -shr 11) / 9007199254740992.0   # 2^53
}

function Get-HashRingIndex {
    <# Returns the 1-based computed ring index for a user. #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)] [string] $Seed,
        [Parameter(Mandatory)] [string] $ObjectId,
        [Parameter(Mandatory)] [double[]] $Weights
    )
    $f = Get-HashFraction -Seed $Seed -ObjectId $ObjectId
    $cumulative = 0.0
    for ($i = 0; $i -lt $Weights.Count; $i++) {
        $cumulative += $Weights[$i]
        if ($f -lt $cumulative) { return $i + 1 }
    }
    return $Weights.Count   # floating point remainder
}

function ConvertTo-UtcDateTime {
    [CmdletBinding()]
    param($Value)
    if ($null -eq $Value -or ($Value -is [string] -and [string]::IsNullOrWhiteSpace($Value))) { return $null }
    if ($Value -is [datetime]) { return $Value.ToUniversalTime() }
    if ($Value -is [datetimeoffset]) { return $Value.UtcDateTime }
    $parsed = [datetimeoffset]::MinValue
    if ([datetimeoffset]::TryParse([string]$Value, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed)) {
        return $parsed.UtcDateTime
    }
    return $null
}

function Test-RingInactiveEmployeeType {
    <# True when the Inactive ring is on and employeeType matches InactiveEmployeeTypes. #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] $User,
        [Parameter(Mandatory)] $Settings
    )
    if (-not $Settings.EnableInactiveRing -or [string]::IsNullOrWhiteSpace($User.EmployeeType)) { return $false }
    $value = $User.EmployeeType.Trim()
    foreach ($pattern in $Settings.InactiveEmployeeTypes) {
        if ($value -like $pattern) { return $true }
    }
    return $false
}

function Get-InactiveReason {
    <#
        Returns a short reason string when the user is inactive, otherwise
        $null. Expects a normalized user object (see ConvertTo-RingUser).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] $User,
        [Parameter(Mandatory)] $Settings,
        [Parameter(Mandatory)] [datetime] $Now
    )
    if (-not $Settings.EnableInactiveRing) { return $null }

    if ($Settings.DisabledUserAction -eq 'Inactive' -and -not $User.AccountEnabled) { return 'Disabled' }

    if (Test-RingInactiveEmployeeType -User $User -Settings $Settings) { return "EmployeeType:$($User.EmployeeType.Trim())" }

    if ($Settings.InactiveCompanyNames.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($User.CompanyName)) {
        foreach ($pattern in $Settings.InactiveCompanyNames) {
            if ($User.CompanyName -like $pattern) { return "CompanyName:$($User.CompanyName)" }
        }
    }

    if ($User.UserPrincipalName) {
        foreach ($rule in $Settings.InactiveUpnRules) {
            if ($rule.Regex.IsMatch($User.UserPrincipalName)) { return "UpnPattern:$($rule.Pattern)" }
        }
    }

    if ($Settings.InactiveSignInDays -gt 0) {
        $cutoff = $Now.AddDays(-$Settings.InactiveSignInDays)
        if ($null -ne $User.LastSuccessfulSignIn) {
            if ($User.LastSuccessfulSignIn -lt $cutoff) {
                return 'NoSignInFor{0}Days' -f $Settings.InactiveSignInDays
            }
        }
        else {
            # Never signed in successfully (since Microsoft began recording it).
            $graceCutoff = $Now.AddDays(-$Settings.NewUserGraceDays)
            if ($null -ne $User.CreatedDateTime -and $User.CreatedDateTime -lt $graceCutoff) {
                return 'NeverSignedIn'
            }
        }
    }
    return $null
}

function ConvertTo-RingUser {
    <# Normalizes a Graph user (hashtable or object) into a flat object. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $GraphUser)

    function Get-Prop($Object, [string] $Name) {
        if ($null -eq $Object) { return $null }
        if ($Object -is [System.Collections.IDictionary]) { return $Object[$Name] }
        $p = $Object.PSObject.Properties[$Name]
        if ($p) { return $p.Value }
        return $null
    }

    $signIn = Get-Prop $GraphUser 'signInActivity'
    $licenses = Get-Prop $GraphUser 'assignedLicenses'
    [pscustomobject]@{
        Id                   = [string](Get-Prop $GraphUser 'id')
        UserPrincipalName    = [string](Get-Prop $GraphUser 'userPrincipalName')
        AccountEnabled       = [bool](Get-Prop $GraphUser 'accountEnabled')
        UserType             = [string](Get-Prop $GraphUser 'userType')
        EmployeeType         = [string](Get-Prop $GraphUser 'employeeType')
        CompanyName          = [string](Get-Prop $GraphUser 'companyName')
        CreatedDateTime      = ConvertTo-UtcDateTime (Get-Prop $GraphUser 'createdDateTime')
        LastSuccessfulSignIn = ConvertTo-UtcDateTime (Get-Prop $signIn 'lastSuccessfulSignInDateTime')
        LicenseCount         = @($licenses | Where-Object { $null -ne $_ }).Count
    }
}

function Get-RingScopeExclusion {
    <#
        Returns why a user is out of scope (for example 'Disabled',
        'EmployeeType:Vendor', 'UpnPattern:SVC-{user}@{domain}'), or $null
        when the user is in scope.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] $User,
        [Parameter(Mandatory)] $Settings,
        [System.Collections.Generic.HashSet[string]] $ExcludedIds
    )
    if ($Settings.DisabledUserAction -eq 'Exclude' -and -not $User.AccountEnabled) { return 'Disabled' }
    if ($Settings.IncludeUserTypes.Count -gt 0) {
        if (-not ($Settings.IncludeUserTypes | Where-Object { $_ -ieq $User.UserType })) { return "UserType:$($User.UserType)" }
    }
    if ($Settings.IncludeEmployeeTypes.Count -gt 0 -and -not (Test-RingInactiveEmployeeType -User $User -Settings $Settings)) {
        if ([string]::IsNullOrWhiteSpace($User.EmployeeType)) { return 'EmployeeType:(empty)' }
        if (-not ($Settings.IncludeEmployeeTypes | Where-Object { $_ -ieq $User.EmployeeType.Trim() })) { return "EmployeeType:$($User.EmployeeType)" }
    }
    if ($Settings.RequireAssignedLicense -and $User.LicenseCount -lt 1) { return 'NoLicense' }
    if ($ExcludedIds -and $ExcludedIds.Contains($User.Id)) { return 'ExclusionGroup' }
    if ($User.UserPrincipalName) {
        foreach ($rule in $Settings.ExcludeUpnRules) {
            if ($rule.Regex.IsMatch($User.UserPrincipalName)) { return "UpnPattern:$($rule.Pattern)" }
        }
    }
    return $null
}

function Test-RingUserInScope {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] $User,
        [Parameter(Mandatory)] $Settings,
        [System.Collections.Generic.HashSet[string]] $ExcludedIds
    )
    return -not (Get-RingScopeExclusion -User $User -Settings $Settings -ExcludedIds $ExcludedIds)
}

function Get-RingPlan {
    <#
        Computes the desired state and the membership changes needed to reach
        it. Pure function: no Graph calls.

        CurrentMembers: hashtable groupKey -> hashtable(userId -> UPN), for
                        every managed group (computed rings, orphan rings,
                        Inactive). Also include 'First' and 'Last' for
                        DIRECT members of the manual groups.
        FirstIds/LastIds: transitive user IDs of the manual groups.
        OrphanKeys:     ring keys above RingCount that still exist.
        ExclusionReasons: userId -> why a known user is out of scope; used
                        to label removals and First/Last conflicts.
        UpnById:        userId -> UPN for every user read from Graph; used
                        to name users in First/Last conflicts.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Users,
        [Parameter(Mandatory)] $Settings,
        [Parameter(Mandatory)] [hashtable] $CurrentMembers,
        [System.Collections.Generic.HashSet[string]] $FirstIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase),
        [System.Collections.Generic.HashSet[string]] $LastIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase),
        [string[]] $OrphanKeys = @(),
        [hashtable] $ExclusionReasons = @{},
        [hashtable] $UpnById = @{},
        [datetime] $Now = [datetime]::UtcNow
    )

    $ringKeys = $Settings.RingKeys
    $ringKeySet = [System.Collections.Generic.HashSet[string]]::new([string[]]$ringKeys, [StringComparer]::OrdinalIgnoreCase)
    $inactiveKey = 'Inactive'
    $rebalanceReason = if ($Settings.InitialRun) { 'InitialRun' } else { 'Rebalance' }

    # Managed group keys: groups whose membership this script owns.
    $managedKeys = [System.Collections.Generic.List[string]]::new()
    $managedKeys.AddRange([string[]]$ringKeys)
    foreach ($k in $OrphanKeys) { $managedKeys.Add($k) }
    if ($Settings.EnableInactiveRing) { $managedKeys.Add($inactiveKey) }

    foreach ($k in @($managedKeys) + @('First', 'Last')) {
        if (-not $CurrentMembers.ContainsKey($k) -or $null -eq $CurrentMembers[$k]) { $CurrentMembers[$k] = @{} }
    }

    # userId -> list of current computed ring keys (valid and orphan).
    $currentRingsByUser = @{}
    foreach ($k in @($ringKeys) + @($OrphanKeys)) {
        foreach ($uid in $CurrentMembers[$k].Keys) {
            if (-not $currentRingsByUser.ContainsKey($uid)) { $currentRingsByUser[$uid] = [System.Collections.Generic.List[string]]::new() }
            $currentRingsByUser[$uid].Add($k)
        }
    }

    $usersById = @{}
    foreach ($u in $Users) { $usersById[$u.Id] = $u }

    $desired        = @{}   # userId -> group key (ring key, Inactive, First, Last)
    $inactiveReason = @{}
    $pending        = [System.Collections.Generic.List[object]]::new()
    $conflicts      = [System.Collections.Generic.List[object]]::new()
    $ringCounts     = @{}
    foreach ($k in $ringKeys) { $ringCounts[$k] = 0 }

    foreach ($u in ($Users | Sort-Object Id)) {
        $reason = Get-InactiveReason -User $u -Settings $Settings -Now $Now
        $inFirst = $FirstIds.Contains($u.Id)
        $inLast  = $LastIds.Contains($u.Id)

        if ($inFirst -and $inLast) {
            $conflicts.Add([pscustomobject]@{ UserId = $u.Id; UserPrincipalName = $u.UserPrincipalName; Conflict = 'InFirstAndLast'; GroupKeys = @('First', 'Last'); Detail = 'User is in both First and Last; Last takes precedence. Remove the user from one of them.' })
        }

        if ($reason) {
            $desired[$u.Id] = $inactiveKey
            $inactiveReason[$u.Id] = $reason
            if (($inFirst -or $inLast) -and -not $Settings.RemoveInactiveFromManualRings) {
                $conflicts.Add([pscustomobject]@{ UserId = $u.Id; UserPrincipalName = $u.UserPrincipalName; Conflict = 'InactiveUserInManualRing'; GroupKeys = @($(if ($inLast) { 'Last' } else { 'First' })); Detail = "Inactive ($reason) but still in $(if ($inLast) { 'Last' } else { 'First' }). Use -RemoveInactiveFromManualRings to remove automatically." })
            }
            continue
        }
        if ($inLast)  { $desired[$u.Id] = 'Last';  continue }
        if ($inFirst) { $desired[$u.Id] = 'First'; continue }

        $valid = @()
        if ($currentRingsByUser.ContainsKey($u.Id)) {
            $valid = @($currentRingsByUser[$u.Id] | Where-Object { $ringKeySet.Contains($_) } | Sort-Object)
        }
        if (-not $Settings.Rebalance -and $valid.Count -gt 0) {
            $keep = $valid[0]
            if ($valid.Count -gt 1) {
                $hashKey = Get-RingKey -Index (Get-HashRingIndex -Seed $Settings.HashSeed -ObjectId $u.Id -Weights $Settings.RingWeights)
                if ($valid -contains $hashKey) { $keep = $hashKey }
            }
            $desired[$u.Id] = $keep
            $ringCounts[$keep]++
        }
        else {
            $pending.Add($u)
        }
    }

    # Place users without a ring.
    if ($pending.Count -gt 0) {
        if ($Settings.AssignmentMode -eq 'Balance') {
            $kept = ($ringCounts.Values | Measure-Object -Sum).Sum
            $total = $kept + $pending.Count
            $targets = @{}
            for ($i = 0; $i -lt $ringKeys.Count; $i++) { $targets[$ringKeys[$i]] = $total * $Settings.RingWeights[$i] }
            foreach ($u in $pending) {
                $best = $null; $bestDeficit = [double]::NegativeInfinity
                foreach ($k in $ringKeys) {
                    $deficit = $targets[$k] - $ringCounts[$k]
                    if ($deficit -gt $bestDeficit) { $best = $k; $bestDeficit = $deficit }
                }
                $desired[$u.Id] = $best
                $ringCounts[$best]++
            }
        }
        else {
            foreach ($u in $pending) {
                $k = Get-RingKey -Index (Get-HashRingIndex -Seed $Settings.HashSeed -ObjectId $u.Id -Weights $Settings.RingWeights)
                $desired[$u.Id] = $k
                $ringCounts[$k]++
            }
        }
    }

    # Build changes.
    $changes = [System.Collections.Generic.List[object]]::new()
    $newChange = {
        param($Action, $Key, $UserId, $Upn, $Reason)
        [pscustomobject]@{
            Action = $Action; GroupKey = $Key; UserId = $UserId; UserPrincipalName = $Upn
            Reason = $Reason; Result = 'Pending'; ErrorMessage = $null
        }
    }

    foreach ($k in $managedKeys) {
        foreach ($uid in @($CurrentMembers[$k].Keys)) {
            $target = $desired[$uid]
            if ($target -eq $k) { continue }
            $upn = $CurrentMembers[$k][$uid]
            $why = if (-not $usersById.ContainsKey($uid)) {
                       if ($ExclusionReasons.ContainsKey($uid)) { "OutOfScope:$($ExclusionReasons[$uid])" } else { 'OutOfScope' }
                   }
                   elseif ($target -eq $inactiveKey) { 'MovedToInactive' }
                   elseif ($target -in 'First', 'Last') { "ManualRingOverride:$target" }
                   elseif ($k -in $OrphanKeys) { 'OrphanRingRetired' }
                   elseif ($k -eq $inactiveKey) { 'NoLongerInactive' }
                   elseif ($Settings.Rebalance) { $rebalanceReason }
                   else { 'DuplicateRingMembership' }
            $changes.Add((& $newChange 'Remove' $k $uid $upn $why))
        }
    }

    foreach ($uid in $desired.Keys) {
        $k = $desired[$uid]
        if ($k -in 'First', 'Last') { continue }
        if ($CurrentMembers[$k].ContainsKey($uid)) { continue }
        $u = $usersById[$uid]
        $why = if ($k -eq $inactiveKey) { "Inactive:$($inactiveReason[$uid])" }
               elseif ($CurrentMembers.ContainsKey($inactiveKey) -and $CurrentMembers[$inactiveKey].ContainsKey($uid)) { 'ReturnedFromInactive' }
               elseif ($currentRingsByUser.ContainsKey($uid)) {
                   if ($Settings.Rebalance) { $rebalanceReason } else { 'OrphanRingRetired' }
               }
               else { 'NewAssignment' }
        $changes.Add((& $newChange 'Add' $k $uid $u.UserPrincipalName $why))
    }

    # Optional cleanup of inactive users from manual rings (direct members only).
    if ($Settings.EnableInactiveRing -and $Settings.RemoveInactiveFromManualRings) {
        foreach ($mk in 'First', 'Last') {
            # Plain assignment: an if-expression would enumerate the HashSet.
            $ids = $FirstIds
            if ($mk -eq 'Last') { $ids = $LastIds }
            foreach ($uid in $inactiveReason.Keys) {
                if (-not $ids.Contains($uid)) { continue }
                if ($CurrentMembers[$mk].ContainsKey($uid)) {
                    $changes.Add((& $newChange 'Remove' $mk $uid $usersById[$uid].UserPrincipalName 'MovedToInactive'))
                }
                else {
                    $conflicts.Add([pscustomobject]@{ UserId = $uid; UserPrincipalName = $usersById[$uid].UserPrincipalName; Conflict = 'InactiveUserNestedInManualRing'; GroupKeys = @($mk); Detail = "Inactive but a member of $mk through a nested group; remove manually." })
                }
            }
        }
    }

    # Out-of-scope users sitting in First or Last. The script never edits those
    # groups (except inactive removal on request), so report them for a human.
    if ($Settings.ReportExcludedInManualRings) {
        foreach ($mk in 'First', 'Last') {
            # Plain assignment: an if-expression would enumerate the HashSet.
            $ids = $FirstIds
            if ($mk -eq 'Last') { $ids = $LastIds }
            foreach ($uid in @($ids)) {
                if ($usersById.ContainsKey($uid)) { continue }
                $why = if ($ExclusionReasons.ContainsKey($uid)) { $ExclusionReasons[$uid] } else { 'NotReturnedByGraph' }
                $upn = if ($UpnById.ContainsKey($uid)) { $UpnById[$uid] } elseif ($CurrentMembers[$mk].ContainsKey($uid)) { $CurrentMembers[$mk][$uid] } else { $null }
                $how = if ($CurrentMembers[$mk].ContainsKey($uid)) { '' } else { ' through a nested group' }
                $hint = if ($why -eq 'NotReturnedByGraph') { ' (usually a disabled account with DisabledUserAction = Exclude)' } else { '' }
                $conflicts.Add([pscustomobject]@{
                    UserId = $uid; UserPrincipalName = $upn; Conflict = 'ExcludedUserInManualRing'; GroupKeys = @($mk)
                    Detail = "Out of scope ($why$hint) but in $mk$how. The script doesn't edit $mk; remove the user by hand if this isn't intended. Set ReportExcludedInManualRings to false to stop these reports."
                })
            }
        }
    }

    # Final distribution.
    $counts = [ordered]@{}
    foreach ($k in $ringKeys) { $counts[$k] = 0 }
    $counts['First'] = 0; $counts['Last'] = 0; $counts[$inactiveKey] = 0
    foreach ($k in $desired.Values) { $counts[$k]++ }

    $baseline = 0
    foreach ($k in $managedKeys) { $baseline += $CurrentMembers[$k].Count }

    [pscustomobject]@{
        Desired   = $desired
        Changes   = $changes
        Conflicts = $conflicts
        Counts    = $counts
        Baseline  = $baseline
        ScopedUserCount = $Users.Count
    }
}

function Test-ChangeThreshold {
    <# Circuit breaker evaluation. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [int] $ChangeCount,
        [Parameter(Mandatory)] [int] $Baseline,
        [Parameter(Mandatory)] $Settings
    )
    $pct = if ($Baseline -gt 0) { [math]::Round(100.0 * $ChangeCount / $Baseline, 2) } else { 100.0 }
    $result = [pscustomobject]@{ Allowed = $true; Percent = $pct; Baseline = $Baseline; ChangeCount = $ChangeCount; Reason = 'WithinLimit' }

    if ($ChangeCount -eq 0) { $result.Reason = 'NoChanges'; return $result }
    if ($Settings.InitialRun) { $result.Reason = 'InitialRun'; return $result }
    if ($Settings.Rebalance) { $result.Reason = 'Rebalance'; return $result }
    if ($Baseline -eq 0) { $result.Reason = 'InitialPopulation'; return $result }
    if ($ChangeCount -le $Settings.MaxChangeFloor) { $result.Reason = 'BelowFloor'; return $result }
    if ($pct -le $Settings.MaxChangePercent) { return $result }
    if ($Settings.BypassChangeLimit) { $result.Reason = 'Bypassed'; return $result }

    $result.Allowed = $false
    $result.Reason = 'Exceeded'
    return $result
}

#endregion

#region ---------- Graph plumbing --------------------------------------------

function Get-GraphErrorStatus {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [System.Management.Automation.ErrorRecord] $ErrorRecord)
    $status = $null; $retryAfter = $null
    $ex = $ErrorRecord.Exception
    while ($ex) {
        $resp = $null
        if ($ex.PSObject.Properties['Response']) { $resp = $ex.Response }
        if ($resp -and $resp.PSObject.Properties['StatusCode']) {
            $status = [int]$resp.StatusCode
            if ($resp.PSObject.Properties['Headers'] -and $resp.Headers -and $resp.Headers.PSObject.Properties['RetryAfter'] -and $resp.Headers.RetryAfter) {
                if ($resp.Headers.RetryAfter.Delta) { $retryAfter = [int][math]::Ceiling($resp.Headers.RetryAfter.Delta.TotalSeconds) }
            }
            break
        }
        $ex = $ex.InnerException
    }
    if (-not $status) {
        $msg = "$($ErrorRecord.Exception.Message) $($ErrorRecord.ErrorDetails)"
        if ($msg -match '\b(429|TooManyRequests)\b') { $status = 429 }
        elseif ($msg -match '\b(503|ServiceUnavailable)\b') { $status = 503 }
        elseif ($msg -match '\b(504|GatewayTimeout)\b') { $status = 504 }
        elseif ($msg -match '\b(404|NotFound|Request_ResourceNotFound)\b') { $status = 404 }
        elseif ($msg -match '\b(403|Forbidden|Authorization_RequestDenied)\b') { $status = 403 }
    }
    [pscustomobject]@{ Status = $status; RetryAfter = $retryAfter }
}

function Invoke-RingGraphRequest {
    <#
        Invoke-MgGraphRequest with retry on throttling and transient errors.
        A 401/403 is rethrown with a readable explanation: what the script was
        doing (Purpose), the permission the call needs, what the token holds,
        and the likely fix. The original Graph error is the InnerException.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Method,
        [Parameter(Mandatory)] [string] $Uri,
        $Body,
        [hashtable] $Headers,
        [string] $Purpose,
        [int] $MaxAttempts = 6
    )
    $params = @{ Method = $Method; Uri = $Uri; OutputType = 'Hashtable'; ErrorAction = 'Stop' }
    if ($null -ne $Body) {
        $params.Body = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 20 -Compress }
        $params.ContentType = 'application/json'
    }
    if ($Headers) { $params.Headers = $Headers }
    if ($null -eq $script:MgSupportsWhatIf) {
        $cmd = Get-Command Invoke-MgGraphRequest -ErrorAction SilentlyContinue
        $script:MgSupportsWhatIf = [bool]($cmd -and $cmd.Parameters.ContainsKey('WhatIf'))
    }
    if ($script:MgSupportsWhatIf) { $params.WhatIf = $false }

    for ($attempt = 1; ; $attempt++) {
        try {
            return Invoke-MgGraphRequest @params
        }
        catch {
            $info = Get-GraphErrorStatus -ErrorRecord $_
            if ($info.Status -in 401, 403) {
                $detail = Get-RingGraphErrorDetail -ErrorRecord $_
                $msg = Get-RingGraphAccessDeniedMessage -Method $Method -Uri $Uri -Status $info.Status -Detail $detail -Purpose $Purpose
                $denied = [System.UnauthorizedAccessException]::new($msg, $_.Exception)
                $denied.Data['RingGraphStatus'] = $info.Status
                throw $denied
            }
            $transient = $info.Status -in 429, 500, 502, 503, 504
            if (-not $transient -or $attempt -ge $MaxAttempts) { throw }
            $delay = if ($info.RetryAfter) { $info.RetryAfter } else { [math]::Min(60, [math]::Pow(2, $attempt)) }
            Write-RingLog -Level Verbose "Graph $Method $Uri returned $($info.Status); retry $attempt/$MaxAttempts in $delay s."
            Start-Sleep -Seconds $delay
        }
    }
}

function Get-RingGraphPaged {
    <#
        Follows @odata.nextLink and returns every item. OnPage, when given, is
        called after each page with (items so far, page number, is last page).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Uri,
        [hashtable] $Headers,
        [string] $Purpose,
        [scriptblock] $OnPage
    )
    $items = [System.Collections.Generic.List[object]]::new()
    $next = $Uri
    $pageNo = 0
    while ($next) {
        $page = Invoke-RingGraphRequest -Method GET -Uri $next -Headers $Headers -Purpose $Purpose
        $pageNo++
        if ($page.ContainsKey('value') -and $page['value']) { foreach ($i in $page['value']) { $items.Add($i) } }
        $next = if ($page.ContainsKey('@odata.nextLink')) { $page['@odata.nextLink'] } else { $null }
        if ($OnPage) { & $OnPage $items.Count $pageNo (-not $next) }
    }
    return , $items
}

function Invoke-RingGraphBatch {
    <#
        Sends sub-requests through $batch (20 per call). Retries sub-requests
        that return 429/5xx (and optionally 404) honouring Retry-After.
        Returns hashtable requestId -> @{ status; body }. OnProgress, when
        given, is called with the number of members each finished sub-request
        covered (Weights: id -> members; 1 when absent).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Requests,
        [int[]] $RetryStatus = @(429, 500, 502, 503, 504),
        [int] $MaxRounds = 6,
        [hashtable] $Weights,
        [scriptblock] $OnProgress
    )
    $results = @{}
    $queue = [System.Collections.Generic.List[object]]::new()
    foreach ($r in $Requests) { $queue.Add($r) }

    for ($round = 1; $queue.Count -gt 0; $round++) {
        $retry = [System.Collections.Generic.List[object]]::new()
        $maxWait = 0
        for ($i = 0; $i -lt $queue.Count; $i += $script:BatchSize) {
            $chunk = $queue.GetRange($i, [math]::Min($script:BatchSize, $queue.Count - $i))
            $payload = @{ requests = @($chunk) } | ConvertTo-Json -Depth 20 -Compress
            $resp = Invoke-RingGraphRequest -Method POST -Uri "$($script:GraphApi)/`$batch" -Body $payload
            foreach ($r in $resp['responses']) {
                $status = [int]$r['status']
                $req = $chunk | Where-Object { $_.id -eq [string]$r['id'] } | Select-Object -First 1
                if ($status -in $RetryStatus -and $round -lt $MaxRounds) {
                    $wait = 0
                    if ($r['headers'] -and $r['headers']['Retry-After']) { [int]::TryParse([string]$r['headers']['Retry-After'], [ref]$wait) | Out-Null }
                    if ($wait -le 0) { $wait = [math]::Min(60, [math]::Pow(2, $round)) }
                    $maxWait = [math]::Max($maxWait, $wait)
                    $retry.Add($req)
                }
                else {
                    $id = [string]$r['id']
                    $results[$id] = @{ status = $status; body = $r['body'] }
                    if ($OnProgress) { & $OnProgress $(if ($Weights -and $Weights.ContainsKey($id)) { [int]$Weights[$id] } else { 1 }) }
                }
            }
        }
        $queue = $retry
        if ($queue.Count -gt 0) {
            Write-RingLog "  Graph asked to slow down or wasn't ready: $($queue.Count) request(s) will be retried in $maxWait s (round $round of $MaxRounds)."
            Start-Sleep -Seconds $maxWait
        }
    }
    return $results
}

function Get-GraphBatchErrorMessage {
    [CmdletBinding()]
    param($Response)
    if ($null -eq $Response) { return 'No response' }
    $body = $Response.body
    if ($body -is [System.Collections.IDictionary] -and $body['error']) { return "$($Response.status): $($body['error']['code']) $($body['error']['message'])" }
    return "HTTP $($Response.status)"
}

function ConvertTo-RingGraphDisplayPath {
    <# '/groups?$filter=startswith(displayName,'X')' from a full or relative Graph URI, decoded for reading. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Uri)
    $p = ($Uri -replace '^https://[^/]+/', '') -replace '^(v1\.0|beta)/', ''
    $p = '/' + $p.TrimStart('/')
    try { return [uri]::UnescapeDataString($p) } catch { return $p }
}

function Get-RingGraphPermissionHint {
    <#
        What a Graph request needs, for access-denied messages. Requires lists
        each requirement; any one permission in AnyOf meets it. The first
        entry is the one this script's setup grants.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Method,
        [Parameter(Mandatory)] [string] $Uri
    )
    $path  = ConvertTo-RingGraphDisplayPath -Uri $Uri
    $parts = $path.Split('?', 2)
    $route = $parts[0].Trim('/')
    $query = if ($parts.Count -gt 1) { $parts[1] } else { '' }
    $groupRead  = @('GroupMember.ReadWrite.All', 'GroupMember.Read.All', 'Group.Read.All', 'Group.ReadWrite.All', 'Directory.Read.All', 'Directory.ReadWrite.All')
    $groupWrite = @('GroupMember.ReadWrite.All', 'Group.ReadWrite.All', 'Directory.ReadWrite.All')
    $userRead   = @('User.Read.All', 'User.ReadWrite.All', 'Directory.Read.All', 'Directory.ReadWrite.All')
    $need = { param([string] $For, [string[]] $AnyOf) [pscustomobject]@{ For = $For; AnyOf = $AnyOf } }

    $op = 'calling Microsoft Graph'; $kind = 'Other'; $requires = @()
    switch -Regex ("$($Method.ToUpperInvariant()) $route") {
        '^GET users$' {
            $op = 'reading users'; $kind = 'Users'
            $requires = @(& $need 'read users' $userRead)
            if ($query -match 'signInActivity') {
                $op = 'reading users and their sign-in activity'; $kind = 'SignIn'
                $requires += & $need 'read sign-in activity' @('AuditLog.Read.All')
            }
            break
        }
        '^GET groups$'                                  { $op = 'listing groups';            $kind = 'GroupRead';   $requires = @(& $need 'read groups' $groupRead); break }
        '^GET groups/[^/]+/(members|transitiveMembers)$' { $op = 'reading group membership'; $kind = 'GroupRead';   $requires = @(& $need 'read group membership' $groupRead); break }
        '^GET groups/[^/]+$'                            { $op = 'reading a group';           $kind = 'GroupRead';   $requires = @(& $need 'read groups' $groupRead); break }
        '^POST groups$'                                 { $op = 'creating a group';          $kind = 'GroupCreate'; $requires = @(& $need 'create groups' @('Group.Create', 'Group.ReadWrite.All', 'Directory.ReadWrite.All')); break }
        '^(PATCH groups/[^/]+|POST groups/[^/]+/members/\$ref|DELETE groups/[^/]+/members/[^/]+/\$ref|POST \$batch)$' {
            $op = 'changing group membership'; $kind = 'GroupWrite'; $requires = @(& $need 'change group membership' $groupWrite); break
        }
        '^POST users/[^/]+/sendMail$'                   { $op = 'sending email';             $kind = 'Mail';        $requires = @(& $need 'send email' @('Mail.Send')); break }
    }
    [pscustomobject]@{ Operation = $op; Kind = $kind; Requires = $requires; Path = $path }
}

function Get-RingGraphErrorDetail {
    <# Graph's error code, message and request-id from a failed request, when present. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [System.Management.Automation.ErrorRecord] $ErrorRecord)
    $texts = [System.Collections.Generic.List[string]]::new()
    if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) { $texts.Add($ErrorRecord.ErrorDetails.Message) }
    $ex = $ErrorRecord.Exception
    while ($ex) { $texts.Add([string]$ex.Message); $ex = $ex.InnerException }

    $code = $null; $message = $null; $requestId = $null; $date = $null
    foreach ($t in $texts) {
        $i = $t.IndexOf('{"error"'); $j = $t.LastIndexOf('}')
        if ($i -lt 0 -or $j -le $i) { continue }
        try { $e = ($t.Substring($i, $j - $i + 1) | ConvertFrom-Json -AsHashtable -ErrorAction Stop)['error'] } catch { continue }
        if (-not ($e -is [System.Collections.IDictionary])) { continue }
        $code = [string]$e['code']; $message = [string]$e['message']
        $inner = $e['innerError']
        if ($inner -is [System.Collections.IDictionary]) {
            $requestId = [string]$inner['request-id']
            $d = $inner['date']   # ConvertFrom-Json turns ISO dates into [datetime]
            $date = if ($d -is [datetime]) { $d.ToString('yyyy-MM-ddTHH:mm:ss', [cultureinfo]::InvariantCulture) } else { [string]$d }
        }
        break
    }
    if (-not $code) {
        foreach ($t in $texts) { if ($t -match '\b(Authorization_RequestDenied|Authentication_\w+|ErrorAccessDenied|InvalidAuthenticationToken|Forbidden|Unauthorized)\b') { $code = $Matches[1]; break } }
    }
    if (-not $requestId) {
        foreach ($t in $texts) { if ($t -match 'request-id:\s*([0-9a-fA-F-]{36})') { $requestId = $Matches[1]; break } }
    }
    [pscustomobject]@{ Code = $code; Message = $message; RequestId = $requestId; Date = $date }
}

function Get-RingGraphSession {
    <# The current Graph session, without the signed-in account (this text can reach Teams and email). #>
    [CmdletBinding()]
    param()
    $ctx = $null
    try { $ctx = Get-MgContext -ErrorAction SilentlyContinue } catch { $ctx = $null }
    if (-not $ctx) { return $null }
    $get = { param([string] $Name) if ($ctx.PSObject.Properties[$Name]) { $ctx.$Name } else { $null } }
    $scopes = & $get 'Scopes'
    [pscustomobject]@{
        Delegated = ([string](& $get 'AuthType')) -eq 'Delegated'
        ClientId  = [string](& $get 'ClientId')
        AppName   = [string](& $get 'AppName')
        TenantId  = [string](& $get 'TenantId')
        Scopes    = if ($null -eq $scopes) { $null } else { [string[]]@($scopes) }
    }
}

function Get-RingGraphAccessDeniedMessage {
    <#
        Explains a 401/403 from Graph: what was being done, which permission
        the call needs, what the token holds, and the most likely fix.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Method,
        [Parameter(Mandatory)] [string] $Uri,
        [int] $Status = 403,
        $Detail,
        [string] $Purpose,
        $Session = (Get-RingGraphSession)
    )
    $hint = Get-RingGraphPermissionHint -Method $Method -Uri $Uri
    $code = if ($Detail -and $Detail.Code) { " $($Detail.Code)" } else { '' }
    $what = if ($Purpose) { "$($hint.Operation) ($Purpose)" } else { $hint.Operation }
    $nl = [Environment]::NewLine
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("Microsoft Graph refused access ($Status$code) while $what.")
    $lines.Add("  Request:    $($Method.ToUpperInvariant()) $($hint.Path)")
    if ($Detail -and $Detail.Message) { $lines.Add("  Graph said: $($Detail.Message)") }
    foreach ($r in $hint.Requires) { $lines.Add("  Needs:      one of $($r.AnyOf -join ', ') (to $($r.For))") }

    $have = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    if ($Session) {
        $who = if ($Session.Delegated) { 'a signed-in user (delegated permissions)' }
               else { (@($(if ($Session.AppName) { "app '$($Session.AppName)'" } else { 'app' }), $Session.ClientId, '(application permissions)') | Where-Object { $_ }) -join ' ' }
        $tenant = if ($Session.TenantId) { " in tenant $($Session.TenantId)" } else { '' }
        $lines.Add("  Signed in:  $who$tenant")
        if ($null -eq $Session.Scopes) { $lines.Add('  Token has:  (the token does not list its permissions)') }
        else {
            foreach ($sc in $Session.Scopes) { [void]$have.Add($sc) }
            $list = @($Session.Scopes | Sort-Object -Unique)
            $shown = if ($list.Count -eq 0) { '(no Microsoft Graph permissions)' }
                     elseif ($list.Count -gt 15) { ($list[0..14] -join ', ') + ", and $($list.Count - 15) more" }
                     else { $list -join ', ' }
            $lines.Add("  Token has:  $shown")
        }
    }
    else { $lines.Add('  Signed in:  no Microsoft Graph session') }

    $unmet = @($hint.Requires | Where-Object { -not @($_.AnyOf | Where-Object { $have.Contains($_) }).Count })
    $delegated = [bool]($Session -and $Session.Delegated)
    $toGrant = (@($unmet | ForEach-Object {
        # Group.Create exists only as an application permission.
        if ($delegated -and $_.AnyOf[0] -eq 'Group.Create') { 'Group.ReadWrite.All (Group.Create is not available to a signed-in user)' } else { $_.AnyOf[0] }
    }) -join ' and ')
    $narrow = if ($hint.Kind -eq 'GroupCreate' -and -not $delegated) { ' Use Group.Create, not Group.ReadWrite.All: the script never needs to change or delete existing groups.' } else { '' }
    $fix =
        if ($Status -eq 401) {
            'The token was rejected (expired, or issued for a different tenant or cloud). Sign in again, and check TenantId and GraphEnvironment.'
        }
        elseif ($Detail -and $Detail.Code -match 'NonPremium|B2C') {
            'Reading sign-in activity needs Microsoft Entra ID P1 or P2 in this tenant. Without it, set InactiveSignInDays to 0.'
        }
        elseif (-not $Session) { 'Sign in to Microsoft Graph, then run again.' }
        elseif ($hint.Requires.Count -eq 0) { "Check the identity's Microsoft Graph permissions against docs/Setup.md." }
        elseif ($hint.Kind -eq 'Mail') {
            'Grant Mail.Send to this identity, and check that its Exchange RBAC for Applications scope includes the EmailFrom mailbox (docs/Security.md, "Scope Mail.Send to one mailbox").'
        }
        elseif ($null -eq $Session.Scopes) {
            "The token does not list its permissions, so the missing one can't be identified. Check that the identity has been granted $((@($hint.Requires | ForEach-Object { $_.AnyOf[0] })) -join ' and ') with admin consent (docs/Setup.md)."
        }
        elseif ($unmet.Count -gt 0) {
            if ($Session.Delegated) {
                "The token doesn't include $toGrant. Sign in again and consent to it (your tenant may need an admin to approve it). For scheduled runs, use an app registration or managed identity (docs/Setup.md)."
            }
            else {
                "Grant $toGrant as an Application permission to this identity and select Grant admin consent (docs/Setup.md, Option A step 2, or Option B for a managed identity). Then run again: a token issued before the grant doesn't include it, and a managed identity can take up to 24 hours to pick it up.$narrow"
            }
        }
        else {
            $found = (@($hint.Requires | ForEach-Object { $r = $_; @($r.AnyOf | Where-Object { $have.Contains($_) })[0] }) -join ', ')
            if ($Session.Delegated) {
                $role = switch ($hint.Kind) {
                    'SignIn'      { 'Reports Reader (or Security Reader, Global Reader)' }
                    'GroupWrite'  { 'Groups Administrator' }
                    'GroupCreate' { 'Groups Administrator' }
                    default       { 'a directory role such as Groups Administrator or Directory Readers (your tenant may restrict what users without a role can read)' }
                }
                "The token has $found, but delegated access is also limited by what the signed-in account may do. The account needs $role. If you use PIM, activate the role, then sign in again (docs/Setup.md, Option C)."
            }
            else {
                $extra = switch ($hint.Kind) {
                    'GroupRead'  {
                        if (-not $have.Overlaps([string[]]@('GroupMember.Read.All', 'Group.Read.All', 'Group.ReadWrite.All', 'Directory.Read.All', 'Directory.ReadWrite.All'))) {
                            ' If it still fails, also grant GroupMember.Read.All, which is the permission Microsoft documents for reading groups.'
                        }
                    }
                    'GroupWrite' { ' If only some groups are refused, check whether they are role-assignable or in a restricted management administrative unit: those refuse this permission.' }
                    default      { '' }
                }
                "The token has $found, which normally allows this. If it was granted recently, wait a few minutes and run again (a managed identity can take up to 24 hours).$extra"
            }
        }
    $lines.Add("  Fix:        $fix")
    if ($Detail -and $Detail.RequestId) {
        $when = if ($Detail.Date) { ", $($Detail.Date) UTC" } else { '' }
        $lines.Add("  request-id: $($Detail.RequestId)$when (give this to Microsoft support if you need them)")
    }
    return ($lines -join $nl)
}

#endregion

#region ---------- Network test ----------------------------------------------

function Get-RingExceptionChain {
    <# Every message in an exception chain, innermost last, with the exception type (some messages are empty). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [System.Exception] $Exception)
    $parts = [System.Collections.Generic.List[string]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new()
    $e = $Exception
    while ($e) {
        $m = ([string]$e.Message).Trim()
        $text = if ($m) { "$($e.GetType().Name): $m" } else { $e.GetType().Name }
        if ($seen.Add($text)) { $parts.Add($text) }
        $e = $e.InnerException
    }
    return ($parts -join ' -> ')
}

function Invoke-RingHttpProbe {
    <#
        One HTTPS request to the root of an endpoint. Any HTTP answer (even 400
        or 404) proves the network path works; only no answer, DNS failure, a
        TLS failure or a proxy refusal count as unreachable. Uses the machine's
        proxy settings, as the Graph SDK does.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [uri] $Uri,
        [int] $TimeoutSeconds = $script:NetworkTimeoutSeconds
    )
    # Test seam: the Pester Graph emulator answers here instead of the network.
    $seam = Get-Variable -Name EntraDeploymentRingsNetworkProbe -Scope Global -ValueOnly -ErrorAction SilentlyContinue
    if ($seam) { return (& $seam $Uri) }

    $r = [ordered]@{ Reachable = $false; StatusCode = $null; Milliseconds = $null; Proxy = $null; Error = $null }
    try {
        $p = [System.Net.Http.HttpClient]::DefaultProxy.GetProxy($Uri)
        if ($p -and $p.Authority -ne $Uri.Authority) { $r.Proxy = $p.GetLeftPart([System.UriPartial]::Authority) }
    }
    catch { $r.Proxy = $null }

    try {
        $dns = [System.Net.Dns]::GetHostAddressesAsync($Uri.Host)
        if (-not $dns.Wait([TimeSpan]::FromSeconds($TimeoutSeconds))) { throw [System.TimeoutException]::new("no answer within $TimeoutSeconds s") }
    }
    catch {
        if (-not $r.Proxy) { $r.Error = "DNS lookup of $($Uri.Host) failed ($(Get-RingExceptionChain $_.Exception))"; return [pscustomobject]$r }
        # Behind a proxy the machine may not resolve public names itself; the proxy does.
    }

    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.DefaultProxyCredentials = [System.Net.CredentialCache]::DefaultCredentials
    $handler.AllowAutoRedirect = $false
    $client = [System.Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $resp = $client.GetAsync($Uri).GetAwaiter().GetResult()
        $r.Milliseconds = [int]$clock.ElapsedMilliseconds
        $r.StatusCode = [int]$resp.StatusCode
        if ($r.StatusCode -eq 407) { $r.Error = 'the proxy requires authentication (HTTP 407)' }
        elseif ($r.Proxy -and $r.StatusCode -in 502, 503, 504) {
            # A gateway error through a proxy is the proxy saying it couldn't reach the endpoint.
            $r.Error = "the proxy answered HTTP $($r.StatusCode) (it couldn't reach the endpoint, or blocks it)"
        }
        else { $r.Reachable = $true }
        $resp.Dispose()
    }
    catch {
        $r.Milliseconds = [int]$clock.ElapsedMilliseconds
        $ex = $_.Exception
        if ($ex -is [System.Management.Automation.MethodInvocationException] -and $ex.InnerException) { $ex = $ex.InnerException }
        $inner = $ex; while ($inner.InnerException) { $inner = $inner.InnerException }
        $chain = Get-RingExceptionChain $ex
        $r.Error =
            if ($chain -match "proxy tunnel request .*status code '(\d+)'") {
                if ($Matches[1] -eq '407') { 'the proxy requires authentication (HTTP 407)' }
                else { "the proxy refused to connect to it (HTTP $($Matches[1])): it blocks this destination" }
            }
            elseif ($ex -is [System.Threading.Tasks.TaskCanceledException] -or $chain -match 'TaskCanceled|timed out|Timeout') { "no response within $TimeoutSeconds s" }
            elseif ($chain -match 'SSL|TLS|certificate|Authentication failed') { "TLS failed ($($inner.Message.Trim())). A TLS-inspecting proxy or firewall may be replacing Microsoft's certificate" }
            else { "$($inner.GetType().Name): $($inner.Message.Trim())" }
    }
    finally { $client.Dispose(); $handler.Dispose() }
    return [pscustomobject]$r
}

function Test-RingNetwork {
    <#
        Tests the network path to every endpoint this run needs, logs each
        result, and throws before sign-in when a required one can't be reached.
        Returns the results for the summary (host names only, never URLs).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Settings,
        [switch] $NoThrow
    )
    $targets = [System.Collections.Generic.List[object]]::new()
    $add = { param($Name, $Uri, $Required) $targets.Add([pscustomobject]@{ Name = $Name; Uri = [uri]$Uri; Required = $Required }) }
    switch ($Settings.AuthMode) {
        'ManagedIdentity' {
            if ($env:IDENTITY_ENDPOINT) { & $add 'Managed identity endpoint' $env:IDENTITY_ENDPOINT $true }
            else { & $add 'Managed identity endpoint (IMDS)' 'http://169.254.169.254/' $true }
        }
        'ExistingConnection' { }
        default { & $add 'Microsoft Entra sign-in' "$($Settings.Cloud.Login)/" $true }
    }
    & $add 'Microsoft Graph' "$($Settings.Cloud.Graph)/" $true
    if ($Settings.LogAnalyticsEnabled) { & $add 'Log Analytics ingestion' ("https://$(([uri]$Settings.LogIngestionEndpoint).Authority)/") $false }
    if ($Settings.TeamsWebhookUrl) { & $add 'Teams webhook host' ("https://$(([uri]$Settings.TeamsWebhookUrl).Authority)/") $false }

    Write-RingLog "Testing network access to $($targets.Count) endpoint(s) ($script:NetworkTimeoutSeconds s timeout each)..."
    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($t in $targets) {
        $p = Invoke-RingHttpProbe -Uri $t.Uri
        $via = if ($p.Proxy) { "via proxy $($p.Proxy)" } else { 'direct' }
        $label = "$($t.Name) ($($t.Uri.Host))"
        if ($p.Reachable) {
            Write-RingLog "  OK      $label - HTTP $($p.StatusCode) in $($p.Milliseconds) ms, $via."
        }
        else {
            $tag = if ($t.Required) { 'FAILED ' } else { 'FAILED (optional)' }
            Write-RingLog -Level Warning "  $tag $label - $($p.Error), $via."
        }
        $results.Add([pscustomobject][ordered]@{
            Endpoint = $t.Name; Host = $t.Uri.Host; Required = $t.Required; Reachable = [bool]$p.Reachable
            StatusCode = $p.StatusCode; Milliseconds = $p.Milliseconds; Proxy = $p.Proxy; Error = $p.Error
        })
    }
    $bad = @($results | Where-Object { $_.Required -and -not $_.Reachable })
    if ($bad.Count -and -not $NoThrow) {
        $list = ($bad | ForEach-Object { "$($_.Endpoint) ($($_.Host)): $($_.Error)" }) -join '; '
        $proxyNote = $(if (@($results | Where-Object Proxy).Count) { "This machine sends HTTPS through $(@($results | Where-Object Proxy)[0].Proxy)." } else { 'This machine connects directly (no proxy configured).' })
        throw "Network test failed, so the run stopped before signing in and nothing was changed. Can't reach $list. $proxyNote Check the VPN, proxy and firewall: the run needs outbound HTTPS (443) to $((@($results | Where-Object Required) | ForEach-Object Host) -join ', ')."
    }
    return , $results.ToArray()
}

function Get-RingSignInDescription {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Settings)
    switch ($Settings.AuthMode) {
        'Certificate'        { "certificate, app $($Settings.ClientId), tenant $($Settings.TenantId)" }
        'ClientSecret'       { "client secret, app $($Settings.ClientId), tenant $($Settings.TenantId)" }
        'ManagedIdentity'    { if ($Settings.ManagedIdentityClientId) { "managed identity $($Settings.ManagedIdentityClientId)" } else { 'system-assigned managed identity' } }
        'ExistingConnection' { 'the session already open in this window' }
        default              { "interactive$(if ($Settings.TenantId) { ", tenant $($Settings.TenantId)" })" }
    }
}

#endregion

#region ---------- Authentication --------------------------------------------

function Initialize-RingGraphModule {
    [CmdletBinding()]
    param()
    if (Get-Command Invoke-MgGraphRequest -ErrorAction SilentlyContinue) { return }
    $mod = Get-Module -ListAvailable -Name Microsoft.Graph.Authentication |
        Where-Object { $_.Version -ge [version]'2.0.0' } | Sort-Object Version -Descending | Select-Object -First 1
    if (-not $mod) {
        throw 'Module Microsoft.Graph.Authentication 2.0.0 or later is required. Install it with: Install-Module Microsoft.Graph.Authentication -Scope CurrentUser'
    }
    Import-Module $mod -ErrorAction Stop
}

function Get-RingCertificate {
    <# Finds a certificate with private key by thumbprint (cross-platform). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Thumbprint)
    $thumb = ($Thumbprint -replace '\s', '').ToUpperInvariant()
    foreach ($location in 'CurrentUser', 'LocalMachine') {
        $store = [System.Security.Cryptography.X509Certificates.X509Store]::new('My', $location)
        try {
            $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadOnly)
            $found = $store.Certificates.Find([System.Security.Cryptography.X509Certificates.X509FindType]::FindByThumbprint, $thumb, $false)
            foreach ($c in $found) { if ($c.HasPrivateKey) { return $c } }
        }
        catch { Write-RingLog -Level Verbose "Could not open $location\My store: $($_.Exception.Message)" }
        finally { $store.Dispose() }
    }
    throw "Certificate with thumbprint $thumb and a private key was not found in CurrentUser\My or LocalMachine\My."
}

function Get-RingCertificateStatus {
    <#
        Validity of the sign-in certificate. Status: Valid, Expiring (within
        WarningDays), Expired or NotYetValid. Message is ready to log.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Security.Cryptography.X509Certificates.X509Certificate2] $Certificate,
        [int] $WarningDays = 30,
        [datetime] $Now = [datetime]::UtcNow
    )
    $notAfter  = $Certificate.NotAfter.ToUniversalTime()
    $notBefore = $Certificate.NotBefore.ToUniversalTime()
    $daysLeft  = [int][math]::Floor(($notAfter - $Now).TotalDays)
    $renew     = 'Create a new certificate, add it to the app alongside the old one, then update CertificateThumbprint (docs/Setup.md, step 4).'
    $status, $message = if ($Now -gt $notAfter) {
        'Expired', "Certificate $($Certificate.Thumbprint) expired on $($notAfter.ToString('yyyy-MM-dd')) UTC. Sign-in will fail. $renew"
    }
    elseif ($Now -lt $notBefore) {
        'NotYetValid', "Certificate $($Certificate.Thumbprint) is not valid until $($notBefore.ToString('yyyy-MM-dd HH:mm')) UTC. Check the machine clock, or wait."
    }
    elseif ($WarningDays -gt 0 -and $daysLeft -lt $WarningDays) {
        'Expiring', "Certificate $($Certificate.Thumbprint) expires in $daysLeft day(s), on $($notAfter.ToString('yyyy-MM-dd')) UTC. $renew"
    }
    else {
        'Valid', "Certificate $($Certificate.Thumbprint) is valid until $($notAfter.ToString('yyyy-MM-dd')) UTC ($daysLeft day(s))."
    }
    [pscustomobject]@{ Status = $status; DaysLeft = $daysLeft; NotAfter = $notAfter; Message = $message }
}

function Get-RingRequiredScopes {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Settings)
    # Delegated scopes for Interactive sign-in. Group.Create is application-only, so a
    # signed-in user creating groups needs Group.ReadWrite.All (capped by their role).
    $groupScope = if ($Settings.CreateMissingGroups) { 'Group.ReadWrite.All' } else { 'GroupMember.ReadWrite.All' }
    if ($Settings.CreateGroupsOnly) {
        # No users are read and no membership is changed.
        $only = [System.Collections.Generic.List[string]]@('Group.ReadWrite.All')
        if ($Settings.EmailEnabled) { $only.Add('Mail.Send') }
        return , $only.ToArray()
    }
    $scopes = [System.Collections.Generic.List[string]]@('User.Read.All', $groupScope)
    if ($Settings.NeedsSignInActivity) { $scopes.Add('AuditLog.Read.All') }
    if ($Settings.EmailEnabled) { $scopes.Add('Mail.Send') }
    return , $scopes.ToArray()
}

function Connect-RingGraph {
    <# Connects to Graph. Returns $true when this script opened the session. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Settings,
        [System.Security.Cryptography.X509Certificates.X509Certificate2] $Certificate
    )
    Initialize-RingGraphModule
    $common = @{ NoWelcome = $true; ErrorAction = 'Stop' }
    if ($Settings.AuthMode -ne 'ExistingConnection') { $common.Environment = $Settings.GraphEnvironment }

    switch ($Settings.AuthMode) {
        'ExistingConnection' {
            if (-not (Get-MgContext)) { throw 'AuthMode ExistingConnection requires an existing Connect-MgGraph session.' }
            return $false
        }
        'Interactive' {
            $p = @{ Scopes = (Get-RingRequiredScopes -Settings $Settings); ContextScope = 'Process' }
            if ($Settings.TenantId) { $p.TenantId = $Settings.TenantId }
            Connect-MgGraph @common @p | Out-Null
        }
        'Certificate' {
            Connect-MgGraph @common -TenantId $Settings.TenantId -ClientId $Settings.ClientId -Certificate $Certificate | Out-Null
        }
        'ClientSecret' {
            $cred = [pscredential]::new($Settings.ClientId, $Settings.ClientSecret)
            Connect-MgGraph @common -TenantId $Settings.TenantId -ClientSecretCredential $cred | Out-Null
        }
        'ManagedIdentity' {
            $p = @{ Identity = $true }
            if ($Settings.ManagedIdentityClientId) { $p.ClientId = $Settings.ManagedIdentityClientId }
            Connect-MgGraph @common @p | Out-Null
        }
    }
    return $true
}

function Get-RingMissingPermission {
    <#
        Graph permissions this configuration needs that the session's token
        does not show. Returns $null when the token's permissions can't be
        read. Mail.Send is not checked: Exchange RBAC for Applications grants
        it outside the token.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Settings)
    $ctx = Get-MgContext
    if (-not $ctx -or -not $ctx.Scopes) { return $null }
    $have = [System.Collections.Generic.HashSet[string]]::new([string[]]$ctx.Scopes, [StringComparer]::OrdinalIgnoreCase)
    $missing = [System.Collections.Generic.List[string]]::new()
    if ($Settings.CreateGroupsOnly) {
        $canCreate = $have.Contains('Group.ReadWrite.All') -or $have.Contains('Directory.ReadWrite.All') -or $have.Contains('Group.Create')
        $canRead = @('Group.ReadWrite.All', 'Directory.ReadWrite.All', 'Group.Read.All', 'Directory.Read.All', 'GroupMember.Read.All', 'GroupMember.ReadWrite.All' | Where-Object { $have.Contains($_) }).Count -gt 0
        if (-not $canCreate) { $missing.Add('Group.Create (app or managed identity) or Group.ReadWrite.All (signed-in user) to create groups') }
        if (-not $canRead) { $missing.Add('a group read permission such as GroupMember.ReadWrite.All or GroupMember.Read.All, to find the groups that already exist') }
        return , $missing.ToArray()
    }
    if (-not ($have.Contains('User.Read.All') -or $have.Contains('User.ReadWrite.All') -or $have.Contains('Directory.Read.All') -or $have.Contains('Directory.ReadWrite.All'))) { $missing.Add('User.Read.All') }
    $memberOk = $have.Contains('GroupMember.ReadWrite.All') -or $have.Contains('Group.ReadWrite.All') -or $have.Contains('Directory.ReadWrite.All')
    $createOk = $have.Contains('Group.ReadWrite.All') -or $have.Contains('Directory.ReadWrite.All') -or $have.Contains('Group.Create')
    if (-not $memberOk) { $missing.Add('GroupMember.ReadWrite.All') }
    if ($Settings.CreateMissingGroups -and -not $createOk) { $missing.Add('Group.Create (app or managed identity) or Group.ReadWrite.All (signed-in user), needed for -CreateMissingGroups') }
    if ($Settings.NeedsSignInActivity -and -not ($have.Contains('AuditLog.Read.All'))) { $missing.Add('AuditLog.Read.All') }
    return , $missing.ToArray()
}

function Test-RingGraphPermission {
    <# Warns when the session's scopes/roles look insufficient. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Settings)
    $missing = Get-RingMissingPermission -Settings $Settings
    if ($null -eq $missing) {
        Write-RingLog -Level Warning 'Could not read Graph permissions from the session; continuing.'
        return
    }
    if ($Settings.EmailEnabled) {
        Write-RingLog -Level Verbose 'Mail.Send is not checked from the token: Exchange Online RBAC for Applications grants it outside the token.'
    }
    if ($missing.Count -gt 0) {
        Write-RingLog -Level Warning "Session may be missing Graph permission(s): $($missing -join '; '). Requests may fail with 403."
    }
}

function ConvertTo-Base64Url {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [byte[]] $Bytes)
    [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function Get-RingClientAssertion {
    <# Builds a signed JWT client assertion for certificate auth. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Security.Cryptography.X509Certificates.X509Certificate2] $Certificate,
        [Parameter(Mandatory)] [string] $ClientId,
        [Parameter(Mandatory)] [string] $Audience
    )
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $header = [ordered]@{
        alg        = 'RS256'
        typ        = 'JWT'
        x5t        = ConvertTo-Base64Url $Certificate.GetCertHash()
        'x5t#S256' = ConvertTo-Base64Url $Certificate.GetCertHash([System.Security.Cryptography.HashAlgorithmName]::SHA256)
    }
    $payload = [ordered]@{ aud = $Audience; iss = $ClientId; sub = $ClientId; jti = [guid]::NewGuid().ToString(); nbf = $now; iat = $now; exp = $now + 600 }
    $enc = [System.Text.Encoding]::UTF8
    $unsigned = '{0}.{1}' -f (ConvertTo-Base64Url $enc.GetBytes(($header | ConvertTo-Json -Compress))), (ConvertTo-Base64Url $enc.GetBytes(($payload | ConvertTo-Json -Compress)))
    $rsa = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($Certificate)
    if (-not $rsa) { throw 'The certificate does not have an accessible RSA private key.' }
    $sig = $rsa.SignData($enc.GetBytes($unsigned), [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
    return "$unsigned.$(ConvertTo-Base64Url $sig)"
}

function Get-RingMonitorToken {
    <# Acquires an Azure Monitor (Logs Ingestion) access token. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Settings,
        [System.Security.Cryptography.X509Certificates.X509Certificate2] $Certificate
    )
    $aud = $Settings.LogTokenAudience
    switch ($Settings.AuthMode) {
        'ManagedIdentity' {
            if ($env:IDENTITY_ENDPOINT -and $env:IDENTITY_HEADER) {
                # Azure Automation, Functions, App Service
                $uri = '{0}?resource={1}&api-version=2019-08-01' -f $env:IDENTITY_ENDPOINT, [uri]::EscapeDataString("$aud/")
                if ($Settings.ManagedIdentityClientId) { $uri += "&client_id=$($Settings.ManagedIdentityClientId)" }
                $r = Invoke-RestMethod -Method GET -Uri $uri -Headers @{ 'X-IDENTITY-HEADER' = $env:IDENTITY_HEADER } -ErrorAction Stop
            }
            else {
                # Azure VM / Arc IMDS
                $uri = 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource={0}' -f [uri]::EscapeDataString("$aud/")
                if ($Settings.ManagedIdentityClientId) { $uri += "&client_id=$($Settings.ManagedIdentityClientId)" }
                $r = Invoke-RestMethod -Method GET -Uri $uri -Headers @{ Metadata = 'true' } -ErrorAction Stop
            }
            return [string]$r.access_token
        }
        { $_ -in 'ClientSecret', 'Certificate' } {
            $tokenUri = '{0}/{1}/oauth2/v2.0/token' -f $Settings.Cloud.Login, $Settings.TenantId
            $form = @{ client_id = $Settings.ClientId; scope = "$aud/.default"; grant_type = 'client_credentials' }
            if ($Settings.AuthMode -eq 'ClientSecret') {
                $form.client_secret = [System.Net.NetworkCredential]::new('', $Settings.ClientSecret).Password
            }
            else {
                $form.client_assertion_type = 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer'
                $form.client_assertion = Get-RingClientAssertion -Certificate $Certificate -ClientId $Settings.ClientId -Audience $tokenUri
            }
            $r = Invoke-RestMethod -Method POST -Uri $tokenUri -Body $form -ContentType 'application/x-www-form-urlencoded' -ErrorAction Stop
            return [string]$r.access_token
        }
        default {
            if (-not (Get-Command Get-AzAccessToken -ErrorAction SilentlyContinue)) {
                throw "Log Analytics with AuthMode '$($Settings.AuthMode)' needs the Az.Accounts module and Connect-AzAccount, or use an app-only / managed identity AuthMode."
            }
            $t = Get-AzAccessToken -ResourceUrl $aud -ErrorAction Stop
            if ($t.Token -is [securestring]) { return [System.Net.NetworkCredential]::new('', $t.Token).Password }
            return [string]$t.Token
        }
    }
}

#endregion

#region ---------- Groups ----------------------------------------------------

function Get-RingGroupDescription {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Base,
        [Parameter(Mandatory)] [string] $Key
    )
    $text = switch -Regex ($Key) {
        '^First$'    { 'First deployment ring. Membership is managed MANUALLY by administrators.' }
        '^Last$'     { 'Last deployment ring. Membership is managed MANUALLY by administrators.' }
        '^Inactive$' { 'Inactive users. Membership is managed automatically; do not edit.' }
        default      { "Computed deployment ring $Key. Membership is managed automatically; do not edit." }
    }
    "$text Ring set '$Base', maintained by Invoke-EntraDeploymentRings. $(Get-RingMarker -Base $Base -Key $Key)"
}

function Find-RingGroup {
    <#
        Looks up a group by display name and validates it. Returns $null when
        absent; throws when a same-name group is unsafe to manage.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $DisplayName,
        [Parameter(Mandatory)] [string] $Marker
    )
    $filter = [uri]::EscapeDataString("displayName eq '$($DisplayName.Replace("'", "''"))'")
    $select = 'id,displayName,description,mailEnabled,securityEnabled,groupTypes,onPremisesSyncEnabled'
    $found = Get-RingGraphPaged -Uri "$($script:GraphApi)/groups?`$filter=$filter&`$select=$select" -Purpose "looking up ring group '$DisplayName'"
    if ($found.Count -eq 0) { return $null }

    $marked = @($found | Where-Object { $_['description'] -and ([string]$_['description']).Contains($Marker) })
    if ($marked.Count -eq 0) {
        throw "Group '$DisplayName' exists but its description does not contain the marker $Marker. It was not created by this script, so it will not be modified. Rename it, or add the marker to its description to adopt it."
    }
    if ($marked.Count -gt 1) {
        throw "More than one group named '$DisplayName' carries the marker $Marker ($($marked.ForEach({ $_['id'] }) -join ', ')). Delete the duplicate."
    }
    $g = $marked[0]
    if ($g['onPremisesSyncEnabled']) { throw "Group '$DisplayName' is synced from on-premises AD. Ring groups must be cloud-only." }
    if (-not $g['securityEnabled'] -or $g['mailEnabled']) { throw "Group '$DisplayName' must be a security group that is not mail-enabled." }
    if (@($g['groupTypes']) -contains 'DynamicMembership') { throw "Group '$DisplayName' uses dynamic membership. Ring groups must use assigned membership." }
    if (@($g['groupTypes']) -contains 'Unified') { throw "Group '$DisplayName' is a Microsoft 365 group. Ring groups must be security groups." }
    [pscustomobject]@{ Id = [string]$g['id']; DisplayName = [string]$g['displayName']; IsNew = $false }
}

function New-RingGroup {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $Base,
        [Parameter(Mandatory)] [string] $Key
    )
    $name = Get-RingGroupName -Base $Base -Key $Key
    if (-not $PSCmdlet.ShouldProcess($name, 'Create cloud-only security group')) {
        return [pscustomobject]@{ Id = $null; DisplayName = $name; IsNew = $true }
    }
    $nick = (('edr-{0}-{1}' -f $Base, $Key).ToLowerInvariant() -replace '[^a-z0-9\-]', '')
    if ($nick.Length -gt 50) { $nick = $nick.Substring(0, 50) }
    $nick = '{0}-{1}' -f $nick, ([guid]::NewGuid().ToString('N').Substring(0, 6))
    $body = @{
        displayName     = $name
        description     = Get-RingGroupDescription -Base $Base -Key $Key
        mailEnabled     = $false
        mailNickname    = $nick
        securityEnabled = $true
        groupTypes      = @()
    }
    $g = Invoke-RingGraphRequest -Method POST -Uri "$($script:GraphApi)/groups" -Body $body -Purpose "creating ring group '$name'"
    Write-RingLog "Created group '$name' ($($g['id']))."

    # Wait for directory replication so membership writes do not 404.
    for ($i = 1; $i -le 12; $i++) {
        try {
            Invoke-RingGraphRequest -Method GET -Uri "$($script:GraphApi)/groups/$($g['id'])?`$select=id" -Purpose "checking the new group '$name'" | Out-Null
            break
        }
        catch {
            if ((Get-GraphErrorStatus -ErrorRecord $_).Status -ne 404 -or $i -eq 12) { throw }
            Start-Sleep -Seconds 5
        }
    }
    [pscustomobject]@{ Id = [string]$g['id']; DisplayName = $name; IsNew = $true }
}

function Resolve-RingGroups {
    <#
        Finds every group in the ring set and, with CreateMissingGroups,
        creates the missing ones. Returns key -> group.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)] $Settings)
    $keys = [System.Collections.Generic.List[string]]::new()
    $keys.Add('First')
    $keys.AddRange([string[]]$Settings.RingKeys)
    $keys.Add('Last')
    if ($Settings.EnableInactiveRing) { $keys.Add('Inactive') }

    # Look everything up first so a missing group never leaves a half-created set.
    $groups = [ordered]@{}
    $missing = [System.Collections.Generic.List[string]]::new()
    foreach ($k in $keys) {
        $name = Get-RingGroupName -Base $Settings.GroupNameBase -Key $k
        $groups[$k] = Find-RingGroup -DisplayName $name -Marker (Get-RingMarker -Base $Settings.GroupNameBase -Key $k)
        if (-not $groups[$k]) { $missing.Add($k) }
    }
    if ($missing.Count -gt 0 -and -not $Settings.CreateMissingGroups) {
        $names = ($missing | ForEach-Object { Get-RingGroupName -Base $Settings.GroupNameBase -Key $_ }) -join ', '
        throw "Ring group(s) not found: $names. Nothing was changed. Check GroupNameBase, or create them first with -CreateGroupsOnly (or add -CreateMissingGroups to this run); either needs Group.Create (app or managed identity) or Group.ReadWrite.All (signed-in user)."
    }
    foreach ($k in $missing) { $groups[$k] = New-RingGroup -Base $Settings.GroupNameBase -Key $k }
    return $groups
}

function Find-OrphanRingGroups {
    <# Managed ring groups numbered above RingCount (RingCount was reduced). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Settings)
    $prefix = "$($Settings.GroupNameBase)-Ring"
    $filter = [uri]::EscapeDataString("startswith(displayName,'$($prefix.Replace("'", "''"))')")
    $found = Get-RingGraphPaged -Uri "$($script:GraphApi)/groups?`$filter=$filter&`$select=id,displayName,description" -Purpose "looking for ring groups above RingCount, whose names start with '$prefix'"
    $pattern = '^' + [regex]::Escape($prefix) + '(\d{2,})$'
    $orphans = [ordered]@{}
    foreach ($g in $found) {
        $m = [regex]::Match([string]$g['displayName'], $pattern)
        if (-not $m.Success) { continue }
        $idx = [int]$m.Groups[1].Value
        if ($idx -le $Settings.RingCount) { continue }
        $key = Get-RingKey -Index $idx
        if (-not ([string]$g['description']).Contains((Get-RingMarker -Base $Settings.GroupNameBase -Key $key))) { continue }
        $orphans[$key] = [pscustomobject]@{ Id = [string]$g['id']; DisplayName = [string]$g['displayName']; IsNew = $false }
    }
    return $orphans
}

function Resolve-RingExclusionGroup {
    <#
        Reads an exclusion group by ID. Throws a clear, named error when it
        no longer exists. Returns @{ Id; DisplayName; Members (id -> UPN) }.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $GroupId)
    try {
        $g = Invoke-RingGraphRequest -Method GET -Uri "$($script:GraphApi)/groups/$($GroupId)?`$select=id,displayName" -Purpose "reading exclusion group $GroupId (ExcludeGroupIds)"
    }
    catch {
        if ((Get-GraphErrorStatus -ErrorRecord $_).Status -eq 404) {
            throw "Exclusion group $GroupId (listed in ExcludeGroupIds) was not found; it may have been deleted. Nothing was changed: without it, its members (for example break-glass or service accounts) would be placed in rings. Restore the group, or remove its ID from ExcludeGroupIds."
        }
        throw
    }
    $name = [string]$g['displayName']
    $members = Get-RingGroupUserMembers -GroupId $GroupId -GroupName $name -Transitive
    [pscustomobject]@{ Id = $GroupId; DisplayName = $name; Members = $members }
}

function Get-RingGroupUserMembers {
    <# Returns hashtable userId -> UPN. Transitive when requested. #>
    [CmdletBinding()]
    param(
        [string] $GroupId,
        [string] $GroupName,
        [switch] $Transitive
    )
    $map = @{}
    if (-not $GroupId) { return $map }
    $rel = if ($Transitive) { 'transitiveMembers' } else { 'members' }
    $label = if ($GroupName) { "'$GroupName'" } else { "group $GroupId" }
    $items = Get-RingGraphPaged -Uri "$($script:GraphApi)/groups/$GroupId/$($rel)?`$select=id,userPrincipalName&`$top=999" -Purpose "reading the members of $label"
    foreach ($m in $items) {
        if ([string]$m['@odata.type'] -eq '#microsoft.graph.user') { $map[[string]$m['id']] = [string]$m['userPrincipalName'] }
    }
    return $map
}

function Get-RingCandidateUsers {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Settings)
    $select = 'id,userPrincipalName,accountEnabled,userType,employeeType,companyName,createdDateTime,assignedLicenses'
    $top = 999
    if ($Settings.NeedsSignInActivity) { $select += ',signInActivity'; $top = 120 }   # Graph caps pages at 120 with signInActivity
    $uri = "$($script:GraphApi)/users?`$select=$select&`$top=$top"
    if ($Settings.DisabledUserAction -eq 'Exclude') { $uri += '&$filter=' + [uri]::EscapeDataString('accountEnabled eq true') }

    # Progress: a console line at the start, every UserProgressEvery users and at the end
    # (these reach the job log too), plus a progress bar in interactive consoles.
    $how = if ($Settings.NeedsSignInActivity) { ' with sign-in activity (Graph returns at most 120 users per request with it, so a large tenant takes a few minutes)' } else { '' }
    Write-RingLog "Reading users from Microsoft Graph$how..."
    $userClock = [System.Diagnostics.Stopwatch]::StartNew()
    $userProgress = @{ NextLog = $script:UserProgressEvery }
    $onPage = {
        param([int] $Count, [int] $PageNo, [bool] $IsLast)
        Write-Progress -Id 1 -Activity 'Reading users from Microsoft Graph' -Status ('{0:N0} user(s) read, request {1}' -f $Count, $PageNo)
        # Not on the last page: the "Read n user(s)" line that follows gives the total.
        if (-not $IsLast -and $script:UserProgressEvery -gt 0 -and $Count -ge $userProgress.NextLog) {
            Write-RingLog ('  {0:N0} user(s) read so far ({1:N0} s).' -f $Count, $userClock.Elapsed.TotalSeconds)
            while ($userProgress.NextLog -le $Count) { $userProgress.NextLog += $script:UserProgressEvery }
        }
    }
    try {
        # A 403 here is explained by Invoke-RingGraphRequest, including AuditLog.Read.All and the P1/P2 licence.
        $raw = Get-RingGraphPaged -Uri $uri -Purpose 'reading the users to place in rings' -OnPage $onPage
    }
    finally { Write-Progress -Id 1 -Activity 'Reading users from Microsoft Graph' -Completed }
    Write-RingLog ('Read {0:N0} user(s) in {1:N0} s.' -f $raw.Count, $userClock.Elapsed.TotalSeconds)
    return , @($raw | ForEach-Object { ConvertTo-RingUser -GraphUser $_ })
}

function Update-RingApplyProgress {
    <# Counts finished membership changes; logs every ApplyProgressEvery and drives a progress bar. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable] $Progress,
        [int] $Count = 1,
        [string] $Group
    )
    $Progress.Done += $Count
    $pct = if ($Progress.Total -gt 0) { [math]::Min(100, [int](100 * $Progress.Done / $Progress.Total)) } else { 100 }
    Write-Progress -Id 2 -Activity 'Updating ring groups' -Status ('{0:N0} of {1:N0} change(s) - {2}' -f $Progress.Done, $Progress.Total, $Group) -PercentComplete $pct
    if ($script:ApplyProgressEvery -gt 0 -and $Progress.Done -ge $Progress.NextLog -and $Progress.Done -lt $Progress.Total) {
        Write-RingLog ('    {0:N0} of {1:N0} change(s) applied ({2}%, {3:N0} s).' -f $Progress.Done, $Progress.Total, $pct, $Progress.Clock.Elapsed.TotalSeconds)
        while ($Progress.NextLog -le $Progress.Done) { $Progress.NextLog += $script:ApplyProgressEvery }
    }
}

function Invoke-RingMembershipChanges {
    <#
        Applies the planned changes for one group. Updates Result /
        ErrorMessage on each change object in place.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] $Group,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Changes,
        [Parameter(Mandatory)] $Settings,
        [hashtable] $Progress
    )
    $adds    = @($Changes | Where-Object Action -eq 'Add')
    $removes = @($Changes | Where-Object Action -eq 'Remove')
    if ($adds.Count + $removes.Count -eq 0) { return }

    $target = if ($Group.Id) { "$($Group.DisplayName) ($($Group.Id))" } else { $Group.DisplayName }
    if (-not $PSCmdlet.ShouldProcess($target, "Add $($adds.Count) and remove $($removes.Count) member(s)")) {
        foreach ($c in $Changes) { $c.Result = 'WhatIf' }
        return
    }
    if (-not $Group.Id) {
        foreach ($c in $Changes) { $c.Result = 'Failed'; $c.ErrorMessage = 'Group was not created.' }
        return
    }

    $gid = $Group.Id
    $dirObj = "$($Settings.Cloud.Graph)/$($script:GraphApi)/directoryObjects"
    $retry404 = if ($Group.IsNew) { @(404, 429, 500, 502, 503, 504) } else { @(429, 500, 502, 503, 504) }

    # --- Adds: 20 members per PATCH, 20 PATCHes per $batch ---------------
    if ($adds.Count -gt 0) {
        $requests = [System.Collections.Generic.List[object]]::new()
        $chunks = @{}
        for ($i = 0; $i -lt $adds.Count; $i += $script:BatchSize) {
            $chunk = $adds[$i..([math]::Min($i + $script:BatchSize, $adds.Count) - 1)]
            $id = "a$i"
            $chunks[$id] = $chunk
            $requests.Add(@{
                id      = $id
                method  = 'PATCH'
                url     = "/groups/$gid"
                headers = @{ 'Content-Type' = 'application/json' }
                body    = @{ 'members@odata.bind' = @($chunk | ForEach-Object { "$dirObj/$($_.UserId)" }) }
            })
        }
        $weights = @{}; foreach ($cid in $chunks.Keys) { $weights[$cid] = $chunks[$cid].Count }
        $onProgress = if ($Progress) { { param([int] $N) Update-RingApplyProgress -Progress $Progress -Count $N -Group $Group.DisplayName } } else { $null }
        $res = Invoke-RingGraphBatch -Requests $requests -RetryStatus $retry404 -Weights $weights -OnProgress $onProgress
        $fallback = [System.Collections.Generic.List[object]]::new()
        foreach ($id in $chunks.Keys) {
            $r = $res[$id]
            if ($r -and $r.status -in 200, 204) { foreach ($c in $chunks[$id]) { $c.Result = 'Success' } }
            else { $fallback.AddRange([object[]]$chunks[$id]) }   # one bad reference fails the whole PATCH
        }
        if ($fallback.Count -gt 0) {
            Write-RingLog -Level Verbose "Retrying $($fallback.Count) add(s) to $($Group.DisplayName) individually."
            $single = [System.Collections.Generic.List[object]]::new()
            $map = @{}
            $n = 0
            foreach ($c in $fallback) {
                $id = "s$n"; $n++
                $map[$id] = $c
                $single.Add(@{
                    id      = $id
                    method  = 'POST'
                    url     = "/groups/$gid/members/`$ref"
                    headers = @{ 'Content-Type' = 'application/json' }
                    body    = @{ '@odata.id' = "$dirObj/$($c.UserId)" }
                })
            }
            $res2 = Invoke-RingGraphBatch -Requests $single -RetryStatus $retry404
            foreach ($id in $map.Keys) {
                $r = $res2[$id]; $c = $map[$id]
                if ($r -and $r.status -in 200, 204) { $c.Result = 'Success' }
                elseif ($r -and $r.status -eq 400 -and (Get-GraphBatchErrorMessage $r) -match 'already exist') { $c.Result = 'AlreadyMember' }
                else { $c.Result = 'Failed'; $c.ErrorMessage = Get-GraphBatchErrorMessage $r }
            }
        }
    }

    # --- Removes: one DELETE per member, 20 per $batch ---------------------
    if ($removes.Count -gt 0) {
        $requests = [System.Collections.Generic.List[object]]::new()
        $map = @{}
        $n = 0
        foreach ($c in $removes) {
            $id = "r$n"; $n++
            $map[$id] = $c
            $requests.Add(@{ id = $id; method = 'DELETE'; url = "/groups/$gid/members/$($c.UserId)/`$ref" })
        }
        $onProgress = if ($Progress) { { param([int] $N) Update-RingApplyProgress -Progress $Progress -Count $N -Group $Group.DisplayName } } else { $null }
        $res = Invoke-RingGraphBatch -Requests $requests -OnProgress $onProgress
        foreach ($id in $map.Keys) {
            $r = $res[$id]; $c = $map[$id]
            if ($r -and $r.status -in 200, 204) { $c.Result = 'Success' }
            elseif ($r -and $r.status -eq 404) { $c.Result = 'NotMember' }
            else { $c.Result = 'Failed'; $c.ErrorMessage = Get-GraphBatchErrorMessage $r }
        }
    }

    # Refused changes: explain once per group instead of leaving only per-row codes.
    $denied = @($Changes | Where-Object { $_.Result -eq 'Failed' -and [string]$_.ErrorMessage -match '^(401|403):' })
    if ($denied.Count -gt 0) {
        $null = ([string]$denied[0].ErrorMessage) -match '^(\d{3}):\s*(\S+)?\s*(.*)$'
        $detail = [pscustomobject]@{ Code = $Matches[2]; Message = $Matches[3]; RequestId = $null; Date = $null }
        $msg = Get-RingGraphAccessDeniedMessage -Method PATCH -Uri "groups/$gid" -Status ([int]$Matches[1]) -Detail $detail `
            -Purpose "$($denied.Count) change(s) to '$($Group.DisplayName)' refused"
        Write-RingLog -Level Warning $msg
    }
}

#endregion

#region ---------- Reporting -------------------------------------------------

function Get-RingRecords {
    <# Flattens changes, conflicts and the summary into uniform records. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Context,
        [AllowEmptyCollection()] [object[]] $Changes = @(),
        [AllowEmptyCollection()] [object[]] $Conflicts = @(),
        $Summary
    )
    $time = [datetime]::UtcNow.ToString('o')
    $records = [System.Collections.Generic.List[object]]::new()
    foreach ($c in $Changes) {
        $g = $Context.Groups[$c.GroupKey]
        $records.Add([pscustomobject][ordered]@{
            TimeGenerated = $time; RunId = $Context.RunId; RecordType = 'Change'; RingSet = $Context.Settings.GroupNameBase
            Action = $c.Action; UserId = $c.UserId; UserPrincipalName = $c.UserPrincipalName
            GroupName = if ($g) { $g.DisplayName } else { Get-RingGroupName -Base $Context.Settings.GroupNameBase -Key $c.GroupKey }
            GroupId = if ($g) { $g.Id } else { $null }
            RingKey = $c.GroupKey; Reason = $c.Reason; Result = $c.Result; ErrorMessage = $c.ErrorMessage
            IsWhatIf = $Context.IsWhatIf; ScriptRevision = $script:ScriptRevision; Details = $null
        })
    }
    foreach ($c in $Conflicts) {
        $keys = @()
        if ($c.PSObject.Properties['GroupKeys'] -and $c.GroupKeys) { $keys = @($c.GroupKeys) }
        $gNames = @($keys | ForEach-Object { $g = $Context.Groups[$_]; if ($g) { $g.DisplayName } else { Get-RingGroupName -Base $Context.Settings.GroupNameBase -Key $_ } })
        $gIds = @($keys | ForEach-Object { $g = $Context.Groups[$_]; if ($g -and $g.Id) { $g.Id } })
        $records.Add([pscustomobject][ordered]@{
            TimeGenerated = $time; RunId = $Context.RunId; RecordType = 'Conflict'; RingSet = $Context.Settings.GroupNameBase
            Action = 'None'; UserId = $c.UserId; UserPrincipalName = $c.UserPrincipalName
            GroupName = $(if ($gNames) { $gNames -join '; ' } else { $null }); GroupId = $(if ($gIds) { $gIds -join '; ' } else { $null })
            RingKey = $(if ($keys) { $keys -join '; ' } else { $null }); Reason = $c.Conflict; Result = 'Reported'; ErrorMessage = $c.Detail
            IsWhatIf = $Context.IsWhatIf; ScriptRevision = $script:ScriptRevision; Details = $null
        })
    }
    if ($Summary) {
        $records.Add([pscustomobject][ordered]@{
            TimeGenerated = $time; RunId = $Context.RunId; RecordType = 'Summary'; RingSet = $Context.Settings.GroupNameBase
            Action = 'None'; UserId = $null; UserPrincipalName = $null; GroupName = $null; GroupId = $null; RingKey = $null
            Reason = $Summary.ChangeLimitReason; Result = $Summary.Result; ErrorMessage = $Summary.ErrorMessage
            IsWhatIf = $Context.IsWhatIf; ScriptRevision = $script:ScriptRevision; Details = $Summary
        })
    }
    return , $records
}

function Get-RingReportFilePattern {
    <# Regex matching ONLY this ring set's report files. #>
    [CmdletBinding()]
    [OutputType([regex])]
    param([Parameter(Mandatory)] [string] $Base)
    $safe = $Base -replace '[^\w\-]', '_'
    [regex]::new('^EntraDeploymentRings_' + [regex]::Escape($safe) + '_\d{8}-\d{6}_[0-9a-f]{8}(\.csv|\.summary\.json)$', 'IgnoreCase')
}

function Get-RingReportPath {
    <#
        Returns @{ Csv; Json } for this run (either may be $null depending on
        ReportFormat / SkipReport) and creates the report folder if needed.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Context)
    $result = [pscustomobject]@{ Csv = $null; Json = $null }
    $settings = $Context.Settings
    if ($settings.SkipReport) { return $result }
    $dir = $settings.ReportDirectory
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force -WhatIf:$false -Confirm:$false | Out-Null }
    $stem = 'EntraDeploymentRings_{0}_{1:yyyyMMdd-HHmmss}_{2}' -f ($settings.GroupNameBase -replace '[^\w\-]', '_'), $Context.StartTime, $Context.RunId.Substring(0, 8)
    if ($settings.ReportFormat -in 'Csv', 'Both') { $result.Csv = Join-Path $dir "$stem.csv" }
    if ($settings.ReportFormat -in 'Json', 'Both') { $result.Json = Join-Path $dir "$stem.summary.json" }
    return $result
}

function Write-RingCsvReport {
    <# Writes the per-change CSV. A run with no rows still gets a header-only file. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Records
    )
    $Records | Where-Object RecordType -ne 'Summary' |
        Select-Object TimeGenerated, RunId, RecordType, RingSet, Action, UserId, UserPrincipalName, GroupName, GroupId, RingKey, Reason, Result, ErrorMessage, IsWhatIf |
        Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding utf8 -WhatIf:$false -Confirm:$false
    if (-not (Test-Path -LiteralPath $Path) -or (Get-Item -LiteralPath $Path).Length -eq 0) {
        'TimeGenerated,RunId,RecordType,RingSet,Action,UserId,UserPrincipalName,GroupName,GroupId,RingKey,Reason,Result,ErrorMessage,IsWhatIf' |
            Set-Content -LiteralPath $Path -Encoding utf8 -WhatIf:$false -Confirm:$false
    }
}

function Write-RingJsonSummary {
    <# Writes the run summary. Called last so every field is final. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] $Summary
    )
    $Summary | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Path -Encoding utf8 -WhatIf:$false -Confirm:$false
}

function Remove-RingExpiredReport {
    <#
        Deletes this ring set's report files older than RetentionDays.
        Returns the number of files removed.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)] [string] $Directory,
        [Parameter(Mandatory)] [string] $Base,
        [Parameter(Mandatory)] [int] $RetentionDays,
        [datetime] $Now = [datetime]::UtcNow,
        [string[]] $Keep = @()
    )
    if ($RetentionDays -le 0 -or -not (Test-Path -LiteralPath $Directory -PathType Container)) { return 0 }
    $pattern = Get-RingReportFilePattern -Base $Base
    $cutoff = $Now.AddDays(-$RetentionDays)
    # Compare by file name: names embed timestamp + run ID, so they are unique.
    $keepSet = [System.Collections.Generic.HashSet[string]]::new([string[]]@($Keep | ForEach-Object { Split-Path -Leaf $_ }), [StringComparer]::OrdinalIgnoreCase)
    $expired = @(Get-ChildItem -LiteralPath $Directory -File -ErrorAction Stop |
        Where-Object { $pattern.IsMatch($_.Name) -and $_.LastWriteTimeUtc -lt $cutoff -and -not $keepSet.Contains($_.Name) })
    if ($expired.Count -eq 0) { return 0 }
    if (-not $PSCmdlet.ShouldProcess($Directory, "Delete $($expired.Count) report file(s) older than $RetentionDays day(s)")) { return 0 }
    $removed = 0
    foreach ($f in $expired) {
        try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop -WhatIf:$false -Confirm:$false; $removed++ }
        catch { Write-RingLog -Level Warning "Could not delete old report $($f.Name): $($_.Exception.Message)" }
    }
    return $removed
}

function Test-RingShouldNotify {
    <#
        True when a notification should be sent on the given channel for this
        run: the result is listed in the channel's NotifyOn, or the
        certificate is expiring and CertificateExpiring is listed. Preview
        (WhatIf) runs notify only when WhatIf is listed.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] $Settings,
        [Parameter(Mandatory)] [string] $Result,
        [bool] $IsWhatIf,
        [ValidateSet('Teams', 'Email')] [string] $Channel = 'Teams',
        [bool] $CertificateWarning
    )
    if ($Channel -eq 'Teams') { $enabled = [bool]$Settings.TeamsWebhookUrl; $on = $Settings.TeamsNotifyOn }
    else { $enabled = [bool]$Settings.EmailEnabled; $on = $Settings.EmailNotifyOn }
    if (-not $enabled) { return $false }
    if ($IsWhatIf) { return ($on -contains 'WhatIf') }
    return ($on -contains $Result) -or ($CertificateWarning -and $on -contains 'CertificateExpiring')
}

function Get-RingCertificateNote {
    <# One-line certificate expiry warning for notifications, or $null. Tolerates summaries without certificate fields. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Summary)
    $p = $Summary.PSObject.Properties
    if (-not ($p['CertificateWarning'] -and $Summary.CertificateWarning)) { return $null }
    $when = if ($p['CertificateExpires'] -and $Summary.CertificateExpires) { ' (' + ([datetime]$Summary.CertificateExpires).ToUniversalTime().ToString('yyyy-MM-dd') + ' UTC)' } else { '' }
    "Sign-in certificate expires in $($Summary.CertificateDaysLeft) day(s)$when. Renew it before then, or scheduled runs will stop."
}

function Get-RingTeamsPayload {
    <#
        Builds the Teams Workflows webhook body: a message with one Adaptive
        Card. Counts and reasons only - no user names or IDs.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Summary,
        [AllowEmptyCollection()] [object[]] $Changes = @()
    )
    $look = switch ($Summary.Result) {
        'Success'              { @{ Icon = [char]0x2705; Title = 'Run succeeded';           Style = 'good' } }
        'CompletedWithErrors'  { @{ Icon = [char]0x26A0; Title = 'Completed with errors';   Style = 'warning' } }
        'BlockedByChangeLimit' { @{ Icon = [char]0x26D4; Title = 'Blocked by change limit'; Style = 'warning' } }
        'Failed'               { @{ Icon = [char]0x274C; Title = 'Run failed';              Style = 'attention' } }
        'WhatIf'               { @{ Icon = [char]0x2139; Title = 'Preview (WhatIf) run';    Style = 'accent' } }
        default                { @{ Icon = '';           Title = [string]$Summary.Result;   Style = 'default' } }
    }
    $when = try { ([datetime]$Summary.EndTime).ToUniversalTime().ToString('yyyy-MM-dd HH:mm') + ' UTC' } catch { [string]$Summary.EndTime }
    $createOnly = [bool]($Summary.PSObject.Properties['CreateGroupsOnly'] -and $Summary.CreateGroupsOnly)

    $body = [System.Collections.Generic.List[object]]::new()
    $body.Add(@{
        type = 'Container'; style = $look.Style; bleed = $true
        items = @(
            @{ type = 'TextBlock'; size = 'Large'; weight = 'Bolder'; wrap = $true; text = ('{0} Deployment rings: {1}' -f $look.Icon, $look.Title).Trim() }
            @{ type = 'TextBlock'; isSubtle = $true; spacing = 'None'; wrap = $true; text = "Ring set **$($Summary.RingSet)** - $($Summary.Mode) $(if ($createOnly) { 'create-groups-only ' })run - $when" }
        )
    })
    if ($Summary.ErrorMessage) {
        $msg = [string]$Summary.ErrorMessage
        if ($msg.Length -gt 1500) { $msg = $msg.Substring(0, 1500) + '...' }
        $msg = $msg -replace '\r?\n', "`n`n"   # Adaptive Card text needs a blank line for a line break
        $body.Add(@{ type = 'TextBlock'; wrap = $true; color = 'Attention'; text = $msg })
    }
    $certNote = Get-RingCertificateNote -Summary $Summary
    if ($certNote) { $body.Add(@{ type = 'TextBlock'; wrap = $true; weight = 'Bolder'; color = 'Warning'; text = "$([char]0x26A0) $certNote" }) }
    $facts = [System.Collections.Generic.List[object]]::new()
    $facts.Add(@{ title = 'Result'; value = [string]$Summary.Result })
    if ($createOnly) {
        $made = @($Summary.GroupsCreated)
        $facts.Add(@{ title = 'Groups created'; value = $(if ($made.Count) { $made -join ', ' } else { 'None (all already existed)' }) })
    }
    else {
        $facts.Add(@{ title = 'Changes'; value = "$($Summary.PlannedAdds) add(s), $($Summary.PlannedRemoves) remove(s)" })
        if ($Summary.Failed) { $facts.Add(@{ title = 'Failed'; value = [string]$Summary.Failed }) }
        if ($Summary.Conflicts) { $facts.Add(@{ title = 'Conflicts'; value = "$($Summary.Conflicts) (need manual action)" }) }
        $facts.Add(@{ title = 'Users in scope'; value = [string]$Summary.ScopedUsers })
        $facts.Add(@{ title = 'Change limit'; value = "$($Summary.ChangePercent)% of $($Summary.ChangeBaseline) ($($Summary.ChangeLimitReason))" })
    }
    if ($Summary.RetiredRingGroups -and @($Summary.RetiredRingGroups).Count) { $facts.Add(@{ title = 'Can be deleted'; value = (@($Summary.RetiredRingGroups) -join ', ') }) }
    $facts.Add(@{ title = 'Duration'; value = "$($Summary.DurationSeconds) s" })
    if ($Summary.ReportPath) { $facts.Add(@{ title = 'Report'; value = [string]$Summary.ReportPath }) }
    $body.Add(@{ type = 'FactSet'; facts = $facts.ToArray() })

    $top = @($Changes | Group-Object Action, Reason | Sort-Object Count -Descending | Select-Object -First 6)
    if ($top.Count) {
        $body.Add(@{ type = 'TextBlock'; weight = 'Bolder'; spacing = 'Medium'; text = 'Top changes' })
        $body.Add(@{ type = 'FactSet'; facts = @($top | ForEach-Object { @{ title = ($_.Name -replace ', ', ': '); value = [string]$_.Count } }) })
    }
    $dist = @($Summary.Distribution | Where-Object { $_ })
    if ($dist.Count) {
        $body.Add(@{ type = 'TextBlock'; weight = 'Bolder'; spacing = 'Medium'; text = 'Ring sizes' })
        $body.Add(@{ type = 'FactSet'; facts = @($dist | ForEach-Object {
            $v = [string]$_.Members
            if ($null -ne $_.TargetPercentOfComputed) { $v += " ($($_.ActualPercentOfComputed)% / target $($_.TargetPercentOfComputed)%)" }
            @{ title = [string]$_.Ring; value = $v }
        }) })
    }
    $body.Add(@{ type = 'TextBlock'; isSubtle = $true; size = 'Small'; wrap = $true; spacing = 'Medium'; text = "Run $($Summary.RunId) - revision $($Summary.ScriptRevision) - host $([Environment]::MachineName)" })

    @{
        type        = 'message'
        attachments = @(@{
            contentType = 'application/vnd.microsoft.card.adaptive'
            contentUrl  = $null
            content     = @{
                '$schema' = 'http://adaptivecards.io/schemas/adaptive-card.json'
                type      = 'AdaptiveCard'
                version   = '1.4'
                msteams   = @{ width = 'Full' }
                body      = $body.ToArray()
            }
        })
    }
}

function Send-RingTeamsNotification {
    <# Posts the card. Retries throttling/server errors. Never logs the URL. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $WebhookUrl,
        [Parameter(Mandatory)] $Payload
    )
    $json = $Payload | ConvertTo-Json -Depth 20 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    for ($attempt = 1; ; $attempt++) {
        try {
            Invoke-RestMethod -Method POST -Uri $WebhookUrl -Body $bytes -ContentType 'application/json; charset=utf-8' -ErrorAction Stop | Out-Null
            return
        }
        catch {
            $status = (Get-GraphErrorStatus -ErrorRecord $_).Status
            if ($status -in 429, 500, 502, 503, 504 -and $attempt -lt 4) { Start-Sleep -Seconds ([math]::Pow(2, $attempt)); continue }
            $reason = $_.Exception.Message.Replace($WebhookUrl, '<webhook>')
            throw "Teams webhook returned an error$(if ($status) { " ($status)" }): $reason"
        }
    }
}

function Get-RingEmailMessage {
    <#
        Builds the notification email: @{ Subject; Html }. Counts and reasons
        only - no user names or IDs. Every value is HTML-encoded.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Summary,
        [AllowEmptyCollection()] [object[]] $Changes = @()
    )
    $enc = { param($v) [System.Net.WebUtility]::HtmlEncode([string]$v) }
    $label = switch ($Summary.Result) {
        'Success'              { @{ Text = 'Run succeeded';           Color = '#107C10' } }
        'CompletedWithErrors'  { @{ Text = 'Completed with errors';   Color = '#C19C00' } }
        'BlockedByChangeLimit' { @{ Text = 'Blocked by change limit'; Color = '#C19C00' } }
        'Failed'               { @{ Text = 'Run failed';              Color = '#C50F1F' } }
        'WhatIf'               { @{ Text = 'Preview (WhatIf) run';    Color = '#0F6CBD' } }
        default                { @{ Text = [string]$Summary.Result;   Color = '#616161' } }
    }
    $subject = "[EntraDeploymentRings] $($label.Text) - $($Summary.RingSet)"
    $certNote = Get-RingCertificateNote -Summary $Summary
    if ($certNote) { $subject += " - certificate expires in $($Summary.CertificateDaysLeft) day(s)" }

    $rows = [System.Collections.Generic.List[string]]::new()
    $addRow = { param($k, $v) $rows.Add("<tr><td style=""padding:4px 12px 4px 0;color:#616161"">$(& $enc $k)</td><td style=""padding:4px 0"">$(& $enc $v)</td></tr>") }
    & $addRow 'Result' $Summary.Result
    & $addRow 'Mode' $Summary.Mode
    if ($Summary.PSObject.Properties['CreateGroupsOnly'] -and $Summary.CreateGroupsOnly) {
        $made = @($Summary.GroupsCreated)
        & $addRow 'Run type' 'Create groups only (no users read, no membership changed)'
        & $addRow 'Groups created' $(if ($made.Count) { $made -join ', ' } else { 'None (all already existed)' })
    }
    else {
        & $addRow 'Changes' "$($Summary.PlannedAdds) add(s), $($Summary.PlannedRemoves) remove(s)"
        if ($Summary.Failed) { & $addRow 'Failed' $Summary.Failed }
        if ($Summary.Conflicts) { & $addRow 'Conflicts' "$($Summary.Conflicts) (need manual action)" }
        & $addRow 'Users in scope' $Summary.ScopedUsers
        & $addRow 'Change limit' "$($Summary.ChangePercent)% of $($Summary.ChangeBaseline) ($($Summary.ChangeLimitReason))"
    }
    if ($Summary.RetiredRingGroups -and @($Summary.RetiredRingGroups).Count) { & $addRow 'Can be deleted' (@($Summary.RetiredRingGroups) -join ', ') }
    & $addRow 'Duration' "$($Summary.DurationSeconds) s"
    if ($Summary.ReportPath) { & $addRow 'Report' $Summary.ReportPath }
    & $addRow 'Run ID' $Summary.RunId
    & $addRow 'Host' ([Environment]::MachineName)

    $sections = [System.Text.StringBuilder]::new()
    $top = @($Changes | Group-Object Action, Reason | Sort-Object Count -Descending | Select-Object -First 6)
    if ($top.Count) {
        [void]$sections.Append('<h3 style="margin:16px 0 4px">Top changes</h3><table>')
        foreach ($t in $top) { [void]$sections.Append("<tr><td style=""padding:2px 12px 2px 0"">$(& $enc ($t.Name -replace ', ', ': '))</td><td>$($t.Count)</td></tr>") }
        [void]$sections.Append('</table>')
    }
    $dist = @($Summary.Distribution | Where-Object { $_ })
    if ($dist.Count) {
        [void]$sections.Append('<h3 style="margin:16px 0 4px">Ring sizes</h3><table>')
        foreach ($d in $dist) {
            $v = [string]$d.Members
            if ($null -ne $d.TargetPercentOfComputed) { $v += " ($($d.ActualPercentOfComputed)% / target $($d.TargetPercentOfComputed)%)" }
            [void]$sections.Append("<tr><td style=""padding:2px 12px 2px 0"">$(& $enc $d.Ring)</td><td>$(& $enc $v)</td></tr>")
        }
        [void]$sections.Append('</table>')
    }
    $err = ''
    if ($Summary.ErrorMessage) {
        $msg = [string]$Summary.ErrorMessage
        if ($msg.Length -gt 2000) { $msg = $msg.Substring(0, 2000) + '...' }
        $err = "<p style=""color:#C50F1F;margin:8px 0"">$((& $enc $msg) -replace '\r?\n', '<br>')</p>"
    }
    if ($certNote) { $err += "<p style=""color:#8A5100;font-weight:600;margin:8px 0"">$(& $enc $certNote)</p>" }
    $html = @"
<div style="font-family:Segoe UI,Arial,sans-serif;font-size:14px;color:#242424">
<div style="border-left:6px solid $($label.Color);padding:4px 12px;margin-bottom:8px">
<div style="font-size:18px;font-weight:600">Deployment rings: $(& $enc $label.Text)</div>
<div style="color:#616161">Ring set <b>$(& $enc $Summary.RingSet)</b> - revision $(& $enc $Summary.ScriptRevision) - finished $(& $enc $Summary.EndTime)</div>
</div>
$err
<table>$($rows -join '')</table>
$($sections.ToString())
<p style="color:#616161;font-size:12px;margin-top:16px">Sent by Invoke-EntraDeploymentRings. This message contains counts only; see the report for user-level detail.</p>
</div>
"@
    @{ Subject = $subject; Html = $html }
}

function Send-RingEmailNotification {
    <# Sends the email through Microsoft Graph sendMail (needs a connected Graph session). #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $From,
        [Parameter(Mandatory)] [string[]] $To,
        [Parameter(Mandatory)] [string] $Subject,
        [Parameter(Mandatory)] [string] $Html
    )
    $body = @{
        message         = @{
            subject      = $Subject
            body         = @{ contentType = 'HTML'; content = $Html }
            toRecipients = @($To | ForEach-Object { @{ emailAddress = @{ address = $_ } } })
        }
        saveToSentItems = $false
    }
    try {
        Invoke-RingGraphRequest -Method POST -Uri "$($script:GraphApi)/users/$([uri]::EscapeDataString($From))/sendMail" -Body $body -Purpose "sending the notification from $From" | Out-Null
    }
    catch {
        $status = (Get-GraphErrorStatus -ErrorRecord $_).Status
        $hint = switch ($status) {
            404 { ' The EmailFrom mailbox was not found or has no Exchange Online license.' }
            default { '' }
        }
        throw "sendMail failed$(if ($status) { " ($status)" }).$hint $($_.Exception.Message)"
    }
}

function Send-RingLogAnalytics {
    <# Sends records through the Logs Ingestion API in ~1 MB chunks. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Settings,
        [Parameter(Mandatory)] [string] $Token,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Records
    )
    if ($Records.Count -eq 0) { return }
    $uri = '{0}/dataCollectionRules/{1}/streams/{2}?api-version=2023-01-01' -f $Settings.LogIngestionEndpoint, $Settings.LogDcrImmutableId, $Settings.LogStreamName
    $headers = @{ Authorization = "Bearer $Token" }
    $maxBytes = 900KB
    $batch = [System.Collections.Generic.List[string]]::new()
    $size = 2

    $flush = {
        if ($batch.Count -eq 0) { return }
        $body = '[' + ($batch -join ',') + ']'
        for ($attempt = 1; ; $attempt++) {
            try {
                Invoke-RestMethod -Method POST -Uri $uri -Headers $headers -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) -ContentType 'application/json' -ErrorAction Stop | Out-Null
                break
            }
            catch {
                $status = (Get-GraphErrorStatus -ErrorRecord $_).Status
                if ($status -notin 429, 500, 502, 503, 504 -or $attempt -ge 5) { throw }
                Start-Sleep -Seconds ([math]::Pow(2, $attempt))
            }
        }
        $batch.Clear()
    }

    foreach ($r in $Records) {
        $line = $r | ConvertTo-Json -Depth 8 -Compress
        $len = [System.Text.Encoding]::UTF8.GetByteCount($line) + 1
        if ($size + $len -gt $maxBytes) { & $flush; $size = 2 }
        $batch.Add($line); $size += $len
    }
    & $flush
}

#endregion

#region ---------- Orchestration ---------------------------------------------

function Invoke-DeploymentRingSync {
    <# End-to-end run. Returns the summary object. #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)] $Settings)

    $ctx = [pscustomobject]@{
        RunId     = [guid]::NewGuid().ToString()
        StartTime = [datetime]::UtcNow
        Settings  = $Settings
        IsWhatIf  = [bool]$WhatIfPreference
        Groups    = [ordered]@{}
    }
    $summary = [pscustomobject][ordered]@{
        RunId = $ctx.RunId; ScriptRevision = $script:ScriptRevision; RingSet = $Settings.GroupNameBase
        Mode = if ($ctx.IsWhatIf) { 'WhatIf' } else { 'Live' }; Result = 'Running'; ErrorMessage = $null
        StartTime = $ctx.StartTime.ToString('o'); EndTime = $null; DurationSeconds = $null
        AssignmentMode = $Settings.AssignmentMode; Rebalance = $Settings.Rebalance; InitialRun = $Settings.InitialRun
        CreateGroupsOnly = $Settings.CreateGroupsOnly
        ExcludedByReason = [ordered]@{}
        CandidateUsers = 0; ScopedUsers = 0; Distribution = @()
        PlannedAdds = 0; PlannedRemoves = 0; Succeeded = 0; Failed = 0; Conflicts = 0
        ChangeBaseline = 0; ChangePercent = 0; ChangeLimitReason = $null
        GroupsCreated = @(); RetiredRingGroups = @(); ReportPath = $null; ReportFiles = @(); ReportsPruned = 0
        Notification = 'NotConfigured'; EmailNotification = 'NotConfigured'; LogAnalytics = 'NotConfigured'
        CertificateExpires = $null; CertificateDaysLeft = $null; CertificateWarning = $false
        ExclusionGroups = @(); Network = @()
    }
    $changes = @(); $conflicts = @()
    $cert = $null; $monitorToken = $null; $connectedHere = $false; $runError = $null
    $signedIn = $false   # set only when THIS run signed in; email must never borrow another session

    try {
        Write-RingLog "Run $($ctx.RunId) starting (revision $($script:ScriptRevision), ring set '$($Settings.GroupNameBase)', $($Settings.RingCount) computed ring(s), mode $($summary.Mode))."
        if ($Settings.CreateGroupsOnly) {
            Write-RingLog 'Create-groups-only run: missing ring groups will be created. No users are read and no membership is changed.'
        }

        # Network first: a blocked path would otherwise look like a 100-second hang at sign-in.
        $summary.Network = Test-RingNetwork -Settings $Settings
        if ($Settings.Rebalance) {
            $label = if ($Settings.InitialRun) { 'InitialRun' } else { 'Rebalance' }
            Write-RingLog -Level Warning "$($label): every computed-ring user will be re-placed using the current weights, and the change limit is not enforced."
        }

        if ($Settings.AuthMode -eq 'Certificate') {
            $cert = Get-RingCertificate -Thumbprint $Settings.CertificateThumbprint
            $certStatus = Get-RingCertificateStatus -Certificate $cert -WarningDays $Settings.CertificateExpiryWarningDays
            $summary.CertificateExpires = $certStatus.NotAfter.ToString('o')
            $summary.CertificateDaysLeft = $certStatus.DaysLeft
            if ($certStatus.Status -in 'Expired', 'NotYetValid') { throw $certStatus.Message }
            if ($certStatus.Status -eq 'Expiring') {
                $summary.CertificateWarning = $true
                Write-RingLog -Level Warning $certStatus.Message
            }
        }
        Write-RingLog "Signing in to Microsoft Graph ($(Get-RingSignInDescription -Settings $Settings))..."
        $signClock = [System.Diagnostics.Stopwatch]::StartNew()
        try { $connectedHere = Connect-RingGraph -Settings $Settings -Certificate $cert }
        catch {
            $secs = [int]$signClock.Elapsed.TotalSeconds
            $why = Get-RingExceptionChain $_.Exception
            $hint = if ($secs -ge 90) { ' It took about 100 s, which is a network timeout: the sign-in request got no answer. Check the VPN, proxy and firewall.' } else { '' }
            throw [System.Exception]::new("Sign-in to Microsoft Graph failed after $secs s ($($Settings.AuthMode)): $why.$hint", $_.Exception)
        }
        $signedIn = $true
        Write-RingLog "Signed in ($([int]$signClock.Elapsed.TotalSeconds) s)."
        Test-RingGraphPermission -Settings $Settings

        # Fail fast on Log Analytics configuration before changing anything.
        if ($Settings.LogAnalyticsEnabled -and -not $ctx.IsWhatIf) {
            $monitorToken = Get-RingMonitorToken -Settings $Settings -Certificate $cert
            Write-RingLog 'Azure Monitor token acquired for Log Analytics.'
        }

        if ($Settings.CreateGroupsOnly) {
            $ctx.Groups = Resolve-RingGroups -Settings $Settings
            $new = @($ctx.Groups.Values | Where-Object IsNew | ForEach-Object { $_.DisplayName })
            $existing = @($ctx.Groups.Values | Where-Object { -not $_.IsNew } | ForEach-Object { $_.DisplayName })
            $summary.GroupsCreated = $new
            $verb = if ($ctx.IsWhatIf) { 'Would create' } else { 'Created' }
            if ($new.Count) { Write-RingLog "$verb $($new.Count) group(s): $($new -join ', ')." }
            if ($existing.Count) { Write-RingLog "$($existing.Count) group(s) already existed and were left unchanged: $($existing -join ', ')." }
            if (-not $new.Count) { Write-RingLog 'Nothing to create: every ring group already exists.' }
            $summary.Result = if ($ctx.IsWhatIf) { 'WhatIf' } else { 'Success' }
            if (-not $ctx.IsWhatIf) {
                Write-RingLog 'Next: assign your policies to the empty rings, then fill them with -InitialRun (preview with -InitialRun -WhatIf first).'
            }
        }
        else {
            # Groups
            Write-RingLog 'Reading ring groups and their members...'
            $groupClock = [System.Diagnostics.Stopwatch]::StartNew()
            $orphans = Find-OrphanRingGroups -Settings $Settings
            # An already-emptied orphan is retired: warn so it can be deleted, but don't block scheduled runs.
            $retired = [System.Collections.Generic.List[string]]::new()
            foreach ($k in @($orphans.Keys)) {
                if ((Get-RingGroupUserMembers -GroupId $orphans[$k].Id -GroupName $orphans[$k].DisplayName).Count -eq 0) {
                    Write-RingLog -Level Warning "Ring group '$($orphans[$k].DisplayName)' is above RingCount $($Settings.RingCount) and empty. It is no longer managed; remove its policy assignments and delete it."
                    $retired.Add($orphans[$k].DisplayName)
                    $orphans.Remove($k)
                }
            }
            $summary.RetiredRingGroups = $retired.ToArray()
            if ($orphans.Count -gt 0 -and -not $Settings.RetireOrphanRings) {
                throw "Found ring group(s) above RingCount $($Settings.RingCount) that still have members: $($orphans.Values.DisplayName -join ', '). RingCount was reduced. Re-run with -RetireOrphanRings to empty them and re-place their members, or restore RingCount."
            }
            $ctx.Groups = Resolve-RingGroups -Settings $Settings
            foreach ($k in $orphans.Keys) { $ctx.Groups[$k] = $orphans[$k] }
            $summary.GroupsCreated = @($ctx.Groups.Values | Where-Object IsNew | ForEach-Object { $_.DisplayName })

            # Membership snapshot
            $current = @{}
            foreach ($k in $ctx.Groups.Keys) {
                if ($k -in 'First', 'Last') { continue }
                $current[$k] = Get-RingGroupUserMembers -GroupId $ctx.Groups[$k].Id -GroupName $ctx.Groups[$k].DisplayName
            }
            $current['First'] = Get-RingGroupUserMembers -GroupId $ctx.Groups['First'].Id -GroupName $ctx.Groups['First'].DisplayName
            $current['Last']  = Get-RingGroupUserMembers -GroupId $ctx.Groups['Last'].Id -GroupName $ctx.Groups['Last'].DisplayName
            $firstIds = [System.Collections.Generic.HashSet[string]]::new([string[]]@((Get-RingGroupUserMembers -GroupId $ctx.Groups['First'].Id -GroupName $ctx.Groups['First'].DisplayName -Transitive).Keys), [StringComparer]::OrdinalIgnoreCase)
            $lastIds  = [System.Collections.Generic.HashSet[string]]::new([string[]]@((Get-RingGroupUserMembers -GroupId $ctx.Groups['Last'].Id -GroupName $ctx.Groups['Last'].DisplayName -Transitive).Keys), [StringComparer]::OrdinalIgnoreCase)
            $memberships = 0; foreach ($k in $current.Keys) { $memberships += $current[$k].Count }
            $nested = ($firstIds.Count - $current['First'].Count) + ($lastIds.Count - $current['Last'].Count)
            $nestedNote = if ($nested -gt 0) { ', including {0:N0} through groups nested in First or Last' -f $nested } else { '' }
            Write-RingLog ('Read {0} ring group(s) with {1:N0} user member(s){2} in {3:N0} s.' -f $ctx.Groups.Count, $memberships, $nestedNote, $groupClock.Elapsed.TotalSeconds)

            $excluded = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            $exclusionGroups = [System.Collections.Generic.List[object]]::new()
            foreach ($gid in $Settings.ExcludeGroupIds) {
                $eg = Resolve-RingExclusionGroup -GroupId $gid
                foreach ($uid in $eg.Members.Keys) { [void]$excluded.Add($uid) }
                $exclusionGroups.Add([pscustomobject]@{ Id = $eg.Id; DisplayName = $eg.DisplayName; Members = $eg.Members.Count })
                Write-RingLog "Exclusion group '$($eg.DisplayName)' ($($eg.Id)): $($eg.Members.Count) user(s) excluded."
            }
            $summary.ExclusionGroups = $exclusionGroups.ToArray()

            # Users
            $candidates = Get-RingCandidateUsers -Settings $Settings
            $scopedList = [System.Collections.Generic.List[object]]::new()
            $exclusionReasons = @{}
            $upnById = @{}
            foreach ($c in $candidates) {
                $upnById[$c.Id] = $c.UserPrincipalName
                $why = Get-RingScopeExclusion -User $c -Settings $Settings -ExcludedIds $excluded
                if ($why) { $exclusionReasons[$c.Id] = $why } else { $scopedList.Add($c) }
            }
            $scoped = $scopedList.ToArray()
            $summary.CandidateUsers = $candidates.Count
            $summary.ScopedUsers = $scoped.Count
            foreach ($grp in ($exclusionReasons.Values | Group-Object { ($_ -split ':', 2)[0] } | Sort-Object Name)) {
                $summary.ExcludedByReason[$grp.Name] = $grp.Count
            }
            $excludedText = if ($summary.ExcludedByReason.Count) { ($summary.ExcludedByReason.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' ' } else { 'none' }
            Write-RingLog "$($candidates.Count) candidate user(s), $($scoped.Count) in scope. Excluded: $excludedText."

            # Plan
            $plan = Get-RingPlan -Users $scoped -Settings $Settings -CurrentMembers $current -FirstIds $firstIds -LastIds $lastIds -OrphanKeys ([string[]]@($orphans.Keys)) -ExclusionReasons $exclusionReasons -UpnById $upnById
            $changes = @($plan.Changes); $conflicts = @($plan.Conflicts)
            $summary.PlannedAdds = @($changes | Where-Object Action -eq 'Add').Count
            $summary.PlannedRemoves = @($changes | Where-Object Action -eq 'Remove').Count
            $summary.Conflicts = $conflicts.Count

            $computedTotal = 0
            foreach ($k in $Settings.RingKeys) { $computedTotal += $plan.Counts[$k] }
            $dist = [System.Collections.Generic.List[object]]::new()
            $allKeys = @('First') + @($Settings.RingKeys) + @('Last') + $(if ($Settings.EnableInactiveRing) { 'Inactive' } else { @() })
            foreach ($k in $allKeys) {
                $i = [array]::IndexOf($Settings.RingKeys, $k)
                $dist.Add([pscustomobject][ordered]@{
                    Ring = $k
                    Group = $ctx.Groups[$k].DisplayName
                    Members = $plan.Counts[$k]
                    TargetPercentOfComputed = if ($i -ge 0) { [math]::Round(100 * $Settings.RingWeights[$i], 2) } else { $null }
                    ActualPercentOfComputed = if ($i -ge 0 -and $computedTotal -gt 0) { [math]::Round(100.0 * $plan.Counts[$k] / $computedTotal, 2) } else { $null }
                })
            }
            $summary.Distribution = $dist.ToArray()
            Write-RingLog ("Plan: {0} add(s), {1} remove(s), {2} conflict(s). Distribution: {3}" -f $summary.PlannedAdds, $summary.PlannedRemoves, $summary.Conflicts, (($dist | ForEach-Object { "$($_.Ring)=$($_.Members)" }) -join ' '))

            # Circuit breaker
            $limit = Test-ChangeThreshold -ChangeCount $changes.Count -Baseline $plan.Baseline -Settings $Settings
            $summary.ChangeBaseline = $limit.Baseline; $summary.ChangePercent = $limit.Percent; $summary.ChangeLimitReason = $limit.Reason
            if (-not $limit.Allowed) {
                foreach ($c in $changes) { $c.Result = 'Blocked' }
                $summary.Result = 'BlockedByChangeLimit'
                $summary.ErrorMessage = "Planned changes ($($limit.ChangeCount)) are $($limit.Percent)% of current managed membership ($($limit.Baseline)), above MaxChangePercent $($Settings.MaxChangePercent)%. Review the report, then re-run with -BypassChangeLimit if the changes are expected."
                throw $summary.ErrorMessage
            }
            if ($limit.Reason -in 'InitialPopulation', 'InitialRun', 'Rebalance', 'Bypassed') { Write-RingLog -Level Warning "Change limit not enforced: $($limit.Reason) ($($limit.ChangeCount) change(s))." }

            # Apply: removals first, so no user is ever in two rings at once.
            $ordered = @('Inactive') + @($Settings.RingKeys) + @($orphans.Keys) + @('First', 'Last')
            $live = -not $ctx.IsWhatIf -and $changes.Count -gt 0
            $progress = @{ Total = $changes.Count; Done = 0; NextLog = $script:ApplyProgressEvery; Clock = [System.Diagnostics.Stopwatch]::StartNew() }
            if ($live) {
                $groupCount = @($changes | Select-Object -ExpandProperty GroupKey -Unique).Count
                Write-RingLog ('Applying {0:N0} change(s) to {1} group(s): removals first, then additions...' -f $changes.Count, $groupCount)
            }
            foreach ($action in 'Remove', 'Add') {
                foreach ($k in $ordered) {
                    $groupChanges = @($changes | Where-Object { $_.GroupKey -eq $k -and $_.Action -eq $action })
                    if (-not $groupChanges.Count) { continue }
                    $g = $ctx.Groups[$k]
                    $verb = if ($action -eq 'Add') { @('adding', 'added') } else { @('removing', 'removed') }
                    if ($live) { Write-RingLog ('  {0}: {1} {2:N0} user(s)...' -f $g.DisplayName, $verb[0], $groupChanges.Count) }
                    $groupClock = [System.Diagnostics.Stopwatch]::StartNew()
                    Invoke-RingMembershipChanges -Group $g -Changes $groupChanges -Settings $Settings -Progress $(if ($live) { $progress } else { $null })
                    if ($live) {
                        $ok = @($groupChanges | Where-Object Result -in 'Success', 'AlreadyMember', 'NotMember').Count
                        $bad = @($groupChanges | Where-Object Result -eq 'Failed').Count
                        $msg = '  {0}: {1:N0} {2}, {3:N0} failed ({4:N0} s).' -f $g.DisplayName, $ok, $verb[1], $bad, $groupClock.Elapsed.TotalSeconds
                        if ($bad) { Write-RingLog -Level Warning $msg } else { Write-RingLog $msg }
                    }
                }
            }
            if ($live) {
                Write-Progress -Id 2 -Activity 'Updating ring groups' -Completed
                $okAll = @($changes | Where-Object Result -in 'Success', 'AlreadyMember', 'NotMember').Count
                $badAll = @($changes | Where-Object Result -eq 'Failed').Count
                Write-RingLog ('Applied {0:N0} change(s) in {1:N0} s: {2:N0} succeeded, {3:N0} failed.' -f $changes.Count, $progress.Clock.Elapsed.TotalSeconds, $okAll, $badAll)
            }

            $summary.Succeeded = @($changes | Where-Object Result -in 'Success', 'AlreadyMember', 'NotMember').Count
            $summary.Failed = @($changes | Where-Object Result -eq 'Failed').Count
            $summary.Result = if ($ctx.IsWhatIf) { 'WhatIf' } elseif ($summary.Failed -gt 0) { 'CompletedWithErrors' } else { 'Success' }
            foreach ($f in ($changes | Where-Object Result -eq 'Failed' | Select-Object -First 10)) {
                Write-RingLog -Level Warning "Failed to $($f.Action.ToLower()) $($f.UserPrincipalName) ($($f.UserId)) in $($f.GroupKey): $($f.ErrorMessage)"
            }
        }
    }
    catch {
        if ($summary.Result -eq 'Running') { $summary.Result = 'Failed'; $summary.ErrorMessage = $_.Exception.Message }
        $runError = $_
    }
    finally {
        $end = [datetime]::UtcNow
        $summary.EndTime = $end.ToString('o')
        $summary.DurationSeconds = [math]::Round(($end - $ctx.StartTime).TotalSeconds, 1)

        $records = Get-RingRecords -Context $ctx -Changes $changes -Conflicts $conflicts -Summary $summary
        $paths = $null

        # 1. CSV, then retention.
        try {
            $paths = Get-RingReportPath -Context $ctx
            if ($paths.Csv) { Write-RingCsvReport -Path $paths.Csv -Records $records }
            $summary.ReportFiles = @(@($paths.Csv, $paths.Json) | Where-Object { $_ })
            $summary.ReportPath = $summary.ReportFiles | Select-Object -First 1
            if ($summary.ReportFiles.Count -gt 0 -and $Settings.ReportRetentionDays -gt 0) {
                $summary.ReportsPruned = Remove-RingExpiredReport -Directory $Settings.ReportDirectory -Base $Settings.GroupNameBase -RetentionDays $Settings.ReportRetentionDays -Keep $summary.ReportFiles
                if ($summary.ReportsPruned) { Write-RingLog "Deleted $($summary.ReportsPruned) report file(s) older than $($Settings.ReportRetentionDays) day(s)." }
            }
        }
        catch { Write-RingLog -Level Warning "Could not write or prune reports: $($_.Exception.Message)" }

        # 2. Teams.
        if ($Settings.TeamsWebhookUrl) {
            if (Test-RingShouldNotify -Settings $Settings -Result $summary.Result -IsWhatIf $ctx.IsWhatIf -Channel Teams -CertificateWarning $summary.CertificateWarning) {
                try {
                    Send-RingTeamsNotification -WebhookUrl $Settings.TeamsWebhookUrl -Payload (Get-RingTeamsPayload -Summary $summary -Changes $changes)
                    $summary.Notification = 'Sent'
                    Write-RingLog 'Teams notification sent.'
                }
                catch {
                    $summary.Notification = 'Failed'
                    Write-RingLog -Level Warning "Could not send Teams notification: $($_.Exception.Message)"
                }
            }
            else { $summary.Notification = 'NotRequested' }
        }

        # 2b. Email (Graph sendMail; needs the Graph session, which is still open here).
        if ($Settings.EmailEnabled) {
            if (Test-RingShouldNotify -Settings $Settings -Result $summary.Result -IsWhatIf $ctx.IsWhatIf -Channel Email -CertificateWarning $summary.CertificateWarning) {
                try {
                    # Checking Get-MgContext alone is not enough: a session left in this PowerShell process by
                    # someone else (for example an admin's Connect-MgGraph) would send under their identity.
                    if (-not $signedIn) { throw 'not sent: this run did not sign in to Microsoft Graph (for example, the certificate expired), and email is only sent from the run''s own session.' }
                    $mail = Get-RingEmailMessage -Summary $summary -Changes $changes
                    Send-RingEmailNotification -From $Settings.EmailFrom -To $Settings.EmailTo -Subject $mail.Subject -Html $mail.Html
                    $summary.EmailNotification = 'Sent'
                    Write-RingLog "Email notification sent to $($Settings.EmailTo.Count) recipient(s)."
                }
                catch {
                    $summary.EmailNotification = 'Failed'
                    Write-RingLog -Level Warning "Could not send email notification: $($_.Exception.Message)"
                }
            }
            else { $summary.EmailNotification = 'NotRequested' }
        }

        # 3. Log Analytics. Marked Sent first so the Summary record that arrives says so;
        #    reverted to Failed if the send fails.
        if ($monitorToken) {
            try {
                $summary.LogAnalytics = 'Sent'
                Send-RingLogAnalytics -Settings $Settings -Token $monitorToken -Records $records
                Write-RingLog "Sent $($records.Count) record(s) to Log Analytics."
            }
            catch {
                $summary.LogAnalytics = 'Failed'
                Write-RingLog -Level Warning "Could not send to Log Analytics: $($_.Exception.Message)"
            }
        }
        elseif ($Settings.LogAnalyticsEnabled) { $summary.LogAnalytics = 'Skipped' }

        # 4. JSON summary last, so every field above is final.
        if ($paths -and $paths.Json) {
            try { Write-RingJsonSummary -Path $paths.Json -Summary $summary }
            catch { Write-RingLog -Level Warning "Could not write the JSON summary: $($_.Exception.Message)" }
        }
        if ($connectedHere) { try { Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null } catch { Write-RingLog -Level Verbose 'Disconnect-MgGraph failed.' } }
        if ($cert) { $cert.Dispose() }
        Write-RingLog "Run $($ctx.RunId) finished: $($summary.Result). Report: $($summary.ReportPath)"
    }

    if ($runError) {
        $summary
        throw $runError
    }
    if ($summary.Failed -gt 0) {
        Write-Error "$($summary.Failed) membership change(s) failed. See $($summary.ReportPath)." -ErrorAction Continue
    }
    $summary
}

#endregion

#region ---------- Preflight -------------------------------------------------

function Get-RingPreflightTeamsPayload {
    <# Teams card listing preflight checks. No user data. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Summary)
    $icon = @{ Pass = [char]0x2705; Warn = [char]0x26A0; Fail = [char]0x274C; Skip = [char]0x2796 }
    $style = switch ($Summary.Result) { 'PreflightPassed' { 'good' } 'PreflightPassedWithWarnings' { 'warning' } default { 'attention' } }
    $title = switch ($Summary.Result) { 'PreflightPassed' { 'Preflight passed' } 'PreflightPassedWithWarnings' { 'Preflight passed with warnings' } default { 'Preflight failed' } }
    $body = [System.Collections.Generic.List[object]]::new()
    $body.Add(@{
        type = 'Container'; style = $style; bleed = $true
        items = @(
            @{ type = 'TextBlock'; size = 'Large'; weight = 'Bolder'; wrap = $true; text = "Deployment rings: $title" }
            @{ type = 'TextBlock'; isSubtle = $true; spacing = 'None'; wrap = $true; text = "Ring set **$($Summary.RingSet)** - test notification from -Preflight - no changes were made" }
        )
    })
    $body.Add(@{ type = 'FactSet'; facts = @($Summary.Checks | ForEach-Object { @{ title = "$($icon[$_.Status]) $($_.Area): $($_.Check)"; value = [string]$_.Detail } }) })
    $body.Add(@{ type = 'TextBlock'; isSubtle = $true; size = 'Small'; wrap = $true; text = "Run $($Summary.RunId) - revision $($Summary.ScriptRevision) - host $([Environment]::MachineName)" })
    @{
        type = 'message'
        attachments = @(@{
            contentType = 'application/vnd.microsoft.card.adaptive'; contentUrl = $null
            content = @{ '$schema' = 'http://adaptivecards.io/schemas/adaptive-card.json'; type = 'AdaptiveCard'; version = '1.4'; msteams = @{ width = 'Full' }; body = $body.ToArray() }
        })
    }
}

function Get-RingPreflightEmailMessage {
    <# Email listing preflight checks. HTML-encoded, no user data. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Summary)
    $enc = { param($v) [System.Net.WebUtility]::HtmlEncode([string]$v) }
    $color = @{ Pass = '#107C10'; Warn = '#8A5100'; Fail = '#C50F1F'; Skip = '#616161' }
    $title = switch ($Summary.Result) { 'PreflightPassed' { 'Preflight passed' } 'PreflightPassedWithWarnings' { 'Preflight passed with warnings' } default { 'Preflight failed' } }
    $rows = ($Summary.Checks | ForEach-Object {
        "<tr><td style=""padding:3px 10px 3px 0;color:$($color[$_.Status]);font-weight:600"">$($_.Status.ToUpperInvariant())</td><td style=""padding:3px 10px 3px 0"">$(& $enc "$($_.Area): $($_.Check)")</td><td style=""padding:3px 0"">$(& $enc $_.Detail)</td></tr>"
    }) -join ''
    $html = @"
<div style="font-family:Segoe UI,Arial,sans-serif;font-size:14px;color:#242424">
<div style="font-size:18px;font-weight:600">Deployment rings: $(& $enc $title)</div>
<div style="color:#616161;margin-bottom:8px">Ring set <b>$(& $enc $Summary.RingSet)</b> - test notification from -Preflight - no changes were made</div>
<table>$rows</table>
<p style="color:#616161;font-size:12px;margin-top:16px">Run $(& $enc $Summary.RunId) - revision $(& $enc $Summary.ScriptRevision) - host $(& $enc ([Environment]::MachineName))</p>
</div>
"@
    @{ Subject = "[EntraDeploymentRings] $title - $($Summary.RingSet)"; Html = $html }
}

function Invoke-RingPreflight {
    <#
        Checks the environment without planning or changing anything:
        configuration, certificate, sign-in, permissions, user and group
        access, exclusion groups, report folder, Log Analytics (sends one
        test record), Teams and email (send one test message each).
        Returns a summary with a Checks list (Status Pass/Warn/Fail/Skip).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Settings)

    $start = [datetime]::UtcNow
    $runId = [guid]::NewGuid().ToString()
    $checks = [System.Collections.Generic.List[object]]::new()
    $add = { param($Area, $Check, $Status, $Detail) $checks.Add([pscustomobject][ordered]@{ Area = $Area; Check = $Check; Status = $Status; Detail = [string]$Detail }) }
    $cert = $null; $connectedHere = $false; $signedIn = $false
    $summary = [pscustomobject][ordered]@{
        RunId = $runId; ScriptRevision = $script:ScriptRevision; RingSet = $Settings.GroupNameBase; Mode = 'Preflight'
        Result = $null; StartTime = $start.ToString('o'); EndTime = $null; DurationSeconds = $null
        Passed = 0; Warnings = 0; Failed = 0; Skipped = 0
        CertificateExpires = $null; CertificateDaysLeft = $null; CertificateWarning = $false
        Checks = @()
    }
    Write-RingLog "Preflight $runId (revision $($script:ScriptRevision), ring set '$($Settings.GroupNameBase)'). Nothing will be changed."

    try {
        # --- Configuration and runtime ------------------------------------
        $weights = ($Settings.RingWeights | ForEach-Object { [math]::Round(100 * $_, 2) }) -join '/'
        & $add 'Configuration' 'Settings' 'Pass' "$($Settings.RingCount) ring(s) weighted $weights; AuthMode $($Settings.AuthMode)"
        & $add 'Runtime' 'PowerShell' 'Pass' "$($PSVersionTable.PSVersion) on $([System.Runtime.InteropServices.RuntimeInformation]::OSDescription)"
        $moduleOk = $false
        try {
            Initialize-RingGraphModule
            $mod = Get-Module Microsoft.Graph.Authentication | Select-Object -First 1
            & $add 'Runtime' 'Microsoft.Graph.Authentication' 'Pass' $(if ($mod) { "version $($mod.Version)" } else { 'Invoke-MgGraphRequest available' })
            $moduleOk = $true
        }
        catch { & $add 'Runtime' 'Microsoft.Graph.Authentication' 'Fail' $_.Exception.Message }

        # --- Certificate ----------------------------------------------------
        if ($Settings.AuthMode -eq 'Certificate') {
            try {
                $cert = Get-RingCertificate -Thumbprint $Settings.CertificateThumbprint
                $cs = Get-RingCertificateStatus -Certificate $cert -WarningDays $Settings.CertificateExpiryWarningDays
                $summary.CertificateExpires = $cs.NotAfter.ToString('o'); $summary.CertificateDaysLeft = $cs.DaysLeft
                $summary.CertificateWarning = ($cs.Status -eq 'Expiring')
                $st = switch ($cs.Status) { 'Valid' { 'Pass' } 'Expiring' { 'Warn' } default { 'Fail' } }
                & $add 'Sign-in' 'Certificate' $st $cs.Message
                if ($st -eq 'Fail') { $cert.Dispose(); $cert = $null }
            }
            catch { & $add 'Sign-in' 'Certificate' 'Fail' $_.Exception.Message }
        }

        # --- Network --------------------------------------------------------
        $networkOk = $true
        foreach ($n in (Test-RingNetwork -Settings $Settings -NoThrow)) {
            $via = if ($n.Proxy) { "via proxy $($n.Proxy)" } else { 'direct' }
            if ($n.Reachable) { & $add 'Network' $n.Endpoint 'Pass' "$($n.Host): HTTP $($n.StatusCode) in $($n.Milliseconds) ms, $via." }
            elseif ($n.Required) { & $add 'Network' $n.Endpoint 'Fail' "$($n.Host): $($n.Error), $via."; $networkOk = $false }
            else { & $add 'Network' $n.Endpoint 'Warn' "$($n.Host): $($n.Error), $via. Optional: the run still works, but this channel would fail." }
        }

        # --- Sign-in --------------------------------------------------------
        $canConnect = $moduleOk -and $networkOk -and -not ($Settings.AuthMode -eq 'Certificate' -and -not $cert)
        if ($canConnect) {
            try {
                $connectedHere = Connect-RingGraph -Settings $Settings -Certificate $cert
                $ctx = Get-MgContext
                $who = if ($ctx -and $ctx.PSObject.Properties['Account'] -and $ctx.Account) { "account $($ctx.Account)" }
                       elseif ($ctx -and $ctx.PSObject.Properties['ClientId'] -and $ctx.ClientId) { "app $($ctx.ClientId)" } else { 'existing session' }
                $tenant = if ($ctx -and $ctx.PSObject.Properties['TenantId'] -and $ctx.TenantId) { " in tenant $($ctx.TenantId)" } else { '' }
                & $add 'Sign-in' 'Microsoft Graph' 'Pass' "Signed in as $who$tenant ($($Settings.GraphEnvironment))"
                $signedIn = $true
            }
            catch { & $add 'Sign-in' 'Microsoft Graph' 'Fail' (Get-RingExceptionChain $_.Exception) }
        }
        else { & $add 'Sign-in' 'Microsoft Graph' 'Skip' 'Not attempted: fix the failures above first.' }

        if ($signedIn) {
            # --- Permissions ------------------------------------------------
            $missing = Get-RingMissingPermission -Settings $Settings
            if ($null -eq $missing) { & $add 'Permissions' 'Graph permissions' 'Warn' 'The token does not list its permissions; the checks below show what works.' }
            elseif ($missing.Count) { & $add 'Permissions' 'Graph permissions' 'Fail' "Missing: $($missing -join '; ')" }
            else {
                $required = Get-RingRequiredScopes -Settings $Settings
                & $add 'Permissions' 'Graph permissions' 'Pass' ("Present: " + (@($required | Where-Object { $_ -ne 'Mail.Send' }) -join ', '))
            }

            # --- Reading users ----------------------------------------------
            $sel = 'id,userPrincipalName,accountEnabled,employeeType'
            if ($Settings.NeedsSignInActivity) { $sel += ',signInActivity' }
            try {
                $page = Invoke-RingGraphRequest -Method GET -Uri "$($script:GraphApi)/users?`$select=$sel&`$top=1" -Purpose 'checking that users can be read'
                $extra = if ($Settings.NeedsSignInActivity) { ', including sign-in activity' } else { '' }
                & $add 'Directory' 'Read users' 'Pass' "Users can be read$extra."
            }
            catch {
                & $add 'Directory' 'Read users' 'Fail' $_.Exception.Message
            }

            # --- Ring groups ------------------------------------------------
            $keys = @('First') + @($Settings.RingKeys) + @('Last') + $(if ($Settings.EnableInactiveRing) { @('Inactive') } else { @() })
            foreach ($k in $keys) {
                $name = Get-RingGroupName -Base $Settings.GroupNameBase -Key $k
                try {
                    $g = Find-RingGroup -DisplayName $name -Marker (Get-RingMarker -Base $Settings.GroupNameBase -Key $k)
                    if ($g) {
                        $n = (Get-RingGroupUserMembers -GroupId $g.Id -GroupName $g.DisplayName).Count
                        & $add 'Groups' $name 'Pass' "Found ($($g.Id)), $n user member(s)."
                    }
                    elseif ($Settings.CreateMissingGroups) { & $add 'Groups' $name 'Warn' 'Missing; a run with -CreateMissingGroups will create it.' }
                    else { & $add 'Groups' $name 'Fail' 'Missing. A run would stop. Check GroupNameBase, or create the groups once with -CreateGroupsOnly.' }
                }
                catch { & $add 'Groups' $name 'Fail' $_.Exception.Message }
            }
            try {
                foreach ($o in (Find-OrphanRingGroups -Settings $Settings).Values) {
                    $n = (Get-RingGroupUserMembers -GroupId $o.Id -GroupName $o.DisplayName).Count
                    if ($n -eq 0) { & $add 'Groups' $o.DisplayName 'Warn' "Above RingCount and empty; no longer managed. Remove its assignments and delete it." }
                    elseif ($Settings.RetireOrphanRings) { & $add 'Groups' $o.DisplayName 'Warn' "Above RingCount with $n member(s); -RetireOrphanRings will empty it." }
                    else { & $add 'Groups' $o.DisplayName 'Fail' "Above RingCount with $n member(s). A run would stop until -RetireOrphanRings is used." }
                }
            }
            catch { & $add 'Groups' 'Retired rings' 'Fail' $_.Exception.Message }
            & $add 'Groups' 'Change membership' 'Skip' 'Not tested: proving write access would change a group. The granted permission is checked above.'

            # --- Exclusion groups -------------------------------------------
            if ($Settings.ExcludeGroupIds.Count -eq 0) { & $add 'Scope' 'Exclusion groups' 'Skip' 'None configured.' }
            foreach ($gid in $Settings.ExcludeGroupIds) {
                try {
                    $eg = Resolve-RingExclusionGroup -GroupId $gid
                    & $add 'Scope' "Exclusion group $($eg.DisplayName)" 'Pass' "$gid, $($eg.Members.Count) user(s) excluded."
                }
                catch { & $add 'Scope' "Exclusion group $gid" 'Fail' $_.Exception.Message }
            }
        }

        # --- Report folder --------------------------------------------------
        if ($Settings.SkipReport) { & $add 'Reports' 'Report folder' 'Skip' 'SkipReport is set.' }
        else {
            try {
                if (-not (Test-Path -LiteralPath $Settings.ReportDirectory)) { New-Item -ItemType Directory -Path $Settings.ReportDirectory -Force -WhatIf:$false -Confirm:$false | Out-Null }
                $probe = Join-Path $Settings.ReportDirectory ".preflight-$runId.tmp"
                Set-Content -LiteralPath $probe -Value 'preflight' -WhatIf:$false -Confirm:$false
                Remove-Item -LiteralPath $probe -Force -WhatIf:$false -Confirm:$false
                & $add 'Reports' 'Report folder' 'Pass' "Writable: $((Resolve-Path -LiteralPath $Settings.ReportDirectory).Path)"
            }
            catch { & $add 'Reports' 'Report folder' 'Fail' $_.Exception.Message }
        }
    }
    finally {
        $snapshot = {
            $summary.Checks = $checks.ToArray()
            $summary.Passed = @($checks | Where-Object Status -eq 'Pass').Count
            $summary.Warnings = @($checks | Where-Object Status -eq 'Warn').Count
            $summary.Failed = @($checks | Where-Object Status -eq 'Fail').Count
            $summary.Skipped = @($checks | Where-Object Status -eq 'Skip').Count
            $summary.Result = if ($summary.Failed) { 'PreflightFailed' } elseif ($summary.Warnings) { 'PreflightPassedWithWarnings' } else { 'PreflightPassed' }
        }

        # --- Log Analytics: one test record ---------------------------------
        if ($Settings.LogAnalyticsEnabled) {
            try {
                $token = Get-RingMonitorToken -Settings $Settings -Certificate $cert
                & $snapshot
                $rec = [pscustomobject][ordered]@{
                    TimeGenerated = [datetime]::UtcNow.ToString('o'); RunId = $runId; RecordType = 'Preflight'; RingSet = $Settings.GroupNameBase
                    Action = 'None'; UserId = $null; UserPrincipalName = $null; GroupName = $null; GroupId = $null; RingKey = $null
                    Reason = 'Preflight'; Result = $summary.Result; ErrorMessage = $null; IsWhatIf = $true; ScriptRevision = $script:ScriptRevision
                    Details = [pscustomobject]@{ Checks = $summary.Checks }
                }
                Send-RingLogAnalytics -Settings $Settings -Token $token -Records @($rec)
                & $add 'Notifications' 'Log Analytics' 'Pass' "Test record sent (RecordType = Preflight). It appears in EntraDeploymentRings_CL within a few minutes."
            }
            catch { & $add 'Notifications' 'Log Analytics' 'Fail' $_.Exception.Message }
        }
        else { & $add 'Notifications' 'Log Analytics' 'Skip' 'Not configured.' }

        # --- Teams: one test card -------------------------------------------
        if ($Settings.TeamsWebhookUrl) {
            try {
                & $snapshot
                Send-RingTeamsNotification -WebhookUrl $Settings.TeamsWebhookUrl -Payload (Get-RingPreflightTeamsPayload -Summary $summary)
                & $add 'Notifications' 'Teams' 'Pass' 'Test card posted. Check the channel.'
            }
            catch { & $add 'Notifications' 'Teams' 'Fail' $_.Exception.Message }
        }
        else { & $add 'Notifications' 'Teams' 'Skip' 'Not configured.' }

        # --- Email: one test message ----------------------------------------
        if ($Settings.EmailEnabled) {
            if (-not $signedIn) { & $add 'Notifications' 'Email' 'Fail' 'Not sent: email goes through Microsoft Graph, and sign-in failed.' }
            else {
                try {
                    & $snapshot
                    $m = Get-RingPreflightEmailMessage -Summary $summary
                    Send-RingEmailNotification -From $Settings.EmailFrom -To $Settings.EmailTo -Subject $m.Subject -Html $m.Html
                    & $add 'Notifications' 'Email' 'Pass' "Test email sent from $($Settings.EmailFrom) to $($Settings.EmailTo.Count) recipient(s). Check the inbox."
                }
                catch { & $add 'Notifications' 'Email' 'Fail' $_.Exception.Message }
            }
        }
        else { & $add 'Notifications' 'Email' 'Skip' 'Not configured.' }

        if ($connectedHere) { try { Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null } catch { Write-RingLog -Level Verbose 'Disconnect-MgGraph failed.' } }
        if ($cert) { $cert.Dispose() }
        & $snapshot
        $end = [datetime]::UtcNow
        $summary.EndTime = $end.ToString('o')
        $summary.DurationSeconds = [math]::Round(($end - $start).TotalSeconds, 1)
    }

    foreach ($c in $summary.Checks) {
        $line = '[{0}] {1}: {2} - {3}' -f $c.Status.ToUpperInvariant(), $c.Area, $c.Check, $c.Detail
        if ($c.Status -eq 'Fail') { Write-RingLog -Level Warning $line } else { Write-RingLog $line }
    }
    Write-RingLog "Preflight finished: $($summary.Result) ($($summary.Passed) passed, $($summary.Warnings) warning(s), $($summary.Failed) failed, $($summary.Skipped) skipped)."
    if ($summary.Failed) { Write-Error "Preflight found $($summary.Failed) problem(s). See the checks marked FAIL." -ErrorAction Continue }
    $summary
}

#endregion

#region ---------- Entry point -----------------------------------------------

# Dot-sourcing (for example from Pester) loads the functions only.
if ($MyInvocation.InvocationName -eq '.') { return }

# Precedence: command line > configuration file > parameter defaults.
$commonParams = @([System.Management.Automation.PSCmdlet]::CommonParameters) + @([System.Management.Automation.PSCmdlet]::OptionalCommonParameters)
$paramNames = @($MyInvocation.MyCommand.Parameters.Keys | Where-Object { $_ -notin $commonParams })

$values = @{}
$defaults = @{}
foreach ($n in $paramNames) {
    $v = Get-Variable -Name $n -ValueOnly -ErrorAction SilentlyContinue
    if ($v -is [System.Management.Automation.SwitchParameter]) { $v = $v.IsPresent }
    if ($PSBoundParameters.ContainsKey($n)) { $values[$n] = $v }
    elseif ($null -ne $v -and -not ($v -is [string] -and $v -eq '')) { $defaults[$n] = $v }
}

if ($ConfigPath) {
    $fileValues = Read-RingConfigFile -Path $ConfigPath -AllowedNames ($paramNames | Where-Object { $_ -notin 'ConfigPath', 'ClientSecret', 'Rebalance', 'InitialRun', 'Preflight', 'CreateGroupsOnly' })
    foreach ($k in $fileValues.Keys) { if (-not $values.ContainsKey($k)) { $values[$k] = $fileValues[$k] } }
}
foreach ($k in $defaults.Keys) { if (-not $values.ContainsKey($k)) { $values[$k] = $defaults[$k] } }

$settings = ConvertTo-RingSettings -Values $values
if ($settings.Preflight) { Invoke-RingPreflight -Settings $settings }
else { Invoke-DeploymentRingSync -Settings $settings }

#endregion
