# Operations

- [Safety features](#safety-features)
- [Reports](#reports)
- [Things to know](#things-to-know)

---

## Safety features

| Feature | What it does |
|---|---|
| `-WhatIf` / `-Confirm` | Preview everything. `-Confirm` asks once per group, not once per user. |
| **Change limit** | Stops if a run would change more than `MaxChangePercent` (10%) of memberships **and** more than `MaxChangeFloor` (25) users. Nothing is changed, and the plan is saved to the report as `Blocked`. |
| **Missing groups** | Without `-CreateGroupsOnly` or `-CreateMissingGroups`, a missing group stops the run before anything changes. |
| **Marker check** | The script won't touch a group whose description lacks its marker. |
| **Network test** | Every run, and every preflight, starts by making one HTTPS request to each endpoint it needs: Entra sign-in (or the managed identity endpoint), Microsoft Graph, and the Log Analytics and Teams hosts if configured. Each result is logged with its status, time and proxy. If sign-in or Graph can't be reached, the run stops at once with the reason, instead of hanging for about 100 seconds at sign-in. An unreachable optional endpoint only warns. |
| **Preflight** | `-Preflight` checks the network, sign-in, permissions, groups, the certificate and every notification channel, without changing anything. |
| **Certificate expiry** | Warns (and notifies) 30 days ahead; an expired certificate stops the run before sign-in with renewal instructions. |
| **Exclusion groups** | A missing exclusion group stops the run, so break-glass and service accounts are never pulled into rings. |
| **Removals first** | Users are removed before they're added, so nobody is in two rings mid-run. |
| **Fewer rings** | Lowering `RingCount` stops the run until you add `-RetireOrphanRings`. Once emptied, the old groups only trigger a warning. |
| **Manual rings** | First and Last are never edited, unless you set `-RemoveInactiveFromManualRings`. |
| **Throttling** | Graph throttling (429) and server errors are retried, honouring `Retry-After`. |

### When the change limit stops a run

1. Open the CSV report ([columns](Reports.md#csv-columns)). Every planned change is listed with `Result = Blocked`. If [Teams notifications](Configuration.md#teams-notifications) are on, the card shows the top reasons.
2. If the changes look right, run again with `-BypassChangeLimit`.
3. If they don't, look for the cause. Common ones:
   - A changed scope filter.
   - A mass account disable.
   - Graph returning incomplete data.

The change limit **doesn't apply** to:
- The very first fill of empty groups.
- `-Rebalance` and `-InitialRun`.

Preview those with `-WhatIf`.

---

## Reports

Every run writes a CSV of changes and a JSON summary, returns the summary, and can send both to Log Analytics.

**Everything about them is in [Reports.md](Reports.md):** file names, every column, row and run results, all change reasons, conflicts and what to do about them, retention, and ready-made queries.

---

## Things to know

- **Changing ring sizes doesn't move anyone.** New weights only affect new users. Use `-Rebalance` to re-sort everyone.
- **Changing `GroupNameBase` creates a separate ring set.** Changing `HashSeed` changes where new users land.
- **Sign-in data lags** by a few hours. Keep `InactiveSignInDays` well above how often you run the script.
- **Group changes take a few minutes** to show up in Graph. Don't run two copies against the same ring set at the same time.
- **Disabled users go to Inactive** by default. In a tenant that keeps disabled leavers for a long time, Inactive can be large. That's expected, and it keeps those accounts out of every rollout. Use `DisabledUserAction = Exclude` if you'd rather drop them.
- **A mass disable shows up as Inactive moves**, not removals. A large offboarding batch can therefore trip the change limit; see [Examples: When a run is blocked](Examples.md#6-when-a-run-is-blocked).
