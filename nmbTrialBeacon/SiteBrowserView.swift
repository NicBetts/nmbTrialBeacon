//
//  SiteBrowserView.swift
//  nmbTrialBeacon
//

import CoreLocation
import SwiftUI

struct SiteRoute: Hashable, Sendable {
    let ref: SiteRef
    init(ref: SiteRef) { self.ref = ref }
}

struct SiteBrowserView: View {
    @Environment(TrialDataService.self) private var data
    @Environment(LocationService.self) private var location

    @AppStorage("nearbyRadiusMiles") private var radiusMiles = LocationService.defaultRadiusMiles

    @State private var mode: SiteBrowserMode = .highActivity
    @State private var query = ""
    @State private var results: [SiteSummary] = []
    @State private var cities: [SiteCityGroup] = []
    @State private var countries: [SiteCountryGroup] = []
    @State private var selectedCity: SiteCityGroup?
    @State private var selectedCountry: SiteCountryGroup?
    @State private var isLoading = true
    @State private var statusNote: String?

    var body: some View {
        VStack(spacing: 0) {
            if mode == .search {
                searchField
            }
            modeBar
            content
                .background(Color(.systemGroupedBackground))
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Sites")
        .navigationBarTitleDisplayMode(.inline)
        .task { location.prepare() }
        .task(id: reloadToken) { await reload() }
        // SiteRoute is registered on the parent stack via trialNavigationDestinations().
    }

    private var reloadToken: String {
        let lat = location.coordinate.map { String(format: "%.3f", $0.latitude) } ?? "-"
        let lon = location.coordinate.map { String(format: "%.3f", $0.longitude) } ?? "-"
        return "\(mode.rawValue)|\(query)|\(selectedCity?.id ?? "")|\(selectedCountry?.id ?? "")|\(lat)|\(lon)|\(radiusMiles)"
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search facilities", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(Color(.secondarySystemGroupedBackground), in: Capsule())
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private var modeBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(SiteBrowserMode.allCases) { item in
                    Button {
                        selectedCity = nil
                        selectedCountry = nil
                        mode = item
                    } label: {
                        Text(item.label)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(
                                mode == item
                                    ? Color.accentColor.opacity(0.16)
                                    : Color(.tertiarySystemFill),
                                in: Capsule()
                            )
                            .foregroundStyle(mode == item ? Color.accentColor : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && results.isEmpty && cities.isEmpty && countries.isEmpty {
            ProgressView(statusNote ?? "Loading sites…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if mode == .city, selectedCity == nil {
            cityList
        } else if mode == .country, selectedCountry == nil {
            countryList
        } else if results.isEmpty {
            ContentUnavailableView(
                emptyTitle,
                systemImage: "mappin.slash",
                description: Text(emptyDescription)
            )
        } else {
            VStack(spacing: 0) {
                if let statusNote {
                    Text(statusNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                }
                if mode == .city, let selectedCity {
                    breadcrumb("Cities", selectedCity.label) { self.selectedCity = nil }
                }
                if mode == .country, let selectedCountry {
                    breadcrumb("Countries", selectedCountry.country) { self.selectedCountry = nil }
                }
                List {
                    ForEach(results) { site in
                        NavigationLink(value: SiteRoute(ref: site.ref)) {
                            SiteRow(summary: site)
                        }
                        .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparatorTint(Color.primary.opacity(0.12))
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }

    private var cityList: some View {
        List {
            ForEach(cities) { city in
                Button {
                    selectedCity = city
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(city.label)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text("\(city.siteCount.formatted()) sites · \(city.trialCount.formatted()) studies")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private var countryList: some View {
        List {
            ForEach(countries) { country in
                Button {
                    selectedCountry = country
                } label: {
                    HStack {
                        Text("\(CountryFlag.emoji(for: country.country)) \(country.country)")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Spacer()
                        Text("\(country.siteCount.formatted())")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func breadcrumb(_ root: String, _ leaf: String, back: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Button(root, action: back)
                .font(.caption.weight(.semibold))
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            Text(leaf)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private var emptyTitle: String {
        switch mode {
        case .nearby: return "No nearby sites"
        case .search: return "No matching sites"
        default: return "No sites"
        }
    }

    private var emptyDescription: String {
        switch mode {
        case .nearby:
            return "Enable location or widen the radius in Settings."
        case .search:
            return query.isEmpty ? "Type a facility name to search." : "Try a shorter name or another spelling."
        default:
            return "Site data is still indexing or unavailable in this database."
        }
    }

    private func reload() async {
        isLoading = true
        statusNote = data.supportsCanonicalSites
            ? nil
            : "This database has no site catalogue yet — showing recruiting facilities only. Rebuild with the v10 site tables for the full list."
        await data.waitUntilReady()
        // First Sites open builds the recruiting index (decompress every
        // recruiting trial). Warm here so Site detail is not cold.
        if !data.supportsCanonicalSites {
            await data.warmSiteIndexIfNeeded()
        }

        switch mode {
        case .search:
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                results = await data.highActivitySites(limit: 80)
            } else {
                try? await Task.sleep(nanoseconds: 250_000_000)
                if Task.isCancelled { return }
                results = await data.searchSites(trimmed, limit: 80)
            }
            cities = []; countries = []
        case .nearby:
            guard let coordinate = location.coordinate else {
                results = []
                isLoading = false
                return
            }
            let meters = Double(radiusMiles) * NearbyDistance.metersPerMile
            results = await data.nearbySites(
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                radiusMeters: meters,
                limit: 80
            )
            cities = []; countries = []
        case .city:
            if let selectedCity {
                results = await data.sites(
                    inCity: selectedCity.city,
                    country: selectedCity.country,
                    limit: 80
                )
            } else {
                cities = await data.siteCities(limit: 80)
                results = []
            }
            countries = []
        case .country:
            if let selectedCountry {
                results = await data.sites(inCountry: selectedCountry.country, limit: 80)
            } else {
                countries = await data.siteCountries(limit: 80)
                results = []
            }
            cities = []
        case .highActivity:
            results = await data.highActivitySites(limit: 80)
            cities = []; countries = []
        }
        isLoading = false
    }
}

struct SiteRow: View {
    let summary: SiteSummary

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            SiteMonogram(text: summary.monogram)
            VStack(alignment: .leading, spacing: 4) {
                Text(summary.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                if !summary.subtitle.isEmpty {
                    Text(summary.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 8) {
                    if summary.includesNonRecruitingStudies {
                        Text("\(summary.totalRelatedTrialCount.formatted()) studies")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        if summary.recruitingTrialCount > 0 {
                            Text("\(summary.recruitingTrialCount.formatted()) recruiting")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    } else if summary.recruitingTrialCount > 0 {
                        Text("\(summary.recruitingTrialCount.formatted()) recruiting")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    if let distance = summary.distanceLabel {
                        Text(distance)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tint)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

struct SiteMonogram: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.bold))
            .foregroundStyle(.white)
            .frame(width: 36, height: 36)
            .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityHidden(true)
    }
}
