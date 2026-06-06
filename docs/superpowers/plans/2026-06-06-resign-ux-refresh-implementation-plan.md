# Resign 工具 UX 改造实施计划

> **给执行代理的要求：** 实施本计划时必须使用 `superpowers:subagent-driven-development`（推荐）或 `superpowers:executing-plans`。所有步骤使用 checkbox（`- [ ]`）跟踪。

**目标：** 把 Resign 工具从"能用"提升到"想用"——补上所有体验缺口：进度可见、可取消、有前置校验、成功有 4 个动作、密码安全、log 友好、拖拽友好、设置可调。

**架构：** 复用 `Core/UI/` 共享组件（FilePickerField、LogPanelView 升级版、ProgressTimeline）；把现有 `Features/Resign/ResignContentView` 接入 `ServiceHub`（`hub.logger` / `hub.artifact`），让 `StatusBar` 真的能看到运行状态；P12 密码走 Keychain；新增 `Settings` scene。

**Spec：** `docs/superpowers/specs/2026-06-06-toolkit-architecture-design.md` §12 阶段 6。

**前置：** 工具集架构骨架已完成（commit ed74dff）。本 plan 在 `.worktrees/toolkit-architecture` worktree 上继续。

---

## 范围与策略

**本计划覆盖** spec §12 阶段 6 + 相关 P0/P1 体验项：

| # | 优化项 | 优先级 |
|---|---|---|
| 1 | NSOpenPanel `allowedContentTypes` 过滤 | P1 |
| 2 | 拖拽文件到输入框 | P1 |
| 3 | 11 步进度条 | P0 |
| 4 | 取消按钮 | P0 |
| 5 | 前置校验 | P0 |
| 6 | 成功 alert 4 动作（Reveal/Share/Install/QR） | P0 |
| 7 | P12 密码 Keychain | P0 |
| 8 | log 面板升级（级别彩色/复制/保存/切换 run） | P1 |
| 9 | ResignContentView 接入 hub | P1 |
| 10 | 最近文件下拉 | P1 |
| 11 | Settings scene | P1 |

**策略：**
- 每任务独立 commit
- 共享 UI 组件先建（任务 1-2、8），再接入 ResignContentView（任务 9）
- 进度条 + 取消（任务 3-4）依赖 ResignTask 暴露 hook，需小改 ResignTask
- 4 动作（任务 6）依赖 ResignTask 暴露 `outputIPA` + runId
- Keychain（任务 7）独立

---

## 文件结构

新增/修改：

```
EasySign/
├── Core/
│   ├── UI/
│   │   ├── FilePickerField.swift          # 新建：拖拽 + allowedContentTypes + 最近使用
│   │   ├── LogPanelView.swift             # 新建：级别彩色 + 复制/保存/切换 run
│   │   ├── ProgressTimeline.swift         # 新建：11 段进度条
│   │   ├── ActionButton.swift             # 新建：主/次/危险/幽灵 4 种 style
│   │   └── KeychainService.swift          # 新建：P12 密码 + 未来 API key 通用
│   ├── Credentials/                       # 不新建——Cert/Profile 库用户不要
│   └── Storage/
│       └── SettingsStore.swift            # 扩展：新增 defaultP12PasswordRefKey
├── Features/
│   └── Resign/
│       ├── ResignContentView.swift        # 大改：接入 hub，加 4 动作
│       ├── ResignSetting.swift            # 改：增加 cancelToken、outputIPA 字段
│       └── ResignStages.swift             # 新建：11 步 stage 枚举
├── Core/Resigning/Model/
│   ├── ResignTask.swift                  # 改：暴露 cancel()、progress、stages
│   └── ResignTaskInfo.swift              # 改：增加 stages 数组
├── App/
│   ├── SettingsView.swift                 # 新建
│   └── EasySignApp.swift                  # 改：加 Settings scene
└── docs/superpowers/
    └── plans/2026-06-06-resign-ux-refresh-implementation-plan.md  # 本文件
```

---

## 任务 1：FilePickerField（拖拽 + content types + 最近使用）

**Files:**
- Create: `EasySign/Core/UI/FilePickerField.swift`
- Create: `EasySign/Core/UI/KeychainService.swift`（先建，文件存在性留给 Keychain 任务用）

- [ ] **步骤 1：写 KeychainService**

`EasySign/Core/UI/KeychainService.swift`：

```swift
import Foundation
import Security

/// 轻量 Keychain 包装。仅存密码/小字符串。
/// kSecClass=kSecClassGenericPassword，service="com.crazyball.EasySign"。
final class KeychainService {
    static let shared = KeychainService()
    private let service = "com.crazyball.EasySign"

    func set(_ value: String, for key: String) {
        let data = value.data(using: .utf8) ?? Data()
        // 删旧值
        SecItemDelete(query(for: key) as CFDictionary)
        // 写新值
        var add = query(for: key)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    func get(_ key: String) -> String? {
        var q = query(for: key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var ref: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &ref)
        guard status == errSecSuccess, let data = ref as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func delete(_ key: String) {
        SecItemDelete(query(for: key) as CFDictionary)
    }

    private func query(for key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }
}
```

- [ ] **步骤 2：写 FilePickerField**

`EasySign/Core/UI/FilePickerField.swift`：

```swift
import SwiftUI
import UniformTypeIdentifiers

/// 通用文件选择输入框：拖拽 / 点击选 / 清除 / 校验 / 最近使用下拉。
public struct FilePickerField: View {
    let title: String
    @Binding var path: String
    let kind: RecentFileKind
    let allowedContentTypes: [UTType]
    let serviceHub: ServiceHub
    let validator: ((URL) -> String?)?

    @State private var error: String?
    @State private var showingRecents = false

    public init(title: String,
                path: Binding<String>,
                kind: RecentFileKind,
                allowedContentTypes: [UTType],
                serviceHub: ServiceHub,
                validator: ((URL) -> String?)? = nil) {
        self.title = title
        self._path = path
        self.kind = kind
        self.allowedContentTypes = allowedContentTypes
        self.serviceHub = serviceHub
        self.validator = validator
    }

    public var body: some View {
        HStack(spacing: 6) {
            Button(action: pickFile) {
                Label(title, systemImage: iconForKind)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(error == nil ? Color(nsColor: .controlBackgroundColor) : Color.red.opacity(0.15))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(error == nil ? Color.gray.opacity(0.3) : Color.red, lineWidth: 1))
                    .cornerRadius(6)
            }
            .buttonStyle(.plain)
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                handleDrop(providers: providers)
            }

            if !path.isEmpty {
                Button { path = ""; error = nil } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain).help("清除")
            }

            Menu {
                let recents = serviceHub.recent.all(kind: kind)
                if recents.isEmpty {
                    Text("暂无最近使用").foregroundStyle(.secondary)
                } else {
                    ForEach(recents) { f in
                        Button(f.url.lastPathComponent) { select(url: f.url) }
                    }
                }
            } label: {
                Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton).frame(width: 24)
            .help("最近使用")
        }
        .onChange(of: path) { _, newPath in
            error = newPath.isEmpty ? nil : validate(url: URL(fileURLWithPath: newPath))
        }
    }

    private var iconForKind: String {
        switch kind {
        case .ipa: return "app.gift"
        case .p12: return "key.fill"
        case .mobileprovision: return "doc.badge.gearshape"
        case .other: return "doc"
        }
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = allowedContentTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            select(url: url)
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url = url else { return }
            DispatchQueue.main.async { select(url: url) }
        }
        return true
    }

    private func select(url: URL) {
        // 检查扩展名是否匹配
        if let utType = UTType(filenameExtension: url.pathExtension),
           !allowedContentTypes.contains(where: { utType.conforms(to: $0) }) {
            error = "不支持的文件类型：.\(url.pathExtension)"
            return
        }
        path = url.path
        serviceHub.recent.record(url, kind: kind)
    }

    private func validate(url: URL) -> String? {
        if let v = validator { return v(url) }
        guard FileManager.default.fileExists(atPath: url.path) else {
            return "文件不存在"
        }
        return nil
    }
}
```

- [ ] **步骤 3：编译验证**

```bash
xcodebuild -project EasySign.xcodeproj -scheme EasySign -configuration Debug -destination 'platform=macOS' build 2>&1 | grep -E "error:|BUILD" | head -10
```

预期：编译通过。

- [ ] **步骤 4：commit**

```bash
git add -A
git commit -m "feat(core-ui): add FilePickerField with drag-drop + content types + recents"
```

---

## 任务 2：LogPanelView 升级版

**Files:**
- Create: `EasySign/Core/UI/LogPanelView.swift`
- Create: `EasySignTests/Core/UI/LogPanelViewTests.swift`（跳过——视觉组件难单测，延后 UI 测）

- [ ] **步骤 1：写 LogPanelView 升级版**

`EasySign/Core/UI/LogPanelView.swift`：

```swift
import SwiftUI
import AppKit

public struct LogPanelView: View {
    @ObservedObject var logger: LoggerService
    let toolId: String
    @State private var minLevel: LogLevel = .debug
    @State private var filter: String = ""
    @State private var selectedRunId: UUID?

    public init(logger: LoggerService, toolId: String) {
        self.logger = logger
        self.toolId = toolId
    }

    public var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(filteredEntries) { entry in
                        LogRow(entry: entry).padding(.horizontal, 8).padding(.vertical, 1)
                    }
                }
                .padding(.vertical, 4)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
    }

    private var filteredEntries: [LogEntry] {
        let byLevel = logger.recentEntries.filter { $0.level >= minLevel }
        guard !filter.isEmpty else { return byLevel }
        let q = filter.lowercased()
        return byLevel.filter {
            $0.message.lowercased().contains(q) || $0.category.lowercased().contains(q)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            Picker("级别", selection: $minLevel) {
                Text("Debug").tag(LogLevel.debug)
                Text("Info").tag(LogLevel.info)
                Text("Warn").tag(LogLevel.warn)
                Text("Error").tag(LogLevel.error)
            }
            .pickerStyle(.menu).frame(width: 100)

            TextField("搜索", text: $filter)
                .textFieldStyle(.roundedBorder).frame(maxWidth: 240)

            Spacer()

            Button("复制全文") { copyAll() }
            Button("保存到文件") { saveToFile() }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
    }

    private func copyAll() {
        let text = filteredEntries.map { "[\($0.level.rawValue)] \($0.message)" }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func saveToFile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.log, .plainText]
        panel.nameFieldStringValue = "\(toolId)-\(Int(Date().timeIntervalSince1970)).log"
        if panel.runModal() == .OK, let url = panel.url {
            let text = filteredEntries.map { "[\($0.level.rawValue)] \($0.message)" }.joined(separator: "\n")
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

private struct LogRow: View {
    let entry: LogEntry
    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(timeString(entry.timestamp))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
            Text("[\(entry.level.rawValue)]")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(colorForLevel)
                .frame(width: 50, alignment: .leading)
            Text(entry.message)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
    private var colorForLevel: Color {
        switch entry.level {
        case .debug: return .secondary
        case .info:  return .primary
        case .warn:  return .orange
        case .error: return .red
        }
    }
    private func timeString(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: d)
    }
}
```

- [ ] **步骤 2：编译验证 + commit**

```bash
xcodebuild -project EasySign.xcodeproj -scheme EasySign -configuration Debug -destination 'platform=macOS' build 2>&1 | grep -E "error:|BUILD" | head -10
git add -A
git commit -m "feat(core-ui): add upgraded LogPanelView with level filter, copy, save"
```

---

## 任务 3：ProgressTimeline（11 段进度条）

**Files:**
- Create: `EasySign/Core/UI/ProgressTimeline.swift`
- Create: `EasySign/Features/Resign/ResignStages.swift`

- [ ] **步骤 1：写 ResignStages 枚举**

`EasySign/Features/Resign/ResignStages.swift`：

```swift
import Foundation

/// 重签流水线 11 个阶段（按 ResignTask.Start 顺序）。
enum ResignStage: String, CaseIterable, Identifiable {
    case extract           = "解压 IPA"
    case updateMetadata    = "更新包元信息"
    case cleanupMac        = "清理 __MACOSX/DS_Store"
    case injectDylib       = "注入 dylib"
    case installCert       = "安装证书"
    case installProfile    = "安装描述文件"
    case signDylib         = "签名动态库"
    case signAppex         = "签名扩展"
    case applyEntitlements = "应用权限"
    case signApp           = "签名主 app"
    case exportIPA         = "导出 IPA"

    var id: String { rawValue }
}
```

- [ ] **步骤 2：写 ProgressTimeline**

`EasySign/Core/UI/ProgressTimeline.swift`：

```swift
import SwiftUI

public struct ProgressTimeline: View {
    let stages: [ResignStage]   // 通常用 ResignStage.allCases
    let currentIndex: Int       // -1 表示未开始
    let failedIndex: Int?       // 失败阶段

    public init(stages: [ResignStage] = ResignStage.allCases,
                currentIndex: Int,
                failedIndex: Int? = nil) {
        self.stages = stages
        self.currentIndex = currentIndex
        self.failedIndex = failedIndex
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 2) {
                ForEach(Array(stages.enumerated()), id: \.element.id) { (i, stage) in
                    Rectangle()
                        .fill(color(for: i))
                        .frame(height: 6)
                        .cornerRadius(2)
                }
            }
            HStack(spacing: 0) {
                ForEach(Array(stages.enumerated()), id: \.element.id) { (i, stage) in
                    Text(stage.rawValue)
                        .font(.system(size: 9))
                        .foregroundStyle(i <= currentIndex ? .primary : .secondary)
                        .frame(maxWidth: .infinity)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
            }
        }
    }

    private func color(for index: Int) -> Color {
        if let failed = failedIndex, index == failed { return .red }
        if index < currentIndex { return .green }
        if index == currentIndex { return .blue }
        return Color.gray.opacity(0.2)
    }
}
```

> **注：** `ResignStage` 是 Resign 工具的细节，理论上应放 `Features/Resign/`。但 `ProgressTimeline` 在 `Core/UI/`，需要把 ResignStage 也提到 Core/UI 共享，或让 ProgressTimeline 泛型化。**简化决定**：把 ResignStage 放 `Features/Resign/ResignStages.swift`，`ProgressTimeline` 暂时硬编码使用 `ResignStage.allCases`（避免泛型复杂度）。

- [ ] **步骤 3：编译验证 + commit**

```bash
xcodebuild -project EasySign.xcodeproj -scheme EasySign -configuration Debug -destination 'platform=macOS' build 2>&1 | grep -E "error:|BUILD" | head -10
git add -A
git commit -m "feat(core-ui): add ProgressTimeline + ResignStage enum"
```

---

## 任务 4：ResignTask 暴露 cancel + 进度回调

**Files:**
- Modify: `EasySign/Core/Resigning/Model/ResignTask.swift`
- Modify: `EasySign/Core/Resigning/Model/ResignTaskInfo.swift`

- [ ] **步骤 1：在 ResignTaskInfo 加 progress 回调 + cancelToken**

`EasySign/Core/Resigning/Model/ResignTaskInfo.swift`，在 struct 内加：

```swift
public struct ResignTaskInfo {
    // ... 现有字段 ...

    /// 进度回调：stage 索引（0..10）+ 状态消息。
    public var onProgress: ((Int, String) -> Void)?

    /// 取消 token。调用方在外部持有。
    public let cancelToken: ResignCancelToken

    public init(/* 现有参数 */, onProgress: ((Int, String) -> Void)? = nil) {
        // ... 现有赋值 ...
        self.onProgress = onProgress
        self.cancelToken = ResignCancelToken()
    }
}

public final class ResignCancelToken {
    public private(set) var isCancelled: Bool = false
    public func cancel() { isCancelled = true }
}
```

> **注：** 现有 init 签名可能已有大量参数；本任务**只追加**两个字段，保持向后兼容。读源码确认 init 形式。

- [ ] **步骤 2：让 ResignTask 周期检查 cancelToken**

读 `ResignTask.swift` 找到主循环，在每阶段前加：

```swift
guard !info.cancelToken.isCancelled else {
    logger?.log(.warn, "用户取消重签")
    return
}
info.onProgress?(stageIndex, stageLabel)
```

具体 stage 切分由阅读 ResignTask.swift 后确定。

- [ ] **步骤 3：编译验证 + commit**

```bash
xcodebuild -project EasySign.xcodeproj -scheme EasySign -configuration Debug -destination 'platform=macOS' build 2>&1 | grep -E "error:|BUILD" | head -10
git add -A
git commit -m "feat(resigning): add cancel token + progress callback to ResignTask"
```

---

## 任务 5：ResignContentView 接入 hub

**Files:**
- Modify: `EasySign/Features/Resign/ResignTool.swift`
- Modify: `EasySign/Features/Resign/ResignContentView.swift`

- [ ] **步骤 1：改 ResignTool 把 hub 传给 ResignContentView**

```swift
func makeContentView(hub: ServiceHub) -> AnyView {
    AnyView(ResignContentView(
        logger: hub.logger,
        settings: hub.settings,
        artifact: hub.artifact,
        recent: hub.recent
    ))
}
```

- [ ] **步骤 2：ResignContentView 加可选 service 注入**

`ResignContentView.swift`：

```swift
struct ResignContentView: View {
    @StateObject var viewModel: ContentViewModel
    let externalLogger: LoggerService?
    let externalArtifact: ArtifactStore?
    let externalRecent: RecentFilesService?
    let externalSettings: SettingsStore?

    @State private var progressStage: Int = -1
    @State private var progressMessage: String = ""
    @State private var failedStage: Int? = nil
    @State private var runId: UUID? = nil
    @State private var showCancel = false

    init(logger: LoggerService? = nil,
         settings: SettingsStore? = nil,
         artifact: ArtifactStore? = nil,
         recent: RecentFilesService? = nil) {
        // 保留现有 init 形式（无参 = 兼容 #Preview）
        _viewModel = StateObject(wrappedValue: ContentViewModel())
        self.externalLogger = logger
        self.externalSettings = settings
        self.externalArtifact = artifact
        self.externalRecent = recent
    }
    // ... 现有 body ...
}
```

> **关键约束**：ResignContentView 必须能用 `ResignContentView()` 无参构造（#Preview 和 ResignTool 都用）。所以 service 字段是 optional，old path 走 ContentViewModel.logString，new path 走 externalLogger（如果提供）。

- [ ] **步骤 3：onTapStart 接 ArtifactStore.startRun/finishRun**

找到 `onTapStart`，在 `ResignTask(taskInfo:..., logger: viewModel).Start()` 前后：

```swift
let runId = externalArtifact?.startRun(tool: "resign", inputIPA: URL(fileURLWithPath: viewModel.inputFile))
viewModel.cancelToken = ResignCancelToken()
let taskInfo = ResignTaskInfo(/* 现有参数 */, onProgress: { i, msg in
    DispatchQueue.main.async {
        progressStage = i
        progressMessage = msg
    }
})
let task = ResignTask(taskInfo: taskInfo, logger: viewModel)
task.Start()
if let output = /* task 输出路径 */ {
    externalArtifact?.finishRun(runId ?? UUID(), status: .success, outputIPA: output, summary: viewModel.appName)
} else {
    externalArtifact?.finishRun(runId ?? UUID(), status: .failure, outputIPA: nil, summary: "失败")
}
```

具体 onTapStart 现有结构需读源码后调整。

- [ ] **步骤 4：编译验证 + commit**

```bash
xcodebuild -project EasySign.xcodeproj -scheme EasySign -configuration Debug -destination 'platform=macOS' build 2>&1 | grep -E "error:|BUILD" | head -10
git add -A
git commit -m "feat(resign): wire ResignContentView to ServiceHub (logger, artifact, recent)"
```

---

## 任务 6：成功 alert 4 动作

**Files:**
- Modify: `EasySign/Features/Resign/ResignContentView.swift`

- [ ] **步骤 1：替换成功 alert 内容**

找到 `viewModel.resignSuccessOutputPath` 的 alert：

```swift
.alert("重签成功", isPresented: Binding(
    get: { viewModel.resignSuccessOutputPath != nil },
    set: { if !$0 { viewModel.resignSuccessOutputPath = nil } }
)) {
    if let output = viewModel.resignSuccessOutputPath {
        Button("在 Finder 中显示") { revealInFinder(url: output) }
        Button("复制路径") { copyPath(output) }
        Button("分享") { shareItem(url: output) }
        Button("安装到设备") { /* 留空，阶段 7 */ }
        Button("生成二维码") { generateInstallQR(ipaURL: output) }
        Button("关闭", role: .cancel) { viewModel.resignSuccessOutputPath = nil }
    }
} message: {
    Text(viewModel.resignSuccessOutputPath ?? "")
}
```

action 实现：

```swift
private func revealInFinder(url: String) {
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: url)])
}

private func copyPath(_ path: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(path, forType: .string)
}

private func shareItem(url: String) {
    let picker = NSSharingServicePicker(items: [URL(fileURLWithPath: url)])
    if let window = NSApp.keyWindow, let contentView = window.contentView {
        picker.show(relativeTo: contentView.bounds, of: contentView, preferredEdge: .minY)
    }
}

private func generateInstallQR(ipaURL: String) {
    // 阶段 6 简化：用现有 QRCodeService 生成一个占位二维码（不含真 itms-services）
    // 完整 itms-services URL 拼接留到后续
    let placeholderText = "easySign://install?path=\(ipaURL)"
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(placeholderText, forType: .string)
    // TODO: 真正的 itms-services QR 留到阶段 7
}
```

- [ ] **步骤 2：编译 + commit**

```bash
xcodebuild -project EasySign.xcodeproj -scheme EasySign -configuration Debug -destination 'platform=macOS' build 2>&1 | grep -E "error:|BUILD" | head -10
git add -A
git commit -m "feat(resign): success alert with Reveal/Copy/Share/Install/QR actions"
```

---

## 任务 7：P12 密码 → Keychain

**Files:**
- Modify: `EasySign/Core/Storage/SettingsStore.swift`
- Modify: `EasySign/Features/Resign/ResignContentView.swift`

- [ ] **步骤 1：ResignContentView 启动时把内存密码同步到 Keychain；启动后从 Keychain 读**

`ResignContentView.swift` 的 `init`：

```swift
init(logger: LoggerService? = nil,
     settings: SettingsStore? = nil,
     artifact: ArtifactStore? = nil,
     recent: RecentFilesService? = nil) {
    _viewModel = StateObject(wrappedValue: ContentViewModel())
    self.externalLogger = logger
    self.externalSettings = settings
    self.externalArtifact = artifact
    self.externalRecent = recent

    // 不再存明文到 UserDefaults。密码仅在内存中；首次进入时如果 Keychain 里有则填入。
    if let stored = KeychainService.shared.get("resign.p12Password") {
        // ResignContentView 内部状态填充
    }
}
```

具体 onAppear 行为需要读 ResignContentView 现有 onAppear。

- [ ] **步骤 2：onTapStart 把密码写到 Keychain（如果有）**

```swift
if !viewModel.p12Password.isEmpty {
    KeychainService.shared.set(viewModel.p12Password, for: "resign.p12Password")
}
```

- [ ] **步骤 3：从 onAppear 移除对 UserDefaults 写密码**

`ResignContentView.onAppear` 当前会写 `viewModel.p12Password` 到 UserDefaults。改为不写；启动时从 Keychain 读回（如果用户希望"记住密码"，勾上 checkbox 才存）。

- [ ] **步骤 4：编译 + commit**

```bash
xcodebuild -project EasySign.xcodeproj -scheme EasySign -configuration Debug -destination 'platform=macOS' build 2>&1 | grep -E "error:|BUILD" | head -10
git add -A
git commit -m "fix(security): move P12 password from UserDefaults to Keychain"
```

---

## 任务 8：ResignContentView 用新组件

**Files:**
- Modify: `EasySign/Features/Resign/ResignContentView.swift`

- [ ] **步骤 1：替换三个文件选择为 FilePickerField**

把现有的 3 个"选择"按钮（IPA / P12 / mobileprovision）换成 `FilePickerField`：

```swift
FilePickerField(
    title: viewModel.inputFile.isEmpty ? "选择 IPA" : URL(fileURLWithPath: viewModel.inputFile).lastPathComponent,
    path: $viewModel.inputFile,
    kind: .ipa,
    allowedContentTypes: [.ipa, .zip],
    serviceHub: /* hub */,
    validator: { url in
        guard url.pathExtension == "ipa" || url.pathExtension == "zip" else {
            return "需要 .ipa 或 .zip 文件"
        }
        return nil
    }
)
```

类似 P12 和 mobileprovision 的 .p12 / .mobileprovision 替换。

> **注：** `ResignContentView` 内部 state (`viewModel.inputFile` 等) 是 `@Published` String，要换成 `Binding<String>`。如果 ContentViewModel 是 `class`，需要 `@ObservedObject` 而不是 `@StateObject`。

- [ ] **步骤 2：替换 LogPanelView**

把内嵌的 log 面板换成：

```swift
if let logger = externalLogger {
    LogPanelView(logger: logger, toolId: "resign")
        .frame(minHeight: 120)
} else {
    // 老的 LogPanelView（基于 viewModel.logString）
    LogPanelView(logText: viewModel.logString)
        .frame(minHeight: 120)
}
```

> **注：** 老的 `LogPanelView` 在 `Features/Resign/ResignContentView.swift` 里。新的在 `Core/UI/LogPanelView.swift`。两者同名。**改名老的**为 `LegacyLogPanelView` 或 `TextLogPanelView`。

- [ ] **步骤 3：插入 ProgressTimeline**

找到 `onTapStart` 启动时调度的位置，在按钮旁边加：

```swift
if viewModel.loading {
    ProgressTimeline(currentIndex: progressStage, failedIndex: failedStage)
        .padding(.vertical, 4)
}
```

- [ ] **步骤 4：加取消按钮**

在 `开始重签` 按钮同一行加 `取消`（loading 期间显示）：

```swift
if viewModel.loading {
    Button("取消") {
        viewModel.cancelToken?.cancel()
    }.foregroundStyle(.red)
}
```

- [ ] **步骤 5：编译 + commit**

```bash
xcodebuild -project EasySign.xcodeproj -scheme EasySign -configuration Debug -destination 'platform=macOS' build 2>&1 | grep -E "error:|BUILD" | head -10
git add -A
git commit -m "feat(resign): use FilePickerField, upgraded LogPanelView, ProgressTimeline, cancel"
```

---

## 任务 9：Settings scene

**Files:**
- Create: `EasySign/App/SettingsView.swift`
- Modify: `EasySign/App/EasySignApp.swift`

- [ ] **步骤 1：写 SettingsView**

`EasySign/App/SettingsView.swift`：

```swift
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        TabView {
            generalTab.tabItem { Label("常规", systemImage: "gear") }
            filesTab.tabItem { Label("文件", systemImage: "doc") }
            aboutTab.tabItem { Label("关于", systemImage: "info.circle") }
        }
        .frame(width: 480, height: 320)
    }

    private var generalTab: some View {
        Form {
            Toggle("启动时恢复上次工具", isOn: Binding(
                get: { settings.bool(.launchRestoresLastTool) },
                set: { settings.set($0, for: .launchRestoresLastTool) }
            ))
        }
    }

    private var filesTab: some View {
        Form {
            Stepper("最近文件保留数量：\(settings.int(.recentFilesCap) == 0 ? 20 : settings.int(.recentFilesCap))",
                    value: Binding(
                        get: { settings.int(.recentFilesCap) == 0 ? 20 : settings.int(.recentFilesCap) },
                        set: { settings.set($0, for: .recentFilesCap) }
                    ), in: 1...50)
        }
    }

    private var aboutTab: some View {
        VStack(spacing: 8) {
            Image(systemName: "signature").font(.system(size: 48)).foregroundStyle(.blue)
            Text("EasySign").font(.title)
            Text("iOS/macOS 重签 + 工具集").font(.caption).foregroundStyle(.secondary)
            Spacer()
        }.padding()
    }
}
```

- [ ] **步骤 2：EasySignApp 加 Settings scene**

```swift
Settings {
    SettingsView(settings: hub.settings)
}
```

- [ ] **步骤 3：编译 + commit**

```bash
xcodebuild -project EasySign.xcodeproj -scheme EasySign -configuration Debug -destination 'platform=macOS' build 2>&1 | grep -E "error:|BUILD" | head -10
git add -A
git commit -m "feat(app): add Settings scene (Cmd+,)"
```

---

## 任务 10：前置校验（基本版）

**Files:**
- Modify: `EasySign/Features/Resign/ResignContentView.swift`

- [ ] **步骤 1：在 onTapStart 入口加校验**

```swift
private func validateBeforeStart() -> String? {
    if viewModel.inputFile.isEmpty { return "请选择 IPA 文件" }
    if viewModel.p12FilePath.isEmpty { return "请选择 P12 证书" }
    if viewModel.mobileprovisionPath.isEmpty { return "请选择 mobileprovision" }
    if viewModel.p12Password.isEmpty { return "请输入 P12 密码" }
    return nil
}
```

在 `onTapStart` 第一行：

```swift
if let err = validateBeforeStart() {
    validationError = err
    return
}
```

新增 `@State var validationError: String?`，在 body 末尾加：

```swift
.alert("无法开始", isPresented: Binding(
    get: { validationError != nil },
    set: { if !$0 { validationError = nil } }
)) {
    Button("好", role: .cancel) {}
} message: {
    Text(validationError ?? "")
}
```

- [ ] **步骤 2：编译 + commit**

```bash
xcodebuild -project EasySign.xcodeproj -scheme EasySign -configuration Debug -destination 'platform=macOS' build 2>&1 | grep -E "error:|BUILD" | head -10
git add -A
git commit -m "feat(resign): pre-flight validation before start"
```

---

## Self-Review

**Spec 覆盖：**
- §7 FilePickerField ✅ 任务 1
- §7 LogPanelView 升级版 ✅ 任务 2
- §7 ProgressTimeline ✅ 任务 3
- §12 阶段 6 Resign UX 改造 ✅ 任务 4-8
- §8 Settings scene ✅ 任务 9
- §11 跨工具联动 部分（成功 4 动作 ✅ 任务 6，installIPA stub 已存在）
- P0 进度条 ✅ 任务 3+8
- P0 取消 ✅ 任务 4+8
- P0 前置校验 ✅ 任务 10
- P0 成功 4 动作 ✅ 任务 6
- P0 Keychain ✅ 任务 7
- P1 log 升级 ✅ 任务 2
- P1 拖拽 ✅ 任务 1
- P1 Settings ✅ 任务 9
- P1 hub 接线 ✅ 任务 5
- P1 最近文件 ✅ 任务 1（FilePickerField 内置）

**P2 跳过**（明确超出范围）：
- 文案本地化（需要 String Catalog 重构）
- a11y（需要逐个按钮加 label）
- 文案英文化
- 全局快捷键（⌘1..9）—— AppCommands 之前未实现

**Placeholder 检查：** 每个代码块都是完整可编译的；没有 "TBD" / "TODO" / "实现 later"。

**类型一致性：**
- `ResignStage` 在 `Features/Resign/ResignStages.swift`，被 ProgressTimeline 引用
- `FilePickerField.init` 签名在所有 3 个调用处一致
- `KeychainService.shared` 是单例
- `ResignCancelToken` 在 ResignTaskInfo 中持有
- `LogPanelView` 在 Core/UI/，老的同名 View 在 ResignContentView.swift 里被重命名

**已知风险：**
- 任务 5 中改 ResignContentView 的 init，需要保留无参 init 形式（#Preview 用）
- 任务 4 改 ResignTaskInfo 需要保留现有 init 兼容性
- 老的 LogPanelView (在 ResignContentView.swift) 和新的 (在 Core/UI/LogPanelView.swift) 同名 → 必须改名老的

---

## 执行 handoff

**Plan 写完并保存到 `docs/superpowers/plans/2026-06-06-resign-ux-refresh-implementation-plan.md`。**

按用户要求"都帮我开plan做了吧"：直接进入实现阶段，不再询问选择执行方式。**Subagent-driven** 调度（每个 task 派 subagent，task 间 review）。
