//
//  StarsView.swift
//  Open Sky
//
//  Created by Ben Kiev on 8/21/26.
//

import SwiftUI
import Charts
import CoreLocation
import MapKit

struct SkyPoint: Codable, TimeSeriesPoint {
    let time: Date
    let altitude: Double
    let azimuth: Double

    static func interpolated(at time: Date, before: SkyPoint, after: SkyPoint) -> SkyPoint {
        let span = after.time.timeIntervalSince(before.time)
        let fraction = span > 0 ? time.timeIntervalSince(before.time) / span : 0
        func lerp(_ a: Double, _ b: Double) -> Double { a + (b - a) * fraction }
        return SkyPoint(time: time, altitude: lerp(before.altitude, after.altitude), azimuth: lerp(before.azimuth, after.azimuth))
    }
}

struct SunInfo: Codable {
    let rises: [Date]
    let sets: [Date]
    let civilDawns: [Date]
    let civilDusks: [Date]
    let nauticalDawns: [Date]
    let nauticalDusks: [Date]
    let astronomicalDawns: [Date]
    let astronomicalDusks: [Date]
    let hourly: [SkyPoint]

    enum CodingKeys: String, CodingKey {
        case rises, sets, hourly
        case civilDawns = "civil_dawns"
        case civilDusks = "civil_dusks"
        case nauticalDawns = "nautical_dawns"
        case nauticalDusks = "nautical_dusks"
        case astronomicalDawns = "astronomical_dawns"
        case astronomicalDusks = "astronomical_dusks"
    }
}

struct MoonInfo: Codable {
    let rises: [Date]
    let sets: [Date]
    let nextNewMoon: Date?
    let nextFullMoon: Date?

    enum CodingKeys: String, CodingKey {
        case rises, sets
        case nextNewMoon = "next_new_moon"
        case nextFullMoon = "next_full_moon"
    }
}

struct SnapshotMoon: Codable {
    let altitude: Double
    let azimuth: Double
    let phaseName: String
    let illuminationPercent: Double
    let ageDays: Double
    let distanceKm: Double

    enum CodingKeys: String, CodingKey {
        case altitude, azimuth
        case phaseName = "phase_name"
        case illuminationPercent = "illumination_percent"
        case ageDays = "age_days"
        case distanceKm = "distance_km"
    }
}

struct SnapshotPlanet: Codable {
    let name: String
    let altitude: Double
    let azimuth: Double
}

struct SkySnapshot: Codable {
    let time: Date
    let moon: SnapshotMoon
    let planets: [SnapshotPlanet]
    let stars: [StarInfo]
}

struct PlanetInfo: Codable, Identifiable {
    let name: String
    let magnitude: Double
    let rise: Date?
    let set: Date?
    let hourly: [SkyPoint]

    var id: String { name }

    var isNakedEyeVisible: Bool { magnitude < 6.0 }

    var color: Color {
        switch name {
        case "Mercury": .gray
        case "Venus": .yellow
        case "Mars": .red
        case "Jupiter": .orange
        case "Saturn": Color(red: 0.85, green: 0.75, blue: 0.5)
        case "Uranus": .cyan
        case "Neptune": .blue
        default: .white
        }
    }
}

struct StarInfo: Codable, Identifiable {
    let hip: Int
    let name: String?
    let magnitude: Double
    let altitude: Double
    let azimuth: Double

    var id: Int { hip }
}

struct SkyResponse: Codable {
    let generatedAt: Date
    let sun: SunInfo
    let moon: MoonInfo
    let planets: [PlanetInfo]
    let snapshots: [SkySnapshot]

    enum CodingKeys: String, CodingKey {
        case sun, moon, planets, snapshots
        case generatedAt = "generated_at"
    }
}

struct SkyRequest: Codable {
    let lat: Double
    let lon: Double
    let dayReferenceTimes: [Date]

    enum CodingKeys: String, CodingKey {
        case lat, lon
        case dayReferenceTimes = "day_reference_times"
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

func skyDayReferenceTimes(dayCount: Int = 14, now: Date = Date()) -> [Date] {
    let calendar = Calendar.current
    let todayStart = calendar.startOfDay(for: now)
    return (0..<dayCount).map { offset -> Date in
        if offset == 0 { return now }
        let dayStart = calendar.date(byAdding: .day, value: offset, to: todayStart) ?? todayStart
        return calendar.date(bySettingHour: 21, minute: 0, second: 0, of: dayStart) ?? dayStart
    }
}

enum SkyError: Error { case badResponse }

func fetchSky(lat: Double, lon: Double, dayReferenceTimes: [Date]) async throws -> SkyResponse {
    var request = URLRequest(url: URL(string: "\(BASE_URL)/api/get-sky")!)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    request.httpBody = try encoder.encode(SkyRequest(lat: lat, lon: lon, dayReferenceTimes: dayReferenceTimes))

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
        throw SkyError.badResponse
    }

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(SkyResponse.self, from: data)
}

enum TwilightPhase: String {
    case day = "Day"
    case civil = "Civil Twilight"
    case nautical = "Nautical Twilight"
    case astronomical = "Astronomical Twilight"
    case night = "Night"
}

private func currentTwilightPhase(sun: SunInfo, now: Date) -> TwilightPhase {
    guard let nearest = sun.hourly.min(by: { abs($0.time.timeIntervalSince(now)) < abs($1.time.timeIntervalSince(now)) }) else {
        return .night
    }
    switch nearest.altitude {
    case let a where a > -0.83: return .day
    case let a where a > -6: return .civil
    case let a where a > -12: return .nautical
    case let a where a > -18: return .astronomical
    default: return .night
    }
}

struct StarsView: View {
    @EnvironmentObject private var locationManager: LocationManager
    @StateObject private var searchService = LocationSearchService()
    @State private var response: SkyResponse?
    @State private var selectedTime: Date?
    @State private var searchText = ""
    @State private var selectedLocation: SelectedLocation?
    @State private var currentLocationLabel: SelectedLocation?
    @State private var selectedPlanetID: String?
    @State private var isRefreshing = false
    @State private var loadError: String?
    @State private var selectedDayOffset = 0

    private var selectedDayStart: Date {
        let today = Calendar.current.startOfDay(for: Date())
        return Calendar.current.date(byAdding: .day, value: selectedDayOffset, to: today) ?? today
    }

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

    private func loadSky() async {
        guard let coordinate = activeCoordinate else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let referenceTimes = skyDayReferenceTimes()
        async let fetchTask = fetchSky(lat: coordinate.latitude, lon: coordinate.longitude, dayReferenceTimes: referenceTimes)
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
            loadError = "Sky data unavailable"
            print("Sky fetch failed: \(error)")
        }
    }

    private var navigationTitleText: String {
        guard let activeLocation else { return "Locating…" }
        return activeLocation.region.isEmpty ? activeLocation.name : "\(activeLocation.name), \(activeLocation.region)"
    }

    var body: some View {
        ZStack {
            NightSkyBackgroundView(phase: response.map { currentTwilightPhase(sun: $0.sun, now: Date()) } ?? .night)

            ScrollView {
                VStack(spacing: 16) {
                    DayBar(selectedDayOffset: $selectedDayOffset)

                    if let response {
                        let snapshot = response.snapshots[safe: selectedDayOffset]
                        let referenceTime = snapshot?.time ?? Date()

                        StarMapCard(
                            response: response,
                            snapshot: snapshot,
                            referenceTime: referenceTime,
                            isToday: selectedDayOffset == 0
                        )

                        MoonCard(
                            moon: response.moon,
                            snapshot: snapshot?.moon,
                            referenceTime: referenceTime,
                            selectedDayStart: selectedDayStart
                        )

                        SunCard(sun: response.sun, selectedDayStart: selectedDayStart)

                        PlanetsCard(
                            planets: response.planets,
                            snapshot: snapshot,
                            selectedPlanetID: $selectedPlanetID,
                            selectedTime: $selectedTime,
                            selectedDayOffset: selectedDayOffset,
                            selectedDayStart: selectedDayStart
                        )
                    } else if let loadError {
                        Text(loadError)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.top, 40)
                    } else {
                        MetricSkeleton()
                        MetricSkeleton()
                    }
                }
                .padding()
            }
            .refreshable {
                await loadSky()
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
            await loadSky()
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

private struct NightSkyBackgroundView: View {
    let phase: TwilightPhase

    private var skyColors: [Color] {
        switch phase {
        case .day:
            return [Color(red: 0.30, green: 0.55, blue: 0.80), Color(red: 0.55, green: 0.72, blue: 0.88)]
        case .civil:
            return [Color(red: 0.85, green: 0.45, blue: 0.35), Color(red: 0.20, green: 0.18, blue: 0.38)]
        case .nautical:
            return [Color(red: 0.18, green: 0.16, blue: 0.35), Color(red: 0.08, green: 0.09, blue: 0.22)]
        case .astronomical:
            return [Color(red: 0.08, green: 0.09, blue: 0.20), Color(red: 0.03, green: 0.04, blue: 0.10)]
        case .night:
            return [Color(red: 0.02, green: 0.03, blue: 0.08), Color(red: 0.01, green: 0.01, blue: 0.04)]
        }
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: skyColors, startPoint: .top, endPoint: .bottom)

            TimelineView(.animation) { timeline in
                Canvas { context, size in
                    let t = timeline.date.timeIntervalSinceReferenceDate
                    for i in 0..<60 {
                        let seed = Double(i)
                        let x = (sin(seed * 12.9898) * 43758.5453).truncatingRemainder(dividingBy: 1) * size.width
                        let y = (sin(seed * 78.233) * 12345.6789).truncatingRemainder(dividingBy: 1) * size.height
                        let px = abs(x), py = abs(y)
                        let twinkle = 0.35 + 0.35 * sin(t * 0.8 + seed)
                        let r = 0.6 + 1.0 * (seed.truncatingRemainder(dividingBy: 3) / 3)
                        context.fill(
                            Circle().path(in: CGRect(x: px - r / 2, y: py - r / 2, width: r, height: r)),
                            with: .color(.white.opacity(max(0, twinkle)))
                        )
                    }
                }
            }
        }
        .ignoresSafeArea()
    }
}

private struct StarMapCard: View {
    let response: SkyResponse
    let snapshot: SkySnapshot?
    let referenceTime: Date
    let isToday: Bool

    private var brightestNamedStarCount: Int { 14 }

    private func planetEntries(_ snapshot: SkySnapshot) -> [(planet: PlanetInfo, altitude: Double, azimuth: Double)] {
        snapshot.planets.compactMap { sp in
            guard let info = response.planets.first(where: { $0.name == sp.name }) else { return nil }
            return (planet: info, altitude: sp.altitude, azimuth: sp.azimuth)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                Text(isToday ? "Sky Right Now" : "Sky on \(referenceTime.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))")
                    .font(.headline)
                Spacer()
                Text(referenceTime, format: .dateTime.hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            StarMapCanvas(
                stars: snapshot?.stars ?? [],
                planets: snapshot.map(planetEntries) ?? [],
                moon: snapshot?.moon,
                referenceTime: referenceTime,
                namedStarLimit: brightestNamedStarCount
            )
            .frame(height: 300)
            .frame(maxWidth: .infinity)

            HStack(spacing: 4) {
                Image(systemName: "hand.tap")
                Text("Tap an object for details · pinch to zoom")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            if let illumination = snapshot?.moon.illuminationPercent, illumination > 50 {
                Text("Bright moonlight (\(Int(illumination))% lit) may wash out fainter stars \(isToday ? "tonight" : "that night").")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20))
    }
}

private struct SkyMapSelection: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String
    let iconName: String
    let iconColor: Color
    let rows: [(String, String)]

    init(star: StarInfo) {
        title = star.name ?? "HIP \(star.hip)"
        subtitle = star.name != nil ? "Star · HIP \(star.hip)" : "Star"
        iconName = "sparkle"
        iconColor = .white
        rows = [
            ("Magnitude", String(format: "%.2f", star.magnitude)),
            ("Altitude", String(format: "%.1f°", star.altitude)),
            ("Azimuth", String(format: "%.1f°", star.azimuth)),
        ]
    }

    init(planet: PlanetInfo, altitude: Double, azimuth: Double) {
        title = planet.name
        subtitle = "Planet"
        iconName = "circle.hexagongrid.fill"
        iconColor = planet.color
        var r: [(String, String)] = [
            ("Magnitude", String(format: "%.2f", planet.magnitude)),
            ("Altitude", String(format: "%.1f°", altitude)),
            ("Azimuth", String(format: "%.1f°", azimuth)),
        ]
        if let rise = planet.rise { r.append(("Rises", rise.formatted(.dateTime.hour().minute()))) }
        if let set = planet.set { r.append(("Sets", set.formatted(.dateTime.hour().minute()))) }
        rows = r
    }

    init(moon: SnapshotMoon, referenceTime: Date) {
        title = "Moon"
        subtitle = moon.phaseName
        iconName = MoonPhase.symbolName(for: referenceTime)
        iconColor = .white
        rows = [
            ("Illumination", "\(Int(moon.illuminationPercent))%"),
            ("Altitude", String(format: "%.1f°", moon.altitude)),
            ("Azimuth", String(format: "%.1f°", moon.azimuth)),
        ]
    }
}

private struct SkyMapDetailSheet: View {
    let selection: SkyMapSelection

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: selection.iconName)
                    .font(.title2)
                    .foregroundStyle(selection.iconColor)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(selection.title)
                        .font(.title3.bold())
                    Text(selection.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                ForEach(selection.rows, id: \.0) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.0)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(row.1)
                            .font(.subheadline.bold())
                            .monospacedDigit()
                    }
                }
            }

            Spacer()
        }
        .padding()
        .presentationDetents([.height(240)])
        .presentationDragIndicator(.visible)
    }
}

private struct StarMapCanvas: View {
    let stars: [StarInfo]
    let planets: [(planet: PlanetInfo, altitude: Double, azimuth: Double)]
    let moon: SnapshotMoon?
    let referenceTime: Date
    let namedStarLimit: Int

    @State private var scale: CGFloat = 1
    @State private var steadyScale: CGFloat = 1
    @State private var panOffset: CGSize = .zero
    @State private var steadyPanOffset: CGSize = .zero
    @State private var selection: SkyMapSelection?

    private let minScale: CGFloat = 1
    private let maxScale: CGFloat = 6

    private func center(in size: CGSize) -> CGPoint {
        CGPoint(x: size.width / 2 + panOffset.width, y: size.height / 2 + panOffset.height)
    }

    private func baseRadius(in size: CGSize) -> Double {
        Double(min(size.width, size.height) / 2 - 18) * Double(scale)
    }

    private func point(altitude: Double, azimuth: Double, in size: CGSize) -> CGPoint {
        let c = center(in: size)
        let r = baseRadius(in: size) * max(0, 90 - altitude) / 90
        let rad = azimuth * Double.pi / 180
        let dx = r * sin(rad)
        let dy = r * cos(rad)
        return CGPoint(x: c.x + CGFloat(dx), y: c.y - CGFloat(dy))
    }

    private func clampedPan(_ proposed: CGSize, in size: CGSize) -> CGSize {
        guard scale > 1 else { return .zero }
        let radius = Double(min(size.width, size.height) / 2 - 18)
        let maxPan = CGFloat(radius * (Double(scale) - 1) + radius * 0.3)
        return CGSize(
            width: min(max(proposed.width, -maxPan), maxPan),
            height: min(max(proposed.height, -maxPan), maxPan)
        )
    }

    private func nearestSelection(to location: CGPoint, in size: CGSize) -> SkyMapSelection? {
        let hitRadius: Double = 18
        var best: (dist: Double, selection: SkyMapSelection)?

        func consider(_ p: CGPoint, _ makeSelection: @autoclosure () -> SkyMapSelection) {
            let d = hypot(Double(p.x - location.x), Double(p.y - location.y))
            guard d < hitRadius, best == nil || d < best!.dist else { return }
            best = (d, makeSelection())
        }

        for star in stars {
            consider(point(altitude: star.altitude, azimuth: star.azimuth, in: size), SkyMapSelection(star: star))
        }
        for entry in planets where entry.altitude > 0 {
            consider(
                point(altitude: entry.altitude, azimuth: entry.azimuth, in: size),
                SkyMapSelection(planet: entry.planet, altitude: entry.altitude, azimuth: entry.azimuth)
            )
        }
        if let moon, moon.altitude > 0 {
            consider(
                point(altitude: moon.altitude, azimuth: moon.azimuth, in: size),
                SkyMapSelection(moon: moon, referenceTime: referenceTime)
            )
        }
        return best?.selection
    }

    private func resetZoom() {
        withAnimation(.easeInOut(duration: 0.2)) {
            scale = 1
            steadyScale = 1
            panOffset = .zero
            steadyPanOffset = .zero
        }
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size

            Canvas { context, size in
                let center = center(in: size)
                let radius = baseRadius(in: size)

                let cgRadius = CGFloat(radius)
                let horizonRect = CGRect(x: center.x - cgRadius, y: center.y - cgRadius, width: cgRadius * 2, height: cgRadius * 2)
                context.stroke(Circle().path(in: horizonRect), with: .color(.white.opacity(0.25)), lineWidth: 1)

                for ring in [30.0, 60.0] {
                    let r = CGFloat(radius * (90 - ring) / 90)
                    let rect = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
                    context.stroke(Circle().path(in: rect), with: .color(.white.opacity(0.1)), lineWidth: 0.5)
                }

                for (label, az) in [("N", 0.0), ("E", 90.0), ("S", 180.0), ("W", 270.0)] {
                    let rad = az * Double.pi / 180
                    let dx = (radius + 11) * sin(rad)
                    let dy = (radius + 11) * cos(rad)
                    let p = CGPoint(x: center.x + CGFloat(dx), y: center.y - CGFloat(dy))
                    context.draw(Text(label).font(.caption2.bold()).foregroundColor(.white.opacity(0.55)), at: p)
                }

                let namedFirst = stars.filter { $0.name != nil }.sorted { $0.magnitude < $1.magnitude }
                let labeledHips = Set(namedFirst.prefix(namedStarLimit).map(\.hip))

                for star in stars {
                    let p = point(altitude: star.altitude, azimuth: star.azimuth, in: size)
                    let dotSize = CGFloat(max(1.2, 4.2 - star.magnitude * 0.7))
                    let rect = CGRect(x: p.x - dotSize / 2, y: p.y - dotSize / 2, width: dotSize, height: dotSize)
                    context.fill(Circle().path(in: rect), with: .color(.white.opacity(0.9)))

                    if labeledHips.contains(star.hip), let name = star.name {
                        context.draw(
                            Text(name).font(.system(size: 9)).foregroundColor(.white.opacity(0.75)),
                            at: CGPoint(x: p.x, y: p.y - 8)
                        )
                    }
                }

                for entry in planets where entry.altitude > 0 {
                    let p = point(altitude: entry.altitude, azimuth: entry.azimuth, in: size)
                    let rect = CGRect(x: p.x - 3.5, y: p.y - 3.5, width: 7, height: 7)
                    context.fill(Circle().path(in: rect), with: .color(entry.planet.color))
                    context.draw(
                        Text(entry.planet.name).font(.system(size: 9).bold()).foregroundColor(entry.planet.color),
                        at: CGPoint(x: p.x, y: p.y - 10)
                    )
                }

                if let moon, moon.altitude > 0 {
                    let p = point(altitude: moon.altitude, azimuth: moon.azimuth, in: size)
                    context.draw(Image(systemName: MoonPhase.symbolName(for: referenceTime)), at: p)
                }
            }
            .contentShape(Rectangle())
            .clipped()
            .gesture(
                MagnificationGesture()
                    .onChanged { value in
                        scale = min(max(steadyScale * value, minScale), maxScale)
                    }
                    .onEnded { _ in
                        steadyScale = scale
                        if scale <= 1 {
                            panOffset = .zero
                            steadyPanOffset = .zero
                        }
                    }
            )
            .simultaneousGesture(
                DragGesture()
                    .onChanged { value in
                        guard scale > 1 else { return }
                        panOffset = clampedPan(
                            CGSize(width: steadyPanOffset.width + value.translation.width, height: steadyPanOffset.height + value.translation.height),
                            in: size
                        )
                    }
                    .onEnded { _ in
                        steadyPanOffset = panOffset
                    }
            )
            .simultaneousGesture(
                SpatialTapGesture()
                    .onEnded { value in
                        selection = nearestSelection(to: value.location, in: size)
                    }
            )
            .overlay(alignment: .topTrailing) {
                if scale > 1 {
                    Button(action: resetZoom) {
                        Image(systemName: "arrow.down.right.and.arrow.up.left")
                            .font(.caption)
                            .foregroundStyle(.white)
                            .padding(8)
                            .background(.black.opacity(0.35), in: Circle())
                    }
                    .padding(6)
                }
            }
        }
        .sheet(item: $selection) { selection in
            SkyMapDetailSheet(selection: selection)
        }
    }
}

private struct MoonCard: View {
    let moon: MoonInfo
    let snapshot: SnapshotMoon?
    let referenceTime: Date
    let selectedDayStart: Date

    private var selectedDayEnd: Date {
        Calendar.current.date(byAdding: .day, value: 1, to: selectedDayStart) ?? selectedDayStart
    }

    private func firstInSelectedDay(_ dates: [Date]) -> Date? {
        dates.first { $0 >= selectedDayStart && $0 < selectedDayEnd }
    }

    private var rows: [(String, String)] {
        var result: [(String, String)] = []
        if let rise = firstInSelectedDay(moon.rises) { result.append(("Moonrise", rise.formatted(.dateTime.hour().minute()))) }
        if let set = firstInSelectedDay(moon.sets) { result.append(("Moonset", set.formatted(.dateTime.hour().minute()))) }
        if let nextFull = moon.nextFullMoon { result.append(("Next Full Moon", nextFull.formatted(.dateTime.month(.abbreviated).day()))) }
        if let nextNew = moon.nextNewMoon { result.append(("Next New Moon", nextNew.formatted(.dateTime.month(.abbreviated).day()))) }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: MoonPhase.symbolName(for: referenceTime))
                    .font(.system(size: 34))
                    .foregroundStyle(.white)
                    .frame(width: 44)

                VStack(alignment: .leading, spacing: 2) {
                    Text(snapshot?.phaseName ?? "—")
                        .font(.title3.bold())
                    if let snapshot {
                        Text("\(Int(snapshot.illuminationPercent))% illuminated · \(snapshot.ageDays, specifier: "%.1f") days old")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(rows, id: \.0) { row in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.0)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(row.1)
                            .font(.subheadline.bold())
                            .monospacedDigit()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20))
    }
}

private struct SunCard: View {
    let sun: SunInfo
    let selectedDayStart: Date

    private var selectedDayEnd: Date {
        Calendar.current.date(byAdding: .day, value: 1, to: selectedDayStart) ?? selectedDayStart
    }

    private func firstInSelectedDay(_ dates: [Date]) -> Date? {
        dates.first { $0 >= selectedDayStart && $0 < selectedDayEnd }
    }

    private var currentPhase: TwilightPhase {
        currentTwilightPhase(sun: sun, now: Date())
    }

    private var stargazingWindow: String? {
        guard let dusk = firstInSelectedDay(sun.astronomicalDusks),
              let dawn = sun.astronomicalDawns.first(where: { $0 > dusk }) else { return nil }
        return "\(dusk.formatted(.dateTime.hour().minute())) – \(dawn.formatted(.dateTime.hour().minute()))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "sun.max.fill")
                Text("Sun & Twilight")
                    .font(.headline)
                Spacer()
                Text(currentPhase.rawValue)
                    .font(.caption.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.white.opacity(0.15), in: Capsule())
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                if let rise = firstInSelectedDay(sun.rises) {
                    labeledTime("Sunrise", rise)
                }
                if let set = firstInSelectedDay(sun.sets) {
                    labeledTime("Sunset", set)
                }
                if let civilDawn = firstInSelectedDay(sun.civilDawns) {
                    labeledTime("Civil Dawn", civilDawn)
                }
                if let civilDusk = firstInSelectedDay(sun.civilDusks) {
                    labeledTime("Civil Dusk", civilDusk)
                }
            }

            if let stargazingWindow {
                HStack(spacing: 6) {
                    Image(systemName: "moon.stars.fill")
                        .foregroundStyle(.indigo)
                    Text("Darkest skies: \(stargazingWindow)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20))
    }

    private func labeledTime(_ label: String, _ date: Date) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(date.formatted(.dateTime.hour().minute()))
                .font(.subheadline.bold())
                .monospacedDigit()
        }
    }
}

private struct PlanetsCard: View {
    let planets: [PlanetInfo]
    let snapshot: SkySnapshot?
    @Binding var selectedPlanetID: String?
    @Binding var selectedTime: Date?
    let selectedDayOffset: Int
    let selectedDayStart: Date

    private func snapshotAltitude(_ planet: PlanetInfo) -> Double? {
        snapshot?.planets.first { $0.name == planet.name }?.altitude
    }

    private var sortedPlanets: [PlanetInfo] {
        planets.sorted { $0.magnitude < $1.magnitude }
    }

    private var selected: PlanetInfo? {
        planets.first { $0.id == selectedPlanetID } ?? sortedPlanets.first
    }

    private var referenceNow: Date? {
        selectedDayOffset == 0 ? Date() : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "circle.hexagongrid.fill")
                Text("Planets")
                    .font(.headline)
            }

            VStack(spacing: 6) {
                ForEach(sortedPlanets) { planet in
                    Button {
                        selectedPlanetID = planet.id
                        selectedTime = nil
                    } label: {
                        PlanetRow(planet: planet, altitude: snapshotAltitude(planet), isSelected: planet.id == (selectedPlanetID ?? sortedPlanets.first?.id))
                    }
                    .buttonStyle(.plain)
                }
            }

            if let selected {
                MetricChart(
                    title: "\(selected.name) Altitude",
                    color: selected.color,
                    points: dayBoundedPoints(selected.hourly, dayStart: selectedDayStart),
                    value: { $0.altitude },
                    unit: "°",
                    style: .line,
                    iconName: "circle.hexagongrid.fill",
                    direction: { $0.azimuth },
                    referenceNow: referenceNow,
                    selectedTime: $selectedTime,
                    dynamicYScale: true,
                    interpolationMethod: .catmullRom
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20))
    }
}

private struct PlanetRow: View {
    let planet: PlanetInfo
    let altitude: Double?
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(planet.color)
                .frame(width: 10, height: 10)

            Text(planet.name)
                .font(.subheadline.weight(isSelected ? .bold : .regular))
                .foregroundStyle(.primary)

            if !planet.isNakedEyeVisible {
                Text("faint")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(.white.opacity(0.1), in: Capsule())
            }

            Spacer()

            if let altitude {
                Text(altitude > 0 ? "\(Int(altitude))° up" : "below horizon")
                    .font(.caption)
                    .foregroundStyle(altitude > 0 ? .primary : .secondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isSelected ? Color.white.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
    }
}

#Preview {
    StarsView()
        .environmentObject(LocationManager())
}
