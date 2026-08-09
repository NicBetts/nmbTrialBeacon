//
//  OpenInAppleMaps.swift
//  nmbTrialBeacon
//
//  Shared confirm → open for map previews across Home, Discover, Site, Org, Trial.
//

import MapKit
import SwiftUI

enum OpenInAppleMaps {
    static func open(coordinate: CLLocationCoordinate2D, name: String?) {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let item = MKMapItem(location: location, address: nil)
        if let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            item.name = name
        }
        item.openInMaps(launchOptions: [
            MKLaunchOptionsMapCenterKey: NSValue(mkCoordinate: coordinate),
            MKLaunchOptionsMapSpanKey: NSValue(
                mkCoordinateSpan: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
            ),
        ])
    }
}

/// Confirmation dialog + Apple Maps open. Attach to any map preview.
struct OpenInMapsConfirmationModifier: ViewModifier {
    let coordinate: CLLocationCoordinate2D?
    let placeName: String?
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                "Open in Maps?",
                isPresented: $isPresented,
                titleVisibility: .visible
            ) {
                Button("Open in Apple Maps") {
                    guard let coordinate else { return }
                    OpenInAppleMaps.open(coordinate: coordinate, name: placeName)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                if let placeName, !placeName.isEmpty {
                    Text("Show \(placeName) in Apple Maps.")
                } else {
                    Text("Show this location in Apple Maps.")
                }
            }
    }
}

extension View {
    func openInMapsConfirmation(
        isPresented: Binding<Bool>,
        coordinate: CLLocationCoordinate2D?,
        placeName: String? = nil
    ) -> some View {
        modifier(OpenInMapsConfirmationModifier(
            coordinate: coordinate,
            placeName: placeName,
            isPresented: isPresented
        ))
    }
}
