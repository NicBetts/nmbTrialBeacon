//
//  ConditionBrowserView.swift
//  nmbTrialBeacon
//
//  Discover Conditions (schema v14) — domain-photo split cards (same language as
//  Featured / Pulse momentum), not a plain list.
//

import SwiftUI

struct ConditionBrowserView: View {
    @Environment(TrialDataService.self) private var data

    @State private var query = ""
    @State private var results: [LookupValue] = []
    @State private var isLoading = true

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                searchField

                if isLoading && results.isEmpty {
                    ProgressView("Loading conditions…")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 48)
                } else if results.isEmpty {
                    ContentUnavailableView.search(text: query.isEmpty ? "conditions" : query)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 32)
                } else {
                    if query.isEmpty {
                        Text("Popular")
                            .font(.title3.bold())
                    }

                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(results) { row in
                            NavigationLink(value: TrialListRequest(
                                title: row.display,
                                filter: {
                                    var f = TrialFilter()
                                    f.conditions = [row.value]
                                    return f
                                }()
                            )) {
                                ConditionSplitCard(
                                    condition: row.display,
                                    studyCount: row.count
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
        .navigationTitle("Conditions")
        .navigationBarTitleDisplayMode(.large)
        .task(id: query) { await reload() }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search conditions", text: $query)
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

    private func reload() async {
        isLoading = true
        await data.waitUntilReady()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            results = await data.popularConditions(limit: 50)
        } else {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled { return }
            results = await data.searchDiscoverConditions(trimmed, limit: 80)
        }
        isLoading = false
    }
}

/// Domain photo band + title / count — mirrors Pulse momentum / Featured split cards.
struct ConditionSplitCard: View {
    let condition: String
    let studyCount: Int

    /// Slightly shorter photo band; text block tightened to match.
    private let imageHeight: CGFloat = 70

    var body: some View {
        let asset = DomainHeroImage.assetName(forCondition: condition)
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)

        VStack(alignment: .leading, spacing: 0) {
            Image(asset)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity)
                .frame(height: imageHeight)
                .clipped()

            VStack(alignment: .leading, spacing: 2) {
                Text(condition)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                Text("\(studyCount.formatted()) studies")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 9)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(Color(.secondarySystemGroupedBackground))
        }
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .contentShape(shape)
        .accessibilityLabel("\(condition), \(studyCount.formatted()) studies")
    }
}

/// Compact intervention tile — type badge top-trailing so the body can stay short.
struct DiscoverEntityCard: View {
    let title: String
    let count: Int
    let symbolName: String
    var accent: Color = .accentColor
    /// Shown as a top-trailing chip (e.g. Drug, Device).
    var typeLabel: String? = nil
    /// Drugs@FDA catalog match (ingredient or brand) — browse indication only.
    var inFdaCatalog: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                ZStack {
                    Circle()
                        .fill(accent.opacity(0.12))
                        .frame(width: 32, height: 32)
                    Image(systemName: symbolName)
                        .font(.subheadline.weight(.semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(accent)
                }

                Spacer(minLength: 0)

                HStack(spacing: 6) {
                    if inFdaCatalog {
                        FDAIndicator(interventionName: title)
                    }
                    if let typeLabel, !typeLabel.isEmpty {
                        Text(typeLabel)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(accent)
                            .lineLimit(1)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(accent.opacity(0.12), in: Capsule())
                    }
                }
            }

            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            Text("\(count.formatted()) studies")
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
