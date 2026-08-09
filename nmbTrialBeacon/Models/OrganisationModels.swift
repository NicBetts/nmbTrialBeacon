//
//  OrganisationModels.swift
//  nmbTrialBeacon
//
//  Organisation exploration models.
//  v9: lead sponsor (by name) and collaborator (by id) as separate refs.
//  v10+: optional unified organisation_id when those tables exist.
//

import Foundation

nonisolated enum OrganisationCategory: String, CaseIterable, Identifiable, Sendable, Hashable {
    case all
    case industry
    case academicMedical
    case government
    case other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "All"
        case .industry: return "Industry"
        case .academicMedical: return "Academic & Medical"
        case .government: return "Government"
        case .other: return "Other"
        }
    }

    /// SF Symbol for list rows / filters.
    var systemImage: String {
        switch self {
        case .all: return "building.2"
        case .industry: return "briefcase.fill"
        case .academicMedical: return "cross.case.fill"
        case .government: return "building.columns.fill"
        case .other: return "building.fill"
        }
    }

    /// Maps CTG agency_class tokens into display buckets.
    static func category(forAgencyClass raw: String?) -> OrganisationCategory {
        switch (raw ?? "").uppercased() {
        case "INDUSTRY": return .industry
        case "OTHER_GOV", "NIH", "FED", "NETWORK": return .government
        case "OTHER": return .academicMedical
        case "INDIV", "UNKNOWN", "": return .other
        default: return .other
        }
    }
}

/// Stable identity for navigation / recently viewed across schema versions.
nonisolated enum OrganisationRef: Hashable, Sendable {
    /// Schema v10+ unified row.
    case organisation(Int64)
    /// Schema v9 lead sponsor (`trial.lead_sponsor_name`).
    case leadSponsor(String)
    /// Schema v9 collaborator (`lookup_collaborator.collaborator_id`).
    case collaborator(Int64)

    var identityKey: String {
        switch self {
        case .organisation(let id): return "org:\(id)"
        case .leadSponsor(let name): return "lead:\(name)"
        case .collaborator(let id): return "collab:\(id)"
        }
    }

    static func parse(identityKey: String) -> OrganisationRef? {
        if identityKey.hasPrefix("org:"), let id = Int64(identityKey.dropFirst(4)) {
            return .organisation(id)
        }
        if identityKey.hasPrefix("lead:") {
            return .leadSponsor(String(identityKey.dropFirst(5)))
        }
        if identityKey.hasPrefix("collab:"), let id = Int64(identityKey.dropFirst(6)) {
            return .collaborator(id)
        }
        return nil
    }
}

struct OrganisationSummary: Identifiable, Sendable, Hashable {
    let ref: OrganisationRef
    let displayName: String
    let organisationClass: String
    let category: OrganisationCategory
    let totalRelatedTrialCount: Int
    /// `trial.is_active = 1` — Recruiting, Not yet recruiting, Enrolling by invitation, Active not recruiting.
    let activeTrialCount: Int
    let recruitingTrialCount: Int
    let logoAssetName: String?
    /// Lead-only / collaborator-only / both (when known).
    var roleHint: RoleHint = .unknown

    enum RoleHint: String, Sendable, Hashable {
        case unknown, leadSponsor, collaborator, both
    }

    var id: String { ref.identityKey }

    var classLabel: String {
        switch category {
        case .all: return organisationClass
        case .industry: return "Industry"
        case .academicMedical: return "Academic & Medical"
        case .government: return "Government"
        case .other:
            return organisationClass.isEmpty
                ? "Other"
                : organisationClass.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    var monogram: String {
        let parts = displayName.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first.map(String.init) }
        return letters.isEmpty ? String(displayName.prefix(1)).uppercased() : letters.joined().uppercased()
    }
}

/// Curated headquarters (schema 11+). Never invent from trial footprint countries.
/// `nonisolated` so `TrialStore` can build these under default MainActor isolation.
nonisolated struct OrganisationHeadquarters: Sendable, Hashable {
    let country: String?
    let addressLine: String?
    let city: String?
    let region: String?
    let postalCode: String?
    let website: String?
    let source: String?

    /// `hq_country` is the minimum bar for “has address”.
    var hasAddress: Bool {
        guard let country, !country.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return true
    }

    var hasWebsite: Bool {
        guard let website, !website.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return true
    }

    var isEmpty: Bool { !hasAddress && !hasWebsite }

    /// Locality line without country (city, region, postal).
    var localityLine: String? {
        var parts: [String] = []
        if let city, !city.isEmpty { parts.append(city) }
        if let region, !region.isEmpty { parts.append(region) }
        if let postalCode, !postalCode.isEmpty { parts.append(postalCode) }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// Display lines for the HQ block (street → locality → country).
    var addressLines: [String] {
        guard hasAddress else { return [] }
        var lines: [String] = []
        if let addressLine, !addressLine.isEmpty { lines.append(addressLine) }
        if let localityLine { lines.append(localityLine) }
        if let country, !country.isEmpty {
            lines.append("\(CountryFlag.emoji(for: country)) \(country)".trimmingCharacters(in: .whitespaces))
        }
        return lines
    }

    /// Enough place detail to drop a meaningful pin (city or street — not country alone).
    var isMappable: Bool {
        hasAddress && (
            !(city ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !(addressLine ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
    }

    /// Locality/address only (no organisation name) — used as a city bias for POI search.
    var localityGeocodeQuery: String? {
        guard isMappable else { return nil }
        var parts: [String] = []
        if let addressLine, !addressLine.isEmpty { parts.append(addressLine) }
        if let city, !city.isEmpty { parts.append(city) }
        if let region, !region.isEmpty { parts.append(region) }
        if let postalCode, !postalCode.isEmpty { parts.append(postalCode) }
        if let country, !country.isEmpty { parts.append(country) }
        let q = parts.joined(separator: ", ")
        return q.isEmpty ? nil : q
    }

    /// Prefer “Org, City, Country” so geocoding / Maps resolve the POI, not city centre.
    func geocodeQuery(organisationName: String) -> String? {
        let name = organisationName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let locality = localityGeocodeQuery else { return nil }
        return "\(name), \(locality)"
    }
}

struct OrganisationDetail: Identifiable, Sendable, Hashable {
    let summary: OrganisationSummary
    let leadSponsorTrialCount: Int
    let collaboratorTrialCount: Int
    let completedTrialCount: Int
    let terminatedTrialCount: Int
    let phase1TrialCount: Int
    let phase2TrialCount: Int
    let phase3TrialCount: Int
    let phase4TrialCount: Int
    let countryCount: Int
    let siteCount: Int?
    let resultsAvailableCount: Int
    let firstPostedYear: Int?
    let mostRecentUpdateDate: Date?
    let newTrialCount30d: Int
    let recentlyUpdatedRecruitingCount30d: Int
    let recentlyUpdatedCompletedCount30d: Int
    let recentlyUpdatedTerminatedCount30d: Int
    /// Schema 11+ curated HQ; nil when columns absent or not curated.
    var headquarters: OrganisationHeadquarters? = nil
    /// Schema 13+: distinct CTG-linked publications on this org’s related trials.
    var linkedPublicationCount: Int = 0
    /// Schema 13+: subset with OpenAlex `is_open_access = 1` (0 until enrichment).
    var openAccessPublicationCount: Int = 0

    var id: String { summary.id }

    var hasPublicationStats: Bool {
        linkedPublicationCount > 0 || openAccessPublicationCount > 0
    }
}

struct OrganisationConditionCount: Identifiable, Sendable, Hashable {
    let condition: String
    let trialCount: Int
    var id: String { condition }
}

struct OrganisationCountryCount: Identifiable, Sendable, Hashable {
    let country: String
    let trialCount: Int
    var id: String { country }
}
