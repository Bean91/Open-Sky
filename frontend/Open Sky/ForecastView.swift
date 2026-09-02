//
//  ForecastView.swift
//  Open Sky
//
//  Created by Ben Kiev on 8/21/26.
//

import SwiftUI
import Charts
import CoreLocation
import MapKit
internal import _LocationEssentials

protocol TimeSeriesPoint {
    var time: Date { get }
    static func interpolated(at time: Date, before: Self, after: Self) -> Self
}

/// Filters points to the given local day, synthesizing an interpolated point exactly at the day's
/// start/end boundary whenever the raw data straddles midnight without landing on it — so a day's
/// chart always spans the true full 24-hour window instead of stopping at whatever timestamps
/// happen to exist in the source data.
func dayBoundedPoints<Point: TimeSeriesPoint>(_ points: [Point], dayStart: Date) -> [Point] {
    let start = dayStart
    let end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start
    let sorted = points.sorted { $0.time < $1.time }
    var result = sorted.filter { $0.time >= start && $0.time < end }

    if let firstInside = result.first, firstInside.time > start,
       let beforeStart = sorted.last(where: { $0.time < start }) {
        result.insert(.interpolated(at: start, before: beforeStart, after: firstInside), at: 0)
    }

    if let lastInside = result.last, lastInside.time < end,
       let afterEnd = sorted.first(where: { $0.time >= end }) {
        result.append(.interpolated(at: end, before: lastInside, after: afterEnd))
    }

    return result
}

struct ForecastPoint: Codable, TimeSeriesPoint {
    let time: Date
    let t2m: Double
    let u10: Double
    let v10: Double
    let tp: Double
    let d2m: Double
    let sp: Double
    var tcc: Double
    var pop: Double
    var thunder: Bool

    init(time: Date, t2m: Double, u10: Double, v10: Double, tp: Double, d2m: Double, sp: Double, tcc: Double, pop: Double, thunder: Bool = false) {
        self.time = time
        self.t2m = t2m
        self.u10 = u10
        self.v10 = v10
        self.tp = tp
        self.d2m = d2m
        self.sp = sp
        self.tcc = tcc
        self.pop = pop
        self.thunder = thunder
    }

    static func interpolated(at time: Date, before: ForecastPoint, after: ForecastPoint) -> ForecastPoint {
        let span = after.time.timeIntervalSince(before.time)
        let fraction = span > 0 ? time.timeIntervalSince(before.time) / span : 0
        func lerp(_ a: Double, _ b: Double) -> Double { a + (b - a) * fraction }

        return ForecastPoint(
            time: time,
            t2m: lerp(before.t2m, after.t2m),
            u10: lerp(before.u10, after.u10),
            v10: lerp(before.v10, after.v10),
            tp: lerp(before.tp, after.tp),
            d2m: lerp(before.d2m, after.d2m),
            sp: lerp(before.sp, after.sp),
            tcc: lerp(before.tcc, after.tcc),
            pop: lerp(before.pop, after.pop),
            thunder: fraction < 0.5 ? before.thunder : after.thunder
        )
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        time = try container.decode(Date.self, forKey: .time)
        t2m = try container.decode(Double.self, forKey: .t2m)
        u10 = try container.decode(Double.self, forKey: .u10)
        v10 = try container.decode(Double.self, forKey: .v10)
        tp = try container.decode(Double.self, forKey: .tp)
        d2m = try container.decode(Double.self, forKey: .d2m)
        sp = try container.decode(Double.self, forKey: .sp)
        tcc = try container.decode(Double.self, forKey: .tcc)
        pop = try container.decode(Double.self, forKey: .pop)
        thunder = try container.decodeIfPresent(Bool.self, forKey: .thunder) ?? false
    }
}

private let rainingPopThreshold: Double = 50

private func cloudCoverSymbol(tcc: Double, pop: Double, thunder: Bool) -> String {
    if thunder {
        return "cloud.bolt.rain.fill"
    }
    if pop >= rainingPopThreshold {
        return "cloud.rain.fill"
    }
    switch tcc {
    case ..<20: return "sun.max.fill"
    case 20..<60: return "cloud.sun.fill"
    default: return "cloud.fill"
    }
}

struct ForecastRequest: Codable {
    let lat: Double
    let lon: Double
}

enum ForecastError: Error { case badResponse }

func fetchForecast(lat: Double, lon: Double) async throws -> [ForecastPoint] {
    var request = URLRequest(url: URL(string: "\(BASE_URL)/api/get-forecast")!)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(ForecastRequest(lat: lat, lon: lon))

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
        throw ForecastError.badResponse
    }

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode([ForecastPoint].self, from: data)
}

struct ForecastView: View {
    @EnvironmentObject private var locationManager: LocationManager
    @StateObject private var searchService = LocationSearchService()
    @State private var points: [ForecastPoint]
    @State private var selectedTime: Date?
    @State private var searchText = ""
    @State private var selectedLocation: SelectedLocation?
    @State private var currentLocationLabel: SelectedLocation?
    @State private var selectedDayOffset = 0
    @State private var isRefreshing = false

    @AppStorage("temperatureUnit") private var temperatureUnit = TemperatureUnit.systemDefault
    @AppStorage("windSpeedUnit") private var windSpeedUnit = WindSpeedUnit.metersPerSecond
    @AppStorage("precipitationUnit") private var precipitationUnit = PrecipitationUnit.millimeters

    init(points: [ForecastPoint] = []) {
        _points = State(initialValue: points)
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

    private func loadForecast() async {
        guard let coordinate = activeCoordinate else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        async let fetchTask = fetchForecast(lat: coordinate.latitude, lon: coordinate.longitude)
        async let minimumVisible: Void = {
            try? await Task.sleep(nanoseconds: 500_000_000)
        }()

        do {
            let fetched = try await fetchTask
            _ = await minimumVisible
            points = fetched
        } catch {
            _ = await minimumVisible
            print("Fetch failed: \(error)")
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

    private var selectedDayPoints: [ForecastPoint] {
        dayBoundedPoints(points, dayStart: selectedDayStart)
    }

    private var referenceNow: Date? {
        selectedDayOffset == 0 ? Date() : nil
    }

    private var currentCondition: WeatherCondition {
        guard let nearest = points.min(by: {
            abs($0.time.timeIntervalSinceNow) < abs($1.time.timeIntervalSinceNow)
        }) else { return .clear }

        switch nearest.tp {
        case ..<0.05: return .clear
        case 0.05..<4: return .rain
        default: return .thunderstorm
        }
    }

    var body: some View {
        ZStack {
            WeatherBackgroundView(condition: currentCondition)

            ScrollView {
                VStack(spacing: 16) {
                    DayBar(selectedDayOffset: $selectedDayOffset)

                    if points.isEmpty {
                        ForEach(0..<4, id: \.self) { _ in
                            MetricSkeleton()
                        }
                    } else {
                        MetricChart(
                            title: "Temperature",
                            color: .orange,
                            points: selectedDayPoints,
                            value: { temperatureUnit.convert(fromKelvin: $0.t2m) },
                            unit: temperatureUnit.symbol,
                            style: .line,
                            iconName: "thermometer",
                            referenceNow: referenceNow,
                            selectedTime: $selectedTime,
                            showDayRange: true,
                            dynamicYScale: true
                        )

                        MetricChart(
                            title: "Wind",
                            color: .teal,
                            points: selectedDayPoints,
                            value: { windSpeedUnit.convert(fromMetersPerSecond: sqrt(pow($0.u10, 2) + pow($0.v10, 2))) },
                            unit: windSpeedUnit.symbol,
                            style: .line,
                            iconName: "wind",
                            direction: { point in
                                let degrees = atan2(-point.u10, -point.v10) * 180 / .pi
                                return degrees < 0 ? degrees + 360 : degrees
                            },
                            referenceNow: referenceNow,
                            selectedTime: $selectedTime
                        )

                        MetricChart(
                            title: "Precipitation",
                            color: .blue,
                            points: selectedDayPoints,
                            value: { precipitationUnit.convert(fromMillimeters: $0.tp) },
                            unit: precipitationUnit.symbol,
                            style: .bar,
                            iconName: "drop.fill",
                            referenceNow: referenceNow,
                            selectedTime: $selectedTime,
                            zeroFloorYScale: true
                        )

                        MetricChart(
                            title: "Precip Chance",
                            color: .indigo,
                            points: selectedDayPoints,
                            value: { $0.pop },
                            unit: "%",
                            style: .bar,
                            iconName: "cloud.fill",
                            symbol: { cloudCoverSymbol(tcc: $0.tcc, pop: $0.pop, thunder: $0.thunder) },
                            referenceNow: referenceNow,
                            selectedTime: $selectedTime,
                            fixedYDomain: 0...100
                        )
                    }
                }
                .padding()
            }
            .refreshable {
                await loadForecast()
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
            await loadForecast()
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

struct SearchSuggestionRow: View {
    let title: String
    let subtitle: String?
    let systemImage: String?
    let onSelect: () async -> Void

    @Environment(\.dismissSearch) private var dismissSearch

    var body: some View {
        Button {
            Task {
                await onSelect()
                dismissSearch()
            }
        } label: {
            HStack(spacing: 10) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                }
                VStack(alignment: .leading) {
                    Text(title)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

struct MetricSkeleton: View {
    var body: some View {
        TimelineView(.animation) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate
            let pulse = 0.75 + 0.25 * sin(phase * (2 * .pi / 1.8))

            content
                .opacity(pulse)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle()
                    .frame(width: 18, height: 18)
                RoundedRectangle(cornerRadius: 4)
                    .frame(width: 60, height: 20)
            }
            .frame(height: 28)

            RoundedRectangle(cornerRadius: 12)
                .frame(maxWidth: .infinity)
                .frame(height: 180)
        }
        .foregroundStyle(.secondary.opacity(0.3))
        .frame(maxWidth: .infinity)
        .padding()
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20))
    }
}

private struct OptionalChartYScale: ViewModifier {
    let domain: ClosedRange<Double>?

    func body(content: Content) -> some View {
        if let domain {
            content.chartYScale(domain: domain)
        } else {
            content
        }
    }
}

private struct HeaderWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct MetricChart<Point: TimeSeriesPoint>: View {
    enum Style { case line, bar }

    let title: String
    let color: Color
    let points: [Point]
    let value: (Point) -> Double
    let unit: String
    let style: Style
    let iconName: String
    let direction: ((Point) -> Double)?
    let symbol: ((Point) -> String)?
    let referenceNow: Date?
    let showDayRange: Bool
    let dynamicYScale: Bool
    let zeroFloorYScale: Bool
    let fixedYDomain: ClosedRange<Double>?
    let interpolationMethod: InterpolationMethod

    @Binding var selectedTime: Date?
    @State private var headerX: CGFloat?
    @State private var headerWidth: CGFloat = 0

    init(
        title: String,
        color: Color,
        points: [Point],
        value: @escaping (Point) -> Double,
        unit: String,
        style: Style,
        iconName: String,
        direction: ((Point) -> Double)? = nil,
        symbol: ((Point) -> String)? = nil,
        referenceNow: Date?,
        selectedTime: Binding<Date?>,
        showDayRange: Bool = false,
        dynamicYScale: Bool = false,
        zeroFloorYScale: Bool = false,
        fixedYDomain: ClosedRange<Double>? = nil,
        interpolationMethod: InterpolationMethod = .monotone
    ) {
        self.title = title
        self.color = color
        self.points = points
        self.value = value
        self.unit = unit
        self.style = style
        self.iconName = iconName
        self.direction = direction
        self.symbol = symbol
        self.referenceNow = referenceNow
        self._selectedTime = selectedTime
        self.showDayRange = showDayRange
        self.dynamicYScale = dynamicYScale
        self.zeroFloorYScale = zeroFloorYScale
        self.fixedYDomain = fixedYDomain
        self.interpolationMethod = interpolationMethod
    }

    private func reading(at time: Date) -> (time: Date, value: Double)? {
        let sorted = points.sorted { $0.time < $1.time }
        guard let first = sorted.first, let last = sorted.last else { return nil }

        switch style {
        case .bar:
            let nearest = hourlyBarPoints(sorted: sorted).min { a, b in
                abs(a.time.timeIntervalSince(time)) < abs(b.time.timeIntervalSince(time))
            }
            return nearest.map { ($0.time, $0.value) }

        case .line:
            if time <= first.time { return (first.time, value(first)) }
            if time >= last.time { return (last.time, value(last)) }

            guard let afterIndex = sorted.firstIndex(where: { $0.time >= time }), afterIndex > 0 else {
                return (last.time, value(last))
            }
            let after = sorted[afterIndex]
            let before = sorted[afterIndex - 1]

            let span = after.time.timeIntervalSince(before.time)
            guard span > 0 else { return (before.time, value(before)) }
            let fraction = time.timeIntervalSince(before.time) / span
            return (time, value(before) + (value(after) - value(before)) * fraction)
        }
    }

    private var selected: (time: Date, value: Double)? {
        guard let selectedTime else { return nil }
        return reading(at: selectedTime)
    }

    private func nearestPoint(at time: Date) -> Point? {
        points.min { a, b in
            abs(a.time.timeIntervalSince(time)) < abs(b.time.timeIntervalSince(time))
        }
    }

    private struct LinePoint: Identifiable {
        let id: String
        let time: Date
        let value: Double
        let phase: String
    }

    private func linePoints(now: Date?) -> [LinePoint] {
        let sorted = points.sorted { $0.time < $1.time }
        guard !sorted.isEmpty else { return [] }

        guard let now else {
            return sorted.map { point in
                LinePoint(id: "\(point.time.timeIntervalSince1970)", time: point.time, value: value(point), phase: "Future")
            }
        }

        var result = sorted.map { point in
            LinePoint(
                id: "\(point.time.timeIntervalSince1970)",
                time: point.time,
                value: value(point),
                phase: point.time < now ? "Past" : "Future"
            )
        }

        if let afterIndex = sorted.firstIndex(where: { $0.time >= now }), afterIndex > 0 {
            let before = sorted[afterIndex - 1]
            let after = sorted[afterIndex]
            let span = after.time.timeIntervalSince(before.time)
            let fraction = span > 0 ? now.timeIntervalSince(before.time) / span : 0
            let bridgedValue = value(before) + (value(after) - value(before)) * fraction

            result.insert(LinePoint(id: "now-past", time: now, value: bridgedValue, phase: "Past"), at: afterIndex)
            result.insert(LinePoint(id: "now-future", time: now, value: bridgedValue, phase: "Future"), at: afterIndex + 1)
        }

        return result
    }

    private func areaPoints(now: Date?) -> [LinePoint] {
        var seenTimes = Set<TimeInterval>()
        return linePoints(now: now).filter { seenTimes.insert($0.time.timeIntervalSince1970).inserted }
    }

    private func interpolatedValue(sorted: [Point], at time: Date) -> Double? {
        guard let first = sorted.first, let last = sorted.last else { return nil }
        if time <= first.time { return value(first) }
        if time >= last.time { return value(last) }

        guard let afterIndex = sorted.firstIndex(where: { $0.time >= time }), afterIndex > 0 else {
            return value(last)
        }
        let after = sorted[afterIndex]
        let before = sorted[afterIndex - 1]

        let span = after.time.timeIntervalSince(before.time)
        guard span > 0 else { return value(before) }
        let fraction = time.timeIntervalSince(before.time) / span
        return value(before) + (value(after) - value(before)) * fraction
    }

    private func hourlyBarPoints(sorted: [Point]) -> [LinePoint] {
        guard let first = sorted.first?.time, let last = sorted.last?.time, first <= last else { return [] }

        let calendar = Calendar.current
        var hourTime = calendar.date(bySettingHour: calendar.component(.hour, from: first), minute: 0, second: 0, of: first) ?? first
        if hourTime < first {
            hourTime = calendar.date(byAdding: .hour, value: 1, to: hourTime) ?? hourTime
        }

        var result: [LinePoint] = []
        while hourTime <= last {
            if let v = interpolatedValue(sorted: sorted, at: hourTime) {
                result.append(LinePoint(id: "\(hourTime.timeIntervalSince1970)", time: hourTime, value: v, phase: "Future"))
            }
            guard let next = calendar.date(byAdding: .hour, value: 1, to: hourTime), next > hourTime else { break }
            hourTime = next
        }
        return result
    }

    private var dayHighLow: (high: Double, low: Double)? {
        guard showDayRange, !points.isEmpty else { return nil }
        let values = points.map(value)
        guard let low = values.min(), let high = values.max() else { return nil }
        return (high, low)
    }

    private struct WindCompass: View {
        let degrees: Double

        var body: some View {
            ZStack {
                Circle()
                    .strokeBorder(.secondary.opacity(0.3), lineWidth: 1)
                Image(systemName: "location.north.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.teal)
                    .rotationEffect(.degrees(degrees))
            }
            .frame(width: 18, height: 18)
        }
    }

    @ViewBuilder
    private func header(now: Date) -> some View {
        HStack(spacing: 6) {
            if let direction, let point = nearestPoint(at: selected?.time ?? now) {
                WindCompass(degrees: direction(point))
            } else if let symbol, let point = nearestPoint(at: selected?.time ?? now) {
                Image(systemName: symbol(point))
                    .foregroundStyle(color)
            } else {
                Image(systemName: iconName)
                    .foregroundStyle(color)
            }

            if let selected {
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(selected.value, specifier: "%.1f")\(unit)")
                        .font(.title3.bold())
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                    Text(selected.time, format: .dateTime.hour().minute())
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            } else if let current = reading(at: now) {
                Text("\(current.value, specifier: "%.1f")\(unit)")
                    .font(.title3.bold())
                    .monospacedDigit()
                    .foregroundStyle(.primary)
            } else {
                Text("--")
                    .font(.title3.bold())
                    .foregroundStyle(.secondary)
            }
        }
        .fixedSize()
        .background {
            GeometryReader { geometry in
                Color.clear
                    
                .onAppear {
                    headerWidth = geometry.size.width
                }
                .onChange(of: geometry.size.width) { _, newValue in
                    headerWidth = newValue
                }
            }
        }
    }


    private func clampedHeaderX(_ x: CGFloat, rowWidth: CGFloat) -> CGFloat {
        let halfWidth = max(headerWidth / 2, 20)
        let minX = halfWidth
        let maxX = rowWidth - halfWidth
        guard maxX > minX else { return rowWidth / 2 }
        return min(max(x, minX), maxX)
    }

    private var yDomain: ClosedRange<Double>? {
        if let fixedYDomain { return fixedYDomain }

        let sorted = points.sorted { $0.time < $1.time }
        let values = sorted.map(value)

        if zeroFloorYScale {
            let maxV = values.max() ?? 0
            let ceiling = max(maxV * 1.15, maxV + 0.5, 1)
            return 0...ceiling
        }

        guard dynamicYScale else { return nil }
        guard let minV = values.min(), let maxV = values.max() else { return nil }
        if minV == maxV { return (minV - 1)...(maxV + 1) }
        let padding = max((maxV - minV) * 0.15, 1)
        return (minV - padding)...(maxV + padding)
    }

    var body: some View {
        let sorted = points.sorted { $0.time < $1.time }
        let displayTime = referenceNow ?? sorted.first?.time ?? Date()

        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { rowGeo in
                ZStack(alignment: .leading) {
                    if let headerX, selected != nil {
                        header(now: displayTime)
                            .background(
                                GeometryReader { headerGeo in
                                    Color.clear.preference(key: HeaderWidthKey.self, value: headerGeo.size.width)
                                }
                            )
                            .position(x: clampedHeaderX(headerX, rowWidth: rowGeo.size.width), y: 12)
                    } else {
                        header(now: displayTime)
                            .background(
                                GeometryReader { headerGeo in
                                    Color.clear.preference(key: HeaderWidthKey.self, value: headerGeo.size.width)
                                }
                            )
                            .position(x: max(headerWidth / 2, 20), y: 12)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 28)
            .overlay(alignment: .trailing) {
                if selected == nil, let dayHighLow {
                    Text("H:\(dayHighLow.high, specifier: "%.0f")\(unit)  L:\(dayHighLow.low, specifier: "%.0f")\(unit)")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .onPreferenceChange(HeaderWidthKey.self) { headerWidth = $0 }

            Chart {
                switch style {
                case .line:
                    let areaBaseline = yDomain?.lowerBound ?? 0
                    ForEach(areaPoints(now: referenceNow)) { p in
                        AreaMark(
                            x: .value("Time", p.time),
                            yStart: .value(title, areaBaseline),
                            yEnd: .value(title, p.value)
                        )
                            .interpolationMethod(interpolationMethod)
                            .foregroundStyle(
                                .linearGradient(
                                    colors: [color.opacity(0.55), color.opacity(0.2)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                    }

                    ForEach(linePoints(now: referenceNow)) { p in
                        LineMark(x: .value("Time", p.time), y: .value(title, p.value))
                            .interpolationMethod(interpolationMethod)
                            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                            .foregroundStyle(by: .value("Phase", p.phase))
                    }
                case .bar:
                    ForEach(hourlyBarPoints(sorted: sorted)) { p in
                        let isPast = referenceNow.map { p.time < $0 } ?? false
                        let markColor = isPast ? color.opacity(0.3) : color
                        BarMark(x: .value("Time", p.time), y: .value(title, p.value))
                            .foregroundStyle(markColor.gradient)
                            .cornerRadius(4)
                    }
                }

                if let referenceNow {
                    let current = reading(at: referenceNow)
                    let markerTime = current?.time ?? referenceNow

                    RuleMark(x: .value("Now", markerTime))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                        .foregroundStyle(.secondary.opacity(0.5))

                    if selected == nil, let current {
                        PointMark(x: .value("Now", markerTime), y: .value(title, current.value))
                            .foregroundStyle(color)
                            .symbolSize(50)
                    }
                }

                if let selected {
                    RuleMark(x: .value("Selected", selected.time))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                        .foregroundStyle(.secondary)

                    PointMark(x: .value("Selected", selected.time), y: .value(title, selected.value))
                        .foregroundStyle(color)
                        .symbolSize(80)
                }
            }
            .chartForegroundStyleScale([
                "Past": color.opacity(0.3),
                "Future": color
            ])
            .chartLegend(.hidden)
            .chartXScale(domain: (sorted.first?.time ?? displayTime)...(sorted.last?.time ?? displayTime))
            .modifier(OptionalChartYScale(domain: yDomain))
            .chartPlotStyle { plotArea in
                plotArea.clipped()
            }
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { drag in
                                    guard let plotFrame = proxy.plotFrame else { return }
                                    let originX = geo[plotFrame].origin.x
                                    let xPosition = drag.location.x - originX

                                    guard let firstTime = sorted.first?.time,
                                          let lastTime = sorted.last?.time,
                                          let rawDate: Date = proxy.value(atX: xPosition) else { return }

                                    selectedTime = min(max(rawDate, firstTime), lastTime)
                                }
                                .onEnded { _ in
                                    selectedTime = nil
                                }
                        )
                        .onChange(of: selectedTime) { _, newTime in
                            guard let newTime else { headerX = nil; return }

                            if let firstTime = sorted.first?.time, newTime <= firstTime {
                                headerX = 0
                            } else if let lastTime = sorted.last?.time, newTime >= lastTime {
                                headerX = geo.size.width
                            } else if let plotFrame = proxy.plotFrame {
                                headerX = (proxy.position(forX: newTime) ?? 0) + geo[plotFrame].origin.x
                            }
                        }
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .hour, count: 4)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.hour())
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading)
            }
            .frame(height: 180)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20))
    }
}

extension ForecastPoint {
    static let samples: [ForecastPoint] = {
        let start = Calendar.current.startOfDay(for: .now)
        let totalDays = 14
        return (0...(totalDays * 24)).map { hour in
            let hourOfDay = hour % 24
            let dayIndex = hour / 24
            let hourDouble = Double(hourOfDay)
            let timeOffset = Double(hour) * 3600
            let tempPhase = (hourDouble - 6) / 24 * 2 * .pi
            let windPhase = hourDouble / 24 * 2 * .pi
            let dewPhase = (hourDouble - 6) / 24 * 2 * .pi
            let cloudPhase = (hourDouble - 3) / 24 * 2 * .pi
            let cloudCover = 45 + 35 * sin(cloudPhase)
            let isRainy = [3, 4, 15, 16].contains(hourOfDay)
            let isThundery = hourOfDay == 16
            let seasonalDrift = 3 * sin(Double(dayIndex) / Double(totalDays) * 2 * .pi)

            return ForecastPoint(
                time: start.addingTimeInterval(timeOffset),
                t2m: 300 + seasonalDrift + 10 * sin(tempPhase),
                u10: 2.5 + sin(windPhase),
                v10: 1.0,
                tp: isRainy ? 0.6 * hourDouble : 0.0,
                d2m: 10 + 3 * sin(dewPhase),
                sp: 1013.0,
                tcc: cloudCover,
                pop: isRainy ? 70 + 0.35 * cloudCover : 5 + 0.3 * cloudCover,
                thunder: isThundery
            )
        }
    }()
}

#Preview {
    ForecastView(points: ForecastPoint.samples)
        .environmentObject(LocationManager())
}
