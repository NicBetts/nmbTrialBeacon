//
//  FavouritesSupport.swift
//  nmbTrialBeacon
//
//  On-device favourite organisations / sites (separate from trial Watchlist).
//

import SwiftData
import SwiftUI

enum RecentlyViewed {
    /// Rows kept in SwiftData per entity type (Discover shows fewer).
    static let storageLimit = 20
    /// Chips shown on Discover (combined orgs + sites, newest first).
    static let discoverDisplayLimit = 5

    static func recordOrganisation(
        identityKey: String,
        displayName: String,
        context: ModelContext
    ) {
        let key = identityKey
        let existing = try? context.fetch(
            FetchDescriptor<RecentlyViewedOrganisation>(
                predicate: #Predicate { $0.identityKey == key }
            )
        ).first
        if let existing {
            existing.displayName = displayName
            existing.viewedAt = Date()
        } else {
            context.insert(RecentlyViewedOrganisation(
                identityKey: key,
                displayName: displayName
            ))
        }
        pruneOrganisations(context: context)
        try? context.save()
    }

    static func recordSite(
        identityKey: String,
        displayName: String,
        context: ModelContext
    ) {
        let key = identityKey
        let existing = try? context.fetch(
            FetchDescriptor<RecentlyViewedSite>(
                predicate: #Predicate { $0.identityKey == key }
            )
        ).first
        if let existing {
            existing.displayName = displayName
            existing.viewedAt = Date()
        } else {
            context.insert(RecentlyViewedSite(
                identityKey: key,
                displayName: displayName
            ))
        }
        pruneSites(context: context)
        try? context.save()
    }

    private static func pruneOrganisations(context: ModelContext) {
        let descriptor = FetchDescriptor<RecentlyViewedOrganisation>(
            sortBy: [SortDescriptor(\.viewedAt, order: .reverse)]
        )
        guard let rows = try? context.fetch(descriptor), rows.count > storageLimit else { return }
        for row in rows.dropFirst(storageLimit) {
            context.delete(row)
        }
    }

    private static func pruneSites(context: ModelContext) {
        let descriptor = FetchDescriptor<RecentlyViewedSite>(
            sortBy: [SortDescriptor(\.viewedAt, order: .reverse)]
        )
        guard let rows = try? context.fetch(descriptor), rows.count > storageLimit else { return }
        for row in rows.dropFirst(storageLimit) {
            context.delete(row)
        }
    }

    static func clearAll(context: ModelContext) {
        if let orgs = try? context.fetch(FetchDescriptor<RecentlyViewedOrganisation>()) {
            for row in orgs { context.delete(row) }
        }
        if let sites = try? context.fetch(FetchDescriptor<RecentlyViewedSite>()) {
            for row in sites { context.delete(row) }
        }
        try? context.save()
    }

    static func removeOrganisation(identityKey: String, context: ModelContext) {
        let key = identityKey
        if let row = try? context.fetch(
            FetchDescriptor<RecentlyViewedOrganisation>(
                predicate: #Predicate { $0.identityKey == key }
            )
        ).first {
            context.delete(row)
            try? context.save()
        }
    }

    static func removeSite(identityKey: String, context: ModelContext) {
        let key = identityKey
        if let row = try? context.fetch(
            FetchDescriptor<RecentlyViewedSite>(
                predicate: #Predicate { $0.identityKey == key }
            )
        ).first {
            context.delete(row)
            try? context.save()
        }
    }
}

enum EntityFavourites {
    static func isFavouriteOrganisation(identityKey: String, context: ModelContext) -> Bool {
        let key = identityKey
        var descriptor = FetchDescriptor<FavouriteOrganisation>(
            predicate: #Predicate { $0.identityKey == key }
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first != nil
    }

    static func isFavouriteSite(identityKey: String, context: ModelContext) -> Bool {
        let key = identityKey
        var descriptor = FetchDescriptor<FavouriteSite>(
            predicate: #Predicate { $0.identityKey == key }
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first != nil
    }

    @discardableResult
    static func toggleOrganisation(
        identityKey: String,
        displayName: String,
        context: ModelContext
    ) -> Bool {
        let key = identityKey
        var descriptor = FetchDescriptor<FavouriteOrganisation>(
            predicate: #Predicate { $0.identityKey == key }
        )
        descriptor.fetchLimit = 1
        if let existing = try? context.fetch(descriptor).first {
            context.delete(existing)
            try? context.save()
            return false
        }
        context.insert(FavouriteOrganisation(identityKey: key, displayName: displayName))
        try? context.save()
        return true
    }

    @discardableResult
    static func toggleSite(
        identityKey: String,
        displayName: String,
        context: ModelContext
    ) -> Bool {
        let key = identityKey
        var descriptor = FetchDescriptor<FavouriteSite>(
            predicate: #Predicate { $0.identityKey == key }
        )
        descriptor.fetchLimit = 1
        if let existing = try? context.fetch(descriptor).first {
            context.delete(existing)
            try? context.save()
            return false
        }
        context.insert(FavouriteSite(identityKey: key, displayName: displayName))
        try? context.save()
        return true
    }
}

enum TrialWatchlist {
    static func contains(nctId: String, context: ModelContext) -> Bool {
        let id = nctId
        var descriptor = FetchDescriptor<WatchlistItem>(
            predicate: #Predicate { $0.nctId == id }
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first != nil
    }

    /// Returns `true` when the trial is on the watchlist after the toggle.
    @discardableResult
    static func toggle(nctId: String, context: ModelContext) -> Bool {
        let id = nctId
        var descriptor = FetchDescriptor<WatchlistItem>(
            predicate: #Predicate { $0.nctId == id }
        )
        descriptor.fetchLimit = 1
        if let existing = try? context.fetch(descriptor).first {
            context.delete(existing)
            try? context.save()
            return false
        }
        context.insert(WatchlistItem(nctId: nctId))
        try? context.save()
        return true
    }
}

/// Standard Add/Remove Watchlist long-press menu for trial surfaces.
private struct TrialWatchlistContextMenuModifier: ViewModifier {
    let nctId: String

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \WatchlistItem.dateAdded, order: .reverse)
    private var watchlist: [WatchlistItem]

    func body(content: Content) -> some View {
        content.contextMenu {
            let onList = watchlist.contains { $0.nctId == nctId }
            Button {
                _ = TrialWatchlist.toggle(nctId: nctId, context: modelContext)
            } label: {
                Label(
                    onList ? "Remove from Watchlist" : "Add to Watchlist",
                    systemImage: onList ? "bookmark.slash" : "bookmark"
                )
            }
        }
    }
}

extension View {
    func trialWatchlistContextMenu(nctId: String) -> some View {
        modifier(TrialWatchlistContextMenuModifier(nctId: nctId))
    }
}
