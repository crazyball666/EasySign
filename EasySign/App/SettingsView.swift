import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var transfer: TransferService
    @ObservedObject var update: UpdateService

    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    var body: some View {
        TabView {
            generalTab.tabItem { Label("常规", systemImage: "gear") }
            filesTab.tabItem { Label("文件", systemImage: "doc") }
            transferTab.tabItem { Label("互传", systemImage: "arrow.left.arrow.right") }
            aboutTab.tabItem { Label("关于", systemImage: "info.circle") }
        }
        .frame(width: 480, height: 320)
    }

    private var generalTab: some View {
        Form {
            Toggle("启动时恢复上次工具", isOn: launchRestoresBinding)
            Toggle("启用实验性功能", isOn: experimentalBinding)
            Toggle("启动时自动检查更新", isOn: Binding(
                get: { update.autoCheckEnabled },
                set: { update.autoCheckEnabled = $0 }
            ))
            Button("检查更新…") { update.checkForUpdates(silent: false) }
        }
        .padding(16)
    }

    private var filesTab: some View {
        Form {
            Stepper(value: recentFilesCapBinding, in: 1...50) {
                Text("最近文件保留数量：\(recentFilesCapBinding.wrappedValue)")
            }
            Stepper(value: logRetentionBinding, in: 7...90) {
                Text("日志保留天数：\(logRetentionBinding.wrappedValue)")
            }
            HStack {
                Text("工作区保留天数")
                Spacer()
                Text("\(workspaceRetentionBinding.wrappedValue)")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
    }

    private var transferTab: some View {
        Form {
            TextField("设备名", text: deviceNameBinding)
            Toggle("开机自启", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { newValue in
                    LaunchAtLogin.setEnabled(newValue)
                }
            Toggle("隐身模式(不广播 Bonjour)", isOn: stealthBinding)
            Stepper(value: retentionBinding, in: 0...365) {
                Text(retentionBinding.wrappedValue == 0
                     ? "历史保留天数：永久"
                     : "历史保留天数：\(retentionBinding.wrappedValue)")
            }
            HStack {
                Button("清空传输历史") { transfer.clearHistory() }
                Button("清空已配对设备") { transfer.clearPairedDevices() }
            }
        }
        .padding(16)
    }

    private var aboutTab: some View {
        VStack(spacing: 8) {
            Image(systemName: "signature")
                .font(.system(size: 48))
                .foregroundStyle(.blue)
            Text("EasySign").font(.title)
            Text("iOS/macOS 重签 + 工具集")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding()
    }

    private var launchRestoresBinding: Binding<Bool> {
        Binding(
            get: { settings.bool(.launchRestoresLastTool) },
            set: { settings.set($0, for: .launchRestoresLastTool) }
        )
    }

    private var experimentalBinding: Binding<Bool> {
        Binding(
            get: { settings.bool(.enableExperimental) },
            set: { settings.set($0, for: .enableExperimental) }
        )
    }

    private var recentFilesCapBinding: Binding<Int> {
        Binding(
            get: { max(1, settings.int(.recentFilesCap) == 0 ? 20 : settings.int(.recentFilesCap)) },
            set: { settings.set($0, for: .recentFilesCap) }
        )
    }

    private var logRetentionBinding: Binding<Int> {
        Binding(
            get: { settings.int(.logRetentionDays) == 0 ? 30 : settings.int(.logRetentionDays) },
            set: { settings.set($0, for: .logRetentionDays) }
        )
    }

    private var workspaceRetentionBinding: Binding<Int> {
        Binding(
            get: { settings.int(.workspaceRetentionDays) == 0 ? 7 : settings.int(.workspaceRetentionDays) },
            set: { settings.set($0, for: .workspaceRetentionDays) }
        )
    }

    private var deviceNameBinding: Binding<String> {
        Binding(
            get: { transfer.deviceName },
            set: { transfer.setDeviceName($0) }
        )
    }

    private var retentionBinding: Binding<Int> {
        Binding(
            get: { settings.int(.transferRetentionDays) },   // 0 = 永久
            set: { settings.set($0, for: .transferRetentionDays) }
        )
    }

    private var stealthBinding: Binding<Bool> {
        Binding(
            get: { settings.bool(.transferStealthMode) },
            set: {
                settings.set($0, for: .transferStealthMode)
                transfer.setStealthMode($0)
            }
        )
    }
}
