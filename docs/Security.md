# Security and best practices

This script runs unattended with permission to change group membership across your tenant. This page covers how to run it safely: what to protect, how to watch it, and what to do if something goes wrong.

- [Threat model: what could go wrong](#threat-model-what-could-go-wrong)
- [Checklist](#checklist)
- [1. The identity](#1-the-identity)
- [2. The machine or service that runs it](#2-the-machine-or-service-that-runs-it)
- [3. The script and its configuration](#3-the-script-and-its-configuration)
- [4. Data: reports and logs](#4-data-reports-and-logs)
- [5. Monitoring and alerts](#5-monitoring-and-alerts)
- [6. Change control](#6-change-control)
- [7. Back up what the script can't rebuild](#7-back-up-what-the-script-cant-rebuild)
- [8. Incident response](#8-incident-response)
- [Compliance mapping](#compliance-mapping)

---

## Threat model: what could go wrong

| Risk | Example | Main defence |
|---|---|---|
| **Stolen credential** | Someone copies the certificate or secret and uses the app's Graph access | Non-exportable key, Conditional Access location policy, sign-in alerts |
| **Abuse of `GroupMember.ReadWrite.All`** | An attacker uses the app to add themselves to a group that grants access, or that exempts them from MFA via a Conditional Access exclusion group | Protect sensitive groups ([§1](#protect-sensitive-groups-from-this-permission)); alert on changes outside the ring set |
| **Tampered script** | Someone edits the `.ps1` on the runner, and it runs with the app's permissions | Write access limited to admins, code signing, hash check |
| **Tampered configuration** | Someone edits `ExcludeGroupIds` or the patterns to slip users in or out of a rollout | File permissions, config in source control with review |
| **Bad data → mass change** | An HR sync blanks `employeeType` and thousands of users drop out | Built-in change limit (default 10%) and `-WhatIf` review |
| **Data exposure** | Reports with UPNs left on a share | Folder permissions, retention, Log Analytics instead of files |
| **Mail.Send misuse** | An unscoped `Mail.Send` grant used to send phishing as the CEO or any other mailbox | Scope it to the one sender mailbox ([below](#scope-mailsend-to-one-mailbox)), or don't use email |
| **Webhook misuse** | A leaked Teams webhook URL used to post fake "all clear" or phishing cards | Treat the URL as a secret; recreate the workflow if it leaks. Cards never contain user data. |
| **Supply chain** | A modified copy of the script or a malicious module | Get it from the official repo, verify the build attestation, pin module versions |

The key point: **anyone who can change the script, its config, or the machine it runs on can act with the app's Graph permissions.** Protect all three as carefully as the credential itself.

---

## Checklist

**Identity**
- [ ] Certificate or managed identity, not a client secret
- [ ] Only `User.Read.All`, `AuditLog.Read.All` and `GroupMember.ReadWrite.All` granted
- [ ] No `Group.ReadWrite.All` as an **application** permission, ever. An app that creates the groups uses `Group.Create`; the scheduled identity has neither.
- [ ] Sensitive groups made role-assignable, or placed in a restricted management administrative unit
- [ ] App owners kept to a minimum. Owners can add credentials.
- [ ] Certificate expiry warning left on (`CertificateExpiryWarningDays`, default 30) and `CertificateExpiring` kept in `TeamsNotifyOn` / `EmailNotifyOn`
- [ ] `-Preflight` passes after every certificate renewal or permission change

**Runner**
- [ ] Dedicated service account or managed identity, with no interactive sign-in
- [ ] Only admins can write to the script folder, config and module path
- [ ] Azure Automation: only admins can edit the runbook or the account

**Script and config**
- [ ] Downloaded from the official repo, hash verified
- [ ] Signed, with `AllSigned` execution policy on the runner (recommended)
- [ ] Config kept in source control; changes reviewed

**Data and monitoring**
- [ ] `ReportDirectory` access-controlled; `ReportRetentionDays` set
- [ ] Log Analytics enabled for audit history
- [ ] Alerts: changes outside ring groups, new credentials on the app, unusual sign-in location, failed or blocked runs, missed runs
- [ ] Teams webhook URL (if used) kept outside shared config files, in an environment variable, Key Vault or an Automation variable
- [ ] `Mail.Send` (if email is used) scoped to the sender mailbox with Exchange RBAC for Applications, with no Entra-level grant

**Operations**
- [ ] If you publish or fork this repository: branch and tag rulesets from `.github/rulesets/` imported ([CONTRIBUTING.md](../CONTRIBUTING.md#repository-setup-maintainers)). A protected `main` and admin-only release tags mean the code people download has passed CI.
- [ ] `-Rebalance`, `-InitialRun` and `-BypassChangeLimit` only after a reviewed `-WhatIf`
- [ ] First and Last membership backed up
- [ ] Incident steps documented and tested

---

## 1. The identity

### Use a certificate or managed identity

| Method | Verdict | Why |
|---|---|---|
| Managed identity | **Best** in Azure | No credential exists to steal or rotate |
| Certificate, non-exportable key | **Best** on servers | The private key can't be copied off the machine |
| Certificate, exportable key | Acceptable | Protect the PFX like a password; better to recreate it non-exportable |
| Client secret | **Avoid** | Easy to leak in config files, tickets and scripts. The script refuses secrets in its config file. |

Setup steps: [Setup.md](Setup.md).

### Grant the minimum

| Permission | Scheduled runs | First run / adding rings |
|---|---|---|
| `User.Read.All` | ✔ | ✔ |
| `AuditLog.Read.All` | ✔ (only if the sign-in rule is on) | ✔ |
| `GroupMember.ReadWrite.All` | ✔ | ✔ |
| `Group.Create` (application) | ✘ | ✔ if an app creates the groups |
| `Group.ReadWrite.All` | ✘ | **Never as an application permission.** Only as the delegated scope of your own sign-in, capped by Groups Administrator |
| `Mail.Send` | Only if you use email, and **scoped to one mailbox** | — |

Create the groups once with `-CreateGroupsOnly`. If an app does it, grant `Group.Create`, not `Group.ReadWrite.All`, because `Group.ReadWrite.All` can change or delete every group and reach Microsoft 365 group content. If you do it signed in, the delegated `Group.ReadWrite.All` is capped by your Groups Administrator role, which you should activate in PIM just for that run. Either way, the scheduled identity never needs the right to create groups. Details and the no-owner caveat: [Setup.md](Setup.md#creating-the-groups-use-groupcreate).

### Protect sensitive groups from this permission

`GroupMember.ReadWrite.All` lets the app change membership of **any group that isn't role-assignable**, not just the ring groups. Groups worth shielding include:
- Conditional Access exclusion groups (for example, MFA exceptions)
- Groups that grant access to sensitive apps (EHR, finance, HR)
- Break-glass and privileged access groups

To shield them, do one of these:
- **Make them role-assignable.** Their membership then requires role-management permissions, which this app doesn't have. This only works for groups created that way.
- **Put them in a restricted management administrative unit.** Tenant-wide permissions like this one can't change them; only identities scoped to that unit can.

### Scope Mail.Send to one mailbox

Only needed if you use [email notifications](Configuration.md#email-notifications). A tenant-wide `Mail.Send` application permission lets the identity send mail **as any user**. Use **Exchange Online RBAC for Applications** to limit it to the sender mailbox. Then **don't** grant `Mail.Send` in Entra at all.

```powershell
# Exchange Online PowerShell (ExchangeOnlineManagement module), as an Exchange administrator
Connect-ExchangeOnline

$appId    = '<client-id>'                       # app registration, or the managed identity's app ID
$spObject = '<service-principal-object-id>'     # Enterprise application object ID
$sender   = 'deployment-rings@contoso.com'

# 1. Make the service principal known to Exchange
New-ServicePrincipal -AppId $appId -ObjectId $spObject -DisplayName 'EntraDeploymentRings'

# 2. A scope containing only the sender mailbox
New-ManagementScope -Name 'EntraDeploymentRings sender' -RecipientRestrictionFilter "PrimarySmtpAddress -eq '$sender'"

# 3. Grant Mail.Send within that scope only
New-ManagementRoleAssignment -App $appId -Role 'Application Mail.Send' -CustomResourceScope 'EntraDeploymentRings sender'

# 4. Check: should be allowed for the sender, and denied for any other mailbox
Test-ServicePrincipalAuthorization -Identity $appId -Resource $sender
Test-ServicePrincipalAuthorization -Identity $appId -Resource 'ceo@contoso.com'
```

- **Remove any Entra-level `Mail.Send` grant** on the app. Entra and Exchange permissions add up, so a tenant-wide grant in Entra cancels out the scoping.
- The token won't list `Mail.Send` when it's granted this way. That's expected, and the script only notes it in verbose output.
- Use a **shared mailbox** as the sender. It needs no license and has no sign-in of its own.
- **Allow 30 minutes to 2 hours** for the assignment to take effect. Exchange caches app permissions. `Test-ServicePrincipalAuthorization` bypasses that cache, so it can show *allowed* while sends still fail for a while.
- Instead of a management scope, you can scope the assignment to an **administrative unit** (`-RecipientAdministrativeUnitScope`) that contains only the sender mailbox. Microsoft's documentation recommends this option.

### Limit the app itself

- **Owners.** Anyone who owns the app registration can add a new certificate or secret to it, which is a quiet way to keep access. Keep owners to two or three named admins, and alert on credential changes ([§5](#5-monitoring-and-alerts)).
- **Sign-in location.** With Workload ID Premium, a Conditional Access policy for workload identities can block the app from signing in anywhere except your runner's IP addresses.
- **Certificate lifetime.** One year is a sensible maximum. The script warns 30 days ahead and notifies even on successful runs. An expired certificate stops the job, which is safe but disruptive. Email and Teams both deliver the advance warning, on every run inside the window. Only the "Run failed" alert on the day the certificate has *expired* needs Teams: email goes through Graph, and that run can't sign in.
- **Admin accounts.** Interactive runs use your own account. Activate Groups Administrator and Reports Reader through PIM just in time, not as standing roles.

---

## 2. The machine or service that runs it

### Windows or Linux server

- **Dedicated identity.** Run it under a dedicated service account (or a gMSA on Windows), denied interactive and remote-desktop sign-in.
- **The certificate lives in that account's store,** with a non-exportable key.
- **Folder permissions.** Only administrators can write to the script folder, config files and PowerShell module paths. Anyone who can edit those files can make the script do anything the app is allowed to do.
- **Execution policy.** Set `AllSigned` and sign the script ([§3](#3-the-script-and-its-configuration)).
- **Patching.** Keep PowerShell 7 and `Microsoft.Graph.Authentication` patched. Pin the module version you've tested.
- **Tier.** Treat the runner as a tier-0/tier-1 asset (the same tier as other identity-management servers), not a general-purpose utility box.

### Azure Automation

- **Account access is the same as running code as the managed identity.** Anyone with Contributor (or Automation Contributor) on the Automation account can edit the runbook and run code as the managed identity. Limit those roles to the admins who would also be trusted with the app's Graph permissions.
- Use **Automation Job Operator** for people who only need to start jobs or read output.
- **Lock the module versions** in the runtime environment.
- Report files are deleted with the job's sandbox. Use **Log Analytics** for history.

---

## 3. The script and its configuration

### Verify what you download

Download only from the official repository's **Releases** page.

**Best: verify the build attestation.** Every release file has a signed build-provenance attestation. It proves the file was built by this repository's release workflow, from a specific commit, and hasn't changed since. It needs the GitHub CLI:

```powershell
gh attestation verify ./Invoke-EntraDeploymentRings.ps1 -R seanreiglegh/EntraDeploymentRings
```

This is stronger than a checksum. Someone who could tamper with a release could also replace `SHA256SUMS.txt` next to it, but they can't forge an attestation signed for this repository's workflow.

**Alternative: compare the checksum.** Every release also includes a `SHA256SUMS.txt`:

```powershell
$expected = (Select-String -Path ./SHA256SUMS.txt -Pattern 'Invoke-EntraDeploymentRings\.ps1').Line.Split(' ')[0]
$actual   = (Get-FileHash ./Invoke-EntraDeploymentRings.ps1 -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actual -eq $expected) { 'Hash matches' } else { throw 'HASH MISMATCH: do not run this file' }
```

Both checks prove *where a file came from*, not that its code is safe. Code review of the release, and the CHANGELOG, are still what tell you that.

Review the diff before upgrading. The CHANGELOG and the script's revision history list every change.

### Sign it (recommended)

```powershell
$cert = Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert | Select-Object -First 1
Set-AuthenticodeSignature -FilePath ./Invoke-EntraDeploymentRings.ps1 -Certificate $cert -TimestampServer 'http://timestamp.digicert.com'
```

With `Set-ExecutionPolicy AllSigned` on the runner, an edited script won't run until someone with the signing certificate re-signs it.

### Pin dependencies

```powershell
# Install a specific, tested version, or mirror it to an internal repository
Install-Module Microsoft.Graph.Authentication -RequiredVersion '<tested version>' -Scope AllUsers
```

### Treat the configuration as code

The config file decides **who receives changes first and who is exempt**. Changing it can quietly move people in or out of a rollout.
- Keep it in source control and require review for changes, especially to `ExcludeGroupIds`, the exclusion and inactive patterns, and `MaxChangePercent`.
- Only admins can write to it on the runner.
- Never put secrets in it. The script rejects `ClientSecret` in the file.
- `Rebalance`, `InitialRun` and `CreateGroupsOnly` are also rejected in the file, so a one-time action can't become a daily one by accident.

---

## 4. Data: reports and logs

Reports and Log Analytics records contain **user principal names and object IDs**. Treat them as internal identity data.

| Store | Recommendation |
|---|---|
| `ReportDirectory` | Access-controlled folder, readable only by admins and the service account. Not a general file share. |
| Retention | Set `ReportRetentionDays` to match your records policy, for example 180 or 365. The default `0` keeps everything forever. |
| Log Analytics | Set table retention in the Bicep template (`retentionInDays`). Limit who can read `EntraDeploymentRings_CL` (workspace or table-level RBAC). |
| Copies | Don't attach full reports to tickets. Filter to the rows you need. |

The script never writes credentials, tokens or secrets to reports or logs.

---

## 5. Monitoring and alerts

Turn on [Log Analytics](LogAnalytics.md) for run history. Then add these alerts in Microsoft Sentinel or Azure Monitor.

> Column names can vary slightly between workspaces and table versions. Test each query in your workspace before saving it as an alert.

### The app changed a group outside the ring set

Needs Entra audit logs (`AuditLogs`) in the workspace. **High severity:** the app should never do this.

```kusto
let appId = "<client-id or managed identity app id>";
let ringPrefix = "SG-Deploy-Users-";
AuditLogs
| where OperationName in ("Add member to group", "Remove member from group")
| where tostring(InitiatedBy.app.appId) == appId
| mv-apply p = TargetResources[0].modifiedProperties on (
    where tostring(p.displayName) == "Group.DisplayName"
    | project GroupName = trim('"', coalesce(tostring(p.newValue), tostring(p.oldValue))))
| where not(GroupName startswith ringPrefix)
| project TimeGenerated, OperationName, GroupName, Target = tostring(TargetResources[0].userPrincipalName), CorrelationId
```

### A credential was added to the app

A new certificate or secret is a common way to keep access after a compromise.

```kusto
let appObjectName = "EntraDeploymentRings";
AuditLogs
| where OperationName has "Certificates and secrets management"
   or OperationName in ("Add service principal credentials", "Update application")
| where tostring(TargetResources[0].displayName) == appObjectName
| project TimeGenerated, OperationName, Actor = coalesce(tostring(InitiatedBy.user.userPrincipalName), tostring(InitiatedBy.app.displayName)), Result
```

### The app signed in from somewhere unexpected

Needs the `AADServicePrincipalSignInLogs` diagnostic category. Managed identities log to `AADManagedIdentitySignInLogs` instead.

```kusto
let appId = "<client-id>";
let runnerIps = dynamic(["203.0.113.10"]);
AADServicePrincipalSignInLogs
| where AppId == appId
| where IPAddress !in (runnerIps) or ResultType != "0"
| project TimeGenerated, IPAddress, Location, ResultType, ResultDescription
```

### A run failed, was blocked, or didn't happen

See [LogAnalytics.md](LogAnalytics.md#alert-rules-azure-monitor-or-sentinel-analytics). Treat `BlockedByChangeLimit` as something to investigate, not just a nuisance. It's the control doing its job.

### Optional: everything the app did in Graph

If you collect the `MicrosoftGraphActivityLogs` table, you can see every Graph call the app made. That's useful for investigations:

```kusto
MicrosoftGraphActivityLogs
| where AppId == "<client-id>"
| extend Path = tostring(split(RequestUri, "?")[0])
| summarize Calls = count() by RequestMethod, Path, bin(TimeGenerated, 1d)
```

---

## 6. Change control

| Action | Treat as | Do this first |
|---|---|---|
| Daily scheduled run | Standard change | Nothing. The change limit guards it. |
| Editing the config (scope, patterns, exclusions) | Normal change | `-WhatIf` run; review the CSV ([Reports.md](Reports.md)) |
| `-Rebalance` / `-InitialRun` | Normal change, CAB if your process requires | `-WhatIf` run; review; schedule outside critical rollout windows |
| `-BypassChangeLimit` | Normal change | Find out *why* the limit tripped ([Examples](Examples.md#6-when-a-run-is-blocked)). Don't bypass a `OutOfScope` spike you can't explain. |
| Raising `MaxChangePercent` | Normal change | Justify it. A higher limit weakens the main safety control. |
| Upgrading the script | Normal change | Read the CHANGELOG, verify the hash, run `-WhatIf` |

**Timing.** Don't rebalance in the middle of a rollout. Moving users between rings mid-rollout can give someone a change early, or skip them.

---

## 7. Back up what the script can't rebuild

The script can always rebuild the computed rings and Inactive. **First and Last are hand-picked**, so they're the only state that can't be recreated. Export them on a schedule:

```powershell
# Needs Microsoft.Graph.Groups; run with read access to groups
foreach ($name in 'SG-Deploy-Users-First', 'SG-Deploy-Users-Last') {
    $g = Get-MgGroup -Filter "displayName eq '$name'"
    Get-MgGroupMember -GroupId $g.Id -All |
        Select-Object Id, @{ n = 'UserPrincipalName'; e = { $_.AdditionalProperties.userPrincipalName } } |
        Export-Csv "./backup/$name-$(Get-Date -Format yyyyMMdd).csv" -NoTypeInformation
}
```

---

## 8. Incident response

### Suspected credential compromise

1. **Contain.** Disable the app's service principal. This blocks every credential at once:
   ```powershell
   Update-MgServicePrincipal -ServicePrincipalId '<service-principal-object-id>' -AccountEnabled:$false
   ```
   For a managed identity, remove its Graph app role assignments, or disable the Automation schedule.
2. **Remove credentials.** Delete all certificates and secrets on the app registration. Check that no credential was added you don't recognise.
3. **Scope.** Run the [outside-the-ring-set query](#the-app-changed-a-group-outside-the-ring-set) over the suspected window. Also check `MicrosoftGraphActivityLogs` if you collect it.
4. **Repair.**
   - **Other groups:** reverse any membership changes the audit log shows.
   - **Ring groups:** compare against the last trusted CSV report, or simply re-run the script, which rebuilds the computed rings and Inactive.
   - **First and Last:** restore them from backup ([§7](#7-back-up-what-the-script-cant-rebuild)).
5. **Recover.** Create a new certificate on a clean runner ([Setup.md](Setup.md)), re-enable the service principal, and run `-WhatIf` before the first live run.

### Unexpected mass change (not malicious)

1. Stop the schedule.
2. Read the run's CSV and group it by `Reason` ([Reports.md](Reports.md#working-with-reports)) to find the cause, for example an HR sync that blanked `employeeType`.
3. Fix the source data or the config, run `-WhatIf`, then run normally. Sticky placement in Hash mode means returning users go back to their original rings.

### Reporting a vulnerability in this script

See [SECURITY.md](../SECURITY.md).

---

## Compliance mapping

How the script and the practices on this page **support** common control frameworks:

- **HIPAA** Security Rule (45 CFR 164)
- **NIST SP 800-53** Rev. 5
- **NIST Cybersecurity Framework (CSF)** 2.0
- **ISO/IEC 27001:2022** Annex A

> **Read this first.**
> - This maps *capabilities* to controls. It isn't a compliance determination or audit evidence on its own. Your risk analysis and control owners decide what applies and whether it's met.
> - Control IDs follow the versions named above. Check them against the current published standards before citing them in an audit.
> - **HITRUST CSF** maps to these frameworks. Use your HITRUST mapping to carry these rows across, rather than relying on control numbers listed here.

### Cross-reference by capability

| # | Capability | How it's provided | HIPAA | NIST 800-53 Rev. 5 | NIST CSF 2.0 | ISO 27001:2022 |
|---|---|---|---|---|---|---|
| 1 | **Staged deployment of changes** | Users split into ordered rings, so changes and patches reach a small group first | §164.308(a)(1)(ii)(B) Risk management | CM-3 Configuration Change Control; CM-4 Impact Analyses; SI-2 Flaw Remediation | PR.PS-01 Configuration management; PR.PS-02 Software maintenance | 8.32 Change management; 8.19 Installation of software on operational systems; 8.8 Management of technical vulnerabilities |
| 2 | **Departed and inactive accounts set aside** | Disabled, `employeeType = Former`, `….former@` and dormant accounts are moved to Inactive automatically | §164.308(a)(3)(ii)(C) Termination procedures | AC-2 Account Management, incl. AC-2(3) Disable Accounts; PS-4 Personnel Termination | PR.AA-01 Identities and credentials managed | 5.18 Access rights; 6.5 Responsibilities after termination or change of employment |
| 3 | **Least privilege for the automation** | Only `User.Read.All`, `AuditLog.Read.All` and `GroupMember.ReadWrite.All`; group creation done interactively; sensitive groups protected | §164.308(a)(4) Information access management; §164.312(a)(1) Access control | AC-6 Least Privilege; AC-6(9) Log Use of Privileged Functions | PR.AA-05 Access permissions managed (least privilege) | 5.15 Access control; 8.2 Privileged access rights |
| 4 | **Strong non-human authentication** | Certificate with non-exportable key, or managed identity; no secrets in config; Conditional Access for workload identities | §164.312(d) Person or entity authentication | IA-5 Authenticator Management; IA-9 Service Identification and Authentication | PR.AA-01; PR.AA-03 Users, services and hardware authenticated | 5.16 Identity management; 5.17 Authentication information; 8.5 Secure authentication |
| 5 | **Audit trail of every change** | Each membership change recorded with who, what, when and why (`RunId`, `Reason`, `Result`); optional Log Analytics | §164.312(b) Audit controls | AU-2 Event Logging; AU-3 Content of Audit Records; AU-12 Audit Record Generation | PR.PS-04 Log records generated | 8.15 Logging |
| 6 | **Review and alerting** | Sentinel / Azure Monitor alerts: changes outside ring groups, new app credentials, unexpected sign-ins, failed, blocked or missed runs | §164.308(a)(1)(ii)(D) Information system activity review | AU-6 Audit Record Review, Analysis, and Reporting; SI-4 System Monitoring | DE.CM-03 Personnel activity and technology usage monitored; DE.CM-09 Computing hardware, software and runtime environments monitored | 8.16 Monitoring activities |
| 7 | **Protection and retention of audit data** | Access-controlled report folder; `ReportRetentionDays`; Log Analytics retention and table RBAC | §164.316(b)(2)(i) Documentation retention (time limit) | AU-9 Protection of Audit Information; AU-11 Audit Record Retention | PR.DS-01 Data-at-rest protected | 5.33 Protection of records; 8.10 Information deletion |
| 8 | **Safe change control** | `-WhatIf` preview, change limit (default 10%), config under source control, one-off actions blocked from config files | §164.312(c)(1) Integrity | CM-3; CM-4; CM-5 Access Restrictions for Change | PR.PS-01 | 8.32 Change management; 8.9 Configuration management |
| 9 | **Integrity of the automation** | Hash verification, code signing with `AllSigned`, pinned module versions, write-restricted runner | §164.312(c)(1) Integrity | SI-7 Software, Firmware, and Information Integrity; CM-14 Signed Components; SR-4 Provenance | PR.PS-02; GV.SC Cybersecurity supply chain risk management | 8.19 Installation of software on operational systems; 5.21 Managing information security in the ICT supply chain |
| 10 | **Protected runtime** | Dedicated service account, no interactive sign-in, tiered host; Automation RBAC limited | §164.308(a)(4); §164.312(a)(1) | AC-2; AC-6; CM-7 Least Functionality | PR.AA-05; PR.PS-01 | 8.2 Privileged access rights; 8.9 Configuration management |
| 11 | **Backup of hand-maintained data** | Scheduled export of First and Last membership | §164.308(a)(7)(ii)(A) Data backup plan (by analogy: group membership isn't ePHI) | CP-9 System Backup | PR.DS-11 Backups of data created, protected, maintained and tested | 8.13 Information backup |
| 12 | **Incident response** | Documented containment (disable service principal), credential removal, scoping, repair and recovery steps | §164.308(a)(6) Security incident procedures | IR-4 Incident Handling; IR-8 Incident Response Plan | RS.MA Incident management; RC.RP Incident recovery plan execution | 5.24 Incident management planning and preparation; 5.26 Response to information security incidents |
| 13 | **Handling of personal data in reports** | Reports limited to UPN and object ID; access control and retention guidance | §164.312(a)(1); §164.502(b) Minimum necessary | PT-2 Authority to Process PII; SI-12 Information Management and Retention | PR.DS-01 | 5.34 Privacy and protection of PII |

### Responsibility split

The script supplies some of each control. **You** supply the rest:

| The script provides | You provide |
|---|---|
| Ring groups kept accurate; inactive accounts set aside | Assigning changes to rings in the right order; the rollout schedule |
| A record of every change, and a summary per run | Log Analytics or report storage, retention settings, and regular review |
| A change limit, preview mode, and refusal of unsafe config | A change-approval process for `-Rebalance`, `-BypassChangeLimit` and config edits |
| Minimum permission requirements, and no secrets in config | Least-privilege grants, credential protection, Conditional Access, protected sensitive groups |
| — | Host hardening, script signing, alert rules, backups, incident response |
| — | HR processes that set `employeeType` or disable accounts on termination |
