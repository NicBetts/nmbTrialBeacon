//
//  PulseHighlightSections.swift
//  nmbTrialBeacon
//
//  Shared Pulse cards used on Home. Home owns loading so Featured / Nearby /
//  On This Day / Interesting never duplicate the same NCT.
//

import SwiftUI

// MARK: - On This Day

struct PulseOnThisDaySection: View {
    let item: PulseOnThisDay?
    var loading: Bool = false
    var tablePresent: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("On This Day")
                .font(.title2.bold())

            if loading && item == nil && !tablePresent {
                PulseLoadingRow()
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                    )
            } else if let item {
                PulseSpotlightPhotoBandCard(
                    eyebrow: yearsAgoLine(item),
                    title: item.briefTitle,
                    meta: [
                        item.nctId,
                        item.phaseDisplay,
                        item.primaryCondition,
                        item.hasResults ? "Results available" : nil
                    ],
                    condition: item.primaryCondition,
                    nctId: item.nctId
                )
            } else if !loading {
                PulsePlaceholder(
                    title: "Waiting on database",
                    message: "On This Day uses a shortlist from the next database build."
                )
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
            }
        }
    }

    private func yearsAgoLine(_ item: PulseOnThisDay) -> String {
        switch item.yearsAgo {
        case 0: return "First posted this year · \(String(item.firstPostedYear))"
        case 1: return "First posted 1 year ago · \(String(item.firstPostedYear))"
        default: return "First posted \(item.yearsAgo) years ago · \(String(item.firstPostedYear))"
        }
    }
}

// MARK: - Interesting Trial

struct PulseInterestingTrialSection: View {
    let item: PulseInterestingTrial?
    var loading: Bool = false
    var tablePresent: Bool = true

    @ViewBuilder
    var body: some View {
        // Hidden entirely when Home deduped it against On This Day.
        if let item {
            VStack(alignment: .leading, spacing: 12) {
                Text("Interesting Trial")
                    .font(.title2.bold())
                PulseSpotlightPhotoBandCard(
                    eyebrow: interestingEyebrow(item),
                    title: item.briefTitle,
                    meta: [
                        item.nctId,
                        item.statusDisplay,
                        item.primaryCondition,
                        item.primaryCountry.map { "\(CountryFlag.emoji(for: $0)) \($0)" }
                    ],
                    condition: item.primaryCondition,
                    nctId: item.nctId
                )
            }
        } else if loading {
            VStack(alignment: .leading, spacing: 12) {
                Text("Interesting Trial")
                    .font(.title2.bold())
                PulseLoadingRow()
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                    )
            }
        } else if !tablePresent {
            VStack(alignment: .leading, spacing: 12) {
                Text("Interesting Trial")
                    .font(.title2.bold())
                PulsePlaceholder(
                    title: "Waiting on database",
                    message: "Interesting Trial of the Day lands with the next database build."
                )
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
            }
        }
    }

    private func interestingEyebrow(_ item: PulseInterestingTrial) -> String {
        if let blurb = item.blurb?.trimmingCharacters(in: .whitespacesAndNewlines), !blurb.isEmpty {
            return blurb
        }
        return item.statusDisplay
    }
}

// MARK: - Research Momentum (condition growth)

struct PulseResearchMomentumSection: View {
    @Environment(TrialDataService.self) private var data
    @State private var growth: [PulseConditionGrowth] = []
    @State private var tablePresent = false
    @State private var loading = true

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]
    private let imageHeight: CGFloat = 72
    private let gridLimit = 6
    private let minGrowthRatio = 2.0

    @ViewBuilder
    var body: some View {
        Group {
            if loading && growth.isEmpty && !tablePresent {
                momentumChrome {
                    PulseLoadingRow()
                }
            } else if !growth.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Research Momentum")
                        .font(.title2.bold())

                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(growth) { row in
                            NavigationLink(value: TrialListRequest(
                                title: row.condition,
                                filter: TrialFilter(conditions: [row.condition])
                            )) {
                                momentumCard(row)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(row.condition), \(growthLabel(row)) growth")
                        }
                    }
                }
            } else if !loading && !tablePresent {
                momentumChrome {
                    PulsePlaceholder(
                        title: "Waiting on database",
                        message: "Condition growth ranks appear with the next database build."
                    )
                }
            }
            // Filtered empty (nothing > 2×) → hide the section.
        }
        .task { await load() }
    }

    private func momentumChrome<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Research Momentum")
                .font(.title2.bold())
            content()
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
        }
    }

    private func momentumCard(_ row: PulseConditionGrowth) -> some View {
        let asset = DomainHeroImage.assetName(forCondition: row.condition)

        return VStack(alignment: .leading, spacing: 0) {
            Image(asset)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity)
                .frame(height: imageHeight)
                .clipped()

            VStack(alignment: .leading, spacing: 4) {
                Text(growthLabel(row))
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                    .monospacedDigit()
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)

                Text(row.condition)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
            .background(Color(.secondarySystemGroupedBackground))
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func load() async {
        loading = true
        defer { loading = false }
        await data.waitUntilReady()
        let caps = await data.pulseCapabilities()
        tablePresent = caps.conditionGrowth
        let raw = await data.pulseConditionGrowth(limit: 24)
        let qualified = raw.filter { row in
            guard let ratio = row.growthRatio, ratio.isFinite else { return false }
            return ratio > minGrowthRatio
        }
        var next = Array(qualified.prefix(gridLimit))
        if next.count % 2 == 1 {
            next.removeLast()
        }
        growth = next
    }

    private func growthLabel(_ row: PulseConditionGrowth) -> String {
        if let ratio = row.growthRatio, ratio.isFinite {
            if ratio >= 10 { return String(format: "%.0f×", ratio) }
            return String(format: "%.1f×", ratio)
        }
        let sign = row.absDelta >= 0 ? "+" : ""
        return "\(sign)\(row.absDelta.formatted())"
    }
}

// MARK: - Shared chrome

/// Split card: domain photo band + text. Used by On This Day and Interesting Trial.
struct PulseSpotlightPhotoBandCard: View {
    let eyebrow: String
    let title: String
    let meta: [String?]
    let condition: String?
    let nctId: String

    /// Shared with Recruiting Near You — not a system size; ~100 reads well with title + meta.
    private let bandHeight: CGFloat = 100
    private let titleBlockHeight: CGFloat = 40

    var body: some View {
        let assetName = DomainHeroImage.assetName(forCondition: condition)

        NavigationLink(value: nctId) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .bottomLeading) {
                    Image(assetName)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity)
                        .frame(height: bandHeight)
                        .clipped()

                    LinearGradient(
                        colors: [.black.opacity(0.5), .clear],
                        startPoint: .bottom,
                        endPoint: .top
                    )
                    .allowsHitTesting(false)

                    Text(eyebrow)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                        .lineLimit(1)
                        .padding(12)
                }
                .frame(height: bandHeight)
                .clipped()

                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, minHeight: titleBlockHeight, alignment: .topLeading)

                    HStack(spacing: 4) {
                        if let condition, !condition.isEmpty {
                            Image(systemName: ConditionDomainCatalog.shared.symbolName(for: condition))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .symbolRenderingMode(.hierarchical)
                        }
                        PulseMetaRow(parts: meta)
                    }
                }
                .padding(EdgeInsets(top: 12, leading: 16, bottom: 16, trailing: 16))
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemGroupedBackground))
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .trialWatchlistContextMenu(nctId: nctId)
    }
}

struct PulseFeatureSection<Content: View>: View {
    let title: String
    var contentInsets: EdgeInsets = EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title2.bold())

            content
                .padding(contentInsets)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
        }
    }
}

struct PulsePlaceholder: View {
    let title: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct PulseLoadingRow: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Loading…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

struct PulseMetaRow: View {
    let parts: [String?]

    var body: some View {
        let shown = parts.compactMap { part -> String? in
            guard let part, !part.isEmpty else { return nil }
            return part
        }
        if !shown.isEmpty {
            Text(shown.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}
