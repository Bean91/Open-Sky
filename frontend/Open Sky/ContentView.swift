//
//  ContentView.swift
//  Open Sky
//
//  Created by Ben Kiev on 8/21/26.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            
            Tab("Forecast", systemImage: "cloud.sun") {
                ForecastView().withSettingsToolbar()
            }
            
            Tab("Map", systemImage: "map") {
                MapView().withSettingsToolbar()
            }
            
            Tab("Tides", systemImage: "water.waves") {
                TidesView().withSettingsToolbar()
            }
            
            Tab("Stars", systemImage: MoonPhase.symbolName()) {
                StarsView().withSettingsToolbar()
            }
            
            Tab("Planes", systemImage: "airplane") {
                PlanesView().withSettingsToolbar()
            }
        }
        #if os(iOS)
        .tabBarMinimizeBehavior(.onScrollDown)
        #endif
    }
}

#Preview {
    ContentView()
        .environmentObject(LocationManager())
}
