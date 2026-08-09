//
//  AnalyticsView.swift
//  nmbTrialBeacon
//
//  Rankings come from precomputed aggregate tables (agg_dimension_count,
//  agg_year_count, agg_condition_by_year), plus live top-lead-sponsor /
//  top-collaborator queries for Analytics. Dimension taps push a filtered list.
//
//  Liquid Glass (iOS 26+): glass is reserved for the filter controls that float
//  above content. Rankings, charts and overview numbers stay on standard
//  grouped surfaces so we never stack glass on glass.
//

import SwiftUI
import Charts

struct AnalyticsView: View {
    @Environment(TrialDataService.self) private var data

    @State private var activeOnly = false
    /// Schema v6: selects `*_excl_healthy` aggregate scopes (precomputed).
    @State private var excludeHealthy = false
    @State private var conditions: [DimensionCount] = []
    @State private var countries: [DimensionCount] = []
    @State private var sponsors: [DimensionCount] = []
    @State private var collaborators: [DimensionCount] = []
    @State private var phases: [DimensionCount] = []
    @State private var studyTypes: [DimensionCount] = []
    @State private var genders: [DimensionCount] = []
    @State private var statuses: [DimensionCount] = []
    @State private var conditionByYear: [ConditionByYear] = []
    @State private var years: [YearCount] = []
    @State private var loading = true
    /// Default windows trim history for readability; this reveals the full past.
    @State private var showEarlierYears = false

    private var scope: AggScope {
        // Older DBs lack excl-healthy scopes — fall back to all/active and
        // leave population labels in the condition rankings.
        if data.supportsExclHealthyAggregates {
            return AggScope.resolve(activeOnly: activeOnly, excludeHealthy: excludeHealthy)
        }
        return activeOnly ? .active : .all
    }

    private var scopeKey: String { "\(activeOnly)-\(excludeHealthy)" }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    OverviewStatsSection(activeOnly: activeOnly, excludeHealthy: excludeHealthy)

                    if !years.isEmpty {
                        StartYearSection(years: years, showEarlierYears: $showEarlierYears)
                    }

                    AnalyticsSection(
                        title: "Top Conditions", icon: "cross.case.fill", color: .red,
                        kind: .condition, data: conditions, loading: loading,
                        activeOnly: activeOnly, collapsible: true
                    )
                    if !conditionByYear.isEmpty {
                        ConditionByYearSection(rows: conditionByYear, showEarlierYears: $showEarlierYears)
                    }
                    AnalyticsSection(
                        title: "Top Countries", icon: "globe", color: .blue,
                        kind: .country, data: countries, loading: loading,
                        activeOnly: activeOnly, collapsible: true
                    )
                    AnalyticsSection(
                        title: "Top Sponsors", icon: "building.2.fill", color: .indigo,
                        kind: .leadSponsor, data: sponsors, loading: loading,
                        activeOnly: activeOnly, collapsible: true
                    )
                    if data.supportsCollaborators || !collaborators.isEmpty {
                        AnalyticsSection(
                            title: "Top Collaborators", icon: "person.3.fill", color: .mint,
                            kind: .collaborator, data: collaborators, loading: loading,
                            activeOnly: activeOnly, collapsible: true
                        )
                    }
                    AnalyticsSection(
                        title: "Study Phases", icon: "number.circle.fill", color: .purple,
                        kind: .phase, data: phases, loading: loading,
                        activeOnly: activeOnly
                    )
                    AnalyticsSection(
                        title: "Study Types", icon: "doc.text.fill", color: .orange,
                        kind: .studyType, data: studyTypes, loading: loading,
                        activeOnly: activeOnly
                    )
                    AnalyticsSection(
                        title: "Sex Eligibility", icon: "person.2.fill", color: .green,
                        kind: .gender, data: genders, loading: loading,
                        activeOnly: activeOnly
                    )
                    AnalyticsSection(
                        title: "Trial Status", icon: "circle.fill", color: .teal,
                        kind: .status, data: statuses, loading: loading,
                        activeOnly: activeOnly
                    )
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            // Soft fade under the floating nav title / tab bar glass.
            .scrollEdgeEffectStyle(.soft, for: .top)
            .scrollEdgeEffectStyle(.soft, for: .bottom)
            .navigationTitle("Analytics")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Toggle("Active only", isOn: $activeOnly)
                        if data.supportsExclHealthyAggregates {
                            Toggle("Exclude healthy volunteers", isOn: $excludeHealthy)
                        }
                    } label: {
                        Image(systemName: filtersMenuSymbol)
                    }
                    .accessibilityLabel("Analytics filters")
                }
            }
            .trialNavigationDestinations()
            .task(id: scopeKey) { await load() }
        }
    }

    private var filtersMenuSymbol: String {
        if activeOnly || excludeHealthy {
            return "line.3.horizontal.decrease.circle.fill"
        }
        return "line.3.horizontal.decrease.circle"
    }

    private func load() async {
        loading = true
        async let c = data.dimensionCounts(.condition, scope: scope, limit: 10)
        async let co = data.dimensionCounts(.country, scope: scope, limit: 10)
        async let sp = data.topLeadSponsors(activeOnly: activeOnly, limit: 10)
        async let col = data.topCollaborators(activeOnly: activeOnly, limit: 10)
        async let p = data.dimensionCounts(.phase, scope: scope, limit: 10)
        async let st = data.dimensionCounts(.studyType, scope: scope, limit: 10)
        async let g = data.dimensionCounts(.gender, scope: scope, limit: 10)
        async let s = data.dimensionCounts(.status, scope: scope, limit: 10)
        async let y = data.yearCounts(scope: scope)
        // Top 2 shown per year; fetch a little headroom for the section.
        async let cby = data.topConditionByYear(scope: scope, maxRank: 3)
        conditions = await c
        countries = await co
        sponsors = await sp
        collaborators = await col
        phases = await p
        studyTypes = await st
        genders = await g
        statuses = await s
        years = await y
        conditionByYear = await cby
        loading = false
    }
}

/// Ranking row kind — includes precomputed agg dimensions plus live sponsor/collaborator lists.
private enum AnalyticsRankKind: Hashable {
    case condition, country, phase, studyType, gender, status
    case leadSponsor, collaborator
}

// MARK: - Overview

private struct OverviewStatsSection: View {
    let activeOnly: Bool
    let excludeHealthy: Bool
    @Environment(TrialDataService.self) private var data

    private var total: Int {
        guard let s = data.stats else { return 0 }
        if excludeHealthy, s.hasExclHealthyTotals {
            if activeOnly {
                return (s.recruitingCountExclHealthy ?? 0) + (s.activeNotRecruitingCountExclHealthy ?? 0)
            }
            return s.totalTrialsExclHealthy ?? s.totalTrials
        }
        return activeOnly ? (s.recruitingCount + s.activeNotRecruitingCount) : s.totalTrials
    }

    private var active: Int {
        guard let s = data.stats else { return 0 }
        if excludeHealthy, s.hasExclHealthyTotals {
            return (s.recruitingCountExclHealthy ?? 0) + (s.activeNotRecruitingCountExclHealthy ?? 0)
        }
        return s.recruitingCount + s.activeNotRecruitingCount
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Overview")
                .font(.title2.bold())

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                OverviewCard(title: activeOnly ? "Active Trials" : "Total Trials", value: total.formatted(), icon: "flask.fill", color: .blue)
                OverviewCard(title: "Active Studies", value: active.formatted(), icon: "play.circle.fill", color: .green)
                OverviewCard(title: "Countries", value: data.countryTotal.formatted(), icon: "globe", color: .orange)
                OverviewCard(title: "Conditions", value: data.conditionTotal.formatted(), icon: "cross.case.fill", color: .red)
            }
        }
    }
}

private struct OverviewCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(value).font(.title2.bold())
                    .contentTransition(.numericText())
                    .minimumScaleFactor(0.6).lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: icon)
                    .foregroundStyle(color)
                    .symbolRenderingMode(.hierarchical)
            }
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - Section

private struct AnalyticsSection: View {
    let title: String
    let icon: String
    let color: Color
    let kind: AnalyticsRankKind
    let data: [DimensionCount]
    let loading: Bool
    var activeOnly: Bool = false
    /// Top 5 initially; “Show more” reveals up to 10.
    var collapsible: Bool = false

    private static let previewCount = 5
    private static let expandedCount = 10

    @Environment(TrialDataService.self) private var dataService
    @State private var expanded = false

    private var total: Int { data.reduce(0) { $0 + $1.count } }

    private var visible: [DimensionCount] {
        let limit = collapsible
            ? (expanded ? Self.expandedCount : Self.previewCount)
            : Self.expandedCount
        return Array(data.prefix(limit))
    }

    private var canExpand: Bool {
        collapsible && data.count > Self.previewCount
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(.title2.bold())
                .labelStyle(TintedIconLabelStyle(tint: color))

            VStack(alignment: .leading, spacing: 4) {
                if loading && data.isEmpty {
                    ForEach(0..<4, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color(.tertiarySystemFill))
                            .frame(height: 18)
                            .padding(.vertical, 4)
                    }
                } else if data.isEmpty {
                    Text("No data available").font(.subheadline).foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, item in
                        NavigationLink(value: TrialListRequest(
                            title: listTitle(for: item),
                            filter: filter(for: item)
                        )) {
                            HStack(spacing: 10) {
                                Text("\(index + 1)")
                                    .font(.caption).fontWeight(.semibold)
                                    .foregroundStyle(index == 0 ? .white : .secondary)
                                    .frame(width: 22, height: 22)
                                    .background(index == 0 ? color : Color(.tertiarySystemFill), in: Circle())
                                if kind == .condition {
                                    ConditionDomainIcon(condition: displayName(for: item))
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .frame(width: 18, alignment: .center)
                                }
                                Text(label(for: item))
                                    .font(.subheadline).lineLimit(1)
                                    .foregroundStyle(.primary)
                                Spacer(minLength: 0)
                                Text(percent(item.count))
                                    .font(.subheadline).fontWeight(.medium)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Shows matching trials")
                    }

                    if canExpand {
                        Button {
                            withAnimation(.smooth(duration: 0.2)) { expanded.toggle() }
                        } label: {
                            Text(expanded ? "Show less" : "Show more")
                                .font(.subheadline.weight(.medium))
                        }
                        .buttonStyle(.borderless)
                        .padding(.top, 4)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .onChange(of: data.map(\.id)) { _, _ in
            expanded = false
        }
    }

    private func displayName(for item: DimensionCount) -> String {
        switch kind {
        case .condition, .country, .phase, .studyType, .gender, .status:
            if let agg = aggDimension {
                return dataService.displayName(for: agg, value: item.value)
            }
            return item.label
        case .leadSponsor, .collaborator:
            return item.label
        }
    }

    private func label(for item: DimensionCount) -> String {
        let name = displayName(for: item)
        if kind == .country {
            return "\(name) \(CountryFlag.emoji(for: item.value))"
        }
        return name
    }

    private func listTitle(for item: DimensionCount) -> String {
        let name = displayName(for: item)
        return activeOnly ? "\(name) · active" : name
    }

    private var aggDimension: AggDimension? {
        switch kind {
        case .condition: return .condition
        case .country:   return .country
        case .phase:     return .phase
        case .studyType: return .studyType
        case .gender:    return .gender
        case .status:    return .status
        case .leadSponsor, .collaborator: return nil
        }
    }

    private func filter(for item: DimensionCount) -> TrialFilter {
        var filter = TrialFilter()
        filter.activeOnly = activeOnly
        switch kind {
        case .condition:    filter.conditions = [item.value]
        case .country:      filter.country = item.value
        case .phase:        filter.phase = item.value
        case .studyType:    filter.studyType = item.value
        case .gender:       filter.gender = item.value
        case .status:       filter.status = item.value
        case .leadSponsor:  filter.leadSponsor = item.value
        case .collaborator: filter.collaborators = [item.value]
        }
        return filter
    }

    private func percent(_ count: Int) -> String {
        guard total > 0 else { return count.formatted() }
        return "\(count.formatted()) (\(Int((Double(count) / Double(total) * 100).rounded()))%)"
    }
}

private struct StartYearSection: View {
    let years: [YearCount]
    @Binding var showEarlierYears: Bool

    /// Default: last 25 years (phone-readable). Expanded: history from
    /// `earliestCredibleYear` through the current year. Future starts stay hidden.
    ///
    /// Years before 1950 exist in the registry (including a `1900` placeholder)
    /// but are not credible chart history — ClinicalTrials.gov’s own era of
    /// recorded start dates begins in the mid‑1950s. We do not invent years;
    /// we omit those sparse/outlier buckets from the chart.
    private static let recentWindowYears = 25
    private static let earliestCredibleYear = 1950

    private var recent: [YearCount] {
        let thisYear = Self.currentYear
        let earliest = showEarlierYears
            ? Self.earliestCredibleYear
            : max(Self.earliestCredibleYear, thisYear - (Self.recentWindowYears - 1))
        return years
            .filter { $0.year >= earliest && $0.year <= thisYear && $0.count > 0 }
            .sorted { $0.year < $1.year }
    }

    private var hasEarlierYears: Bool {
        let recentCutoff = max(Self.earliestCredibleYear, Self.currentYear - (Self.recentWindowYears - 1))
        return years.contains {
            $0.year >= Self.earliestCredibleYear && $0.year < recentCutoff && $0.count > 0
        }
    }

    /// Thin labels harder when the expanded history packs many bars.
    private var labelledYears: [String] {
        let step = recent.count > 40 ? 10 : (recent.count > 25 ? 5 : 2)
        return recent.map(\.year).filter { $0.isMultiple(of: step) }.map(String.init)
    }

    private var hasFutureStarts: Bool { years.contains { $0.year > Self.currentYear && $0.count > 0 } }

    private static var currentYear: Int { Calendar.current.component(.year, from: Date()) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Trials by Start Year", systemImage: "chart.bar.fill")
                .font(.title2.bold())
                .labelStyle(TintedIconLabelStyle(tint: .blue))

            VStack(alignment: .leading, spacing: 10) {
                Chart(recent) { item in
                    BarMark(
                        x: .value("Year", String(item.year)),
                        y: .value("Trials", item.count)
                    )
                    .foregroundStyle(Color.blue.gradient)
                    .cornerRadius(3)
                    .accessibilityLabel(String(item.year))
                    .accessibilityValue("\(item.count.formatted()) trials")
                }
                .chartXAxis {
                    AxisMarks(values: labelledYears) { value in
                        AxisTick()
                        AxisValueLabel(collisionResolution: .disabled, orientation: .vertical) {
                            if let year = value.as(String.self) {
                                Text(year).font(.caption2).fixedSize()
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let count = value.as(Int.self) {
                                Text(count.formatted(.number.notation(.compactName))).font(.caption2)
                            }
                        }
                    }
                }
                .frame(height: 210)

                if hasEarlierYears || showEarlierYears {
                    Button {
                        showEarlierYears.toggle()
                    } label: {
                        Text(showEarlierYears ? "Show recent years" : "Show earlier years")
                            .font(.subheadline.weight(.medium))
                    }
                    .buttonStyle(.borderless)
                }

                if hasFutureStarts {
                    Text("Studies with start dates after \(String(Self.currentYear)) are not shown.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if showEarlierYears {
                    Text("Start years before \(Self.earliestCredibleYear) are omitted (registry placeholders / sparse outliers).")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}

private struct ConditionByYearSection: View {
    let rows: [ConditionByYear]
    @Binding var showEarlierYears: Bool

    private static let recentWindowYears = 15
    private static let earliestCredibleYear = 1950

    /// Top 2 in equal columns. Default: newest 15 years; expanded: from 1950.
    private var years: [(year: Int, conditions: [String])] {
        let thisYear = Calendar.current.component(.year, from: Date())
        let filtered = rows.filter {
            $0.year >= Self.earliestCredibleYear && $0.year <= thisYear
        }
        let grouped = Dictionary(grouping: filtered, by: \.year)
        let sortedKeys = grouped.keys.sorted(by: >)
        let keys = showEarlierYears ? sortedKeys : Array(sortedKeys.prefix(Self.recentWindowYears))
        return keys.compactMap { year in
            let names = (grouped[year] ?? [])
                .sorted { $0.rank < $1.rank }
                .prefix(2)
                .map(\.condition)
            guard !names.isEmpty else { return nil }
            return (year, Array(names))
        }
    }

    private var hasEarlierYears: Bool {
        let thisYear = Calendar.current.component(.year, from: Date())
        let past = Set(rows.map(\.year).filter {
            $0 >= Self.earliestCredibleYear && $0 <= thisYear
        }).sorted(by: >)
        return past.count > Self.recentWindowYears
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Top Conditions by Year", systemImage: "calendar.badge.clock")
                .font(.title2.bold())
                .labelStyle(TintedIconLabelStyle(tint: .indigo))

            VStack(alignment: .leading, spacing: 10) {
                ForEach(years, id: \.year) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(String(entry.year))
                            .font(.subheadline.bold())
                            .foregroundStyle(.indigo)
                            .frame(width: 44, alignment: .leading)

                        ForEach(0..<2, id: \.self) { index in
                            Group {
                                if index < entry.conditions.count {
                                    HStack(spacing: 4) {
                                        ConditionDomainIcon(condition: entry.conditions[index])
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Text(entry.conditions[index])
                                            .foregroundStyle(.primary)
                                    }
                                } else {
                                    Text("—")
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .font(.subheadline)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(entry.year). \(entry.conditions.joined(separator: ", "))")
                }

                if hasEarlierYears || showEarlierYears {
                    Button {
                        showEarlierYears.toggle()
                    } label: {
                        Text(showEarlierYears ? "Show recent years" : "Show earlier years")
                            .font(.subheadline.weight(.medium))
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}

private struct TintedIconLabelStyle: LabelStyle {
    let tint: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon
                .foregroundStyle(tint)
                .symbolRenderingMode(.hierarchical)
            configuration.title
        }
    }
}
