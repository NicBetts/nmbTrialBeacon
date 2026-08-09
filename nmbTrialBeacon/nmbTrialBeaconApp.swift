//
//  nmbTrialBeaconApp.swift
//  nmbTrialBeacon
//
//  Created by Nic Betts on 7/20/25.
//  Rewritten for the read-only bundled-SQLite architecture.
//

import SwiftUI
import SwiftData

@main
struct nmbTrialBeaconApp: App {
    @State private var data = TrialDataService.shared
    @State private var sync = SyncService.shared
    @State private var ai = AIMatchingService.shared
    @State private var location = LocationService.shared
    @State private var biometricLock = BiometricLockService.shared

    @AppStorage("appearanceMode") private var appearanceMode = "system"
    @Environment(\.scenePhase) private var scenePhase

    /// Small, user-owned SwiftData store. The clinical-trials dataset is NOT
    /// here — it lives in the read-only bundled `trialbeacon.sqlite`.
    private let userContainer: ModelContainer = {
        // Must happen before the store is opened: compaction rewrites the file.
        LegacyStoreCleanup.runIfNeeded()

        let schema = Schema([
            WatchlistItem.self,
            UserProfile.self,
            UserCondition.self,
            RecentlyViewedOrganisation.self,
            RecentlyViewedSite.self,
            FavouriteOrganisation.self,
            FavouriteSite.self,
            SavedSearch.self,
            SyncMetadata.self
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false, cloudKitDatabase: .none)
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("Could not create user ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(data)
                .environment(sync)
                .environment(ai)
                .environment(location)
                .environment(biometricLock)
                .preferredColorScheme(preferredScheme)
                .task {
                    sync.configure(container: userContainer)
                    ai.configure(store: data.store)
                    await data.start()
                }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        TrialAIService.shared.refreshReadiness()
                        biometricLock.handleBecameActive()
                    case .background:
                        biometricLock.handleEnteredBackground()
                    default:
                        break
                    }
                }
        }
        .modelContainer(userContainer)
    }

    private var preferredScheme: ColorScheme? {
        switch appearanceMode {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }
}

// MARK: - Root gating view

struct RootView: View {
    @Environment(TrialDataService.self) private var data
    @Environment(BiometricLockService.self) private var biometricLock
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    /// Open is usually instant; only show the brand gate if it takes a beat.
    @State private var showLoadingChrome = false

    var body: some View {
        ZStack {
            // When locked, do not mount main UI (avoids flashing watchlist / profile).
            if biometricLock.needsUnlock {
                BiometricLockView()
                    .transition(.opacity)
            } else {
                switch data.status {
                case .loading:
                    if showLoadingChrome {
                        LaunchScreenView(state: .loading)
                            .transition(.opacity)
                    } else {
                        // System launch screen covers the first paint; stay quiet
                        // until we know open is actually slow.
                        Color(.systemGroupedBackground).ignoresSafeArea()
                    }
                case .failed(let message):
                    LaunchScreenView(state: .failed(message))
                case .ready:
                    // Onboarding waits for the database so it can offer real
                    // condition names and a real trial count.
                    if hasCompletedOnboarding {
                        MainTabView()
                    } else {
                        OnboardingView()
                            .transition(.opacity)
                    }
                }
            }
        }
        .animation(.smooth(duration: 0.35), value: data.status)
        .animation(.smooth(duration: 0.35), value: hasCompletedOnboarding)
        .animation(.smooth(duration: 0.25), value: showLoadingChrome)
        .animation(.smooth(duration: 0.25), value: biometricLock.needsUnlock)
        .task(id: data.status) {
            guard case .loading = data.status else {
                showLoadingChrome = false
                return
            }
            showLoadingChrome = false
            try? await Task.sleep(for: .milliseconds(300))
            if case .loading = data.status {
                showLoadingChrome = true
            }
        }
    }
}

// MARK: - Biometric lock cover (mirrors LaunchScreenView chrome)

struct BiometricLockView: View {
    @Environment(BiometricLockService.self) private var lock
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            VStack(spacing: 16) {
                Group {
                    if let icon = UIImage(named: "AppIcon") {
                        Image(uiImage: icon).resizable().aspectRatio(contentMode: .fit)
                    } else {
                        Image(systemName: "cross.case.circle.fill")
                            .font(.system(size: 72))
                            .foregroundStyle(.blue.gradient)
                    }
                }
                .frame(width: 84, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: .black.opacity(0.12), radius: 10, y: 5)

                Text("TrialBeacon")
                    .font(.largeTitle.bold())

                Text("Unlock to continue.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Spacer()

            VStack(spacing: 14) {
                if lock.isAuthenticating {
                    ProgressView()
                        .controlSize(.large)
                } else {
                    Button {
                        Task { await lock.authenticate() }
                    } label: {
                        Text(lock.unlockButtonTitle)
                            .frame(maxWidth: 280)
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(!lock.canUseDeviceAuthentication)
                }

                if let message = lock.lastErrorMessage, !message.isEmpty {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
            }

            Spacer()

            Text("Privacy-first clinical trial discovery")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .background(Color(.systemGroupedBackground))
        // Prompt only while active — avoids Face ID while backgrounded for the app switcher.
        .task(id: "\(lock.needsUnlock)-\(scenePhase)") {
            guard lock.needsUnlock, scenePhase == .active, !lock.isAuthenticating else { return }
            await lock.authenticate()
        }
    }
}

// MARK: - Launch / error screen

struct LaunchScreenView: View {
    enum State {
        case loading
        case failed(String)
    }

    let state: State

    private var isLoading: Bool {
        if case .loading = state { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            VStack(spacing: 16) {
                Group {
                    if let icon = UIImage(named: "AppIcon") {
                        Image(uiImage: icon).resizable().aspectRatio(contentMode: .fit)
                    } else {
                        Image(systemName: "cross.case.circle.fill")
                            .font(.system(size: 72))
                            .foregroundStyle(.blue.gradient)
                            .symbolEffect(.breathe, isActive: isLoading)
                    }
                }
                .frame(width: 84, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: .black.opacity(0.12), radius: 10, y: 5)

                Text("TrialBeacon")
                    .font(.largeTitle.bold())

                Text("Shining a light on your path to clinical research.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Spacer()

            switch state {
            case .loading:
                VStack(spacing: 12) {
                    ProgressView().controlSize(.large)
                    Text("Opening trials database…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            case .failed(let message):
                VStack(spacing: 14) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.orange)
                    Text("Database Unavailable")
                        .font(.headline)
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
            }

            Spacer()

            Text("Privacy-first clinical trial discovery")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .background(Color(.systemGroupedBackground))
    }
}
