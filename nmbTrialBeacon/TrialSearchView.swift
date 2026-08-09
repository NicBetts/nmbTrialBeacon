//
//  TrialSearchView.swift
//  nmbTrialBeacon
//
//  Existing trial browse + full-text search (filters, scope, sort, rows).
//  Presented from the Discover landing page — do not replace this engine in
//  Phase 1 entity exploration work.
//
//  Results are paged (keyset for browse, offset for FTS) so scrolling stays
//  flat across ~500k trials. Liquid Glass stays on chrome; rows are flat list
//  content with hairline separators.
//

import SwiftData
import SwiftUI

struct TrialSearchView: View {
    @Environment(TrialDataService.self) private var data

    @Query(sort: \SavedSearch.savedAt, order: .reverse)
    private var savedSearches: [SavedSearch]

    @Namespace private var detailTransition
    @FocusState private var searchFocused: Bool

    @State private var filter: TrialFilter
    @State private var searchText: String
    @State private var searchScope: TrialSearchScope
    @State private var sort: TrialSort

    @State private var results: [TrialSummary] = []
    @State private var organisationHits: [OrganisationSummary] = []
    @State private var totalCount: Int?
    @State private var cursor: TrialCursor?
    @State private var searchOffset = 0
    @State private var reachedEnd = false
    @State private var isLoadingMore = false
    @State private var isLoadingFirstPage = true

    @State private var showingFilters = false
    @State private var showingSmartSearch = false
    @State private var showingSaveSearch = false
    @State private var didLoadSavedFilters = false
    @State private var saveConfirmation = false

    private let pageSize = 40
    private let organisationSuggestionLimit = 5
    private let autoFocusSearch: Bool
    /// When false (saved-search / filtered launches), do not merge last session filters.
    private let restoreLastFilter: Bool

    init(
        initialFilter: TrialFilter = TrialFilter(),
        initialSearch: String = "",
        initialScope: TrialSearchScope = .all,
        initialSort: TrialSort = .lastUpdatedDesc,
        autoFocusSearch: Bool = false,
        restoreLastFilter: Bool = true
    ) {
        _filter = State(initialValue: initialFilter)
        _searchText = State(initialValue: initialSearch)
        _searchScope = State(initialValue: initialScope)
        _sort = State(initialValue: initialSort)
        self.autoFocusSearch = autoFocusSearch
        self.restoreLastFilter = restoreLastFilter
    }

    init(launch: SavedSearches.Launch, autoFocusSearch: Bool = false) {
        self.init(
            initialFilter: launch.filter,
            initialSearch: launch.query,
            initialScope: launch.scope,
            initialSort: launch.sort,
            autoFocusSearch: autoFocusSearch,
            restoreLastFilter: false
        )
    }

    private var trimmedQuery: String {
        searchText.trimmingCharacters(in: .whitespaces)
    }

    private var isSearching: Bool { !trimmedQuery.isEmpty }

    private var canSaveSearch: Bool {
        !filter.isEmpty || !trimmedQuery.isEmpty
    }

    /// Same filter + query already stored (sort/scope may still be updated on save).
    private var matchingSavedSearch: SavedSearch? {
        SavedSearches.match(filter: filter, query: trimmedQuery, in: savedSearches)
    }

    private var saveSearchChipLabels: [String] {
        filter.activeChips.map { data.displayName(for: $0) }
    }

    private struct QueryKey: Equatable {
        let search: String
        let scope: TrialSearchScope
        let filter: TrialFilter
        let sort: TrialSort
    }

    private var queryKey: QueryKey {
        QueryKey(search: trimmedQuery, scope: searchScope, filter: filter, sort: sort)
    }

    var body: some View {
        VStack(spacing: 0) {
            DiscoverChrome(
                searchText: $searchText,
                searchScope: $searchScope,
                filter: $filter,
                searchFocused: $searchFocused,
                isSearching: isSearching,
                onOpenFilters: { showingFilters = true }
            )

            if showsResultsCountBar {
                resultsCountBar
            }

            resultsArea
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Search Trials")
        .navigationBarTitleDisplayMode(.inline)
        // TrialListRequest / OrganisationRoute / SiteRoute come from the parent
        // stack’s `trialNavigationDestinations()` — registering them again here
        // double-pushes and breaks Back.
        .navigationDestination(for: String.self) { nctId in
            TrialDetailView(nctId: nctId)
                .navigationTransition(.zoom(sourceID: nctId, in: detailTransition))
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if canSaveSearch {
                    let isSaved = matchingSavedSearch != nil
                    Button {
                        showingSaveSearch = true
                    } label: {
                        // Bookmark = Apple’s “keep for later” (Reading List, etc.).
                        // Watchlist uses the same family on its tab; label + fill state
                        // keep this action readable in Search.
                        Label(
                            isSaved ? "Saved" : "Save Search",
                            systemImage: isSaved ? "bookmark.fill" : "bookmark"
                        )
                    }
                    .tint(isSaved ? Color.accentColor : nil)
                    .accessibilityLabel(isSaved ? "Saved search" : "Save search")
                    .accessibilityValue(isSaved ? "Saved" : "Not saved")
                }

                Menu {
                    Picker("Sort", selection: $sort) {
                        if isSearching {
                            Label("Best match", systemImage: "star").tag(TrialSort.relevance)
                        }
                        Label("Recently updated", systemImage: "clock").tag(TrialSort.lastUpdatedDesc)
                        Label("Newly added", systemImage: "sparkles").tag(TrialSort.firstPostedDesc)
                        Label("Title A–Z", systemImage: "textformat").tag(TrialSort.titleAsc)
                    }
                } label: {
                    Label(sort.discoverShortLabel, systemImage: "arrow.up.arrow.down")
                }

                if TrialAIService.shared.isReady {
                    Button {
                        showingSmartSearch = true
                    } label: {
                        Label("Describe a search", systemImage: "sparkles")
                    }
                }
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { searchFocused = false }
            }
        }
        .sheet(isPresented: $showingFilters) {
            FilterSheet(filter: $filter)
        }
        .sheet(isPresented: $showingSaveSearch) {
            SaveSearchSheet(
                filter: filter,
                query: trimmedQuery,
                sort: sort,
                scope: searchScope,
                chipLabels: saveSearchChipLabels,
                existing: matchingSavedSearch,
                onSaved: {
                    saveConfirmation = true
                }
            )
        }
        .sensoryFeedback(.success, trigger: saveConfirmation)
        .onChange(of: saveConfirmation) { _, confirmed in
            guard confirmed else { return }
            Task {
                try? await Task.sleep(nanoseconds: 300_000_000)
                saveConfirmation = false
            }
        }
        .sheet(isPresented: $showingSmartSearch) {
            SmartSearchView(initialRequest: searchText) { newFilter, newSearch in
                filter = newFilter
                searchText = newSearch
                if !newSearch.trimmingCharacters(in: .whitespaces).isEmpty {
                    sort = .relevance
                }
            }
        }
        .task(id: queryKey) {
            if isSearching {
                try? await Task.sleep(nanoseconds: 300_000_000)
                if Task.isCancelled { return }
                data.cancelSearch()
            }
            await loadFirstPage()
        }
        .onAppear {
            loadSavedFiltersIfNeeded()
            if autoFocusSearch {
                searchFocused = true
            }
        }
        .onChange(of: filter) { _, newValue in
            SavedFilters.save(newValue)
        }
        .onChange(of: trimmedQuery) { old, new in
            let wasSearching = !old.isEmpty
            let nowSearching = !new.isEmpty
            if nowSearching && !wasSearching {
                sort = .relevance
            } else if !nowSearching && wasSearching && sort == .relevance {
                sort = .lastUpdatedDesc
            }
        }
    }

    private var showsResultsCountBar: Bool {
        !results.isEmpty || !organisationHits.isEmpty || totalCount != nil
            || (isSearching && !isLoadingFirstPage)
    }

    private var hasAnyResults: Bool {
        !results.isEmpty || !organisationHits.isEmpty
    }

    private var resultsCountBar: some View {
        HStack(spacing: 8) {
            Text(headerText)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
            Spacer(minLength: 0)
            if isLoadingFirstPage {
                ProgressView()
                    .controlSize(.mini)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .overlay(alignment: .bottom) {
            Divider().opacity(0.35)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Results

    @ViewBuilder
    private var resultsArea: some View {
        ZStack {
            if !hasAnyResults && isLoadingFirstPage {
                LoadingStateView(title: isSearching ? "Searching…" : "Loading trials…")
            } else if !hasAnyResults {
                if isSearching {
                    ContentUnavailableView.search(text: trimmedQuery)
                } else {
                    EmptyResultsView(
                        icon: "line.3.horizontal.decrease.circle",
                        title: "No trials found",
                        message: "Try adjusting or clearing your filters."
                    )
                }
            } else {
                resultsList
                    .opacity(isLoadingFirstPage ? 0.45 : 1)
                    .allowsHitTesting(!isLoadingFirstPage)
            }

            if isLoadingFirstPage, hasAnyResults {
                ProgressView()
                    .controlSize(.regular)
            }
        }
        .frame(maxHeight: .infinity)
        .animation(.smooth(duration: 0.2), value: isLoadingFirstPage)
    }

    private var prefetchTriggerID: TrialSummary.ID? {
        guard !results.isEmpty else { return nil }
        return results[max(0, results.count - 8)].id
    }

    private var resultsList: some View {
        List {
            if !organisationHits.isEmpty {
                Section {
                    ForEach(organisationHits) { org in
                        NavigationLink(value: OrganisationRoute(ref: org.ref)) {
                            OrganisationRow(summary: org)
                        }
                        .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparatorTint(Color.primary.opacity(0.12))
                    }
                } header: {
                    Text("Organisations")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                }
            }

            if !results.isEmpty {
                Section {
                    ForEach(results) { trial in
                        NavigationLink(value: trial.nctId) {
                            TrialSummaryRow(summary: trial, dateKind: rowDateKind, chrome: .plain)
                        }
                        .matchedTransitionSource(id: trial.nctId, in: detailTransition)
                        .listRowInsets(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparatorTint(Color.primary.opacity(0.12))
                        .onAppear {
                            if trial.id == prefetchTriggerID { Task { await loadMore() } }
                        }
                    }
                    if isLoadingMore {
                        HStack { Spacer(); ProgressView(); Spacer() }
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                } header: {
                    if !organisationHits.isEmpty {
                        Text("Trials")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color(.systemGroupedBackground))
        .scrollDismissesKeyboard(.immediately)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .scrollEdgeEffectStyle(.soft, for: .bottom)
    }

    private var headerText: String {
        if isSearching {
            let orgPart = organisationHits.isEmpty
                ? ""
                : "\(organisationHits.count) org\(organisationHits.count == 1 ? "" : "s") · "
            return "\(orgPart)\(results.count)\(reachedEnd ? "" : "+") trials · \(sort.discoverLabel.lowercased())"
        }
        guard let totalCount else {
            return "\(results.count)\(reachedEnd ? "" : "+") trials"
        }
        return "\(totalCount.formatted()) trial\(totalCount == 1 ? "" : "s")"
    }

    private var rowDateKind: TrialRowDateKind {
        sort == .firstPostedDesc ? .firstPosted : .lastUpdated
    }

    // MARK: - Loading

    private func loadFirstPage() async {
        isLoadingFirstPage = true
        reachedEnd = false
        cursor = nil
        searchOffset = 0

        if isSearching {
            // Organisations first — typing an org name should surface the entity
            // before the long trial list (e.g. "Pfizer" → Organisation Pfizer).
            async let orgsTask = data.searchOrganisations(
                trimmedQuery, category: .all, limit: organisationSuggestionLimit
            )
            async let trialsTask = data.search(
                trimmedQuery, scope: searchScope, filter: filter, sort: sort,
                offset: 0, limit: pageSize
            )
            let (orgs, page) = await (orgsTask, trialsTask)
            if Task.isCancelled { return }
            organisationHits = orgs
            results = page
            searchOffset = page.count
            reachedEnd = page.count < pageSize
        } else {
            organisationHits = []
            let page = await data.page(filter: filter, sort: sort, after: nil, limit: pageSize)
            if Task.isCancelled { return }
            results = page
            cursor = page.last?.cursor
            reachedEnd = page.count < pageSize
            totalCount = nil
            countTotal(for: filter)
        }
        isLoadingFirstPage = false
    }

    private func countTotal(for target: TrialFilter) {
        Task {
            let total = await data.count(filter: target)
            if target == filter, !isSearching { totalCount = total }
        }
    }

    private func loadMore() async {
        guard !reachedEnd, !isLoadingMore, !isLoadingFirstPage else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }

        if isSearching {
            let page = await data.search(trimmedQuery, scope: searchScope, filter: filter, sort: sort,
                                         offset: searchOffset, limit: pageSize)
            results.append(contentsOf: page)
            searchOffset += page.count
            reachedEnd = page.count < pageSize
        } else {
            let page = await data.page(filter: filter, sort: sort, after: cursor, limit: pageSize)
            results.append(contentsOf: page)
            if let last = page.last { cursor = last.cursor }
            reachedEnd = page.count < pageSize
        }
    }

    private func loadSavedFiltersIfNeeded() {
        guard !didLoadSavedFilters else { return }
        didLoadSavedFilters = true
        guard restoreLastFilter else { return }
        guard filter.isEmpty else { return }
        if let saved = SavedFilters.load() { filter = saved }
    }
}

// MARK: - Chrome (search + scope/sort/filters)

private struct DiscoverChrome: View {
    @Binding var searchText: String
    @Binding var searchScope: TrialSearchScope
    @Binding var filter: TrialFilter
    var searchFocused: FocusState<Bool>.Binding
    let isSearching: Bool
    let onOpenFilters: () -> Void

    @Environment(TrialDataService.self) private var data

    private var filterCount: Int { filter.activeFilterCount }
    private var hasFilters: Bool { filterCount > 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            searchField

            GlassEffectContainer(spacing: 8) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        filtersButton

                        Menu {
                            Picker("Search in", selection: $searchScope) {
                                ForEach(TrialSearchScope.allCases) { scope in
                                    Text(scope.rawValue).tag(scope)
                                }
                            }
                        } label: {
                            Label(searchScope.shortLabel, systemImage: "text.magnifyingglass")
                        }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                        // Scope only affects FTS; dim when browsing.
                        .opacity(isSearching ? 1 : 0.55)

                        Spacer(minLength: 0)

                        if hasFilters {
                            Button("Clear") { filter = TrialFilter() }
                                .font(.caption)
                                .buttonStyle(.glass)
                                .controlSize(.small)
                                .accessibilityLabel("Clear filters")
                        }
                    }

                    if hasFilters {
                        filterChipsRow
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .sensoryFeedback(.selection, trigger: filter)
        .sensoryFeedback(.selection, trigger: searchScope)
    }

    @ViewBuilder
    private var filtersButton: some View {
        let label = Label(
            hasFilters ? "Filters (\(filterCount))" : "Filters",
            systemImage: hasFilters
                ? "line.3.horizontal.decrease.circle.fill"
                : "line.3.horizontal.decrease.circle"
        )
        if hasFilters {
            Button(action: onOpenFilters) { label }
                .buttonStyle(.glassProminent)
                .controlSize(.small)
                .tint(.accentColor)
                .accessibilityValue("\(filterCount) active")
        } else {
            Button(action: onOpenFilters) { label }
                .buttonStyle(.glass)
                .controlSize(.small)
                .accessibilityValue("None")
        }
    }

    private var filterChipsRow: some View {
        FlowLayout(spacing: 8) {
            ForEach(filter.activeChips) { chip in
                Button {
                    filter.remove(chip.kind)
                } label: {
                    HStack(spacing: 4) {
                        Text(data.displayName(for: chip)).lineLimit(1)
                        Image(systemName: "xmark")
                            .font(.caption2.weight(.bold))
                    }
                    .font(.caption.weight(.medium))
                }
                .buttonStyle(.glassProminent)
                .controlSize(.small)
                .tint(.accentColor)
                .accessibilityLabel("Remove filter \(data.displayName(for: chip))")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField(searchPrompt, text: $searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused(searchFocused)
                .onSubmit { searchFocused.wrappedValue = false }

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .glassEffect(.regular, in: .capsule)
    }

    private var searchPrompt: String {
        switch searchScope {
        case .all: return "Search trials"
        case .titles: return "Search titles"
        case .conditions: return "Search conditions"
        case .interventions: return "Search interventions"
        case .summaries: return "Search summaries"
        case .nctId: return "Search NCT ID"
        }
    }
}

// MARK: - Labels

private extension TrialSort {
    var discoverLabel: String {
        switch self {
        case .relevance: return "Best match"
        case .lastUpdatedDesc: return "Recently updated"
        case .firstPostedDesc: return "Newly added"
        case .titleAsc: return "Title A–Z"
        }
    }

    var discoverShortLabel: String {
        switch self {
        case .relevance: return "Best match"
        case .lastUpdatedDesc: return "Updated"
        case .firstPostedDesc: return "Added"
        case .titleAsc: return "Title"
        }
    }
}

private extension TrialSearchScope {
    var shortLabel: String {
        switch self {
        case .all: return "All fields"
        case .titles: return "Titles"
        case .conditions: return "Conditions"
        case .interventions: return "Interventions"
        case .summaries: return "Summaries"
        case .nctId: return "NCT ID"
        }
    }
}

// MARK: - Pushed filtered list (used by Home / Analytics / detail org links)

/// Typed navigation value — destination-style `NavigationLink { TrialListView }`
/// inside `LazyVStack` breaks the stack on recent iOS; push this instead.
struct TrialListRequest: Hashable, Sendable {
    let title: String
    let filter: TrialFilter
    var sort: TrialSort = .lastUpdatedDesc
}

extension View {
    /// Registers filtered-list + trial-detail destinations for a tab's `NavigationStack`.
    func trialNavigationDestinations() -> some View {
        self
            .navigationDestination(for: TrialListRequest.self) { request in
                TrialListView(title: request.title, filter: request.filter, sort: request.sort)
            }
            .navigationDestination(for: NearbyStudiesRoute.self) { route in
                NearbyStudiesView(focusedNctId: route.focusedNctId, initialAnchor: route.anchor)
            }
            .navigationDestination(for: OrganisationRoute.self) { route in
                OrganisationDetailView(ref: route.ref)
            }
            .navigationDestination(for: SiteRoute.self) { route in
                SiteDetailView(ref: route.ref)
            }
            .navigationDestination(for: String.self) { nctId in
                TrialDetailView(nctId: nctId)
            }
    }
}

struct TrialListView: View {
    let title: String
    let filter: TrialFilter
    var sort: TrialSort = .lastUpdatedDesc

    @Environment(TrialDataService.self) private var data
    @State private var results: [TrialSummary] = []
    @State private var cursor: TrialCursor?
    @State private var totalCount: Int?
    @State private var reachedEnd = false
    @State private var isLoadingMore = false
    @State private var isLoadingFirstPage = true

    private let pageSize = 40

    private var prefetchTriggerID: TrialSummary.ID? {
        guard !results.isEmpty else { return nil }
        return results[max(0, results.count - 8)].id
    }

    private var countLabel: String {
        totalCount.map { "\($0.formatted()) trial\($0 == 1 ? "" : "s")" }
            ?? "\(results.count)\(reachedEnd ? "" : "+") trials"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(isLoadingFirstPage ? "Loading…" : countLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                Spacer(minLength: 0)
                if isLoadingFirstPage {
                    ProgressView().controlSize(.mini)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground))
            .overlay(alignment: .bottom) {
                Divider().opacity(0.35)
            }

            if !isLoadingFirstPage && results.isEmpty {
                EmptyResultsView(icon: "tray", title: "No trials",
                                 message: "No trials match this selection.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(results) { trial in
                        NavigationLink(value: trial.nctId) {
                            TrialSummaryRow(summary: trial, chrome: .plain)
                        }
                        .listRowInsets(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparatorTint(Color.primary.opacity(0.12))
                        .onAppear { if trial.id == prefetchTriggerID { Task { await loadMore() } } }
                    }
                    if isLoadingMore {
                        HStack { Spacer(); ProgressView(); Spacer() }
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Color(.systemGroupedBackground))
                .scrollEdgeEffectStyle(.soft, for: .top)
                .scrollEdgeEffectStyle(.soft, for: .bottom)
                .overlay {
                    if isLoadingFirstPage {
                        ProgressView()
                            .controlSize(.regular)
                    }
                }
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: filter) {
            isLoadingFirstPage = true
            reachedEnd = false
            cursor = nil
            totalCount = nil
            // Count + first page in parallel. Site soft-key lists may return a
            // short first page from the v9 index cache — use total for end.
            async let pageTask = data.page(filter: filter, sort: sort, after: nil, limit: pageSize)
            async let countTask = data.count(filter: filter)
            let (page, total) = await (pageTask, countTask)
            results = page
            cursor = page.last?.cursor
            totalCount = total
            reachedEnd = results.count >= total || (total == 0 && page.isEmpty)
            isLoadingFirstPage = false
        }
    }

    private func loadMore() async {
        guard !reachedEnd, !isLoadingMore, !isLoadingFirstPage else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        let page = await data.page(filter: filter, sort: sort, after: cursor, limit: pageSize)
        results.append(contentsOf: page)
        if let last = page.last { cursor = last.cursor }
        if let total = totalCount {
            reachedEnd = results.count >= total || page.isEmpty
        } else {
            reachedEnd = page.count < pageSize
        }
    }
}

// MARK: - Last-updated options

enum LastUpdatedOption: Int, CaseIterable, Identifiable {
    case day = 1, week = 7, twoWeeks = 14, month = 30, quarter = 90, year = 365
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .day: return "Past 24 hours"
        case .week: return "Past 7 days"
        case .twoWeeks: return "Past 14 days"
        case .month: return "Past 30 days"
        case .quarter: return "Past 90 days"
        case .year: return "Past year"
        }
    }
}

// MARK: - Filter sheet

struct FilterSheet: View {
    @Binding var filter: TrialFilter
    /// Nearby Studies is recruiting-only — hide the status picker and keep it locked.
    var locksRecruitingStatus = false
    @Environment(TrialDataService.self) private var data
    @Environment(\.dismiss) private var dismiss

    @State private var leadSponsors: [LookupValue] = []

    var body: some View {
        NavigationStack {
            Form {
                if locksRecruitingStatus {
                    Section("Status") {
                        LabeledContent("Status", value: "Recruiting")
                        Text("Nearby Studies only includes recruiting trials.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("Status") {
                        lookupPicker(title: "Status", selection: $filter.status, options: data.statuses)
                        Toggle("Active studies only", isOn: $filter.activeOnly)
                    }
                }
                Section("Study") {
                    lookupPicker(title: "Study type", selection: $filter.studyType, options: data.studyTypes)
                    lookupPicker(title: "Phase", selection: $filter.phase, options: data.phases)
                    boolPicker("FDA regulated drug", selection: $filter.fdaRegulatedDrug,
                               yes: "Yes", no: "No")
                    boolPicker("Expanded access", selection: $filter.hasExpandedAccess,
                               yes: "Available", no: "Not available")
                }
                Section("Results") {
                    boolPicker("Posted results", selection: $filter.hasResults,
                               yes: "Has posted results", no: "No posted results")
                    if data.supportsTrialResults {
                        boolPicker("Serious AEs", selection: $filter.hasSeriousAdverseEvents,
                                   yes: "Present", no: "Not present")
                        boolPicker("Other AEs", selection: $filter.hasOtherAdverseEvents,
                                   yes: "Present", no: "Not present")
                        boolPicker("Statistical analysis", selection: $filter.hasStatisticalAnalysis,
                                   yes: "Present", no: "Not present")
                    }
                }
                Section("Eligibility") {
                    lookupPicker(title: "Sex", selection: $filter.gender, options: data.genders)
                    lookupPicker(title: "Age group", selection: $filter.ageRange, options: data.ageRanges)
                }
                Section("Location") {
                    NavigationLink {
                        SingleSelectList(title: "Country", options: data.countries, selection: $filter.country)
                    } label: {
                        LabeledContent("Country", value: filter.country ?? "Any")
                    }
                }
                Section("Conditions") {
                    NavigationLink {
                        MultiSelectList(title: "Conditions", options: data.conditions,
                                        selection: $filter.conditions,
                                        remoteSearch: { await data.searchConditions($0) })
                    } label: {
                        LabeledContent("Conditions",
                                       value: filter.conditions.isEmpty ? "Any" : "\(filter.conditions.count) selected")
                    }
                }
                Section("Organisations") {
                    NavigationLink {
                        SingleSelectList(
                            title: "Lead sponsor",
                            options: leadSponsors,
                            selection: $filter.leadSponsor,
                            remoteSearch: { await data.searchLeadSponsors($0) }
                        )
                    } label: {
                        LabeledContent("Lead sponsor", value: filter.leadSponsor ?? "Any")
                    }
                    if data.supportsCollaborators {
                        NavigationLink {
                            MultiSelectList(
                                title: "Collaborators",
                                options: data.collaborators,
                                selection: $filter.collaborators,
                                remoteSearch: { await data.searchCollaborators($0) }
                            )
                        } label: {
                            LabeledContent(
                                "Collaborators",
                                value: filter.collaborators.isEmpty
                                    ? "Any"
                                    : "\(filter.collaborators.count) selected"
                            )
                        }
                    }
                }
                Section("Recency") {
                    Picker("Last updated", selection: Binding(
                        get: { filter.lastUpdatedWithinDays },
                        set: { filter.lastUpdatedWithinDays = $0 }
                    )) {
                        Text("Any time").tag(nil as Int?)
                        ForEach(LastUpdatedOption.allCases) { Text($0.label).tag($0.rawValue as Int?) }
                    }
                    Picker("Newly added", selection: Binding(
                        get: { filter.firstPostedWithinDays },
                        set: { filter.firstPostedWithinDays = $0 }
                    )) {
                        Text("Any time").tag(nil as Int?)
                        ForEach(LastUpdatedOption.allCases) { Text($0.label).tag($0.rawValue as Int?) }
                    }
                }
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Clear") {
                        var cleared = TrialFilter()
                        if locksRecruitingStatus { cleared.status = "RECRUITING" }
                        filter = cleared
                    }
                    .disabled(clearDisabled)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        if locksRecruitingStatus { filter.status = "RECRUITING" }
                        dismiss()
                    }
                }
            }
            .task {
                if leadSponsors.isEmpty {
                    leadSponsors = await data.searchLeadSponsors("", limit: 500)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var clearDisabled: Bool {
        if locksRecruitingStatus {
            var probe = filter
            probe.status = nil
            return probe.isEmpty
        }
        return filter.isEmpty
    }

    @ViewBuilder
    private func lookupPicker(title: String, selection: Binding<String?>, options: [LookupValue]) -> some View {
        Picker(title, selection: selection) {
            Text("Any").tag(nil as String?)
            ForEach(options) { option in
                Text(option.display).tag(option.value as String?)
            }
        }
    }

    @ViewBuilder
    private func boolPicker(_ title: String, selection: Binding<Bool?>, yes: String, no: String) -> some View {
        Picker(title, selection: selection) {
            Text("Any").tag(nil as Bool?)
            Text(yes).tag(true as Bool?)
            Text(no).tag(false as Bool?)
        }
    }
}

// MARK: - Selection lists

struct SingleSelectList: View {
    let title: String
    let options: [LookupValue]
    @Binding var selection: String?
    /// When set, typed search hits the database instead of filtering `options` only.
    var remoteSearch: ((String) async -> [LookupValue])? = nil

    @State private var query = ""
    @State private var remoteResults: [LookupValue] = []
    @Environment(\.dismiss) private var dismiss

    private var filtered: [LookupValue] {
        guard !query.isEmpty else { return options }
        if remoteSearch != nil { return remoteResults }
        return options.filter { $0.display.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        List {
            Button {
                selection = nil; dismiss()
            } label: {
                HStack { Text("Any"); Spacer(); if selection == nil { Image(systemName: "checkmark") } }
            }
            ForEach(filtered) { option in
                Button {
                    selection = option.value; dismiss()
                } label: {
                    HStack {
                        Text(option.display)
                        Spacer()
                        Text(option.count.formatted()).font(.caption).foregroundStyle(.secondary)
                        if selection == option.value { Image(systemName: "checkmark") }
                    }
                }
                .tint(.primary)
            }
        }
        .searchable(text: $query, prompt: "Search \(title.lowercased())")
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: query) {
            guard let remoteSearch, !query.isEmpty else { return }
            try? await Task.sleep(nanoseconds: 200_000_000)
            if Task.isCancelled { return }
            remoteResults = await remoteSearch(query)
        }
    }
}

struct MultiSelectList: View {
    let title: String
    let options: [LookupValue]
    @Binding var selection: Set<String>
    /// Supplied when the full list lives in the database rather than in
    /// `options` (conditions), so searching reaches beyond the loaded subset.
    var remoteSearch: ((String) async -> [LookupValue])?

    @State private var query = ""
    @State private var remoteResults: [LookupValue] = []

    private var filtered: [LookupValue] {
        guard !query.isEmpty else { return options }
        if remoteSearch != nil { return remoteResults }
        return options.filter { $0.display.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        List {
            if !selection.isEmpty {
                Section {
                    Button("Clear selection", role: .destructive) { selection.removeAll() }
                }
            }
            Section {
                ForEach(filtered) { option in
                    Button {
                        if selection.contains(option.value) { selection.remove(option.value) }
                        else { selection.insert(option.value) }
                    } label: {
                        HStack {
                            if title == "Conditions" {
                                ConditionDomainIcon(condition: option.display)
                                    .foregroundStyle(.secondary)
                            }
                            Text(option.display)
                            Spacer()
                            Text(option.count.formatted()).font(.caption).foregroundStyle(.secondary)
                            if selection.contains(option.value) {
                                Image(systemName: "checkmark").foregroundStyle(.blue)
                            }
                        }
                    }
                    .tint(.primary)
                }
            }
        }
        .searchable(text: $query, prompt: "Search \(title.lowercased())")
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: query) {
            guard let remoteSearch, !query.isEmpty else { return }
            try? await Task.sleep(nanoseconds: 200_000_000)
            if Task.isCancelled { return }
            remoteResults = await remoteSearch(query)
        }
    }
}
