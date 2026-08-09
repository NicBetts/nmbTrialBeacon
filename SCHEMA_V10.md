# Schema v10 — Organisations + Sites (DB generator handoff)

**Schema version:** `10` (`PRAGMA user_version = 10`)

Keep all existing v9 tables (`trial`, `lookup_collaborator`, `trial_collaborator`, `trial_country`, etc.). Schema v10 **adds**:

1. Unified **organisation** tables (Discover Phase 1)
2. Canonical **site** tables + reviewable alias system (Discover Phase 2 / Nearby)

Aggregates are precomputed so the phone does not scan packed `detail_z` for org/site browse pages.

---

## Purpose — Organisations

- Lead sponsors and collaborators share one `organisation` identity when `(name, agency_class)` match after soft normalisation / explicit overrides.
- Roles stay separate on `trial_organisation.role` = `lead_sponsor` | `collaborator`.
- Aggregates are precomputed on device-facing pages (lists, detail, popular, conditions, countries).
- `lookup_collaborator` / `trial_collaborator` remain for v9 filter compatibility.
- `organisation_collaborator_map` links `collaborator_id` → `organisation_id`.

## Purpose — Sites

- ClinicalTrials.gov facility strings become first-class **sites** with a conservative, reviewable alias system.
- Keep **original** facility name on the alias/link row; keep **canonical** display name, city, state/region, country, lat/lon on `site`.
- Do **not** rely on automatic fuzzy merging alone.
- Powers Site browser (search, nearby, city, country, high-activity), Site detail, and faster Nearby Studies.

---

## New tables

### `organisation`

One row per `(canonical_name, organisation_class)`.

| Column | Type | Notes |
|--------|------|--------|
| `organisation_id` | INTEGER PRIMARY KEY | |
| `canonical_name` | TEXT NOT NULL | |
| `display_name` | TEXT NOT NULL | |
| `organisation_class` | TEXT NOT NULL DEFAULT `''` | |
| `normalized_search_name` | TEXT NOT NULL | typically `lower(display_name)` |
| `logo_asset_name` | TEXT | nullable |
| `total_related_trial_count` | INTEGER NOT NULL DEFAULT 0 | distinct trials via any role |
| `lead_sponsor_trial_count` | INTEGER NOT NULL DEFAULT 0 | |
| `collaborator_trial_count` | INTEGER NOT NULL DEFAULT 0 | |
| `recruiting_trial_count` | INTEGER NOT NULL DEFAULT 0 | |
| `completed_trial_count` | INTEGER NOT NULL DEFAULT 0 | |
| `terminated_trial_count` | INTEGER NOT NULL DEFAULT 0 | |
| `phase_1_trial_count` | INTEGER NOT NULL DEFAULT 0 | `PHASE1`, `EARLY_PHASE1` |
| `phase_2_trial_count` | INTEGER NOT NULL DEFAULT 0 | `PHASE2`, `PHASE1/PHASE2` |
| `phase_3_trial_count` | INTEGER NOT NULL DEFAULT 0 | `PHASE3`, `PHASE2/PHASE3` |
| `phase_4_trial_count` | INTEGER NOT NULL DEFAULT 0 | `PHASE4` |
| `country_count` | INTEGER NOT NULL DEFAULT 0 | distinct countries |
| `site_count` | INTEGER | `SUM(trial.location_count)` over related trials (facility-row total, not a deduplicated site graph) |
| `results_available_count` | INTEGER NOT NULL DEFAULT 0 | |
| `first_posted_year` | INTEGER | nullable |
| `most_recent_update_date` | INTEGER | unix timestamp |
| `new_trial_count_30d` | INTEGER NOT NULL DEFAULT 0 | `first_posted_date` within 30 days |
| `recruiting_trial_count_30d` | INTEGER NOT NULL DEFAULT 0 | status = `RECRUITING` **and** `last_update_post_date` within 30 days |
| `recently_updated_completed_count_30d` | INTEGER NOT NULL DEFAULT 0 | status = `COMPLETED` **and** last update within 30 days |
| `recently_updated_terminated_count_30d` | INTEGER NOT NULL DEFAULT 0 | status = `TERMINATED` **and** last update within 30 days |

Constraints:

- `UNIQUE (canonical_name, organisation_class)`

DDL reference:

```sql
CREATE TABLE organisation (
    organisation_id              INTEGER PRIMARY KEY,
    canonical_name               TEXT    NOT NULL,
    display_name                 TEXT    NOT NULL,
    organisation_class           TEXT    NOT NULL DEFAULT '',
    normalized_search_name       TEXT    NOT NULL,
    logo_asset_name              TEXT,
    total_related_trial_count    INTEGER NOT NULL DEFAULT 0,
    lead_sponsor_trial_count     INTEGER NOT NULL DEFAULT 0,
    collaborator_trial_count     INTEGER NOT NULL DEFAULT 0,
    recruiting_trial_count       INTEGER NOT NULL DEFAULT 0,
    completed_trial_count        INTEGER NOT NULL DEFAULT 0,
    terminated_trial_count       INTEGER NOT NULL DEFAULT 0,
    phase_1_trial_count          INTEGER NOT NULL DEFAULT 0,
    phase_2_trial_count          INTEGER NOT NULL DEFAULT 0,
    phase_3_trial_count          INTEGER NOT NULL DEFAULT 0,
    phase_4_trial_count          INTEGER NOT NULL DEFAULT 0,
    country_count                INTEGER NOT NULL DEFAULT 0,
    site_count                   INTEGER,
    results_available_count      INTEGER NOT NULL DEFAULT 0,
    first_posted_year            INTEGER,
    most_recent_update_date      INTEGER,
    new_trial_count_30d          INTEGER NOT NULL DEFAULT 0,
    recruiting_trial_count_30d   INTEGER NOT NULL DEFAULT 0,
    recently_updated_completed_count_30d INTEGER NOT NULL DEFAULT 0,
    recently_updated_terminated_count_30d INTEGER NOT NULL DEFAULT 0,
    UNIQUE (canonical_name, organisation_class)
);
```

### `trial_organisation`

| Column | Type | Notes |
|--------|------|--------|
| `trial_id` | INTEGER NOT NULL | |
| `organisation_id` | INTEGER NOT NULL | |
| `role` | TEXT NOT NULL | `lead_sponsor` or `collaborator` only |

```sql
CREATE TABLE trial_organisation (
    trial_id         INTEGER NOT NULL,
    organisation_id  INTEGER NOT NULL,
    role             TEXT    NOT NULL,
    PRIMARY KEY (trial_id, organisation_id, role)
) WITHOUT ROWID;
```

### `organisation_collaborator_map`

Maps every `lookup_collaborator.collaborator_id` to a unified organisation.

```sql
CREATE TABLE organisation_collaborator_map (
    collaborator_id  INTEGER PRIMARY KEY,
    organisation_id  INTEGER NOT NULL
) WITHOUT ROWID;
```

### `organisation_condition`

Top **10** conditions per organisation by distinct trial count.

```sql
CREATE TABLE organisation_condition (
    organisation_id INTEGER NOT NULL,
    rank            INTEGER NOT NULL,
    condition       TEXT    NOT NULL,
    trial_count     INTEGER NOT NULL,
    PRIMARY KEY (organisation_id, rank)
) WITHOUT ROWID;
```

### `organisation_country`

```sql
CREATE TABLE organisation_country (
    organisation_id INTEGER NOT NULL,
    country         TEXT    NOT NULL,
    trial_count     INTEGER NOT NULL,
    PRIMARY KEY (organisation_id, country)
) WITHOUT ROWID;
```

### `popular_organisation`

Top **50** organisations for Discover.

```sql
CREATE TABLE popular_organisation (
    organisation_id INTEGER PRIMARY KEY,
    rank            INTEGER NOT NULL,
    score           REAL    NOT NULL
) WITHOUT ROWID;
```

### `organisation_fts`

```sql
CREATE VIRTUAL TABLE organisation_fts USING fts5(
    display_name,
    content = '',
    tokenize = 'porter unicode61 remove_diacritics 2'
);
-- rowid = organisation_id
```

---

## Indexes

```sql
CREATE INDEX IF NOT EXISTS idx_trial_organisation_org
    ON trial_organisation(organisation_id, trial_id);
CREATE INDEX IF NOT EXISTS idx_organisation_count
    ON organisation(total_related_trial_count DESC);
CREATE INDEX IF NOT EXISTS idx_organisation_class
    ON organisation(organisation_class, total_related_trial_count DESC);
```

Also retain existing v9 collaborator indexes used by filters:

```sql
CREATE INDEX IF NOT EXISTS idx_trial_collaborator_collab
    ON trial_collaborator(collaborator_id, trial_id);
CREATE INDEX IF NOT EXISTS idx_lookup_collaborator_count
    ON lookup_collaborator(trial_count DESC);
```

---

## Popular ranking

```
score = recruiting_trial_count * 3
      + total_related_trial_count
      + new_trial_count_30d * 2
```

- Rank top 50 by score DESC, then `display_name` COLLATE NOCASE.
- Not alphabetical.
- Only orgs with `total_related_trial_count > 0`.

---

## 30-day metrics methodology

| Field | Meaning |
|-------|---------|
| `new_trial_count_30d` | `first_posted_date` within 30 days |
| `recruiting_trial_count_30d` | status = `RECRUITING` **and** `last_update_post_date` within 30 days |
| `recently_updated_completed_count_30d` | status = `COMPLETED` **and** last update within 30 days |
| `recently_updated_terminated_count_30d` | status = `TERMINATED` **and** last update within 30 days |

These do **not** prove a status *changed* in the window unless a prior snapshot comparison exists (not available in a single build). The iOS Organisation detail UI discloses this.

---

## Name / alias policy

- Automatic merges: soft key only (case / punctuation / `&` ↔ `and`).
- Explicit merges: `organization-overrides.json` (deterministic, reviewable).
- No fuzzy-only merges of distinct legal entities.

---

## Build order (after v9 base data is written)

### Organisations
1. Insert organisations from distinct lead sponsors + collaborators.
2. Fill `organisation_collaborator_map`.
3. Fill `trial_organisation` (lead + collaborator roles).
4. Aggregate stats onto `organisation`.
5. Build `organisation_condition` (top 10) and `organisation_country`.
6. Rank `popular_organisation` (top 50).
7. Rebuild `organisation_fts`.

### Sites
8. Extract distinct facility rows from packed location data (and/or legacy `location` if present).
9. Apply soft-key grouping + `site-overrides.json` → populate `site` + `site_alias`.
10. Fill `trial_site` (preserve `original_facility_name`).
11. Aggregate stats onto `site`.
12. Build `site_condition` (top 10) and `site_lead_organisation` (top 12).
13. Rank `popular_site` / high-activity (top 50).
14. Rebuild `site_fts`.
15. Set `PRAGMA user_version = 10`.

---

## Validation expectations — Organisations

- `organisation` populated (`COUNT(*) > 0`).
- Every `trial_organisation.organisation_id` resolves to `organisation`.
- Every `trial_organisation.role` is `lead_sponsor` or `collaborator`.
- `organisation_collaborator_map` covers `lookup_collaborator`.
- `popular_organisation` has ranked rows (up to 50).
- `organisation.total_related_trial_count` matches distinct `trial_organisation.trial_id` links.
- Required tables present:  
  `organisation`, `trial_organisation`, `organisation_collaborator_map`,  
  `organisation_condition`, `organisation_country`, `popular_organisation`, `organisation_fts`
- Required indexes present:  
  `idx_trial_organisation_org`, `idx_organisation_count`, `idx_organisation_class`

---

## Validation expectations — Sites

- `site` populated (`COUNT(*) > 0`).
- Every `trial_site.site_id` / `site_alias.site_id` resolves to `site`.
- Every `site_alias` row preserves a non-empty `original_facility_name`.
- `popular_site` has ranked rows (up to 50).
- `site.total_related_trial_count` matches distinct `trial_site.trial_id` links.
- Required tables present:  
  `site`, `site_alias`, `trial_site`, `site_condition`, `site_lead_organisation`,  
  `popular_site`, `site_fts`
- Required indexes present:  
  `idx_trial_site_site`, `idx_site_count`, `idx_site_city`, `idx_site_country`,  
  `idx_site_geo`, `idx_site_alias_norm`

---

## Compatibility notes

- Keep `lookup_collaborator` / `trial_collaborator` for existing collaborator filters and trial detail collaborator chips.
- Keep packed `detail_z` location arrays for trial detail screens; site tables are the exploration/Nearby index, not a replacement for per-trial location UI.
- iOS detects tables via presence (`hasOrganisations` / `hasSites`). `supportedSchemaVersion` is **10**; a newer `user_version` is still refused.
- An org-only v10 file (no `site` / `trial_site`) still opens; Discover Sites shows “—” and the Sites browser uses the recruiting fallback until you **Repair** / rebuild with the site artifact.
- While testing on shipping **v9** DBs, the app falls back to live lead/collaborator SQL for organisations, and a recruiting/`detail_z` scan cache for sites (slower, recruiting-weighted).

---

# Sites (Phase 2)

## Name / alias policy (hard requirement)

ClinicalTrials.gov site names include variants such as:

- Massachusetts General Hospital
- Mass General Hospital
- MGH
- Massachusetts General Hospital Cancer Center

Phase 2 introduces a **conservative, reviewable** site alias system:

| Layer | Rule |
|-------|------|
| Soft key (automatic) | Case / punctuation / `&`↔`and` / collapse whitespace only. Same city + country required to auto-merge. |
| Explicit overrides | `site-overrides.json` maps original (or soft key) → canonical site. Deterministic, reviewable, preferred for acronyms (MGH) and campus variants. |
| Do not | Fuzzy-only merges of distinct facilities (e.g. different hospitals that share a token). |
| Preserve | Every observed `original_facility_name` on `site_alias` / `trial_site`, even after canonicalisation. |

Canonical site always stores:

- `display_name` (canonical)
- `city`, `state` / region, `country`
- `latitude`, `longitude` when supplied (median / first non-null of members is fine; document choice)

## New site tables

### `site`

| Column | Type | Notes |
|--------|------|--------|
| `site_id` | INTEGER PRIMARY KEY | |
| `canonical_name` | TEXT NOT NULL | Stable merge key name |
| `display_name` | TEXT NOT NULL | UI title |
| `normalized_search_name` | TEXT NOT NULL | `lower(display_name)` (+ soft normalize) |
| `city` | TEXT | |
| `state` | TEXT | state / region |
| `country` | TEXT | |
| `postal_code` | TEXT | nullable |
| `latitude` | REAL | nullable |
| `longitude` | REAL | nullable |
| `total_related_trial_count` | INTEGER NOT NULL DEFAULT 0 | |
| `recruiting_trial_count` | INTEGER NOT NULL DEFAULT 0 | |
| `phase_3_trial_count` | INTEGER NOT NULL DEFAULT 0 | `PHASE3`, `PHASE2/PHASE3` |
| `organisation_count` | INTEGER NOT NULL DEFAULT 0 | distinct lead sponsors on related trials |
| `most_recent_update_date` | INTEGER | unix |
| UNIQUE | `(canonical_name, city, country)` | empty string when null city/country |

```sql
CREATE TABLE site (
    site_id                    INTEGER PRIMARY KEY,
    canonical_name             TEXT    NOT NULL,
    display_name               TEXT    NOT NULL,
    normalized_search_name     TEXT    NOT NULL,
    city                       TEXT    NOT NULL DEFAULT '',
    state                      TEXT    NOT NULL DEFAULT '',
    country                    TEXT    NOT NULL DEFAULT '',
    postal_code                TEXT,
    latitude                   REAL,
    longitude                  REAL,
    total_related_trial_count  INTEGER NOT NULL DEFAULT 0,
    recruiting_trial_count     INTEGER NOT NULL DEFAULT 0,
    phase_3_trial_count        INTEGER NOT NULL DEFAULT 0,
    organisation_count         INTEGER NOT NULL DEFAULT 0,
    most_recent_update_date    INTEGER,
    UNIQUE (canonical_name, city, country)
);
```

### `site_alias`

Maps every observed facility string (and soft-key form) to a canonical site.

```sql
CREATE TABLE site_alias (
    alias_id                 INTEGER PRIMARY KEY,
    site_id                  INTEGER NOT NULL,
    original_facility_name   TEXT    NOT NULL,
    normalized_alias         TEXT    NOT NULL,
    city                     TEXT    NOT NULL DEFAULT '',
    country                  TEXT    NOT NULL DEFAULT '',
    source                   TEXT    NOT NULL DEFAULT 'soft_key',
    -- source: soft_key | override | identical
    UNIQUE (normalized_alias, city, country)
);
```

### `trial_site`

```sql
CREATE TABLE trial_site (
    trial_id                 INTEGER NOT NULL,
    site_id                  INTEGER NOT NULL,
    original_facility_name   TEXT    NOT NULL,
    status                   TEXT,          -- CTG location status when present
    latitude                 REAL,          -- row-level coords when present
    longitude                REAL,
    PRIMARY KEY (trial_id, site_id, original_facility_name)
) WITHOUT ROWID;
```

### `site_condition`

Top **10** conditions per site.

```sql
CREATE TABLE site_condition (
    site_id     INTEGER NOT NULL,
    rank        INTEGER NOT NULL,
    condition   TEXT    NOT NULL,
    trial_count INTEGER NOT NULL,
    PRIMARY KEY (site_id, rank)
) WITHOUT ROWID;
```

### `site_lead_organisation`

Top **12** lead organisations (by trial count) for the site detail “Lead organisations” section. Prefer linking to `organisation_id` when org tables exist; keep display name for resilience.

```sql
CREATE TABLE site_lead_organisation (
    site_id          INTEGER NOT NULL,
    rank             INTEGER NOT NULL,
    organisation_id  INTEGER,           -- nullable if org tables not yet linked
    display_name     TEXT    NOT NULL,
    organisation_class TEXT  NOT NULL DEFAULT '',
    trial_count      INTEGER NOT NULL,
    PRIMARY KEY (site_id, rank)
) WITHOUT ROWID;
```

### `popular_site` (high-activity)

Top **50** sites for Discover / Site browser “High activity”.

```sql
CREATE TABLE popular_site (
    site_id INTEGER PRIMARY KEY,
    rank    INTEGER NOT NULL,
    score   REAL    NOT NULL
) WITHOUT ROWID;
```

### `site_fts`

```sql
CREATE VIRTUAL TABLE site_fts USING fts5(
    display_name,
    city,
    country,
    content = '',
    tokenize = 'porter unicode61 remove_diacritics 2'
);
-- rowid = site_id
```

## Site indexes

```sql
CREATE INDEX IF NOT EXISTS idx_trial_site_site
    ON trial_site(site_id, trial_id);
CREATE INDEX IF NOT EXISTS idx_site_count
    ON site(total_related_trial_count DESC);
CREATE INDEX IF NOT EXISTS idx_site_city
    ON site(city, total_related_trial_count DESC);
CREATE INDEX IF NOT EXISTS idx_site_country
    ON site(country, total_related_trial_count DESC);
CREATE INDEX IF NOT EXISTS idx_site_geo
    ON site(latitude, longitude)
    WHERE latitude IS NOT NULL AND longitude IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_site_alias_norm
    ON site_alias(normalized_alias, city, country);
```

## High-activity / popular score

```
score = recruiting_trial_count * 3
      + total_related_trial_count
      + phase_3_trial_count
```

Rank top 50 by score DESC, then `display_name` COLLATE NOCASE.

## Browser surfaces the tables must support

| Browse mode | Query shape |
|-------------|-------------|
| Search by name | `site_fts` / `normalized_search_name` / `site_alias.normalized_alias` |
| Nearby sites | `idx_site_geo` bbox + haversine; prefer sites with `recruiting_trial_count > 0` |
| By city | `idx_site_city` |
| By country | `idx_site_country` |
| High activity | `popular_site` join `site` |

## Site detail metrics (iOS contract)

Header example:

- Display name  
- `city`, `state` (e.g. Boston, Massachusetts)  
- Chips: studies · recruiting · Phase III · organisations  

Sections:

- Recruiting studies (filtered list)  
- Top conditions (`site_condition`)  
- Lead organisations (`site_lead_organisation` → org detail when `organisation_id` set)  
- Recent studies  
- Study footprint (country already on site; optional state)  
- Distance from user when location is available  

## Out of scope for this schema bump

Do **not** add yet: site reviews/ratings, directions, investigator profiles, site contact aggregation beyond the trial record, collaboration graphs, full condition/intervention/country entity profiles.
