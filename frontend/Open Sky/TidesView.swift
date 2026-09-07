//
//  TidesView.swift
//  Open Sky
//
//  Created by Ben Kiev on 8/21/26.
//

import SwiftUI
import Charts
import CoreLocation
import MapKit

struct TidePoint: Codable, Identifiable, TimeSeriesPoint {
    let time: Date
    let height: Double

    var id: TimeInterval { time.timeIntervalSince1970 }

    static func interpolated(at time: Date, before: TidePoint, after: TidePoint) -> TidePoint {
        let span = after.time.timeIntervalSince(before.time)
        let fraction = span > 0 ? time.timeIntervalSince(before.time) / span : 0
        return TidePoint(time: time, height: before.height + (after.height - before.height) * fraction)
    }
}

struct TideExtreme: Codable, Identifiable {
    let time: Date
    let type: String
    let height: Double

    var id: TimeInterval { time.timeIntervalSince1970 }
    var isHigh: Bool { type == "high" }
}

struct TidesResponse: Codable {
    let stationId: String
    let stationName: String
    let stationDistanceKm: Double
    let datum: String
    let units: String
    let hourly: [TidePoint]
    let extremes: [TideExtreme]

    enum CodingKeys: String, CodingKey {
        case stationId = "station_id"
        case stationName = "station_name"
        case stationDistanceKm = "station_distance_km"
        case datum, units, hourly, extremes
    }
}

enum TidesError: Error { case badResponse }

func fetchTides(lat: Double, lon: Double) async throws -> TidesResponse {
    var request = URLRequest(url: URL(string: "\(BASE_URL)/api/get-tides")!)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(ForecastRequest(lat: lat, lon: lon))

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
        throw TidesError.badResponse
    }

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(TidesResponse.self, from: data)
}

struct TidesView: View {
    @EnvironmentObject private var locationManager: LocationManager
    @StateObject private var searchService = LocationSearchService()
    @State private var response: TidesResponse?
    @State private var selectedTime: Date?
    @State private var searchText = ""
    @State private var selectedLocation: SelectedLocation?
    @State private var currentLocationLabel: SelectedLocation?
    @State private var selectedDayOffset = 0
    @State private var isRefreshing = false
    @State private var loadError: String?

    @AppStorage("tideHeightUnit") private var tideHeightUnit = TideHeightUnit.meters

    private var activeLocation: SelectedLocation? {
        selectedLocation ?? currentLocationLabel
    }

    private var activeCoordinate: CLLocationCoordinate2D? {
        selectedLocation?.coordinate ?? locationManager.location?.coordinate
    }

    private var activeCoordinateKey: String? {
        guard let c = activeCoordinate else { return nil }
        return String(format: "%.2f,%.2f", c.latitude, c.longitude)
    }

    private var deviceCoordinateKey: String? {
        guard let c = locationManager.location?.coordinate else { return nil }
        return String(format: "%.2f,%.2f", c.latitude, c.longitude)
    }

    private func selectSearchResult(_ completion: MKLocalSearchCompletion) async {
        guard let resolved = await searchService.resolve(completion) else { return }
        selectedLocation = resolved
        searchText = ""
    }

    private func loadTides() async {
        guard let coordinate = activeCoordinate else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        async let fetchTask = fetchTides(lat: coordinate.latitude, lon: coordinate.longitude)
        async let minimumVisible: Void = {
            try? await Task.sleep(nanoseconds: 500_000_000)
        }()

        do {
            let fetched = try await fetchTask
            _ = await minimumVisible
            response = fetched
            loadError = nil
        } catch {
            _ = await minimumVisible
            loadError = "No tide station nearby"
            print("Tide fetch failed: \(error)")
        }
    }

    private var navigationTitleText: String {
        guard let activeLocation else { return "Locating…" }
        return activeLocation.region.isEmpty ? activeLocation.name : "\(activeLocation.name), \(activeLocation.region)"
    }

    private var selectedDayStart: Date {
        let today = Calendar.current.startOfDay(for: Date())
        return Calendar.current.date(byAdding: .day, value: selectedDayOffset, to: today) ?? today
    }

    private var selectedDayPoints: [TidePoint] {
        guard let response else { return [] }
        return dayBoundedPoints(response.hourly, dayStart: selectedDayStart)
    }

    private var selectedDayExtremes: [TideExtreme] {
        guard let response else { return [] }
        let start = selectedDayStart
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start
        return response.extremes.filter { $0.time >= start && $0.time < end }
    }

    private var referenceNow: Date? {
        selectedDayOffset == 0 ? Date() : nil
    }

    private var extremesRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(selectedDayExtremes) { extreme in
                    HStack(spacing: 6) {
                        Image(systemName: extreme.isHigh ? "arrow.up" : "arrow.down")
                            .font(.caption.bold())
                        VStack(alignment: .leading, spacing: 0) {
                            Text(extreme.isHigh ? "High" : "Low")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text("\(tideHeightUnit.convert(fromMeters: extreme.height), specifier: "%.1f")\(tideHeightUnit.symbol)")
                                .font(.caption.bold())
                                .monospacedDigit()
                        }
                        Text(extreme.time, format: .dateTime.hour().minute())
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14))
                }
            }
            .padding(.horizontal, 2)
        }
    }

    var body: some View {
        ZStack {
            TideBackgroundView()

            ScrollView {
                VStack(spacing: 16) {
                    DayBar(selectedDayOffset: $selectedDayOffset)

                    if let response {
                        if !selectedDayExtremes.isEmpty {
                            extremesRow
                        }

                        MetricChart(
                            title: "Tide Height",
                            color: .cyan,
                            points: selectedDayPoints,
                            value: { tideHeightUnit.convert(fromMeters: $0.height) },
                            unit: tideHeightUnit.symbol,
                            style: .line,
                            iconName: "water.waves",
                            referenceNow: referenceNow,
                            selectedTime: $selectedTime,
                            showDayRange: true,
                            dynamicYScale: true,
                            interpolationMethod: .catmullRom
                        )

                        Text("Station: \(response.stationName) · \(response.stationDistanceKm, specifier: "%.0f") km away")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else if let loadError {
                        Text(loadError)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.top, 40)
                    } else {
                        MetricSkeleton()
                    }
                }
                .padding()
            }
            .refreshable {
                await loadTides()
            }

            if isRefreshing {
                ProgressView()
                    .padding(10)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 8)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isRefreshing)
        .navigationTitle(navigationTitleText)
        .navigationBarTitleDisplayMode(.large)
        .onChange(of: selectedDayOffset) { _, _ in
            selectedTime = nil
        }
        .searchable(text: $searchText, prompt: "Search for a city")
        .onChange(of: searchText) { _, newValue in
            searchService.queryFragment = newValue
        }
        .searchSuggestions {
            SearchSuggestionRow(title: "My Location", subtitle: nil, systemImage: "location.fill") {
                selectedLocation = nil
                searchText = ""
            }

            ForEach(Array(searchService.completions.enumerated()), id: \.offset) { _, completion in
                SearchSuggestionRow(title: completion.title, subtitle: completion.subtitle, systemImage: nil) {
                    await selectSearchResult(completion)
                }
            }
        }
        .task(id: activeCoordinateKey) {
            await loadTides()
        }
        .task(id: deviceCoordinateKey) {
            guard selectedLocation == nil, let location = locationManager.location else { return }
            currentLocationLabel = await reverseGeocode(location)
        }
        .onAppear {
            locationManager.requestPermission()
            locationManager.startPeriodicUpdates()
        }
        .onDisappear {
            locationManager.stopUpdates()
        }
    }
}

private struct TideBackgroundView: View {
    private var hourFraction: Double {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: Date())
        return Double(comps.hour ?? 12) + Double(comps.minute ?? 0) / 60
    }

    private var skyColors: [Color] {
        switch hourFraction {
        case 0..<5:
            return [Color(red: 0.04, green: 0.05, blue: 0.14), Color(red: 0.09, green: 0.12, blue: 0.25)]
        case 5..<7:
            return [Color(red: 0.20, green: 0.16, blue: 0.32), Color(red: 0.86, green: 0.55, blue: 0.45)]
        case 7..<17:
            return [Color(red: 0.30, green: 0.60, blue: 0.78), Color(red: 0.65, green: 0.85, blue: 0.85)]
        case 17..<19:
            return [Color(red: 0.85, green: 0.45, blue: 0.35), Color(red: 0.25, green: 0.20, blue: 0.40)]
        default:
            return [Color(red: 0.05, green: 0.07, blue: 0.18), Color(red: 0.12, green: 0.14, blue: 0.28)]
        }
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: skyColors, startPoint: .top, endPoint: .bottom)

            Image(systemName: MoonPhase.symbolName())
                .resizable()
                .scaledToFit()
                .frame(width: 140, height: 140)
                .foregroundStyle(.white.opacity(0.18))
                .blur(radius: 1)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .offset(x: -30, y: 110)

            TimelineView(.animation) { timeline in
                let phase = timeline.date.timeIntervalSinceReferenceDate * 0.15
                WaveShape(phase: phase)
                    .fill(Color.white.opacity(0.08))
                    .frame(height: 140)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
        }
        .ignoresSafeArea()
    }
}

private struct WaveShape: Shape {
    var phase: Double

    var animatableData: Double {
        get { phase }
        set { phase = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let midHeight = rect.height * 0.35
        let wavelength = max(rect.width / 1.5, 1)

        path.move(to: CGPoint(x: 0, y: midHeight))
        var x: CGFloat = 0
        while x <= rect.width {
            let relativeX = x / wavelength
            let y = midHeight + sin(relativeX * 2 * .pi + phase) * 10
            path.addLine(to: CGPoint(x: x, y: y))
            x += 2
        }
        path.addLine(to: CGPoint(x: rect.width, y: rect.height))
        path.addLine(to: CGPoint(x: 0, y: rect.height))
        path.closeSubpath()
        return path
    }
}

#Preview {
    TidesView()
        .environmentObject(LocationManager())
}
