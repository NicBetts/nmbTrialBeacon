//
//  ProfileComponents.swift
//  nmbTrialBeacon
//
//  Profile editing sections hosted by Settings. Demographic option lists come
//  from the read-only database's lookup tables (via TrialDataService); the
//  profile itself is SwiftData.
//

import SwiftUI
import SwiftData

// MARK: - Demographics

struct DemographicsSection: View {
    let profile: UserProfile
    let ageRanges: [LookupValue]
    let genders: [LookupValue]
    let countries: [LookupValue]

    var body: some View {
        Picker("Age Range", selection: Binding(
            get: { profile.ageRange },
            set: { profile.ageRange = $0; try? profile.modelContext?.save() })) {
            Text("Not specified").tag(nil as String?)
            ForEach(ageRanges) { Text($0.display).tag($0.value as String?) }
        }

        Picker("Sex", selection: Binding(
            get: { profile.gender },
            set: { profile.gender = $0; try? profile.modelContext?.save() })) {
            Text("Not specified").tag(nil as String?)
            ForEach(genders) { Text($0.display).tag($0.value as String?) }
        }

        NavigationLink {
            SingleSelectList(title: "Country", options: countries, selection: Binding(
                get: { profile.country },
                set: { profile.country = $0; try? profile.modelContext?.save() }))
        } label: {
            LabeledContent("Country", value: profile.country ?? "Not specified")
        }
    }
}

// MARK: - Conditions of interest

struct ConditionsOfInterestSection: View {
    let profile: UserProfile
    let onAddCondition: () -> Void
    let onRemoveCondition: (UserCondition) -> Void

    private let previewLimit = 4

    var body: some View {
        if profile.conditionsOfInterest.isEmpty {
            Button(action: onAddCondition) {
                Label("Add Medical Condition", systemImage: "plus.circle.fill")
            }
        } else if profile.conditionsOfInterest.count > previewLimit {
            NavigationLink {
                SettingsConditionsListView(
                    profile: profile,
                    onAddCondition: onAddCondition,
                    onRemoveCondition: onRemoveCondition
                )
            } label: {
                Label(
                    "\(profile.conditionsOfInterest.count) conditions",
                    systemImage: "heart.text.square"
                )
            }
            Button(action: onAddCondition) {
                Label("Add Another Condition", systemImage: "plus.circle")
            }
        } else {
            ForEach(profile.conditionsOfInterest) { condition in
                conditionRow(condition)
            }
            Button(action: onAddCondition) {
                Label("Add Another Condition", systemImage: "plus.circle")
            }
        }
    }

    private func conditionRow(_ condition: UserCondition) -> some View {
        HStack {
            ConditionDomainIcon(condition: condition.name)
                .foregroundStyle(.secondary)
            Text(condition.name)
            Spacer()
            Button("Remove \(condition.name)", systemImage: "minus.circle.fill", role: .destructive) {
                onRemoveCondition(condition)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .foregroundStyle(.red)
        }
    }
}

struct SettingsConditionsListView: View {
    let profile: UserProfile
    let onAddCondition: () -> Void
    let onRemoveCondition: (UserCondition) -> Void

    var body: some View {
        List {
            ForEach(profile.conditionsOfInterest) { condition in
                HStack {
                    ConditionDomainIcon(condition: condition.name)
                        .foregroundStyle(.secondary)
                    Text(condition.name)
                    Spacer()
                    Button("Remove \(condition.name)", systemImage: "minus.circle.fill", role: .destructive) {
                        onRemoveCondition(condition)
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                }
            }
            Button(action: onAddCondition) {
                Label("Add Another Condition", systemImage: "plus.circle")
            }
        }
        .navigationTitle("Conditions")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct SettingsFavouritesListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \FavouriteOrganisation.favoritedAt, order: .reverse)
    private var favouriteOrgs: [FavouriteOrganisation]
    @Query(sort: \FavouriteSite.favoritedAt, order: .reverse)
    private var favouriteSites: [FavouriteSite]

    var body: some View {
        List {
            if !favouriteOrgs.isEmpty {
                Section("Organisations") {
                    ForEach(favouriteOrgs) { row in
                        if let ref = row.ref {
                            NavigationLink {
                                OrganisationDetailView(ref: ref)
                            } label: {
                                Label(row.displayName, systemImage: "building.2")
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button("Remove", role: .destructive) {
                                    modelContext.delete(row)
                                    try? modelContext.save()
                                }
                            }
                        }
                    }
                }
            }
            if !favouriteSites.isEmpty {
                Section("Sites") {
                    ForEach(favouriteSites) { row in
                        if let ref = row.ref {
                            NavigationLink {
                                SiteDetailView(ref: ref)
                            } label: {
                                Label(row.displayName, systemImage: "mappin.and.ellipse")
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button("Remove", role: .destructive) {
                                    modelContext.delete(row)
                                    try? modelContext.save()
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Favourites")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct PrivacyInfoRow: View {
    let icon: String
    let title: String
    let description: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(.green)
                .font(.body)
                .symbolRenderingMode(.hierarchical)
                .frame(width: 28, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                // Match Form row titles (body), not a smaller subheadline.
                Text(title).font(.body)
                // Footnote is the Settings-standard supporting size (Dynamic Type).
                Text(description).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Condition picker

struct ConditionPickerView: View {
    let profile: UserProfile
    /// The most common conditions, already in memory. Anything beyond this
    /// subset is found by querying the database as the user types.
    let availableConditions: [LookupValue]

    @State private var query = ""
    @State private var searchResults: [LookupValue] = []
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(AIMatchingService.self) private var ai
    @Environment(TrialDataService.self) private var data

    private var filtered: [LookupValue] {
        let existing = Set(profile.conditionsOfInterest.map { $0.name })
        let source = query.isEmpty ? availableConditions : searchResults
        return source.filter { !existing.contains($0.value) }
    }

    var body: some View {
        NavigationStack {
            List(filtered) { condition in
                Button {
                    add(condition.value)
                    dismiss()
                } label: {
                    HStack {
                        ConditionDomainIcon(condition: condition.display)
                            .foregroundStyle(.secondary)
                        Text(condition.display)
                        Spacer()
                        Text(condition.count.formatted()).font(.caption).foregroundStyle(.secondary)
                        Image(systemName: "plus.circle").foregroundStyle(.blue)
                    }
                }
                .tint(.primary)
            }
            .overlay {
                if filtered.isEmpty, !query.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .searchable(text: $query, prompt: "Search conditions")
            .navigationTitle("Add Condition")
            .navigationBarTitleDisplayMode(.inline)
            .task(id: query) {
                guard !query.isEmpty else { return }
                try? await Task.sleep(for: .milliseconds(200))
                if Task.isCancelled { return }
                searchResults = await data.searchConditions(query)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func add(_ name: String) {
        let condition = UserCondition(name: name, userProfile: profile)
        profile.conditionsOfInterest.append(condition)
        modelContext.insert(condition)
        try? modelContext.save()
        ai.invalidateRecommendationsCache()
    }
}
