//
//  MapView.swift
//  Open Sky
//
//  Created by Ben Kiev on 8/21/26.
//

import SwiftUI
import MapKit
import CoreLocation
import UIKit

enum GlobalMapField: String, CaseIterable, Identifiable {
    case temperature, windSpeed, precipitation, dewPoint, pressure, cloudCover

    var id: String { rawValue }

    var label: String {
        switch self {
        case .temperature: "Temperature"
        case .windSpeed: "Wind Speed"
        case .precipitation: "Precipitation"
        case .dewPoint: "Dew Point"
        case .pressure: "Pressure"
        case .cloudCover: "Cloud Cover"
        }
    }

    var iconName: String {
        switch self {
        case .temperature: "thermometer"
        case .windSpeed: "wind"
        case .precipitation: "drop.fill"
        case .dewPoint: "humidity.fill"
        case .pressure: "gauge.with.dots.needle.50percent"
        case .cloudCover: "cloud.fill"
        }
    }

    var backendFields: [String] {
        switch self {
        case .temperature: ["t2m"]
        case .windSpeed: ["u10", "v10"]
        case .precipitation: ["tp"]
        case .dewPoint: ["d2m"]
        case .pressure: ["sp"]
        case .cloudCover: ["tcc"]
        }
    }

    var colorScale: MapColorScale {
        switch self {
        case .temperature: .temperature
        case .windSpeed: .windSpeed
        case .precipitation: .precipitation
        case .dewPoint: .dewPoint
        case .pressure: .pressure
        case .cloudCover: .cloudCover
        }
    }
}

struct MapColorScale {
    let minValue: Double
    let maxValue: Double
    let stops: [(t: Double, color: (UInt8, UInt8, UInt8))]

    func rgba(for value: Double) -> (UInt8, UInt8, UInt8, UInt8) {
        guard maxValue > minValue, let first = stops.first, let last = stops.last else {
            return (128, 128, 128, 160)
        }
        let clamped = min(max(value, minValue), maxValue)
        let t = (clamped - minValue) / (maxValue - minValue)

        if t <= first.t { return (first.color.0, first.color.1, first.color.2, 190) }
        if t >= last.t { return (last.color.0, last.color.1, last.color.2, 190) }

        for i in 0..<(stops.count - 1) {
            let a = stops[i]
            let b = stops[i + 1]
            guard t >= a.t && t <= b.t else { continue }
            let span = b.t - a.t
            let localT = span > 0 ? (t - a.t) / span : 0
            let r = UInt8((Double(a.color.0) + (Double(b.color.0) - Double(a.color.0)) * localT).rounded())
            let g = UInt8((Double(a.color.1) + (Double(b.color.1) - Double(a.color.1)) * localT).rounded())
            let bch = UInt8((Double(a.color.2) + (Double(b.color.2) - Double(a.color.2)) * localT).rounded())
            return (r, g, bch, 190)
        }
        return (128, 128, 128, 160)
    }
}

extension MapColorScale {
    static let temperature = MapColorScale(
        minValue: 223.15, maxValue: 313.15,
        stops: [
            (0.0, (68, 39, 122)),
            (0.16, (49, 104, 180)),
            (0.34, (79, 179, 209)),
            (0.5, (178, 223, 187)),
            (0.62, (247, 233, 149)),
            (0.78, (249, 156, 82)),
            (1.0, (191, 43, 46))
        ]
    )

    static let windSpeed = MapColorScale(
        minValue: 0, maxValue: 25,
        stops: [
            (0.0, (233, 245, 250)),
            (0.28, (146, 210, 224)),
            (0.52, (99, 178, 138)),
            (0.72, (233, 196, 76)),
            (0.88, (232, 121, 63)),
            (1.0, (191, 54, 120))
        ]
    )

    static let precipitation = MapColorScale(
        minValue: 0, maxValue: 8,
        stops: [
            (0.0, (246, 251, 255)),
            (0.25, (198, 228, 250)),
            (0.5, (129, 191, 235)),
            (0.75, (69, 130, 214)),
            (1.0, (37, 56, 143))
        ]
    )

    static let dewPoint = MapColorScale(
        minValue: 243.15, maxValue: 303.15,
        stops: [
            (0.0, (150, 100, 40)),
            (0.3, (168, 178, 96)),
            (0.55, (137, 201, 138)),
            (0.78, (99, 189, 178)),
            (1.0, (65, 122, 199))
        ]
    )

    static let pressure = MapColorScale(
        minValue: 97000, maxValue: 105000,
        stops: [
            (0.0, (94, 79, 162)),
            (0.35, (139, 140, 202)),
            (0.5, (245, 245, 247)),
            (0.65, (240, 190, 122)),
            (1.0, (214, 128, 44))
        ]
    )

    static let cloudCover = MapColorScale(
        minValue: 0, maxValue: 100,
        stops: [
            (0.0, (255, 255, 255)),
            (0.5, (196, 208, 224)),
            (1.0, (94, 105, 128))
        ]
    )
}

struct GlobalMapPayload {
    let field: GlobalMapField
    let lat: [Double]
    let lon: [Double]
    let times: [Date]
    let values: [[[Double]]]
}

private struct RawGlobalMapResponse: Decodable {
    let field: String
    let lat: [Double]
    let lon: [Double]
    let times: [String]
    let values: [[[Double]]]
}

private let globalMapTimeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.locale = Locale(identifier: "en_US_POSIX")
    return formatter
}()

private func fetchGlobalMapField(_ key: String) async throws -> RawGlobalMapResponse {
    guard let url = URL(string: "\(BASE_URL)/api/global-map?field=\(key)") else {
        throw URLError(.badURL)
    }
    let (data, response) = try await URLSession.shared.data(from: url)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
        throw ForecastError.badResponse
    }
    return try JSONDecoder().decode(RawGlobalMapResponse.self, from: data)
}

private func fetchGlobalMap(_ field: GlobalMapField) async throws -> GlobalMapPayload {
    let keys = field.backendFields

    if keys.count == 1 {
        let raw = try await fetchGlobalMapField(keys[0])
        return GlobalMapPayload(
            field: field,
            lat: raw.lat,
            lon: raw.lon,
            times: raw.times.compactMap { globalMapTimeFormatter.date(from: $0) },
            values: raw.values
        )
    }

    async let uResponse = fetchGlobalMapField(keys[0])
    async let vResponse = fetchGlobalMapField(keys[1])
    let (u, v) = try await (uResponse, vResponse)

    let frameCount = min(u.values.count, v.values.count)
    var combined: [[[Double]]] = []
    combined.reserveCapacity(frameCount)

    for f in 0..<frameCount {
        let uFrame = u.values[f]
        let vFrame = v.values[f]
        var frameGrid: [[Double]] = []
        frameGrid.reserveCapacity(uFrame.count)

        for latIdx in 0..<uFrame.count {
            let uRow = uFrame[latIdx]
            let vRow = latIdx < vFrame.count ? vFrame[latIdx] : []
            var row: [Double] = []
            row.reserveCapacity(uRow.count)
            for lonIdx in 0..<uRow.count {
                let uVal = uRow[lonIdx]
                let vVal = lonIdx < vRow.count ? vRow[lonIdx] : 0
                row.append((uVal * uVal + vVal * vVal).squareRoot())
            }
            frameGrid.append(row)
        }
        combined.append(frameGrid)
    }

    return GlobalMapPayload(
        field: field,
        lat: u.lat,
        lon: u.lon,
        times: u.times.compactMap { globalMapTimeFormatter.date(from: $0) },
        values: combined
    )
}

private func makeHeatmapImage(lat: [Double], lon: [Double], grid: [[Double]], colorScale: MapColorScale, width: Int, height: Int) -> CGImage? {
    guard !lat.isEmpty, !lon.isEmpty, !grid.isEmpty, grid[0].count == lon.count else { return nil }

    let latCount = lat.count
    let lonCount = lon.count
    guard latCount > 1, lonCount > 1 else { return nil }
    let latStep = (lat[latCount - 1] - lat[0]) / Double(latCount - 1)
    let lonStep = (lon[lonCount - 1] - lon[0]) / Double(lonCount - 1)
    guard latStep != 0, lonStep != 0 else { return nil }

    let worldRect = MKMapRect.world
    var pixels = [UInt8](repeating: 0, count: width * height * 4)

    func sample(latitude: Double, longitude: Double) -> Double {
        let rawLatIdx = (latitude - lat[0]) / latStep
        var rawLonIdx = (longitude - lon[0]) / lonStep
        if rawLonIdx < 0 { rawLonIdx += Double(lonCount) }

        let lat0 = Int(floor(rawLatIdx))
        let lat1 = lat0 + 1
        let latFrac = rawLatIdx - Double(lat0)
        let clampedLat0 = min(max(lat0, 0), latCount - 1)
        let clampedLat1 = min(max(lat1, 0), latCount - 1)

        let lon0Floor = Int(floor(rawLonIdx))
        let lonFrac = rawLonIdx - Double(lon0Floor)
        let lon0 = ((lon0Floor % lonCount) + lonCount) % lonCount
        let lon1 = (lon0 + 1) % lonCount

        let v00 = grid[clampedLat0][lon0]
        let v01 = grid[clampedLat0][lon1]
        let v10 = grid[clampedLat1][lon0]
        let v11 = grid[clampedLat1][lon1]

        let top = v00 + (v01 - v00) * lonFrac
        let bottom = v10 + (v11 - v10) * lonFrac
        return top + (bottom - top) * latFrac
    }

    for py in 0..<height {
        let mapY = worldRect.origin.y + (Double(py) / Double(height)) * worldRect.height
        let latitude = MKMapPoint(x: worldRect.midX, y: mapY).coordinate.latitude

        for px in 0..<width {
            let mapX = worldRect.origin.x + (Double(px) / Double(width)) * worldRect.width
            var longitude = MKMapPoint(x: mapX, y: worldRect.midY).coordinate.longitude
            if longitude < 0 { longitude += 360 }

            let value = sample(latitude: latitude, longitude: longitude)
            let (r, g, b, a) = colorScale.rgba(for: value)
            let offset = (py * width + px) * 4
            pixels[offset] = r
            pixels[offset + 1] = g
            pixels[offset + 2] = b
            pixels[offset + 3] = a
        }
    }

    guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
    return CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
        provider: provider,
        decode: nil,
        shouldInterpolate: true,
        intent: .defaultIntent
    )
}

private final class HeatmapOverlay: NSObject, MKOverlay {
    let coordinate: CLLocationCoordinate2D
    let boundingMapRect: MKMapRect
    let cgImage: CGImage

    init(image: CGImage, mapRect: MKMapRect) {
        self.cgImage = image
        self.boundingMapRect = mapRect
        self.coordinate = CLLocationCoordinate2D(latitude: 0, longitude: 0)
    }
}

private final class HeatmapOverlayRenderer: MKOverlayRenderer {
    private let cgImage: CGImage

    init(overlay: HeatmapOverlay) {
        self.cgImage = overlay.cgImage
        super.init(overlay: overlay)
    }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        let drawRect = rect(for: overlay.boundingMapRect)
        context.saveGState()
        context.translateBy(x: 0, y: drawRect.minY + drawRect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(cgImage, in: drawRect)
        context.restoreGState()
    }
}

private struct HeatmapMapView: UIViewRepresentable {
    var image: CGImage?

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.mapType = .mutedStandard
        mapView.pointOfInterestFilter = .excludingAll
        mapView.isZoomEnabled = true
        mapView.isScrollEnabled = true
        mapView.isPitchEnabled = false
        mapView.isRotateEnabled = false
        mapView.showsUserLocation = true
        mapView.setVisibleMapRect(.world, animated: false)
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        guard image !== context.coordinator.lastImage else { return }
        context.coordinator.lastImage = image

        mapView.removeOverlays(mapView.overlays)
        if let image {
            mapView.addOverlay(HeatmapOverlay(image: image, mapRect: .world), level: .aboveLabels)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var lastImage: CGImage?

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let heatmap = overlay as? HeatmapOverlay {
                return HeatmapOverlayRenderer(overlay: heatmap)
            }
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}

struct MapView: View {
    @State private var selectedField: GlobalMapField = .temperature
    @State private var payload: GlobalMapPayload?
    @State private var frameImages: [CGImage] = []
    @State private var frameIndex: Int = 0
    @State private var isPlaying = false
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var playbackTask: Task<Void, Never>?

    @AppStorage("temperatureUnit") private var temperatureUnit = TemperatureUnit.systemDefault
    @AppStorage("windSpeedUnit") private var windSpeedUnit = WindSpeedUnit.metersPerSecond
    @AppStorage("precipitationUnit") private var precipitationUnit = PrecipitationUnit.millimeters

    private var frameIndexBinding: Binding<Double> {
        Binding(
            get: { Double(frameIndex) },
            set: { newValue in
                stopPlayback()
                frameIndex = Int(newValue.rounded())
            }
        )
    }

    var body: some View {
        HeatmapMapView(image: frameImages.indices.contains(frameIndex) ? frameImages[frameIndex] : nil)
            .ignoresSafeArea()
            .overlay(alignment: .top) {
                HStack {
                    fieldPicker
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
                    }
                }
                .padding()
            }
            .overlay(alignment: .bottom) {
                VStack(spacing: 10) {
                    legend
                    playbackBar
                }
                .padding()
            }
            .task(id: selectedField) {
                await loadField()
            }
            .onDisappear {
                stopPlayback()
            }
    }

    private var fieldPicker: some View {
        Menu {
            ForEach(GlobalMapField.allCases) { field in
                Button {
                    guard field != selectedField else { return }
                    stopPlayback()
                    selectedField = field
                } label: {
                    Label(field.label, systemImage: field.iconName)
                }
            }
        } label: {
            Image(systemName: selectedField.iconName)
                .font(.title3)
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .glassEffect(.regular, in: Circle())
        }
    }

    private var legend: some View {
        VStack(spacing: 6) {
            LinearGradient(
                stops: selectedField.colorScale.stops.map {
                    .init(
                        color: Color(
                            red: Double($0.color.0) / 255,
                            green: Double($0.color.1) / 255,
                            blue: Double($0.color.2) / 255
                        ),
                        location: $0.t
                    )
                },
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(height: 10)
            .clipShape(Capsule())

            HStack {
                Text(legendLabel(for: selectedField.colorScale.minValue))
                Spacer()
                Text(selectedField.label)
                    .font(.caption.bold())
                Spacer()
                Text(legendLabel(for: selectedField.colorScale.maxValue))
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
    }

    private var playbackBar: some View {
        HStack(spacing: 12) {
            Button {
                togglePlayback()
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.body.bold())
                    .frame(width: 32, height: 32)
            }
            .disabled(frameImages.count < 2)

            VStack(spacing: 2) {
                Slider(value: frameIndexBinding, in: 0...Double(max(frameImages.count - 1, 1)), step: 1)
                    .disabled(frameImages.count < 2)

                if let payload, payload.times.indices.contains(frameIndex) {
                    Text(frameIndex == 0 ? "Now" : payload.times[frameIndex].formatted(date: .omitted, time: .shortened))
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18))
    }

    private func legendLabel(for rawValue: Double) -> String {
        switch selectedField {
        case .temperature, .dewPoint:
            return "\(Int(temperatureUnit.convert(fromKelvin: rawValue).rounded()))\(temperatureUnit.symbol)"
        case .windSpeed:
            return "\(Int(windSpeedUnit.convert(fromMetersPerSecond: rawValue).rounded()))\(windSpeedUnit.symbol)"
        case .precipitation:
            return "\(String(format: "%.1f", precipitationUnit.convert(fromMillimeters: rawValue)))\(precipitationUnit.symbol)"
        case .pressure:
            return "\(Int((rawValue / 100).rounded())) hPa"
        case .cloudCover:
            return "\(Int(rawValue))%"
        }
    }

    private func loadField() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }

        do {
            let field = selectedField
            let result = try await fetchGlobalMap(field)
            guard field == selectedField else { return }

            let images = await buildFrameImages(for: result)
            guard field == selectedField else { return }

            payload = result
            frameImages = images
            frameIndex = 0
        } catch {
            loadError = "Couldn't load map data"
            print("Global map fetch failed: \(error)")
        }
    }

    private func buildFrameImages(for payload: GlobalMapPayload) async -> [CGImage] {
        let lat = payload.lat
        let lon = payload.lon
        let values = payload.values
        let colorScale = payload.field.colorScale

        return await Task.detached(priority: .userInitiated) {
            values.compactMap { frameGrid in
                makeHeatmapImage(lat: lat, lon: lon, grid: frameGrid, colorScale: colorScale, width: 540, height: 300)
            }
        }.value
    }

    private func togglePlayback() {
        if isPlaying {
            stopPlayback()
            return
        }

        isPlaying = true
        playbackTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 900_000_000)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard !frameImages.isEmpty else { return }
                    frameIndex = (frameIndex + 1) % frameImages.count
                }
            }
        }
    }

    private func stopPlayback() {
        isPlaying = false
        playbackTask?.cancel()
        playbackTask = nil
    }
}

#Preview {
    MapView()
}
