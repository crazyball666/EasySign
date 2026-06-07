//
//  EasySignApp.swift
//  EasySign
//
//  Created by crazyball on 2024/7/13.
//

import SwiftUI
import AppKit

@main
struct EasySignApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var hub: ServiceHub

    init() {
        let h = ServiceHub.live()
        h.validate()
        h.transfer.start()
        _hub = State(initialValue: h)
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            RootView(hub: hub)
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView(settings: hub.settings, transfer: hub.transfer)
        }

        MenuBarExtra("互传", systemImage: "arrow.left.arrow.right") {
            TransferMenuBar(service: hub.transfer)
        }
    }
}

/// 关闭最后一个窗口时不退出 App —— 互传/剪贴板同步需要常驻后台。
/// 保留 Dock 图标(不设置 LSUIElement),窗口可从菜单栏重新打开。
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
