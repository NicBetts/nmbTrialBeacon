//
//  SettingsView.swift
//  nmbTrialBeacon
//

import SwiftUI
import SwiftData
import UIKit

struct SettingsView: View {
    @Environment(TrialDataService.self) private var data
    @Environment(SyncService.self) private var sync
    @Environment(AIMatchingService.self) private var ai
    @Environment(LocationService.self) private var location
    @Environment(BiometricLockService.self) private var biometricLock
    private let router = AppRouter.shared
    @Environment(\.modelContext) private var modelContext
    @Query private var userProfiles: [UserProfile]

    @AppStorage("smartRecommendationsEnabled") private var smartRecommendationsEnabled = true
    @AppStorage("nearbyRadiusMiles") private var nearbyRadiusMiles = LocationService.defaultRadiusMiles
    @AppStorage(BiometricLockService.enabledKey) private var biometricAuthEnabled = false
    @AppStorage("appearanceMode") private var appearanceMode = "system"
    @AppStorage("dateFormat") private var dateFormat = "system"
    @AppStorage(ConditionDomainIcons.enabledKey) private var conditionDomainIconsEnabled = false

    @State private var isSyncing = false
    @State private var isUpdatingBiometricToggle = false
    @State private var showingConditionPicker = false
    @State private var showingCityPicker = false

    @Query(sort: \FavouriteOrganisation.favoritedAt, order: .reverse)
    private var favouriteOrgs: [FavouriteOrganisation]
    @Query(sort: \FavouriteSite.favoritedAt, order: .reverse)
    private var favouriteSites: [FavouriteSite]
    @Query(sort: \RecentlyViewedOrganisation.viewedAt, order: .reverse)
    private var recentlyViewedOrgs: [RecentlyViewedOrganisation]
    @Query(sort: \RecentlyViewedSite.viewedAt, order: .reverse)
    private var recentlyViewedSites: [RecentlyViewedSite]

    private var favouriteCount: Int { favouriteOrgs.count + favouriteSites.count }
    private var recentlyViewedCount: Int { recentlyViewedOrgs.count + recentlyViewedSites.count }

    /// Intercepts the toggle so enabling requires a successful device authentication.
    private var biometricToggleBinding: Binding<Bool> {
        Binding(
            get: { biometricAuthEnabled },
            set: { newValue in
                guard !isUpdatingBiometricToggle else { return }
                isUpdatingBiometricToggle = true
                Task { @MainActor in
                    let applied = await biometricLock.applyEnabled(newValue)
                    biometricAuthEnabled = applied
                    isUpdatingBiometricToggle = false
                }
            }
        )
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                Form {
                    profileSection
                    nearbySection
                    if !favouriteOrgs.isEmpty || !favouriteSites.isEmpty {
                        favouritesSection
                    }
                    privacySecuritySection
                    appearanceSection
                    betaTestingSection
                    dataSection
                    aboutSection
                }
                .navigationTitle("Settings")
                .scrollEdgeEffectStyle(.soft, for: .top)
                .scrollEdgeEffectStyle(.soft, for: .bottom)
                .onAppear {
                    biometricLock.refreshAvailability()
                    ensureProfileExists()
                    consumeFocus(proxy)
                }
                .onChange(of: router.settingsFocus) { _, _ in consumeFocus(proxy) }
                .sheet(isPresented: $showingConditionPicker) {
                    if let profile = userProfiles.first {
                        ConditionPickerView(profile: profile, availableConditions: data.conditions)
                    }
                }
                .sheet(isPresented: $showingCityPicker) {
                    NearbyPlacePicker { place in
                        applyPreferredCity(place)
                    }
                }
            }
        }
    }

    // MARK: - Sections

    private var profileSection: some View {
        Section {
            Toggle("Personalized Recommendations", isOn: $smartRecommendationsEnabled)
            if smartRecommendationsEnabled, let profile = userProfiles.first {
                DemographicsSection(profile: profile,
                                    ageRanges: data.ageRanges,
                                    genders: data.genders,
                                    countries: data.countries)
                ConditionsOfInterestSection(profile: profile,
                                            onAddCondition: { showingConditionPicker = true },
                                            onRemoveCondition: removeCondition)
            }
        } header: {
            Text("Your Profile")
        } footer: {
            Text("Personalize Home suggestions. Age, sex, country and conditions stay on this device.")
        }
        .id(Self.profileAnchor)
    }

    private var nearbySection: some View {
        Section {
            if let profile = userProfiles.first {
                Button {
                    showingCityPicker = true
                } label: {
                    LabeledContent("Preferred city") {
                        Text(profile.hasPreferredCityCoordinate
                             ? (profile.preferredCity ?? "Set")
                             : "Near me")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .foregroundStyle(.primary)

                if profile.hasPreferredCityCoordinate {
                    Button("Use Near Me instead", role: .destructive) {
                        clearPreferredCity()
                    }
                }
            }

            if location.canRequestAuthorization {
                Button("Allow Location Access") {
                    location.prepare()
                }
            } else if location.isDenied {
                Button("Open Settings to Enable Location") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
            } else if location.isAuthorized {
                Label("Location access on", systemImage: "location.fill")
                    .foregroundStyle(.secondary)
            }

            Picker("Search radius", selection: $nearbyRadiusMiles) {
                ForEach(LocationService.radiusChoicesMiles, id: \.self) { miles in
                    Text("\(miles) miles").tag(miles)
                }
            }
        } header: {
            Text("Nearby Studies")
        } footer: {
            Text("Preferred city anchors Discover Recruiting and Nearby. Without a city, Near Me uses your device location. Home’s Recruiting Near You still needs location access.")
        }
    }

    private var favouritesSection: some View {
        Section {
            if favouriteCount > 4 {
                NavigationLink {
                    SettingsFavouritesListView()
                } label: {
                    Label("\(favouriteCount) favourites", systemImage: "star.fill")
                }
            } else {
                ForEach(favouriteOrgs) { row in
                    if let ref = row.ref {
                        NavigationLink {
                            OrganisationDetailView(ref: ref)
                        } label: {
                            Label(row.displayName, systemImage: "building.2")
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button("Remove", role: .destructive) {
                                modelContext.delete(row)
                                try? modelContext.save()
                            }
                        }
                    }
                }
                ForEach(favouriteSites) { row in
                    if let ref = row.ref {
                        NavigationLink {
                            SiteDetailView(ref: ref)
                        } label: {
                            Label(row.displayName, systemImage: "mappin.and.ellipse")
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button("Remove", role: .destructive) {
                                modelContext.delete(row)
                                try? modelContext.save()
                            }
                        }
                    }
                }
            }
        } header: {
            Text("Favourites")
        } footer: {
            Text("Starred organisations and sites from Discover. Separate from your trial Watchlist.")
        }
    }

    private var privacySecuritySection: some View {
        Section {
            Toggle(isOn: biometricToggleBinding) {
                Label(
                    biometricLock.settingsToggleLabel,
                    systemImage: biometricLock.settingsToggleSymbol
                )
            }
            .disabled(!biometricLock.canUseDeviceAuthentication || isUpdatingBiometricToggle)

            NavigationLink {
                SettingsPrivacyView()
            } label: {
                Label("Privacy", systemImage: "hand.raised.fill")
            }
        } header: {
            Text("Privacy & Security")
        } footer: {
            Text("Off by default. When enabled, Face ID, Touch ID, or your device passcode is required to open the app. You can also change this in iPhone Settings → TrialBeacon.")
        }
    }

    private var appearanceSection: some View {
        Section("Appearance") {
            Picker("Theme", selection: $appearanceMode) {
                Label("System", systemImage: "circle.lefthalf.filled").tag("system")
                Label("Light", systemImage: "sun.max").tag("light")
                Label("Dark", systemImage: "moon").tag("dark")
            }
            .pickerStyle(.navigationLink)
            Picker("Date Format", selection: $dateFormat) {
                Text("System").tag("system")
                Text("US (MM/DD/YYYY)").tag("us")
                Text("European (DD/MM/YYYY)").tag("european")
                Text("ISO (YYYY-MM-DD)").tag("iso")
            }
        }
    }

    private var betaTestingSection: some View {
        Section {
            Toggle(isOn: $conditionDomainIconsEnabled) {
                Label("Condition domain icons", systemImage: "cross.case")
            }
            if conditionDomainIconsEnabled {
                NavigationLink {
                    ConditionDomainPreviewView()
                } label: {
                    Label("Preview domain icons", systemImage: "square.grid.2x2")
                }
            }
        } header: {
            Text("Beta Testing")
        } footer: {
            Text("Shows a small SF Symbol next to conditions, based on a medical-domain mapping. Off by default while we evaluate the look.")
        }
    }

    private var dataSection: some View {
        Section {
            Button(action: performSync) {
                HStack {
                    Label {
                        Text(isSyncing ? "Checking…" : "Check for Updates")
                    } icon: {
                        if isSyncing {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    Spacer(minLength: 0)
                    if let last = sync.lastSyncDate {
                        Text(last.formatted(date: .abbreviated, time: .omitted))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .disabled(isSyncing)

            NavigationLink {
                SettingsDataView()
            } label: {
                Label("Catalog & methodology", systemImage: "cylinder.split.1x2")
            }

            if recentlyViewedCount > 0 {
                Button("Clear Recently Viewed", role: .destructive) {
                    RecentlyViewed.clearAll(context: modelContext)
                }
            }
        } header: {
            Text("Data")
        } footer: {
            Text("The trials catalog ships with the app and refreshes through App Store updates. Catalog & methodology covers source attribution, how the snapshot is prepared, and database details.")
        }
    }

    private var aboutSection: some View {
        Section {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("About TrialBeacon")
                        .font(.headline)
                    Text("Discover and track clinical trials from ClinicalTrials.gov — search, watchlist and notes stay on your device.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(versionLabel)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("Nic Betts")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image("AppLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Imagery")
                    .font(.subheadline.weight(.semibold))
                Text("Condition scenes are AI-generated originals. Commercial use permitted.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)

            Link(destination: ClinicalTrialsAttribution.clinicalTrialsURL) {
                Label("ClinicalTrials.gov", systemImage: "link")
            }
        }
    }

    private var versionLabel: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        if let build, build != short {
            return "Version \(short) (\(build))"
        }
        return "Version \(short)"
    }

    // MARK: - Helpers

    private static let profileAnchor = "profile"

    /// Another tab can send the user here to finish setting up their profile.
    /// The section is the first one in the form, so this mostly matters when
    /// Settings was already scrolled elsewhere.
    private func consumeFocus(_ proxy: ScrollViewProxy) {
        guard router.settingsFocus == .profile else { return }
        router.settingsFocus = nil
        smartRecommendationsEnabled = true
        withAnimation(.smooth) {
            proxy.scrollTo(Self.profileAnchor, anchor: .top)
        }
    }

    /// The profile row is created here rather than lazily from the view body —
    /// inserting into the context while rendering would invalidate the query
    /// that is driving the render.
    private func ensureProfileExists() {
        guard userProfiles.isEmpty else { return }
        modelContext.insert(UserProfile())
        try? modelContext.save()
    }

    private func applyPreferredCity(_ place: NearbyAnchor) {
        ensureProfileExists()
        guard let profile = userProfiles.first else { return }
        profile.preferredCity = place.label
        profile.preferredCityLatitude = place.latitude
        profile.preferredCityLongitude = place.longitude
        try? modelContext.save()
    }

    private func clearPreferredCity() {
        guard let profile = userProfiles.first else { return }
        profile.preferredCity = nil
        profile.preferredCityLatitude = nil
        profile.preferredCityLongitude = nil
        try? modelContext.save()
    }

    private func removeCondition(_ condition: UserCondition) {
        modelContext.delete(condition)
        try? modelContext.save()
        ai.invalidateRecommendationsCache()
    }

    private func performSync() {
        Task {
            isSyncing = true
            defer { isSyncing = false }
            try? await sync.performSync()
        }
    }
}

// MARK: - Privacy (single destination)

private struct SettingsPrivacyView: View {
    var body: some View {
        List {
            Section {
                Text("TrialBeacon keeps health-related preferences on your device. Profile choices, watchlist membership and notes are not uploaded to a TrialBeacon server.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }

            Section("On this device") {
                PrivacyInfoRow(icon: "lock.shield", title: "Local storage only",
                               description: "Your profile and watchlist never leave this device")
                PrivacyInfoRow(icon: "lock.fill", title: "Optional app lock",
                               description: "Face ID, Touch ID, or passcode before opening the app — also available in iPhone Settings → TrialBeacon")
                PrivacyInfoRow(icon: "brain", title: "On-device matching",
                               description: "Recommendations are computed on your phone")
                PrivacyInfoRow(icon: "eye.slash", title: "No tracking",
                               description: "No personal health information is collected")
                PrivacyInfoRow(icon: "person.crop.circle", title: "Profile",
                               description: "Age range, sex, country and conditions of interest")
                PrivacyInfoRow(icon: "bookmark.fill", title: "Watchlist & notes",
                               description: "Trials you save and any notes you attach")
                PrivacyInfoRow(icon: "sparkles", title: "On-device AI",
                               description: "Plain-language and smart-search features run locally when available")
            }

            Section("Public catalog") {
                Text("The clinical-trials catalog is a read-only database bundled with the app. Opening a trial’s external link leaves the app and uses ClinicalTrials.gov’s own privacy practices.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                Text(ClinicalTrialsAttribution.cautionLine)
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
        .scrollEdgeEffectStyle(.soft, for: .top)
    }
}

// MARK: - Data (single destination: attribution, methodology, catalog)

private struct SettingsDataView: View {
    @Environment(TrialDataService.self) private var data

    var body: some View {
        List {
            Section {
                ClinicalTrialsAttributionBlock()
            } header: {
                Text("Source")
            }

            Section {
                Text("ClinicalTrials.gov is the source of study records. Sponsors and investigators submit those facts; TrialBeacon does not replace them.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                Text("The app ships a curated offline snapshot of the public catalog so you can search and explore without a network connection. Always open the current ClinicalTrials.gov record for the latest study status and contacts.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            } header: {
                Text("How the catalog is prepared")
            }

            Section("Catalog") {
                LabeledContent("Source", value: data.stats?.source ?? "ClinicalTrials.gov (bundled)")
                LabeledContent("Total trials", value: data.totalTrials.formatted())
                if let snapshot = data.stats?.sourceSnapshotDate {
                    LabeledContent("Snapshot", value: snapshot.formatted(date: .abbreviated, time: .omitted))
                }
                if let built = data.stats?.createdAt {
                    LabeledContent("Built", value: built.formatted(date: .abbreviated, time: .omitted))
                }
                if let days = data.dataAgeDays {
                    LabeledContent("Age", value: "\(days) day\(days == 1 ? "" : "s")")
                }
                if let schema = data.stats?.schemaVersion, schema > 0 {
                    LabeledContent("Schema", value: "v\(schema)")
                }
                if let cap = data.capabilityReport {
                    LabeledContent("File", value: "\(cap.databaseFileName) · \(cap.fileSizeLabel)")
                }
            }

            Link(destination: ClinicalTrialsAttribution.clinicalTrialsURL) {
                Label("Open ClinicalTrials.gov", systemImage: "link")
            }
        }
        .navigationTitle("Catalog & methodology")
        .navigationBarTitleDisplayMode(.inline)
        .scrollEdgeEffectStyle(.soft, for: .top)
    }
}
