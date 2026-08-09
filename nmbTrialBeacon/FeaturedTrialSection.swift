//
//  FeaturedTrialSection.swift
//  nmbTrialBeacon
//
//  Home “Featured” — one recruiting study picked for this user,
//  shown with a condition-domain stock photo. Selection blends:
//    • profile: conditions of interest, age group, country
//    • place: preferred city (or device location) — nearby sites score higher
//    • behaviour: conditions mined from the watchlist, favourite / recently
//      viewed organisations (watchlisted trials themselves are excluded)
//    • momentum: newly posted, recently updated, Phase 2/3, interventional
//  The pick is stable for the day and won’t repeat within a week
//  (see FeaturedTrialLog).
//

import CoreLocation
import SwiftUI
import UIKit

// MARK: - Pick model

struct FeaturedTrialPick {
    let trial: TrialSummary
    let siteLatitude: Double?
    let siteLongitude: Double?
    let siteLabel: String?
    let distanceMeters: Double?
    /// Short “why this one” line, e.g. “Matches your interest in Melanoma”.
    let reason: String?

    var siteCoordinate: CLLocationCoordinate2D? {
        guard let siteLatitude, let siteLongitude else { return nil }
        return CLLocationCoordinate2D(latitude: siteLatitude, longitude: siteLongitude)
    }
}

// MARK: - Selection engine

enum FeaturedTrialEngine {
    struct Context {
        var profileConditions: [String] = []
        var ageRange: String?
        var country: String?
        var watchlistNctIds: [String] = []
        var favouriteOrgNames: [String] = []
        var recentOrgNames: [String] = []
        var coordinate: CLLocationCoordinate2D?
        var countryHint: String?
        var radiusMiles: Int = LocationService.defaultRadiusMiles
        /// Recently featured NCT ids (past days) — never repeat these.
        var excludedNctIds: Set<String> = []
        /// On This Day / Interesting Trial (and similar editorial slots) — hard
        /// exclude; never feature the same study Home is already showing.
        var reservedEditorialNctIds: Set<String> = []
        /// Today’s already-logged pick; kept if still a valid candidate so the
        /// card doesn’t change mid-day.
        var preferredNctId: String?
    }

    private struct Candidate {
        var trial: TrialSummary
        var nearby: NearbyTrial?
        var favouriteOrg: String?
        var recentOrg: String?
    }

    static func pick(data: TrialDataService, context: Context) async -> FeaturedTrialPick? {
        await data.waitUntilReady()

        let reserved = context.reservedEditorialNctIds
        let watchlist = Set(context.watchlistNctIds)
        let profileConditions = Set(context.profileConditions.map { $0.lowercased() })

        // Fast path: today’s already-chosen pick (stable for the day).
        if let preferred = context.preferredNctId,
           !reserved.contains(preferred),
           !watchlist.contains(preferred),
           !context.excludedNctIds.contains(preferred),
           let summary = await data.summaries(nctIds: [preferred]).first,
           summary.overallStatus.uppercased() == "RECRUITING" {
            let kept = Candidate(trial: summary)
            return await resolve(
                kept,
                reason: reason(for: kept, profileConditions: profileConditions, watchConditions: []),
                data: data,
                context: context
            )
        }

        var base = TrialFilter()
        base.status = "RECRUITING"
        base.ageRange = context.ageRange

        // Watchlist taste: conditions from trials the user already tracks.
        let watchSummaries = await data.summaries(nctIds: Array(context.watchlistNctIds.prefix(30)))
        let watchConditions = Set(watchSummaries.compactMap { $0.primaryCondition?.lowercased() })

        var pool: [String: Candidate] = [:]
        func add(_ summary: TrialSummary, nearby: NearbyTrial? = nil,
                 favouriteOrg: String? = nil, recentOrg: String? = nil) {
            var candidate = pool[summary.nctId] ?? Candidate(trial: summary)
            if let nearby {
                if candidate.nearby.map({ nearby.distanceMeters < $0.distanceMeters }) ?? true {
                    candidate.nearby = nearby
                }
            }
            if let favouriteOrg { candidate.favouriteOrg = favouriteOrg }
            if let recentOrg { candidate.recentOrg = recentOrg }
            pool[summary.nctId] = candidate
        }

        // Pool 1 — recruiting near the user’s place (also supplies the map pin).
        let radiusMeters = Double(context.radiusMiles) * NearbyDistance.metersPerMile
        if let coordinate = context.coordinate {
            let hits = await data.nearbyRecruiting(
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                radiusMeters: radiusMeters,
                filter: base,
                countryHint: context.countryHint,
                limit: 120
            )
            for hit in hits { add(hit.trial, nearby: hit) }
        }

        // Pool 2 — conditions of interest (profile + mined from watchlist).
        let interestConditions = Set(context.profileConditions)
            .union(watchSummaries.compactMap(\.primaryCondition))
        if !interestConditions.isEmpty {
            var f = base
            f.conditions = interestConditions
            for row in await data.page(filter: f, sort: .lastUpdatedDesc, after: nil, limit: 120) {
                add(row)
            }
        }

        // Pool 3 — favourite / recently viewed organisations.
        for org in context.favouriteOrgNames.prefix(3) {
            var f = base
            f.leadSponsor = org
            for row in await data.page(filter: f, sort: .lastUpdatedDesc, after: nil, limit: 25) {
                add(row, favouriteOrg: org)
            }
        }
        for org in context.recentOrgNames.prefix(2) where !context.favouriteOrgNames.contains(org) {
            var f = base
            f.leadSponsor = org
            for row in await data.page(filter: f, sort: .lastUpdatedDesc, after: nil, limit: 15) {
                add(row, recentOrg: org)
            }
        }

        // Fallback pool — freshly posted recruiting studies (country-aware),
        // so brand-new users still get a sensible card.
        if pool.count < 10 {
            var f = base
            f.firstPostedWithinDays = 45
            f.country = context.country
            for row in await data.page(filter: f, sort: .firstPostedDesc, after: nil, limit: 60) {
                add(row)
            }
        }

        // Never feature watchlist, recent repeats, or today’s editorial slots.
        var excluded = context.excludedNctIds
            .union(watchlist)
            .union(reserved)
        // Prefer today’s pick only when it isn’t reserved for On This Day / Interesting.
        if let preferred = context.preferredNctId, !reserved.contains(preferred) {
            excluded.remove(preferred)
        }
        let candidates = pool.values.filter { !excluded.contains($0.trial.nctId) }
        guard !candidates.isEmpty else { return nil }

        let now = Date()
        func daysAgo(_ date: Date?) -> Int? {
            guard let date else { return nil }
            return Calendar.current.dateComponents([.day], from: date, to: now).day
        }

        func score(_ c: Candidate) -> Double {
            var s = 0.0
            if let cond = c.trial.primaryCondition?.lowercased() {
                if profileConditions.contains(cond) { s += 40 }
                else if watchConditions.contains(cond) { s += 22 }
            }
            if c.favouriteOrg != nil { s += 30 }
            else if c.recentOrg != nil { s += 14 }
            if let nearby = c.nearby {
                s += 12 + 20 * max(0, 1 - nearby.distanceMeters / radiusMeters)
            }
            if let d = daysAgo(c.trial.firstPostedDate) {
                if d <= 14 { s += 15 } else if d <= 60 { s += 7 }
            }
            if let d = daysAgo(c.trial.lastUpdatePostDate), d <= 30 { s += 4 }
            if let phase = c.trial.phaseDisplay {
                if phase.contains("3") { s += 8 } else if phase.contains("2") { s += 5 }
            }
            if (c.trial.studyTypeDisplay ?? "").localizedCaseInsensitiveContains("Interventional") {
                s += 5
            }
            return s
        }

        // Deterministic winner: score, then newest, then id — so the same
        // inputs always feature the same trial for the whole day.
        let winner = candidates.max { a, b in
            let sa = score(a), sb = score(b)
            if sa != sb { return sa < sb }
            let fa = a.trial.firstPostedDate ?? .distantPast
            let fb = b.trial.firstPostedDate ?? .distantPast
            if fa != fb { return fa < fb }
            return a.trial.nctId > b.trial.nctId
        }
        guard let winner else { return nil }
        return await resolve(winner, reason: reason(for: winner,
                                                    profileConditions: profileConditions,
                                                    watchConditions: watchConditions),
                             data: data, context: context)
    }

    private static func reason(for c: Candidate,
                               profileConditions: Set<String>,
                               watchConditions: Set<String>) -> String? {
        if let cond = c.trial.primaryCondition,
           profileConditions.contains(cond.lowercased()) {
            return "Matches your interest in \(cond)"
        }
        if let org = c.favouriteOrg {
            return "Led by \(org) — one of your favourites"
        }
        if let cond = c.trial.primaryCondition,
           watchConditions.contains(cond.lowercased()) {
            return "Similar to trials on your watchlist"
        }
        if let org = c.recentOrg {
            return "Led by \(org), which you viewed recently"
        }
        if let posted = c.trial.firstPostedDate,
           let days = Calendar.current.dateComponents([.day], from: posted, to: Date()).day,
           days <= 30 {
            return "Newly posted study"
        }
        if c.nearby != nil {
            return "Recruiting near you"
        }
        return nil
    }

    /// Attach a mappable site. Nearby candidates already carry one; otherwise
    /// fetch the winner’s detail (one query) and choose the closest / most
    /// relevant located site.
    private static func resolve(_ c: Candidate, reason: String?,
                                data: TrialDataService, context: Context) async -> FeaturedTrialPick {
        if let nearby = c.nearby {
            return FeaturedTrialPick(
                trial: c.trial,
                siteLatitude: nearby.site.latitude,
                siteLongitude: nearby.site.longitude,
                siteLabel: nearby.siteLabel,
                distanceMeters: nearby.distanceMeters,
                reason: reason
            )
        }

        var site: TrialLocationInfo?
        var distance: Double?
        if let detail = await data.detail(nctId: c.trial.nctId) {
            let located = detail.locations.filter { $0.coordinate != nil }
            if let user = context.coordinate {
                site = located.min {
                    NearbyDistance.meters(from: user.latitude, lon1: user.longitude,
                                          to: $0.latitude ?? 0, lon2: $0.longitude ?? 0)
                        < NearbyDistance.meters(from: user.latitude, lon1: user.longitude,
                                                to: $1.latitude ?? 0, lon2: $1.longitude ?? 0)
                }
                if let s = site {
                    distance = NearbyDistance.meters(from: user.latitude, lon1: user.longitude,
                                                     to: s.latitude ?? 0, lon2: s.longitude ?? 0)
                }
            } else if let country = context.country ?? context.countryHint {
                site = located.first { $0.country == country } ?? located.first
            } else {
                site = located.first
            }
        }

        var label: String?
        if let site {
            if let facility = site.facilityName, !facility.isEmpty {
                label = site.city.map { "\(facility) · \($0)" } ?? facility
            } else {
                label = site.placeDescription
            }
        }
        return FeaturedTrialPick(
            trial: c.trial,
            siteLatitude: site?.latitude,
            siteLongitude: site?.longitude,
            siteLabel: label,
            distanceMeters: distance,
            reason: reason
        )
    }
}

// MARK: - Daily rotation log

/// Comma-separated `yyyy-MM-dd|NCTxxxxxxxx` entries persisted in AppStorage.
/// Keeps the pick stable within a day and blocks repeats for the last week.
nonisolated struct FeaturedTrialLog {
    private var entries: [(day: String, nctId: String)]

    init(raw: String) {
        entries = raw.split(separator: ",").compactMap { part in
            let bits = part.split(separator: "|", maxSplits: 1)
            guard bits.count == 2 else { return nil }
            return (String(bits[0]), String(bits[1]))
        }
    }

    var raw: String {
        entries.map { "\($0.day)|\($0.nctId)" }.joined(separator: ",")
    }

    static func dayStamp(_ date: Date = Date()) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    var todaysId: String? {
        let today = Self.dayStamp()
        return entries.last(where: { $0.day == today })?.nctId
    }

    /// Ids featured on previous days (today’s pick stays eligible).
    var previousIds: Set<String> {
        let today = Self.dayStamp()
        return Set(entries.filter { $0.day != today }.map(\.nctId))
    }

    mutating func record(nctId: String) {
        let today = Self.dayStamp()
        entries.removeAll { $0.day == today }
        entries.append((today, nctId))
        if entries.count > 8 {
            entries.removeFirst(entries.count - 8)
        }
    }
}

// MARK: - Home Featured (domain photo split card)

struct FeaturedTrialSection: View {
    let pick: FeaturedTrialPick

    private let sceneHeight: CGFloat = 168
    private static let showDistanceMaxMeters = 200 * NearbyDistance.metersPerMile

    var body: some View {
        let condition = pick.trial.primaryCondition
        let assetName = DomainHeroImage.assetName(forCondition: condition)

        VStack(alignment: .leading, spacing: 12) {
            Text("Featured")
                .font(.title2.bold())

            NavigationLink(value: pick.trial.nctId) {
                VStack(alignment: .leading, spacing: 0) {
                    ZStack(alignment: .bottomLeading) {
                        Image(assetName)
                            .resizable()
                            .scaledToFill()
                            .frame(maxWidth: .infinity)
                            .frame(height: sceneHeight)
                            .clipped()

                        LinearGradient(
                            colors: [
                                .black.opacity(0.55),
                                .black.opacity(0.15),
                                .clear
                            ],
                            startPoint: .bottom,
                            endPoint: .top
                        )
                        .allowsHitTesting(false)

                        VStack(alignment: .leading, spacing: 4) {
                            if let reason = pick.reason {
                                Text(reason)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                            }
                            if let condition, !condition.isEmpty {
                                Text(condition)
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.9))
                                    .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                            }
                        }
                        .padding(14)
                    }
                    .frame(height: sceneHeight)
                    .clipped()

                    VStack(alignment: .leading, spacing: 8) {
                        Text(pick.trial.briefTitle)
                            .font(.title3.weight(.bold))
                            .foregroundStyle(.primary)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)

                        StatusBadge(status: pick.trial.statusDisplay)

                        if let footnote {
                            Text(footnote)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemGroupedBackground))
                }
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(.plain)
            .trialWatchlistContextMenu(nctId: pick.trial.nctId)
            .accessibilityLabel(accessibilitySummary)
        }
    }

    private var footnote: String? {
        var parts: [String] = []
        if let label = pick.siteLabel, !label.isEmpty { parts.append(label) }
        if let distance = pick.distanceMeters, distance <= Self.showDistanceMaxMeters {
            parts.append(NearbyDistance.formatMiles(distance))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var accessibilitySummary: String {
        var parts = [pick.trial.briefTitle, pick.trial.statusDisplay]
        if let reason = pick.reason { parts.append(reason) }
        if let footnote { parts.append(footnote) }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Domain stock photo lookup

/// Maps condition → bundled `domain_*_1600x800` asset.
enum DomainHeroImage {
    static let fallbackAsset = "domain_other_1600x800"

    private static let bundledKeys: Set<String> = [
        "oncology", "cardiology", "infectious", "metabolic", "respiratory",
        "neurology", "psychiatry", "musculoskeletal", "immunology", "nephrology",
        "ophthalmology", "reproductive", "hematology", "pediatrics", "dermatology",
        "gastroenterology", "healthy_volunteers", "vaccines", "surgery",
        "rare_disease", "other"
    ]

    static func assetName(forCondition condition: String?) -> String {
        let key = imageKey(forCondition: condition)
        let name = "domain_\(key)_1600x800"
        if UIImage(named: name) != nil { return name }
        return fallbackAsset
    }

    static func imageKey(forCondition condition: String?) -> String {
        guard let condition, !condition.isEmpty else { return "other" }
        if let domain = ConditionDomainCatalog.shared.domain(for: condition) {
            return normalize(domain.name)
        }
        return "other"
    }

    private static func normalize(_ raw: String) -> String {
        let lowered = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let aliases: [String: String] = [
            "oncology": "oncology",
            "cardiology": "cardiology",
            "vascular": "cardiology",
            "infectious disease": "infectious",
            "infectious": "infectious",
            "neurology": "neurology",
            "mental health": "psychiatry",
            "psychiatry": "psychiatry",
            "respiratory": "respiratory",
            "immunology": "immunology",
            "allergy": "immunology",
            "haematology": "hematology",
            "hematology": "hematology",
            "endocrinology": "metabolic",
            "diabetes": "metabolic",
            "metabolic": "metabolic",
            "obesity & weight": "metabolic",
            "obesity and weight": "metabolic",
            "gastroenterology": "gastroenterology",
            "hepatology": "gastroenterology",
            "nephrology": "nephrology",
            "urology": "reproductive",
            "reproductive health": "reproductive",
            "reproductive": "reproductive",
            "pregnancy & maternal health": "reproductive",
            "pregnancy and maternal health": "reproductive",
            "paediatrics": "pediatrics",
            "pediatrics": "pediatrics",
            "ageing & geriatrics": "other",
            "aging & geriatrics": "other",
            "dermatology": "dermatology",
            "ophthalmology": "ophthalmology",
            "ear, nose & throat": "other",
            "musculoskeletal": "musculoskeletal",
            "orthopaedics": "musculoskeletal",
            "orthopedics": "musculoskeletal",
            "rheumatology": "musculoskeletal",
            "pain": "musculoskeletal",
            "genetics": "rare_disease",
            "rare disease": "rare_disease",
            "vaccines": "vaccines",
            "cell & gene therapy": "rare_disease",
            "surgery": "surgery",
            "anaesthesia & critical care": "surgery",
            "anesthesia & critical care": "surgery",
            "healthy volunteers": "healthy_volunteers",
            "healthy_volunteers": "healthy_volunteers",
            "other / unclassified": "other",
            "other": "other"
        ]
        if let mapped = aliases[lowered], bundledKeys.contains(mapped) {
            return mapped
        }
        let slug = lowered
            .replacingOccurrences(of: "&", with: " and ")
            .replacingOccurrences(of: "/", with: " ")
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .joined(separator: "_")
        if bundledKeys.contains(slug) { return slug }
        return "other"
    }
}
