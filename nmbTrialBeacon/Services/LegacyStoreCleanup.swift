//
//  LegacyStoreCleanup.swift
//  nmbTrialBeacon
//
//  Upgrades from the pre-rewrite build leave two kinds of junk behind: a copy
//  of the whole trials dataset that the old importer wrote into the container,
//  and a SwiftData store still carrying the dropped trial entities. Neither is
//  reachable any more, but together they can hold hundreds of megabytes and
//  they are what produces the "entities being removed" Core Data logging on
//  the first launch after upgrading.
//
//  This runs once, synchronously, before the ModelContainer is created — the
//  store must not be open while it is rebuilt.
//

import Foundation
import SQLite3

enum LegacyStoreCleanup {
    /// Bump when a new generation of leftovers needs sweeping; the work re-runs
    /// once per device at that point.
    private static let currentVersion = 1
    private static let versionKey = "legacyCleanupVersion"

    /// Filenames the old importer used for its writable copy of the dataset.
    /// The shipped database lives in the bundle and is never copied out, so
    /// anything matching these inside the container is dead weight.
    private static let orphanedDatasetNames = [
        "TrialBeacon.sqlite", "trialbeacon.sqlite",
        "ClinicalTrials.sqlite", "clinicaltrials.sqlite"
    ]

    /// Tables that only exist if the SwiftData store predates the rewrite.
    private static let legacyTables = [
        "ZTRIAL", "ZCONDITION", "ZINTERVENTION", "ZOUTCOME",
        "ZSPONSOR", "ZSTUDYLOCATION", "ZELIGIBILITYCRITERIA"
    ]

    static func runIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.integer(forKey: versionKey) < currentVersion else { return }

        removeOrphanedDatasetCopies()

        // Core Data drops the removed entities during its own migration, which
        // happens after this point on the very first upgraded launch. Reclaiming
        // the space has to wait until that has been through, so the version flag
        // is only set once the store is genuinely clean.
        guard compactUserStore() else { return }

        defaults.set(currentVersion, forKey: versionKey)
    }

    // MARK: - Orphaned dataset copies

    private static func removeOrphanedDatasetCopies() {
        let fm = FileManager.default
        let roots = [URL.applicationSupportDirectory, URL.documentsDirectory, URL.cachesDirectory]

        for root in roots {
            for name in orphanedDatasetNames {
                for suffix in ["", "-wal", "-shm"] {
                    let url = root.appending(path: name + suffix)
                    guard fm.fileExists(atPath: url.path(percentEncoded: false)) else { continue }
                    let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    do {
                        try fm.removeItem(at: url)
                        print("🧹 [Cleanup] removed \(name + suffix) (\(format(bytes)))")
                    } catch {
                        print("⚠️ [Cleanup] could not remove \(name + suffix): \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    // MARK: - User store compaction

    /// - Returns: `false` if the legacy entities are still present, meaning
    ///   Core Data has yet to migrate them away and the sweep should be retried
    ///   on the next launch.
    private static func compactUserStore() -> Bool {
        let url = URL.applicationSupportDirectory.appending(path: "default.store")
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return true }

        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path(percentEncoded: false), &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let db else {
            sqlite3_close_v2(db)
            return true   // nothing we can do; don't keep retrying every launch
        }
        defer { sqlite3_close_v2(db) }

        if hasLegacyTables(db) {
            print("🧹 [Cleanup] legacy entities still present; deferring compaction to next launch")
            return false
        }

        let before = fileSize(of: url)
        // The trial rows may still be sitting in the write-ahead log, and VACUUM
        // only rewrites what is in the main file.
        exec(db, "PRAGMA wal_checkpoint(TRUNCATE)")
        guard exec(db, "VACUUM") else { return true }
        let after = fileSize(of: url)

        if before > after {
            print("🧹 [Cleanup] compacted user store: \(format(before)) → \(format(after))")
        }
        return true
    }

    private static func hasLegacyTables(_ db: OpaquePointer) -> Bool {
        let names = legacyTables.map { "'\($0)'" }.joined(separator: ",")
        let sql = "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name IN (\(names))"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return false }
        return sqlite3_column_int(stmt, 0) > 0
    }

    // MARK: - Helpers

    @discardableResult
    private static func exec(_ db: OpaquePointer, _ sql: String) -> Bool {
        var error: UnsafeMutablePointer<CChar>?
        let ok = sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK
        if let error {
            print("⚠️ [Cleanup] \(sql) failed: \(String(cString: error))")
            sqlite3_free(error)
        }
        return ok
    }

    private static func fileSize(of url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    private static func format(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
