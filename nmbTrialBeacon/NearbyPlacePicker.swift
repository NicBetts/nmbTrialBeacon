//
//  NearbyPlacePicker.swift
//  nmbTrialBeacon
//
//  Choose a city / place to centre Recruiting Nearby (instead of device GPS).
//

import MapKit
import SwiftUI

struct NearbyAnchor: Hashable, Sendable {
    var label: String
    var latitude: Double
    var longitude: Double
    var countryHint: String?

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

struct NearbyPlacePicker: View {
    @Environment(\.dismiss) private var dismiss
    var onSelect: (NearbyAnchor) -> Void

    @State private var query = ""
    @State private var results: [MKMapItem] = []
    @State private var isSearching = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("City or place", text: $query)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.search)
                        .onSubmit { Task { await search() } }
                } footer: {
                    Text("We’ll show recruiting studies within your usual radius of that place.")
                }

                if isSearching {
                    ProgressView("Searching…")
                } else if !results.isEmpty {
                    Section("Places") {
                        ForEach(Array(results.enumerated()), id: \.offset) { _, item in
                            Button {
                                select(item)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.name ?? "Place")
                                        .font(.body.weight(.medium))
                                        .foregroundStyle(.primary)
                                    Text(item.nearbySubtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Choose a place")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task(id: query) {
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard !Task.isCancelled else { return }
                await search()
            }
        }
    }

    private func search() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            results = []
            return
        }
        isSearching = true
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = trimmed
        request.resultTypes = [.address, .pointOfInterest]
        do {
            let response = try await MKLocalSearch(request: request).start()
            results = Array(response.mapItems.prefix(12))
        } catch {
            results = []
        }
        isSearching = false
    }

    private func select(_ item: MKMapItem) {
        let coord = item.location.coordinate
        let cityContext = item.addressRepresentations?.cityWithContext
            ?? item.addressRepresentations?.cityName
        let label = [item.name, cityContext]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        let country = item.addressRepresentations?.regionName
        onSelect(NearbyAnchor(
            label: label.isEmpty ? (item.name ?? "Selected place") : label,
            latitude: coord.latitude,
            longitude: coord.longitude,
            countryHint: country
        ))
        dismiss()
    }
}

private extension MKMapItem {
    var nearbySubtitle: String {
        addressRepresentations?.cityWithContext
            ?? addressRepresentations?.regionName
            ?? ""
    }
}
