 //
//  ContentView.swift
//  nmbTrialBeacon
//
//  App shell (Liquid Glass tab bar) + Home dashboard.
//

import SwiftUI
import SwiftData
import CoreLocation

// MARK: - Tab shell

struct MainTabView: View {
    var body: some View {
        @Bindable var router = AppRouter.shared

        TabView(selection: $router.selectedTab) {
            Tab("Home", systemImage: "house.fill", value: AppTab.home) {
                HomeView()
            }
            // Normal tab (not search-role): Discover owns its search field so the
            // query stays visible and sort/filter chrome doesn't disappear.
            Tab("Discover", systemImage: "magnifyingglass", value: AppTab.discover) {
                DiscoverView()
            }
            Tab("Watchlist", systemImage: "bookmark.fill", value: AppTab.watchlist) {
                WatchlistView()
            }
            Tab("Analytics", systemImage: "chart.pie.fill", value: AppTab.analytics) {
                AnalyticsView()
            }
            Tab("Settings", systemImage: "gearshape.fill", value: AppTab.settings) {
                SettingsView()
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
    }
}

enum AppTab: Hashable {
    case home, watchlist, analytics, settings, discover
}

/// Cross-tab navigation. Screens can hand the user off to a destination that
/// lives under a different tab — which a `NavigationLink` cannot do — and say
/// what should be brought into view once they arrive.
///
/// Reached through `shared` rather than the environment. `@Environment(AppRouter.self)`
/// traps at runtime if no ancestor injected the value, and there is only ever
/// one router, so the lookup bought nothing but a crash if the two halves of
/// the wiring ever drifted apart. Observation still tracks reads made through
/// the singleton, so views update exactly as they did before.
@MainActor
@Observable
final class AppRouter {
    static let shared = AppRouter()

    enum SettingsFocus: Hashable { case profile }

    var selectedTab: AppTab = .home
    var settingsFocus: SettingsFocus?

    private init() {}

    func openProfileSetup() {
        settingsFocus = .profile
        selectedTab = .settings
    }
}

// MARK: - Home

struct HomeView: View {
    @Environment(TrialDataService.self) private var data
    @Environment(AIMatchingService.self) private var ai
    @Environment(LocationService.self) private var location
    @Environment(\.modelContext) private var modelContext

    @Query private var userProfiles: [UserProfile]
    @Query(sort: \FavouriteOrganisation.favoritedAt, order: .reverse)
    private var favouriteOrgs: [FavouriteOrganisation]
    @Query(sort: \RecentlyViewedOrganisation.viewedAt, order: .reverse)
    private var recentlyViewedOrgs: [RecentlyViewedOrganisation]
    @Query(sort: \WatchlistItem.dateAdded, order: .reverse)
    private var watchlist: [WatchlistItem]

    @AppStorage("nearbyRadiusMiles") private var nearbyRadiusMiles = LocationService.defaultRadiusMiles
    @AppStorage("featuredTrialLog") private var featuredTrialLog = ""

    @State private var profile: UserProfile?
    @State private var showingDataStatus = false
    @State private var showingPulse = false
    @State private var nearbySpotlight: NearbyTrial?
    @State private var featured: FeaturedTrialPick?
    @State private var onThisDay: PulseOnThisDay?
    @State private var interestingTrial: PulseInterestingTrial?
    @State private var pulseTablesPresent = (onThisDay: false, interesting: false)
    @State private var articlesLoading = true

    private var resolvedProfile: UserProfile? { profile ?? userProfiles.first }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    if let days = data.dataAgeDays, days >= 7 {
                        DataFreshnessBanner(daysOld: days)
                    }

                    if let featured {
                        FeaturedTrialSection(pick: featured)
                    }

                    DashboardCardsSection()

                    // Only insert when we have a hit — an empty LazyVStack child
                    // never lays out, so its `.task` would never run (and would
                    // never request location permission).
                    if let nearbySpotlight {
                        HomeRecruitingNearYouSection(spotlight: nearbySpotlight)
                    }

                    PulseOnThisDaySection(
                        item: onThisDay,
                        loading: articlesLoading,
                        tablePresent: pulseTablesPresent.onThisDay
                    )
                    PulseInterestingTrialSection(
                        item: interestingTrial,
                        loading: articlesLoading,
                        tablePresent: pulseTablesPresent.interesting
                    )
                    PulseResearchMomentumSection()
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .scrollEdgeEffectStyle(.soft, for: .top)
            .scrollEdgeEffectStyle(.soft, for: .bottom)
            .navigationTitle("TrialBeacon")
            .navigationSubtitle("\(data.totalTrials.formatted()) trials")
            .trialNavigationDestinations()
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        showingPulse = true
                    } label: {
                        Image(systemName: "waveform.path.ecg")
                    }
                    .accessibilityLabel("Clinical Research Pulse")

                    Button {
                        showingDataStatus = true
                    } label: {
                        Image(systemName: "checkmark.seal.fill")
                    }
                    .tint(.green)
                    .accessibilityLabel("Data status, \(data.totalTrials.formatted()) trials")
                }
            }
            .sheet(isPresented: $showingDataStatus) {
                DataStatusSheet()
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showingPulse) {
                ClinicalResearchPulseView()
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
            .task {
                loadProfile()
                location.prepare()
                await ai.precalculateRecommendations(for: resolvedProfile)
            }
            .task(id: homeArticlesToken) {
                await loadHomeArticles()
            }
        }
    }

    private var homeArticlesToken: String {
        let p = resolvedProfile
        let conditions = (p?.conditionsOfInterest.map(\.name) ?? []).sorted().joined(separator: ",")
        let favs = favouriteOrgs.map(\.identityKey).joined(separator: ",")
        let city = p?.preferredCity ?? ""
        let lat = p?.preferredCityLatitude.map { String(format: "%.3f", $0) }
            ?? location.coordinate.map { String(format: "%.3f", $0.latitude) }
            ?? "-"
        let lon = p?.preferredCityLongitude.map { String(format: "%.3f", $0) }
            ?? location.coordinate.map { String(format: "%.3f", $0.longitude) }
            ?? "-"
        let auth = location.isAuthorized
        return [
            FeaturedTrialLog.dayStamp(),
            "\(auth)|\(city)|\(lat)|\(lon)|\(nearbyRadiusMiles)",
            conditions,
            p?.ageRange ?? "",
            p?.country ?? "",
            String(watchlist.count),
            favs
        ].joined(separator: "#")
    }

    private func loadProfile() {
        var descriptor = FetchDescriptor<UserProfile>()
        descriptor.fetchLimit = 1
        profile = try? modelContext.fetch(descriptor).first
    }

    /// All article sources start together; collisions are resolved as results arrive.
    private func loadHomeArticles() async {
        articlesLoading = true
        await data.waitUntilReady()
        loadProfile()

        let p = resolvedProfile
        let anchor = p?.nearbyAnchor
        var log = FeaturedTrialLog(raw: featuredTrialLog)
        let coordinate = location.isAuthorized ? location.coordinate : nil
        let radiusMeters = Double(nearbyRadiusMiles) * NearbyDistance.metersPerMile

        // Featured starts without pulse reserved — preferred-day fast path doesn’t
        // need it; rare collisions re-pick below.
        var featuredContext = FeaturedTrialEngine.Context()
        featuredContext.profileConditions = p?.conditionsOfInterest.map(\.name) ?? []
        featuredContext.ageRange = p?.ageRange
        featuredContext.country = p?.country
        featuredContext.watchlistNctIds = watchlist.map(\.nctId)
        featuredContext.favouriteOrgNames = favouriteOrgs.map(\.displayName)
        featuredContext.recentOrgNames = recentlyViewedOrgs.prefix(4).map(\.displayName)
        featuredContext.coordinate = anchor?.coordinate ?? location.coordinate
        featuredContext.countryHint = anchor?.countryHint ?? location.countryName
        featuredContext.radiusMiles = nearbyRadiusMiles
        featuredContext.excludedNctIds = log.previousIds
        featuredContext.preferredNctId = log.todaysId

        async let capsTask = data.pulseCapabilities()
        async let dayTask = data.pulseOnThisDay()
        async let interestingTask = data.pulseInterestingTrial()
        async let featuredTask = FeaturedTrialEngine.pick(data: data, context: featuredContext)
        async let nearbyHitsTask: [NearbyTrial] = {
            guard let coordinate else { return [] }
            return await data.nearbyRecruiting(
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                radiusMeters: radiusMeters,
                filter: TrialFilter(),
                countryHint: location.countryName,
                limit: 40
            )
        }()

        let caps = await capsTask
        let day = await dayTask
        var interesting = await interestingTask
        if let day, interesting?.nctId == day.nctId {
            interesting = nil
        }
        pulseTablesPresent = (caps.onThisDay, caps.interestingTrial)
        onThisDay = day
        interestingTrial = interesting
        articlesLoading = false

        var reserved = Set<String>()
        if let day { reserved.insert(day.nctId) }
        if let interesting { reserved.insert(interesting.nctId) }

        var pick = await featuredTask
        if let current = pick, reserved.contains(current.trial.nctId) {
            featuredContext.reservedEditorialNctIds = reserved
            featuredContext.preferredNctId = nil
            pick = await FeaturedTrialEngine.pick(data: data, context: featuredContext)
        }
        if let pick {
            log.record(nctId: pick.trial.nctId)
            featuredTrialLog = log.raw
            reserved.insert(pick.trial.nctId)
        }
        featured = pick

        let hits = await nearbyHitsTask
        let ranked = ai.rankNearby(hits, profile: p)
        nearbySpotlight = ranked.first { !reserved.contains($0.trial.nctId) }
    }
}

// MARK: - Dashboard cards

struct DashboardCardsSection: View {
    @Environment(TrialDataService.self) private var data
    @State private var activity: PulseRecentActivity?

    private let cardSpacing: CGFloat = 10
    private let scrollCardWidth: CGFloat = 118

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: cardSpacing) {
                    cards(flexible: true)
                }

                ScrollView(.horizontal) {
                    HStack(spacing: cardSpacing) {
                        cards(flexible: false)
                    }
                    .scrollTargetLayout()
                }
                .scrollIndicators(.hidden)
                .scrollTargetBehavior(.viewAligned)
            }

            Text("Last 30 days")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task {
            activity = await data.pulseRecentActivity(withinDays: 30)
        }
    }

    @ViewBuilder
    private func cards(flexible: Bool) -> some View {
        let a = activity
        dashboardCard(
            title: "New",
            count: a?.newTrials ?? 0,
            icon: "sparkles",
            color: .teal,
            filter: {
                var f = TrialFilter()
                f.firstPostedWithinDays = 30
                return f
            }(),
            sort: .firstPostedDesc,
            flexible: flexible
        )
        dashboardCard(
            title: "Recruiting",
            count: a?.beganRecruiting ?? 0,
            icon: "person.badge.plus",
            color: .green,
            filter: {
                var f = TrialFilter()
                f.status = "RECRUITING"
                f.lastUpdatedWithinDays = 30
                return f
            }(),
            flexible: flexible
        )
        dashboardCard(
            title: "Completed",
            count: a?.completed ?? 0,
            icon: "checkmark.circle",
            color: .blue,
            filter: {
                var f = TrialFilter()
                f.status = "COMPLETED"
                f.lastUpdatedWithinDays = 30
                return f
            }(),
            flexible: flexible
        )
        dashboardCard(
            title: "Terminated",
            count: a?.terminated ?? 0,
            icon: "xmark.circle",
            color: .orange,
            filter: {
                var f = TrialFilter()
                f.status = "TERMINATED"
                f.lastUpdatedWithinDays = 30
                return f
            }(),
            flexible: flexible
        )
    }

    private func dashboardCard(
        title: String,
        count: Int,
        icon: String,
        color: Color,
        filter: TrialFilter,
        sort: TrialSort = .lastUpdatedDesc,
        flexible: Bool
    ) -> some View {
        DashboardCard(title: title, count: count, icon: icon, color: color, filter: filter, sort: sort)
            .frame(width: flexible ? nil : scrollCardWidth)
            .frame(maxWidth: flexible ? .infinity : nil)
    }
}

struct DashboardCard: View {
    let title: String
    let count: Int
    let icon: String
    let color: Color
    let filter: TrialFilter
    var sort: TrialSort = .lastUpdatedDesc
    /// Defaults to home’s “Title · last 30 days” when nil.
    var listTitle: String? = nil

    private var destinationTitle: String {
        listTitle ?? "\(title) · last 30 days"
    }

    var body: some View {
        NavigationLink(value: TrialListRequest(
            title: destinationTitle,
            filter: filter,
            sort: sort
        )) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(count.formatted())
                        .font(.title3.bold())
                        .foregroundStyle(.primary)
                        .contentTransition(.numericText())
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: icon)
                        .font(.subheadline)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(color)
                }
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .frame(height: 68)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Supporting tiles

struct InfoTile: View {
    let icon: String
    let title: String
    let message: String
    var showsDisclosure = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.blue)
                .symbolRenderingMode(.hierarchical)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline).fontWeight(.medium).foregroundStyle(.primary)
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if showsDisclosure {
                Image(systemName: "chevron.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct DataFreshnessBanner: View {
    let daysOld: Int

    private var color: Color { daysOld > 30 ? .red : .orange }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: daysOld > 30 ? "exclamationmark.triangle.fill" : "clock.badge.exclamationmark")
                .font(.title3)
                .foregroundStyle(color)
                .symbolRenderingMode(.hierarchical)
            VStack(alignment: .leading, spacing: 2) {
                Text("Data is \(daysOld) days old").font(.subheadline).fontWeight(.medium)
                Text("A newer dataset may be available via an app update.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - Data status sheet

struct DataStatusSheet: View {
    @Environment(TrialDataService.self) private var data
    @Environment(SyncService.self) private var sync
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ClinicalTrialsAttributionBlock()
                } header: {
                    Text("Attribution")
                }

                Section("Database") {
                    LabeledContent("Total trials", value: data.totalTrials.formatted())
                    if let schema = data.stats?.schemaVersion, schema > 0 {
                        LabeledContent("Schema", value: "v\(schema)")
                    }
                    if let generator = data.stats?.generatorVersion, !generator.isEmpty {
                        LabeledContent("Generator", value: generator)
                    }
                    if let snapshot = data.stats?.sourceSnapshotDate {
                        LabeledContent("Data snapshot", value: snapshot.formatted(date: .abbreviated, time: .omitted))
                    }
                    if let created = data.stats?.createdAt {
                        LabeledContent("Built", value: created.formatted(date: .abbreviated, time: .omitted))
                    }
                    if let days = data.dataAgeDays {
                        LabeledContent("Age", value: "\(days) day\(days == 1 ? "" : "s")")
                    }
                    if let cap = data.capabilityReport {
                        LabeledContent("Bundled file", value: "\(cap.databaseFileName) · \(cap.fileSizeLabel)")
                        if let modified = cap.databaseModifiedAt {
                            LabeledContent("File modified", value: modified.formatted(date: .abbreviated, time: .shortened))
                        }
                    }
                }
                Section("Organisations capability") {
                    if let cap = data.capabilityReport {
                        LabeledContent("Org tables", value: cap.hasOrganisationTables ? "Present" : "Missing")
                        LabeledContent("active_trial_count", value: cap.hasOrganisationActiveTrialCount ? "Present" : "Missing")
                        LabeledContent("HQ / website", value: cap.hasOrganisationHQ ? "Present (hq_*)" : "Missing")
                        LabeledContent("linked_publication_count", value: cap.hasOrganisationPublicationCounts ? "Present (v13)" : "Missing")
                    } else {
                        Text("Capability report unavailable")
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Sites capability") {
                    if let cap = data.capabilityReport {
                        LabeledContent("Site tables", value: cap.sitesReadyLabel)
                        LabeledContent("trial_site rows", value: cap.trialSiteRowCount.formatted())
                        LabeledContent("Query path", value: cap.sitesQueryPath.rawValue)
                        ForEach(cap.siteCompanionTables, id: \.0) { name, present in
                            LabeledContent(name, value: present ? "Present" : "Missing")
                        }
                    } else {
                        Text("Capability report unavailable")
                            .foregroundStyle(.secondary)
                    }
                    if data.supportsCanonicalSites {
                        Label("Using bundled site catalogue", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label("Using slow recruiting fallback", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
                Section("Publications (v13+)") {
                    if let cap = data.capabilityReport {
                        LabeledContent("Publication records", value: cap.publicationRowCount.formatted())
                        LabeledContent("Publication references", value: cap.trialPublicationRowCount.formatted())
                        LabeledContent("results pub counts", value: cap.hasTrialResultsPublicationCounts ? "Present" : "Missing")
                        LabeledContent("org pub counts", value: cap.hasOrganisationPublicationCounts ? "Present" : "Missing")
                        LabeledContent("site pub counts", value: cap.hasSitePublicationCounts ? "Present (v14)" : "Live join / missing")
                        ForEach(cap.publicationCompanionTables, id: \.0) { name, present in
                            LabeledContent(name, value: present ? "Present" : "Missing")
                        }
                    } else {
                        Text("Capability report unavailable")
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Discover browse (v14)") {
                    if let cap = data.capabilityReport {
                        LabeledContent("popular_condition", value: cap.hasPopularCondition ? "Present" : "Missing")
                        LabeledContent("lookup_intervention", value: cap.hasLookupIntervention ? "Present" : "Missing")
                        LabeledContent("popular_intervention", value: cap.hasPopularIntervention ? "Present" : "Missing")
                    } else {
                        Text("Capability report unavailable")
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Drugs@FDA (v13)") {
                    if let cap = data.capabilityReport {
                        LabeledContent("FDA drug ingredients", value: cap.fdaDrugRowCount.formatted())
                        LabeledContent("Trial ↔ drug links", value: cap.trialDrugRowCount.formatted())
                        LabeledContent("Trials with FDA link", value: cap.trialsWithFdaLinkCount.formatted())
                        if cap.hasFdaDrugs, cap.trialDrugRowCount == 0 {
                            Text("Ingredient catalogue is present, but no trial interventions are linked yet. Re-run Drugs@FDA matching in the database generator, then rebundle.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else if cap.trialsWithFdaLinkCount > 0, cap.trialsWithFdaLinkCount < 100 {
                            Text("Only \(cap.trialsWithFdaLinkCount.formatted()) trials have Drugs@FDA links in this snapshot. FDA tags appear only on those trials.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(cap.fdaCompanionTables, id: \.0) { name, present in
                            LabeledContent(name, value: present ? "Present" : "Missing")
                        }
                    } else {
                        Text("Capability report unavailable")
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Status") {
                    Label("Database ready", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    if let last = sync.lastSyncDate {
                        LabeledContent("Last checked", value: last.formatted(date: .abbreviated, time: .shortened))
                    }
                }
            }
            .navigationTitle("Data Status")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
