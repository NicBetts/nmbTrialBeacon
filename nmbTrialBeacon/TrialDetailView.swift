//
//  TrialDetailView.swift
//  nmbTrialBeacon
//
//  Loads a single trial's full detail on demand from the read-only database
//  (by NCT id). Watchlist membership and notes are the only mutable state and
//  live in SwiftData.
//

import SwiftUI
import SwiftData
import MapKit

struct TrialDetailView: View {
    let nctId: String
    let preloadedSummary: TrialSummary?

    @Environment(TrialDataService.self) private var data
    @Environment(\.modelContext) private var modelContext

    @State private var detail: TrialDetail?
    @State private var isLoading = true
    @State private var watchlistItem: WatchlistItem?
    @State private var showingNotes = false
    @State private var publications: [TrialPublication] = []
    @State private var fdaIngredients: [TrialFDAIngredient] = []
    @State private var fdaSheet: FDASheetRoute?
    @State private var visibleSections: Set<TrialSection> = []
    /// Jump rail stays out of the way until the user scrolls, then fades back
    /// out a moment after they stop.
    @State private var railRevealed = false
    @State private var railHideTask: Task<Void, Never>?

    /// Groups Drugs@FDA matches by normalised intervention name (trim + case-fold).
    private var fdaByIntervention: [String: [TrialFDAIngredient]] {
        Dictionary(grouping: fdaIngredients, by: { Self.fdaMatchKey($0.originalIntervention) })
    }

    private static func fdaMatchKey(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    init(nctId: String, preloadedSummary: TrialSummary? = nil) {
        self.nctId = nctId
        self.preloadedSummary = preloadedSummary
    }

    private var isWatched: Bool { watchlistItem != nil }
    private var hasNotes: Bool { !(watchlistItem?.notes ?? "").isEmpty }

    /// The sections this particular trial actually has. A trial with no results
    /// or no listed sites shouldn't offer a shortcut to an absent card.
    private var availableSections: [TrialSection] {
        guard let detail else { return [] }
        var sections: [TrialSection] = [.overview]
        if TrialAIService.shared.showsPlainLanguage { sections.append(.explain) }
        sections.append(contentsOf: [.study, .eligibility])
        if !detail.conditions.isEmpty { sections.append(.conditions) }
        if !detail.interventions.isEmpty { sections.append(.interventions) }
        if !detail.outcomes.isEmpty { sections.append(.outcomes) }
        if detail.results != nil { sections.append(.results) }
        if !publications.isEmpty { sections.append(.publications) }
        if !detail.sponsors.isEmpty || !detail.collaborators.isEmpty || detail.leadSponsorName != nil {
            sections.append(.sponsors)
        }
        if !detail.locations.isEmpty { sections.append(.locations) }
        if !(detail.briefSummary ?? "").isEmpty { sections.append(.summary) }
        if !(detail.detailedDescription ?? "").isEmpty { sections.append(.description) }
        sections.append(.links)
        return sections
    }

    private var activeSection: TrialSection? {
        availableSections.first { visibleSections.contains($0) }
    }

    var body: some View {
        ScrollViewReader { proxy in
            content
                .overlay(alignment: .trailing) {
                    let sections = availableSections
                    let show = sections.count > 2 && railRevealed
                    SectionJumpRail(sections: sections, active: activeSection) { section in
                        revealRail(hold: true)
                        withAnimation(.smooth(duration: 0.35)) {
                            proxy.scrollTo(section, anchor: .top)
                        }
                    }
                    .padding(.trailing, 5)
                    .opacity(show ? 1 : 0)
                    .scaleEffect(show ? 1 : 0.92, anchor: .trailing)
                    .allowsHitTesting(show)
                    .accessibilityHidden(!show)
                    .animation(.smooth(duration: 0.25), value: show)
                }
        }
    }

    private func revealRail(hold: Bool = false) {
        withAnimation(.smooth(duration: 0.2)) { railRevealed = true }
        railHideTask?.cancel()
        let delay: Duration = hold ? .seconds(3.5) : .seconds(2.8)
        railHideTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            withAnimation(.smooth(duration: 0.35)) { railRevealed = false }
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let detail {
                    TrialHeaderCard(detail: detail)
                        .trialSection(.overview, visible: $visibleSections)
                    if TrialAIService.shared.showsPlainLanguage {
                        PlainLanguageCard(detail: detail)
                            .trialSection(.explain, visible: $visibleSections)
                    }
                    StudyInformationCard(detail: detail)
                        .trialSection(.study, visible: $visibleSections)
                    EligibilityCard(detail: detail)
                        .trialSection(.eligibility, visible: $visibleSections)
                    if !detail.conditions.isEmpty {
                        ConditionsCard(conditions: detail.conditions)
                            .trialSection(.conditions, visible: $visibleSections)
                    }
                    if !detail.interventions.isEmpty {
                        InterventionsCard(
                            interventions: detail.interventions,
                            fdaByIntervention: fdaByIntervention
                        ) { matches, interventionName in
                            presentFDA(matches: matches, interventionName: interventionName)
                        }
                        .trialSection(.interventions, visible: $visibleSections)
                    }
                    if !detail.outcomes.isEmpty {
                        OutcomesCard(outcomes: detail.outcomes)
                            .trialSection(.outcomes, visible: $visibleSections)
                    }
                    if let results = detail.results {
                        ResultsCard(results: results, enrollmentCount: detail.enrollmentCount)
                            .trialSection(.results, visible: $visibleSections)
                    }
                    if !publications.isEmpty {
                        PublicationSection(publications: publications)
                            .trialSection(.publications, visible: $visibleSections)
                    }
                    if !detail.sponsors.isEmpty || !detail.collaborators.isEmpty || detail.leadSponsorName != nil {
                        SponsorsCard(
                            sponsors: detail.sponsors,
                            collaborators: detail.collaborators,
                            fallbackLeadName: detail.leadSponsorName
                        )
                        .trialSection(.sponsors, visible: $visibleSections)
                    }
                    if !detail.locations.isEmpty {
                        LocationsCard(locations: detail.locations)
                            .trialSection(.locations, visible: $visibleSections)
                    }
                    if let summary = detail.briefSummary, !summary.isEmpty {
                        TextSectionCard(title: "Brief Summary", icon: "doc.text", text: summary)
                            .trialSection(.summary, visible: $visibleSections)
                    }
                    if let desc = detail.detailedDescription, !desc.isEmpty {
                        TextSectionCard(title: "Detailed Description", icon: "text.alignleft", text: desc)
                            .trialSection(.description, visible: $visibleSections)
                    }
                    ExternalLinksCard(nctId: detail.nctId, officialTitle: detail.officialTitle)
                        .trialSection(.links, visible: $visibleSections)
                } else if isLoading {
                    LoadingStateView(title: "Loading trial…")
                        .frame(minHeight: 300)
                } else {
                    EmptyResultsView(icon: "questionmark.folder",
                                     title: "Trial not found",
                                     message: "This trial (\(nctId)) isn't in the current dataset.")
                        .frame(minHeight: 300)
                }
            }
            .padding(.leading, 16)
            .padding(.top, 16)
            // Leave a modest gutter — slight overlap with the rail is fine.
            .padding(.trailing, 32)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
        .scrollEdgeEffectStyle(.soft, for: .top)
        .scrollEdgeEffectStyle(.soft, for: .bottom)
        .onScrollPhaseChange { _, phase in
            // Anything other than idle means the user is still moving the
            // list — keep the jump rail up. Avoid switching on ScrollPhase
            // cases: the enum grows across SDKs and breaks exhaustiveness.
            if phase != .idle {
                revealRail()
            }
        }
        .sensoryFeedback(.success, trigger: isWatched) { _, watched in watched }
        .sensoryFeedback(.impact(weight: .light), trigger: isWatched) { _, watched in !watched }
        .navigationTitle(nctId)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Grouped into one glass capsule; share sits in its own so the
            // destructive-free actions read as a set.
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    toggleWatch()
                } label: {
                    Label(isWatched ? "Remove from watchlist" : "Add to watchlist",
                          systemImage: isWatched ? "bookmark.fill" : "bookmark")
                        .contentTransition(.symbolEffect(.replace))
                }
                .tint(isWatched ? .blue : .primary)

                Button {
                    showingNotes = true
                } label: {
                    Label(hasNotes ? "Edit notes" : "Add notes",
                          systemImage: hasNotes ? "note.text" : "square.and.pencil")
                }
                .tint(hasNotes ? .orange : .primary)
            }
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(
                    item: shareText,
                    subject: Text(shareTitle),
                    preview: SharePreview(shareTitle, image: Image("AppLogo"))
                ) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }
        }
        .sheet(isPresented: $showingNotes) {
            NotesEditView(initialNotes: watchlistItem?.notes ?? "", onSave: saveNotes)
                .presentationDetents([.medium, .large])
        }
        .sheet(item: $fdaSheet) { route in
            switch route {
            case .list(let interventionName, let matches):
                FDAIngredientListSheet(
                    interventionName: interventionName,
                    ingredients: matches
                ) { chosen in
                    // Replace the list sheet with the ingredient detail sheet.
                    fdaSheet = nil
                    Task { @MainActor in
                        fdaSheet = .ingredient(chosen, interventionName: interventionName)
                    }
                }
            case .ingredient(let ingredient, let interventionName):
                FDAIngredientSheet(ingredient: ingredient, interventionName: interventionName)
            }
        }
        .task(id: nctId) {
            loadWatchlistItem()
            isLoading = true
            publications = []
            fdaIngredients = []
            let loaded = await data.detail(nctId: nctId)
            detail = loaded
            isLoading = false
            guard let loaded else { return }
            await loadV13Enrichment(trialId: loaded.summary.trialId)
        }
    }

    private func loadV13Enrichment(trialId: Int64) async {
        // Always query the store when tables exist — don't rely on cached facade
        // flags alone (avoids a race if detail opens during startup).
        async let pubs: [TrialPublication] = data.publications(trialId: trialId)
        async let fda: [TrialFDAIngredient] = data.fdaIngredients(trialId: trialId)
        publications = await pubs
        fdaIngredients = await fda
        if !fdaIngredients.isEmpty {
            print("ℹ️ [TrialDetail] \(nctId): \(fdaIngredients.count) Drugs@FDA link(s) for trial_id=\(trialId)")
        }
    }

    private func presentFDA(matches: [TrialFDAIngredient], interventionName: String) {
        guard !matches.isEmpty else { return }
        if matches.count == 1, let only = matches.first {
            fdaSheet = .ingredient(only, interventionName: interventionName)
        } else {
            fdaSheet = .list(interventionName: interventionName, matches: matches)
        }
    }

    private var shareTitle: String {
        detail?.summary.briefTitle ?? preloadedSummary?.briefTitle ?? nctId
    }

    private var shareText: String {
        "\(shareTitle)\nNCT ID: \(nctId)\nhttps://clinicaltrials.gov/study/\(nctId)"
    }

    // MARK: - Watchlist / notes

    private func loadWatchlistItem() {
        let target = nctId
        var descriptor = FetchDescriptor<WatchlistItem>(predicate: #Predicate { $0.nctId == target })
        descriptor.fetchLimit = 1
        watchlistItem = (try? modelContext.fetch(descriptor))?.first
    }

    private func toggleWatch() {
        if let item = watchlistItem {
            modelContext.delete(item)
            watchlistItem = nil
        } else {
            let item = WatchlistItem(nctId: nctId)
            modelContext.insert(item)
            watchlistItem = item
        }
        try? modelContext.save()
    }

    private func saveNotes(_ notes: String) {
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if let item = watchlistItem {
            item.notes = trimmed.isEmpty ? nil : trimmed
        } else {
            let item = WatchlistItem(nctId: nctId, notes: trimmed.isEmpty ? nil : trimmed)
            modelContext.insert(item)
            watchlistItem = item
        }
        try? modelContext.save()
    }
}

// MARK: - Section shortcuts

/// A trial record runs to a dozen cards, so reaching the sites or the outcomes
/// meant a long scroll and a lot of guessing. Each section is addressable, and
/// the rail on the trailing edge jumps straight to it.
enum TrialSection: Hashable, Identifiable, CaseIterable {
    case overview, explain, study, eligibility, conditions, interventions
    case outcomes, results, publications, sponsors, locations, summary, description, links

    var id: Self { self }

    var title: String {
        switch self {
        case .overview:      return "Top"
        case .explain:       return "Plain language"
        case .study:         return "Study information"
        case .eligibility:   return "Eligibility"
        case .conditions:    return "Medical conditions"
        case .interventions: return "Interventions"
        case .outcomes:      return "Study outcomes"
        case .results:       return "Results"
        case .publications:  return "Publications"
        case .sponsors:      return "Sponsors"
        case .locations:     return "Study locations"
        case .summary:       return "Brief summary"
        case .description:   return "Detailed description"
        case .links:         return "External links"
        }
    }

    /// Deliberately the same symbol each card already shows in its header, so
    /// the rail reads as an index of the page rather than a new vocabulary.
    var icon: String {
        switch self {
        case .overview:      return "arrow.up.to.line"
        case .explain:       return "sparkles"
        case .study:         return "info.circle"
        case .eligibility:   return "checkmark.circle"
        case .conditions:    return "cross.case"
        case .interventions: return "pills"
        case .outcomes:      return "target"
        case .results:       return "chart.bar.doc.horizontal"
        case .publications:  return "doc.richtext"
        case .sponsors:      return "building.2"
        case .locations:     return "mappin.and.ellipse"
        case .summary:       return "doc.text"
        case .description:   return "text.alignleft"
        case .links:         return "link"
        }
    }
}

/// FDA sheet routing for Trial Detail (list → ingredient, or direct ingredient).
private enum FDASheetRoute: Identifiable, Equatable {
    case list(interventionName: String, matches: [TrialFDAIngredient])
    case ingredient(TrialFDAIngredient, interventionName: String)

    var id: String {
        switch self {
        case .list(let name, let matches):
            return "list:\(name):\(matches.map(\.id).joined(separator: ","))"
        case .ingredient(let ingredient, let name):
            return "ingredient:\(name):\(ingredient.id)"
        }
    }
}

private extension View {
    /// Makes a card a scroll target and reports whether it is on screen, which
    /// is what lights up the matching icon in the rail.
    func trialSection(_ section: TrialSection, visible: Binding<Set<TrialSection>>) -> some View {
        self
            .id(section)
            .onScrollVisibilityChange(threshold: 0.05) { isVisible in
                if isVisible { visible.wrappedValue.insert(section) }
                else { visible.wrappedValue.remove(section) }
            }
    }
}

private struct SectionJumpRail: View {
    let sections: [TrialSection]
    let active: TrialSection?
    let onSelect: (TrialSection) -> Void

    @State private var announced: TrialSection?

    var body: some View {
        GlassEffectContainer(spacing: 6) {
            HStack(spacing: 6) {
                if let announced {
                    Text(announced.title)
                        .font(.caption2.weight(.medium))
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .glassEffect(.regular, in: .capsule)
                        .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .trailing)))
                }

                VStack(spacing: 1) {
                    ForEach(sections) { section in
                        Button {
                            onSelect(section)
                            announce(section)
                        } label: {
                            Image(systemName: section.icon)
                                .font(.system(size: 14, weight: .semibold))
                                .frame(width: 36, height: 30)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(section == active ? Color.accentColor : Color.secondary.opacity(0.9))
                        .accessibilityLabel("Jump to \(section.title)")
                    }
                }
                .padding(.vertical, 5)
                .glassEffect(.regular, in: .rect(cornerRadius: 18, style: .continuous))
            }
        }
        .animation(.smooth(duration: 0.2), value: active)
        .animation(.smooth(duration: 0.2), value: announced)
        .sensoryFeedback(.selection, trigger: announced)
    }

    private func announce(_ section: TrialSection) {
        announced = section
        Task {
            try? await Task.sleep(for: .seconds(1.4))
            if announced == section { announced = nil }
        }
    }
}

// MARK: - Plain-language explanation

/// Registry text is written for investigators, not for the people a trial is
/// recruiting. This rewrites the record in ordinary language using the on-device
/// model — nothing is sent anywhere, and it is opt-in per trial because
/// generating it takes a few seconds of compute.
private struct PlainLanguageCard: View {
    let detail: TrialDetail

    private enum Phase: Equatable {
        case idle, running, done, failed(String)
    }

    @State private var phase: Phase = .idle
    @State private var draft: PlainLanguageSummary.PartiallyGenerated?
    @State private var finished: PlainLanguageSummary?

    private var ai: TrialAIService { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            switch phase {
            case .idle:
                Text("Rewrite this record in everyday language, on your device.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button {
                    Task { await generate() }
                } label: {
                    Label("Explain this trial", systemImage: "sparkles")
                        .frame(maxWidth: .infinity)
                }
                .font(.callout.weight(.medium))
                .buttonStyle(.glassProminent)

            case .running, .done:
                explanation(purpose: finished?.purpose ?? draft?.purpose,
                            whoCanJoin: finished?.whoCanJoin ?? draft?.whoCanJoin,
                            whatIsInvolved: finished?.whatIsInvolved ?? draft?.whatIsInvolved,
                            questions: finished?.questionsForYourDoctor ?? draft?.questionsForYourDoctor ?? [])

            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                Button("Try again") { Task { await generate() } }
                    .font(.callout.weight(.medium))
                    .buttonStyle(.glass)
            }

            if phase == .done {
                Text("Written on this device from the registry record. It can get things wrong — check anything that matters with your doctor.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .cardStyle()
        .animation(.smooth(duration: 0.3), value: phase)
        .task(id: detail.nctId) { adoptCachedSummary() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .foregroundStyle(.blue)
                .font(.title3)
                .symbolEffect(.variableColor.iterative, isActive: phase == .running)
            Text("In Plain Language")
                .font(.title3.weight(.semibold))
            Spacer()
            if phase == .running {
                ProgressView().controlSize(.small)
            } else if phase == .done {
                Button {
                    Task { await generate() }
                } label: {
                    Label("Regenerate", systemImage: "arrow.clockwise")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Regenerate explanation")
            }
        }
    }

    @ViewBuilder
    private func explanation(purpose: String?, whoCanJoin: String?,
                             whatIsInvolved: String?, questions: [String]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            paragraph("What it's testing", purpose)
            paragraph("Who it's looking for", whoCanJoin)
            paragraph("What taking part involves", whatIsInvolved)

            if !questions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Questions for your doctor")
                        .font(.subheadline.weight(.semibold))
                    ForEach(Array(questions.enumerated()), id: \.offset) { _, question in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: "questionmark.circle")
                                .font(.caption)
                                .foregroundStyle(.blue)
                            Text(question)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func paragraph(_ title: String, _ text: String?) -> some View {
        if let text, !text.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .transition(.opacity)
        }
    }

    private func adoptCachedSummary() {
        guard let cached = ai.cachedSummary(for: detail.nctId) else { return }
        finished = cached
        phase = .done
    }

    private func generate() async {
        draft = nil
        finished = nil
        phase = .running
        do {
            let summary = try await ai.generateSummary(for: detail) { partial in
                draft = partial
            }
            finished = summary
            phase = .done
        } catch {
            draft = nil
            print("❌ [TrialAI] summary failed: \(error)")
            phase = .failed(TrialAIService.userMessage(for: error))
        }
    }
}

// MARK: - Cards

private struct TrialHeaderCard: View {
    let detail: TrialDetail

    /// Unique countries from sites, primary first, so a US-led multi-site study
    /// doesn't bury the lead behind alphabet soup.
    private var countries: [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        if let primary = detail.summary.primaryCountry, !primary.isEmpty {
            seen.insert(primary)
            ordered.append(primary)
        }
        for country in detail.locations.compactMap(\.country) where seen.insert(country).inserted {
            ordered.append(country)
        }
        return ordered
    }

    private static let flagLimit = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !countries.isEmpty {
                countryFlags
            }

            Text(detail.summary.briefTitle)
                .font(.title2.bold())
                .multilineTextAlignment(.leading)

            if let official = detail.officialTitle, official != detail.summary.briefTitle {
                Text(official).font(.subheadline).foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                StatusBadge(status: detail.summary.statusDisplay)
                if let phase = detail.summary.phaseDisplay { PhaseChip(phase: phase) }
                if let type = detail.summary.studyTypeDisplay {
                    Text(type)
                        .font(.caption).fontWeight(.medium)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.orange.opacity(0.15), in: Capsule())
                        .foregroundStyle(.orange)
                }
            }

            if let reason = detail.whyStopped, !reason.isEmpty {
                Label {
                    Text(reason).font(.footnote)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .foregroundStyle(.orange)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .cardStyle()
    }

    private var countryFlags: some View {
        let shown = Array(countries.prefix(Self.flagLimit))
        let overflow = countries.count - shown.count
        return HStack(spacing: 6) {
            ForEach(shown, id: \.self) { country in
                Text(CountryFlag.emoji(for: country))
                    .font(.title2)
                    .accessibilityLabel(country)
            }
            if overflow > 0 {
                Text("+\(overflow)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(overflow) more countries")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            countries.count == 1
                ? "Country: \(countries[0])"
                : "Countries: \(countries.joined(separator: ", "))"
        )
    }
}

private struct StudyInformationCard: View {
    let detail: TrialDetail

    private var countries: [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        if let primary = detail.summary.primaryCountry, !primary.isEmpty {
            seen.insert(primary)
            ordered.append(primary)
        }
        for country in detail.locations.compactMap(\.country) where seen.insert(country).inserted {
            ordered.append(country)
        }
        return ordered
    }

    var body: some View {
        SectionCard(title: "Study Information", icon: "info.circle") {
            DetailRow(label: "Start date", value: detail.startDateDisplay)
            DetailRow(label: "Completion date", value: detail.completionDateDisplay)
            DetailRow(label: "First posted", value: detail.firstPostedDateDisplay)
            DetailRow(label: "Last updated", value: detail.lastUpdateDisplay
                      ?? detail.summary.lastUpdateDisplay
                      ?? detail.summary.lastUpdatePostDate.formattedWithUserPreference())
            DetailRow(label: "Lead sponsor", value: detail.leadSponsorName)
            if !countries.isEmpty {
                DetailRow(
                    label: countries.count == 1 ? "Country" : "Countries",
                    value: countries.joined(separator: ", ")
                )
            }
            if let enrollment = detail.enrollmentCount {
                DetailRow(label: "Enrollment", value: "\(enrollment.formatted()) participants")
            }
            DetailRow(label: "Results available", value: detail.hasResults ? "Yes" : "No")
            DetailRow(label: "FDA regulated drug", value: detail.fdaRegulatedDrug ? "Yes" : "No")
            DetailRow(label: "Expanded access", value: detail.hasExpandedAccess ? "Yes" : "No")
        }
    }
}

private struct EligibilityCard: View {
    let detail: TrialDetail

    var body: some View {
        SectionCard(title: "Eligibility", icon: "checkmark.circle") {
            let ages = [detail.minAgeDisplay, detail.maxAgeDisplay].compactMap { $0 }
            DetailRow(label: "Age range", value: ages.isEmpty ? nil : ages.joined(separator: " – "))
            if !detail.stdAges.isEmpty {
                HStack(spacing: 6) {
                    Spacer(minLength: 0)
                    ForEach(detail.stdAges, id: \.self) { group in
                        Text(Self.ageGroupLabel(group))
                            .font(.caption).fontWeight(.medium)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.blue.opacity(0.12), in: Capsule())
                            .foregroundStyle(.blue)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Age groups: \(detail.stdAges.map(Self.ageGroupLabel).joined(separator: ", "))")
            }
            DetailRow(label: "Sex", value: detail.genderEligibilityDisplay)
            if let hv = detail.healthyVolunteers {
                DetailRow(label: "Healthy volunteers", value: hv ? "Accepts" : "No")
            }

            if let e = detail.eligibility {
                if let population = e.studyPopulation, !population.isEmpty {
                    DetailRow(label: "Study population", value: population)
                }
                if let sampling = e.samplingMethod, !sampling.isEmpty {
                    DetailRow(label: "Sampling method", value: sampling.replacingOccurrences(of: "_", with: " ").capitalized)
                }
                if let inclusion = e.inclusion, !inclusion.isEmpty {
                    CriteriaBlock(title: "Inclusion Criteria", text: inclusion, color: .green)
                }
                if let exclusion = e.exclusion, !exclusion.isEmpty {
                    CriteriaBlock(title: "Exclusion Criteria", text: exclusion, color: .red)
                }
                if (e.inclusion ?? "").isEmpty, (e.exclusion ?? "").isEmpty, let raw = e.rawText, !raw.isEmpty {
                    Text(raw).font(.callout).foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
            }
        }
    }

    private static func ageGroupLabel(_ value: String) -> String {
        switch value {
        case "CHILD":       return "Child (0–17)"
        case "ADULT":       return "Adult (18–64)"
        case "OLDER_ADULT": return "Older adult (65+)"
        default:            return value.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

private struct CriteriaBlock: View {
    let title: String
    let text: String
    let color: Color

    @State private var expanded = false

    /// Long criteria lists dominate the screen, so only the opening few show
    /// until asked. Most trials have well under this many.
    private static let collapsedLimit = 6

    private var items: [String] { Self.parse(text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(color)
                Spacer()
                if items.count > 1 {
                    Text("\(items.count)")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(color.opacity(0.12), in: Capsule())
                }
            }

            if items.count <= 1 {
                // No bullet structure to recover — show the paragraph as-is.
                Text(text)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                let shown = expanded ? items : Array(items.prefix(Self.collapsedLimit))
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(shown.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Circle()
                                .fill(color.opacity(0.5))
                                .frame(width: 5, height: 5)
                                .offset(y: -2)
                            Text(item)
                                .font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                if items.count > Self.collapsedLimit {
                    Button(expanded ? "Show less" : "Show \(items.count - Self.collapsedLimit) more") {
                        withAnimation(.smooth(duration: 0.25)) { expanded.toggle() }
                    }
                    .font(.caption.weight(.medium))
                    .buttonStyle(.plain)
                    .foregroundStyle(color)
                }
            }
        }
        .padding(.top, 6)
    }

    /// Registry criteria arrive as one blob with `*`, `-` or `1.` markers and
    /// hard-wrapped continuation lines. Splitting on the markers — rather than
    /// on newlines — keeps wrapped sentences in one bullet.
    static func parse(_ text: String) -> [String] {
        var items: [String] = []
        var current = ""

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            if let body = bulletBody(line) {
                if !current.isEmpty { items.append(current) }
                current = body
            } else if current.isEmpty {
                current = line
            } else {
                current += " " + line
            }
        }
        if !current.isEmpty { items.append(current) }
        return items.filter { !$0.isEmpty }
    }

    /// The text after a leading bullet marker, or nil if the line doesn't start one.
    private static func bulletBody(_ line: String) -> String? {
        for marker in ["* ", "- ", "• ", "– ", "— "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
        }
        if line == "*" || line == "-" { return "" }

        let digits = line.prefix(while: \.isNumber)
        if !digits.isEmpty, digits.count <= 2 {
            let rest = line.dropFirst(digits.count)
            if rest.hasPrefix(". ") || rest.hasPrefix(") ") {
                return String(rest.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}

private struct ConditionsCard: View {
    let conditions: [String]
    @AppStorage(ConditionDomainIcons.enabledKey) private var domainIconsEnabled = false

    var body: some View {
        SectionCard(title: "Medical Conditions", icon: "cross.case") {
            ForEach(conditions, id: \.self) { c in
                if domainIconsEnabled {
                    ConditionLabel(condition: c, lineLimit: 3, showGenericWhenDisabled: false)
                        .font(.callout)
                } else {
                    Label(c, systemImage: "circle.fill")
                        .labelStyle(BulletLabelStyle())
                        .font(.callout)
                }
            }
        }
    }
}

private struct InterventionsCard: View {
    let interventions: [TrialInterventionInfo]
    /// Keys must be normalised (`trim` + lowercased), same as `TrialDetailView.fdaMatchKey`.
    let fdaByIntervention: [String: [TrialFDAIngredient]]
    var onFDATap: ([TrialFDAIngredient], String) -> Void

    var body: some View {
        SectionCard(title: "Interventions", icon: "pills") {
            ForEach(interventions) { i in
                let matches = fdaByIntervention[Self.matchKey(i.name)] ?? []
                if matches.isEmpty {
                    interventionContent(i, showsFDA: false)
                        .padding(.vertical, 4)
                } else {
                    Button {
                        onFDATap(matches, i.name)
                    } label: {
                        interventionContent(i, showsFDA: true)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(i.name), Drugs at FDA information available")
                    .accessibilityAddTraits(.isButton)
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private static func matchKey(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    @ViewBuilder
    private func interventionContent(
        _ i: TrialInterventionInfo, showsFDA: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                if let type = i.typeDisplay ?? i.type {
                    Text(type)
                        .font(.caption).fontWeight(.semibold)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.purple.opacity(0.15), in: Capsule())
                        .foregroundStyle(.purple)
                }
                Text(i.name).font(.callout).fontWeight(.medium)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                if let d = i.details, !d.isEmpty {
                    Text(d).font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if showsFDA {
                HStack(spacing: 6) {
                    FDAIndicator(interventionName: i.name)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .padding(.top, 2)
            }
        }
    }
}

private struct OutcomesCard: View {
    let outcomes: [TrialOutcomeInfo]

    @State private var showSecondary = false

    private var primary: [TrialOutcomeInfo] {
        outcomes.filter { $0.type.lowercased() == "primary" }
    }

    private var secondary: [TrialOutcomeInfo] {
        outcomes.filter { $0.type.lowercased() != "primary" }
    }

    var body: some View {
        SectionCard(title: "Study Outcomes", icon: "target") {
            // Primary endpoints are what the study is actually powered for;
            // secondary/other lists can run to dozens and bury that.
            let shownPrimary = primary.isEmpty ? Array(outcomes.prefix(1)) : primary
            ForEach(shownPrimary) { OutcomeRow(outcome: $0) }

            if !secondary.isEmpty, !primary.isEmpty {
                if showSecondary {
                    ForEach(secondary) { OutcomeRow(outcome: $0) }
                    Button("Hide secondary outcomes") {
                        withAnimation(.smooth(duration: 0.25)) { showSecondary = false }
                    }
                    .font(.caption.weight(.medium))
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                } else {
                    Button {
                        withAnimation(.smooth(duration: 0.25)) { showSecondary = true }
                    } label: {
                        Label(
                            secondary.count == 1
                                ? "Show 1 secondary outcome"
                                : "Show \(secondary.count) secondary outcomes",
                            systemImage: "chevron.down"
                        )
                        .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.orange)
                    .padding(.top, 4)
                }
            } else if primary.isEmpty, outcomes.count > 1 {
                // No typed primary — first row is already shown; collapse the rest.
                if showSecondary {
                    ForEach(outcomes.dropFirst()) { OutcomeRow(outcome: $0) }
                } else {
                    Button {
                        withAnimation(.smooth(duration: 0.25)) { showSecondary = true }
                    } label: {
                        Label("Show \(outcomes.count - 1) more", systemImage: "chevron.down")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                }
            }
        }
    }
}

private struct OutcomeRow: View {
    let outcome: TrialOutcomeInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(outcome.type.capitalized)
                .font(.caption).fontWeight(.semibold)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(color.opacity(0.16), in: Capsule())
                .foregroundStyle(color)
            Text(outcome.measure).font(.callout).fontWeight(.medium)
            if let tf = outcome.timeFrame, !tf.isEmpty {
                Text("Time Frame: \(tf)").font(.caption).foregroundStyle(.secondary)
            }
            if let d = outcome.details, !d.isEmpty {
                Text(d).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var color: Color {
        switch outcome.type.lowercased() {
        case "primary": return .blue
        case "secondary": return .orange
        default: return .gray
        }
    }
}

private struct ResultsCard: View {
    let results: TrialResultsSummary
    let enrollmentCount: Int?

    var body: some View {
        SectionCard(title: "Results", icon: "chart.bar.doc.horizontal") {
            if let posted = results.resultsFirstPostDate {
                DetailRow(label: "Results first posted",
                          value: posted.formattedWithUserPreference())
            }
            // Proxy only — study record update while results are posted (never “results updated”).
            if let recordUpdated = results.studyRecordLastUpdatePostDate {
                DetailRow(label: "Study record last updated",
                          value: recordUpdated.formattedWithUserPreference())
            }

            if let reported = reportedOutcomesLine {
                DetailRow(label: "Reported outcomes", value: reported)
            } else {
                DetailRow(label: "Primary outcomes",
                          value: results.primaryOutcomeCount.formatted())
            }

            if results.hasSeriousAdverseEvents || results.hasOtherAdverseEvents || results.hasStatisticalAnalysis {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Data available")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    FlowLayout(spacing: 6) {
                        if results.hasStatisticalAnalysis {
                            resultFlag("Statistical analyses", color: .blue)
                        }
                        if results.hasSeriousAdverseEvents {
                            resultFlag("Serious adverse events", color: .red)
                        }
                        if results.hasOtherAdverseEvents {
                            resultFlag("Other adverse events", color: .orange)
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            if results.flowStarted != nil || results.flowCompleted != nil {
                if let started = results.flowStarted, let completed = results.flowCompleted {
                    DetailRow(
                        label: "Participant flow",
                        value: "\(started.formatted()) started · \(completed.formatted()) completed"
                    )
                } else if let started = results.flowStarted {
                    DetailRow(label: "Participants started", value: started.formatted())
                } else if let completed = results.flowCompleted {
                    let label = completed == 0 ? "No participants completed" : completed.formatted()
                    DetailRow(label: "Participants completed", value: label)
                }
            }
            if let withdrawn = results.withdrawn {
                DetailRow(label: "Withdrawn / not completed", value: withdrawn.formatted())
            }
            if let pct = results.completionPercent {
                DetailRow(label: "Completion rate",
                          value: String(format: "%.0f%%", pct))
            }

            if let pubs = publicationsLine {
                DetailRow(label: "Publications", value: pubs)
            }

            if let enrollment = enrollmentCount, results.flowStarted != nil, results.flowStarted != enrollment {
                Text("Registry enrolment count is \(enrollment.formatted()); completion uses the results flow (period 1).")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
            }
        }
    }

    private var reportedOutcomesLine: String? {
        let secondary = results.secondaryOutcomeCount
        let total = results.totalOutcomeCount
        guard secondary != nil || total != nil else { return nil }
        var parts = ["\(results.primaryOutcomeCount.formatted()) primary"]
        if let secondary {
            parts.append("\(secondary.formatted()) secondary")
        }
        if let total {
            parts.append("\(total.formatted()) total")
        }
        return parts.joined(separator: " · ")
    }

    private var publicationsLine: String? {
        let linked = results.linkedPublicationCount
        let resultRefs = results.resultReferenceCount
        guard let linked, linked > 0 || (resultRefs ?? 0) > 0 else { return nil }
        var parts: [String] = []
        if linked > 0 {
            parts.append("\(linked.formatted()) linked")
        }
        if let resultRefs, resultRefs > 0 {
            parts.append("\(resultRefs.formatted()) results publications")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func resultFlag(_ title: String, color: Color) -> some View {
        Text(title)
            .font(.caption).fontWeight(.medium)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.14), in: Capsule())
            .foregroundStyle(color)
    }
}

private struct SponsorsCard: View {
    let sponsors: [TrialSponsorInfo]
    let collaborators: [CollaboratorInfo]
    /// Used when `detail_z` has no lead row but `trial.lead_sponsor_name` is set.
    var fallbackLeadName: String? = nil

    private var leadRows: [TrialSponsorInfo] {
        if !sponsors.isEmpty { return sponsors }
        if let name = fallbackLeadName, !name.isEmpty {
            return [TrialSponsorInfo(name: name, agencyClass: nil, role: "LEAD")]
        }
        return []
    }

    var body: some View {
        SectionCard(title: "Sponsors & Collaborators", icon: "building.2") {
            if !leadRows.isEmpty {
                Text(leadRows.count == 1 ? "Lead Sponsor" : "Lead Sponsors")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .padding(.top, 2)

                ForEach(leadRows) { s in
                    OrganisationOrTrialListLink(
                        organisationName: s.name,
                        agencyClass: s.agencyClass,
                        collaboratorId: nil,
                        fallbackListTitle: s.name,
                        fallbackFilter: {
                            var f = TrialFilter()
                            f.leadSponsor = s.name
                            return f
                        }()
                    ) {
                        organisationLinkRow(name: s.name, subtitle: s.agencyClass)
                    }
                }
            }

            if !collaborators.isEmpty {
                Text("Collaborators")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .padding(.top, leadRows.isEmpty ? 2 : 10)

                ForEach(collaborators) { c in
                    OrganisationOrTrialListLink(
                        organisationName: c.name,
                        agencyClass: c.agencyClass,
                        collaboratorId: c.collaboratorId,
                        fallbackListTitle: c.name,
                        fallbackFilter: {
                            var f = TrialFilter()
                            f.collaborators = [String(c.collaboratorId)]
                            return f
                        }()
                    ) {
                        organisationLinkRow(
                            name: c.name,
                            subtitle: {
                                var parts: [String] = []
                                if let cls = c.agencyClass, !cls.isEmpty { parts.append(cls) }
                                if c.trialCount > 0 {
                                    parts.append("\(c.trialCount.formatted()) trials")
                                }
                                return parts.isEmpty ? nil : parts.joined(separator: " · ")
                            }()
                        )
                    }
                }
            }
        }
    }

    private func organisationLinkRow(name: String, subtitle: String?) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

/// Opens OrganisationDetail when schema v10 orgs are present; otherwise the
/// existing filtered trial list (lead name / collaborator id).
private struct OrganisationOrTrialListLink<Label: View>: View {
    let organisationName: String
    let agencyClass: String?
    let collaboratorId: Int64?
    let fallbackListTitle: String
    let fallbackFilter: TrialFilter
    @ViewBuilder var label: () -> Label

    @Environment(TrialDataService.self) private var data
    @State private var route: OrganisationRoute?

    var body: some View {
        Group {
            if let route {
                NavigationLink(value: route) {
                    label()
                }
            } else {
                NavigationLink(value: TrialListRequest(title: fallbackListTitle, filter: fallbackFilter)) {
                    label()
                }
            }
        }
        .buttonStyle(.plain)
        .task {
            if let resolved = await data.organisationRoute(
                name: organisationName,
                agencyClass: agencyClass,
                collaboratorId: collaboratorId
            ) {
                route = resolved
            } else if let collaboratorId {
                route = OrganisationRoute(collaboratorId: collaboratorId)
            } else {
                route = OrganisationRoute(leadSponsor: organisationName)
            }
        }
    }
}

private struct LocationsCard: View {
    let locations: [TrialLocationInfo]

    /// A multi-site trial can list thousands of facilities, and this card sits
    /// in a plain (non-lazy) ScrollView — so the card previews a handful and
    /// pushes the rest into a lazy List.
    private static let previewLimit = 8

    @State private var selectedIndex = 0

    private var preview: [TrialLocationInfo] { Array(locations.prefix(Self.previewLimit)) }
    private var countries: Int { Set(locations.compactMap(\.country)).count }

    private var selected: TrialLocationInfo? {
        guard !locations.isEmpty else { return nil }
        return locations[min(selectedIndex, locations.count - 1)]
    }

    var body: some View {
        SectionCard(title: "Study Locations", icon: "mappin.and.ellipse") {
            Text(locations.count == 1
                 ? "1 site"
                 : "\(locations.count.formatted()) sites in \(countries) countr\(countries == 1 ? "y" : "ies")")
                .font(.caption)
                .foregroundStyle(.secondary)

            LocationsMap(selected: selected, all: locations)

            ForEach(Array(preview.enumerated()), id: \.element.id) { index, loc in
                Button {
                    withAnimation(.smooth(duration: 0.25)) { selectedIndex = index }
                } label: {
                    LocationRow(location: loc, isSelected: index == selectedIndex)
                }
                .buttonStyle(.plain)
            }

            if locations.count > Self.previewLimit {
                NavigationLink {
                    AllLocationsView(locations: locations)
                } label: {
                    Label("View all \(locations.count.formatted()) sites", systemImage: "list.bullet")
                        .font(.callout.weight(.medium))
                }
                .padding(.top, 4)
            }
        }
    }
}

private struct LocationRow: View {
    let location: TrialLocationInfo
    var isSelected = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                if let f = location.facilityName {
                    Text(f)
                        .font(.callout)
                        .fontWeight(isSelected ? .semibold : .medium)
                        .foregroundStyle(.primary)
                }
                Spacer()
                if let status = location.status, !status.isEmpty {
                    StatusBadge(status: status.replacingOccurrences(of: "_", with: " ").capitalized)
                }
            }
            Text([location.city, location.state, location.postalCode, location.country]
                .compactMap { $0 }
                .joined(separator: ", "))
                .font(.caption).foregroundStyle(.secondary)
            if isSelected, location.coordinate == nil {
                Text("No map coordinates for this site")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isSelected ? Color.blue.opacity(0.08) : Color.clear,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isSelected ? Color.blue.opacity(0.35) : Color.clear, lineWidth: 1)
        )
    }
}

/// Centers on the selected site. Fitting every pin (e.g. US + Australia) lands
/// the camera over Africa, so we never use MapKit's automatic world fit.
private struct LocationsMap: View {
    let selected: TrialLocationInfo?
    let all: [TrialLocationInfo]

    @State private var confirmOpenInMaps = false

    private static let markerLimit = 60
    private static let focusedSpan = MKCoordinateSpan(latitudeDelta: 0.45, longitudeDelta: 0.45)

    private var pins: [TrialLocationInfo] {
        Array(all.filter { Self.isValid($0.coordinate) }.prefix(Self.markerLimit))
    }

    private var focusCoordinate: CLLocationCoordinate2D? {
        if let c = selected?.coordinate, Self.isValid(c) { return c }
        return pins.first?.coordinate
    }

    private var focusRegion: MKCoordinateRegion? {
        guard let center = focusCoordinate else { return nil }
        return MKCoordinateRegion(center: center, span: Self.focusedSpan)
    }

    private var openPlaceName: String? {
        selected.map { $0.facilityName ?? $0.placeDescription }
            ?? pins.first.map { $0.facilityName ?? $0.placeDescription }
    }

    var body: some View {
        if let focusRegion {
            Map(initialPosition: .region(focusRegion), interactionModes: []) {
                ForEach(pins) { pin in
                    if let coordinate = pin.coordinate {
                        let isFocus = pin.id == selected?.id
                            || (coordinate.latitude == focusRegion.center.latitude
                                && coordinate.longitude == focusRegion.center.longitude)
                        Marker(pin.facilityName ?? pin.placeDescription, coordinate: coordinate)
                            .tint(isFocus ? .red : .blue.opacity(0.45))
                    }
                }
            }
            // Recreate when the selection changes so the camera always jumps.
            .id(selected.map { "\($0.facilityName ?? "")-\($0.city ?? "")-\($0.latitude ?? 0)-\($0.longitude ?? 0)" } ?? "none")
            .mapControlVisibility(.hidden)
            .allowsHitTesting(false)
            .frame(height: 180)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
            .onTapGesture {
                guard focusCoordinate != nil else { return }
                confirmOpenInMaps = true
            }
            .openInMapsConfirmation(
                isPresented: $confirmOpenInMaps,
                coordinate: focusCoordinate,
                placeName: openPlaceName
            )
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(
                selected.map { "Map centered on \($0.facilityName ?? $0.placeDescription)" }
                    ?? "Map of study sites"
            )
            .accessibilityHint("Opens in Apple Maps")
        }
    }

    private static func isValid(_ coordinate: CLLocationCoordinate2D?) -> Bool {
        guard let coordinate else { return false }
        // Reject missing / Null Island garbage that pulls the camera to Africa.
        return abs(coordinate.latitude) > 0.01 || abs(coordinate.longitude) > 0.01
    }
}

private struct AllLocationsView: View {
    let locations: [TrialLocationInfo]

    private var grouped: [(country: String, items: [TrialLocationInfo])] {
        Dictionary(grouping: locations) { $0.country ?? "Unknown" }
            .map { ($0.key, $0.value) }
            .sorted { $0.country < $1.country }
    }

    var body: some View {
        List {
            ForEach(grouped, id: \.country) { group in
                Section("\(group.country) \(CountryFlag.emoji(for: group.country)) · \(group.items.count)") {
                    ForEach(group.items) { LocationRow(location: $0) }
                }
            }
        }
        .navigationTitle("Study Locations")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct TextSectionCard: View {
    let title: String
    let icon: String
    let text: String

    var body: some View {
        SectionCard(title: title, icon: icon) {
            Text(text).font(.callout).foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ExternalLinksCard: View {
    let nctId: String
    let officialTitle: String?

    var body: some View {
        SectionCard(title: "External Links", icon: "link") {
            Link(destination: URL(string: "https://clinicaltrials.gov/study/\(nctId)")!) {
                Label("View on ClinicalTrials.gov", systemImage: "arrow.up.right.square")
                    .frame(maxWidth: .infinity)
            }
            .font(.callout.weight(.medium))
            .buttonStyle(.glassProminent)

            ClinicalTrialsAttributionBlock(compact: true)
                .padding(.top, 8)
        }
    }
}

// MARK: - Reusable card scaffolding

private struct SectionCard<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(.title2.bold())
                .labelStyle(SectionTitleLabelStyle())

            VStack(alignment: .leading, spacing: 8) { content }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}

private struct SectionTitleLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon
                .foregroundStyle(.blue)
                .symbolRenderingMode(.hierarchical)
            configuration.title
        }
    }
}

private struct DetailRow: View {
    let label: String
    let value: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.callout).foregroundStyle(.secondary)
                .frame(width: 150, alignment: .leading)
            Text(value ?? "Not specified")
                .font(.callout)
                .foregroundStyle(value == nil ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
    }
}

private struct BulletLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            configuration.icon.font(.system(size: 6)).foregroundStyle(.blue)
            configuration.title
        }
    }
}

private extension View {
    func cardStyle() -> some View {
        self
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - Notes editor

struct NotesEditView: View {
    let initialNotes: String
    let onSave: (String) -> Void

    @State private var notes: String
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    init(initialNotes: String, onSave: @escaping (String) -> Void) {
        self.initialNotes = initialNotes
        self.onSave = onSave
        _notes = State(initialValue: initialNotes)
    }

    var body: some View {
        NavigationStack {
            TextEditor(text: $notes)
                .focused($focused)
                .padding(12)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                .padding()
                .background(Color(.systemGroupedBackground))
                .navigationTitle("Trial Notes")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { onSave(notes); dismiss() }.fontWeight(.semibold)
                    }
                }
                .onAppear { focused = true }
        }
    }
}
