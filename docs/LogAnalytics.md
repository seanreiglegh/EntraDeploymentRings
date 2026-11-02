# Log Analytics integration

Revision: 1.0

`Invoke-EntraDeploymentRings.ps1` can send every run to a Log Analytics workspace (and therefore Microsoft Sentinel) through the **Logs Ingestion API**. The legacy HTTP Data Collector API was retired on 14 September 2026 and is not supported.

## 1. Deploy the table and Data Collection Rule

```bash
az deployment group create \
  --resource-group <workspace-rg> \
  --template-file infra/loganalytics-dcr.bicep \
  --parameters workspaceName=<workspace> ingestionPrincipalId=<object-id-of-runner>
```

`ingestionPrincipalId` is the **object ID** of the identity that runs the script:

- **App registration:** use the enterprise application (service principal) object ID, not the app registration object ID.
- **Managed identity:** use its principal ID.
- **Interactive runs:** pass your own user object ID with `principalType=User`.

The template creates:

| Resource | Purpose |
|---|---|
| `EntraDeploymentRings_CL` | Custom table (Analytics plan) |
| Data Collection Rule, kind `Direct` | Receives the `Custom-EntraDeploymentRings_CL` stream. It has its own ingestion endpoint, so no separate DCE is needed. |
| Monitoring Metrics Publisher role assignment | Lets the runner post to the DCR |

The outputs map to the script parameters:

| Output | Parameter |
|---|---|
| `logIngestionEndpoint` | `-LogIngestionEndpoint` |
| `dcrImmutableId` | `-LogDcrImmutableId` |
| `streamName` | `-LogStreamName` (the default already matches) |

Role assignments can take several minutes to propagate. The first run after deployment may log a 403 warning. Ring changes still apply, because a Log Analytics failure never fails the run.

## 2. How the token is obtained

| AuthMode | Azure Monitor token source |
|---|---|
| ManagedIdentity | `IDENTITY_ENDPOINT` (Automation, Functions, App Service) or IMDS (VMs, Arc) |
| Certificate | Client-credentials flow with a signed JWT assertion |
| ClientSecret | Client-credentials flow |
| Interactive / ExistingConnection | `Get-AzAccessToken` (requires Az.Accounts and `Connect-AzAccount`) |

The token is acquired **before** any group change, so a broken logging configuration stops the run early instead of producing unlogged changes.

## 3. Schema

| Column | Type | Notes |
|---|---|---|
| TimeGenerated | datetime | |
| RunId | string | Correlates every record from one run |
| RecordType | string | `Change`, `Conflict`, `Summary`, or `Preflight` (one test record from `-Preflight`) |
| RingSet | string | `GroupNameBase` |
| Action | string | `Add`, `Remove` or `None` |
| UserId, UserPrincipalName | string | |
| GroupName, GroupId, RingKey | string | `RingKey` is `First`, `Ring01`…, `Last` or `Inactive` |
| Reason | string | See [Operations.md](Reports.md#change-reasons) for the full list. For Summary records, this is the change-limit reason. |
| Result | string | Change: `Success`, `AlreadyMember`, `NotMember`, `Failed`, `Blocked` or `WhatIf`. Summary: the run result. |
| ErrorMessage | string | |
| IsWhatIf | boolean | |
| ScriptRevision | string | |
| Details | dynamic | Summary records only: the full summary object |

## 4. KQL

Run history:

```kusto
EntraDeploymentRings_CL
| where RecordType == "Summary"
| extend d = Details
| project TimeGenerated, RingSet, Result, ScopedUsers = toint(d.ScopedUsers),
          Adds = toint(d.PlannedAdds), Removes = toint(d.PlannedRemoves),
          Failed = toint(d.Failed), ChangePercent = todouble(d.ChangePercent), RunId
| order by TimeGenerated desc
```

Ring distribution over time:

```kusto
EntraDeploymentRings_CL
| where RecordType == "Summary" and Result in ("Success", "CompletedWithErrors")
| mv-expand ring = Details.Distribution
| project TimeGenerated, RingSet, Ring = tostring(ring.Ring), Members = toint(ring.Members)
| render timechart
```

Who moved into Inactive in the last 7 days, and why:

```kusto
EntraDeploymentRings_CL
| where TimeGenerated > ago(7d) and RecordType == "Change" and RingKey == "Inactive" and Action == "Add"
| project TimeGenerated, UserPrincipalName, Reason
```

Change history for one user:

```kusto
EntraDeploymentRings_CL
| where RecordType == "Change" and UserPrincipalName =~ "user@contoso.com"
| project TimeGenerated, Action, GroupName, Reason, Result
| order by TimeGenerated asc
```

### Alert rules (Azure Monitor or Sentinel analytics)

Circuit breaker tripped or run failed:

```kusto
EntraDeploymentRings_CL
| where RecordType == "Summary" and Result in ("BlockedByChangeLimit", "Failed", "CompletedWithErrors")
| project TimeGenerated, RingSet, Result, ErrorMessage, RunId
```

Sign-in certificate expiring (set the window to match `CertificateExpiryWarningDays`):

```kusto
EntraDeploymentRings_CL
| where RecordType == "Summary" and TimeGenerated > ago(2d)
| extend daysLeft = toint(Details.CertificateDaysLeft)
| where isnotnull(daysLeft) and daysLeft < 30
| summarize arg_max(TimeGenerated, daysLeft, ExpiresUtc = tostring(Details.CertificateExpires)) by RingSet
```

Missed run. The ring set hasn't reported in 26 hours, assuming a daily schedule:

```kusto
EntraDeploymentRings_CL
| where RecordType == "Summary"
| summarize LastRun = max(TimeGenerated) by RingSet
| where LastRun < ago(26h)
```

Unusual movement. More than 5% of scoped users changed in one run, even if below the breaker:

```kusto
EntraDeploymentRings_CL
| where RecordType == "Summary"
| extend scoped = toint(Details.ScopedUsers), changes = toint(Details.PlannedAdds) + toint(Details.PlannedRemoves)
| where scoped > 0 and changes * 100.0 / scoped > 5
```
