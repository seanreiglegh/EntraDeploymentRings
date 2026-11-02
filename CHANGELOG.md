# Changelog

Most recent first. The script header carries the matching `Revision`, and `.VERSION` carries the same number for releases.

## 1.0.0 — 2026-11-01

First public release.

### Rings
- Creates and maintains cloud-only, assigned-membership security groups: `{Base}-First`, `{Base}-Ring01..NN`, `{Base}-Last` and `{Base}-Inactive`.
- Every in-scope user is in exactly one ring. Precedence is Inactive > Last > First > computed.
- **Weighted computed rings** (`RingWeights`, which must add up to 100).
- **Users stay in their ring between runs.** Only new or returning users are placed, by `Hash` (deterministic) or `Balance` (fills the ring furthest below target). `-InitialRun` / `-Rebalance` re-place everyone once and are command line only.
- **First and Last** are maintained by hand. A user added there leaves their computed ring on the next run. Out-of-scope users found there are reported, never removed, unless you opt in.

### Inactive and scope
- **Inactive** collects:
  - disabled accounts (`DisabledUserAction`)
  - `employeeType` and `companyName` matching `Former`
  - UPN patterns such as `{user}.former@{domain}`
  - accounts with no successful sign-in for N days, with a grace period for new users

  Each rule can be configured or turned off, and so can the ring itself.
- **Scope:** `employeeType` (default Employee and Contingent Worker), `userType`, licence, exclusion groups, and UPN patterns such as `SVC-{user}@{domain}` (`{user}`, `{domain}`, `*`, `?`).

### Safety
- `-WhatIf` / `-Confirm`, and `-Preflight`, which checks network, certificate, sign-in, permissions, groups, report folder and notifications, and changes nothing.
- A change-limit circuit breaker (`MaxChangePercent`, `MaxChangeFloor`). It doesn't apply to the first fill, `-InitialRun` or `-Rebalance`.
- An ownership marker in every group's description. Same-named groups without it are refused.
- Groups are created only with `-CreateGroupsOnly` (create, then stop, with no users read) or `-CreateMissingGroups`. A partial set is never created.
- Orphan-ring protection when `RingCount` is reduced (`-RetireOrphanRings`). Removals are applied before additions.
- `ClientSecret`, `Rebalance`, `InitialRun`, `Preflight` and `CreateGroupsOnly` are rejected in configuration files.

### Diagnostics
- **Network test before every run:** Entra sign-in or the managed identity endpoint, Graph, and the Log Analytics and Teams hosts. It stops at once, with the reason, when sign-in or Graph can't be reached.
- **Logged progress** for sign-in, reading ring groups, reading users and applying membership changes, with progress bars and throttling waits.
- **Graph 401/403 errors are explained:** the operation, the request, the permission needed, the token's permissions, the fix and the request-id. A signed-in user's UPN is never included.
- **Sign-in failures** show the full inner error chain, and a timeout is flagged as one.

### Permissions
- Scheduled runs: `User.Read.All`, `AuditLog.Read.All` (sign-in rule only) and `GroupMember.ReadWrite.All`.
- Creating groups: `Group.Create` for an app, never `Group.ReadWrite.All`. For a signed-in user, the delegated `Group.ReadWrite.All` is capped by their role.

### Reporting and notifications
- CSV and/or JSON reports (`ReportFormat`), with retention (`ReportRetentionDays`). The JSON summary is written last.
- Teams (Workflows webhooks) and email (Graph `sendMail`) notifications. They carry counts only, never user names. Email is sent only from the run's own sign-in.
- Certificate expiry warning (`CertificateExpiryWarningDays`).
- Optional Log Analytics through the Logs Ingestion API, with a Bicep template for the DCR and custom table.

### Platform
- PowerShell 7.2+ on Windows, Linux and macOS. The only module needed is `Microsoft.Graph.Authentication`; Graph is called through `Invoke-MgGraphRequest` with `$batch` and retry honouring `Retry-After`.
- Auth: Interactive, Certificate, ClientSecret, ManagedIdentity and ExistingConnection, in the Global, USGov, USGovDoD and China clouds.

### Project
- 244 Pester tests against an in-memory Graph emulator; CI on Windows and Linux, a documentation link check and a Bicep build.
- GitHub rulesets for `main` and release tags, and a release workflow with SHA-256 checksums and build-provenance attestations.
- Docs: Setup, Configuration, Examples, Operations, Reports, Security (with NIST 800-53, NIST CSF 2.0, ISO 27001 and HIPAA mapping), Log Analytics, Testing and Decommissioning.
