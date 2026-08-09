//
//  AIMatchingService.swift
//  nmbTrialBeacon
//
//  Query-driven recommendations. Instead of scoring ~500k trials in memory,
//  we build a SQL candidate query from the user's profile (conditions of
//  interest, active status) that returns a bounded candidate set via indexes,
//  then score only those candidates.
//

import Foundation

@MainActor
@Observable
final class AIMatchingService {
    static let shared = AIMatchingService()

    @ObservationIgnored private var store: TrialStore?

    private(set) var isGeneratingRecommendations = false
    private(set) var lastRecommendationUpdate: Date?
    private(set) var cachedRecommendations: [TrialRecommendation] = []
    private(set) var recommendationsCacheValid = false

    @ObservationIgnored private let candidateLimit = 300
    @ObservationIgnored private let resultLimit = 10

    private init() {}

    func configure(store: TrialStore) {
        self.store = store
    }

    // MARK: - Cache API (used by Home)

    func invalidateRecommendationsCache() {
        recommendationsCacheValid = false
        cachedRecommendations = []
    }

    /// No-op while the cache is still valid — Home calls this every time the
    /// tab appears, and the candidate query is not free.
    func precalculateRecommendations(for profile: UserProfile?) async {
        guard !recommendationsCacheValid else { return }
        guard let profile, !profile.conditionsOfInterest.isEmpty else {
            cachedRecommendations = []
            recommendationsCacheValid = true
            return
        }
        await recompute(conditions: profile.conditionsOfInterest.map { $0.name },
                        country: profile.country)
    }

    // MARK: - Nearby ranking

    /// Profile-complete users: relevance first, then distance. Otherwise distance only.
    func rankNearby(_ trials: [NearbyTrial], profile: UserProfile?) -> [NearbyTrial] {
        guard let profile, profile.isCompleteForMatching,
              !profile.conditionsOfInterest.isEmpty else {
            return trials.sorted { $0.distanceMeters < $1.distanceMeters }
        }
        let userConditions = Set(profile.conditionsOfInterest.map { $0.name.lowercased() })
        let country = profile.country
        return trials.map { item in
            var ranked = item
            ranked.matchScore = score(item.trial, userConditions: userConditions, country: country).matchScore
            return ranked
        }
        .sorted {
            let s0 = $0.matchScore ?? 0
            let s1 = $1.matchScore ?? 0
            if s0 != s1 { return s0 > s1 }
            return $0.distanceMeters < $1.distanceMeters
        }
    }

    // MARK: - Core

    private func recompute(conditions: [String], country: String?) async {
        guard let store, !conditions.isEmpty else {
            cachedRecommendations = []
            recommendationsCacheValid = true
            return
        }
        isGeneratingRecommendations = true
        defer { isGeneratingRecommendations = false }

        var filter = TrialFilter()
        filter.conditions = Set(conditions)
        let candidates = await store.page(filter: filter, sort: .lastUpdatedDesc, after: nil, limit: candidateLimit)

        let userConditions = Set(conditions.map { $0.lowercased() })
        let scored = candidates.map { score($0, userConditions: userConditions, country: country) }
            .sorted { $0.matchScore > $1.matchScore }

        cachedRecommendations = Array(scored.prefix(resultLimit))
        recommendationsCacheValid = true
        lastRecommendationUpdate = Date()
    }

    private func score(_ trial: TrialSummary, userConditions: Set<String>, country: String?) -> TrialRecommendation {
        var score = 0.5   // baseline: candidate already matched a condition of interest
        var reasons: [String] = []

        if let primary = trial.primaryCondition, userConditions.contains(primary.lowercased()) {
            score += 0.3
            reasons.append("Matches your interest in \(primary)")
        } else if let primary = trial.primaryCondition {
            reasons.append("Related to \(primary)")
        }

        if let country, let tc = trial.primaryCountry, tc == country {
            score += 0.15
            reasons.append("Available in \(country)")
        }

        switch trial.overallStatus {
        case "RECRUITING":
            score += 0.1
            reasons.append("Currently recruiting participants")
        case "NOT_YET_RECRUITING", "ENROLLING_BY_INVITATION", "ACTIVE_NOT_RECRUITING":
            score += 0.05
        default:
            break
        }

        if reasons.isEmpty { reasons.append("May be relevant to your interests") }

        return TrialRecommendation(trial: trial,
                                   matchScore: min(score, 1.0),
                                   matchReasons: Array(reasons.prefix(3)))
    }
}

// MARK: - Profile completeness

extension UserProfile {
    var completenessScore: Double {
        var score = 0.0
        if ageRange != nil { score += 1.0 }
        if gender != nil { score += 1.0 }
        if country != nil { score += 1.0 }
        if !conditionsOfInterest.isEmpty { score += 1.0 }
        return score / 4.0
    }

    var isCompleteForMatching: Bool { completenessScore >= 0.5 }
    var completenessPercentage: Int { Int(completenessScore * 100) }
}
