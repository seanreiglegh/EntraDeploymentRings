# Security policy

## Reporting a vulnerability

Please **don't open a public issue** for security problems.

Report them privately through GitHub: on this repository's **Security** tab, choose **Report a vulnerability**. Include:
- What the problem is, and its impact.
- Steps to reproduce, with tenant-specific details removed.
- The script `Revision` (from the file header) and your PowerShell and `Microsoft.Graph.Authentication` versions.

You'll get an acknowledgement, and updates as the issue is investigated and fixed. Fixes are listed in [CHANGELOG.md](CHANGELOG.md).

**Never include real tenant data in a report:** no UPNs, object IDs, report files, certificates, secrets or tokens.

## Supported versions

Only the latest revision gets security fixes. Check the `Revision` line at the top of `Invoke-EntraDeploymentRings.ps1`.

## Running it securely

See [docs/Security.md](docs/Security.md) for hardening, monitoring and incident-response guidance.
