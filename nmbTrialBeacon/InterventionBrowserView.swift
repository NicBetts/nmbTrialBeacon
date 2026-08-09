//
//  InterventionBrowserView.swift
//  nmbTrialBeacon
//
//  Discover Interventions (schema v14) — 2-column type-symbol cards.
//  Opening a row launches Interventions-scoped FTS (no trial_intervention table).
//

import SwiftUI

struct InterventionBrowserView: View {
    @Environment(TrialDataService.self) private var data

    @State private var query = ""
    @State private var fdaCatalogOnly = false
    @State private var results: [InterventionLookupValue] = []
    @State private var isLoading = true

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    private var reloadToken: String {
        "\(query)#\(fdaCatalogOnly ? "fda" : "all")"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                searchField
                filterBar

                if isLoading && results.isEmpty {
                    ProgressView(fdaCatalogOnly ? "Loading Drugs@FDA…" : "Loading interventions…")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 48)
                } else if results.isEmpty {
                    emptyState
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 32)
                } else {
                    // Popular only when browsing; Drugs@FDA heading (+ count) also while searching.
                    if query.isEmpty || fdaCatalogOnly {
                        sectionHeading
                    }

                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(results) { row in
                            NavigationLink(value: DiscoverRoute.trialSearchLaunch(
                                SavedSearches.Launch(
                                    query: row.value,
                                    scope: .interventions,
                                    sort: .relevance
                                )
                            )) {
                                DiscoverEntityCard(
                                    title: row.value,
                                    count: row.trialCount,
                                    symbolName: Self.symbolName(for: row.type),
                                    accent: Self.accent(for: row.type),
                                    typeLabel: row.typeLabel.isEmpty ? nil : row.typeLabel,
                                    inFdaCatalog: row.inFdaCatalog
                                )
                                .accessibilityLabel(
                                    row.inFdaCatalog
                                    ? "\(row.value), in Drugs at FDA catalog, \(row.trialCount) studies"
                                    : "\(row.value), \(row.trialCount) studies"
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Interventions")
        .navigationBarTitleDisplayMode(.large)
        .task(id: reloadToken) { await reload() }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(fdaCatalogOnly ? "Search Drugs@FDA" : "Search interventions", text: $query)
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
    }

    private var sectionHeading: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(fdaCatalogOnly ? "Drugs@FDA" : "Popular")
                .font(.title3.bold())
            if fdaCatalogOnly, !isLoading {
                Text(results.count.formatted())
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            fdaCatalogOnly
            ? "Drugs at FDA linked to trials, \(results.count) drug\(results.count == 1 ? "" : "s")"
            : "Popular"
        )
    }

    @ViewBuilder
    private var filterBar: some View {
        // Needs trial_drug links — catalog-only match was misleading vs Data Status counts.
        if data.supportsFdaDrugs, data.supportsTrialDrug {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Button {
                        withAnimation(.smooth(duration: 0.2)) {
                            fdaCatalogOnly.toggle()
                        }
                    } label: {
                        Text("Drugs@FDA")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .foregroundStyle(fdaCatalogOnly ? Color.white : Color.blue)
                            .background(
                                fdaCatalogOnly ? Color.blue : Color.blue.opacity(0.14),
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Show Drugs at FDA ingredients linked to trials")
                    .accessibilityAddTraits(fdaCatalogOnly ? .isSelected : [])
                }
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if fdaCatalogOnly {
            ContentUnavailableView(
                "No Drugs@FDA matches",
                systemImage: "pills",
                description: Text(
                    query.isEmpty
                    ? "No Drugs@FDA ingredients are linked to trials in this database."
                    : "No linked Drugs@FDA ingredients match “\(query)”."
                )
            )
        } else {
            ContentUnavailableView.search(text: query.isEmpty ? "interventions" : query)
        }
    }

    private func reload() async {
        isLoading = true
        await data.waitUntilReady()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if fdaCatalogOnly {
            // Don't flash Popular rows under the Drugs@FDA heading while aggregating.
            results = []
            if !trimmed.isEmpty {
                try? await Task.sleep(nanoseconds: 250_000_000)
                if Task.isCancelled { return }
            }
            // Distinct fda_drug rows with ≥1 trial_drug link (not popular-name exact match).
            results = await data.trialLinkedFdaDrugs(query: trimmed)
        } else if trimmed.isEmpty {
            results = await data.popularInterventions(limit: 50)
        } else {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled { return }
            results = await data.searchInterventions(trimmed, limit: 80)
        }
        isLoading = false
    }

    static func symbolName(for type: String) -> String {
        switch type.uppercased() {
        case "DRUG", "BIOLOGICAL": return "pills.fill"
        case "DEVICE": return "wrench.and.screwdriver.fill"
        case "PROCEDURE": return "cross.case.fill"
        case "BEHAVIORAL": return "brain.head.profile"
        case "DIETARY_SUPPLEMENT": return "leaf.fill"
        case "RADIATION": return "waveform.path"
        case "GENETIC": return "dna"
        case "DIAGNOSTIC_TEST": return "testtube.2"
        case "COMBINATION_PRODUCT": return "square.split.2x1.fill"
        default: return "pills"
        }
    }

    static func accent(for type: String) -> Color {
        switch type.uppercased() {
        case "DRUG", "BIOLOGICAL": return .teal
        case "DEVICE": return .indigo
        case "PROCEDURE": return .orange
        case "BEHAVIORAL": return .purple
        case "DIETARY_SUPPLEMENT": return .green
        case "RADIATION": return .yellow
        case "GENETIC": return .mint
        case "DIAGNOSTIC_TEST": return .blue
        default: return .accentColor
        }
    }
}
