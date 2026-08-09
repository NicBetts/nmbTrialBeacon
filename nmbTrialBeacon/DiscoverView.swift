//
//  DiscoverView.swift
//  nmbTrialBeacon
//
//  Search → landscape (Orgs / Sites / Recruiting + Conditions / Interventions)
//  → Recently viewed → Matching → Saved → Favourites → Popular lists.
//

import CoreLocation
import SwiftData
import SwiftUI

// MARK: - Routes

enum DiscoverRoute: Hashable {
    case trialSearch(focus: Bool)
    case trialSearchFiltered(TrialFilter)
    case trialSearchLaunch(SavedSearches.Launch)
    case organisationBrowser
    case organisation(OrganisationRoute)
    case siteBrowser
    case site(SiteRoute)
    case conditionBrowser
    case interventionBrowser
}

/// Typed push to `OrganisationDetailView` from Discover, detail, or Analytics.
nonisolated struct OrganisationRoute: Hashable, Sendable {
    let ref: OrganisationRef

    init(ref: OrganisationRef) { self.ref = ref }
    init(organisationId: Int64) { self.ref = .organisation(organisationId) }
    init(leadSponsor name: String) { self.ref = .leadSponsor(name) }
    init(collaboratorId: Int64) { self.ref = .collaborator(collaboratorId) }
}

/// Entity exploration kinds. Org + site always; condition + intervention need v14 tables.
enum DiscoverEntityKind: String, CaseIterable, Identifiable, Sendable {
    case organisation
    case condition
    case site
    case intervention
    case country

    var id: String { rawValue }

    var title: String {
        switch self {
        case .organisation: return "Organisations"
        case .condition: return "Conditions"
        case .site: return "Sites"
        case .intervention: return "Interventions"
        case .country: return "Countries"
        }
    }

    var isEnabled: Bool {
        switch self {
        case .organisation, .site, .condition, .intervention: return true
        case .country: return false
        }
    }
}

// MARK: - Landing

struct DiscoverView: View {
    @Environment(TrialDataService.self) private var data
    @Environment(LocationService.self) private var location
    @Environment(\.modelContext) private var modelContext

    @Query private var userProfiles: [UserProfile]
    @Query(sort: \FavouriteOrganisation.favoritedAt, order: .reverse)
    private var favouriteOrgs: [FavouriteOrganisation]
    @Query(sort: \FavouriteSite.favoritedAt, order: .reverse)
    private var favouriteSites: [FavouriteSite]
    @Query(sort: \RecentlyViewedOrganisation.viewedAt, order: .reverse)
    private var recentlyViewedOrgs: [RecentlyViewedOrganisation]
    @Query(sort: \RecentlyViewedSite.viewedAt, order: .reverse)
    private var recentlyViewedSites: [RecentlyViewedSite]
    @Query(sort: \SavedSearch.savedAt, order: .reverse)
    private var savedSearches: [SavedSearch]

    @AppStorage("nearbyRadiusMiles") private var radiusMiles = LocationService.defaultRadiusMiles

    @State private var renameSearch: SavedSearch?
    @State private var renameDraft = ""

    @State private var popularOrgs: [OrganisationSummary] = []
    @State private var popularSites: [SiteSummary] = []
    @State private var popularConditions: [LookupValue] = []
    @State private var popularInterventions: [InterventionLookupValue] = []
    @State private var popularOrgVisibleCount = 5
    @State private var popularSiteVisibleCount = 5
    @State private var popularConditionVisibleCount = 5
    @State private var popularInterventionVisibleCount = 5
    @State private var isLoadingPopularOrgs = true
    @State private var isLoadingPopularSites = true
    @State private var isLoadingPopularConditions = true
    @State private var isLoadingPopularInterventions = true
    @State private var organisationCount: Int?
    @State private var siteCount: Int?
    @State private var conditionCount: Int?
    @State private var interventionCount: Int?
    @State private var recruitingNearbyCount: Int?
    /// Live counts / icons for favourites rows (identityKey → stats).
    @State private var favouriteStats: [String: FavouriteRowStats] = [:]

    private var profile: UserProfile? { userProfiles.first }

    private var profileConditions: [String] {
        profile?.conditionsOfInterest.map(\.name) ?? []
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    landscapeBoxes
                    if !recentItems.isEmpty {
                        recentlyViewed
                    }
                    if !profileConditions.isEmpty {
                        DiscoverMatchingTrialsMockup(profile: profile)
                    }
                    if !savedSearches.isEmpty {
                        savedSearchesSection
                    }
                    if !favouriteItems.isEmpty {
                        favouritesSection
                    }
                    popularOrganisations
                    popularSitesSection
                    if data.supportsPopularCondition {
                        popularConditionsSection
                    }
                    if data.supportsPopularIntervention {
                        popularInterventionsSection
                    }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .scrollEdgeEffectStyle(.soft, for: .top)
            .scrollEdgeEffectStyle(.soft, for: .bottom)
            .navigationTitle("Discover")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(value: DiscoverRoute.trialSearch(focus: true)) {
                        Image(systemName: "magnifyingglass")
                    }
                    .accessibilityLabel("Search trials")
                }
            }
            .navigationDestination(for: DiscoverRoute.self) { route in
                switch route {
                case .trialSearch(let focus):
                    TrialSearchView(autoFocusSearch: focus)
                case .trialSearchFiltered(let filter):
                    TrialSearchView(initialFilter: filter, restoreLastFilter: false)
                case .trialSearchLaunch(let launch):
                    TrialSearchView(launch: launch)
                case .organisationBrowser:
                    OrganisationBrowserView()
                case .organisation(let route):
                    OrganisationDetailView(ref: route.ref)
                case .siteBrowser:
                    SiteBrowserView()
                case .site(let route):
                    SiteDetailView(ref: route.ref)
                case .conditionBrowser:
                    ConditionBrowserView()
                case .interventionBrowser:
                    InterventionBrowserView()
                }
            }
            .alert("Rename Search", isPresented: Binding(
                get: { renameSearch != nil },
                set: { if !$0 { renameSearch = nil } }
            )) {
                TextField("Name", text: $renameDraft)
                Button("Cancel", role: .cancel) { renameSearch = nil }
                Button("Save") {
                    if let row = renameSearch {
                        SavedSearches.rename(row, to: renameDraft, context: modelContext)
                    }
                    renameSearch = nil
                }
            }
            .trialNavigationDestinations()
            .task { location.prepare() }
            .task { await loadLandscapeCounts() }
            .task { await loadPopularOrgs(limit: 10) }
            .task { await loadPopularSites(limit: 10) }
            .task { await loadPopularConditions(limit: 10) }
            .task { await loadPopularInterventions(limit: 10) }
            .task(id: nearbyQueryToken) { await loadRecruitingCount() }
            .task(id: favouritesQueryToken) { await loadFavouriteStats() }
        }
    }

    // MARK: Landscape boxes

    private var landscapeTileCount: Int {
        3
            + (data.supportsPopularCondition ? 1 : 0)
            + (data.supportsLookupIntervention ? 1 : 0)
    }

    private var landscapeBoxes: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    NavigationLink(value: DiscoverRoute.organisationBrowser) {
                        DiscoverLandscapeCard(
                            title: "Organisations",
                            countText: organisationCount.map { $0.formatted() } ?? "—",
                            systemImage: "building.2"
                        )
                    }
                    .buttonStyle(.plain)

                    NavigationLink(value: DiscoverRoute.siteBrowser) {
                        DiscoverLandscapeCard(
                            title: "Sites",
                            countText: siteBoxCountText,
                            systemImage: "mappin.and.ellipse"
                        )
                    }
                    .buttonStyle(.plain)

                    NavigationLink(value: recruitingRoute) {
                        DiscoverLandscapeCard(
                            // One line — avoids the cramped “Recruiting / Boston” stack.
                            title: recruitingCardTitle,
                            countText: recruitingNearbyCount.map { $0.formatted() } ?? "—",
                            systemImage: "waveform.path.ecg"
                        )
                    }
                    .buttonStyle(.plain)

                    if data.supportsPopularCondition {
                        NavigationLink(value: DiscoverRoute.conditionBrowser) {
                            DiscoverLandscapeCard(
                                title: "Conditions",
                                countText: conditionCount.map { $0.formatted() } ?? "—",
                                systemImage: "heart.text.square"
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    if data.supportsLookupIntervention {
                        NavigationLink(value: DiscoverRoute.interventionBrowser) {
                            DiscoverLandscapeCard(
                                title: "Interventions",
                                countText: interventionCount.map { $0.formatted() } ?? "—",
                                systemImage: "pills"
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollClipDisabled()
            .accessibilityHint(landscapeTileCount > 3 ? "Swipe horizontally for more categories" : "")

            if landscapeTileCount > 3 {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left.chevron.right")
                        .font(.caption2.weight(.semibold))
                    Text("Swipe for more")
                        .font(.caption2.weight(.medium))
                }
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            }
        }
    }

    private var siteBoxCountText: String {
        // Canonical `site` / `trial_site` tables ship with a v11 rebuild. Until
        // those exist in the opened file, show Browse rather than a fake 0.
        guard data.supportsCanonicalSites else { return "Browse" }
        return siteCount.map { $0.formatted() } ?? "—"
    }

    /// Single-line landscape label for nearby recruiting (city when set, else Near me).
    private var recruitingCardTitle: String {
        if let city = profile?.preferredCity?.trimmingCharacters(in: .whitespacesAndNewlines),
           !city.isEmpty,
           profile?.hasPreferredCityCoordinate == true {
            let short = city.split(separator: ",").first.map(String.init) ?? city
            return "Near \(short)"
        }
        return "Near me"
    }

    private var recruitingRoute: NearbyStudiesRoute {
        NearbyStudiesRoute(anchor: profile?.nearbyAnchor)
    }

    // MARK: Popular

    private var popularOrganisations: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Popular organisations")
                .font(.title2.bold())

            if isLoadingPopularOrgs && popularOrgs.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            } else if !popularOrgs.isEmpty {
                let visible = Array(popularOrgs.prefix(popularOrgVisibleCount))
                VStack(spacing: 0) {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, org in
                        NavigationLink(value: OrganisationRoute(ref: org.ref)) {
                            popularOrgRow(org)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            let key = org.ref.identityKey
                            let isFav = favouriteOrgKeys.contains(key)
                            Button {
                                _ = EntityFavourites.toggleOrganisation(
                                    identityKey: key,
                                    displayName: org.displayName,
                                    context: modelContext
                                )
                            } label: {
                                Label(
                                    isFav ? "Remove from Favourites" : "Add to Favourites",
                                    systemImage: isFav ? "star.slash" : "star"
                                )
                            }
                        }
                        if index < visible.count - 1 {
                            Divider().opacity(0.35)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .glassEffect(.regular, in: .rect(cornerRadius: 18, style: .continuous))

                if popularOrgs.count > 5 {
                    Button {
                        withAnimation(.smooth(duration: 0.25)) {
                            popularOrgVisibleCount = popularOrgVisibleCount > 5 ? 5 : 10
                        }
                    } label: {
                        Text(popularOrgVisibleCount > 5 ? "Show less" : "Show more")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.borderless)
                    .padding(.top, 4)
                }
            }
        }
    }

    private var popularSitesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Popular sites")
                .font(.title2.bold())

            if isLoadingPopularSites && popularSites.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            } else if !popularSites.isEmpty {
                let visible = Array(popularSites.prefix(popularSiteVisibleCount))
                VStack(spacing: 0) {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, site in
                        NavigationLink(value: SiteRoute(ref: site.ref)) {
                            popularSiteRow(site)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            let key = site.ref.identityKey
                            let isFav = favouriteSiteKeys.contains(key)
                            Button {
                                _ = EntityFavourites.toggleSite(
                                    identityKey: key,
                                    displayName: site.displayName,
                                    context: modelContext
                                )
                            } label: {
                                Label(
                                    isFav ? "Remove from Favourites" : "Add to Favourites",
                                    systemImage: isFav ? "star.slash" : "star"
                                )
                            }
                        }
                        if index < visible.count - 1 {
                            Divider().opacity(0.35)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .glassEffect(.regular, in: .rect(cornerRadius: 18, style: .continuous))

                if popularSites.count > 5 {
                    Button {
                        withAnimation(.smooth(duration: 0.25)) {
                            popularSiteVisibleCount = popularSiteVisibleCount > 5 ? 5 : 10
                        }
                    } label: {
                        Text(popularSiteVisibleCount > 5 ? "Show less" : "Show more")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.borderless)
                    .padding(.top, 4)
                }
            }
        }
    }

    private var popularConditionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Popular conditions")
                    .font(.title2.bold())
                Spacer()
                NavigationLink(value: DiscoverRoute.conditionBrowser) {
                    Text("See all")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderless)
            }

            if isLoadingPopularConditions && popularConditions.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            } else if !popularConditions.isEmpty {
                let visible = Array(popularConditions.prefix(popularConditionVisibleCount))
                VStack(spacing: 0) {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, row in
                        NavigationLink(value: TrialListRequest(
                            title: row.display,
                            filter: {
                                var f = TrialFilter()
                                f.conditions = [row.value]
                                return f
                            }()
                        )) {
                            popularLookupRow(
                                title: row.display,
                                count: row.count,
                                systemImage: "heart.text.square"
                            )
                        }
                        .buttonStyle(.plain)
                        if index < visible.count - 1 {
                            Divider().opacity(0.35)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .glassEffect(.regular, in: .rect(cornerRadius: 18, style: .continuous))

                if popularConditions.count > 5 {
                    Button {
                        withAnimation(.smooth(duration: 0.25)) {
                            popularConditionVisibleCount = popularConditionVisibleCount > 5 ? 5 : 10
                        }
                    } label: {
                        Text(popularConditionVisibleCount > 5 ? "Show less" : "Show more")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.borderless)
                    .padding(.top, 4)
                }
            }
        }
    }

    private var popularInterventionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Popular interventions")
                    .font(.title2.bold())
                Spacer()
                NavigationLink(value: DiscoverRoute.interventionBrowser) {
                    Text("See all")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderless)
            }

            if isLoadingPopularInterventions && popularInterventions.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            } else if !popularInterventions.isEmpty {
                let visible = Array(popularInterventions.prefix(popularInterventionVisibleCount))
                VStack(spacing: 0) {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, row in
                        NavigationLink(value: DiscoverRoute.trialSearchLaunch(
                            SavedSearches.Launch(
                                query: row.value,
                                scope: .interventions,
                                sort: .relevance
                            )
                        )) {
                            popularLookupRow(
                                title: row.value,
                                count: row.trialCount,
                                systemImage: "pills",
                                subtitle: row.typeLabel.isEmpty ? nil : row.typeLabel,
                                inFdaCatalog: row.inFdaCatalog
                            )
                        }
                        .buttonStyle(.plain)
                        if index < visible.count - 1 {
                            Divider().opacity(0.35)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .glassEffect(.regular, in: .rect(cornerRadius: 18, style: .continuous))

                if popularInterventions.count > 5 {
                    Button {
                        withAnimation(.smooth(duration: 0.25)) {
                            popularInterventionVisibleCount = popularInterventionVisibleCount > 5 ? 5 : 10
                        }
                    } label: {
                        Text(popularInterventionVisibleCount > 5 ? "Show less" : "Show more")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.borderless)
                    .padding(.top, 4)
                }
            }
        }
    }

    private func popularLookupRow(
        title: String,
        count: Int,
        systemImage: String,
        subtitle: String? = nil,
        inFdaCatalog: Bool = false
    ) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: systemImage)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 36, height: 36)
                .background(Color(.tertiarySystemFill), in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            if inFdaCatalog {
                FDAIndicator(interventionName: title)
            }

            Text(count.formatted())
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .accessibilityLabel(
            inFdaCatalog
            ? "\(title), in Drugs at FDA catalog, \(count) studies"
            : "\(title), \(count) studies"
        )
    }

    private func popularOrgRow(_ org: OrganisationSummary) -> some View {
        HStack(alignment: .center, spacing: 10) {
            OrganisationCategoryIcon(category: org.category)

            VStack(alignment: .leading, spacing: 4) {
                Text(org.displayName)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(org.classLabel)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 2) {
                Text("\(org.activeTrialCount.formatted()) active")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Text("\(org.recruitingTrialCount.formatted()) recruiting")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func popularSiteRow(_ site: SiteSummary) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "mappin.and.ellipse")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 36, height: 36)
                .background(Color(.tertiarySystemFill), in: Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(site.displayName)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(site.subtitle)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 2) {
                if site.includesNonRecruitingStudies {
                    Text("\(site.totalRelatedTrialCount.formatted()) total")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Text("\(site.recruitingTrialCount.formatted()) recruiting")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    // MARK: Saved searches

    private var savedSearchesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Saved searches")
                .font(.title2.bold())

            VStack(spacing: 0) {
                ForEach(Array(savedSearches.enumerated()), id: \.element.id) { index, row in
                    if let launch = SavedSearches.decode(row) {
                        NavigationLink(value: DiscoverRoute.trialSearchLaunch(launch)) {
                            savedSearchRow(row, launch: launch)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button {
                                renameDraft = row.name
                                renameSearch = row
                            } label: {
                                Label("Rename", systemImage: "pencil")
                            }
                            Button(role: .destructive) {
                                SavedSearches.delete(row, context: modelContext)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                    if index < savedSearches.count - 1 {
                        Divider().opacity(0.35)
                    }
                }
            }
            .padding(.horizontal, 8)
            .glassEffect(.regular, in: .rect(cornerRadius: 18, style: .continuous))
        }
    }

    private func savedSearchRow(_ row: SavedSearch, launch: SavedSearches.Launch) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.body.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 36, height: 36)
                .background(Color(.tertiarySystemFill), in: Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(row.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                if let subtitle = savedSearchSubtitle(launch) {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "chevron.forward")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(row.name)
    }

    private func savedSearchSubtitle(_ launch: SavedSearches.Launch) -> String? {
        var parts: [String] = []
        let q = launch.query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty { parts.append(q) }
        parts.append(contentsOf: launch.filter.activeChips.prefix(3).map { data.displayName(for: $0) })
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ")
    }

    // MARK: Favourites

    private var favouritesQueryToken: String {
        favouriteItems.map(\.identityKey).joined(separator: "|")
    }

    private var favouritesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Favourites")
                .font(.title2.bold())

            VStack(spacing: 0) {
                ForEach(Array(favouriteItems.enumerated()), id: \.element.id) { index, item in
                    favouriteRow(item)
                    if index < favouriteItems.count - 1 {
                        Divider().opacity(0.35)
                    }
                }
            }
            .padding(.horizontal, 8)
            .glassEffect(.regular, in: .rect(cornerRadius: 18, style: .continuous))
        }
    }

    private var favouriteOrgKeys: Set<String> {
        Set(favouriteOrgs.map(\.identityKey))
    }

    private var favouriteSiteKeys: Set<String> {
        Set(favouriteSites.map(\.identityKey))
    }

    @ViewBuilder
    private func favouriteRow(_ item: FavouriteItem) -> some View {
        let stats = favouriteStats[item.identityKey]
        switch item {
        case .organisation(let row):
            if let ref = row.ref {
                NavigationLink(value: OrganisationRoute(ref: ref)) {
                    favouriteRowContent(
                        title: row.displayName,
                        subtitle: stats?.subtitle,
                        kind: .organisation(stats?.category ?? .other),
                        active: stats?.activeCount,
                        recruiting: stats?.recruitingCount
                    )
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button(role: .destructive) {
                        _ = EntityFavourites.toggleOrganisation(
                            identityKey: row.identityKey,
                            displayName: row.displayName,
                            context: modelContext
                        )
                    } label: {
                        Label("Remove from Favourites", systemImage: "star.slash")
                    }
                }
            }
        case .site(let row):
            if let ref = row.ref {
                NavigationLink(value: SiteRoute(ref: ref)) {
                    favouriteRowContent(
                        title: row.displayName,
                        subtitle: stats?.subtitle,
                        kind: .site,
                        active: stats?.activeCount,
                        recruiting: stats?.recruitingCount
                    )
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button(role: .destructive) {
                        _ = EntityFavourites.toggleSite(
                            identityKey: row.identityKey,
                            displayName: row.displayName,
                            context: modelContext
                        )
                    } label: {
                        Label("Remove from Favourites", systemImage: "star.slash")
                    }
                }
            }
        }
    }

    private enum FavouriteRowKind {
        case organisation(OrganisationCategory)
        case site
    }

    private func favouriteRowContent(
        title: String,
        subtitle: String?,
        kind: FavouriteRowKind,
        active: Int?,
        recruiting: Int?
    ) -> some View {
        HStack(alignment: .center, spacing: 10) {
            switch kind {
            case .organisation(let category):
                OrganisationCategoryIcon(category: category)
            case .site:
                Image(systemName: "mappin.and.ellipse")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
                    .background(Color(.tertiarySystemFill), in: Circle())
                    .accessibilityLabel("Site")
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if active != nil || recruiting != nil {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\((active ?? 0).formatted()) active")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Text("\((recruiting ?? 0).formatted()) recruiting")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func loadFavouriteStats() async {
        await data.waitUntilReady()
        let items = favouriteItems
        guard !items.isEmpty else {
            favouriteStats = [:]
            return
        }

        var next: [String: FavouriteRowStats] = [:]
        await withTaskGroup(of: (String, FavouriteRowStats)?.self) { group in
            for item in items {
                group.addTask {
                    switch item {
                    case .organisation(let row):
                        guard let ref = row.ref,
                              let detail = await data.organisationDetail(ref: ref)
                        else { return nil }
                        let s = detail.summary
                        return (row.identityKey, FavouriteRowStats(
                            category: s.category,
                            subtitle: s.classLabel,
                            activeCount: s.activeTrialCount,
                            recruitingCount: s.recruitingTrialCount
                        ))
                    case .site(let row):
                        guard let ref = row.ref,
                              let detail = await data.siteDetail(ref: ref)
                        else { return nil }
                        let s = detail.summary
                        var active = s.totalRelatedTrialCount
                        if case .site(let id) = ref {
                            var filter = TrialFilter()
                            filter.siteId = String(id)
                            filter.activeOnly = true
                            active = await data.count(filter: filter)
                        }
                        let place = s.subtitle
                        return (row.identityKey, FavouriteRowStats(
                            category: nil,
                            subtitle: place.isEmpty ? nil : place,
                            activeCount: active,
                            recruitingCount: s.recruitingTrialCount
                        ))
                    }
                }
            }
            for await result in group {
                if let (key, stats) = result {
                    next[key] = stats
                }
            }
        }
        favouriteStats = next
    }

    // MARK: Recently viewed

    private var recentlyViewed: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Recently viewed")
                    .font(.title2.bold())
                Spacer(minLength: 8)
                Button("Clear") {
                    RecentlyViewed.clearAll(context: modelContext)
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.borderless)
            }

            FlowLayout(spacing: 8) {
                ForEach(recentItems, id: \.id) { item in
                    switch item {
                    case .organisation(let row):
                        if let ref = row.ref {
                            NavigationLink(value: OrganisationRoute(ref: ref)) {
                                chip(row.displayName)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                let isFav = favouriteOrgKeys.contains(row.identityKey)
                                Button {
                                    _ = EntityFavourites.toggleOrganisation(
                                        identityKey: row.identityKey,
                                        displayName: row.displayName,
                                        context: modelContext
                                    )
                                } label: {
                                    Label(
                                        isFav ? "Remove from Favourites" : "Add to Favourites",
                                        systemImage: isFav ? "star.slash" : "star"
                                    )
                                }
                                Button(role: .destructive) {
                                    RecentlyViewed.removeOrganisation(
                                        identityKey: row.identityKey,
                                        context: modelContext
                                    )
                                } label: {
                                    Label("Remove from Recently Viewed", systemImage: "eye.slash")
                                }
                            }
                        }
                    case .site(let row):
                        if let ref = row.ref {
                            NavigationLink(value: SiteRoute(ref: ref)) {
                                chip(row.displayName)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                let isFav = favouriteSiteKeys.contains(row.identityKey)
                                Button {
                                    _ = EntityFavourites.toggleSite(
                                        identityKey: row.identityKey,
                                        displayName: row.displayName,
                                        context: modelContext
                                    )
                                } label: {
                                    Label(
                                        isFav ? "Remove from Favourites" : "Add to Favourites",
                                        systemImage: isFav ? "star.slash" : "star"
                                    )
                                }
                                Button(role: .destructive) {
                                    RecentlyViewed.removeSite(
                                        identityKey: row.identityKey,
                                        context: modelContext
                                    )
                                } label: {
                                    Label("Remove from Recently Viewed", systemImage: "eye.slash")
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func chip(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: .capsule)
    }

    // MARK: Loading

    private var nearbyQueryToken: String {
        let city = profile?.preferredCity ?? ""
        let lat = profile?.preferredCityLatitude.map { String(format: "%.3f", $0) }
            ?? location.coordinate.map { String(format: "%.3f", $0.latitude) }
            ?? "-"
        let lon = profile?.preferredCityLongitude.map { String(format: "%.3f", $0) }
            ?? location.coordinate.map { String(format: "%.3f", $0.longitude) }
            ?? "-"
        return "\(city)|\(lat)|\(lon)|\(radiusMiles)"
    }

    private func loadLandscapeCounts() async {
        await data.waitUntilReady()
        async let orgs = data.organisationEntityCount()
        async let sites = data.siteEntityCount()
        async let conditions = data.discoverConditionCount()
        async let interventions = data.discoverInterventionCount()
        organisationCount = await orgs
        siteCount = await sites
        conditionCount = await conditions
        interventionCount = await interventions
    }

    private func loadPopularOrgs(limit: Int) async {
        isLoadingPopularOrgs = true
        await data.waitUntilReady()
        var rows = await data.popularOrganisations(limit: limit)
        if rows.isEmpty {
            rows = await data.organisations(category: .all, limit: limit)
        }
        popularOrgs = rows
        isLoadingPopularOrgs = false
    }

    private func loadPopularSites(limit: Int) async {
        isLoadingPopularSites = true
        await data.waitUntilReady()
        popularSites = await data.highActivitySites(limit: limit)
        isLoadingPopularSites = false
    }

    private func loadPopularConditions(limit: Int) async {
        isLoadingPopularConditions = true
        await data.waitUntilReady()
        guard data.supportsPopularCondition else {
            popularConditions = []
            isLoadingPopularConditions = false
            return
        }
        popularConditions = await data.popularConditions(limit: limit)
        isLoadingPopularConditions = false
    }

    private func loadPopularInterventions(limit: Int) async {
        isLoadingPopularInterventions = true
        await data.waitUntilReady()
        guard data.supportsPopularIntervention else {
            popularInterventions = []
            isLoadingPopularInterventions = false
            return
        }
        popularInterventions = await data.popularInterventions(limit: limit)
        isLoadingPopularInterventions = false
    }

    private func loadRecruitingCount() async {
        let anchor = profile?.nearbyAnchor
        let coordinate = anchor?.coordinate ?? location.coordinate
        guard let coordinate else {
            recruitingNearbyCount = nil
            return
        }
        await data.waitUntilReady()
        let radiusMeters = Double(radiusMiles) * NearbyDistance.metersPerMile
        let hits = await data.nearbyRecruiting(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            radiusMeters: radiusMeters,
            filter: TrialFilter(),
            countryHint: anchor?.countryHint ?? location.countryName,
            limit: 400
        )
        recruitingNearbyCount = hits.count
    }

    // MARK: Lists

    private struct FavouriteRowStats: Equatable {
        var category: OrganisationCategory?
        var subtitle: String?
        var activeCount: Int
        var recruitingCount: Int
    }

    private enum FavouriteItem: Identifiable {
        case organisation(FavouriteOrganisation)
        case site(FavouriteSite)

        var id: String {
            switch self {
            case .organisation(let row): return "fo:\(row.identityKey)"
            case .site(let row): return "fs:\(row.identityKey)"
            }
        }

        var identityKey: String {
            switch self {
            case .organisation(let row): return row.identityKey
            case .site(let row): return row.identityKey
            }
        }

        var favoritedAt: Date {
            switch self {
            case .organisation(let row): return row.favoritedAt
            case .site(let row): return row.favoritedAt
            }
        }
    }

    private enum RecentItem: Identifiable {
        case organisation(RecentlyViewedOrganisation)
        case site(RecentlyViewedSite)

        var id: String {
            switch self {
            case .organisation(let row): return "ro:\(row.identityKey)"
            case .site(let row): return "rs:\(row.identityKey)"
            }
        }

        var viewedAt: Date {
            switch self {
            case .organisation(let row): return row.viewedAt
            case .site(let row): return row.viewedAt
            }
        }
    }

    private var favouriteItems: [FavouriteItem] {
        (favouriteOrgs.map(FavouriteItem.organisation) + favouriteSites.map(FavouriteItem.site))
            .sorted { $0.favoritedAt > $1.favoritedAt }
    }

    private var recentItems: [RecentItem] {
        var seen = Set<String>()
        var orgs: [RecentlyViewedOrganisation] = []
        for row in recentlyViewedOrgs {
            guard seen.insert(row.identityKey).inserted else { continue }
            orgs.append(row)
            if orgs.count >= 8 { break }
        }
        seen.removeAll()
        var sites: [RecentlyViewedSite] = []
        for row in recentlyViewedSites {
            guard seen.insert(row.identityKey).inserted else { continue }
            sites.append(row)
            if sites.count >= 8 { break }
        }
        return (orgs.map(RecentItem.organisation) + sites.map(RecentItem.site))
            .sorted { $0.viewedAt > $1.viewedAt }
            .prefix(RecentlyViewed.discoverDisplayLimit)
            .map { $0 }
    }
}

// MARK: - Landscape card (Home-style box + action arrow)

private struct DiscoverLandscapeCard: View {
    let title: String
    let countText: String
    var systemImage: String = "arrow.up.right"

    /// Matches Home dashboard card height so counts + label breathe.
    private static let cardWidth: CGFloat = 132
    private static let cardHeight: CGFloat = 68

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(countText)
                    // Same size on every tile — do not scale down long counts.
                    .font(.title3.weight(.bold).monospacedDigit())
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText())
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: systemImage)
                    .font(.caption.weight(.semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            }
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: Self.cardWidth, height: Self.cardHeight, alignment: .topLeading)
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
    }
}
