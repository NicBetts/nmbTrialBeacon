//
//  SavedFilters.swift
//  nmbTrialBeacon
//
//  Persistence for the Discover filter selection. This is plain storage with
//  no observable state, so it is a namespace rather than an object in the
//  environment.
//

import Foundation

enum SavedFilters {
    private static let key = "SavedTrialFilter"

    static func load() -> TrialFilter? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        // Filters saved before `phases` lacked that key; synthesized Codable
        // would fail the whole decode.
        let patched = Self.patchMissingKeys(data)
        guard let filter = try? JSONDecoder().decode(TrialFilter.self, from: patched),
              !filter.isEmpty else { return nil }
        return filter
    }

    private static func patchMissingKeys(_ data: Data) -> Data {
        guard var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return data
        }
        if obj["phases"] == nil { obj["phases"] = [String]() }
        return (try? JSONSerialization.data(withJSONObject: obj)) ?? data
    }

    static func save(_ filter: TrialFilter) {
        guard !filter.isEmpty else {
            UserDefaults.standard.removeObject(forKey: key)
            return
        }
        guard let data = try? JSONEncoder().encode(filter) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
