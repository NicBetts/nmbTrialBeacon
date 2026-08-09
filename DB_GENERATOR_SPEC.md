# TrialBeacon — Database Generator Specification

**Audience:** the macOS desktop app (and its Cursor agent) that builds the clinical-trials database bundled into the TrialBeacon iOS app.

**Version:** schema v1 · spec revision 1.2 (2026-07-29)
**Data source:** ClinicalTrials.gov REST API **v2** (`https://clinicaltrials.gov/api/v2/studies`)
**Output:** a single, clean, read-only **SQLite** file named `trialbeacon.sqlite`

---

## Status — read this first

Schema v1 is **agreed and implemented**. Two documents now exist and they have
different jobs:

| Document | Owner | Job |
|---|---|---|
| `TRIALBEACON_DATABASE.md` | generator app | **The contract.** Exact DDL, column semantics, blob format, query recipes. If this spec and that document disagree, that document wins. |
| `DB_GENERATOR_SPEC.md` (this file) | iOS app | **The requirements and the build-side knowledge**: normalization rules (§5), API field mapping (§6), build pipeline (§7), acceptance checks (§8), and open change requests (§11). |

Revision 1.1 folds the generator's accepted amendments into the sections below
so this file no longer contradicts the shipped schema. The amendments were:

1. Long prose moved to DEFLATE-compressed `*_z` BLOBs, with a new plain-text
   `summary_snippet` for list rows (§3.1, §3.2).
2. FTS indexes titles, conditions and interventions — **not** summaries (§3.3).
3. Extra `trial` columns: `enrollment_count`, `why_stopped`, `std_ages`,
   `summary_snippet` (§3.1).
4. `eligibility.raw_text_z` is written only when the inclusion/exclusion split
   failed (§3.2).
5. `lookup_condition` is case-normalized and carries `value_norm` (§3.4, §5.10).
6. `agg_condition_by_year` ranks by distinct trials (§3.5).

Revision 1.2 adds nothing to the schema. It records a full verification of the
real `gen-2026.07.29` sample build against this contract: compressed blobs, FTS,
lookups, aggregates, coordinates and status vocabularies all check out.

**§11 lists what the iOS app is asking for in the next build.** The important
new ask is §11.8 — pack detail-only child tables into one compressed BLOB per
trial (projected ~200 MB saving). Two indexes remain (§11.1, §11.7).
`lookup_condition.value_norm` (§11.6) is present and correct on the full
`101,705`-trial build; leave it alone.

---

## 0. TL;DR — what you must produce

Produce **one plain SQLite database file** (`trialbeacon.sqlite`) that is:

1. A **normal relational SQLite schema** — **NOT** a Core Data / SwiftData `.store`. No `Z*` tables, no `ACHANGE`, no `ATRANSACTION`, no `Z_METADATA`, no persistent-history change log.
2. **Fully populated**, including the detail tables that are currently empty: `location`, `intervention`, `outcome`, `sponsor`, `eligibility` (and `condition`).
3. **Indexed** on every column the app filters/sorts by.
4. **Full-text searchable** via an FTS5 virtual table.
5. **Pre-aggregated**: dashboard counts, per-dimension counts, per-year counts, and top-condition-by-year are computed at build time and stored in tables, so the phone never scans 500k rows.
6. Shipped **without** `-wal`/`-shm` sidecar files, with `journal_mode` not set to WAL, `VACUUM`ed and `ANALYZE`d, so the iOS app can open it **read-only, in place, from the app bundle**.

> ### Why this is a full rewrite of the old database
> The current bundled file is a 694 MB Core Data store containing **496,455 trials** but **~9.7 million `ACHANGE` rows** (Core Data change-tracking) that waste ~355 MB, and the `location`/`intervention`/`outcome`/`sponsor`/`eligibility` tables are **empty**. The iOS app then re-imports every row into a second SwiftData store at launch. The new approach: emit a clean, query-ready SQLite that the app reads directly with pagination + FTS. Expected size after cleanup: **~250–350 MB** before compression (vs. 694 MB).

---

## 1. Output file & build-time conventions

| Item | Requirement |
|---|---|
| File name | `trialbeacon.sqlite` |
| Encoding | UTF-8 |
| `PRAGMA user_version` | `1` (schema version — bump when schema changes) |
| `PRAGMA application_id` | `0x54424541` (`"TBEA"`) |
| Journal mode (final) | `DELETE` (or `OFF`) — **never ship WAL** |
| Sidecar files | Do **not** ship `-wal` or `-shm`. Checkpoint & remove them. |
| Finalization | Run `PRAGMA wal_checkpoint(TRUNCATE);` → `PRAGMA journal_mode=DELETE;` → `VACUUM;` → `ANALYZE;` |
| Foreign keys | Declared in schema; enforce during build (`PRAGMA foreign_keys=ON`) |
| Read-only at runtime | The iOS app opens with `SQLITE_OPEN_READONLY` directly from the bundle — the file must be self-contained with no pending WAL. |

**Build-speed pragmas (during generation only, then reverse for the final file):**

```sql
PRAGMA journal_mode = OFF;
PRAGMA synchronous  = OFF;
PRAGMA temp_store   = MEMORY;
PRAGMA cache_size   = -200000;   -- ~200 MB page cache
PRAGMA foreign_keys = ON;
```

Insert in **transactions of ~5,000–50,000 rows**, use **prepared statements** with bound parameters (never string-interpolate values), and build **all indexes + FTS + aggregates AFTER bulk insert**, not before.

---

## 2. Data type conventions (read this before the schema)

- **Dates** are stored as **INTEGER Unix epoch seconds (UTC)** for sorting/filtering, plus a **TEXT `*_display`** copy of the original string for the UI.
  - Do **not** use Core Data reference-date doubles (seconds since 2001). Plain Unix epoch only.
  - ClinicalTrials.gov dates are often partial (`"2019"`, `"2019-06"`). Normalize to epoch using the **first day** of the known precision (e.g. `2019` → `2019-01-01`, `2019-06` → `2019-06-01`), and keep the original string in `*_display`.
- **Booleans** are stored as **INTEGER `0`/`1`** (nullable only where noted).
- **Enums** (status, phase, study type, gender, agency class, outcome type, sponsor role) are stored as **canonical UPPER_SNAKE_CASE** in the primary column, with a human-readable **`*_display`** where the UI needs it. Canonicalization rules are in §5.
- **Text**: trim whitespace; convert empty strings to `NULL`.
- **`name_norm`** columns are the trimmed name lowercased with **full Unicode
  case folding** (Swift's `lowercased()`), used for grouping/dedup; keep the
  original in `name`. Do **not** use SQLite's `lower()`: it only folds ASCII, so
  names containing characters like the Roman numeral "Ⅱ" (which really do occur,
  e.g. "Dyslipidemia (Fredrickson Type Ⅱa)") would normalize inconsistently and
  silently fail to match. The same function must produce both
  `condition.name_norm` and `lookup_condition.value_norm`.
- **Long prose is compressed.** `trial.brief_summary_z`,
  `trial.detailed_description_z`, `eligibility.inclusion_z`,
  `eligibility.exclusion_z` and `eligibility.raw_text_z` are BLOBs: a 4-byte
  little-endian `UInt32` uncompressed byte count followed by a raw DEFLATE
  stream (Apple `COMPRESSION_ZLIB`, no zlib header). If the payload is
  incompressible, store the raw UTF-8 bytes after the same length prefix.
  `NULL` means "no text".

---

## 3. Schema (DDL)

Create the schema exactly as below (names are the contract the iOS app codes against).

### 3.1 `trial` — one row per study

```sql
CREATE TABLE trial (
    trial_id                       INTEGER PRIMARY KEY,      -- internal rowid, used as FK + FTS rowid
    nct_id                         TEXT    NOT NULL UNIQUE,  -- e.g. "NCT04123456"
    brief_title                    TEXT    NOT NULL,
    official_title                 TEXT,
    overall_status                 TEXT    NOT NULL,         -- canonical enum (§5.1)
    status_display                 TEXT    NOT NULL,         -- e.g. "Recruiting"
    study_type                     TEXT,                     -- INTERVENTIONAL / OBSERVATIONAL / EXPANDED_ACCESS
    study_type_display             TEXT,
    phase                          TEXT,                     -- canonical enum (§5.2); NULL if N/A
    phase_display                  TEXT,                     -- e.g. "Phase 2"
    summary_snippet                TEXT,                     -- first ~300 chars of the brief summary,
                                                             --   plain text; this is what list rows read
    brief_summary_z                BLOB,                     -- compressed (§2)
    detailed_description_z         BLOB,                     -- compressed (§2)

    -- Dates (epoch seconds UTC + display string)
    start_date                     INTEGER,
    start_date_display             TEXT,
    completion_date                INTEGER,
    completion_date_display        TEXT,
    first_posted_date              INTEGER,
    first_posted_date_display      TEXT,
    last_update_post_date          INTEGER NOT NULL,         -- primary sort key for lists
    last_update_post_date_display  TEXT,

    -- Eligibility scalars (denormalized onto trial for filtering)
    gender_eligibility             TEXT,                     -- ALL / MALE / FEMALE
    gender_eligibility_display     TEXT,
    min_age_display                TEXT,                     -- original, e.g. "18 Years"
    max_age_display                TEXT,
    min_age_years                  REAL,                     -- normalized numeric (§5.4); NULL if none
    max_age_years                  REAL,
    std_ages                       TEXT,                     -- CSV of CHILD,ADULT,OLDER_ADULT
    healthy_volunteers             INTEGER,                  -- 0/1, nullable

    -- Study facts shown on the detail screen
    enrollment_count               INTEGER,
    why_stopped                    TEXT,                     -- terminated/suspended/withdrawn only

    -- Flags
    has_results                    INTEGER NOT NULL DEFAULT 0,
    fda_regulated_drug             INTEGER NOT NULL DEFAULT 0,
    has_expanded_access            INTEGER NOT NULL DEFAULT 0,

    -- Denormalized "primary" values for fast list rows + filtering (no joins needed)
    primary_condition              TEXT,
    primary_country                TEXT,
    primary_state                  TEXT,
    lead_sponsor_name              TEXT,
    lead_sponsor_class             TEXT,                     -- canonical agency class (§5.5)

    -- Denormalized counts for list badges without joins
    condition_count                INTEGER NOT NULL DEFAULT 0,
    location_count                 INTEGER NOT NULL DEFAULT 0,
    intervention_count             INTEGER NOT NULL DEFAULT 0,
    outcome_count                  INTEGER NOT NULL DEFAULT 0,
    sponsor_count                  INTEGER NOT NULL DEFAULT 0,

    -- Derived helper for the "active only" toggle (§5.3)
    is_active                      INTEGER NOT NULL DEFAULT 0,

    -- Derived year buckets for analytics (from start_date; NULL if unknown) (§5.6)
    start_year                     INTEGER
);
```

Design intent: **a list row and every filter are served entirely from this table** — no joins, no decompression.

### 3.2 Detail tables (MUST be populated — currently empty in the old DB)

```sql
CREATE TABLE condition (
    condition_id INTEGER PRIMARY KEY,
    trial_id     INTEGER NOT NULL REFERENCES trial(trial_id),
    name         TEXT    NOT NULL,
    name_norm    TEXT    NOT NULL,          -- Unicode-lowercased trim(name) (§2) — the filter join key
    ordinal      INTEGER NOT NULL DEFAULT 0 -- order as listed on the study (0-based)
);

CREATE TABLE location (
    location_id   INTEGER PRIMARY KEY,
    trial_id      INTEGER NOT NULL REFERENCES trial(trial_id),
    facility_name TEXT,
    city          TEXT,
    state         TEXT,
    country       TEXT,
    postal_code   TEXT,
    status        TEXT,                      -- recruitment status at this site (canonical enum §5.1 if present)
    latitude      REAL,
    longitude     REAL,
    ordinal       INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE intervention (
    intervention_id INTEGER PRIMARY KEY,
    trial_id        INTEGER NOT NULL REFERENCES trial(trial_id),
    type            TEXT,                    -- DRUG / DEVICE / PROCEDURE / BIOLOGICAL / BEHAVIORAL / etc. (§5.7)
    type_display    TEXT,
    name            TEXT    NOT NULL,
    description     TEXT,
    ordinal         INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE outcome (
    outcome_id  INTEGER PRIMARY KEY,
    trial_id    INTEGER NOT NULL REFERENCES trial(trial_id),
    type        TEXT    NOT NULL,            -- PRIMARY / SECONDARY / OTHER
    measure     TEXT    NOT NULL,
    time_frame  TEXT,
    description TEXT,
    ordinal     INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE sponsor (
    sponsor_id   INTEGER PRIMARY KEY,
    trial_id     INTEGER NOT NULL REFERENCES trial(trial_id),
    name         TEXT    NOT NULL,
    agency_class TEXT,                       -- canonical agency class (§5.5)
    role         TEXT,                       -- LEAD / COLLABORATOR
    ordinal      INTEGER NOT NULL DEFAULT 0
);

-- One-to-one with trial
CREATE TABLE eligibility (
    trial_id         INTEGER PRIMARY KEY REFERENCES trial(trial_id),
    inclusion_z      BLOB,                   -- compressed parsed inclusion block (§2, §5.8)
    exclusion_z      BLOB,                   -- compressed parsed exclusion block
    raw_text_z       BLOB,                   -- compressed original criteria; written ONLY when the
                                             --   inclusion/exclusion split failed (~2–3% of trials)
    study_population TEXT,                   -- observational only
    sampling_method  TEXT                    -- observational only
);
```

### 3.3 Full-text search (FTS5)

Use a **contentless** FTS5 table whose `rowid` equals `trial.trial_id`. The app matches, then joins back to `trial`.

```sql
CREATE VIRTUAL TABLE trial_fts USING fts5(
    nct_id,
    brief_title,
    official_title,
    conditions,                 -- newline-joined condition names for this trial
    interventions,              -- newline-joined intervention names
    content = '',               -- contentless: index only, rowid = trial_id
    tokenize = 'porter unicode61 remove_diacritics 2'
);
```

Summaries are deliberately **not** indexed: excluding them keeps the index about
ten times smaller, and titles + conditions + interventions cover realistic
search intent.

Populate after all trials, conditions and interventions exist:

```sql
INSERT INTO trial_fts(rowid, nct_id, brief_title, official_title, conditions, interventions)
SELECT t.trial_id, t.nct_id, t.brief_title, t.official_title,
       (SELECT group_concat(c.name, char(10)) FROM condition c WHERE c.trial_id = t.trial_id),
       (SELECT group_concat(i.name, char(10)) FROM intervention i WHERE i.trial_id = t.trial_id)
FROM trial t;
```

> The app queries `... FROM trial_fts JOIN trial ON trial.trial_id = trial_fts.rowid WHERE trial_fts MATCH ? ORDER BY trial_fts.rank LIMIT ? OFFSET ?`. `nct_id` is indexed so an exact NCT lookup also works through FTS. Note that the MATCH operand must be the table name — FTS5 rejects an alias there.

### 3.4 Lookup tables (distinct filter values + counts)

Each holds the distinct values used to populate filter menus, with a `trial_count` for display and a `sort_order`.

```sql
CREATE TABLE lookup_status     (value TEXT PRIMARY KEY, display TEXT NOT NULL, trial_count INTEGER NOT NULL DEFAULT 0, sort_order INTEGER NOT NULL DEFAULT 0);
CREATE TABLE lookup_phase      (value TEXT PRIMARY KEY, display TEXT NOT NULL, trial_count INTEGER NOT NULL DEFAULT 0, sort_order INTEGER NOT NULL DEFAULT 0);
CREATE TABLE lookup_study_type (value TEXT PRIMARY KEY, display TEXT NOT NULL, trial_count INTEGER NOT NULL DEFAULT 0, sort_order INTEGER NOT NULL DEFAULT 0);
CREATE TABLE lookup_gender     (value TEXT PRIMARY KEY, display TEXT NOT NULL, trial_count INTEGER NOT NULL DEFAULT 0, sort_order INTEGER NOT NULL DEFAULT 0);
CREATE TABLE lookup_country    (value TEXT PRIMARY KEY, trial_count INTEGER NOT NULL DEFAULT 0);
CREATE TABLE lookup_condition  (value      TEXT PRIMARY KEY,               -- representative casing, for display
                                value_norm TEXT NOT NULL,                  -- join key: matches condition.name_norm
                                trial_count INTEGER NOT NULL DEFAULT 0);
CREATE TABLE lookup_age_range  (value TEXT PRIMARY KEY, display TEXT NOT NULL, sort_order INTEGER NOT NULL DEFAULT 0);
```

- `lookup_country.trial_count` = number of **distinct trials** with at least one location in that country (not raw location rows).
- `lookup_condition` is **case-normalized**: "Breast cancer" and "Breast Cancer" are one row. `value` is the representative casing for display, `value_norm` is the key the app binds when filtering, and `trial_count` is the number of **distinct trials** having that condition.
- `lookup_age_range` is a fixed, curated list: `CHILD` "0–17", `ADULT` "18–64", `OLDER_ADULT` "65+". The app maps these buckets onto `min_age_years`/`max_age_years` (which are indexed) rather than scanning `std_ages`, so the bounds above must stay in step with the display strings.

**These counts are load-bearing, not decoration.** The app uses `trial_count`
to render totals without a `COUNT(*)`, and to choose between a correlated
`EXISTS` and an `IN (SELECT …)` plan for the country and condition filters.
Wrong counts cost performance rather than correctness, but the cost is large:
the wrong plan on a rare value measured ~1.5 s versus ~27 ms on a 500k corpus.

### 3.5 Aggregate tables (precomputed analytics — build once, read on device)

```sql
-- Generic per-dimension counts, split by scope ('all' vs 'active')
CREATE TABLE agg_dimension_count (
    dimension TEXT    NOT NULL,   -- 'status' | 'phase' | 'study_type' | 'gender' | 'country' | 'condition'
    value     TEXT    NOT NULL,
    scope     TEXT    NOT NULL,   -- 'all' | 'active'
    count     INTEGER NOT NULL,
    PRIMARY KEY (dimension, value, scope)
);

-- Trials per year (by start_year), split by scope
CREATE TABLE agg_year_count (
    year  INTEGER NOT NULL,
    scope TEXT    NOT NULL,       -- 'all' | 'active'
    count INTEGER NOT NULL,
    PRIMARY KEY (year, scope)
);

-- Top conditions within each start_year (store the ranked list; app usually shows the #1 per year)
CREATE TABLE agg_condition_by_year (
    year      INTEGER NOT NULL,
    condition TEXT    NOT NULL,
    count     INTEGER NOT NULL,
    rank      INTEGER NOT NULL,   -- 1 = most common that year
    PRIMARY KEY (year, condition)
);
```

- Compute `agg_dimension_count` for **both** `scope='all'` and `scope='active'` (active = `trial.is_active = 1`) for dimensions: `status`, `phase`, `study_type`, `gender`, `country`, `condition`. The app reads the top N ordered by `count DESC`.
- `agg_year_count` covers years **1975 → snapshot year** (older/unknown years may simply be absent).
- `agg_condition_by_year` should store at least the **top 10** conditions per year (rank 1–10), ranked by distinct trials. The Analytics screen shows "Top Condition by Year".
- Condition dimensions here use the same case-normalized grouping as `lookup_condition`, so a value appears once regardless of registry casing.

### 3.6 Metadata (single row)

```sql
CREATE TABLE db_metadata (
    id                          INTEGER PRIMARY KEY CHECK (id = 1),
    schema_version              INTEGER NOT NULL,   -- 1
    generator_version           TEXT    NOT NULL,   -- your build tag, e.g. "gen-2026.07.29"
    source                      TEXT    NOT NULL,   -- "ClinicalTrials.gov API v2"
    source_snapshot_date        INTEGER NOT NULL,   -- epoch when data was pulled
    created_at                  INTEGER NOT NULL,   -- epoch when file was built
    total_trials                INTEGER NOT NULL,
    recruiting_count            INTEGER NOT NULL,   -- overall_status = RECRUITING
    active_not_recruiting_count INTEGER NOT NULL,   -- overall_status = ACTIVE_NOT_RECRUITING
    recently_updated_count      INTEGER NOT NULL,   -- last_update_post_date within 30 days of snapshot
    build_options               TEXT                -- human-readable description of the build filters,
                                                    --   e.g. which trials had detailed text omitted
);
```

`build_options` is surfaced verbatim in the app's Settings ▸ Database section,
so write it for a human: it is how a user (or we) can tell why a given trial has
no detailed description.

---

## 4. Indexes (create AFTER bulk insert)

```sql
-- trial: list sorting + every filter column
CREATE INDEX idx_trial_update            ON trial(last_update_post_date DESC);
CREATE INDEX idx_trial_status_update     ON trial(overall_status, last_update_post_date DESC);
CREATE INDEX idx_trial_active_update     ON trial(is_active, last_update_post_date DESC);
CREATE INDEX idx_trial_phase             ON trial(phase);
CREATE INDEX idx_trial_study_type        ON trial(study_type);
CREATE INDEX idx_trial_gender            ON trial(gender_eligibility);
CREATE INDEX idx_trial_country           ON trial(primary_country);
CREATE INDEX idx_trial_condition         ON trial(primary_condition);
CREATE INDEX idx_trial_start_year        ON trial(start_year);
CREATE INDEX idx_trial_min_age           ON trial(min_age_years);
CREATE INDEX idx_trial_max_age           ON trial(max_age_years);

-- detail tables: foreign keys + common groupings
CREATE INDEX idx_condition_trial         ON condition(trial_id);
CREATE INDEX idx_condition_norm          ON condition(name_norm);
CREATE INDEX idx_location_trial          ON location(trial_id);
CREATE INDEX idx_location_country        ON location(country);
CREATE INDEX idx_intervention_trial      ON intervention(trial_id);
CREATE INDEX idx_outcome_trial           ON outcome(trial_id);
CREATE INDEX idx_sponsor_trial           ON sponsor(trial_id);

-- aggregates
CREATE INDEX idx_agg_dim                  ON agg_dimension_count(dimension, scope, count DESC);
CREATE INDEX idx_agg_cby_year             ON agg_condition_by_year(year, rank);
```

`nct_id` is already uniquely indexed via the `UNIQUE` constraint on `trial.nct_id`.

---

## 5. Normalization rules

### 5.1 `overall_status` (and location `status`)
Store the raw ClinicalTrials.gov value **uppercased with underscores** as the canonical `value`; provide a friendly `status_display`. Canonical set:

| Canonical `value` | `status_display` |
|---|---|
| `RECRUITING` | Recruiting |
| `NOT_YET_RECRUITING` | Not yet recruiting |
| `ENROLLING_BY_INVITATION` | Enrolling by invitation |
| `ACTIVE_NOT_RECRUITING` | Active, not recruiting |
| `COMPLETED` | Completed |
| `SUSPENDED` | Suspended |
| `TERMINATED` | Terminated |
| `WITHDRAWN` | Withdrawn |
| `UNKNOWN` | Unknown status |
| `AVAILABLE` | Available |
| `NO_LONGER_AVAILABLE` | No longer available |
| `TEMPORARILY_NOT_AVAILABLE` | Temporarily not available |
| `APPROVED_FOR_MARKETING` | Approved for marketing |
| `WITHHELD` | Withheld |

### 5.2 `phase`
API v2 gives an array `phases`. Collapse to a single canonical value:

| Source | Canonical `phase` | `phase_display` |
|---|---|---|
| `EARLY_PHASE1` | `EARLY_PHASE1` | Early Phase 1 |
| `PHASE1` | `PHASE1` | Phase 1 |
| `PHASE1`+`PHASE2` | `PHASE1_PHASE2` | Phase 1/Phase 2 |
| `PHASE2` | `PHASE2` | Phase 2 |
| `PHASE2`+`PHASE3` | `PHASE2_PHASE3` | Phase 2/Phase 3 |
| `PHASE3` | `PHASE3` | Phase 3 |
| `PHASE4` | `PHASE4` | Phase 4 |
| `NA` / empty | `NULL` | (omit / "Not Applicable") |

### 5.3 `is_active`
Set `is_active = 1` when `overall_status` ∈ {`RECRUITING`, `NOT_YET_RECRUITING`, `ENROLLING_BY_INVITATION`, `ACTIVE_NOT_RECRUITING`}; else `0`. (This drives the app's "active only" toggle and the `scope='active'` aggregates.)

### 5.4 Age normalization (`min_age_years` / `max_age_years`)
Parse strings like `"18 Years"`, `"6 Months"`, `"2 Weeks"`, `"90 Days"`, `"N/A"`:
- Convert to **years (REAL)**: Years×1, Months÷12, Weeks÷52.1429, Days÷365.25, Hours/Minutes → ~0.
- `"N/A"`, empty, or unparseable → `NULL`.
- Always keep the original in `min_age_display` / `max_age_display`.

### 5.5 `agency_class` / `lead_sponsor_class`
Canonicalize API `class`: `NIH`, `FED`, `OTHER_GOV`, `INDIV`, `INDUSTRY`, `NETWORK`, `AMBIG`, `OTHER`, `UNKNOWN`. Store as-is uppercased.

### 5.6 `start_year`
Integer calendar year extracted from `start_date` (UTC). `NULL` if start date unknown. Used by `agg_year_count` and `agg_condition_by_year`.

### 5.7 `intervention.type`
Canonicalize: `DRUG`, `DEVICE`, `BIOLOGICAL`, `PROCEDURE`, `RADIATION`, `BEHAVIORAL`, `GENETIC`, `DIETARY_SUPPLEMENT`, `COMBINATION_PRODUCT`, `DIAGNOSTIC_TEST`, `OTHER`. Provide `type_display` (title case).

### 5.8 Eligibility parsing
`eligibilityModule.eligibilityCriteria` is a single free-text block. Store the whole thing in `eligibility.raw_text`. Best-effort split into `inclusion` / `exclusion` by locating the "Inclusion Criteria" and "Exclusion Criteria" headers (case-insensitive). If it can't be split cleanly, leave `inclusion`/`exclusion` `NULL` and rely on `raw_text`.

### 5.9 Denormalized `primary_*` and counts
- `primary_condition` = first condition (`condition.ordinal = 0`).
- `primary_country` / `primary_state` = country/state of the first location (`location.ordinal = 0`); pick a recruiting location first if you want it more useful, otherwise first listed.
- `lead_sponsor_name` / `lead_sponsor_class` = the sponsor with `role = LEAD`.
- `*_count` columns = actual row counts of the related child tables for that trial.
- Compute these **after** child tables are inserted (single `UPDATE ... FROM` pass per field, or during a post-processing step).

---

## 6. ClinicalTrials.gov API v2 → column mapping

Base: `GET https://clinicaltrials.gov/api/v2/studies?pageSize=1000&pageToken=…&fields=…`
Each study lives under `protocolSection` (+ `hasResults`, `derivedSection`).

| DB column | API v2 path |
|---|---|
| `nct_id` | `identificationModule.nctId` |
| `brief_title` | `identificationModule.briefTitle` |
| `official_title` | `identificationModule.officialTitle` |
| `overall_status` | `statusModule.overallStatus` |
| `study_type` | `designModule.studyType` |
| `phase` | `designModule.phases[]` (collapse per §5.2) |
| `summary_snippet` | `descriptionModule.briefSummary`, first ~300 chars, plain text |
| `brief_summary_z` | `descriptionModule.briefSummary`, compressed (§2) |
| `detailed_description_z` | `descriptionModule.detailedDescription`, compressed (§2) |
| `start_date` / `_display` | `statusModule.startDateStruct.date` |
| `completion_date` / `_display` | `statusModule.completionDateStruct.date` (fallback `primaryCompletionDateStruct.date`) |
| `first_posted_date` / `_display` | `statusModule.studyFirstPostDateStruct.date` |
| `last_update_post_date` / `_display` | `statusModule.lastUpdatePostDateStruct.date` |
| `gender_eligibility` | `eligibilityModule.sex` (`ALL`/`MALE`/`FEMALE`) |
| `min_age_display` / `min_age_years` | `eligibilityModule.minimumAge` |
| `max_age_display` / `max_age_years` | `eligibilityModule.maximumAge` |
| `std_ages` | `eligibilityModule.stdAges[]`, joined with commas |
| `healthy_volunteers` | `eligibilityModule.healthyVolunteers` |
| `enrollment_count` | `designModule.enrollmentInfo.count` |
| `why_stopped` | `statusModule.whyStopped` |
| `has_results` | top-level `hasResults` |
| `fda_regulated_drug` | `oversightModule.isFdaRegulatedDrug` |
| `has_expanded_access` | `statusModule.expandedAccessInfo.hasExpandedAccess` |
| `condition.*` | `conditionsModule.conditions[]` (index → `ordinal`) |
| `location.*` | `contactsLocationsModule.locations[]` → `facility`, `city`, `state`, `country`, `zip`→`postal_code`, `status`, `geoPoint.lat`→`latitude`, `geoPoint.lon`→`longitude` |
| `intervention.*` | `armsInterventionsModule.interventions[]` → `type`, `name`, `description` |
| `outcome.* (PRIMARY)` | `outcomesModule.primaryOutcomes[]` → `measure`, `timeFrame`, `description` |
| `outcome.* (SECONDARY)` | `outcomesModule.secondaryOutcomes[]` |
| `outcome.* (OTHER)` | `outcomesModule.otherOutcomes[]` |
| `sponsor.* (LEAD)` | `sponsorCollaboratorsModule.leadSponsor` → `name`, `class`; `role=LEAD` |
| `sponsor.* (COLLABORATOR)` | `sponsorCollaboratorsModule.collaborators[]`; `role=COLLABORATOR` |
| `eligibility.inclusion_z` / `exclusion_z` | `eligibilityModule.eligibilityCriteria`, split per §5.8, each compressed |
| `eligibility.raw_text_z` | `eligibilityModule.eligibilityCriteria`, compressed — **only when the split failed** |
| `eligibility.study_population` | `eligibilityModule.studyPopulation` |
| `eligibility.sampling_method` | `eligibilityModule.samplingMethod` |

**Paging:** loop on `nextPageToken` until absent. Consider `countTotal=true` on the first call to size progress. Respect rate limits (throttle / retry with backoff on HTTP 429/5xx). Record the pull timestamp as `source_snapshot_date`.

---

## 7. Build pipeline (recommended order)

1. **Create** the empty DB, set `application_id` + `user_version`, apply build-speed pragmas, create **tables only** (no indexes yet).
2. **Fetch & insert** studies page-by-page inside transactions: insert `trial` (scalars + flags + dates + eligibility scalars, leaving `primary_*`/counts/`is_active`/`start_year` for step 4 or compute inline), then its `condition` / `location` / `intervention` / `outcome` / `sponsor` / `eligibility` rows.
3. **Post-process trial rows**: set `is_active`, `start_year`, `primary_condition`, `primary_country`, `primary_state`, `lead_sponsor_name`, `lead_sponsor_class`, and the `*_count` columns.
4. **Build FTS5** (`trial_fts`) from `trial` + `condition` + `intervention`.
5. **Build lookup tables** (distinct values + trial-based counts).
6. **Build aggregates** (`agg_dimension_count` for all+active, `agg_year_count`, `agg_condition_by_year`).
7. **Write `db_metadata`** (counts, snapshot date, versions).
8. **Create all indexes** (§4).
9. **Finalize**: `PRAGMA wal_checkpoint(TRUNCATE)` → `PRAGMA journal_mode=DELETE` → `VACUUM` → `ANALYZE`.
10. **Validate** (§8). Emit `trialbeacon.sqlite` with no `-wal`/`-shm` beside it.

---

## 8. Validation / acceptance criteria

The build must **fail loudly** unless all of these pass:

- [ ] No Core Data artifacts: `SELECT name FROM sqlite_master WHERE name LIKE 'Z%' OR name LIKE 'A%CHANGE%' OR name IN ('ATRANSACTION','Z_METADATA','Z_MODELCACHE','Z_PRIMARYKEY');` returns **0 rows**.
- [ ] `PRAGMA integrity_check;` → `ok`.
- [ ] `PRAGMA foreign_key_check;` → **0 rows**.
- [ ] `PRAGMA journal_mode;` is **not** `wal`; no `.sqlite-wal` / `.sqlite-shm` files exist.
- [ ] `SELECT count(*) FROM trial;` matches `db_metadata.total_trials` and is > 0.
- [ ] Every detail table is **non-empty** and every `trial_id` referenced exists: `condition`, `location`, `intervention`, `outcome`, `sponsor`, `eligibility` all have rows (barring genuinely data-less studies).
- [ ] Orphan check: no child row points to a missing `trial_id` (covered by `foreign_key_check`).
- [ ] `SELECT count(*) FROM trial_fts;` equals `SELECT count(*) FROM trial;`.
- [ ] FTS smoke test returns rows: `SELECT count(*) FROM trial_fts WHERE trial_fts MATCH 'cancer';`
- [ ] Every `trial.overall_status` value exists in `lookup_status`; likewise phase/study_type/gender/country/condition ↔ their lookup tables.
- [ ] `db_metadata.recruiting_count = (SELECT count(*) FROM trial WHERE overall_status='RECRUITING')` (and same for the other two counters).
- [ ] `agg_dimension_count` has both `scope='all'` and `scope='active'` for each dimension; totals reconcile with direct `GROUP BY` on `trial`.
- [ ] No `start_date`/`last_update_post_date` stored as Core Data reference-date doubles (spot check: `last_update_post_date` epoch converts to a sane recent date).
- [ ] Final file opens successfully with `SQLITE_OPEN_READONLY`.

Checks added in revision 1.1, all of which guard something the client depends on:

- [ ] **Round-trip every compressed column on a sample.** Decode 1,000 random
      `brief_summary_z` / `detailed_description_z` / `inclusion_z` values with
      the reference decoder and compare against the source text. A malformed
      length prefix is invisible until a detail screen renders blank.
- [ ] **`summary_snippet` is present** wherever `brief_summary_z` is, and is
      plain text (no BLOB, no HTML). List rows read only this column.
- [ ] **Normalization join integrity:**
      `SELECT count(*) FROM condition c LEFT JOIN lookup_condition l ON l.value_norm = c.name_norm WHERE l.value_norm IS NULL;`
      must be **0**. This is the check that catches a Unicode case-folding
      mismatch — the filter silently returns nothing when it fails.
- [ ] **Normalization was not done in SQL:**
      `SELECT count(*) FROM lookup_condition WHERE value_norm <> value AND value_norm = lower(value);`
      should be well below the row count; a value containing non-ASCII uppercase
      (e.g. "Ⅱ") must differ from `lower(value)`.
- [ ] **`lookup_*.trial_count` reconciles** with a direct `GROUP BY` for every
      dimension (see the note in §3.4 — these counts pick the query plan).
- [ ] `trial_fts` rowids equal `trial.trial_id`:
      `SELECT count(*) FROM trial_fts f LEFT JOIN trial t ON t.trial_id = f.rowid WHERE t.trial_id IS NULL;` → 0.
- [ ] **`lookup_age_range` bucket bounds** still match `CHILD` 0–17, `ADULT`
      18–64, `OLDER_ADULT` 65+; the app hardcodes those numeric bounds against
      `min_age_years`/`max_age_years`.
- [ ] `db_metadata.build_options` is non-empty and readable by a human.

Recommended reconciliation query to log at the end of every build:

```sql
SELECT
  (SELECT count(*) FROM trial)                                            AS trials,
  (SELECT count(*) FROM condition)                                        AS conditions,
  (SELECT count(*) FROM location)                                         AS locations,
  (SELECT count(*) FROM intervention)                                     AS interventions,
  (SELECT count(*) FROM outcome)                                          AS outcomes,
  (SELECT count(*) FROM sponsor)                                          AS sponsors,
  (SELECT count(*) FROM eligibility)                                      AS eligibility_rows,
  (SELECT count(*) FROM trial_fts)                                        AS fts_rows,
  (SELECT count(*) FROM trial WHERE is_active=1)                          AS active_trials;
```

---

## 9. Notes for whoever wires up the iOS side (context only)

The iOS app will:
- Bundle `trialbeacon.sqlite` and open it **read-only, in place** (no copy to Documents, no import into SwiftData).
- Drive lists with paginated queries (`ORDER BY last_update_post_date DESC LIMIT ? OFFSET ?`) + the filter indexes.
- Drive search via `trial_fts MATCH` → join to `trial`.
- Drive the dashboard/Analytics from `db_metadata` + the `agg_*` tables (no full-table scans).
- Keep watchlist / profile / notes in a **separate** small SwiftData store, referencing trials by `nct_id`.

So: **the app never mutates this file** — it is a pure, read-only reference database. Everything the app needs to be fast (indexes, FTS, aggregates, denormalized `primary_*` + counts) must be baked in here at generation time.

---

## 10. Change log

- **v1** — Initial clean relational schema. Replaces the Core Data `.store` export. Adds FTS5, lookup tables, precomputed aggregates, denormalized `primary_*`/count columns, Unix-epoch dates, and mandates populating the previously-empty detail tables.
- **v1, spec revision 1.1 (2026-07-29)** — Reconciled with the shipped
  generator: compressed `*_z` text columns and `summary_snippet`, FTS scope
  (titles/conditions/interventions, no summaries), extra `trial` columns
  (`enrollment_count`, `why_stopped`, `std_ages`), `eligibility.raw_text_z` on
  split failure only, `lookup_condition.value_norm`, `db_metadata.build_options`.
  Added the Unicode normalization rule to §2 and eight acceptance checks to §8.
  Added §11 (open change requests). No `schema_version` change.
- **v1, spec revision 1.2 (2026-07-29)** — Verified the whole contract against
  the real `gen-2026.07.29` sample build. Closed §11.3 (location status uses the
  canonical enum) and §11.4 (coordinates on 97.8% of locations). Opened §11.6:
  `lookup_condition.value_norm` is specified but absent from the build. Confirmed
  working as specified: raw-DEFLATE `*_z` blobs with a 4-byte length prefix
  (1,686 sampled, all decoded), `summary_snippet` coverage, FTS5 rowid join,
  `std_ages` as a comma-separated list, and all lookup/aggregate table shapes.
  Re-measured §11.1 and §11.5 after fixing the benchmark harness, which had been
  timing with 10 ms granularity and silently erroring on the FTS cases. The
  corrected figures replace earlier estimates: the title index is a larger win
  than first reported (96 ms → 0.08 ms warm, not 130 ms → 1 ms), and broad FTS
  is cheaper than first reported (54 ms warm, not 190 ms). Scripts to reproduce
  any of it live in the iOS repo under `PerfTesting/`.

---

## 11. Open change requests from the iOS app

Verified against the real sample build `gen-2026.07.29` (4,028 trials, 38 MB),
plus profiling on a synthetic 500k-trial fixture.

**Priority ask: §11.8 — compress detail-only child tables into one BLOB per
trial.** Indexes §11.1 and §11.7 remain. §11.6 (`value_norm`) is resolved on
the full corpus.

Resolved by inspecting the sample build: §11.3 (status vocabulary — correct)
and §11.4 (coordinates — populated).

### 11.1 Index `brief_title` for the "Title A–Z" sort — **requested**

The list offers two sorts. "Recently updated" is served by
`idx_trial_update`; "Title A–Z" has no index, so keyset pagination over
`brief_title` degrades into a full table scan plus sort.

```sql
CREATE INDEX idx_trial_title ON trial(brief_title, trial_id);
```

The query plan is the clearest part of the argument. Without the index:

```
SCAN trial / USE TEMP B-TREE FOR ORDER BY
```

It sorts all 500k rows to hand back 40. With the index:

```
SCAN trial USING INDEX idx_trial_title
```

It reads 40 index entries and stops. Measured on the 500k-trial, 559 MB fixture
(`PerfTesting/measure_open_items.py`, first page of 40 with the app's column
list):

| | First query, fresh connection | Warm median of 10 |
|---|---|---|
| No index | 740 ms | 96 ms |
| `idx_trial_title` | 0.14 ms | 0.08 ms |

Subsequent keyset pages are likewise sub-millisecond. The first-query figure
swings with OS page-cache state — repeat runs land anywhere from ~350 ms to
~740 ms — but the warm median and the plan are stable, and the index removes
the sort in every case.

The index costs **24.9 MB** (559.4 MB → 584.3 MB, confirmed against `dbstat`);
expect roughly 25–40 MB on the real corpus, where titles are longer. Include
`trial_id` as the second column — the app's cursor is `(brief_title, trial_id)`,
and the composite lets the whole keyset predicate be served from the index.

### 11.2 Index `lookup_condition.value_norm` — nice to have

The condition filter menu searches with `value_norm LIKE '%…%'`, which cannot
use an index, but the app also resolves a selected condition by primary key on
`value`. If `lookup_condition` grows past ~100k rows, a covering index would
help the menu's `ORDER BY trial_count DESC` path:

```sql
CREATE INDEX idx_lookup_condition_count ON lookup_condition(trial_count DESC, value);
```

Low priority — the current scan is a few milliseconds and runs on a dedicated
connection.

### 11.3 Confirm the `location.status` vocabulary — **resolved, no action**

`location.status` is documented as "canonical recruitment status of the site
(may be NULL)". The app renders it as a badge next to each site using the same
palette as `overall_status`, so the two vocabularies have to agree.

They do. The sample build emits exactly the §5.1 canonical set —
`RECRUITING`, `NOT_YET_RECRUITING`, `ACTIVE_NOT_RECRUITING`,
`ENROLLING_BY_INVITATION`, `COMPLETED`, `SUSPENDED`, `TERMINATED`,
`WITHDRAWN`, `AVAILABLE`. Please keep it that way.

### 11.4 Populate `latitude`/`longitude` wherever the registry has them — **resolved, no action**

The detail screen draws a map of study sites from these columns and falls back
to a text list when they are absent.

The sample build populates coordinates on 53,439 of 54,668 locations (97.8%),
which is ample. No change needed.

### 11.5 Note on the FTS performance target — no action needed

`TRIALBEACON_DATABASE.md` §7 targets "FTS query < 30 ms". That holds for
selective queries but not for broad ones, because `ORDER BY rank` has to score
every match before it can return the top 40. On the 500k fixture:

| Query | Matches | First | Warm median |
|---|---|---|---|
| `"nct00250000"*` | 1 | 1.9 ms | 0.05 ms |
| `"breast"* "canc"*` | many | 84 ms | 64 ms |
| `"cancer"*` | 71,428 | 153 ms | 54 ms |

So a selective lookup beats the target comfortably, while any term matching tens
of thousands of rows costs tens of milliseconds regardless. That is inherent to
ranked FTS5, not a defect in the build.

The app absorbs it rather than asking the generator to change anything: search
runs on its own connection, keystrokes are debounced, and a superseded query is
abandoned with `sqlite3_interrupt`. Flagging it only so the number in §7 isn't
read as a regression when someone measures a one-word search.

### 11.6 `lookup_condition.value_norm` — **resolved on full corpus**

The early `gen-2026.07.29` sample (4,028 trials) shipped without
`value_norm`. The full `101,705`-trial build has it, every row populated, and
the join integrity check is clean:

```
PRAGMA table_info(lookup_condition);
-- value, value_norm, trial_count

SELECT COUNT(*) FROM condition c
LEFT JOIN lookup_condition l ON l.value_norm = c.name_norm
WHERE l.value_norm IS NULL;
-- 0
```

Keep producing it. No further action.


### 11.7 Index `first_posted_date` for a "Newly added" sort — **requested**

The Home screen wants a row of *newly registered* trials, which is a different
and more useful signal than "recently updated": an update is often an
administrative edit, whereas a first posting is genuinely new research.

`trial.first_posted_date` is populated, but nothing indexes it, so ordering by
it degrades exactly the way §11.1 describes — full scan plus sort.

```sql
CREATE INDEX idx_trial_first_posted ON trial(first_posted_date DESC, trial_id DESC);
```

Same shape as the reasoning in §11.1: include `trial_id` so the composite can
serve a keyset cursor of `(first_posted_date, trial_id)`. Expect a similar cost
to `idx_trial_update`. Until this lands the app sorts that row by
`last_update_post_date`, which is indexed.

### 11.8 Pack detail-only child tables into one compressed BLOB per trial — **done (schema v2)**

Implemented by the generator; see `TRIALBEACON_DATABASE.md` §4.1 / §4.2 / §7.
Ship target: ~491.5 MB, `PRAGMA user_version = 2`. Note: `o.type` ships as
uppercase `PRIMARY` / `SECONDARY` / `OTHER` (not the lowercase example below).

Measured on the current `101,705`-trial / ~738 MB file. Search, filter, sort,
list rows and analytics never touch these tables — only the trial detail screen
does. Stored as plain text across hundreds of thousands of tiny rows they are
the bulk of the file:

| Object | Size |
|---|---|
| `outcome` (+ index) | ~198 MB |
| `location` (+ indexes) | ~79 MB |
| `intervention` (+ index) | ~39 MB |
| `sponsor` (+ index) | ~11 MB |
| **Total** | **~327 MB** |

Compressing each short field alone is useless (headers outweigh the saving).
Grouping a trial's child rows into **one JSON blob and DEFLATE-compressing that
blob** gets ~3×. Projected: **~327 MB → ~119 MB** (~208 MB saved), with no
network and no functional change.

#### What to emit

Add one column on `trial`:

```sql
ALTER TABLE trial ADD COLUMN detail_z BLOB;   -- compressed JSON, same *_z format as §2
```

**Blob format — identical to the existing `*_z` contract (§2):**

1. 4-byte little-endian `UInt32` = uncompressed UTF-8 byte count
2. Raw DEFLATE stream (Apple `COMPRESSION_ZLIB`, no zlib header)
3. If the payload is incompressible, store raw UTF-8 after the same length prefix
4. `NULL` only when the trial truly has no child rows of any kind

**Uncompressed JSON shape** (compact, no whitespace). Keys are short on purpose:

```json
{
  "o": [["primary","Primary measure text","12 weeks","Optional description"], ...],
  "l": [["Facility Name","City","State","United States","02115","RECRUITING",42.36,-71.06], ...],
  "i": [["DRUG","Drug","Drug name","Optional description"], ...],
  "s": [["Sponsor Name","INDUSTRY","LEAD"], ...]
}
```

Column order inside each array (positional — do not add named keys):

| Key | Array columns (in order) |
|---|---|
| `o` (outcomes) | `type`, `measure`, `time_frame`, `description` |
| `l` (locations) | `facility_name`, `city`, `state`, `country`, `postal_code`, `status`, `latitude`, `longitude` |
| `i` (interventions) | `type`, `type_display`, `name`, `description` |
| `s` (sponsors) | `name`, `agency_class`, `role` |

Use JSON `null` for missing values. Preserve the same row order you currently
write via `ordinal`. Omit a key entirely when that trial has no rows of that
kind (e.g. no interventions → no `"i"`).

Leave `brief_summary_z`, `detailed_description_z` and the three
`eligibility.*_z` columns alone for this change — they are already compressed.
This ask is only the four relational child tables above.

#### Country filter still needs a slim side table

The Discover country filter currently does
`EXISTS (SELECT 1 FROM location WHERE country = ?)`. Once `location` is no
longer a relational table, replace that with:

```sql
CREATE TABLE trial_country (
    trial_id INTEGER NOT NULL REFERENCES trial(trial_id),
    country  TEXT    NOT NULL,
    PRIMARY KEY (trial_id, country)
);
CREATE INDEX idx_trial_country_country ON trial_country(country);
```

Populate with the **distinct** `(trial_id, country)` pairs from the locations
you would have written. Keep `trial.primary_country` and
`lookup_country` exactly as they are — those still drive the list row and the
filter menu. The existing `location` table and `idx_location_country` go away.

#### What to drop once `detail_z` is populated

After every trial has a correct `detail_z` and `trial_country` is populated:

- Drop tables: `outcome`, `location`, `intervention`, `sponsor`
- Drop their indexes (`idx_outcome_trial`, `idx_location_*`,
  `idx_intervention_trial`, `idx_sponsor_trial`, …)
- Keep: `condition` (filter), `eligibility` (already compressed), `trial_fts*`,
  all `lookup_*`, all `agg_*`, `db_metadata`

Bump `schema_version` / `PRAGMA user_version` to **2** so the iOS app can detect
the new shape. Keep writing `generator_version` / `build_options` so we can tell
builds apart.

#### Acceptance checks

- [x] Round-trip checks on `detail_z` (generator suite includes packed-blob
      decode vs claimed counts).
- [x] `detail_z` null only when a trial has none of the four child kinds.
- [x] `trial_country` populated; orphan-country check is 0.
- [x] File size after `VACUUM` ~491.5 MB (was ~738 MB).
- [x] Finalization still ends with checkpoint → `journal_mode=DELETE` →
      `VACUUM` → `ANALYZE`, no `-wal`/`-shm`.

#### What the iOS app does

`TrialStore` detects `detail_z` / `trial_country` at open:

1. Reads `trial.detail_z` once when opening a trial
2. Inflates + decodes JSON into the same in-memory models
3. Points the country filter at `trial_country` instead of `location`
4. Uses `idx_trial_title` / `idx_trial_first_posted` for Title A–Z and Newly added
5. Still opens a transitional v1 file via the old relational paths

No live ClinicalTrials.gov fetch. Search, filters, analytics and list rows are
unchanged — they never touched these tables.
