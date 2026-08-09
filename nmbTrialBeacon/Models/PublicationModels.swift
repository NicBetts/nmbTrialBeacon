//
//  PublicationModels.swift
//  nmbTrialBeacon
//
//  Schema v13: ClinicalTrials.gov reference publications (+ OpenAlex enrichment
//  fields filled at database build time). No live network enrichment in the app.
//

import Foundation

struct TrialPublication: Identifiable, Sendable, Hashable {
    let publicationID: Int64
    let pmid: String?
    let doi: String?
    let openAlexID: String?
    let title: String?
    let journalName: String?
    let publicationDate: Date?
    let publicationYear: Int?
    /// Exact ClinicalTrials.gov `reference_type` enum (e.g. RESULT, BACKGROUND).
    let referenceType: String
    let sourceCitation: String?
    let isOpenAccess: Bool?
    let openAccessStatus: String?
    let landingPageURL: String?
    let openAccessURL: String?
    let isRetracted: Bool
    let retractionCount: Int
    let enrichmentStatus: String

    /// Same paper can appear under multiple reference types.
    var id: String { "\(publicationID)|\(referenceType)" }

    var referenceTypeDisplay: String {
        Self.displayLabel(for: referenceType)
    }

    var isCitationOnly: Bool {
        enrichmentStatus == "citation_only"
            || ((title == nil || title?.isEmpty == true)
                && !(sourceCitation ?? "").isEmpty)
    }

    /// Primary line for the row.
    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        if let citation = sourceCitation, !citation.isEmpty { return citation }
        if let doi, !doi.isEmpty { return doi }
        if let pmid, !pmid.isEmpty { return "PMID \(pmid)" }
        return "ClinicalTrials.gov reference"
    }

    var showsRetractionWarning: Bool {
        isRetracted || retractionCount > 0
    }

    /// Best external destination for a user tap. Nil → row is not a link.
    var bestExternalURL: URL? {
        if let raw = openAccessURL?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty,
           let url = Self.url(from: raw) {
            return url
        }
        if let doi, !doi.isEmpty {
            let trimmed = doi.trimmingCharacters(in: .whitespacesAndNewlines)
            let path = trimmed.lowercased().hasPrefix("http") ? trimmed : "https://doi.org/\(trimmed)"
            if let url = Self.url(from: path) { return url }
        }
        if let pmid, !pmid.isEmpty {
            let id = pmid.trimmingCharacters(in: .whitespacesAndNewlines)
            if let url = URL(string: "https://pubmed.ncbi.nlm.nih.gov/\(id)/") { return url }
        }
        if let raw = landingPageURL?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty,
           let url = Self.url(from: raw) {
            return url
        }
        if let openAlexID, !openAlexID.isEmpty {
            let trimmed = openAlexID.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.lowercased().hasPrefix("http"), let url = Self.url(from: trimmed) {
                return url
            }
            let id = trimmed.hasPrefix("W") || trimmed.hasPrefix("w") ? trimmed : "W\(trimmed)"
            if let url = URL(string: "https://openalex.org/\(id)") { return url }
        }
        return nil
    }

    static func displayLabel(for referenceType: String) -> String {
        switch referenceType.uppercased() {
        case "RESULT": return "Results publication"
        case "BACKGROUND": return "Background reference"
        case "DERIVED": return "Derived reference"
        default:
            let raw = referenceType.replacingOccurrences(of: "_", with: " ")
            return raw.localizedCapitalized.isEmpty ? referenceType : raw.localizedCapitalized
        }
    }

    private static func url(from string: String) -> URL? {
        guard let url = URL(string: string), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        return url
    }
}

struct PublicationRetraction: Identifiable, Sendable, Hashable {
    let retractionPMID: String
    let retractionSource: String

    var id: String { "\(retractionPMID)|\(retractionSource)" }
}
