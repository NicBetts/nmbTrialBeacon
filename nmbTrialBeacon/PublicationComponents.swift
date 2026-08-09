//
//  PublicationComponents.swift
//  nmbTrialBeacon
//
//  Trial Detail publications (schema v13). Matches SectionCard chrome used on
//  Trial Detail — grouped surface, not Liquid Glass content cards.
//

import SwiftUI

// MARK: - Section

struct PublicationSection: View {
    let publications: [TrialPublication]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Publications", systemImage: "doc.richtext")
                .font(.title2.bold())
                .labelStyle(TrialDetailSectionTitleLabelStyle())

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(publications.enumerated()), id: \.element.id) { index, pub in
                    PublicationRow(publication: pub)
                    if index < publications.count - 1 {
                        Divider().padding(.vertical, 10)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color(.secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
        }
    }
}

// MARK: - Row

struct PublicationRow: View {
    let publication: TrialPublication
    /// Org Profile lists distinct papers (no CTG reference type) — hide the chip.
    var showsReferenceType: Bool = true
    @Environment(\.openURL) private var openURL
    @State private var showingRetractionInfo = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if publication.showsRetractionWarning {
                RetractionWarningView {
                    showingRetractionInfo = true
                }
            }

            Group {
                if let url = publication.bestExternalURL {
                    Button {
                        openURL(url)
                    } label: {
                        rowContent(showsChevron: true)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(.isLink)
                } else {
                    rowContent(showsChevron: false)
                }
            }
        }
        .alert("Retracted publication", isPresented: $showingRetractionInfo) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("ClinicalTrials.gov links this reference to one or more retraction notices. TrialBeacon does not interpret why it was retracted.")
        }
    }

    @ViewBuilder
    private func rowContent(showsChevron: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                if publication.isCitationOnly && (publication.title == nil || publication.title?.isEmpty == true) {
                    Text("ClinicalTrials.gov reference")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                Text(publication.displayTitle)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                metaLine

                if showsReferenceType || publication.isOpenAccess == true {
                    HStack(spacing: 8) {
                        if showsReferenceType, !publication.referenceType.isEmpty {
                            Text(publication.referenceTypeDisplay)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.blue.opacity(0.12), in: Capsule())
                                .foregroundStyle(.blue)
                        }

                        if publication.isOpenAccess == true {
                            OpenAccessBadge()
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if showsChevron {
                Image(systemName: "arrow.up.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var metaLine: some View {
        let parts = metaParts
        if !parts.isEmpty {
            Text(parts.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var metaParts: [String] {
        var parts: [String] = []
        if let journal = publication.journalName, !journal.isEmpty {
            parts.append(journal)
        }
        if let date = publication.publicationDate {
            parts.append(date.formattedWithUserPreference())
        } else if let year = publication.publicationYear {
            parts.append(String(year))
        }
        return parts
    }

    private var accessibilityLabel: String {
        var bits = [publication.displayTitle]
        if showsReferenceType, !publication.referenceType.isEmpty {
            bits.append(publication.referenceTypeDisplay)
        }
        if publication.isOpenAccess == true { bits.append("Open access") }
        if publication.showsRetractionWarning { bits.append("Retracted publication") }
        if publication.bestExternalURL != nil { bits.append("Opens in browser") }
        return bits.joined(separator: ", ")
    }
}

// MARK: - Badges / warnings

struct OpenAccessBadge: View {
    var body: some View {
        Label("Open access", systemImage: "lock.open.fill")
            .font(.caption.weight(.semibold))
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.secondary.opacity(0.12), in: Capsule())
            .foregroundStyle(.secondary)
            .accessibilityLabel("Open access")
    }
}

struct RetractionWarningView: View {
    var onInfo: () -> Void

    var body: some View {
        Button(action: onInfo) {
            Label("Retracted publication", systemImage: "exclamationmark.triangle.fill")
                .font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .foregroundStyle(.orange)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Shows an explanation about retraction notices")
    }
}

/// Shared with FDAComponents / PublicationSection — mirrors Trial Detail section titles.
struct TrialDetailSectionTitleLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon
                .foregroundStyle(.blue)
                .symbolRenderingMode(.hierarchical)
            configuration.title
        }
    }
}
