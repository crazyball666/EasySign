//
//  ContentView.swift
//  EasySign
//
//  Created by crazyball on 2024/7/13.
//

import SwiftUI
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
    case selectedInjectedDylibs = "selected_injected_dylibs"
}


class ContentViewModel: ObservableObject, LoggerProtocol {
    func log(_ level: LogLevel, _ text: String) {
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

    @Published var resignType: ResignExportType = .dev

    @Published var resignBackend: ResignBackend = .zsign

    @Published var outputDir = ""

    @Published var isDetailActive = false

    @Published var logString: String = ""

    @Published var resignSetting: ResignSetting?

    @Published var presentError: Error?

    @Published var loading: Bool = false

    var selectedAppBundle: AppBundle? {
        didSet {
            guard let appBundle = selectedAppBundle else {
                return
            }
            do {
                let entitlements = try appBundle.getEntitlementsString()
                resignSetting = ResignSetting(
                    bundleId: appBundle.bundleId,
                    displayName: appBundle.displayName,
                    version: appBundle.version,
                    buildVersion: appBundle.buildVersion,
                    entitlements: entitlements
                )
            } catch {
                self.presentError = NSError(message: "Read entitlements error: \(error.localizedDescription)")
            }
        }
    }
}


struct InputField<TailView: View>: View {
    var title: String
    @Binding var text: String
    var selectAction: (() -> Void)? = nil
    var selectTitle: String = "Select"
    var tailView: TailView? = nil

    init(title: String, text: Binding<String>, selectAction: (() -> Void)? = nil, selectTitle: String = "Select", @ViewBuilder tailView: @escaping () -> TailView) {
        self.title = title
        self._text = text
        self.selectAction = selectAction
        self.selectTitle = selectTitle
        self.tailView = tailView()
    }

    init(title: String, text: Binding<String>, selectAction: (() -> Void)? = nil, selectTitle: String = "Select") where TailView == EmptyView {
        self.title = title
        self._text = text
        self.selectAction = selectAction
        self.selectTitle = selectTitle
    }


    var body: some View {
        HStack {
            Text(title)
                .frame(width: 100)

            TextField(title, text: $text)
                .textFieldStyle(.roundedBorder)

            if let selectAction = selectAction {
                Button(action: selectAction) {
                    Text(selectTitle)
                        .padding(.vertical, 3)
                }
            }

            if let tailView = tailView {
                tailView
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 12)
        .background(Color.gray.opacity(0.2))
        .cornerRadius(10)
    }
}


enum NavigationTab: String, CaseIterable {
    case resign = "Resign"
    case devices = "Devices"
}

struct SidebarView: View {
    @Binding var selectedTab: NavigationTab

    var body: some View {
        VStack(spacing: 0) {
            ForEach(NavigationTab.allCases, id: \.rawValue) { tab in
                SidebarItem(
                    title: tab.rawValue,
                    icon: tab == .resign ? "doc.badge.gearshape" : "iphone",
                    isSelected: selectedTab == tab
                ) {
                    selectedTab = tab
                }
            }
            Spacer()
        }
        .background(Color.gray.opacity(0.1))
    }
}

struct SidebarItem: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                Text(title)
                    .font(.caption)
            }
            .foregroundColor(isSelected ? .blue : .primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
        .background(isSelected ? Color.blue.opacity(0.1) : Color.clear)
    }
}


struct ContentView: View {
    @State private var selectedTab: NavigationTab = .resign

    var body: some View {
        HStack(spacing: 0) {
            // 侧边栏
            SidebarView(selectedTab: $selectedTab)
                .frame(width: 80)

            // 内容区域
            Group {
                switch selectedTab {
                case .resign:
                    ResignContentView()
                case .devices:
                    DeviceView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct ResignContentView: View {
    @StateObject var viewModel = ContentViewModel()
    @State var logText = ""

    private var injectedDylibText: Binding<String> {
        Binding {
            DylibInjection.displayText(from: viewModel.injectedDylibPaths)
        } set: { newValue in
            viewModel.injectedDylibPaths = DylibInjection.paths(from: newValue)
        }
    }

    var body: some View {
        VStack(alignment: .leading) {
            InputField(title: "Input File", text: $viewModel.inputFile, selectAction: {
                guard let selectedUrl = selectFile() else {
                    return
                }
                viewModel.inputFile = selectedUrl.path
            }) {
                Button(action: showIPAInfo) {
                    Text("Update")
                    .padding(EdgeInsets(top: 5, leading: 0, bottom: 5, trailing: 0))
                }
                .popover(isPresented: $viewModel.isDetailActive, arrowEdge: .leading) {
                    IPAContentView(resignSetting: Binding(get: { viewModel.resignSetting ?? ResignSetting() }, set: { newValue in viewModel.resignSetting = newValue }))
                }
            }


            InputField(title: "P12 File", text: $viewModel.p12Path) {
                guard let selectedUrl = selectFile() else {
                    return
                }
                viewModel.p12Path = selectedUrl.path
            }

            InputField(title: "P12 Password", text: $viewModel.p12Password)

            InputField(title: "Mobileprovision", text: $viewModel.mobileprovisionPath) {
                guard let selectedUrl = selectFile() else {
                    return
                }
                viewModel.mobileprovisionPath = selectedUrl.path
            }

            InputField(title: "Inject Dylibs", text: injectedDylibText, selectAction: {
                guard let selectedUrls = selectFiles(allowsMultipleSelection: true, allowedExtensions: ["dylib"]) else {
                    return
                }
                viewModel.injectedDylibPaths = selectedUrls.map { $0.path }
            }) {
                if !viewModel.injectedDylibPaths.isEmpty {
                    Button(action: {
                        viewModel.injectedDylibPaths = []
                    }) {
                        Text("Clear")
                            .padding(.vertical, 3)
                    }
                }
            }

            HStack {
                Text("Sign Backend")
                    .frame(width: 100)
                Picker(selection: $viewModel.resignBackend) {
                    ForEach(ResignBackend.allCases, id: \.rawValue) { option in
                        Text(option.displayName)
                            .tag(option)
                    }
                } label: {}
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 8)
            .padding(.vertical, 12)
            .background(Color.gray.opacity(0.2))
            .cornerRadius(10)

            HStack {
                Text("Resign Type")
                    .frame(width: 100)
                Picker(selection: $viewModel.resignType) {
                    ForEach(ResignExportType.allCases, id: \.rawValue) { option in
                        Text(option.rawValue)
                            .tag(option)
                    }
                } label: {}
                    .pickerStyle(.segmented) // 设置为下拉菜单样式
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 8)
            .padding(.vertical, 12)
            .background(Color.gray.opacity(0.2))
            .cornerRadius(10)

            InputField(title: "Output", text: $viewModel.outputDir) {
                guard let selectedUrl = selectFile(isDirectory: true) else {
                    return
                }
                viewModel.outputDir = selectedUrl.path
            }

            Text("Logcat:")
                .padding(.top)
            ScrollView(.vertical) {  // 指定垂直滚动
                Text(viewModel.logString)
                    .frame(maxWidth: .infinity)
            }
            .frame(height: 110)
            .padding(.init(top: 10, leading: 10, bottom: 10, trailing: 10))
            .background(Color.gray.opacity(0.2))
            .cornerRadius(10)

            HStack {
                Button(action: onTapStart) {
                    Text("Start")
                        .frame(width: 80, height: 30)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear(perform: {
            viewModel.inputFile = UserDefaults.standard.string(forKey: CacheKey.selectedInput.rawValue) ?? ""
            viewModel.p12Path = UserDefaults.standard.string(forKey: CacheKey.selectedP12.rawValue) ?? ""
            viewModel.p12Password = UserDefaults.standard.string(forKey: CacheKey.selectedP12Password.rawValue) ?? ""
            viewModel.mobileprovisionPath = UserDefaults.standard.string(forKey: CacheKey.selectedMobileProvision.rawValue) ?? ""
            viewModel.injectedDylibPaths = UserDefaults.standard.stringArray(forKey: CacheKey.selectedInjectedDylibs.rawValue) ?? []
            viewModel.resignBackend = ResignBackend(rawValue: UserDefaults.standard.string(forKey: CacheKey.selectedResignBackend.rawValue) ?? "") ?? .zsign
            viewModel.resignType = ResignExportType(rawValue: UserDefaults.standard.string(forKey: CacheKey.selectedResignType.rawValue) ?? "") ?? .dev
            viewModel.outputDir = UserDefaults.standard.string(forKey: CacheKey.selectedOutput.rawValue) ?? ""
        })
        .alert("Error", isPresented: Binding(value: $viewModel.presentError)) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.presentError?.localizedDescription ?? "")
        }
        .sheet(isPresented: $viewModel.loading) {
            CustomLoadingView(text: "重签中", color: .blue)
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

    private func onTapStart() {
        UserDefaults.standard.set(viewModel.inputFile, forKey: CacheKey.selectedInput.rawValue)
        UserDefaults.standard.set(viewModel.p12Path, forKey: CacheKey.selectedP12.rawValue)
        UserDefaults.standard.set(viewModel.p12Password, forKey: CacheKey.selectedP12Password.rawValue)
        UserDefaults.standard.set(viewModel.mobileprovisionPath, forKey: CacheKey.selectedMobileProvision.rawValue)
        UserDefaults.standard.set(viewModel.injectedDylibPaths, forKey: CacheKey.selectedInjectedDylibs.rawValue)
        UserDefaults.standard.set(viewModel.resignBackend.rawValue, forKey: CacheKey.selectedResignBackend.rawValue)
        UserDefaults.standard.set(viewModel.resignType.rawValue, forKey: CacheKey.selectedResignType.rawValue)
        UserDefaults.standard.set(viewModel.outputDir, forKey: CacheKey.selectedOutput.rawValue)

        let taskInfo = ResignTaskInfo(
            filePath: URL(fileURLWithPath: viewModel.inputFile),
            p12Path: URL(fileURLWithPath: viewModel.p12Path),
            p12Password: viewModel.p12Password,
            mobileProvisionPath: URL(fileURLWithPath: viewModel.mobileprovisionPath),
            appexResignInfos: nil,
            exportType: viewModel.resignType,
            backend: viewModel.resignBackend,
            injectedDylibPaths: viewModel.injectedDylibPaths.map { URL(fileURLWithPath: $0) },
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
            } catch {
                print("重签错误：", error.localizedDescription)
                viewModel.log(.ERROR, error.localizedDescription)
                DispatchQueue.main.async {
                    viewModel.presentError = error
                }
            }
            DispatchQueue.main.async {
                viewModel.loading = false
            }
        }
    }
}

#Preview {
    ContentView()
}
