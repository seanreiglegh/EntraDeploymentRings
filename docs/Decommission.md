# Decommissioning

How to remove EntraDeploymentRings safely, either completely or one ring set at a time, without disrupting the policies that use the groups.

> **The order matters.** The ring groups are referenced by Intune assignments, Conditional Access policies and app assignments, often as **exclusions**, for example "All users except `-Inactive`". If you delete a group that a policy excludes, that exclusion silently disappears, and the policy starts applying to people it shouldn't. **Remove every reference first, then delete the groups.**

- [Before you start](#before-you-start)
- [Step 1. Stop the schedule](#step-1-stop-the-schedule)
- [Step 2. Keep a final record](#step-2-keep-a-final-record)
- [Step 3. Find and remove every reference to the groups](#step-3-find-and-remove-every-reference-to-the-groups)
- [Step 4. Delete the groups](#step-4-delete-the-groups)
- [Step 5. Remove the identity and its permissions](#step-5-remove-the-identity-and-its-permissions)
- [Step 6. Remove the runner, monitoring and logging](#step-6-remove-the-runner-monitoring-and-logging)
- [Step 7. Verify and record](#step-7-verify-and-record)
- [Partial decommissioning](#partial-decommissioning)

---

## Before you start

| Decide | Why |
|---|---|
| **Full or partial?** | Removing one ring set, the Inactive ring, or just the automation leaves different pieces behind. See [Partial decommissioning](#partial-decommissioning). |
| **What replaces it?** | Do rollouts move to Windows Autopatch, a different tool, or fixed groups? Policies need a new target before the old groups go. |
| **How long to keep the records?** | Reports and Log Analytics data are audit evidence. Agree the retention period with your records or compliance owner *before* deleting anything. |
| **Who approves?** | Treat this as a normal change with CAB approval. It touches policy targeting for every user in scope. |

You'll need:
- Groups Administrator.
- Intune Administrator, and Conditional Access Administrator (or Security Administrator).
- Application Administrator, plus Privileged Role Administrator to remove Graph permissions.
- Owner or Contributor on the Azure resources (Automation account, Log Analytics workspace, DCR).

---

## Step 1. Stop the schedule

Stop the script first, so it doesn't recreate memberships while you work.

| Where it runs | Do this |
|---|---|
| Windows Task Scheduler | `Disable-ScheduledTask -TaskName 'EntraDeploymentRings'` |
| Linux cron | Comment out the line in `crontab -e` |
| Azure Automation | Unlink or disable the schedule on the runbook |

Confirm no run is in progress before going on.

---

## Step 2. Keep a final record

```powershell
# 1. A last preview run: the full current state, in a report, without changing anything
./Invoke-EntraDeploymentRings.ps1 -ConfigPath ./config/prod.json -WhatIf

# 2. Export every ring group's membership (computed rings are rebuildable; First and Last are not)
$base = 'SG-Deploy-Users'
$filter = [uri]::EscapeDataString("startswith(displayName,'$base-')")
$groups = (Invoke-MgGraphRequest -Uri "v1.0/groups?`$filter=$filter&`$select=id,displayName,description").value |
    Where-Object { ([string]$_.description).Contains("[EntraDeploymentRings:$($base):") }   # plain substring: '[' is a wildcard in -like
foreach ($g in $groups) {
    $members = @()
    $uri = "v1.0/groups/$($g.id)/members?`$select=id,userPrincipalName&`$top=999"
    while ($uri) { $page = Invoke-MgGraphRequest -Uri $uri; $members += $page.value; $uri = $page['@odata.nextLink'] }
    $members | Select-Object @{ n = 'GroupName'; e = { $g.displayName } }, @{ n = 'GroupId'; e = { $g.id } }, @{ n = 'UserId'; e = { $_.id } }, @{ n = 'UserPrincipalName'; e = { $_.userPrincipalName } } |
        Export-Csv "./final-$($g.displayName).csv" -NoTypeInformation
}
$groups | Select-Object id, displayName | Export-Csv ./final-groups.csv -NoTypeInformation
```

Store these with your change record, under your retention policy. They let you rebuild First and Last, or prove who was in which ring, later.

> The snippets on this page use `Invoke-MgGraphRequest`, so `Microsoft.Graph.Authentication` is the only module needed. Connect first, for example: `Connect-MgGraph -Scopes 'Group.Read.All','Policy.Read.All','Application.Read.All'`.

---

## Step 3. Find and remove every reference to the groups

Check each place a group can be used. For every reference, **retarget** the policy to its replacement, or remove the assignment. Pay special attention to **exclusions**.

### Conditional Access

```powershell
$ids = $groups.id
(Invoke-MgGraphRequest -Uri 'v1.0/identity/conditionalAccess/policies').value | ForEach-Object {
    $u = $_.conditions.users
    $hits = @(@($u.includeGroups) + @($u.excludeGroups) | Where-Object { $_ -in $ids })
    if ($hits) {
        [pscustomobject]@{
            Policy   = $_.displayName
            State    = $_.state
            Included = (@($u.includeGroups) | Where-Object { $_ -in $ids }) -join ', '
            Excluded = (@($u.excludeGroups) | Where-Object { $_ -in $ids }) -join ', '
        }
    }
} | Format-Table -Wrap
```

Any policy listed under **Excluded** needs a replacement exclusion *before* the group is deleted.

### App and resource assignments

```powershell
foreach ($g in $groups) {
    (Invoke-MgGraphRequest -Uri "v1.0/groups/$($g.id)/appRoleAssignments").value |
        Select-Object @{ n = 'Group'; e = { $g.displayName } }, resourceDisplayName, appRoleId
}
```

Also check these, in their own consoles:
- Group-based licensing
- Access packages
- SharePoint and Teams permissions
- Azure RBAC role assignments

### Intune

Intune assignments can't be listed by group in a single v1.0 call. Check each area in the **Intune admin center**, and look in every policy's **Assignments** for the ring groups, in both *Included* and *Excluded* groups:

| Area | Where |
|---|---|
| Configuration profiles and settings catalog | **Devices → Configuration** |
| Compliance policies | **Devices → Compliance** |
| Update rings, feature and quality updates | **Devices → Windows updates** |
| Endpoint security policies | **Endpoint security** |
| Apps (required, available, uninstall) | **Apps → All apps** |
| App protection and configuration policies | **Apps → App protection / App configuration policies** |
| Scripts and remediations | **Devices → Scripts and remediations** |

The Entra admin center's group page can't show Intune assignments. Search Intune by group, or use your Intune reporting or export tooling if you have it.

### Anything else that uses the groups

- Feature-flag systems, third-party management tools and SaaS apps that sync these groups.
- Automation and runbooks that read the groups, including your own Sentinel or Logic Apps content.

---

## Step 4. Delete the groups

Only after Step 3 is complete:

```powershell
foreach ($g in $groups) {
    Invoke-MgGraphRequest -Method DELETE -Uri "v1.0/groups/$($g.id)"
    "Deleted $($g.displayName)"
}
```

- **Treat deletion as permanent.** Microsoft 365 groups can be restored for 30 days, but don't count on restoring a deleted **security** group. Your Step 2 exports are the way back: recreate the group with `-CreateMissingGroups` and re-add First and Last from the export.
- **Only groups with the marker.** The snippet in Step 2 selects only groups whose description carries the `[EntraDeploymentRings:<base>:…]` marker, so it can't delete an unrelated group that happens to share the prefix.
- **Repeat for each ring set,** if you ran more than one `GroupNameBase`.

---

## Step 5. Remove the identity and its permissions

### App registration (certificate or secret)

```powershell
$appId = '<client-id>'
$sp = (Invoke-MgGraphRequest -Uri "v1.0/servicePrincipals(appId='$appId')")
# 1. Disable first: blocks all sign-ins immediately
Invoke-MgGraphRequest -Method PATCH -Uri "v1.0/servicePrincipals/$($sp.id)" -Body @{ accountEnabled = $false }
# 2. Remove its Graph permissions
(Invoke-MgGraphRequest -Uri "v1.0/servicePrincipals/$($sp.id)/appRoleAssignments").value | ForEach-Object {
    Invoke-MgGraphRequest -Method DELETE -Uri "v1.0/servicePrincipals/$($sp.id)/appRoleAssignments/$($_.id)"
}
# 3. Delete the app registration (also removes its service principal)
$app = Invoke-MgGraphRequest -Uri "v1.0/applications(appId='$appId')"
Invoke-MgGraphRequest -Method DELETE -Uri "v1.0/applications/$($app.id)"
```

- Deleted app registrations can be restored for **30 days** under **App registrations → Deleted applications**.
- **Delete the certificate on the runner**, in the store of the account that ran the script:
  ```powershell
  Remove-Item "Cert:\CurrentUser\My\<thumbprint>"     # Windows; use LocalMachine\My if it was installed there
  ```
- Delete any `.pfx` copies, and remove the secret from Key Vault or the Automation credential, if one was used.

### Managed identity

Remove its Graph app role assignments, using the same loop as step 2 above with the managed identity's object ID. Then:
- **System-assigned:** turn the identity off on the Automation account, or delete the account.
- **User-assigned:** delete the identity, if nothing else uses it.

### Email permission (if email notifications were used)

```powershell
# Exchange Online PowerShell
Get-ManagementRoleAssignment -App '<client-id>' | Remove-ManagementRoleAssignment -Confirm:$false
Remove-ManagementScope -Identity 'EntraDeploymentRings sender' -Confirm:$false
Remove-ServicePrincipal -Identity '<client-id>' -Confirm:$false
```

Also decide what to do with the sender mailbox. Convert or delete it once nothing else uses it.

### Interactive admin access

If roles were granted only for this tool, for example Groups Administrator or Reports Reader through PIM, remove those eligible assignments.

---

## Step 6. Remove the runner, monitoring and logging

| Item | Action |
|---|---|
| **Scheduled task / cron** | Delete it (it was disabled in Step 1) |
| **Script, config, module** | Delete the script folder and `config/*.json`. Uninstall `Microsoft.Graph.Authentication` if nothing else uses it. |
| **Service account** | Disable or delete the dedicated account or gMSA |
| **Report files** | Keep them for the agreed retention period, then delete. They contain UPNs. |
| **Azure Automation** | Delete the runbook and schedule (or the whole account) |
| **Teams notifications** | Turn off or delete the Power Automate workflow that receives the webhook. Anyone with the old URL can post until the workflow is gone. |
| **Email notifications** | Remove the Exchange RBAC assignment and scope (Step 5). Update any mail rules or ticketing integrations that keyed on the `[EntraDeploymentRings]` subject. |
| **Sentinel / Azure Monitor alerts** | Delete the rules for this tool, so they don't fire on an empty table or go stale |
| **Data Collection Rule** | Delete the DCR. Its role assignment goes with it. |
| **Log Analytics table** | Keep `EntraDeploymentRings_CL` until its retention period has passed. Deleting the table deletes its data. |

```powershell
# Azure resources (Az PowerShell), after the retention decision
Remove-AzDataCollectionRule -ResourceGroupName '<rg>' -Name 'dcr-entra-deployment-rings'
# Only when the data is no longer needed:
Remove-AzOperationalInsightsTable -ResourceGroupName '<rg>' -WorkspaceName '<workspace>' -TableName 'EntraDeploymentRings_CL'
```

---

## Step 7. Verify and record

- [ ] No group with the `[EntraDeploymentRings:` marker remains: re-run the Step 2 query, which should return nothing.
- [ ] No Conditional Access policy, app assignment or Intune assignment references the old group IDs. Re-run the Step 3 checks.
- [ ] The service principal is disabled or deleted, and has no Graph app role assignments or Exchange RBAC assignments.
- [ ] The certificate is gone from the runner. No secret remains in Key Vault or Automation.
- [ ] Schedules, the runbook, the Teams workflow and alert rules are removed.
- [ ] Reports and Log Analytics data are retained, or disposed of, according to the agreed policy.
- [ ] The change record includes the final exports from Step 2.

**Two weeks later,** check the Entra sign-in logs for the old app ID. There should be no attempts. If there are, something still has the credential.

---

## Partial decommissioning

| Goal | What to do |
|---|---|
| **Remove one ring set**, keep others | Steps 2–4 for that `GroupNameBase` only. Delete its config file and schedule entry. Keep the identity. |
| **Stop using the Inactive ring** | Remove references to `-Inactive` (Step 3). Set `EnableInactiveRing = false`, then delete the `-Inactive` group. With the ring off, inactive and disabled users are **excluded** from every ring, not placed in one. |
| **Use fewer rings** | Not a decommission: lower `RingCount` and run with `-RetireOrphanRings -Rebalance` (see [Examples](Examples.md#5-changing-the-rings-later)). Remove references to the retired group, then delete it. |
| **Stop the automation, keep the groups** | Steps 1, 2, 5 and 6 only. The groups stay, but from now on nobody maintains them: new hires won't be placed, and departed users won't be moved to Inactive. Assign an owner to maintain them by hand, or plan their removal. |
| **Switch to a new identity** | Set up the new one ([Setup.md](Setup.md)), run with `-WhatIf` to confirm it works, then remove the old identity (Step 5). The groups don't need to change. |
