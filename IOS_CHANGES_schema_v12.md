# iOS changes — schema v12 (slim sites + ship polish)

**Schema version:** `12` (`PRAGMA user_version = 12` == `db_metadata.schema_version`)  
**Generator:** `ArtifactBuilder.schemaVersion = 12`  
**Builds on:** schema 11 (`IOS_CHANGES_schema_v11.md`)  
**Full contract:** `TRIALBEACON_DATABASE.md` (schema 12)

## Summary

| Area | Change |
|------|--------|
| `trial_site` | **Slim** — only `(trial_id, site_id)`. Facility spelling, status, and coordinates are **not** duplicated on the join (they remain in `detail_z` / `site` / `site_alias`). |
| Size defaults | Generator default long-text scope is **active + since 2015** (was “every trial”). |
| Sites migration | Repair **drops and recreates** site tables when the fat v11 shape (or wrong `site_fts`) is detected. |
| Everything from v11 | HQ, `active_trial_count`, `lookup_condition.domain`, full site entity set — unchanged in meaning. |

A **v11** file can **Repair** (site DDL migrates) or Create Database. A **v10** file still needs **Create Database** (HQ columns).

After Create / Repair, copy the new `trialbeacon.sqlite` into the iOS app bundle.

---

## Why slim `trial_site`

Full-corpus builds pushed past **3 GB**, largely from millions of join rows repeating facility strings and coords already stored in `detail_z`. Discover’s filter only needs:

```sql
trial.trial_id IN (SELECT ts.trial_id FROM trial_site ts WHERE ts.site_id = ?)
```

### Shipped shape

```sql
CREATE TABLE trial_site (
    trial_id INTEGER NOT NULL,
    site_id  INTEGER NOT NULL,
    PRIMARY KEY (trial_id, site_id)
) WITHOUT ROWID;
```

One row per distinct trial↔site pair (soft-key merge). Multiple facility spellings at the same site collapse via `INSERT OR IGNORE` / `DISTINCT`.

### iOS impact

- Keep filtering on `site_id` — no change.
- If any code read `trial_site.original_facility_name`, `status`, or lat/lon: stop. Use `site` for the entity coordinate / name, `site_alias` for alternate spellings, `detail_z` locations for per-visit detail.
- Capability gate unchanged: `tableExists("site") && tableExists("trial_site")`.

---

## Site tables (complete set)

Still required:

`site`, `trial_site`, `site_alias`, `site_condition`, `site_lead_organisation`, `popular_site`, `site_fts`

| Piece | Notes |
|-------|--------|
| Soft key | `facility\|city\|country` via `SiteSoftKey` / generator `siteNormalize` |
| `site_alias.normalized_alias` | Soft-key facility part (not raw `lower()`) |
| `site_fts` | Contentless: `display_name`, `city`, `country` |
| Popular score | `recruiting*3 + total + phase_3` (top 50) |
| Indexes | `idx_trial_site_site`, `idx_site_count`, `idx_site_city`, `idx_site_country`, `idx_site_geo` (partial), `idx_site_alias_norm` |

---

## Size / compression practices (still required)

| Practice | Status |
|----------|--------|
| 16 KB page size | yes |
| Dictionary DEFLATE on `*_z` / `detail_z` | yes |
| Packed locations/outcomes/interventions/lead in `detail_z` | yes |
| Contentless FTS | yes (`trial`, collaborator, org, site) |
| `VACUUM` + `ANALYZE` on Create | yes (Repair skips `VACUUM`) |
| Long text omitted for old finished trials | **default** `sinceYear` 2015 |
| Slim `trial_site` | **new in v12** |

Size Options → “Every trial — biggest file” still available when you need a full-text archive.

Expect on the order of **~25–33%** smaller than a v11 full-text + fat-`trial_site` file when using shipping defaults (active+2015 long text + slim join). Exact % depends on how much fat join + long prose the previous file carried.

---

## Carried forward from schema 11

Use as before (see `IOS_CHANGES_schema_v11.md`):

- `organisation.hq_*` / `website` / `hq_source`
- `organisation.active_trial_count` (prefer over correlated subquery)
- `lookup_condition.domain` (optional icon token; NULL → on-device keywords)

---

## Generator / Tools clarity

| Action | Updates open sqlite? | Needs Create Database (step 3)? |
|--------|----------------------|----------------------------------|
| **Create Database** | Rebuilds whole file | — (this *is* the rebuild) |
| **Repair** | Yes — menus, stats, orgs, sites, domains, HQ apply | No |
| **Fetch / Apply Organisation HQ** | Yes — stamps HQ columns | No |
| **Review / saved name mappings** | Saves JSON only | **Yes — Repair or Create** to rebuild derived tables |
| **Checks / Show report** | No | No |

---

## iOS checklist

| Item | Action |
|------|--------|
| Schema gate | Was `12`; shipping client now gates at **13** (see `IOS_CHANGES_schema_v13.md`). v12 files still open. |
| `trial_site` | Read only `trial_id`, `site_id` |
| Active counts / HQ / domain / sites | Same as v11 |
| Bundled DB | Create or Repair to v12, then rebundle |

### Verify on device

1. Data Status / Settings → Sites capability: `Yes — N sites`, query path **canonical SQL**, not v9 slow index  
2. Console: `[TrialStore] DB capability:`  
3. Discover Sites box shows a **number**, not “Browse”
