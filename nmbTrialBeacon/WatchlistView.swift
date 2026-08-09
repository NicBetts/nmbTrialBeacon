//
//  WatchlistView.swift
//  nmbTrialBeacon
//
//  Watchlist membership + notes live in SwiftData (WatchlistItem). Trial
//  content is fetched from the read-only store by NCT id — only the watched
//  trials are loaded, never the whole dataset.
//
//  Search is a custom field (not `.searchable`) so it never fights the iOS 26
//  tab-bar / navigation-bar search chrome.
//

import SwiftUI
import SwiftData

struct WatchlistView: View {
    @Environment(TrialDataService.self) private var data
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \WatchlistItem.dateAdded, order: .reverse) private var items: [WatchlistItem]

    @State private var summaries: [String: TrialSummary] = [:]
    @State private var searchText = ""
    @State private var isSearching = false
    @FocusState private var searchFocused: Bool

    private var trimmedQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var visibleItems: [WatchlistItem] {
        guard !trimmedQuery.isEmpty else { return items }
        let q = trimmedQuery
        return items.filter { item in
            if item.nctId.localizedCaseInsensitiveContains(q) { return true }
            if let notes = item.notes, notes.localizedCaseInsensitiveContains(q) { return true }
            if let s = summaries[item.nctId] {
                return s.briefTitle.localizedCaseInsensitiveContains(q)
                    || (s.primaryCondition?.localizedCaseInsensitiveContains(q) ?? false)
                    || (s.statusDisplay.localizedCaseInsensitiveContains(q))
                    || (s.phaseDisplay?.localizedCaseInsensitiveContains(q) ?? false)
            }
            return false
        }
    }

    private var countSubtitle: String {
        if isSearching, !trimmedQuery.isEmpty {
            return "\(visibleItems.count) of \(items.count) watched"
        }
        return "\(items.count) watched trial\(items.count == 1 ? "" : "s")"
    }

    var body: some View {
        NavigationStack {
            Group {
                if items.isEmpty {
                    EmptyResultsView(
                        icon: "bookmark",
                        title: "No Watched Trials",
                        message: "Trials you bookmark will appear here. Explore in the Discover tab."
                    )
                } else if isSearching, visibleItems.isEmpty {
                    EmptyResultsView(
                        icon: "magnifyingglass",
                        title: "No Matches",
                        message: "Nothing in your watchlist matches “\(trimmedQuery)”."
                    )
                } else {
                    List {
                        ForEach(visibleItems) { item in
                            NavigationLink(value: item.nctId) {
                                WatchedTrialRow(item: item, summary: summaries[item.nctId])
                            }
                            .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                            .listRowBackground(Color.clear)
                            .listRowSeparatorTint(Color.primary.opacity(0.12))
                        }
                        .onDelete(perform: delete)
                    }
                    .listStyle(.plain)
                    .contentMargins(.top, 4, for: .scrollContent)
                    .scrollEdgeEffectStyle(.soft, for: .top)
                    .scrollEdgeEffectStyle(.soft, for: .bottom)
                }
            }
            .navigationTitle("Watchlist")
            .navigationSubtitle(items.isEmpty ? "" : countSubtitle)
            .toolbar {
                if !items.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            toggleSearch()
                        } label: {
                            Image(systemName: isSearching ? "xmark" : "magnifyingglass")
                        }
                        .accessibilityLabel(isSearching ? "Cancel search" : "Search watched trials")
                    }
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if isSearching, !items.isEmpty {
                    searchField
                }
            }
            .trialNavigationDestinations()
            .task(id: items.map(\.nctId)) { await loadSummaries() }
            .onChange(of: items.isEmpty) { _, empty in
                if empty { closeSearch() }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search watched trials", text: $searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($searchFocused)
                .submitLabel(.search)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }

    private func toggleSearch() {
        if isSearching {
            closeSearch()
        } else {
            withAnimation(.smooth(duration: 0.2)) {
                isSearching = true
            }
            searchFocused = true
        }
    }

    private func closeSearch() {
        searchFocused = false
        withAnimation(.smooth(duration: 0.2)) {
            isSearching = false
            searchText = ""
        }
    }

    private func loadSummaries() async {
        let ids = items.map(\.nctId)
        guard !ids.isEmpty else { summaries = [:]; return }
        let fetched = await data.summaries(nctIds: ids)
        summaries = Dictionary(fetched.map { ($0.nctId, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private func delete(_ offsets: IndexSet) {
        withAnimation {
            for index in offsets where index < visibleItems.count {
                modelContext.delete(visibleItems[index])
            }
            try? modelContext.save()
        }
    }
}

private struct WatchedTrialRow: View {
    let item: WatchlistItem
    let summary: TrialSummary?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(summary?.briefTitle ?? item.nctId)
                .font(.subheadline.weight(.semibold))
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text("\(item.nctId) · Added \(item.dateAdded.formatted(date: .abbreviated, time: .omitted))")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let summary {
                HStack(spacing: 6) {
                    StatusBadge(status: summary.statusDisplay)
                    if let phase = summary.phaseDisplay { PhaseChip(phase: phase) }
                }
                if let condition = summary.primaryCondition {
                    ConditionLabel(condition: condition, showGenericWhenDisabled: false)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let notes = item.notes, !notes.isEmpty {
                Label(notes, systemImage: "note.text")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}
