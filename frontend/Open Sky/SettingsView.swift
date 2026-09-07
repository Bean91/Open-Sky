//
//  SettingsView.swift
//  Open Sky
//
//  Created by Ben Kiev on 8/21/26.
//

import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @AppStorage("appearanceMode") private var appearanceMode = AppearanceMode.system
    @AppStorage("temperatureUnit") private var temperatureUnit = TemperatureUnit.systemDefault
    @AppStorage("windSpeedUnit") private var windSpeedUnit = WindSpeedUnit.metersPerSecond
    @AppStorage("precipitationUnit") private var precipitationUnit = PrecipitationUnit.millimeters
    @AppStorage("tideHeightUnit") private var tideHeightUnit = TideHeightUnit.meters
    @AppStorage("forecastSmoothingLevel") private var forecastSmoothingLevel = ForecastSmoothingLevel.medium

    private var smoothingSliderValue: Binding<Double> {
        Binding(
            get: { Double(forecastSmoothingLevel.rawValue) },
            set: { forecastSmoothingLevel = ForecastSmoothingLevel(rawValue: Int($0.rounded())) ?? .medium }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Appearance") {
                    Picker("Appearance", selection: $appearanceMode) {
                        ForEach(AppearanceMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Units") {
                    Picker("Temperature", selection: $temperatureUnit) {
                        ForEach(TemperatureUnit.allCases) { unit in
                            Text(unit.label).tag(unit)
                        }
                    }
                    Picker("Wind Speed", selection: $windSpeedUnit) {
                        ForEach(WindSpeedUnit.allCases) { unit in
                            Text(unit.label).tag(unit)
                        }
                    }
                    Picker("Precipitation", selection: $precipitationUnit) {
                        ForEach(PrecipitationUnit.allCases) { unit in
                            Text(unit.label).tag(unit)
                        }
                    }
                    Picker("Tide Height", selection: $tideHeightUnit) {
                        ForEach(TideHeightUnit.allCases) { unit in
                            Text(unit.label).tag(unit)
                        }
                    }
                }

                Section("Forecast") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Graph Smoothing")
                            Spacer()
                            Text(forecastSmoothingLevel.label)
                                .foregroundStyle(.secondary)
                        }
                        Slider(
                            value: smoothingSliderValue,
                            in: 0...Double(ForecastSmoothingLevel.allCases.count - 1),
                            step: 1
                        )
                        HStack {
                            Text("Most Accurate")
                            Spacer()
                            Text("Most Smooth")
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    SettingsView()
}
