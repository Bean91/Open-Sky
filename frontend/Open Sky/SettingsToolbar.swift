//
//  SettingsToolbar.swift
//  Open Sky
//
//  Created by Ben Kiev on 8/21/26.
//

import SwiftUI

struct SettingsToolbar: ViewModifier {
    @State private var showSettings = false

    func body(content: Content) -> some View {
        NavigationStack {
            content
                .toolbar {
                    #if os(iOS)
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                        }
                    }
                    #else
                    ToolbarItem(placement: .automatic) {
                        Button {
                            showSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                        }
                    }
                    #endif
                }
                .sheet(isPresented: $showSettings) {
                    SettingsView()
                }
        }
    }
}

extension View {
    func withSettingsToolbar() -> some View {
        modifier(SettingsToolbar())
    }
}
