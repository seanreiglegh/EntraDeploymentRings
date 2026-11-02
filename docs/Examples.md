# Examples

Copy-paste examples for common situations. Each one says what it does and why.

- [First-time setup](#1-first-time-setup)
- [Example configurations](#2-example-configurations)
  - [Healthcare organisation, 6 rings](#healthcare-organisation-6-rings)
  - [Small organisation, 3 equal rings](#small-organisation-3-equal-rings)
  - [Separate ring set for one department](#separate-ring-set-for-one-department)
- [Keeping accounts out](#3-keeping-accounts-out)
- [Scheduling](#4-scheduling)
  - [Windows Task Scheduler](#windows-task-scheduler)
  - [Linux cron](#linux-cron)
  - [Azure Automation](#azure-automation)
- [Changing the rings later](#5-changing-the-rings-later)
- [When a run is blocked](#6-when-a-run-is-blocked)
- [Reading the results](#7-reading-the-results)
- [Other environments](#8-other-environments)
- [Notifications (Teams and email)](#10-notifications-teams-and-email)
- [Using the rings in a rollout](#9-using-the-rings-in-a-rollout)

---

## 1. First-time setup

Sign in with your own admin account (Groups Administrator + Reports Reader).

**Check.** This confirms sign-in, permissions, and that users can be read, and changes nothing. The groups show as warnings because they don't exist yet:

```powershell
./Invoke-EntraDeploymentRings.ps1 -GroupNameBase 'SG-Deploy-Users' -RingCount 5 -RingWeights 1,5,15,30,49 `
    -CreateMissingGroups -Preflight
```

**Preview.** This creates nothing and changes nothing:

```powershell
./Invoke-EntraDeploymentRings.ps1 -GroupNameBase 'SG-Deploy-Users' -RingCount 5 -RingWeights 1,5,15,30,49 `
    -CreateMissingGroups -WhatIf
```

Open the CSV in `./reports`. Check the ring sizes in the summary, and check who is being excluded.

**Create the groups.** This creates the empty groups and stops. It reads no users and changes no membership, so you need only Groups Administrator, not Reports Reader. Signed in, it requests `Group.ReadWrite.All`; an app would need `Group.Create` ([why](Setup.md#creating-the-groups-use-groupcreate)):

```powershell
./Invoke-EntraDeploymentRings.ps1 -GroupNameBase 'SG-Deploy-Users' -RingCount 5 -CreateGroupsOnly -WhatIf   # preview
./Invoke-EntraDeploymentRings.ps1 -GroupNameBase 'SG-Deploy-Users' -RingCount 5 -CreateGroupsOnly
```

Running it again is safe: groups that already exist are checked and left alone.

**Assign your policies (optional).** The rings are empty, so you can wire up Intune assignments now, and nobody receives anything until the next step.

**Fill them:**

```powershell
./Invoke-EntraDeploymentRings.ps1 -GroupNameBase 'SG-Deploy-Users' -RingCount 5 -RingWeights 1,5,15,30,49 -InitialRun
```

To create and fill in one go instead, add `-CreateMissingGroups` to that command.

**Add your pilot users.** Add them to `SG-Deploy-Users-First` in the Entra admin center, or use PowerShell:

```powershell
# Needs Microsoft.Graph.Groups
$first = Get-MgGroup -Filter "displayName eq 'SG-Deploy-Users-First'"
New-MgGroupMember -GroupId $first.Id -DirectoryObjectId (Get-MgUser -UserId 'jane.doe@contoso.com').Id
```

The next run removes them from their computed ring automatically.

---

## 2. Example configurations

These three configurations are also in the repository as files, ready to copy: [`config/examples/`](../config/examples). The test suite checks that they stay identical to what's shown here, and that they validate against the [schema](Configuration.md#configuration-file).

Save a configuration as `config/<name>.json` and run it with `-ConfigPath`. Keys you leave out use their defaults.

### Healthcare organisation, 6 rings

IT and informatics pilot first; clinical-critical staff go last. Contractors are included. Renamed departed users (`….former@`) go to Inactive. Service and admin accounts are excluded.

```json
{
  "_comment": "Enterprise user rings. First = IT/informatics pilot (manual). Last = clinical-critical (manual).",
  "GroupNameBase": "SG-Deploy-Users",
  "RingCount": 6,
  "RingWeights": [1, 4, 10, 20, 30, 35],

  "IncludeEmployeeTypes": ["Employee", "Contingent Worker"],
  "ExcludeUpnPatterns": ["SVC-{user}@{domain}", "adm-{user}@{domain}"],
  "ExcludeGroupIds": ["00000000-0000-0000-0000-000000000000"],

  "InactiveSignInDays": 60,
  "InactiveCompanyNames": ["Former", "Terminated*"],
  "InactiveUpnPatterns": ["{user}.former@{domain}"],
  "RemoveInactiveFromManualRings": true,

  "MaxChangePercent": 5,
  "MaxChangeFloor": 50,

  "AuthMode": "Certificate",
  "TenantId": "contoso.onmicrosoft.com",
  "ClientId": "11111111-1111-1111-1111-111111111111",
  "CertificateThumbprint": "0123456789ABCDEF0123456789ABCDEF01234567",

  "ReportDirectory": "D:/EntraDeploymentRings/reports",
  "ReportRetentionDays": 180
}
```

Why these values:
- `ExcludeGroupIds` holds your break-glass and service-account group.
- A **tighter change limit (5%)** suits a large, stable tenant, where a big swing is more likely a mistake than real churn.
- `RemoveInactiveFromManualRings` stops a dormant VIP account from sitting in Last forever.
- `ReportRetentionDays: 180` keeps six months of change evidence.

### Small organisation, 3 equal rings

No Inactive ring, every employee type, interactive sign-in:

```json
{
  "GroupNameBase": "Rollout",
  "RingCount": 3,
  "RingWeights": [33.33, 33.33, 33.34],
  "EnableInactiveRing": false,
  "IncludeEmployeeTypes": [],
  "MaxChangeFloor": 10,
  "ReportFormat": "Csv",
  "ReportRetentionDays": 30
}
```

- `IncludeEmployeeTypes: []` means every employee type is in scope, including users with no employee type set.
- `EnableInactiveRing: false` means no Inactive group is created and the inactivity rules aren't checked. That also means **no Entra ID P1/P2 is needed**.

### Separate ring set for one department

You can run several ring sets side by side. Each `GroupNameBase` is independent, and a user can be in one ring of *each* set.

```json
{
  "GroupNameBase": "SG-Deploy-Clinical",
  "RingCount": 3,
  "RingWeights": [10, 30, 60],
  "IncludeEmployeeTypes": ["Employee"],
  "ExcludeGroupIds": ["22222222-2222-2222-2222-222222222222"],
  "AssignmentMode": "Balance"
}
```

> The script has no department filter. To scope a ring set to one department, put everyone *outside* it in an exclusion group (for example a dynamic group on `department -ne "Clinical"`).

---

## 3. Keeping accounts out

| Account type | Setting |
|---|---|
| Service accounts named `svc-…@` | `-ExcludeUpnPatterns 'SVC-{user}@{domain}'` |
| Admin accounts named `adm-…@` | `-ExcludeUpnPatterns 'adm-{user}@{domain}'` |
| Renamed departed users `….former@`, kept **out** of every group | `-ExcludeUpnPatterns '{user}.former@{domain}'` |
| Accounts in one specific domain | `-ExcludeUpnPatterns '*@legacy.contoso.com'` |
| Test accounts `test1@`, `test2@`… | `-ExcludeUpnPatterns 'test?@{domain}', 'test??@{domain}'` |
| Break-glass and anything hand-picked | `-ExcludeGroupIds '<group-id>'` |
| Vendors (`employeeType` = Vendor) | Leave them out of `IncludeEmployeeTypes` (the default does) |
| Unlicensed accounts | `-RequireAssignedLicense` |
| Disabled accounts | Go to **Inactive** by default. To drop them instead: `-DisabledUserAction Exclude` |

### Departed users: Inactive or excluded?

**Offboarding sets `employeeType` to `Former`?** That's handled by default. `InactiveEmployeeTypes` defaults to `Former`, so those users go to Inactive (`Inactive:EmployeeType:Former`) instead of dropping out. If your HR process uses other values, list them:

```json
"InactiveEmployeeTypes": ["Former", "Terminated", "Leaver*"]
```

**Offboarding renames the UPN to `….former@`?** Choose one list. Don't put the pattern in both.

```powershell
# Option 1 (recommended): park them in the Inactive group.
# They stay visible, and you can exclude -Inactive from "All users" assignments.
-InactiveUpnPatterns '{user}.former@{domain}'

# Option 2: drop them from every group.
-ExcludeUpnPatterns '{user}.former@{domain}'
```

To preview which accounts the rule will move, run this **before** adding the pattern to your config. Once they're in Inactive, later runs don't list them again.

```powershell
$r = ./Invoke-EntraDeploymentRings.ps1 -ConfigPath ./config/prod.json -InactiveUpnPatterns '{user}.former@{domain}' -WhatIf
Import-Csv $r.ReportPath | Where-Object Reason -eq 'Inactive:UpnPattern:{user}.former@{domain}' |
    Select-Object UserPrincipalName, Action, GroupName
```

To check who would be excluded, and why, before changing anything:

```powershell
$r = ./Invoke-EntraDeploymentRings.ps1 -ConfigPath ./config/prod.json -ExcludeUpnPatterns 'SVC-{user}@{domain}' -WhatIf
$r.ExcludedByReason                       # counts per reason
Import-Csv $r.ReportPath | Where-Object Reason -like 'OutOfScope:UpnPattern*' |
    Select-Object UserPrincipalName, GroupName, Reason
```

---

## 4. Scheduling

Put `TenantId`, `ClientId` and `CertificateThumbprint` in the config file, so the scheduled command only needs `-ConfigPath`.

### Windows Task Scheduler

Run this as an administrator. The task runs daily at 05:40 under a service account. That account must be the one whose certificate store holds the certificate.

```powershell
$action  = New-ScheduledTaskAction -Execute 'pwsh.exe' `
    -Argument '-NoProfile -NonInteractive -File "D:\EntraDeploymentRings\Invoke-EntraDeploymentRings.ps1" -ConfigPath "D:\EntraDeploymentRings\config\prod.json"' `
    -WorkingDirectory 'D:\EntraDeploymentRings'
$trigger = New-ScheduledTaskTrigger -Daily -At '05:40'
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 2) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName 'EntraDeploymentRings' -Action $action -Trigger $trigger -Settings $settings `
    -User 'CONTOSO\svc-entrarings' -Password (Read-Host 'Service account password')
```

`-MultipleInstances IgnoreNew` stops two runs from overlapping. If you use a group managed service account (gMSA), register the task with `New-ScheduledTaskPrincipal -LogonType Password` instead of a password.

### Linux cron

```bash
# crontab -e   (as the user that owns the certificate)
40 5 * * * cd /opt/entra-rings && /usr/bin/flock -n /tmp/entra-rings.lock \
  pwsh -NoProfile -NonInteractive -File ./Invoke-EntraDeploymentRings.ps1 -ConfigPath ./config/prod.json \
  >> ./logs/run.log 2>&1
```

`flock -n` skips a run if the previous one is still going.

### Azure Automation

Azure Automation can't read a config file, so set the parameters on the schedule. Lists are JSON:

| Parameter | Value |
|---|---|
| GroupNameBase | `SG-Deploy-Users` |
| RingCount | `5` |
| RingWeights | `[1,5,15,30,49]` |
| InactiveUpnPatterns | `["{user}.former@{domain}"]` |
| ExcludeUpnPatterns | `["SVC-{user}@{domain}"]` |
| AuthMode | `ManagedIdentity` |
| SkipReport | `true` |
| LogIngestionEndpoint | `https://dcr-xxxx.westus2-1.ingest.monitor.azure.com` |
| LogDcrImmutableId | `dcr-0123456789abcdef0123456789abcdef` |

Report files don't survive the job, so turn on [Log Analytics](LogAnalytics.md) for history.

---

## 5. Changing the rings later

**Change ring sizes.** Existing users don't move until you rebalance:

```powershell
# 1. Edit RingWeights in config/prod.json, then preview the re-sort
./Invoke-EntraDeploymentRings.ps1 -ConfigPath ./config/prod.json -Rebalance -WhatIf
# 2. Apply it
./Invoke-EntraDeploymentRings.ps1 -ConfigPath ./config/prod.json -Rebalance
```

**Add a ring** (5 → 6). Change `RingCount` and `RingWeights`. Create the new group with your own account, then re-sort with the scheduled identity, which needs no group-creation rights:

```powershell
./Invoke-EntraDeploymentRings.ps1 -ConfigPath ./config/prod.json -CreateGroupsOnly          # creates only Ring06
./Invoke-EntraDeploymentRings.ps1 -ConfigPath ./config/prod.json -Rebalance -WhatIf
./Invoke-EntraDeploymentRings.ps1 -ConfigPath ./config/prod.json -Rebalance
```

Or do it in one run with `-CreateMissingGroups -Rebalance`.

**Remove a ring** (5 → 4). Change `RingCount` and `RingWeights`, then:

```powershell
./Invoke-EntraDeploymentRings.ps1 -ConfigPath ./config/prod.json -RetireOrphanRings -Rebalance
```

`SG-Deploy-Users-Ring05` is emptied, not deleted. Later runs work normally and log a warning that it can be deleted. Remove its policy assignments, then delete it when you're ready.

**Exact ring sizes, once.** Hash mode matches the weights statistically. For exact sizes:

```powershell
./Invoke-EntraDeploymentRings.ps1 -ConfigPath ./config/prod.json -Rebalance -AssignmentMode Balance
```

---

## 6. When a run is blocked

A daily run fails with `BlockedByChangeLimit`. Nothing was changed. To find out why:

```powershell
$csv = Get-ChildItem ./reports/*.csv | Sort-Object LastWriteTime | Select-Object -Last 1
Import-Csv $csv | Group-Object Action, Reason | Sort-Object Count -Descending | Format-Table Count, Name
```

| You see mostly… | Likely cause | What to do |
|---|---|---|
| `Add` / `Inactive:Disabled` | A mass disable or offboarding batch | If expected, rerun with `-BypassChangeLimit` |
| `Add` / `Inactive:EmployeeType:Former` | An offboarding batch | If expected, rerun with `-BypassChangeLimit` |
| `Remove` / `OutOfScope:EmployeeType:…` | HR or sync changed `employeeType` to a value that isn't listed | Fix the source data, or add the value to `IncludeEmployeeTypes` or `InactiveEmployeeTypes` |
| `Remove` / `OutOfScope` (no detail) | Graph returned fewer users than normal | Wait and rerun. Don't bypass. |
| `Add` / `Inactive:NoSignIn…` | A sign-in data delay, or the threshold changed | Check `InactiveSignInDays`. Rerun later. |

Once you've confirmed the changes are expected:

```powershell
./Invoke-EntraDeploymentRings.ps1 -ConfigPath ./config/prod.json -BypassChangeLimit
```

---

## 7. Reading the results

Column and reason definitions are in [Reports.md](Reports.md).

```powershell
$r = ./Invoke-EntraDeploymentRings.ps1 -ConfigPath ./config/prod.json -WhatIf

# Ring sizes vs target
$r.Distribution | Format-Table Ring, Members, TargetPercentOfComputed, ActualPercentOfComputed

# What would change, by reason
Import-Csv $r.ReportPath | Where-Object RecordType -eq 'Change' |
    Group-Object Action, Reason | Sort-Object Count -Descending | Format-Table Count, Name

# Conflicts to fix by hand
Import-Csv $r.ReportPath | Where-Object RecordType -eq 'Conflict' |
    Format-Table UserPrincipalName, Reason, ErrorMessage -Wrap

# Where is a particular user, and why?
Import-Csv $r.ReportPath | Where-Object UserPrincipalName -eq 'jane.doe@contoso.com'
```

Compare today's run summary with last week's:

```powershell
$runs = Get-ChildItem ./reports/*.summary.json | Sort-Object LastWriteTime
$old  = Get-Content $runs[-8].FullName -Raw | ConvertFrom-Json
$new  = Get-Content $runs[-1].FullName -Raw | ConvertFrom-Json
foreach ($ring in $new.Distribution) {
    $was = ($old.Distribution | Where-Object Ring -eq $ring.Ring).Members
    '{0,-9} {1,6} -> {2,6}' -f $ring.Ring, $was, $ring.Members
}
```

---

## 8. Other environments

**US Government cloud (GCC High):**

```powershell
./Invoke-EntraDeploymentRings.ps1 -ConfigPath ./config/prod.json -GraphEnvironment USGov
```

**Reuse a Graph session you already opened** (handy for troubleshooting):

```powershell
Connect-MgGraph -Scopes 'User.Read.All', 'AuditLog.Read.All', 'GroupMember.ReadWrite.All'
./Invoke-EntraDeploymentRings.ps1 -ConfigPath ./config/prod.json -AuthMode ExistingConnection -WhatIf -Verbose
```

**Client secret from Azure Key Vault**, when a certificate isn't possible:

```powershell
$secret = Get-AzKeyVaultSecret -VaultName 'kv-ops' -Name 'EntraRings-Secret'   # returns SecretValue as SecureString
./Invoke-EntraDeploymentRings.ps1 -ConfigPath ./config/prod.json -AuthMode ClientSecret -ClientSecret $secret.SecretValue
```

---

## 9. Using the rings in a rollout

The script only maintains the groups. You assign them in the tool doing the rollout. A typical schedule:

| Day | Assign to | Watch for |
|---|---|---|
| 0 | `SG-Deploy-Users-First` | IT pilot feedback |
| 2 | `-Ring01` (1%) | Helpdesk tickets |
| 4 | `-Ring02` (5%) | |
| 7 | `-Ring03` (15%) | |
| 10 | `-Ring04` (30%) | |
| 14 | `-Ring05` (49%) | |
| 16 | `SG-Deploy-Users-Last` | Clinical-critical staff, after everything else is stable |

In Intune, add each ring group to the policy's or app's **Included groups** in turn. Never assign anything to `-Inactive`. To keep a change away from dormant accounts, add `-Inactive` as an **Excluded group** on assignments that target "All users".

---

## 10. Notifications (Teams and email)

**Daily job, alerts only when something needs attention** (the default results):

```powershell
$env:EDR_TEAMS_WEBHOOK = '<workflow URL>'   # set in the scheduled task's environment or a secret store, not in the config file
./Invoke-EntraDeploymentRings.ps1 -ConfigPath ./config/prod.json -TeamsWebhookUrl $env:EDR_TEAMS_WEBHOOK
```

**Also confirm every successful run.** This is useful in the first weeks, to know the job is running:

```powershell
./Invoke-EntraDeploymentRings.ps1 -ConfigPath ./config/prod.json -TeamsWebhookUrl $env:EDR_TEAMS_WEBHOOK `
    -TeamsNotifyOn Failed, BlockedByChangeLimit, CompletedWithErrors, CertificateExpiring, Success
```

**Post a preview to the channel for review** before a rebalance:

```powershell
./Invoke-EntraDeploymentRings.ps1 -ConfigPath ./config/prod.json -Rebalance -WhatIf `
    -TeamsWebhookUrl $env:EDR_TEAMS_WEBHOOK -TeamsNotifyOn WhatIf
```

**Azure Automation:** store the URL as an **encrypted** Automation variable, and pass it from a small wrapper runbook:

```powershell
$hook = Get-AutomationVariable -Name 'EDR-TeamsWebhook'
./Invoke-EntraDeploymentRings.ps1 -GroupNameBase 'SG-Deploy-Users' -RingCount 5 -RingWeights 1,5,15,30,49 `
    -AuthMode ManagedIdentity -SkipReport -TeamsWebhookUrl $hook
```

Check whether a run notified: `$r.Notification` (Teams) and `$r.EmailNotification` are `Sent`, `NotRequested`, `NotConfigured` or `Failed`.

**Email instead of, or as well as, Teams.** Scope `Mail.Send` first ([Security.md](Security.md#scope-mailsend-to-one-mailbox)):

```powershell
./Invoke-EntraDeploymentRings.ps1 -ConfigPath ./config/prod.json `
    -EmailTo 'it-ops@contoso.com' -EmailFrom 'deployment-rings@contoso.com'
```

Or in the config file, since email addresses aren't secrets:

```json
"EmailTo": ["it-ops@contoso.com", "secops@contoso.com"],
"EmailFrom": "deployment-rings@contoso.com",
"EmailNotifyOn": ["Failed", "BlockedByChangeLimit", "CompletedWithErrors", "CertificateExpiring"]
```
