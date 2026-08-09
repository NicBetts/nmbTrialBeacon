//
//  NearbyStudiesView.swift
//  nmbTrialBeacon
//
//  Home “Recruiting Near You” card + full Nearby Studies map/list screen.
//

import MapKit
import SwiftData
import SwiftUI

// MARK: - Home section

struct HomeRecruitingNearYouSection: View {
    let spotlight: NearbyTrial
    @Environment(LocationService.self) private var location

    /// Match On This Day / Interesting photo-band height.
    private let mapHeight: CGFloat = 100
    private let titleBlockHeight: CGFloat = 40

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recruiting Near You")
                .font(.title2.bold())

            NavigationLink(value: NearbyStudiesRoute(focusedNctId: spotlight.trial.nctId)) {
                VStack(alignment: .leading, spacing: 0) {
                    ZStack(alignment: .bottomLeading) {
                        heroMap
                            .frame(maxWidth: .infinity)
                            .frame(height: mapHeight)
                            .clipped()

                        LinearGradient(
                            colors: [.black.opacity(0.45), .clear],
                            startPoint: .bottom,
                            endPoint: .top
                        )
                        .allowsHitTesting(false)

                        Text(spotlight.distanceLabel)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                            .padding(12)
                    }
                    .frame(height: mapHeight)
                    .clipped()

                    VStack(alignment: .leading, spacing: 6) {
                        Text(spotlight.trial.briefTitle)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, minHeight: titleBlockHeight, alignment: .topLeading)

                        StatusBadge(status: spotlight.trial.statusDisplay)

                        Text(spotlight.siteLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(EdgeInsets(top: 12, leading: 16, bottom: 16, trailing: 16))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemGroupedBackground))
                }
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            .trialWatchlistContextMenu(nctId: spotlight.trial.nctId)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "\(spotlight.trial.briefTitle), \(spotlight.trial.statusDisplay), \(spotlight.siteLabel), \(spotlight.distanceLabel)"
            )
        }
    }

    @ViewBuilder
    private var heroMap: some View {
        let userCoordinate = location.coordinate
        if let region = mapRegion(user: userCoordinate) {
            Map(initialPosition: .region(region), interactionModes: []) {
                if let userCoordinate {
                    Annotation("", coordinate: userCoordinate, anchor: .center) {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 12, height: 12)
                            .overlay(Circle().stroke(.white, lineWidth: 2))
                    }
                }
                if let site = spotlight.site.coordinate {
                    Annotation("", coordinate: site, anchor: .center) {
                        ZStack {
                            Circle()
                                .fill(Color.green.opacity(0.28))
                                .frame(width: 36, height: 36)
                            Circle()
                                .fill(Color.green)
                                .frame(width: 14, height: 14)
                                .overlay(Circle().stroke(.white, lineWidth: 2))
                        }
                    }
                }
            }
            .mapStyle(.standard(elevation: .realistic))
            .mapControlVisibility(.hidden)
            .allowsHitTesting(false)
        } else {
            Rectangle()
                .fill(Color(.tertiarySystemFill))
                .overlay {
                    Image(systemName: "map")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                }
        }
    }

    private func mapRegion(user: CLLocationCoordinate2D?) -> MKCoordinateRegion? {
        let site = spotlight.site.coordinate
        let points = [user, site].compactMap { $0 }
        guard !points.isEmpty else { return nil }
        if points.count == 1 {
            return MKCoordinateRegion(
                center: points[0],
                span: MKCoordinateSpan(latitudeDelta: 0.08, longitudeDelta: 0.08)
            )
        }
        let lats = points.map(\.latitude)
        let lons = points.map(\.longitude)
        let center = CLLocationCoordinate2D(
            latitude: (lats.min()! + lats.max()!) / 2,
            longitude: (lons.min()! + lons.max()!) / 2
        )
        return MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(
                latitudeDelta: max(0.04, (lats.max()! - lats.min()!) * 2.8),
                longitudeDelta: max(0.04, (lons.max()! - lons.min()!) * 2.8)
            )
        )
    }
}

/// Typed push value so the Home `LazyVStack` does not use destination-style links.
struct NearbyStudiesRoute: Hashable, Identifiable {
    /// NCT to select on the map/list when opening from Home’s spotlight card.
    var focusedNctId: String?
    /// When set, search around this place instead of the device location.
    var anchor: NearbyAnchor? = nil

    var id: String {
        "\(focusedNctId ?? "")|\(anchor?.label ?? "")|\(anchor?.latitude ?? 0)|\(anchor?.longitude ?? 0)"
    }
}

// MARK: - Full screen

struct NearbyStudiesView: View {
    var focusedNctId: String? = nil
    var initialAnchor: NearbyAnchor? = nil

    @Environment(TrialDataService.self) private var data
    @Environment(AIMatchingService.self) private var ai
    @Environment(LocationService.self) private var location
    @Environment(\.modelContext) private var modelContext

    @AppStorage("nearbyRadiusMiles") private var radiusMiles = LocationService.defaultRadiusMiles
    @AppStorage("smartRecommendationsEnabled") private var smartRecommendationsEnabled = true

    @State private var filter = TrialFilter(status: "RECRUITING")
    @State private var results: [NearbyTrial] = []
    @State private var isLoading = true
    @State private var showingFilters = false
    @State private var showingPlacePicker = false
    @State private var profile: UserProfile?
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var filterEpoch = 0
    /// Shared selection for map pins ↔ list rows (NCT id).
    @State private var selectedNctId: String?
    @State private var pendingFocusNctId: String?
    @State private var confirmOpenInMaps = false
    /// When a profile exists, user can switch relevance ranking ↔ nearest-first.
    @State private var preferNearest = false
    /// Custom search centre; `nil` uses device location.
    @State private var anchor: NearbyAnchor?

    var body: some View {
        VStack(spacing: 0) {
            interactiveMap
                .frame(height: 240)

            filterBar

            Group {
                if isLoading && results.isEmpty {
                    ProgressView("Finding recruiting studies…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if activeCoordinate == nil {
                    ContentUnavailableView(
                        "Choose a location",
                        systemImage: "mappin.and.ellipse",
                        description: Text("Allow location access, or pick a city to search around.")
                    )
                } else if results.isEmpty {
                    ContentUnavailableView(
                        "No recruiting studies nearby",
                        systemImage: "mappin.slash",
                        description: Text("Try another city, widen the radius in Settings, or adjust filters.")
                    )
                } else {
                    ScrollViewReader { proxy in
                        List {
                            ForEach(results) { item in
                                let isSelected = item.trial.nctId == selectedNctId
                                NavigationLink(value: item.trial.nctId) {
                                    NearbyStudyRow(
                                        item: item,
                                        showMatch: item.matchScore != nil,
                                        isHighlighted: isSelected
                                    )
                                }
                                .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                                .listRowBackground(
                                    isSelected
                                        ? Color.accentColor.opacity(0.12)
                                        : Color.clear
                                )
                                .listRowSeparatorTint(Color.primary.opacity(0.12))
                                .id(item.trial.nctId)
                            }
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                        .onChange(of: selectedNctId) { _, nctId in
                            guard let nctId else { return }
                            withAnimation(.smooth(duration: 0.25)) {
                                proxy.scrollTo(nctId, anchor: .center)
                            }
                            focusCamera(on: nctId)
                        }
                    }
                }
            }
            .background(Color(.systemGroupedBackground))
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(navigationTitleText)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingPlacePicker = true
                } label: {
                    Label(anchor == nil ? "City" : "Change", systemImage: "building.2")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingFilters = true
                } label: {
                    Label("Filters", systemImage: filterBadgeIcon)
                }
            }
        }
        .sheet(isPresented: $showingFilters, onDismiss: {
            filter.status = "RECRUITING"
            filterEpoch += 1
        }) {
            FilterSheet(filter: $filter, locksRecruitingStatus: true)
        }
        .sheet(isPresented: $showingPlacePicker) {
            NearbyPlacePicker { place in
                anchor = place
                filterEpoch += 1
            }
        }
        .onAppear {
            if anchor == nil { anchor = initialAnchor }
            pendingFocusNctId = focusedNctId
            if selectedNctId == nil { selectedNctId = focusedNctId }
        }
        .task { location.prepare() }
        .task(id: queryToken) { await reload() }
    }

    private var navigationTitleText: String {
        if let anchor { return "Near \(anchor.label)" }
        return "Nearby Studies"
    }

    private var activeCoordinate: CLLocationCoordinate2D? {
        anchor?.coordinate ?? location.coordinate
    }

    private var activeCountryHint: String? {
        anchor?.countryHint ?? location.countryName
    }

    private var filterBadgeIcon: String {
        var probe = filter
        probe.status = nil
        return probe.isEmpty ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill"
    }

    private var queryToken: String {
        let lat = activeCoordinate.map { String(format: "%.4f", $0.latitude) } ?? "-"
        let lon = activeCoordinate.map { String(format: "%.4f", $0.longitude) } ?? "-"
        return "\(lat)|\(lon)|\(anchor?.label ?? "me")|\(radiusMiles)|\(filterEpoch)|\(activeCountryHint ?? "")|\(smartRecommendationsEnabled)|\(preferNearest)"
    }

    private var mapItems: [NearbyTrial] {
        var items = Array(results.prefix(80))
        if let selectedNctId,
           let hit = results.first(where: { $0.trial.nctId == selectedNctId }),
           !items.contains(where: { $0.trial.nctId == selectedNctId }) {
            items.append(hit)
        }
        return items
    }

    private var interactiveMap: some View {
        Map(position: $cameraPosition, selection: $selectedNctId) {
            if let centre = activeCoordinate {
                Annotation(anchor == nil ? "You" : "Search", coordinate: centre, anchor: .center) {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 14, height: 14)
                        .overlay(Circle().stroke(.white, lineWidth: 2))
                }
            }
            ForEach(mapItems) { item in
                if let coordinate = item.site.coordinate {
                    Marker(item.trial.briefTitle, coordinate: coordinate)
                        .tint(item.trial.nctId == selectedNctId ? .red : .green)
                        .tag(item.trial.nctId)
                }
            }
        }
        .mapStyle(.standard)
        .mapControls {
            if anchor == nil {
                MapUserLocationButton()
            }
            MapCompass()
        }
    }

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(isLoading ? "Searching…" : "\(results.count.formatted()) nearby")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                Spacer(minLength: 0)
                Text("Within \(radiusMiles) mi")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            HStack(spacing: 8) {
                Button {
                    showingPlacePicker = true
                } label: {
                    Label(
                        anchor?.label ?? "Near me",
                        systemImage: anchor == nil ? "location.fill" : "building.2.fill"
                    )
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                if anchor != nil {
                    Button("Use my location") {
                        anchor = nil
                        filterEpoch += 1
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.borderless)
                }
                Spacer(minLength: 0)
                if mapsExportCoordinate != nil {
                    Button {
                        confirmOpenInMaps = true
                    } label: {
                        Label("Maps", systemImage: "arrow.up.forward.app")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .openInMapsConfirmation(
                isPresented: $confirmOpenInMaps,
                coordinate: mapsExportCoordinate,
                placeName: mapsExportName
            )
            if canRankByProfile {
                Picker("Sort", selection: $preferNearest) {
                    Text("For you").tag(false)
                    Text("Nearest").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemGroupedBackground))
        .overlay(alignment: .bottom) { Divider().opacity(0.35) }
    }

    private var canRankByProfile: Bool {
        smartRecommendationsEnabled
            && profile?.isCompleteForMatching == true
            && !(profile?.conditionsOfInterest.isEmpty ?? true)
    }

    /// Selected site pin, else search centre — for “Open in Apple Maps”.
    private var mapsExportCoordinate: CLLocationCoordinate2D? {
        if let selectedNctId,
           let hit = results.first(where: { $0.trial.nctId == selectedNctId }),
           let coordinate = hit.site.coordinate {
            return coordinate
        }
        return activeCoordinate
    }

    private var mapsExportName: String? {
        if let selectedNctId,
           let hit = results.first(where: { $0.trial.nctId == selectedNctId }) {
            return hit.site.facilityName ?? hit.siteLabel
        }
        return anchor?.label ?? "Nearby search"
    }

    private func reload() async {
        guard let coordinate = activeCoordinate else {
            results = []
            isLoading = false
            return
        }
        isLoading = true
        await data.waitUntilReady()
        loadProfile()

        filter.status = "RECRUITING"
        let radiusMeters = Double(radiusMiles) * NearbyDistance.metersPerMile
        var queryFilter = filter
        queryFilter.status = "RECRUITING"
        let hits = await data.nearbyRecruiting(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            radiusMeters: radiusMeters,
            filter: queryFilter,
            countryHint: queryFilter.country == nil ? activeCountryHint : nil,
            limit: 400
        )
        let ranked: [NearbyTrial]
        if canRankByProfile && !preferNearest {
            ranked = ai.rankNearby(hits, profile: profile)
        } else {
            // No profile / Nearest mode: distance first; prefer interventional slightly.
            ranked = hits.sorted {
                let i0 = ($0.trial.studyTypeDisplay ?? "").localizedCaseInsensitiveContains("Interventional")
                let i1 = ($1.trial.studyTypeDisplay ?? "").localizedCaseInsensitiveContains("Interventional")
                if i0 != i1 { return i0 && !i1 }
                return $0.distanceMeters < $1.distanceMeters
            }
        }
        results = ranked
        isLoading = false

        let focus = pendingFocusNctId ?? focusedNctId
        if let focus, ranked.contains(where: { $0.trial.nctId == focus }) {
            selectedNctId = focus
            pendingFocusNctId = nil
            focusCamera(on: focus)
        } else {
            updateCamera(user: coordinate, items: ranked)
        }
    }

    private func focusCamera(on nctId: String) {
        guard let item = results.first(where: { $0.trial.nctId == nctId }),
              let site = item.site.coordinate else { return }
        withAnimation(.smooth(duration: 0.3)) {
            cameraPosition = .region(MKCoordinateRegion(
                center: site,
                span: MKCoordinateSpan(latitudeDelta: 0.08, longitudeDelta: 0.08)
            ))
        }
    }

    private func updateCamera(user: CLLocationCoordinate2D, items: [NearbyTrial]) {
        var coords = items.prefix(40).compactMap(\.site.coordinate)
        coords.append(user)
        guard let region = regionFitting(coords) else {
            cameraPosition = .region(MKCoordinateRegion(
                center: user,
                latitudinalMeters: Double(radiusMiles) * NearbyDistance.metersPerMile * 2,
                longitudinalMeters: Double(radiusMiles) * NearbyDistance.metersPerMile * 2
            ))
            return
        }
        cameraPosition = .region(region)
    }

    private func regionFitting(_ coordinates: [CLLocationCoordinate2D]) -> MKCoordinateRegion? {
        guard !coordinates.isEmpty else { return nil }
        var minLat = coordinates[0].latitude
        var maxLat = minLat
        var minLon = coordinates[0].longitude
        var maxLon = minLon
        for c in coordinates {
            minLat = min(minLat, c.latitude)
            maxLat = max(maxLat, c.latitude)
            minLon = min(minLon, c.longitude)
            maxLon = max(maxLon, c.longitude)
        }
        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta: max(0.02, (maxLat - minLat) * 1.35),
            longitudeDelta: max(0.02, (maxLon - minLon) * 1.35)
        )
        return MKCoordinateRegion(center: center, span: span)
    }

    private func loadProfile() {
        var descriptor = FetchDescriptor<UserProfile>()
        descriptor.fetchLimit = 1
        profile = try? modelContext.fetch(descriptor).first
    }
}

private struct NearbyStudyRow: View {
    let item: NearbyTrial
    var showMatch = false
    var isHighlighted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.trial.briefTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Spacer(minLength: 8)
                Text(item.distanceLabel)
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(isHighlighted ? Color.accentColor : Color.secondary)
            }
            HStack(spacing: 8) {
                StatusBadge(status: item.trial.statusDisplay)
                if showMatch, let score = item.matchScore {
                    Text("\(Int((score * 100).rounded()))% match")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tint)
                }
            }
            Text(item.siteLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let condition = item.trial.primaryCondition {
                ConditionLabel(condition: condition, showGenericWhenDisabled: false)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Apple Maps–style preview (Home / Discover / Site / Org)

struct NearbyMapPreview: View {
    let user: CLLocationCoordinate2D?
    let site: CLLocationCoordinate2D?
    /// Label shown in the “Open in Apple Maps?” dialog.
    var placeName: String? = nil
    var height: CGFloat = 140

    @State private var confirmOpenInMaps = false

    /// Prefer the site pin; fall back to user when that’s all we have.
    private var openCoordinate: CLLocationCoordinate2D? { site ?? user }

    var body: some View {
        Group {
            if let region = previewRegion {
                Map(initialPosition: .region(region), interactionModes: []) {
                    if let user {
                        Annotation("", coordinate: user, anchor: .center) {
                            Circle()
                                .fill(Color.accentColor)
                                .frame(width: 10, height: 10)
                                .overlay(Circle().stroke(.white, lineWidth: 1.5))
                        }
                    }
                    if let site {
                        Marker("", coordinate: site)
                            .tint(.green)
                    }
                }
                .mapControlVisibility(.hidden)
                .allowsHitTesting(false)
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                )
            } else {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(.tertiarySystemFill))
                    .frame(maxWidth: .infinity)
                    .frame(height: height)
                    .overlay {
                        Image(systemName: "map")
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard openCoordinate != nil else { return }
            confirmOpenInMaps = true
        }
        .openInMapsConfirmation(
            isPresented: $confirmOpenInMaps,
            coordinate: openCoordinate,
            placeName: placeName
        )
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(openCoordinate == nil ? [] : .isButton)
        .accessibilityLabel(placeName.map { "Map of \($0)" } ?? "Map")
        .accessibilityHint(openCoordinate == nil ? "" : "Opens in Apple Maps")
    }

    private var previewRegion: MKCoordinateRegion? {
        let points = [user, site].compactMap { $0 }
        guard !points.isEmpty else { return nil }
        if points.count == 1 {
            return MKCoordinateRegion(center: points[0], span: MKCoordinateSpan(latitudeDelta: 0.06, longitudeDelta: 0.06))
        }
        let lats = points.map(\.latitude)
        let lons = points.map(\.longitude)
        let center = CLLocationCoordinate2D(
            latitude: (lats.min()! + lats.max()!) / 2,
            longitude: (lons.min()! + lons.max()!) / 2
        )
        return MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(
                latitudeDelta: max(0.03, (lats.max()! - lats.min()!) * 2.4),
                longitudeDelta: max(0.03, (lons.max()! - lons.min()!) * 2.4)
            )
        )
    }
}

private extension TrialFilter {
    init(status: String) {
        self.init()
        self.status = status
    }
}
