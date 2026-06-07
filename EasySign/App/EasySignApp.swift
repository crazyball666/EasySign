//
//  EasySignApp.swift
//  EasySign
//
//  Created by crazyball on 2024/7/13.
//

import SwiftUI

@main
struct EasySignApp: App {
    @State private var hub: ServiceHub

    init() {
        let h = ServiceHub.live()
        h.validate()
        h.transfer.start()
        _hub = State(initialValue: h)
    }

    var body: some Scene {
        WindowGroup {
            RootView(hub: hub)
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView(settings: hub.settings)
        }
    }
}
