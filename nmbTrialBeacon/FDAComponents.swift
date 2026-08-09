//
//  FDAComponents.swift
//  nmbTrialBeacon
//
//  Drugs@FDA indicators and sheets for Trial Detail (schema v13).
//  Content uses the same grouped SectionCard surface as the rest of Trial Detail;
//  Liquid Glass stays on chrome (toolbar / presentation), not content cards.
//  Match ≠ indication approval. Wording follows IOS_CHANGES_schema_v13.md.
//

import SwiftUI

// MARK: - Indicator

struct FDAIndicator: View {
    let interventionName: String

    var body: some View {
        Text("FDA")
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.blue.opacity(0.14), in: Capsule())
            .foregroundStyle(.blue)
            .accessibilityHidden(true)
    }
}

// MARK: - Multi-match picker

struct FDAIngredientListSheet: View {
    let interventionName: String
    let ingredients: [TrialFDAIngredient]
    var onSelect: (TrialFDAIngredient) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("This intervention matches more than one Drugs@FDA ingredient. Choose one to view product and application details.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(ingredients.enumerated()), id: \.element.id) { index, ingredient in
                            Button {
                                onSelect(ingredient)
                            } label: {
                                HStack(alignment: .top, spacing: 10) {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(ingredient.canonicalIngredient)
                                            .font(.body.weight(.semibold))
                                            .foregroundStyle(.primary)
                                            .multilineTextAlignment(.leading)
                                        if let date = ingredient.firstKnownApprovalDate {
                                            Text(FDACopy.firstKnownApproval(date: date))
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .multilineTextAlignment(.leading)
                                        }
                                    }
                                    Spacer(minLength: 8)
                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.tertiary)
                                        .padding(.top, 4)
                                }
                                .padding(.vertical, 12)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            if index < ingredients.count - 1 {
                                Divider()
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .background(
                        Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                    )
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(interventionName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(.regularMaterial)
    }
}

// MARK: - Ingredient detail sheet

struct FDAIngredientSheet: View {
    let ingredient: TrialFDAIngredient
    /// Shown in the nav title when opened from an intervention row.
    var interventionName: String?

    @Environment(TrialDataService.self) private var data
    @Environment(\.dismiss) private var dismiss

    @State private var brands: [FDABrand] = []
    @State private var applications: [FDAApplication] = []
    @State private var products: [FDAProduct] = []
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    FDASheetCard(title: "Ingredient", icon: "pills") {
                        FDASheetRow(label: "Active ingredient", value: ingredient.canonicalIngredient)
                        if !brands.isEmpty {
                            FDASheetRow(
                                label: "Brand names",
                                value: brands.map(\.brandName).joined(separator: ", "))
                        }
                        if let date = ingredient.firstKnownApprovalDate {
                            FDASheetRow(
                                label: "First known approval",
                                value: date.formattedWithUserPreference(),
                                footnote: FDACopy.firstKnownApprovalFootnote(
                                    scope: ingredient.approvalDateScope))
                        } else {
                            FDASheetRow(
                                label: "First known approval",
                                value: "Not available in Drugs@FDA for this ingredient",
                                valueIsSecondary: true)
                        }
                        if !ingredient.originalIntervention.isEmpty,
                           ingredient.originalIntervention != ingredient.canonicalIngredient {
                            FDASheetRow(
                                label: "Matched intervention",
                                value: ingredient.originalIntervention)
                        }
                    }

                    if !applications.isEmpty {
                        FDASheetCard(title: "Applications", icon: "doc.text") {
                            ForEach(Array(applications.enumerated()), id: \.element.id) { index, app in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(app.typeAndNumberLabel)
                                        .font(.callout.weight(.semibold))
                                    if let sponsor = app.sponsorName, !sponsor.isEmpty {
                                        Text(sponsor)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    if let date = app.approvalDate {
                                        Text("Approved \(date.formattedWithUserPreference())")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    if let status = app.marketingStatus, !status.isEmpty {
                                        Text(status)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.vertical, 4)
                                if index < applications.count - 1 {
                                    Divider().padding(.vertical, 6)
                                }
                            }
                        }
                    }

                    if !products.isEmpty {
                        FDASheetCard(title: "Products", icon: "cross.case") {
                            ForEach(Array(products.enumerated()), id: \.element.id) { index, product in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(product.drugName?.nilIfEmpty ?? "Product \(product.productNumber)")
                                        .font(.callout.weight(.semibold))
                                    let meta = productMeta(product)
                                    if !meta.isEmpty {
                                        Text(meta)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    if let status = product.marketingStatus, !status.isEmpty {
                                        Text(status)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    let flags = productFlags(product)
                                    if !flags.isEmpty {
                                        Text(flags)
                                            .font(.caption2.weight(.medium))
                                            .foregroundStyle(.blue)
                                    }
                                }
                                .padding(.vertical, 4)
                                if index < products.count - 1 {
                                    Divider().padding(.vertical, 6)
                                }
                            }
                        }
                    }

                    FDASheetCard(title: "About this information", icon: "info.circle") {
                        Text("Drugs@FDA contains product and application information associated with this ingredient. The exact use, dose, route, combination or indication in this study may remain investigational.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text("No Drugs@FDA match does not mean that an intervention is not approved.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                    }
                }
                .padding(16)
                .opacity(isLoading ? 0.35 : 1)
                .overlay {
                    if isLoading {
                        ProgressView()
                            .controlSize(.large)
                    }
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(interventionName ?? ingredient.canonicalIngredient)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .task(id: ingredient.fdaDrugID) {
                await loadChildren()
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(.regularMaterial)
    }

    private func productMeta(_ product: FDAProduct) -> String {
        [product.dosageForm, product.strength]
            .compactMap { $0?.nilIfEmpty }
            .joined(separator: " · ")
    }

    private func productFlags(_ product: FDAProduct) -> String {
        var parts: [String] = []
        if product.isReferenceDrug == true { parts.append("Reference drug") }
        if product.isReferenceStandard == true { parts.append("Reference standard") }
        return parts.joined(separator: " · ")
    }

    private func loadChildren() async {
        isLoading = true
        defer { isLoading = false }
        async let b = data.fdaBrands(fdaDrugId: ingredient.fdaDrugID)
        async let a = data.fdaApplications(fdaDrugId: ingredient.fdaDrugID)
        async let p = data.fdaProducts(fdaDrugId: ingredient.fdaDrugID)
        brands = await b
        applications = await a
        products = await p
    }
}

// MARK: - Sheet chrome (matches Trial Detail SectionCard)

private struct FDASheetCard<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(.title3.bold())
                .labelStyle(FDASheetTitleLabelStyle())

            VStack(alignment: .leading, spacing: 10) { content }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
        }
    }
}

private struct FDASheetTitleLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon
                .foregroundStyle(.blue)
                .symbolRenderingMode(.hierarchical)
            configuration.title
        }
    }
}

private struct FDASheetRow: View {
    let label: String
    let value: String
    var footnote: String? = nil
    var valueIsSecondary: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout)
                .foregroundStyle(valueIsSecondary ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
            if let footnote {
                Text(footnote)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private enum FDACopy {
    static func firstKnownApproval(date: Date) -> String {
        "First known Drugs@FDA approval associated with this ingredient: \(date.formattedWithUserPreference())"
    }

    static func firstKnownApprovalFootnote(scope: String) -> String {
        if scope == "ingredient" {
            return "Earliest original (ORIG/AP) approval linked to this ingredient in Drugs@FDA — not a claim of approval for this trial’s indication."
        }
        return "From Drugs@FDA. Coverage is incomplete; absence of a date does not mean unapproved."
    }
}

private extension String {
    var nilIfEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
