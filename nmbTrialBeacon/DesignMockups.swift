//
//  DesignMockups.swift
//  nmbTrialBeacon
//
//  Discover Matching trials (promoted) and any leftover design explorations.
//

import SwiftData
import SwiftUI

// MARK: - Discover — matching trials (carousel per condition)

/// One carousel per profile condition: lead image → full search, then
/// text cards for active trials matching country / age / sex when set.
struct DiscoverMatchingTrialsMockup: View {
    let profile: UserProfile?

    @Environment(TrialDataService.self) private var data

    @State private var groups: [MatchGroup] = []
    @State private var loaded = false
    @State private var visibleConditionCount = 3

    private struct MatchGroup: Identifiable {
        let condition: String
        let trials: [TrialSummary]
        var id: String { condition }
    }

    private let perCondition = 5
    private let collapsedConditionLimit = 3
    private let expandedConditionCap = 5
    private let cardHeight: CGFloat = 108

    var body: some View {
        let conditions = profile?.conditionsOfInterest.map(\.name) ?? []
        Group {
            if !conditions.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Matching trials")
                        .font(.title2.bold())

                    if !loaded {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                    } else if groups.isEmpty {
                        emptyState(
                            title: "No active matches yet",
                            message: "None of your conditions returned active studies for your age, sex and country."
                        )
                    } else {
                        let visible = Array(groups.prefix(visibleConditionCount))
                        VStack(alignment: .leading, spacing: 20) {
                            ForEach(visible) { group in
                                conditionCarousel(group)
                            }
                        }

                        if groups.count > collapsedConditionLimit {
                            Button {
                                withAnimation(.smooth(duration: 0.25)) {
                                    if visibleConditionCount > collapsedConditionLimit {
                                        visibleConditionCount = collapsedConditionLimit
                                    } else {
                                        visibleConditionCount = min(groups.count, expandedConditionCap)
                                    }
                                }
                            } label: {
                                Text(visibleConditionCount > collapsedConditionLimit
                                      ? "Show less"
                                      : "Show more")
                                    .font(.subheadline.weight(.semibold))
                            }
                            .buttonStyle(.borderless)
                            .padding(.top, 4)
                        }
                    }
                }
                .task(id: loadToken) { await load(conditions: conditions) }
            }
        }
    }

    private var loadToken: String {
        let p = profile
        let conditions = (p?.conditionsOfInterest.map(\.name) ?? []).sorted().joined(separator: "|")
        return [
            conditions,
            p?.country ?? "",
            p?.ageRange ?? "",
            p?.gender ?? ""
        ].joined(separator: "#")
    }

    private func conditionCarousel(_ group: MatchGroup) -> some View {
        let asset = DomainHeroImage.assetName(forCondition: group.condition)
        let searchRoute = DiscoverRoute.trialSearchFiltered(filter(for: group.condition))

        return Group {
            if group.trials.isEmpty {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 10) {
                        NavigationLink(value: searchRoute) {
                            conditionLeadCard(asset: asset, condition: group.condition)
                        }
                        .buttonStyle(.plain)

                        Text("No active studies match your profile for this condition.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: 180, alignment: .leading)
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.viewAligned)
                .scrollIndicators(.hidden)
                .padding(.horizontal, -16)
                .contentMargins(.horizontal, 16, for: .scrollContent)
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 10) {
                        NavigationLink(value: searchRoute) {
                            conditionLeadCard(asset: asset, condition: group.condition)
                        }
                        .buttonStyle(.plain)

                        ForEach(group.trials) { trial in
                            NavigationLink(value: trial.nctId) {
                                trialCard(trial)
                            }
                            .buttonStyle(.plain)
                            .containerRelativeFrame(.horizontal, count: 20, span: 11, spacing: 10)
                            .trialWatchlistContextMenu(nctId: trial.nctId)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.viewAligned)
                .scrollIndicators(.hidden)
                .padding(.horizontal, -16)
                .contentMargins(.horizontal, 16, for: .scrollContent)
            }
        }
    }

    /// Square lead tile — same height as text cards, fixed width (= height).
    private func conditionLeadCard(asset: String, condition: String) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)

        return Image(asset)
            .resizable()
            .scaledToFill()
            .frame(width: cardHeight, height: cardHeight)
            .clipped()
            .overlay(alignment: .bottomLeading) {
                LinearGradient(
                    colors: [.black.opacity(0.55), .clear],
                    startPoint: .bottom,
                    endPoint: .top
                )
                .frame(height: 56)
                .allowsHitTesting(false)
            }
            .overlay(alignment: .bottomLeading) {
                Text(condition)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                    .lineLimit(2)
                    .padding(10)
            }
            .clipShape(shape)
            // Hairline only — settles the photo edge against the lighter text cards.
            .overlay {
                shape.strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
            }
            .contentShape(shape)
            .accessibilityLabel("See all \(condition) trials")
    }

    private func trialCard(_ trial: TrialSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            StatusBadge(status: trial.statusDisplay)
            Text(trial.briefTitle)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: cardHeight, maxHeight: cardHeight, alignment: .topLeading)
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityLabel("\(trial.briefTitle), \(trial.statusDisplay)")
    }

    private func emptyState(title: String, message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
    }

    private func filter(for condition: String) -> TrialFilter {
        var f = TrialFilter()
        f.conditions = [condition]
        f.activeOnly = true
        if let country = profile?.country, !country.isEmpty { f.country = country }
        if let age = profile?.ageRange, !age.isEmpty { f.ageRange = age }
        if let gender = profile?.gender, !gender.isEmpty { f.gender = gender }
        return f
    }

    private func load(conditions: [String]) async {
        loaded = false
        visibleConditionCount = collapsedConditionLimit
        await data.waitUntilReady()
        var used = Set<String>()
        var next: [MatchGroup] = []

        for condition in conditions.prefix(expandedConditionCap) {
            let page = await data.page(
                filter: filter(for: condition),
                sort: .lastUpdatedDesc,
                after: nil,
                limit: 24
            )
            let ranked = page.sorted { a, b in
                let ar = a.overallStatus.uppercased() == "RECRUITING"
                let br = b.overallStatus.uppercased() == "RECRUITING"
                if ar != br { return ar && !br }
                return false
            }
            var picked: [TrialSummary] = []
            for trial in ranked {
                guard !used.contains(trial.nctId) else { continue }
                used.insert(trial.nctId)
                picked.append(trial)
                if picked.count >= perCondition { break }
            }
            next.append(MatchGroup(condition: condition, trials: picked))
        }

        groups = next.contains(where: { !$0.trials.isEmpty }) ? next : []
        loaded = true
    }
}
