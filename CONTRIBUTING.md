# Contributing

Thanks for helping improve EntraDeploymentRings. This script changes group membership in production tenants, so changes are held to a high bar for safety and testing.

## How to contribute

**Pull requests are limited to collaborators.** The project has one maintainer, and every change has to meet the rules below, so code comes in through people who have agreed to them. Anyone can still contribute:

- **Bugs:** open an issue with the bug template. Include the script `Revision`, what you ran (with tenant details removed), and what happened.
- **Ideas and changes:** open an issue with the feature template. Describe the problem first, then the change you'd like.
- **Code you've already written:** put it in the issue, as a snippet or a link to a branch or commit on your fork. If it's taken, it's applied with credit: you're added as a co-author of the commit.
- **Ongoing or larger work:** ask in an issue. Regular contributors can be invited as collaborators.
- **Security problems:** report them privately ([SECURITY.md](SECURITY.md)), not as an issue.

You can also fork the repository under the MIT licence and change your own copy however you like.

## Development setup

```powershell
Install-Module Pester -MinimumVersion 5.5 -Scope CurrentUser
Install-Module PSScriptAnalyzer -Scope CurrentUser

Invoke-Pester -Path ./tests -Output Detailed
Invoke-ScriptAnalyzer -Path ./Invoke-EntraDeploymentRings.ps1 -Settings ./PSScriptAnalyzerSettings.psd1
pwsh ./tools/Test-DocLinks.ps1
```

You don't need a tenant. The tests run end to end against an in-memory Graph emulator (`tests/FakeGraph.ps1`). If you add a Graph call, teach the emulator to answer it. [docs/Testing.md](docs/Testing.md) explains how the tests are built and lists every test.

## Rules for changes

1. **Increment the `Revision`** in the script header, and add an entry at the **top** of the revision history (newest first). Mirror it in `CHANGELOG.md`.
2. **Every behaviour change needs a test.** Changes to placement, removal, the change limit or exclusion logic need an end-to-end test against the emulator, not only a unit test.
3. **Keep it safe by default.**
   - New behaviour that adds, removes or moves users must respect `-WhatIf`, count toward the change limit, and be off by default unless clearly safe.
   - Don't add anything that edits First or Last without an explicit opt-in.
4. **Keep permissions minimal.** Don't introduce a new Graph permission without discussion. Document any you add in `docs/Setup.md` and `docs/Security.md`.
5. **Never log secrets or personal data.**
   - Credentials, tokens and webhook URLs must never reach the console, reports or Log Analytics.
   - Teams cards carry counts only.
6. **Only `Microsoft.Graph.Authentication`.** Call Graph through `Invoke-MgGraphRequest` rather than adding SDK modules.
7. **PowerShell 7.2+, cross-platform.** No Windows-only APIs in the main script.
8. **Update the docs.** New parameters go in:
   - the help block
   - the parameter reference in `docs/Configuration.md`
   - **`config/EntraDeploymentRings.schema.json`**. A test fails if a parameter is missing from the schema.
   - the sample config

   New outputs go in `docs/Reports.md`. New tests go in the catalogue in `docs/Testing.md`. If you change a config shown in `docs/Examples.md`, change the matching file in `config/examples/` too; a test keeps them identical.

## Pull requests (collaborators)

- Keep them focused: one change per PR.
- Fill in the PR template, including **Safety impact**.
- CI must pass: analyzer, Pester on Windows and Linux, doc links, Bicep build. The `main` ruleset blocks merging until it does.
- The code owner is asked to review automatically. No approval is required, so a solo maintainer can merge, but read your own diff as if someone else wrote it.

## Repository setup (maintainers)

Do this once, after the first push to `main`.

**Who can open pull requests:** Settings → General → **Pull requests** → **Collaborators only**. Everyone can still see and comment on pull requests, and open issues.

The two rulesets in [`.github/rulesets/`](.github/rulesets) hold the exact settings:

| File | Effect |
|---|---|
| `main-branch.json` | Nobody can push directly to `main`, force-push, or delete it. Changes need a pull request with all review threads resolved, and these CI checks passing on up-to-date code: `test (ubuntu-latest)`, `test (windows-latest)`, `docs`, `bicep`. **No approvals are required and nobody can bypass it.** GitHub doesn't let authors approve their own PRs, so requiring approval would lock a solo maintainer out. |
| `release-tags.json` | Only repository admins can create, move or delete `v*` tags, which are what trigger a public release. |

**Option 1: import in the browser.** Go to **Settings → Rules → Rulesets → New ruleset → Import a ruleset** and choose each file.

**Option 2: GitHub CLI** (needs admin rights on the repository):

```powershell
gh api --method POST repos/seanreiglegh/EntraDeploymentRings/rulesets --input .github/rulesets/main-branch.json
gh api --method POST repos/seanreiglegh/EntraDeploymentRings/rulesets --input .github/rulesets/release-tags.json
```

After importing:
- **Pin the checks to GitHub Actions (recommended).** Edit the `Protect main` ruleset, and for each required check choose **GitHub Actions** as the source. This stops another app from reporting a fake passing check under the same name. It isn't in the file because the app ID couldn't be verified when the file was written.
- **When a second maintainer joins,** raise *Required approvals* to 1 and turn on *Require review from Code Owners*.
- **Emergencies.** There's no bypass. An admin can set the ruleset to *Disabled*, make the fix, and set it back to *Active*. That change is recorded in the repository's audit log.

Also set **Settings → Actions → General → Workflow permissions** to **Read repository contents**. The release workflow asks for the write access it needs in its own `permissions` block.

**Renaming a CI job or changing the OS list** changes the check names GitHub reports. Update `main-branch.json`, and the live ruleset, in the same PR, or every PR will wait for a check that never reports. A test fails if the file and `ci.yml` disagree.

## Releases (maintainers)

1. Set `.VERSION` in the script's PSScriptInfo block, for example `1.1.0`.
2. Make sure `Revision` and `CHANGELOG.md` match.
3. Tag and push: `git tag v1.1.0 && git push origin v1.1.0`.
4. The release workflow runs the tests, then publishes the script, a zip and `SHA256SUMS.txt`, each with a signed build-provenance attestation (`gh attestation verify <file> -R seanreiglegh/EntraDeploymentRings`). Attestations need the repository to be public.

## Code of conduct

Be respectful and constructive. Assume good intent, critique code rather than people, and keep discussions on topic. Maintainers may remove comments or contributors that don't follow this.
