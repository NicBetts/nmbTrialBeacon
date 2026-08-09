# TrialBeacon — App Spec (recreate from this)

**Product:** TrialBeacon  
**Platform:** iOS 26+ (SwiftUI)  
**Author:** Nic Betts  
**Companion:** macOS database generator (`TrialBeacon DB app/nmbTrialBeaconDB`)  
**This document:** product idea, features, UX, design rules, architecture, and recreation notes for the iOS client. Schema detail lives in `TRIALBEACON_DATABASE.md` and `IOS_CHANGES_schema_v*.md`.

---

## 1. Idea

TrialBeacon is a **privacy-first, fully offline** clinical-trial discovery app. It ships a large ClinicalTrials.gov-derived SQLite database in the App Store binary so users can browse, search, filter, watchlist, and get suggestions **without an account, network dependency, or PHI leaving the device**.

**Tagline (in app):** “Shining a light on your path to clinical research.”

**Who it’s for:** Patients, caregivers, and researchers who want to explore hundreds of thousands of registry studies on a phone — with honest presentation of what the registry actually knows (and doesn’t).

**What it is not:** A live ClinicalTrials.gov client, a medical advice tool, a recruiting CRM, or a cloud-synced health record. Dataset refreshes ship with app updates; the generator builds the file, the phone only reads it.

---

## 2. Product principles

1. **Offline-first.** The registry is bundled. Open SQLite in place from the app bundle; never import trials into SwiftData.
2. **Honest copy.** ClinicalTrials.gov publishes *record update* times, not *status-change* days. Never say “terminated yesterday.” Prefer “Updated Jul 30, 2026” / “record updated recently.”
3. **Curated over random.** Home never dumps “newest random.” Spotlight cards and Featured Studies are deterministic or profile-matched.
4. **Glass on chrome only.** Liquid Glass (iOS 26) on floating controls; content stays on standard grouped surfaces — never glass stacked on glass.
5. **Schema gate.** Open **only** `user_version` **13–14**; refuse older and newer. Within that range, feature-detect tables/columns.
6. **Privacy.** Trials DB is read-only and local. Watchlist, notes, and profile live in on-device SwiftData with CloudKit disabled. Matching and smart search stay on-device.

---

## 3. Tech stack

| Layer | Choice |
|---|---|
| UI | SwiftUI, Observation (`@Observable`) |
| Deployment | iOS **26.0** |
| Trials data | Bundled `trialbeacon.sqlite` via **libsqlite3** (FTS5), `READONLY` + `immutable=1` |
| User data | SwiftData: watchlist, profile, conditions, sync metadata — `cloudKitDatabase: .none` |
| Search AI | Apple **Foundation Models** (`TrialAIService`) for “Describe a search” |
| Home matching | Heuristic SQL + scoring (`AIMatchingService`) — not LLM matching |
| Charts | Swift Charts (Analytics) |
| Maps | MapKit (coords from DB; no live GPS required for core use) |
| Design | Liquid Glass: `.buttonStyle(.glass)`, `GlassEffectContainer`, `.glassEffect`, soft scroll edges, tab-bar minimize |

**Entry:** `nmbTrialBeaconApp.swift` → `RootView` (open DB → onboarding or main tabs).

---

## 4. Information architecture

### Tabs (`MainTabView`)

| Tab | Role |
|---|---|
| **Home** | Dashboard counts, Pulse spotlights, Featured Studies, Research Momentum |
| **Discover** | Browse + FTS search + filters + sort |
| **Watchlist** | Saved trials + notes |
| **Analytics** | Precomputed aggregates only |
| **Settings** | Profile, privacy, appearance, about, data status |

### Sheets / pushed surfaces

- **Clinical Research Pulse** — Home toolbar ECG icon; large sheet
- **Trial detail** — from any NCT navigation (`String` destination + zoom transition where used)
- **Smart Search** — Discover “Describe a search”
- **Filter sheet** — Discover filters
- **Onboarding** — welcome → conditions (skippable), waits for DB ready
- **Data Status** — Home trailing seal / trial count

### Cross-tab routing

`AppRouter` singleton (e.g. open profile setup in Settings). Do not rely on `NavigationLink` across tabs.

---

## 5. Features by surface

### 5.1 Home

**Order (top → bottom):**

1. Data freshness banner if snapshot age ≥ 7 days (stronger treatment ~30+ days)
2. **Dashboard cards** — four metrics, all “Last 30 days” (footnote outside the cards)
   - New (first posted)
   - Recruiting (status recruiting + record updated in window — *proxy*, not true “began recruiting” date)
   - Completed / Terminated (status + updated in window)
   - Fit four in a row when possible; otherwise horizontal scroll (`ViewThatFits`)
   - Tap → filtered `TrialListView`
3. **On This Day** — one spotlight trial from `pulse_on_this_day`
4. **Interesting Trial** — one daily pick from `pulse_interesting_trial`
5. **Featured Studies** — profile recommendations *or* Editor’s Picks carousel
6. **Research Momentum** — top growing conditions (`pulse_condition_growth`)

Toolbar: leading waveform → Pulse sheet; trailing “N trials” → data status.

### 5.2 Clinical Research Pulse (sheet)

- Editorial opener (not a KPI strip), e.g.  
  *“In the last 30 days, **612** new trials were posted, **184** began recruiting…”*  
  — only numbers are bold; then a divider
- Same three shared sections as Home (On This Day, Interesting Trial, Research Momentum)
- **Trial Status Watch** (Pulse-only): segmented Completed | Terminated | Suspended | Withdrawn  
  - Recently **updated** records in that status (≈30 days), top 5 each  
  - Compact rows; color only the status/phase badge  
  - No “terminated yesterday” language

Shared cards live in `PulseHighlightSections.swift` so Home and Pulse stay in sync.

### 5.3 Discover

- **In-page search field** (not the system search-role tab). Query must stay visible while typing.
- Always-visible chrome: Filters · Search in (scope) · Clear
- Sort in the nav bar (Best match when searching; Updated / Added / Title A–Z)
- FTS scopes: All fields, Titles, Conditions, Interventions, Summaries, NCT ID
- Sort on search results is real (bm25/rank vs date/title columns)
- Filter sheet: status, phase, study type, country, conditions, sex, age group, recency, active-only
- Filters persist via `SavedFilters`
- Browse: keyset pagination; Search: offset pagination; page size ~40; cancel previous FTS on new keystrokes
- Flat list rows + hairline dividers (not stacked cards under glass)
- Optional Apple Intelligence “Describe a search” when ready
- Landscape: single-row horizontal carousel of compact tiles (Orgs / Sites / Recruiting / Conditions / Interventions)
- Entity browsers: Org + Site lists; Conditions / Interventions use 2-column symbol cards (domain / type iconography); Countries not shipped
- Organisation detail (v13): publication counts + **10** recent + **See all**; footnote clarifies CTG-linked refs on related trials, not full research output
- Site detail (v13/v14): same publications pattern; prefers precomputed `site.*_publication_count` (v14), live join fallback on v13

### 5.4 Watchlist

- Membership + optional notes in SwiftData (`WatchlistItem` by `nctId`)
- Trial content always loaded from SQLite by NCT id
- Local search over watched set; swipe to delete
- Notes preview on rows when present

### 5.5 Analytics

- **Only** precomputed aggregate tables — no full-table scans for charts
- Glass toggles: Active only, Exclude Healthy (v6 scopes)
- Overview + dimension rankings + year charts + conditions-by-year
- Year charts floor at ~1950 (1900 placeholders are junk); optional “show earlier”

### 5.6 Settings / Profile / Onboarding

- Profile: age range, sex, country, conditions of interest; toggle for personalized recommendations
- Onboarding: welcome + optional conditions; sets `hasCompletedOnboarding`
- Appearance (system/light/dark), date format preference
- Privacy copy: local-only, on-device matching
- **App lock (implemented):** `@AppStorage` / UserDefaults key `biometricAuthEnabled` (default off). Same key is exposed in **iPhone Settings → TrialBeacon** via `Settings.bundle`. Enabling in-app requires a successful `deviceOwnerAuthentication` challenge. When on, `BiometricLockService` locks on background / cold start; `BiometricLockView` (LaunchScreen-matched chrome) gates the UI until Face ID, Touch ID, Optic ID, or device passcode succeeds. This is an access gate, not encryption of the SQLite file.
- About with ClinicalTrials.gov attribution + independence disclaimer; database / schema metadata; same attribution on Data Status and trial detail

### 5.7 Trial detail

- On-demand `TrialDetail` load (decompress `*_z` / `detail_z` as needed)
- Sections: header, study info, eligibility, conditions, interventions (optional Drugs@FDA “FDA” indicator → sheet), outcomes, results (v13 study-record update wording + outcome/publication counts), publications (v13; hide when empty), sponsors, locations/map, summaries, links
- Watchlist toggle; notes (saving notes can auto-watch)
- Share ClinicalTrials.gov URL
- Plain-language AI summary is **off** by policy (`plainLanguageEnabled = false`) due to medical-domain model guardrails
- v13 enrichment loads lazily after detail; no live CTG / OpenAlex / FDA API calls — only user-tapped external links

---

## 6. Featured Studies (curation rules)

Section title is always **Featured Studies**.

| Mode | When | Behavior |
|---|---|---|
| **Recommendations** | Smart recommendations on **and** profile has ≥1 condition of interest | `AIMatchingService`: SQL candidates by conditions (≤~300) → score condition / country / status → top 10 with match % |
| **Editor’s Picks** | Otherwise | Deterministic pool (not random newest) |

### Editor’s Picks algorithm

SQL candidate pool (`TrialStore.editorPickCandidates`):

- `study_type = INTERVENTIONAL`
- Recruiting **or** first-posted within ~90 days
- Phase in II / II–III / III / I–II
- Score boosts: Phase III > II, recruiting, newly posted, larger `enrollment_count`, `lead_sponsor_class = INDUSTRY`

Then `EditorPicks.select`:

- Diversify by `primary_condition`
- Rotate with **UTC day-of-year** seed (stable within a day, changes across days)
- Suppress NCT ids shown in the last **30 days** (UserDefaults history); if pool too thin, widen without exclude

Carousel cards: fixed height (~160), 2-line titles — consistent whether recommendations or editor picks.

---

## 7. Pulse content rules (schema v8)

| Feature | Source | Pick rule |
|---|---|---|
| On This Day | `pulse_on_this_day` | UTC month/day; rotate among ranks by day-of-year; use **`first_posted_year` column** — never derive year from epoch in local TZ |
| Interesting Trial | `pulse_interesting_trial` | **`candidate_id`** from day-of-year mod count — **never ORDER BY score** (score clusters themes) |
| Research Momentum | `pulse_condition_growth` | Default scope **`all_excl_healthy`**, metric **`ratio`**, top ~5 |
| Status Watch | live `trial` + status/update index | Terminal statuses, recent `last_update_post_date` |

Condition labels: v8 merges safe `X (ABBR)` → `X`; subtypes like `Lung Cancer (NSCLC)` stay separate. Counts can shift vs v7.

### Spotlight card layout (On This Day + Interesting Trial)

Shared `PulseSpotlightCard` so the two Home cards match in height:

1. Eyebrow — 1 line (years-ago **or** blurb/status)
2. Title — 2 lines, reserved height
3. Meta — 1 line (NCT · phase/status · condition · …)

Do not add a free-floating blurb row under the title.

---

## 8. Design language

### Liquid Glass

- **Use glass** for floating chrome: filter chips, toggles, search field capsule, toolbar-adjacent controls
- **Do not** put result rows or long content inside glass cards under more glass
- Backgrounds: `systemGroupedBackground` page, `secondarySystemGroupedBackground` content wells
- Soft scroll-edge fades under nav / tab bar

### Layout patterns

- Section titles: `.title2.bold()`, usually **no decorative section icons** on Home/Pulse editorial sections
- Discover: flat list + hairline dividers
- Home/Pulse/Analytics overview: rounded grouped surfaces
- Avoid dashboard overload: prefer editorial sentences with bold numbers over KPI grids when telling a story
- Prefer air between sections (~22–36pt) once icons/captions are removed

### Typography & motion

- System Dynamic Type; monospaced digits for counts; `.contentTransition(.numericText())` where counts update
- Zoom navigation into detail where `matchedTransitionSource` is wired
- Tab bar: `.tabBarMinimizeBehavior(.onScrollDown)`

### Color

- Status accents sparingly (recruiting green, terminated red, etc.)
- In Status Watch, **color only the badge**, keep body monochrome

---

## 9. Data architecture (client)

### Split brain

| Store | Contents |
|---|---|
| Bundled SQLite | All trials, FTS, lookups, aggregates, pulse tables |
| SwiftData | Watchlist, notes, user profile, conditions, sync bookkeeping |

### Client services

- **`TrialStore`** — actor over SQLite; paging, FTS, detail inflate, aggregates, pulse, editor picks
- **`TrialDataService`** — `@MainActor` facade; primary + auxiliary connections for search and count so heavy work doesn’t block list scroll
- **`AIMatchingService`** — Home recommendations
- **`TrialAIService`** — Foundation Models smart search
- **`SyncService`** — timestamps / “check for updates” bookkeeping (not a live downloader)
- **`LegacyStoreCleanup`** — one-time removal of old huge SwiftData trial imports

### Schema stance

- `PRAGMA application_id` = `TBEA` (`0x54424541`)
- Schema gate: `minimumSchemaVersion = 13`, `supportedSchemaVersion = 14` (only v13–v14 open).
- v14: site pub counters + Discover Conditions / Interventions browse tables (wired in UI).
- Place DB at: `nmbTrialBeacon/nmbTrialBeacon/trialbeacon.sqlite`
- Long text: DEFLATE `*_z` (+ optional dictionary from `db_dictionary`)
- Dates: epoch + `date_precision`, format in **UTC**
- Enum labels: from tiny lookup tables in memory (v4 dropped per-row `*_display`)

### Search

- FTS5 contentless index: titles, conditions, interventions; v7+ `brief_summary`
- Eligibility / detailed description are **not** FTS-indexed
- Discover owns an explicit search field so the query never disappears into system chrome

---

## 10. Key UX constraints (do not regress)

1. Discover search field always visible with the current query.
2. Sort works while searching (including Best match).
3. Pulse / dashboard status wording stays honest about update vs change day.
4. Interesting Trial variety comes from `candidate_id` round-robin, not score order.
5. On This Day years come from `first_posted_year`.
6. Research Momentum excludes healthy-volunteer dominated scopes for user-facing lists.
7. Featured Studies is curated; never a raw newest dump.
8. Glass only on chrome.
9. Refuse schema versions outside v13–v14 loudly.
10. App lock cover must not mount main tabs underneath; preference key stays `biometricAuthEnabled` (in-app + Settings.bundle).

---

## 11. File map (iOS)

| Area | Files |
|---|---|
| App shell | `nmbTrialBeaconApp.swift` (RootView, LaunchScreen, `BiometricLockView`), `ContentView.swift` (`MainTabView`, `HomeView`, dashboard, Featured Studies) |
| Discover | `DiscoverView.swift`, `OrganisationBrowserView.swift`, `SiteBrowserView.swift`, `ConditionBrowserView.swift`, `InterventionBrowserView.swift` (Countries not shipped) |
| Pulse | `ClinicalResearchPulseView.swift`, `PulseHighlightSections.swift` |
| Detail | `TrialDetailView.swift`, `OrganisationDetailView.swift` (incl. publications list), `SiteDetailView.swift`, `PublicationComponents.swift`, `FDAComponents.swift` |
| Watchlist | `WatchlistView.swift` |
| Analytics | `AnalyticsView.swift` |
| Settings / profile | `SettingsView.swift`, `ProfileComponents.swift`, `OnboardingView.swift`, `Settings.bundle` (system Settings toggle) |
| Models | `Models/TrialModels.swift`, `Models/OrganisationModels.swift`, `Models/SiteModels.swift`, `Item.swift` |
| Data | `Services/TrialStore.swift`, `TrialDataService.swift` |
| Lock | `Services/BiometricLockService.swift` |
| Curation / AI | `EditorPicks.swift`, `AIMatchingService.swift`, `TrialAIService.swift`, `SmartSearchView.swift` |
| Shared UI | `SharedComponents.swift`, `SavedFilters.swift` |
| DB docs | `README_DATABASE.md`, `TRIALBEACON_DATABASE.md`, `IOS_CHANGES_schema_v10…v14.md` |

---

## 12. Companion generator

| Item | Notes |
|---|---|
| App | `TrialBeacon DB app/nmbTrialBeaconDB` |
| Job | ClinicalTrials.gov API → validated `trialbeacon.sqlite` |
| Contract | `TRIALBEACON_DATABASE.md`; per-version asks in `IOS_CHANGES_schema_v*.md` |
| Size (v12 shipping order of magnitude) | ~3 GB class depending on long-text scope; slim `trial_site` vs fat v11 |
| iOS placement | Drop export on `nmbTrialBeacon/nmbTrialBeacon/trialbeacon.sqlite` |

The iOS app does not rebuild the DB. Recreating the product means recreating **both** the generator contract and this client’s read path.

### Doc authority

| Doc | Authority |
|---|---|
| **This file** | Product, UX, client architecture |
| **`TRIALBEACON_DATABASE.md`** | Core SQLite contract (see schema evolution note at top) |
| **`IOS_CHANGES_schema_v10.md` … `v14.md`** | Additive schema deltas; client opens **v13–v14 only** |
| **`README_DATABASE.md`** | Where to place the bundled file |
| **`BUILD_STATUS.md`** | Historical — superseded; do not trust for architecture |

---

## 13. Recreation checklist

Use this as a build order if starting over:

1. [ ] Bundled SQLite open path + application_id / user_version gate + capability detection  
2. [ ] `TrialSummary` list + keyset browse + FTS search + filter sheet  
3. [ ] Detail inflate (`*_z`, `detail_z`) + watchlist/notes in SwiftData  
4. [ ] Home dashboard 30-day cards + Discover polish (in-page search, sort-while-searching)  
5. [ ] Analytics on aggregates only + excl-healthy scopes  
6. [ ] Pulse tables + shared Home/Pulse spotlights + Status Watch  
7. [ ] Featured Studies (recommendations + Editor’s Picks)  
8. [ ] Onboarding, Settings, privacy copy, Liquid Glass chrome rules  
9. [ ] Wire generator export; verify against `IOS_CHANGES_schema_v8.md`  

---

## 14. Related docs

| Doc | Use |
|---|---|
| `TRIALBEACON_DATABASE.md` | Full schema / query contract |
| `IOS_CHANGES_schema_v*.md` | Per-version client deltas |
| `README_DATABASE.md` | Where to put the SQLite file |
| `DB_GENERATOR_SPEC.md` | Historical / generator-facing spec |
| `IOS_APP_REWORK_PLAN.md` | Earlier rewrite plan (may be partially superseded — prefer this file + v8 changes for current truth) |

---

*Last aligned with the iOS client at schema v13–v14 only: Trial Detail publications + Drugs@FDA UI, Organisation + Site publications, v14 site pub counters + Discover Conditions/Interventions browsers, Pulse, Featured Studies, Discover (org + site), app lock + Settings.bundle, and honest status-update wording.*
