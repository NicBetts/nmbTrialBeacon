//
//  SaveSearchSheet.swift
//  nmbTrialBeacon
//
//  Name a saved search. Seeds from filter chips (and AI when available); the
//  user can edit before saving. Re-saving the same filter + query updates
//  the existing row instead of creating a duplicate.
//

import SwiftData
import SwiftUI

struct SaveSearchSheet: View {
    let filter: TrialFilter
    let query: String
    let sort: TrialSort
    let scope: TrialSearchScope
    let chipLabels: [String]
    /// Existing row when this filter + query is already saved (rename / update).
    var existing: SavedSearch? = nil
    var onSaved: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var userEditedName = false
    @State private var trackEdits = false
    @State private var isSuggesting = false
    @State private var atLimit = false
    @State private var saveFailed = false

    private var isUpdating: Bool { existing != nil }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (!filter.isEmpty || !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private var nameBinding: Binding<String> {
        Binding(
            get: { name },
            set: { newValue in
                name = newValue
                if trackEdits { userEditedName = true }
            }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: nameBinding)
                        .textInputAutocapitalization(.words)
                } footer: {
                    if atLimit {
                        Text("You already have \(SavedSearches.storageLimit) saved searches. Delete one on Discover to save another.")
                    } else if isSuggesting {
                        Text("Suggesting a short name…")
                    } else if isUpdating {
                        Text("This search is already saved. You can rename it here.")
                    } else {
                        Text("Saved searches keep filters, sort, and any search text.")
                    }
                }

                if !chipLabels.isEmpty || !query.isEmpty {
                    Section("Includes") {
                        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            LabeledContent("Search") {
                                Text(query)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.trailing)
                            }
                        }
                        ForEach(chipLabels, id: \.self) { label in
                            Text(label)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle(isUpdating ? "Saved Search" : "Save Search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isUpdating ? "Update" : "Save") { save() }
                        .disabled(!canSave || atLimit)
                }
            }
            .alert("Couldn’t Save", isPresented: $saveFailed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(
                    atLimit
                    ? "Delete a saved search on Discover, then try again."
                    : "Check the name and try again."
                )
            }
            .task { await seedName() }
        }
        .presentationDetents([.medium])
    }

    private func seedName() async {
        let matched = existing ?? SavedSearches.match(
            filter: filter,
            query: query,
            context: modelContext
        )
        atLimit = !isUpdating
            && matched == nil
            && SavedSearches.isAtLimit(context: modelContext)

        if let matched {
            name = matched.name
            userEditedName = false
            trackEdits = true
            return
        }

        let fallback = SavedSearches.fallbackName(chipLabels: chipLabels, query: query)
        name = fallback
        userEditedName = false
        trackEdits = true

        guard TrialAIService.shared.isReady else { return }
        isSuggesting = true
        let suggested = await TrialAIService.shared.suggestSavedSearchTitle(
            chipLabels: chipLabels,
            query: query,
            fallback: fallback
        )
        isSuggesting = false
        if !userEditedName {
            trackEdits = false
            name = suggested
            trackEdits = true
        }
    }

    private func save() {
        let row = SavedSearches.save(
            name: name,
            filter: filter,
            query: query,
            sort: sort,
            scope: scope,
            context: modelContext
        )
        if row != nil {
            onSaved()
            dismiss()
        } else {
            atLimit = SavedSearches.isAtLimit(context: modelContext)
            saveFailed = true
        }
    }
}
