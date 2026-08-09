//
//  TrialStore.swift
//  nmbTrialBeacon
//
//  Read-only access layer over the bundled `trialbeacon.sqlite` using the
//  native SQLite C API (libsqlite3, includes FTS5). The database is opened
//  read-only and immutable, straight from the app bundle — never copied,
//  never imported into SwiftData. All queries are paginated / indexed so
//  memory stays flat regardless of dataset size.
//
//  Schema contract: TRIALBEACON_DATABASE.md / IOS_CHANGES_schema_v9.md.
//  Long prose and packed detail records live in DEFLATE-compressed `*_z`
//  BLOBs (schema 3+: preset dictionary via zlib — Apple Compression cannot
//  set a dictionary). Schema 4 drops duplicated `*_display` enum/date
//  columns. Schema 5 compresses official_title / summary_snippet /
//  study_population too — list rows decompress the snippet. Older files
//  still open when columns allow.
//

import Foundation
import SQLite3
import zlib

private enum SQLArg: Sendable {
    case int(Int64)
    case double(Double)
    case text(String)
    case null
}

/// Holds the connection handle so `sqlite3_interrupt` can be called from
/// outside the actor while a query is executing on it — that is the only
/// documented way to abandon a long-running statement.
nonisolated private final class InterruptHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var db: OpaquePointer?

    func adopt(_ handle: OpaquePointer?) {
        lock.lock(); db = handle; lock.unlock()
    }

    func interrupt() {
        lock.lock()
        if let db { sqlite3_interrupt(db) }
        lock.unlock()
    }
}

actor TrialStore {

    /// `PRAGMA application_id` written by the generator ("TBEA").
    private static let expectedApplicationID: Int64 = 0x5442_4541
    /// Inclusive schema range this client opens.
    /// Refuse newer (decoder/file mismatch) and older than the floor (unsupported paths).
    /// v13 = publications + Drugs@FDA; v14 = site pub counters + Discover browse tables.
    /// See `IOS_CHANGES_schema_v13.md` / `IOS_CHANGES_schema_v14.md`.
    static let minimumSchemaVersion: Int64 = 13
    static let supportedSchemaVersion: Int64 = 14

    private var db: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private let interruptHandle = InterruptHandle()

    // Precomputed per-value trial counts from the lookup_* tables. Used both to
    // pick a join strategy and to answer single-dimension counts without a query.
    private var totalTrialCount = 0
    private var lookupCounts: [LookupDimension: [String: Int]] = [:]
    private var conditionCache: [String: ConditionLookup?] = [:]
    /// Enum display strings from the four tiny lookup tables (14 / 3 / 7 / 3 rows).
    /// Schema v4 removed the per-row `*_display` copies — map in memory, never join.
    private var displayNames = DisplayNames()

    /// Schema v1 specifies `lookup_condition.value_norm`, but builds exist
    /// without it. When absent the normalized form is derived here instead,
    /// which is correct for every ASCII name and can drift on the handful of
    /// registry entries containing non-ASCII uppercase characters.
    private var hasConditionValueNorm = false

    /// Schema v2+: outcomes/sites/interventions/sponsors packed into `trial.detail_z`.
    private var usesDetailBlob = false
    /// Schema v2+: country filter joins `trial_country` instead of `location`.
    private var usesTrialCountry = false
    /// Schema v3+: `std_ages` is an INTEGER bit set (1 CHILD / 2 ADULT / 4 OLDER_ADULT).
    private var usesStdAgesBitmask = false
    /// Schema v4+: `date_precision` bitmask; the four `*_date_display` columns are gone.
    private var usesDatePrecision = false
    /// Schema v5+: `summary_snippet` / `official_title` / `study_population` are `*_z` blobs.
    private var usesCompressedSnippet = false
    private var usesCompressedOfficialTitle = false
    private var usesCompressedStudyPopulation = false
    /// Schema v6+: `agg_condition_by_year.scope` + `*_excl_healthy` aggregates.
    private var conditionByYearHasScope = false
    private(set) var hasExclHealthyAggregates = false
    /// Schema v7+: `trial_fts.brief_summary` — full summary text is searchable.
    private var ftsHasBriefSummary = false
    /// Pulse tables (generator; may land with / after v7).
    private var hasPulseOnThisDay = false
    private var hasPulseInteresting = false
    private var hasPulseConditionGrowth = false
    /// Schema v9+: results summary + searchable collaborators.
    private(set) var hasTrialResults = false
    private(set) var hasCollaborators = false
    /// Schema v10+: unified organisation entity + aggregates.
    private(set) var hasOrganisations = false
    /// Schema v11+: precomputed `organisation.active_trial_count`.
    private var hasOrganisationActiveTrialCount = false
    /// Schema v11+: curated HQ address / website columns on `organisation`.
    private var hasOrganisationHQ = false
    /// Schema v10+/v11 generator: canonical site entity + aggregates.
    private(set) var hasSites = false
    private var hasCollaboratorFTS = false
    /// Schema v13+: CTG reference publications + OpenAlex enrichment tables.
    private(set) var hasPublications = false
    /// Schema v13+: `publication_retraction` table (may be empty).
    private(set) var hasPublicationRetractions = false
    /// Schema v13+: `trial_results.linked_publication_count` (and sibling result counters).
    private(set) var hasTrialResultsPublicationCounts = false
    /// Schema v13+: Drugs@FDA ingredient / application tables (may be empty).
    private(set) var hasFdaDrugs = false
    /// Schema v13+: `trial_drug` link table (required with `fda_drug` for FDA UI).
    private(set) var hasTrialDrug = false
    /// Normalised ingredient + brand names from Drugs@FDA (for intervention browse badges).
    private var fdaCatalogNorms: Set<String> = []
    /// Schema v13+: `organisation.linked_publication_count`.
    private(set) var hasOrganisationPublicationCounts = false
    /// Schema v14+ (or repaired): `site.linked_publication_count` (+ OA).
    /// When absent on a v13 file, Site Profile uses a live join.
    private(set) var hasSitePublicationCounts = false
    /// Schema v14+: `popular_condition` (Discover browse).
    private(set) var hasPopularCondition = false
    /// Schema v14+: `lookup_intervention`.
    private(set) var hasLookupIntervention = false
    /// Schema v14+: `popular_intervention`.
    private(set) var hasPopularIntervention = false
    /// Populated at open for Data Status / console debugging.
    private(set) var capabilityReport: DatabaseCapabilityReport?
    private var databaseFileURL: URL?
    /// v9 fallback: recruiting-weighted site index built once per connection.
    private var siteIndexV9: SiteIndexV9?
    private var cachedOrganisationEntityCount: Int?
    private var cachedSiteEntityCount: Int?
    /// Schema v3+: preset DEFLATE dictionaries keyed by compressed column name.
    private var dictionaries: [String: Data] = [:]

    /// A `lookup_condition` row. `norm` is the generator's normalized form and
    /// the only correct join key against `condition.name_norm`.
    private struct ConditionLookup {
        let norm: String
        let count: Int
    }

    private struct DisplayNames {
        var status: [String: String] = [:]
        var studyType: [String: String] = [:]
        var phase: [String: String] = [:]
        var gender: [String: String] = [:]

        func statusLabel(_ value: String) -> String { status[value] ?? value }
        func phaseLabel(_ value: String?) -> String? {
            guard let value else { return nil }
            return phase[value] ?? value
        }
        func studyTypeLabel(_ value: String?) -> String? {
            guard let value else { return nil }
            return studyType[value] ?? value
        }
        func genderLabel(_ value: String?) -> String? {
            guard let value else { return nil }
            return gender[value] ?? value
        }
    }

    var isOpen: Bool { db != nil }

    /// Abandons the statement currently executing on this connection. Safe to
    /// call from any thread/actor; a no-op when nothing is running.
    nonisolated func cancelCurrentQuery() {
        interruptHandle.interrupt()
    }

    // MARK: - Lifecycle

    /// Secondary connections get a smaller page cache: they exist to keep slow
    /// work off the paging connection, not to hold much of the file resident.
    /// Values are KiB (`PRAGMA cache_size = -N`) so they stay correct under the
    /// generator's 16 KB page size (§7).
    enum Role {
        case primary, auxiliary

        var cacheSizeKB: Int { self == .primary ? 20_000 : 6_000 }
        var mmapBytes: Int { self == .primary ? 268_435_456 : 134_217_728 }
    }

    func open(role: Role = .primary) throws {
        guard let url = Bundle.main.url(forResource: "trialbeacon", withExtension: "sqlite") else {
            throw TrialDataError.databaseNotFound
        }
        databaseFileURL = url

        var handle: OpaquePointer?
        // `immutable=1` lets SQLite skip locking / journal checks for a truly
        // read-only file shipped inside the read-only app bundle.
        let uri = url.absoluteString + "?immutable=1"
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI

        guard sqlite3_open_v2(uri, &handle, flags, nil) == SQLITE_OK, let handle else {
            let msg = handle != nil ? String(cString: sqlite3_errmsg(handle)) : "unknown error"
            sqlite3_close(handle)
            throw TrialDataError.openFailed(msg)
        }
        db = handle
        interruptHandle.adopt(handle)

        exec("PRAGMA query_only = 1;")
        exec("PRAGMA cache_size = -\(role.cacheSizeKB);")
        exec("PRAGMA mmap_size = \(role.mmapBytes);")
        exec("PRAGMA temp_store = MEMORY;")

        try verifyIdentity()
        detectCapabilities()
        loadDictionaries()
        loadDisplayNames()
        loadSelectivityStats()
        if role == .primary {
            capabilityReport = buildCapabilityReport(fileURL: url)
            print(capabilityReport?.consoleLine ?? "ℹ️ [TrialStore] capability report unavailable.")
        }
    }

    private func detectCapabilities() {
        hasConditionValueNorm = columnExists("lookup_condition", "value_norm")
        if !hasConditionValueNorm {
            print("ℹ️ [TrialStore] lookup_condition.value_norm is missing; deriving condition keys locally.")
        }
        usesDetailBlob = columnExists("trial", "detail_z")
        usesTrialCountry = tableExists("trial_country")
        // INTEGER NOT NULL from schema 3; older builds stored a CSV TEXT.
        usesStdAgesBitmask = columnType("trial", "std_ages")?.uppercased() == "INTEGER"
        usesDatePrecision = columnExists("trial", "date_precision")
        usesCompressedSnippet = columnExists("trial", "summary_snippet_z")
        usesCompressedOfficialTitle = columnExists("trial", "official_title_z")
        usesCompressedStudyPopulation = columnExists("eligibility", "study_population_z")
        conditionByYearHasScope = columnExists("agg_condition_by_year", "scope")
        hasExclHealthyAggregates = columnExists("db_metadata", "total_trials_excl_healthy")
        if usesDetailBlob {
            print("ℹ️ [TrialStore] detail_z present — decoding packed outcomes/sites/interventions/sponsors.")
        } else {
            print("ℹ️ [TrialStore] no trial.detail_z; using relational detail tables (schema v1).")
        }
        if usesStdAgesBitmask {
            print("ℹ️ [TrialStore] std_ages is an integer bit set (schema v3).")
        }
        if usesDatePrecision {
            print("ℹ️ [TrialStore] date_precision present — formatting registry dates in UTC (schema v4).")
        }
        if usesCompressedSnippet {
            print("ℹ️ [TrialStore] summary_snippet_z present — list rows decompress snippets (schema v5).")
        }
        if hasExclHealthyAggregates {
            print("ℹ️ [TrialStore] excl-healthy aggregates present (schema v6).")
        }
        ftsHasBriefSummary = columnExists("trial_fts", "brief_summary")
        if ftsHasBriefSummary {
            print("ℹ️ [TrialStore] trial_fts.brief_summary present — summary prose is searchable (schema v7).")
        }
        hasPulseOnThisDay = tableExists("pulse_on_this_day")
        hasPulseInteresting = tableExists("pulse_interesting_trial")
        hasPulseConditionGrowth = tableExists("pulse_condition_growth")
        if hasPulseOnThisDay || hasPulseInteresting || hasPulseConditionGrowth {
            print("ℹ️ [TrialStore] pulse tables: onThisDay=\(hasPulseOnThisDay) interesting=\(hasPulseInteresting) growth=\(hasPulseConditionGrowth).")
        }
        hasTrialResults = tableExists("trial_results")
        hasCollaborators = tableExists("trial_collaborator") && tableExists("lookup_collaborator")
        hasCollaboratorFTS = tableExists("collaborator_fts")
        hasOrganisations = tableExists("organisation") && tableExists("trial_organisation")
        hasOrganisationActiveTrialCount = hasOrganisations
            && columnExists("organisation", "active_trial_count")
        hasOrganisationHQ = hasOrganisations
            && columnExists("organisation", "hq_country")
        if hasOrganisations {
            print("ℹ️ [TrialStore] organisation tables present (active_trial_count=\(hasOrganisationActiveTrialCount) hq=\(hasOrganisationHQ)).")
        }
        hasSites = tableExists("site") && tableExists("trial_site")
        if hasSites {
            print("ℹ️ [TrialStore] site tables present — Sites use SQL (not the slow v9 index).")
        } else {
            print("⚠️ [TrialStore] site/trial_site MISSING — Sites use slow on-device recruiting index.")
        }
        if hasTrialResults || hasCollaborators {
            print("ℹ️ [TrialStore] schema v9: results=\(hasTrialResults) collaborators=\(hasCollaborators) collaboratorFTS=\(hasCollaboratorFTS).")
        }

        // Schema v13 — publications + Drugs@FDA (see IOS_CHANGES_schema_v13.md).
        hasPublications = tableExists("publication") && tableExists("trial_publication")
        hasPublicationRetractions = tableExists("publication_retraction")
        hasTrialResultsPublicationCounts = hasTrialResults
            && columnExists("trial_results", "linked_publication_count")
        hasFdaDrugs = tableExists("fda_drug")
        hasTrialDrug = tableExists("trial_drug")
        hasOrganisationPublicationCounts = hasOrganisations
            && columnExists("organisation", "linked_publication_count")
        hasSitePublicationCounts = hasSites
            && columnExists("site", "linked_publication_count")
            && columnExists("site", "open_access_publication_count")
        // Schema v14 — Discover browse tables (see IOS_CHANGES_schema_v14.md).
        hasPopularCondition = tableExists("popular_condition")
        hasLookupIntervention = tableExists("lookup_intervention")
        hasPopularIntervention = tableExists("popular_intervention")
        if hasPublications || hasFdaDrugs || hasTrialResultsPublicationCounts {
            print("ℹ️ [TrialStore] schema v13+: publications=\(hasPublications) retractions=\(hasPublicationRetractions) resultsPubCounts=\(hasTrialResultsPublicationCounts) fda=\(hasFdaDrugs) trial_drug=\(hasTrialDrug) orgPubCounts=\(hasOrganisationPublicationCounts) sitePubCounts=\(hasSitePublicationCounts).")
        }
        if hasPopularCondition || hasLookupIntervention || hasPopularIntervention {
            print("ℹ️ [TrialStore] schema v14: popular_condition=\(hasPopularCondition) lookup_intervention=\(hasLookupIntervention) popular_intervention=\(hasPopularIntervention).")
        }
        loadFdaCatalogNorms()
    }

    /// Ingredient + brand names for “in Drugs@FDA catalog” badges on intervention browse.
    /// Separate from `trial_drug`, which only links a sparse subset of trial interventions.
    private func loadFdaCatalogNorms() {
        fdaCatalogNorms = []
        guard hasFdaDrugs else { return }
        var norms = Set<String>()
        let ingredientStmt = prepare("""
            SELECT canonical_ingredient FROM fda_drug
            """)
        defer { sqlite3_finalize(ingredientStmt) }
        while sqlite3_step(ingredientStmt) == SQLITE_ROW {
            if let raw = text(ingredientStmt, 0) {
                let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if !key.isEmpty { norms.insert(key) }
            }
        }
        if tableExists("fda_brand") {
            let brandStmt = prepare("SELECT brand_name FROM fda_brand")
            defer { sqlite3_finalize(brandStmt) }
            while sqlite3_step(brandStmt) == SQLITE_ROW {
                if let raw = text(brandStmt, 0) {
                    let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    if !key.isEmpty { norms.insert(key) }
                }
            }
        }
        fdaCatalogNorms = norms
        print("ℹ️ [TrialStore] Drugs@FDA catalog norms: \(norms.count) (for intervention browse badges).")
        if hasTrialDrug {
            let links = scalarCount("SELECT COUNT(*) FROM trial_drug")
            if links < 100 {
                print("⚠️ [TrialStore] trial_drug has only \(links) row(s) — Trial Detail FDA badges will be rare until the generator refill links more interventions.")
            }
        }
    }

    private func buildCapabilityReport(fileURL: URL) -> DatabaseCapabilityReport {
        let stats = dashboardStats()
        let siteRows = hasSites ? scalarCount("SELECT COUNT(*) FROM site") : 0
        let trialSiteRows = hasSites ? scalarCount("SELECT COUNT(*) FROM trial_site") : 0
        let publicationRows = hasPublications ? scalarCount("SELECT COUNT(*) FROM publication") : 0
        let trialPublicationRows = hasPublications ? scalarCount("SELECT COUNT(*) FROM trial_publication") : 0
        let fdaDrugRows = hasFdaDrugs ? scalarCount("SELECT COUNT(*) FROM fda_drug") : 0
        let trialDrugRows = hasTrialDrug ? scalarCount("SELECT COUNT(*) FROM trial_drug") : 0
        let trialsWithFda = hasTrialDrug
            ? scalarCount("SELECT COUNT(DISTINCT trial_id) FROM trial_drug")
            : 0
        let bytes = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) }
        let modified = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let companions: [(String, Bool)] = [
            ("site_alias", tableExists("site_alias")),
            ("site_condition", tableExists("site_condition")),
            ("site_lead_organisation", tableExists("site_lead_organisation")),
            ("popular_site", tableExists("popular_site")),
            ("site_fts", tableExists("site_fts")),
        ]
        let publicationCompanions: [(String, Bool)] = [
            ("publication", tableExists("publication")),
            ("trial_publication", tableExists("trial_publication")),
            ("publication_retraction", tableExists("publication_retraction")),
            ("enrichment_source", tableExists("enrichment_source")),
        ]
        let fdaCompanions: [(String, Bool)] = [
            ("fda_drug", tableExists("fda_drug")),
            ("fda_brand", tableExists("fda_brand")),
            ("fda_application", tableExists("fda_application")),
            ("fda_drug_application", tableExists("fda_drug_application")),
            ("fda_product", tableExists("fda_product")),
            ("trial_drug", tableExists("trial_drug")),
        ]
        return DatabaseCapabilityReport(
            schemaVersion: stats.schemaVersion,
            generatorVersion: stats.generatorVersion,
            hasOrganisationTables: hasOrganisations,
            hasOrganisationActiveTrialCount: hasOrganisationActiveTrialCount,
            hasOrganisationHQ: hasOrganisationHQ,
            hasOrganisationPublicationCounts: hasOrganisationPublicationCounts,
            hasSitePublicationCounts: hasSitePublicationCounts,
            hasPopularCondition: hasPopularCondition,
            hasLookupIntervention: hasLookupIntervention,
            hasPopularIntervention: hasPopularIntervention,
            hasSiteTables: hasSites,
            siteRowCount: siteRows,
            trialSiteRowCount: trialSiteRows,
            siteCompanionTables: companions,
            sitesQueryPath: hasSites ? .canonicalSQL : .v9OnDeviceIndex,
            hasPublications: hasPublications,
            publicationRowCount: publicationRows,
            trialPublicationRowCount: trialPublicationRows,
            publicationCompanionTables: publicationCompanions,
            hasTrialResultsPublicationCounts: hasTrialResultsPublicationCounts,
            hasFdaDrugs: hasFdaDrugs,
            fdaDrugRowCount: fdaDrugRows,
            trialDrugRowCount: trialDrugRows,
            trialsWithFdaLinkCount: trialsWithFda,
            fdaCompanionTables: fdaCompanions,
            databaseFileName: fileURL.lastPathComponent,
            databaseByteCount: bytes,
            databaseModifiedAt: modified
        )
    }

    private func scalarCount(_ sql: String) -> Int {
        let stmt = prepare(sql)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(int(stmt, 0))
    }

    /// The four enum lookup tables are tiny (14 / 3 / 7 / 3 rows). Load once
    /// and resolve labels in memory — do not join them onto list queries.
    private func loadDisplayNames() {
        func table(_ name: String) -> [String: String] {
            var map: [String: String] = [:]
            let stmt = prepare("SELECT value, display FROM \(name)")
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let value = text(stmt, 0), let display = text(stmt, 1) else { continue }
                map[value] = display
            }
            return map
        }
        displayNames = DisplayNames(
            status: table("lookup_status"),
            studyType: table("lookup_study_type"),
            phase: table("lookup_phase"),
            gender: table("lookup_gender")
        )
        print("ℹ️ [TrialStore] loaded display names (status \(displayNames.status.count), phase \(displayNames.phase.count), studyType \(displayNames.studyType.count), gender \(displayNames.gender.count)).")
    }

    private func loadDictionaries() {
        guard tableExists("db_dictionary") else {
            print("ℹ️ [TrialStore] no db_dictionary — decompressing without a preset dictionary.")
            return
        }
        let stmt = prepare("SELECT column_name, dictionary FROM db_dictionary")
        defer { sqlite3_finalize(stmt) }
        var loaded: [String: Data] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let name = text(stmt, 0), let data = blob(stmt, 1), !data.isEmpty else { continue }
            loaded[name] = data
        }
        dictionaries = loaded
        if loaded.isEmpty {
            print("ℹ️ [TrialStore] db_dictionary is empty — decompressing without a preset dictionary.")
        } else {
            print("ℹ️ [TrialStore] loaded \(loaded.count) DEFLATE dictionaries (\(loaded.keys.sorted().joined(separator: ", "))).")
        }
    }

    private func columnExists(_ table: String, _ column: String) -> Bool {
        let stmt = prepare("SELECT 1 FROM pragma_table_info(?) WHERE name = ? LIMIT 1",
                           [.text(table), .text(column)])
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    private func columnType(_ table: String, _ column: String) -> String? {
        let stmt = prepare("SELECT type FROM pragma_table_info(?) WHERE name = ? LIMIT 1",
                           [.text(table), .text(column)])
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return text(stmt, 0)
    }

    private func tableExists(_ name: String) -> Bool {
        let stmt = prepare("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1",
                           [.text(name)])
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    /// Loads the `lookup_*` trial counts into memory. These tables hold a few
    /// thousand rows in total, so this costs ~1 ms at launch and saves seconds
    /// later on both filtering and counting.
    private func loadSelectivityStats() {
        let totalStmt = prepare("SELECT total_trials FROM db_metadata WHERE id = 1")
        if sqlite3_step(totalStmt) == SQLITE_ROW { totalTrialCount = Int(int(totalStmt, 0)) }
        sqlite3_finalize(totalStmt)

        // Conditions are deliberately excluded — that table is far too large to
        // hold in memory, so those counts are fetched per value on demand.
        for dimension in [LookupDimension.status, .phase, .studyType, .gender, .country] {
            var counts: [String: Int] = [:]
            let stmt = prepare("SELECT value, trial_count FROM \(table(for: dimension).name)")
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let value = text(stmt, 0) { counts[value] = Int(int(stmt, 1)) }
            }
            sqlite3_finalize(stmt)
            lookupCounts[dimension] = counts
        }
    }

    /// Primary-key lookup, memoised. Used instead of caching the whole
    /// `lookup_condition` table, which is free text and can be enormous.
    ///
    /// The normalized form has to come from the table rather than being derived
    /// here: the generator produced `name_norm`/`value_norm` with Swift's full
    /// Unicode lowercasing, and condition names in the registry really do
    /// contain characters (e.g. the Roman numeral "Ⅱ") where a locally computed
    /// form can drift from the stored one.
    private func conditionLookup(_ value: String) -> ConditionLookup? {
        if let cached = conditionCache[value] { return cached }
        let normColumn = hasConditionValueNorm ? "value_norm" : "value"
        let stmt = prepare("SELECT \(normColumn), trial_count FROM lookup_condition WHERE value = ? LIMIT 1",
                           [.text(value)])
        defer { sqlite3_finalize(stmt) }
        var result: ConditionLookup?
        if sqlite3_step(stmt) == SQLITE_ROW, let stored = text(stmt, 0) {
            result = ConditionLookup(norm: hasConditionValueNorm ? stored : stored.lowercased(),
                                     count: Int(int(stmt, 1)))
        }
        conditionCache[value] = result
        return result
    }

    /// Schema contract checks. Only v13–v14 open. Newer files are refused
    /// (decoder/file mismatch); older files are refused (unsupported paths).
    private func verifyIdentity() throws {
        let appID = pragmaInt("application_id")
        if appID != 0 && appID != Self.expectedApplicationID {
            print("⚠️ [TrialStore] unexpected application_id \(appID); is this the right file?")
        }
        let version = pragmaInt("user_version")
        if version < Self.minimumSchemaVersion || version > Self.supportedSchemaVersion {
            throw TrialDataError.unsupportedSchema(
                found: version,
                minimum: Self.minimumSchemaVersion,
                maximum: Self.supportedSchemaVersion
            )
        }
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    // MARK: - Low-level helpers

    private func exec(_ sql: String) {
        guard let db else { return }
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func pragmaInt(_ name: String) -> Int64 {
        let stmt = prepare("PRAGMA \(name)")
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? int(stmt, 0) : 0
    }

    private func prepare(_ sql: String, _ args: [SQLArg] = []) -> OpaquePointer? {
        guard let db else { return nil }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            print("⚠️ [TrialStore] prepare failed: \(String(cString: sqlite3_errmsg(db)))\n\(sql)")
            return nil
        }
        for (i, arg) in args.enumerated() {
            let idx = Int32(i + 1)
            switch arg {
            case .int(let v):    sqlite3_bind_int64(stmt, idx, v)
            case .double(let v): sqlite3_bind_double(stmt, idx, v)
            case .text(let v):   sqlite3_bind_text(stmt, idx, v, -1, transient)
            case .null:          sqlite3_bind_null(stmt, idx)
            }
        }
        return stmt
    }

    private func text(_ stmt: OpaquePointer?, _ i: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, i) else { return nil }
        return String(cString: c)
    }

    private func int(_ stmt: OpaquePointer?, _ i: Int32) -> Int64 {
        sqlite3_column_int64(stmt, i)
    }

    private func optionalInt(_ stmt: OpaquePointer?, _ i: Int32) -> Int? {
        sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, i))
    }

    private func optionalInt64(_ stmt: OpaquePointer?, _ i: Int32) -> Int64? {
        sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, i)
    }

    private func optionalDouble(_ stmt: OpaquePointer?, _ i: Int32) -> Double? {
        sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, i)
    }

    private func boolValue(_ stmt: OpaquePointer?, _ i: Int32) -> Bool {
        sqlite3_column_int64(stmt, i) != 0
    }

    private func optionalBool(_ stmt: OpaquePointer?, _ i: Int32) -> Bool? {
        sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, i) != 0
    }

    private func date(_ stmt: OpaquePointer?, _ i: Int32) -> Date? {
        guard sqlite3_column_type(stmt, i) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(stmt, i))
    }

    /// Reads a `*_z` BLOB column and inflates it to text, using the column's
    /// preset dictionary when schema v3 shipped one in `db_dictionary`.
    private func compressedText(_ stmt: OpaquePointer?, _ i: Int32, column: String) -> String? {
        guard sqlite3_column_type(stmt, i) == SQLITE_BLOB,
              let bytes = sqlite3_column_blob(stmt, i) else { return nil }
        let count = Int(sqlite3_column_bytes(stmt, i))
        guard count > 4 else { return nil }
        return Self.decompressText(Data(bytes: bytes, count: count),
                                   dictionary: dictionaries[column])
    }

    /// Blob format (§4): 4-byte little-endian uncompressed length + raw DEFLATE
    /// (or raw UTF-8 when the payload length equals the prefix).
    ///
    /// Schema v3 compresses against a preset dictionary. Apple's Compression
    /// framework cannot set one, so this uses zlib. With raw DEFLATE (`-15`)
    /// zlib never returns `Z_NEED_DICT` — the dictionary must be set
    /// immediately after `inflateInit2`, before the first `inflate` call.
    static func decompressData(_ blob: Data?, dictionary: Data?) -> Data? {
        guard let blob, blob.count > 4 else { return nil }
        let length = blob.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
        let payload = Data(blob.dropFirst(4))
        guard length > 0 else { return nil }
        if payload.count == Int(length) { return payload }

        var stream = z_stream()
        guard inflateInit2_(&stream, -15, ZLIB_VERSION,
                            Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
        defer { inflateEnd(&stream) }

        // Must be before the first inflate call — raw streams never raise Z_NEED_DICT.
        if let dictionary, !dictionary.isEmpty {
            let ok = dictionary.withUnsafeBytes { raw -> Bool in
                guard let base = raw.bindMemory(to: Bytef.self).baseAddress else { return false }
                return inflateSetDictionary(&stream, base, uInt(dictionary.count)) == Z_OK
            }
            guard ok else { return nil }
        }

        var output = Data(count: Int(length))
        let decoded: Int = output.withUnsafeMutableBytes { dst in
            payload.withUnsafeBytes { src in
                stream.next_in = UnsafeMutablePointer(mutating: src.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(payload.count)
                stream.next_out = dst.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(length)
                guard zlib.inflate(&stream, Z_FINISH) == Z_STREAM_END else { return 0 }
                return Int(length) - Int(stream.avail_out)
            }
        }
        guard decoded == Int(length) else { return nil }
        return output
    }

    static func decompressText(_ blob: Data?, dictionary: Data?) -> String? {
        guard let data = decompressData(blob, dictionary: dictionary) else { return nil }
        let text = String(data: data, encoding: .utf8)
        #if DEBUG
        assert(text?.contains("\u{FFFD}") != true,
               "decompressed text contains U+FFFD — dictionary was likely missing or wrong")
        #endif
        return text
    }

    // Column layout shared by all list queries. `prefix` qualifies the columns
    // (e.g. "trial.") when the query joins another table such as trial_fts.
    // Schema v4: status/phase/study_type labels come from in-memory lookups.
    // Schema v5: `summary_snippet_z` — decompress in `summary(from:)` (list path).
    private func summaryColumns(_ prefix: String = "") -> String {
        let p = prefix
        let snippet = usesCompressedSnippet ? "\(p)summary_snippet_z" : "\(p)summary_snippet"
        let base = """
        \(p)trial_id, \(p)nct_id, \(p)brief_title, \(p)overall_status, \(p)phase, \
        \(p)study_type, \(p)primary_condition, \(p)primary_country, \
        \(p)last_update_post_date, \(p)first_posted_date, \(p)condition_count, \(p)location_count, \
        \(p)is_active, \(snippet)
        """
        if usesDatePrecision {
            return base + ", \(p)date_precision"
        }
        return base
    }

    private func summary(from stmt: OpaquePointer?) -> TrialSummary {
        let status = text(stmt, 3) ?? "UNKNOWN"
        let phase = text(stmt, 4)
        let studyType = text(stmt, 5)
        let lastUpdate = date(stmt, 8) ?? .distantPast
        let firstPosted = date(stmt, 9)
        let snippet: String? = usesCompressedSnippet
            ? compressedText(stmt, 13, column: "summary_snippet_z")
            : text(stmt, 13)

        var firstPostedDisplay: String?
        var lastUpdateDisplay: String?
        if usesDatePrecision {
            let mask = Int(int(stmt, 14))
            firstPostedDisplay = TrialDateFormat.string(
                epochSeconds: firstPosted.map { Int64($0.timeIntervalSince1970) },
                precision: DatePrecision(mask: mask, shift: DatePrecision.firstPosted)
            )
            lastUpdateDisplay = TrialDateFormat.string(
                epochSeconds: Int64(lastUpdate.timeIntervalSince1970),
                precision: DatePrecision(mask: mask, shift: DatePrecision.lastUpdate)
            )
        }

        return TrialSummary(
            trialId: int(stmt, 0),
            nctId: text(stmt, 1) ?? "",
            briefTitle: text(stmt, 2) ?? "Untitled Study",
            overallStatus: status,
            statusDisplay: displayNames.statusLabel(status),
            phaseDisplay: displayNames.phaseLabel(phase),
            studyTypeDisplay: displayNames.studyTypeLabel(studyType),
            primaryCondition: text(stmt, 6),
            primaryCountry: text(stmt, 7),
            lastUpdatePostDate: lastUpdate,
            firstPostedDate: firstPosted,
            firstPostedDisplay: firstPostedDisplay,
            lastUpdateDisplay: lastUpdateDisplay,
            conditionCount: Int(int(stmt, 10)),
            locationCount: Int(int(stmt, 11)),
            isActive: boolValue(stmt, 12),
            summarySnippet: snippet
        )
    }

    // MARK: - WHERE builder

    /// Filters on a child table (country → `location`, condition → `condition`)
    /// can be written two ways, and the right choice depends entirely on how
    /// many trials match:
    ///
    /// - `EXISTS (correlated)` walks `trial` in sort order and probes the child
    ///   index per row. It stops as soon as it has a page, so it is excellent
    ///   for common values and pathological for rare ones (a country with a
    ///   handful of trials scans the whole table — measured at ~1.5 s / 500k rows).
    /// - `trial_id IN (SELECT …)` materialises the matching ids first, which is
    ///   near-instant for rare values but expensive for common ones (it builds a
    ///   250k-row set before sorting).
    ///
    /// The crossover measured on a 500k-trial corpus sits around 0.5–1% of the
    /// table, so selectivity is taken from the `lookup_*` counts loaded at open.
    /// Counting always uses the `IN` form: a COUNT has to visit every match
    /// anyway, and the correlated probe is far slower at that job.
    private func usesIdSetForm(matchCount: Int?, isCount: Bool) -> Bool {
        if isCount { return true }
        guard let matchCount, totalTrialCount > 0 else { return true }
        return matchCount * 100 < totalTrialCount
    }

    private func whereClause(_ f: TrialFilter, isCount: Bool = false) -> (String, [SQLArg]) {
        var clauses: [String] = []
        var args: [SQLArg] = []

        // Always qualify with `trial.` — search joins `trial_fts` and bare
        // column names have been a source of silent prepare failures there.
        if let s = f.status { clauses.append("trial.overall_status = ?"); args.append(.text(s)) }
        if let s = f.studyType { clauses.append("trial.study_type = ?"); args.append(.text(s)) }
        if !f.phases.isEmpty {
            let values = Array(f.phases)
            let placeholders = Array(repeating: "?", count: values.count).joined(separator: ",")
            clauses.append("trial.phase IN (\(placeholders))")
            args.append(contentsOf: values.map { .text($0) })
        } else if let s = f.phase {
            clauses.append("trial.phase = ?")
            args.append(.text(s))
        }
        if let s = f.gender { clauses.append("trial.gender_eligibility = ?"); args.append(.text(s)) }
        if let s = f.leadSponsor { clauses.append("trial.lead_sponsor_name = ?"); args.append(.text(s)) }
        if hasOrganisations, let orgIdText = f.organisationId, let orgId = Int64(orgIdText) {
            if let role = f.organisationRole, !role.isEmpty {
                clauses.append("""
                    trial.trial_id IN (
                        SELECT tor.trial_id FROM trial_organisation tor
                        WHERE tor.organisation_id = ? AND tor.role = ?
                    )
                    """)
                args.append(.int(orgId))
                args.append(.text(role))
            } else {
                clauses.append("""
                    trial.trial_id IN (
                        SELECT tor.trial_id FROM trial_organisation tor
                        WHERE tor.organisation_id = ?
                    )
                    """)
                args.append(.int(orgId))
            }
        }
        if hasSites, let siteIdText = f.siteId, let siteId = Int64(siteIdText) {
            clauses.append("""
                trial.trial_id IN (
                    SELECT ts.trial_id FROM trial_site ts
                    WHERE ts.site_id = ?
                )
                """)
            args.append(.int(siteId))
        }
        if let hasResults = f.hasResults {
            clauses.append("trial.has_results = ?")
            args.append(.int(hasResults ? 1 : 0))
        }
        if let fda = f.fdaRegulatedDrug {
            clauses.append("trial.fda_regulated_drug = ?")
            args.append(.int(fda ? 1 : 0))
        }
        if let expanded = f.hasExpandedAccess {
            clauses.append("trial.has_expanded_access = ?")
            args.append(.int(expanded ? 1 : 0))
        }
        if f.activeOnly { clauses.append("trial.is_active = 1") }

        // Schema v9 results flags — presence filters join `trial_results`.
        if hasTrialResults {
            func appendResultsFlag(bit: Int, present: Bool?) {
                guard let present else { return }
                let op = present ? "!=" : "="
                clauses.append("""
                    EXISTS (
                        SELECT 1 FROM trial_results r
                         WHERE r.trial_id = trial.trial_id
                           AND (r.results_flags & ?) \(op) 0
                    )
                    """)
                args.append(.int(Int64(bit)))
            }
            appendResultsFlag(bit: 1, present: f.hasSeriousAdverseEvents)
            appendResultsFlag(bit: 2, present: f.hasOtherAdverseEvents)
            appendResultsFlag(bit: 4, present: f.hasStatisticalAnalysis)
        }

        if let days = f.lastUpdatedWithinDays {
            let cutoff = Int64(Date().addingTimeInterval(-Double(days) * 86_400).timeIntervalSince1970)
            clauses.append("trial.last_update_post_date >= ?")
            args.append(.int(cutoff))
        }
        if let days = f.firstPostedWithinDays {
            let cutoff = Int64(Date().addingTimeInterval(-Double(days) * 86_400).timeIntervalSince1970)
            clauses.append("trial.first_posted_date >= ?")
            args.append(.int(cutoff))
        }
        if let country = f.country {
            // Schema v2: distinct countries live in `trial_country`. Schema v1
            // still has the full `location` table.
            if usesTrialCountry {
                if usesIdSetForm(matchCount: lookupCounts[.country]?[country], isCount: isCount) {
                    clauses.append("trial.trial_id IN (SELECT tc.trial_id FROM trial_country tc WHERE tc.country = ?)")
                } else {
                    clauses.append("EXISTS (SELECT 1 FROM trial_country tc WHERE tc.trial_id = trial.trial_id AND tc.country = ?)")
                }
            } else if usesIdSetForm(matchCount: lookupCounts[.country]?[country], isCount: isCount) {
                clauses.append("trial.trial_id IN (SELECT l.trial_id FROM location l WHERE l.country = ?)")
            } else {
                clauses.append("EXISTS (SELECT 1 FROM location l WHERE l.trial_id = trial.trial_id AND l.country = ?)")
            }
            args.append(.text(country))
        }
        if !f.conditions.isEmpty {
            let values = Array(f.conditions)
            let resolved = values.map { (value: $0, lookup: conditionLookup($0)) }
            // Unknown values fall back to a locally normalized form so a stale
            // saved filter still returns something sensible.
            let norms = resolved.map { $0.lookup?.norm ?? $0.value.lowercased() }
            let matchCount: Int? = resolved.allSatisfy { $0.lookup != nil }
                ? resolved.reduce(0) { $0 + ($1.lookup?.count ?? 0) }
                : nil

            let placeholders = Array(repeating: "?", count: norms.count).joined(separator: ",")
            if usesIdSetForm(matchCount: matchCount, isCount: isCount) {
                clauses.append("trial.trial_id IN (SELECT c.trial_id FROM condition c WHERE c.name_norm IN (\(placeholders)))")
            } else {
                clauses.append("EXISTS (SELECT 1 FROM condition c WHERE c.trial_id = trial.trial_id AND c.name_norm IN (\(placeholders)))")
            }
            for norm in norms { args.append(.text(norm)) }
        }
        if hasCollaborators, !f.collaborators.isEmpty {
            let ids = f.collaborators.compactMap { Int64($0) }
            if !ids.isEmpty {
                let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
                clauses.append("""
                    trial.trial_id IN (
                        SELECT tc.trial_id FROM trial_collaborator tc
                        WHERE tc.collaborator_id IN (\(placeholders))
                    )
                    """)
                for id in ids { args.append(.int(id)) }
            }
        }
        if let bit = f.stdAgesBit, usesStdAgesBitmask {
            // Schema v3 bit set — faster and correct (LIKE '%ADULT%' matched OLDER_ADULT).
            clauses.append("(trial.std_ages & ?) != 0")
            args.append(.int(bit))
        } else if let bounds = f.ageBounds {
            // Keep a trial whose eligible age window overlaps the bucket at all.
            clauses.append("(trial.max_age_years IS NULL OR trial.max_age_years >= ?)")
            args.append(.double(bounds.lower))
            clauses.append("(trial.min_age_years IS NULL OR trial.min_age_years <= ?)")
            args.append(.double(bounds.upper))
        }

        return (clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND "), args)
    }

    // MARK: - Counts

    func count(filter: TrialFilter) -> Int {
        // `siteKey` is not expressible in `whereClause` — never fall through to a
        // corpus COUNT (same class of bug as Org’s global precomputed totals).
        if let siteKey = filter.siteKey, !siteKey.isEmpty, filter.siteId == nil {
            return countForSiteKeyV9(siteKey: siteKey, filter: filter)
        }
        if let precomputed = precomputedCount(filter) { return precomputed }
        let (whereSQL, args) = whereClause(filter, isCount: true)
        let stmt = prepare("SELECT COUNT(*) FROM trial \(whereSQL)", args)
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(int(stmt, 0)) : 0
    }

    /// An unfiltered count, or one narrowed by a single lookup dimension, is
    /// already tabulated in the database — no scan required. Counting a broad
    /// value such as "United States" the hard way measured over a second on a
    /// 500k-trial corpus, and this is the number the list header displays.
    /// Multiple dimensions can't be combined (their counts overlap), so those
    /// still run a real COUNT.
    private func precomputedCount(_ f: TrialFilter) -> Int? {
        // Lookup totals are corpus-wide. Any entity scope (org / site / lead)
        // must run a real COUNT — otherwise Org “1,397 Recruiting” opens a list
        // headed with the global recruiting total.
        guard f.lastUpdatedWithinDays == nil, f.firstPostedWithinDays == nil,
              f.ageRange == nil, !f.activeOnly, f.collaborators.isEmpty,
              f.leadSponsor == nil, f.organisationId == nil, f.organisationRole == nil,
              f.siteId == nil, f.siteKey == nil,
              f.hasResults == nil,
              f.fdaRegulatedDrug == nil, f.hasExpandedAccess == nil,
              f.hasSeriousAdverseEvents == nil, f.hasOtherAdverseEvents == nil,
              f.hasStatisticalAnalysis == nil,
              f.phases.isEmpty else { return nil }

        var dimensions = 0
        var resolved: Int?

        func consider(_ dimension: LookupDimension, _ value: String?) {
            guard let value else { return }
            dimensions += 1
            resolved = lookupCounts[dimension]?[value]
        }

        consider(.status, f.status)
        consider(.phase, f.phase)
        consider(.studyType, f.studyType)
        consider(.gender, f.gender)
        consider(.country, f.country)
        if f.conditions.count == 1, let only = f.conditions.first {
            dimensions += 1
            resolved = conditionLookup(only)?.count
        } else if f.conditions.count > 1 {
            return nil
        }

        if dimensions == 0 { return totalTrialCount > 0 ? totalTrialCount : nil }
        return dimensions == 1 ? resolved : nil
    }

    // MARK: - Paged browse (keyset pagination)

    func page(filter: TrialFilter, sort: TrialSort, after cursor: TrialCursor?, limit: Int) -> [TrialSummary] {
        // Soft-key site filter cannot use `trial_site` — scan detail_z (v9 path,
        // or a v10 file opened with a raw SiteRef before id resolution).
        if let siteKey = filter.siteKey, !siteKey.isEmpty, filter.siteId == nil {
            return pageForSiteKeyV9(siteKey: siteKey, filter: filter, after: cursor, limit: limit)
        }

        var (whereSQL, args) = whereClause(filter)

        func addCondition(_ cond: String, _ extra: [SQLArg]) {
            if whereSQL.isEmpty { whereSQL = "WHERE " + cond }
            else { whereSQL += " AND " + cond }
            args.append(contentsOf: extra)
        }

        let orderSQL: String
        switch sort {
        case .relevance, .lastUpdatedDesc:
            if let c = cursor {
                addCondition("(trial.last_update_post_date < ? OR (trial.last_update_post_date = ? AND trial.trial_id < ?))",
                             [.int(c.lastUpdate), .int(c.lastUpdate), .int(c.trialId)])
            }
            orderSQL = "ORDER BY trial.last_update_post_date DESC, trial.trial_id DESC"
        case .titleAsc:
            if let c = cursor {
                addCondition("(trial.brief_title > ? OR (trial.brief_title = ? AND trial.trial_id > ?))",
                             [.text(c.title), .text(c.title), .int(c.trialId)])
            }
            orderSQL = "ORDER BY trial.brief_title ASC, trial.trial_id ASC"
        case .firstPostedDesc:
            if let c = cursor {
                addCondition("(trial.first_posted_date < ? OR (trial.first_posted_date = ? AND trial.trial_id < ?))",
                             [.int(c.firstPosted), .int(c.firstPosted), .int(c.trialId)])
            }
            orderSQL = "ORDER BY trial.first_posted_date DESC, trial.trial_id DESC"
        }

        args.append(.int(Int64(limit)))
        let sql = "SELECT \(summaryColumns()) FROM trial \(whereSQL) \(orderSQL) LIMIT ?"
        let stmt = prepare(sql, args)
        defer { sqlite3_finalize(stmt) }

        var results: [TrialSummary] = []
        results.reserveCapacity(limit)
        while sqlite3_step(stmt) == SQLITE_ROW { results.append(summary(from: stmt)) }
        return results
    }

    // MARK: - Full-text search (FTS5, contentless)

    func search(_ query: String, scope: TrialSearchScope = .all,
                filter: TrialFilter, sort: TrialSort = .relevance,
                offset: Int, limit: Int) -> [TrialSummary] {
        guard let match = Self.ftsQuery(query, scope: scope) else { return [] }

        // The FTS5 MATCH operand must be the table name itself — an alias is not
        // accepted for the hidden match column, so this join stays unaliased.
        var clauses = ["trial_fts MATCH ?"]
        var args: [SQLArg] = [.text(match)]

        let (whereSQL, filterArgs) = whereClause(filter)
        if !whereSQL.isEmpty {
            clauses.append(String(whereSQL.dropFirst("WHERE ".count)))
            args.append(contentsOf: filterArgs)
        }

        args.append(.int(Int64(limit)))
        args.append(.int(Int64(offset)))

        let orderSQL: String
        switch sort {
        case .relevance:
            // Schema v7: weight titles above summary prose so a passing mention in
            // brief_summary doesn't bury a title hit (bm25 column order = FTS decl).
            if scope == .all, ftsHasBriefSummary {
                orderSQL = "ORDER BY bm25(trial_fts, 10.0, 10.0, 5.0, 5.0, 5.0, 1.0)"
            } else {
                orderSQL = "ORDER BY trial_fts.rank"
            }
        case .lastUpdatedDesc:
            orderSQL = "ORDER BY trial.last_update_post_date DESC, trial.trial_id DESC"
        case .firstPostedDesc:
            orderSQL = "ORDER BY trial.first_posted_date DESC, trial.trial_id DESC"
        case .titleAsc:
            orderSQL = "ORDER BY trial.brief_title ASC, trial.trial_id ASC"
        }

        let sql = """
            SELECT \(summaryColumns("trial."))
            FROM trial_fts
            JOIN trial ON trial.trial_id = trial_fts.rowid
            WHERE \(clauses.joined(separator: " AND "))
            \(orderSQL)
            LIMIT ? OFFSET ?
            """
        let stmt = prepare(sql, args)
        defer { sqlite3_finalize(stmt) }

        var results: [TrialSummary] = []
        while sqlite3_step(stmt) == SQLITE_ROW { results.append(summary(from: stmt)) }
        return results
    }

    /// Turns free text into a safe FTS5 MATCH expression: every term is quoted
    /// (so user input can't be interpreted as query syntax) and prefix-matched.
    /// Optional column filter scopes to titles / conditions / etc.
    static func ftsQuery(_ raw: String, scope: TrialSearchScope = .all) -> String? {
        let terms = raw
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !terms.isEmpty else { return nil }
        let body = terms.map { "\"\($0)\"*" }.joined(separator: " ")
        if let columns = scope.ftsColumnFilter {
            return "\(columns): (\(body))"
        }
        return body
    }

    // MARK: - Detail

    func detail(nctId: String) -> TrialDetail? {
        // Summary is 14 columns (0…13), plus `date_precision` at 14 on schema v4.
        let summaryWidth = usesDatePrecision ? 15 : 14
        let detailColumn = usesDetailBlob ? ", detail_z" : ""
        let dateAndGenderSQL: String
        if usesDatePrecision {
            // Epochs + precision bitmask; labels come from TrialDateFormat (UTC).
            // Enum label for sex comes from lookup_gender — not a dropped display column.
            dateAndGenderSQL = """
                start_date, completion_date, gender_eligibility,
                min_age_display, max_age_display
                """
        } else {
            // Schema ≤3 still ships the four `*_date_display` strings.
            dateAndGenderSQL = """
                start_date_display, completion_date_display, first_posted_date_display,
                last_update_post_date_display, gender_eligibility,
                min_age_display, max_age_display
                """
        }
        let officialTitleSQL = usesCompressedOfficialTitle ? "official_title_z" : "official_title"
        let sql = """
            SELECT \(summaryColumns()),
                   \(officialTitleSQL), brief_summary_z, detailed_description_z,
                   \(dateAndGenderSQL), std_ages, healthy_volunteers,
                   enrollment_count, why_stopped, lead_sponsor_name,
                   has_results, fda_regulated_drug, has_expanded_access
                   \(detailColumn)
            FROM trial WHERE nct_id = ? LIMIT 1
            """
        let stmt = prepare(sql, [.text(nctId)])
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

        let s = summary(from: stmt)
        let titleCol = Int32(summaryWidth)
        let briefCol = titleCol + 1
        let detailedCol = titleCol + 2
        let datesCol = titleCol + 3
        let officialTitle: String? = usesCompressedOfficialTitle
            ? compressedText(stmt, titleCol, column: "official_title_z")
            : text(stmt, titleCol)

        let startDateDisplay: String?
        let completionDateDisplay: String?
        let firstPostedDateDisplay: String?
        let lastUpdateDisplay: String?
        let genderCol: Int32
        let minAgeCol: Int32

        if usesDatePrecision {
            let mask = Int(int(stmt, 14))
            startDateDisplay = TrialDateFormat.string(
                epochSeconds: optionalInt64(stmt, datesCol),
                precision: DatePrecision(mask: mask, shift: DatePrecision.start)
            )
            completionDateDisplay = TrialDateFormat.string(
                epochSeconds: optionalInt64(stmt, datesCol + 1),
                precision: DatePrecision(mask: mask, shift: DatePrecision.completion)
            )
            firstPostedDateDisplay = s.firstPostedDisplay
            lastUpdateDisplay = s.lastUpdateDisplay
            genderCol = datesCol + 2
            minAgeCol = datesCol + 3
        } else {
            startDateDisplay = text(stmt, datesCol)
            completionDateDisplay = text(stmt, datesCol + 1)
            firstPostedDateDisplay = text(stmt, datesCol + 2)
            lastUpdateDisplay = text(stmt, datesCol + 3)
            genderCol = datesCol + 4
            minAgeCol = datesCol + 5
        }

        let maxAgeCol = minAgeCol + 1
        let stdAgesCol = maxAgeCol + 1
        let healthyCol = stdAgesCol + 1
        let enrollmentCol = healthyCol + 1
        let whyStoppedCol = enrollmentCol + 1
        let leadSponsorCol = whyStoppedCol + 1
        let hasResultsCol = leadSponsorCol + 1
        let fdaCol = hasResultsCol + 1
        let expandedCol = fdaCol + 1
        let detailBlobCol = expandedCol + 1

        let packed: PackedDetail
        if usesDetailBlob {
            if let text = Self.decompressText(blob(stmt, detailBlobCol), dictionary: dictionaries["detail_z"]),
               let data = text.data(using: .utf8) {
                packed = Self.decodePackedDetail(data)
            } else {
                packed = PackedDetail()
            }
        } else {
            packed = PackedDetail(
                locations: locations(trialId: s.trialId),
                interventions: interventions(trialId: s.trialId),
                outcomes: outcomes(trialId: s.trialId),
                sponsors: sponsors(trialId: s.trialId)
            )
        }

        let hasResults = boolValue(stmt, hasResultsCol)
        let collabs = hasCollaborators ? collaborators(trialId: s.trialId) : []
        let resultsSummary = (hasTrialResults && hasResults) ? trialResults(trialId: s.trialId) : nil

        return TrialDetail(
            summary: s,
            officialTitle: officialTitle,
            briefSummary: compressedText(stmt, briefCol, column: "brief_summary_z"),
            detailedDescription: compressedText(stmt, detailedCol, column: "detailed_description_z"),
            startDateDisplay: startDateDisplay,
            completionDateDisplay: completionDateDisplay,
            firstPostedDateDisplay: firstPostedDateDisplay,
            lastUpdateDisplay: lastUpdateDisplay,
            genderEligibilityDisplay: displayNames.genderLabel(text(stmt, genderCol)),
            minAgeDisplay: text(stmt, minAgeCol),
            maxAgeDisplay: text(stmt, maxAgeCol),
            stdAges: decodeStdAges(stmt, stdAgesCol),
            healthyVolunteers: optionalBool(stmt, healthyCol),
            enrollmentCount: optionalInt(stmt, enrollmentCol),
            whyStopped: text(stmt, whyStoppedCol),
            leadSponsorName: text(stmt, leadSponsorCol),
            hasResults: hasResults,
            fdaRegulatedDrug: boolValue(stmt, fdaCol),
            hasExpandedAccess: boolValue(stmt, expandedCol),
            conditions: conditions(trialId: s.trialId),
            locations: packed.locations,
            interventions: packed.interventions,
            outcomes: packed.outcomes,
            sponsors: packed.sponsors,
            collaborators: collabs,
            results: resultsSummary,
            eligibility: eligibility(trialId: s.trialId)
        )
    }

    private func decodeStdAges(_ stmt: OpaquePointer?, _ i: Int32) -> [String] {
        if usesStdAgesBitmask {
            let bits = Int(int(stmt, i))
            var out: [String] = []
            if bits & 1 != 0 { out.append("CHILD") }
            if bits & 2 != 0 { out.append("ADULT") }
            if bits & 4 != 0 { out.append("OLDER_ADULT") }
            return out
        }
        return (text(stmt, i) ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private struct PackedDetail {
        var locations: [TrialLocationInfo] = []
        var interventions: [TrialInterventionInfo] = []
        var outcomes: [TrialOutcomeInfo] = []
        var sponsors: [TrialSponsorInfo] = []
    }

    /// Schema v2 `detail_z` JSON (§4.2): keys `o`/`l`/`i`/`s`, positional rows.
    /// Schema v9: `"s"` is lead-only; collaborators live in `trial_collaborator`.
    private static func decodePackedDetail(_ json: Data?) -> PackedDetail {
        guard let json,
              let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else {
            return PackedDetail()
        }

        func rows(_ key: String) -> [[Any]] { (root[key] as? [[Any]]) ?? [] }
        func str(_ row: [Any], _ i: Int) -> String? {
            guard i < row.count else { return nil }
            if row[i] is NSNull { return nil }
            return row[i] as? String
        }
        func num(_ row: [Any], _ i: Int) -> Double? {
            guard i < row.count else { return nil }
            if row[i] is NSNull { return nil }
            return (row[i] as? NSNumber)?.doubleValue
        }

        var packed = PackedDetail()
        packed.outcomes = rows("o").map {
            TrialOutcomeInfo(type: str($0, 0) ?? "OTHER",
                             measure: str($0, 1) ?? "",
                             timeFrame: str($0, 2),
                             details: str($0, 3))
        }
        packed.locations = rows("l").map {
            TrialLocationInfo(facilityName: str($0, 0), city: str($0, 1),
                              state: str($0, 2), country: str($0, 3),
                              postalCode: str($0, 4), status: str($0, 5),
                              latitude: num($0, 6), longitude: num($0, 7))
        }
        packed.interventions = rows("i").map {
            TrialInterventionInfo(type: str($0, 0), typeDisplay: str($0, 1),
                                  name: str($0, 2) ?? "", details: str($0, 3))
        }
        // v9 packs at most the LEAD; ignore any unexpected COLLABORATOR rows.
        packed.sponsors = rows("s").compactMap { row in
            let role = str(row, 2)
            if let role, role.uppercased() == "COLLABORATOR" { return nil }
            return TrialSponsorInfo(name: str(row, 0) ?? "", agencyClass: str(row, 1), role: role ?? "LEAD")
        }
        return packed
    }

    private func blob(_ stmt: OpaquePointer?, _ i: Int32) -> Data? {
        guard sqlite3_column_type(stmt, i) == SQLITE_BLOB,
              let bytes = sqlite3_column_blob(stmt, i) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, i)))
    }

    private func conditions(trialId: Int64) -> [String] {
        let stmt = prepare("SELECT name FROM condition WHERE trial_id = ? ORDER BY ordinal", [.int(trialId)])
        defer { sqlite3_finalize(stmt) }
        var out: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW { if let n = text(stmt, 0) { out.append(n) } }
        return out
    }

    /// Schema v1 fallback — unused once `detail_z` is present.
    private func locations(trialId: Int64) -> [TrialLocationInfo] {
        let stmt = prepare("""
            SELECT facility_name, city, state, country, postal_code, status, latitude, longitude
            FROM location WHERE trial_id = ? ORDER BY ordinal
            """, [.int(trialId)])
        defer { sqlite3_finalize(stmt) }
        var out: [TrialLocationInfo] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(TrialLocationInfo(facilityName: text(stmt, 0), city: text(stmt, 1),
                                         state: text(stmt, 2), country: text(stmt, 3),
                                         postalCode: text(stmt, 4), status: text(stmt, 5),
                                         latitude: optionalDouble(stmt, 6),
                                         longitude: optionalDouble(stmt, 7)))
        }
        return out
    }

    private func interventions(trialId: Int64) -> [TrialInterventionInfo] {
        let stmt = prepare("SELECT type, type_display, name, description FROM intervention WHERE trial_id = ? ORDER BY ordinal", [.int(trialId)])
        defer { sqlite3_finalize(stmt) }
        var out: [TrialInterventionInfo] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(TrialInterventionInfo(type: text(stmt, 0), typeDisplay: text(stmt, 1),
                                             name: text(stmt, 2) ?? "", details: text(stmt, 3)))
        }
        return out
    }

    private func outcomes(trialId: Int64) -> [TrialOutcomeInfo] {
        let stmt = prepare("SELECT type, measure, time_frame, description FROM outcome WHERE trial_id = ? ORDER BY ordinal", [.int(trialId)])
        defer { sqlite3_finalize(stmt) }
        var out: [TrialOutcomeInfo] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(TrialOutcomeInfo(type: text(stmt, 0) ?? "OTHER", measure: text(stmt, 1) ?? "",
                                        timeFrame: text(stmt, 2), details: text(stmt, 3)))
        }
        return out
    }

    private func sponsors(trialId: Int64) -> [TrialSponsorInfo] {
        let stmt = prepare("SELECT name, agency_class, role FROM sponsor WHERE trial_id = ? ORDER BY ordinal", [.int(trialId)])
        defer { sqlite3_finalize(stmt) }
        var out: [TrialSponsorInfo] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let role = text(stmt, 2)
            if let role, role.uppercased() == "COLLABORATOR" { continue }
            out.append(TrialSponsorInfo(name: text(stmt, 0) ?? "", agencyClass: text(stmt, 1), role: role ?? "LEAD"))
        }
        return out
    }

    /// Schema v9: collaborators are relational, not in `detail_z`.
    private func collaborators(trialId: Int64) -> [CollaboratorInfo] {
        let stmt = prepare("""
            SELECT lc.collaborator_id, lc.name, lc.agency_class, lc.trial_count
              FROM trial_collaborator tc
              JOIN lookup_collaborator lc ON lc.collaborator_id = tc.collaborator_id
             WHERE tc.trial_id = ?
             ORDER BY lc.name
            """, [.int(trialId)])
        defer { sqlite3_finalize(stmt) }
        var out: [CollaboratorInfo] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let cls = text(stmt, 2) ?? ""
            out.append(CollaboratorInfo(
                collaboratorId: int(stmt, 0),
                name: text(stmt, 1) ?? "",
                agencyClass: cls.isEmpty ? nil : cls,
                trialCount: Int(int(stmt, 3))
            ))
        }
        return out
    }

    private func trialResults(trialId: Int64) -> TrialResultsSummary? {
        if hasTrialResultsPublicationCounts {
            let stmt = prepare("""
                SELECT results_first_post_date, results_last_update_post_date,
                       primary_outcome_count, secondary_outcome_count, total_result_outcome_count,
                       results_flags, flow_started, flow_completed,
                       linked_publication_count, result_reference_count
                  FROM trial_results WHERE trial_id = ? LIMIT 1
                """, [.int(trialId)])
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return TrialResultsSummary(
                resultsFirstPostDate: date(stmt, 0),
                studyRecordLastUpdatePostDate: date(stmt, 1),
                primaryOutcomeCount: Int(int(stmt, 2)),
                secondaryOutcomeCount: optionalInt(stmt, 3),
                totalOutcomeCount: optionalInt(stmt, 4),
                resultsFlags: Int(int(stmt, 5)),
                flowStarted: optionalInt(stmt, 6),
                flowCompleted: optionalInt(stmt, 7),
                linkedPublicationCount: optionalInt(stmt, 8),
                resultReferenceCount: optionalInt(stmt, 9)
            )
        }

        let stmt = prepare("""
            SELECT results_first_post_date, primary_outcome_count, results_flags,
                   flow_started, flow_completed
              FROM trial_results WHERE trial_id = ? LIMIT 1
            """, [.int(trialId)])
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return TrialResultsSummary(
            resultsFirstPostDate: date(stmt, 0),
            studyRecordLastUpdatePostDate: nil,
            primaryOutcomeCount: Int(int(stmt, 1)),
            secondaryOutcomeCount: nil,
            totalOutcomeCount: nil,
            resultsFlags: Int(int(stmt, 2)),
            flowStarted: optionalInt(stmt, 3),
            flowCompleted: optionalInt(stmt, 4),
            linkedPublicationCount: nil,
            resultReferenceCount: nil
        )
    }

    // MARK: - Schema v13 publications / Drugs@FDA (Trial Detail)

    /// CTG-linked publications for a trial. Empty when tables missing or unfilled.
    func publications(trialId: Int64) -> [TrialPublication] {
        guard hasPublications else { return [] }
        let stmt = prepare("""
            SELECT p.publication_id, p.pmid, p.doi, p.openalex_id, p.title, p.journal_name,
                   p.publication_date, p.publication_year,
                   p.is_open_access, p.open_access_status, p.landing_page_url, p.open_access_url,
                   p.enrichment_status,
                   tp.reference_type, tp.source_citation, tp.is_retracted, tp.retraction_count
              FROM trial_publication tp
              JOIN publication p ON p.publication_id = tp.publication_id
             WHERE tp.trial_id = ?
             ORDER BY tp.reference_type, p.publication_year DESC, p.publication_id
            """, [.int(trialId)])
        defer { sqlite3_finalize(stmt) }
        var out: [TrialPublication] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(TrialPublication(
                publicationID: int(stmt, 0),
                pmid: text(stmt, 1),
                doi: text(stmt, 2),
                openAlexID: text(stmt, 3),
                title: text(stmt, 4),
                journalName: text(stmt, 5),
                publicationDate: date(stmt, 6),
                publicationYear: optionalInt(stmt, 7),
                referenceType: text(stmt, 13) ?? "",
                sourceCitation: text(stmt, 14),
                isOpenAccess: optionalBool(stmt, 8),
                openAccessStatus: text(stmt, 9),
                landingPageURL: text(stmt, 10),
                openAccessURL: text(stmt, 11),
                isRetracted: boolValue(stmt, 15),
                retractionCount: Int(int(stmt, 16)),
                enrichmentStatus: text(stmt, 12) ?? "citation_only"
            ))
        }
        return out
    }

    func publicationRetractions(publicationId: Int64) -> [PublicationRetraction] {
        guard hasPublicationRetractions else { return [] }
        let stmt = prepare("""
            SELECT retraction_pmid, retraction_source
              FROM publication_retraction
             WHERE publication_id = ?
            """, [.int(publicationId)])
        defer { sqlite3_finalize(stmt) }
        var out: [PublicationRetraction] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(PublicationRetraction(
                retractionPMID: text(stmt, 0) ?? "",
                retractionSource: text(stmt, 1) ?? ""
            ))
        }
        return out
    }

    /// Drugs@FDA ingredient matches for a trial’s interventions. Empty when tables missing/unfilled.
    func fdaIngredients(trialId: Int64) -> [TrialFDAIngredient] {
        guard hasFdaDrugs, hasTrialDrug else { return [] }
        let stmt = prepare("""
            SELECT d.fda_drug_id, d.canonical_ingredient, d.first_known_approval_date,
                   d.approval_date_scope, td.original_intervention, td.match_method
              FROM trial_drug td
              JOIN fda_drug d ON d.fda_drug_id = td.fda_drug_id
             WHERE td.trial_id = ?
             ORDER BY td.original_intervention, d.canonical_ingredient
            """, [.int(trialId)])
        defer { sqlite3_finalize(stmt) }
        var out: [TrialFDAIngredient] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(TrialFDAIngredient(
                fdaDrugID: int(stmt, 0),
                canonicalIngredient: text(stmt, 1) ?? "",
                originalIntervention: text(stmt, 4) ?? "",
                firstKnownApprovalDate: date(stmt, 2),
                approvalDateScope: text(stmt, 3) ?? "unknown",
                matchMethod: text(stmt, 5) ?? ""
            ))
        }
        return out
    }

    func fdaBrands(fdaDrugId: Int64) -> [FDABrand] {
        guard hasFdaDrugs else { return [] }
        let stmt = prepare("""
            SELECT brand_name FROM fda_brand
             WHERE fda_drug_id = ?
             ORDER BY brand_name
            """, [.int(fdaDrugId)])
        defer { sqlite3_finalize(stmt) }
        var out: [FDABrand] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let name = text(stmt, 0), !name.isEmpty {
                out.append(FDABrand(brandName: name))
            }
        }
        return out
    }

    func fdaApplications(fdaDrugId: Int64) -> [FDAApplication] {
        guard hasFdaDrugs else { return [] }
        let stmt = prepare("""
            SELECT a.application_number, a.application_type, a.sponsor_name,
                   a.approval_date, a.marketing_status
              FROM fda_drug_application da
              JOIN fda_application a ON a.application_number = da.application_number
             WHERE da.fda_drug_id = ?
             ORDER BY a.approval_date, a.application_number
            """, [.int(fdaDrugId)])
        defer { sqlite3_finalize(stmt) }
        var out: [FDAApplication] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(FDAApplication(
                applicationNumber: text(stmt, 0) ?? "",
                applicationType: text(stmt, 1) ?? "",
                sponsorName: text(stmt, 2),
                approvalDate: date(stmt, 3),
                marketingStatus: text(stmt, 4)
            ))
        }
        return out
    }

    func fdaProducts(fdaDrugId: Int64) -> [FDAProduct] {
        guard hasFdaDrugs else { return [] }
        let stmt = prepare("""
            SELECT application_number, product_number, drug_name, dosage_form, strength,
                   marketing_status, is_reference_drug, is_reference_standard
              FROM fda_product
             WHERE fda_drug_id = ?
             ORDER BY application_number, product_number
            """, [.int(fdaDrugId)])
        defer { sqlite3_finalize(stmt) }
        var out: [FDAProduct] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(FDAProduct(
                applicationNumber: text(stmt, 0) ?? "",
                productNumber: text(stmt, 1) ?? "",
                drugName: text(stmt, 2),
                dosageForm: text(stmt, 3),
                strength: text(stmt, 4),
                marketingStatus: text(stmt, 5),
                isReferenceDrug: optionalBool(stmt, 6),
                isReferenceStandard: optionalBool(stmt, 7)
            ))
        }
        return out
    }

    private func eligibility(trialId: Int64) -> TrialEligibilityInfo? {
        let populationSQL = usesCompressedStudyPopulation ? "study_population_z" : "study_population"
        let stmt = prepare("""
            SELECT inclusion_z, exclusion_z, raw_text_z, \(populationSQL), sampling_method
            FROM eligibility WHERE trial_id = ? LIMIT 1
            """, [.int(trialId)])
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let population: String? = usesCompressedStudyPopulation
            ? compressedText(stmt, 3, column: "study_population_z")
            : text(stmt, 3)
        return TrialEligibilityInfo(inclusion: compressedText(stmt, 0, column: "inclusion_z"),
                                    exclusion: compressedText(stmt, 1, column: "exclusion_z"),
                                    rawText: compressedText(stmt, 2, column: "raw_text_z"),
                                    studyPopulation: population,
                                    samplingMethod: text(stmt, 4))
    }

    // MARK: - Watchlist / recommendation lookups by NCT id

    func summaries(nctIds: [String]) -> [TrialSummary] {
        guard !nctIds.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: nctIds.count).joined(separator: ",")
        let stmt = prepare("SELECT \(summaryColumns()) FROM trial WHERE nct_id IN (\(placeholders))",
                           nctIds.map { .text($0) })
        defer { sqlite3_finalize(stmt) }
        var map: [String: TrialSummary] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let s = summary(from: stmt)
            map[s.nctId] = s
        }
        return nctIds.compactMap { map[$0] }   // preserve caller order
    }

    // MARK: - Lookups

    private struct LookupTable {
        let name: String
        /// Expression selected as the filter/canonical value (usually `value`).
        let value: String
        let display: String     // some lookup tables have no separate display column
        let count: String
        let order: String
        /// Column a text search runs against, and whether its contents are
        /// already lowercased (SQLite's LIKE only case-folds ASCII).
        let search: String
        let searchIsNormalized: Bool

        init(name: String, display: String, count: String, order: String,
             value: String = "value", search: String = "value", searchIsNormalized: Bool = false) {
            self.name = name
            self.value = value
            self.display = display
            self.count = count
            self.order = order
            self.search = search
            self.searchIsNormalized = searchIsNormalized
        }
    }

    private func table(for dimension: LookupDimension) -> LookupTable {
        switch dimension {
        case .status:
            return LookupTable(name: "lookup_status", display: "display", count: "trial_count", order: "sort_order, value")
        case .phase:
            return LookupTable(name: "lookup_phase", display: "display", count: "trial_count", order: "sort_order, value")
        case .studyType:
            return LookupTable(name: "lookup_study_type", display: "display", count: "trial_count", order: "sort_order, value")
        case .gender:
            return LookupTable(name: "lookup_gender", display: "display", count: "trial_count", order: "sort_order, value")
        case .country:
            return LookupTable(name: "lookup_country", display: "value", count: "trial_count", order: "trial_count DESC, value")
        case .condition:
            // Searching value_norm makes the match case-insensitive for
            // non-ASCII names too, which `value LIKE` would miss.
            return LookupTable(name: "lookup_condition", display: "value", count: "trial_count",
                               order: "trial_count DESC, value",
                               search: hasConditionValueNorm ? "value_norm" : "value",
                               searchIsNormalized: hasConditionValueNorm)
        case .ageRange:
            return LookupTable(name: "lookup_age_range", display: "display", count: "0", order: "sort_order, value")
        case .collaborator:
            return LookupTable(
                name: "lookup_collaborator",
                display: "name",
                count: "trial_count",
                order: "trial_count DESC, name",
                value: "CAST(collaborator_id AS TEXT)",
                search: "name"
            )
        }
    }

    private func lookupValues(_ sql: String, _ args: [SQLArg]) -> [LookupValue] {
        let stmt = prepare(sql, args)
        defer { sqlite3_finalize(stmt) }
        var out: [LookupValue] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(LookupValue(value: text(stmt, 0) ?? "",
                                   display: text(stmt, 1) ?? (text(stmt, 0) ?? ""),
                                   count: Int(int(stmt, 2))))
        }
        return out
    }

    /// `limit` matters for conditions: the registry's condition field is free
    /// text, so `lookup_condition` can hold tens of thousands of rows. Menus
    /// take the most common ones and reach for `searchLookup` beyond that.
    func lookup(_ dimension: LookupDimension, limit: Int? = nil) -> [LookupValue] {
        guard dimension != .collaborator || hasCollaborators else { return [] }
        let t = table(for: dimension)
        var sql = "SELECT \(t.value), \(t.display), \(t.count) FROM \(t.name) ORDER BY \(t.order)"
        var args: [SQLArg] = []
        if let limit {
            sql += " LIMIT ?"
            args.append(.int(Int64(limit)))
        }
        return lookupValues(sql, args)
    }

    func searchLookup(_ dimension: LookupDimension, query: String, limit: Int) -> [LookupValue] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return lookup(dimension, limit: limit) }
        guard dimension != .collaborator || hasCollaborators else { return [] }

        let t = table(for: dimension)
        let escaped = (t.searchIsNormalized ? trimmed.lowercased() : trimmed)
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        let sql = """
            SELECT \(t.value), \(t.display), \(t.count) FROM \(t.name)
            WHERE \(t.search) LIKE ? ESCAPE '\\' ORDER BY \(t.order) LIMIT ?
            """
        return lookupValues(sql, [.text("%\(escaped)%"), .int(Int64(limit))])
    }

    /// Schema v9: FTS over organisation names (`collaborator_fts`).
    func searchCollaborators(query: String, limit: Int = 40) -> [LookupValue] {
        guard hasCollaborators else { return [] }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return lookup(.collaborator, limit: limit) }
        guard hasCollaboratorFTS, let match = Self.ftsQuery(trimmed) else {
            return searchLookup(.collaborator, query: trimmed, limit: limit)
        }
        let sql = """
            SELECT CAST(lc.collaborator_id AS TEXT), lc.name, lc.trial_count
              FROM collaborator_fts
              JOIN lookup_collaborator lc ON lc.collaborator_id = collaborator_fts.rowid
             WHERE collaborator_fts MATCH ?
             ORDER BY lc.trial_count DESC
             LIMIT ?
            """
        return lookupValues(sql, [.text(match), .int(Int64(limit))])
    }

    func collaboratorName(id: String) -> String? {
        guard hasCollaborators, let cid = Int64(id) else { return nil }
        let stmt = prepare("SELECT name FROM lookup_collaborator WHERE collaborator_id = ? LIMIT 1", [.int(cid)])
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return text(stmt, 0)
    }

    /// Total distinct values available for a dimension, for display purposes.
    func lookupTotal(_ dimension: LookupDimension) -> Int {
        if dimension == .collaborator, !hasCollaborators { return 0 }
        let stmt = prepare("SELECT COUNT(*) FROM \(table(for: dimension).name)")
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(int(stmt, 0)) : 0
    }

    // MARK: - Schema v14 Discover browse (conditions / interventions)

    /// Non-population conditions in `lookup_condition` (Discover landscape count).
    func discoverConditionCount() -> Int {
        guard tableExists("lookup_condition") else { return 0 }
        if columnExists("lookup_condition", "is_population") {
            return scalarCount("SELECT COUNT(*) FROM lookup_condition WHERE is_population = 0")
        }
        return scalarCount("SELECT COUNT(*) FROM lookup_condition")
    }

    /// Schema v14: top conditions from `popular_condition` (already excludes population labels).
    func popularConditions(limit: Int) -> [LookupValue] {
        guard hasPopularCondition else { return [] }
        let stmt = prepare("""
            SELECT l.value, l.value, l.trial_count
              FROM popular_condition p
              JOIN lookup_condition l ON l.value = p.value
             ORDER BY p.rank
             LIMIT ?
            """, [.int(Int64(limit))])
        defer { sqlite3_finalize(stmt) }
        var out: [LookupValue] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(LookupValue(
                value: text(stmt, 0) ?? "",
                display: text(stmt, 1) ?? "",
                count: Int(int(stmt, 2))
            ))
        }
        return out
    }

    /// Discover condition search — excludes `is_population = 1` when that column exists.
    func searchDiscoverConditions(_ query: String, limit: Int) -> [LookupValue] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return popularConditions(limit: limit) }
        guard tableExists("lookup_condition") else { return [] }

        let escaped = (hasConditionValueNorm ? trimmed.lowercased() : trimmed)
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        let searchCol = hasConditionValueNorm ? "value_norm" : "value"
        var sql = """
            SELECT value, value, trial_count FROM lookup_condition
             WHERE \(searchCol) LIKE ? ESCAPE '\\'
            """
        if columnExists("lookup_condition", "is_population") {
            sql += " AND is_population = 0"
        }
        sql += " ORDER BY trial_count DESC, value COLLATE NOCASE LIMIT ?"
        return lookupValues(sql, [.text("%\(escaped)%"), .int(Int64(limit))])
    }

    func discoverInterventionCount() -> Int {
        guard hasLookupIntervention else { return 0 }
        return scalarCount("SELECT COUNT(*) FROM lookup_intervention")
    }

    func popularInterventions(limit: Int) -> [InterventionLookupValue] {
        guard hasPopularIntervention, hasLookupIntervention else { return [] }
        let stmt = prepare("""
            SELECT i.value, i.trial_count, i.type
              FROM popular_intervention p
              JOIN lookup_intervention i ON i.value = p.value
             ORDER BY p.rank
             LIMIT ?
            """, [.int(Int64(limit))])
        defer { sqlite3_finalize(stmt) }
        return readInterventionLookups(stmt)
    }

    func searchInterventions(_ query: String, limit: Int) -> [InterventionLookupValue] {
        guard hasLookupIntervention else { return [] }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return popularInterventions(limit: limit) }

        let escaped = trimmed.lowercased()
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        let stmt = prepare("""
            SELECT value, trial_count, type FROM lookup_intervention
             WHERE value_norm LIKE ? ESCAPE '\\'
             ORDER BY trial_count DESC, value COLLATE NOCASE
             LIMIT ?
            """, [.text("%\(escaped)%"), .int(Int64(limit))])
        defer { sqlite3_finalize(stmt) }
        return readInterventionLookups(stmt)
    }

    /// Distinct Drugs@FDA ingredients that appear in `trial_drug` (tied to ≥1 trial).
    /// Optional `query` matches `canonical_ingredient` (case-insensitive substring).
    func trialLinkedFdaDrugs(query: String = "", limit: Int = 5_000) -> [InterventionLookupValue] {
        guard hasFdaDrugs, hasTrialDrug else { return [] }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let stmt: OpaquePointer?
        if trimmed.isEmpty {
            stmt = prepare("""
                SELECT d.canonical_ingredient, COUNT(DISTINCT td.trial_id)
                  FROM trial_drug td
                  JOIN fda_drug d ON d.fda_drug_id = td.fda_drug_id
                 GROUP BY d.fda_drug_id
                 ORDER BY COUNT(DISTINCT td.trial_id) DESC, d.canonical_ingredient COLLATE NOCASE
                 LIMIT ?
                """, [.int(Int64(limit))])
        } else {
            let escaped = trimmed
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_")
            stmt = prepare("""
                SELECT d.canonical_ingredient, COUNT(DISTINCT td.trial_id)
                  FROM trial_drug td
                  JOIN fda_drug d ON d.fda_drug_id = td.fda_drug_id
                 WHERE d.canonical_ingredient LIKE ? ESCAPE '\\'
                 GROUP BY d.fda_drug_id
                 ORDER BY COUNT(DISTINCT td.trial_id) DESC, d.canonical_ingredient COLLATE NOCASE
                 LIMIT ?
                """, [.text("%\(escaped)%"), .int(Int64(limit))])
        }
        defer { sqlite3_finalize(stmt) }
        var out: [InterventionLookupValue] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let value = text(stmt, 0) ?? ""
            guard !value.isEmpty else { continue }
            out.append(InterventionLookupValue(
                value: value,
                trialCount: Int(int(stmt, 1)),
                type: "DRUG",
                inFdaCatalog: true
            ))
        }
        return out
    }

    private func readInterventionLookups(_ stmt: OpaquePointer?) -> [InterventionLookupValue] {
        var out: [InterventionLookupValue] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let value = text(stmt, 0) ?? ""
            let key = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            out.append(InterventionLookupValue(
                value: value,
                trialCount: Int(int(stmt, 1)),
                type: text(stmt, 2) ?? "",
                inFdaCatalog: !key.isEmpty && fdaCatalogNorms.contains(key)
            ))
        }
        return out
    }

    // MARK: - Aggregates

    func dashboardStats() -> DashboardStats {
        let exclSQL = hasExclHealthyAggregates
            ? ", total_trials_excl_healthy, recruiting_count_excl_healthy, active_not_recruiting_count_excl_healthy"
            : ""
        let stmt = prepare("""
            SELECT total_trials, recruiting_count, active_not_recruiting_count,
                   recently_updated_count, created_at, source_snapshot_date,
                   schema_version, generator_version, source, build_options
                   \(exclSQL)
            FROM db_metadata WHERE id = 1
            """)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return DashboardStats(totalTrials: 0, recruitingCount: 0, activeNotRecruitingCount: 0,
                                  recentlyUpdatedCount: 0, createdAt: nil, sourceSnapshotDate: nil,
                                  schemaVersion: 0, generatorVersion: nil, source: nil, buildOptions: nil,
                                  totalTrialsExclHealthy: nil, recruitingCountExclHealthy: nil,
                                  activeNotRecruitingCountExclHealthy: nil)
        }
        return DashboardStats(
            totalTrials: Int(int(stmt, 0)),
            recruitingCount: Int(int(stmt, 1)),
            activeNotRecruitingCount: Int(int(stmt, 2)),
            recentlyUpdatedCount: Int(int(stmt, 3)),
            createdAt: date(stmt, 4),
            sourceSnapshotDate: date(stmt, 5),
            schemaVersion: Int(int(stmt, 6)),
            generatorVersion: text(stmt, 7),
            source: text(stmt, 8),
            buildOptions: text(stmt, 9),
            totalTrialsExclHealthy: hasExclHealthyAggregates ? Int(int(stmt, 10)) : nil,
            recruitingCountExclHealthy: hasExclHealthyAggregates ? Int(int(stmt, 11)) : nil,
            activeNotRecruitingCountExclHealthy: hasExclHealthyAggregates ? Int(int(stmt, 12)) : nil
        )
    }

    func dimensionCounts(_ dimension: AggDimension, scope: AggScope, limit: Int) -> [DimensionCount] {
        let stmt = prepare("""
            SELECT value, count FROM agg_dimension_count
            WHERE dimension = ? AND scope = ?
            ORDER BY count DESC LIMIT ?
            """, [.text(dimension.rawValue), .text(scope.rawValue), .int(Int64(limit))])
        defer { sqlite3_finalize(stmt) }
        var out: [DimensionCount] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(DimensionCount(value: text(stmt, 0) ?? "", count: Int(int(stmt, 1))))
        }
        return out
    }

    /// Lead sponsors are not in `agg_dimension_count` — group on the fly (indexed
    /// enough for a LIMIT 10 ranking on Analytics load).
    func topLeadSponsors(activeOnly: Bool, limit: Int) -> [DimensionCount] {
        let activeClause = activeOnly ? "AND is_active = 1" : ""
        let stmt = prepare("""
            SELECT lead_sponsor_name, COUNT(*) AS c
              FROM trial
             WHERE lead_sponsor_name IS NOT NULL AND lead_sponsor_name != ''
               \(activeClause)
             GROUP BY lead_sponsor_name
             ORDER BY c DESC
             LIMIT ?
            """, [.int(Int64(limit))])
        defer { sqlite3_finalize(stmt) }
        var out: [DimensionCount] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(DimensionCount(value: text(stmt, 0) ?? "", count: Int(int(stmt, 1))))
        }
        return out
    }

    /// Filter-menu search: empty query → top sponsors by trial count; otherwise LIKE.
    func searchLeadSponsors(query: String, limit: Int) -> [LookupValue] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return topLeadSponsors(activeOnly: false, limit: limit).map {
                LookupValue(value: $0.value, display: $0.value, count: $0.count)
            }
        }
        let escaped = trimmed
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        let stmt = prepare("""
            SELECT lead_sponsor_name, COUNT(*) AS c
              FROM trial
             WHERE lead_sponsor_name LIKE ? ESCAPE '\\'
             GROUP BY lead_sponsor_name
             ORDER BY c DESC, lead_sponsor_name
             LIMIT ?
            """, [.text("%\(escaped)%"), .int(Int64(limit))])
        defer { sqlite3_finalize(stmt) }
        var out: [LookupValue] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let name = text(stmt, 0) ?? ""
            out.append(LookupValue(value: name, display: name, count: Int(int(stmt, 1))))
        }
        return out
    }

    /// Schema v9: uses `lookup_collaborator.trial_count` when browsing all trials;
    /// active-only recomputes against `trial.is_active`.
    func topCollaborators(activeOnly: Bool, limit: Int) -> [DimensionCount] {
        guard hasCollaborators else { return [] }
        if !activeOnly {
            let stmt = prepare("""
                SELECT CAST(collaborator_id AS TEXT), name, trial_count
                  FROM lookup_collaborator
                 ORDER BY trial_count DESC, name
                 LIMIT ?
                """, [.int(Int64(limit))])
            defer { sqlite3_finalize(stmt) }
            var out: [DimensionCount] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(DimensionCount(
                    value: text(stmt, 0) ?? "",
                    count: Int(int(stmt, 2)),
                    display: text(stmt, 1)
                ))
            }
            return out
        }
        let stmt = prepare("""
            SELECT CAST(lc.collaborator_id AS TEXT), lc.name, COUNT(*) AS c
              FROM trial_collaborator tc
              JOIN trial t ON t.trial_id = tc.trial_id
              JOIN lookup_collaborator lc ON lc.collaborator_id = tc.collaborator_id
             WHERE t.is_active = 1
             GROUP BY lc.collaborator_id
             ORDER BY c DESC
             LIMIT ?
            """, [.int(Int64(limit))])
        defer { sqlite3_finalize(stmt) }
        var out: [DimensionCount] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(DimensionCount(
                value: text(stmt, 0) ?? "",
                count: Int(int(stmt, 2)),
                display: text(stmt, 1)
            ))
        }
        return out
    }

    func yearCounts(scope: AggScope) -> [YearCount] {
        let stmt = prepare("SELECT year, count FROM agg_year_count WHERE scope = ? ORDER BY year",
                           [.text(scope.rawValue)])
        defer { sqlite3_finalize(stmt) }
        var out: [YearCount] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(YearCount(year: Int(int(stmt, 0)), count: Int(int(stmt, 1))))
        }
        return out
    }

    /// Schema v6 requires `scope` — without it four scopes interleave. Older files
    /// only built the `all` scope and have no scope column.
    func topConditionByYear(scope: AggScope, maxRank: Int = 3) -> [ConditionByYear] {
        let sql: String
        let args: [SQLArg]
        if conditionByYearHasScope {
            sql = """
                SELECT year, condition, count, rank FROM agg_condition_by_year
                WHERE scope = ? AND rank <= ?
                ORDER BY year DESC, rank
                """
            args = [.text(scope.rawValue), .int(Int64(maxRank))]
        } else {
            sql = """
                SELECT year, condition, count, rank FROM agg_condition_by_year
                WHERE rank <= ?
                ORDER BY year DESC, rank
                """
            args = [.int(Int64(maxRank))]
        }
        let stmt = prepare(sql, args)
        defer { sqlite3_finalize(stmt) }
        var out: [ConditionByYear] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(ConditionByYear(
                year: Int(int(stmt, 0)),
                condition: text(stmt, 1) ?? "",
                count: Int(int(stmt, 2)),
                rank: Int(int(stmt, 3))
            ))
        }
        return out
    }

    // MARK: - Editor's Picks (deterministic Home curation)

    /// High-signal interventional studies: recruiting and/or newly posted,
    /// Phase II/III preferred, larger enrolment and industry sponsor boosted.
    /// Caller applies diversity / 30-day no-repeat on the returned pool.
    func editorPickCandidates(poolLimit: Int = 80, excluding nctIds: Set<String> = []) -> [TrialSummary] {
        let postedCutoff = Int64(Date().addingTimeInterval(-90 * 86_400).timeIntervalSince1970)
        var clauses = [
            "trial.study_type = 'INTERVENTIONAL'",
            """
            (trial.overall_status = 'RECRUITING'
             OR trial.first_posted_date >= ?)
            """,
            """
            trial.phase IN ('PHASE2', 'PHASE3', 'PHASE2_PHASE3', 'PHASE1_PHASE2')
            """
        ]
        var args: [SQLArg] = [.int(postedCutoff)]

        if !nctIds.isEmpty {
            let placeholders = Array(repeating: "?", count: nctIds.count).joined(separator: ",")
            clauses.append("trial.nct_id NOT IN (\(placeholders))")
            args.append(contentsOf: nctIds.sorted().map { .text($0) })
        }

        // Same postedCutoff again inside the score expression.
        args.append(.int(postedCutoff))
        args.append(.int(Int64(poolLimit)))

        let scoreSQL = """
            (CASE trial.phase
                WHEN 'PHASE3' THEN 40
                WHEN 'PHASE2_PHASE3' THEN 35
                WHEN 'PHASE2' THEN 30
                WHEN 'PHASE1_PHASE2' THEN 12
                ELSE 0 END)
            + (CASE WHEN trial.overall_status = 'RECRUITING' THEN 25 ELSE 0 END)
            + (CASE WHEN trial.first_posted_date >= ? THEN 20 ELSE 0 END)
            + (CASE
                WHEN trial.enrollment_count >= 500 THEN 20
                WHEN trial.enrollment_count >= 100 THEN 12
                WHEN trial.enrollment_count >= 50 THEN 6
                ELSE 0 END)
            + (CASE WHEN trial.lead_sponsor_class = 'INDUSTRY' THEN 10 ELSE 0 END)
            """

        let sql = """
            SELECT \(summaryColumns("trial."))
            FROM trial
            WHERE \(clauses.joined(separator: " AND "))
            ORDER BY (\(scoreSQL)) DESC,
                     trial.first_posted_date DESC,
                     trial.trial_id DESC
            LIMIT ?
            """
        let stmt = prepare(sql, args)
        defer { sqlite3_finalize(stmt) }
        var out: [TrialSummary] = []
        out.reserveCapacity(poolLimit)
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(summary(from: stmt))
        }
        return out
    }

    // MARK: - Clinical Research Pulse

    func pulseCapabilities() -> PulseCapabilities {
        PulseCapabilities(
            onThisDay: hasPulseOnThisDay,
            interestingTrial: hasPulseInteresting,
            conditionGrowth: hasPulseConditionGrowth
        )
    }

    /// Counts for the Pulse “Recent activity” line. New = first posted; the
    /// status counts use last record update (registry never publishes change day).
    func pulseRecentActivity(withinDays: Int = 30) -> PulseRecentActivity {
        let cutoff = Int64(Date().addingTimeInterval(-Double(withinDays) * 86_400).timeIntervalSince1970)
        func count(_ sql: String, _ args: [SQLArg]) -> Int {
            let stmt = prepare(sql, args)
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return Int(int(stmt, 0))
        }
        return PulseRecentActivity(
            newTrials: count(
                "SELECT COUNT(*) FROM trial WHERE first_posted_date >= ?",
                [.int(cutoff)]
            ),
            beganRecruiting: count(
                """
                SELECT COUNT(*) FROM trial
                WHERE overall_status = 'RECRUITING' AND last_update_post_date >= ?
                """,
                [.int(cutoff)]
            ),
            completed: count(
                """
                SELECT COUNT(*) FROM trial
                WHERE overall_status = 'COMPLETED' AND last_update_post_date >= ?
                """,
                [.int(cutoff)]
            ),
            terminated: count(
                """
                SELECT COUNT(*) FROM trial
                WHERE overall_status = 'TERMINATED' AND last_update_post_date >= ?
                """,
                [.int(cutoff)]
            )
        )
    }

    /// One study from today's shortlist. Rotates among ranks using a UTC day seed
    /// so the card changes across the month without scanning `trial`.
    ///
    /// Schema v8: use `first_posted_year` as stored — do not derive the year from
    /// `first_posted_date` in local time (midnight-UTC posts disagree with month/day).
    func pulseOnThisDay(now: Date = Date()) -> PulseOnThisDay? {
        guard hasPulseOnThisDay else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let month = calendar.component(.month, from: now)
        let day = calendar.component(.day, from: now)
        let year = calendar.component(.year, from: now)

        let countStmt = prepare(
            "SELECT COUNT(*) FROM pulse_on_this_day WHERE month = ? AND day = ?",
            [.int(Int64(month)), .int(Int64(day))]
        )
        defer { sqlite3_finalize(countStmt) }
        guard sqlite3_step(countStmt) == SQLITE_ROW else { return nil }
        let count = Int(int(countStmt, 0))
        guard count > 0 else { return nil }

        let dayOfYear = calendar.ordinality(of: .day, in: .year, for: now) ?? 1
        let rank = ((dayOfYear - 1) % count) + 1

        let stmt = prepare("""
            SELECT nct_id, brief_title, first_posted_year, phase, primary_condition,
                   enrollment_count, has_results
            FROM pulse_on_this_day
            WHERE month = ? AND day = ? AND rank = ?
            LIMIT 1
            """, [.int(Int64(month)), .int(Int64(day)), .int(Int64(rank))])
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        // Column is authoritative (UTC); never derive from an epoch locally.
        let postedYear = Int(int(stmt, 2))
        return PulseOnThisDay(
            nctId: text(stmt, 0) ?? "",
            briefTitle: text(stmt, 1) ?? "",
            firstPostedYear: postedYear,
            yearsAgo: max(0, year - postedYear),
            phaseDisplay: displayNames.phaseLabel(text(stmt, 3)),
            primaryCondition: text(stmt, 4),
            enrollmentCount: optionalInt(stmt, 5),
            hasResults: boolValue(stmt, 6)
        )
    }

    /// Deterministic daily pick from the interesting pool.
    ///
    /// Schema v8: pick by dense `candidate_id` (theme round-robin), never by `score`.
    /// Score order would cluster a single theme (e.g. VR) for weeks.
    func pulseInterestingTrial(now: Date = Date()) -> PulseInterestingTrial? {
        guard hasPulseInteresting else { return nil }
        let countStmt = prepare("SELECT COUNT(*) FROM pulse_interesting_trial")
        defer { sqlite3_finalize(countStmt) }
        guard sqlite3_step(countStmt) == SQLITE_ROW else { return nil }
        let count = Int(int(countStmt, 0))
        guard count > 0 else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let dayOfYear = calendar.ordinality(of: .day, in: .year, for: now) ?? 1
        // 1…N walk: day 1 → candidate_id 1. Do not ORDER BY score.
        let candidateId = ((dayOfYear - 1) % count) + 1

        let stmt = prepare("""
            SELECT nct_id, brief_title, primary_condition, overall_status, primary_country,
                   interest_tags, blurb
            FROM pulse_interesting_trial WHERE candidate_id = ? LIMIT 1
            """, [.int(Int64(candidateId))])
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let status = text(stmt, 3) ?? "UNKNOWN"
        let tags = (text(stmt, 5) ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return PulseInterestingTrial(
            nctId: text(stmt, 0) ?? "",
            briefTitle: text(stmt, 1) ?? "",
            primaryCondition: text(stmt, 2),
            statusDisplay: displayNames.statusLabel(status),
            primaryCountry: text(stmt, 4),
            interestTags: tags,
            blurb: text(stmt, 6)
        )
    }

    /// Precomputed growth leaderboard. User-facing default is excl-healthy so
    /// "Healthy Volunteers" does not top the chart (schema v8).
    func pulseConditionGrowth(scope: AggScope = .allExclHealthy, metric: String = "ratio",
                              limit: Int = 8) -> [PulseConditionGrowth] {
        guard hasPulseConditionGrowth else { return [] }
        let stmt = prepare("""
            SELECT condition, year_from, year_to, count_from, count_to, abs_delta, growth_ratio, rank
            FROM pulse_condition_growth
            WHERE scope = ? AND metric = ?
            ORDER BY rank
            LIMIT ?
            """, [.text(scope.rawValue), .text(metric), .int(Int64(limit))])
        defer { sqlite3_finalize(stmt) }
        var out: [PulseConditionGrowth] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(PulseConditionGrowth(
                condition: text(stmt, 0) ?? "",
                yearFrom: Int(int(stmt, 1)),
                yearTo: Int(int(stmt, 2)),
                countFrom: Int(int(stmt, 3)),
                countTo: Int(int(stmt, 4)),
                absDelta: Int(int(stmt, 5)),
                growthRatio: optionalDouble(stmt, 6),
                rank: Int(int(stmt, 7))
            ))
        }
        return out
    }

    /// Recently updated studies in a terminal status via `idx_trial_status_update`.
    /// Registry only exposes record-update time, never status-change day.
    func pulseStatusWatch(status: String, withinDays: Int = 30, limit: Int = 5) -> [PulseStoppedTrial] {
        let cutoff = Int64(Date().addingTimeInterval(-Double(withinDays) * 86_400).timeIntervalSince1970)
        let precisionCol = usesDatePrecision ? ", date_precision" : ""
        let stmt = prepare("""
            SELECT nct_id, brief_title, overall_status, phase, primary_condition,
                   lead_sponsor_name, why_stopped, last_update_post_date, has_results
                   \(precisionCol)
            FROM trial
            WHERE overall_status = ?
              AND last_update_post_date >= ?
            ORDER BY last_update_post_date DESC
            LIMIT ?
            """, [.text(status), .int(cutoff), .int(Int64(limit))])
        defer { sqlite3_finalize(stmt) }
        var out: [PulseStoppedTrial] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let statusValue = text(stmt, 2) ?? "UNKNOWN"
            let epoch = optionalInt64(stmt, 7)
            let precision: DatePrecision
            if usesDatePrecision, sqlite3_column_type(stmt, 9) != SQLITE_NULL {
                precision = DatePrecision(mask: Int(int(stmt, 9)), shift: DatePrecision.lastUpdate)
            } else {
                precision = .day
            }
            out.append(PulseStoppedTrial(
                nctId: text(stmt, 0) ?? "",
                briefTitle: text(stmt, 1) ?? "",
                overallStatus: statusValue,
                statusDisplay: displayNames.statusLabel(statusValue),
                phaseDisplay: displayNames.phaseLabel(text(stmt, 3)),
                primaryCondition: text(stmt, 4),
                leadSponsorName: text(stmt, 5),
                whyStopped: text(stmt, 6),
                lastUpdateLabel: TrialDateFormat.string(epochSeconds: epoch, precision: precision),
                hasResults: boolValue(stmt, 8)
            ))
        }
        return out
    }

    // MARK: - Nearby recruiting (geo)

    /// Recruiting studies with at least one site inside `radiusMeters` of the user.
    ///
    /// Site coordinates live in packed `detail_z` (schema v2+), so this streams
    /// candidate rows, inflates locations, and applies a haversine check. A
    /// country hint (from reverse geocode) is applied when the filter has no
    /// country of its own — that keeps a US scan around a few seconds.
    func nearbyRecruiting(
        latitude: Double,
        longitude: Double,
        radiusMeters: Double,
        filter: TrialFilter,
        countryHint: String? = nil,
        limit: Int = 200
    ) -> [NearbyTrial] {
        guard radiusMeters > 0, limit > 0 else { return [] }

        var f = filter
        f.status = "RECRUITING"
        if f.country == nil, let resolved = resolveCountryHint(countryHint) {
            f.country = resolved
        }

        if usesDetailBlob {
            return nearbyFromDetailBlob(
                latitude: latitude, longitude: longitude,
                radiusMeters: radiusMeters, filter: f, limit: limit
            )
        }
        return nearbyFromLocationTable(
            latitude: latitude, longitude: longitude,
            radiusMeters: radiusMeters, filter: f, limit: limit
        )
    }

    private func resolveCountryHint(_ hint: String?) -> String? {
        guard let hint, !hint.isEmpty else { return nil }
        let countries = lookupCounts[.country] ?? [:]
        if countries[hint] != nil { return hint }
        let lowered = hint.lowercased()
        return countries.keys.first { $0.lowercased() == lowered }
    }

    private func nearbyFromDetailBlob(
        latitude: Double, longitude: Double,
        radiusMeters: Double, filter: TrialFilter, limit: Int
    ) -> [NearbyTrial] {
        let (whereSQL, args) = whereClause(filter)
        let sql = """
            SELECT \(summaryColumns("trial.")), trial.detail_z
            FROM trial
            \(whereSQL)
            AND trial.detail_z IS NOT NULL
            """
        let stmt = prepare(sql, args)
        defer { sqlite3_finalize(stmt) }

        let dict = dictionaries["detail_z"]
        let detailCol: Int32 = usesDatePrecision ? 15 : 14
        var hits: [NearbyTrial] = []

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let blob = blob(stmt, detailCol),
                  let data = Self.decompressData(blob, dictionary: dict),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            let summary = summary(from: stmt)
            guard let nearest = nearestSite(
                in: root["l"] as? [[Any]] ?? [],
                latitude: latitude, longitude: longitude, radiusMeters: radiusMeters
            ) else { continue }

            hits.append(NearbyTrial(
                trial: summary,
                site: nearest.site,
                distanceMeters: nearest.meters,
                matchScore: nil
            ))
        }

        hits.sort { $0.distanceMeters < $1.distanceMeters }
        if hits.count > limit { hits = Array(hits.prefix(limit)) }
        return hits
    }

    private func nearbyFromLocationTable(
        latitude: Double, longitude: Double,
        radiusMeters: Double, filter: TrialFilter, limit: Int
    ) -> [NearbyTrial] {
        let latDelta = radiusMeters / 111_320.0
        let cosLat = max(0.01, cos(latitude * .pi / 180))
        let lonDelta = radiusMeters / (111_320.0 * cosLat)
        let (whereSQL, args) = whereClause(filter)

        let sql = """
            SELECT \(summaryColumns("trial.")),
                   l.facility_name, l.city, l.state, l.country, l.postal_code, l.status,
                   l.latitude, l.longitude
            FROM trial
            JOIN location l ON l.trial_id = trial.trial_id
            \(whereSQL.isEmpty ? "WHERE" : whereSQL + " AND")
            l.latitude BETWEEN ? AND ?
            AND l.longitude BETWEEN ? AND ?
            """
        var bind = args
        bind.append(contentsOf: [
            .double(latitude - latDelta), .double(latitude + latDelta),
            .double(longitude - lonDelta), .double(longitude + lonDelta)
        ])

        let stmt = prepare(sql, bind)
        defer { sqlite3_finalize(stmt) }

        let baseCols: Int32 = usesDatePrecision ? 15 : 14
        var bestByTrial: [Int64: NearbyTrial] = [:]

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let lat = optionalDouble(stmt, baseCols + 6),
                  let lon = optionalDouble(stmt, baseCols + 7),
                  Self.isValidCoordinate(lat: lat, lon: lon)
            else { continue }

            let meters = NearbyDistance.meters(from: latitude, lon1: longitude, to: lat, lon2: lon)
            guard meters <= radiusMeters else { continue }

            let summary = summary(from: stmt)
            let site = TrialLocationInfo(
                facilityName: text(stmt, baseCols),
                city: text(stmt, baseCols + 1),
                state: text(stmt, baseCols + 2),
                country: text(stmt, baseCols + 3),
                postalCode: text(stmt, baseCols + 4),
                status: text(stmt, baseCols + 5),
                latitude: lat,
                longitude: lon
            )
            let hit = NearbyTrial(trial: summary, site: site, distanceMeters: meters, matchScore: nil)
            if let existing = bestByTrial[summary.trialId] {
                if meters < existing.distanceMeters { bestByTrial[summary.trialId] = hit }
            } else {
                bestByTrial[summary.trialId] = hit
            }
        }

        var hits = Array(bestByTrial.values)
        hits.sort { $0.distanceMeters < $1.distanceMeters }
        if hits.count > limit { hits = Array(hits.prefix(limit)) }
        return hits
    }

    private func nearestSite(
        in rows: [[Any]],
        latitude: Double, longitude: Double, radiusMeters: Double
    ) -> (site: TrialLocationInfo, meters: Double)? {
        var best: (TrialLocationInfo, Double)?
        for row in rows {
            guard let lat = Self.jsonNumber(row, 6),
                  let lon = Self.jsonNumber(row, 7),
                  Self.isValidCoordinate(lat: lat, lon: lon)
            else { continue }
            let meters = NearbyDistance.meters(from: latitude, lon1: longitude, to: lat, lon2: lon)
            guard meters <= radiusMeters else { continue }
            if let current = best, meters >= current.1 { continue }
            let site = TrialLocationInfo(
                facilityName: Self.jsonString(row, 0),
                city: Self.jsonString(row, 1),
                state: Self.jsonString(row, 2),
                country: Self.jsonString(row, 3),
                postalCode: Self.jsonString(row, 4),
                status: Self.jsonString(row, 5),
                latitude: lat,
                longitude: lon
            )
            best = (site, meters)
        }
        return best.map { ($0.0, $0.1) }
    }

    private static func isValidCoordinate(lat: Double, lon: Double) -> Bool {
        abs(lat) > 0.01 || abs(lon) > 0.01
    }

    private static func jsonString(_ row: [Any], _ i: Int) -> String? {
        guard i < row.count else { return nil }
        if row[i] is NSNull { return nil }
        return row[i] as? String
    }

    private static func jsonNumber(_ row: [Any], _ i: Int) -> Double? {
        guard i < row.count else { return nil }
        if row[i] is NSNull { return nil }
        return (row[i] as? NSNumber)?.doubleValue
    }

    // MARK: - Organisations (v10 tables when present; otherwise live v9 lead/collaborator queries)

    /// Count for Discover landscape box. v10: `organisation` rows. v9: distinct lead sponsors.
    func organisationEntityCount() -> Int {
        if let cachedOrganisationEntityCount { return cachedOrganisationEntityCount }
        let count: Int
        if hasOrganisations {
            let stmt = prepare("SELECT COUNT(*) FROM organisation")
            defer { sqlite3_finalize(stmt) }
            count = sqlite3_step(stmt) == SQLITE_ROW ? Int(int(stmt, 0)) : 0
        } else {
            let stmt = prepare("""
                SELECT COUNT(*) FROM (
                    SELECT DISTINCT lead_sponsor_name FROM trial
                    WHERE lead_sponsor_name IS NOT NULL AND lead_sponsor_name != ''
                )
                """)
            defer { sqlite3_finalize(stmt) }
            count = sqlite3_step(stmt) == SQLITE_ROW ? Int(int(stmt, 0)) : 0
        }
        cachedOrganisationEntityCount = count
        return count
    }

    /// Count for Discover landscape box. v10: `site` rows. v9 without site tables: 0.
    func siteEntityCount() -> Int {
        if let cachedSiteEntityCount { return cachedSiteEntityCount }
        let count: Int
        if hasSites {
            let stmt = prepare("SELECT COUNT(*) FROM site")
            defer { sqlite3_finalize(stmt) }
            count = sqlite3_step(stmt) == SQLITE_ROW ? Int(int(stmt, 0)) : 0
        } else {
            count = 0
        }
        cachedSiteEntityCount = count
        return count
    }

    func popularOrganisations(limit: Int) -> [OrganisationSummary] {
        if hasOrganisations {
            let stmt = prepare("""
                SELECT o.organisation_id, o.display_name, o.organisation_class,
                       o.total_related_trial_count, o.recruiting_trial_count, o.logo_asset_name,
                       \(activeOrganisationCountSQLAlias)
                FROM popular_organisation p
                JOIN organisation o ON o.organisation_id = p.organisation_id
                ORDER BY p.rank
                LIMIT ?
                """, [.int(Int64(limit))])
            defer { sqlite3_finalize(stmt) }
            return readUnifiedOrganisationSummaries(stmt)
        }
        return popularOrganisationsV9(limit: limit)
    }

    func organisations(category: OrganisationCategory, limit: Int) -> [OrganisationSummary] {
        if hasOrganisations {
            return organisationsV10(category: category, limit: limit)
        }
        return organisationsV9(category: category, limit: limit)
    }

    func searchOrganisations(_ query: String, category: OrganisationCategory, limit: Int) -> [OrganisationSummary] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return organisations(category: category, limit: limit) }
        if hasOrganisations {
            return searchOrganisationsV10(trimmed, category: category, limit: limit)
        }
        return searchOrganisationsV9(trimmed, category: category, limit: limit)
    }

    func organisationDetail(ref: OrganisationRef) -> OrganisationDetail? {
        switch ref {
        case .organisation(let id):
            return hasOrganisations ? organisationDetailV10(id: id) : nil
        case .leadSponsor(let name):
            return organisationDetailLeadV9(name: name)
        case .collaborator(let id):
            return organisationDetailCollaboratorV9(id: id)
        }
    }

    func organisationTopConditions(ref: OrganisationRef, limit: Int) -> [OrganisationConditionCount] {
        switch ref {
        case .organisation(let id):
            guard hasOrganisations, tableExists("organisation_condition") else { return [] }
            let stmt = prepare("""
                SELECT condition, trial_count FROM organisation_condition
                WHERE organisation_id = ? ORDER BY rank LIMIT ?
                """, [.int(id), .int(Int64(limit))])
            defer { sqlite3_finalize(stmt) }
            return readConditionCounts(stmt)
        case .leadSponsor(let name):
            let stmt = prepare("""
                SELECT c.name, COUNT(*) AS n
                FROM condition c
                JOIN trial t ON t.trial_id = c.trial_id
                WHERE t.lead_sponsor_name = ?
                GROUP BY c.name
                ORDER BY n DESC, c.name COLLATE NOCASE
                LIMIT ?
                """, [.text(name), .int(Int64(limit))])
            defer { sqlite3_finalize(stmt) }
            return readConditionCounts(stmt)
        case .collaborator(let id):
            guard hasCollaborators else { return [] }
            let stmt = prepare("""
                SELECT c.name, COUNT(*) AS n
                FROM condition c
                JOIN trial_collaborator tc ON tc.trial_id = c.trial_id
                WHERE tc.collaborator_id = ?
                GROUP BY c.name
                ORDER BY n DESC, c.name COLLATE NOCASE
                LIMIT ?
                """, [.int(id), .int(Int64(limit))])
            defer { sqlite3_finalize(stmt) }
            return readConditionCounts(stmt)
        }
    }

    /// Distinct canonical sites linked to this organisation’s trials (schema v10+).
    /// Prefer this over `organisation.site_count`, which is `SUM(location_count)`
    /// (participating site *instances*, not unique facilities).
    func organisationUniqueSiteCount(ref: OrganisationRef) -> Int? {
        guard hasSites else { return nil }
        switch ref {
        case .organisation(let id):
            let stmt = prepare("""
                SELECT COUNT(DISTINCT ts.site_id)
                FROM trial_organisation tor
                JOIN trial_site ts ON ts.trial_id = tor.trial_id
                WHERE tor.organisation_id = ?
                """, [.int(id)])
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return Int(int(stmt, 0))
        case .leadSponsor(let name):
            let stmt = prepare("""
                SELECT COUNT(DISTINCT ts.site_id)
                FROM trial t
                JOIN trial_site ts ON ts.trial_id = t.trial_id
                WHERE t.lead_sponsor_name = ?
                """, [.text(name)])
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return Int(int(stmt, 0))
        case .collaborator(let id):
            guard hasCollaborators else { return nil }
            let stmt = prepare("""
                SELECT COUNT(DISTINCT ts.site_id)
                FROM trial_collaborator tc
                JOIN trial_site ts ON ts.trial_id = tc.trial_id
                WHERE tc.collaborator_id = ?
                """, [.int(id)])
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return Int(int(stmt, 0))
        }
    }

    func organisationCountries(ref: OrganisationRef, limit: Int) -> [OrganisationCountryCount] {
        switch ref {
        case .organisation(let id):
            guard hasOrganisations, tableExists("organisation_country") else { return [] }
            let stmt = prepare("""
                SELECT country, trial_count FROM organisation_country
                WHERE organisation_id = ?
                ORDER BY trial_count DESC, country COLLATE NOCASE
                LIMIT ?
                """, [.int(id), .int(Int64(limit))])
            defer { sqlite3_finalize(stmt) }
            return readCountryCounts(stmt)
        case .leadSponsor(let name):
            guard usesTrialCountry else { return [] }
            let stmt = prepare("""
                SELECT tc.country, COUNT(DISTINCT t.trial_id) AS n
                FROM trial t
                JOIN trial_country tc ON tc.trial_id = t.trial_id
                WHERE t.lead_sponsor_name = ?
                GROUP BY tc.country
                ORDER BY n DESC, tc.country COLLATE NOCASE
                LIMIT ?
                """, [.text(name), .int(Int64(limit))])
            defer { sqlite3_finalize(stmt) }
            return readCountryCounts(stmt)
        case .collaborator(let id):
            guard hasCollaborators, usesTrialCountry else { return [] }
            let stmt = prepare("""
                SELECT tc.country, COUNT(DISTINCT t.trial_id) AS n
                FROM trial_collaborator jt
                JOIN trial t ON t.trial_id = jt.trial_id
                JOIN trial_country tc ON tc.trial_id = t.trial_id
                WHERE jt.collaborator_id = ?
                GROUP BY tc.country
                ORDER BY n DESC, tc.country COLLATE NOCASE
                LIMIT ?
                """, [.int(id), .int(Int64(limit))])
            defer { sqlite3_finalize(stmt) }
            return readCountryCounts(stmt)
        }
    }

    func organisationRecentStudies(ref: OrganisationRef, limit: Int) -> [TrialSummary] {
        page(filter: filter(for: ref), sort: .lastUpdatedDesc, after: nil, limit: limit)
    }

    func organisationRoute(name: String, agencyClass: String?, collaboratorId: Int64?) -> OrganisationRoute? {
        if hasOrganisations {
            if let collaboratorId,
               tableExists("organisation_collaborator_map") {
                let stmt = prepare("""
                    SELECT organisation_id FROM organisation_collaborator_map
                    WHERE collaborator_id = ? LIMIT 1
                    """, [.int(collaboratorId)])
                defer { sqlite3_finalize(stmt) }
                if sqlite3_step(stmt) == SQLITE_ROW {
                    return OrganisationRoute(organisationId: int(stmt, 0))
                }
            }
            if let agencyClass, !agencyClass.isEmpty {
                let stmt = prepare("""
                    SELECT organisation_id FROM organisation
                    WHERE display_name = ? AND organisation_class = ? LIMIT 1
                    """, [.text(name), .text(agencyClass)])
                defer { sqlite3_finalize(stmt) }
                if sqlite3_step(stmt) == SQLITE_ROW {
                    return OrganisationRoute(organisationId: int(stmt, 0))
                }
            }
            let stmt = prepare("""
                SELECT organisation_id FROM organisation
                WHERE display_name = ?
                ORDER BY total_related_trial_count DESC LIMIT 1
                """, [.text(name)])
            defer { sqlite3_finalize(stmt) }
            if sqlite3_step(stmt) == SQLITE_ROW {
                return OrganisationRoute(organisationId: int(stmt, 0))
            }
        }
        if let collaboratorId { return OrganisationRoute(collaboratorId: collaboratorId) }
        return OrganisationRoute(leadSponsor: name)
    }

    private func filter(for ref: OrganisationRef) -> TrialFilter {
        var f = TrialFilter()
        switch ref {
        case .organisation(let id):
            f.organisationId = String(id)
        case .leadSponsor(let name):
            f.leadSponsor = name
        case .collaborator(let id):
            f.collaborators = [String(id)]
        }
        return f
    }

    // MARK: v10 helpers

    private func organisationsV10(category: OrganisationCategory, limit: Int) -> [OrganisationSummary] {
        if category == .all {
            let stmt = prepare("""
                SELECT organisation_id, display_name, organisation_class,
                       total_related_trial_count, recruiting_trial_count, logo_asset_name,
                       \(activeOrganisationCountSQL)
                FROM organisation
                ORDER BY total_related_trial_count DESC, display_name COLLATE NOCASE
                LIMIT ?
                """, [.int(Int64(limit))])
            defer { sqlite3_finalize(stmt) }
            return readUnifiedOrganisationSummaries(stmt)
        }
        let classes = Self.agencyClasses(for: category)
        guard !classes.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: classes.count).joined(separator: ",")
        var args: [SQLArg] = classes.map { .text($0) }
        args.append(.int(Int64(limit)))
        let stmt = prepare("""
            SELECT organisation_id, display_name, organisation_class,
                   total_related_trial_count, recruiting_trial_count, logo_asset_name,
                   \(activeOrganisationCountSQL)
            FROM organisation
            WHERE organisation_class IN (\(placeholders))
            ORDER BY total_related_trial_count DESC, display_name COLLATE NOCASE
            LIMIT ?
            """, args)
        defer { sqlite3_finalize(stmt) }
        return readUnifiedOrganisationSummaries(stmt)
    }

    private func searchOrganisationsV10(_ query: String, category: OrganisationCategory, limit: Int) -> [OrganisationSummary] {
        // Prefer FTS when present, then LIKE. Rank exact / prefix hits above
        // popularity so typing "Pfizer" surfaces Pfizer before noisier matches.
        var rows: [OrganisationSummary] = []
        if tableExists("organisation_fts"), let match = Self.ftsQuery(query) {
            let stmt = prepare("""
                SELECT o.organisation_id, o.display_name, o.organisation_class,
                       o.total_related_trial_count, o.recruiting_trial_count, o.logo_asset_name,
                       \(activeOrganisationCountSQLAlias)
                FROM organisation_fts f
                JOIN organisation o ON o.organisation_id = f.rowid
                WHERE organisation_fts MATCH ?
                ORDER BY o.total_related_trial_count DESC
                LIMIT ?
                """, [.text(match), .int(Int64(max(limit * 3, 24)))])
            defer { sqlite3_finalize(stmt) }
            rows = readUnifiedOrganisationSummaries(stmt)
        }
        if rows.isEmpty {
            let like = "%\(query)%"
            var clauses = ["(o.display_name LIKE ? OR o.normalized_search_name LIKE ?)"]
            var args: [SQLArg] = [.text(like), .text(like.lowercased())]
            if category != .all {
                let classes = Self.agencyClasses(for: category)
                if !classes.isEmpty {
                    let placeholders = Array(repeating: "?", count: classes.count).joined(separator: ",")
                    clauses.append("o.organisation_class IN (\(placeholders))")
                    args.append(contentsOf: classes.map { .text($0) })
                }
            }
            args.append(.int(Int64(max(limit * 3, 24))))
            let stmt = prepare("""
                SELECT o.organisation_id, o.display_name, o.organisation_class,
                       o.total_related_trial_count, o.recruiting_trial_count, o.logo_asset_name,
                       \(activeOrganisationCountSQLAlias)
                FROM organisation o
                WHERE \(clauses.joined(separator: " AND "))
                ORDER BY o.total_related_trial_count DESC, o.display_name COLLATE NOCASE
                LIMIT ?
                """, args)
            defer { sqlite3_finalize(stmt) }
            rows = readUnifiedOrganisationSummaries(stmt)
        }

        if category != .all {
            let allowed = Set(Self.agencyClasses(for: category))
            rows = rows.filter { allowed.contains($0.organisationClass) }
        }

        let needle = query.lowercased()
        return rows.sorted { a, b in
            let sa = Self.organisationSearchRank(a.displayName, needle: needle)
            let sb = Self.organisationSearchRank(b.displayName, needle: needle)
            if sa != sb { return sa < sb }
            if a.activeTrialCount != b.activeTrialCount { return a.activeTrialCount > b.activeTrialCount }
            if a.totalRelatedTrialCount != b.totalRelatedTrialCount {
                return a.totalRelatedTrialCount > b.totalRelatedTrialCount
            }
            return a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
        }
        .prefix(limit)
        .map { $0 }
    }

    /// Lower is better: exact name, then prefix, then contains, then other.
    private static func organisationSearchRank(_ name: String, needle: String) -> Int {
        let lowered = name.lowercased()
        if lowered == needle { return 0 }
        if lowered.hasPrefix(needle) { return 1 }
        if lowered.contains(needle) { return 2 }
        return 3
    }

    private func organisationDetailV10(id: Int64) -> OrganisationDetail? {
        let stmt = prepare("""
            SELECT organisation_id, display_name, organisation_class,
                   total_related_trial_count, recruiting_trial_count, logo_asset_name,
                   lead_sponsor_trial_count, collaborator_trial_count,
                   completed_trial_count, terminated_trial_count,
                   phase_1_trial_count, phase_2_trial_count, phase_3_trial_count, phase_4_trial_count,
                   country_count, site_count, results_available_count,
                   first_posted_year, most_recent_update_date,
                   new_trial_count_30d, recruiting_trial_count_30d,
                   recently_updated_completed_count_30d, recently_updated_terminated_count_30d
            FROM organisation WHERE organisation_id = ? LIMIT 1
            """, [.int(id)])
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW,
              let summary = unifiedOrganisationSummary(
                from: stmt,
                activeTrialCount: activeOrganisationTrialCountV10(id: id)
              ) else { return nil }
        let pubCounts = organisationPublicationCountsV10(id: id)
        return OrganisationDetail(
            summary: summary,
            leadSponsorTrialCount: Int(int(stmt, 6)),
            collaboratorTrialCount: Int(int(stmt, 7)),
            completedTrialCount: Int(int(stmt, 8)),
            terminatedTrialCount: Int(int(stmt, 9)),
            phase1TrialCount: Int(int(stmt, 10)),
            phase2TrialCount: Int(int(stmt, 11)),
            phase3TrialCount: Int(int(stmt, 12)),
            phase4TrialCount: Int(int(stmt, 13)),
            countryCount: Int(int(stmt, 14)),
            siteCount: optionalInt(stmt, 15),
            resultsAvailableCount: Int(int(stmt, 16)),
            firstPostedYear: optionalInt(stmt, 17),
            mostRecentUpdateDate: date(stmt, 18),
            newTrialCount30d: Int(int(stmt, 19)),
            recentlyUpdatedRecruitingCount30d: Int(int(stmt, 20)),
            recentlyUpdatedCompletedCount30d: Int(int(stmt, 21)),
            recentlyUpdatedTerminatedCount30d: Int(int(stmt, 22)),
            headquarters: organisationHeadquartersV10(id: id),
            linkedPublicationCount: pubCounts.linked,
            openAccessPublicationCount: pubCounts.openAccess
        )
    }

    private func organisationPublicationCountsV10(id: Int64) -> (linked: Int, openAccess: Int) {
        guard hasOrganisationPublicationCounts else { return (0, 0) }
        let stmt = prepare("""
            SELECT linked_publication_count, open_access_publication_count
              FROM organisation WHERE organisation_id = ? LIMIT 1
            """, [.int(id)])
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return (0, 0) }
        return (Int(int(stmt, 0)), Int(int(stmt, 1)))
    }

    /// Distinct publications linked to any trial this organisation is on.
    /// Ordered by year (newest first). Empty when tables missing or unfilled.
    func organisationRecentPublications(ref: OrganisationRef, limit: Int = 8) -> [TrialPublication] {
        guard hasPublications, let organisationId = resolvedOrganisationId(for: ref) else { return [] }
        let stmt = prepare("""
            SELECT p.publication_id, p.pmid, p.doi, p.openalex_id, p.title, p.journal_name,
                   p.publication_date, p.publication_year,
                   p.is_open_access, p.open_access_status, p.landing_page_url, p.open_access_url,
                   p.enrichment_status,
                   MAX(tp.source_citation),
                   MAX(CASE WHEN tp.is_retracted = 1 THEN 1 ELSE 0 END),
                   MAX(tp.retraction_count)
              FROM trial_organisation tor
              JOIN trial_publication tp ON tp.trial_id = tor.trial_id
              JOIN publication p ON p.publication_id = tp.publication_id
             WHERE tor.organisation_id = ?
             GROUP BY p.publication_id
             ORDER BY (p.publication_year IS NULL), p.publication_year DESC,
                      p.publication_id DESC
             LIMIT ?
            """, [.int(organisationId), .int(Int64(limit))])
        defer { sqlite3_finalize(stmt) }
        var out: [TrialPublication] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(TrialPublication(
                publicationID: int(stmt, 0),
                pmid: text(stmt, 1),
                doi: text(stmt, 2),
                openAlexID: text(stmt, 3),
                title: text(stmt, 4),
                journalName: text(stmt, 5),
                publicationDate: date(stmt, 6),
                publicationYear: optionalInt(stmt, 7),
                referenceType: "",
                sourceCitation: text(stmt, 13),
                isOpenAccess: optionalBool(stmt, 8),
                openAccessStatus: text(stmt, 9),
                landingPageURL: text(stmt, 10),
                openAccessURL: text(stmt, 11),
                isRetracted: boolValue(stmt, 14),
                retractionCount: Int(int(stmt, 15)),
                enrichmentStatus: text(stmt, 12) ?? "citation_only"
            ))
        }
        return out
    }

    /// Unified `organisation.organisation_id` when schema v10+ tables exist.
    private func resolvedOrganisationId(for ref: OrganisationRef) -> Int64? {
        guard hasOrganisations else { return nil }
        switch ref {
        case .organisation(let id):
            return id
        case .collaborator(let collaboratorId):
            guard tableExists("organisation_collaborator_map") else { return nil }
            let stmt = prepare("""
                SELECT organisation_id FROM organisation_collaborator_map
                WHERE collaborator_id = ? LIMIT 1
                """, [.int(collaboratorId)])
            defer { sqlite3_finalize(stmt) }
            return sqlite3_step(stmt) == SQLITE_ROW ? int(stmt, 0) : nil
        case .leadSponsor(let name):
            let stmt = prepare("""
                SELECT organisation_id FROM organisation
                WHERE display_name = ?
                ORDER BY total_related_trial_count DESC LIMIT 1
                """, [.text(name)])
            defer { sqlite3_finalize(stmt) }
            return sqlite3_step(stmt) == SQLITE_ROW ? int(stmt, 0) : nil
        }
    }

    private func organisationHeadquartersV10(id: Int64) -> OrganisationHeadquarters? {
        guard hasOrganisationHQ else { return nil }
        let stmt = prepare("""
            SELECT hq_country, hq_address_line, hq_city, hq_region,
                   hq_postal_code, website, hq_source
            FROM organisation WHERE organisation_id = ? LIMIT 1
            """, [.int(id)])
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        func nonempty(_ i: Int32) -> String? {
            guard let s = text(stmt, i)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !s.isEmpty else { return nil }
            return s
        }
        let hq = OrganisationHeadquarters(
            country: nonempty(0),
            addressLine: nonempty(1),
            city: nonempty(2),
            region: nonempty(3),
            postalCode: nonempty(4),
            website: nonempty(5),
            source: nonempty(6)
        )
        return hq.isEmpty ? nil : hq
    }

    // MARK: v9 live queries

    private func popularOrganisationsV9(limit: Int) -> [OrganisationSummary] {
        // Same score shape as schema v10 popular ranking, computed live.
        let leads = leadSponsorSummariesV9(category: .all, query: nil, limit: limit * 2)
        let collabs = hasCollaborators
            ? collaboratorSummariesV9(category: .all, query: nil, limit: limit * 2)
            : []
        let merged = (leads + collabs).sorted {
            let s0 = Double($0.recruitingTrialCount) * 3 + Double($0.activeTrialCount)
            let s1 = Double($1.recruitingTrialCount) * 3 + Double($1.activeTrialCount)
            if s0 != s1 { return s0 > s1 }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        return Array(merged.prefix(limit))
    }

    private func organisationsV9(category: OrganisationCategory, limit: Int) -> [OrganisationSummary] {
        let half = max(1, limit / 2)
        let leads = leadSponsorSummariesV9(category: category, query: nil, limit: half)
        let collabs = hasCollaborators
            ? collaboratorSummariesV9(category: category, query: nil, limit: limit - leads.count)
            : []
        return (leads + collabs).sorted {
            if $0.activeTrialCount != $1.activeTrialCount {
                return $0.activeTrialCount > $1.activeTrialCount
            }
            if $0.totalRelatedTrialCount != $1.totalRelatedTrialCount {
                return $0.totalRelatedTrialCount > $1.totalRelatedTrialCount
            }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    private func searchOrganisationsV9(_ query: String, category: OrganisationCategory, limit: Int) -> [OrganisationSummary] {
        let half = max(1, limit / 2)
        let leads = leadSponsorSummariesV9(category: category, query: query, limit: half)
        let collabs = hasCollaborators
            ? collaboratorSummariesV9(category: category, query: query, limit: limit - leads.count)
            : []
        let needle = query.lowercased()
        return (leads + collabs).sorted { a, b in
            let sa = Self.organisationSearchRank(a.displayName, needle: needle)
            let sb = Self.organisationSearchRank(b.displayName, needle: needle)
            if sa != sb { return sa < sb }
            if a.activeTrialCount != b.activeTrialCount {
                return a.activeTrialCount > b.activeTrialCount
            }
            if a.totalRelatedTrialCount != b.totalRelatedTrialCount {
                return a.totalRelatedTrialCount > b.totalRelatedTrialCount
            }
            return a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
        }
    }

    private func leadSponsorSummariesV9(
        category: OrganisationCategory, query: String?, limit: Int
    ) -> [OrganisationSummary] {
        var clauses = ["lead_sponsor_name IS NOT NULL", "lead_sponsor_name != ''"]
        var args: [SQLArg] = []
        if let query, !query.isEmpty {
            clauses.append("lead_sponsor_name LIKE ?")
            args.append(.text("%\(query)%"))
        }
        if category != .all {
            let classes = Self.agencyClasses(for: category)
            if classes.isEmpty { return [] }
            let placeholders = Array(repeating: "?", count: classes.count).joined(separator: ",")
            clauses.append("COALESCE(lead_sponsor_class, '') IN (\(placeholders))")
            args.append(contentsOf: classes.map { .text($0) })
        }
        args.append(.int(Int64(limit)))
        let stmt = prepare("""
            SELECT lead_sponsor_name,
                   COALESCE(lead_sponsor_class, ''),
                   COUNT(*) AS total,
                   SUM(CASE WHEN is_active = 1 THEN 1 ELSE 0 END) AS active,
                   SUM(CASE WHEN overall_status = 'RECRUITING' THEN 1 ELSE 0 END) AS recruiting
            FROM trial
            WHERE \(clauses.joined(separator: " AND "))
            GROUP BY lead_sponsor_name, COALESCE(lead_sponsor_class, '')
            ORDER BY active DESC, total DESC, lead_sponsor_name COLLATE NOCASE
            LIMIT ?
            """, args)
        defer { sqlite3_finalize(stmt) }
        var out: [OrganisationSummary] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let name = text(stmt, 0) ?? ""
            let cls = text(stmt, 1) ?? ""
            out.append(OrganisationSummary(
                ref: .leadSponsor(name),
                displayName: name,
                organisationClass: cls,
                category: OrganisationCategory.category(forAgencyClass: cls),
                totalRelatedTrialCount: Int(int(stmt, 2)),
                activeTrialCount: Int(int(stmt, 3)),
                recruitingTrialCount: Int(int(stmt, 4)),
                logoAssetName: nil,
                roleHint: .leadSponsor
            ))
        }
        return out
    }

    private func collaboratorSummariesV9(
        category: OrganisationCategory, query: String?, limit: Int
    ) -> [OrganisationSummary] {
        var clauses: [String] = ["1 = 1"]
        var args: [SQLArg] = []
        if let query, !query.isEmpty {
            clauses.append("lc.name LIKE ?")
            args.append(.text("%\(query)%"))
        }
        if category != .all {
            let classes = Self.agencyClasses(for: category)
            if classes.isEmpty { return [] }
            let placeholders = Array(repeating: "?", count: classes.count).joined(separator: ",")
            clauses.append("lc.agency_class IN (\(placeholders))")
            args.append(contentsOf: classes.map { .text($0) })
        }
        args.append(.int(Int64(limit)))
        let stmt = prepare("""
            SELECT lc.collaborator_id, lc.name, lc.agency_class, lc.trial_count,
                   (
                     SELECT COUNT(*) FROM trial_collaborator tc
                     JOIN trial t ON t.trial_id = tc.trial_id
                     WHERE tc.collaborator_id = lc.collaborator_id
                       AND t.is_active = 1
                   ) AS active,
                   (
                     SELECT COUNT(*) FROM trial_collaborator tc
                     JOIN trial t ON t.trial_id = tc.trial_id
                     WHERE tc.collaborator_id = lc.collaborator_id
                       AND t.overall_status = 'RECRUITING'
                   ) AS recruiting
            FROM lookup_collaborator lc
            WHERE \(clauses.joined(separator: " AND "))
            ORDER BY active DESC, lc.trial_count DESC, lc.name COLLATE NOCASE
            LIMIT ?
            """, args)
        defer { sqlite3_finalize(stmt) }
        var out: [OrganisationSummary] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = int(stmt, 0)
            let name = text(stmt, 1) ?? ""
            let cls = text(stmt, 2) ?? ""
            out.append(OrganisationSummary(
                ref: .collaborator(id),
                displayName: name,
                organisationClass: cls,
                category: OrganisationCategory.category(forAgencyClass: cls),
                totalRelatedTrialCount: Int(int(stmt, 3)),
                activeTrialCount: Int(int(stmt, 4)),
                recruitingTrialCount: Int(int(stmt, 5)),
                logoAssetName: nil,
                roleHint: .collaborator
            ))
        }
        return out
    }

    private func organisationDetailLeadV9(name: String) -> OrganisationDetail? {
        let cutoff = Int64(Date().addingTimeInterval(-30 * 86_400).timeIntervalSince1970)
        let stmt = prepare("""
            SELECT
                COALESCE(MAX(lead_sponsor_class), ''),
                COUNT(*),
                SUM(CASE WHEN overall_status = 'RECRUITING' THEN 1 ELSE 0 END),
                SUM(CASE WHEN overall_status = 'COMPLETED' THEN 1 ELSE 0 END),
                SUM(CASE WHEN overall_status = 'TERMINATED' THEN 1 ELSE 0 END),
                SUM(CASE WHEN phase IN ('PHASE1','EARLY_PHASE1') THEN 1 ELSE 0 END),
                SUM(CASE WHEN phase IN ('PHASE2','PHASE1/PHASE2') THEN 1 ELSE 0 END),
                SUM(CASE WHEN phase IN ('PHASE3','PHASE2/PHASE3') THEN 1 ELSE 0 END),
                SUM(CASE WHEN phase = 'PHASE4' THEN 1 ELSE 0 END),
                SUM(CASE WHEN has_results = 1 THEN 1 ELSE 0 END),
                SUM(location_count),
                MIN(CASE WHEN first_posted_date > 0
                    THEN CAST(strftime('%Y', datetime(first_posted_date, 'unixepoch')) AS INTEGER) END),
                MAX(last_update_post_date),
                SUM(CASE WHEN first_posted_date >= ? THEN 1 ELSE 0 END),
                SUM(CASE WHEN overall_status = 'RECRUITING' AND last_update_post_date >= ? THEN 1 ELSE 0 END),
                SUM(CASE WHEN overall_status = 'COMPLETED' AND last_update_post_date >= ? THEN 1 ELSE 0 END),
                SUM(CASE WHEN overall_status = 'TERMINATED' AND last_update_post_date >= ? THEN 1 ELSE 0 END)
            FROM trial
            WHERE lead_sponsor_name = ?
            """, [.int(cutoff), .int(cutoff), .int(cutoff), .int(cutoff), .text(name)])
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let total = Int(int(stmt, 1))
        guard total > 0 else { return nil }
        let cls = text(stmt, 0) ?? ""
        let recruiting = Int(int(stmt, 2))
        let activeStmt = prepare("""
            SELECT COUNT(*) FROM trial
            WHERE lead_sponsor_name = ? AND is_active = 1
            """, [.text(name)])
        defer { sqlite3_finalize(activeStmt) }
        let active = sqlite3_step(activeStmt) == SQLITE_ROW ? Int(int(activeStmt, 0)) : 0
        var countryCount = 0
        if usesTrialCountry {
            let cStmt = prepare("""
                SELECT COUNT(DISTINCT tc.country)
                FROM trial t JOIN trial_country tc ON tc.trial_id = t.trial_id
                WHERE t.lead_sponsor_name = ?
                """, [.text(name)])
            defer { sqlite3_finalize(cStmt) }
            if sqlite3_step(cStmt) == SQLITE_ROW { countryCount = Int(int(cStmt, 0)) }
        }
        let summary = OrganisationSummary(
            ref: .leadSponsor(name),
            displayName: name,
            organisationClass: cls,
            category: OrganisationCategory.category(forAgencyClass: cls),
            totalRelatedTrialCount: total,
            activeTrialCount: active,
            recruitingTrialCount: recruiting,
            logoAssetName: nil,
            roleHint: .leadSponsor
        )
        return OrganisationDetail(
            summary: summary,
            leadSponsorTrialCount: total,
            collaboratorTrialCount: 0,
            completedTrialCount: Int(int(stmt, 3)),
            terminatedTrialCount: Int(int(stmt, 4)),
            phase1TrialCount: Int(int(stmt, 5)),
            phase2TrialCount: Int(int(stmt, 6)),
            phase3TrialCount: Int(int(stmt, 7)),
            phase4TrialCount: Int(int(stmt, 8)),
            countryCount: countryCount,
            siteCount: optionalInt(stmt, 9),
            resultsAvailableCount: Int(int(stmt, 10)),
            firstPostedYear: optionalInt(stmt, 11),
            mostRecentUpdateDate: date(stmt, 12),
            newTrialCount30d: Int(int(stmt, 13)),
            recentlyUpdatedRecruitingCount30d: Int(int(stmt, 14)),
            recentlyUpdatedCompletedCount30d: Int(int(stmt, 15)),
            recentlyUpdatedTerminatedCount30d: Int(int(stmt, 16))
        )
    }

    private func organisationDetailCollaboratorV9(id: Int64) -> OrganisationDetail? {
        guard hasCollaborators else { return nil }
        let cutoff = Int64(Date().addingTimeInterval(-30 * 86_400).timeIntervalSince1970)
        let meta = prepare("""
            SELECT name, agency_class, trial_count FROM lookup_collaborator
            WHERE collaborator_id = ? LIMIT 1
            """, [.int(id)])
        defer { sqlite3_finalize(meta) }
        guard sqlite3_step(meta) == SQLITE_ROW else { return nil }
        let name = text(meta, 0) ?? ""
        let cls = text(meta, 1) ?? ""
        let total = Int(int(meta, 2))
        guard total > 0 else { return nil }

        let stmt = prepare("""
            SELECT
                SUM(CASE WHEN t.overall_status = 'RECRUITING' THEN 1 ELSE 0 END),
                SUM(CASE WHEN t.overall_status = 'COMPLETED' THEN 1 ELSE 0 END),
                SUM(CASE WHEN t.overall_status = 'TERMINATED' THEN 1 ELSE 0 END),
                SUM(CASE WHEN t.phase IN ('PHASE1','EARLY_PHASE1') THEN 1 ELSE 0 END),
                SUM(CASE WHEN t.phase IN ('PHASE2','PHASE1/PHASE2') THEN 1 ELSE 0 END),
                SUM(CASE WHEN t.phase IN ('PHASE3','PHASE2/PHASE3') THEN 1 ELSE 0 END),
                SUM(CASE WHEN t.phase = 'PHASE4' THEN 1 ELSE 0 END),
                SUM(CASE WHEN t.has_results = 1 THEN 1 ELSE 0 END),
                SUM(t.location_count),
                MIN(CASE WHEN t.first_posted_date > 0
                    THEN CAST(strftime('%Y', datetime(t.first_posted_date, 'unixepoch')) AS INTEGER) END),
                MAX(t.last_update_post_date),
                SUM(CASE WHEN t.first_posted_date >= ? THEN 1 ELSE 0 END),
                SUM(CASE WHEN t.overall_status = 'RECRUITING' AND t.last_update_post_date >= ? THEN 1 ELSE 0 END),
                SUM(CASE WHEN t.overall_status = 'COMPLETED' AND t.last_update_post_date >= ? THEN 1 ELSE 0 END),
                SUM(CASE WHEN t.overall_status = 'TERMINATED' AND t.last_update_post_date >= ? THEN 1 ELSE 0 END)
            FROM trial_collaborator tc
            JOIN trial t ON t.trial_id = tc.trial_id
            WHERE tc.collaborator_id = ?
            """, [.int(cutoff), .int(cutoff), .int(cutoff), .int(cutoff), .int(id)])
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

        var countryCount = 0
        if usesTrialCountry {
            let cStmt = prepare("""
                SELECT COUNT(DISTINCT tc.country)
                FROM trial_collaborator jt
                JOIN trial_country tc ON tc.trial_id = jt.trial_id
                WHERE jt.collaborator_id = ?
                """, [.int(id)])
            defer { sqlite3_finalize(cStmt) }
            if sqlite3_step(cStmt) == SQLITE_ROW { countryCount = Int(int(cStmt, 0)) }
        }

        let recruiting = Int(int(stmt, 0))
        let activeStmt = prepare("""
            SELECT COUNT(*) FROM trial_collaborator tc
            JOIN trial t ON t.trial_id = tc.trial_id
            WHERE tc.collaborator_id = ? AND t.is_active = 1
            """, [.int(id)])
        defer { sqlite3_finalize(activeStmt) }
        let active = sqlite3_step(activeStmt) == SQLITE_ROW ? Int(int(activeStmt, 0)) : 0
        let summary = OrganisationSummary(
            ref: .collaborator(id),
            displayName: name,
            organisationClass: cls,
            category: OrganisationCategory.category(forAgencyClass: cls),
            totalRelatedTrialCount: total,
            activeTrialCount: active,
            recruitingTrialCount: recruiting,
            logoAssetName: nil,
            roleHint: .collaborator
        )
        return OrganisationDetail(
            summary: summary,
            leadSponsorTrialCount: 0,
            collaboratorTrialCount: total,
            completedTrialCount: Int(int(stmt, 1)),
            terminatedTrialCount: Int(int(stmt, 2)),
            phase1TrialCount: Int(int(stmt, 3)),
            phase2TrialCount: Int(int(stmt, 4)),
            phase3TrialCount: Int(int(stmt, 5)),
            phase4TrialCount: Int(int(stmt, 6)),
            countryCount: countryCount,
            siteCount: optionalInt(stmt, 7),
            resultsAvailableCount: Int(int(stmt, 8)),
            firstPostedYear: optionalInt(stmt, 9),
            mostRecentUpdateDate: date(stmt, 10),
            newTrialCount30d: Int(int(stmt, 11)),
            recentlyUpdatedRecruitingCount30d: Int(int(stmt, 12)),
            recentlyUpdatedCompletedCount30d: Int(int(stmt, 13)),
            recentlyUpdatedTerminatedCount30d: Int(int(stmt, 14))
        )
    }

    private func readUnifiedOrganisationSummaries(_ stmt: OpaquePointer?) -> [OrganisationSummary] {
        var out: [OrganisationSummary] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let row = unifiedOrganisationSummary(from: stmt) { out.append(row) }
        }
        return out
    }

    /// Active-count SELECT fragment for unaliased `organisation` (column 6).
    /// Prefers schema-11 `active_trial_count`; falls back to a correlated subquery.
    private var activeOrganisationCountSQL: String {
        if hasOrganisationActiveTrialCount {
            return "organisation.active_trial_count AS active_count"
        }
        return """
            (
              SELECT COUNT(DISTINCT t.trial_id)
              FROM trial_organisation tor
              JOIN trial t ON t.trial_id = tor.trial_id
              WHERE tor.organisation_id = organisation.organisation_id AND t.is_active = 1
            ) AS active_count
            """
    }

    /// Same for queries that alias the org table as `o`.
    private var activeOrganisationCountSQLAlias: String {
        if hasOrganisationActiveTrialCount {
            return "o.active_trial_count AS active_count"
        }
        return """
            (
              SELECT COUNT(DISTINCT t.trial_id)
              FROM trial_organisation tor
              JOIN trial t ON t.trial_id = tor.trial_id
              WHERE tor.organisation_id = o.organisation_id AND t.is_active = 1
            ) AS active_count
            """
    }

    private func activeOrganisationTrialCountV10(id: Int64) -> Int {
        if hasOrganisationActiveTrialCount {
            let stmt = prepare(
                "SELECT active_trial_count FROM organisation WHERE organisation_id = ?",
                [.int(id)]
            )
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return Int(int(stmt, 0))
        }
        let stmt = prepare("""
            SELECT COUNT(DISTINCT t.trial_id)
            FROM trial_organisation tor
            JOIN trial t ON t.trial_id = tor.trial_id
            WHERE tor.organisation_id = ? AND t.is_active = 1
            """, [.int(id)])
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(int(stmt, 0))
    }

    private func unifiedOrganisationSummary(
        from stmt: OpaquePointer?,
        activeTrialCount: Int? = nil
    ) -> OrganisationSummary? {
        let id = int(stmt, 0)
        guard id > 0 else { return nil }
        let className = text(stmt, 2) ?? ""
        return OrganisationSummary(
            ref: .organisation(id),
            displayName: text(stmt, 1) ?? "",
            organisationClass: className,
            category: OrganisationCategory.category(forAgencyClass: className),
            totalRelatedTrialCount: Int(int(stmt, 3)),
            activeTrialCount: activeTrialCount ?? Int(int(stmt, 6)),
            recruitingTrialCount: Int(int(stmt, 4)),
            logoAssetName: text(stmt, 5),
            roleHint: .unknown
        )
    }

    private func readConditionCounts(_ stmt: OpaquePointer?) -> [OrganisationConditionCount] {
        var out: [OrganisationConditionCount] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(OrganisationConditionCount(
                condition: text(stmt, 0) ?? "",
                trialCount: Int(int(stmt, 1))
            ))
        }
        return out
    }

    private func readCountryCounts(_ stmt: OpaquePointer?) -> [OrganisationCountryCount] {
        var out: [OrganisationCountryCount] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(OrganisationCountryCount(
                country: text(stmt, 0) ?? "",
                trialCount: Int(int(stmt, 1))
            ))
        }
        return out
    }

    private static func agencyClasses(for category: OrganisationCategory) -> [String] {
        switch category {
        case .all: return []
        case .industry: return ["INDUSTRY"]
        case .academicMedical: return ["OTHER"]
        case .government: return ["OTHER_GOV", "NIH", "FED", "NETWORK"]
        case .other: return ["INDIV", "UNKNOWN", ""]
        }
    }

    // MARK: - Sites (v10 tables when present; else recruiting detail_z index)

    private struct SiteIndexEntryV9 {
        var displayName: String
        var city: String?
        var state: String?
        var country: String?
        var latitude: Double?
        var longitude: Double?
        var recruitingCount: Int = 0
        var phase3Count: Int = 0
        var leadSponsors: [String: Int] = [:]
        var conditions: [String: Int] = [:]
        /// Newest-first recruiting trial ids seen while building the index
        /// (avoids a full `detail_z` rescan for Site → Recent Trials).
        var recentTrialIds: [Int64] = []
    }

    private struct SiteIndexV9 {
        var byKey: [String: SiteIndexEntryV9] = [:]
        var highActivityKeys: [String] = []
        var cities: [SiteCityGroup] = []
        var countries: [SiteCountryGroup] = []
    }

    func searchSites(_ query: String, limit: Int) -> [SiteSummary] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return highActivitySites(limit: limit) }
        if hasSites {
            return searchSitesV10(trimmed, limit: limit)
        }
        let index = ensureSiteIndexV9()
        let q = trimmed.lowercased()
        return index.byKey.values
            .filter { $0.displayName.lowercased().contains(q) }
            .sorted {
                if $0.recruitingCount != $1.recruitingCount { return $0.recruitingCount > $1.recruitingCount }
                return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
            .prefix(limit)
            .map { summary(fromV9: $0) }
    }

    func highActivitySites(limit: Int) -> [SiteSummary] {
        if hasSites {
            let stmt = prepare("""
                SELECT s.site_id, s.display_name, s.city, s.state, s.country,
                       s.latitude, s.longitude, s.total_related_trial_count,
                       s.recruiting_trial_count, s.phase_3_trial_count, s.organisation_count
                FROM popular_site p
                JOIN site s ON s.site_id = p.site_id
                ORDER BY p.rank
                LIMIT ?
                """, [.int(Int64(limit))])
            defer { sqlite3_finalize(stmt) }
            return readSiteSummariesV10(stmt)
        }
        let index = ensureSiteIndexV9()
        return index.highActivityKeys.prefix(limit).compactMap { key in
            index.byKey[key].map { summary(fromV9: $0) }
        }
    }

    func nearbySites(
        latitude: Double, longitude: Double, radiusMeters: Double, limit: Int
    ) -> [SiteSummary] {
        if hasSites {
            return nearbySitesV10(
                latitude: latitude, longitude: longitude,
                radiusMeters: radiusMeters, limit: limit
            )
        }
        // Derive unique facilities from nearby recruiting trials (already geo-pruned).
        var f = TrialFilter()
        f.status = "RECRUITING"
        let hits = nearbyRecruiting(
            latitude: latitude, longitude: longitude,
            radiusMeters: radiusMeters, filter: f, limit: max(limit * 8, 200)
        )
        struct Acc {
            var facility: String
            var city: String?
            var state: String?
            var country: String?
            var latitude: Double?
            var longitude: Double?
            var total: Int = 0
            var phase3: Int = 0
            var distance: Double
        }
        var best: [String: Acc] = [:]
        for hit in hits {
            let facility = hit.site.facilityName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !facility.isEmpty else { continue }
            let key = SiteSoftKey.make(
                facility: facility, city: hit.site.city, country: hit.site.country
            )
            let isPhase3 = (hit.trial.phaseDisplay ?? "").localizedCaseInsensitiveContains("Phase 3")
            if var acc = best[key] {
                acc.total += 1
                if isPhase3 { acc.phase3 += 1 }
                acc.distance = min(acc.distance, hit.distanceMeters)
                best[key] = acc
            } else {
                best[key] = Acc(
                    facility: facility,
                    city: hit.site.city,
                    state: hit.site.state,
                    country: hit.site.country,
                    latitude: hit.site.latitude,
                    longitude: hit.site.longitude,
                    total: 1,
                    phase3: isPhase3 ? 1 : 0,
                    distance: hit.distanceMeters
                )
            }
        }
        return best.values
            .map {
                SiteSummary(
                    ref: .raw(facility: $0.facility, city: $0.city, country: $0.country),
                    displayName: $0.facility,
                    city: $0.city,
                    state: $0.state,
                    country: $0.country,
                    latitude: $0.latitude,
                    longitude: $0.longitude,
                    totalRelatedTrialCount: $0.total,
                    recruitingTrialCount: $0.total,
                    phase3TrialCount: $0.phase3,
                    organisationCount: 0,
                    distanceMeters: $0.distance,
                    includesNonRecruitingStudies: false
                )
            }
            .sorted { ($0.distanceMeters ?? .greatestFiniteMagnitude) < ($1.distanceMeters ?? .greatestFiniteMagnitude) }
            .prefix(limit)
            .map { $0 }
    }

    func siteCities(limit: Int) -> [SiteCityGroup] {
        if hasSites {
            let stmt = prepare("""
                SELECT city, country, COUNT(*) AS sites, SUM(total_related_trial_count) AS trials
                FROM site
                WHERE city != ''
                GROUP BY city, country
                ORDER BY trials DESC, city COLLATE NOCASE
                LIMIT ?
                """, [.int(Int64(limit))])
            defer { sqlite3_finalize(stmt) }
            var out: [SiteCityGroup] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(SiteCityGroup(
                    city: text(stmt, 0) ?? "",
                    country: text(stmt, 1),
                    siteCount: Int(int(stmt, 2)),
                    trialCount: Int(int(stmt, 3))
                ))
            }
            return out
        }
        return Array(ensureSiteIndexV9().cities.prefix(limit))
    }

    func siteCountries(limit: Int) -> [SiteCountryGroup] {
        if hasSites {
            let stmt = prepare("""
                SELECT country, COUNT(*) AS sites, SUM(total_related_trial_count) AS trials
                FROM site
                WHERE country != ''
                GROUP BY country
                ORDER BY trials DESC, country COLLATE NOCASE
                LIMIT ?
                """, [.int(Int64(limit))])
            defer { sqlite3_finalize(stmt) }
            var out: [SiteCountryGroup] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(SiteCountryGroup(
                    country: text(stmt, 0) ?? "",
                    siteCount: Int(int(stmt, 1)),
                    trialCount: Int(int(stmt, 2))
                ))
            }
            return out
        }
        return Array(ensureSiteIndexV9().countries.prefix(limit))
    }

    func sites(inCity city: String, country: String?, limit: Int) -> [SiteSummary] {
        if hasSites {
            var args: [SQLArg] = [.text(city)]
            var sql = """
                SELECT site_id, display_name, city, state, country,
                       latitude, longitude, total_related_trial_count,
                       recruiting_trial_count, phase_3_trial_count, organisation_count
                FROM site
                WHERE city = ?
                """
            if let country, !country.isEmpty {
                sql += " AND country = ?"
                args.append(.text(country))
            }
            sql += " ORDER BY total_related_trial_count DESC, display_name COLLATE NOCASE LIMIT ?"
            args.append(.int(Int64(limit)))
            let stmt = prepare(sql, args)
            defer { sqlite3_finalize(stmt) }
            return readSiteSummariesV10(stmt)
        }
        let index = ensureSiteIndexV9()
        let cityKey = city.lowercased()
        let countryKey = country?.lowercased()
        return index.byKey.values
            .filter {
                ($0.city ?? "").lowercased() == cityKey &&
                (countryKey == nil || ($0.country ?? "").lowercased() == countryKey)
            }
            .sorted { $0.recruitingCount > $1.recruitingCount }
            .prefix(limit)
            .map { summary(fromV9: $0) }
    }

    func sites(inCountry country: String, limit: Int) -> [SiteSummary] {
        if hasSites {
            let stmt = prepare("""
                SELECT site_id, display_name, city, state, country,
                       latitude, longitude, total_related_trial_count,
                       recruiting_trial_count, phase_3_trial_count, organisation_count
                FROM site
                WHERE country = ?
                ORDER BY total_related_trial_count DESC, display_name COLLATE NOCASE
                LIMIT ?
                """, [.text(country), .int(Int64(limit))])
            defer { sqlite3_finalize(stmt) }
            return readSiteSummariesV10(stmt)
        }
        let index = ensureSiteIndexV9()
        let countryKey = country.lowercased()
        return index.byKey.values
            .filter { ($0.country ?? "").lowercased() == countryKey }
            .sorted { $0.recruitingCount > $1.recruitingCount }
            .prefix(limit)
            .map { summary(fromV9: $0) }
    }

    func siteDetail(ref: SiteRef) -> SiteDetail? {
        let resolved = resolveSiteRef(ref)
        switch resolved {
        case .site(let id):
            guard hasSites else { return nil }
            let stmt = prepare("""
                SELECT site_id, display_name, city, state, country,
                       latitude, longitude, total_related_trial_count,
                       recruiting_trial_count, phase_3_trial_count, organisation_count
                FROM site WHERE site_id = ? LIMIT 1
                """, [.int(id)])
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW,
                  let summary = siteSummaryV10(from: stmt)
            else { return nil }
            // Cheap path only: precomputed columns. Live joins run via `sitePublicationCounts(ref:)`.
            var detail = SiteDetail(summary: summary)
            if hasSitePublicationCounts {
                let counts = sitePublicationCountsPrecomputed(siteId: id)
                detail.linkedPublicationCount = counts.linked
                detail.openAccessPublicationCount = counts.openAccess
            }
            return detail
        case .raw(let facility, let city, let country):
            let key = SiteSoftKey.make(facility: facility, city: city, country: country)
            if let entry = ensureSiteIndexV9().byKey[key] {
                return SiteDetail(summary: summary(fromV9: entry))
            }
            // Fallback when index miss (e.g. opened from a nearby hit before index).
            return SiteDetail(summary: SiteSummary(
                ref: resolved,
                displayName: facility,
                city: city,
                state: nil,
                country: country,
                latitude: nil,
                longitude: nil,
                totalRelatedTrialCount: 0,
                recruitingTrialCount: 0,
                phase3TrialCount: 0,
                organisationCount: 0,
                distanceMeters: nil,
                includesNonRecruitingStudies: false
            ))
        }
    }

    /// Distinct publications linked to any trial that ran at this site.
    /// Prefers precomputed `site.*_publication_count` columns when present; otherwise live join.
    func sitePublicationCounts(ref: SiteRef) -> (linked: Int, openAccess: Int) {
        guard case .site(let siteId) = resolveSiteRef(ref) else { return (0, 0) }
        if hasSitePublicationCounts {
            return sitePublicationCountsPrecomputed(siteId: siteId)
        }
        guard hasPublications else { return (0, 0) }
        let stmt = prepare("""
            SELECT COUNT(DISTINCT p.publication_id),
                   COUNT(DISTINCT CASE WHEN p.is_open_access = 1 THEN p.publication_id END)
              FROM trial_site ts
              JOIN trial_publication tp ON tp.trial_id = ts.trial_id
              JOIN publication p ON p.publication_id = tp.publication_id
             WHERE ts.site_id = ?
            """, [.int(siteId)])
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return (0, 0) }
        return (Int(int(stmt, 0)), Int(int(stmt, 1)))
    }

    private func sitePublicationCountsPrecomputed(siteId: Int64) -> (linked: Int, openAccess: Int) {
        let stmt = prepare("""
            SELECT linked_publication_count, open_access_publication_count
              FROM site WHERE site_id = ? LIMIT 1
            """, [.int(siteId)])
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return (0, 0) }
        return (Int(int(stmt, 0)), Int(int(stmt, 1)))
    }

    /// Distinct publications linked to any trial at this site. Ordered by year (newest first).
    /// Empty when publication tables missing, site is v9-raw, or no linked refs.
    func siteRecentPublications(ref: SiteRef, limit: Int = 8) -> [TrialPublication] {
        guard hasPublications else { return [] }
        guard case .site(let siteId) = resolveSiteRef(ref) else { return [] }
        let stmt = prepare("""
            SELECT p.publication_id, p.pmid, p.doi, p.openalex_id, p.title, p.journal_name,
                   p.publication_date, p.publication_year,
                   p.is_open_access, p.open_access_status, p.landing_page_url, p.open_access_url,
                   p.enrichment_status,
                   MAX(tp.source_citation),
                   MAX(CASE WHEN tp.is_retracted = 1 THEN 1 ELSE 0 END),
                   MAX(tp.retraction_count)
              FROM trial_site ts
              JOIN trial_publication tp ON tp.trial_id = ts.trial_id
              JOIN publication p ON p.publication_id = tp.publication_id
             WHERE ts.site_id = ?
             GROUP BY p.publication_id
             ORDER BY (p.publication_year IS NULL), p.publication_year DESC,
                      p.publication_id DESC
             LIMIT ?
            """, [.int(siteId), .int(Int64(limit))])
        defer { sqlite3_finalize(stmt) }
        var out: [TrialPublication] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(TrialPublication(
                publicationID: int(stmt, 0),
                pmid: text(stmt, 1),
                doi: text(stmt, 2),
                openAlexID: text(stmt, 3),
                title: text(stmt, 4),
                journalName: text(stmt, 5),
                publicationDate: date(stmt, 6),
                publicationYear: optionalInt(stmt, 7),
                referenceType: "",
                sourceCitation: text(stmt, 13),
                isOpenAccess: optionalBool(stmt, 8),
                openAccessStatus: text(stmt, 9),
                landingPageURL: text(stmt, 10),
                openAccessURL: text(stmt, 11),
                isRetracted: boolValue(stmt, 14),
                retractionCount: Int(int(stmt, 15)),
                enrichmentStatus: text(stmt, 12) ?? "citation_only"
            ))
        }
        return out
    }

    func siteTopConditions(ref: SiteRef, limit: Int) -> [SiteConditionCount] {
        switch resolveSiteRef(ref) {
        case .site(let id):
            guard hasSites else { return [] }
            let stmt = prepare("""
                SELECT condition, trial_count FROM site_condition
                WHERE site_id = ? ORDER BY rank LIMIT ?
                """, [.int(id), .int(Int64(limit))])
            defer { sqlite3_finalize(stmt) }
            var out: [SiteConditionCount] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(SiteConditionCount(
                    condition: text(stmt, 0) ?? "",
                    trialCount: Int(int(stmt, 1))
                ))
            }
            return out
        case .raw(let facility, let city, let country):
            let key = SiteSoftKey.make(facility: facility, city: city, country: country)
            guard let entry = ensureSiteIndexV9().byKey[key] else { return [] }
            return entry.conditions
                .sorted { $0.value > $1.value }
                .prefix(limit)
                .map { SiteConditionCount(condition: $0.key, trialCount: $0.value) }
        }
    }

    func siteLeadOrganisations(ref: SiteRef, limit: Int) -> [SiteLeadOrganisation] {
        switch resolveSiteRef(ref) {
        case .site(let id):
            guard hasSites else { return [] }
            let stmt = prepare("""
                SELECT display_name, organisation_class, trial_count, organisation_id
                FROM site_lead_organisation
                WHERE site_id = ? ORDER BY rank LIMIT ?
                """, [.int(id), .int(Int64(limit))])
            defer { sqlite3_finalize(stmt) }
            var out: [SiteLeadOrganisation] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let orgId = optionalInt64(stmt, 3)
                let name = text(stmt, 0) ?? ""
                out.append(SiteLeadOrganisation(
                    displayName: name,
                    organisationClass: text(stmt, 1) ?? "",
                    trialCount: Int(int(stmt, 2)),
                    organisationId: orgId,
                    leadSponsorName: orgId == nil ? name : nil
                ))
            }
            return out
        case .raw(let facility, let city, let country):
            let key = SiteSoftKey.make(facility: facility, city: city, country: country)
            guard let entry = ensureSiteIndexV9().byKey[key] else { return [] }
            return entry.leadSponsors
                .sorted { $0.value > $1.value }
                .prefix(limit)
                .map {
                    SiteLeadOrganisation(
                        displayName: $0.key,
                        organisationClass: "",
                        trialCount: $0.value,
                        organisationId: nil,
                        leadSponsorName: $0.key
                    )
                }
        }
    }

    func siteRecentStudies(ref: SiteRef, limit: Int) -> [TrialSummary] {
        let resolved = resolveSiteRef(ref)
        switch resolved {
        case .site:
            return page(filter: filter(for: resolved), sort: .lastUpdatedDesc, after: nil, limit: limit)
        case .raw(let facility, let city, let country):
            // Prefer ids captured while indexing — `pageForSiteKeyV9` rescans the
            // whole corpus and often leaves the Site profile with an empty list.
            let key = SiteSoftKey.make(facility: facility, city: city, country: country)
            if let ids = ensureSiteIndexV9().byKey[key]?.recentTrialIds, !ids.isEmpty {
                return summaries(trialIds: Array(ids.prefix(limit)))
            }
            return page(filter: filter(for: resolved), sort: .lastUpdatedDesc, after: nil, limit: limit)
        }
    }

    /// Prefer canonical `site:` ids when tables exist — recently viewed / favourites
    /// may still hold pre-v11 `raw:` keys.
    private func resolveSiteRef(_ ref: SiteRef) -> SiteRef {
        switch ref {
        case .site:
            return ref
        case .raw(let facility, let city, let country):
            guard hasSites, let id = lookupSiteId(facility: facility, city: city, country: country) else {
                return ref
            }
            print("ℹ️ [TrialStore] resolved raw site → site:\(id) (\(facility))")
            return .site(id)
        }
    }

    private func lookupSiteId(facility: String, city: String?, country: String?) -> Int64? {
        let cityVal = city ?? ""
        let countryVal = country ?? ""
        // v12 `site_alias.normalized_alias` = soft-key facility part (SiteSoftKey.normalize).
        // Also try plain lower() for older v11 alias rows.
        let softAlias = SiteSoftKey.normalize(facility)
        let lowerAlias = facility.lowercased()
        if tableExists("site_alias") {
            for alias in [softAlias, lowerAlias] where !alias.isEmpty {
                let stmt = prepare("""
                    SELECT site_id FROM site_alias
                    WHERE normalized_alias = ? AND city = ? AND country = ?
                    LIMIT 1
                    """, [.text(alias), .text(cityVal), .text(countryVal)])
                defer { sqlite3_finalize(stmt) }
                if sqlite3_step(stmt) == SQLITE_ROW {
                    let id = int(stmt, 0)
                    if id > 0 { return id }
                }
            }
        }
        let stmt = prepare("""
            SELECT site_id FROM site
            WHERE lower(display_name) = ? AND city = ? AND country = ?
            ORDER BY recruiting_trial_count DESC, total_related_trial_count DESC
            LIMIT 1
            """, [.text(lowerAlias), .text(cityVal), .text(countryVal)])
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let id = int(stmt, 0)
        return id > 0 ? id : nil
    }

    private func filter(for ref: SiteRef) -> TrialFilter {
        var f = TrialFilter()
        switch resolveSiteRef(ref) {
        case .site(let id):
            f.siteId = String(id)
        case .raw(let facility, let city, let country):
            f.siteKey = SiteSoftKey.make(facility: facility, city: city, country: country)
        }
        return f
    }

    /// Preserve caller order (unlike an unordered IN-query result).
    private func summaries(trialIds: [Int64]) -> [TrialSummary] {
        guard !trialIds.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: trialIds.count).joined(separator: ",")
        let stmt = prepare(
            "SELECT \(summaryColumns()) FROM trial WHERE trial_id IN (\(placeholders))",
            trialIds.map { .int($0) }
        )
        defer { sqlite3_finalize(stmt) }
        var map: [Int64: TrialSummary] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let s = summary(from: stmt)
            map[s.trialId] = s
        }
        return trialIds.compactMap { map[$0] }
    }

    // MARK: Sites v10 helpers

    private func searchSitesV10(_ query: String, limit: Int) -> [SiteSummary] {
        if tableExists("site_fts") {
            let stmt = prepare("""
                SELECT s.site_id, s.display_name, s.city, s.state, s.country,
                       s.latitude, s.longitude, s.total_related_trial_count,
                       s.recruiting_trial_count, s.phase_3_trial_count, s.organisation_count
                FROM site_fts f
                JOIN site s ON s.site_id = f.rowid
                WHERE site_fts MATCH ?
                ORDER BY s.total_related_trial_count DESC
                LIMIT ?
                """, [.text(Self.ftsQuery(query) ?? query), .int(Int64(limit))])
            defer { sqlite3_finalize(stmt) }
            let rows = readSiteSummariesV10(stmt)
            if !rows.isEmpty { return rows }
        }
        let stmt = prepare("""
            SELECT site_id, display_name, city, state, country,
                   latitude, longitude, total_related_trial_count,
                   recruiting_trial_count, phase_3_trial_count, organisation_count
            FROM site
            WHERE display_name LIKE ? OR normalized_search_name LIKE ?
            ORDER BY total_related_trial_count DESC, display_name COLLATE NOCASE
            LIMIT ?
            """, [.text("%\(query)%"), .text("%\(query.lowercased())%"), .int(Int64(limit))])
        defer { sqlite3_finalize(stmt) }
        return readSiteSummariesV10(stmt)
    }

    private func nearbySitesV10(
        latitude: Double, longitude: Double, radiusMeters: Double, limit: Int
    ) -> [SiteSummary] {
        let latDelta = radiusMeters / 111_320.0
        let cosLat = max(0.01, cos(latitude * .pi / 180))
        let lonDelta = radiusMeters / (111_320.0 * cosLat)
        let stmt = prepare("""
            SELECT site_id, display_name, city, state, country,
                   latitude, longitude, total_related_trial_count,
                   recruiting_trial_count, phase_3_trial_count, organisation_count
            FROM site
            WHERE latitude BETWEEN ? AND ?
              AND longitude BETWEEN ? AND ?
              AND recruiting_trial_count > 0
            """, [
                .double(latitude - latDelta), .double(latitude + latDelta),
                .double(longitude - lonDelta), .double(longitude + lonDelta)
            ])
        defer { sqlite3_finalize(stmt) }
        var out: [SiteSummary] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard var summary = siteSummaryV10(from: stmt),
                  let lat = summary.latitude, let lon = summary.longitude
            else { continue }
            let meters = NearbyDistance.meters(from: latitude, lon1: longitude, to: lat, lon2: lon)
            guard meters <= radiusMeters else { continue }
            summary.distanceMeters = meters
            out.append(summary)
        }
        out.sort { ($0.distanceMeters ?? .greatestFiniteMagnitude) < ($1.distanceMeters ?? .greatestFiniteMagnitude) }
        if out.count > limit { out = Array(out.prefix(limit)) }
        return out
    }

    private func readSiteSummariesV10(_ stmt: OpaquePointer?) -> [SiteSummary] {
        var out: [SiteSummary] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let row = siteSummaryV10(from: stmt) { out.append(row) }
        }
        return out
    }

    private func siteSummaryV10(from stmt: OpaquePointer?) -> SiteSummary? {
        let id = int(stmt, 0)
        guard id > 0 else { return nil }
        return SiteSummary(
            ref: .site(id),
            displayName: text(stmt, 1) ?? "",
            city: text(stmt, 2),
            state: text(stmt, 3),
            country: text(stmt, 4),
            latitude: optionalDouble(stmt, 5),
            longitude: optionalDouble(stmt, 6),
            totalRelatedTrialCount: Int(int(stmt, 7)),
            recruitingTrialCount: Int(int(stmt, 8)),
            phase3TrialCount: Int(int(stmt, 9)),
            organisationCount: Int(int(stmt, 10)),
            distanceMeters: nil,
            includesNonRecruitingStudies: true
        )
    }

    private func summary(fromV9 entry: SiteIndexEntryV9) -> SiteSummary {
        SiteSummary(
            ref: .raw(facility: entry.displayName, city: entry.city, country: entry.country),
            displayName: entry.displayName,
            city: entry.city,
            state: entry.state,
            country: entry.country,
            latitude: entry.latitude,
            longitude: entry.longitude,
            // Index is built from RECRUITING trials only — both fields are the
            // same on purpose until canonical site tables ship.
            totalRelatedTrialCount: entry.recruitingCount,
            recruitingTrialCount: entry.recruitingCount,
            phase3TrialCount: entry.phase3Count,
            organisationCount: entry.leadSponsors.count,
            distanceMeters: nil,
            includesNonRecruitingStudies: false
        )
    }

    /// Builds the on-device recruiting site index once (no-op when site tables exist).
    func warmSiteIndexIfNeeded() {
        guard !hasSites else { return }
        _ = ensureSiteIndexV9()
    }

    private func ensureSiteIndexV9() -> SiteIndexV9 {
        if hasSites {
            // Never decompress the whole recruiting corpus when site tables exist.
            // Callers with stale `raw:` refs should go through `resolveSiteRef`.
            if let siteIndexV9 { return siteIndexV9 }
            print("⚠️ [TrialStore] v9 site index skipped — canonical site tables are present.")
            let empty = SiteIndexV9()
            siteIndexV9 = empty
            return empty
        }
        if let siteIndexV9 { return siteIndexV9 }
        print("ℹ️ [TrialStore] building v9 site index from recruiting detail_z…")
        let built = buildSiteIndexV9()
        siteIndexV9 = built
        print("ℹ️ [TrialStore] v9 site index ready: \(built.byKey.count) sites.")
        return built
    }

    private func buildSiteIndexV9() -> SiteIndexV9 {
        var index = SiteIndexV9()
        guard usesDetailBlob else { return index }

        // Newest first so each site’s `recentTrialIds` fills with recent studies.
        let sql = """
            SELECT trial.trial_id, trial.phase, trial.primary_condition, trial.lead_sponsor_name,
                   trial.detail_z
            FROM trial
            WHERE trial.overall_status = 'RECRUITING'
              AND trial.detail_z IS NOT NULL
            ORDER BY trial.last_update_post_date DESC, trial.trial_id DESC
            """
        let stmt = prepare(sql)
        defer { sqlite3_finalize(stmt) }
        let dict = dictionaries["detail_z"]
        // Enough for one TrialListView page; Site profile still requests ≤5.
        let recentCap = 40

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let blob = blob(stmt, 4),
                  let data = Self.decompressData(blob, dictionary: dict),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            let trialId = int(stmt, 0)
            let phase = text(stmt, 1) ?? ""
            let condition = text(stmt, 2)
            let lead = text(stmt, 3)
            let isPhase3 = phase == "PHASE3" || phase == "PHASE2_PHASE3" || phase == "PHASE2/PHASE3"
            let rows = root["l"] as? [[Any]] ?? []
            var seenKeys = Set<String>()

            for row in rows {
                let facility = (Self.jsonString(row, 0) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !facility.isEmpty else { continue }
                let city = Self.jsonString(row, 1)
                let state = Self.jsonString(row, 2)
                let country = Self.jsonString(row, 3)
                let key = SiteSoftKey.make(facility: facility, city: city, country: country)
                guard seenKeys.insert(key).inserted else { continue }

                var entry = index.byKey[key] ?? SiteIndexEntryV9(
                    displayName: facility, city: city, state: state, country: country
                )
                entry.recruitingCount += 1
                if isPhase3 { entry.phase3Count += 1 }
                if entry.recentTrialIds.count < recentCap,
                   !entry.recentTrialIds.contains(trialId) {
                    entry.recentTrialIds.append(trialId)
                }
                if entry.latitude == nil, let lat = Self.jsonNumber(row, 6), let lon = Self.jsonNumber(row, 7),
                   Self.isValidCoordinate(lat: lat, lon: lon) {
                    entry.latitude = lat
                    entry.longitude = lon
                }
                if let lead, !lead.isEmpty {
                    entry.leadSponsors[lead, default: 0] += 1
                }
                if let condition, !condition.isEmpty {
                    entry.conditions[condition, default: 0] += 1
                }
                // Cap maps so memory stays bounded on large campuses.
                if entry.leadSponsors.count > 40 {
                    entry.leadSponsors = Dictionary(uniqueKeysWithValues:
                        entry.leadSponsors.sorted { $0.value > $1.value }.prefix(30).map { ($0.key, $0.value) })
                }
                if entry.conditions.count > 40 {
                    entry.conditions = Dictionary(uniqueKeysWithValues:
                        entry.conditions.sorted { $0.value > $1.value }.prefix(30).map { ($0.key, $0.value) })
                }
                index.byKey[key] = entry
            }
        }

        index.highActivityKeys = index.byKey.keys.sorted { a, b in
            let ea = index.byKey[a]!, eb = index.byKey[b]!
            let sa = Double(ea.recruitingCount) * 3 + Double(ea.phase3Count)
            let sb = Double(eb.recruitingCount) * 3 + Double(eb.phase3Count)
            if sa != sb { return sa > sb }
            return ea.displayName.localizedCaseInsensitiveCompare(eb.displayName) == .orderedAscending
        }

        var cityMap: [String: (SiteCityGroup, Int)] = [:]
        var countryMap: [String: (SiteCountryGroup, Int)] = [:]
        for entry in index.byKey.values {
            if let city = entry.city, !city.isEmpty {
                let id = "\(city)|\(entry.country ?? "")"
                var g = cityMap[id]?.0 ?? SiteCityGroup(
                    city: city, country: entry.country, siteCount: 0, trialCount: 0
                )
                g = SiteCityGroup(
                    city: g.city, country: g.country,
                    siteCount: g.siteCount + 1,
                    trialCount: g.trialCount + entry.recruitingCount
                )
                cityMap[id] = (g, g.trialCount)
            }
            if let country = entry.country, !country.isEmpty {
                var g = countryMap[country]?.0 ?? SiteCountryGroup(
                    country: country, siteCount: 0, trialCount: 0
                )
                g = SiteCountryGroup(
                    country: g.country,
                    siteCount: g.siteCount + 1,
                    trialCount: g.trialCount + entry.recruitingCount
                )
                countryMap[country] = (g, g.trialCount)
            }
        }
        index.cities = cityMap.values.map(\.0).sorted { $0.trialCount > $1.trialCount }
        index.countries = countryMap.values.map(\.0).sorted { $0.trialCount > $1.trialCount }
        return index
    }

    private func pageForSiteKeyV9(
        siteKey: String, filter: TrialFilter, after cursor: TrialCursor?, limit: Int
    ) -> [TrialSummary] {
        guard usesDetailBlob else { return [] }
        var probe = filter
        probe.siteKey = nil
        probe.siteId = nil

        // First page only: use newest recruiting ids from the v9 index when the
        // filter is recruiting-compatible. TrialListView must use `count` for
        // `reachedEnd` — a short page here does not mean the list is complete.
        if cursor == nil,
           let ids = siteKeyIndexTrialIds(siteKey, filter: probe, limit: limit),
           !ids.isEmpty {
            return summaries(trialIds: ids)
        }

        let (whereSQL, args) = whereClause(probe)
        let sql = """
            SELECT \(summaryColumns("trial.")), trial.detail_z
            FROM trial
            \(whereSQL)
            AND trial.detail_z IS NOT NULL
            ORDER BY trial.last_update_post_date DESC, trial.trial_id DESC
            """
        let stmt = prepare(sql, args)
        defer { sqlite3_finalize(stmt) }
        let dict = dictionaries["detail_z"]
        let detailCol: Int32 = usesDatePrecision ? 15 : 14
        var out: [TrialSummary] = []
        var skipping = cursor != nil

        while sqlite3_step(stmt) == SQLITE_ROW {
            let summary = summary(from: stmt)
            if skipping {
                if let cursor, summary.trialId == cursor.trialId {
                    skipping = false
                }
                continue
            }
            guard let blob = blob(stmt, detailCol),
                  let data = Self.decompressData(blob, dictionary: dict),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            let rows = root["l"] as? [[Any]] ?? []
            let matches = rows.contains { row in
                let facility = Self.jsonString(row, 0) ?? ""
                let city = Self.jsonString(row, 1)
                let country = Self.jsonString(row, 3)
                return SiteSoftKey.make(facility: facility, city: city, country: country) == siteKey
            }
            guard matches else { continue }
            out.append(summary)
            if out.count >= limit { break }
        }
        return out
    }

    /// Header counts for Site soft-key filters. Prefer the v9 index aggregates
    /// so Studies / Recruiting / Phase III match the Site summary cards.
    private func countForSiteKeyV9(siteKey: String, filter: TrialFilter) -> Int {
        var probe = filter
        probe.siteKey = nil
        probe.siteId = nil

        if let entry = ensureSiteIndexV9().byKey[siteKey] {
            if probe.isEmpty { return entry.recruitingCount }
            if probe.status == "RECRUITING" {
                var rest = probe
                rest.status = nil
                if rest.isEmpty { return entry.recruitingCount }
            }
            let phase3: Set<String> = ["PHASE3", "PHASE2_PHASE3", "PHASE2/PHASE3"]
            if !probe.phases.isEmpty, probe.phases.isSubset(of: phase3) {
                var rest = probe
                rest.phases = []
                rest.phase = nil
                if rest.isEmpty { return entry.phase3Count }
            }
        }

        return scanCountForSiteKeyV9(siteKey: siteKey, filter: probe)
    }

    private func siteKeyIndexTrialIds(_ siteKey: String, filter: TrialFilter, limit: Int) -> [Int64]? {
        guard let entry = ensureSiteIndexV9().byKey[siteKey], !entry.recentTrialIds.isEmpty else {
            return nil
        }
        if filter.isEmpty { return Array(entry.recentTrialIds.prefix(limit)) }
        if filter.status == "RECRUITING" {
            var rest = filter
            rest.status = nil
            if rest.isEmpty { return Array(entry.recentTrialIds.prefix(limit)) }
        }
        return nil
    }

    private func scanCountForSiteKeyV9(siteKey: String, filter: TrialFilter) -> Int {
        guard usesDetailBlob else { return 0 }
        let (whereSQL, args) = whereClause(filter, isCount: true)
        let sql = """
            SELECT trial.detail_z FROM trial
            \(whereSQL)
            AND trial.detail_z IS NOT NULL
            """
        let stmt = prepare(sql, args)
        defer { sqlite3_finalize(stmt) }
        let dict = dictionaries["detail_z"]
        var n = 0
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let blob = blob(stmt, 0),
                  let data = Self.decompressData(blob, dictionary: dict),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            let rows = root["l"] as? [[Any]] ?? []
            let matches = rows.contains { row in
                let facility = Self.jsonString(row, 0) ?? ""
                let city = Self.jsonString(row, 1)
                let country = Self.jsonString(row, 3)
                return SiteSoftKey.make(facility: facility, city: city, country: country) == siteKey
            }
            if matches { n += 1 }
        }
        return n
    }
}
