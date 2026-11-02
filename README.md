# EntraDeploymentRings

A PowerShell 7 script that keeps your Microsoft Entra ID users sorted into **deployment-ring groups**, so you can roll out software and configuration changes in stages: a few pilot users first, then a bigger group, and so on.

```
SG-Deploy-Users-First      you choose      pilot users
SG-Deploy-Users-Ring01     script fills      1%
SG-Deploy-Users-Ring02     script fills      5%
SG-Deploy-Users-Ring03     script fills     15%
SG-Deploy-Users-Ring04     script fills     30%
SG-Deploy-Users-Ring05     script fills     49%
SG-Deploy-Users-Last       you choose      VIPs, clinical-critical users, etc.
SG-Deploy-Users-Inactive   script fills    dormant or departed accounts
```

Assign your Intune policies, apps or feature flags to **First → Ring01 → … → Last**, in that order. Don't assign anything to Inactive.

> Users only. For device-based Windows update rings, use Windows Autopatch.

---

## Executive summary

**The problem.** Pushing a change to everyone at once means one bad update can disrupt the whole organization in a single day. Staged rollouts fix that, but only if the stage groups are kept accurate. When they're kept by hand they drift: new hires are missed, departed staff linger, and the "pilot" group slowly becomes everyone.

**What this does.** It keeps a fixed set of rollout groups in Microsoft Entra ID up to date automatically, every day:
- **Every user in scope is in exactly one stage.** A change reaches about 1% of people first, then 5%, and so on, so problems surface while they're small.
- **People stay in the same stage over time,** so each person's place in the rollout order is predictable.
- **IT chooses who goes first and who goes last.** For example, IT staff pilot changes, and clinical-critical or executive users receive them only after everyone else.
- **Dormant, disabled and departed accounts are moved aside automatically,** so rollouts don't target people who have left. This also gives security a clean list of accounts to review.

**Business value**

| Outcome | How |
|---|---|
| Less disruption from bad changes | Problems are caught in small early stages, before they reach everyone |
| Critical staff protected | Clinical-critical, VIP and other sensitive users are always in the last stage |
| Less manual work, fewer errors | No hand-maintained group lists. New hires and departures are handled automatically. |
| Audit evidence | Every run records who moved, where, and why. Logs can go to Microsoft Sentinel. |
| Works with existing tools | Uses standard Entra ID security groups, so Intune, Conditional Access and app assignments use them as they are |

**Risk controls built in**
- **Preview mode.** Shows every change before anything is applied.
- **Automatic stop.** If a run would move an unusually large number of people (default 10%), it halts and changes nothing until someone reviews it. This guards against a data error turning into a mass change.
- **Narrow reach.** It only modifies groups it created and marked as its own. It never edits the hand-picked first and last groups unless told to.
- **Least privilege.** Scheduled runs need only read access to users and their sign-in activity, plus permission to manage group membership. They need no rights to create groups.

**What it takes to adopt**

| Item | Detail |
|---|---|
| Cost | Free and open source (MIT license). No new infrastructure: runs on an existing server or in Azure Automation. |
| Licensing | Microsoft Entra ID P1 or P2, only for the "no recent sign-in" rule. This is included in Microsoft 365 E3/E5. |
| Setup effort | Register the app, grant permissions, then preview and run once. Steps are in [docs/Setup.md](docs/Setup.md). |
| Ongoing effort | Act on Teams or Sentinel alerts when a run fails or is blocked. Maintain the first and last groups. |
| Main risk to manage | The service identity can change the membership of any non-privileged group, so treat its credentials as privileged and monitor its activity. Hardening guidance and ready-made alerts: [docs/Security.md](docs/Security.md). |

---

## How it works

- **Everyone lands in exactly one group.** When a user qualifies for more than one, the first match wins: **Inactive → Last → First → computed ring**.
- **You manage First and Last by hand.** Add a user to one of them, and the next run takes that user out of their computed ring.
- **Users stay put.** Once placed, a user keeps their ring on every later run. Only new or returning users are placed, so nobody's rollout schedule changes underneath them.
- **Inactive is automatic.** A user is inactive when their account is **disabled**, their employee type or company name is `Former`, they have no successful sign-in for 90 days, or their UPN matches a pattern such as `{user}.former@{domain}`. Every rule is configurable.
- **The scope is yours.** By default it's employees and contingent workers (enabled or disabled; disabled ones go to Inactive). You can also exclude users by group or UPN pattern, for example `SVC-{user}@{domain}`.

Full details: [docs/Configuration.md](docs/Configuration.md)

---

## Quick start

**1. Install the one module it needs** (PowerShell 7.2+):

```powershell
Install-Module Microsoft.Graph.Authentication -Scope CurrentUser
```

**2. Set up an identity.** For a first try, use your own admin account: you need Groups Administrator and Reports Reader. For scheduled runs, set up an app registration or managed identity using **[docs/Setup.md](docs/Setup.md)**.

**3. Check, then preview.** First run with `-Preflight`. It checks sign-in, permissions and groups, and sends test notifications, without changing anything. Missing groups show as warnings when `-CreateMissingGroups` is set. Then preview with `-WhatIf`: nothing is created or changed. Open the CSV in `./reports` to see the plan.

```powershell
./Invoke-EntraDeploymentRings.ps1 -GroupNameBase 'SG-Deploy-Users' -RingCount 5 -RingWeights 1,5,15,30,49 `
    -InactiveUpnPatterns '{user}.former@{domain}' -ExcludeUpnPatterns 'SVC-{user}@{domain}' -CreateMissingGroups -WhatIf
```

**4. Create the groups, then fill them.** `-CreateGroupsOnly` creates the empty groups and stops. It reads no users and changes no membership, and it's the only run that needs the right to create groups. That right is `Group.Create` for an app, or `Group.ReadWrite.All` for your own sign-in ([why](docs/Setup.md#creating-the-groups-use-groupcreate)).

```powershell
./Invoke-EntraDeploymentRings.ps1 -GroupNameBase 'SG-Deploy-Users' -RingCount 5 -CreateGroupsOnly
```

Optionally, assign your policies to the empty rings now. Nobody receives anything until the rings are filled. Then fill them:

```powershell
./Invoke-EntraDeploymentRings.ps1 -GroupNameBase 'SG-Deploy-Users' -RingCount 5 -RingWeights 1,5,15,30,49 `
    -InactiveUpnPatterns '{user}.former@{domain}' -ExcludeUpnPatterns 'SVC-{user}@{domain}' -InitialRun
```

(You can also do both in one run by adding `-CreateMissingGroups` to the `-InitialRun` command.)

**5. Schedule it daily.**
1. Copy `config/EntraDeploymentRings.sample.json` to `config/prod.json`, or start from one of the [example configs](config/examples). Editors like VS Code validate the file and autocomplete keys as you type, using the bundled schema.
2. **Change `AuthMode` from `Interactive`** to `Certificate` (with `TenantId`, `ClientId`, `CertificateThumbprint`) or `ManagedIdentity`. The sample ships with `Interactive` for first runs; a scheduled job left on `Interactive` waits for a sign-in nobody answers, then fails.
3. Schedule it:

```powershell
./Invoke-EntraDeploymentRings.ps1 -ConfigPath ./config/prod.json
```

Scheduling recipes for Task Scheduler, cron and Azure Automation: [docs/Examples.md](docs/Examples.md#4-scheduling).

---

## Common tasks

| I want to… | Do this |
|---|---|
| Check the setup without changing anything | Add `-Preflight` ([what it checks](docs/Configuration.md#preflight-checks)) |
| Create the ring groups without filling them | `-CreateGroupsOnly` (add `-WhatIf` to preview). An app needs `Group.Create`, never `Group.ReadWrite.All`. |
| See what a run would change | Add `-WhatIf` and open the CSV report ([what the columns mean](docs/Reports.md#csv-columns)) |
| Put a user in the pilot | Add them to the `-First` group |
| Make a user go last | Add them to the `-Last` group |
| Keep service accounts out | `-ExcludeUpnPatterns 'SVC-{user}@{domain}'` or `-ExcludeGroupIds <group-id>` |
| Park departed `….former@` accounts in Inactive | `-InactiveUpnPatterns '{user}.former@{domain}'` |
| Change ring sizes | Edit `RingWeights`, then run once with `-Rebalance` (preview with `-WhatIf` first) |
| Reduce the number of rings | Lower `RingCount` and run with `-RetireOrphanRings -Rebalance` |
| Stop old reports piling up | Set `ReportRetentionDays`, for example `90` |
| Send results to Sentinel / Log Analytics | Follow [docs/LogAnalytics.md](docs/LogAnalytics.md) |
| Understand why a user moved | Check the `Reason` column ([list of reasons](docs/Reports.md#change-reasons)) |
| Schedule it (Task Scheduler, cron, Azure Automation) | See [Examples: Scheduling](docs/Examples.md#4-scheduling) |
| Fix a blocked run | See [Examples: When a run is blocked](docs/Examples.md#6-when-a-run-is-blocked) |
| Fix a `403` / permission error | The error names what was refused, what the token has, and the fix. See [Reading a permission error](docs/Setup.md#reading-a-permission-error). |
| Get a Teams message when a run fails or is blocked | `-TeamsWebhookUrl <workflow URL>` ([setup](docs/Configuration.md#teams-notifications)) |
| Get an email instead | `-EmailTo <address> -EmailFrom <mailbox>` ([setup](docs/Configuration.md#email-notifications); scope `Mail.Send` first) |
| Remove the solution | Follow [docs/Decommission.md](docs/Decommission.md). Remove policy references **before** deleting groups. |

More scenarios: **[docs/Examples.md](docs/Examples.md)**

---

## Built-in safety

- **Check before you run** with `-Preflight`, and **preview anything** with `-WhatIf`.
- **Warns before the certificate expires,** 30 days ahead by default, even on runs that succeed.
- **Stops on large changes.** If a run would change more than 10% of memberships, it stops without changing anything and writes the plan to the report. `-Rebalance` and `-InitialRun` skip this check, so preview those first.
- **Never creates groups unless asked** (`-CreateGroupsOnly` or `-CreateMissingGroups`).
- **Never touches groups it didn't create.** Each ring group carries a marker in its description, and the script refuses any group without one.
- **Never edits First or Last** unless you opt in. It does report out-of-scope users it finds there.
- **Tests the network first.** Each run checks that it can reach Entra sign-in and Graph and logs the result. If it can't reach them, it stops at once with the reason, instead of hanging at sign-in.
- **Tells you when something's wrong.** Optional Teams cards or emails for failed or blocked runs carry counts only, never user names.

More: [docs/Operations.md](docs/Operations.md). Before going live, read [docs/Security.md](docs/Security.md). To report a vulnerability, see [SECURITY.md](SECURITY.md).

---

## Documentation

| Page | What's in it |
|---|---|
| [docs/Examples.md](docs/Examples.md) | Copy-paste scenarios: example configs, scheduling, changing rings, blocked runs, reading results |
| [docs/Setup.md](docs/Setup.md) | Creating the app registration, certificate or managed identity; permissions; hardening |
| [docs/Configuration.md](docs/Configuration.md) | How rings are assigned, every parameter, the config file, auth modes |
| [docs/Operations.md](docs/Operations.md) | Safety features, the change limit, day-to-day notes |
| [docs/Decommission.md](docs/Decommission.md) | Removing it safely, completely or in part: references first, then groups, identity, runner and logs |
| [docs/Security.md](docs/Security.md) | Security and best practices: threat model, checklist, hardening, alerts, incident response, compliance mapping (HIPAA, NIST 800-53, NIST CSF 2.0, ISO 27001) |
| [docs/Reports.md](docs/Reports.md) | Report files, every column, results, change reasons, conflicts, retention, queries |
| [docs/LogAnalytics.md](docs/LogAnalytics.md) | Sending results to Log Analytics / Sentinel, KQL queries and alerts |
| [docs/Testing.md](docs/Testing.md) | Every test and what it proves, how the Graph emulator works, which safety controls are tested, and what the tests can't prove |
| [CHANGELOG.md](CHANGELOG.md) | Version history |

Built-in help: `Get-Help ./Invoke-EntraDeploymentRings.ps1 -Full`

---

## Requirements

- PowerShell **7.2+** on Windows, Linux or macOS. Windows PowerShell 5.1 isn't supported.
- `Microsoft.Graph.Authentication` 2.0+.
- **Entra ID P1 or P2**, for the sign-in inactivity rule.
- Graph permissions: `User.Read.All`, `AuditLog.Read.All` and `GroupMember.ReadWrite.All`. Only the run that creates the groups needs more: `Group.Create` for an app, or `Group.ReadWrite.All` for your own sign-in. Never grant an app `Group.ReadWrite.All`. See [docs/Setup.md](docs/Setup.md).

## Development

```powershell
Install-Module Pester -MinimumVersion 5.5 -Scope CurrentUser
Install-Module PSScriptAnalyzer -Scope CurrentUser
Invoke-ScriptAnalyzer -Path ./Invoke-EntraDeploymentRings.ps1 -Settings ./PSScriptAnalyzerSettings.psd1
Invoke-Pester -Path ./tests -Output Detailed
```

The tests run against an in-memory Graph emulator, so you don't need a tenant. [docs/Testing.md](docs/Testing.md) lists every test and what the emulator doesn't cover.

## License

[MIT](LICENSE)
