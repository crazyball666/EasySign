import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct AppListView: View {
    @Environment(\.colorScheme) private var colorScheme
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
    @State private var detailApp: InstalledApp?
    @StateObject private var iconStore = AppIconStore()

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
        VStack(spacing: GlassMetric.spacingM) {
            searchBar
            content
        }
        .glassSurface(.emphasized, radius: GlassMetric.radiusLarge, padding: GlassMetric.spacingM)
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
        .sheet(item: $detailApp) { app in
            AppDetailSheet(app: app, icon: iconStore.icons[app.bundleID])
        }
        .onAppear { loadApps() }
        .onChange(of: device) { _, _ in
            iconStore.reset(deviceID: device?.id)
            loadApps()
        }
    }

    private var searchBar: some View {
        HStack(spacing: GlassMetric.spacingS) {
            HStack(spacing: GlassMetric.spacingS) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(GlassPalette(colorScheme: colorScheme).mutedText)
                    .font(.system(size: 12))
                TextField("按名称或 Bundle ID 搜索", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .glassSurface(.inset, radius: GlassMetric.radiusSmall)
            .frame(minWidth: 120)

            Picker("", selection: $selectedFilter) {
                ForEach(AppFilter.allCases, id: \.self) { f in
                    Text(f.rawValue).tag(f)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 170)

            Button {
                pickAndInstall()
            } label: {
                Label("安装 IPA", systemImage: "square.and.arrow.down.on.square")
            }
            .buttonStyle(GlassButtonStyle(.primary, compact: true))
            .disabled(device == nil || opTitle != nil || isLoading)
            .fixedSize()
        }
    }

    @ViewBuilder
    private var content: some View {
        // ZStack + 每个分支自带 transition:if/else 直接换视图会硬切,
        // 加载态出现/消失都很突兀。外层 .animation 绑定状态标识驱动转场。
        ZStack {
            if isLoading {
                StatePlaceholder(
                    title: "正在读取 App 列表",
                    detail: "正在从已连接设备加载应用信息",
                    status: .active
                )
                .transition(.glassState)
            } else if let error = errorMessage {
                StatePlaceholder(title: "无法读取 App 列表", detail: error, status: .danger)
                    .transition(.glassState)
            } else if filteredApps.isEmpty {
                StatePlaceholder(
                    title: apps.isEmpty ? "没有找到 App" : "没有匹配的 App",
                    detail: apps.isEmpty ? "设备中没有可显示的应用" : "尝试调整搜索词或筛选条件",
                    status: .idle
                )
                .transition(.glassState)
            } else {
                List(filteredApps) { app in
                    AppRow(
                        app: app,
                        icon: iconStore.icons[app.bundleID],
                        onUninstall: { pendingUninstall = $0 },
                        onShowDetail: { detailApp = $0 }
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { onAppSelected(app) }
                    // 行出现时才拉图标 —— 一次 RPC 一个 App,三百多个全拉完既慢又白费。
                    .onAppear { iconStore.load(for: app) }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                // Drop the List's default bottom content margin so the very last
                // row is fully visible and clickable.
                .listBottomContentMarginZero()
                .transition(.glassState)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.glassState, value: contentStateKey)
    }

    /// 只在「哪一种状态」真正变化时触发转场 —— 绑定 filteredApps 本身会让
    /// 每次输入搜索词都把整个列表淡入淡出一遍。
    private var contentStateKey: String {
        if isLoading { return "loading" }
        if let error = errorMessage { return "error:\(error)" }
        return filteredApps.isEmpty ? "empty:\(apps.isEmpty)" : "list"
    }

    private var operationOverlay: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()
            VStack(spacing: GlassMetric.spacingM) {
                ActivityPulse(isActive: true, color: GlassPalette(colorScheme: colorScheme).primaryStart)
                Text("\(opTitle ?? "")中…").font(.headline)
                ProgressView(value: opProgress)
                    .tint(GlassPalette(colorScheme: colorScheme).primaryStart)
                    .frame(width: 220)
                if let m = opMessage {
                    Text(m)
                        .font(.caption)
                        .foregroundStyle(GlassPalette(colorScheme: colorScheme).mutedText)
                        .lineLimit(1)
                }
            }
            .glassSurface(.emphasized, radius: GlassMetric.radiusLarge, padding: 22)
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
            // 已连接同一台设备时复用现有会话,不要无脑重连。安装/卸载只是开了几条 service 连接
            // (用完即 AMDServiceConnectionInvalidate),并不会动主会话;而 connect()→performConnect
            // 会在 readDeviceMetadata 里对活跃 ref 做一遍 Connect/Disconnect 把会话拆了再重建,设备
            // 此刻常忙于收尾安装、握手易瞬时失败 → 误报「无法连接到设备」,逼用户重新点设备。
            let reusing = DeviceManager.shared.getConnectedDeviceRef(for: device.id) != nil
            if !reusing, !DeviceManager.shared.connect(to: device) {
                DispatchQueue.main.async {
                    self.errorMessage = "无法连接到设备"
                    self.isLoading = false
                }
                return
            }

            do {
                let appList = try AppLister(device: device).listInstalledApps()
                DispatchQueue.main.async {
                    self.apps = appList
                    self.isLoading = false
                }
            } catch {
                // 复用的会话可能确已失效(设备被拔过/被系统回收)→ 重连一次再列一次,仍失败才报错。
                if reusing,
                   DeviceManager.shared.connect(to: device),
                   let appList = try? AppLister(device: device).listInstalledApps() {
                    DispatchQueue.main.async {
                        self.apps = appList
                        self.isLoading = false
                    }
                } else {
                    DispatchQueue.main.async {
                        self.errorMessage = error.localizedDescription
                        self.isLoading = false
                    }
                }
            }
        }
    }
}

// MARK: - AppRow

struct AppRow: View {
    @Environment(\.colorScheme) private var colorScheme
    let app: InstalledApp
    var icon: NSImage? = nil
    var onUninstall: ((InstalledApp) -> Void)? = nil
    var onShowDetail: ((InstalledApp) -> Void)? = nil

    var body: some View {
        HStack(spacing: 10) {
            AppIconView(app: app, icon: icon)

            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(app.bundleID)
                    .font(.system(size: 11))
                    .foregroundStyle(GlassPalette(colorScheme: colorScheme).mutedText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 3) {
                Text(app.version.isEmpty ? "—" : app.version)
                    .font(.system(size: 11))
                    .foregroundStyle(GlassPalette(colorScheme: colorScheme).mutedText)
                SigningBadge(app: app)
            }

            if let onShowDetail {
                Button {
                    onShowDetail(app)
                } label: {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(GlassIconButtonStyle())
                .foregroundStyle(GlassPalette(colorScheme: colorScheme).primaryStart)
                .help("应用详情")
            }

            // 卸载入口仅对用户 App 开放(系统 App installation_proxy 也会拒)。
            if let onUninstall, !app.isSystemApp {
                Button {
                    onUninstall(app)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(GlassIconButtonStyle())
                .foregroundStyle(GlassPalette(colorScheme: colorScheme).danger)
                .help("卸载")
            }
        }
        .padding(.vertical, 3)
    }
}

// MARK: - AppIconPlaceholder

// 真实图标走 SpringBoardServicesClient(见 AppIconStore);这里是它到位之前
// (以及取不到时)的兜底:按 bundle ID 哈希着色的字母占位图。
struct AppIconPlaceholder: View {
    @Environment(\.colorScheme) private var colorScheme
    let app: InstalledApp
    var size: CGFloat = 38

    var body: some View {
        let colors = gradient(for: app.bundleID)
        RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
            .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: size, height: size)
            .overlay(
                Text(initial)
                    .font(.system(size: size * 0.47, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
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
        let palette = GlassPalette(colorScheme: colorScheme)
        let palettes: [[Color]] = [
            [palette.primaryStart, palette.primaryEnd],
            [palette.success, palette.primaryStart],
            [palette.warning, palette.primaryEnd],
            [palette.primaryEnd, palette.danger],
            [palette.danger, palette.primaryEnd],
            [palette.primaryStart, palette.success],
            [palette.primaryEnd, palette.primaryStart],
            [palette.warning, palette.primaryStart],
        ]
        var hash: UInt32 = 5381
        for byte in key.utf8 {
            hash = (hash &* 33) &+ UInt32(byte)
        }
        return palettes[Int(hash) % palettes.count]
    }
}
