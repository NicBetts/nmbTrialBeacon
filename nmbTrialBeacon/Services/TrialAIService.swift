//
//  TrialAIService.swift
//  nmbTrialBeacon
//
//  On-device language-model features, built on Foundation Models. Everything
//  here runs locally: no trial text, profile or query ever leaves the device,
//  which is the whole point of shipping the dataset in the bundle.
//
//  Two capabilities:
//    • a plain-language rewrite of a registry listing, generated from the
//      record's own text so it can't introduce facts the registry doesn't state;
//    • turning a sentence like "recruiting phase 3 lung cancer studies in
//      Spain" into the structured filters the SQL layer already understands.
//
//  Both are strictly additive — if Apple Intelligence is off or the device
//  isn't eligible, the entry points hide and the app behaves exactly as before.
//
//  The on-device safety filter is sensitive to medical wording. Prompts are
//  framed as rewriting a public registry listing (not advice), kept short, and
//  a smaller retry is used if the first attempt is refused.
//

import Foundation
import FoundationModels

// MARK: - Generated shapes

/// The explanation shown on a trial. Structured rather than free prose so the
/// card can lay it out and stream each part in as it arrives.
@Generable
struct PlainLanguageSummary: Equatable, Sendable {
    @Guide(description: "One or two short everyday sentences saying what this listing is studying.")
    var purpose: String

    @Guide(description: "One or two short everyday sentences about who the listing says may take part.")
    var whoCanJoin: String

    @Guide(description: "One or two short everyday sentences about what taking part involves, based only on the listing.")
    var whatIsInvolved: String

    @Guide(description: "Two or three short questions someone could ask a clinician about this listing.", .count(2...3))
    var questionsForYourDoctor: [String]
}

/// A search request in the user's own words, pulled apart into the dimensions
/// the database indexes. Constrained fields use `anyOf` so the small model
/// emits values the SQL layer already understands.
@Generable
struct ParsedTrialSearch: Equatable, Sendable {
    @Guide(description: "Disease or condition mentioned, e.g. breast cancer. Empty if none.")
    var condition: String

    @Guide(description: "Recruitment status if mentioned, otherwise empty.",
           .anyOf(["", "RECRUITING", "NOT_YET_RECRUITING", "ACTIVE_NOT_RECRUITING",
                   "ENROLLING_BY_INVITATION", "COMPLETED", "TERMINATED", "SUSPENDED", "WITHDRAWN"]))
    var status: String

    @Guide(description: "Study phase if mentioned, otherwise empty.",
           .anyOf(["", "EARLY_PHASE1", "PHASE1", "PHASE1_PHASE2", "PHASE2",
                   "PHASE2_PHASE3", "PHASE3", "PHASE4"]))
    var phase: String

    @Guide(description: "Study type if mentioned, otherwise empty.",
           .anyOf(["", "INTERVENTIONAL", "OBSERVATIONAL", "EXPANDED_ACCESS"]))
    var studyType: String

    @Guide(description: "Country name in English if mentioned, e.g. United States. Empty if none.")
    var country: String

    @Guide(description: "Age group if mentioned, otherwise empty.",
           .anyOf(["", "CHILD", "ADULT", "OLDER_ADULT"]))
    var ageGroup: String

    @Guide(description: "Sex if mentioned, otherwise empty.",
           .anyOf(["", "FEMALE", "MALE", "ALL"]))
    var sex: String

    @Guide(description: "Days back if the request asks for recent listings. 0 if none.",
           .range(0...3650))
    var updatedWithinDays: Int

    @Guide(description: "Leftover search words such as a drug or device name. Empty if none.")
    var keywords: String
}

/// Short bookmark title for a saved trial search (from filter chips / query).
@Generable
struct SavedSearchTitleSuggestion: Equatable, Sendable {
    @Guide(description: "A short bookmark title, at most six words. No quotes or trailing punctuation.")
    var title: String
}

// MARK: - Service

@MainActor
@Observable
final class TrialAIService {
    static let shared = TrialAIService()

    /// Plain-language trial explanations are off for now. Apple Intelligence's
    /// on-device safety filter consistently refuses clinical-trial / health
    /// registry text (`.refusal` / `.guardrailViolation`), and there is no
    /// supported way to opt a third-party app out of that for medical content.
    /// Smart search stays on — short filter extraction trips it far less often.
    static let plainLanguageEnabled = false

    enum Readiness: Equatable {
        case ready
        case unsupported(String)

        var isReady: Bool { self == .ready }
    }

    private(set) var readiness: Readiness = .unsupported("Checking…")

    var isReady: Bool { readiness.isReady }

    /// Whether the detail-screen "In Plain Language" card should appear.
    var showsPlainLanguage: Bool { Self.plainLanguageEnabled && isReady }

    /// Explanations are expensive enough that re-opening a trial should not pay
    /// for one twice. Bounded because a long browsing session would otherwise
    /// hold every trial the user looked at.
    @ObservationIgnored private var summaryCache: [String: PlainLanguageSummary] = [:]
    @ObservationIgnored private var summaryOrder: [String] = []
    @ObservationIgnored private let summaryCacheLimit = 30

    private init() {
        refreshReadiness()
    }

    func refreshReadiness() {
        switch SystemLanguageModel.default.availability {
        case .available:
            readiness = .ready
        case .unavailable(.deviceNotEligible):
            readiness = .unsupported("This device doesn't support Apple Intelligence.")
        case .unavailable(.appleIntelligenceNotEnabled):
            readiness = .unsupported("Turn on Apple Intelligence in Settings to use this.")
        case .unavailable(.modelNotReady):
            readiness = .unsupported("The on-device model is still downloading. Try again shortly.")
        case .unavailable:
            readiness = .unsupported("The on-device model isn't available right now.")
        }
    }

    // MARK: - Plain-language summary

    func cachedSummary(for nctId: String) -> PlainLanguageSummary? { summaryCache[nctId] }

    private func cache(_ summary: PlainLanguageSummary, for nctId: String) {
        if summaryCache[nctId] == nil { summaryOrder.append(nctId) }
        summaryCache[nctId] = summary
        while summaryOrder.count > summaryCacheLimit {
            summaryCache.removeValue(forKey: summaryOrder.removeFirst())
        }
    }

    /// Generates the explanation. Uses a full prompt first, then one shorter
    /// retry if Apple Intelligence refuses the medical-ish wording.
    @discardableResult
    func generateSummary(
        for detail: TrialDetail,
        onPartial: @escaping (PlainLanguageSummary.PartiallyGenerated) -> Void = { _ in }
    ) async throws -> PlainLanguageSummary {
        refreshReadiness()
        guard isReady else {
            throw AIFeatureError.unavailable(readinessMessage)
        }

        do {
            return try await runSummary(for: detail, compact: false, onPartial: onPartial)
        } catch let error as LanguageModelSession.GenerationError {
            switch error {
            case .guardrailViolation, .refusal, .exceededContextWindowSize:
                print("⚠️ [TrialAI] summary rejected (\(error)); retrying with shorter prompt")
                return try await runSummary(for: detail, compact: true, onPartial: onPartial)
            default:
                throw error
            }
        }
    }

    private func runSummary(
        for detail: TrialDetail,
        compact: Bool,
        onPartial: @escaping (PlainLanguageSummary.PartiallyGenerated) -> Void
    ) async throws -> PlainLanguageSummary {
        // Fresh session each attempt — a refused turn left in the transcript
        // makes the retry more likely to fail again.
        let session = LanguageModelSession(instructions: Self.summaryInstructions)
        let prompt = Self.summaryPrompt(for: detail, compact: compact)

        // Stream so the card can fill in, but fall back to a single respond if
        // the stream ends without a usable value.
        do {
            let stream = session.streamResponse(
                to: prompt,
                generating: PlainLanguageSummary.self,
                options: GenerationOptions(temperature: 0.2, maximumResponseTokens: 450)
            )
            var latest: PlainLanguageSummary.PartiallyGenerated?
            for try await snapshot in stream {
                latest = snapshot.content
                onPartial(snapshot.content)
            }
            if let summary = Self.finalize(latest) {
                cache(summary, for: detail.nctId)
                return summary
            }
        } catch {
            print("⚠️ [TrialAI] stream failed (\(error)); trying one-shot respond")
        }

        let response = try await LanguageModelSession(instructions: Self.summaryInstructions)
            .respond(
                to: prompt,
                generating: PlainLanguageSummary.self,
                options: GenerationOptions(temperature: 0.2, maximumResponseTokens: 450)
            )
        cache(response.content, for: detail.nctId)
        return response.content
    }

    private static func finalize(_ partial: PlainLanguageSummary.PartiallyGenerated?) -> PlainLanguageSummary? {
        guard let partial,
              let purpose = partial.purpose, !purpose.isEmpty,
              let whoCanJoin = partial.whoCanJoin, !whoCanJoin.isEmpty,
              let whatIsInvolved = partial.whatIsInvolved, !whatIsInvolved.isEmpty else {
            return nil
        }
        return PlainLanguageSummary(
            purpose: purpose,
            whoCanJoin: whoCanJoin,
            whatIsInvolved: whatIsInvolved,
            questionsForYourDoctor: partial.questionsForYourDoctor ?? []
        )
    }

    private var readinessMessage: String {
        if case .unsupported(let message) = readiness { return message }
        return "Apple Intelligence isn't available right now."
    }

    private static let summaryInstructions = """
    You rewrite public research-study listings into plain everyday English for \
    a general reader.

    Rules:
    - Use only facts stated in the listing text that follows.
    - Do not add findings, advice, or recommendations.
    - Do not tell anyone whether to join a study.
    - Keep each answer to one or two short sentences.
    - If a detail is missing from the listing, say it is not stated.
    """

    private static func summaryPrompt(for detail: TrialDetail, compact: Bool) -> String {
        var lines: [String] = []
        lines.append("Listing title: \(detail.summary.briefTitle)")
        lines.append("Status: \(detail.summary.statusDisplay)")
        if let phase = detail.summary.phaseDisplay { lines.append("Phase: \(phase)") }
        if let type = detail.summary.studyTypeDisplay { lines.append("Type: \(type)") }

        let conditions = detail.conditions.prefix(compact ? 3 : 6)
        if !conditions.isEmpty {
            lines.append("Topics: \(conditions.joined(separator: ", "))")
        }

        let interventions = detail.interventions.prefix(compact ? 2 : 4)
        if !interventions.isEmpty {
            let names = interventions.map(\.name).joined(separator: "; ")
            lines.append("Approaches named: \(names)")
        }

        if !compact {
            let ages = [detail.minAgeDisplay, detail.maxAgeDisplay].compactMap { $0 }
            if !ages.isEmpty { lines.append("Ages listed: \(ages.joined(separator: " to "))") }
            if let sex = detail.genderEligibilityDisplay { lines.append("Sex listed: \(sex)") }
            if let enrollment = detail.enrollmentCount {
                lines.append("Planned size: \(enrollment)")
            }
        }

        if let summary = detail.briefSummary, !summary.isEmpty {
            lines.append("Listing text: \(truncate(summary, to: compact ? 500 : 900))")
        }

        // Inclusion criteria are the most common safety-filter tripwire, so the
        // compact retry leaves them out entirely.
        if !compact, let inclusion = detail.eligibility?.inclusion, !inclusion.isEmpty {
            lines.append("Who may take part (from listing): \(truncate(inclusion, to: 400))")
        }

        return "Rewrite this public listing in plain English:\n\n" + lines.joined(separator: "\n")
    }

    private static func truncate(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        let clipped = String(text.prefix(limit))
        if let stop = clipped.lastIndex(of: ".") { return String(clipped[...stop]) }
        return clipped + "…"
    }

    // MARK: - Natural-language search

    func parseSearch(_ request: String) async throws -> ParsedTrialSearch {
        refreshReadiness()
        guard isReady else {
            throw AIFeatureError.unavailable(readinessMessage)
        }

        let options = GenerationOptions(temperature: 0.0, maximumResponseTokens: 250)
        do {
            let response = try await LanguageModelSession(instructions: Self.searchInstructions)
                .respond(
                    to: """
                    Extract search fields from this request. Put only mentioned \
                    values; leave the rest empty or zero.

                    Request: \(request)
                    """,
                    generating: ParsedTrialSearch.self,
                    options: options
                )
            return response.content
        } catch let error as LanguageModelSession.GenerationError {
            // Medical words in the user's sentence can trip the filter even when
            // the task is just field extraction — one softer retry, new session.
            switch error {
            case .guardrailViolation, .refusal:
                print("⚠️ [TrialAI] search rejected (\(error)); retrying softer prompt")
                let retry = try await LanguageModelSession(instructions: Self.searchInstructions)
                    .respond(
                        to: """
                        Turn this into database search fields. Use empty strings \
                        when a field is not mentioned.

                        Text: \(request)
                        """,
                        generating: ParsedTrialSearch.self,
                        options: options
                    )
                return retry.content
            default:
                throw error
            }
        }
    }

    private static let searchInstructions = """
    You extract structured search fields from a short user request about \
    research-study listings in a local database.

    Rules:
    - Fill only fields the request clearly mentions.
    - Use empty string or zero for everything else.
    - Do not invent a condition, place, phase or status.
    - Do not give medical advice.
    """

    /// Maps the model's guesses onto values the database actually holds. The
    /// model works from a fixed vocabulary, but the shipped dataset decides
    /// which of those values exist, so anything unrecognised is dropped rather
    /// than sent to SQL where it would silently return nothing.
    func resolve(_ parsed: ParsedTrialSearch,
                 using data: TrialDataService) async -> ResolvedSearch {
        var filter = TrialFilter()
        var unmatched: [String] = []

        filter.status = Self.match(parsed.status, in: data.statuses)
        filter.phase = Self.match(parsed.phase, in: data.phases)
        filter.studyType = Self.match(parsed.studyType, in: data.studyTypes)
        filter.gender = Self.match(parsed.sex, in: data.genders)
        filter.ageRange = Self.match(parsed.ageGroup, in: data.ageRanges)

        let country = Self.clean(parsed.country)
        if !country.isEmpty {
            if let hit = Self.match(country, in: data.countries) {
                filter.country = hit
            } else {
                unmatched.append(country)
            }
        }

        if parsed.updatedWithinDays > 0 {
            filter.lastUpdatedWithinDays = parsed.updatedWithinDays
        }

        let condition = Self.clean(parsed.condition)
        var searchTerms: [String] = []
        if !condition.isEmpty {
            let matches = await data.searchConditions(condition, limit: 25)
            if let best = Self.bestCondition(for: condition, among: matches) {
                filter.conditions = [best]
            } else {
                searchTerms.append(condition)
            }
        }

        let keywords = Self.clean(parsed.keywords)
        if !keywords.isEmpty { searchTerms.append(keywords) }
        searchTerms.append(contentsOf: unmatched)

        return ResolvedSearch(filter: filter,
                              searchText: searchTerms.joined(separator: " "),
                              unmatched: unmatched)
    }

    struct ResolvedSearch: Equatable, Sendable {
        var filter: TrialFilter
        var searchText: String
        var unmatched: [String]

        var isEmpty: Bool { filter.isEmpty && searchText.isEmpty }
    }

    // MARK: - Saved search titles

    /// Suggests a short name from chip labels + optional query. Falls back to a
    /// deterministic join when the on-device model is unavailable or refuses.
    func suggestSavedSearchTitle(
        chipLabels: [String],
        query: String,
        fallback: String
    ) async -> String {
        refreshReadiness()
        guard isReady else { return fallback }

        let chips = chipLabels
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !chips.isEmpty || !q.isEmpty else { return fallback }

        var lines: [String] = []
        if !q.isEmpty { lines.append("Typed words: \(q)") }
        if !chips.isEmpty { lines.append("Active filters: \(chips.joined(separator: ", "))") }

        let options = GenerationOptions(temperature: 0.2, maximumResponseTokens: 40)
        do {
            let response = try await LanguageModelSession(instructions: Self.savedSearchTitleInstructions)
                .respond(
                    to: """
                    Suggest one short bookmark title for this study-listing search.

                    \(lines.joined(separator: "\n"))
                    """,
                    generating: SavedSearchTitleSuggestion.self,
                    options: options
                )
            return Self.sanitizeSavedSearchTitle(response.content.title, fallback: fallback)
        } catch {
            print("⚠️ [TrialAI] saved-search title failed (\(error)); using fallback")
            return fallback
        }
    }

    private static let savedSearchTitleInstructions = """
    You name bookmarks for study-listing searches in a local database app.

    Rules:
    - Return a short title only (at most six words).
    - Prefer condition, place, or status words from the filters.
    - No quotes, no emoji, no trailing punctuation.
    - Do not give medical advice.
    """

    private static func sanitizeSavedSearchTitle(_ raw: String, fallback: String) -> String {
        var title = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”"))
        while title.last == "." || title.last == "!" || title.last == "?" {
            title.removeLast()
            title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let words = title.split(whereSeparator: \.isWhitespace)
        if words.count > 6 {
            title = words.prefix(6).joined(separator: " ")
        }
        if title.count > 48 {
            title = String(title.prefix(48)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return title.isEmpty ? fallback : title
    }

    // MARK: - Value matching

    private static func clean(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let rejected: Set<String> = ["", "none", "n/a", "na", "null", "any", "unknown", "not mentioned"]
        return rejected.contains(trimmed.lowercased()) ? "" : trimmed
    }

    private static func match(_ raw: String, in options: [LookupValue]) -> String? {
        let value = clean(raw)
        guard !value.isEmpty else { return nil }
        let needle = normalize(value)

        if let exact = options.first(where: { normalize($0.value) == needle }) { return exact.value }
        if let display = options.first(where: { normalize($0.display) == needle }) { return display.value }
        if let alias = aliases[needle],
           let hit = options.first(where: { normalize($0.value) == alias || normalize($0.display) == alias }) {
            return hit.value
        }
        return nil
    }

    private static func normalize(_ value: String) -> String {
        value.lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .joined(separator: " ")
    }

    private static let aliases: [String: String] = [
        "usa": "united states", "us": "united states", "u s a": "united states",
        "america": "united states", "uk": "united kingdom", "britain": "united kingdom",
        "england": "united kingdom", "holland": "netherlands", "uae": "united arab emirates",
        "children": "child", "kids": "child",
        "elderly": "older adult", "seniors": "older adult", "women": "female", "men": "male"
    ]

    private static func bestCondition(for request: String, among options: [LookupValue]) -> String? {
        guard !options.isEmpty else { return nil }
        let needle = normalize(request)
        if let exact = options.first(where: { normalize($0.display) == needle || normalize($0.value) == needle }) {
            return exact.value
        }
        let contains = options.filter {
            normalize($0.display).contains(needle) || normalize($0.value).contains(needle)
        }
        return (contains.isEmpty ? options : contains).max { $0.count < $1.count }?.value
    }

    // MARK: - User-facing errors

    /// Turns Foundation Models errors into something a person can act on.
    static func userMessage(for error: Error) -> String {
        if let feature = error as? AIFeatureError {
            return feature.localizedDescription
        }
        if let generation = error as? LanguageModelSession.GenerationError {
            switch generation {
            case .guardrailViolation:
                return "Apple Intelligence declined this text. Try a shorter request, or a different trial."
            case .refusal:
                return "Apple Intelligence declined to answer. Try rewording, or open a different trial."
            case .exceededContextWindowSize:
                return "This listing is too long for the on-device model. Try another trial."
            case .assetsUnavailable, .rateLimited:
                return "The on-device model is busy. Wait a moment and try again."
            case .concurrentRequests:
                return "Another AI request is still running. Wait a moment and try again."
            case .unsupportedLanguageOrLocale:
                return "This language isn't supported by the on-device model yet."
            case .decodingFailure:
                return "The model returned something we couldn't use. Try again."
            default:
                return generation.errorDescription
                    ?? generation.failureReason
                    ?? "Something went wrong with Apple Intelligence. Try again."
            }
        }
        return error.localizedDescription
    }
}

enum AIFeatureError: LocalizedError {
    case unavailable(String)
    case incomplete

    var errorDescription: String? {
        switch self {
        case .unavailable(let message): return message
        case .incomplete: return "The model stopped before finishing. Try again."
        }
    }
}
