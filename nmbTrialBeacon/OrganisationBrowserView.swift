//
//  OrganisationBrowserView.swift
//  nmbTrialBeacon
//

import SwiftUI

struct OrganisationBrowserView: View {
    @Environment(TrialDataService.self) private var data

    @State private var query = ""
    @State private var category: OrganisationCategory = .all
    @State private var results: [OrganisationSummary] = []
    @State private var isLoading = true

    var body: some View {
        VStack(spacing: 0) {
            searchField
            categoryBar
            Group {
                if isLoading && results.isEmpty {
                    ProgressView("Loading organisations…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if results.isEmpty {
                    ContentUnavailableView.search(text: query.isEmpty ? "organisations" : query)
                } else {
                    List {
                        ForEach(results) { org in
                            NavigationLink(value: OrganisationRoute(ref: org.ref)) {
                                OrganisationRow(summary: org)
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
            .background(Color(.systemGroupedBackground))
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Organisations")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: "\(category.rawValue)|\(query)") {
            await reload()
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search organisations", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
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

    private var categoryBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(OrganisationCategory.allCases) { item in
                    Button {
                        category = item
                    } label: {
                        Text(item.label)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(
                                category == item
                                    ? Color.accentColor.opacity(0.16)
                                    : Color(.tertiarySystemFill),
                                in: Capsule()
                            )
                            .foregroundStyle(category == item ? Color.accentColor : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }

    private func reload() async {
        isLoading = true
        await data.waitUntilReady()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            results = await data.organisations(category: category, limit: 80)
        } else {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled { return }
            results = await data.searchOrganisations(trimmed, category: category, limit: 80)
        }
        isLoading = false
    }
}

struct OrganisationRow: View {
    let summary: OrganisationSummary
    var rank: Int?

    var body: some View {
        HStack(spacing: 12) {
            if let rank {
                Text("\(rank)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(rank == 1 ? .white : .secondary)
                    .frame(width: 22, height: 22)
                    .background(rank == 1 ? Color.accentColor : Color(.tertiarySystemFill), in: Circle())
            } else {
                OrganisationCategoryIcon(category: summary.category)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(summary.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(summary.classLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 2) {
                Text("\(summary.activeTrialCount.formatted()) active")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                Text("\(summary.recruitingTrialCount.formatted()) recruiting")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

struct OrganisationCategoryIcon: View {
    let category: OrganisationCategory

    var body: some View {
        Image(systemName: category.systemImage)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(width: 36, height: 36)
            .background(Color(.tertiarySystemFill), in: Circle())
            .accessibilityLabel(category.label)
    }
}

struct OrganisationMonogram: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.bold))
            .foregroundStyle(.secondary)
            .frame(width: 36, height: 36)
            .background(Color(.tertiarySystemFill), in: Circle())
            .accessibilityHidden(true)
    }
}
