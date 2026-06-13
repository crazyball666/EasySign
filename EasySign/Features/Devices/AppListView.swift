import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct AppListView: View {
    let device: Device?
    let onAppSelected: (InstalledApp) -> Void

    @State private var apps: [InstalledApp] = []
    @State private var searchText: String = ""
    @State private var selectedFilter: AppFilter = .all
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?

    // 安装 / 卸载操作状态(opTitle 非 nil = 操作进行中,显示覆盖层)
    @State private var opTitle: String?
    @State private var opProgress: Double = 0
    @State private var opMessage: String?
    @State private var opError: String?
    @State private var pendingUninstall: InstalledApp?

    enum AppFilter: String, CaseIterable {
        case all = "All"
        case user = "User"
        case system = "System"
    }

    private var pairedDevice: PairedDevice? {
        device.map { PairedDevice(id: $0.id, name: $0.name, model: $0.model, osVersion: $0.systemVersion) }
    }

    var filteredApps: [InstalledApp] {
        var result = apps

        switch selectedFilter {
        case .all:
            break
        case .user:
            result = result.filter { !$0.isSystemApp }
        case .system:
            result = result.filter { $0.isSystemApp }
        }

        if !searchText.isEmpty {
            result = result.filter {
                $0.name.localizedCaseInsensitiveContains(searchText) ||
                $0.bundleID.localizedCaseInsensitiveContains(searchText)
            }
        }

        // User apps first, then by name.
        return result.sorted { a, b in
            if a.isSystemApp != b.isSystemApp { return !a.isSystemApp }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            content
        }
        .overlay { if opTitle != nil { operationOverlay } }
        .alert("操作失败", isPresented: Binding(
            get: { opError != nil },
            set: { if !$0 { opError = nil } }
        )) {
            Button("好") { opError = nil }
        } message: {
            Text(opError ?? "")
        }
        .confirmationDialog(
            "卸载「\(pendingUninstall?.name ?? "")」?",
            isPresented: Binding(get: { pendingUninstall != nil },
                                 set: { if !$0 { pendingUninstall = nil } }),
            titleVisibility: .visible
        ) {
            Button("卸载", role: .destructive) {
                if let app = pendingUninstall { uninstall(app) }
                pendingUninstall = nil
            }
            Button("取消", role: .cancel) { pendingUninstall = nil }
        } message: {
            Text("将从设备删除该 App 及其数据,不可撤销。")
        }
        .onAppear { loadApps() }
        .onChange(of: device) { _ in loadApps() }
    }

    private var searchBar: some View {
        VStack(spacing: 6) {
            HStack {
                Spacer()
                Button {
                    pickAndInstall()
                } label: {
                    Label("安装 IPA…", systemImage: "square.and.arrow.down.on.square")
                }
                .controlSize(.small)
                .disabled(device == nil || opTitle != nil || isLoading)
            }

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .font(.system(size: 12))
                TextField("按名称或 Bundle ID 搜索", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.gray.opacity(0.12))
            .cornerRadius(6)

            Picker("", selection: $selectedFilter) {
                ForEach(AppFilter.allCases, id: \.self) { f in
                    Text(f.rawValue).tag(f)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            VStack(spacing: 8) {
                ProgressView()
                Text("加载 App 列表...")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = errorMessage {
            Text(error)
                .foregroundColor(.red)
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filteredApps.isEmpty {
            Text(apps.isEmpty ? "没有找到 App" : "没有匹配的 App")
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(filteredApps) { app in
                AppRow(app: app, onUninstall: { pendingUninstall = $0 })
                    .contentShape(Rectangle())
                    .onTapGesture { onAppSelected(app) }
            }
            .listStyle(.plain)
        }
    }

    private var operationOverlay: some View {
        ZStack {
            Color.black.opacity(0.15).ignoresSafeArea()
            VStack(spacing: 10) {
                Text("\(opTitle ?? "")中…").font(.headline)
                ProgressView(value: opProgress).frame(width: 220)
                if let m = opMessage {
                    Text(m).font(.caption).foregroundColor(.secondary).lineLimit(1)
                }
            }
            .padding(22)
            .background(.regularMaterial)
            .cornerRadius(12)
            .shadow(radius: 8)
        }
    }

    // MARK: - 安装 / 卸载

    private func pickAndInstall() {
        guard let paired = pairedDevice else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [UTType(filenameExtension: "ipa") ?? .data]
        panel.begin { resp in
            guard resp == .OK, let url = panel.url else { return }
            runOperation(title: "安装", stream: DeviceService.shared.installIPA(url, on: paired))
        }
    }

    private func uninstall(_ app: InstalledApp) {
        guard let paired = pairedDevice else { return }
        runOperation(title: "卸载", stream: DeviceService.shared.uninstallApp(bundleID: app.bundleID, on: paired))
    }

    /// 消费 InstallEvent 流:更新覆盖层进度,完成后刷新列表,失败弹错误。
    private func runOperation(title: String, stream: AsyncThrowingStream<InstallEvent, Error>) {
        opTitle = title; opProgress = 0; opMessage = nil; opError = nil
        Task {
            do {
                for try await ev in stream {
                    await MainActor.run {
                        opProgress = ev.progress
                        opMessage = ev.message
                    }
                }
                await MainActor.run {
                    opTitle = nil
                    loadApps()
                }
            } catch {
                await MainActor.run {
                    opTitle = nil
                    opError = error.localizedDescription
                }
            }
        }
    }

    private func loadApps() {
        guard let device = device else { return }

        isLoading = true
        errorMessage = nil

        DispatchQueue.global().async {
            let connected = DeviceManager.shared.connect(to: device)
            guard connected else {
                DispatchQueue.main.async {
                    self.errorMessage = "无法连接到设备"
                    self.isLoading = false
                }
                return
            }

            do {
                let lister = AppLister(device: device)
                let appList = try lister.listInstalledApps()
                DispatchQueue.main.async {
                    self.apps = appList
                    self.isLoading = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }
}

// MARK: - AppRow

struct AppRow: View {
    let app: InstalledApp
    var onUninstall: ((InstalledApp) -> Void)? = nil

    var body: some View {
        HStack(spacing: 10) {
            AppIconPlaceholder(app: app)

            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(app.bundleID)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 3) {
                Text(app.version.isEmpty ? "—" : app.version)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                signingBadge
            }

            // 卸载入口仅对用户 App 开放(系统 App installation_proxy 也会拒)。
            if let onUninstall, !app.isSystemApp {
                Button {
                    onUninstall(app)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundColor(.red)
                .help("卸载")
            }
        }
        .padding(.vertical, 3)
    }

    private var signingBadge: some View {
        let color = badgeColor
        return Text(app.badgeLabel)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color.opacity(0.15))
            .foregroundColor(color)
            .cornerRadius(4)
    }

    private var badgeColor: Color {
        if app.isSystemApp { return .gray }
        switch app.signingInfo {
        case .development: return .green
        case .distribution: return .blue
        case .enterprise: return .orange
        case .system: return .gray
        case .unknown: return .secondary
        }
    }
}

// MARK: - AppIconPlaceholder

// Real iOS app icons live inside the .app bundle which house_arrest doesn't
// expose. Until/unless we add network-based icon fetching (iTunes Search API
// for App Store apps, etc.), this gives a polished color-coded placeholder
// keyed off the bundle ID hash.
struct AppIconPlaceholder: View {
    let app: InstalledApp

    var body: some View {
        let colors = gradient(for: app.bundleID)
        RoundedRectangle(cornerRadius: 9)
            .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: 38, height: 38)
            .overlay(
                Text(initial)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
            )
            .shadow(color: colors.last!.opacity(0.25), radius: 1, y: 1)
    }

    private var initial: String {
        // For system apps where name often starts with com.apple., prefer
        // something more visually distinct.
        let source = app.name.isEmpty ? app.bundleID : app.name
        // First non-whitespace character
        guard let firstChar = source.first(where: { !$0.isWhitespace }) else {
            return "?"
        }
        return String(firstChar).uppercased()
    }

    private func gradient(for key: String) -> [Color] {
        let palettes: [[Color]] = [
            [Color(red: 0.30, green: 0.60, blue: 0.95), Color(red: 0.20, green: 0.40, blue: 0.85)],  // blue
            [Color(red: 0.40, green: 0.75, blue: 0.50), Color(red: 0.25, green: 0.60, blue: 0.35)],  // green
            [Color(red: 0.95, green: 0.55, blue: 0.30), Color(red: 0.85, green: 0.40, blue: 0.20)],  // orange
            [Color(red: 0.75, green: 0.40, blue: 0.85), Color(red: 0.55, green: 0.25, blue: 0.75)],  // purple
            [Color(red: 0.95, green: 0.40, blue: 0.55), Color(red: 0.80, green: 0.25, blue: 0.45)],  // pink
            [Color(red: 0.35, green: 0.70, blue: 0.75), Color(red: 0.20, green: 0.55, blue: 0.65)],  // teal
            [Color(red: 0.55, green: 0.50, blue: 0.85), Color(red: 0.40, green: 0.35, blue: 0.75)],  // indigo
            [Color(red: 0.95, green: 0.75, blue: 0.30), Color(red: 0.85, green: 0.60, blue: 0.20)],  // amber
        ]
        var hash: UInt32 = 5381
        for byte in key.utf8 {
            hash = (hash &* 33) &+ UInt32(byte)
        }
        return palettes[Int(hash) % palettes.count]
    }
}
