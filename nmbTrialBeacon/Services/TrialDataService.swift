//
//  TrialDataService.swift
//  nmbTrialBeacon
//
//  App-facing, main-actor observable facade over the read-only `TrialStore`.
//  Replaces the old 3,500-line DatabaseService. Holds no trial data in memory:
//  it publishes lightweight status + precomputed dashboard stats + cached
//  lookup lists, and forwards queries to the store actor.
//
//  Uses Observation rather than ObservableObject so a view only re-renders for
//  the specific properties it reads — otherwise loading the lookup menus would
//  invalidate every screen observing this object.
//

import Foundation
import SwiftUI

@MainActor
@Observable
final class TrialDataService {
    static let shared = TrialDataService()

    let store = TrialStore()

    /// Search runs on its own connection so a broad full-text query (which has
    /// to rank every match and can take a second on a generic word) never
    /// blocks list paging or a detail screen behind the store actor. It is also
    /// the connection we interrupt when the user keeps typing.
    private let searchStore = TrialStore()
    private var searchStoreReady = false

    /// Result counts for multi-dimension filters aren't served by a covering
    /// index, so a cold one can take a second or two. It's a decorative number
    /// — it gets its own connection so it can never hold up the list.
    private let countStore = TrialStore()
    private var countStoreReady = false

    enum Status: Equatable {
        case loading
        case ready
        case failed(String)
    }

    private(set) var status: Status = .loading
    private(set) var stats: DashboardStats?

    // Cached lookup lists (small; loaded once on startup).
    private(set) var statuses: [LookupValue] = []
    private(set) var studyTypes: [LookupValue] = []
    private(set) var phases: [LookupValue] = []
    private(set) var countries: [LookupValue] = []
    private(set) var conditions: [LookupValue] = []
    private(set) var collaborators: [LookupValue] = []
    private(set) var genders: [LookupValue] = []
    private(set) var ageRanges: [LookupValue] = []

    /// `conditions` holds only the most common ones (see `conditionMenuLimit`);
    /// these are the true totals, for display.
    private(set) var conditionTotal = 0
    private(set) var countryTotal = 0
    private(set) var collaboratorTotal = 0

    /// Schema v9 capability flags (false on older bundled databases).
    private(set) var supportsTrialResults = false
    private(set) var supportsCollaborators = false
    /// Organisation exploration is available on v9+ (live lead/collaborator queries)
    /// and richer when schema v10 organisation tables are present.
    private(set) var supportsOrganisations = false
    /// Site exploration works on v9 via a recruiting/`detail_z` index; richer with v10 site tables.
    private(set) var supportsSites = false
    /// True when canonical `site` / `trial_site` tables are present.
    private(set) var supportsCanonicalSites = false
    /// Schema v13+: `publication` + `trial_publication` present.
    private(set) var supportsPublications = false
    /// Schema v13+: Drugs@FDA `fda_drug` present (may be empty).
    private(set) var supportsFdaDrugs = false
    /// Schema v13+: `trial_drug` present (needed with `supportsFdaDrugs` for indicators).
    private(set) var supportsTrialDrug = false
    /// Schema v14+: `popular_condition` (Discover Conditions browser).
    private(set) var supportsPopularCondition = false
    /// Schema v14+: `lookup_intervention` (+ typically `popular_intervention`).
    private(set) var supportsLookupIntervention = false
    /// Schema v14+: `popular_intervention`.
    private(set) var supportsPopularIntervention = false
    /// Open-file capability snapshot (schema, site row counts, query path).
    private(set) var capabilityReport: DatabaseCapabilityReport?
    private var organisationNames: [String: String] = [:]

    private let conditionMenuLimit = 1000
    private let collaboratorMenuLimit = 500
    /// Resolves collaborator filter chips (id → name) without a sync DB round-trip.
    private var collaboratorNames: [String: String] = [:]

    var isReady: Bool { status == .ready }

    /// Spin until `start()` finishes (or fails). Used by Pulse cards that may
    /// appear before the store is open.
    func waitUntilReady() async {
        while !isReady {
            if case .failed = status { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
    var totalTrials: Int { stats?.totalTrials ?? 0 }
    /// Schema v6 precomputed excl-healthy scopes / metadata columns.
    var supportsExclHealthyAggregates: Bool { stats?.hasExclHealthyTotals == true }

    var dataAgeDays: Int? {
        guard let snapshot = stats?.sourceSnapshotDate ?? stats?.createdAt else { return nil }
        return Calendar.current.dateComponents([.day], from: snapshot, to: Date()).day
    }

    private init() {}

    // MARK: - Startup

    func start() async {
        status = .loading
        do {
            try await store.open()
            stats = await store.dashboardStats()
            supportsTrialResults = await store.hasTrialResults
            supportsCollaborators = await store.hasCollaborators
            // v9: lead sponsors always queryable; collaborators when tables exist.
            // v10: unified organisation tables when present.
            supportsOrganisations = true
            supportsCanonicalSites = await store.hasSites
            supportsSites = true
            supportsPublications = await store.hasPublications
            supportsFdaDrugs = await store.hasFdaDrugs
            supportsTrialDrug = await store.hasTrialDrug
            supportsPopularCondition = await store.hasPopularCondition
            supportsLookupIntervention = await store.hasLookupIntervention
            supportsPopularIntervention = await store.hasPopularIntervention
            capabilityReport = await store.capabilityReport
            await loadLookups()
            status = .ready

            // Non-fatal: if a secondary connection fails, that work falls back
            // to the primary store.
            do {
                try await searchStore.open(role: .auxiliary)
                searchStoreReady = true
            } catch {
                print("⚠️ [TrialDataService] search connection unavailable: \(error.localizedDescription)")
            }
            do {
                try await countStore.open(role: .auxiliary)
                countStoreReady = true
            } catch {
                print("⚠️ [TrialDataService] count connection unavailable: \(error.localizedDescription)")
            }
        } catch {
            status = .failed(error.localizedDescription)
            print("❌ [TrialDataService] \(error.localizedDescription)")
        }
    }

    private func loadLookups() async {
        async let s = store.lookup(.status)
        async let st = store.lookup(.studyType)
        async let p = store.lookup(.phase)
        async let c = store.lookup(.country)
        async let cond = store.lookup(.condition, limit: conditionMenuLimit)
        async let collab = store.lookup(.collaborator, limit: collaboratorMenuLimit)
        async let g = store.lookup(.gender)
        async let a = store.lookup(.ageRange)
        async let condTotal = store.lookupTotal(.condition)
        async let countryTot = store.lookupTotal(.country)
        async let collabTotal = store.lookupTotal(.collaborator)
        statuses = await s
        studyTypes = await st
        phases = await p
        countries = await c
        conditions = await cond
        collaborators = await collab
        genders = await g
        ageRanges = await a
        conditionTotal = await condTotal
        countryTotal = await countryTot
        collaboratorTotal = await collabTotal
        for row in collaborators { collaboratorNames[row.value] = row.display }
    }

    /// Searches the full condition list in the database rather than filtering
    /// the truncated in-memory menu. `lookup_condition` has no index that suits
    /// a substring match, so this runs on the auxiliary connection to keep the
    /// scan off the one serving list pages.
    func searchConditions(_ query: String, limit: Int = 200) async -> [LookupValue] {
        await (searchStoreReady ? searchStore : store).searchLookup(.condition, query: query, limit: limit)
    }

    // MARK: - Schema v14 Discover browse

    func discoverConditionCount() async -> Int {
        await store.discoverConditionCount()
    }

    func popularConditions(limit: Int = 50) async -> [LookupValue] {
        await (searchStoreReady ? searchStore : store).popularConditions(limit: limit)
    }

    /// Discover Conditions browser search (excludes population labels when flagged).
    func searchDiscoverConditions(_ query: String, limit: Int = 80) async -> [LookupValue] {
        await (searchStoreReady ? searchStore : store).searchDiscoverConditions(query, limit: limit)
    }

    func discoverInterventionCount() async -> Int {
        await store.discoverInterventionCount()
    }

    func popularInterventions(limit: Int = 50) async -> [InterventionLookupValue] {
        await (searchStoreReady ? searchStore : store).popularInterventions(limit: limit)
    }

    func searchInterventions(_ query: String, limit: Int = 80) async -> [InterventionLookupValue] {
        await (searchStoreReady ? searchStore : store).searchInterventions(query, limit: limit)
    }

    /// Drugs@FDA ingredients with at least one `trial_drug` link (Discover Interventions filter).
    func trialLinkedFdaDrugs(query: String = "", limit: Int = 5_000) async -> [InterventionLookupValue] {
        await (searchStoreReady ? searchStore : store).trialLinkedFdaDrugs(query: query, limit: limit)
    }

    /// Schema v9: organisation search via `collaborator_fts` (falls back to LIKE).
    func searchCollaborators(_ query: String, limit: Int = 40) async -> [LookupValue] {
        let rows = await (searchStoreReady ? searchStore : store).searchCollaborators(query: query, limit: limit)
        for row in rows { collaboratorNames[row.value] = row.display }
        return rows
    }

    /// Readable text for an active filter. Canonical values like
    /// `ACTIVE_NOT_RECRUITING` are unreadable, and the readable form lives in
    /// the `lookup_*.display` columns rather than being hardcoded in the app.
    func displayName(for chip: TrialFilter.Chip) -> String {
        if chip.kind == .organisation {
            return organisationNames[chip.rawValue] ?? "Organisation"
        }
        if chip.kind == .collaborators {
            if chip.rawValue.hasSuffix(" collaborators") { return chip.rawValue }
            return collaboratorNames[chip.rawValue] ?? chip.rawValue
        }
        guard let dimension = chip.kind.dimension else { return chip.rawValue }
        let values: [LookupValue]
        switch dimension {
        case .status:    values = statuses
        case .phase:     values = phases
        case .studyType: values = studyTypes
        case .gender:    values = genders
        case .ageRange:  values = ageRanges
        default:         values = []
        }
        return values.first { $0.value == chip.rawValue }?.display ?? chip.rawValue
    }

    /// Display label for an aggregate / filter canonical value (e.g. `PHASE2` → “Phase 2”).
    func displayName(for dimension: AggDimension, value: String) -> String {
        switch dimension {
        case .status:    return statuses.first { $0.value == value }?.display ?? value
        case .phase:     return phases.first { $0.value == value }?.display ?? value
        case .studyType: return studyTypes.first { $0.value == value }?.display ?? value
        case .gender:    return genders.first { $0.value == value }?.display ?? value
        case .country, .condition: return value
        }
    }

    // MARK: - Query passthroughs

    func count(filter: TrialFilter) async -> Int {
        await (countStoreReady ? countStore : store).count(filter: filter)
    }

    func page(filter: TrialFilter, sort: TrialSort, after cursor: TrialCursor?, limit: Int) async -> [TrialSummary] {
        await store.page(filter: filter, sort: sort, after: cursor, limit: limit)
    }

    func search(_ query: String, scope: TrialSearchScope = .all,
                filter: TrialFilter, sort: TrialSort = .relevance,
                offset: Int, limit: Int) async -> [TrialSummary] {
        guard searchStoreReady else {
            return await store.search(query, scope: scope, filter: filter, sort: sort, offset: offset, limit: limit)
        }
        return await searchStore.search(query, scope: scope, filter: filter, sort: sort, offset: offset, limit: limit)
    }

    /// Abandons a search still running from a previous keystroke. Call this
    /// immediately before issuing a new one.
    func cancelSearch() {
        searchStore.cancelCurrentQuery()
    }

    func detail(nctId: String) async -> TrialDetail? {
        await store.detail(nctId: nctId)
    }

    /// Schema v13 Trial Detail enrichment — empty when unsupported or unfilled.
    func publications(trialId: Int64) async -> [TrialPublication] {
        await store.publications(trialId: trialId)
    }

    func publicationRetractions(publicationId: Int64) async -> [PublicationRetraction] {
        await store.publicationRetractions(publicationId: publicationId)
    }

    func fdaIngredients(trialId: Int64) async -> [TrialFDAIngredient] {
        await store.fdaIngredients(trialId: trialId)
    }

    func fdaBrands(fdaDrugId: Int64) async -> [FDABrand] {
        await store.fdaBrands(fdaDrugId: fdaDrugId)
    }

    func fdaApplications(fdaDrugId: Int64) async -> [FDAApplication] {
        await store.fdaApplications(fdaDrugId: fdaDrugId)
    }

    func fdaProducts(fdaDrugId: Int64) async -> [FDAProduct] {
        await store.fdaProducts(fdaDrugId: fdaDrugId)
    }

    func summaries(nctIds: [String]) async -> [TrialSummary] {
        await store.summaries(nctIds: nctIds)
    }

    func dimensionCounts(_ dimension: AggDimension, scope: AggScope, limit: Int) async -> [DimensionCount] {
        await store.dimensionCounts(dimension, scope: scope, limit: limit)
    }

    func topLeadSponsors(activeOnly: Bool, limit: Int = 10) async -> [DimensionCount] {
        await store.topLeadSponsors(activeOnly: activeOnly, limit: limit)
    }

    /// Top lead sponsors for the filter menu (empty query) or substring search.
    func searchLeadSponsors(_ query: String, limit: Int = 200) async -> [LookupValue] {
        await (searchStoreReady ? searchStore : store).searchLeadSponsors(query: query, limit: limit)
    }

    func topCollaborators(activeOnly: Bool, limit: Int = 10) async -> [DimensionCount] {
        let rows = await store.topCollaborators(activeOnly: activeOnly, limit: limit)
        for row in rows {
            if let name = row.display { collaboratorNames[row.value] = name }
        }
        return rows
    }

    func yearCounts(scope: AggScope) async -> [YearCount] {
        await store.yearCounts(scope: scope)
    }

    func topConditionByYear(scope: AggScope, maxRank: Int = 3) async -> [ConditionByYear] {
        await store.topConditionByYear(scope: scope, maxRank: maxRank)
    }

    // MARK: - Editor's Picks

    func editorPickCandidates(poolLimit: Int = 80, excluding nctIds: Set<String> = []) async -> [TrialSummary] {
        await store.editorPickCandidates(poolLimit: poolLimit, excluding: nctIds)
    }

    // MARK: - Clinical Research Pulse

    func pulseCapabilities() async -> PulseCapabilities {
        await store.pulseCapabilities()
    }

    func pulseRecentActivity(withinDays: Int = 30) async -> PulseRecentActivity {
        await store.pulseRecentActivity(withinDays: withinDays)
    }

    func pulseOnThisDay() async -> PulseOnThisDay? {
        await store.pulseOnThisDay()
    }

    func pulseInterestingTrial() async -> PulseInterestingTrial? {
        await store.pulseInterestingTrial()
    }

    func pulseConditionGrowth(scope: AggScope = .allExclHealthy, metric: String = "ratio",
                              limit: Int = 8) async -> [PulseConditionGrowth] {
        await store.pulseConditionGrowth(scope: scope, metric: metric, limit: limit)
    }

    func pulseStatusWatch(status: String, withinDays: Int = 30, limit: Int = 5) async -> [PulseStoppedTrial] {
        await store.pulseStatusWatch(status: status, withinDays: withinDays, limit: limit)
    }

    // MARK: - Organisations (schema v10+)

    func organisationEntityCount() async -> Int {
        await store.organisationEntityCount()
    }

    func siteEntityCount() async -> Int {
        await store.siteEntityCount()
    }

    func popularOrganisations(limit: Int = 8) async -> [OrganisationSummary] {
        await store.popularOrganisations(limit: limit)
    }

    func organisations(category: OrganisationCategory, limit: Int = 80) async -> [OrganisationSummary] {
        await store.organisations(category: category, limit: limit)
    }

    func searchOrganisations(_ query: String, category: OrganisationCategory, limit: Int = 80) async -> [OrganisationSummary] {
        let rows = await store.searchOrganisations(query, category: category, limit: limit)
        for row in rows { organisationNames[row.id] = row.displayName }
        return rows
    }

    func organisationDetail(ref: OrganisationRef) async -> OrganisationDetail? {
        let detail = await store.organisationDetail(ref: ref)
        if let detail { organisationNames[detail.id] = detail.summary.displayName }
        return detail
    }

    func organisationTopConditions(ref: OrganisationRef, limit: Int = 8) async -> [OrganisationConditionCount] {
        await store.organisationTopConditions(ref: ref, limit: limit)
    }

    func organisationCountries(ref: OrganisationRef, limit: Int = 12) async -> [OrganisationCountryCount] {
        await store.organisationCountries(ref: ref, limit: limit)
    }

    /// Distinct facilities when site tables exist; `nil` means fall back to
    /// `organisation.site_count` (study-site instances) with a clearer label.
    func organisationUniqueSiteCount(ref: OrganisationRef) async -> Int? {
        await store.organisationUniqueSiteCount(ref: ref)
    }

    func organisationRecentStudies(ref: OrganisationRef, limit: Int = 5) async -> [TrialSummary] {
        await store.organisationRecentStudies(ref: ref, limit: limit)
    }

    /// Schema v13+: recent distinct publications across the org’s related trials.
    func organisationRecentPublications(ref: OrganisationRef, limit: Int = 8) async -> [TrialPublication] {
        await store.organisationRecentPublications(ref: ref, limit: limit)
    }

    /// Schema v13+: recent distinct publications across trials that ran at this site.
    func siteRecentPublications(ref: SiteRef, limit: Int = 8) async -> [TrialPublication] {
        await store.siteRecentPublications(ref: ref, limit: limit)
    }

    /// Schema v13+: distinct publication counts for a site (precomputed columns or live join).
    func sitePublicationCounts(ref: SiteRef) async -> (linked: Int, openAccess: Int) {
        await store.sitePublicationCounts(ref: ref)
    }

    func organisationRoute(name: String, agencyClass: String?, collaboratorId: Int64?) async -> OrganisationRoute? {
        await store.organisationRoute(name: name, agencyClass: agencyClass, collaboratorId: collaboratorId)
    }

    // MARK: - Sites (schema v10+; v9 recruiting fallback)

    /// Pre-builds the recruiting-only site index so Site detail is not cold.
    func warmSiteIndexIfNeeded() async {
        guard !supportsCanonicalSites else { return }
        await store.warmSiteIndexIfNeeded()
    }

    func searchSites(_ query: String, limit: Int = 80) async -> [SiteSummary] {
        await (searchStoreReady ? searchStore : store).searchSites(query, limit: limit)
    }

    func highActivitySites(limit: Int = 80) async -> [SiteSummary] {
        await (searchStoreReady ? searchStore : store).highActivitySites(limit: limit)
    }

    func nearbySites(
        latitude: Double, longitude: Double, radiusMeters: Double, limit: Int = 80
    ) async -> [SiteSummary] {
        await (searchStoreReady ? searchStore : store).nearbySites(
            latitude: latitude, longitude: longitude, radiusMeters: radiusMeters, limit: limit
        )
    }

    func siteCities(limit: Int = 80) async -> [SiteCityGroup] {
        await (searchStoreReady ? searchStore : store).siteCities(limit: limit)
    }

    func siteCountries(limit: Int = 80) async -> [SiteCountryGroup] {
        await (searchStoreReady ? searchStore : store).siteCountries(limit: limit)
    }

    func sites(inCity city: String, country: String?, limit: Int = 80) async -> [SiteSummary] {
        await (searchStoreReady ? searchStore : store).sites(inCity: city, country: country, limit: limit)
    }

    func sites(inCountry country: String, limit: Int = 80) async -> [SiteSummary] {
        await (searchStoreReady ? searchStore : store).sites(inCountry: country, limit: limit)
    }

    func siteDetail(ref: SiteRef) async -> SiteDetail? {
        await store.siteDetail(ref: ref)
    }

    func siteTopConditions(ref: SiteRef, limit: Int = 8) async -> [SiteConditionCount] {
        await store.siteTopConditions(ref: ref, limit: limit)
    }

    func siteLeadOrganisations(ref: SiteRef, limit: Int = 8) async -> [SiteLeadOrganisation] {
        await store.siteLeadOrganisations(ref: ref, limit: limit)
    }

    func siteRecentStudies(ref: SiteRef, limit: Int = 5) async -> [TrialSummary] {
        await store.siteRecentStudies(ref: ref, limit: limit)
    }

    // MARK: - Nearby recruiting

    /// Recruiting studies with a site inside `radiusMeters`. Prefer the search
    /// connection so a multi-second country scan never blocks list paging.
    func nearbyRecruiting(
        latitude: Double,
        longitude: Double,
        radiusMeters: Double,
        filter: TrialFilter = TrialFilter(),
        countryHint: String? = nil,
        limit: Int = 200
    ) async -> [NearbyTrial] {
        await (searchStoreReady ? searchStore : store).nearbyRecruiting(
            latitude: latitude,
            longitude: longitude,
            radiusMeters: radiusMeters,
            filter: filter,
            countryHint: countryHint,
            limit: limit
        )
    }
}
