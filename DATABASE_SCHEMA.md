# TrialBeacon — Database Schema (shipping)

**File:** `trialbeacon.sqlite` (bundled in the iOS app; **not** stored in this GitHub repo)  
**Shipping schema:** **14** (`PRAGMA user_version` == `db_metadata.schema_version`)  
**iOS gate:** open **only** v13–v14 (`TrialStore.minimumSchemaVersion = 13`, `supportedSchemaVersion = 14`)  
**Producer:** macOS `nmbTrialBeaconDB` from ClinicalTrials.gov API v2 (+ build-time OpenAlex / Drugs@FDA enrichment)  
**Status date:** 9 Aug 2026  

This is the **current** schema overview for shipping builds. Deep recipes, blob framing, and historical narrative live in `TRIALBEACON_DATABASE.md`. Per-version deltas: `IOS_CHANGES_schema_v10.md` … `v14.md`.

---

## 1. Hard rules

1. **Open in place, read-only.** Never copy into SwiftData; never write. User data is a separate on-device SwiftData store keyed by `nct_id`.
2. **Filters / search / sorts / counts** use relational columns and tables. **Detail-only** payloads live in compressed `*_z` / `detail_z` blobs.
3. **No runtime network** for catalog enrichment. CTG, OpenAlex, and Drugs@FDA data are generator-filled.
4. Condition joins use Swift `lowercased()` norms (`name_norm` / `value_norm`) — **never** SQL `lower()` (Unicode).

---

## 2. Schema evolution (shipping client)

| Version | Highlights |
|--------:|------------|
| ≤ 8 | Core: `trial` + `detail_z`, FTS, lookups, aggregates, Pulse |
| 10 | Organisations / sites / trial links |
| 11 | Org HQ/website, `active_trial_count`, condition `domain`, canonical sites |
| 12 | Slim `trial_site` |
| 13 | Publications + OpenAlex fields, results/pub counters, org pub counts, **Drugs@FDA** + `trial_drug` |
| **14** | Site pub counters, `popular_condition`, `lookup_intervention`, `popular_intervention` |

---

## 3. Core tables (always)

### 3.1 `trial`

One row per study. List/filter columns live here; bulky detail is in blobs.

Important columns (non-exhaustive): `trial_id`, `nct_id`, titles, `overall_status`, `phase`, `study_type`, dates (`first_posted_date`, `last_update_post_date`, …), enrollment, lead sponsor fields, `primary_condition`, `primary_country`, FDA-regulated / results flags, count helpers, `brief_summary_z`, `detailed_description_z`, **`detail_z`** (packed outcomes, sites, interventions, sponsors).

### 3.2 Relational children

| Table | Role |
|---|---|
| `condition` | Trial conditions (`name`, `name_norm`) — filter join |
| `trial_country` | Distinct `(trial_id, country)` — country filter |
| `eligibility` | Sex / age / criteria text (as shipped) |

### 3.3 Full-text — `trial_fts` (FTS5)

Contentless FTS5; `rowid` = `trial.trial_id`. Scopes include title, conditions, interventions, summaries, NCT id (client `TrialSearchScope`).

### 3.4 Lookups (filter menus)

`lookup_status`, `lookup_phase`, `lookup_study_type`, `lookup_gender`, `lookup_country`, `lookup_condition` (+ `value_norm`, `is_population`, `domain` when present), `lookup_age_range`, collaborator lookups as shipped.

### 3.5 Aggregates (Analytics)

`agg_dimension_count`, `agg_year_count`, `agg_condition_by_year`, `agg_condition_year_count` (and excl-healthy / active scopes when present). **Do not** full-scan `trial` for charts.

### 3.6 Pulse (Home)

| Table | Use |
|---|---|
| `pulse_on_this_day` | Calendar anniversary pick |
| `pulse_interesting_trial` | Daily interesting pick (`candidate_id` rotation) |
| `pulse_condition_growth` | Research Momentum ratios |

### 3.7 Metadata

| Table | Use |
|---|---|
| `db_metadata` | Single row: totals, schema/generator versions, snapshot date, build options |
| `db_dictionary` | Blob column framing / inflate hints |

---

## 4. Organisations & sites (v10–v12)

| Table | Role |
|---|---|
| `organisation` | Canonical orgs; counters incl. active/recruiting; v13 pub counts |
| `trial_organisation` | Trial ↔ org links |
| `site` | Canonical facilities; coords; v14 pub counts |
| `trial_site` | Trial ↔ site (v12+: slim `trial_id`, `site_id`) |
| Companions | `site_alias`, `site_condition`, `popular_site`, `site_fts`, etc. when present |

Capability flags in the client feature-detect missing older shapes.

---

## 5. Publications (v13)

| Table | Role |
|---|---|
| `publication` | Deduped paper / citation-only record (PMID/DOI/OpenAlex, title, journal, OA flags/URLs, enrichment status) |
| `trial_publication` | Link + CTG `reference_type` + `source_citation` + retraction flags |
| `publication_retraction` | Retraction PMIDs (query exists; UI mainly uses flags today) |
| `enrichment_source` | Provenance bookkeeping |

**iOS uses:** identity + title/journal/dates/OA URLs + `enrichment_status` for citation-only; `source_citation` as **fallback display title** when title empty.  
**Loaded but little-used / unused in UI:** `open_access_status`, `cited_by_count`, full retraction PMID lists.

Org/site **linked / open-access publication counts** are precomputed (org v13; site v14 columns with v13 join fallback).

---

## 6. Drugs@FDA (v13)

| Table | Role |
|---|---|
| `fda_drug` | Canonical ingredient (+ first known approval date / scope) |
| `fda_brand` | Brand names |
| `fda_application` / `fda_drug_application` / `fda_product` | Application & product metadata |
| **`trial_drug`** | Link: trial intervention string ↔ `fda_drug_id` (+ `match_method`) |

**Semantics:** a link means Drugs@FDA **product/application metadata** matched to an intervention name — **not** “this trial’s indication is FDA-approved.” No match ≠ unapproved.

**iOS behaviour:**

| Surface | Data used |
|---|---|
| Trial Detail FDA badge | Requires `trial_drug` row matching intervention (trim + lower) |
| Interventions **Drugs@FDA** filter | `SELECT` distinct `fda_drug` with `COUNT(DISTINCT trial_id)` from `trial_drug` |
| Popular intervention blue chip | In-memory norms from `fda_drug` + `fda_brand` names (catalog presence) |

**CTG** `trial.fda_regulated_drug` is a separate registry boolean (search filter) — not the Drugs@FDA badge.

---

## 7. Discover browse (v14)

| Table | Role |
|---|---|
| `popular_condition` | Top ~50 conditions (excludes `is_population`) |
| `lookup_intervention` | Cleaned intervention names + `value_norm` + `trial_count` + dominant `type` |
| `popular_intervention` | Top ~50 interventions |

**No** `trial_intervention` join table and **no** intervention FTS in v14. Opening a browser row launches Interventions-scoped FTS (or condition filter list) on the client.

---

## 8. Compressed blobs (`*_z` / `detail_z`)

- Framing documented in `TRIALBEACON_DATABASE.md` §4 and `db_dictionary`.
- `detail_z` packs outcomes, locations/sites, interventions, sponsors as DEFLATE JSON.
- Inflate on detail screens only; list rows use relational columns + snippets.

---

## 9. Opening checklist (iOS)

```text
application_id ≈ 0x54424541 (“TBEA”)   // warn if wrong
PRAGMA user_version ∈ [13, 14]
READONLY + immutable=1 URI
Feature-detect: publications, fda_*, trial_drug, popular_*, lookup_intervention, site pub columns, …
```

Capability snapshot is exposed in-app under Data Status.

---

## 10. What is not in GitHub

| Artifact | Where |
|---|---|
| `trialbeacon.sqlite` | Local app bundle / generator output only (multi‑GB; gitignored) |
| OpenAlex / Drugs@FDA caches | Generator working folder only |
| User SwiftData store | On device |

Place the shipping file at:

```text
nmbTrialBeacon/trialbeacon.sqlite
```

Exact name required. Prefer schema **14**. See `nmbTrialBeacon/README_DATABASE.md`.

---

## 11. Related docs

| Doc | Role |
|---|---|
| `TRIALBEACON_DATABASE.md` | Full integration guide + core DDL narrative |
| `IOS_CHANGES_schema_v*.md` | Additive version notes |
| `DB_GENERATOR_SPEC.md` | Generator specification |
| `APPLICATION_STATUS.md` | Product done / not-done / why |
| `TrialBeacon.sqlite.sql` / `PerfTesting/schema.sql` | Auxiliary SQL snapshots (may lag shipping) |

When schema advances past 14, bump this file’s header, add `IOS_CHANGES_schema_vN.md`, and raise `supportedSchemaVersion` in `TrialStore`.
