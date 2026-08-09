//
//  OrganisationDetailView.swift
//  nmbTrialBeacon
//

import MapKit
import SwiftData
import SwiftUI

struct OrganisationDetailView: View {
    let ref: OrganisationRef

    @Environment(TrialDataService.self) private var data
    @Environment(\.modelContext) private var modelContext

    @State private var detail: OrganisationDetail?
    @State private var topConditions: [OrganisationConditionCount] = []
    @State private var countries: [OrganisationCountryCount] = []
    @State private var recentStudies: [TrialSummary] = []
    @State private var recentPublications: [TrialPublication] = []
    @State private var uniqueSiteCount: Int?
    @State private var hqCoordinate: CLLocationCoordinate2D?
    /// Pin / Apple Maps label — organisation name when resolved, not just the city.
    @State private var hqMapsName: String?
    @State private var isLoading = true
    @State private var isFavourite = false
    @State private var researchFocusExpanded = false

    private static let researchFocusPreview = 5
    private static let researchFocusLimit = 10
    private static let publicationPreviewLimit = 10
    private let mapSize: CGFloat = 88

    var body: some View {
        Group {
            if isLoading && detail == nil {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let detail {
                content(detail)
            } else {
                ContentUnavailableView(
                    "Organisation unavailable",
                    systemImage: "building.2",
                    description: Text("This organisation is not in the current database.")
                )
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if detail != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        toggleFavourite()
                    } label: {
                        Image(systemName: isFavourite ? "star.fill" : "star")
                    }
                    .accessibilityLabel(isFavourite ? "Remove from favourites" : "Add to favourites")
                }
            }
        }
        .task(id: ref.identityKey) {
            await load()
        }
    }

    @ViewBuilder
    private func content(_ detail: OrganisationDetail) -> some View {
        // ScrollView (not List) so Summary / Activity DashboardCards don't pick up
        // List disclosure chevrons or double-push on the navigation stack.
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header(detail)
                summarySection(detail)
                recentActivitySection(detail)
                if !topConditions.isEmpty {
                    researchFocusSection(detail)
                }
                if detail.countryCount > 0 || (detail.siteCount ?? 0) > 0 || !countries.isEmpty {
                    footprintSection(detail)
                }
                if !recentStudies.isEmpty {
                    recentTrialsSection(detail)
                }
                if detail.hasPublicationStats || !recentPublications.isEmpty {
                    publicationsSection(detail)
                }
                if detail.leadSponsorTrialCount > 0 || detail.collaboratorTrialCount > 0 {
                    researchRolesSection(detail)
                }
            }
            .padding()
        }
        .navigationTitle(detail.summary.displayName)
    }

    private func header(_ detail: OrganisationDetail) -> some View {
        let hq = detail.headquarters.flatMap { $0.isEmpty ? nil : $0 }

        return HStack(alignment: .bottom, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(detail.summary.displayName)
                    // Slightly tighter than `.largeTitle` so long names (NCI) don’t
                    // dominate three full lines — still hero-level, SF Symbol only.
                    .font(.title.weight(.bold))
                    .tracking(-0.3)
                    .minimumScaleFactor(0.88)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)

                Text(detail.summary.classLabel.uppercased())
                    .font(.caption.weight(.semibold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)

                if let hq {
                    if let country = hq.country {
                        Text("\(CountryFlag.emoji(for: country)) \(country)")
                            .font(.subheadline.weight(.semibold))
                    }
                    if let locality = hq.localityLine {
                        Text(locality)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    if hq.hasWebsite, let raw = hq.website, let url = Self.websiteURL(raw) {
                        Link(destination: url) {
                            Label(Self.websiteLabel(raw), systemImage: "link")
                                .font(.subheadline.weight(.semibold))
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let hq, hq.isMappable {
                NearbyMapPreview(
                    user: nil,
                    site: hqCoordinate,
                    placeName: hqMapsName ?? detail.summary.displayName,
                    height: mapSize
                )
                .frame(width: mapSize, height: mapSize)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private static func websiteURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), url.scheme != nil { return url }
        return URL(string: "https://\(trimmed)")
    }

    private static func websiteLabel(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let host = URL(string: trimmed)?.host, !host.isEmpty { return host }
        if let host = URL(string: "https://\(trimmed)")?.host, !host.isEmpty { return host }
        return trimmed
    }

    private func geocodeHeadquarters(name: String, hq: OrganisationHeadquarters?) async {
        hqCoordinate = nil
        hqMapsName = name
        guard let hq else { return }

        // 1) “Pfizer, New York City, United States” — prefer a real POI hit.
        if let query = hq.geocodeQuery(organisationName: name),
           let item = await Self.geocodeMapItem(query) {
            hqCoordinate = item.location.coordinate
            hqMapsName = Self.mapItemName(item) ?? name
            return
        }

        // 2) City centre, then local search for the organisation nearby.
        guard let locality = hq.localityGeocodeQuery,
              let cityItem = await Self.geocodeMapItem(locality)
        else { return }
        let cityCoordinate = cityItem.location.coordinate
        if let poi = await Self.localSearchMapItem(
            query: name,
            near: cityCoordinate
        ) {
            hqCoordinate = poi.location.coordinate
            hqMapsName = Self.mapItemName(poi) ?? name
            return
        }

        // Last resort: city pin still labelled with the organisation.
        hqCoordinate = cityCoordinate
        hqMapsName = name
    }

    private static func mapItemName(_ item: MKMapItem) -> String? {
        let name = item.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? nil : name
    }

    private static func geocodeMapItem(_ address: String) async -> MKMapItem? {
        guard let request = MKGeocodingRequest(addressString: address) else { return nil }
        return try? await request.mapItems.first
    }

    private static func localSearchMapItem(
        query: String,
        near coordinate: CLLocationCoordinate2D
    ) async -> MKMapItem? {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = [.pointOfInterest, .address]
        request.region = MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.35, longitudeDelta: 0.35)
        )
        return try? await MKLocalSearch(request: request).start().mapItems.first
    }

    // MARK: - Summary (same 4-across pattern as Recent Activity)

    private func summarySection(_ detail: OrganisationDetail) -> some View {
        let cardSpacing: CGFloat = 10

        return VStack(alignment: .leading, spacing: 12) {
            Text("Summary")
                .font(.title2.bold())

            ViewThatFits(in: .horizontal) {
                HStack(spacing: cardSpacing) {
                    summaryCards(detail, flexible: true)
                }

                ScrollView(.horizontal) {
                    HStack(spacing: cardSpacing) {
                        summaryCards(detail, flexible: false)
                    }
                    .scrollTargetLayout()
                }
                .scrollIndicators(.hidden)
                .scrollTargetBehavior(.viewAligned)
            }
        }
    }

    @ViewBuilder
    private func summaryCards(_ detail: OrganisationDetail, flexible: Bool) -> some View {
        let width: CGFloat? = flexible ? nil : 118
        DashboardCard(
            title: "Total",
            count: detail.summary.totalRelatedTrialCount,
            icon: "doc.text",
            color: .accentColor,
            filter: orgFilter(detail),
            listTitle: detail.summary.displayName
        )
        .frame(width: width)
        .frame(maxWidth: flexible ? .infinity : nil)

        DashboardCard(
            title: "Active",
            count: detail.summary.activeTrialCount,
            icon: "bolt.fill",
            color: .orange,
            filter: {
                var f = orgFilter(detail)
                f.activeOnly = true
                return f
            }(),
            listTitle: "\(detail.summary.displayName) · Active"
        )
        .frame(width: width)
        .frame(maxWidth: flexible ? .infinity : nil)

        DashboardCard(
            title: "Recruiting",
            count: detail.summary.recruitingTrialCount,
            icon: "person.badge.plus",
            color: .green,
            filter: orgFilter(detail, status: "RECRUITING"),
            listTitle: "\(detail.summary.displayName) · Recruiting"
        )
        .frame(width: width)
        .frame(maxWidth: flexible ? .infinity : nil)

        DashboardCard(
            title: "Phase III",
            count: detail.phase3TrialCount,
            icon: "flask",
            color: .indigo,
            filter: orgFilter(detail, phases: ["PHASE3", "PHASE2_PHASE3"]),
            listTitle: "\(detail.summary.displayName) · Phase III"
        )
        .frame(width: width)
        .frame(maxWidth: flexible ? .infinity : nil)
    }

    // MARK: - Recent Activity (same 4 home boxes)

    private func recentActivitySection(_ detail: OrganisationDetail) -> some View {
        let cardSpacing: CGFloat = 10

        return VStack(alignment: .leading, spacing: 8) {
            Text("Recent Activity")
                .font(.title2.bold())

            ViewThatFits(in: .horizontal) {
                HStack(spacing: cardSpacing) {
                    activityCards(detail, flexible: true)
                }

                ScrollView(.horizontal) {
                    HStack(spacing: cardSpacing) {
                        activityCards(detail, flexible: false)
                    }
                    .scrollTargetLayout()
                }
                .scrollIndicators(.hidden)
                .scrollTargetBehavior(.viewAligned)
            }

            Text("Last 30 days · based on first-posted / last-updated dates with current status — not proven status transitions.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func activityCards(_ detail: OrganisationDetail, flexible: Bool) -> some View {
        let width: CGFloat? = flexible ? nil : 118
        DashboardCard(
            title: "New",
            count: detail.newTrialCount30d,
            icon: "sparkles",
            color: .teal,
            filter: {
                var f = orgFilter(detail)
                f.firstPostedWithinDays = 30
                return f
            }(),
            sort: .firstPostedDesc,
            listTitle: "\(detail.summary.displayName) · New"
        )
        .frame(width: width)
        .frame(maxWidth: flexible ? .infinity : nil)

        DashboardCard(
            title: "Recruiting",
            count: detail.recentlyUpdatedRecruitingCount30d,
            icon: "person.badge.plus",
            color: .green,
            filter: {
                var f = orgFilter(detail, status: "RECRUITING")
                f.lastUpdatedWithinDays = 30
                return f
            }(),
            listTitle: "\(detail.summary.displayName) · Recruiting"
        )
        .frame(width: width)
        .frame(maxWidth: flexible ? .infinity : nil)

        DashboardCard(
            title: "Completed",
            count: detail.recentlyUpdatedCompletedCount30d,
            icon: "checkmark.circle",
            color: .blue,
            filter: {
                var f = orgFilter(detail, status: "COMPLETED")
                f.lastUpdatedWithinDays = 30
                return f
            }(),
            listTitle: "\(detail.summary.displayName) · Completed"
        )
        .frame(width: width)
        .frame(maxWidth: flexible ? .infinity : nil)

        DashboardCard(
            title: "Terminated",
            count: detail.recentlyUpdatedTerminatedCount30d,
            icon: "xmark.circle",
            color: .orange,
            filter: {
                var f = orgFilter(detail, status: "TERMINATED")
                f.lastUpdatedWithinDays = 30
                return f
            }(),
            listTitle: "\(detail.summary.displayName) · Terminated"
        )
        .frame(width: width)
        .frame(maxWidth: flexible ? .infinity : nil)
    }

    // MARK: - Research Focus

    private func researchFocusSection(_ detail: OrganisationDetail) -> some View {
        let visible = Array(
            topConditions.prefix(
                researchFocusExpanded ? Self.researchFocusLimit : Self.researchFocusPreview
            )
        )
        let canExpand = topConditions.count > Self.researchFocusPreview

        return VStack(alignment: .leading, spacing: 12) {
            Text("Top Conditions")
                .font(.title2.bold())

            VStack(spacing: 0) {
                ForEach(Array(visible.enumerated()), id: \.element.id) { index, row in
                    NavigationLink(value: TrialListRequest(
                        title: row.condition,
                        filter: orgFilter(detail, condition: row.condition)
                    )) {
                        HStack(spacing: 10) {
                            Text("\(index + 1)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(index == 0 ? .white : .secondary)
                                .frame(width: 22, height: 22)
                                .background(
                                    index == 0 ? Color.accentColor : Color(.tertiarySystemFill),
                                    in: Circle()
                                )
                            ConditionDomainIcon(condition: row.condition)
                                .font(.body)
                                .foregroundStyle(.secondary)
                                .frame(width: 22, alignment: .center)
                            Text(row.condition)
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                            Text(row.trialCount.formatted())
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if index < visible.count - 1 {
                        Divider().opacity(0.35)
                    }
                }

                if canExpand {
                    Button {
                        withAnimation(.smooth(duration: 0.2)) {
                            researchFocusExpanded.toggle()
                        }
                    } label: {
                        Text(researchFocusExpanded ? "Show less" : "Show more")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.borderless)
                    .padding(.top, 10)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color(.secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
        }
    }

    // MARK: - Footprint

    private func footprintSection(_ detail: OrganisationDetail) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Study Footprint")
                .font(.title2.bold())

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 16) {
                    if detail.countryCount > 0 {
                        footprintStat(value: detail.countryCount, label: "Countries")
                    }
                    if let unique = uniqueSiteCount, unique > 0 {
                        footprintStat(value: unique, label: "Sites")
                    } else if let instances = detail.siteCount, instances > 0 {
                        // `organisation.site_count` = SUM(location_count) — not unique.
                        footprintStat(value: instances, label: "Study Sites")
                    }
                    Spacer(minLength: 0)
                }

                if uniqueSiteCount == nil, let instances = detail.siteCount, instances > 0 {
                    Text("Study Sites counts every participating facility row across trials, not unique locations.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !countries.isEmpty {
                    FlowLayout(spacing: 8) {
                        ForEach(countries.prefix(10)) { row in
                            NavigationLink(value: TrialListRequest(
                                title: "\(detail.summary.displayName) · \(row.country)",
                                filter: orgFilter(detail, country: row.country)
                            )) {
                                Text("\(CountryFlag.emoji(for: row.country)) \(row.country) · \(row.trialCount.formatted())")
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 7)
                                    .background(Color(.tertiarySystemFill), in: Capsule())
                                    .foregroundStyle(.primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Text("Tap a country to see this organisation’s studies there.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color(.secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
        }
    }

    // MARK: - Recent Trials

    private func recentTrialsSection(_ detail: OrganisationDetail) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent Trials")
                .font(.title2.bold())

            VStack(spacing: 0) {
                ForEach(Array(recentStudies.enumerated()), id: \.element.id) { index, trial in
                    NavigationLink(value: trial.nctId) {
                        TrialSummaryRow(summary: trial, chrome: .plain)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)

                    if index < recentStudies.count - 1 {
                        Divider().opacity(0.35)
                    }
                }

                NavigationLink(value: TrialListRequest(
                    title: detail.summary.displayName,
                    filter: orgFilter(detail)
                )) {
                    Text("See all studies")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color(.secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
        }
    }

    // MARK: - Publications (schema v13)

    private var showsSeeAllPublications: Bool {
        if let detail, detail.linkedPublicationCount > Self.publicationPreviewLimit {
            return true
        }
        return recentPublications.count >= Self.publicationPreviewLimit
    }

    private func publicationsSection(_ detail: OrganisationDetail) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Publications")
                .font(.title2.bold())

            VStack(alignment: .leading, spacing: 12) {
                if detail.hasPublicationStats {
                    HStack(spacing: 16) {
                        if detail.linkedPublicationCount > 0 {
                            footprintStat(value: detail.linkedPublicationCount, label: "Linked")
                        }
                        if detail.openAccessPublicationCount > 0 {
                            footprintStat(value: detail.openAccessPublicationCount, label: "Open access")
                        }
                        Spacer(minLength: 0)
                    }
                }

                if !recentPublications.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(recentPublications.enumerated()), id: \.element.id) { index, pub in
                            PublicationRow(publication: pub, showsReferenceType: false)
                            if index < recentPublications.count - 1 {
                                Divider().padding(.vertical, 10)
                            }
                        }

                        if showsSeeAllPublications {
                            NavigationLink {
                                OrganisationPublicationsListView(
                                    ref: detail.summary.ref,
                                    organisationName: detail.summary.displayName,
                                    expectedCount: detail.linkedPublicationCount
                                )
                            } label: {
                                Text(seeAllPublicationsLabel(for: detail))
                                    .font(.subheadline.weight(.semibold))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.top, 12)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Text("From ClinicalTrials.gov references on this organisation’s studies — not its full research output. Open access reflects OpenAlex enrichment from the database build. Tap a title to open an external source when available.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color(.secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
        }
    }

    private func seeAllPublicationsLabel(for detail: OrganisationDetail) -> String {
        if detail.linkedPublicationCount > Self.publicationPreviewLimit {
            return "See all \(detail.linkedPublicationCount.formatted()) publications"
        }
        return "See all publications"
    }

    // MARK: - Research Roles

    private func researchRolesSection(_ detail: OrganisationDetail) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Research Roles")
                .font(.title2.bold())

            VStack(spacing: 0) {
                if detail.leadSponsorTrialCount > 0 {
                    NavigationLink(value: TrialListRequest(
                        title: "\(detail.summary.displayName) · Lead",
                        filter: orgFilter(detail, role: .leadSponsor)
                    )) {
                        metricRow("Lead sponsor", value: detail.leadSponsorTrialCount)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.plain)

                    if detail.collaboratorTrialCount > 0 {
                        Divider().opacity(0.35)
                    }
                }
                if detail.collaboratorTrialCount > 0 {
                    NavigationLink(value: TrialListRequest(
                        title: "\(detail.summary.displayName) · Collaborator",
                        filter: orgFilter(detail, role: .collaborator)
                    )) {
                        metricRow("Collaborator", value: detail.collaboratorTrialCount)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color(.secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
        }
    }

    private func footprintStat(value: Int, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value.formatted())
                .font(.title2.weight(.bold).monospacedDigit())
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func metricRow(_ title: String, value: Int) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.primary)
            Spacer()
            Text("\(value.formatted()) studies")
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private enum OrgRoleFilter { case leadSponsor, collaborator }

    private func orgFilter(
        _ detail: OrganisationDetail,
        role: OrgRoleFilter? = nil,
        status: String? = nil,
        phase: String? = nil,
        phases: Set<String> = [],
        condition: String? = nil,
        country: String? = nil
    ) -> TrialFilter {
        var f = TrialFilter()
        switch detail.summary.ref {
        case .organisation(let id):
            f.organisationId = String(id)
            switch role {
            case .leadSponsor: f.organisationRole = "lead_sponsor"
            case .collaborator: f.organisationRole = "collaborator"
            case nil: break
            }
        case .leadSponsor(let name):
            f.leadSponsor = name
        case .collaborator(let id):
            f.collaborators = [String(id)]
        }
        f.status = status
        f.phase = phase
        f.phases = phases
        f.country = country
        if let condition { f.conditions = [condition] }
        return f
    }

    private func load() async {
        isLoading = true
        researchFocusExpanded = false
        await data.waitUntilReady()
        async let d = data.organisationDetail(ref: ref)
        async let c = data.organisationTopConditions(ref: ref, limit: Self.researchFocusLimit)
        async let co = data.organisationCountries(ref: ref, limit: 12)
        async let r = data.organisationRecentStudies(ref: ref, limit: 5)
        async let pubs = data.organisationRecentPublications(ref: ref, limit: Self.publicationPreviewLimit)
        async let sites = data.organisationUniqueSiteCount(ref: ref)
        detail = await d
        topConditions = await c
        countries = await co
        recentStudies = await r
        recentPublications = await pubs
        uniqueSiteCount = await sites
        isFavourite = EntityFavourites.isFavouriteOrganisation(
            identityKey: ref.identityKey, context: modelContext
        )
        isLoading = false
        if let detail {
            recordView(detail.summary)
            await geocodeHeadquarters(
                name: detail.summary.displayName,
                hq: detail.headquarters
            )
        } else {
            hqCoordinate = nil
            hqMapsName = nil
        }
    }

    private func toggleFavourite() {
        let name = detail?.summary.displayName ?? ref.identityKey
        isFavourite = EntityFavourites.toggleOrganisation(
            identityKey: ref.identityKey,
            displayName: name,
            context: modelContext
        )
    }

    private func recordView(_ summary: OrganisationSummary) {
        RecentlyViewed.recordOrganisation(
            identityKey: summary.ref.identityKey,
            displayName: summary.displayName,
            context: modelContext
        )
    }
}

// MARK: - Organisation publications list

/// Full (capped) publication list for an organisation — destination from “See all”.
struct OrganisationPublicationsListView: View {
    let ref: OrganisationRef
    let organisationName: String
    /// Precomputed `organisation.linked_publication_count` when available (0 if unknown).
    var expectedCount: Int = 0

    @Environment(TrialDataService.self) private var data
    @State private var publications: [TrialPublication] = []
    @State private var isLoading = true

    /// Hard cap so huge orgs stay responsive; matches generator “distinct CTG refs” spirit.
    private static let listLimit = 200

    var body: some View {
        Group {
            if isLoading && publications.isEmpty {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if publications.isEmpty {
                ContentUnavailableView(
                    "No publications",
                    systemImage: "doc.richtext",
                    description: Text("No ClinicalTrials.gov references are linked to this organisation’s studies in the current database.")
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(publications.enumerated()), id: \.element.id) { index, pub in
                            PublicationRow(publication: pub, showsReferenceType: false)
                                .padding(.vertical, 4)
                            if index < publications.count - 1 {
                                Divider().padding(.vertical, 10)
                            }
                        }

                        if wasTruncated {
                            Text("Showing the \(Self.listLimit.formatted()) most recent. \(expectedCount.formatted()) linked in this database.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.top, 16)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                    )
                    .padding()
                }
                .background(Color(.systemGroupedBackground))
            }
        }
        .navigationTitle("Publications")
        .navigationSubtitle(organisationName)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: ref.identityKey) {
            isLoading = true
            await data.waitUntilReady()
            publications = await data.organisationRecentPublications(
                ref: ref,
                limit: Self.listLimit
            )
            isLoading = false
        }
    }

    private var wasTruncated: Bool {
        expectedCount > Self.listLimit || publications.count >= Self.listLimit
    }
}
