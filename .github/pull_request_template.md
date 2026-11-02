## What and why

<!-- What does this change, and what problem does it solve? Link the issue: Fixes #123 -->

## Type of change

- [ ] Bug fix
- [ ] New feature or parameter
- [ ] Documentation only
- [ ] Build / CI

## Checklist

- [ ] `Revision` in the script header is incremented, with a new entry at the **top** of the revision history
- [ ] `CHANGELOG.md` updated
- [ ] Tests added or updated, and `Invoke-Pester -Path ./tests` passes
- [ ] `Invoke-ScriptAnalyzer` reports no warnings or errors
- [ ] Docs updated (parameter reference in `docs/Configuration.md`, and `docs/Reports.md` if outputs changed)
- [ ] New or changed parameters added to `config/EntraDeploymentRings.schema.json` (and the sample config)
- [ ] `pwsh ./tools/Test-DocLinks.ps1` passes
- [ ] If CI job names or the OS list changed: `.github/rulesets/main-branch.json` and the live ruleset updated
- [ ] No tenant data in this PR (UPNs, object IDs, report files, certificates, secrets, webhook URLs)

## Safety impact

<!-- Does this change who is placed where, what gets removed, the change limit, permissions, or what is logged? If yes, explain, and describe how you tested it (a -WhatIf run against a test tenant is ideal). -->
