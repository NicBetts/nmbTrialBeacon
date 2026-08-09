//
//  FDAModels.swift
//  nmbTrialBeacon
//
//  Schema v13: Drugs@FDA identity matches for trial interventions.
//  A match is product/application metadata linked to an intervention name —
//  not a claim that the trial’s indication is FDA-approved.
//

import Foundation

struct TrialFDAIngredient: Identifiable, Sendable, Hashable {
    let fdaDrugID: Int64
    let canonicalIngredient: String
    /// Exact intervention display string from the trial (match key).
    let originalIntervention: String
    let firstKnownApprovalDate: Date?
    let approvalDateScope: String
    let matchMethod: String

    var id: String { "\(fdaDrugID)|\(originalIntervention)" }
}

struct FDABrand: Identifiable, Sendable, Hashable {
    let brandName: String
    var id: String { brandName }
}

struct FDAApplication: Identifiable, Sendable, Hashable {
    let applicationNumber: String
    let applicationType: String
    let sponsorName: String?
    let approvalDate: Date?
    let marketingStatus: String?

    var id: String { applicationNumber }

    var typeAndNumberLabel: String {
        let type = applicationType.trimmingCharacters(in: .whitespacesAndNewlines)
        if type.isEmpty { return applicationNumber }
        return "\(type) \(applicationNumber)"
    }
}

struct FDAProduct: Identifiable, Sendable, Hashable {
    let applicationNumber: String
    let productNumber: String
    let drugName: String?
    let dosageForm: String?
    let strength: String?
    let marketingStatus: String?
    let isReferenceDrug: Bool?
    let isReferenceStandard: Bool?

    var id: String { "\(applicationNumber)|\(productNumber)" }
}
