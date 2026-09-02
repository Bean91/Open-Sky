//
//  AppSettings.swift
//  Open Sky
//
//  Created by Ben Kiev on 8/25/26.
//

import SwiftUI

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum TemperatureUnit: String, CaseIterable, Identifiable {
    case celsius, kelvin, fahrenheit

    var id: String { rawValue }
    var label: String { self == .kelvin ? "Kelvin (K)" : self == .celsius ? "Celsius (°C)" : "Fahrenheit (°F)" }
    var symbol: String { self == .kelvin ? "K" : self == .celsius ? "°C" : "°F" }

    func convert(fromKelvin value: Double) -> Double {
        self == .kelvin ? value : self == .celsius ? value - 273.15 : (value - 273.15) * 9 / 5 + 32
    }

    /// Sensible first-launch default before the user has picked one in Settings — Kelvin is a poor
    /// default for a weather app, so infer Fahrenheit/Celsius from the device's measurement system.
    static var systemDefault: TemperatureUnit {
        Locale.current.measurementSystem == .us ? .fahrenheit : .celsius
    }
}

enum WindSpeedUnit: String, CaseIterable, Identifiable {
    case metersPerSecond, milesPerHour, kilometersPerHour

    var id: String { rawValue }

    var label: String {
        switch self {
        case .metersPerSecond: "Meters per Second (m/s)"
        case .milesPerHour: "Miles per Hour (mph)"
        case .kilometersPerHour: "Kilometers per Hour (km/h)"
        }
    }

    var symbol: String {
        switch self {
        case .metersPerSecond: " m/s"
        case .milesPerHour: " mph"
        case .kilometersPerHour: " km/h"
        }
    }

    func convert(fromMetersPerSecond value: Double) -> Double {
        switch self {
        case .metersPerSecond: value
        case .milesPerHour: value * 2.23694
        case .kilometersPerHour: value * 3.6
        }
    }
}

enum PrecipitationUnit: String, CaseIterable, Identifiable {
    case millimeters, inches

    var id: String { rawValue }
    var label: String { self == .millimeters ? "Millimeters (mm)" : "Inches (in)" }
    var symbol: String { self == .millimeters ? " mm" : " in" }

    func convert(fromMillimeters value: Double) -> Double {
        self == .millimeters ? value : value * 0.0393700787
    }
}
