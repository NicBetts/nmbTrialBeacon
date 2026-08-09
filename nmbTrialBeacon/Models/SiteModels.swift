//
//  SiteModels.swift
//  nmbTrialBeacon
//
//  Site exploration models.
//  v10+: canonical site_id when site tables exist.
//  v9: soft key from facility + city + country (recruiting/detail_z fallback).
//

import CoreLocation
import Foundation

/// What the open `trialbeacon.sqlite` actually supports (Data Status + console).
/// `nonisolated` so `TrialStore` can build / print this under default MainActor isolation.
nonisolated struct DatabaseCapabilityReport: Sendable, Equatable {
    enum SitesQueryPath: String, Sendable, Equatable {
        case canonicalSQL = "canonical SQL (site / trial_site)"
        case v9OnDeviceIndex = "v9 on-device recruiting index (SLOW)"
    }

    let schemaVersion: Int
    let generatorVersion: String?
    let hasOrganisationTables: Bool
    let hasOrganisationActiveTrialCount: Bool
    let hasOrganisationHQ: Bool
    /// Schema v13+: `organisation.linked_publication_count`.
    let hasOrganisationPublicationCounts: Bool
    /// Schema v14+ (or repaired): `site.linked_publication_count` (live join on v13 when absent).
    let hasSitePublicationCounts: Bool
    /// Schema v14+: `popular_condition`.
    let hasPopularCondition: Bool
    /// Schema v14+: `lookup_intervention`.
    let hasLookupIntervention: Bool
    /// Schema v14+: `popular_intervention`.
    let hasPopularIntervention: Bool
    let hasSiteTables: Bool
    let siteRowCount: Int
    let trialSiteRowCount: Int
    /// `(tableName, present)`
    let siteCompanionTables: [(String, Bool)]
    let sitesQueryPath: SitesQueryPath
    /// Schema v13+: `publication` + `trial_publication`.
    let hasPublications: Bool
    let publicationRowCount: Int
    let trialPublicationRowCount: Int
    let publicationCompanionTables: [(String, Bool)]
    /// Schema v13+: `trial_results.linked_publication_count` present.
    let hasTrialResultsPublicationCounts: Bool
    /// Schema v13+: `fda_drug` (may be empty if FDA enrichment skipped).
    let hasFdaDrugs: Bool
    let fdaDrugRowCount: Int
    /// Schema v13+: rows in `trial_drug` (intervention ↔ ingredient links).
    let trialDrugRowCount: Int
    /// Distinct trials with at least one `trial_drug` row.
    let trialsWithFdaLinkCount: Int
    let fdaCompanionTables: [(String, Bool)]
    let databaseFileName: String
    let databaseByteCount: Int64?
    let databaseModifiedAt: Date?

    var sitesReadyLabel: String {
        guard hasSiteTables else { return "No — missing site / trial_site" }
        if siteRowCount == 0 { return "Tables empty (0 sites)" }
        return "Yes — \(siteRowCount) sites"
    }

    var publicationsReadyLabel: String {
        guard hasPublications else { return "No — missing publication tables" }
        if publicationRowCount == 0 { return "Tables empty (0 publications)" }
        return "Yes — \(publicationRowCount.formatted()) publications"
    }

    var fdaReadyLabel: String {
        guard hasFdaDrugs else { return "No — missing fda_drug" }
        if fdaDrugRowCount == 0 { return "Tables empty (0 drugs)" }
        return "Yes — \(fdaDrugRowCount.formatted()) ingredients"
    }

    var fileSizeLabel: String {
        guard let databaseByteCount else { return "—" }
        return Self.formatBytes(databaseByteCount)
    }

    var consoleLine: String {
        let companions = siteCompanionTables
            .map { "\($0.0)=\($0.1 ? "✓" : "✗")" }
            .joined(separator: " ")
        let gen = generatorVersion ?? "?"
        return """
        ℹ️ [TrialStore] DB capability: schema=v\(schemaVersion) generator=\(gen) \
        orgs=\(hasOrganisationTables) active_trial_count=\(hasOrganisationActiveTrialCount) \
        hq=\(hasOrganisationHQ) org_pubs=\(hasOrganisationPublicationCounts) \
        site_pubs=\(hasSitePublicationCounts) popular_condition=\(hasPopularCondition) \
        lookup_intervention=\(hasLookupIntervention) popular_intervention=\(hasPopularIntervention) \
        sites=\(hasSiteTables) site_rows=\(siteRowCount) trial_site_rows=\(trialSiteRowCount) \
        pubs=\(hasPublications) pub_rows=\(publicationRowCount) trial_pub_rows=\(trialPublicationRowCount) \
        results_pub_counts=\(hasTrialResultsPublicationCounts) \
        fda=\(hasFdaDrugs) fda_rows=\(fdaDrugRowCount) trial_drug_rows=\(trialDrugRowCount) \
        trials_with_fda=\(trialsWithFdaLinkCount) \
        path=\(sitesQueryPath.rawValue) file=\(databaseFileName) size=\(fileSizeLabel) \
        companions: \(companions)
        """
    }

    private static func formatBytes(_ n: Int64) -> String {
        let kb = 1024.0
        let value = Double(n)
        if value < kb { return "\(n) B" }
        if value < kb * kb { return String(format: "%.1f KB", value / kb) }
        if value < kb * kb * kb { return String(format: "%.1f MB", value / (kb * kb)) }
        return String(format: "%.2f GB", value / (kb * kb * kb))
    }

    static func == (lhs: DatabaseCapabilityReport, rhs: DatabaseCapabilityReport) -> Bool {
        lhs.schemaVersion == rhs.schemaVersion
            && lhs.generatorVersion == rhs.generatorVersion
            && lhs.hasOrganisationTables == rhs.hasOrganisationTables
            && lhs.hasOrganisationActiveTrialCount == rhs.hasOrganisationActiveTrialCount
            && lhs.hasOrganisationHQ == rhs.hasOrganisationHQ
            && lhs.hasOrganisationPublicationCounts == rhs.hasOrganisationPublicationCounts
            && lhs.hasSitePublicationCounts == rhs.hasSitePublicationCounts
            && lhs.hasPopularCondition == rhs.hasPopularCondition
            && lhs.hasLookupIntervention == rhs.hasLookupIntervention
            && lhs.hasPopularIntervention == rhs.hasPopularIntervention
            && lhs.hasSiteTables == rhs.hasSiteTables
            && lhs.siteRowCount == rhs.siteRowCount
            && lhs.trialSiteRowCount == rhs.trialSiteRowCount
            && lhs.sitesQueryPath == rhs.sitesQueryPath
            && lhs.hasPublications == rhs.hasPublications
            && lhs.publicationRowCount == rhs.publicationRowCount
            && lhs.trialPublicationRowCount == rhs.trialPublicationRowCount
            && lhs.hasTrialResultsPublicationCounts == rhs.hasTrialResultsPublicationCounts
            && lhs.hasFdaDrugs == rhs.hasFdaDrugs
            && lhs.fdaDrugRowCount == rhs.fdaDrugRowCount
            && lhs.trialDrugRowCount == rhs.trialDrugRowCount
            && lhs.trialsWithFdaLinkCount == rhs.trialsWithFdaLinkCount
            && lhs.databaseFileName == rhs.databaseFileName
            && lhs.databaseByteCount == rhs.databaseByteCount
            && lhs.databaseModifiedAt == rhs.databaseModifiedAt
            && lhs.siteCompanionTables.map(\.0) == rhs.siteCompanionTables.map(\.0)
            && lhs.siteCompanionTables.map(\.1) == rhs.siteCompanionTables.map(\.1)
            && lhs.publicationCompanionTables.map(\.0) == rhs.publicationCompanionTables.map(\.0)
            && lhs.publicationCompanionTables.map(\.1) == rhs.publicationCompanionTables.map(\.1)
            && lhs.fdaCompanionTables.map(\.0) == rhs.fdaCompanionTables.map(\.0)
            && lhs.fdaCompanionTables.map(\.1) == rhs.fdaCompanionTables.map(\.1)
    }
}

enum SiteBrowserMode: String, CaseIterable, Identifiable, Sendable, Hashable {
    case search
    case nearby
    case city
    case country
    case highActivity

    var id: String { rawValue }

    var label: String {
        switch self {
        case .search: return "Search"
        case .nearby: return "Nearby"
        case .city: return "City"
        case .country: return "Country"
        case .highActivity: return "High activity"
        }
    }
}

/// Stable identity for navigation / recently viewed across schema versions.
enum SiteRef: Hashable, Sendable {
    /// Schema v10+ unified row.
    case site(Int64)
    /// Schema v9 soft identity (`facility|city|country`).
    case raw(facility: String, city: String?, country: String?)

    var identityKey: String {
        switch self {
        case .site(let id):
            return "site:\(id)"
        case .raw(let facility, let city, let country):
            // Keep original facility spelling for display; lookups use SiteSoftKey.make.
            return "raw:\(facility)|\(city ?? "")|\(country ?? "")"
        }
    }

    /// Soft-merge key used for v9 index membership.
    var softKey: String {
        switch self {
        case .site(let id):
            return "site:\(id)"
        case .raw(let facility, let city, let country):
            return SiteSoftKey.make(facility: facility, city: city, country: country)
        }
    }

    static func parse(identityKey: String) -> SiteRef? {
        if identityKey.hasPrefix("site:"), let id = Int64(identityKey.dropFirst(5)) {
            return .site(id)
        }
        if identityKey.hasPrefix("raw:") {
            let body = String(identityKey.dropFirst(4))
            let parts = body.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { return nil }
            let facility = String(parts[0])
            guard !facility.isEmpty else { return nil }
            let city = parts[1].isEmpty ? nil : String(parts[1])
            let country = parts[2].isEmpty ? nil : String(parts[2])
            return .raw(facility: facility, city: city, country: country)
        }
        return nil
    }
}

nonisolated enum SiteSoftKey {
    /// Conservative soft key — not a fuzzy merge. Generator should use the same idea.
    static func make(facility: String, city: String?, country: String?) -> String {
        let f = normalize(facility)
        let c = normalize(city ?? "")
        let co = normalize(country ?? "")
        return "\(f)|\(c)|\(co)"
    }

    static func normalize(_ raw: String) -> String {
        var s = raw.lowercased()
        s = s.replacingOccurrences(of: "&", with: " and ")
        let allowed = CharacterSet.alphanumerics.union(.whitespaces)
        s = String(s.unicodeScalars.map { allowed.contains($0) ? Character($0) : " " })
        while s.contains("  ") { s = s.replacingOccurrences(of: "  ", with: " ") }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct SiteSummary: Identifiable, Sendable, Hashable {
    let ref: SiteRef
    let displayName: String
    let city: String?
    let state: String?
    let country: String?
    let latitude: Double?
    let longitude: Double?
    let totalRelatedTrialCount: Int
    let recruitingTrialCount: Int
    let phase3TrialCount: Int
    let organisationCount: Int
    /// Populated for nearby browse.
    var distanceMeters: Double?
    /// `false` for the on-device v9 index (built from RECRUITING trials only), so
    /// `totalRelatedTrialCount` equals `recruitingTrialCount` and must not be
    /// shown as a separate “all studies” total.
    var includesNonRecruitingStudies: Bool = true

    var id: String { ref.identityKey }

    var placeLabel: String {
        let parts = [city, state].compactMap { value -> String? in
            guard let value, !value.isEmpty else { return nil }
            return value
        }
        if parts.isEmpty {
            return country ?? ""
        }
        if let country, !country.isEmpty {
            return parts.joined(separator: ", ")
        }
        return parts.joined(separator: ", ")
    }

    var subtitle: String {
        let place = placeLabel
        if place.isEmpty { return country ?? "" }
        if let country, !country.isEmpty, !place.localizedCaseInsensitiveContains(country) {
            return "\(place)"
        }
        return place
    }

    var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude,
              latitude >= -90, latitude <= 90,
              longitude >= -180, longitude <= 180,
              !(latitude == 0 && longitude == 0)
        else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var distanceLabel: String? {
        guard let distanceMeters else { return nil }
        return NearbyDistance.formatMiles(distanceMeters)
    }

    var monogram: String {
        let parts = displayName.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first.map(String.init) }
        return letters.isEmpty ? String(displayName.prefix(1)).uppercased() : letters.joined().uppercased()
    }
}

struct SiteDetail: Identifiable, Sendable, Hashable {
    let summary: SiteSummary
    /// Distinct CTG-linked pubs on trials at this site (precomputed column or live join).
    var linkedPublicationCount: Int = 0
    /// Subset with OpenAlex `is_open_access = 1`.
    var openAccessPublicationCount: Int = 0

    var id: String { summary.id }

    var hasPublicationStats: Bool {
        linkedPublicationCount > 0 || openAccessPublicationCount > 0
    }
}

struct SiteConditionCount: Identifiable, Sendable, Hashable {
    let condition: String
    let trialCount: Int
    var id: String { condition }
}

struct SiteLeadOrganisation: Identifiable, Sendable, Hashable {
    let displayName: String
    let organisationClass: String
    let trialCount: Int
    /// When set, push Organisation detail via unified id.
    let organisationId: Int64?
    /// v9 fallback: lead sponsor name filter.
    let leadSponsorName: String?

    var id: String { "\(displayName)|\(organisationId.map(String.init) ?? leadSponsorName ?? "")" }
}

struct SiteCityGroup: Identifiable, Sendable, Hashable {
    let city: String
    let country: String?
    let siteCount: Int
    let trialCount: Int
    var id: String { "\(city)|\(country ?? "")" }

    var label: String {
        if let country, !country.isEmpty { return "\(city), \(country)" }
        return city
    }
}

struct SiteCountryGroup: Identifiable, Sendable, Hashable {
    let country: String
    let siteCount: Int
    let trialCount: Int
    var id: String { country }
}
