//
//  SharedComponents.swift
//  nmbTrialBeacon
//
//  Reusable UI building blocks shared across screens.
//

import SwiftUI

// MARK: - Status Badge

struct StatusBadge: View {
    let status: String   // display text, e.g. "Recruiting"

    var body: some View {
        Text(status)
            .font(.caption).fontWeight(.semibold)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.16), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color { StatusPalette.color(for: status) }
}

enum StatusPalette {
    static func color(for status: String) -> Color {
        switch status.lowercased() {
        case let s where s.contains("recruiting") && !s.contains("not"):
            return .green
        case "completed":
            return .blue
        case "not yet recruiting":
            return .orange
        case let s where s.contains("active"):
            return .teal
        case "suspended", "terminated", "withdrawn":
            return .red
        case "enrolling by invitation":
            return .purple
        default:
            return .gray
        }
    }
}

// MARK: - Phase chip

struct PhaseChip: View {
    let phase: String

    var body: some View {
        Text(phase)
            .font(.caption).fontWeight(.medium)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.purple.opacity(0.15), in: Capsule())
            .foregroundStyle(.purple)
    }
}

// MARK: - Reusable trial row

enum TrialRowDateKind: Sendable {
    /// `last_update_post_date` — default browse sort and search results.
    case lastUpdated
    /// `first_posted_date` — "Newly added" sort.
    case firstPosted
}

enum TrialSummaryRowChrome {
    /// Rounded grouped card — sheets / watchlist-style surfaces.
    case card
    /// Flat list content for Liquid Glass pages — separators come from the List.
    case plain
}

struct TrialSummaryRow: View {
    let summary: TrialSummary
    var showsSnippet: Bool = true
    /// Subtle trailing date; `nil` hides it (e.g. watchlist can omit).
    var dateKind: TrialRowDateKind? = .lastUpdated
    var chrome: TrialSummaryRowChrome = .card

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(summary.nctId)
                    .font(.caption).fontWeight(.medium)
                    .foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: 6) {
                    StatusBadge(status: summary.statusDisplay)
                    if let phase = summary.phaseDisplay { PhaseChip(phase: phase) }
                }
            }

            Text(summary.briefTitle)
                .font(.subheadline).fontWeight(.semibold)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .lineLimit(2)

            if showsSnippet, let snippet = summary.summarySnippet, !snippet.isEmpty {
                Text(snippet)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }

            HStack(alignment: .bottom, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    if let condition = summary.primaryCondition {
                        ConditionLabel(condition: condition)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let country = summary.primaryCountry {
                        Label {
                            Text("\(country) \(CountryFlag.emoji(for: country))")
                        } icon: {
                            Image(systemName: "mappin.and.ellipse")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                if let dateKind, let label = dateLabel(for: dateKind) {
                    Text(label)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(2)
                }
            }
        }
        .padding(chrome == .card ? 16 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if chrome == .card {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            }
        }
    }

    private func dateLabel(for kind: TrialRowDateKind) -> String? {
        switch kind {
        case .lastUpdated:
            if let display = summary.lastUpdateDisplay { return display }
            return summary.lastUpdatePostDate.formattedWithUserPreference()
        case .firstPosted:
            if let display = summary.firstPostedDisplay { return display }
            guard let date = summary.firstPostedDate else {
                return summary.lastUpdateDisplay
                    ?? summary.lastUpdatePostDate.formattedWithUserPreference()
            }
            return date.formattedWithUserPreference()
        }
    }
}

// MARK: - Loading

struct LoadingStateView: View {
    let title: String

    var body: some View {
        VStack(spacing: 16) {
            ProgressView().controlSize(.large)
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Empty state

struct EmptyResultsView: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: icon)
        } description: {
            Text(message)
        }
    }
}

// MARK: - Country flags

nonisolated enum CountryFlag {
    static func emoji(for countryName: String) -> String {
        let trimmed = countryName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let flag = flags[canonical(trimmed)] { return flag }
        // Registry often uses "Turkey (Türkiye)", "Congo (Kinshasa)", etc.
        if let open = trimmed.range(of: " ("), trimmed.hasSuffix(")") {
            let base = String(trimmed[..<open.lowerBound])
            if let flag = flags[canonical(base)] { return flag }
        }
        return "🌍"
    }

    private static func canonical(_ name: String) -> String {
        variations[name] ?? name
    }

    private static let variations: [String: String] = [
        "Russian Federation": "Russia", "USA": "United States", "US": "United States",
        "United States of America": "United States", "America": "United States",
        "Great Britain": "United Kingdom", "Britain": "United Kingdom", "England": "United Kingdom",
        "Scotland": "United Kingdom", "Wales": "United Kingdom", "Northern Ireland": "United Kingdom",
        "People's Republic of China": "China", "PRC": "China",
        "Korea, South": "South Korea", "Korea, Republic of": "South Korea",
        "Republic of Korea": "South Korea", "Korea, North": "North Korea",
        "Democratic People's Republic of Korea": "North Korea",
        "Islamic Republic of Iran": "Iran", "Czechia": "Czech Republic",
        "The Netherlands": "Netherlands", "Holland": "Netherlands",
        "Turkey (Türkiye)": "Turkey", "Türkiye": "Turkey", "Turkiye": "Turkey",
        "Republic of Türkiye": "Turkey", "Republic of Turkey": "Turkey",
        "Viet Nam": "Vietnam", "Burma": "Myanmar", "Ivory Coast": "Côte d’Ivoire",
        "Cote d'Ivoire": "Côte d’Ivoire", "Côte d'Ivoire": "Côte d’Ivoire",
        "Cape Verde": "Cabo Verde", "Swaziland": "Eswatini",
        "Macedonia": "North Macedonia", "Republic of Moldova": "Moldova",
        "Syrian Arab Republic": "Syria", "Lao People's Democratic Republic": "Laos",
        "Brunei Darussalam": "Brunei", "Macao": "Macau", "Macao SAR": "Macau",
        "Hong Kong SAR": "Hong Kong", "Taiwan, Province of China": "Taiwan",
        "Bolivia (Plurinational State of)": "Bolivia",
        "Venezuela (Bolivarian Republic of)": "Venezuela",
        "Tanzania, United Republic of": "Tanzania",
        "Congo, The Democratic Republic of the": "Democratic Republic of the Congo",
        "Congo, Democratic Republic of the": "Democratic Republic of the Congo",
        "DR Congo": "Democratic Republic of the Congo", "DRC": "Democratic Republic of the Congo",
        "Congo": "Republic of the Congo", "Congo, Republic of the": "Republic of the Congo",
        "Palestinian Territory": "Palestinian Territories",
        "Occupied Palestinian Territory": "Palestinian Territories",
        "Palestine": "Palestinian Territories", "The Gambia": "Gambia",
        "Slovak Republic": "Slovakia", "East Timor": "Timor-Leste",
        "Netherlands Antilles": "Netherlands",
    ]

    private static let flags: [String: String] = [
        "United States": "🇺🇸", "Canada": "🇨🇦", "Brazil": "🇧🇷", "Mexico": "🇲🇽", "Argentina": "🇦🇷",
        "Chile": "🇨🇱", "Colombia": "🇨🇴", "Peru": "🇵🇪", "United Kingdom": "🇬🇧", "Germany": "🇩🇪",
        "France": "🇫🇷", "Italy": "🇮🇹", "Spain": "🇪🇸", "Netherlands": "🇳🇱", "Belgium": "🇧🇪",
        "Switzerland": "🇨🇭", "Austria": "🇦🇹", "Sweden": "🇸🇪", "Norway": "🇳🇴", "Denmark": "🇩🇰",
        "Finland": "🇫🇮", "Poland": "🇵🇱", "Czech Republic": "🇨🇿", "Hungary": "🇭🇺", "Portugal": "🇵🇹",
        "Greece": "🇬🇷", "Turkey": "🇹🇷", "Russia": "🇷🇺", "Ukraine": "🇺🇦", "Ireland": "🇮🇪",
        "China": "🇨🇳", "Japan": "🇯🇵", "South Korea": "🇰🇷", "North Korea": "🇰🇵", "India": "🇮🇳",
        "Indonesia": "🇮🇩", "Thailand": "🇹🇭", "Vietnam": "🇻🇳", "Philippines": "🇵🇭",
        "Malaysia": "🇲🇾", "Singapore": "🇸🇬", "Taiwan": "🇹🇼", "Hong Kong": "🇭🇰", "Macau": "🇲🇴",
        "Israel": "🇮🇱", "Saudi Arabia": "🇸🇦", "United Arab Emirates": "🇦🇪", "Egypt": "🇪🇬",
        "South Africa": "🇿🇦", "Australia": "🇦🇺", "New Zealand": "🇳🇿", "Pakistan": "🇵🇰",
        "Romania": "🇷🇴", "Bulgaria": "🇧🇬", "Puerto Rico": "🇵🇷", "Slovakia": "🇸🇰",
        "Serbia": "🇷🇸", "Croatia": "🇭🇷", "Lithuania": "🇱🇹", "Slovenia": "🇸🇮", "Estonia": "🇪🇪",
        "Latvia": "🇱🇻", "Iran": "🇮🇷", "Iraq": "🇮🇶", "Uganda": "🇺🇬", "Georgia": "🇬🇪",
        "Kenya": "🇰🇪", "Bangladesh": "🇧🇩", "Lebanon": "🇱🇧", "Jordan": "🇯🇴", "Tunisia": "🇹🇳",
        "Tanzania": "🇹🇿", "Nigeria": "🇳🇬", "Nepal": "🇳🇵", "Guatemala": "🇬🇹", "Panama": "🇵🇦",
        "Moldova": "🇲🇩", "Malawi": "🇲🇼", "Belarus": "🇧🇾", "Ethiopia": "🇪🇹", "Zambia": "🇿🇲",
        "Cyprus": "🇨🇾", "Bosnia and Herzegovina": "🇧🇦", "Syria": "🇸🇾", "Ghana": "🇬🇭",
        "Kazakhstan": "🇰🇿", "Costa Rica": "🇨🇷", "Dominican Republic": "🇩🇴", "Qatar": "🇶🇦",
        "Burkina Faso": "🇧🇫", "Iceland": "🇮🇸", "Ecuador": "🇪🇨", "North Macedonia": "🇲🇰",
        "Zimbabwe": "🇿🇼", "Kuwait": "🇰🇼", "Mali": "🇲🇱", "Venezuela": "🇻🇪",
        "Democratic Republic of the Congo": "🇨🇩", "Republic of the Congo": "🇨🇬",
        "Morocco": "🇲🇦", "Luxembourg": "🇱🇺", "Cameroon": "🇨🇲", "Rwanda": "🇷🇼",
        "Mozambique": "🇲🇿", "Cambodia": "🇰🇭", "Oman": "🇴🇲", "Honduras": "🇭🇳",
        "Senegal": "🇸🇳", "Armenia": "🇦🇲", "Botswana": "🇧🇼", "Sri Lanka": "🇱🇰",
        "Algeria": "🇩🇿", "Uruguay": "🇺🇾", "Monaco": "🇲🇨", "Paraguay": "🇵🇾",
        "Gambia": "🇬🇲", "Palestinian Territories": "🇵🇸", "Uzbekistan": "🇺🇿",
        "Jamaica": "🇯🇲", "Côte d’Ivoire": "🇨🇮", "Cabo Verde": "🇨🇻", "Eswatini": "🇸🇿",
        "Myanmar": "🇲🇲", "Laos": "🇱🇦", "Brunei": "🇧🇳", "Timor-Leste": "🇹🇱",
        "Turkmenistan": "🇹🇲", "Martinique": "🇲🇶", "Reunion": "🇷🇪", "Guadeloupe": "🇬🇵",
    ]
}

// MARK: - Flow layout (wrapping chips)

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = layout(subviews: subviews, width: width)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in layout(subviews: subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y),
                                      proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row {
        var indices: [Int] = []
        var y: CGFloat = 0
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func layout(subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        var x: CGFloat = 0

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !current.indices.isEmpty, x + size.width > width {
                rows.append(current)
                current = Row(y: current.y + current.height + spacing)
                x = 0
            }
            current.indices.append(index)
            x += size.width + spacing
            current.width = max(current.width, x - spacing)
            current.height = max(current.height, size.height)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

// MARK: - ClinicalTrials.gov attribution

/// Source credit, independence, methodology pointer, and medical/staleness
/// caveats. Full text for Settings / About; compact for trial detail footers.
enum ClinicalTrialsAttribution {
    static let attributionLine =
        "TrialBeacon uses publicly available study information from ClinicalTrials.gov, a service of the U.S. National Library of Medicine. TrialBeacon is independent and is not affiliated with or endorsed by ClinicalTrials.gov, NLM, NIH or the U.S. Government."

    static let methodologyLine =
        "ClinicalTrials.gov records are supplied by study sponsors and investigators. TrialBeacon prepares a curated offline snapshot of that public catalog for search and discovery in the app."

    static let cautionLine =
        "Trial information can change after the TrialBeacon database snapshot. Users should consult the current ClinicalTrials.gov record and speak with an appropriate healthcare professional before making medical or study-participation decisions."

    static let clinicalTrialsURL = URL(string: "https://clinicaltrials.gov")!
}

struct ClinicalTrialsAttributionBlock: View {
    /// Compact for detail footers; fuller for Settings / About.
    var compact: Bool = false

    var body: some View {
        let font: Font = compact ? .caption : .footnote
        VStack(alignment: .leading, spacing: compact ? 6 : 8) {
            Text(ClinicalTrialsAttribution.attributionLine)
            if !compact {
                Text(ClinicalTrialsAttribution.methodologyLine)
            }
            Text(ClinicalTrialsAttribution.cautionLine)
        }
        .font(font)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }
}
