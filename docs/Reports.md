# Reports

Every run records what it did, in up to six places:

| Output | Contains | Where |
|---|---|---|
| **CSV report** | One row per change or conflict | `ReportDirectory` (default `./reports`) |
| **JSON summary** | One object per run: totals, ring sizes, exclusions | `ReportDirectory` |
| **Pipeline object** | The same summary, returned by the script | `$r = ./Invoke-EntraDeploymentRings.ps1 …` |
| **Log Analytics** | CSV rows and the summary, in one table | `EntraDeploymentRings_CL` ([setup](LogAnalytics.md)) |
| **Teams card** | Result and counts only (no user names) | A Teams channel ([setup](Configuration.md#teams-notifications)) |
| **Email** | The same as the Teams card, as HTML (no user names, no attachment) | Recipients you choose ([setup](Configuration.md#email-notifications)) |

**Order at the end of every run:**
1. CSV
2. Delete old reports (retention)
3. Teams notification
4. Email notification
5. Log Analytics
6. **JSON summary, last**

Writing the JSON last means it records the final state of everything before it: the report file list (including itself), the prune count, and whether the notification and Log Analytics sends worked.

Contents:
- [Files and naming](#files-and-naming)
- [CSV columns](#csv-columns)
- [Row results](#row-results)
- [Change reasons](#change-reasons)
- [Conflicts](#conflicts)
- [JSON summary](#json-summary)
- [Run results](#run-results)
- [Retention and privacy](#retention-and-privacy)
- [Working with reports](#working-with-reports)

---

## Files and naming

```
EntraDeploymentRings_<GroupNameBase>_<yyyyMMdd-HHmmss>_<run>.csv
EntraDeploymentRings_<GroupNameBase>_<yyyyMMdd-HHmmss>_<run>.summary.json
```

- `<yyyyMMdd-HHmmss>` is the run's start time in **UTC**.
- `<run>` is the first 8 characters of the `RunId`.
- Characters in `GroupNameBase` other than letters, digits, `_` and `-` become `_`.

| Setting | Effect |
|---|---|
| `ReportFormat = Both` (default) | Writes both files |
| `ReportFormat = Csv` | CSV only |
| `ReportFormat = Json` | JSON only |
| `SkipReport` | No files (the pipeline object and Log Analytics still work) |
| `ReportRetentionDays` | Deletes old files; see [Retention](#retention-and-privacy) |

Reports are written for every run: live, `-WhatIf`, blocked by the change limit, or failed. A run with no changes writes a CSV with just the header row.

---

## CSV columns

One row per membership change (`RecordType = Change`) or conflict (`RecordType = Conflict`). The file is UTF-8 with a header row, and opens directly in Excel.

| # | Column | Example | Description |
|---|---|---|---|
| 1 | `TimeGenerated` | `2026-10-26T01:49:16.9534915Z` | When the report was written (UTC, ISO 8601). It's the same for every row of a run. |
| 2 | `RunId` | `f06aebda-dd71-…` | Ties every row, the JSON file and Log Analytics records of one run together |
| 3 | `RecordType` | `Change` | `Change` or `Conflict` |
| 4 | `RingSet` | `SG-Deploy-Users` | The `GroupNameBase` |
| 5 | `Action` | `Add` | `Add`, `Remove`, or `None` (conflicts) |
| 6 | `UserId` | `038011ac-3c05-…` | User's Entra object ID |
| 7 | `UserPrincipalName` | `aisha.khan@contoso.com` | User's UPN at the time of the run |
| 8 | `GroupName` | `SG-Deploy-Users-Inactive` | Group being changed. For conflicts, the First/Last group(s) involved, separated by `; ` |
| 9 | `GroupId` | `27853bf1-607e-…` | Its object ID. Empty in a `-WhatIf` run for groups that don't exist yet. |
| 10 | `RingKey` | `Inactive` | `First`, `Ring01`…`RingNN`, `Last` or `Inactive`. For conflicts, `First`, `Last` or `First; Last`. |
| 11 | `Reason` | `Inactive:EmployeeType:Former` | Why. See [Change reasons](#change-reasons) and [Conflicts](#conflicts). |
| 12 | `Result` | `Success` | What happened. See [Row results](#row-results). |
| 13 | `ErrorMessage` | | The Graph error if the change failed. For conflicts, what to do. |
| 14 | `IsWhatIf` | `False` | `True` in a preview run |

### Sample

A real run against the test emulator. A user moving to Inactive produces **two rows**: a `Remove` from their ring and an `Add` to Inactive. IDs are shortened here.

| Action | UserPrincipalName | GroupName | Reason | Result |
|---|---|---|---|---|
| Remove | aisha.khan@contoso.com | SG-Deploy-Users-Ring01 | `MovedToInactive` | Success |
| Remove | dev.patel.former@contoso.com | SG-Deploy-Users-Ring01 | `MovedToInactive` | Success |
| Remove | emma.li@contoso.com | SG-Deploy-Users-Ring03 | `ManualRingOverride:Last` | Success |
| Remove | svc-reporting@contoso.com | SG-Deploy-Users-Ring03 | `OutOfScope:UpnPattern:SVC-{user}@{domain}` | Success |
| Remove | ben.ortiz@contoso.com | SG-Deploy-Users-Ring03 | `MovedToInactive` | Success |
| Add | aisha.khan@contoso.com | SG-Deploy-Users-Inactive | `Inactive:EmployeeType:Former` | Success |
| Add | dev.patel.former@contoso.com | SG-Deploy-Users-Inactive | `Inactive:UpnPattern:{user}.former@{domain}` | Success |
| Add | ben.ortiz@contoso.com | SG-Deploy-Users-Inactive | `Inactive:Disabled` | Success |
| Add | kai.walker@contoso.com | SG-Deploy-Users-Ring03 | `NewAssignment` | Success |
| None | emma.li@contoso.com | | `InFirstAndLast` | Reported |

Raw CSV for the first and last rows:

```csv
"TimeGenerated","RunId","RecordType","RingSet","Action","UserId","UserPrincipalName","GroupName","GroupId","RingKey","Reason","Result","ErrorMessage","IsWhatIf"
"2026-10-26T01:49:16.9534915Z","f06aebda-dd71-4775-9b05-6e288bef651c","Change","SG-Deploy-Users","Remove","038011ac-3c05-89d9-a3f7-011573e34d81","aisha.khan@contoso.com","SG-Deploy-Users-Ring01","ab3ff7cb-f2c0-414e-a960-ed41f7cd32f3","Ring01","MovedToInactive","Success",,"False"
"2026-10-26T01:49:16.9534915Z","f06aebda-dd71-4775-9b05-6e288bef651c","Conflict","SG-Deploy-Users","None","e709dfc5-8d3a-2fbf-e0cb-5eee6e5c8c28","emma.li@contoso.com",,,,"InFirstAndLast","Reported","User is in both First and Last; Last takes precedence. Remove the user from one of them.","False"
```

---

## Row results

The `Result` column.

| Result | Meaning |
|---|---|
| `Success` | The change was made |
| `AlreadyMember` | The add wasn't needed; the user was already a member (someone added them since the run started). Counts as success. |
| `NotMember` | The remove wasn't needed; the user had already left the group. Counts as success. |
| `Failed` | Graph rejected the change. See `ErrorMessage`. |
| `WhatIf` | Preview run; nothing was changed |
| `Blocked` | The change limit stopped the run; nothing was changed |
| `Pending` | Not attempted, because the run stopped on an error first. Check the run's `ErrorMessage` in the JSON summary. |
| `Reported` | A conflict row; no change is made for conflicts |

---

## Change reasons

The `Reason` column on `Change` rows.

**Moving into a ring**

| Reason | Action | Meaning |
|---|---|---|
| `NewAssignment` | Add | User had no ring yet: a new user, or one an admin removed from First or Last |
| `ReturnedFromInactive` | Add | Active again; back in a computed ring (in Hash mode, their original one) |
| `Rebalance` / `InitialRun` | Add / Remove | Moved by `-Rebalance` or `-InitialRun` |
| `OrphanRingRetired` | Add / Remove | Moved out of a ring above `RingCount` (with `-RetireOrphanRings`) |

**Moving into Inactive**

| Reason | Action | Meaning |
|---|---|---|
| `Inactive:Disabled` | Add | Account is disabled |
| `Inactive:EmployeeType:<value>` | Add | `employeeType` matches `InactiveEmployeeTypes`, for example `Former` |
| `Inactive:CompanyName:<value>` | Add | `companyName` matches `InactiveCompanyNames` |
| `Inactive:UpnPattern:<pattern>` | Add | UPN matches `InactiveUpnPatterns` |
| `Inactive:NoSignInFor<N>Days` | Add | No successful sign-in for `InactiveSignInDays` |
| `Inactive:NeverSignedIn` | Add | Never signed in, and the account is older than `NewUserGraceDays` |
| `MovedToInactive` | Remove | Taken out of a ring (or First or Last, with `-RemoveInactiveFromManualRings`) because the user is now inactive. Paired with an `Inactive:…` add. |
| `NoLongerInactive` | Remove | Taken out of Inactive. Paired with a `ReturnedFromInactive` add. |

**Leaving the ring set**

| Reason | Action | Meaning |
|---|---|---|
| `ManualRingOverride:First` / `:Last` | Remove | An admin put the user in First or Last |
| `OutOfScope:Disabled` | Remove | Disabled, with `DisabledUserAction = Exclude` |
| `OutOfScope:UserType:<value>` | Remove | `userType` not in `IncludeUserTypes` (for example `Guest`) |
| `OutOfScope:EmployeeType:<value>` | Remove | `employeeType` not in `IncludeEmployeeTypes` or `InactiveEmployeeTypes`. `(empty)` means the field is blank. |
| `OutOfScope:NoLicense` | Remove | No license, with `RequireAssignedLicense` |
| `OutOfScope:ExclusionGroup` | Remove | Member of a group in `ExcludeGroupIds` |
| `OutOfScope:UpnPattern:<pattern>` | Remove | UPN matches `ExcludeUpnPatterns` |
| `OutOfScope` | Remove | Graph didn't return the user at all: deleted, or disabled while `DisabledUserAction = Exclude` |
| `DuplicateRingMembership` | Remove | Was in more than one computed ring; kept in one |

---

## Conflicts

`Conflict` rows flag things the script won't fix by itself, because First and Last are managed by people. `Action` is `None`, `Result` is `Reported`, and `ErrorMessage` says what to do.

| Reason | Meaning | What to do |
|---|---|---|
| `InFirstAndLast` | The user is in both First and Last. Last wins until you fix it. | Remove them from one group |
| `InactiveUserInManualRing` | An inactive user is in First or Last | Remove them, or set `-RemoveInactiveFromManualRings` |
| `InactiveUserNestedInManualRing` | An inactive user is in First or Last through a nested group | Remove them from the nested group |
| `ExcludedUserInManualRing` | An out-of-scope user is in First or Last. The detail gives the reason, for example `UpnPattern:SVC-{user}@{domain}`, `EmployeeType:Vendor`, or `NotReturnedByGraph` (usually disabled with `DisabledUserAction = Exclude`). | Remove them by hand if it isn't intended. Turn off with `ReportExcludedInManualRings = false`. |

---

## JSON summary

One object per run. It's the same object the script returns, and the `Details` of the `Summary` record in Log Analytics.

| Field | Type | Description |
|---|---|---|
| `RunId` | string | Matches the CSV and Log Analytics |
| `ScriptRevision` | string | Script revision that ran |
| `RingSet` | string | `GroupNameBase` |
| `Mode` | string | `Live` or `WhatIf` |
| `Result` | string | See [Run results](#run-results) |
| `ErrorMessage` | string | Why the run failed or was blocked |
| `StartTime`, `EndTime` | string | UTC, ISO 8601 |
| `DurationSeconds` | number | |
| `AssignmentMode` | string | `Hash` or `Balance` |
| `Rebalance`, `InitialRun` | bool | Whether this run re-sorted everyone |
| `CreateGroupsOnly` | bool | Whether this run only created groups. User and change counts are then 0, and `GroupsCreated` lists what was created. |
| `ExcludedByReason` | object | Excluded users counted by category: `Disabled`, `UserType`, `EmployeeType`, `NoLicense`, `ExclusionGroup`, `UpnPattern` |
| `CandidateUsers` | number | Users read from Graph |
| `ScopedUsers` | number | Users in scope, including those going to Inactive |
| `Distribution` | array | One entry per group; see below |
| `PlannedAdds`, `PlannedRemoves` | number | Changes in the plan |
| `Succeeded` | number | Rows with `Success`, `AlreadyMember` or `NotMember` |
| `Failed` | number | Rows with `Failed` |
| `Conflicts` | number | Conflict rows |
| `ChangeBaseline` | number | Current memberships of the managed groups (computed rings + Inactive) |
| `ChangePercent` | number | Planned changes as a % of `ChangeBaseline` |
| `ChangeLimitReason` | string | `WithinLimit`, `BelowFloor`, `NoChanges`, `InitialPopulation`, `Rebalance`, `InitialRun`, `Bypassed`, or `Exceeded` (run blocked) |
| `GroupsCreated` | array | Groups created this run (`-CreateGroupsOnly` or `-CreateMissingGroups`); under `-WhatIf`, the groups that would be created |
| `RetiredRingGroups` | array | Empty groups above `RingCount` that you can delete |
| `ReportPath` | string | CSV path (or the JSON path if `ReportFormat = Json`) |
| `ReportFiles` | array | Report files written, including the JSON file itself |
| `ReportsPruned` | number | Old report files deleted by retention |
| `Notification` | string | Teams notification: `NotConfigured`, `NotRequested` (this result isn't in `TeamsNotifyOn`), `Sent`, or `Failed` |
| `EmailNotification` | string | Email notification: same values (`NotRequested` means the result isn't in `EmailNotifyOn`) |
| `CertificateExpires` | string | Certificate expiry (UTC), with `AuthMode Certificate` |
| `CertificateDaysLeft` | number | Days until it expires |
| `CertificateWarning` | bool | `true` when it expires within `CertificateExpiryWarningDays` |
| `ExclusionGroups` | array | Each group in `ExcludeGroupIds`: `Id`, `DisplayName`, `Members` |
| `Network` | array | The network test before sign-in, one entry per endpoint: `Endpoint`, `Host`, `Required`, `Reachable`, `StatusCode`, `Milliseconds`, `Proxy`, `Error`. Host names only, never full URLs. |
| `LogAnalytics` | string | `NotConfigured`, `Sent`, `Failed`, or `Skipped` (WhatIf runs aren't sent) |

**`Distribution` entries:**

| Field | Description |
|---|---|
| `Ring` | `First`, `Ring01`…, `Last`, `Inactive` |
| `Group` | Group display name |
| `Members` | Users in this group **after** the run (in a `-WhatIf` run, after the planned changes) |
| `TargetPercentOfComputed` | The ring's weight. Empty for First, Last and Inactive. |
| `ActualPercentOfComputed` | Its actual share of computed-ring users. Empty for First, Last and Inactive. |

### Sample

The same run as the CSV sample:

```json
{
  "RunId": "f06aebda-dd71-4775-9b05-6e288bef651c",
  "ScriptRevision": "1.0",
  "RingSet": "SG-Deploy-Users",
  "Mode": "Live",
  "Result": "Success",
  "ErrorMessage": null,
  "StartTime": "2026-10-26T01:49:16.0293237Z",
  "EndTime": "2026-10-26T01:49:16.9533441Z",
  "DurationSeconds": 0.9,
  "AssignmentMode": "Hash",
  "Rebalance": false,
  "InitialRun": false,
  "CreateGroupsOnly": false,
  "ExcludedByReason": { "UpnPattern": 1 },
  "CandidateUsers": 401,
  "ScopedUsers": 400,
  "Distribution": [
    { "Ring": "First",    "Group": "SG-Deploy-Users-First",    "Members": 0,   "TargetPercentOfComputed": null, "ActualPercentOfComputed": null },
    { "Ring": "Ring01",   "Group": "SG-Deploy-Users-Ring01",   "Members": 31,  "TargetPercentOfComputed": 10.0, "ActualPercentOfComputed": 7.83 },
    { "Ring": "Ring02",   "Group": "SG-Deploy-Users-Ring02",   "Members": 121, "TargetPercentOfComputed": 30.0, "ActualPercentOfComputed": 30.56 },
    { "Ring": "Ring03",   "Group": "SG-Deploy-Users-Ring03",   "Members": 244, "TargetPercentOfComputed": 60.0, "ActualPercentOfComputed": 61.62 },
    { "Ring": "Last",     "Group": "SG-Deploy-Users-Last",     "Members": 1,   "TargetPercentOfComputed": null, "ActualPercentOfComputed": null },
    { "Ring": "Inactive", "Group": "SG-Deploy-Users-Inactive", "Members": 3,   "TargetPercentOfComputed": null, "ActualPercentOfComputed": null }
  ],
  "PlannedAdds": 4,
  "PlannedRemoves": 5,
  "Succeeded": 9,
  "Failed": 0,
  "Conflicts": 1,
  "ChangeBaseline": 400,
  "ChangePercent": 2.25,
  "ChangeLimitReason": "BelowFloor",
  "GroupsCreated": [],
  "RetiredRingGroups": [],
  "ReportPath": "/reports/EntraDeploymentRings_SG-Deploy-Users_20261026-014916_f06aebda.csv",
  "ReportFiles": [
    "/reports/EntraDeploymentRings_SG-Deploy-Users_20261026-014916_f06aebda.csv",
    "/reports/EntraDeploymentRings_SG-Deploy-Users_20261026-014916_f06aebda.summary.json"
  ],
  "ReportsPruned": 0,
  "Notification": "NotConfigured",
  "EmailNotification": "NotConfigured",
  "CertificateExpires": null,
  "CertificateDaysLeft": null,
  "CertificateWarning": false,
  "ExclusionGroups": [],
  "Network": [ { "Endpoint": "Microsoft Graph", "Host": "graph.microsoft.com", "Required": true, "Reachable": true, "StatusCode": 404, "Milliseconds": 84, "Proxy": null, "Error": null } ],
  "LogAnalytics": "NotConfigured"
}
```

In this small 400-user sample, Ring01 is at 7.83% against a 10% target. Hash placement is statistical, so small rings drift. At 14,500 users, the rings land within about half a percent of target. Use `-Rebalance -AssignmentMode Balance` once if you need exact sizes.

---

## Run results

The `Result` field of the JSON summary.

| Result | Meaning | Changes made? |
|---|---|---|
| `Success` | Run completed, no failed changes | Yes |
| `CompletedWithErrors` | Run completed, but some rows are `Failed` | Partly |
| `WhatIf` | Preview | No |
| `BlockedByChangeLimit` | The change limit stopped the run | No |
| `Failed` | Stopped on an error (see `ErrorMessage`). Rows not reached show `Pending`. | Possibly some, before the error |

A run that ends `BlockedByChangeLimit` or `Failed` also exits with an error, so a scheduler or Azure Automation marks the job as failed.

### Preflight results

`-Preflight` returns a different summary: `Mode = Preflight`, `Result` of `PreflightPassed`, `PreflightPassedWithWarnings` or `PreflightFailed`, counts (`Passed`, `Warnings`, `Failed`, `Skipped`), the certificate fields, and a `Checks` list with `Area`, `Check`, `Status` (`Pass`, `Warn`, `Fail`, `Skip`) and `Detail`. It writes no report files. If Log Analytics is configured, it sends one record with `RecordType = Preflight`. See [Configuration.md](Configuration.md#preflight-checks).

---

## Retention and privacy

- **Retention.** `ReportRetentionDays = N` deletes this ring set's report files older than N days, after the new report is written. The default `0` keeps everything.
  - Only files that match the naming pattern above **for this `GroupNameBase`** are deleted. Other ring sets' reports, renamed copies and unrelated files are left alone.
  - Age is the file's last-modified time.
  - Respects `-WhatIf` and `-Confirm`.
- **Privacy.** Reports contain UPNs and object IDs. Keep `ReportDirectory` access-controlled, and set a retention period that matches your records policy.
- **Azure Automation.** Files are lost when the job ends. Set `SkipReport = true` and use [Log Analytics](LogAnalytics.md) for history.

---

## Working with reports

```powershell
# Latest report
$csv = Get-ChildItem ./reports/*.csv | Sort-Object LastWriteTime | Select-Object -Last 1

# What changed, grouped
Import-Csv $csv | Where-Object RecordType -eq 'Change' |
    Group-Object Action, Reason | Sort-Object Count -Descending | Format-Table Count, Name

# Anything that failed
Import-Csv $csv | Where-Object Result -eq 'Failed' | Format-Table UserPrincipalName, GroupName, ErrorMessage -Wrap

# Conflicts to fix by hand
Import-Csv $csv | Where-Object RecordType -eq 'Conflict' | Format-Table UserPrincipalName, Reason, ErrorMessage -Wrap

# Every change ever recorded for one user, across all reports
Get-ChildItem ./reports/*.csv | Import-Csv | Where-Object UserPrincipalName -eq 'aisha.khan@contoso.com' |
    Sort-Object TimeGenerated | Format-Table TimeGenerated, Action, GroupName, Reason, Result

# Ring sizes over the last 30 runs
Get-ChildItem ./reports/*.summary.json | Sort-Object LastWriteTime | Select-Object -Last 30 | ForEach-Object {
    $s = Get-Content $_ -Raw | ConvertFrom-Json
    $row = [ordered]@{ Run = $s.StartTime; Result = $s.Result }
    foreach ($d in $s.Distribution) { $row[$d.Ring] = $d.Members }
    [pscustomobject]$row
} | Format-Table
```

**Finding a user after a UPN change:** the CSV records the UPN *at the time of the run*. Search by `UserId` to follow someone across a rename, for example `jane.doe@` becoming `jane.doe.former@`.

For KQL versions of these queries, see [LogAnalytics.md](LogAnalytics.md).
