//
//  LocationService.swift
//  nmbTrialBeacon
//
//  When-in-use location for “Recruiting Near You”. Permission is requested
//  from Home (not from a LazyVStack placeholder — those never lay out).
//

import CoreLocation
import Foundation
import MapKit

@MainActor
@Observable
final class LocationService: NSObject {
    static let shared = LocationService()

    /// Default search radius (miles). Mirrored by `@AppStorage("nearbyRadiusMiles")`.
    static let defaultRadiusMiles = 50
    static let radiusChoicesMiles = [10, 25, 50, 100, 200]

    private let manager = CLLocationManager()
    private var geocodeTask: Task<Void, Never>?
    private var stopUpdatesTask: Task<Void, Never>?

    private(set) var authorizationStatus: CLAuthorizationStatus
    private(set) var coordinate: CLLocationCoordinate2D?
    /// Registry-style country name from reverse geocode (e.g. "United States"), when known.
    private(set) var countryName: String?
    /// Local place label from reverse geocode (e.g. "Boston, Massachusetts"), when known.
    private(set) var placeLabel: String?
    private(set) var isLocating = false

    var isAuthorized: Bool {
        switch authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: return true
        default: return false
        }
    }

    /// `true` when the system dialog can still be shown.
    var canRequestAuthorization: Bool {
        authorizationStatus == .notDetermined
    }

    /// Previously denied — user must flip the switch in Settings.
    var isDenied: Bool {
        switch authorizationStatus {
        case .denied, .restricted: return true
        default: return false
        }
    }

    private override init() {
        authorizationStatus = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        if isAuthorized, let existing = manager.location {
            coordinate = existing.coordinate
        }
    }

    /// Ask for when-in-use if still undetermined; otherwise refresh the fix.
    func prepare() {
        authorizationStatus = manager.authorizationStatus
        switch authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            requestFix()
        default:
            break
        }
    }

    func requestFix() {
        guard isAuthorized else { return }
        isLocating = true

        if let existing = manager.location {
            apply(existing)
        }

        // `requestLocation()` often fails on Simulator with “location unknown”
        // if Features → Location isn’t set. Continuous updates are more reliable;
        // we stop them shortly after the first good fix.
        manager.startUpdatingLocation()
        manager.requestLocation()

        stopUpdatesTask?.cancel()
        stopUpdatesTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            await MainActor.run {
                self?.manager.stopUpdatingLocation()
                self?.isLocating = false
            }
        }
    }

    private func apply(_ location: CLLocation) {
        coordinate = location.coordinate
        isLocating = false
        reverseGeocode(location)
        manager.stopUpdatingLocation()
        stopUpdatesTask?.cancel()
    }

    private func reverseGeocode(_ location: CLLocation) {
        geocodeTask?.cancel()
        geocodeTask = Task { [weak self] in
            guard let request = MKReverseGeocodingRequest(location: location) else { return }
            guard let item = try? await request.mapItems.first else { return }
            guard !Task.isCancelled else { return }

            let name: String?
            if let region = item.addressRepresentations?.region {
                name = Locale.current.localizedString(forRegionCode: region.identifier) ?? region.identifier
            } else {
                name = item.addressRepresentations?.regionName
            }

            let place = item.addressRepresentations?.cityWithContext
                ?? item.addressRepresentations?.cityName

            await MainActor.run {
                self?.countryName = name
                self?.placeLabel = place
            }
        }
    }
}

extension LocationService: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            authorizationStatus = manager.authorizationStatus
            if isAuthorized {
                requestFix()
            } else {
                coordinate = nil
                countryName = nil
                placeLabel = nil
                isLocating = false
                manager.stopUpdatingLocation()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            guard let location = locations.last else { return }
            apply(location)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            // Keep listening via startUpdatingLocation; only clear the spinner
            // if we never got a coordinate.
            if coordinate == nil {
                isLocating = manager.authorizationStatus == .authorizedWhenInUse
                    || manager.authorizationStatus == .authorizedAlways
            } else {
                isLocating = false
            }
        }
    }
}

/// Pure geo helpers — `nonisolated` so `TrialStore` (background actor) can call them.
enum NearbyDistance: Sendable {
    nonisolated static let metersPerMile = 1609.344

    nonisolated static func meters(from lat1: Double, lon1: Double, to lat2: Double, lon2: Double) -> Double {
        let r = 6_371_000.0
        let p1 = lat1 * .pi / 180
        let p2 = lat2 * .pi / 180
        let dPhi = (lat2 - lat1) * .pi / 180
        let dLambda = (lon2 - lon1) * .pi / 180
        let a = sin(dPhi / 2) * sin(dPhi / 2)
            + cos(p1) * cos(p2) * sin(dLambda / 2) * sin(dLambda / 2)
        return 2 * r * asin(min(1, sqrt(a)))
    }

    nonisolated static func formatMiles(_ meters: Double) -> String {
        let miles = meters / metersPerMile
        if miles < 10 {
            return String(format: "%.1f mi", miles)
        }
        return "\(Int(miles.rounded())) mi"
    }
}
