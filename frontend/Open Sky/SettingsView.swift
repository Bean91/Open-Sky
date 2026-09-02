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
