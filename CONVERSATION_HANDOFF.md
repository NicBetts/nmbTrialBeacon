# TrialBeacon iOS — Conversation Handoff

**Purpose:** Detailed export of the long Cursor chat (`3784ae11-b973-424e-88d8-cfe21e752c8f`) so a new conversation can continue without losing product decisions, technical context, or open work.

**App:** `nmbTrialBeacon` (iOS / SwiftUI)  
**Companion:** Desktop DB generator (`nmbTrialBeaconDB`) that ships read-only `trialbeacon.sqlite`  
**Primary path:**  
`/Users/nicbetts/Desktop/Developer/nmbTrialBeacon and DB app/TrialBecon app/nmbTrialBeacon`  

**Transcript:**  
`/Users/nicbetts/.cursor/projects/Users-nicbetts-Desktop-Developer-nmbTrialBeacon-and-DB-app-TrialBecon-app-nmbTrialBeacon/agent-transcripts/3784ae11-b973-424e-88d8-cfe21e752c8f/3784ae11-b973-424e-88d8-cfe21e752c8f.jsonl`

**Dates covered:** ~29 Jul 2026 → 6 Aug 2026 (very long thread: architecture rewrite → Discover/Home polish → saved searches → FDA/publications)

**Note:** Near the end, a “sister city / appearance mode” question was asked by mistake (belongs to the **5pm cities** app `nmb5pm`). Ignore that for TrialBeacon.

---

## 1. Product & architecture (locked)

### What the app is
- Clinical-trials browser over a **bundled, read-only SQLite** database built on macOS.
- **User data** (watchlist, profile, favourites, recently viewed, saved searches) lives in a small **SwiftData** store.
- No live ClinicalTrials.gov / OpenAlex / FDA API calls in the iOS app for catalog data — enrichment is generator-time.

### Stack
- SwiftUI, iOS 26/27 design language (Liquid Glass on chrome, flat content cards).
- `TrialStore` actor → native `libsqlite3` over `trialbeacon.sqlite`.
- `TrialDataService` as `@Observable` environment façade.
- Tabs: Home · Discover · Watchlist · Analytics · Settings.

### Schema evolution (relevant)
- **v13:** publications + Drugs@FDA (`fda_*`, `trial_drug`, `publication*`).
- **v14:** Discover browse (`lookup_intervention`, `popular_intervention`, `popular_condition`, site pub counters).
- Docs: `IOS_CHANGES_schema_v13.md`, `IOS_CHANGES_schema_v14.md`, `TRIALBEACON_DATABASE.md` (also in generator project).

### Domain imagery
- Stock/AI-generated domain photos in Assets as `domain_*_1600x800`.
- Lookup helper: `DomainHeroImage` (in `FeaturedTrialSection.swift`).
- Settings About: *“AI-generated originals. Commercial use permitted.”*

---

## 2. Home — current product shape

Order / behaviour negotiated over many iterations:

1. **Featured** (top) — one recruiting pick; domain photo **split card** (image band + text). Stable for the day via `featuredTrialLog` / `FeaturedTrialEngine`.
2. **Recruiting Near You** — split card with map band (~100pt) + title/status/site; section title outside card.
3. **On This Day** / **Interesting Trial** — same split photo-band pattern (`PulseSpotlightPhotoBandCard`).
4. **Research Momentum** — **2×3 max grid** of split cards (image on top, bold multiplier + condition below).
   - Only growth ratio **> 2.0**
   - Always **even** count (2/4/6), never more than 6
   - Light hairline border so tiles don’t merge
   - Hidden if nothing qualifies

### Home rules that must not regress
- **NCT dedupe** across Featured / Nearby / OTD / Interesting (coordinated load in `ContentView.loadHomeArticles()`).
- Loads should run **in parallel**, not gated on Pulse finishing first.
- Featured fast path: if today’s NCT still in log and still recruiting, skip heavy pool rebuild.
- Toolbar: Pulse + data seal **trailing**; trial count as `navigationSubtitle` under “TrialBeacon”.
- Context menus on Home trial cards: **Add/Remove Watchlist** (`trialWatchlistContextMenu`).

### Research Momentum history
- Was ranked list with SF Symbols; redesigned to image grid with proud multipliers.
- Overlay-on-photo version looked “merged”; switched to **split cards + border**.

---

## 3. Discover — current product shape

Rough order:

1. Landscape boxes (Orgs / Sites / Recruiting)
2. Recently viewed (cap **5**, Clear in caption + Settings → Data)
3. **Matching trials** (promoted; no mockup eyebrow)
4. **Saved searches** (above Favourites)
5. Favourites (orgs/sites)
6. Popular organisations
7. Popular sites
8. Popular interventions (+ See all → Intervention browser)

### Matching trials (was mockup → kept)
**File:** still named `DiscoverMatchingTrialsMockup` in `DesignMockups.swift` (promoted in product sense; rename optional).

**Behaviour:**
- One horizontal carousel **per profile condition**.
- Profile country / age / sex + active-only; prefer Recruiting; NCT dedupe across conditions; up to ~5 trial cards.
- Show **3** condition carousels, then Show more → up to **5**.
- **Lead card = square domain image** (same height as text cards, width = height), hairline border, condition label on image.
- Tap lead image → full search for that condition (`DiscoverRoute.trialSearchFiltered` / launch).
- Following cards = **text only** (status badge + 3-line title). **No phase** on cards.
- No per-row condition title / “See all” (redundant with image).
- Context menu on trial cards: **Watchlist only** (not Favourites).

**Design notes:**
- User rejected full-bleed overlay cards; wanted half-and-half, then moved image to section/lead.
- Equal-width lead vs square: user compared screenshots; **kept square + hairline**.
- Optical “taller image” discussed; hairline helps; left alone otherwise.

### Favourites / Popular / Recently viewed context menus
| Surface | Menu |
|---|---|
| Favourites | Remove from Favourites (destructive) |
| Popular orgs/sites | Add/Remove Favourites |
| Recently viewed chips | Add/Remove Favourites · Remove from Recently Viewed |
| Matching trial cards | Add/Remove Watchlist |
| Home Featured / OTD / Interesting / Nearby | Add/Remove Watchlist |

Helpers: `FavouritesSupport.swift` — `EntityFavourites`, `TrialWatchlist`, `RecentlyViewed`, `trialWatchlistContextMenu`.

### Conditions vs Favourites
- Conditions stay **out of** Favourites list.
- Matching trials carousels replace the old “Your conditions” tile grid.

---

## 4. Saved searches (implemented)

### Spec (user-approved)
- Persist **filter + query + sort + scope** + user **name**.
- Max **10**.
- Discover section **above Favourites**.
- User names the search; seed from chips; **AI short title** when Apple Intelligence ready (fallback = chip join).
- **Last filter restore** on opening Search normally still works (`SavedFilters` UserDefaults).
- **Parked (do not build yet):** alerts when new trials match a saved search; live “count then vs now” badges (discussed; user said think/don’t do).

### Implementation
- SwiftData `SavedSearch` in `Item.swift` (registered in app schema).
- `SavedSearches.swift` — CRUD, limit, semantic match on **filter + query** (not raw JSON bytes — Set encoding order caused false duplicates).
- `SaveSearchSheet.swift` — name sheet; Update vs Save when already matched.
- `TrialSearchView` — toolbar Save; **bookmark / bookmark.fill** + accent when saved (not download icon — Watchlist also uses bookmark family; label distinguishes).
- `DiscoverRoute.trialSearchLaunch(SavedSearches.Launch)` opens full search without merging last-session filters.
- Filtered / saved launches use `restoreLastFilter: false`.

### Icon decision
- Tried `square.and.arrow.down` → felt like download.
- Settled on **bookmark / bookmark.fill** with “Save Search” / “Saved” labels + tint when saved.

---

## 5. FDA / interventions (recent)

### Two different “FDA” concepts
1. **CTG** `trial.fda_regulated_drug` — oversight boolean (filter / study info). **Not** the Drugs@FDA badge.
2. **Drugs@FDA catalog** — `fda_drug` / `fda_brand` / … + sparse `trial_drug` links.

### Why Trial Detail rarely shows FDA badges
- Detail badges require a **`trial_drug` row** for that trial, matched to the **exact** intervention string (trim + lower).
- Bundled DB had ~**2,887** `fda_drug` ingredients but only **~14** `trial_drug` rows → almost no detail badges.
- Example: browse shows **Cyclophosphamide**; trial lists **Cyclophosphamide 500 MG** with **0** `trial_drug` links → **generator gap**, not an iOS bug (conservative exact match; dose suffixes don’t match bare ingredient).

### What iOS did for Intervention browser
- Load in-memory set of FDA catalog norms (ingredient + brand) at store open.
- `InterventionLookupValue.inFdaCatalog`.
- Blue **FDA** chip on browser cards + Discover popular interventions.
- **Drugs@FDA** filter chip on Intervention browser (widens fetch then filters).

### Console warning
- Logs when `trial_drug` row count is tiny so detail badges will stay rare until generator refill.

---

## 6. Publications — field usage (answered in chat)

### Used from `publication`
`publication_id`, `pmid`, `doi`, `openalex_id`, `title`, `journal_name`, `publication_date`, `publication_year`, `is_open_access`, `open_access_url`, `landing_page_url`, `enrichment_status` (only for `citation_only` detection).

### Loaded but not shown
`open_access_status`.

### Not read
`citation_fingerprint`, `source_type`, `cited_by_count`, `enrichment_source` (column), `retrieved_at`.

### `trial_publication`
Used: `reference_type`, `source_citation`, `is_retracted`, `retraction_count`.

**Where citation is used:** `source_citation` is **fallback display title** in `TrialPublication.displayTitle` when there is no enriched `title` — not a separate UI field. If a row looks like a long bibliographic string, that’s `source_citation`.

### `publication_retraction`
Query exists (`publicationRetractions`) but **UI never calls it** — only flag-based “Retracted publication” alert.

### `enrichment_source` table
Presence check for Data Status only.

### Counters
- `trial_results.linked_publication_count` / `result_reference_count` on results summary.
- Org/site `linked_publication_count` / `open_access_publication_count` on profile footprint.

---

## 7. Settings / privacy / catalog (earlier in thread)

- Consolidated **Catalog & methodology** (`SettingsDataView`) — short non-secret methodology; removed “secret sauce” SQLite/index detail from user-facing settings.
- Consolidated **Privacy** (`SettingsPrivacyView`); biometric stays on Settings root.
- Conditions / Favourites collapse after **> 4** → navigate to full lists.
- Clear recently viewed from Discover + Settings → Data.

---

## 8. AI features

- **Smart Search:** on-device Foundation Models → `TrialFilter` + query (kept).
- **In Plain Language** trial rewrite: largely **disabled** (`TrialAIService.plainLanguageEnabled = false`) — Apple on-device safety refused clinical text.
- **Saved search titles:** short Generable suggestion when AI ready; deterministic chip fallback otherwise.

---

## 9. Key files (current)

| Area | Files |
|---|---|
| Home | `ContentView.swift`, `FeaturedTrialSection.swift`, `PulseHighlightSections.swift`, `NearbyStudiesView.swift` |
| Discover | `DiscoverView.swift`, `DesignMockups.swift` (Matching trials), `InterventionBrowserView.swift` |
| Search | `TrialSearchView.swift`, `SavedFilters.swift`, `SaveSearchSheet.swift`, `SavedSearches.swift`, `SmartSearchView.swift` |
| Favourites / watchlist | `FavouritesSupport.swift`, `Item.swift`, `WatchlistView.swift` |
| FDA | `FDAComponents.swift`, `FDAModels.swift`, `TrialStore` FDA + catalog norms |
| Publications | `PublicationModels.swift`, `PublicationComponents.swift` |
| Data | `TrialStore.swift`, `TrialDataService.swift`, `Models/TrialModels.swift` |
| App shell | `nmbTrialBeaconApp.swift`, `SettingsView.swift` |

---

## 10. Open / parked items (for next chat)

1. **`trial_drug` generator refill** — denser links + matching that tolerates dose/strength suffixes so Trial Detail FDA badges match browse reality.
2. **Saved-search match alerts / live counts** — discussed; explicitly deferred.
3. Rename `DiscoverMatchingTrialsMockup` → production name / move out of `DesignMockups.swift`.
4. Optional: app-side FDA fallback on Trial Detail (catalog name match without `trial_drug`) — **product change** vs schema contract; not done.
5. Optional: surface `publication_retraction` PMIDs, `cited_by_count`, OA status text — unused today.
6. Matching trials performance (parallel per-condition queries) / empty states polish.
7. Home cold-start Featured still can be heavy first-of-day.

---

## 11. Design / product principles from this thread

- Prefer **split cards** (image band + text) over full-bleed overlays for editorial Home cards.
- Matching carousels: **square lead image** as lane key; text cards for trials.
- Don’t put conditions into Favourites.
- Watchlist = trials; Favourites = orgs/sites; Saved searches = filter bookmarks — keep separate.
- System `.contextMenu` + Labels; don’t custom-style menu chrome.
- Don’t over-explain generator methodology in Settings.
- When user says “think / don’t do anything,” discuss only.

---

## 12. How to start the next conversation

Suggested opener for a new agent:

> Continue TrialBeacon iOS from `CONVERSATION_HANDOFF.md` in the project root. Repo path:  
> `/Users/nicbetts/Desktop/Developer/nmbTrialBeacon and DB app/TrialBecon app/nmbTrialBeacon`.  
> Read that handoff first. Current priorities: [state your priority — e.g. generator trial_drug, rename Matching trials, etc.].

---

## 13. Chronological highlight (late thread only)

Rough sequence of the **Discover/Home polish + searches + FDA** stretch:

1. Context menus on Favourites / Popular / Matching / Home.
2. Matching carousel iteration: drop phase → 3-line titles → one image per row → image as first card → square lead → drop row titles/See all → hairline → square kept.
3. Research Momentum → 2×3 image cards → filter >2.0, even count, split + border.
4. Matching trials promoted (lose mockup eyebrow; show 3 then more/less).
5. Saved searches designed then implemented (max 10, AI name seed, above Favourites, bookmark icon, duplicate fix).
6. Deferred: saved-search counts / notifications.
7. FDA catalog badges + filter on Intervention browser; diagnosed Trial Detail gap as generator `trial_drug` sparsity.
8. Publications field audit + clarification that `source_citation` is fallback title only.
9. Mistaken sister-city appearance question (wrong chat).

---

*Generated as a handoff from the Cursor agent conversation. Prefer this file + the live codebase over re-deriving decisions from the raw JSONL unless you need exact quotes.*
