//
//  ClinicalResearchPulseView.swift
//  nmbTrialBeacon
//
//  Clinical Research Pulse — insights surface presented from Home.
//  Keeps the 30-day activity sentence + Trial Status Watch. Home already
//  surfaces On This Day / Interesting Trial / Research Momentum.
//
//  Liquid Glass (iOS 26+): glass on chrome / controls only. Content uses
//  standard grouped surfaces so we never stack glass on glass.
//

import SwiftUI

struct ClinicalResearchPulseView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(TrialDataService.self) private var data

    @State private var statusWatch: [PulseStatusWatchTab: [PulseStoppedTrial]] = [:]
    @State private var statusTab: PulseStatusWatchTab = .completed
    @State private var recentActivity: PulseRecentActivity?
    @State private var loading = true

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 28) {
                    PulseRecentActivityHeader(activity: recentActivity, loading: loading && recentActivity == nil)

                    PulseFeatureSection(title: "Trial Status Watch") {
                        statusWatchContent
                    }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .scrollEdgeEffectStyle(.soft, for: .top)
            .scrollEdgeEffectStyle(.soft, for: .bottom)
            .navigationTitle("Clinical Research Pulse")
            .navigationBarTitleDisplayMode(.large)
            .trialNavigationDestinations()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .task { await load() }
        }
    }

    @ViewBuilder
    private var statusWatchContent: some View {
        let rows = statusWatch[statusTab] ?? []
        VStack(alignment: .leading, spacing: 12) {
            Picker("Status", selection: $statusTab) {
                ForEach(PulseStatusWatchTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)

            if loading && statusWatch.isEmpty {
                PulseLoadingRow()
            } else if rows.isEmpty {
                Text("No \(statusTab.title.lowercased()) records updated this month.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, item in
                        NavigationLink(value: item.nctId) {
                            StatusWatchRow(item: item)
                        }
                        .buttonStyle(.plain)

                        if index < rows.count - 1 {
                            Divider().opacity(0.35)
                        }
                    }
                }
            }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        await data.waitUntilReady()

        async let activity = data.pulseRecentActivity()

        var watch: [PulseStatusWatchTab: [PulseStoppedTrial]] = [:]
        await withTaskGroup(of: (PulseStatusWatchTab, [PulseStoppedTrial]).self) { group in
            for tab in PulseStatusWatchTab.allCases {
                group.addTask {
                    let rows = await data.pulseStatusWatch(status: tab.rawValue, withinDays: 30, limit: 5)
                    return (tab, rows)
                }
            }
            for await (tab, rows) in group {
                watch[tab] = rows
            }
        }

        recentActivity = await activity
        statusWatch = watch
    }
}

// MARK: - Recent activity (editorial line, not a KPI strip)

private struct PulseRecentActivityHeader: View {
    let activity: PulseRecentActivity?
    let loading: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Group {
                if loading {
                    PulseLoadingRow()
                } else if let activity {
                    activityLine(activity)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityElement(children: .combine)
                }
            }

            Divider()
                .opacity(0.45)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 4)
    }

    private func activityLine(_ a: PulseRecentActivity) -> Text {
        Text("In the last 30 days, \(emphasized(a.newTrials)) new trials were posted, \(emphasized(a.beganRecruiting)) began recruiting, \(emphasized(a.completed)) completed, and \(emphasized(a.terminated)) were terminated.")
    }

    private func emphasized(_ value: Int) -> Text {
        Text(value.formatted())
            .font(.body.weight(.semibold).monospacedDigit())
            .foregroundStyle(.primary)
    }
}

// MARK: - Status Watch row

private struct StatusWatchRow: View {
    let item: PulseStoppedTrial

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            statusBadge

            Text(item.briefTitle)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            if item.overallStatus == "COMPLETED" {
                HStack(spacing: 4) {
                    if let condition = item.primaryCondition, !condition.isEmpty {
                        ConditionDomainIcon(condition: condition)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    PulseMetaRow(parts: [
                        item.nctId,
                        item.primaryCondition,
                        item.leadSponsorName
                    ])
                }
                if let updated = item.lastUpdateLabel {
                    Text("Updated \(updated)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if item.hasResults {
                    Text("Results available")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            } else {
                if let why = item.whyStopped, !why.isEmpty {
                    Text("Reason: \(why)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let updated = item.lastUpdateLabel {
                    Text("Updated \(updated)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }

    private var statusBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(badgeColor)
                .frame(width: 8, height: 8)
            Text(badgeLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(badgeColor)
        }
    }

    private var badgeLabel: String {
        if item.overallStatus == "COMPLETED", let phase = item.phaseDisplay, !phase.isEmpty {
            return phase
        }
        return item.statusDisplay
    }

    private var badgeColor: Color {
        switch item.overallStatus {
        case "COMPLETED": return .green
        case "TERMINATED": return .red
        case "SUSPENDED": return .orange
        case "WITHDRAWN": return Color.primary.opacity(0.55)
        default: return .secondary
        }
    }
}

#Preview {
    ClinicalResearchPulseView()
        .environment(TrialDataService.shared)
}
