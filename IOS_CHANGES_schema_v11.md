# iOS changes — schema v11 (HQ, active counts, domains, sites ship)

**Schema version:** `11` (`PRAGMA user_version = 11` == `db_metadata.schema_version`)  
**Generator:** `ArtifactBuilder.schemaVersion = 11`  
**Builds on:** schema 10 (`IOS_CHANGES_schema_v10.md`)  
**Full contract:** `TRIALBEACON_DATABASE.md` (core through v8 + evolution note) plus this file for v11 deltas.  
**Superseded for shipping:** schema **12** slim `trial_site` — see `IOS_CHANGES_schema_v12.md`.

## Summary

| Area | What shipped |
|------|----------------|
| Organisation HQ | Curated `hq_*` + `website` from ROR / Wikidata / manual JSON |
| Active trial count | Precomputed `organisation.active_trial_count` |
| Condition domain | Optional `lookup_condition.domain` for Discover icons |
| Sites | Relational site tables built from `detail_z` on Create / Repair |

A **v10** file must be **rebuilt** with Create Database for the HQ column shape. Early **v11** files missing only `active_trial_count` / `domain` can **Repair** — those columns are `ALTER`ed in place.

After Create / Repair, copy the new `trialbeacon.sqlite` into the iOS app bundle (or Documents) so the phone sees sites + HQ + active counts.

---

## Organisation headquarters

All nullable. Absence means “not curated yet”, not “no HQ exists”.

| Column | Meaning |
|--------|---------|
| `hq_country` | Headquarters country (minimum bar for “has address”) |
| `hq_address_line` | Street / building |
| `hq_city` | |
| `hq_region` | State, province, canton — nullable where unused |
| `hq_postal_code` | |
| `website` | Canonical URL (`https://…`) |
| `hq_source` | Provenance: `manual` / `ror` / `wikidata` |

`logo_asset_name` remains reserved / unused.

**Do not** treat `organisation_country` (trial footprint) as HQ.

### Generator behaviour

- **Fetch from ROR & Wikidata** — separate from ClinicalTrials.gov. Writes `organization-enrichment.json` and stamps the open database.
- **Auto-accept rules:** exact soft-key match whose ROR *display* is the same organisation (not a national subsidiary). Merck-family hard keys are never auto-filled.
- **What ROR provides:** country, city, region, website. **Not** street. Wikidata may supply `hq_address_line` via P6375.
- **Organisation HQ & Website…** — review UI; **Apply Organisation HQ** stamps JSON without a full rebuild.
- **Create Database / Repair** — apply JSON after org aggregates; end-of-run gap report. Missing HQ does **not** fail validation.

### Matching enrichment to org rows

Enrichment keys use `Normalize.organizationSoftKey` plus `organisation_class`. A spelling tidy that keeps the soft key still finds the HQ record.

---

## `organisation.active_trial_count`

Precomputed distinct trials linked to the organisation where `trial.is_active = 1` (Recruiting, Not yet recruiting, Enrolling by invitation, Active not recruiting).

Discover Popular orgs and org search rows should read this column instead of the correlated subquery:

```sql
-- Prefer (schema 11):
SELECT active_trial_count, recruiting_trial_count, … FROM organisation …

-- Avoid (v10 interim):
(SELECT COUNT(DISTINCT t.trial_id) FROM trial_organisation tor
 JOIN trial t ON t.trial_id = tor.trial_id
 WHERE tor.organisation_id = organisation.organisation_id AND t.is_active = 1)
```

Same identity rules as other org counters: distinct trials, either role. Gate on `columnExists("organisation", "active_trial_count")` so mixed / older files still open.

---

## `lookup_condition.domain` (optional)

Nullable `TEXT` therapeutic-area token for the Discover icon beta. Prefer these exact strings when non-null:

`oncology`, `cardiology`, `neurology`, `infectious`, `metabolic`, `respiratory`, `immunology`, `psychiatry`, `musculoskeletal`, `ophthalmology`, `dermatology`, `gastroenterology`, `nephrology`, `hematology`, `reproductive`, `pediatrics`

- Generator fills via keyword rules on the condition display name, then applies reviewed overrides from `condition-domains.json` in the working folder (`value_norm` or `value` → domain).
- **NULL** = unclassified — keep the on-device keyword CSV fallback.
- Not required for Sites / orgs to work.

---

## Sites (full ship in the generator)

Create Database and Repair both run `buildSiteTables` from `trial.detail_z`. Tables:

`site`, `trial_site`, `site_alias`, `site_condition`, `site_lead_organisation`, `popular_site`, `site_fts`

### Shipped `site` shape (generator)

| Column | Notes |
|--------|--------|
| `site_id` | Not stable across builds |
| `canonical_name` | Soft-key merge identity (with city + country) |
| `display_name` | Representative facility spelling |
| `city` / `state` / `country` | `''` when unknown — do **not** use NULL for city/country |
| `postal_code` | Nullable |
| `latitude` / `longitude` | Nullable; nearby queries skip NULLs |
| Aggregate counts | `total_related_trial_count`, `recruiting_trial_count`, `phase_3_trial_count`, `organisation_count` |
| `most_recent_update_date` | Nullable epoch |

### Link / companion notes

- `trial_site` PK is `(trial_id, site_id, original_facility_name)` so multiple facility spellings at one site stay distinct; the trial filter still uses `WHERE site_id = ?`.
- `site_fts` indexes `display_name`, `city`, `country` (contentless; `rowid` = `site_id`).
- Popular score:  
  `recruiting_trial_count * 3 + total_related_trial_count + phase_3_trial_count`  
  (top 50).
- `site_lead_organisation.organisation_id` may be NULL — route by sponsor name when missing.

Broader contract / query patterns: `IOS_CHANGES_schema_v10.md` § Sites (Discover Phase 2). Where that doc’s older interim column list disagrees with the generator DDL above, **trust the generator / `TRIALBEACON_DATABASE.md`**.

### iOS Sites status

- Capability gate: `tableExists("site") && tableExists("trial_site")`.
- Until those tables exist in the file the app opens, Discover Sites stays on the slow on-device fallback (“Browse” / recruiting-only).
- **Discover Sites browser polish is next** (search, popular, nearby, city/country browse UX). Site → Leading Organisations → Organisation linkage already works when the tables are present.

### How to verify the phone opened the right file

The app only reads **bundled** `nmbTrialBeacon/trialbeacon.sqlite` (rebuild / reinstall after replacing the file — there is no Documents override).

1. **Data Status** (home) or **Settings → Database details → Sites capability**
   - Site tables: `Yes — N sites` (expect hundreds of thousands after a full Create)
   - `trial_site` rows: millions on a full build
   - Query path: `canonical SQL (site / trial_site)` — **not** `v9 on-device recruiting index (SLOW)`
2. **Xcode console** on launch — one line starting with `[TrialStore] DB capability:`
3. Discover Sites box should show a **number**, not “Browse”

### What to tell the DB generator (v11 Sites)

Already required by this document / Create Database + Repair:

1. Run **`buildSiteTables`** from `trial.detail_z` (soft-key merge `facility|city|country`).
2. Emit tables: `site`, `trial_site`, `site_alias`, `site_condition`, `site_lead_organisation`, `popular_site`, `site_fts`.
3. Populate aggregates on `site`: `total_related_trial_count`, `recruiting_trial_count`, `phase_3_trial_count`, `organisation_count`, `most_recent_update_date`.
4. Indexes: `idx_trial_site_site`, `idx_site_count`, `idx_site_city`, `idx_site_country`, `idx_site_geo`, `idx_site_alias_norm`.
5. `PRAGMA user_version` / `db_metadata.schema_version` = **11**.
6. Validation must fail the export if site tables are missing or empty when Sites are in scope.

---

## iOS app checklist

| Item | Action |
|------|--------|
| Schema gate | `TrialStore.supportedSchemaVersion = 11` |
| Active counts | Prefer `organisation.active_trial_count` when the column exists; else v10 subquery |
| Org HQ | Show HQ when `hq_country` non-null; website when present — never invent from trial countries |
| Condition icons | Prefer `lookup_condition.domain` when non-null; else keyword CSV |
| Sites | Gate on table presence; Durable key = soft-key / `SiteRef.raw`, never `site_id` |
| Org identity | Persist `(canonical_name, organisation_class)`, never `organisation_id` |
| Bundled DB | Rebuild / Repair to v11 and copy `trialbeacon.sqlite` into the app |

### Organisation linkage (already in app; uses v10+ tables)

Discover → Organisations → Org · Trial detail Lead / Collaborators → Org · Search suggests Organisations before trials · Site → Leading Organisations → Org (needs site tables). Condition → Leading Orgs remains Phase 3.
