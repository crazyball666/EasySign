import SwiftUI
import AppKit

struct SettingsView: View {
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
                stepperRow("最近文件保留数量", text: "\(recentFilesCapBinding.wrappedValue) 个", value: recentFilesCapBinding, in: 1...50)
                stepperRow("日志保留天数", text: "\(logRetentionBinding.wrappedValue) 天", value: logRetentionBinding, in: 7...90)
                stepperRow("工作区保留天数", text: "\(workspaceRetentionBinding.wrappedValue) 天", value: workspaceRetentionBinding, in: 1...90)
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
                stepperRow("历史保留天数",
                           text: retentionBinding.wrappedValue == 0 ? "永久" : "\(retentionBinding.wrappedValue) 天",
                           value: retentionBinding, in: 0...365)
            }
            Section {
                Button("清空传输历史", role: .destructive) { transfer.clearHistory() }
                Button("清空已配对设备", role: .destructive) { transfer.clearPairedDevices() }
            }
        }
        .scrollContentBackground(.hidden)
        .formStyle(.grouped)
    }

    /// macOS 惯例:数值在前、箭头贴右;Stepper 自带 label 在 LabeledContent
    /// 里会渲染成「箭头在前」,故显式拆开。
    private func stepperRow(_ title: String, text: String, value: Binding<Int>, in range: ClosedRange<Int>) -> some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                Text(text).monospacedDigit()
                Stepper("", value: value, in: range)
                    .labelsHidden()
                    .controlSize(.small)
            }
        }
    }

    private var aboutTab: some View {
        VStack(spacing: GlassMetric.spacingS) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("EasySign").font(.title2.weight(.bold))
            Text("版本 \(appVersionText)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("iOS/macOS 重签 + 工具集")
                .font(.caption)
                .foregroundStyle(.secondary)
            Link("GitHub 项目主页", destination: URL(string: "https://github.com/crazyball666/EasySign")!)
                .font(.caption)
                .padding(.top, GlassMetric.spacingS)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var appVersionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return build.map { "\(version) (\($0))" } ?? version
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
            set: {
                settings.set($0, for: .interfaceTheme)
                (GlassThemePreference(rawValue: $0) ?? .system).applyToApp()
            }
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
