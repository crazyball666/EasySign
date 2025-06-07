//
//  ContentView.swift
//  EasySign
//
//  Created by crazyball on 2024/7/13.
//

import SwiftUI

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
                self.selectedIPA = nil
            }
        }
    }
    
    @Published var p12Path = ""
    
    @Published var p12Password = ""
    
    @Published var mobileprovisionPath = ""
    
    @Published var resignType: ResignExportType = .dev
    
    @Published var outputDir = ""
    
    @Published var isDetailActive = false
    
    @Published var logString: String = ""
    
    @Published var resignSetting: ResignSetting?
        
    @Published var presentError: Error?
    
    @Published var loading: Bool = false
        
    var selectedIPA: IPA? {
        didSet {
            guard let ipa = selectedIPA else {
                return
            }
            do {
                let entitlements = try ipa.appBundle.getEntitlementsString()
                resignSetting = ResignSetting(
                    bundleId: ipa.appBundle.bundleId,
                    displayName: ipa.appBundle.displayName,
                    version: ipa.appBundle.version,
                    buildVersion: ipa.appBundle.buildVersion,
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



struct ContentView: View {
    @StateObject var viewModel = ContentViewModel()
    @State var logText = ""
    
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

            HStack {
                Picker(selection: $viewModel.resignType) {
                    ForEach(ResignExportType.allCases, id: \.rawValue) { option in
                        Text(option.rawValue).tag(option)
                    }
                } label: {
                    Text("Resign Type")
                        .frame(width: 100)
                }
                .pickerStyle(.menu) // 设置为下拉菜单样式
                
            }
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
            .frame(height: 180)
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
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = !isDirectory
        panel.canChooseDirectories = isDirectory
        if panel.runModal() == .OK {
            return panel.url
        }
        return nil
    }
    
    private func showIPAInfo() {
        if viewModel.selectedIPA != nil {
            viewModel.isDetailActive = true
            return
        }
        if let inputFile = URL(string: viewModel.inputFile) {
            do {
                let ipa = try IPA(file:inputFile)
                viewModel.selectedIPA = ipa
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
        UserDefaults.standard.set(viewModel.resignType.rawValue, forKey: CacheKey.selectedResignType.rawValue)
        UserDefaults.standard.set(viewModel.outputDir, forKey: CacheKey.selectedOutput.rawValue)
        
        let taskInfo = ResignTaskInfo(
            filePath: URL(fileURLWithPath: viewModel.inputFile),
            p12Path: URL(fileURLWithPath: viewModel.p12Path),
            p12Password: viewModel.p12Password,
            mobileProvisionPath: URL(fileURLWithPath: viewModel.mobileprovisionPath),
            appexResignInfos: nil,
            exportType: viewModel.resignType,
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
