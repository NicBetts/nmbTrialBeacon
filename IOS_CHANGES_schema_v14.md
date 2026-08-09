# iOS changes — schema v14 (Discover browse + site pubs)

**Schema version:** `14` (`PRAGMA user_version = 14` == `db_metadata.schema_version`)  
**Generator:** `ArtifactBuilder.schemaVersion = 14`  
**Builds on:** schema 13  
**Full contract:** `TRIALBEACON_DATABASE.md`

| From | Action |
|------|--------|
| v13 | **Repair** (additive) or **Create Database** |
| v12 | **Repair** (v13+v14) or **Create Database** |
| ≤ v11 | **Create Database** |

No live network on device. Compact by design: **no** intervention FTS, **no** `trial_intervention` join table.

---

## A. Site publication counters

On `site` (mirror organisation v13):

| Column | Meaning |
|--------|---------|
| `linked_publication_count` | Distinct `publication_id` via `trial_site → trial_publication` |
| `open_access_publication_count` | Subset with `publication.is_open_access = 1` |

CTG-linked refs on the site’s related trials only — not “everything this hospital published”. Zeros are fine when pubs are missing.

Filled on Create/Repair after sites exist (`PublicationEnrichmentService.refreshEntityPublicationCounts`).

---

## B. `popular_condition`

```sql
CREATE TABLE popular_condition (
    value TEXT PRIMARY KEY,   -- = lookup_condition.value
    rank  INTEGER NOT NULL,
    score REAL    NOT NULL    -- = trial_count
) WITHOUT ROWID;
```

- Top **50** by `trial_count DESC`, tie-break `value COLLATE NOCASE`
- **`is_population = 1` excluded** (Healthy Volunteers must not dominate Discover)
- Join trials: `lookup_condition.value_norm` → `condition.name_norm` (Swift `lowercased()`, never SQL `lower()`)

Index: `idx_lookup_condition_count ON lookup_condition(trial_count DESC)` (+ existing unique `value_norm`).

---

## C. Interventions — `lookup_intervention` + `popular_intervention`

```sql
CREATE TABLE lookup_intervention (
    value       TEXT PRIMARY KEY,  -- cleaned display spelling
    value_norm  TEXT NOT NULL,     -- Swift Unicode lower join key
    trial_count INTEGER NOT NULL,  -- distinct trials
    type        TEXT NOT NULL DEFAULT ''  -- dominant CTG type, or ''
) WITHOUT ROWID;

CREATE TABLE popular_intervention (
    value TEXT PRIMARY KEY,
    rank  INTEGER NOT NULL,
    score REAL    NOT NULL           -- = trial_count
) WITHOUT ROWID;
```

- Source: all intervention names from corpus (`stg_intervention` during Create; `detail_z` on Repair)
- Clean/dedupe like conditions (most-common casing; acronyms preserved)
- Popular: top **50**, same ranking rules as conditions
- Indexes: `idx_lookup_intervention_norm` (UNIQUE), `idx_lookup_intervention_count`

Filter trials (when iOS adds the browser): match intervention names inside `detail_z` / FTS `interventions` column using `value` / `value_norm` — there is **no** relational child table in v14.

---

## Capability checks

```text
PRAGMA user_version == 13 || 14   // client opens only this range
columnExists(site, linked_publication_count)
columnExists(site, open_access_publication_count)
tableExists(popular_condition)
tableExists(lookup_intervention)
tableExists(popular_intervention)
```

---

## iOS client checklist (this repo)

| Item | Action |
|------|--------|
| Schema gate | `minimumSchemaVersion = 13`, `supportedSchemaVersion = 14` (refuse below 13 and above 14) |
| Capability flags | `hasSitePublicationCounts`, `hasPopularCondition`, `hasLookupIntervention`, `hasPopularIntervention` |
| Site pubs | Prefer precomputed site columns; live join fallback on v13 without columns |
| Discover browsers | **Shipped:** Conditions + Interventions browsers, landscape boxes, popular lists |
| Network | Do **not** call CTG / OpenAlex / FDA at runtime |

### Verify on device

1. Bundle a **v14** file → app opens; Data Status shows Discover browse (v14) Present + site pub counts Present  
2. Bundle a **v13** file → app opens; Discover browse rows Missing; site pubs may live-join  
3. Bundle a **v12** (or older) file → open **fails** with unsupported-schema error  
4. Console: `[TrialStore] schema v14:` includes popular_condition / lookup_intervention flags when present  

---

## Repair notes

`ensureV14Schema` → ALTER site columns + `CREATE TABLE IF NOT EXISTS` discover tables → rebuild lookups/popular → refresh org **and** site pub counters. Does not require re-running OpenAlex if `trial_publication` already filled.
