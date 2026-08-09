//
//  EditorPicks.swift
//  nmbTrialBeacon
//
//  Deterministic Home curation when the user has no profile interests.
//  Scores live in SQL; this layer handles 30-day no-repeat history and
//  condition diversity + a UTC day seed so the row changes daily without
//  randomness.
//

import Foundation

enum EditorPicks {
    private static let historyKey = "editorPicks.shownHistory"
    private static let suppressDays = 30
    private static let resultLimit = 10
    private static let poolLimit = 80

    private struct Entry: Codable {
        let nctId: String
        let shownAt: Date
    }

    /// NCT ids shown in the last 30 days — excluded from the next fetch.
    static func recentlyShownNctIds(now: Date = Date()) -> Set<String> {
        Set(prune(now: now).map(\.nctId))
    }

    static func recordShown(_ nctIds: [String], now: Date = Date()) {
        guard !nctIds.isEmpty else { return }
        var entries = prune(now: now)
        let existing = Set(entries.map(\.nctId))
        for id in nctIds where !existing.contains(id) {
            entries.append(Entry(nctId: id, shownAt: now))
        }
        save(entries)
    }

    /// Diversify by primary condition, then rotate with a UTC day seed.
    static func select(from candidates: [TrialSummary], now: Date = Date()) -> [TrialSummary] {
        guard !candidates.isEmpty else { return [] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let dayOfYear = calendar.ordinality(of: .day, in: .year, for: now) ?? 1
        let start = dayOfYear % candidates.count
        let rotated = Array(candidates[start...]) + Array(candidates[..<start])

        var picked: [TrialSummary] = []
        var seenConditions = Set<String>()
        var deferred: [TrialSummary] = []

        for trial in rotated {
            let key = (trial.primaryCondition ?? "").lowercased()
            if key.isEmpty || !seenConditions.contains(key) {
                picked.append(trial)
                if !key.isEmpty { seenConditions.insert(key) }
                if picked.count == resultLimit { break }
            } else {
                deferred.append(trial)
            }
        }
        if picked.count < resultLimit {
            for trial in deferred where picked.count < resultLimit {
                picked.append(trial)
            }
        }
        return picked
    }

    // MARK: - Persistence

    private static func prune(now: Date) -> [Entry] {
        let cutoff = now.addingTimeInterval(-Double(suppressDays) * 86_400)
        return load().filter { $0.shownAt >= cutoff }
    }

    private static func load() -> [Entry] {
        guard let data = UserDefaults.standard.data(forKey: historyKey),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else {
            return []
        }
        return entries
    }

    private static func save(_ entries: [Entry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: historyKey)
    }
}
