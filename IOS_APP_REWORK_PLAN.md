# TrialBeacon iOS App — Complete Rework Plan

**Companion to:** `DB_GENERATOR_SPEC.md` (the read-only `trialbeacon.sqlite` contract)
**Goal:** eliminate the load-time / navigation / memory problems and rebuild the UI on iOS 26/27 (Liquid Glass), without changing what the app *does* for users.

---

## 1. Guiding principles

1. **The bundled trials DB is read-only reference data.** Open it in place, query it lazily, never import it into SwiftData, never copy it to Documents, never mutate it.
2. **Never hold the dataset in memory.** No screen ever loads more than one page (~50 rows). Memory stays flat whether the DB has 500 or 5,000,000 trials.
3. **Push work into SQL.** Filtering, sorting, search (FTS5), and analytics are done by indexed queries / pre-aggregated tables, not Swift loops over arrays.
4. **Native and fast.** Use Apple's built-in `libsqlite3` (which includes FTS5) behind one small Swift wrapper. No heavyweight dependencies. (GRDB remains an optional ergonomic upgrade later — it's a source-only SPM package over the same SQLite — but is not required.)
5. **Separate the two data worlds.** Big read-only trials DB (SQLite) vs. small mutable user data (SwiftData). They never mix.
6. **UI assumes lazy data.** Liquid Glass lists/search are built for paged, on-demand content — which is exactly what the new data layer provides.

---

## 2. Target architecture

```
┌──────────────────────────── iOS App ────────────────────────────┐
│                                                                  │
│  SwiftUI (iOS 26/27 Liquid Glass)                                │
│     Discover · Detail · Home · Analytics · Watchlist · Profile   │
│        │ reads view models / paged results                       │
│        ▼                                                          │
│  Repositories (async, actor-isolated)                            │
│     TrialRepository   → lists, search, detail, lookups, aggs     │
│     UserDataRepository→ watchlist, profile, notes, sync state    │
│        │                         │                               │
│        ▼                         ▼                               │
│  TrialStore (actor)         SwiftData ModelContainer             │
│   native libsqlite3          (small, user-owned)                 │
│   read-only, immutable                                           │
│        │                                                         │
│        ▼                                                         │
│  trialbeacon.sqlite  (bundled, read-only, indexes+FTS5+aggs)     │
└──────────────────────────────────────────────────────────────────┘
```

- **`TrialStore`** — an `actor` owning one or more read-only SQLite connections to `trialbeacon.sqlite`. All access to the big DB goes through it. Because the file is immutable, we can safely use multiple connections for concurrent reads if needed.
- **`TrialRepository`** — a thin, testable API that turns app intents (filters, search text, page) into SQL and returns plain value types.
- **`UserDataRepository`** — wraps the small SwiftData store for watchlist/profile/notes/sync metadata.
- **View models** — per-screen `@Observable` objects that call repositories and expose paged results + loading state.

---

## 3. Data layer design

### 3.1 Opening the database (read-only, immutable, from the bundle)

- Locate `trialbeacon.sqlite` in `Bundle.main`.
- Open with `sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)` using a URI of the form `file:<path>?immutable=1`.
  - `immutable=1` tells SQLite the file cannot change → skips locking and WAL/journal checks → faster, and works from the read-only bundle with no sidecar files.
- Set per-connection pragmas: `PRAGMA query_only = 1;`, `PRAGMA cache_size = -20000;` (~20 MB), `PRAGMA mmap_size = 268435456;` (256 MB memory-mapped I/O for fast reads).
- If the bundled file is missing/corrupt, surface a clear error state (no "sample data" fallback — see §9).

### 3.2 Concurrency model

- `TrialStore` is an `actor`; queries run off the main actor. View models `await` results and publish them on the main actor.
- Long-running queries (search, aggregates) are cancellable; tie them to SwiftUI `.task`/`Task` lifecycles so scrolling/typing cancels stale work.

### 3.3 Read models (plain `Sendable` structs — NOT `@Model`)

```
struct TrialSummary: Identifiable, Sendable {   // list rows
    let trialId: Int64
    let nctId: String
    let briefTitle: String
    let overallStatus: String          // canonical
    let statusDisplay: String
    let phaseDisplay: String?
    let studyTypeDisplay: String?
    let primaryCondition: String?
    let primaryCountry: String?
    let lastUpdatePostDate: Date
    let conditionCount: Int
    let locationCount: Int
    let isActive: Bool
    var id: Int64 { trialId }
}

struct TrialDetail: Identifiable, Sendable {    // detail screen
    let summary: TrialSummary
    let officialTitle: String?
    let briefSummary: String?
    let detailedDescription: String?
    let startDateDisplay: String?
    let completionDateDisplay: String?
    let genderEligibilityDisplay: String?
    let minAgeDisplay: String?
    let maxAgeDisplay: String?
    let healthyVolunteers: Bool?
    let hasResults: Bool
    let fdaRegulatedDrug: Bool
    let conditions: [String]
    let locations: [TrialLocation]
    let interventions: [TrialIntervention]
    let outcomes: [TrialOutcome]
    let sponsors: [TrialSponsor]
    let eligibility: TrialEligibility?
    var id: Int64 { summary.trialId }
}
// + TrialLocation / TrialIntervention / TrialOutcome / TrialSponsor / TrialEligibility structs
```

These replace the `@Model` `Trial`, `Condition`, `Location`, `Outcome`, `Eligibility`, `Intervention`, `Sponsor` classes in `Item.swift` (which are deleted — see §10).

### 3.4 Filter + sort model

```
struct TrialFilter: Equatable, Sendable {
    var status: String?          // canonical
    var studyType: String?
    var phase: String?
    var country: String?
    var conditions: Set<String> = []
    var gender: String?
    var lastUpdatedWithinDays: Int?   // e.g. 30/90/365
    var minAgeYears: Double?
    var maxAgeYears: Double?
    var activeOnly: Bool = false
}
enum TrialSort { case lastUpdatedDesc, titleAsc }   // default: lastUpdatedDesc
```

### 3.5 Repository API (the surface the UI codes against)

```
protocol TrialRepository {
    // Lists (keyset pagination)
    func count(filter: TrialFilter) async -> Int
    func page(filter: TrialFilter, sort: TrialSort, after cursor: TrialCursor?, limit: Int) async -> [TrialSummary]

    // Search (FTS5, ranked)
    func search(_ query: String, filter: TrialFilter, offset: Int, limit: Int) async -> [TrialSummary]

    // Detail
    func detail(nctId: String) async -> TrialDetail?
    func summaries(nctIds: [String]) async -> [TrialSummary]   // for watchlist / recommendations

    // Lookups for filter menus
    func lookup(_ dimension: LookupDimension) async -> [LookupValue]   // value + display + count

    // Analytics / dashboard (pre-aggregated)
    func dashboardStats() async -> DashboardStats
    func dimensionCounts(_ dimension: AggDimension, scope: AggScope, limit: Int) async -> [DimensionCount]
    func yearCounts(scope: AggScope) async -> [YearCount]
    func topConditionByYear() async -> [ConditionByYear]
}
```

### 3.6 Pagination strategy

- **Browse/filtered lists:** **keyset pagination** on `(last_update_post_date DESC, trial_id DESC)`.
  `WHERE (<filters>) AND (last_update_post_date, trial_id) < (?, ?) ORDER BY last_update_post_date DESC, trial_id DESC LIMIT ?`.
  Stable during infinite scroll and index-friendly (`idx_trial_status_update` / `idx_trial_update`).
- **Search results:** FTS `MATCH … ORDER BY rank` with `LIMIT/OFFSET` (offset is fine here since result sets are bounded and users rarely page deep).
  `SELECT rowid FROM trial_fts WHERE trial_fts MATCH ? ORDER BY rank LIMIT ? OFFSET ?` → join `trial` on `trial_id = rowid`, then apply structured filters in the outer query.
- **Page size:** 50 rows. Prefetch the next page when the user reaches ~10 rows from the end.

### 3.7 Query building notes

- Build `WHERE` clauses from `TrialFilter` with **bound parameters only** (never string-interpolate user input).
- For `conditions` multi-select, join to `condition` (`EXISTS (SELECT 1 FROM condition c WHERE c.trial_id = trial.trial_id AND c.name_norm IN (...))`) or match `primary_condition` for the fast path — decide per UX (multi-select → EXISTS).
- Escape FTS query text; support prefix search (`term*`) and quoted phrases; treat a bare `NCTxxxxxxxx` as an exact `nct_id` match.

---

## 4. User data (SwiftData, small)

Keep a **separate, tiny** SwiftData `ModelContainer` with only:
`WatchlistItem`, `UserProfile`, `UserCondition`, `SyncMetadata` (see `Item.swift`). All reference trials by **`nctId`** (already the case for `WatchlistItem`).

- **Watchlist rendering:** fetch `nctId`s from SwiftData → `TrialRepository.summaries(nctIds:)` to get display data from the read-only DB.
- **Profile → recommendations:** profile drives a SQL candidate query (see §6.3).
- Remove `Trial`/`Condition`/`Location`/`Outcome`/`Eligibility`/`Intervention`/`Sponsor` and all `Lookup*` `@Model` types from the SwiftData schema — they're no longer stored in SwiftData.

---

## 5. UI redesign — iOS 26/27 Liquid Glass

### 5.1 App shell
- `TabView` using the modern `Tab` API with a **search tab role** so Discover gets the OS's morphing Liquid Glass search field.
- Liquid Glass tab bar + toolbars via system materials; adopt `.scrollEdgeEffectStyle` so content flows under the glass chrome.
- Consider tab bar minimize-on-scroll behavior for more content room.
- Replace the custom launch/loading screen with a fast, minimal splash — launch is now near-instant, so the elaborate progress UI in `nmbTrialBeaconApp.swift` / `LaunchScreenView` is mostly removed.

### 5.2 Discover
- `.searchable` (scoped to the search tab) with a **debounced** binding (250–300 ms) → `TrialRepository.search`.
- Results in a `List`/`LazyVStack` with **incremental pagination** (`.task` on the trailing sentinel row). Row = restyled `TrialSearchRowView` as a Liquid Glass card.
- **Filters** presented in a sheet; options come from `lookup_*` tables via `TrialRepository.lookup`. Active-filter count + result count shown in a glass header.
- Empty/loading/error states as distinct, calm views.

### 5.3 Trial Detail
- Loads a single `TrialDetail` by `nctId` via `.task` (one indexed query + child fetches). No reliance on preloaded relationships.
- Sections as Liquid Glass cards: Summary, Status/Phase, Conditions, Eligibility (inclusion/exclusion), Interventions, Outcomes, Sponsors, Locations (grouped by country).
- Watchlist toggle writes to SwiftData; optional "Refresh from ClinicalTrials.gov" action (see §6.4).

### 5.4 Home / Dashboard
- Header stats (recruiting / active-not-recruiting / recently-updated / total) read directly from `db_metadata` — instant.
- "Top conditions" / "Top countries" cards from `agg_dimension_count` (respecting the active-only toggle via `scope`).
- "Recommended for you" from the reworked matching (§6.3), rendered as glass cards.

### 5.5 Analytics
- All charts/lists read from `agg_dimension_count`, `agg_year_count`, `agg_condition_by_year`. No `@Query allTrials`, no in-memory tallying.
- Year-range control filters against `agg_year_count` rows.

### 5.6 Watchlist / Profile / Settings
- **Watchlist:** SwiftData `@Query` for `WatchlistItem` (small) + repository lookup for display; keep swipe-to-delete, notes, export.
- **Profile:** age range / gender / country / conditions of interest; options from `lookup_*`.
- **Settings:** appearance, data/version info from `db_metadata`, about/privacy. Keep the pieces that don't depend on the old import pipeline.

### 5.7 iOS 26/27 features to adopt
- Liquid Glass materials (`glassEffect`, glass button styles, glass containers) for chrome and cards.
- Modern search presentation + tab search role.
- Scroll edge effects; edge-to-edge content.
- `NavigationStack` value-based navigation; `NavigationSplitView` for iPad.
- Dynamic Type, accessibility, and dark/light continue to be first-class.

---

## 6. Services rework

### 6.1 `DatabaseService` (3,538 lines) → retire
Replace with `TrialStore` + `TrialRepository` (a few hundred lines total). Delete all import/copy/sample-data/pre-generated-store/OLD_DEPRECATED code paths. Keep a tiny `DataStatus` observable for "DB opened / version / error" if the UI needs it.

### 6.2 `AnalyticsCache` → mostly gone
The aggregate tables replace it. If any caching is still wanted, keep a trivial in-memory memo of the last aggregate query results; drop the 400+ line recalculation engine and the practice of passing `[Trial]` arrays around.

### 6.3 `AIMatchingService` → query-driven candidates
Instead of scoring all ~500k trials in memory:
1. Build a **SQL candidate query** from the user's profile (conditions of interest, age within `min/max_age_years`, gender, country, `is_active`) → returns a bounded candidate set (e.g. ≤ 500 rows) via indexes.
2. Score only those candidates in Swift and return the top N with match reasons.
This turns the recommender from an O(500k) main-thread loop into an indexed query + tiny scoring pass.

### 6.4 `SyncService` → simplified
Because the DB is bundled and regenerated by the desktop app, "full sync" is delivered via app/DB updates, not runtime API imports. Reduce sync to:
- **DB version check** using `db_metadata` (show "data as of <date>").
- **Optional per-trial live refresh** in Detail (fetch the latest from ClinicalTrials.gov API for the open trial only), if you want fresher detail than the snapshot. This does **not** write into the read-only DB — it's transient view state (or cached in the small user store keyed by `nctId`).

### 6.5 `FilterCoordinator`
Keep as the shared filter state holder; map its state onto `TrialFilter`. Persist selected filters via `UserDefaults` as today.

---

## 7. Performance targets (acceptance)

| Metric | Target |
|---|---|
| Cold launch → interactive | < 1.0 s (open file + `COUNT`, no import) |
| First Discover page render | < 200 ms |
| Search latency (typed query → results) | < 100 ms typical (FTS) |
| Scroll | 60/120 fps, no hitches while paging |
| Peak memory (browsing) | < 150 MB regardless of DB size |
| Analytics screen load | < 150 ms (aggregate reads) |

Instrument with signposts around DB open, page fetch, search, and detail fetch; verify with a Release build on a real device against the full ~500k dataset.

---

## 8. Delivery phases

- **Phase 0 — Scaffolding.** Add the `trialbeacon.sqlite` contract, create `TrialStore`/`TrialRepository` skeleton, and a small test DB fixture. Feature-flag the new path so the app still builds.
- **Phase 1 — Data layer.** Implement open/immutable, read models, list/keyset pagination, FTS search, detail, lookups, aggregates. Unit-test every query against the fixture.
- **Phase 2 — Discover.** Rebuild list + `.searchable` + filters on the repository with pagination.
- **Phase 3 — Detail.** On-demand `TrialDetail` fetch; render all sections.
- **Phase 4 — Home + Analytics.** Dashboard from `db_metadata`; analytics from `agg_*`; rework `AIMatchingService`.
- **Phase 5 — Watchlist / Profile / Settings.** Wire small SwiftData store + repository lookups.
- **Phase 6 — Liquid Glass pass.** Apply iOS 26/27 design across shell, lists, detail, search, cards.
- **Phase 7 — Remove legacy.** Delete `DatabaseService` import pipeline, `Trial`/related `@Model` types, `AnalyticsCache` engine, old launch UI. Trim SwiftData schema to user models.
- **Phase 8 — QA + perf.** Validate against §7 on-device; ship.

Phases 1–5 can each ship behind the feature flag; Phase 7 flips the default and removes the old code.

---

## 9. Behavior changes / decisions baked in

- **No "sample data" fallback.** If the bundled DB is missing/corrupt, show an explicit error (it's a build/packaging bug, not a normal state). The old fabricated sample data hid real failures.
- **No runtime import.** The app reads the bundled DB directly; first launch is instant.
- **Trials are immutable on-device.** Any freshness beyond the snapshot comes from optional per-trial API refresh, not by writing to the DB.
- **Distribution = bundled** (per your other apps). Keep an eye on the ~200 MB over-cellular threshold; compressing the bundled DB and decompressing once on first launch is a fallback if size becomes a problem.

---

## 10. File-by-file change map

| File | Action |
|---|---|
| `Services/DatabaseService.swift` | **Delete.** Replace with `Services/TrialStore.swift` + `Services/TrialRepository.swift`. |
| `Services/AnalyticsCache.swift` | **Delete** (or reduce to a trivial memo). Analytics reads `agg_*`. |
| `Services/AIMatchingService.swift` | **Rewrite** to query-driven candidates (§6.3). |
| `Services/SyncService.swift` | **Simplify** to version check + optional per-trial refresh (§6.4). |
| `Item.swift` | **Split:** keep `WatchlistItem`, `UserProfile`, `UserCondition`, `SyncMetadata`; **remove** `Trial`, `Condition`, `Location`, `Outcome`, `Eligibility`, `Intervention`, `Sponsor`, and all `Lookup*` `@Model` types. Add plain read-model structs (or a new `TrialModels.swift`). |
| `nmbTrialBeaconApp.swift` | **Simplify** init: open `TrialStore`, create the small user `ModelContainer`, drop the multi-step import/progress orchestration. |
| `DiscoverView.swift` | **Rewrite** on repository + pagination + `.searchable`. Remove `@Query allTrials`. |
| `TrialDetailView.swift` | **Rewrite** to load `TrialDetail` by `nctId`. |
| `ContentView.swift` (Home) | **Rewrite** dashboard from `db_metadata` + aggregates + reworked recommendations. Remove `@Query allTrials`. |
| `AnalyticsView.swift` | **Rewrite** to read `agg_*`. Remove `@Query allTrials`. |
| `WatchlistView.swift` | **Adjust** to SwiftData watchlist + repository lookup. |
| `ProfileView.swift` | **Adjust** lookups to repository; keep flow. |
| `SettingsView.swift` | **Adjust** data/version info to `db_metadata`; drop reload/import controls tied to old pipeline. |
| `FilterCoordinator.swift` | **Keep**; map to `TrialFilter`. |
| `SharedComponents.swift` | **Restyle** to Liquid Glass; reuse across screens. |
| `DatabaseReloadProgressView.swift` | **Delete** (no runtime reload/import). |
| `Extensions/DateFormatter+Extensions.swift` | **Keep**; used for display strings. |
| Bundled `TrialBeacon.store*` files | **Remove** from the target; replace with `trialbeacon.sqlite`. |

---

## 11. Testing

- **Query unit tests** against a small fixture `trialbeacon.sqlite`: filters, keyset pagination correctness (no gaps/dupes), FTS ranking, detail joins, aggregate reconciliation vs. direct `GROUP BY`.
- **Contract test:** on launch (debug), assert the DB's `PRAGMA user_version` matches the app's expected schema version and required tables/indexes exist; fail fast if the generator output drifts from `DB_GENERATOR_SPEC.md`.
- **Performance tests:** signpost-based checks against §7 targets on the full dataset.
- **UI smoke tests:** Discover paging, search, detail navigation, watchlist add/remove, profile-driven recommendations.

---

## 12. Risks & mitigations

- **DB/app schema drift** → the launch contract test (§11) + shared `schema_version` in `db_metadata`.
- **Bundle size / cellular limit** → compress bundled DB; decompress once on first launch if needed.
- **SQLite from a read-only bundle** → open with `immutable=1`; ensure the generator ships no WAL/sidecars (enforced in `DB_GENERATOR_SPEC.md`).
- **FTS edge cases** (special characters, empty query) → sanitize/escape; fall back to structured filters when query is empty.
- **Liquid Glass adoption on older OS** → gate glass styling behind availability checks with graceful fallbacks if you still support < iOS 26.

---

## 13. Definition of done

- No screen uses `@Query` over trials; all trial reads go through `TrialRepository`.
- `DatabaseService` import pipeline and `Trial`/related `@Model` types are gone.
- App launches to interactive in < 1 s and browses/searches the full ~500k dataset within the §7 budgets.
- All screens rebuilt on Liquid Glass (iOS 26/27).
- User data (watchlist/profile) persists in its own small SwiftData store, keyed by `nctId`.
