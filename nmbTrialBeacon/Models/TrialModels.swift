//
//  TrialModels.swift
//  nmbTrialBeacon
//
//  Plain, Sendable read models for the read-only trials database.
//  These replace the old SwiftData @Model trial graph. The bundled
//  `trialbeacon.sqlite` (see DB_GENERATOR_SPEC.md) is queried directly
//  and mapped into these value types — never imported into SwiftData.
//

import Foundation
import CoreLocation

// MARK: - List row

struct TrialSummary: Identifiable, Sendable, Hashable {
    let trialId: Int64
    let nctId: String
    let briefTitle: String
    let overallStatus: String          // canonical, e.g. "RECRUITING"
    /// Resolved from `lookup_status` (schema v4 dropped `status_display`).
    let statusDisplay: String          // e.g. "Recruiting"
    /// Resolved from `lookup_phase` (schema v4 dropped `phase_display`).
    let phaseDisplay: String?          // e.g. "Phase 2"
    /// Resolved from `lookup_study_type` (schema v4 dropped `study_type_display`).
    let studyTypeDisplay: String?
    let primaryCondition: String?
    let primaryCountry: String?
    let lastUpdatePostDate: Date
    /// Used as the keyset cursor for the "Newly added" sort (`first_posted_date`).
    let firstPostedDate: Date?
    /// Precision-aware UTC label for `first_posted_date` (schema v4+).
    let firstPostedDisplay: String?
    /// Precision-aware UTC label for `last_update_post_date` (schema v4+).
    let lastUpdateDisplay: String?
    let conditionCount: Int
    let locationCount: Int
    let isActive: Bool
    /// First ~300 chars of the brief summary. Schema 5 stores this as
    /// `summary_snippet_z` (decompressed in the list path); older files used
    /// plain `summary_snippet` TEXT. Still cheaper than inflating `brief_summary_z`.
    let summarySnippet: String?

    var id: Int64 { trialId }

    var cursor: TrialCursor {
        TrialCursor(
            lastUpdate: Int64(lastUpdatePostDate.timeIntervalSince1970),
            firstPosted: Int64((firstPostedDate ?? .distantPast).timeIntervalSince1970),
            title: briefTitle,
            trialId: trialId
        )
    }
}

// MARK: - Detail

struct TrialLocationInfo: Identifiable, Sendable, Hashable {
    let id = UUID()
    let facilityName: String?
    let city: String?
    let state: String?
    let country: String?
    let postalCode: String?
    let status: String?
    let latitude: Double?
    let longitude: Double?

    var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// "Boston, MA, United States" — omitting whatever the record is missing.
    var placeDescription: String {
        [city, state, country].compactMap { $0 }.joined(separator: ", ")
    }
}

struct TrialInterventionInfo: Identifiable, Sendable, Hashable {
    let id = UUID()
    let type: String?
    let typeDisplay: String?
    let name: String
    let details: String?
}

struct TrialOutcomeInfo: Identifiable, Sendable, Hashable {
    let id = UUID()
    let type: String
    let measure: String
    let timeFrame: String?
    let details: String?
}

struct TrialSponsorInfo: Identifiable, Sendable, Hashable {
    let id = UUID()
    let name: String
    let agencyClass: String?
    let role: String?
}

/// Schema v9+: organisation from `lookup_collaborator` / `trial_collaborator`.
struct CollaboratorInfo: Identifiable, Sendable, Hashable {
    let collaboratorId: Int64
    let name: String
    let agencyClass: String?
    let trialCount: Int
    var id: Int64 { collaboratorId }
}

/// Schema v9+: sparse `trial_results` row (absent when `has_results` is false).
/// Schema v13 adds study-record update proxy, outcome totals, and publication counts.
struct TrialResultsSummary: Sendable, Hashable {
    let resultsFirstPostDate: Date?
    /// Study-level `lastUpdatePostDate` while results are posted — **not** a results-section edit date.
    let studyRecordLastUpdatePostDate: Date?
    let primaryOutcomeCount: Int
    let secondaryOutcomeCount: Int?
    let totalOutcomeCount: Int?
    let resultsFlags: Int
    let flowStarted: Int?
    let flowCompleted: Int?
    let linkedPublicationCount: Int?
    let resultReferenceCount: Int?

    var hasSeriousAdverseEvents: Bool { resultsFlags & 1 != 0 }
    var hasOtherAdverseEvents: Bool { resultsFlags & 2 != 0 }
    var hasStatisticalAnalysis: Bool { resultsFlags & 4 != 0 }

    /// `flow_started - flow_completed` when both are present and non-negative.
    var withdrawn: Int? {
        guard let started = flowStarted, let completed = flowCompleted else { return nil }
        let value = started - completed
        return value >= 0 ? value : nil
    }

    /// Completion rate capped at 100% (registry occasionally reports completed > started).
    var completionPercent: Double? {
        guard let started = flowStarted, started > 0, let completed = flowCompleted else { return nil }
        return min(100.0, 100.0 * Double(completed) / Double(started))
    }
}

struct TrialEligibilityInfo: Sendable, Hashable {
    let inclusion: String?
    let exclusion: String?
    let rawText: String?
    let studyPopulation: String?
    let samplingMethod: String?
}

struct TrialDetail: Identifiable, Sendable {
    let summary: TrialSummary
    let officialTitle: String?
    let briefSummary: String?          // decompressed from brief_summary_z
    let detailedDescription: String?   // decompressed from detailed_description_z
    /// Formatted from epoch + `date_precision` in UTC (schema v4); legacy files
    /// still supply the old `*_date_display` strings.
    let startDateDisplay: String?
    let completionDateDisplay: String?
    let firstPostedDateDisplay: String?
    let lastUpdateDisplay: String?
    /// Resolved from `lookup_gender` (schema v4 dropped `gender_eligibility_display`).
    let genderEligibilityDisplay: String?
    /// Registry unit wording — kept on the row intentionally (`"18 Years"`, `"6 Months"`).
    let minAgeDisplay: String?
    let maxAgeDisplay: String?
    /// Standard age groups from `trial.std_ages` — CHILD / ADULT / OLDER_ADULT
    /// (schema v3 stores these as bits 1/2/4; older files used a CSV string).
    let stdAges: [String]
    let healthyVolunteers: Bool?
    let enrollmentCount: Int?
    let whyStopped: String?
    let leadSponsorName: String?
    let hasResults: Bool
    let fdaRegulatedDrug: Bool
    let hasExpandedAccess: Bool
    let conditions: [String]
    let locations: [TrialLocationInfo]
    let interventions: [TrialInterventionInfo]
    let outcomes: [TrialOutcomeInfo]
    /// Lead sponsor rows from `detail_z` `"s"` (v9: lead-only).
    let sponsors: [TrialSponsorInfo]
    /// Schema v9+: collaborators from `trial_collaborator` (not the detail blob).
    let collaborators: [CollaboratorInfo]
    /// Schema v9+: present only when results were posted (`trial_results` row).
    let results: TrialResultsSummary?
    let eligibility: TrialEligibilityInfo?

    var id: Int64 { summary.trialId }
    var nctId: String { summary.nctId }
}

// MARK: - Filtering & sorting

nonisolated struct TrialFilter: Equatable, Hashable, Sendable, Codable {
    var status: String?
    var studyType: String?
    var phase: String?
    /// When non-empty, matches `trial.phase IN (…)`. Takes precedence over `phase`.
    /// Used for org/site Phase III buckets (`PHASE3` + `PHASE2_PHASE3`).
    var phases: Set<String> = []
    var country: String?
    var conditions: Set<String> = []
    /// Schema v9+: `lookup_collaborator.collaborator_id` values as decimal strings.
    var collaborators: Set<String> = []
    /// Exact match on `trial.lead_sponsor_name`.
    var leadSponsor: String?
    /// Schema v10+: `organisation.organisation_id` as a decimal string.
    var organisationId: String?
    /// Schema v10+: `lead_sponsor` or `collaborator` when scoping an organisation filter.
    var organisationRole: String?
    /// Schema v10+: `site.site_id` as a decimal string.
    var siteId: String?
    /// Schema v9 fallback: soft site key `facility|city|country` (see `SiteSoftKey`).
    var siteKey: String?
    /// `nil` = any; `true` / `false` match `trial.has_results`.
    var hasResults: Bool?
    /// `nil` = any; matches `trial.fda_regulated_drug`.
    var fdaRegulatedDrug: Bool?
    /// `nil` = any; matches `trial.has_expanded_access`.
    var hasExpandedAccess: Bool?
    /// Schema v9+: `trial_results.results_flags` bit 0. `nil` = any.
    var hasSeriousAdverseEvents: Bool?
    /// Schema v9+: `trial_results.results_flags` bit 1. `nil` = any.
    var hasOtherAdverseEvents: Bool?
    /// Schema v9+: `trial_results.results_flags` bit 2. `nil` = any.
    var hasStatisticalAnalysis: Bool?
    var gender: String?
    var lastUpdatedWithinDays: Int?
    /// Trials whose `first_posted_date` falls within this many days.
    var firstPostedWithinDays: Int?
    /// A `lookup_age_range` value: CHILD, ADULT or OLDER_ADULT.
    var ageRange: String?
    var activeOnly: Bool = false

    // These are read from the store actor as well as from views, so they are
    // explicitly nonisolated rather than picking up the module's MainActor default.
    nonisolated var isEmpty: Bool {
        status == nil && studyType == nil && phase == nil && phases.isEmpty && country == nil &&
        conditions.isEmpty && collaborators.isEmpty && leadSponsor == nil &&
        organisationId == nil && organisationRole == nil &&
        siteId == nil && siteKey == nil &&
        hasResults == nil && fdaRegulatedDrug == nil && hasExpandedAccess == nil &&
        hasSeriousAdverseEvents == nil && hasOtherAdverseEvents == nil &&
        hasStatisticalAnalysis == nil && gender == nil &&
        lastUpdatedWithinDays == nil && firstPostedWithinDays == nil &&
        ageRange == nil && !activeOnly
    }

    /// Number of user-facing active filters (used for the "Filters (n)" badge).
    nonisolated var activeFilterCount: Int {
        var n = 0
        if status != nil { n += 1 }
        if studyType != nil { n += 1 }
        if phase != nil || !phases.isEmpty { n += 1 }
        if country != nil { n += 1 }
        if !conditions.isEmpty { n += 1 }
        if !collaborators.isEmpty { n += 1 }
        if leadSponsor != nil { n += 1 }
        if organisationId != nil { n += 1 }
        if siteId != nil || siteKey != nil { n += 1 }
        if hasResults != nil { n += 1 }
        if fdaRegulatedDrug != nil { n += 1 }
        if hasExpandedAccess != nil { n += 1 }
        if hasSeriousAdverseEvents != nil { n += 1 }
        if hasOtherAdverseEvents != nil { n += 1 }
        if hasStatisticalAnalysis != nil { n += 1 }
        if gender != nil { n += 1 }
        if lastUpdatedWithinDays != nil { n += 1 }
        if firstPostedWithinDays != nil { n += 1 }
        if ageRange != nil { n += 1 }
        if activeOnly { n += 1 }
        return n
    }

    /// One entry per active filter, for the removable chips above the results.
    /// Conditions collapse into a single chip because clearing them one at a
    /// time is rarely what someone wants and the row would overflow.
    ///
    /// Raw canonical values are returned rather than display text: the readable
    /// form lives in the `lookup_*.display` columns, so the view resolves labels
    /// from the loaded lookups instead of this type reimplementing the mapping.
    nonisolated var activeChips: [Chip] {
        var chips: [Chip] = []
        if activeOnly { chips.append(Chip(kind: .activeOnly, rawValue: "Active studies")) }
        if let status { chips.append(Chip(kind: .status, rawValue: status)) }
        if !phases.isEmpty {
            let label = phases.count == 1
                ? (phases.first ?? "Phase")
                : "Phase III"
            chips.append(Chip(kind: .phase, rawValue: label))
        } else if let phase {
            chips.append(Chip(kind: .phase, rawValue: phase))
        }
        if let studyType { chips.append(Chip(kind: .studyType, rawValue: studyType)) }
        if let country { chips.append(Chip(kind: .country, rawValue: country)) }
        if !conditions.isEmpty {
            let label = conditions.count == 1 ? (conditions.first ?? "") : "\(conditions.count) conditions"
            chips.append(Chip(kind: .conditions, rawValue: label))
        }
        if !collaborators.isEmpty {
            let label = collaborators.count == 1
                ? (collaborators.first ?? "")
                : "\(collaborators.count) collaborators"
            chips.append(Chip(kind: .collaborators, rawValue: label))
        }
        if let leadSponsor { chips.append(Chip(kind: .leadSponsor, rawValue: leadSponsor)) }
        if let organisationId {
            chips.append(Chip(kind: .organisation, rawValue: organisationId))
        }
        if let siteId {
            chips.append(Chip(kind: .site, rawValue: siteId))
        } else if let siteKey {
            chips.append(Chip(kind: .site, rawValue: siteKey))
        }
        if let hasResults {
            chips.append(Chip(kind: .hasResults, rawValue: hasResults ? "Has results" : "No results"))
        }
        if let fdaRegulatedDrug {
            chips.append(Chip(kind: .fdaRegulatedDrug,
                              rawValue: fdaRegulatedDrug ? "FDA regulated drug" : "Not FDA regulated"))
        }
        if let hasExpandedAccess {
            chips.append(Chip(kind: .hasExpandedAccess,
                              rawValue: hasExpandedAccess ? "Expanded access" : "No expanded access"))
        }
        if let hasSeriousAdverseEvents {
            chips.append(Chip(kind: .hasSeriousAdverseEvents,
                              rawValue: hasSeriousAdverseEvents ? "Serious AEs" : "No serious AEs"))
        }
        if let hasOtherAdverseEvents {
            chips.append(Chip(kind: .hasOtherAdverseEvents,
                              rawValue: hasOtherAdverseEvents ? "Other AEs" : "No other AEs"))
        }
        if let hasStatisticalAnalysis {
            chips.append(Chip(kind: .hasStatisticalAnalysis,
                              rawValue: hasStatisticalAnalysis ? "Statistical analysis" : "No statistical analysis"))
        }
        if let gender { chips.append(Chip(kind: .gender, rawValue: gender)) }
        if let ageRange { chips.append(Chip(kind: .ageRange, rawValue: ageRange)) }
        if let days = lastUpdatedWithinDays {
            chips.append(Chip(kind: .updatedWithin, rawValue: "Updated in \(days) days"))
        }
        if let days = firstPostedWithinDays {
            chips.append(Chip(kind: .postedWithin, rawValue: "Added in \(days) days"))
        }
        return chips
    }

    struct Chip: Identifiable, Hashable, Sendable {
        enum Kind: Hashable, Sendable {
            case activeOnly, status, phase, studyType, country, conditions, collaborators,
                 leadSponsor, organisation, site, hasResults, fdaRegulatedDrug, hasExpandedAccess,
                 hasSeriousAdverseEvents, hasOtherAdverseEvents, hasStatisticalAnalysis,
                 gender, ageRange, updatedWithin, postedWithin

            /// The lookup whose `display` column names this value, when there is one.
            var dimension: LookupDimension? {
                switch self {
                case .status:    return .status
                case .phase:     return .phase
                case .studyType: return .studyType
                case .gender:    return .gender
                case .ageRange:  return .ageRange
                case .activeOnly, .country, .conditions, .collaborators, .leadSponsor,
                     .organisation, .site, .hasResults, .fdaRegulatedDrug, .hasExpandedAccess,
                     .hasSeriousAdverseEvents, .hasOtherAdverseEvents, .hasStatisticalAnalysis,
                     .updatedWithin, .postedWithin: return nil
                }
            }
        }
        let kind: Kind
        let rawValue: String
        var id: Kind { kind }
    }

    nonisolated mutating func remove(_ kind: Chip.Kind) {
        switch kind {
        case .activeOnly:              activeOnly = false
        case .status:                  status = nil
        case .phase:                   phase = nil; phases = []
        case .studyType:               studyType = nil
        case .country:                 country = nil
        case .conditions:              conditions = []
        case .collaborators:           collaborators = []
        case .leadSponsor:             leadSponsor = nil
        case .organisation:            organisationId = nil; organisationRole = nil
        case .site:                    siteId = nil; siteKey = nil
        case .hasResults:              hasResults = nil
        case .fdaRegulatedDrug:        fdaRegulatedDrug = nil
        case .hasExpandedAccess:       hasExpandedAccess = nil
        case .hasSeriousAdverseEvents: hasSeriousAdverseEvents = nil
        case .hasOtherAdverseEvents:   hasOtherAdverseEvents = nil
        case .hasStatisticalAnalysis:  hasStatisticalAnalysis = nil
        case .gender:                  gender = nil
        case .ageRange:                ageRange = nil
        case .updatedWithin:           lastUpdatedWithinDays = nil
        case .postedWithin:            firstPostedWithinDays = nil
        }
    }

    /// Inclusive year bounds for `ageRange` on schema v1/v2 (CSV `std_ages`).
    /// Schema v3 prefers `stdAgesBit` against the integer bit set instead.
    nonisolated var ageBounds: (lower: Double, upper: Double)? {
        switch ageRange {
        case "CHILD":       return (0, 17)
        case "ADULT":       return (18, 64)
        case "OLDER_ADULT": return (65, 130)
        default:            return nil
        }
    }

    /// Bit for schema v3 `trial.std_ages` (1 CHILD / 2 ADULT / 4 OLDER_ADULT).
    nonisolated var stdAgesBit: Int64? {
        switch ageRange {
        case "CHILD":       return 1
        case "ADULT":       return 2
        case "OLDER_ADULT": return 4
        default:            return nil
        }
    }
}

enum TrialSort: String, Sendable, Equatable, Hashable, Codable {
    /// FTS relevance (bm25 / rank). Browse mode treats this as recently updated.
    case relevance
    case lastUpdatedDesc
    case titleAsc
    /// Newest registrations first — needs `idx_trial_first_posted` (schema v2).
    case firstPostedDesc
}

/// Which `trial_fts` columns a Discover search hits.
/// Schema v7 indexes full `brief_summary` as well; eligibility / detailed
/// description remain outside the index.
enum TrialSearchScope: String, CaseIterable, Sendable, Identifiable {
    case all = "All fields"
    case titles = "Titles"
    case conditions = "Conditions"
    case interventions = "Interventions"
    case summaries = "Summaries"
    case nctId = "NCT ID"

    var id: String { rawValue }

    /// FTS5 column filter prefix, or `nil` for an unscoped (all-column) match.
    /// `nonisolated` so `TrialStore` (background actor) can build MATCH strings.
    nonisolated var ftsColumnFilter: String? {
        switch self {
        case .all: return nil
        case .titles: return "{brief_title official_title}"
        case .conditions: return "conditions"
        case .interventions: return "interventions"
        case .summaries: return "brief_summary"
        case .nctId: return "nct_id"
        }
    }
}

/// Keyset pagination cursor. Only the field relevant to the active sort is used.
/// `nonisolated` so `TrialStore` can compare cursors under default MainActor isolation.
nonisolated struct TrialCursor: Sendable, Equatable {
    let lastUpdate: Int64
    let firstPosted: Int64
    let title: String
    let trialId: Int64
}

// MARK: - Registry dates (schema v4 `date_precision`)

/// How much of a registry date the sponsor actually stated. Two bits per date
/// in `trial.date_precision`. Epochs are the first instant of that precision
/// in UTC — format them in UTC or month/year values roll back west of Greenwich.
///
/// Marked `nonisolated` so `TrialStore` (a background actor) can format dates
/// under the module's default MainActor isolation.
enum DatePrecision: Int, Sendable {
    case none = 0, year = 1, month = 2, day = 3

    nonisolated init(mask: Int, shift: Int) {
        self = DatePrecision(rawValue: (mask >> shift) & 3) ?? .none
    }

    nonisolated static let start = 0
    nonisolated static let completion = 2
    nonisolated static let firstPosted = 4
    nonisolated static let lastUpdate = 6
}

enum TrialDateFormat {
    nonisolated private static let utc = TimeZone(secondsFromGMT: 0)!
    nonisolated private static let cache = Cache()

    nonisolated static func string(epochSeconds: Int64?, precision: DatePrecision) -> String? {
        guard let epochSeconds, precision != .none else { return nil }
        let date = Date(timeIntervalSince1970: TimeInterval(epochSeconds))
        // Placeholder the registry sometimes carries; treat as unstated.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        if calendar.component(.year, from: date) == 1900 { return nil }
        return cache.formatter(for: precision).string(from: date)
    }

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        /// Guarded by `lock`; `nonisolated(unsafe)` so TrialStore can format under
        /// the module's default MainActor isolation.
        nonisolated(unsafe) private var formatters: [DatePrecision: DateFormatter] = [:]

        nonisolated func formatter(for precision: DatePrecision) -> DateFormatter {
            lock.lock()
            defer { lock.unlock() }
            if let existing = formatters[precision] { return existing }
            let formatter = DateFormatter()
            formatter.timeZone = TrialDateFormat.utc
            formatter.locale = .current
            switch precision {
            case .none:
                break
            case .year:
                formatter.setLocalizedDateFormatFromTemplate("y")
            case .month:
                formatter.setLocalizedDateFormatFromTemplate("yMMMM")
            case .day:
                formatter.setLocalizedDateFormatFromTemplate("yMMMMd")
            }
            formatters[precision] = formatter
            return formatter
        }
    }
}

// MARK: - Lookups (filter menus)

/// Explicit nonisolated Equatable/Hashable so `TrialStore` (background actor) can
/// use this as a dictionary key under the module's default MainActor isolation.
enum LookupDimension: Sendable {
    case status, phase, studyType, gender, country, condition, ageRange, collaborator
}

extension LookupDimension: Equatable {
    nonisolated static func == (lhs: LookupDimension, rhs: LookupDimension) -> Bool {
        lhs.stableTag == rhs.stableTag
    }
}

extension LookupDimension: Hashable {
    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(stableTag)
    }

    nonisolated fileprivate var stableTag: Int {
        switch self {
        case .status: return 0
        case .phase: return 1
        case .studyType: return 2
        case .gender: return 3
        case .country: return 4
        case .condition: return 5
        case .ageRange: return 6
        case .collaborator: return 7
        }
    }
}

struct LookupValue: Identifiable, Sendable, Hashable {
    let value: String
    let display: String
    let count: Int
    var id: String { value }
}

/// Schema v14+: row from `lookup_intervention` / `popular_intervention`.
struct InterventionLookupValue: Identifiable, Sendable, Hashable {
    let value: String
    let trialCount: Int
    /// Dominant CTG intervention type when known (e.g. `DRUG`); may be empty.
    let type: String
    /// True when `value` matches a Drugs@FDA ingredient or brand in `fda_drug` / `fda_brand`.
    /// Catalog presence only — not a claim the trial’s indication is approved.
    let inFdaCatalog: Bool

    var id: String { value }

    var typeLabel: String {
        let trimmed = type.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return trimmed
            .replacingOccurrences(of: "_", with: " ")
            .localizedCapitalized
    }
}

// MARK: - Clinical Research Pulse

struct PulseCapabilities: Sendable {
    var onThisDay: Bool
    var interestingTrial: Bool
    var conditionGrowth: Bool
}

/// 30-day registry activity for the Pulse headline (natural prose, not a KPI strip).
struct PulseRecentActivity: Sendable {
    var newTrials: Int
    var beganRecruiting: Int
    var completed: Int
    var terminated: Int
}

struct PulseOnThisDay: Sendable, Identifiable {
    let nctId: String
    let briefTitle: String
    let firstPostedYear: Int
    let yearsAgo: Int
    let phaseDisplay: String?
    let primaryCondition: String?
    let enrollmentCount: Int?
    let hasResults: Bool
    var id: String { nctId }
}

struct PulseInterestingTrial: Sendable, Identifiable {
    let nctId: String
    let briefTitle: String
    let primaryCondition: String?
    let statusDisplay: String
    let primaryCountry: String?
    let interestTags: [String]
    let blurb: String?
    var id: String { nctId }
}

struct PulseConditionGrowth: Sendable, Identifiable {
    let condition: String
    let yearFrom: Int
    let yearTo: Int
    let countFrom: Int
    let countTo: Int
    let absDelta: Int
    let growthRatio: Double?
    let rank: Int
    var id: String { "\(rank)-\(condition)" }
}

struct PulseStoppedTrial: Sendable, Identifiable {
    let nctId: String
    let briefTitle: String
    let overallStatus: String
    let statusDisplay: String
    let phaseDisplay: String?
    let primaryCondition: String?
    let leadSponsorName: String?
    let whyStopped: String?
    let lastUpdateLabel: String?
    let hasResults: Bool
    var id: String { nctId }
}

/// Segments for Trial Status Watch (recently updated records).
enum PulseStatusWatchTab: String, CaseIterable, Identifiable, Sendable {
    case completed = "COMPLETED"
    case terminated = "TERMINATED"
    case suspended = "SUSPENDED"
    case withdrawn = "WITHDRAWN"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .completed: return "Completed"
        case .terminated: return "Terminated"
        case .suspended: return "Suspended"
        case .withdrawn: return "Withdrawn"
        }
    }
}

// MARK: - Aggregates (analytics / dashboard)

enum AggDimension: String, Sendable {
    case status
    case phase
    case studyType = "study_type"
    case gender
    case country
    case condition
}

enum AggScope: String, Sendable {
    case all
    case active
    /// Schema v6 — trials whose primary condition is a population label removed.
    case allExclHealthy = "all_excl_healthy"
    case activeExclHealthy = "active_excl_healthy"

    static func resolve(activeOnly: Bool, excludeHealthy: Bool) -> AggScope {
        switch (activeOnly, excludeHealthy) {
        case (false, false): return .all
        case (true, false):  return .active
        case (false, true):  return .allExclHealthy
        case (true, true):   return .activeExclHealthy
        }
    }
}

struct DimensionCount: Identifiable, Sendable, Hashable {
    let value: String
    let count: Int
    /// Optional label when `value` is a canonical id (e.g. collaborator_id).
    var display: String? = nil
    var id: String { value }
    var label: String { display ?? value }
}

struct YearCount: Identifiable, Sendable {
    let year: Int
    let count: Int
    var id: Int { year }
}

struct ConditionByYear: Identifiable, Sendable {
    let year: Int
    let condition: String
    let count: Int
    let rank: Int
    var id: String { "\(year)-\(rank)-\(condition)" }
}

struct DashboardStats: Sendable {
    let totalTrials: Int
    let recruitingCount: Int
    let activeNotRecruitingCount: Int
    let recentlyUpdatedCount: Int
    let createdAt: Date?
    let sourceSnapshotDate: Date?
    let schemaVersion: Int
    let generatorVersion: String?
    let source: String?
    let buildOptions: String?
    /// Schema v6 `db_metadata` — nil on older files.
    let totalTrialsExclHealthy: Int?
    let recruitingCountExclHealthy: Int?
    let activeNotRecruitingCountExclHealthy: Int?

    var hasExclHealthyTotals: Bool {
        totalTrialsExclHealthy != nil
    }
}

// MARK: - Recommendations

/// A recruiting study with its nearest site inside the user’s radius.
struct NearbyTrial: Identifiable, Sendable, Hashable {
    let trial: TrialSummary
    let site: TrialLocationInfo
    /// Great-circle distance from the user to `site`, in meters.
    let distanceMeters: Double
    /// Profile relevance when ranking with a completed profile; otherwise `nil`.
    var matchScore: Double?

    var id: Int64 { trial.trialId }

    var distanceLabel: String { NearbyDistance.formatMiles(distanceMeters) }

    var siteLabel: String {
        if let facility = site.facilityName, !facility.isEmpty {
            if let city = site.city, !city.isEmpty { return "\(facility) · \(city)" }
            return facility
        }
        return site.placeDescription
    }
}

struct TrialRecommendation: Identifiable, Sendable, Hashable {
    let trial: TrialSummary
    let matchScore: Double        // 0.0 ... 1.0
    let matchReasons: [String]

    var id: Int64 { trial.trialId }
    var matchPercentage: Int { Int((matchScore * 100).rounded()) }

    var matchQuality: MatchQuality {
        switch matchScore {
        case 0.8...1.0: return .excellent
        case 0.6..<0.8: return .good
        case 0.4..<0.6: return .fair
        default:        return .poor
        }
    }
}

enum MatchQuality: String, Sendable {
    case excellent = "Excellent Match"
    case good = "Good Match"
    case fair = "Fair Match"
    case poor = "Potential Match"
}

// MARK: - Errors

enum TrialDataError: LocalizedError {
    case databaseNotFound
    case openFailed(String)
    /// `user_version` outside the client’s supported inclusive range (currently v13–v14).
    case unsupportedSchema(found: Int64, minimum: Int64, maximum: Int64)
    case notReady

    var errorDescription: String? {
        switch self {
        case .databaseNotFound:
            return "The trials database (trialbeacon.sqlite) was not found in the app bundle."
        case .openFailed(let msg):
            return "Could not open the trials database: \(msg)"
        case .unsupportedSchema(let found, let minimum, let maximum):
            if found > maximum {
                return "This database is schema v\(found), but the app only reads up to v\(maximum). Update the app."
            }
            return "This database is schema v\(found), but the app requires schema v\(minimum)–v\(maximum). Rebuild or rebundle a current database."
        case .notReady:
            return "The trials database is not ready yet."
        }
    }
}
