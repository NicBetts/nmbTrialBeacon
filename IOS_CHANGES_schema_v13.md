# iOS changes — schema v13 (publications + Drugs@FDA)

**Schema version:** `13` (`PRAGMA user_version = 13` == `db_metadata.schema_version`)  
**Generator:** `ArtifactBuilder.schemaVersion = 13`  
**Builds on:** schema 12  
**Full contract:** `TRIALBEACON_DATABASE.md`

**Upgrade path**

| From | Action |
|------|--------|
| v12 | **Repair** adds empty-capable v13 tables, or **Create Database** for a full fill |
| ≤ v11 | **Create Database** |

All enrichment is done in the macOS generator. The iOS app must not call ClinicalTrials.gov, OpenAlex, openFDA, or FDA APIs for this data.

---

## A. Publications

Authoritative trial↔paper links: ClinicalTrials.gov `protocolSection.referencesModule.references[]` only (no discovery).

| Table | Role |
|-------|------|
| `publication` | Deduplicated paper / citation-only record |
| `trial_publication` | Link + exact CTG `reference_type` + `source_citation` + retraction flags |
| `publication_retraction` | Retraction PMIDs from CTG |
| `enrichment_source` | Provenance (`clinicaltrials_gov_references`, `openalex`, `drugs_at_fda`) |

**Identity priority:** PMID → DOI → OpenAlex ID → `citation_fingerprint`  
Citation-only: `enrichment_status = citation_only`, fingerprint = SHA256(**normalised citation text alone**). `reference_type` is **not** part of identity — it lives on `trial_publication`. The same citation listed as both `RESULT` and `BACKGROUND` is one `publication` row and two `trial_publication` rows.

**OpenAlex** (build-time, required): title, journal, dates, cited-by, OA flags/URLs. Persistent cache: `openalex/cache.sqlite` (not shipped).  
Statuses: `enriched` \| `citation_only` \| `not_found` \| `conflict` \| `failed`.  
Conflicts keep CTG identifiers and set `conflict`.

No abstracts, PDFs, author lists, or raw JSON.

### Example

```sql
SELECT p.pmid, p.doi, p.title, p.journal_name, p.publication_year,
       p.is_open_access, p.open_access_url, tp.reference_type, tp.source_citation
  FROM trial_publication tp
  JOIN publication p ON p.publication_id = tp.publication_id
 WHERE tp.trial_id = ?
 ORDER BY tp.reference_type, p.publication_year DESC;
```

---

## B. `trial_results` extensions

| Column | Meaning |
|--------|---------|
| `results_last_update_post_date` | **Proxy only:** study-level `lastUpdatePostDate` when `has_results`. ClinicalTrials.gov has **no** dedicated “results section last amended” date. |
| `secondary_outcome_count` | Posted SECONDARY outcome measures |
| `total_result_outcome_count` | All posted outcome measures |
| `linked_publication_count` | Distinct publications for this trial |
| `result_reference_count` | Links with CTG type `RESULT` |

---

## C. Organisation counters

| Column | Meaning |
|--------|---------|
| `linked_publication_count` | Distinct pubs on the org’s related trials |
| `open_access_publication_count` | Subset with `is_open_access = 1` |

Not total organisational research output — only CTG-linked (OA-enriched) pubs.

---

## D. Drugs@FDA

Tables: `fda_drug`, `fda_brand`, `fda_application`, `fda_drug_application`, `fda_product`, `trial_drug`.

**Approval-date rule (generator):** for each `ApplNo`, earliest `Submissions` row with `SubmissionType = ORIG` and `SubmissionStatus = AP`; date = `SubmissionStatusDate`. Supplements ignored. Ingredient-level `first_known_approval_date` = min of those application dates across apps containing the ingredient; `approval_date_scope = ingredient` when present, else `unknown`.

**Wording:** treat `first_known_approval_date` as **“first known Drugs@FDA approval associated with this ingredient.”** Do **not** call it universal first FDA approval — coverage is incomplete (many biologics, non-US products, and products outside Drugs@FDA are absent), and the date is derived only from ORIG/AP rows in this dataset.

**Matching (conservative):** DRUG / BIOLOGICAL only; exact normalised active ingredient, exact brand, or reviewed overrides. No fuzzy unreviewed matches. **No `is_fda_approved` on trials** — a match only means Drugs@FDA product/application metadata linked to the intervention name. No match ≠ “not FDA approved.”

### Example

```sql
SELECT d.canonical_ingredient, d.first_known_approval_date, d.approval_date_scope,
       td.original_intervention, td.match_method
  FROM trial_drug td
  JOIN fda_drug d ON d.fda_drug_id = td.fda_drug_id
 WHERE td.trial_id = ?;
```

---

### `results_last_update_post_date` — UI wording (required)

This column is **not** when the results section changed. It is when the **study record** was last posted/updated, copied onto the results row only because `has_results` is true.

| Allowed | Forbidden |
|---------|-----------|
| “Study record last updated…” | “Results updated on…” |
| “Record last updated while results are posted…” | Inferring the results section itself changed on that date |

---

## Capability checks

```text
tableExists(publication) && tableExists(trial_publication)
columnExists(trial_results, linked_publication_count)
tableExists(fda_drug)   // may be empty if FDA enrichment skipped
columnExists(organisation, linked_publication_count)
PRAGMA user_version == 13
```

---

## Generator caches (not in the shipping file)

| Path under working folder | Purpose |
|---------------------------|---------|
| `openalex-api-key` | OpenAlex API key (**Settings → Enrichment**) |
| `openalex/cache.sqlite` | PMID/DOI work cache |
| `drugs_at_fda/` | ZIP + extracted TSV + manifest |
| `drug-intervention-overrides.json` | Reviewed intervention maps |
| `drugs_at_fda/staged_interventions.sqlite` | Post-build unmatched export support |

Tools → Enrichment controls fetch/refresh and Create Database toggles.

---

## iOS client checklist (this repo)

| Item | Action |
|------|--------|
| Schema gate | Client now opens **v13–v14 only** (`minimumSchemaVersion = 13`, `supportedSchemaVersion = 14`). See `IOS_CHANGES_schema_v14.md`. |
| Capability flags | `hasPublications`, `hasTrialResultsPublicationCounts`, `hasFdaDrugs`, `hasOrganisationPublicationCounts` |
| Network | Do **not** call CTG / OpenAlex / openFDA / FDA at runtime |
| UI | **Trial Detail:** enhanced Results, Publications section, Drugs@FDA indicator + sheets. **Org / Site Profile:** publication counts + recent list + See all. |
| Wording | Never present `results_last_update_post_date` as “results updated on…” |

### Verify on device

1. Bundle a v13 file → app opens; Data Status shows schema **v13** and Publications / Drugs@FDA sections  
2. Bundle a v14 file → app opens; see `IOS_CHANGES_schema_v14.md`  
3. Bundle ≤ v12 → open **fails** (floor is 13)  
4. Console: `[TrialStore] DB capability:` includes `pubs=` / `fda=`
