# TrialBeacon — Application Status

**Product:** TrialBeacon (iOS)  
**Repo:** [NicBetts/nmbTrialBeacon](https://github.com/NicBetts/nmbTrialBeacon)  
**Platform:** iOS 26+ · SwiftUI  
**Companion:** macOS DB generator (`nmbTrialBeaconDB`) ships read-only `trialbeacon.sqlite`  
**Shipping schema:** **v14** (client opens **v13–v14** only)  
**Status date:** 9 Aug 2026  

This document describes what the app is, what is shipped, what was deliberately not built, and why. For recreation detail see `TRIALBEACON_APP.md`. For schema see `DATABASE_SCHEMA.md` and `TRIALBEACON_DATABASE.md`.

---

## 1. What TrialBeacon is

A **privacy-first, fully offline** clinical-trials discovery app. It browses a large ClinicalTrials.gov–derived SQLite corpus bundled in the App Store binary. Users can search, filter, watchlist, favourite organisations/sites, save searches, and get profile-aware suggestions **without an account, network dependency, or PHI leaving the device**.

**Tagline:** “Shining a light on your path to clinical research.”

**Audience:** patients, caregivers, and researchers exploring registry studies on a phone — with honest presentation of what the registry knows (and does not).

**Not:** a live ClinicalTrials.gov client, medical advice, recruiting CRM, or cloud health record. Dataset refreshes ship with app updates; the generator builds the file; the phone only reads it.

---

## 2. Architecture (locked)

| Layer | Choice |
|---|---|
| UI | SwiftUI, `@Observable`, Liquid Glass on chrome only |
| Trials corpus | Bundled `trialbeacon.sqlite` via **libsqlite3** (`READONLY` + `immutable=1`) |
| User data | SwiftData (`cloudKitDatabase: .none`): watchlist, profile, favourites, recently viewed, saved searches |
| Entry | `nmbTrialBeaconApp` → `RootView` (DB open → biometric gate → onboarding or tabs) |

**Tabs:** Home · Discover · Watchlist · Analytics · Settings  

**Split brain:** never import trials into SwiftData; reference by `nct_id`. Enrichment (OpenAlex, Drugs@FDA) is generator-time only — **no** live CTG / OpenAlex / FDA API calls on device.

---

## 3. What we did (shipped)

### 3.1 Core product

- Read-only SQLite architecture with schema gate **13–14** and capability feature-detection
- Full-text search (FTS5) + multi-dimension filters + sort; last-filter restore (`SavedFilters`)
- Trial detail (overview, eligibility, interventions, outcomes, results, pubs, sponsors, map/locations)
- Watchlist + notes; Favourites for orgs/sites (conditions stay out of Favourites)
- Onboarding (welcome → optional conditions); profile-driven recommendations toggle
- Nearby recruiting (MapKit + location / preferred city)
- Analytics from precomputed aggregates only
- Biometric lock (Face ID / Touch ID / passcode gate — not file encryption)
- Data Status / catalog & methodology / privacy surfaces (non-secret wording)

### 3.2 Home & Pulse

- Featured Studies (profile scoring or Editor’s Picks; same-day stable pick via log; NCT dedupe)
- Last-30-days dashboard cards (New / Recruiting / Completed / Terminated — honest “record updated” wording)
- Recruiting Near You spotlight
- On This Day / Interesting Trial (split photo-band cards)
- Research Momentum: growth ratio **> 2.0**, even count ≤ 6, split cards + hairline
- Clinical Research Pulse sheet (shared cards + Status Watch)
- Parallel Home load (not gated on Pulse finishing first)

### 3.3 Discover

- Landscape boxes: Orgs · Sites · Nearby · Conditions · Interventions (v14-gated)
- Recently viewed (display cap 5; Clear)
- Matching trials carousels (per profile condition; square domain lead image; text cards; 3 then Show more → 5)
- Saved searches (max 10; name + filter/query/sort/scope; bookmark toolbar icon; AI short title when ready)
- Favourites + Popular orgs/sites/conditions/interventions
- Intervention / Condition browsers

### 3.4 Drugs@FDA (v13 + recent browse fix)

- Trial Detail: FDA indicator when a **`trial_drug`** row matches the intervention string (exact trim + lower)
- Intervention browser **Drugs@FDA** filter: lists **distinct `fda_drug` ingredients that have ≥1 `trial_drug` link**, with distinct-trial counts and search — **not** “popular CTG names that happen to equal a catalog string”
- Popular browse still shows blue FDA chips via in-memory catalog norms (ingredient + brand names) for presence indication

### 3.5 Publications (v13)

- Trial / org / site publication lists from generator-filled tables
- OA links, retraction **flag** alert on rows
- Org/site publication counters (site counters prefer v14 columns)

### 3.6 On-device AI

- **Smart Search** (Foundation Models → filter + query) — on when model ready
- **Saved search titles** — short Generable suggestion with chip-join fallback
- **Plain-language trial rewrite** — implemented but **disabled** (`plainLanguageEnabled = false`)

### 3.7 Design decisions locked in polish pass

- Prefer **split cards** (image band + text) over full-bleed overlays on Home
- Matching: square lead image as lane key; no phase on trial cards; conditions not in Favourites
- Watchlist = trials; Favourites = orgs/sites; Saved searches = filter bookmarks
- System `.contextMenu` + Labels; glass on chrome only
- Don’t over-explain generator internals in Settings

---

## 4. What we deliberately did **not** do (and why)

| Item | Status | Why |
|---|---|---|
| Live CTG / OpenAlex / openFDA calls in the iOS app | Not done | Privacy, offline-first, App Store size/control; enrichment stays in the macOS generator |
| Saved-search **alerts** / live “count then vs now” badges | Parked | Discussed; user explicitly deferred |
| Rename `DiscoverMatchingTrialsMockup` → production name / leave `DesignMockups.swift` | Parked | Works in product; rename is cosmetic cleanup |
| App-side FDA fallback on Trial Detail (catalog name match **without** `trial_drug`) | Not done | Would change the schema contract (match = linked intervention row). Prefer denser generator `trial_drug` links |
| Fuzzy / dose-tolerant intervention↔FDA matching on device | Not done | Generator owns conservative matching; dose suffixes are a generator gap |
| Surface `publication_retraction` PMIDs, `cited_by_count`, OA status text in UI | Not done | Data available; UI uses flag-based retraction alert and core fields only — optional polish |
| Plain-language AI summary on Trial Detail | Disabled | On-device safety refused clinical rewrite text |
| CloudKit / account sync for user data | Not done | Privacy principle; local SwiftData only |
| Importing corpus into SwiftData | Forbidden | Doubled footprint and launch cost in the old architecture |
| Shipping `trialbeacon.sqlite` in GitHub | Excluded | Multi‑GB binary; exceeds GitHub limits; built/bundled locally from the generator |

---

## 5. Known gaps / next priorities

1. **Generator `trial_drug` quality** — denser links + matching that tolerates dose/strength suffixes so Detail FDA badges match browse/link reality when intervention strings differ (e.g. `Cyclophosphamide 500 MG` vs `Cyclophosphamide`).
2. Saved-search notifications / live match counts (if product wants them later).
3. Rename Matching trials mockup symbol / file hygiene.
4. Matching trials performance (parallel per-condition queries) and empty-state polish.
5. Home cold-start Featured pool rebuild cost (first-of-day).
6. Optional unused publication fields in UI.

---

## 6. Mental model: three “FDA” ideas

Do not conflate these:

| Concept | Meaning | Where you see it |
|---|---|---|
| CTG `fda_regulated_drug` | Registry oversight boolean | Search filter / study info |
| Drugs@FDA **catalog** (`fda_drug` / brands / apps) | Ingredient product/application metadata | Catalog norms for browse chips; ~thousands of ingredients |
| **`trial_drug` links** | Generator-matched intervention ↔ ingredient for a trial | Detail badges; Interventions **Drugs@FDA** filter (distinct linked ingredients + trial counts) |

A catalog row without a `trial_drug` link is **not** “tied to a trial” in the app’s link sense. “Trials with FDA link” (Data Status) counts distinct trials that have ≥1 `trial_drug` row — not the ingredient list length.

---

## 7. Key source map

| Area | Files |
|---|---|
| App shell | `nmbTrialBeaconApp.swift`, `ContentView.swift` |
| Home | `FeaturedTrialSection.swift`, `PulseHighlightSections.swift`, `NearbyStudiesView.swift` |
| Discover | `DiscoverView.swift`, `DesignMockups.swift` (Matching), `InterventionBrowserView.swift` |
| Search / saved | `TrialSearchView.swift`, `SavedFilters.swift`, `SavedSearches.swift`, `SaveSearchSheet.swift` |
| Data | `TrialStore.swift`, `TrialDataService.swift`, `Models/*` |
| FDA / pubs | `FDAComponents.swift`, `FDAModels.swift`, `PublicationComponents.swift` |
| User models | `Item.swift`, `FavouritesSupport.swift` |

---

## 8. Related documents

| Doc | Role |
|---|---|
| `TRIALBEACON_APP.md` | Full product / UX / recreation spec |
| `DATABASE_SCHEMA.md` | **Current** shipping schema overview (v14) |
| `TRIALBEACON_DATABASE.md` | Deep integration guide (core + evolution pointers) |
| `IOS_CHANGES_schema_v10.md` … `v14.md` | Additive deltas per version |
| `CONVERSATION_HANDOFF.md` | Long-thread product decisions (Discover/Home polish, FDA, saved searches) |
| `DB_GENERATOR_SPEC.md` | Generator-side specification |

---

*Keep this file updated when parking or shipping major product decisions so the next conversation does not re-litigate locked choices.*
