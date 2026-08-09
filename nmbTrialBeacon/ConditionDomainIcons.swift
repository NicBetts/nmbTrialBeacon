//
//  ConditionDomainIcons.swift
//  nmbTrialBeacon
//
//  Domain-level SF Symbols for condition labels (beta). Classification is
//  keyword-based against the bundled mapping CSV until the generator stores
//  a reviewed domain beside each condition.
//

import SwiftUI
import UIKit

// MARK: - Settings key

enum ConditionDomainIcons {
    static let enabledKey = "conditionDomainIconsEnabled"
    /// Generic symbol used when the beta toggle is off (current shipping look).
    static let genericSymbol = "cross.case"
}

// MARK: - Domain model

struct ConditionDomain: Identifiable, Hashable, Sendable {
    let name: String
    let primarySymbol: String
    let fallbackSymbol: String
    let description: String
    /// Keyword terms used for on-device classification (lowercase).
    let matchTerms: [String]

    var id: String { name }
}

// MARK: - Catalog

@MainActor
final class ConditionDomainCatalog {
    static let shared = ConditionDomainCatalog()

    private(set) var domains: [ConditionDomain] = []
    /// Longest-term-first flat index for matching.
    private var terms: [(term: String, domainIndex: Int)] = []
    private var cache: [String: ConditionDomain] = [:]
    private var otherDomain: ConditionDomain?

    private init() {
        load()
    }

    func domain(for condition: String) -> ConditionDomain? {
        let key = condition.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return otherDomain }
        if let cached = cache[key] { return cached }
        let matched = match(key) ?? otherDomain
        cache[key] = matched
        return matched
    }

    /// Prefer the primary SF Symbol; fall back when UIKit reports it unavailable.
    func symbolName(for condition: String) -> String {
        guard let domain = domain(for: condition) else {
            return ConditionDomainIcons.genericSymbol
        }
        if UIImage(systemName: domain.primarySymbol) != nil {
            return domain.primarySymbol
        }
        if UIImage(systemName: domain.fallbackSymbol) != nil {
            return domain.fallbackSymbol
        }
        return ConditionDomainIcons.genericSymbol
    }

    private func match(_ lowered: String) -> ConditionDomain? {
        // Longest keyword wins so "sleep apnea" beats "sleep", etc.
        for entry in terms where lowered.contains(entry.term) {
            return domains[entry.domainIndex]
        }
        return nil
    }

    private func load() {
        guard let url = Bundle.main.url(
            forResource: "trialbeacon_condition_domain_mapping",
            withExtension: "csv"
        ),
        let text = try? String(contentsOf: url, encoding: .utf8)
        else {
            domains = [Self.builtinOther]
            otherDomain = domains[0]
            return
        }

        var parsed: [ConditionDomain] = []
        for (lineIndex, rawLine) in text.split(whereSeparator: \.isNewline).enumerated() {
            if lineIndex == 0 { continue } // header
            let fields = Self.parseCSVLine(String(rawLine))
            guard fields.count >= 4 else { continue }
            let name = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let termsField = fields.count > 4 ? fields[4] : ""
            let matchTerms = termsField
                .split(separator: "|")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
            parsed.append(ConditionDomain(
                name: name,
                primarySymbol: fields[1].trimmingCharacters(in: .whitespacesAndNewlines),
                fallbackSymbol: fields[2].trimmingCharacters(in: .whitespacesAndNewlines),
                description: fields[3].trimmingCharacters(in: .whitespacesAndNewlines),
                matchTerms: matchTerms
            ))
        }

        if parsed.isEmpty {
            domains = [Self.builtinOther]
        } else {
            domains = parsed
        }
        otherDomain = domains.first { $0.name.hasPrefix("Other") } ?? domains.last

        var indexed: [(String, Int)] = []
        for (index, domain) in domains.enumerated() {
            for term in domain.matchTerms {
                indexed.append((term, index))
            }
        }
        indexed.sort { $0.0.count > $1.0.count }
        terms = indexed
    }

    private static let builtinOther = ConditionDomain(
        name: "Other / Unclassified",
        primarySymbol: "cross.case",
        fallbackSymbol: "questionmark.circle",
        description: "Fallback when no medical domain can be assigned confidently",
        matchTerms: []
    )

    /// Minimal quoted-field CSV parser (handles `"Ear, Nose & Throat"`).
    nonisolated static func parseCSVLine(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var i = line.startIndex
        while i < line.endIndex {
            let ch = line[i]
            if ch == "\"" {
                let next = line.index(after: i)
                if inQuotes, next < line.endIndex, line[next] == "\"" {
                    current.append("\"")
                    i = next
                } else {
                    inQuotes.toggle()
                }
            } else if ch == ",", !inQuotes {
                fields.append(current)
                current = ""
            } else {
                current.append(ch)
            }
            i = line.index(after: i)
        }
        fields.append(current)
        return fields
    }
}

// MARK: - Views

/// Condition text with a domain SF Symbol when the beta toggle is on.
/// When off: either the generic medical symbol (rows that already shipped
/// with `cross.case`) or plain text (`showGenericWhenDisabled = false`).
struct ConditionLabel: View {
    let condition: String
    var lineLimit: Int? = 1
    /// Keep the shipping `cross.case` glyph when the beta feature is off.
    var showGenericWhenDisabled: Bool = true

    @AppStorage(ConditionDomainIcons.enabledKey) private var enabled = false

    var body: some View {
        Group {
            if enabled {
                Label {
                    Text(condition)
                } icon: {
                    Image(systemName: ConditionDomainCatalog.shared.symbolName(for: condition))
                        .symbolRenderingMode(.hierarchical)
                }
            } else if showGenericWhenDisabled {
                Label(condition, systemImage: ConditionDomainIcons.genericSymbol)
            } else {
                Text(condition)
            }
        }
        .lineLimit(lineLimit)
    }
}

/// Icon-only glyph for compact rows. Hidden when the beta toggle is off so
/// existing layouts don’t gain a new symbol until the feature is enabled.
struct ConditionDomainIcon: View {
    let condition: String

    @AppStorage(ConditionDomainIcons.enabledKey) private var enabled = false

    var body: some View {
        if enabled {
            Image(systemName: ConditionDomainCatalog.shared.symbolName(for: condition))
                .symbolRenderingMode(.hierarchical)
                .accessibilityHidden(true)
        }
    }
}

// MARK: - Beta preview

struct ConditionDomainPreviewView: View {
    private let catalog = ConditionDomainCatalog.shared

    var body: some View {
        List {
            Section {
                Text("Each condition is mapped to a medical domain and shown with that domain’s SF Symbol. Classification is keyword-based for this beta; a reviewed domain column in the database will replace it later.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Section("Domains") {
                ForEach(catalog.domains) { domain in
                    HStack(spacing: 12) {
                        Image(systemName: resolvedSymbol(for: domain))
                            .font(.title3)
                            .foregroundStyle(.tint)
                            .frame(width: 28, alignment: .center)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(domain.name)
                                .font(.body.weight(.medium))
                            Text(domain.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            Section("Sample conditions") {
                ForEach(Self.sampleConditions, id: \.self) { condition in
                    HStack(spacing: 12) {
                        ConditionDomainIcon(condition: condition)
                            .font(.title3)
                            .foregroundStyle(.tint)
                            .frame(width: 28, alignment: .center)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(condition)
                            if let domain = catalog.domain(for: condition) {
                                Text(domain.name)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Condition Icons")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func resolvedSymbol(for domain: ConditionDomain) -> String {
        if UIImage(systemName: domain.primarySymbol) != nil { return domain.primarySymbol }
        if UIImage(systemName: domain.fallbackSymbol) != nil { return domain.fallbackSymbol }
        return ConditionDomainIcons.genericSymbol
    }

    private static let sampleConditions = [
        "Melanoma",
        "Type 2 Diabetes Mellitus",
        "Alzheimer Disease",
        "Heart Failure",
        "Asthma",
        "Major Depressive Disorder",
        "Crohn's Disease",
        "Rheumatoid Arthritis",
        "COVID-19",
        "Healthy Volunteers",
        "Obstructive Sleep Apnea",
        "Chronic Kidney Disease"
    ]
}
