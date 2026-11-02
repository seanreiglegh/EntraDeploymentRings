# Setup: identity and permissions

The script needs an identity that can read users and change group membership. Pick one:

| Identity | Best for | Go to |
|---|---|---|
| **Your own admin account** | First run, one-off runs, creating the groups | [Option C](#option-c-your-own-admin-account) |
| **App registration + certificate** | Scheduled runs on a server or pipeline outside Azure | [Option A](#option-a-app-registration-with-a-certificate) |
| **Managed identity** | Azure Automation, Azure Functions, Azure VMs | [Option B](#option-b-managed-identity) |

**Recommended split:** create the groups once with `-CreateGroupsOnly`. Then give the scheduled identity only the three permissions below, with no group-creation rights. For which permission to use when creating, see [Creating the groups: use Group.Create](#creating-the-groups-use-groupcreate).

---

## Permissions at a glance

| Permission | Needed for |
|---|---|
| `User.Read.All` | Reading users |
| `AuditLog.Read.All` | Reading last sign-in (only if the sign-in rule is on; needs Entra ID P1/P2) |
| `GroupMember.ReadWrite.All` | Reading the ring groups and changing membership |
| `Group.Create` | **Only** for an app or managed identity that creates the groups (`-CreateGroupsOnly` or `-CreateMissingGroups`). **Not `Group.ReadWrite.All`.** See [below](#creating-the-groups-use-groupcreate). |
| `Mail.Send` | **Only** for email notifications. Scope it to one mailbox: [Security.md](Security.md#scope-mailsend-to-one-mailbox). |

**Who can grant them:**
- **Application Administrator** or **Cloud Application Administrator** can create the app registration.
- **Privileged Role Administrator** (or Global Administrator) is needed to grant admin consent for Graph *application* permissions.

### Creating the groups: use Group.Create

**Don't grant `Group.ReadWrite.All` to an app for this script.** It lets the app change or delete *every* group in the tenant, and reach Microsoft 365 groups' conversations, files and calendars. The script only ever creates its own ring groups, and changes membership through `GroupMember.ReadWrite.All`.

| Who creates the groups | Grant | Notes |
|---|---|---|
| **Nobody: the groups are created once, then left alone** (recommended for the scheduled identity) | Nothing extra | Create them with one of the rows below, then remove that permission or stop using that identity. |
| **An app registration or managed identity** | `Group.Create` + `GroupMember.ReadWrite.All` (application permissions) | `Group.Create` can create groups but not read them. `GroupMember.ReadWrite.All` lets the script find the groups that already exist. With `-CreateGroupsOnly`, `GroupMember.Read.All` is enough. |
| **You, signed in** (`-AuthMode Interactive`, the default) | `Group.ReadWrite.All` (delegated scope, requested automatically) | `Group.Create` doesn't exist as a delegated scope, so this is the only option for a signed-in user. Your access is still capped by your role: activate **Groups Administrator** through PIM for the run, and nothing more. |

**Groups created with `Group.Create` have no owner.**
- Microsoft warns that a group created through `Group.Create` without owners is created "anonymously" and the creating app can't modify it afterwards.
- That doesn't matter to this script: it never edits a group after creating it, and it changes membership through `GroupMember.ReadWrite.All`, which isn't limited to groups the app owns.
- Still, test it once in a test tenant: create the groups with the app, then check that `-InitialRun` fills them.
- Then add owners (for example, your endpoint team) in the Entra admin center, so the groups have accountable people other than Groups Administrators.

---

## Option A: App registration with a certificate

Use a certificate, not a client secret. Secrets end up pasted into config files and tickets. A certificate's private key stays in the machine's certificate store.

### Step 1. Create the certificate

Do this **on the machine that runs the script, signed in as the account that runs it**, so the key lands in that account's certificate store.

**Windows** (the private key can't be exported):

```powershell
$cert = New-SelfSignedCertificate -Subject 'CN=EntraDeploymentRings' -CertStoreLocation 'Cert:\CurrentUser\My' `
    -KeyExportPolicy NonExportable -KeySpec Signature -KeyAlgorithm RSA -KeyLength 3072 -HashAlgorithm SHA256 `
    -NotAfter (Get-Date).AddYears(1)
Export-Certificate -Cert $cert -FilePath ./EntraDeploymentRings.cer | Out-Null   # public key only
$cert.Thumbprint
```

**Linux, macOS or Windows** (PowerShell 7):

```powershell
$rsa  = [System.Security.Cryptography.RSA]::Create(3072)
$req  = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new('CN=EntraDeploymentRings', $rsa,
          [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
$temp = $req.CreateSelfSigned([DateTimeOffset]::UtcNow.AddMinutes(-5), [DateTimeOffset]::UtcNow.AddYears(1))
$flags = [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]'PersistKeySet,UserKeySet'
$cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($temp.Export('Pfx'), [string]$null, $flags)
$store = [System.Security.Cryptography.X509Certificates.X509Store]::new('My', 'CurrentUser')
$store.Open('ReadWrite'); $store.Add($cert); $store.Close()
[System.IO.File]::WriteAllBytes("$PWD/EntraDeploymentRings.cer", $cert.Export('Cert'))   # public key only
$cert.Thumbprint
```

Note the thumbprint. You'll need it later.

### Step 2. Create the app and grant permissions

Use **either** PowerShell **or** the portal.

#### With PowerShell

Run this in the same session as step 1, so `$cert` still exists. It needs the `Microsoft.Graph.Applications` module.

```powershell
Install-Module Microsoft.Graph.Applications -Scope CurrentUser
Connect-MgGraph -TenantId '<tenant-id-or-domain>' -Scopes 'Application.ReadWrite.All', 'AppRoleAssignment.ReadWrite.All'

$permissions = 'User.Read.All', 'AuditLog.Read.All', 'GroupMember.ReadWrite.All'
# Only if THIS app will create the ring groups: add 'Group.Create' (never 'Group.ReadWrite.All').

# 1. App registration (single tenant) with the certificate's public key
$app = New-MgApplication -DisplayName 'EntraDeploymentRings' -SignInAudience 'AzureADMyOrg' `
    -Notes 'Maintains deployment-ring groups. Owner: <team/contact>.' `
    -KeyCredentials @(@{ Type = 'AsymmetricX509Cert'; Usage = 'Verify'; Key = $cert.RawData; DisplayName = $cert.Subject })

# 2. Service principal (the "enterprise application")
$sp = New-MgServicePrincipal -AppId $app.AppId

# 3. Add the Graph permissions and grant admin consent
$graph  = Get-MgServicePrincipal -Filter "appId eq '00000003-0000-0000-c000-000000000000'"
$access = foreach ($p in $permissions) {
    $role = $graph.AppRoles | Where-Object { $_.Value -eq $p -and $_.AllowedMemberTypes -contains 'Application' }
    if (-not $role) { throw "Graph application permission '$p' not found." }
    @{ Id = $role.Id; Type = 'Role' }
}
Update-MgApplication -ApplicationId $app.Id -RequiredResourceAccess @(@{ ResourceAppId = $graph.AppId; ResourceAccess = @($access) })
foreach ($a in $access) {
    New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $sp.Id -PrincipalId $sp.Id -ResourceId $graph.Id -AppRoleId $a.Id | Out-Null
}

# 4. The values you need next
[pscustomobject]@{
    TenantId              = (Get-MgContext).TenantId
    ClientId              = $app.AppId
    CertificateThumbprint = $cert.Thumbprint
    ServicePrincipalId    = $sp.Id      # for Log Analytics (ingestionPrincipalId)
}
```

#### With the Microsoft Entra admin center

1. Go to **Entra ID → App registrations → New registration**.
   - Name it `EntraDeploymentRings`.
   - Choose **Single tenant**.
   - Leave **Redirect URI** empty.
   - Select **Register**.
2. On **Overview**, copy the **Application (client) ID** and the **Directory (tenant) ID**.
3. Go to **Certificates & secrets → Certificates → Upload certificate** and upload `EntraDeploymentRings.cer`.
4. Go to **API permissions → Add a permission → Microsoft Graph → Application permissions** and add:
   - `User.Read.All`
   - `AuditLog.Read.All`
   - `GroupMember.ReadWrite.All`
   - `Group.Create`, **only** if this app will create the ring groups. Never add `Group.ReadWrite.All`.
5. Remove the default `User.Read` delegated permission. It isn't used.
6. Select **Grant admin consent**. Every row should show a green *Granted*.
7. *(Recommended)* Add **Owners**, and put a note on the app saying what it does and who to contact.

### Step 3. Test

Run a preflight first. It checks the certificate, sign-in, permissions, groups and notifications, and changes nothing:

```powershell
./Invoke-EntraDeploymentRings.ps1 -ConfigPath ./config/prod.json -AuthMode Certificate `
    -TenantId '<tenant-id>' -ClientId '<client-id>' -CertificateThumbprint '<thumbprint>' -Preflight
```

Then preview a real run with `-WhatIf` in place of `-Preflight`.

| Error | Meaning |
|---|---|
| `Microsoft Graph refused access (403 …)` | A permission problem. The message says what was refused and how to fix it: see [Reading a permission error](#reading-a-permission-error). |
| Certificate not found | The certificate is in a different account's store than the one running the script. |
| `Network test failed … Can't reach …` | The machine can't reach Entra sign-in or Graph. The message names the endpoint, the reason (no response, the proxy refused it, DNS, TLS) and the proxy in use. Check the VPN, proxy allow-list and firewall for outbound HTTPS to the hosts it lists. A *TLS failed* reason usually means a TLS-inspecting proxy; exempt the Microsoft hosts from inspection. |
| `Sign-in to Microsoft Graph failed after … s` | Sign-in itself failed. The message includes the full inner error. About 100 seconds means the request got no answer: a network timeout. A fast failure with an `AADSTS…` code is a rejection by Entra ID, such as an unregistered certificate or a Conditional Access policy. |

### Reading a permission error

When Microsoft Graph refuses a call, the script stops and explains it, for example:

```text
Microsoft Graph refused access (403 Authorization_RequestDenied) while listing groups (looking for ring groups above RingCount, whose names start with 'SG-Deploy-Users-Ring').
  Request:    GET /groups?$filter=startswith(displayName,'SG-Deploy-Users-Ring')&$select=id,displayName,description
  Graph said: Insufficient privileges to complete the operation.
  Needs:      one of GroupMember.ReadWrite.All, GroupMember.Read.All, Group.Read.All, Group.ReadWrite.All, Directory.Read.All, Directory.ReadWrite.All (to read groups)
  Signed in:  app 'EntraDeploymentRings' 11111111-1111-1111-1111-111111111111 (application permissions) in tenant 22222222-2222-2222-2222-222222222222
  Token has:  AuditLog.Read.All, User.Read.All
  Fix:        Grant GroupMember.ReadWrite.All as an Application permission to this identity and select Grant admin consent (...)
  request-id: 11111111-2222-3333-4444-555555555555, 2026-01-15T12:00:00 UTC (give this to Microsoft support if you need them)
```

Compare **Needs** with **Token has**:

| What you see | Cause | Fix |
|---|---|---|
| **Token has** none of the **Needs** permissions | The permission isn't granted, admin consent is missing, or you signed in as a different identity than you expected (check **Signed in**) | Grant the first permission listed and select **Grant admin consent**. Then run again: a token issued before consent doesn't include it. A managed identity can take up to 24 hours. |
| **Token has** a **Needs** permission, and **Signed in** says *delegated* | Delegated access is limited by what the signed-in account may do, as well as by the token. | Give the account the role in [Option C](#option-c-your-own-admin-account): Groups Administrator for groups, Reports Reader for sign-in activity. Activate it in PIM if you use PIM, then sign in again. |
| **Token has** a **Needs** permission, with *application permissions* | Usually a grant made in the last few minutes. For group reads, the message also suggests adding `GroupMember.Read.All`. For membership changes, check for role-assignable groups or restricted management administrative units. | Follow the **Fix** line. |
| `401` | The token was rejected: expired, or issued for another tenant or cloud. | Sign in again; check `TenantId` and `GraphEnvironment`. |
| `Authentication_RequestFromNonPremiumTenantOrB2CTenant` | Sign-in activity needs Entra ID P1/P2. | Get the licence, or set `InactiveSignInDays` to `0`. |

To see the permissions in your current session yourself:

```powershell
Get-MgContext | Select-Object AuthType, ClientId, TenantId, Account, Scopes
```

Running with `-AuthMode ExistingConnection` uses whatever session is already open in that PowerShell window, which may not be the identity you meant to use. **Signed in** shows which one it was.

### Step 4. Renew the certificate every year

The script warns 30 days before expiry, in the log, in the summary, and in Teams and email if configured (`CertificateExpiryWarningDays`). An expired certificate stops the run before sign-in.

1. Create a new certificate (step 1).
2. Add it to the app **alongside** the old one.
3. Update `CertificateThumbprint` wherever the script runs.
4. Run `-Preflight` to confirm the new certificate works.
5. Remove the old certificate from the app.

---

## Option B: Managed identity

1. In your Azure Automation account, go to **Account Settings → Identity** and turn on the system-assigned identity.
2. Copy its **Object (principal) ID**.
3. Grant the permissions with PowerShell. The portal can't grant Graph permissions to a managed identity.

```powershell
Connect-MgGraph -TenantId '<tenant-id-or-domain>' -Scopes 'AppRoleAssignment.ReadWrite.All', 'Application.Read.All'

$miObjectId  = '<managed-identity-object-id>'
$permissions = 'User.Read.All', 'AuditLog.Read.All', 'GroupMember.ReadWrite.All'

$graph = Get-MgServicePrincipal -Filter "appId eq '00000003-0000-0000-c000-000000000000'"
foreach ($p in $permissions) {
    $role = $graph.AppRoles | Where-Object { $_.Value -eq $p -and $_.AllowedMemberTypes -contains 'Application' }
    New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $miObjectId -PrincipalId $miObjectId -ResourceId $graph.Id -AppRoleId $role.Id | Out-Null
}

# Check what was granted
Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $miObjectId |
    Select-Object @{ n = 'Permission'; e = { $id = $_.AppRoleId; ($graph.AppRoles | Where-Object Id -eq $id).Value } }
```

4. Run the script with `-AuthMode ManagedIdentity -Preflight` to check the setup, then without `-Preflight`. For a user-assigned identity, also pass `-ManagedIdentityClientId <client-id>`.

> New permissions can take **up to 24 hours** to apply to a managed identity, because its tokens are cached.

### Running in Azure Automation

1. Create a **PowerShell 7.2 or later** runtime environment.
2. Add the `Microsoft.Graph.Authentication` module to it.
3. Import `Invoke-EntraDeploymentRings.ps1` as a runbook.
4. Set parameters on the schedule. Lists use JSON, for example `["Employee","Contingent Worker"]`.
5. Set `SkipReport` to `true`, because report files are deleted when the job ends. Use [Log Analytics](LogAnalytics.md) for history instead.

---

## Option C: Your own admin account

No app registration is needed. Run the script without `-AuthMode` (the default is `Interactive`) and sign in when prompted. It requests:
- `User.Read.All`
- `AuditLog.Read.All`
- `GroupMember.ReadWrite.All`, or `Group.ReadWrite.All` when `-CreateMissingGroups` is used

With `-CreateGroupsOnly` it requests only `Group.ReadWrite.All`, and the only role you need is Groups Administrator. A signed-in user can't use `Group.Create`, because it's application-only. `Group.ReadWrite.All` is still limited by your role, so activate Groups Administrator in PIM just for that run.

Your account also needs these Entra roles. Activate them in PIM first if you use it.

| To… | Role |
|---|---|
| Read sign-in activity | Reports Reader (or Security Reader, Global Reader) |
| Create groups and change membership | Groups Administrator |

If your tenant requires admin consent for those scopes, an admin has to approve them once.

---

## Log Analytics permission

Only needed if you send results to Log Analytics. The identity needs **Monitoring Metrics Publisher** on the Data Collection Rule. The Bicep template assigns it when you pass `ingestionPrincipalId`:

| Identity | Pass this ID |
|---|---|
| App registration | The **service principal** object ID (`ServicePrincipalId` from step 2), not the app registration's object ID |
| Managed identity | Its object (principal) ID |
| Your own account | Your user object ID, with `principalType=User` |

Full instructions: [LogAnalytics.md](LogAnalytics.md)

---

## Hardening

`GroupMember.ReadWrite.All` can change membership of **any** group that isn't role-assignable, not just the ring groups. Treat the certificate or managed identity as a privileged credential.

Before going live, work through **[Security.md](Security.md)**. It covers protecting sensitive groups, locking down the runner, monitoring alerts (including changes outside the ring set) and incident response.
