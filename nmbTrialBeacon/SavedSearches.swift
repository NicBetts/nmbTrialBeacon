//
//  SavedSearches.swift
//  nmbTrialBeacon
//
//  Named trial-search snapshots (filter + query + sort + scope). Separate from
//  Watchlist (NCT ids) and Favourites (orgs / sites). Cap is small on purpose.
//

import Foundation
import SwiftData

enum SavedSearches {
    static let storageLimit = 10

    /// Payload used to open Search with a saved (or ad-hoc) configuration.
    struct Launch: Hashable, Sendable {
        var filter: TrialFilter = TrialFilter()
        var query: String = ""
        var scope: TrialSearchScope = .all
        var sort: TrialSort = .lastUpdatedDesc
    }

    static func decode(_ row: SavedSearch) -> Launch? {
        guard let filter = try? JSONDecoder().decode(TrialFilter.self, from: row.filterData) else {
            return nil
        }
        return Launch(
            filter: filter,
            query: row.query,
            scope: TrialSearchScope(rawValue: row.scopeRaw) ?? .all,
            sort: TrialSort(rawValue: row.sortRaw) ?? .lastUpdatedDesc
        )
    }

    static func count(context: ModelContext) -> Int {
        (try? context.fetchCount(FetchDescriptor<SavedSearch>())) ?? 0
    }

    static func isAtLimit(context: ModelContext) -> Bool {
        count(context: context) >= storageLimit
    }

    /// Deterministic short title when Apple Intelligence is off or refuses.
    static func fallbackName(chipLabels: [String], query: String) -> String {
        var parts = chipLabels
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty { parts.insert(q, at: 0) }
        if parts.isEmpty { return "Saved search" }
        let joined = parts.prefix(3).joined(separator: " · ")
        return String(joined.prefix(48))
    }

    /// Returns `nil` when at the cap (caller should explain). Same filter + query
    /// updates the existing row (name / sort / scope) instead of inserting again.
    @discardableResult
    static func save(
        name: String,
        filter: TrialFilter,
        query: String,
        sort: TrialSort,
        scope: TrialSearchScope,
        context: ModelContext
    ) -> SavedSearch? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !filter.isEmpty || !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        guard let filterData = try? JSONEncoder().encode(filter) else { return nil }

        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing = match(filter: filter, query: q, in: fetchAll(context: context)) {
            existing.name = trimmed
            existing.filterData = filterData
            existing.sortRaw = sort.rawValue
            existing.scopeRaw = scope.rawValue
            existing.savedAt = Date()
            try? context.save()
            return existing
        }

        guard !isAtLimit(context: context) else { return nil }

        let row = SavedSearch(
            name: trimmed,
            filterData: filterData,
            query: q,
            sortRaw: sort.rawValue,
            scopeRaw: scope.rawValue
        )
        context.insert(row)
        try? context.save()
        return row
    }

    static func rename(_ row: SavedSearch, to name: String, context: ModelContext) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        row.name = trimmed
        try? context.save()
    }

    static func delete(_ row: SavedSearch, context: ModelContext) {
        context.delete(row)
        try? context.save()
    }

    /// Semantic match on filter + query (not raw JSON bytes — Set encoding order varies).
    static func match(
        filter: TrialFilter,
        query: String,
        in rows: [SavedSearch]
    ) -> SavedSearch? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return rows.first { row in
            guard row.query == q, let launch = decode(row) else { return false }
            return launch.filter == filter
        }
    }

    static func match(
        filter: TrialFilter,
        query: String,
        context: ModelContext
    ) -> SavedSearch? {
        match(filter: filter, query: query, in: fetchAll(context: context))
    }

    private static func fetchAll(context: ModelContext) -> [SavedSearch] {
        (try? context.fetch(FetchDescriptor<SavedSearch>())) ?? []
    }
}
