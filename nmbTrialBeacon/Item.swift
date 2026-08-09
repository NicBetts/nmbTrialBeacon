//
//  Item.swift
//  nmbTrialBeacon
//
//  User-owned SwiftData models ONLY. The large clinical-trials dataset lives
//  in the read-only bundled `trialbeacon.sqlite` and is queried via TrialStore
//  (see TrialModels.swift / TrialStore.swift). Everything here is small,
//  mutable, on-device user data and references trials by `nctId`.
//

import Foundation
import SwiftData

// MARK: - Watchlist

@Model
final class WatchlistItem {
    @Attribute(.unique) var nctId: String
    var dateAdded: Date
    var notes: String?

    init(nctId: String, dateAdded: Date = Date(), notes: String? = nil) {
        self.nctId = nctId
        self.dateAdded = dateAdded
        self.notes = notes
    }
}

// MARK: - User Profile

@Model
final class UserProfile {
    var id: UUID
    var ageRange: String?
    var gender: String?
    var country: String?
    /// Preferred city for Discover / Nearby (“near your city”). Nil → device location.
    var preferredCity: String?
    var preferredCityLatitude: Double?
    var preferredCityLongitude: Double?
    @Relationship(deleteRule: .cascade) var conditionsOfInterest: [UserCondition] = []

    init(id: UUID = UUID(), ageRange: String? = nil, gender: String? = nil, country: String? = nil) {
        self.id = id
        self.ageRange = ageRange
        self.gender = gender
        self.country = country
    }

    var hasPreferredCityCoordinate: Bool {
        preferredCityLatitude != nil && preferredCityLongitude != nil
            && !(preferredCity ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var nearbyAnchor: NearbyAnchor? {
        guard hasPreferredCityCoordinate,
              let name = preferredCity,
              let lat = preferredCityLatitude,
              let lon = preferredCityLongitude
        else { return nil }
        return NearbyAnchor(
            label: name,
            latitude: lat,
            longitude: lon,
            countryHint: country
        )
    }
}

@Model
final class UserCondition {
    var name: String
    var userProfile: UserProfile?

    init(name: String, userProfile: UserProfile? = nil) {
        self.name = name
        self.userProfile = userProfile
    }
}

// MARK: - Recently viewed organisations (Discover)

@Model
final class RecentlyViewedOrganisation {
    /// `org:123` / `lead:Name` / `collab:456` — see `OrganisationRef.identityKey`.
    @Attribute(.unique) var identityKey: String
    var displayName: String
    var viewedAt: Date

    init(identityKey: String, displayName: String, viewedAt: Date = Date()) {
        self.identityKey = identityKey
        self.displayName = displayName
        self.viewedAt = viewedAt
    }

    var ref: OrganisationRef? { OrganisationRef.parse(identityKey: identityKey) }
}

// MARK: - Recently viewed sites (Discover)

@Model
final class RecentlyViewedSite {
    /// `site:123` / `raw:Facility|City|Country` — see `SiteRef.identityKey`.
    @Attribute(.unique) var identityKey: String
    var displayName: String
    var viewedAt: Date

    init(identityKey: String, displayName: String, viewedAt: Date = Date()) {
        self.identityKey = identityKey
        self.displayName = displayName
        self.viewedAt = viewedAt
    }

    var ref: SiteRef? { SiteRef.parse(identityKey: identityKey) }
}

// MARK: - Favourites (Discover entities — separate from trial Watchlist)

@Model
final class FavouriteOrganisation {
    @Attribute(.unique) var identityKey: String
    var displayName: String
    var favoritedAt: Date

    init(identityKey: String, displayName: String, favoritedAt: Date = Date()) {
        self.identityKey = identityKey
        self.displayName = displayName
        self.favoritedAt = favoritedAt
    }

    var ref: OrganisationRef? { OrganisationRef.parse(identityKey: identityKey) }
}

@Model
final class FavouriteSite {
    @Attribute(.unique) var identityKey: String
    var displayName: String
    var favoritedAt: Date

    init(identityKey: String, displayName: String, favoritedAt: Date = Date()) {
        self.identityKey = identityKey
        self.displayName = displayName
        self.favoritedAt = favoritedAt
    }

    var ref: SiteRef? { SiteRef.parse(identityKey: identityKey) }
}

// MARK: - Saved searches (named filter + query bookmarks)

@Model
final class SavedSearch {
    @Attribute(.unique) var id: UUID
    var name: String
    /// JSON-encoded `TrialFilter`.
    var filterData: Data
    var query: String
    /// `TrialSort.rawValue`
    var sortRaw: String
    /// `TrialSearchScope.rawValue`
    var scopeRaw: String
    var savedAt: Date
    // Future (not v1): optional alerts when new trials match this search.

    init(
        id: UUID = UUID(),
        name: String,
        filterData: Data,
        query: String = "",
        sortRaw: String = TrialSort.lastUpdatedDesc.rawValue,
        scopeRaw: String = TrialSearchScope.all.rawValue,
        savedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.filterData = filterData
        self.query = query
        self.sortRaw = sortRaw
        self.scopeRaw = scopeRaw
        self.savedAt = savedAt
    }
}

// MARK: - Sync metadata (data snapshot bookkeeping)

@Model
final class SyncMetadata {
    var id: UUID
    var lastSyncDate: Date?
    var newTrialsCount: Int
    var isSyncing: Bool

    init(id: UUID = UUID(), lastSyncDate: Date? = nil, newTrialsCount: Int = 0, isSyncing: Bool = false) {
        self.id = id
        self.lastSyncDate = lastSyncDate
        self.newTrialsCount = newTrialsCount
        self.isSyncing = isSyncing
    }
}
