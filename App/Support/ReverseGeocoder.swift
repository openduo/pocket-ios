// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import CoreLocation
import MapKit
import PocketCore

/// Names a coordinate with the system map service, for the composer's location picker and for
/// arrivals. MapKit's request on iOS 26 and later, the Core Location geocoder before.
enum ReverseGeocoder {
    struct Name {
        /// The service's name for the point: a point of interest, else the street-level name.
        var name: String?
        /// The full address, one line.
        var address: String?
        /// District and city (`ArrivalPlace.area`); empty when the service gives neither.
        var area: String
    }

    static func name(_ location: CLLocation) async -> Name? {
        if #available(iOS 26.0, *) {
            guard let request = MKReverseGeocodingRequest(location: location),
                  let item = try? await request.mapItems.first else { return nil }
            // iOS 26 MapKit names no district apart; its city with context is the nearest line.
            let reps = item.addressRepresentations
            let area = ArrivalPlace.area(city: reps?.cityWithContext(.short) ?? reps?.cityName, district: nil)
            return Name(name: item.name, address: address(of: item), area: area)
        }
        guard let mark = try? await CLGeocoder().reverseGeocodeLocation(location).first else { return nil }
        let address = [mark.administrativeArea, mark.locality, mark.subLocality, mark.thoroughfare, mark.subThoroughfare]
            .compactMap { $0 }.joined()
        return Name(name: mark.name, address: address.isEmpty ? nil : address,
                    area: ArrivalPlace.area(city: mark.locality, district: mark.subLocality))
    }

    static func address(of item: MKMapItem) -> String? {
        if #available(iOS 26.0, *) {
            return item.address?.fullAddress.replacingOccurrences(of: "\n", with: " ")
        }
        return item.placemark.title
    }
}
