# iOS changes — schema v10 (Organisations)

**Schema version:** `10`  
**Generator:** `ArtifactBuilder.schemaVersion = 10`

## Summary

Unified **Organisation** entity for Discover Phase 1:

- Lead sponsors and collaborators share one `organisation` identity when `(name, agency_class)` match.
- Roles stay separate on `trial_organisation.role` = `lead_sponsor` | `collaborator`.
- Aggregates are precomputed so the phone never scans the full corpus for org pages.
- `lookup_collaborator` / `trial_collaborator` remain for v9 filter compatibility.
- `organisation_collaborator_map` links collaborator_id → organisation_id.

## New tables

| Table | Purpose |
|-------|---------|
| `organisation` | Entity + aggregate columns (counts, phases, 30-day activity, etc.) |
| `trial_organisation` | `(trial_id, organisation_id, role)` |
| `organisation_collaborator_map` | collaborator_id → organisation_id |
| `organisation_condition` | Top conditions per org (`rank` 1…10) |
| `organisation_country` | Country footprint |
| `popular_organisation` | Pre-ranked Discover list |
| `organisation_fts` | FTS5 on display_name |

## Popular ranking (documented)

```
score = recruiting_trial_count * 3
      + total_related_trial_count
      + new_trial_count_30d * 2
```

Top 50 by score (then display name). Not alphabetical.

## 30-day metrics methodology

| Field | Meaning |
|-------|---------|
| `new_trial_count_30d` | `first_posted_date` within 30 days |
| `recruiting_trial_count_30d` | status = RECRUITING **and** `last_update_post_date` within 30 days |
| `recently_updated_completed_count_30d` | status = COMPLETED **and** last update within 30 days |
| `recently_updated_terminated_count_30d` | status = TERMINATED **and** last update within 30 days |

These do **not** prove a status *changed* in the window unless a prior snapshot comparison exists (not available in a single build). The iOS Organisation detail footer states this.

## Name / alias policy

- Automatic merges: `Normalize.organizationSoftKey` only (case / punctuation / `&`↔`and`).
- Explicit merges: `organization-overrides.json` via `OrganizationOverrides` (deterministic, reviewable).
- No fuzzy-only merges of distinct legal entities.

## iOS app

- `TrialStore.supportedSchemaVersion = 10`
- Capability: `hasOrganisations` / `supportsOrganisations` (table presence)
- Discover landing shows Explore / Popular / Recently Viewed only when supported
- Filters: `TrialFilter.organisationId` + optional `organisationRole`
- On v9 DBs, Discover landing still offers Search Trials; org exploration is hidden

## Site count

`organisation.site_count` = `SUM(trial.location_count)` over related trials. This is a facility-row total, not a deduplicated site graph (sites become their own entity later).
