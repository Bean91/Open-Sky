//
//  MoonPhase.swift
//  Open Sky
//
//  Created by Ben Kiev on 8/21/26.
//

import Foundation

enum MoonPhase {
    private static let referenceNewMoon: Date = {
        var components = DateComponents()
        components.year = 2000
        components.month = 1
        components.day = 6
        components.hour = 18
        components.minute = 14
        components.timeZone = TimeZone(secondsFromGMT: 0)
        return Calendar.current.date(from: components)!
    }()

    private static let lunarMonthSeconds: TimeInterval = 29.530588853 * 24 * 60 * 60

    static func cyclePosition(for date: Date = Date()) -> Double {
        let secondsSinceReference = date.timeIntervalSince(referenceNewMoon)
        let remainder = secondsSinceReference.truncatingRemainder(dividingBy: lunarMonthSeconds)
        let position = remainder / lunarMonthSeconds
        return position < 0 ? position + 1.0 : position
    }

    static func symbolName(for date: Date = Date()) -> String {
        let position = cyclePosition(for: date)

        switch position {
        case 0.035..<0.215: return "moonphase.waxing.crescent"
        case 0.215..<0.285: return "moonphase.first.quarter"
        case 0.285..<0.465: return "moonphase.waxing.gibbous"
        case 0.465..<0.535: return "moonphase.full.moon"
        case 0.535..<0.715: return "moonphase.waning.gibbous"
        case 0.715..<0.785: return "moonphase.last.quarter"
        case 0.785..<0.965: return "moonphase.waning.crescent"
        default: return "moonphase.new.moon"
        }
    }
}
