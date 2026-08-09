//
//  OnboardingView.swift
//  nmbTrialBeacon
//
//  Shown once, before the main shell. Its only real job is collecting a few
//  conditions of interest: without them the Home screen opens on an empty
//  recommendations slot, which is the weakest possible first impression.
//  Everything here is skippable and editable later in Settings.
//

import SwiftUI
import SwiftData

struct OnboardingView: View {
    @Environment(TrialDataService.self) private var data
    @Environment(\.modelContext) private var modelContext
    @Query private var profiles: [UserProfile]

    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    /// An explicit step rather than a paged `TabView`: the condition step hosts a
    /// searchable `List`, whose own gestures and search presentation fight the
    /// pager's horizontal swipe.
    private enum Step { case welcome, conditions }

    @State private var step: Step = .welcome
    @State private var selected: Set<String> = []
    @State private var query = ""
    @State private var searchResults: [LookupValue] = []

    private var suggestions: [LookupValue] {
        query.isEmpty ? Array(data.conditions.prefix(30)) : searchResults
    }

    var body: some View {
        ZStack {
            switch step {
            case .welcome:
                welcome.transition(.opacity.combined(with: .move(edge: .leading)))
            case .conditions:
                conditions.transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .background(Color(.systemGroupedBackground))
        .animation(.smooth(duration: 0.3), value: step)
    }

    // MARK: - Pages

    private var welcome: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "cross.case.circle.fill")
                .font(.system(size: 84))
                .foregroundStyle(.blue.gradient)
                .symbolEffect(.bounce, options: .nonRepeating)

            VStack(spacing: 10) {
                Text("Welcome to TrialBeacon")
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)
                Text("Search \(data.totalTrials.formatted()) clinical trials from ClinicalTrials.gov — entirely on your device, with no account and no network.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: 16) {
                OnboardingPoint(icon: "magnifyingglass",
                                title: "Search instantly",
                                message: "Full-text search across every study, offline.")
                OnboardingPoint(icon: "bookmark.fill",
                                title: "Track what matters",
                                message: "Save trials to your watchlist and add private notes.")
                OnboardingPoint(icon: "lock.fill",
                                title: "Private by design",
                                message: "Nothing you enter ever leaves this device.")
            }
            .padding(.top, 8)

            Spacer()

            Button {
                step = .conditions
            } label: {
                Text("Get Started").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
        }
        .padding(28)
    }

    private var conditions: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Text("What are you interested in?")
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                Text("Pick any conditions to get suggestions on your Home screen. You can change these any time.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 28)
            .padding(.top, 32)
            .padding(.bottom, 16)

            List {
                if !selected.isEmpty {
                    Section("Selected") {
                        ForEach(Array(selected).sorted(), id: \.self) { value in
                            ConditionRow(title: value, count: nil, isSelected: true) {
                                selected.remove(value)
                            }
                        }
                    }
                }

                Section(query.isEmpty ? "Most studied" : "Results") {
                    if suggestions.isEmpty, !query.isEmpty {
                        Text("No conditions match “\(query)”.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(suggestions.filter { !selected.contains($0.value) }) { item in
                        ConditionRow(title: item.display, count: item.count, isSelected: false) {
                            selected.insert(item.value)
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "Search conditions")
            .scrollEdgeEffectStyle(.soft, for: .bottom)
            .sensoryFeedback(.selection, trigger: selected)

            GlassEffectContainer(spacing: 10) {
                VStack(spacing: 10) {
                    Button {
                        finish()
                    } label: {
                        Text(selected.isEmpty ? "Continue" : "Continue with \(selected.count)")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)

                    if !selected.isEmpty {
                        Button("Skip for now") { selected = []; finish() }
                            .font(.subheadline)
                            .buttonStyle(.glass)
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 28)
        }
        .task(id: query) {
            guard !query.isEmpty else { searchResults = []; return }
            try? await Task.sleep(for: .milliseconds(200))
            if Task.isCancelled { return }
            searchResults = await data.searchConditions(query, limit: 60)
        }
    }

    // MARK: - Completion

    private func finish() {
        let profile = profiles.first ?? {
            let new = UserProfile()
            modelContext.insert(new)
            return new
        }()

        for value in selected where !profile.conditionsOfInterest.contains(where: { $0.name == value }) {
            modelContext.insert(UserCondition(name: value, userProfile: profile))
        }
        try? modelContext.save()

        withAnimation(.smooth) { hasCompletedOnboarding = true }
    }
}

/// A tappable row that still reads as content. A bare `Button` in a `List`
/// tints its whole label blue, which made every condition look like a link.
private struct ConditionRow: View {
    let title: String
    let count: Int?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                ConditionDomainIcon(condition: title)
                    .foregroundStyle(.secondary)
                Text(title)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                if let count {
                    Text(count.formatted())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Image(systemName: isSelected ? "checkmark.circle.fill" : "plus.circle")
                    .foregroundStyle(isSelected ? .blue : .secondary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

private struct OnboardingPoint: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.blue)
                .symbolRenderingMode(.hierarchical)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}
