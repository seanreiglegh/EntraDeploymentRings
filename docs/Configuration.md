# Configuration

- [How users are placed](#how-users-are-placed)
- [The Inactive ring](#the-inactive-ring)
- [Who is in scope](#who-is-in-scope)
- [The groups](#the-groups)
- [Configuration file](#configuration-file)
- [Sign-in options](#sign-in-options)
- [Teams notifications](#teams-notifications)
- [Email notifications](#email-notifications)
- [Preflight checks](#preflight-checks)
- [Certificate expiry](#certificate-expiry)
- [All parameters](#all-parameters)

---

## How users are placed

### One group per user

When a user qualifies for more than one group, the first match wins:

1. **Inactive**: they match an inactivity rule
2. **Last**: an admin put them there (nested groups count)
3. **First**: an admin put them there (nested groups count)
4. **A computed ring** (Ring01…RingNN)

### Ring sizes

`RingWeights` are **percentages that must add up to 100**, one per ring. For example, `1,5,15,30,49` for five rings. Small rounding is fine: `33.33,33.33,33.34` works. Leave `RingWeights` out to split the rings evenly.

### Users keep their ring

A user already in a computed ring **stays there on every run**. Only users without a ring are placed: new users, users coming back from Inactive, and users an admin removed from First or Last. `AssignmentMode` decides where those users go:

| Mode | How a user is placed | Good | Trade-off |
|---|---|---|---|
| `Hash` (default) | A hash of the user's ID picks the ring by weight | The same user always gets the same ring, so someone returning from Inactive goes back where they were | Ring sizes drift a little from target over time |
| `Balance` | Goes to the ring furthest below its target | Sizes stay close to target | A returning user may land in a different ring |

### Re-sorting everyone

Changing `RingWeights` or `RingCount` **does not move existing users**. To re-sort everyone, run once with `-Rebalance`:

```powershell
./Invoke-EntraDeploymentRings.ps1 -ConfigPath ./config/prod.json -Rebalance -WhatIf   # review the CSV
./Invoke-EntraDeploymentRings.ps1 -ConfigPath ./config/prod.json -Rebalance
```

- `-InitialRun` does the same thing. It's just labelled `InitialRun` in the report, which reads better for a first run.
- Both **skip the 10% change limit**, so always preview with `-WhatIf`.
- Inactive, Last and First still take priority.
- Both work **on the command line only**. A config file containing either one is rejected, so a scheduled job can't re-sort everyone every day.
- Add `-AssignmentMode Balance` for ring sizes that match the weights exactly.

### Fewer rings

If you lower `RingCount`, the run stops until you add `-RetireOrphanRings`. That empties the extra ring groups and re-places their members. It doesn't delete the groups. After that, normal runs continue and log a warning that the empty groups can be deleted. If someone adds members back to a retired group, the run stops again.

---

## The Inactive ring

A user is inactive if **any** rule matches:

| Rule | Setting | Default | Turn off with |
|---|---|---|---|
| Account is disabled | `DisabledUserAction` | `Inactive` | `Exclude` (keeps disabled users out of every group instead) |
| Employee type matches a pattern | `InactiveEmployeeTypes` | `Former` | `[]` (empty) |
| No successful sign-in for N days | `InactiveSignInDays` | `90` | `0` |
| Company name matches a pattern | `InactiveCompanyNames` | `Former` | `[]` (empty) |
| UPN matches a pattern | `InactiveUpnPatterns` | none | `[]` (empty) |

### Inactive vs. excluded by UPN

There are two UPN pattern lists, and they do different things:

| Setting | A matching user… | Typical use |
|---|---|---|
| `InactiveUpnPatterns` | goes into the **Inactive** group | Renamed departed users, for example `{user}.former@{domain}` |
| `ExcludeUpnPatterns` | is kept out of **every** group | Service and admin accounts, for example `SVC-{user}@{domain}` |

```json
"InactiveUpnPatterns": ["{user}.former@{domain}"],
"ExcludeUpnPatterns":  ["SVC-{user}@{domain}", "adm-{user}@{domain}"]
```

| UPN | Result |
|---|---|
| `jane.doe.former@contoso.com` | Inactive (`Inactive:UpnPattern:{user}.former@{domain}`) |
| `svc-backup@contoso.com` | Excluded (`OutOfScope:UpnPattern:SVC-{user}@{domain}`) |
| `jane.formerly@contoso.com` | Neither: normal ring |

- Both lists use the same pattern syntax ([UPN patterns](#upn-patterns)).
- If a UPN matches **both** lists, exclusion wins. The script warns at start-up if the same pattern is in both.
- A `.former` user still has to be in scope to reach Inactive. Disabling the account, or setting `employeeType` to `Former`, still counts as in scope: both go to Inactive. Clearing `employeeType` to empty does not; the user is *excluded* instead.

- **Offboarded accounts** (`employeeType` = `Former`) go to Inactive with reason `Inactive:EmployeeType:Former`, even though `Former` isn't in `IncludeEmployeeTypes`. Add other values your HR process uses, for example `["Former", "Terminated", "Leaver*"]`.
  - Matching ignores case and accepts wildcards.
  - UPN and group exclusions still win.
  - With the Inactive ring off, these users are excluded.
- **Disabled accounts** go to Inactive with reason `Inactive:Disabled`, whatever their sign-in history. Re-enable the account and the user returns to their old ring.
  - They must still pass the other scope rules: user type, employee type, license and exclusions.
  - With `DisabledUserAction = Exclude`, disabled users are kept out of every group instead, and Graph doesn't return them at all.
  - If `EnableInactiveRing` is off, disabled users are always excluded. They're never placed in a computed ring.
- The sign-in rule uses the **last successful** sign-in. Failed attempts don't count, so an account under a password-spray attack doesn't look active.
- Accounts that have never signed in get `NewUserGraceDays` (default `30`) after creation before they count as inactive.
- Company-name patterns ignore case and accept wildcards, for example `Former*`.
- When a user becomes active again, they leave Inactive automatically. In Hash mode they go back to their old ring.
- To turn off the Inactive ring completely: `EnableInactiveRing = false`.

---

## Who is in scope

Users who fail any rule are kept out of every group (and removed if they were in one). The report records why.

| Rule | Setting | Default |
|---|---|---|
| Disabled account | `DisabledUserAction` | `Inactive`: disabled users stay in scope and go to Inactive. `Exclude` keeps them out. |
| User type | `IncludeUserTypes` | `Member` (no guests) |
| Employee type | `IncludeEmployeeTypes` | `Employee`, `Contingent Worker` (`[]` = any). Values in `InactiveEmployeeTypes` (default `Former`) are also in scope, and go to Inactive. |
| Has a license | `RequireAssignedLicense` | `false` |
| Not in an exclusion group | `ExcludeGroupIds` | none |
| UPN doesn't match a pattern | `ExcludeUpnPatterns` | none |

### UPN patterns

Patterns must match the **whole** UPN. Case doesn't matter.

| Token | Matches |
|---|---|
| `{user}` | one or more characters, no `@` |
| `{domain}` | one or more characters, no `@` |
| `*` | anything, including nothing |
| `?` | exactly one character |

| Pattern | Excludes | Doesn't exclude |
|---|---|---|
| `{user}.former@{domain}` | `jane.doe.former@contoso.com` | `jane.formerly@contoso.com` |
| `SVC-{user}@{domain}` | `svc-backup@contoso.com` | `jsvc-backup@contoso.com` |
| `admin-{user}@contoso.com` | `admin-jo@contoso.com` | `admin-jo@fabrikam.com` |
| `*#EXT#@*` | Guest-style UPNs | |

A typo such as `{usr}` stops the run at start-up instead of silently matching nothing.

### Excluded users in First or Last

First and Last are managed by hand, so the script never removes anyone from them. That includes users who are out of scope, such as a service account someone added to First. Such users are **reported** as `ExcludedUserInManualRing` conflicts, naming the group and the reason, for example `UpnPattern:SVC-{user}@{domain}`. Remove them by hand if that isn't intended. To stop the reports, set `ReportExcludedInManualRings` to `false`.

A missing exclusion group stops the run, with an error naming the group ID and `ExcludeGroupIds`. Without the group, its members would be placed in rings. Exclusion groups that do exist are logged by name with their member count.

---

## The groups

**Names:** `{GroupNameBase}-First`, `-Ring01` … `-RingNN`, `-Last`, `-Inactive`. They're cloud-only security groups with assigned membership.

**Creating them is opt-in.** Groups are only created with `-CreateGroupsOnly` or `-CreateMissingGroups`. Without one of them, a missing group stops the run before anything changes.

- **`-CreateGroupsOnly`** creates the missing groups and stops.
  - It reads no users, changes no membership, and the change limit doesn't apply.
  - Groups that already exist are checked (marker, cloud-only, security, assigned membership) and left alone, so running it twice is safe.
  - It needs only group permissions: `Group.Create` plus `GroupMember.ReadWrite.All` for an app (never `Group.ReadWrite.All`), or `Group.ReadWrite.All` for your own sign-in. See [Setup](Setup.md#creating-the-groups-use-groupcreate).
  - Use it to create the rings, assign policies to them while they're empty, then fill them with `-InitialRun`. It's also how to add a ring after raising `RingCount`.
- **`-CreateMissingGroups`** creates the missing groups as part of a normal run, then carries on and fills them.

**Why it's opt-in.** It means a typo in `GroupNameBase` can't create a stray set, and a deleted group isn't silently recreated empty.

**Each group carries a marker** in its description, for example `[EntraDeploymentRings:SG-Deploy-Users:Ring02]`.
- The script refuses to touch a group with the right name but no marker.
- To adopt an existing group, add the marker to its description.

**Only user members count.** Devices or nested groups inside a ring group are left alone.

---

## Configuration file

Copy `config/EntraDeploymentRings.sample.json`, or one of the ready-made examples, and pass it with `-ConfigPath`.

| File | What it is |
|---|---|
| `config/EntraDeploymentRings.sample.json` | Every common setting, with defaults. `AuthMode` is `Interactive`; **change it for scheduled runs**. |
| `config/examples/healthcare.json` | 6 rings, IT pilot first, clinical-critical last, certificate auth, tight change limit, 180-day report retention |
| `config/examples/small-org.json` | 3 equal rings, no Inactive ring (no Entra ID P1/P2 needed), every employee type |
| `config/examples/single-department.json` | A second ring set for one department, in Balance mode |
| `config/EntraDeploymentRings.schema.json` | JSON schema for all of the above |

**Editor validation.** Each file starts with a `"$schema"` line that points at the bundled schema. VS Code and other JSON-schema-aware editors then:
- autocomplete every key, with its description
- flag unknown or misspelled keys, wrong types and invalid values
- flag missing companions (for example `Certificate` auth without a thumbprint, or `EmailTo` without `EmailFrom`)
- flag keys that aren't allowed in a file (`ClientSecret`, `Rebalance`, `InitialRun`)

The script ignores the `$schema` key. Keep the line pointing at the schema's location relative to your file: `./EntraDeploymentRings.schema.json` in `config/`, or `../EntraDeploymentRings.schema.json` one folder down.

**Validate from PowerShell** (7.4 or later):

```powershell
Test-Json -Path ./config/prod.json -SchemaFile ./config/EntraDeploymentRings.schema.json
```

The schema can't check everything. The script still checks, at start-up, that `RingWeights` adds up to 100 and has one value per ring, and that UPN patterns are valid.

**Rules:**

- Keys are the parameter names. Command-line values override the file.
- Keys starting with `_` or `$` are ignored, so you can use them for comments.
- **Not allowed in the file:** `ClientSecret`, `Rebalance`, `InitialRun`, `Preflight`, `CreateGroupsOnly`.
- `CreateMissingGroups` is allowed, but should normally stay `false`.
- An unknown key stops the run and lists the valid keys.

---

## Sign-in options

| `-AuthMode` | Use for | Also needs |
|---|---|---|
| `Interactive` (default) | Ad-hoc admin runs | Admin roles ([Setup](Setup.md#option-c-your-own-admin-account)) |
| `Certificate` | Scheduled runs | `TenantId`, `ClientId`, `CertificateThumbprint` ([Setup](Setup.md#option-a-app-registration-with-a-certificate)) |
| `ManagedIdentity` | Azure Automation, Functions, VMs | `ManagedIdentityClientId` if user-assigned ([Setup](Setup.md#option-b-managed-identity)) |
| `ClientSecret` | Last resort | `TenantId`, `ClientId`, `ClientSecret` (SecureString) |
| `ExistingConnection` | Reusing your own `Connect-MgGraph` session | — |

Government and China clouds: `-GraphEnvironment USGov | USGovDoD | China`.

---

## Teams notifications

Post a card to a Microsoft Teams channel when a run fails, is blocked, or completes with errors. Successful runs can be included if you want them.

**1. Create the webhook in Teams.**
1. In the channel, open **Workflows**.
2. Choose the template **"Send webhook alerts to a channel"** (also listed as *When a Teams webhook request is received*).
3. Pick the team and channel, then copy the URL it gives you.

> Office 365 connector webhooks (`…webhook.office.com…`) were retired by Microsoft in 2026 and won't work. Use a **Workflows** URL.

**2. Pass it to the script:**

```powershell
./Invoke-EntraDeploymentRings.ps1 -ConfigPath ./config/prod.json -TeamsWebhookUrl $env:EDR_TEAMS_WEBHOOK
```

| `TeamsNotifyOn` value | Sends a card when… | Default |
|---|---|---|
| `Failed` | the run stopped on an error | ✔ |
| `BlockedByChangeLimit` | the change limit stopped the run | ✔ |
| `CompletedWithErrors` | the run finished, but some changes failed | ✔ |
| `CertificateExpiring` | the sign-in certificate expires within `CertificateExpiryWarningDays`, **even if the run succeeded** | ✔ |
| `Success` | the run finished cleanly | |
| `WhatIf` | a preview ran. Previews never notify unless this is listed. | |

**What the card shows:** the result, any error message, add and remove counts, conflicts, users in scope, the change-limit numbers, the top change reasons, ring sizes, the report path, the run ID and the host name. It contains **no user names or IDs**, so nothing personal lands in the channel.

**Good to know:**
- **Treat the URL as a secret.** Anyone who has it can post to the channel. The script never writes it to logs or reports. Keep it in an environment variable, Key Vault or an Automation variable rather than in a shared config file. If it leaks, delete and recreate the workflow.
- **A failed notification never fails the run.** It logs a warning, and the summary records `Notification = Failed`.
- **Configuration errors can't be notified,** for example an unknown config key, because the script stops before it has read the webhook URL. Your scheduler (a failed task or job) catches those.
- **Network access.** The runner needs outbound HTTPS to the workflow URL's host.

---

## Email notifications

Send an HTML summary by email for the same run results as Teams. Use either one, or both.

```powershell
./Invoke-EntraDeploymentRings.ps1 -ConfigPath ./config/prod.json `
    -EmailTo 'it-ops@contoso.com', 'secops@contoso.com' -EmailFrom 'deployment-rings@contoso.com'
```

| Setting | Default | Meaning |
|---|---|---|
| `EmailTo` | — | One or more recipients. Setting this turns email on. |
| `EmailFrom` | — | The mailbox it's sent from. Required. A **shared mailbox** works well, and needs no license. |
| `EmailNotifyOn` | `Failed`, `BlockedByChangeLimit`, `CompletedWithErrors`, `CertificateExpiring` | Same values as `TeamsNotifyOn` |

**How it's sent.** Through Microsoft Graph (`sendMail`), using the script's own identity. No SMTP server, no stored mail password, and no extra module. It isn't saved to Sent Items.

**What the email contains:** the same as the Teams card (result, counts, top reasons, ring sizes and the report path), with **no user names or IDs**. The report is **not attached**, because it contains UPNs.

**Permission.** The identity needs **`Mail.Send`**.
- As an *application* permission, `Mail.Send` can send as **any mailbox in your tenant**. Don't grant it tenant-wide; scope it to the one sender mailbox with **Exchange Online RBAC for Applications**. Steps are in [Security.md](Security.md#scope-mailsend-to-one-mailbox).
- Interactive runs ask for the delegated `Mail.Send` scope. To send from a shared mailbox you need *Send As* rights on it.

**Good to know:**
- **Email depends on the run's own Graph sign-in.**
  - **What email can't report:** a run that fails *before* signing in, for example on an expired certificate. That run has nothing to send from, and the summary records `EmailNotification = Failed`.
  - **What email still covers:** the 30-day certificate warning before expiry, because the certificate still works then. Only the failure on the day it expires needs Teams.
  - **Email never borrows another session.** It's never sent through a Graph session left in the same PowerShell window by someone else.
- **A failed email never fails the run.** It logs a warning with a hint: a 403 means a permission or scope problem, and a 404 means the sender mailbox wasn't found.
- **Configuration errors can't be notified,** as with Teams.

---

## Preflight checks

`-Preflight` checks that a run would work, **without planning or changing anything**:

```powershell
./Invoke-EntraDeploymentRings.ps1 -ConfigPath ./config/prod.json -Preflight
```

| Area | What's checked |
|---|---|
| Configuration, runtime | Settings are valid; PowerShell and `Microsoft.Graph.Authentication` versions |
| Sign-in | Certificate found, has a private key, and how long until it expires; signing in to Microsoft Graph |
| Permissions | The token has the permissions this configuration needs |
| Directory | Users can be read, including sign-in activity when the sign-in rule is on (needs Entra ID P1/P2) |
| Groups | Every ring group exists and carries its marker; retired rings above `RingCount` |
| Scope | Every exclusion group in `ExcludeGroupIds` exists, by name and member count |
| Reports | The report folder is writable |
| Notifications | Sends **one test record** to Log Analytics, **one test card** to Teams and **one test email**, for whichever are configured |

Each check is **Pass**, **Warn**, **Fail** or **Skip**. The result is `PreflightPassed`, `PreflightPassedWithWarnings` or `PreflightFailed`; a failure also writes an error, so a script or scheduler sees it.
- **Not tested: changing group membership.** The only way to prove that would be to change a group. The granted permission is checked instead.
- **Command line only.** In a config file, a scheduled job would only ever check and never apply.

Run it before the first run, after renewing the certificate, after changing permissions, and after moving the job to a new machine.

## Certificate expiry

With `-AuthMode Certificate`, every run checks the certificate before signing in:

| Certificate | What happens |
|---|---|
| Valid for more than `CertificateExpiryWarningDays` (30) | Nothing |
| Expires within that window | The run continues. It logs a warning, sets `CertificateWarning` in the summary, and notifies Teams and email (`CertificateExpiring`, on by default), **even when the run succeeded**. |
| Expired, or not valid yet | The run stops before sign-in, with a message saying how to renew. A `Failed` notification goes to Teams. Email can't be sent, because the run never signed in. The warnings during the previous 30 days did go out by email. |

If you list `TeamsNotifyOn` or `EmailNotifyOn` yourself, include `CertificateExpiring` to keep the warning. An explicit list replaces the default.

Secrets and managed identities aren't checked. The script can't read a secret's expiry without extra permissions, and managed identities don't expire.

---

## All parameters

### Rings

| Parameter | Default | What it does |
|---|---|---|
| `ConfigPath` | — | JSON configuration file; command-line values override it |
| `Preflight` | off | Check everything and send test notifications; plan and change nothing. Command line only. See [Preflight checks](#preflight-checks). |
| `GroupNameBase` | *(required)* | Prefix for every group name |
| `RingCount` | *(required)* | Number of computed rings (1–50), not counting First, Last and Inactive |
| `RingWeights` | equal split | Percentage per ring; must add up to 100 |
| `AssignmentMode` | `Hash` | `Hash` or `Balance`; see [above](#users-keep-their-ring) |
| `HashSeed` | `GroupNameBase` | Changing it changes where *new* users land |
| `Rebalance` | off | Re-sort everyone once; skips the change limit; command line only |
| `InitialRun` | off | Same as `Rebalance`, with a different report label |
| `CreateGroupsOnly` | off | Create any missing ring group, then stop: no users read, no membership changed. Needs only group permissions: `Group.Create` for an app, `Group.ReadWrite.All` for your own sign-in. Can't be combined with `Rebalance`, `InitialRun`, `Preflight` or `RetireOrphanRings`. Command line only. |
| `CreateMissingGroups` | off | Create any missing ring group, then carry on with the normal run |
| `RetireOrphanRings` | off | Empty ring groups above `RingCount` after you reduce it |

### Inactive ring

| Parameter | Default | What it does |
|---|---|---|
| `EnableInactiveRing` | `true` | Manage the Inactive group |
| `InactiveSignInDays` | `90` | Days without a successful sign-in; `0` = rule off |
| `NewUserGraceDays` | `30` | Grace period for accounts that never signed in |
| `InactiveCompanyNames` | `Former` | Company-name patterns; empty = rule off |
| `InactiveEmployeeTypes` | `Former` | Employee-type patterns that put a user in Inactive (they stay in scope); empty = rule off |
| `InactiveUpnPatterns` | none | UPN patterns that make a user inactive (not excluded) |
| `RemoveInactiveFromManualRings` | off | Also remove inactive users from First/Last (direct members only) |
| `ReportExcludedInManualRings` | `true` | Report out-of-scope users found in First/Last as `ExcludedUserInManualRing` conflicts. They're never removed. |

### Scope

| Parameter | Default | What it does |
|---|---|---|
| `IncludeEmployeeTypes` | `Employee`, `Contingent Worker` | Allowed employee types; empty = any |
| `IncludeUserTypes` | `Member` | Allowed user types |
| `DisabledUserAction` | `Inactive` | `Inactive` = put disabled accounts in Inactive; `Exclude` = leave them out |
| `RequireAssignedLicense` | off | Leave out unlicensed users |
| `ExcludeGroupIds` | none | Group IDs whose members (including nested) are left out |
| `ExcludeUpnPatterns` | none | UPN patterns to leave out |

### Safety

| Parameter | Default | What it does |
|---|---|---|
| `MaxChangePercent` | `10` | Stop if changes exceed this % of current membership |
| `MaxChangeFloor` | `25` | …and also exceed this many changes |
| `BypassChangeLimit` | off | Apply the changes anyway |

### Sign-in

| Parameter | Default | What it does |
|---|---|---|
| `AuthMode` | `Interactive` | See [Sign-in options](#sign-in-options) |
| `TenantId`, `ClientId` | — | App-only sign-in |
| `CertificateThumbprint` | — | Certificate in CurrentUser\My or LocalMachine\My |
| `CertificateExpiryWarningDays` | `30` | Warn this many days before the certificate expires; `0` = off. An expired certificate always stops the run. |
| `ClientSecret` | — | SecureString; command line only |
| `ManagedIdentityClientId` | — | User-assigned managed identity |
| `GraphEnvironment` | `Global` | `Global`, `USGov`, `USGovDoD`, `China` |

### Reports and logging

| Parameter | Default | What it does |
|---|---|---|
| `ReportDirectory` | `./reports` | Where report files go |
| `ReportFormat` | `Both` | `Csv`, `Json` or `Both` |
| `ReportRetentionDays` | `0` (keep all) | Delete this ring set's reports older than N days |
| `SkipReport` | off | No report files |
| `LogIngestionEndpoint`, `LogDcrImmutableId` | — | Turn on Log Analytics ([guide](LogAnalytics.md)) |
| `LogStreamName` | `Custom-EntraDeploymentRings_CL` | DCR stream |
| `LogTokenAudience` | from `GraphEnvironment` | Azure Monitor token audience |

### Notifications

| Parameter | Default | What it does |
|---|---|---|
| `TeamsWebhookUrl` | — | Teams Workflows webhook URL. Treat it as a secret. |
| `TeamsNotifyOn` | `Failed`, `BlockedByChangeLimit`, `CompletedWithErrors`, `CertificateExpiring` | Run results that post a card; add `Success` or `WhatIf` if you want those too |
| `EmailTo` | — | Recipient addresses; turns email on |
| `EmailFrom` | — | Sender mailbox (required with `EmailTo`) |
| `EmailNotifyOn` | `Failed`, `BlockedByChangeLimit`, `CompletedWithErrors`, `CertificateExpiring` | Run results that send an email |
