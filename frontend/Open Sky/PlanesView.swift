//
//  PlanesView.swift
//  Open Sky
//
//  Created by Ben Kiev on 8/21/26.
//

import SwiftUI
import MapKit
import CoreLocation

struct Plane: Codable, Identifiable, Equatable {
    let hex: String
    let callsign: String?
    let lat: Double
    let lon: Double
    let altitudeFt: Int?
    let groundSpeedKt: Double?
    let trackDeg: Double?
    let verticalRateFpm: Int?
    let onGround: Bool
    let distanceKm: Double
    let lastSeen: String

    var id: String { hex }
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
    var displayCallsign: String {
        let trimmed = callsign?.trimmingCharacters(in: .whitespaces) ?? ""
        return trimmed.isEmpty ? hex.uppercased() : trimmed
    }

    enum CodingKeys: String, CodingKey {
        case hex, callsign, lat, lon
        case altitudeFt = "altitude_ft"
        case groundSpeedKt = "ground_speed_kt"
        case trackDeg = "track_deg"
        case verticalRateFpm = "vertical_rate_fpm"
        case onGround = "on_ground"
        case distanceKm = "distance_km"
        case lastSeen = "last_seen"
    }

    static func == (lhs: Plane, rhs: Plane) -> Bool {
        lhs.hex == rhs.hex && lhs.lat == rhs.lat && lhs.lon == rhs.lon
    }
}

struct Airport: Codable {
    let icao: String?
    let iata: String?
    let name: String?
    let municipality: String?
    let country: String?

    var displayName: String {
        if let name, !name.isEmpty {
            return name
        }
        return icao ?? iata ?? "Unknown"
    }

    var locationLine: String? {
        let parts = [municipality, country].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

struct PlaneRoute: Codable {
    let callsign: String?
    let airline: String?
    let origin: Airport?
    let destination: Airport?
}

struct AircraftInfo: Codable {
    let type: String?
    let icaoType: String?
    let manufacturer: String?
    let registration: String?
    let owner: String?
    let ownerCountry: String?
    let photoUrl: String?
    let photoThumbnailUrl: String?

    enum CodingKeys: String, CodingKey {
        case type
        case icaoType = "icao_type"
        case manufacturer
        case registration
        case owner
        case ownerCountry = "owner_country"
        case photoUrl = "photo_url"
        case photoThumbnailUrl = "photo_thumbnail_url"
    }

    var displayName: String {
        [manufacturer, type].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
    }
}

private struct PlaneQuery: Codable {
    let lat: Double
    let lon: Double
    let radiusKm: Double

    enum CodingKeys: String, CodingKey {
        case lat, lon
        case radiusKm = "radius_km"
    }
}

enum PlanesError: Error { case badResponse, notFound }

func fetchPlanes(lat: Double, lon: Double, radiusKm: Double) async throws -> [Plane] {
    var request = URLRequest(url: URL(string: "\(BASE_URL)/api/get-planes")!)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(PlaneQuery(lat: lat, lon: lon, radiusKm: radiusKm))

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
        throw PlanesError.badResponse
    }
    return try JSONDecoder().decode([Plane].self, from: data)
}

func fetchPlaneRoute(callsign: String) async throws -> PlaneRoute {
    guard var components = URLComponents(string: "\(BASE_URL)/api/get-plane-route") else {
        throw PlanesError.badResponse
    }
    components.queryItems = [URLQueryItem(name: "callsign", value: callsign)]

    let (data, response) = try await URLSession.shared.data(from: components.url!)
    guard let http = response as? HTTPURLResponse else { throw PlanesError.badResponse }
    if http.statusCode == 404 { throw PlanesError.notFound }
    guard http.statusCode == 200 else { throw PlanesError.badResponse }
    return try JSONDecoder().decode(PlaneRoute.self, from: data)
}

func fetchAircraftInfo(hex: String) async throws -> AircraftInfo {
    guard var components = URLComponents(string: "\(BASE_URL)/api/get-aircraft") else {
        throw PlanesError.badResponse
    }
    components.queryItems = [URLQueryItem(name: "hex", value: hex)]

    let (data, response) = try await URLSession.shared.data(from: components.url!)
    guard let http = response as? HTTPURLResponse else { throw PlanesError.badResponse }
    if http.statusCode == 404 { throw PlanesError.notFound }
    guard http.statusCode == 200 else { throw PlanesError.badResponse }
    return try JSONDecoder().decode(AircraftInfo.self, from: data)
}

struct PlanesView: View {
    @EnvironmentObject private var locationManager: LocationManager
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var visibleRegion: MKCoordinateRegion?
    @State private var hasCenteredOnUser = false
    @State private var planes: [Plane] = []
    @State private var selectedPlane: Plane?
    @State private var isLoading = false
    @State private var loadError: String?

    private var deviceCoordinateKey: String? {
        guard let c = locationManager.location?.coordinate else { return nil }
        return String(format: "%.2f,%.2f", c.latitude, c.longitude)
    }

    private func regionCenter() -> CLLocationCoordinate2D? {
        visibleRegion?.center ?? locationManager.location?.coordinate
    }

    private func regionRadiusKm() -> Double {
        guard let region = visibleRegion else { return 150 }
        let latKm = region.span.latitudeDelta * 111.0
        let lonKm = region.span.longitudeDelta * 111.0 * max(cos(region.center.latitude * .pi / 180), 0.1)
        let radius = max(latKm, lonKm) / 2 * 1.15
        return min(max(radius, 15), 400)
    }

    private func loadPlanes() async {
        guard let center = regionCenter() else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let fetched = try await fetchPlanes(lat: center.latitude, lon: center.longitude, radiusKm: regionRadiusKm())
            planes = fetched
            loadError = nil
        } catch {
            loadError = "Couldn't load nearby planes"
            print("Plane fetch failed: \(error)")
        }
    }

    private func recenterOnUser() {
        guard let coordinate = locationManager.location?.coordinate else { return }
        let region = MKCoordinateRegion(center: coordinate, span: MKCoordinateSpan(latitudeDelta: 2.5, longitudeDelta: 2.5))
        visibleRegion = region
        withAnimation {
            cameraPosition = .region(region)
        }
        Task { await loadPlanes() }
    }

    var body: some View {
        Map(position: $cameraPosition) {
            UserAnnotation()

            ForEach(planes) { plane in
                Annotation(plane.displayCallsign, coordinate: plane.coordinate) {
                    PlaneMarker(plane: plane)
                        .onTapGesture {
                            selectedPlane = plane
                        }
                }
                .annotationTitles(.hidden)
            }
        }
        .mapStyle(.standard(elevation: .flat))
        .mapControls {
            MapCompass()
            MapScaleView()
        }
        .onMapCameraChange(frequency: .onEnd) { context in
            visibleRegion = context.region
            Task { await loadPlanes() }
        }
        .ignoresSafeArea(edges: .bottom)
        .overlay(alignment: .top) {
            HStack {
                Spacer()
                if isLoading {
                    ProgressView()
                        .padding(10)
                        .glassEffect(.regular, in: Circle())
                } else if let loadError {
                    Text(loadError)
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .glassEffect(.regular, in: Capsule())
                } else {
                    Text("\(planes.count) plane\(planes.count == 1 ? "" : "s") in view")
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .glassEffect(.regular, in: Capsule())
                }
                Spacer()
            }
            .padding(.top, 8)
        }
        .overlay(alignment: .bottomTrailing) {
            Button {
                recenterOnUser()
            } label: {
                Image(systemName: "location.fill")
                    .font(.body)
                    .frame(width: 44, height: 44)
                    .glassEffect(.regular, in: Circle())
            }
            .padding()
        }
        .sheet(item: $selectedPlane) { plane in
            PlaneDetailView(plane: plane)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .task(id: deviceCoordinateKey) {
            guard !hasCenteredOnUser, locationManager.location != nil else { return }
            hasCenteredOnUser = true
            recenterOnUser()
        }
        .task {
            locationManager.requestPermission()
            locationManager.startPeriodicUpdates()
            while !Task.isCancelled {
                await loadPlanes()
                try? await Task.sleep(nanoseconds: 8_000_000_000)
            }
        }
        .onDisappear {
            locationManager.stopUpdates()
        }
        .navigationTitle("Planes")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct PlaneMarker: View {
    let plane: Plane

    var body: some View {
        Image(systemName: "airplane")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .rotationEffect(.degrees((plane.trackDeg ?? 0) - 45))
            .padding(7)
            .background(Circle().fill(plane.onGround ? Color.gray : Color.blue))
            .overlay(Circle().stroke(.white, lineWidth: 1.5))
            .shadow(radius: 2)
    }
}

private struct PlaneDetailView: View {
    let plane: Plane
    @State private var route: PlaneRoute?
    @State private var isLoadingRoute = true
    @State private var routeError: String?
    @State private var aircraft: AircraftInfo?
    @State private var isLoadingAircraft = true

    private func loadRoute() async {
        guard let callsign = plane.callsign, !callsign.trimmingCharacters(in: .whitespaces).isEmpty else {
            isLoadingRoute = false
            routeError = "No callsign broadcast for this aircraft yet"
            return
        }

        isLoadingRoute = true
        do {
            route = try await fetchPlaneRoute(callsign: callsign)
            routeError = nil
        } catch PlanesError.notFound {
            routeError = "No route information found for \(plane.displayCallsign)"
        } catch {
            routeError = "Couldn't load route information"
        }
        isLoadingRoute = false
    }

    private func loadAircraft() async {
        isLoadingAircraft = true
        aircraft = try? await fetchAircraftInfo(hex: plane.hex)
        isLoadingAircraft = false
    }

    private var altitudeText: String? {
        guard let ft = plane.altitudeFt else { return nil }
        return "\(ft.formatted()) ft"
    }

    private var speedText: String? {
        guard let kt = plane.groundSpeedKt else { return nil }
        return "\(Int(kt.rounded())) kt"
    }

    private var headingText: String? {
        guard let deg = plane.trackDeg else { return nil }
        return "\(Int(deg.rounded()))°"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(plane.displayCallsign)
                        .font(.largeTitle.bold())
                    Text("ICAO24 \(plane.hex.uppercased())")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if isLoadingRoute {
                    HStack {
                        ProgressView()
                        Text("Looking up route…")
                            .foregroundStyle(.secondary)
                    }
                } else if let route, route.origin != nil || route.destination != nil {
                    VStack(alignment: .leading, spacing: 14) {
                        if let airline = route.airline {
                            Text(airline)
                                .font(.headline)
                                .foregroundStyle(.secondary)
                        }

                        HStack(alignment: .top, spacing: 12) {
                            RoutePointView(label: "From", airport: route.origin)
                            Image(systemName: "airplane")
                                .foregroundStyle(.secondary)
                                .padding(.top, 20)
                            RoutePointView(label: "To", airport: route.destination)
                        }
                    }
                    .padding(16)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
                } else if let routeError {
                    Text(routeError)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if isLoadingAircraft {
                    HStack {
                        ProgressView()
                        Text("Looking up aircraft…")
                            .foregroundStyle(.secondary)
                    }
                } else if let aircraft, !aircraft.displayName.isEmpty {
                    HStack(alignment: .top, spacing: 14) {
                        if let thumbnailURL = aircraft.photoThumbnailUrl, let url = URL(string: thumbnailURL) {
                            AsyncImage(url: url) { image in
                                image.resizable().scaledToFill()
                            } placeholder: {
                                Color.secondary.opacity(0.15)
                            }
                            .frame(width: 72, height: 72)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text(aircraft.displayName)
                                .font(.headline)
                            if let registration = aircraft.registration {
                                Text(registration)
                                    .font(.subheadline.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            if let owner = aircraft.owner {
                                Text(owner)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Spacer(minLength: 0)
                    }
                    .padding(16)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Flight Data")
                        .font(.headline)

                    Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                        GridRow {
                            statLabel("Altitude", altitudeText ?? "—")
                            statLabel("Speed", speedText ?? "—")
                        }
                        GridRow {
                            statLabel("Heading", headingText ?? "—")
                            statLabel("Distance", "\(plane.distanceKm.formatted()) km")
                        }
                    }
                }
                .padding(16)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))

                Spacer(minLength: 0)
            }
            .padding()
        }
        .task {
            await loadRoute()
        }
        .task {
            await loadAircraft()
        }
    }

    private func statLabel(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.body.monospacedDigit())
        }
    }
}

private struct RoutePointView: View {
    let label: String
    let airport: Airport?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let airport {
                Text(airport.icao ?? airport.iata ?? "—")
                    .font(.title3.bold())
                Text(airport.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let locationLine = airport.locationLine {
                    Text(locationLine)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Unknown")
                    .font(.title3.bold())
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview {
    PlanesView()
        .environmentObject(LocationManager())
}
