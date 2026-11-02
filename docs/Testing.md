# Testing

This page covers what the test suite checks, how it works without a tenant, and what it **can't** tell you.

- **244 tests** in [`tests/Invoke-EntraDeploymentRings.Tests.ps1`](../tests/Invoke-EntraDeploymentRings.Tests.ps1), using Pester 5.
- **No tenant needed.** They run against an in-memory Microsoft Graph emulator, [`tests/FakeGraph.ps1`](../tests/FakeGraph.ps1).
- **CI runs them on Windows and Linux** for every pull request. They must pass before anything merges.

**Contents**
- [Run the tests](#run-the-tests)
- [What CI checks](#what-ci-checks)
- [How the tests work](#how-the-tests-work)
- [What the tests don't prove](#what-the-tests-dont-prove)
- [Safety controls and the tests that prove them](#safety-controls-and-the-tests-that-prove-them)
- [Test catalogue](#test-catalogue)
- [Adding a test](#adding-a-test)

---

## Run the tests

```powershell
Install-Module Pester -MinimumVersion 5.5 -Scope CurrentUser
Invoke-Pester -Path ./tests -Output Detailed
```

The full suite takes under a minute on a typical machine; CI runners, Windows especially, are slower. Most of the time goes on the end-to-end runs and the 20,000-user distribution check.

To run one area, filter by its `Describe` name:

```powershell
Invoke-Pester -Path ./tests -Output Detailed -FullNameFilter 'Get-RingPlan*'
```

Test names are shown on this page exactly as Pester prints them, so you can search for a failing test's name here.

---

## What CI checks

[`.github/workflows/ci.yml`](../.github/workflows/ci.yml) runs four required checks on every pull request. The `main` branch ruleset blocks merging until all four pass.

| Check | What it does |
|---|---|
| `test (ubuntu-latest)` | PSScriptAnalyzer (any Error or Warning fails the job), then all Pester tests. Results are uploaded as `pester-ubuntu-latest`. |
| `test (windows-latest)` | The same, on Windows. |
| `docs` | [`tools/Test-DocLinks.ps1`](../tools/Test-DocLinks.ps1) checks every relative link and `#anchor` in the Markdown files. |
| `bicep` | Builds and lints [`infra/loganalytics-dcr.bicep`](../infra/loganalytics-dcr.bicep). |

The release workflow runs the tests again before it publishes anything.

---

## How the tests work

The tests come in two layers.

### Unit tests

Most tests call one function directly, with users and group memberships built in memory. Examples are `Get-RingPlan`, `Get-InactiveReason`, `Test-ChangeThreshold` and `Get-RingTeamsPayload`.

- Time is pinned to **2026-10-25 12:00 UTC** (`$script:Now`), so the sign-in and grace-period rules give the same answer every day.
- Helper functions at the top of the test file build the inputs:

| Helper | Builds |
|---|---|
| `New-TestSettings` | Validated settings: `SG-Test`, 4 rings weighted `5,15,30,50`, `ExistingConnection` auth, change limit 10% with a floor of 25. Pass `-Override` to change any value. |
| `New-TestUser` | A user that is in scope by default: an enabled `Employee` member with one licence who signed in yesterday. Each parameter changes one attribute. |
| `New-EmptyMembers` | Empty membership for every group in the set. |
| `New-IdSet` | A case-insensitive set of IDs, for First, Last and exclusion-group membership. |

### End-to-end tests

The end-to-end tests run the real `Invoke-DeploymentRingSync`, the same code a scheduled job runs, against the emulator. This exercises the whole path: reading users, finding groups, planning, the change limit, `$batch` writes, reports and notifications.

`Initialize-FakeTenant` creates a fake tenant:
- **1,200 users by default,** with a fixed random seed so every run gets the same tenant. Employee types rotate through Employee (×3), Contingent Worker, Vendor and blank, so some users are always out of scope.
- **Six users with known edge cases**:

| UPN | Case | Expected outcome |
|---|---|---|
| `guest@` | Guest account | Out of scope |
| `disabled@` | Account disabled | Inactive |
| `former@` | Company name `Former` | Inactive |
| `stale@` | Last sign-in 200 days ago | Inactive |
| `neverold@` | Never signed in, created 100 days ago | Inactive |
| `nevernew@` | Never signed in, created 3 days ago | Placed in a ring (grace period) |

Many end-to-end tests change the tenant and then run the sync again: they rename a user, disable an account, or add someone to First. Tests in that block **run in order and build on each other**, so run the whole block when you debug one of them.

### The Graph emulator

`FakeGraph.ps1` defines its own `Invoke-MgGraphRequest`, `Get-MgContext` and `Disconnect-MgGraph`. These take the place of the real Graph SDK commands when the tests load the script. It answers only the calls the script makes:

| Call | Emulated behaviour |
|---|---|
| `GET users` | Returns only the `$select`ed properties. Honours `$filter=accountEnabled eq true`. |
| `GET groups` | `$filter` by `displayName eq` or `startswith(displayName, …)` |
| `GET groups/{id}`, `…/members`, `…/transitiveMembers` | Nested groups are expanded for transitive membership. Returns 404 for an unknown group. |
| `POST groups` | Creates the group |
| `POST $batch` | More than 20 requests returns 400. Supports `PATCH members@odata.bind` (up to 20 references), `POST members/$ref` and `DELETE members/{id}/$ref`, with Graph's real error codes for "already a member", "not a member" and "doesn't exist". |
| `POST users/{id}/sendMail` | Records the message in `$global:Fake.Mail`. Set `$global:Fake.MailFail = 403` to make it fail. |
| Paging | Results are split into pages of 100 with `@odata.nextLink` |
| Throttling | Add `"<METHOD> <url>"` to `$global:Fake.ThrottleOnce`, and that batch sub-request returns 429 with `Retry-After` once |
| Refused calls | Add a regex on `"<METHOD> <route>"` (no query string) to `$global:Fake.Deny`, for example `'^GET groups$'`. Matching calls, including `$batch` sub-requests, return 403 `Authorization_RequestDenied`. |
| Error bodies | Every emulated error ends with Graph's JSON error body, including a `request-id`, as the real SDK's errors do. |
| The network test | The script's network check asks the emulator instead of the network. Every host is reachable unless `$global:Fake.Network['<host>'] = @{ Error = '…'; Proxy = '…' }` says otherwise. `$global:Fake.Probes` lists the hosts checked, in order. |
| The session | `$global:Fake.Context` shapes what `Get-MgContext` returns: `AuthType` (`AppOnly` or `Delegated`), `Scopes`, `ClientId`, `TenantId`, `AppName`, `Account`. |

Any call the emulator doesn't recognise fails with `FakeUnsupported`, so an unexpected Graph call shows up as a failure instead of being silently ignored.

**Other external calls are replaced inside each test.** Teams and Log Analytics calls are captured by replacing `Invoke-RestMethod` in the test that needs them. `Connect-MgGraph`, `Get-RingCertificate` and `Get-AzAccessToken` are replaced the same way. Self-signed certificates are created in memory, never in a certificate store.

---

## What the tests don't prove

A passing suite shows that the script's logic is correct **against the emulator**. The emulator is a simplified copy of Graph, built from the documentation. The following are **not** tested, so they need a test-tenant run before production, and again after major changes:

| Gap | Why it matters |
|---|---|
| **Real permissions** | The emulator refuses only the calls a test tells it to (`Fake.Deny`), and reports only the scopes a test sets. Whether Microsoft Graph *really* refuses a call with a given permission set isn't tested, so the permission map behind the access-denied messages comes from Microsoft's documentation, not from a tenant. Exchange RBAC scoping for `Mail.Send` and role-assignable groups that refuse changes are only seen in a real tenant. **An example of what this misses:** an early version sent failure emails whenever *any* Graph session existed in the window, and the tests didn't catch it because the emulator always reported one. |
| **Real sign-in** | Interactive, ClientSecret and ManagedIdentity auth are never exercised. Certificate auth is tested only up to building and signing the JWT; it is never sent to Entra ID. Reading a certificate from the Windows or Linux certificate store isn't tested. |
| **Replication delay** | Real Graph can take a few seconds to make a newly created group or membership readable, and the emulator is instant. The first run, which creates the groups, is most exposed to this. |
| **Throttling and outages at scale** | Only one 429 on one batch sub-request is tested. Repeated 429s, 5xx errors and throttling of whole requests outside `$batch` are not. |
| **Sign-in data** | The emulator always returns `signInActivity`. In a real tenant it needs Entra ID P1/P2 and `AuditLog.Read.All`, and can lag by hours. |
| **Graph query details** | The emulator implements only the `$filter` forms the script uses. A typo in a real filter string would pass here. |
| **Log Analytics ingestion** | Only the preflight test record is checked (one call to the ingestion endpoint, with the right `RecordType`). A full run's upload, the DCR schema and the table aren't. The `bicep` job checks only that the template builds. |
| **Scale** | The largest end-to-end tenant has 1,200 users. A 25,000-user run against the emulator is checked separately before each release: the first fill, then a second run that must change nothing, with every ring within 0.35 percentage points of its weight. It isn't part of the suite, because building that tenant ~40 times would make CI very slow. It says nothing about real Graph performance at that size. |
| **Teams and email rendering** | The payloads are checked for structure and content. How Teams or Outlook actually displays them isn't. |

**Recommended before production:** run `-Preflight`, then `-WhatIf`, then a live run against a test tenant (or a small test group set with `-GroupNameBase SG-Test-Deploy`). Check the CSV, the Teams or email message, and the Log Analytics rows.

---

## Safety controls and the tests that prove them

These are the promises in the README's **Built-in safety** section, with the tests behind each one. Use this table as evidence that a control works, alongside [Security.md](Security.md#compliance-mapping).

| Control | Tests |
|---|---|
| **Users stay in their ring** between runs | `keeps users in their current ring even when the hash says otherwise (sticky)`; `keeps a manually relocated user where they are (sticky)`; `places only new users and leaves existing users alone`; `InitialRun re-seeds a skewed ring set…` (a normal run leaves the skew alone) |
| **Every in-scope user is in exactly one ring** | `puts every in-scope user in exactly one ring`; `creates all groups and places every in-scope user in exactly one ring`; `resolves duplicate computed-ring membership to a single ring` |
| **Change-limit circuit breaker** | All of `Test-ChangeThreshold`; `trips the circuit breaker and changes nothing when too many users vanish`; `posts to Teams when a run is blocked, and records it in the JSON` |
| **Preview changes nothing** | `previews the first run with -WhatIf without creating anything`; the Preflight tests (no groups created, no membership changed) |
| **Groups are created only when asked** | `stops before changing anything when groups are missing and creation is not allowed`; `does not create the rest of the set when only some groups exist` |
| **`-CreateGroupsOnly` reads no users and changes no membership** | `creates every ring group with nothing but group permissions, reads no users and adds no members`; `leaves existing groups and their members alone, and the next normal run fills the rings`; `still refuses a same-named group without the marker` |
| **Never touches groups it didn't create** | `stamps the marker tag on every group`; `refuses to manage a same-named group that lacks the marker`; `rejects marker characters in the base name` |
| **First and Last are never edited by default** | `never touches First or Last membership by default`; `reports an excluded user in First with the group name, and never removes them` |
| **Reducing the ring count is safe** | `stops when RingCount is reduced, and retires the orphan ring on request`; `keeps running normally after an orphan ring was emptied`; `still stops when an orphan ring regains members` |
| **No secrets in logs or reports** | `keeps the run successful when Teams fails, and never logs the URL`; `reads a configuration file and rejects unknown keys and secrets`; `rejects a client secret` |
| **Notifications carry counts only** | `builds a Workflows-compatible Adaptive Card with counts only`; `HTML-encodes everything and contains no user data`; `sends one test message per configured channel, with no user data` |
| **Email only uses this run's own sign-in** | `never sends through a Graph session it did not open (expired certificate)` |
| **A blocked network stops the run before sign-in, with the reason** | All of `Network test` |
| **Permission errors say what's missing, and never name a user** | All of `Access-denied explanations` and `Access denied end to end` |
| **A notification failure doesn't fail the run** | `keeps the run successful when Teams fails…`; `keeps the run successful when sendMail is denied, with a helpful warning` |
| **Certificate expiry is reported before it breaks the job** | All of `Certificate expiry` and `Certificate expiry by email` |
| **The repository can't be changed without passing CI** | All of `GitHub rulesets` |

---

## Test catalogue

The tests are grouped by `Describe` block, in the order they run. A **data-driven** test runs once for each case listed with it (Pester `-ForEach`), and each case counts as one test.

| Area | Tests | Type |
|---|---:|---|
| [Ring weights](#ring-weights-get-normalizedweights) | 7 | Unit |
| [Hash ring assignment](#hash-ring-assignment) | 3 | Unit |
| [Inactive rules](#inactive-rules-get-inactivereason) | 15 | Unit |
| [Scope](#scope-test-ringuserinscope) | 13 | Unit |
| [UPN patterns](#upn-patterns-convertto-upnpatternregex) | 15 | Unit |
| [Exclusion reasons](#exclusion-reasons-get-ringscopeexclusion) | 3 | Unit |
| [Ring planning](#ring-planning-get-ringplan) | 23 | Unit |
| [Change limit](#change-limit-test-changethreshold) | 7 | Unit |
| [Configuration](#configuration) | 7 | Unit |
| [Reports](#reports) | 8 | Unit |
| [Teams notifications](#teams-notifications) | 15 | Unit |
| [Email notifications](#email-notifications) | 3 | Unit |
| [Configuration files and schema](#configuration-files-and-schema) | 17 | Repository |
| [Certificate expiry](#certificate-expiry) | 9 | Unit and end-to-end |
| [Certificate expiry by email](#certificate-expiry-by-email) | 2 | End-to-end |
| [Preflight](#preflight) | 6 | End-to-end |
| [GitHub rulesets](#github-rulesets) | 4 | Repository |
| [Client assertion](#client-assertion-get-ringclientassertion) | 1 | Unit |
| [Create groups only](#create-groups-only) | 14 | Unit and end-to-end |
| [Network test](#network-test) | 9 | Unit and end-to-end |
| [Access-denied explanations](#access-denied-explanations) | 21 | Unit |
| [Access denied end to end](#access-denied-end-to-end) | 3 | End-to-end |
| [End-to-end against emulated Graph](#end-to-end-against-emulated-graph) | 39 | End-to-end |
| **Total** | **244** | |

"Repository" tests check files in the repository (schema, sample configs, docs, rulesets and workflows) rather than script behaviour. They stop the files from drifting apart.

### Ring weights (`Get-NormalizedWeights`)

| Test | What it proves |
|---|---|
| returns equal weights when none are given | With no `RingWeights`, rings are split equally (4 rings → 25% each). |
| normalizes weights to sum to 1 | `1,5,15,30,49` becomes fractions that add up to exactly 1. |
| rejects a count mismatch | Supplying a different number of weights than `RingCount` is an error. |
| rejects weights that do not add up to 100 | `10,20,30` and `1,1,1,1` are rejected. |
| accepts rounding within 0.01 | `33.33, 33.33, 33.34` is accepted. |
| rejects bad weights when settings are built | The check also runs during settings validation, before anything connects. |
| rejects zero or negative weights | A ring weighted `0` is an error. |

### Hash ring assignment

| Test | What it proves |
|---|---|
| is deterministic and case-insensitive for the object ID | The same user always hashes to the same ring, however the GUID is cased. |
| returns a fraction in [0,1) | 200 random IDs all give a value from 0 up to, but not including, 1. |
| matches the weights within tolerance over 20,000 users | With 20,000 users, every ring is within 1.5 percentage points of its weight. |

### Inactive rules (`Get-InactiveReason`)

| Test | What it proves |
|---|---|
| flags company name Former (case-insensitive) | `former` matches `Former`, with reason `CompanyName:…`. |
| flags last successful sign-in older than the threshold | 91 days without sign-in gives `NoSignInFor90Days`. |
| does not flag a recent sign-in | 89 days is still active. |
| flags never-signed-in accounts older than the grace period | Never signed in and created 31 days ago gives `NeverSignedIn`. |
| gives new accounts a grace period | Never signed in and created 5 days ago is not flagged. |
| can disable the sign-in rule only | `InactiveSignInDays = 0` turns off the sign-in rule; the company rule still applies. |
| can disable the company rule only | An empty `InactiveCompanyNames` turns off the company rule. |
| supports wildcard company patterns | `Former*` matches `Former Employee`. |
| flags a UPN matching InactiveUpnPatterns | `Jane.Doe.Former@…` matches `{user}.former@{domain}`; `jane.formerly@…` doesn't. |
| validates InactiveUpnPatterns when settings are built | A misspelled placeholder such as `{usr}` is an error at start-up. |
| flags employeeType Former (case-insensitive) by default | Offboarded users (`employeeType` Former) go to Inactive. |
| reports Disabled first when an offboarded account is also disabled | When several rules match, `Disabled` is the reason reported. |
| flags disabled accounts first, regardless of sign-in | A disabled account is Inactive even if it signed in today. |
| does not flag disabled accounts with DisabledUserAction Exclude | With `Exclude`, disabled accounts are handled by scope instead. |
| returns nothing when the Inactive ring is disabled | `EnableInactiveRing = $false` turns off every inactive rule. |

### Scope (`Test-RingUserInScope`)

| Test | What it proves |
|---|---|
| includes Employee and Contingent Worker | The default scope, matched case-insensitively. |
| excludes other or empty employee types | `Vendor` and blank are out of scope. |
| keeps employeeType Former in scope (it goes to Inactive) | Offboarded users aren't dropped; they're kept so they can go to Inactive. |
| excludes employeeType Former when InactiveEmployeeTypes is empty | Without that rule, `Former` is simply an employee type that isn't in scope. |
| excludes employeeType Former when the Inactive ring is off | Same, when there is no Inactive ring. |
| lets a UPN exclusion win over employeeType Former | `SVC-…` accounts are excluded even if marked Former. |
| excludes guests | `userType` Guest is out of scope by default. |
| keeps disabled users in scope by default (they go to Inactive) | Default `DisabledUserAction = Inactive`. |
| excludes disabled users with DisabledUserAction Exclude | The opt-out works. |
| falls back to Exclude when the Inactive ring is off | Disabled users can't go to an Inactive ring that doesn't exist, so they're excluded. |
| honours exclusion groups | A member of an `ExcludeGroupIds` group is out of scope. |
| includes every employee type when the filter is empty | An empty `IncludeEmployeeTypes` means all types. |
| optionally requires a license | With `RequireAssignedLicense`, unlicensed users are out of scope. |

### UPN patterns (`ConvertTo-UpnPatternRegex`)

**Data-driven: "matches \<Upn\> against \<Pattern\> = \<Expected\>" (12 cases).**

| Pattern | UPN | Matches |
|---|---|---|
| `{user}.former@{domain}` | `john.smith.former@contoso.com` | Yes |
| `{user}.former@{domain}` | `JOHN.FORMER@CONTOSO.COM` | Yes (case-insensitive) |
| `{user}.former@{domain}` | `john.formerly@contoso.com` | No |
| `{user}.former@{domain}` | `.former@contoso.com` | No (`{user}` can't be empty) |
| `SVC-{user}@{domain}` | `svc-backup@contoso.com` | Yes |
| `SVC-{user}@{domain}` | `jsvc-backup@contoso.com` | No (anchored at the start) |
| `SVC-{user}@{domain}` | `svc-@contoso.com` | No |
| `admin-{user}@contoso.com` | `admin-jo@contoso.com` | Yes |
| `admin-{user}@contoso.com` | `admin-jo@fabrikam.com` | No (literal domain) |
| `*#EXT#@*` | `bob_x.com#EXT#@contoso.onmicrosoft.com` | Yes (`*` wildcard) |
| `test?@{domain}` | `test1@contoso.com` | Yes (`?` is one character) |
| `test?@{domain}` | `test12@contoso.com` | No |

| Test | What it proves |
|---|---|
| rejects unknown placeholders | `{usr}` is an error, not a literal. |
| rejects unbalanced braces | `{user@{domain}` is an error. |
| is validated when settings are built | Bad `ExcludeUpnPatterns` stop the script at start-up. |

### Exclusion reasons (`Get-RingScopeExclusion`)

| Test | What it proves |
|---|---|
| names the UPN pattern that excluded the user | The reason names the exact pattern that matched, for the report. |
| returns nothing for an in-scope user | No false reasons. |
| reports the first failing rule | Gives `EmployeeType:Vendor`, or `Disabled` under `Exclude`. A disabled user under the default action gets no exclusion reason, because they're in scope. |

### Ring planning (`Get-RingPlan`)

`Get-RingPlan` is the core of the script: it decides every add and remove.

| Test | What it proves |
|---|---|
| assigns new users to their hash ring | One add, to the hashed ring, with reason `NewAssignment`. |
| keeps users in their current ring even when the hash says otherwise (sticky) | No change for an existing member, even in the "wrong" ring. |
| removes a user from computed rings when they are in First | One remove, with reason `ManualRingOverride:First`. |
| gives Last precedence over First and reports the conflict | A user in both First and Last is treated as Last, and conflict `InFirstAndLast` is reported. |
| moves inactive users out of computed rings into Inactive | Removed with reason `MovedToInactive`, and added to Inactive. |
| gives Inactive precedence over First and reports the conflict | Conflict `InactiveUserInManualRing`. |
| removes inactive users from First when RemoveInactiveFromManualRings is set | The opt-in is the only way the script edits First. |
| returns a user from Inactive to their hash ring | Reasons are `NoLongerInactive` and `ReturnedFromInactive`; the user returns to their hashed ring. |
| removes out-of-scope members from managed groups | Users who left scope are removed with `OutOfScope`, including from Inactive. |
| never touches First or Last membership by default | No changes at all to the manual rings. |
| resolves duplicate computed-ring membership to a single ring | A user in two computed rings is removed from one, with `DuplicateRingMembership`. |
| fills the most under-target ring in Balance mode | 36 users at 25% each end up 9 per ring, even when Ring01 starts full. |
| moves users only when Rebalance is requested | With `Rebalance`, everyone moves to their hashed ring with reason `Rebalance`. |
| InitialRun re-places every computed user and labels the change InitialRun | `InitialRun` implies `Rebalance`, and changes are labelled `InitialRun`. |
| InitialRun still honours Inactive, First and Last | Precedence still applies during a re-seed. |
| puts a .former user in Inactive (not excluded) and lets exclusion win when both match | An `InactiveUpnPatterns` match goes to Inactive; when the same pattern is also in `ExcludeUpnPatterns`, exclusion wins. |
| labels removals with the exclusion reason when known | Shows `OutOfScope:UpnPattern:SVC-{user}@{domain}`, not just `OutOfScope`. |
| re-places members of retired orphan rings | When `RingCount` drops, members of the old ring are removed (`OrphanRingRetired`) and placed in a current ring. |
| reports an excluded user found in First, with the reason and group key | Conflict `ExcludedUserInManualRing` with UPN, `First` and the reason. Nothing is removed. |
| labels nested membership and users Graph did not return | For a Last member Graph didn't return, the detail says `NotReturnedByGraph` and mentions nested groups. |
| does not report excluded users in First/Last when the option is off | `ReportExcludedInManualRings = $false` turns this off. |
| does not report in-scope First members as excluded | No false conflicts. |
| puts every in-scope user in exactly one ring | 500 users, including Former users, 10 in First and 5 in Last: 500 placements, no gaps or duplicates. |

### Change limit (`Test-ChangeThreshold`)

Defaults: 10%, with a floor of 25 changes.

| Test | What it proves |
|---|---|
| allows the initial population | Empty rings (baseline 0) never block; reason `InitialPopulation`. |
| allows changes below the floor | 20 changes on 50 members is allowed, even though it's 40%. |
| allows changes within the percentage | 90 on 1,000 (9%) is allowed. |
| blocks changes above the percentage and floor | 200 on 1,000 (20%) is blocked. |
| is not enforced on a Rebalance | 900 on 1,000 is allowed, with reason `Rebalance`. |
| is not enforced on an InitialRun | Same, with reason `InitialRun`. |
| can be bypassed | `BypassChangeLimit` gives reason `Bypassed`. |

### Configuration

| Test | What it proves |
|---|---|
| requires GroupNameBase | Missing base name is an error. |
| requires a valid RingCount | `0` is an error. |
| rejects marker characters in the base name | `:` would break the ownership marker, so it's refused. |
| requires credentials for Certificate auth | `AuthMode Certificate` without a thumbprint is an error. |
| requires both Log Analytics values | An endpoint without a DCR ID is an error. |
| derives the Azure Monitor audience from the cloud | `GraphEnvironment USGov` uses `https://monitor.azure.us`. |
| reads a configuration file and rejects unknown keys and secrets | Keys are case-insensitive and `$schema`/`_comment` are ignored. Unknown keys are rejected. `InitialRun`, `Rebalance`, `Preflight` and `CreateGroupsOnly` are refused ("command line" / "never apply" / "never fill the rings"), and so is `ClientSecret`. |

### Reports

| Test | What it proves |
|---|---|
| plans \<Expected\> file(s) for format \<Format\> | Data-driven, 3 cases: `Csv` → 1 file, `Json` → 1, `Both` → 2. |
| plans no files with SkipReport | Nothing is written. |
| writes a header-only CSV when there are no changes | The file still has its header, so tools that import it don't break. |
| prunes only this ring set's expired reports | Deletes only expired files for *this* ring set (CSV and JSON). It leaves alone recent files, other ring sets (including `SG-Test-Other` and the prefix `SG`), unrelated files and look-alike names. Under `-WhatIf` it deletes nothing. |
| keeps everything when retention is 0 | `0` means keep forever. |
| validates the settings | Rejects `Xml` and `-1`; `json` is normalised to `Json`. |

### Teams notifications

| Test | What it proves |
|---|---|
| validates the webhook settings | Requires `https`; unknown `TeamsNotifyOn` values are rejected; the default list is `Failed, BlockedByChangeLimit, CompletedWithErrors, CertificateExpiring`. |
| decides when to notify: \<Result\> (WhatIf=\<WhatIf\>, NotifyOn=\<On\>) -> \<Expected\> | Data-driven, 8 cases, below. |
| never notifies without a webhook URL | No URL, no post. |
| builds a Workflows-compatible Adaptive Card with counts only | The message has the structure Teams Workflows expects. It shows counts by reason, and no UPN or object ID. |
| uses a distinct title for \<Result\> | Data-driven, 4 cases: `Run succeeded`, `Completed with errors`, `Run failed`, `Preview`. |

Notification decision cases:

| Result | Preview (`-WhatIf`) | `TeamsNotifyOn` | Notify? |
|---|---|---|---|
| Failed | No | default | Yes |
| BlockedByChangeLimit | No | default | Yes |
| CompletedWithErrors | No | default | Yes |
| Success | No | default | No |
| Success | No | `Success` | Yes |
| WhatIf | Yes | default | No |
| BlockedByChangeLimit | Yes | default | No (a preview is never alerted unless asked) |
| WhatIf | Yes | `WhatIf` | Yes |

### Email notifications

| Test | What it proves |
|---|---|
| validates the email settings | `EmailFrom` is required with `EmailTo`; addresses must be valid; unknown notify values are rejected; the default list matches Teams; `Mail.Send` is required only when email is configured. |
| decides email and Teams independently | `EmailNotifyOn` and `TeamsNotifyOn` don't affect each other. |
| HTML-encodes everything and contains no user data | A `<script>` in an error message or group name is encoded and can't run in the mail client; no UPN or object ID appears. |

### Configuration files and schema

| Test | What it proves |
|---|---|
| describes every script parameter | The schema and the script's parameters match exactly, with none missing and none extra. |
| marks keys the script rejects as not allowed | `ClientSecret`, `Rebalance`, `InitialRun`, `Preflight`, `CreateGroupsOnly` and `ConfigPath` are refused by the schema, so editors flag them. |
| uses the same notification values as the script | The schema's `TeamsNotifyOn` and `EmailNotifyOn` values match the script's. |
| finds the bundled configs | The test really found the sample and example configs (at least 4), so the next test can't pass by checking nothing. |
| validates every bundled config against the schema AND the script | Every shipped config passes the schema and the script's own validation. |
| rejects \<Case\> | Data-driven, 11 cases the schema must refuse: an unknown key, Certificate auth without a thumbprint, `EmailTo` without `EmailFrom`, a client secret, `Rebalance`, `CreateGroupsOnly`, an invalid notify value, an `http` webhook, half the Log Analytics pair, a non-GUID exclusion group, and a missing `GroupNameBase`. |
| keeps docs/Examples.md and config/examples in sync | The three example configs in the docs are identical to the files in `config/examples/`. |

### Certificate expiry

| Test | What it proves |
|---|---|
| classifies \<Name\> | Data-driven, 5 cases: valid for 200 days → `Valid`; 10 days left → `Expiring`; expired → `Expired`; starts in 5 days → `NotYetValid`; 10 days left with the warning off → `Valid`. |
| validates CertificateExpiryWarningDays | `-1` and `400` are rejected; the default is 30. |
| notifies a successful run when the certificate is expiring (default), but not a preview | A successful run sends the warning by default. Previews and a `TeamsNotifyOn` list without `CertificateExpiring` don't. |
| puts the warning in the Teams card and the email subject | Both show "expires in 12 day(s)". |
| warns and notifies on a certificate run, and stops on an expired certificate | End to end with 10 days left: the run succeeds, sends the warning to Teams, and records it in the JSON. With an expired certificate: the run stops with "expired on…" and sends one "Run failed" Teams card. |

### Certificate expiry by email

| Test | What it proves |
|---|---|
| emails the advance warning while the certificate still works | End to end: a successful run sends one email whose subject includes "certificate expires in". |
| never sends through a Graph session it did not open (expired certificate) | The emulator always reports a Graph session, which is the "someone else's session left in this window" case. With an expired certificate the run stops before sign-in, sends **no** email, and records `EmailNotification = Failed` in the JSON. This test fails against the earlier code that only checked whether any session existed. |

### Preflight

| Test | What it proves |
|---|---|
| fails without creating anything when groups are missing | `PreflightFailed`, with 7 failed group checks (First, 4 rings, Last, Inactive); no groups are created. |
| warns instead of failing when -CreateMissingGroups would create them | `PreflightPassedWithWarnings`; still creates nothing. |
| passes on a healthy ring set, changes no membership, and skips the write test | `PreflightPassed`. The membership-write check is `Skip`, because preflight never writes. Membership is unchanged, and no temporary file is left behind. |
| names a missing exclusion group | The failure detail names the missing group ID and `ExcludeGroupIds`. |
| sends one test message per configured channel, with no user data | Exactly one Teams card, one email and one Log Analytics record. Subjects say "Preflight passed", the record type is `Preflight`, and no UPN appears. |
| runs from the command line with -Preflight | The `-Preflight` switch works through the script's parameters, not only through the internal function. |

### GitHub rulesets

| Test | What it proves |
|---|---|
| requires exactly the checks that ci.yml produces | The ruleset's required checks match the job names CI actually reports. A mismatch would leave every PR waiting for a check that never reports. |
| protects the default branch without a bypass and without self-approval lockout | `main` is protected and active: no deletion, no force-push, PRs required, status checks required, no bypass actors, and 0 approvals required, so a solo maintainer isn't locked out. |
| lets only repository admins create, move or delete v* tags | Release tags are restricted; the only bypass is the Admin role. |
| uses a tag pattern the release workflow triggers on | The protected `v*` pattern is the same one `release.yml` triggers on. |

### Client assertion (`Get-RingClientAssertion`)

| Test | What it proves |
|---|---|
| produces an RS256 JWT that verifies with the certificate public key | The signed token used for certificate auth has three parts and the `RS256` algorithm. `iss` and `sub` are the client ID, and the signature verifies against the certificate. |

### Create groups only

`-CreateGroupsOnly` creates missing ring groups, then stops.

| Test | What it proves |
|---|---|
| implies CreateMissingGroups and turns off the sign-in rule's permission | The mode turns on group creation, and doesn't ask for sign-in activity. |
| refuses to combine with \<Other\> | Data-driven, 4 cases: `InitialRun`, `Rebalance`, `Preflight` and `RetireOrphanRings` each stop with "can't be combined". |
| asks only for group permissions | An interactive sign-in requests only `Group.ReadWrite.All`, plus `Mail.Send` when email is configured. |
| checks the token for create and read permissions only | `Group.ReadWrite.All` alone is enough. `Group.Create` alone is missing a read permission, and `Group.Create` with `GroupMember.Read.All` is enough. The scheduled app's permissions are reported as missing `Group.Create` (app) or `Group.ReadWrite.All` (signed-in user). |
| shows the groups created, not change counts, in Teams and email | The card subtitle says "create-groups-only run", and both list the created groups instead of users in scope and change counts. |
| previews with -WhatIf without creating anything | `WhatIf`, with the 7 groups that would be created listed; none is created. |
| creates every ring group with nothing but group permissions, reads no users and adds no members | The token has only `Group.ReadWrite.All` and reading users is refused, yet the run succeeds. All 7 groups are created with markers and no members, there's no `GET users` and no `$batch`, and the JSON shows `CreateGroupsOnly = true`. |
| works for an app with only Group.Create and GroupMember.ReadWrite.All | The recommended app permissions: groups are created, no user is read, and there's no missing-permission warning. |
| leaves existing groups and their members alone, and the next normal run fills the rings | A second run creates nothing and keeps a pilot user added to First. A normal run without `-CreateMissingGroups` then fills the rings as an initial population. |
| still refuses a same-named group without the marker | The ownership check still applies; nothing is created. |
| runs from the command line with -CreateGroupsOnly | The switch works through the script's parameters (2 rings → 5 groups). |

### Network test

Every run and preflight first checks the network path to the endpoints it needs.

| Test | What it proves |
|---|---|
| tests every endpoint the run needs first, logs host names only, and records them in the JSON | Graph and the Teams host are checked before sign-in, in that order, and logged as `OK … HTTP 404 in 12 ms, direct`. The webhook's path and signature never appear in the log or in the JSON `Network` array. |
| tests Entra sign-in for certificate auth, and stops before signing in when it can't be reached | `login.microsoftonline.com` times out behind a proxy. The run stops ("Network test failed … nothing was changed"), naming the endpoint, the reason, the proxy and the hosts to allow. It never calls `Connect-MgGraph` or Graph. |
| stops before any Graph call when Graph can't be reached | A proxy 502 for `graph.microsoft.com` stops the run with no Graph call. |
| only warns when an optional endpoint can't be reached | An unreachable Teams host gives a `FAILED (optional)` warning, and the run still succeeds. |
| logs the sign-in and explains a failure with the whole inner error chain | `ClientCertificateCredential authentication failed:` with an inner `TaskCanceledException` becomes "Sign-in to Microsoft Graph failed after n s (Certificate): … -> TaskCanceledException: A task was canceled.", in the error and in the JSON. This is the case where the error used to show an empty reason. |
| describes the sign-in it is about to make | Certificate: app and tenant; managed identity: system-assigned. |
| shows network checks in preflight, and skips sign-in when a required endpoint fails | `Network` checks fail and sign-in is `Skip`. |
| reports an endpoint that refuses the connection as unreachable (real probe) | The real check, not the emulator: a refused connection is unreachable, with a reason. |
| joins every message in an exception chain, naming empty ones by type | `Exception: outer -> AggregateException: … -> TimeoutException: slow`. |

### Access-denied explanations

What a 401/403 message says. See [Setup: Reading a permission error](Setup.md#reading-a-permission-error).

**Data-driven: "knows what \<Method\> \<Uri\> needs" (8 cases).** Each call is mapped to what the script is doing and the permission its setup grants:

| Call | Operation | First permission named |
|---|---|---|
| `GET groups?$filter=displayName eq …` | listing groups | `GroupMember.ReadWrite.All` |
| `GET groups/{id}/transitiveMembers` | reading group membership | `GroupMember.ReadWrite.All` |
| `GET groups/{id}` | reading a group | `GroupMember.ReadWrite.All` |
| `POST groups` | creating a group | `Group.Create` |
| `PATCH groups/{id}` | changing group membership | `GroupMember.ReadWrite.All` |
| `DELETE groups/{id}/members/{id}/$ref` | changing group membership | `GroupMember.ReadWrite.All` |
| `GET users` | reading users | `User.Read.All` |
| `POST users/{id}/sendMail` | sending email | `Mail.Send` |

| Test | What it proves |
|---|---|
| adds AuditLog.Read.All when sign-in activity is read | Reading `signInActivity` adds a second requirement, `AuditLog.Read.All`. |
| shows the request decoded, without the host or API version | `%28displayName%2C%27…` is shown as `(displayName,'…`. |
| reads the code, message and request-id from the SDK error text | Parses the real `Invoke-MgGraphRequest` error format (status line, headers, then JSON). |
| tells an app to grant the missing permission and consent to it | Every line of the message: operation and purpose, decoded request, Graph's text, what's needed, the app and tenant, the token's permissions, the fix, and the request-id. |
| suggests GroupMember.Read.All when the app already has GroupMember.ReadWrite.All | When the token has the permission and the call is still refused, the message says so and offers the documented alternative. |
| points at role-assignable groups when a membership change is refused despite the permission | The membership-specific cause is named. |
| names the directory role for a delegated sign-in, and never the account | Delegated: names Groups Administrator (or Reports Reader for sign-in activity) and PIM. The signed-in UPN never appears, because the message can reach Teams and email. |
| asks a delegated user to consent when the token lacks the scope | Delegated, missing scope: sign in again and consent. |
| explains a missing Entra ID P1/P2 licence | `Authentication_RequestFromNonPremiumTenantOrB2CTenant` gives the licence fix, or `InactiveSignInDays 0`. |
| says so when the token does not list its permissions | No guess is made; it says which permission to check. |
| tells an app to use Group.Create, not Group.ReadWrite.All, to create groups | For an app, `Group.Create` is listed first, is what the fix grants, and the fix says not to use `Group.ReadWrite.All`. |
| tells a signed-in user to consent to Group.ReadWrite.All, because Group.Create is application-only | For a delegated sign-in, the fix asks for `Group.ReadWrite.All` and says why. |
| treats a 401 as a rejected token | "Sign in again", and check tenant and cloud. |

### Access denied end to end

| Test | What it proves |
|---|---|
| stops with an explained error when listing groups is refused, and records it in the JSON | The emulator refuses `GET groups` and the token lacks group permissions. The run stops before creating anything, with the full explanation (no URL encoding). The status is still detectable as 403, and the JSON summary's `ErrorMessage` carries the explanation. |
| explains refused membership changes in one warning per group, with no user names | `$batch` membership writes are refused. The run ends `CompletedWithErrors` with 3 failed rows (`403: Authorization_RequestDenied`) and explained warnings naming the group and `GroupMember.ReadWrite.All`, never the users. |
| names the missing permission in the preflight group checks | Preflight fails the permission check and each group check, and the group detail says what to grant. |

### End-to-end against emulated Graph

These run in order on one fake tenant (1,200 users unless noted). Each row is the run's observable result.

| Test | What it proves |
|---|---|
| stops before changing anything when groups are missing and creation is not allowed | Stops with a `CreateMissingGroups` error; no groups are created. |
| does not create the rest of the set when only some groups exist | With only First present, it stops and names the missing `SG-Test-Ring01`. It never half-creates a set. |
| previews the first run with -WhatIf without creating anything | No groups created; adds are planned; every CSV change row says `WhatIf`. |
| creates all groups and places every in-scope user in exactly one ring | Creates all 7 groups. Every in-scope user is in exactly one, and nobody out of scope is in any. All six edge-case users land correctly. |
| stamps the marker tag on every group | Every description has `[EntraDeploymentRings:SG-Test:<key>]`. |
| is idempotent: a second run makes no changes | 0 adds, 0 removes. |
| keeps a manually relocated user where they are (sticky) | A user moved by hand from Ring01 to Ring03 is left there. |
| places only new users and leaves existing users alone | 30 new users: 30 adds, 0 removes, and nobody else moves. |
| removes a user from computed rings when an admin adds them to First | One remove from Ring02; the user stays in First. |
| honours First membership through a nested group | A user in a group nested inside First is removed from Ring04. |
| moves a user to Inactive and back to their original ring | Company set to Former → Inactive; set back → returns to their hashed ring. |
| survives throttling on batch sub-requests | A 429 with `Retry-After` is retried; 0 failures and the user is added. |
| trips the circuit breaker and changes nothing when too many users vanish | Disables 300 users; the run stops on `MaxChangePercent` and membership is unchanged. |
| moves a renamed .former user into Inactive and back out when renamed again | Reason `Inactive:UpnPattern:{user}.former@{domain}` in the CSV; renaming back returns the user to Ring02. |
| moves a disabled user to Inactive and back to their ring when re-enabled | Reason `Inactive:Disabled`; re-enabling returns the user to Ring03. |
| moves an offboarded user (employeeType Former) to Inactive instead of dropping them | Enabled offboarded user gets `Inactive:EmployeeType:Former`; disabled offboarded user gets `Inactive:Disabled`. |
| excludes disabled users and filters them server-side with DisabledUserAction Exclude | The disabled user is removed from all rings, and Graph is asked with `$filter=accountEnabled eq true`. Re-enabling returns the user to Ring04. |
| removes users matching an excluded UPN pattern and records why | `ExcludedByReason.UpnPattern = 1`; the CSV reason is `OutOfScope:UpnPattern:SVC-{user}@{domain}`; renaming the user back puts them in one ring again. |
| InitialRun re-seeds a skewed ring set without tripping the change limit | Everyone is piled into Ring01. A normal preview changes nothing (users stay put). `InitialRun` puts every user back in their hashed ring with reason `InitialRun`. |
| Rebalance re-seeds without tripping the change limit and runs fine without CreateMissingGroups | Reason `Rebalance`; the emptied Ring04 is refilled; group creation isn't needed. |
| stops when RingCount is reduced, and retires the orphan ring on request | With `RingCount` 4 → 3, it stops and mentions `RetireOrphanRings`. With that switch (plus `BypassChangeLimit`, since emptying a ring is a large change), Ring04 is emptied and everyone is in exactly one current ring. |
| reports an excluded user in First with the group name, and never removes them | A CSV `Conflict` row: `ExcludedUserInManualRing`, `SG-Test-First`, `First`, the UPN. The user is still in First. |
| names both groups when a user is in First and Last | The conflict's `GroupName` is `SG-Test-First; SG-Test-Last`. |
| logs exclusion groups by name, and stops with a named error when one is missing | The summary shows the display name "Break Glass Accounts". A deleted exclusion group stops the run with its ID and `ExcludeGroupIds` in the message. |
| keeps running normally after an orphan ring was emptied | An empty Ring04 is reported in `RetiredRingGroups` but doesn't block. |
| still stops when an orphan ring regains members | Someone re-adding a user to Ring04 stops the run ("still have members"). |
| refuses to manage a same-named group that lacks the marker | A pre-existing `SG-Test-Ring01` without the marker stops the run. |
| honours ReportFormat and ReportRetentionDays in a full run | 50 users. `Json` writes only the summary, and a 400-day-old report is pruned. |
| writes the JSON summary last, with its own file list and statuses | 40 users. The JSON lists both files, including itself, with `Notification` and `LogAnalytics` set to `NotConfigured`. It is written no earlier than the CSV. |
| posts to Teams when a run is blocked, and records it in the JSON | 25 users become Vendors with a 1% limit: blocked, one card to the configured webhook saying "Blocked by change limit", no UPNs, and `Notification = Sent` in the JSON. |
| does not post on success by default, but does when Success is listed | `NotRequested` and no post by default; `Sent` and one post with `TeamsNotifyOn Success`. |
| keeps the run successful when Teams fails, and never logs the URL | Teams returns 400: the result is still `Success` with `Notification = Failed`. The webhook signature appears nowhere in output, logs or report files. |
| emails a successful run when Success is listed, from the configured mailbox, without saving to Sent Items | Sent from `rings@contoso.com` to 2 recipients as HTML, not saved to Sent Items, subject `[EntraDeploymentRings] Run succeeded - SG-Test`, no UPNs. The JSON says `Sent`. |
| does not email a successful run by default | `NotRequested`, no mail. |
| keeps the run successful when sendMail is denied, with a helpful warning | A 403 from Graph: `Success`, `EmailNotification = Failed`, and the warning mentions `Mail.Send`. |
| shows progress while reading users | 456 users in pages of 100, logging every 50: one "Reading users… with sign-in activity" line, 4 "read so far" lines, none for the last page (which would only repeat the total), and a final "Read 456 user(s) in … s". |
| reports reading the ring groups between sign-in and reading users | "Reading ring groups and their members…" comes after sign-in and before reading users. "Read 7 ring group(s) with … user member(s), including 1 through groups nested in First or Last" counts a user added through a nested pilot group. |
| reports progress while changing group membership, and stays quiet in a preview | A `-WhatIf` run prints none of the apply lines. A live run prints "Applying n change(s) to g group(s)…", a start and result line per group (`SG-Test-Ring04: … added, 0 failed`), "applied so far" lines, and a final total. |
| pages through large result sets | 450 + 6 users with pages of 100: all 456 are read, over more than 3 follow-up page requests. |

---

## Adding a test

1. **Pick the layer.** For a change to a decision (placement, scope, inactive, the change limit), add a unit test in the matching `Describe`. For anything that changes users or groups, also add an end-to-end test ([CONTRIBUTING](../CONTRIBUTING.md#rules-for-changes), rule 2).
2. **New Graph call?** Teach `FakeGraph.ps1` to answer it, increment its `Revision`, and return Graph's real status codes and error codes for failures.
3. **Test the failure path, and prove the test can fail.** Before you rely on a new test, run it against the code without your fix and watch it fail. A test that can't fail proves nothing.
4. **Clean up.** End-to-end tests share one tenant, so undo tenant changes at the end of the test, and remove any functions you replaced (`Remove-Item function:Invoke-RestMethod`).
5. **No real personal data.** Use `contoso.test` / `contoso.com` and generated GUIDs.
6. **Update this page.** Add the test to the catalogue, update the counts in the area table and at the top, and add it to the safety-controls table if it proves a control.
