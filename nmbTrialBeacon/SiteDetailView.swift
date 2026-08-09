//
//  SiteDetailView.swift
//  nmbTrialBeacon
//
//  Site profile mirrors OrganisationDetailView — same section order, cards,
//  and chrome so users don’t learn a second screen.
//

import CoreLocation
import SwiftData
import SwiftUI

struct SiteDetailView: View {
    let ref: SiteRef

    @Environment(TrialDataService.self) private var data
    @Environment(LocationService.self) private var location
    @Environment(\.modelContext) private var modelContext

    @State private var detail: SiteDetail?
    @State private var topConditions: [SiteConditionCount] = []
    @State private var leadOrgs: [SiteLeadOrganisation] = []
    @State private var recentStudies: [TrialSummary] = []
    @State private var recentPublications: [TrialPublication] = []
    @State private var nearbySites: [SiteSummary] = []
    @State private var distanceMeters: Double?
    @State private var activeTrialCount: Int?
    @State private var isLoading = true
    @State private var isFavourite = false
    @State private var orgsExpanded = false
    @State private var conditionsExpanded = false

    private static let listPreview = 5
    private static let listLimit = 10
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
                    "Site unavailable",
                    systemImage: "mappin.slash",
                    description: Text("This site is not in the current database.")
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
        .task(id: ref.identityKey) { await load() }
        .task { location.prepare() }
    }

    @ViewBuilder
    private func content(_ detail: SiteDetail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header(detail)
                summarySection(detail)
                if !leadOrgs.isEmpty {
                    topOrganisationsSection
                }
                if !topConditions.isEmpty {
                    topConditionsSection(detail)
                }
                if !nearbySites.isEmpty {
                    nearbySection
                }
                if !recentStudies.isEmpty || detail.summary.totalRelatedTrialCount > 0 {
                    recentTrialsSection(detail)
                }
                if detail.hasPublicationStats || !recentPublications.isEmpty {
                    publicationsSection(detail)
                }
            }
            .padding()
        }
        .navigationTitle(detail.summary.displayName)
    }

    // MARK: - Header

    private func header(_ detail: SiteDetail) -> some View {
        // Same two-column layout as Organisation: identity left, map bottom-right.
        HStack(alignment: .bottom, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(detail.summary.displayName)
                    .font(.title.weight(.bold))
                    .tracking(-0.3)
                    .minimumScaleFactor(0.88)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)

                if let cityState = Self.cityStateLine(detail.summary), !cityState.isEmpty {
                    Text(cityState)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                if let country = detail.summary.country, !country.isEmpty {
                    Text("\(CountryFlag.emoji(for: country)) \(country)")
                        .font(.subheadline.weight(.semibold))
                }

                if let distanceMeters {
                    Text(NearbyDistance.formatMiles(distanceMeters))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                } else if detail.summary.coordinate == nil {
                    Text("Location not mapped")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if detail.summary.coordinate != nil {
                NearbyMapPreview(
                    user: location.coordinate,
                    site: detail.summary.coordinate,
                    placeName: detail.summary.displayName,
                    height: mapSize
                )
                .frame(width: mapSize, height: mapSize)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private static func cityStateLine(_ summary: SiteSummary) -> String? {
        let parts = [summary.city, summary.state].compactMap { value -> String? in
            guard let value, !value.isEmpty else { return nil }
            return value
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    // MARK: - Summary (same 4-across pattern as Org / Recent Activity)

    private func summarySection(_ detail: SiteDetail) -> some View {
        let fullCounts = detail.summary.includesNonRecruitingStudies
        let cardSpacing: CGFloat = 10

        return VStack(alignment: .leading, spacing: 12) {
            Text("Summary")
                .font(.title2.bold())

            ViewThatFits(in: .horizontal) {
                HStack(spacing: cardSpacing) {
                    summaryCards(detail, fullCounts: fullCounts, flexible: true)
                }

                ScrollView(.horizontal) {
                    HStack(spacing: cardSpacing) {
                        summaryCards(detail, fullCounts: fullCounts, flexible: false)
                    }
                    .scrollTargetLayout()
                }
                .scrollIndicators(.hidden)
                .scrollTargetBehavior(.viewAligned)
            }

            if !fullCounts {
                Text("Recruiting studies only — full study totals need the site catalogue in the database.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func summaryCards(
        _ detail: SiteDetail,
        fullCounts: Bool,
        flexible: Bool
    ) -> some View {
        let width: CGFloat? = flexible ? nil : 118

        // Without the site catalogue, the on-device index only knows recruiting.
        if fullCounts {
            DashboardCard(
                title: "Total",
                count: detail.summary.totalRelatedTrialCount,
                icon: "doc.text",
                color: .accentColor,
                filter: siteFilter(detail),
                listTitle: detail.summary.displayName
            )
            .frame(width: width)
            .frame(maxWidth: flexible ? .infinity : nil)

            DashboardCard(
                title: "Active",
                count: activeTrialCount ?? detail.summary.recruitingTrialCount,
                icon: "bolt.fill",
                color: .orange,
                filter: {
                    var f = siteFilter(detail)
                    f.activeOnly = true
                    return f
                }(),
                listTitle: "\(detail.summary.displayName) · Active"
            )
            .frame(width: width)
            .frame(maxWidth: flexible ? .infinity : nil)
        }

        DashboardCard(
            title: "Recruiting",
            count: detail.summary.recruitingTrialCount,
            icon: "person.badge.plus",
            color: .green,
            filter: siteFilter(detail, status: "RECRUITING"),
            listTitle: "\(detail.summary.displayName) · Recruiting"
        )
        .frame(width: width)
        .frame(maxWidth: flexible ? .infinity : nil)

        DashboardCard(
            title: "Phase III",
            count: detail.summary.phase3TrialCount,
            icon: "flask",
            color: .indigo,
            filter: siteFilter(detail, phases: ["PHASE3", "PHASE2_PHASE3"]),
            listTitle: "\(detail.summary.displayName) · Phase III"
        )
        .frame(width: width)
        .frame(maxWidth: flexible ? .infinity : nil)
    }

    // MARK: - Top Organisations

    private var topOrganisationsSection: some View {
        let visible = Array(
            leadOrgs.prefix(orgsExpanded ? Self.listLimit : Self.listPreview)
        )
        let canExpand = leadOrgs.count > Self.listPreview

        return VStack(alignment: .leading, spacing: 12) {
            Text("Top Organisations")
                .font(.title2.bold())

            VStack(spacing: 0) {
                ForEach(Array(visible.enumerated()), id: \.element.id) { index, org in
                    Group {
                        if let organisationId = org.organisationId {
                            NavigationLink(value: OrganisationRoute(organisationId: organisationId)) {
                                orgRow(org, rank: index + 1)
                            }
                        } else if let name = org.leadSponsorName {
                            NavigationLink(value: OrganisationRoute(leadSponsor: name)) {
                                orgRow(org, rank: index + 1)
                            }
                        } else {
                            orgRow(org, rank: index + 1)
                        }
                    }
                    .buttonStyle(.plain)

                    if index < visible.count - 1 {
                        Divider().opacity(0.35)
                    }
                }

                if canExpand {
                    Button {
                        withAnimation(.smooth(duration: 0.2)) { orgsExpanded.toggle() }
                    } label: {
                        Text(orgsExpanded ? "Show less" : "Show more")
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

    private func orgRow(_ org: SiteLeadOrganisation, rank: Int) -> some View {
        HStack(spacing: 10) {
            Text("\(rank)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(rank == 1 ? .white : .secondary)
                .frame(width: 22, height: 22)
                .background(
                    rank == 1 ? Color.accentColor : Color(.tertiarySystemFill),
                    in: Circle()
                )
            Image(systemName: "building.2")
                .font(.body)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 22, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(org.displayName)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if !org.organisationClass.isEmpty {
                    Text(org.organisationClass.replacingOccurrences(of: "_", with: " ").capitalized)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Text(org.trialCount.formatted())
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    // MARK: - Top Conditions

    private func topConditionsSection(_ detail: SiteDetail) -> some View {
        let visible = Array(
            topConditions.prefix(
                conditionsExpanded ? Self.listLimit : Self.listPreview
            )
        )
        let canExpand = topConditions.count > Self.listPreview

        return VStack(alignment: .leading, spacing: 12) {
            Text("Top Conditions")
                .font(.title2.bold())

            VStack(spacing: 0) {
                ForEach(Array(visible.enumerated()), id: \.element.id) { index, row in
                    NavigationLink(value: TrialListRequest(
                        title: row.condition,
                        filter: siteFilter(detail, condition: row.condition)
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
                            conditionsExpanded.toggle()
                        }
                    } label: {
                        Text(conditionsExpanded ? "Show less" : "Show more")
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

    // MARK: - Nearby

    private var nearbySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Nearby")
                .font(.title2.bold())

            VStack(spacing: 0) {
                ForEach(Array(nearbySites.prefix(3).enumerated()), id: \.element.id) { index, site in
                    NavigationLink(value: SiteRoute(ref: site.ref)) {
                        HStack(spacing: 10) {
                            Image(systemName: "mappin.and.ellipse")
                                .font(.body)
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(.secondary)
                                .frame(width: 22, alignment: .center)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(site.displayName)
                                    .font(.subheadline)
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)
                                if let label = site.distanceLabel {
                                    Text(label)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if index < min(2, nearbySites.count - 1) {
                        Divider().opacity(0.35)
                    }
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

    // MARK: - Recent Trials

    private func recentTrialsSection(_ detail: SiteDetail) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent Trials")
                .font(.title2.bold())

            VStack(spacing: 0) {
                if recentStudies.isEmpty {
                    Text(isLoading ? "Loading studies…" : "Open the full list to browse studies at this site.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 12)
                } else {
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
                }

                NavigationLink(value: TrialListRequest(
                    title: detail.summary.displayName,
                    filter: siteFilter(detail)
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

    // MARK: - Publications (schema v13; live join or precomputed site counters)

    private var showsSeeAllPublications: Bool {
        if let detail, detail.linkedPublicationCount > Self.publicationPreviewLimit {
            return true
        }
        return recentPublications.count >= Self.publicationPreviewLimit
    }

    private func publicationsSection(_ detail: SiteDetail) -> some View {
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
                                SitePublicationsListView(
                                    ref: detail.summary.ref,
                                    siteName: detail.summary.displayName,
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

                Text("From ClinicalTrials.gov references on studies that ran at this site — not this site’s full research output. Open access reflects OpenAlex enrichment from the database build. Tap a title to open an external source when available.")
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

    private func seeAllPublicationsLabel(for detail: SiteDetail) -> String {
        if detail.linkedPublicationCount > Self.publicationPreviewLimit {
            return "See all \(detail.linkedPublicationCount.formatted()) publications"
        }
        return "See all publications"
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

    // MARK: - Helpers

    private func siteFilter(
        _ detail: SiteDetail,
        status: String? = nil,
        phase: String? = nil,
        phases: Set<String> = [],
        condition: String? = nil
    ) -> TrialFilter {
        var f = TrialFilter()
        switch detail.summary.ref {
        case .site(let id):
            f.siteId = String(id)
        case .raw:
            f.siteKey = detail.summary.ref.softKey
        }
        f.status = status
        f.phase = phase
        f.phases = phases
        if let condition { f.conditions = [condition] }
        return f
    }

    private func load() async {
        isLoading = true
        orgsExpanded = false
        conditionsExpanded = false
        await data.waitUntilReady()

        // Summary first so the page leaves the spinner once the index is ready.
        detail = await data.siteDetail(ref: ref)
        isFavourite = EntityFavourites.isFavouriteSite(
            identityKey: ref.identityKey, context: modelContext
        )
        if let detail { recordView(detail.summary) }
        // Leave the full-screen spinner; sections fill in below.
        isLoading = false

        async let c = data.siteTopConditions(ref: ref, limit: Self.listLimit)
        async let o = data.siteLeadOrganisations(ref: ref, limit: Self.listLimit)
        async let r = data.siteRecentStudies(ref: ref, limit: 5)
        async let pubs = data.siteRecentPublications(ref: ref, limit: Self.publicationPreviewLimit)
        async let pubCounts = data.sitePublicationCounts(ref: ref)
        topConditions = await c
        leadOrgs = await o
        recentStudies = await r
        recentPublications = await pubs
        let counts = await pubCounts
        if var updated = detail {
            // Refresh counts after first paint (live join when site columns absent).
            updated.linkedPublicationCount = counts.linked
            updated.openAccessPublicationCount = counts.openAccess
            detail = updated
        }

        if let detail, detail.summary.includesNonRecruitingStudies {
            var filter = siteFilter(detail)
            filter.activeOnly = true
            activeTrialCount = await data.count(filter: filter)
        } else {
            activeTrialCount = nil
        }

        if let detail {
            if let user = location.coordinate,
               let site = detail.summary.coordinate {
                distanceMeters = NearbyDistance.meters(
                    from: user.latitude, lon1: user.longitude,
                    to: site.latitude, lon2: site.longitude
                )
                let radius = 25 * NearbyDistance.metersPerMile
                let hits = await data.nearbySites(
                    latitude: site.latitude,
                    longitude: site.longitude,
                    radiusMeters: radius,
                    limit: 8
                )
                nearbySites = hits.filter { $0.ref.identityKey != ref.identityKey }
            } else {
                distanceMeters = nil
                nearbySites = []
            }
        }
    }

    private func toggleFavourite() {
        let name = detail?.summary.displayName ?? ref.identityKey
        isFavourite = EntityFavourites.toggleSite(
            identityKey: ref.identityKey,
            displayName: name,
            context: modelContext
        )
    }

    private func recordView(_ summary: SiteSummary) {
        RecentlyViewed.recordSite(
            identityKey: summary.ref.identityKey,
            displayName: summary.displayName,
            context: modelContext
        )
    }
}

// MARK: - Site publications list

/// Full (capped) publication list for a site — destination from “See all”.
struct SitePublicationsListView: View {
    let ref: SiteRef
    let siteName: String
    /// Precomputed or live-joined linked count when available (0 if unknown).
    var expectedCount: Int = 0

    @Environment(TrialDataService.self) private var data
    @State private var publications: [TrialPublication] = []
    @State private var isLoading = true

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
                    description: Text("No ClinicalTrials.gov references are linked to studies at this site in the current database.")
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
        .navigationSubtitle(siteName)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: ref.identityKey) {
            isLoading = true
            await data.waitUntilReady()
            publications = await data.siteRecentPublications(ref: ref, limit: Self.listLimit)
            isLoading = false
        }
    }

    private var wasTruncated: Bool {
        expectedCount > Self.listLimit || publications.count >= Self.listLimit
    }
}
