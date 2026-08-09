//
//  SmartSearchView.swift
//  nmbTrialBeacon
//
//  Describe what you're looking for in a sentence and get the filters set for
//  you. The model only ever produces filter values — the search itself is the
//  same indexed SQL as everywhere else, so results are identical to setting the
//  filters by hand, and the interpretation is shown before it's applied.
//

import SwiftUI
import FoundationModels

struct SmartSearchView: View {
    /// Whatever is already in the search field, so a half-typed thought carries
    /// over rather than being retyped.
    let initialRequest: String
    let onApply: (TrialFilter, String) -> Void

    @Environment(TrialDataService.self) private var data
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    @State private var request: String
    @State private var phase: Phase = .idle
    @State private var resolved: TrialAIService.ResolvedSearch?

    private enum Phase: Equatable {
        case idle, thinking, ready, failed(String)
    }

    private static let examples = [
        "Recruiting phase 3 breast cancer trials in Canada",
        "Observational studies in children with asthma",
        "Type 2 diabetes trials updated in the last month",
        "Trials for women with migraine that are still enrolling"
    ]

    init(initialRequest: String, onApply: @escaping (TrialFilter, String) -> Void) {
        self.initialRequest = initialRequest
        self.onApply = onApply
        _request = State(initialValue: initialRequest)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    prompt
                    if phase == .idle { exampleList }
                    interpretation
                }
                .padding(20)
            }
            .background(Color(.systemGroupedBackground))
            .scrollEdgeEffectStyle(.soft, for: .top)
            .scrollEdgeEffectStyle(.soft, for: .bottom)
            .navigationTitle("Describe a Search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Search") { apply() }
                        .fontWeight(.semibold)
                        .disabled(resolved?.isEmpty ?? true)
                }
            }
            .onAppear { focused = request.isEmpty }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Pieces

    private var prompt: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("What are you looking for?", text: $request, axis: .vertical)
                .lineLimit(2...5)
                .font(.body)
                .focused($focused)
                .submitLabel(.go)
                .onSubmit { Task { await interpret() } }
                .padding(16)
                .background(Color(.secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous))

            GlassEffectContainer(spacing: 10) {
                HStack {
                    Label("Runs on your device", systemImage: "lock.shield")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button {
                        Task { await interpret() }
                    } label: {
                        if phase == .thinking {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Interpret", systemImage: "sparkles")
                        }
                    }
                    .font(.callout.weight(.medium))
                    .buttonStyle(.glassProminent)
                    .disabled(request.trimmingCharacters(in: .whitespaces).isEmpty || phase == .thinking)
                }
            }
        }
    }

    private var exampleList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Try something like")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            ForEach(Self.examples, id: \.self) { example in
                Button {
                    request = example
                    Task { await interpret() }
                } label: {
                    HStack {
                        Text(example)
                            .font(.callout)
                            .multilineTextAlignment(.leading)
                        Spacer()
                        Image(systemName: "arrow.up.left")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(12)
                .background(Color(.secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    @ViewBuilder
    private var interpretation: some View {
        switch phase {
        case .idle, .thinking:
            EmptyView()

        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.orange)

        case .ready:
            if let resolved {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Understood as")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)

                    if resolved.isEmpty {
                        Text("Nothing recognisable to search on. Try naming a condition, a place or a study phase.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        FlowChips(chips: resolved.filter.activeChips.map { data.displayName(for: $0) }
                                  + (resolved.searchText.isEmpty ? [] : ["“\(resolved.searchText)”"]))
                    }

                    if !resolved.unmatched.isEmpty {
                        Text("No trials are listed under \(resolved.unmatched.joined(separator: ", ")), so that part is being searched as text instead.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(Color(.secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
    }

    // MARK: - Actions

    private func interpret() async {
        let text = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        focused = false
        withAnimation(.smooth(duration: 0.2)) { phase = .thinking }

        do {
            let parsed = try await TrialAIService.shared.parseSearch(text)
            let result = await TrialAIService.shared.resolve(parsed, using: data)
            withAnimation(.smooth(duration: 0.3)) {
                resolved = result
                phase = .ready
            }
        } catch is CancellationError {
            phase = .idle
        } catch {
            print("❌ [TrialAI] search failed: \(error)")
            withAnimation(.smooth(duration: 0.2)) {
                phase = .failed(TrialAIService.userMessage(for: error))
            }
        }
    }

    private func apply() {
        guard let resolved, !resolved.isEmpty else { return }
        onApply(resolved.filter, resolved.searchText)
        dismiss()
    }
}

/// Wrapping row of read-only chips. `Layout` rather than a horizontal scroller
/// because the whole point is seeing every interpreted term at once.
private struct FlowChips: View {
    let chips: [String]

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in
                Text(chip)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.blue.opacity(0.14), in: Capsule())
                    .foregroundStyle(.blue)
            }
        }
    }
}

