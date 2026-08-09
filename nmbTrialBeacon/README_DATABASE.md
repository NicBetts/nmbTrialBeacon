# TrialBeacon — Database Placement

The app reads the clinical-trials dataset **directly** from a bundled,
read-only SQLite file. Nothing is imported into SwiftData at runtime.

## Where to put the database

```
nmbTrialBeacon/nmbTrialBeacon/trialbeacon.sqlite
```

### Important details

- **Exact file name:** `trialbeacon.sqlite`
- Prefer **schema version 14** (`IOS_CHANGES_schema_v14.md`): site publication
  counters + `popular_condition` / `lookup_intervention` / `popular_intervention`
  on top of v13 publications + Drugs@FDA.
- **Supported range only:** schema **v13 and v14**.
  - Client: `TrialStore.minimumSchemaVersion = 13`,
    `supportedSchemaVersion = 14`.
  - Older than 13 or newer than 14 is **refused** at open.
- Per-version deltas: `IOS_CHANGES_schema_v10.md` … `v14.md`.
  Core contract + evolution note: `TRIALBEACON_DATABASE.md`.
- Condition counts / filter-menu entries can shift across label-merge eras —
  do not assert exact counts from an older snapshot against a newer file.

## Analytics scopes

| Toggle combo | `scope` |
|---|---|
| (none) | `all` |
| Active only | `active` |
| Exclude Healthy | `all_excl_healthy` |
| Both | `active_excl_healthy` |

`agg_condition_by_year` queries **must** include `AND scope = ?` on v6+ files.
