# TrialBeacon Database — iOS Integration Guide

**File:** `trialbeacon.sqlite`  
**Shipping schema version:** **14** (`PRAGMA user_version` == `db_metadata.schema_version`)  
**iOS gate:** `minimumSchemaVersion = 13`, `supportedSchemaVersion = 14` — **only v13–v14 open** (refuse older and newer)  
**Produced by:** nmbTrialBeaconDB (macOS generator), from the ClinicalTrials.gov API v2  
**Status:** replaces every previous database format (the old SwiftData/Core Data `TrialBeacon.store` with `Z*`/`ACHANGE` tables is gone)

**Current overview:** start with [`DATABASE_SCHEMA.md`](DATABASE_SCHEMA.md) for a concise shipping map; this file is the deep integration guide.

### Schema evolution (read this)

This document’s body still describes the **core contract through schema v8** (packed `detail_z`, FTS, lookups, aggregates, Pulse tables, etc.). That core remains valid.

**Additive shipping contracts** (required for the current client) live in:

| Version | Doc | Highlights |
|--------:|-----|------------|
| 10 | `IOS_CHANGES_schema_v10.md` | Organisation / site entity tables, trial↔org links |
| 11 | `IOS_CHANGES_schema_v11.md` | Org HQ + website, `active_trial_count`, `lookup_condition.domain`, canonical sites |
| 12 | `IOS_CHANGES_schema_v12.md` | Slim `trial_site` (`trial_id`, `site_id` only); size defaults |
| 13 | `IOS_CHANGES_schema_v13.md` | Publications + OpenAlex enrichment, `trial_results` counters, org pub counts, Drugs@FDA |
| 14 | `IOS_CHANGES_schema_v14.md` | Site pub counters, `popular_condition`, `lookup_intervention`, `popular_intervention` |

When the narrative below says “schema version 8”, treat that as the **last fully inlined** revision in this file — not the shipping `user_version`. Prefer the `IOS_CHANGES_*` notes for anything org/site/HQ/domain/`trial_site`/publications/FDA/Discover browse.

## What changed in schema v2 — read this first

v2 implements `DB_GENERATOR_SPEC.md` §11.8, §11.1 and §11.7. Three things move:

1. **`outcome`, `location`, `intervention` and `sponsor` tables are gone.** Each trial's rows from all four now live in one DEFLATE-compressed JSON blob, `trial.detail_z` (§4.2). Same blob framing as the existing `*_z` columns.
2. **New `trial_country` table** — distinct `(trial_id, country)` pairs — is what the country filter joins against now (§3.3).
3. **Two new indexes**: `idx_trial_title` for the Title A–Z sort, `idx_trial_first_posted` for a "Newly added" sort.

Also: the file is now written with a **16 KB page size** rather than the 4 KB default, which is worth 64 MB on its own (§7).

Measured on the same 101,705-trial corpus: **738.9 MB → 491.5 MB**, a 33% reduction, with no loss of data and nothing fetched over the network. The four retired tables and their indexes occupied 327.8 MiB; the blob that replaces them costs 102 MB.

Nothing else changed. Search, filters, sorting, list rows, lookups and aggregates are untouched — they never read those four tables.

---

## 1. What this file is

A single, self-contained, **read-only** SQLite database containing the full clinical-trial corpus:

- Plain relational schema — no Core Data/SwiftData artifacts, no `Z*` tables, no persistent history.
- Everything the registry provides, including the detail records that were empty in the old exports. Conditions and countries stay relational because filters need them; the detail-only records are packed (§4.2).
- FTS5 full-text search index, prebuilt.
- Lookup tables for filter menus and precomputed aggregates for analytics — no full-table scans needed at runtime.
- Finalized with `VACUUM` + `ANALYZE`, journal mode `DELETE`, no `-wal`/`-shm` sidecars.
- Every build passes 134 automated integrity checks before export; a file that failed validation will never be handed to you. Nine of those checks decode a spread of `detail_z` blobs and compare them against what each trial row claims. The generator can also re-run the whole suite against any copy of the file — including the one inside your app bundle — so if you ever suspect the database, hand it back for a check rather than guessing.

### The one rule

**Open it in place, read-only. Never copy it, never import it into SwiftData, never write to it.**
The old iOS code that re-inserted every row into a second on-device store is exactly what doubled the footprint and made launches slow. User data (watchlists, profiles, notes) belongs in the app's own separate SwiftData store, referencing trials by `nct_id`.

---

## 2. Opening the database

Bundle the file as a resource, then open read-only. Works with GRDB (recommended) or raw `sqlite3`.

```swift
// GRDB
let path = Bundle.main.path(forResource: "trialbeacon", ofType: "sqlite")!
var config = Configuration()
config.readonly = true
let dbQueue = try DatabaseQueue(path: path, configuration: config)
```

```swift
// Raw sqlite3
var db: OpaquePointer?
sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil)
```

Optional: append `?immutable=1` via URI filename for a small extra speedup — safe because app-bundle resources can never change while the app runs.

**Set the cache size in kibibytes, not pages.** SQLite's default cache is 2,000 *pages*; at the 16 KB page size (§7) that is 32 MB of resident memory instead of the 8 MB you'd get at 4 KB. A negative `cache_size` is interpreted as KiB and is page-size independent:

```swift
config.prepareDatabase { db in
    try db.execute(sql: "PRAGMA cache_size = -8000")   // 8 MB, whatever the page size
}
```

Sanity check on first open:

```sql
PRAGMA user_version;                 -- must be 8; if greater, the schema changed (see §9)
SELECT * FROM db_metadata WHERE id = 1;
```

---

## 3. Schema

Entity relationship: `trial` 1—N `condition` and 1—N `trial_country`, 1—0..1 `eligibility`, and 1—0..1 `trial.detail_z` (the packed outcomes, sites, interventions and sponsors). Relational children reference `trial(trial_id)` (the integer rowid). `nct_id` is the stable public identifier — use it for deep links, watchlists, and anything persisted on your side.

The dividing line is deliberate: **anything the app filters, sorts, counts or searches on is a column or a row; anything only one trial's detail screen reads is inside `detail_z`.**

### 3.1 `trial` — one row per study

```sql
CREATE TABLE trial (
    trial_id                       INTEGER PRIMARY KEY,   -- rowid; joins + FTS rowid
    nct_id                         TEXT    NOT NULL UNIQUE,
    brief_title                    TEXT    NOT NULL,      -- plain text: indexed and shown on every list row
    official_title_z               BLOB,                  -- compressed, see §4 (was TEXT before schema 5)
    overall_status                 TEXT    NOT NULL,      -- canonical: RECRUITING, COMPLETED, …
    study_type                     TEXT,                  -- INTERVENTIONAL | OBSERVATIONAL | EXPANDED_ACCESS
    phase                          TEXT,                  -- EARLY_PHASE1, PHASE1, PHASE1_PHASE2, … (NULL = N/A)
    summary_snippet_z              BLOB,                  -- compressed; first ~300 chars of brief summary (§4)
    brief_summary_z                BLOB,                  -- compressed, see §4
    detailed_description_z         BLOB,                  -- compressed, see §4
    start_date                     INTEGER,               -- Unix epoch (UTC); partial dates → first instant
    completion_date                INTEGER,
    first_posted_date              INTEGER,
    last_update_post_date          INTEGER NOT NULL,      -- default sort key
    date_precision                 INTEGER NOT NULL,      -- 2 bits per date, see §3.1.1
    gender_eligibility             TEXT,                  -- ALL | MALE | FEMALE
    min_age_display                TEXT,                  -- "18 Years", "6 Months", …
    max_age_display                TEXT,
    min_age_years                  REAL,                  -- numeric, for range filters
    max_age_years                  REAL,
    healthy_volunteers             INTEGER,               -- 0/1/NULL
    enrollment_count               INTEGER,
    why_stopped                    TEXT,                  -- only for terminated/suspended/withdrawn
    std_ages                       INTEGER NOT NULL,      -- bit set: 1 CHILD, 2 ADULT, 4 OLDER_ADULT
    has_results                    INTEGER NOT NULL DEFAULT 0,
    fda_regulated_drug             INTEGER NOT NULL DEFAULT 0,
    has_expanded_access            INTEGER NOT NULL DEFAULT 0,
    primary_condition              TEXT,                  -- first condition (list rows without a join)
    primary_country                TEXT,                  -- prefers a RECRUITING site
    primary_state                  TEXT,
    lead_sponsor_name              TEXT,
    lead_sponsor_class             TEXT,                  -- NIH | INDUSTRY | OTHER | FED | …
    condition_count                INTEGER NOT NULL DEFAULT 0,   -- "N conditions" badges,
    location_count                 INTEGER NOT NULL DEFAULT 0,   -- no COUNT(*) queries needed
    intervention_count             INTEGER NOT NULL DEFAULT 0,
    outcome_count                  INTEGER NOT NULL DEFAULT 0,
    sponsor_count                  INTEGER NOT NULL DEFAULT 0,
    is_active                      INTEGER NOT NULL DEFAULT 0,   -- 1 for RECRUITING, NOT_YET_RECRUITING,
                                                                 --   ENROLLING_BY_INVITATION, ACTIVE_NOT_RECRUITING
    start_year                     INTEGER,                      -- derived from start_date, for charts
    detail_z                       BLOB                          -- packed outcomes/sites/interventions/
                                                                 --   sponsors, see §4.2
);
```

Design intent: **a trial list row and most filters are served entirely from this table** — no joins, no decompression, with one exception added in schema 4: the four enum display strings now come from a lookup table (§3.1.2).

#### 3.1.1 `date_precision` — how much of each date is real

Schema 4 removed `start_date_display`, `completion_date_display`, `first_posted_date_display` and `last_update_post_date_display`. They held the registry's own string — `"2019"`, `"2019-06"` or `"2019-06-15"` — which is the epoch plus one fact the epoch can't carry: how much of the date the sponsor actually stated. A trial that says "June 2019" and one that says "1 June 2019" store the same second.

That fact is now two bits per date in `date_precision`:

| Value | Meaning | Render as |
|---|---|---|
| 0 | no date | — (the epoch is NULL) |
| 1 | year only | `2019` |
| 2 | year and month | `June 2019` |
| 3 | full date | `15 June 2019` |

| Date | Shift |
|---|---|
| `start_date` | `date_precision & 3` |
| `completion_date` | `(date_precision >> 2) & 3` |
| `first_posted_date` | `(date_precision >> 4) & 3` |
| `last_update_post_date` | `(date_precision >> 6) & 3` |

Always read the epoch **in UTC**. The epoch is the first instant of the stated precision, so a month-precision date is the 1st and a year-precision date is 1 January; formatting in local time can roll either back into the previous month or year.

```swift
enum DatePrecision: Int { case none = 0, year = 1, month = 2, day = 3 }

func precision(_ mask: Int, _ shift: Int) -> DatePrecision {
    DatePrecision(rawValue: (mask >> shift) & 3) ?? .none
}

func formatted(epoch: Int64?, precision: DatePrecision, locale: Locale = .current) -> String? {
    guard let epoch, precision != .none else { return nil }
    let date = Date(timeIntervalSince1970: TimeInterval(epoch))
    let formatter = DateFormatter()
    formatter.locale = locale
    formatter.timeZone = TimeZone(secondsFromGMT: 0)   // required: the epoch is UTC
    switch precision {
    case .none:  return nil
    case .year:  formatter.setLocalizedDateFormatFromTemplate("y")
    case .month: formatter.setLocalizedDateFormatFromTemplate("yMMMM")
    case .day:   formatter.setLocalizedDateFormatFromTemplate("yMMMMd")
    }
    return formatter.string(from: date)
}
```

This is strictly better than the old column, which shipped an ISO string you would have had to reformat anyway and could not localise.

#### 3.1.2 Enum display strings now come from the lookup tables

`status_display`, `study_type_display`, `phase_display` and `gender_eligibility_display` are gone. Each was one of at most fourteen distinct strings repeated on every row. The identical string is in the matching lookup table, which you are already loading for the filter menus:

| Removed column | Read instead |
|---|---|
| `status_display` | `lookup_status.display WHERE value = trial.overall_status` |
| `study_type_display` | `lookup_study_type.display WHERE value = trial.study_type` |
| `phase_display` | `lookup_phase.display WHERE value = trial.phase` |
| `gender_eligibility_display` | `lookup_gender.display WHERE value = trial.gender_eligibility` |

The lookup tables are tiny (14, 3, 7 and 3 rows). Load all four into dictionaries once at launch and map in memory — do not add a join to your list query. A build-time check guarantees every value present on a trial row has a lookup row, so the mapping never misses.

`min_age_display` and `max_age_display` **stay**. The registry's unit is a real choice — "6 Months" and "26 Weeks" are both written, and neither is recoverable from `min_age_years = 0.5`.

The `*_count` columns still describe the packed records: `outcome_count` is the number of entries you will find under `"o"` in `detail_z`, and so on. Use them for badges without inflating anything.

### 3.2 `condition` — relational, because the condition filter joins it

```sql
CREATE TABLE condition (
    condition_id INTEGER PRIMARY KEY,
    trial_id     INTEGER NOT NULL REFERENCES trial(trial_id),
    name         TEXT NOT NULL,
    name_norm    TEXT NOT NULL,        -- lowercased/trimmed, for grouping & filter matching
    ordinal      INTEGER NOT NULL DEFAULT 0
);
```

`ordinal` preserves the registry's original ordering — `ORDER BY ordinal` when displaying.

### 3.3 `trial_country` — the country filter's join table

```sql
CREATE TABLE trial_country (
    trial_id INTEGER NOT NULL REFERENCES trial(trial_id),
    country  TEXT    NOT NULL,
    PRIMARY KEY (trial_id, country)
);
CREATE INDEX idx_trial_country_country ON trial_country(country);
```

One row per **distinct** country a trial has a site in — 631,325 sites collapse to far fewer pairs. Replaces `EXISTS (SELECT 1 FROM location WHERE country = ?)`:

```sql
SELECT t.* FROM trial t
WHERE EXISTS (SELECT 1 FROM trial_country tc
              WHERE tc.trial_id = t.trial_id AND tc.country = ?)
ORDER BY t.last_update_post_date DESC LIMIT 50;
```

`trial.primary_country` and `lookup_country` are unchanged and still drive list rows and the filter menu. Full site detail — facility name, city, postcode, per-site status, coordinates — is in `detail_z`.

### 3.4 `eligibility` — one row per trial

```sql
CREATE TABLE eligibility (
    trial_id         INTEGER PRIMARY KEY REFERENCES trial(trial_id),
    inclusion_z      BLOB,             -- compressed, see §4.1
    exclusion_z      BLOB,             -- compressed
    raw_text_z       BLOB,             -- compressed; ONLY set when the inclusion/exclusion
                                       --   split failed (~2–3% of trials). Check _z columns
                                       --   first; fall back to raw_text_z.
    study_population_z BLOB,           -- compressed, §4; observational studies only
    sampling_method  TEXT
);
```

### 3.5 Full-text search — `trial_fts` (FTS5, contentless)

```sql
CREATE VIRTUAL TABLE trial_fts USING fts5(
    nct_id, brief_title, official_title, conditions, interventions, brief_summary,
    content = '',
    tokenize = 'porter unicode61 remove_diacritics 2'
);
```

- `rowid` of `trial_fts` **is** `trial.trial_id` — join on it.
- Indexed fields: NCT ID, both titles, all condition names, all intervention names (newline-joined), and the full brief summary. A bare `MATCH` searches all six, so "all fields" search now covers summary prose.
- `brief_summary` holds the same text as `trial.brief_summary_z`, indexed before compression. The table is contentless, so this is tokens only — the text itself is still stored once, in the blob.
- `detailed_description` is **not** indexed. It is several times larger than the summaries and would cost far more than it returns; revisit only if summary search proves insufficient.
- Contentless table: you cannot `SELECT` column values from it, only `MATCH` and join back to `trial`.

```sql
SELECT t.*
FROM trial_fts f JOIN trial t ON t.trial_id = f.rowid
WHERE trial_fts MATCH ?          -- e.g. 'breast cancer' or 'nct_id:NCT05*'
ORDER BY rank
LIMIT 50;
```

Escape user input (wrap each term in double quotes) unless you intentionally support FTS query syntax.

To search one field only, prefix the query with the column name — `brief_summary : "quality of life"` hits summaries alone, `brief_title : cancer` titles alone.

**Index size.** Indexing the summaries took `trial_fts` from 116 MiB to 314 MiB, so the summary text costs about 198 MiB, and the whole file went from 2045 MiB to 2248 MiB (+9.9%). The older note in this document claimed skipping summaries kept the index "~10× smaller"; that was an estimate and it was wrong — measured, it is about 2.7×. `detailed_description` is the field that would actually be expensive.

### 3.6 Lookup tables (filter menus — never SELECT DISTINCT at runtime)

```sql
CREATE TABLE lookup_status     (value TEXT PRIMARY KEY, display TEXT NOT NULL, trial_count INTEGER, sort_order INTEGER);
CREATE TABLE lookup_phase      (value TEXT PRIMARY KEY, display TEXT NOT NULL, trial_count INTEGER, sort_order INTEGER);
CREATE TABLE lookup_study_type (value TEXT PRIMARY KEY, display TEXT NOT NULL, trial_count INTEGER, sort_order INTEGER);
CREATE TABLE lookup_gender     (value TEXT PRIMARY KEY, display TEXT NOT NULL, trial_count INTEGER, sort_order INTEGER);
CREATE TABLE lookup_country    (value TEXT PRIMARY KEY, trial_count INTEGER);   -- distinct trials per country
CREATE TABLE lookup_condition  (value      TEXT PRIMARY KEY,   -- cleaned display spelling (see §3.6.1)
                                value_norm TEXT NOT NULL,      -- join key: matches condition.name_norm
                                trial_count INTEGER,           -- distinct trials
                                is_population INTEGER NOT NULL DEFAULT 0);  -- 1 = names a population, not a condition (§3.6.2)
CREATE TABLE lookup_age_range  (value TEXT PRIMARY KEY, display TEXT NOT NULL, sort_order INTEGER);
                                -- CHILD "0–17" / ADULT "18–64" / OLDER_ADULT "65+"
```

Use `ORDER BY sort_order` for status/phase menus (curated order: Recruiting first). `trial_count` lets you render "Recruiting (68,412)" without a query.

#### 3.6.1 Condition names are cleaned — display them as they come

Sponsors type condition names by hand, so the registry holds `Breast Cancer`, `BREAST CANCER`, `breast cancer`, `Asthma.` and `PASSIVE SMOKING ,` for things that are all one condition. The generator settles this before shipping, so **`lookup_condition.value` and `condition.name` are ready to display verbatim — do not title-case, capitalize or otherwise post-process them in the app.** Doing so would break the acronyms.

What it does:

- **One spelling per condition**, chosen by how many trials use it. The most common spelling in the registry wins, so `Healthy`, `Breast Cancer`, `Hypertension` and `Coronary Artery Disease` replaced the shouted variants that used to surface.
- **Acronyms and codes are preserved**, because the casing is never invented — it is learned from the ~44,000 entries the registry already writes in mixed case. `HIV`, `COPD`, `PTSD`, `NSCLC`, `COVID-19`, `BRAF V600E`, `Type IV`, `CIN 2`, MeSH codes like `C05.550.905` and brand names like `FARAPULSE` all stay exactly as they are. Roughly 670 menu entries are legitimately uppercase and that is correct.
- **Punctuation is tidied**: trailing full stops, commas and semicolons, wrapping quotes, leading dashes, doubled spaces, and CJK full-width punctuation. This also merges the duplicates it creates — `Asthma.` folds into `Asthma`.
- **` & ` becomes ` and `**, which merges another 11 pairs the registry keeps apart — `Head & Neck Cancer` (34 trials) joins `Head and Neck Cancer` (1,606).
- `trial.primary_condition` is rewritten to match, so a trial's chip list and the filter menu always agree.
- **A few names are decided by hand.** Around 15 terms in the registry appear only in capitals and nowhere in mixed case, so there's no evidence to learn from; the generator leaves those alone, and the operator can correct the handful that are genuinely wrong (`MEDİTERRANEAN DİET` → `Mediterranean Diet`). Those decisions live outside the database and only ever change presentation, never which condition a trial has.
- **A bracketed abbreviation folds into the plain name.** `Atrial Fibrillation (AF)` becomes `Atrial Fibrillation`, and likewise for `(CAD)`, `(HF)`, `(MCI)`, `(COPD)`, `(HCC)` and the rest — see §3.6.3, which matters more than it looks.

Casing changes only affect display. `condition.name_norm` and `lookup_condition.value_norm` remain the join keys, the FTS index is case-insensitive, and every count is computed after the clean-up. Five of the validation checks (§ acceptance) exist to guarantee this: one spelling per condition, no shouted prose, no stray punctuation, no condition listed twice on a trial, and `primary_condition` matching the trial's own rows.

**Important — filtering by condition:** join `lookup_condition.value_norm` to `condition.name_norm` directly. Do **not** compute the normalized form yourself with SQLite's `lower()`: it only lowercases ASCII, so names containing characters like the Unicode Roman numeral "Ⅱ" (as in "Dyslipidemia (Fredrickson Type Ⅱa)", which really is in the registry) will silently fail to match. Both `name_norm` and `value_norm` were produced with Swift's full Unicode lowercasing. If you need to normalize a string in the app, use Swift's `lowercased()`, not SQL.

#### 3.6.2 `is_population` — labels that name who was studied, not what

ClinicalTrials.gov requires a condition on every registration, so trials of healthy people put something in the box anyway: `Healthy`, `Healthy Volunteers`, `Healthy Male Subjects`, `Normal Volunteers`. These are real registry data and stay in the database, but they are not conditions, and they dominate the analytics — `Healthy` alone is the single most-used label in the registry at 11,059 trials.

`lookup_condition.is_population = 1` marks them. **127 of 129,573 labels are flagged**, and they are what the `*_excl_healthy` aggregate scopes (§3.7) leave out.

The flag is set by rule, not by a hand-written list, because the registry's long tail defeats any list — `Healthy Adult Subjects`, `Healthy Young Adults`, `Healthy Older Adults`, `Healthy Subjects (HS)` and 100 more. The rule is:

> The label mentions `healthy` or `normal`, **and every word in it** is one that only ever describes a population — `adult`, `male`, `female`, `child`, `elderly`, `young`, `volunteer`, `subject`, `participant`, `control`, `individual`, `person`, `people`, `population`, `study`, and the plurals of those.

One unrecognised word and the label is a real condition. That is what keeps `Healthy Aging` (262 trials), `Healthy Lifestyle`, `Healthy Diet` and `Healthy Nutrition` in — they are genuine research topics — and what keeps `Normal Tension Glaucoma` and `Normal Pressure Hydrocephalus` in, since they carry disease words the vocabulary has never heard of.

**Read the flag; don't reimplement the rule.** It ships with the data precisely so the numbers and the definition can't drift apart. To show the population labels in a menu, just don't filter on it.

#### 3.6.3 Bracketed abbreviations are folded into the plain name

The registry holds `Atrial Fibrillation` and `Atrial Fibrillation (AF)` as two separate labels for one condition, and sponsors have been drifting from the first to the second. Across the two most recent complete years the plain name fell 132 → 71 while the bracketed one rose 46 → 116 — a 152% "rise" in a condition that did not move at all. Left alone, that artefact is the top of the growth leaderboard, and it also splits the condition filter menu and the top-conditions chart.

So `X (ABBR)` is folded into `X`, under two conditions:

1. **`ABBR` must genuinely abbreviate `X`** — every character of it appears in `X`, in order, starting from `X`'s own first character. Digits count, so `Type 2 Diabetes Mellitus (T2DM)` folds too. That accepts `(AF)`, `(CAD)`, `(MCI)`, `(QOL)`, `(HCC)`, `(T1D)` and `(NF1)`. It rejects `Lung Cancer (NSCLC)` and `Prostate Cancer (CRPC)`, which name *subtypes*; `Colorectal Cancer (MSI-H)`, `Stroke (Subacute)` and `Obesity (Disorder)`, which are qualifiers; and the FAB codes — `Adult Acute Megakaryoblastic Leukemia (M7)` starts with A, not M, so `M7` is never read as an abbreviation of it. Those all stay separate, because merging them would combine two different things.

The rule errs towards leaving things alone. `Knee Osteoarthritis (OA)` and `Metastatic Colorectal Cancer (CRC)` are not folded, because the abbreviation covers only part of the label; that is a missed merge rather than a wrong one.
2. **The plain name must already exist in the registry.** This limits the fold to consolidating a split the registry itself created. A label whose abbreviation is its only appearance — `Chronic Fatigue Syndrome (CFS)`, if nobody ever wrote it without brackets — is left exactly as it is, so no term loses its only searchable copy of an acronym.

Hand-made overrides are never folded.

For the app this changes nothing structurally: it is a spelling decision like every other one in §3.6.1, applied before any count is computed. It does mean condition counts and filter-menu entries shift between schema 7 and 8 for the affected conditions, and they are more correct for it.

### 3.7 Aggregates (analytics screens — read, don't compute)

```sql
CREATE TABLE agg_dimension_count (   -- dimension ∈ status|phase|study_type|gender|country|condition
    dimension TEXT NOT NULL, value TEXT NOT NULL,
    scope     TEXT NOT NULL,         -- see the scope table below
    count     INTEGER NOT NULL,
    PRIMARY KEY (dimension, value, scope)
);

CREATE TABLE agg_year_count (        -- trials by start year
    year INTEGER NOT NULL, scope TEXT NOT NULL, count INTEGER NOT NULL,
    PRIMARY KEY (year, scope)
);

CREATE TABLE agg_condition_by_year ( -- top 10 conditions per start year
    year INTEGER NOT NULL, condition TEXT NOT NULL,
    scope TEXT NOT NULL,
    count INTEGER NOT NULL, rank INTEGER NOT NULL,   -- rank 1–10 within (year, scope)
    PRIMARY KEY (year, condition, scope)
);

CREATE TABLE agg_condition_year_count (  -- EVERY condition per start year
    year INTEGER NOT NULL, condition TEXT NOT NULL,
    scope TEXT NOT NULL, trial_count INTEGER NOT NULL,
    PRIMARY KEY (scope, year, condition)
) WITHOUT ROWID;
```

`agg_condition_year_count` is the same grouping as `agg_condition_by_year` with the top-ten cut removed: every canonical condition with at least one trial in that start year, no minimum. 964,045 rows across the four scopes, 42 MiB. `agg_condition_by_year` is a strict subset of it and is kept only so existing queries don't have to change.

There is deliberately no secondary index. The primary key already puts a `(scope, year)` slice together, and sorting that slice by `trial_count` costs less than the ~40 MiB an index on it would add.

```sql
-- top 25 conditions for 2025
SELECT condition, trial_count FROM agg_condition_year_count
 WHERE scope = 'all_excl_healthy' AND year = 2025
 ORDER BY trial_count DESC LIMIT 25;
```

#### 3.7.1 Scopes

All four tables carry the same four scopes. Every dimension is built for every scope, so the analytics screen can switch scope without any table becoming unavailable.

| `scope` | Trials counted |
|---|---|
| `all` | every trial |
| `active` | `trial.is_active = 1` |
| `all_excl_healthy` | every trial except those whose **`primary_condition` is flagged `is_population`** |
| `active_excl_healthy` | both filters together |

**The exclusion rule is on the primary condition, not on any condition.** A cancer trial that also lists `Healthy Volunteers` is still counted — only its `Healthy Volunteers` label is dropped from the condition rankings. Because `primary_condition` already prefers a real condition over a population term, a trial is dropped only when *every* condition it names is a population term.

Two things follow, and both matter when you're reading the numbers:

- In the `*_excl_healthy` scopes, `dimension='condition'` and `agg_condition_by_year` contain **no rows** for population labels. You do not need to filter them client-side.
- `all_excl_healthy` is always a subset of `all`, year by year — there's a validation check that enforces it.

Example: top conditions among active trials, healthy-volunteer studies left out —

```sql
SELECT value, count FROM agg_dimension_count
 WHERE dimension = 'condition' AND scope = 'active_excl_healthy'
 ORDER BY count DESC LIMIT 20;
```

### 3.7.2 Pulse tables (home screen)

Three shortlists, built so the home screen never scans `trial`. Each is small, denormalised, and read directly.

```sql
CREATE TABLE pulse_on_this_day (
    month INTEGER NOT NULL,             -- 1–12, UTC
    day   INTEGER NOT NULL,             -- 1–31, UTC
    rank  INTEGER NOT NULL,             -- 1 = best, dense within a day
    trial_id INTEGER NOT NULL, nct_id TEXT NOT NULL,
    first_posted_date INTEGER NOT NULL,
    first_posted_year INTEGER NOT NULL, -- UTC, same call as month/day
    score REAL NOT NULL,
    brief_title TEXT NOT NULL, phase TEXT, overall_status TEXT NOT NULL,
    primary_condition TEXT, enrollment_count INTEGER, has_results INTEGER NOT NULL,
    PRIMARY KEY (month, day, rank)
) WITHOUT ROWID;
```

30 studies for each of the 366 calendar days, 10,980 rows. Read it with `WHERE month = ? AND day = ?` and either take `rank = 1` or rotate deterministically through the 30 using a date seed.

**Use `first_posted_year` rather than deriving the year from `first_posted_date` yourself.** `month`, `day` and `first_posted_year` all come from the same UTC conversion. A client that formats the epoch in local time will disagree with the row it is sitting in, for trials posted near midnight.

The shortlist exists because ~1,630 trials share any given calendar day and most of them are withdrawn single-site studies with no phase and no results. `score` favours later phase (0–30), larger enrolment (0–25), posted results (+15) and interventional design (+10), and penalises `WITHDRAWN` (−40), `UNKNOWN` (−20), `SUSPENDED` (−10) and `TERMINATED` (−5). It is a ranking aid only; it means nothing outside this table and should not be shown.

```sql
CREATE TABLE pulse_interesting_trial (
    candidate_id INTEGER PRIMARY KEY,   -- dense 1..N
    trial_id INTEGER NOT NULL UNIQUE, nct_id TEXT NOT NULL,
    brief_title TEXT NOT NULL, primary_condition TEXT,
    overall_status TEXT NOT NULL, primary_country TEXT,
    interest_tags TEXT NOT NULL,        -- CSV, up to 3, strongest first
    score REAL NOT NULL,
    blurb TEXT,                         -- one line on why it is here
    batch_month TEXT NOT NULL           -- 'YYYY-MM' of the build
);
```

A pool of studies worth showing for their own sake — virtual reality, dance, music, spaceflight, therapy animals, and so on — mined at build time from the full-text index over titles, intervention names and summaries. A theme named in the title or an intervention counts fully; the same words in a summary count for 35% of that, because "the ward plays music" is not a music study.

**Pick with `candidate_id`, not by `score`.** Ids are dealt round-robin across themes, so consecutive ids are different themes. `candidates[dayOfYear % count]` therefore gives a different kind of study each day. Ordering by `score` instead would group all 3,138 virtual-reality studies together and show a headset for weeks. No one theme may exceed 200 of the pool.

```sql
SELECT * FROM pulse_interesting_trial
 WHERE candidate_id = (:dayOfYear % (SELECT COUNT(*) FROM pulse_interesting_trial)) + 1;
```

```sql
CREATE TABLE pulse_condition_growth (
    scope  TEXT NOT NULL,
    metric TEXT NOT NULL,               -- 'ratio' or 'delta'
    year_from INTEGER NOT NULL, year_to INTEGER NOT NULL,
    rank INTEGER NOT NULL,              -- 1 = fastest by this metric
    condition TEXT NOT NULL,
    count_from INTEGER NOT NULL, count_to INTEGER NOT NULL,
    abs_delta INTEGER NOT NULL,
    growth_ratio REAL,                  -- NULL when count_from = 0
    PRIMARY KEY (scope, metric, rank)
) WITHOUT ROWID;
```

Top 50 per scope per metric, 400 rows. Both leaderboards are shipped because they answer different questions and neither is a safe default on its own:

| `metric` | Ranked by | Minimum base | Reads as |
|---|---|---|---|
| `ratio` | `count_to / count_from` | `count_from >= 20` | "fastest growing" |
| `delta` | `count_to - count_from` | none | "biggest increase" |

The minimum base on `ratio` is what stops "2 trials became 6" outranking everything real. `delta` has no minimum, so `growth_ratio` there is `NULL` for a condition that did not exist in the earlier year.

**Years.** `year_to` is the most recent year that had already finished when the snapshot was taken, and `year_from` is the year before it — for a July 2026 build, 2025 against 2024. A part-year is never compared with a whole one. Note that trials starting late in `year_to` may still be registered after the snapshot, so the most recent year is slightly understated; this affects both metrics equally and does not reorder the leaderboard.

**Use an `_excl_healthy` scope for anything user-facing**, or `Healthy Volunteers` will head the chart.

#### 3.7.3 Recently completed or stopped — no table, and a wording limit

This one needs no new table. `idx_trial_status_update` is `(overall_status, last_update_post_date DESC)`, which is exactly the query:

```sql
SELECT nct_id, brief_title, overall_status, last_update_post_date FROM trial
 WHERE overall_status IN ('COMPLETED', 'TERMINATED', 'SUSPENDED', 'WITHDRAWN')
 ORDER BY last_update_post_date DESC LIMIT 20;
```

**The file records when a trial's record was last updated, not when its status changed.** Those are different dates and the second one is not in the registry feed. So the honest phrasing is "Terminated — record updated recently" or "Completed — record updated 3 days ago", never "terminated yesterday". A trial marked terminated in 2019 whose contact address was fixed last week will surface here, and the copy has to survive that.

Tracking real status-change dates would mean diffing consecutive monthly snapshots and storing the result. That is a future change, not something this file can currently support.

### 3.8 Metadata — `db_metadata` (single row, id = 1)

```sql
CREATE TABLE db_metadata (
    id                          INTEGER PRIMARY KEY CHECK (id = 1),
    schema_version              INTEGER NOT NULL,   -- 8
    generator_version           TEXT    NOT NULL,   -- e.g. "gen-2026.07.30"
    source                      TEXT    NOT NULL,   -- "ClinicalTrials.gov API v2"
    source_snapshot_date        INTEGER NOT NULL,   -- epoch: data current through this date → show in UI
    created_at                  INTEGER NOT NULL,
    total_trials                INTEGER NOT NULL,
    recruiting_count            INTEGER NOT NULL,
    active_not_recruiting_count INTEGER NOT NULL,
    recently_updated_count      INTEGER NOT NULL,   -- updated within 30 days of snapshot
    build_options               TEXT,               -- human-readable description of build filters
    -- The same three headline numbers with healthy-population trials removed,
    -- so the Exclude Healthy toggle can move the overview too (§3.7.1).
    total_trials_excl_healthy                INTEGER NOT NULL,
    recruiting_count_excl_healthy            INTEGER NOT NULL,
    active_not_recruiting_count_excl_healthy INTEGER NOT NULL
);
```

Show "Data current through {source_snapshot_date}" somewhere in the app — it sets expectations for a bundled database.

---

## 4. Compressed columns (`*_z`) — the one non-obvious contract

Long prose and the packed detail records are the bulk of the corpus, so **nine** columns are stored compressed.

**This changed in schema 5.** It used to say that list rows never touch compressed data. That is no longer true: `summary_snippet_z` is a blob, so a list row that shows the snippet has to decompress it. The cost is a few microseconds on a ~265-byte payload — irrelevant for the handful of rows on screen — but it means decompression now belongs in your cell rendering path, not only your detail screen. `brief_title` is deliberately still plain TEXT, because it is on every row *and* indexed.

All nine use one blob format:

**Blob format:** 4-byte little-endian `UInt32` = uncompressed UTF-8 byte count, followed by a raw DEFLATE stream (no zlib header). Edge case: if the payload length equals the prefix value, the payload is the raw UTF-8 bytes (incompressible input — rare). `NULL` means "nothing here". **This framing is unchanged since v1.**

For the record, DEFLATE is not a legacy choice: on these payloads it was measured against LZFSE, LZMA and Brotli and it won every time, because the payloads are individually small enough that the alternatives' bigger windows and headers cost more than they save. LZFSE was 18–35% larger, LZMA 4–25% larger, Brotli 6–8% larger.

#### Schema 3: preset dictionaries — this changes your decoder

Each blob is 1–4 KB, far too small for DEFLATE's 32 KB window to fill, so every blob was independently re-learning that trials say *Inclusion Criteria*, *Placebo*, *Double-Blind* and the same few hundred country and sponsor names. From schema 3, each column is compressed against a **preset dictionary** trained on the registry. It took 21–31% off every blob and 470 MB off the file.

```sql
CREATE TABLE db_dictionary (column_name TEXT PRIMARY KEY,  -- e.g. 'detail_z'
                            dictionary  BLOB NOT NULL);    -- raw preset dictionary, <= 32 KB
```

**Nine rows** as of schema 5, one per compressed column, about 260 KB total. **The primary key is the column name**, so there is no mapping to write — read the row whose `column_name` matches the column you are decompressing. Load them all once at startup.

**Apple's Compression framework cannot do this.** `compression_decode_buffer` has no way to supply a dictionary, so those calls have to go. Use zlib, which is already on iOS and imports straight into Swift — `import zlib`, no bridging header and no linker flag.

> **The trap.** With raw DEFLATE (negative `windowBits`) zlib **never returns `Z_NEED_DICT`.** The common pattern of waiting for that code before calling `inflateSetDictionary` will wait forever, `inflate` will report success, and you will get **convincing mojibake rather than an error**. Set the dictionary immediately after `inflateInit2`, unconditionally. Our validator checks decoded text for U+FFFD precisely because this failure is silent; a debug assertion on your side is worth the five minutes.

If `db_dictionary` is absent or empty, that file predates schema 3 and its blobs decode with the dictionary step skipped — so an optional-dictionary parameter reads both old and new files from one code path.

#### Schema 5: three short columns joined them

`official_title`, `summary_snippet` and `study_population` became `official_title_z`, `summary_snippet_z` and `study_population_z`. Short strings are where a preset dictionary earns most, because there is almost nothing for a from-scratch compressor to learn inside 137 bytes: `official_title` gives up 12.4 MB to zlib on its own but **42.0 MB** with a dictionary. 138.4 MB of payload across the three, and 165 MiB off the file (2.28 GB → 2.10 GB) once the reduced page slack is counted.

They are renamed rather than changed in place on purpose — a reader written for schema 4 fails on the missing column instead of showing someone raw DEFLATE bytes where a title should be.

### 4.1 Text columns

`trial.brief_summary_z`, `trial.detailed_description_z`, `trial.official_title_z`, `trial.summary_snippet_z`, `eligibility.inclusion_z`, `eligibility.exclusion_z`, `eligibility.raw_text_z`, `eligibility.study_population_z`.

Drop-in decoder (Foundation + zlib):

```swift
import Foundation
import zlib

func decompressText(_ blob: Data?, dictionary: Data?) -> String? {
    guard let blob, blob.count > 4 else { return nil }
    let length = blob.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
    let payload = Data(blob.dropFirst(4))
    if payload.count == Int(length) {                       // stored raw
        return String(data: payload, encoding: .utf8)
    }

    var stream = z_stream()
    guard inflateInit2_(&stream, -15, ZLIB_VERSION,
                        Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
    defer { inflateEnd(&stream) }

    // Must be before the first inflate call — raw streams never raise Z_NEED_DICT.
    if let dictionary, !dictionary.isEmpty {
        let ok = dictionary.withUnsafeBytes {
            inflateSetDictionary(&stream, $0.bindMemory(to: Bytef.self).baseAddress,
                                 uInt(dictionary.count)) == Z_OK
        }
        guard ok else { return nil }
    }

    var output = Data(count: Int(length))
    let decoded: Int = output.withUnsafeMutableBytes { dst in
        payload.withUnsafeBytes { src in
            stream.next_in = UnsafeMutablePointer(mutating: src.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(payload.count)
            stream.next_out = dst.bindMemory(to: Bytef.self).baseAddress
            stream.avail_out = uInt(length)
            guard inflate(&stream, Z_FINISH) == Z_STREAM_END else { return 0 }
            return Int(length) - Int(stream.avail_out)
        }
    }
    guard decoded == Int(length) else { return nil }
    return String(data: output, encoding: .utf8)
}
```

Decompression of one trial's text is sub-millisecond; do it lazily when the detail screen appears.

Note: depending on build options, `detailed_description_z` and the eligibility text may be omitted (NULL) for old inactive trials to control file size (`db_metadata.build_options` says which policy was used). `brief_summary_z` and `summary_snippet_z` are always populated when the registry has a summary.

### 4.2 `trial.detail_z` — packed outcomes, sites, interventions and sponsors

Same blob framing as §4.1; inflate it with the same `decompressText` and the result is compact JSON. Keys are single letters and rows are **positional arrays** — there are no field names inside, so read by index.

```json
{
  "o": [["PRIMARY","Overall survival","24 months","Time from randomisation to death"]],
  "l": [["Mount Sinai Hospital","New York","New York","United States","10029","RECRUITING",40.71427,-74.00597]],
  "i": [["DEVICE","Device","i-STAT TBI Test","The test result is shared with the treating clinician."]],
  "s": [["Icahn School of Medicine at Mount Sinai","OTHER","LEAD"],
        ["Abbott Point of Care","INDUSTRY","COLLABORATOR"]]
}
```

| Key | Positional columns |
|---|---|
| `o` outcomes | `type`, `measure`, `time_frame`, `description` |
| `l` locations | `facility_name`, `city`, `state`, `country`, `postal_code`, `status`, `latitude`, `longitude` |
| `i` interventions | `type`, `type_display`, `name`, `description` |
| `s` sponsors | `name`, `agency_class`, `role` |

Rules:

- **Row order is the registry's order** — the old `ordinal` columns are gone because array position now carries that meaning. Don't re-sort.
- **A key is absent when the trial has no rows of that kind.** Treat a missing key as an empty array.
- **Missing values inside a row are JSON `null`.** Only `o.type`, `o.measure`, `i.name`, `s.name` and `s.role` are guaranteed non-null.
- **`o.type` is `PRIMARY` / `SECONDARY` / `OTHER`, uppercase** — the same vocabulary the `outcome.type` column used. (The spec's §11.8 example showed lowercase `"primary"`; that was inconsistent with the rest of the document, so the canonical uppercase form is what ships.)
- **`l.status` is the canonical site status** — the §6 `overall_status` vocabulary, or null. Coordinates are present on ~98% of sites.
- **`detail_z` is `NULL` only when a trial genuinely has none of the four.** A validation check enforces this, so a null blob never means "lost data".

Decoder:

```swift
struct TrialDetail {
    struct Outcome { var type, measure: String; var timeFrame, description: String? }
    struct Site { var facility, city, state, country, postalCode, status: String?
                  var latitude, longitude: Double? }
    struct Intervention { var type, typeDisplay: String?; var name: String; var description: String? }
    struct Sponsor { var name: String; var agencyClass: String?; var role: String }

    var outcomes: [Outcome] = []
    var sites: [Site] = []
    var interventions: [Intervention] = []
    var sponsors: [Sponsor] = []
}

func decodeDetail(_ blob: Data?) -> TrialDetail? {
    guard let text = decompressText(blob),                       // §4.1
          let data = text.data(using: .utf8),
          let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }

    func rows(_ key: String) -> [[Any]] { (payload[key] as? [[Any]]) ?? [] }
    func str(_ row: [Any], _ i: Int) -> String? { i < row.count ? row[i] as? String : nil }
    func num(_ row: [Any], _ i: Int) -> Double? { i < row.count ? (row[i] as? NSNumber)?.doubleValue : nil }

    var detail = TrialDetail()
    detail.outcomes = rows("o").map {
        .init(type: str($0, 0) ?? "", measure: str($0, 1) ?? "",
              timeFrame: str($0, 2), description: str($0, 3))
    }
    detail.sites = rows("l").map {
        .init(facility: str($0, 0), city: str($0, 1), state: str($0, 2), country: str($0, 3),
              postalCode: str($0, 4), status: str($0, 5),
              latitude: num($0, 6), longitude: num($0, 7))
    }
    detail.interventions = rows("i").map {
        .init(type: str($0, 0), typeDisplay: str($0, 1),
              name: str($0, 2) ?? "", description: str($0, 3))
    }
    detail.sponsors = rows("s").map {
        .init(name: str($0, 0) ?? "", agencyClass: str($0, 1), role: str($0, 2) ?? "")
    }
    return detail
}
```

One blob is on the order of 1 KB stored and 3 KB inflated (2.8× on average), so the whole detail screen is a single row read plus one inflate — cheaper than the five separate indexed queries it replaces.

---

## 5. Query recipes

**Trial list (newest first), keyset pagination — never OFFSET:**

```sql
SELECT trial_id, nct_id, brief_title, overall_status, phase, date_precision,
       primary_condition, primary_country, summary_snippet_z, last_update_post_date
FROM trial
WHERE (last_update_post_date, trial_id) < (?, ?)   -- cursor from the previous page's last row
ORDER BY last_update_post_date DESC, trial_id DESC
LIMIT 50;
```

**Filtered list** (all filter columns are indexed):

```sql
... WHERE is_active = 1 AND phase = 'PHASE3' AND primary_country = 'United States'
ORDER BY last_update_post_date DESC LIMIT 50;
```

**Filter by condition** (any condition, not just primary) — pass `lookup_condition.value_norm` as the parameter:

```sql
SELECT DISTINCT t.trial_id, t.* FROM trial t
JOIN condition c ON c.trial_id = t.trial_id
WHERE c.name_norm = ?                 -- the value_norm from lookup_condition; never lower(?)
ORDER BY t.last_update_post_date DESC LIMIT 50;
```

**Filter by country** — pass a `lookup_country.value`:

```sql
SELECT t.* FROM trial t
WHERE EXISTS (SELECT 1 FROM trial_country tc
              WHERE tc.trial_id = t.trial_id AND tc.country = ?)
ORDER BY t.last_update_post_date DESC LIMIT 50;
```

**Title A–Z and Newly added sorts** (both now indexed, keyset-friendly):

```sql
... ORDER BY brief_title, trial_id LIMIT 40;                       -- idx_trial_title
... ORDER BY first_posted_date DESC, trial_id DESC LIMIT 40;       -- idx_trial_first_posted
```

**Detail screen** — three reads, not seven:

```sql
SELECT * FROM trial       WHERE trial_id = ?;   -- includes detail_z; decode per §4.2
SELECT * FROM condition   WHERE trial_id = ? ORDER BY ordinal;
SELECT * FROM eligibility WHERE trial_id = ?;
```

Outcomes, study sites, interventions and sponsors all come out of the `detail_z` you already fetched with the trial row.

**Resolve a watchlist item:** `SELECT * FROM trial WHERE nct_id = ?;` (unique index).

**Age filter for a 10-year-old patient:**
`WHERE (min_age_years IS NULL OR min_age_years <= 10) AND (max_age_years IS NULL OR max_age_years >= 10)` — or the coarse bucket: `WHERE std_ages & 1` for CHILD (2 = ADULT, 4 = OLDER_ADULT). This was a comma-separated string before schema 3; the bit set is both faster and correct, since `LIKE '%ADULT%'` also matched OLDER_ADULT.

### Indexes you can rely on

`trial`: `last_update_post_date DESC` · `(overall_status, last_update_post_date DESC)` · `(is_active, last_update_post_date DESC)` · `phase` · `study_type` · `gender_eligibility` · `primary_country` · `primary_condition` · `start_year` · `min_age_years` · `max_age_years` · **`(brief_title, trial_id)`** · **`(first_posted_date DESC, trial_id DESC)`** · unique `nct_id`.
Children: `condition(trial_id)` · `condition(name_norm)` · `trial_country(trial_id, country)` (primary key) · `trial_country(country)`.

A validation check runs `EXPLAIN QUERY PLAN` on the list, title, newly-added, country-filter, NCT-lookup and detail-read queries every build, so a missing index fails the build rather than surfacing as a slow screen.

---

## 6. Canonical values

- **overall_status:** `RECRUITING`, `NOT_YET_RECRUITING`, `ENROLLING_BY_INVITATION`, `ACTIVE_NOT_RECRUITING`, `COMPLETED`, `SUSPENDED`, `TERMINATED`, `WITHDRAWN`, `UNKNOWN`, plus rare expanded-access statuses (`AVAILABLE`, `NO_LONGER_AVAILABLE`, `TEMPORARILY_NOT_AVAILABLE`, `APPROVED_FOR_MARKETING`, `WITHHELD`). Always enumerate from `lookup_status` rather than hardcoding.
- **phase:** `EARLY_PHASE1`, `PHASE1`, `PHASE1_PHASE2`, `PHASE2`, `PHASE2_PHASE3`, `PHASE3`, `PHASE4`; `NULL` = not applicable (most observational studies).
- **Booleans** are `INTEGER` 0/1 (or NULL where the registry omitted the field).
- **All epoch dates are UTC seconds.** Partial registry dates ("2019-06") were normalized to the first instant of the stated precision; `date_precision` says how much of each date is real (§3.1.1). Format in UTC, or a month-precision date will roll back into the previous month.

---

## 7. Page size and performance expectations

The file is written with **`PRAGMA page_size = 16384`**, not the 4 KB default. Trial rows carry several compressed blobs, so at 4 KB most rows spill onto overflow pages and waste the tail of each one. Measured on the 101,705-trial build:

| Page size | File |
|---|---|
| 4 KB (default) | 556.1 MB |
| 8 KB | 527.0 MB |
| **16 KB (shipped)** | **491.5 MB** |
| 32 KB | 473.3 MB |

16 KB was chosen because no query got slower — most got marginally faster, there being fewer pages to walk — while 32 KB doubles read amplification and cache cost for another 3.7%. **The one thing you must do is set `cache_size` in KiB (§2)**, otherwise the default 2,000-page cache quietly becomes 32 MB.

Measured targets on a full-corpus build (~500K trials): first list page < 5 ms, filtered page < 20 ms, FTS query < 30 ms for selective terms, detail screen < 15 ms including decompression, cold open < 100 ms. Broad one-word searches matching tens of thousands of rows cost tens of milliseconds regardless — `ORDER BY rank` has to score every match — which is inherent to ranked FTS5, not a defect. No warm-up pass, no preloading, no in-memory caching layer needed. If a query is slow, check that it uses an index (`EXPLAIN QUERY PLAN`) before adding caching.

---

## 8. Differences from `DB_GENERATOR_SPEC.md` (your draft spec)

The generator implements your spec with these deliberate amendments:

0. **Schema v2 packs the detail-only tables** (your §11.8) — see the summary at the top and §4.2. Two notes where the implementation had to make a call your spec left open: `o.type` ships uppercase (`PRIMARY`, not `primary`) to match the vocabulary the rest of the document uses, and `detail_z` sits last in the `trial` column order, matching the `ADD COLUMN` you specified. Your §11.1 and §11.7 indexes are in. Your §11.2 (`idx_lookup_condition_count`) is **not** — you marked it low priority and it costs file size for a few milliseconds on a menu that already runs off the main connection; say the word and it goes in.

1. **Compressed long text** — `brief_summary`/`detailed_description` (trial) and the eligibility text moved into `*_z` BLOB columns (§4). This is the difference between a ~2.5 GB file and roughly half that. `summary_snippet_z` carries a short opening for list rows so lists never have to decompress a whole summary.
2. **FTS excludes summaries** — index covers `nct_id`, both titles, conditions, interventions.
3. **Extra `trial` columns** — `enrollment_count`, `why_stopped`, `std_ages`, `summary_snippet_z`.
4. **`eligibility.raw_text_z` only on split failure** — when inclusion/exclusion parsed cleanly (~97% of trials), raw text is not duplicated.
5. **`lookup_condition` / condition aggregates are case-normalized, and the display spelling is cleaned** — "Breast cancer" and "Breast Cancer" count as one value, and the spelling shown is the one most trials use rather than whichever sorted first (§3.6.1). `lookup_condition` carries an extra `value_norm` column as the join key (see the warning in §3.6); `value` is display-ready.
6. **`agg_condition_by_year`** keeps your top-10-per-year shape, ranked by distinct trials.

Everything else (table names, key structure, canonical enums, epoch dates, keyset pagination model, metadata, acceptance checks) follows the spec.

---

## 9. Versioning & updates

- `PRAGMA user_version` == `db_metadata.schema_version`. **Shipping builds use 14**; the iOS client opens **v13–v14 only** (`minimumSchemaVersion` / `supportedSchemaVersion`). Treat `< 2` as "this file predates the packed details" — a v1 file still has the four relational tables and no `detail_z`, so the two shapes are distinguishable without guessing. The macOS app flags any v1 file it finds as "Older format — create it again".
- For tables/columns introduced after v8, see `IOS_CHANGES_schema_v10.md` … `v13.md` and capability-detect at runtime (do not assume every older bundled file has orgs/sites/HQ/publications/FDA).
- The database is distributed **bundled in the app**; updating data means shipping an app update. When it later moves to CDN/Background Assets delivery, only the file transport changes — the schema and this contract stay the same.
- Application ID: `PRAGMA application_id` = `0x54424541` ("TBEA") — a cheap way to assert you opened the right file.

## 10. Checklist for the iOS side

1. Remove the SwiftData models for the trial corpus and the copy-on-first-launch import path entirely.
2. Add `trialbeacon.sqlite` to the app bundle; open read-only in place, and set `cache_size` in KiB (§2).
3. Build a thin repository layer (GRDB `FetchableRecord` structs or raw queries) using the recipes in §5.
4. Keep user data (watchlist, profile) in a separate SwiftData/GRDB store keyed by `nct_id`.
5. Use `lookup_*` for filter menus, `agg_*` for analytics, `summary_snippet_z` for lists, `decompressText` (§4.1) on both lists and detail screens.
6. Show "Data current through" from `db_metadata.source_snapshot_date`.

### Moving from v1 to v2

7. Delete the `Location`, `Intervention`, `Outcome` and `Sponsor` query paths; decode `trial.detail_z` instead (§4.2) into the same in-memory models you already have.
8. Point the country filter at `trial_country` (§3.3).
9. Bump your known schema version to 2 and add the two new sorts, which now have indexes behind them.
