//
//  Open_SkyApp.swift
//  Open Sky
//
//  Created by Ben Kiev on 8/21/26.
//

import SwiftUI

let BASE_URL: String = "https://sky.openoted.com"

@main
struct Open_SkyApp: App {
    @StateObject private var locationManager = LocationManager()
    @AppStorage("appearanceMode") private var appearanceMode = AppearanceMode.system

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(locationManager)
                .preferredColorScheme(appearanceMode.colorScheme)
        }
    }
}
