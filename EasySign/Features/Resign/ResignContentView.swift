//
//  ContentView.swift
//  EasySign
//
//  Created by crazyball on 2024/7/13.
//

import SwiftUI
import UniformTypeIdentifiers
import PreviewKit

extension Binding where Value == Bool {
    init<T>(value: Binding<T?>) {
        self.init {
            value.wrappedValue != nil
        } set: { newValue in
            if !newValue {
                value.wrappedValue = nil
            }
        }
    }
}

/// 重签进行中的 sheet HUD。注意不要再包 GlassCanvas/glassSurface ——
/// sheet 自带材质背景,再画一层画布会变成「盒中盒」。
struct CustomLoadingView: View {
    let text: String

    var body: some View {
        VStack(spacing: GlassMetric.spacingM) {
            ProgressView()
                .controlSize(.large)
            Text(text)
                .font(.headline)
            Text("正在安全地处理签名与描述文件")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(GlassMetric.spacingXL * 2)
        .frame(minWidth: 280)
    }
}

enum CacheKey: String {
    case selectedInput = "selected_input"
    case selectedP12 = "selected_p12"
    case selectedP12Password = "selected_p12_password"
    case selectedMobileProvision = "selected_mobileprovision"
    case selectedOutput = "selected_output"
    case selectedResignType = "selected_resign_type"
    case selectedResignBackend = "selected_resign_backend"
    case selectedDylibInjectionEnabled = "selected_dylib_injection_enabled"
    case selectedInjectedDylibs = "selected_injected_dylibs"
}


class ContentViewModel: ObservableObject {
    @Published var inputFile = ""
    {
        willSet {
            if inputFile != newValue {
                self.selectedAppBundle = nil
            }
        }
    }

    @Published var p12Path = ""

    @Published var p12Password = ""

    @Published var mobileprovisionPath = ""

    @Published var injectedDylibPaths: [String] = []

    @Published var isDylibInjectionEnabled = false

    @Published var resignType: ResignExportType = .dev

    @Published var resignBackend: ResignBackend = .zsign

    @Published var outputDir = ""

    @Published var isDetailActive = false

    @Published var resignSetting: ResignSetting?

    @Published var presentError: Error?

    @Published var resignSuccessOutputPath: String?

    @Published var ipaPreviewInfo: IPAPreviewInfo?

    @Published var ipaPreviewLoading = false

    @Published var loading: Bool = false

    var selectedAppBundle: AppBundle? {
        didSet {
            guard let appBundle = selectedAppBundle else {
                return
            }
            let entitlements = (try? appBundle.getEntitlementsString()) ?? ""
            resignSetting = ResignSetting(
                bundleId: appBundle.bundleId,
                displayName: appBundle.displayName,
                version: appBundle.version,
                buildVersion: appBundle.buildVersion,
                entitlements: entitlements
            )
        }
    }
}


private let resignLabelWidth: CGFloat = 104
private let resignPanelRadius: CGFloat = GlassMetric.radiusMedium

struct ResignPageHeader: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = GlassPalette(colorScheme: colorScheme)
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: resignPanelRadius, style: .continuous)
                    .fill(palette.primaryStart.opacity(0.14))
                Image(systemName: "signature")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(palette.primaryStart)
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text("重签工作台")
                    .font(.title2.weight(.semibold))
                Text("IPA / APP")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.bottom, 2)
    }
}

struct ResignSectionView<Content: View>: View {
    let title: String
    let systemImage: String
    let content: Content

    init(title: String, systemImage: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: GlassMetric.spacingL) {
            GlassSectionTitle(title, icon: systemImage)

            VStack(alignment: .leading, spacing: 12) {
                content
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(.standard, radius: resignPanelRadius, padding: GlassMetric.spacingL)
    }
}

struct FormRow<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: resignLabelWidth, alignment: .trailing)

            content
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
    }
}

struct InputField<TailView: View>: View {
    var title: String
    @Binding var text: String
    var placeholder: String?
    var selectAction: (() -> Void)?
    var selectTitle: String
    var selectIcon: String
    var isSecure: Bool
    var tailView: TailView?

    init(
        title: String,
        text: Binding<String>,
        placeholder: String? = nil,
        selectAction: (() -> Void)? = nil,
        selectTitle: String = "选择",
        selectIcon: String = "folder",
        isSecure: Bool = false,
        @ViewBuilder tailView: () -> TailView
    ) {
        self.title = title
        self._text = text
        self.placeholder = placeholder
        self.selectAction = selectAction
        self.selectTitle = selectTitle
        self.selectIcon = selectIcon
        self.isSecure = isSecure
        self.tailView = tailView()
    }

    init(
        title: String,
        text: Binding<String>,
        placeholder: String? = nil,
        selectAction: (() -> Void)? = nil,
        selectTitle: String = "选择",
        selectIcon: String = "folder",
        isSecure: Bool = false
    ) where TailView == EmptyView {
        self.title = title
        self._text = text
        self.placeholder = placeholder
        self.selectAction = selectAction
        self.selectTitle = selectTitle
        self.selectIcon = selectIcon
        self.isSecure = isSecure
        self.tailView = nil
    }

    var body: some View {
        FormRow(title) {
            HStack(spacing: 8) {
                if isSecure {
                    SecureField(placeholder ?? title, text: $text)
                        .textFieldStyle(.roundedBorder)
                } else {
                    TextField(placeholder ?? title, text: $text)
                        .textFieldStyle(.roundedBorder)
                }

                if let selectAction = selectAction {
                    Button(action: selectAction) {
                        Label(selectTitle, systemImage: selectIcon)
                    }
                    .buttonStyle(.bordered)
                }

                if let tailView = tailView {
                    tailView
                }
            }
        }
    }
}

struct DropdownPickerRow<SelectionValue: Hashable>: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    @Binding var selection: SelectionValue
    let options: [SelectionValue]
    let displayTitle: (SelectionValue) -> String

    init(
        title: String,
        selection: Binding<SelectionValue>,
        options: [SelectionValue],
        displayTitle: @escaping (SelectionValue) -> String
    ) {
        self.title = title
        self._selection = selection
        self.options = options
        self.displayTitle = displayTitle
    }

    var body: some View {
        let palette = GlassPalette(colorScheme: colorScheme)
        FormRow(title) {
            Menu {
                ForEach(options, id: \.self) { option in
                    Button {
                        selection = option
                    } label: {
                        if option == selection {
                            Label(displayTitle(option), systemImage: "checkmark")
                        } else {
                            Text(displayTitle(option))
                        }
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Text(displayTitle(selection))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(palette.insetFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(palette.mutedBorder, lineWidth: 1)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct InjectedDylibPickerView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Binding var isEnabled: Bool
    @Binding var paths: [String]
    @Binding var text: String
    var addAction: () -> Void

    private var palette: GlassPalette { GlassPalette(colorScheme: colorScheme) }

    var body: some View {
        FormRow("动态库注入") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("启用动态库注入", isOn: $isEnabled)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .toggleStyle(.switch)
                    .controlSize(.small)

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        TextField("选择或粘贴 .dylib 路径", text: $text)
                            .textFieldStyle(.roundedBorder)

                        Button(action: addAction) {
                            Label("添加动态库", systemImage: "plus")
                        }
                        .buttonStyle(.bordered)
                    }

                    if !paths.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(paths.enumerated()), id: \.offset) { index, path in
                                HStack(spacing: 8) {
                                    Image(systemName: "link")
                                        .foregroundStyle(.secondary)
                                        .frame(width: 16)

                                    Text(URL(fileURLWithPath: path).lastPathComponent)
                                        .font(.caption.weight(.medium))
                                        .frame(width: 122, alignment: .leading)
                                        .lineLimit(1)

                                    Text(path)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)

                                    Spacer(minLength: 8)

                                    Button(action: {
                                        paths = DylibInjection.removePath(at: index, from: paths)
                                    }) {
                                        Image(systemName: "xmark.circle.fill")
                                            .accessibilityLabel("移除动态库")
                                    }
                                    .buttonStyle(.borderless)
                                }
                                .padding(.horizontal, 8)
                                .frame(height: 30)
                                .background(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(palette.insetFill)
                                )
                            }

                            Button(action: {
                                paths = []
                            }) {
                                Label("清空动态库", systemImage: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                .disabled(!isEnabled)
                .opacity(isEnabled ? 1 : 0.5)
            }
        }
    }
}

// 重签日志已并入结构化 LoggerService,面板改用 Core/UI/LogPanelView(toolId: "resign")。





struct ResignContentView: View {
    @StateObject var viewModel = ContentViewModel()
    let hub: ServiceHub
    @ObservedObject private var logger: LoggerService

    init(hub: ServiceHub) {
        self.hub = hub
        _logger = ObservedObject(wrappedValue: hub.logger)
    }
    @State private var validationError: String?

    private var injectedDylibText: Binding<String> {
        Binding {
            DylibInjection.displayText(from: viewModel.injectedDylibPaths)
        } set: { newValue in
            viewModel.injectedDylibPaths = DylibInjection.mergePaths(
                existing: [],
                adding: DylibInjection.paths(from: newValue)
            )
        }
    }

    var body: some View {
        GlassCanvas {
            GeometryReader { proxy in
                let usesInspector = GlassLayout.contextPresentation(for: proxy.size.width) == .inspector
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: GlassMetric.spacingL) {
                        workspaceHeader(showsInspector: usesInspector)

                        HStack(alignment: .top, spacing: GlassMetric.spacingL) {
                            resignCanvas
                                .frame(maxWidth: .infinity, alignment: .topLeading)

                            if !usesInspector {
                                resignContextRail
                                    .frame(width: 320)
                            }
                        }
                    }
                    .padding(GlassMetric.spacingXL)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear(perform: {
            viewModel.inputFile = UserDefaults.standard.string(forKey: CacheKey.selectedInput.rawValue) ?? ""
            viewModel.p12Path = UserDefaults.standard.string(forKey: CacheKey.selectedP12.rawValue) ?? ""
            viewModel.p12Password = UserDefaults.standard.string(forKey: CacheKey.selectedP12Password.rawValue) ?? ""
            viewModel.mobileprovisionPath = UserDefaults.standard.string(forKey: CacheKey.selectedMobileProvision.rawValue) ?? ""
            let cachedInjectedDylibs = UserDefaults.standard.stringArray(forKey: CacheKey.selectedInjectedDylibs.rawValue) ?? []
            viewModel.injectedDylibPaths = cachedInjectedDylibs
            if UserDefaults.standard.object(forKey: CacheKey.selectedDylibInjectionEnabled.rawValue) == nil {
                viewModel.isDylibInjectionEnabled = !cachedInjectedDylibs.isEmpty
            } else {
                viewModel.isDylibInjectionEnabled = UserDefaults.standard.bool(forKey: CacheKey.selectedDylibInjectionEnabled.rawValue)
            }
            viewModel.resignBackend = ResignBackend(rawValue: UserDefaults.standard.string(forKey: CacheKey.selectedResignBackend.rawValue) ?? "") ?? .zsign
            viewModel.resignType = ResignExportType(rawValue: UserDefaults.standard.string(forKey: CacheKey.selectedResignType.rawValue) ?? "") ?? .dev
            viewModel.outputDir = UserDefaults.standard.string(forKey: CacheKey.selectedOutput.rawValue) ?? ""
        })
        .alert("Error", isPresented: Binding(value: $viewModel.presentError)) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.presentError?.localizedDescription ?? "")
        }
        .alert("重签成功", isPresented: Binding(value: $viewModel.resignSuccessOutputPath)) {
            Button("在 Finder 中显示") { revealOutputInFinder() }
            Button("复制路径") { copyOutputPath() }
            Button("分享") { shareOutput() }
            Button("关闭", role: .cancel) {}
        } message: {
            Text("IPA 已导出到：\n\(viewModel.resignSuccessOutputPath ?? "")")
        }
        .alert("无法开始", isPresented: Binding(
            get: { validationError != nil },
            set: { if !$0 { validationError = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(validationError ?? "")
        }
        .sheet(isPresented: $viewModel.loading) {
            CustomLoadingView(text: "重签中")
        }
        .sheet(item: $viewModel.ipaPreviewInfo) { info in
            IPAPreviewPanelView(info: info)
        }
    }

    @ViewBuilder
    private func workspaceHeader(showsInspector: Bool) -> some View {
        WorkspaceHeader(
            icon: "signature",
            title: "重签工作台",
            subtitle: "IPA / APP · 分阶段校验与导出",
            status: resignStatus,
            statusTitle: resignStatusTitle
        ) {
            if showsInspector {
                GlassInspectorButton(title: "任务摘要") {
                    ScrollView {
                        resignContextRail
                    }
                }
            } else {
                EmptyView()
            }
        }
    }

    private var resignCanvas: some View {
        VStack(alignment: .leading, spacing: GlassMetric.spacingL) {
            ResignSectionView(title: "输入 IPA", systemImage: "app.badge.checkmark") {
                ResignStageHeader(index: 1, title: "选择待重签包", detail: "导入 IPA、ZIP 或 APP，并可查看应用信息")
                FormRow("输入文件") {
                    HStack(spacing: GlassMetric.spacingS) {
                        FilePickerField(
                            title: "选择 IPA、ZIP 或 APP",
                            path: $viewModel.inputFile,
                            kind: .ipa,
                            allowedContentTypes: [],
                            serviceHub: hub
                        )

                        Button(action: onTapPreview) {
                            Label("预览", systemImage: "eye")
                        }
                        .buttonStyle(GlassButtonStyle())
                        .disabled(!canPreviewInput || viewModel.ipaPreviewLoading)
                        .help("预览 IPA 内容")

                        Button(action: showIPAInfo) {
                            Label("编辑", systemImage: "slider.horizontal.3")
                        }
                        .buttonStyle(GlassButtonStyle())
                        .help("编辑应用信息")
                        .popover(isPresented: $viewModel.isDetailActive, arrowEdge: .leading) {
                            IPAContentView(resignSetting: Binding(get: { viewModel.resignSetting ?? ResignSetting() }, set: { newValue in viewModel.resignSetting = newValue }))
                        }
                    }
                }
            }

            ResignSectionView(title: "证书与权限", systemImage: "checkmark.seal") {
                ResignStageHeader(index: 2, title: "匹配身份与能力", detail: "描述文件决定最终可签入的 entitlement 集合")
                FormRow("P12 证书") {
                    FilePickerField(
                        title: "选择 .p12 文件",
                        path: $viewModel.p12Path,
                        kind: .p12,
                        allowedContentTypes: [],
                        serviceHub: hub
                    )
                }

                InputField(
                    title: "证书密码",
                    text: $viewModel.p12Password,
                    placeholder: "输入 P12 密码",
                    isSecure: true
                )

                FormRow("描述文件") {
                    FilePickerField(
                        title: "选择 .mobileprovision 文件",
                        path: $viewModel.mobileprovisionPath,
                        kind: .mobileprovision,
                        allowedContentTypes: [],
                        serviceHub: hub
                    )
                }

                DropdownPickerRow(
                    title: "重签方式",
                    selection: $viewModel.resignBackend,
                    options: ResignBackend.allCases,
                    displayTitle: { $0.displayName }
                )

                DropdownPickerRow(
                    title: "导出类型",
                    selection: $viewModel.resignType,
                    options: ResignExportType.allCases,
                    displayTitle: { $0.rawValue }
                )

                InjectedDylibPickerView(
                    isEnabled: $viewModel.isDylibInjectionEnabled,
                    paths: $viewModel.injectedDylibPaths,
                    text: injectedDylibText
                ) {
                    guard let selectedUrls = selectFiles(allowsMultipleSelection: true, allowedExtensions: ["dylib"]) else {
                        return
                    }
                    viewModel.injectedDylibPaths = DylibInjection.mergePaths(
                        existing: viewModel.injectedDylibPaths,
                        adding: selectedUrls.map { $0.path }
                    )
                }
            }

            ResignSectionView(title: "校验与导出", systemImage: "arrow.up.doc") {
                ResignStageHeader(index: 3, title: "确认输出并开始", detail: "开始前会检查输入、P12、描述文件与导出目录")
                InputField(
                    title: "输出目录",
                    text: $viewModel.outputDir,
                    placeholder: "选择输出目录",
                    selectAction: {
                        guard let selectedUrl = selectFile(isDirectory: true) else {
                            return
                        }
                        viewModel.outputDir = selectedUrl.path
                    },
                    selectTitle: "选择",
                    selectIcon: "folder"
                )

                HStack(alignment: .center, spacing: GlassMetric.spacingM) {
                    Label("运行详情与完整日志位于任务摘要。", systemImage: "waveform.path.ecg")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    ResignPrimaryAction(isRunning: viewModel.loading, action: onTapStart)
                }
            }
        }
    }

    private var resignContextRail: some View {
        ContextRail(title: "当前任务摘要", subtitle: resignStatusTitle) {
            VStack(alignment: .leading, spacing: GlassMetric.spacingM) {
                ResignSummaryRow(label: "证书", value: displayName(for: viewModel.p12Path, empty: "待选择"), icon: "key.fill")
                ResignSummaryRow(label: "Profile", value: displayName(for: viewModel.mobileprovisionPath, empty: "待选择"), icon: "doc.badge.gearshape")
                ResignSummaryRow(label: "Bundle ID", value: viewModel.resignSetting?.bundleId ?? "待读取", icon: "app.badge")
                ResignSummaryRow(label: "权限改写", value: entitlementRewriteDescription, icon: "checkmark.shield")
                ResignSummaryRow(label: "输出位置", value: viewModel.outputDir.isEmpty ? "待选择" : viewModel.outputDir, icon: "folder")
            }

            ActivityCard(
                title: resignStatusTitle,
                detail: activityDescription,
                status: resignStatus
            )

            VStack(alignment: .leading, spacing: GlassMetric.spacingS) {
                GlassSectionTitle("任务活动", icon: "list.bullet.rectangle")
                LogPanelView(logger: logger, toolId: "resign")
                    .frame(minHeight: 190, maxHeight: 250)
                    .clipShape(RoundedRectangle(cornerRadius: GlassMetric.radiusSmall, style: .continuous))
            }
        }
    }

    private var resignStatus: GlassStatus {
        if viewModel.loading { return .active }
        if viewModel.resignSuccessOutputPath != nil { return .success }
        return .idle
    }

    private var resignStatusTitle: String {
        switch resignStatus {
        case .active: "重签进行中"
        case .success: "导出完成"
        case .idle: "等待配置"
        case .warning: "需要确认"
        case .danger: "任务失败"
        }
    }

    private var activityDescription: String {
        if viewModel.loading {
            return entitlementRewriteCount == 0 ? "正在校验签名与权限…" : "已发现 \(entitlementRewriteCount) 项 entitlement 调整"
        }
        if viewModel.resignSuccessOutputPath != nil {
            return "签名包已生成，可在成功提示中显示或分享。"
        }
        return "补齐输入、证书、描述文件与输出位置后即可开始。"
    }

    private var entitlementRewriteCount: Int {
        _ = logger.revision
        return ResignActivitySummary.rewriteCount(
            in: logger.recentEntries
                .filter { $0.tool == "resign" }
                .map(\.message)
        )
    }

    private var entitlementRewriteDescription: String {
        entitlementRewriteCount == 0 ? "待实际校验" : "\(entitlementRewriteCount) 项"
    }

    private func displayName(for path: String, empty: String) -> String {
        guard !path.isEmpty else { return empty }
        return URL(fileURLWithPath: path).lastPathComponent
    }


    private func selectFile(isDirectory: Bool = false) -> URL? {
        selectFiles(isDirectory: isDirectory)?.first
    }

    private func selectFiles(isDirectory: Bool = false, allowsMultipleSelection: Bool = false, allowedExtensions: [String]? = nil) -> [URL]? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = allowsMultipleSelection
        panel.canChooseFiles = !isDirectory
        panel.canChooseDirectories = isDirectory
        if let allowedExtensions {
            let allowedTypes = allowedExtensions.compactMap { UTType(filenameExtension: $0) }
            if !allowedTypes.isEmpty {
                panel.allowedContentTypes = allowedTypes
            }
        }
        if panel.runModal() == .OK {
            return panel.urls
        }
        return nil
    }

    private var canPreviewInput: Bool {
        let inputURL = URL(fileURLWithPath: viewModel.inputFile)
        return ["ipa", "zip", "app"].contains(inputURL.pathExtension.lowercased()) &&
            FileManager.default.fileExists(atPath: inputURL.path)
    }

    private func onTapPreview() {
        let inputURL = URL(fileURLWithPath: viewModel.inputFile)
        guard canPreviewInput else {
            viewModel.presentError = NSError(message: "请选择 IPA、ZIP 或 APP 后再预览")
            return
        }

        viewModel.ipaPreviewLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                // 主 App 的预览面板不展示 App Entitlements,不必为此整块解压可执行文件
                let previewInfo = try IPAPreviewService().preview(url: inputURL, includeAppEntitlements: false)
                DispatchQueue.main.async {
                    viewModel.ipaPreviewLoading = false
                    viewModel.ipaPreviewInfo = previewInfo
                }
            } catch {
                DispatchQueue.main.async {
                    viewModel.ipaPreviewLoading = false
                    viewModel.presentError = error
                }
            }
        }
    }

    private func showIPAInfo() {
        if viewModel.selectedAppBundle != nil {
            viewModel.isDetailActive = true
            return
        }
        let inputFile = URL(fileURLWithPath: viewModel.inputFile)
        if FileManager.default.fileExists(atPath: viewModel.inputFile) {
            do {
                if inputFile.pathExtension == "ipa" || inputFile.pathExtension == "zip" {
                    let ipa = try IPA(file:inputFile)
                    viewModel.selectedAppBundle = ipa.appBundle
                } else if inputFile.pathExtension == "app" {
                    viewModel.selectedAppBundle = try AppBundle(path: inputFile)
                } else {
                    throw NSError(message: "非法文件")
                }
                viewModel.isDetailActive = true
            } catch {
                viewModel.presentError = error
            }
        } else {
            viewModel.presentError = NSError(message: "invaild input file")
        }
    }

    // MARK: - Pre-flight validation
    private func validateBeforeStart() -> String? {
        if viewModel.inputFile.isEmpty { return "请选择 IPA 文件" }
        if !FileManager.default.fileExists(atPath: viewModel.inputFile) {
            return "IPA 文件不存在：\(viewModel.inputFile)"
        }
        if viewModel.p12Path.isEmpty { return "请选择 P12 证书" }
        if !FileManager.default.fileExists(atPath: viewModel.p12Path) {
            return "P12 文件不存在：\(viewModel.p12Path)"
        }
        if viewModel.p12Password.isEmpty { return "请输入 P12 密码" }
        // 提前在内存里验一次 p12 密码:错的话立即提示,而不是等整包解压后才在 zsign 里报。
        do {
            _ = try PKCS12(file: URL(fileURLWithPath: viewModel.p12Path), password: viewModel.p12Password)
        } catch {
            return "P12 密码错误或证书文件无效,请检查密码"
        }
        if viewModel.mobileprovisionPath.isEmpty { return "请选择 mobileprovision" }
        if !FileManager.default.fileExists(atPath: viewModel.mobileprovisionPath) {
            return "mobileprovision 不存在：\(viewModel.mobileprovisionPath)"
        }
        if viewModel.outputDir.isEmpty { return "请选择输出目录" }
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: viewModel.outputDir, isDirectory: &isDir) || !isDir.boolValue {
            return "输出目录不存在或不是目录：\(viewModel.outputDir)"
        }
        if viewModel.isDylibInjectionEnabled {
            for dylib in viewModel.injectedDylibPaths {
                if !FileManager.default.fileExists(atPath: dylib) {
                    return "注入 dylib 不存在：\(dylib)"
                }
            }
        }
        return nil
    }

    // MARK: - Success actions (alert 4 动作)
    private func revealOutputInFinder() {
        guard let path = viewModel.resignSuccessOutputPath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func copyOutputPath() {
        guard let path = viewModel.resignSuccessOutputPath else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    private func shareOutput() {
        guard let path = viewModel.resignSuccessOutputPath else { return }
        let url = URL(fileURLWithPath: path)
        let picker = NSSharingServicePicker(items: [url])
        if let window = NSApp.keyWindow, let contentView = window.contentView {
            picker.show(relativeTo: contentView.bounds, of: contentView, preferredEdge: .minY)
        }
    }

    private func onTapStart() {
        // 前置校验
        if let err = validateBeforeStart() {
            validationError = err
            return
        }

        UserDefaults.standard.set(viewModel.inputFile, forKey: CacheKey.selectedInput.rawValue)
        UserDefaults.standard.set(viewModel.p12Path, forKey: CacheKey.selectedP12.rawValue)
        // P12 密码存 UserDefaults(个人本地工具,没必要进钥匙串 —— 进钥匙串会让 ad-hoc 本地构建每次启动弹密码授权)。
        UserDefaults.standard.set(viewModel.p12Password, forKey: CacheKey.selectedP12Password.rawValue)
        UserDefaults.standard.set(viewModel.mobileprovisionPath, forKey: CacheKey.selectedMobileProvision.rawValue)
        UserDefaults.standard.set(viewModel.isDylibInjectionEnabled, forKey: CacheKey.selectedDylibInjectionEnabled.rawValue)
        UserDefaults.standard.set(viewModel.injectedDylibPaths, forKey: CacheKey.selectedInjectedDylibs.rawValue)
        UserDefaults.standard.set(viewModel.resignBackend.rawValue, forKey: CacheKey.selectedResignBackend.rawValue)
        UserDefaults.standard.set(viewModel.resignType.rawValue, forKey: CacheKey.selectedResignType.rawValue)
        UserDefaults.standard.set(viewModel.outputDir, forKey: CacheKey.selectedOutput.rawValue)

        let taskInfo = ResignTaskInfo(
            filePath: URL(fileURLWithPath: viewModel.inputFile),
            p12Path: URL(fileURLWithPath: viewModel.p12Path),
            p12Password: viewModel.p12Password,
            mobileProvisionPath: URL(fileURLWithPath: viewModel.mobileprovisionPath),
            exportType: viewModel.resignType,
            backend: viewModel.resignBackend,
            injectedDylibPaths: viewModel.isDylibInjectionEnabled ? viewModel.injectedDylibPaths.map { URL(fileURLWithPath: $0) } : [],
            outputPath: URL(fileURLWithPath: viewModel.outputDir).appendingPathComponent(Date.now.formatString(format: "yyyyMMddHHmmss") + ".ipa"),
            bundleId: viewModel.resignSetting?.bundleId,
            displayName: viewModel.resignSetting?.displayName,
            version: viewModel.resignSetting?.version,
            buildVersion: viewModel.resignSetting?.buildVersion,
            entitlements: viewModel.resignSetting?.entitlements
        )
        viewModel.loading = true
        let logger = hub.logger
        logger.clear(tool: "resign")   // 按次隔离:清掉上次任务残留的日志
        DispatchQueue.global().async {
            do {
                try ResignTask(taskInfo: taskInfo, logger: logger).Start()
                DispatchQueue.main.async {
                    viewModel.loading = false
                    viewModel.resignSuccessOutputPath = taskInfo.outputPath.path
                }
            } catch {
                logger.log(.error, tool: "resign", error.localizedDescription)
                DispatchQueue.main.async {
                    viewModel.presentError = error
                    viewModel.loading = false
                }
            }
        }
    }
}

#Preview {
    ResignContentView(hub: .live())
}
