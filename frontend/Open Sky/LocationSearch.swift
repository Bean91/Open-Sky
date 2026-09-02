//
//  LocationSearch.swift
//  Open Sky
//
//  Created by Ben Kiev on 8/24/26.
//

import Foundation
import MapKit
import CoreLocation
import Combine

struct SelectedLocation: Equatable {
    let name: String
    let region: String
    let coordinate: CLLocationCoordinate2D

    static func == (lhs: SelectedLocation, rhs: SelectedLocation) -> Bool {
        lhs.name == rhs.name && lhs.region == rhs.region
            && lhs.coordinate.latitude == rhs.coordinate.latitude
            && lhs.coordinate.longitude == rhs.coordinate.longitude
    }

    init(name: String, region: String, coordinate: CLLocationCoordinate2D) {
        self.name = name
        self.region = region
        self.coordinate = coordinate
    }

    init?(mapItem: MKMapItem) {
        guard let representations = mapItem.addressRepresentations else { return nil }

        let name = representations.cityName ?? "Unknown"
        let region: String
        if representations.regionName == "United States",
           let cityWithContext = representations.cityWithContext,
           cityWithContext.hasPrefix(name + ", ") {
            region = String(cityWithContext.dropFirst(name.count + 2))
        } else {
            region = representations.regionName ?? ""
        }

        self.name = name
        self.region = region
        self.coordinate = mapItem.location.coordinate
    }
}

func reverseGeocode(_ location: CLLocation) async -> SelectedLocation? {
    guard let request = MKReverseGeocodingRequest(location: location) else { return nil }
    guard let mapItem = (try? await request.mapItems)?.first else { return nil }
    return SelectedLocation(mapItem: mapItem)
}

final class LocationSearchService: NSObject, ObservableObject {
    @Published private(set) var completions: [MKLocalSearchCompletion] = []

    var queryFragment: String = "" {
        didSet { completer.queryFragment = queryFragment }
    }

    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = .address
    }

    @MainActor
    func resolve(_ completion: MKLocalSearchCompletion) async -> SelectedLocation? {
        let request = MKLocalSearch.Request(completion: completion)
        guard let response = try? await MKLocalSearch(request: request).start(),
              let mapItem = response.mapItems.first else { return nil }

        return SelectedLocation(mapItem: mapItem)
    }
}

extension LocationSearchService: MKLocalSearchCompleterDelegate {
    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        completions = completer.results
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        print("Location search failed: \(error.localizedDescription)")
    }
}
