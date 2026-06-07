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
        h.update.maybeAutoCheckOnLaunch()
        _hub = State(initialValue: h)
    }

    var body: some Scene {
        Window("EasySign", id: "main") {
            RootView(hub: hub)
                .modifier(UpdateSheet(service: hub.update))
        }
        .windowResizability(.contentSize)
        .commands { UpdateCommands(update: hub.update) }

        Settings {
            SettingsView(settings: hub.settings, transfer: hub.transfer, update: hub.update)
        }

        MenuBarExtra("互传", systemImage: "arrow.left.arrow.right") {
            TransferMenuBar(service: hub.transfer)
        }
    }
}

struct UpdateCommands: Commands {
    let update: UpdateService
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("检查更新…") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
                update.checkForUpdates(silent: false)
            }
        }
    }
}

/// 把更新 sheet 与"已是最新/错误"提示挂到主窗口。
struct UpdateSheet: ViewModifier {
    @ObservedObject var service: UpdateService
    func body(content: Content) -> some View {
        content
            .sheet(item: $service.availableUpdate) { info in
                UpdateView(service: service, update: info)
            }
            .alert("已是最新版本", isPresented: $service.upToDateNotice) {
                Button("好") { }
            }
            .alert("检查更新", isPresented: Binding(
                get: { service.lastCheckError != nil },
                set: { if !$0 { service.lastCheckError = nil } }
            )) { Button("好") { } } message: { Text(service.lastCheckError ?? "") }
    }
}

/// 关闭最后一个窗口时不退出 App —— 互传/剪贴板同步需要常驻后台。
/// 保留 Dock 图标(不设置 LSUIElement),窗口可从菜单栏重新打开。
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
