//
//  ContentView.swift
//  EasySign
//
//  Created by crazyball on 2024/7/13.
//

import SwiftUI

enum KeychainKey {
    static let p12Password = "resign.p12Password"
}
import UniformTypeIdentifiers

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

struct CustomLoadingView: View {
    let text: String
    let color: Color

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: color))
                .scaleEffect(1.5)
                .padding(.all, 12)
            Text(text)
                .foregroundColor(color)
                .font(.title3)
        }
        .padding()
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


class ContentViewModel: ObservableObject, LoggerProtocol {
    func log(_ level: LegacyLogLevel, _ text: String) {
        DispatchQueue.main.async {
            self.logString += "[\(level.rawValue)] \(text)\n"
        }
    }

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

    @Published var logString: String = ""

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
private let resignPanelRadius: CGFloat = 8

struct ResignPageHeader: View {
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: resignPanelRadius, style: .continuous)
                    .fill(Color.accentColor.opacity(0.14))
                Image(systemName: "signature")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
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
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 18)
                Text(title)
                    .font(.headline)
                Spacer()
            }

            VStack(alignment: .leading, spacing: 12) {
                content
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: resignPanelRadius, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: resignPanelRadius, style: .continuous)
                .stroke(Color.primary.opacity(0.08))
        )
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
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct InjectedDylibPickerView: View {
    @Binding var isEnabled: Bool
    @Binding var paths: [String]
    @Binding var text: String
    var addAction: () -> Void

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
                                        .fill(Color.primary.opacity(0.04))
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

struct LegacyLogPanelView: View {
    let logText: String

    var body: some View {
        ScrollView(.vertical) {
            Text(logText.isEmpty ? "暂无日志" : logText)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(logText.isEmpty ? .secondary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .frame(minHeight: 132, maxHeight: 132)
        .background(
            RoundedRectangle(cornerRadius: resignPanelRadius, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: resignPanelRadius, style: .continuous)
                .stroke(Color.primary.opacity(0.08))
        )
    }
}





struct ResignContentView: View {
    @StateObject var viewModel = ContentViewModel()
    @State var logText = ""
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
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 16) {
                ResignPageHeader()

                ResignSectionView(title: "文件与证书", systemImage: "doc.badge.gearshape") {
                    InputField(
                        title: "输入文件",
                        text: $viewModel.inputFile,
                        placeholder: "选择 IPA、ZIP 或 APP",
                        selectAction: {
                            guard let selectedUrl = selectFile() else {
                                return
                            }
                            viewModel.inputFile = selectedUrl.path
                        },
                        selectTitle: "选择",
                        selectIcon: "doc"
                    ) {
                        Button(action: onTapPreview) {
                            Label("预览", systemImage: "eye")
                        }
                        .buttonStyle(.bordered)
                        .disabled(!canPreviewInput || viewModel.ipaPreviewLoading)
                        .help("预览 IPA 内容")

                        Button(action: showIPAInfo) {
                            Label("编辑", systemImage: "slider.horizontal.3")
                        }
                        .buttonStyle(.bordered)
                        .help("编辑应用信息")
                        .popover(isPresented: $viewModel.isDetailActive, arrowEdge: .leading) {
                            IPAContentView(resignSetting: Binding(get: { viewModel.resignSetting ?? ResignSetting() }, set: { newValue in viewModel.resignSetting = newValue }))
                        }
                    }

                    InputField(
                        title: "P12 证书",
                        text: $viewModel.p12Path,
                        placeholder: "选择 .p12 文件",
                        selectAction: {
                            guard let selectedUrl = selectFile() else {
                                return
                            }
                            viewModel.p12Path = selectedUrl.path
                        },
                        selectTitle: "选择",
                        selectIcon: "key"
                    )

                    InputField(
                        title: "证书密码",
                        text: $viewModel.p12Password,
                        placeholder: "输入 P12 密码",
                        isSecure: true
                    )

                    InputField(
                        title: "描述文件",
                        text: $viewModel.mobileprovisionPath,
                        placeholder: "选择 .mobileprovision 文件",
                        selectAction: {
                            guard let selectedUrl = selectFile() else {
                                return
                            }
                            viewModel.mobileprovisionPath = selectedUrl.path
                        },
                        selectTitle: "选择",
                        selectIcon: "doc.text"
                    )
                }

                ResignSectionView(title: "签名选项", systemImage: "checkmark.seal") {
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

                ResignSectionView(title: "输出与日志", systemImage: "tray.and.arrow.up") {
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

                    LegacyLogPanelView(logText: viewModel.logString)

                    HStack {
                        Spacer()
                        Button(action: onTapStart) {
                            Label("开始重签", systemImage: "play.fill")
                                .frame(minWidth: 96)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(viewModel.loading)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear(perform: {
            viewModel.inputFile = UserDefaults.standard.string(forKey: CacheKey.selectedInput.rawValue) ?? ""
            viewModel.p12Path = UserDefaults.standard.string(forKey: CacheKey.selectedP12.rawValue) ?? ""
            // P12 密码从 Keychain 读取（兼容旧 UserDefaults 数据）
            viewModel.p12Password = KeychainService.shared.get(KeychainKey.p12Password)
                ?? UserDefaults.standard.string(forKey: CacheKey.selectedP12Password.rawValue)
                ?? ""
            // 清理明文 UserDefaults（一次性迁移）
            UserDefaults.standard.removeObject(forKey: CacheKey.selectedP12Password.rawValue)
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
            CustomLoadingView(text: "重签中", color: .blue)
        }
        .sheet(item: $viewModel.ipaPreviewInfo) { info in
            IPAPreviewPanelView(info: info)
        }
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
                let previewInfo = try IPAPreviewService().preview(url: inputURL)
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

        // 同步密码到 Keychain（如果用户希望"记住"）
        KeychainService.shared.set(viewModel.p12Password, for: KeychainKey.p12Password)

        UserDefaults.standard.set(viewModel.inputFile, forKey: CacheKey.selectedInput.rawValue)
        UserDefaults.standard.set(viewModel.p12Path, forKey: CacheKey.selectedP12.rawValue)
        // P12 密码改存 Keychain（不再明文 UserDefaults）
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
        viewModel.logString = ""
        viewModel.loading = true
        DispatchQueue.global().async {
            do {
                try ResignTask(taskInfo: taskInfo, logger: viewModel).Start()
                DispatchQueue.main.async {
                    viewModel.loading = false
                    viewModel.resignSuccessOutputPath = taskInfo.outputPath.path
                }
            } catch {
                print("重签错误：", error.localizedDescription)
                viewModel.log(.ERROR, error.localizedDescription)
                DispatchQueue.main.async {
                    viewModel.presentError = error
                    viewModel.loading = false
                }
            }
        }
    }
}

#Preview {
    ResignContentView()
}
