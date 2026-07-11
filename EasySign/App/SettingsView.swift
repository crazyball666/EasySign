import SwiftUI
import AppKit

struct SettingsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var settings: SettingsStore
    @ObservedObject var transfer: TransferService
    @ObservedObject var update: UpdateService

    @Environment(\.openWindow) private var openWindow
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    var body: some View {
        GlassCanvas {
            TabView {
                generalTab.tabItem { Label("常规", systemImage: "gear") }
                filesTab.tabItem { Label("文件", systemImage: "doc") }
                transferTab.tabItem { Label("互传", systemImage: "arrow.left.arrow.right") }
                aboutTab.tabItem { Label("关于", systemImage: "info.circle") }
            }
            .padding(GlassMetric.spacingS)
        }
        .frame(width: 500, height: 380)
    }

    private var generalTab: some View {
        Form {
                Section("工作台") {
                    Picker("外观", selection: interfaceThemeBinding) {
                        ForEach(GlassThemePreference.allCases) { preference in
                            Text(preference.title).tag(preference.rawValue)
                        }
                    }
                    Text("外观变更会立即应用到主窗口与设置。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Toggle("启动时恢复上次工具", isOn: launchRestoresBinding)
                    Toggle("启用实验性功能", isOn: experimentalBinding)
                }
                Section("更新") {
                    Toggle("启动时自动检查更新", isOn: Binding(
                        get: { update.autoCheckEnabled },
                        set: { update.autoCheckEnabled = $0 }
                    ))
                    Button("检查更新…") {
                        openWindow(id: "main")
                        NSApp.activate(ignoringOtherApps: true)
                        update.checkForUpdates(silent: false)
                    }
                }
        }
        .scrollContentBackground(.hidden)
        .formStyle(.grouped)
    }

    private var filesTab: some View {
        Form {
            Section("保留策略") {
                LabeledContent("最近文件保留数量") {
                    Stepper("\(recentFilesCapBinding.wrappedValue) 个", value: recentFilesCapBinding, in: 1...50)
                }
                LabeledContent("日志保留天数") {
                    Stepper("\(logRetentionBinding.wrappedValue) 天", value: logRetentionBinding, in: 7...90)
                }
                LabeledContent("工作区保留天数") {
                    Stepper("\(workspaceRetentionBinding.wrappedValue) 天", value: workspaceRetentionBinding, in: 1...90)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .formStyle(.grouped)
    }

    private var transferTab: some View {
        Form {
            Section {
                TextField("设备名", text: deviceNameBinding)
                Toggle("开机自启", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        LaunchAtLogin.setEnabled(newValue)
                    }
                Toggle("隐身模式(不广播 Bonjour)", isOn: stealthBinding)
                LabeledContent("历史保留天数") {
                    Stepper(retentionBinding.wrappedValue == 0 ? "永久" : "\(retentionBinding.wrappedValue) 天",
                            value: retentionBinding, in: 0...365)
                }
            }
            Section {
                Button("清空传输历史", role: .destructive) { transfer.clearHistory() }
                Button("清空已配对设备", role: .destructive) { transfer.clearPairedDevices() }
            }
        }
        .scrollContentBackground(.hidden)
        .formStyle(.grouped)
    }

    private var aboutTab: some View {
        let palette = GlassPalette(colorScheme: colorScheme)
        return VStack(spacing: GlassMetric.spacingM) {
            Image(systemName: "signature")
                .font(.system(size: 48))
                .foregroundStyle(palette.primaryStart)
            Text("EasySign").font(.title.weight(.bold))
            Text("iOS/macOS 重签 + 工具集")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .glassSurface(.standard, radius: GlassMetric.radiusLarge, padding: GlassMetric.spacingXL)
        .padding(GlassMetric.spacingL)
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

    private var interfaceThemeBinding: Binding<String> {
        Binding(
            get: { settings.string(.interfaceTheme) ?? GlassThemePreference.system.rawValue },
            set: { settings.set($0, for: .interfaceTheme) }
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
