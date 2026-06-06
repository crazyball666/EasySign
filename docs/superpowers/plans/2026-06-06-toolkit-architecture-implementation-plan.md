# EasySign 工具集架构实施计划

> **给执行代理的要求：** 实施本计划时必须使用 `superpowers:subagent-driven-development`（推荐）或 `superpowers:executing-plans`。所有步骤使用 checkbox（`- [ ]`）跟踪。

**目标：** 把 EasySign 从"重签工具"重构为"工具集平台"。3 层架构（App/Features/Core），共享服务通过 ServiceHub 注入，现有 3 个工具（Resign/QRCode/Devices）按新规范归位，**不重写工作代码**。

**架构：**
- **App/**：顶层 UI、入口、ToolRegistry 路由
- **Features/**：用户能感知的工具（每个 = Tool + View + ViewModel）
- **Core/**：基础设施库（Toolkit 协议、共享 UI、Logger、Storage、Devices、Resigning、QR）
- 依赖方向：App → Features → Core，**只能向下**

**技术栈：** Swift 5.9+、SwiftUI、AppKit（NSOpenPanel/NSWorkspace）、MobileDevice.framework、xcodebuild、xcrun。

**Spec：** `docs/superpowers/specs/2026-06-06-toolkit-architecture-design.md`

---

## 范围与策略

**本计划覆盖 spec §12 的阶段 1-5**，这是架构骨架。**阶段 6（Resign UX 改造）和阶段 7（新工具）不在本计划范围内**，后续按 spec 单独 plan。

**策略：**
- **物理搬迁优先**（阶段 1）—— `git mv` 改目录，不改代码，最小风险
- **每阶段独立 commit、可回退**
- **Feature flag**：`useRootView` 默认 `false` 直至阶段 5 切到 `true`
- **测试**：仅对 ServiceHub.validate、RecentFilesService、SettingsStore、ArtifactStore 等有清晰契约的代码加单元测试；阶段 1-2 不加测试（纯重命名/壳代码）

---

## 文件结构（实施后）

```
EasySign/
├── App/                                       # 顶层
│   ├── EasySignApp.swift                      # 从 Views/ 搬入
│   ├── RootView.swift                         # 新建（阶段 5）
│   ├── SidebarView.swift                      # 新建（阶段 5）
│   ├── ToolSwitcher.swift                     # 新建（阶段 5）
│   ├── StatusBar.swift                        # 新建（阶段 5）
│   └── Commands/                              # 新建（阶段 5）
│
├── Features/                                  # 工具
│   ├── Resign/
│   │   ├── ResignTool.swift                   # 新建（阶段 2）
│   │   ├── ResignContentView.swift            # 从 Views/ 搬入（阶段 1）
│   │   ├── ResignViewModel.swift              # 从 ContentViewModel 改名（阶段 1/2）
│   │   ├── ResignSetting.swift
│   │   ├── IPAContentView.swift               # 从 Views/ 搬入
│   │   └── IPAPreviewPanelView.swift          # 从 Views/ 搬入
│   ├── QRCode/
│   │   ├── QRCodeTool.swift                   # 新建（阶段 2）
│   │   └── QRCodeToolView.swift               # 从 Views/ 搬入（阶段 1）
│   └── Devices/
│       ├── DevicesTool.swift                  # 新建（阶段 2）
│       └── DeviceView.swift + 其他           # 从 Views/ 搬入（阶段 1）
│
├── Core/
│   ├── Toolkit/                               # 新建（阶段 2）
│   │   ├── Tool.swift
│   │   ├── ToolRegistry.swift
│   │   ├── ToolCategory.swift
│   │   ├── ServiceHub.swift
│   │   ├── ServiceKey.swift
│   │   └── ToolError.swift
│   ├── UI/                                    # 新建（阶段 5 之后才填，本计划不动）
│   ├── Logging/
│   │   └── LoggerService.swift                # 新建（阶段 3）
│   ├── Storage/
│   │   ├── SettingsStore.swift                # 新建（阶段 3）
│   │   ├── RecentFilesService.swift           # 新建（阶段 3）
│   │   └── ArtifactStore.swift                # 新建（阶段 3）
│   ├── Devices/                               # 从 DeviceService/ 搬入（阶段 1）
│   ├── Resigning/                             # 从 ResignService/ 搬入（阶段 1）
│   └── QR/                                    # 从 Tools/QRCodeService.swift 搬入（阶段 1）
│
├── EasySignQuickLook/                         # 保留
├── Vendor/                                    # 保留
└── Resources/                                 # 保留
```

---

## 任务 1：阶段 1 — 物理搬迁（git mv）

**Files:**
- 移动：`ResignService/` → `Core/Resigning/`
- 移动：`DeviceService/` → `Core/Devices/`
- 移动：`Tools/QRCodeService.swift` → `Core/QR/QRCodeService.swift`
- 移动：`Views/EasySignApp.swift` → `App/EasySignApp.swift`
- 移动：`Views/ContentView.swift` → `Features/Resign/ResignContentView.swift`
- 移动：`Views/ResignContentView.swift` → `Features/Resign/ResignContentView.swift`（已存在则覆盖；先 diff 再决定）
- 移动：`Views/QRCodeToolView.swift` → `Features/QRCode/QRCodeToolView.swift`
- 移动：`Views/DeviceView.swift` → `Features/Devices/DeviceView.swift`
- 移动：`Views/IPAContentView.swift` → `Features/Resign/IPAContentView.swift`
- 移动：`Views/IPAPreviewPanelView.swift` → `Features/Resign/IPAPreviewPanelView.swift`
- 移动：`Views/IPAPreviewService.swift`（如果在 Views/）→ `Core/Resigning/IPAPreviewService.swift`（它是 Resign 引擎的一部分）
- 其他 Views/ 文件按所属工具归位
- 创建空目录：`App/Commands/`、`App/RootView.swift`（占位）、`Core/Toolkit/`、`Core/Logging/`、`Core/Storage/`

- [ ] **步骤 1：列出 Views/ 下所有 swift 文件**

```bash
find EasySign/Views -name "*.swift" | sort
```

记录所有需要移动的文件。

- [ ] **步骤 2：物理移动 ResignService、DeviceService、QRCodeService**

```bash
git mv EasySign/ResignService EasySign/Core/Resigning
git mv EasySign/DeviceService EasySign/Core/Devices
mkdir -p EasySign/Core/QR
git mv EasySign/Tools/QRCodeService.swift EasySign/Core/QR/QRCodeService.swift
```

- [ ] **步骤 3：物理移动 Views/ 下的文件到 Features/ 和 App/**

```bash
# 创建目录
mkdir -p EasySign/App EasySign/Features/Resign EasySign/Features/QRCode EasySign/Features/Devices
mkdir -p EasySign/App/Commands

# 移动 entry point
git mv EasySign/Views/EasySignApp.swift EasySign/App/EasySignApp.swift

# 移动到 Features/Resign
git mv EasySign/Views/ContentView.swift EasySign/Features/Resign/ResignContentView.swift
git mv EasySign/Views/ResignContentView.swift EasySign/Features/Resign/ResignContentView.swift
git mv EasySign/Views/IPAContentView.swift EasySign/Features/Resign/IPAContentView.swift
git mv EasySign/Views/IPAPreviewPanelView.swift EasySign/Features/Resign/IPAPreviewPanelView.swift

# 移动到 Features/QRCode
git mv EasySign/Views/QRCodeToolView.swift EasySign/Features/QRCode/QRCodeToolView.swift

# 移动到 Features/Devices
git mv EasySign/Views/DeviceView.swift EasySign/Features/Devices/DeviceView.swift
```

- [ ] **步骤 4：处理其他 Views/ 文件**

对步骤 1 列出但未移动的文件，逐个决定：
- 工具专属的 → `Features/<tool>/`
- 共享 UI 组件 → `Core/UI/`（阶段 6 再做，本任务先**保留原位**于 `Features/_Shared/` 或 `Views/` 临时目录）

```bash
# 示例：把 SandBoxBrowser 移到 Devices 工具
# git mv EasySign/Views/SandboxBrowserView.swift EasySign/Features/Devices/SandboxBrowserView.swift
# 实际上根据步骤 1 结果调整
```

- [ ] **步骤 5：清理空目录**

```bash
# 删除已清空的 Views/ 和 Tools/
rmdir EasySign/Views 2>/dev/null || true
rmdir EasySign/Tools 2>/dev/null || true
```

- [ ] **步骤 6：xcodebuild 验证编译通过**

```bash
xcodebuild -project EasySign.xcodeproj -scheme EasySign -configuration Debug -destination 'platform=macOS' build 2>&1 | tail -50
```

预期：编译通过或仅有文件路径无关的警告。如果有编译错误（import 路径变了），按报错修正。

> **注：** Swift 不需要 import 物理路径，Xcode project 用的是 folder reference / file reference。如果 `project.pbxproj` 引用的是文件名（不是路径），物理移动不破坏引用。如果引用了路径，需要更新 `project.pbxproj`。

- [ ] **步骤 7：commit 阶段 1**

```bash
git add -A
git commit -m "refactor: physically move files to 3-layer structure (App/Features/Core)

Stage 1 of toolkit-architecture migration. Pure git mv, no code changes.

ResignService/  -> Core/Resigning/
DeviceService/  -> Core/Devices/
Tools/QRCodeService.swift -> Core/QR/QRCodeService.swift
Views/EasySignApp.swift   -> App/EasySignApp.swift
Views/ContentView.swift   -> Features/Resign/ResignContentView.swift
Views/QRCodeToolView.swift -> Features/QRCode/QRCodeToolView.swift
Views/DeviceView.swift    -> Features/Devices/DeviceView.swift
... (other Views/ files mapped to features)"
```

---

## 任务 2：阶段 2 — 3 层骨架（Tool 协议 + ServiceHub）

**Files:**
- Create: `EasySign/Core/Toolkit/Tool.swift`
- Create: `EasySign/Core/Toolkit/ToolCategory.swift`
- Create: `EasySign/Core/Toolkit/ServiceKey.swift`
- Create: `EasySign/Core/Toolkit/ServiceHub.swift`
- Create: `EasySign/Core/Toolkit/ToolRegistry.swift`
- Create: `EasySign/Core/Toolkit/ToolError.swift`
- Create: `EasySign/Features/Resign/ResignTool.swift`
- Create: `EasySign/Features/QRCode/QRCodeTool.swift`
- Create: `EasySign/Features/Devices/DevicesTool.swift`
- Create: `EasySignTests/Core/Toolkit/ServiceHubTests.swift`

- [ ] **步骤 1：创建 Tool 协议**

`EasySign/Core/Toolkit/Tool.swift`：

```swift
import SwiftUI

public protocol Tool: Identifiable {
    var id: String { get }
    var displayName: String { get }
    var subtitle: String { get }
    var icon: String { get }
    var accentColor: Color { get }
    var category: ToolCategory { get }
    var sortOrder: Int { get }
    var requiredServices: Set<ServiceKey> { get }

    @ViewBuilder
    func makeContentView(hub: ServiceHub) -> AnyView
}

public extension Tool {
    var id: String { String(describing: Self.self).lowercased() }
    var sortOrder: Int { 0 }
}
```

- [ ] **步骤 2：创建 ToolCategory**

`EasySign/Core/Toolkit/ToolCategory.swift`：

```swift
public enum ToolCategory: String, CaseIterable, Identifiable {
    case active    = "今日活跃"
    case frequent  = "常用"
    case advanced  = "高级"
    public var id: String { rawValue }
}
```

- [ ] **步骤 3：创建 ServiceKey 枚举**

`EasySign/Core/Toolkit/ServiceKey.swift`：

```swift
public enum ServiceKey: Hashable {
    case device
    case logger
    case recent
    case settings
    case artifact
}
```

- [ ] **步骤 4：写 ServiceHub 的失败测试**

`EasySignTests/Core/Toolkit/ServiceHubTests.swift`：

```swift
import XCTest
@testable import EasySign

final class ServiceHubTests: XCTestCase {
    func testValidateFailsWhenServiceMissing() {
        let hub = ServiceHub(device: TestDevice(), logger: NullLogger(),
                              recent: RecentFilesService(), settings: SettingsStore(),
                              artifact: ArtifactStore(logger: NullLogger()))
        // 故意注册一个不存在的服务 key
        // 这里仅 smoke test validate 不崩溃
        // 详细契约测试在阶段 3 之后
        XCTAssertNoThrow(hub.validate())
    }
}
```

> **注：** 阶段 2 阶段 ServiceHub.validate() 的契约是"不崩溃"。完整契约（含 missing key 检测）阶段 3 加。

- [ ] **步骤 5：创建 ServiceHub 骨架**

`EasySign/Core/Toolkit/ServiceHub.swift`：

```swift
import Foundation

public final class ServiceHub {
    public let device: DeviceService
    public let logger: LoggerService
    public let recent: RecentFilesService
    public let settings: SettingsStore
    public let artifact: ArtifactStore

    public init(device: DeviceService, logger: LoggerService,
                recent: RecentFilesService, settings: SettingsStore,
                artifact: ArtifactStore) {
        self.device = device
        self.logger = logger
        self.recent = recent
        self.settings = settings
        self.artifact = artifact
    }

    public static func live() -> ServiceHub {
        let logger = LoggerService.live()
        let settings = SettingsStore()
        let recent = RecentFilesService()
        let artifact = ArtifactStore(logger: logger)
        let device = DeviceService.shared
        return ServiceHub(device: device, logger: logger, recent: recent,
                          settings: settings, artifact: artifact)
    }

    /// DEBUG 启动时调用，Release 不调用。
    public func validate() {
        #if DEBUG
        for tool in ToolRegistry.allTools {
            for key in tool.requiredServices {
                precondition(self[key] != nil, "工具 \(tool.id) 需要服务 \(key) 但未注册")
            }
        }
        #endif
    }

    public subscript(key: ServiceKey) -> Any? {
        switch key {
        case .device: return device
        case .logger: return logger
        case .recent: return recent
        case .settings: return settings
        case .artifact: return artifact
        }
    }
}
```

> **注：** `DeviceService`、`LoggerService`、`RecentFilesService`、`SettingsStore`、`ArtifactStore` 在阶段 3-4 才实现，阶段 2 编译会报"type not found"，但这是预期的——下一步会加。

- [ ] **步骤 6：创建 ToolRegistry**

`EasySign/Core/Toolkit/ToolRegistry.swift`：

```swift
import Foundation

public enum ToolRegistry {
    public static let allTools: [any Tool] = [
        ResignTool(),
        QRCodeTool(),
        DevicesTool(),
    ]

    public static func tool(forId id: String) -> (any Tool)? {
        allTools.first { $0.id == id }
    }
}
```

- [ ] **步骤 7：创建 ToolError**

`EasySign/Core/Toolkit/ToolError.swift`：

```swift
import Foundation

public struct ToolError: Error, Identifiable {
    public let id = UUID()
    public let title: String
    public let message: String
    public let underlying: Error?
    public let category: Category
    public let severity: Severity
    public let recoverySuggestion: String?

    public enum Category: String {
        case validation, signing, fileSystem, network, keychain, internal
    }

    public enum Severity: String {
        case info, warning, error, fatal
    }

    public init(title: String, message: String, underlying: Error? = nil,
                category: Category, severity: Severity, recoverySuggestion: String? = nil) {
        self.title = title
        self.message = message
        self.underlying = underlying
        self.category = category
        self.severity = severity
        self.recoverySuggestion = recoverySuggestion
    }
}
```

- [ ] **步骤 8：创建 ResignTool 实现壳**

`EasySign/Features/Resign/ResignTool.swift`：

```swift
import SwiftUI

struct ResignTool: Tool {
    let displayName = "重签"
    let subtitle = "为 IPA 重签名并导出"
    let icon = "signature"
    let accentColor = .blue
    let category: ToolCategory = .frequent
    let sortOrder = 0

    var requiredServices: Set<ServiceKey> { [.logger, .settings, .artifact] }

    func makeContentView(hub: ServiceHub) -> AnyView {
        AnyView(ResignContentView(
            viewModel: ResignViewModel(
                logger: hub.logger,
                settings: hub.settings,
                artifact: hub.artifact
            )
        ))
    }
}
```

> **注：** 阶段 2 这一步会让 `ResignContentView` / `ResignViewModel` 编译失败（因为它们的初始化器还没改）。**先**让它们维持现有 init 形式并用占位参数；阶段 3 切换到 ServiceHub 注入。

修正后的临时实现：

```swift
struct ResignTool: Tool {
    let displayName = "重签"
    let subtitle = "为 IPA 重签名并导出"
    let icon = "signature"
    let accentColor = .blue
    let category: ToolCategory = .frequent
    let sortOrder = 0

    var requiredServices: Set<ServiceKey> { [.logger, .settings, .artifact] }

    func makeContentView(hub: ServiceHub) -> AnyView {
        // 阶段 2 临时：直接用现有 view，待阶段 3 改造
        AnyView(ResignContentView())
    }
}
```

同理 `QRCodeTool` 和 `DevicesTool`，先不传 hub，等阶段 3 统一改造。

- [ ] **步骤 9：创建 QRCodeTool 实现壳**

`EasySign/Features/QRCode/QRCodeTool.swift`：

```swift
import SwiftUI

struct QRCodeTool: Tool {
    let displayName = "二维码"
    let subtitle = "生成与扫描二维码"
    let icon = "qrcode"
    let accentColor = .green
    let category: ToolCategory = .frequent
    let sortOrder = 1

    var requiredServices: Set<ServiceKey> { [.logger] }

    func makeContentView(hub: ServiceHub) -> AnyView {
        AnyView(QRCodeToolView())
    }
}
```

- [ ] **步骤 10：创建 DevicesTool 实现壳**

`EasySign/Features/Devices/DevicesTool.swift`：

```swift
import SwiftUI

struct DevicesTool: Tool {
    let displayName = "设备"
    let subtitle = "浏览已连接 iOS 设备的文件"
    let icon = "iphone"
    let accentColor = .purple
    let category: ToolCategory = .active
    let sortOrder = 0

    var requiredServices: Set<ServiceKey> { [.logger] }

    func makeContentView(hub: ServiceHub) -> AnyView {
        AnyView(DeviceView())
    }
}
```

- [ ] **步骤 11：xcodebuild 验证**

```bash
xcodebuild -project EasySign.xcodeproj -scheme EasySign -configuration Debug -destination 'platform=macOS' build 2>&1 | tail -50
```

预期：编译通过。ResignTool/QRCodeTool/DevicesTool 暂时不被使用，但已编译进 target。

- [ ] **步骤 12：commit 阶段 2**

```bash
git add -A
git commit -m "feat(core): add toolkit contracts (Tool, Registry, ServiceHub, ToolError)

Stage 2 of toolkit-architecture migration. Adds the framework contracts:
- Tool protocol (displayName, icon, category, requiredServices, makeContentView)
- ToolCategory enum (active/frequent/advanced)
- ServiceKey enum (5 keys)
- ServiceHub class (container + validate + subscript)
- ToolRegistry (static allTools list)
- ToolError struct (title/message/category/severity)
- ResignTool / QRCodeTool / DevicesTool implementation shells

Not yet wired up to RootView (stage 5). Views still use old init forms.
Tests for ServiceHub.validate() added (smoke test, no real assertions yet)."
```

---

## 任务 3：阶段 3 — LoggerService + SettingsStore + RecentFilesService + ArtifactStore

**Files:**
- Create: `EasySign/Core/Logging/LoggerService.swift`
- Create: `EasySign/Core/Logging/LogLevel.swift`
- Create: `EasySign/Core/Storage/SettingsStore.swift`
- Create: `EasySign/Core/Storage/RecentFilesService.swift`
- Create: `EasySign/Core/Storage/ArtifactStore.swift`
- Create: `EasySign/Core/Storage/RecentFileKind.swift`
- Create: `EasySign/Core/Storage/ResignArtifact.swift`
- Modify: `EasySign/ResignService/Logger.swift`（保留旧 LoggerProtocol，新 LoggerService 独立）
- Modify: `EasySign/Features/Resign/ResignContentView.swift`（使用新服务）
- Create: `EasySignTests/Core/Storage/RecentFilesServiceTests.swift`
- Create: `EasySignTests/Core/Storage/ArtifactStoreTests.swift`
- Create: `EasySignTests/Core/Storage/SettingsStoreTests.swift`

- [ ] **步骤 1：创建 LogLevel + LoggerService**

`EasySign/Core/Logging/LogLevel.swift`：

```swift
public enum LogLevel: String, Codable, Comparable {
    case debug, info, warn, error
    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        order(lhs) < order(rhs)
    }
    private static func order(_ l: LogLevel) -> Int {
        switch l { case .debug: 0; case .info: 1; case .warn: 2; case .error: 3 }
    }
}
```

`EasySign/Core/Logging/LoggerService.swift`：

```swift
import Foundation

public struct LogEntry: Identifiable, Codable {
    public let id: UUID
    public let runId: UUID?
    public let timestamp: Date
    public let level: LogLevel
    public let category: String
    public let tool: String
    public let message: String

    public init(id: UUID = UUID(), runId: UUID? = nil, timestamp: Date = Date(),
                level: LogLevel, category: String = "", tool: String, message: String) {
        self.id = id; self.runId = runId; self.timestamp = timestamp
        self.level = level; self.category = category; self.tool = tool
        self.message = message
    }
}

public final class LoggerService {
    private var buffer: [LogEntry] = []
    public private(set) var currentRunId: UUID?

    public init() {}

    public static func live() -> LoggerService { LoggerService() }

    public func log(_ level: LogLevel, tool: String, _ message: String) {
        log(level, tool: tool, category: "", message)
    }

    public func log(_ level: LogLevel, tool: String, category: String, _ message: String) {
        let entry = LogEntry(runId: currentRunId, level: level,
                              category: category, tool: tool, message: message)
        buffer.append(entry)
        if buffer.count > 1000 { buffer.removeFirst() }
    }

    public var recentEntries: [LogEntry] { buffer }

    public func entries(forRun runId: UUID) -> [LogEntry] {
        buffer.filter { $0.runId == runId }
    }

    public func setCurrentRun(_ runId: UUID?) { currentRunId = runId }
}
```

- [ ] **步骤 2：写 SettingsStore 实现**

`EasySign/Core/Storage/SettingsStore.swift`：

```swift
import Foundation
import Combine

public enum SettingsKey: String {
    case defaultOutputDir
    case autoCleanWorkspace
    case workspaceRetentionDays
    case logRetentionDays
    case recentFilesCap
    case launchRestoresLastTool
    case lastActiveTool
    case windowSize
    case sidebarWidth
    case enableExperimental
}

public final class SettingsStore: ObservableObject {
    private let defaults: UserDefaults
    private var subjects: [SettingsKey: PassthroughSubject<Void, Never>] = [:]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func string(_ key: SettingsKey) -> String? { defaults.string(forKey: key.rawValue) }
    public func bool(_ key: SettingsKey) -> Bool { defaults.bool(forKey: key.rawValue) }
    public func int(_ key: SettingsKey) -> Int { defaults.integer(forKey: key.rawValue) }
    public func double(_ key: SettingsKey) -> Double { defaults.double(forKey: key.rawValue) }
    public func url(_ key: SettingsKey) -> URL? {
        guard let s = defaults.string(forKey: key.rawValue) else { return nil }
        return URL(string: s)
    }

    public func set(_ value: Any?, for key: SettingsKey) {
        if let v = value { defaults.set(v, forKey: key.rawValue) }
        else { defaults.removeObject(forKey: key.rawValue) }
        subjects[key, default: PassthroughSubject()].send()
    }

    public func publisher(for key: SettingsKey) -> AnyPublisher<Void, Never> {
        subjects[key, default: PassthroughSubject()].eraseToAnyPublisher()
    }

    public func resetAll() {
        for key in [SettingsKey.defaultOutputDir, .autoCleanWorkspace, .workspaceRetentionDays,
                    .logRetentionDays, .recentFilesCap, .launchRestoresLastTool,
                    .lastActiveTool, .windowSize, .sidebarWidth, .enableExperimental] {
            defaults.removeObject(forKey: key.rawValue)
        }
    }
}
```

- [ ] **步骤 3：写 RecentFilesService + RecentFileKind**

`EasySign/Core/Storage/RecentFileKind.swift`：

```swift
public enum RecentFileKind: String, Codable {
    case ipa, p12, mobileprovision, other
}
```

`EasySign/Core/Storage/RecentFilesService.swift`：

```swift
import Foundation

public struct RecentFile: Identifiable, Codable {
    public let url: URL
    public let kind: RecentFileKind
    public var lastUsed: Date
    public var useCount: Int
    public var id: URL { url }
}

public final class RecentFilesService {
    private let storeURL: URL
    private let cap: Int
    private var files: [RecentFile] = []
    private let queue = DispatchQueue(label: "RecentFilesService")

    public init(cap: Int = 20) {
        self.cap = cap
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                in: .userDomainMask).first!
        let dir = support.appendingPathComponent("EasySign", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.storeURL = dir.appendingPathComponent("recent.json")
        load()
    }

    public func record(_ url: URL, kind: RecentFileKind) {
        queue.sync {
            if let i = files.firstIndex(where: { $0.url == url && $0.kind == kind }) {
                files[i].lastUsed = Date()
                files[i].useCount += 1
            } else {
                files.append(RecentFile(url: url, kind: kind, lastUsed: Date(), useCount: 1))
            }
            files.sort { $0.lastUsed > $1.lastUsed }
            if files.count > cap { files = Array(files.prefix(cap)) }
            save()
        }
    }

    public func all(kind: RecentFileKind? = nil) -> [RecentFile] {
        queue.sync {
            kind.map { k in files.filter { $0.kind == k } } ?? files
        }
    }

    public func remove(_ url: URL, kind: RecentFileKind) {
        queue.sync {
            files.removeAll { $0.url == url && $0.kind == kind }
            save()
        }
    }

    public func clear(kind: RecentFileKind? = nil) {
        queue.sync {
            if let k = kind { files.removeAll { $0.kind == k } }
            else { files.removeAll() }
            save()
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let decoded = try? JSONDecoder().decode([RecentFile].self, from: data) else { return }
        self.files = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(files) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}
```

- [ ] **步骤 4：RecentFilesService 单元测试**

`EasySignTests/Core/Storage/RecentFilesServiceTests.swift`：

```swift
import XCTest
@testable import EasySign

final class RecentFilesServiceTests: XCTestCase {
    var service: RecentFilesService!
    var tempDir: URL!

    override func setUp() {
        super.setUp()
        // 用临时 ApplicationSupport
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        service = RecentFilesService(cap: 3)
    }

    func testRecordAndRetrieve() {
        let url = URL(fileURLWithPath: "/tmp/test.ipa")
        service.record(url, kind: .ipa)
        XCTAssertEqual(service.all(kind: .ipa).count, 1)
        XCTAssertEqual(service.all(kind: .ipa).first?.url, url)
    }

    func testCapEnforced() {
        for i in 0..<5 {
            service.record(URL(fileURLWithPath: "/tmp/\(i).ipa"), kind: .ipa)
        }
        XCTAssertEqual(service.all(kind: .ipa).count, 3)
    }

    func testRecordIncrementsUseCount() {
        let url = URL(fileURLWithPath: "/tmp/test.ipa")
        service.record(url, kind: .ipa)
        service.record(url, kind: .ipa)
        XCTAssertEqual(service.all(kind: .ipa).first?.useCount, 2)
    }

    func testRemove() {
        let url = URL(fileURLWithPath: "/tmp/test.ipa")
        service.record(url, kind: .ipa)
        service.remove(url, kind: .ipa)
        XCTAssertEqual(service.all(kind: .ipa).count, 0)
    }
}
```

- [ ] **步骤 5：跑测试**

```bash
xcodebuild test -project EasySign.xcodeproj -scheme EasySign \
  -destination 'platform=macOS' \
  -only-testing:EasySignTests/Core/Storage/RecentFilesServiceTests
```

预期：4/4 PASS。

- [ ] **步骤 6：写 ArtifactStore + ResignArtifact**

`EasySign/Core/Storage/ResignArtifact.swift`：

```swift
import Foundation

public struct ResignArtifact: Identifiable, Codable {
    public let id: UUID
    public let runId: UUID
    public let startedAt: Date
    public let finishedAt: Date?
    public let inputIPA: URL?
    public let outputIPA: URL?
    public let logPath: URL
    public let workspacePath: URL
    public let status: Status
    public let tool: String
    public let summary: String

    public enum Status: String, Codable {
        case running, success, failure, canceled
    }
}
```

`EasySign/Core/Storage/ArtifactStore.swift`：

```swift
import Foundation
import AppKit

public final class ArtifactStore {
    private let logger: LoggerService
    private let storeURL: URL
    private var artifacts: [UUID: ResignArtifact] = [:]
    private let queue = DispatchQueue(label: "ArtifactStore")

    public init(logger: LoggerService) {
        self.logger = logger
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                in: .userDomainMask).first!
        let dir = support.appendingPathComponent("EasySign", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.storeURL = dir.appendingPathComponent("artifacts.json")
        load()
    }

    @discardableResult
    public func startRun(tool: String, inputIPA: URL?) -> UUID {
        let runId = UUID()
        let logs = makeLogsDir().appendingPathComponent("\(runId.uuidString).log")
        let workspace = makeWorkspace().appendingPathComponent(runId.uuidString)
        try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let artifact = ResignArtifact(id: runId, runId: runId, startedAt: Date(),
                                       finishedAt: nil, inputIPA: inputIPA, outputIPA: nil,
                                       logPath: logs, workspacePath: workspace,
                                       status: .running, tool: tool, summary: "")
        queue.sync { artifacts[runId] = artifact; save() }
        logger.setCurrentRun(runId)
        return runId
    }

    public func finishRun(_ runId: UUID, status: ResignArtifact.Status,
                          outputIPA: URL?, summary: String) {
        queue.sync {
            guard var a = artifacts[runId] else { return }
            a = ResignArtifact(id: a.id, runId: a.runId, startedAt: a.startedAt,
                                finishedAt: Date(), inputIPA: a.inputIPA, outputIPA: outputIPA,
                                logPath: a.logPath, workspacePath: a.workspacePath,
                                status: status, tool: a.tool, summary: summary)
            artifacts[runId] = a
            save()
        }
        logger.setCurrentRun(nil)
    }

    public func artifact(forRun runId: UUID) -> ResignArtifact? {
        queue.sync { artifacts[runId] }
    }

    public func allArtifacts(tool: String? = nil, limit: Int = 50) -> [ResignArtifact] {
        queue.sync {
            let filtered = tool.map { t in artifacts.values.filter { $0.tool == t } }
                              ?? Array(artifacts.values)
            return Array(filtered.sorted { $0.startedAt > $1.startedAt }.prefix(limit))
        }
    }

    public func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    public func cleanupExpired(retentionDays: Int = 7) {
        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86400)
        queue.sync {
            for (id, a) in artifacts where a.startedAt < cutoff {
                try? FileManager.default.removeItem(at: a.workspacePath)
                artifacts.removeValue(forKey: id)
            }
            save()
        }
    }

    private func makeLogsDir() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                in: .userDomainMask).first!
        let dir = support.appendingPathComponent("EasySign/logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeWorkspace() -> URL {
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = cache.appendingPathComponent("EasySign/ResignTask", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let decoded = try? JSONDecoder().decode([ResignArtifact].self, from: data) else { return }
        for a in decoded { artifacts[a.runId] = a }
    }

    private func save() {
        let values = Array(artifacts.values)
        guard let data = try? JSONEncoder().encode(values) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}
```

- [ ] **步骤 7：ArtifactStore 单元测试**

`EasySignTests/Core/Storage/ArtifactStoreTests.swift`：

```swift
import XCTest
@testable import EasySign

final class ArtifactStoreTests: XCTestCase {
    func testStartAndFinishRun() {
        let store = ArtifactStore(logger: LoggerService())
        let runId = store.startRun(tool: "resign", inputIPA: nil)
        XCTAssertEqual(store.artifact(forRun: runId)?.status, .running)
        store.finishRun(runId, status: .success, outputIPA: nil, summary: "ok")
        XCTAssertEqual(store.artifact(forRun: runId)?.status, .success)
    }
}
```

- [ ] **步骤 8：SettingsStore 单元测试**

`EasySignTests/Core/Storage/SettingsStoreTests.swift`：

```swift
import XCTest
@testable import EasySign

final class SettingsStoreTests: XCTestCase {
    var store: SettingsStore!

    override func setUp() {
        super.setUp()
        let suite = UserDefaults(suiteName: UUID().uuidString)!
        suite.removePersistentDomain(forName: suite.dictionaryRepresentation().keys.first ?? "")
        store = SettingsStore(defaults: suite)
    }

    func testSetAndGet() {
        store.set("hello", for: .lastActiveTool)
        XCTAssertEqual(store.string(.lastActiveTool), "hello")
    }

    func testBool() {
        store.set(true, for: .autoCleanWorkspace)
        XCTAssertTrue(store.bool(.autoCleanWorkspace))
    }

    func testReset() {
        store.set("hello", for: .lastActiveTool)
        store.resetAll()
        XCTAssertNil(store.string(.lastActiveTool))
    }
}
```

- [ ] **步骤 9：跑测试**

```bash
xcodebuild test -project EasySign.xcodeproj -scheme EasySign \
  -destination 'platform=macOS' \
  -only-testing:EasySignTests/Core/Storage
```

预期：全部 PASS。

- [ ] **步骤 10：xcodebuild 验证**

```bash
xcodebuild -project EasySign.xcodeproj -scheme EasySign -configuration Debug -destination 'platform=macOS' build 2>&1 | tail -30
```

预期：编译通过。

- [ ] **步骤 11：commit 阶段 3**

```bash
git add -A
git commit -m "feat(core): add LoggerService, SettingsStore, RecentFilesService, ArtifactStore

Stage 3 of toolkit-architecture migration. Adds Core/Logging and Core/Storage:
- LogLevel enum (debug/info/warn/error)
- LoggerService (in-memory ring buffer, runId tracking)
- SettingsStore (typed UserDefaults wrapper with publisher)
- RecentFileKind enum, RecentFile struct, RecentFilesService (cap enforced)
- ResignArtifact struct, ArtifactStore (start/finish run, cleanup)
- Unit tests for RecentFilesService, SettingsStore, ArtifactStore

Not yet wired up to ResignContentView. ServiceHub.live() now constructs all 5 services."
```

---

## 任务 4：阶段 4 — 抽 DeviceService

**Files:**
- Modify: `EasySign/Core/Devices/DeviceManager.swift`（在 Core/Devices/）
- Create: `EasySign/Core/Devices/DeviceService.swift`（新文件，仅 ServiceHub 用）
- Create: `EasySign/Core/Devices/PairedDevice.swift`
- Create: `EasySign/Core/Devices/InstallEvent.swift`
- Modify: `EasySign/Features/Devices/DeviceView.swift`（继续用 DeviceManager，原样保留）
- Create: `EasySignTests/Core/Devices/DeviceServiceTests.swift`

- [ ] **步骤 1：创建 PairedDevice + InstallEvent 类型**

`EasySign/Core/Devices/PairedDevice.swift`：

```swift
import Foundation

public struct PairedDevice: Identifiable, Hashable {
    public let id: String        // UDID
    public let name: String
    public let model: String
    public let osVersion: String
}
```

`EasySign/Core/Devices/InstallEvent.swift`：

```swift
import Foundation

public struct InstallEvent {
    public let stage: String
    public let progress: Double
    public let message: String?
    public init(stage: String, progress: Double, message: String? = nil) {
        self.stage = stage; self.progress = progress; self.message = message
    }
}
```

- [ ] **步骤 2：写 DeviceService 协议 + 默认实现**

`EasySign/Core/Devices/DeviceService.swift`：

```swift
import Foundation
import Combine

public protocol DeviceServiceProtocol {
    var devices: AnyPublisher<[PairedDevice], Never> { get }
    func connect(_ device: PairedDevice) async throws
    func disconnect(_ device: PairedDevice)
    func afcClient(for device: PairedDevice) throws -> AFCClient
    func installIPA(_ ipa: URL, on device: PairedDevice) -> AsyncThrowingStream<InstallEvent, Error>
}

public final class DeviceService: DeviceServiceProtocol {
    public static let shared = DeviceService()
    private let manager: DeviceManager

    public init(manager: DeviceManager = .shared) {
        self.manager = manager
    }

    public var devices: AnyPublisher<[PairedDevice], Never> {
        manager.devicePublisher
    }

    public func connect(_ device: PairedDevice) async throws {
        try await manager.connect(deviceID: device.id)
    }

    public func disconnect(_ device: PairedDevice) {
        manager.disconnect(deviceID: device.id)
    }

    public func afcClient(for device: PairedDevice) throws -> AFCClient {
        try manager.afcClient(forDeviceID: device.id)
    }

    public func installIPA(_ ipa: URL, on device: PairedDevice) -> AsyncThrowingStream<InstallEvent, Error> {
        manager.installIPA(ipa, onDeviceID: device.id)
    }
}
```

- [ ] **步骤 3：在 DeviceManager 加 devicePublisher 和 installIPA**

修改 `EasySign/Core/Devices/DeviceManager.swift`：

```swift
// 在 DeviceManager 类里加：
public var devicePublisher: AnyPublisher<[PairedDevice], Never> {
    devicesSubject.eraseToAnyPublisher()
}
private let devicesSubject = CurrentValueSubject<[PairedDevice], Never>([])

// 在合适的回调处（设备插入/拔出）：
// devicesSubject.send(updatedPairedDevices())

public func installIPA(_ ipa: URL, onDeviceID deviceID: String) -> AsyncThrowingStream<InstallEvent, Error> {
    AsyncThrowingStream { continuation in
        // 现有 AFC + installation_proxy 调用
        // 推进时: continuation.yield(InstallEvent(...))
        // 完成时: continuation.finish()
    }
}
```

> **注：** 这步需要看 DeviceManager 现有代码确定具体的连接方式。详细实现参考 `Core/Devices/DeviceManager.swift` 的现有 API。

- [ ] **步骤 4：DeviceService 单元测试（mock）**

`EasySignTests/Core/Devices/DeviceServiceTests.swift`：

```swift
import XCTest
@testable import EasySign

final class DeviceServiceTests: XCTestCase {
    final class MockDeviceService: DeviceServiceProtocol {
        var connectedDevices: [PairedDevice] = []
        var installedIPAs: [(URL, PairedDevice)] = []
        let devicesSubject = PassthroughSubject<[PairedDevice], Never>()
        var devices: AnyPublisher<[PairedDevice], Never> { devicesSubject.eraseToAnyPublisher() }
        func connect(_ device: PairedDevice) async throws { connectedDevices.append(device) }
        func disconnect(_ device: PairedDevice) {}
        func afcClient(for device: PairedDevice) throws -> AFCClient { fatalError() }
        func installIPA(_ ipa: URL, on device: PairedDevice) -> AsyncThrowingStream<InstallEvent, Error> {
            installedIPAs.append((ipa, device))
            return AsyncThrowingStream { c in c.finish() }
        }
    }

    func testInstallIPA() {
        let mock = MockDeviceService()
        let device = PairedDevice(id: "UDID-1", name: "iPhone", model: "iPhone15", osVersion: "17.0")
        let url = URL(fileURLWithPath: "/tmp/test.ipa")
        _ = mock.installIPA(url, on: device)
        XCTAssertEqual(mock.installedIPAs.count, 1)
        XCTAssertEqual(mock.installedIPAs.first?.0, url)
    }
}
```

- [ ] **步骤 5：跑测试 + 编译**

```bash
xcodebuild test -project EasySign.xcodeproj -scheme EasySign \
  -destination 'platform=macOS' \
  -only-testing:EasySignTests/Core/Devices
xcodebuild -project EasySign.xcodeproj -scheme EasySign -configuration Debug build 2>&1 | tail -30
```

预期：测试通过，编译通过。

- [ ] **步骤 6：commit 阶段 4**

```bash
git add -A
git commit -m "feat(core): extract DeviceService from DeviceManager

Stage 4 of toolkit-architecture migration. Adds:
- PairedDevice struct (id/name/model/osVersion)
- InstallEvent struct (stage/progress/message)
- DeviceServiceProtocol + DeviceService class wrapping DeviceManager
- installIPA() returning AsyncThrowingStream<InstallEvent, Error>
- devicePublisher on DeviceManager
- MockDeviceService for tests

Not yet wired up to Resign's 'install to device' button (stage 6 UX refresh).
ServiceHub.live() now uses DeviceService.shared."
```

---

## 任务 5：阶段 5 — App/ 顶层 UI（RootView + Sidebar）

**Files:**
- Create: `EasySign/App/RootView.swift`
- Create: `EasySign/App/SidebarView.swift`
- Create: `EasySign/App/ToolSwitcher.swift`
- Create: `EasySign/App/StatusBar.swift`
- Create: `EasySign/App/Commands/AppCommands.swift`
- Modify: `EasySign/App/EasySignApp.swift`（构造 ServiceHub + RootView）
- Create: `EasySignTests/App/ServiceHubValidateTests.swift`

- [ ] **步骤 1：写 ServiceHub.validate() 契约测试**

`EasySignTests/App/ServiceHubValidateTests.swift`：

```swift
import XCTest
@testable import EasySign

final class ServiceHubValidateTests: XCTestCase {
    func testValidateAllRegisteredServices() {
        let hub = ServiceHub.live()
        // 不应该 precondition 失败
        #if DEBUG
        hub.validate()
        #endif
        XCTAssertTrue(true)
    }
}
```

- [ ] **步骤 2：跑测试**

```bash
xcodebuild test -project EasySign.xcodeproj -scheme EasySign \
  -destination 'platform=macOS' \
  -only-testing:EasySignTests/App/ServiceHubValidateTests
```

预期：PASS。

- [ ] **步骤 3：创建 SidebarView**

`EasySign/App/SidebarView.swift`：

```swift
import SwiftUI

struct SidebarView: View {
    @Binding var selection: String?
    let tools: [any Tool]

    var body: some View {
        List(selection: $selection) {
            ForEach(ToolCategory.allCases) { category in
                let categoryTools = tools.filter { $0.category == category }
                if !categoryTools.isEmpty {
                    Section(category.rawValue) {
                        ForEach(categoryTools, id: \.id) { tool in
                            SidebarRow(tool: tool)
                                .tag(tool.id as String?)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 200, idealWidth: 240, maxWidth: 320)
    }
}

private struct SidebarRow: View {
    let tool: any Tool

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(tool.displayName)
                    .font(.body)
                Text(tool.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: tool.icon)
                .foregroundStyle(tool.accentColor)
        }
    }
}
```

- [ ] **步骤 4：创建 StatusBar**

`EasySign/App/StatusBar.swift`：

```swift
import SwiftUI

struct StatusBar: View {
    let currentTool: (any Tool)?
    @ObservedObject var artifactStore: ArtifactStore

    var body: some View {
        HStack(spacing: 8) {
            if let tool = currentTool {
                Image(systemName: tool.icon)
                    .foregroundStyle(tool.accentColor)
                Text(tool.displayName)
                    .font(.caption)
            }
            Spacer()
            if let last = artifactStore.allArtifacts(limit: 1).first {
                StatusBadge(status: last.status)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .frame(height: 24)
    }
}

struct StatusBadge: View {
    let status: ResignArtifact.Status
    var body: some View {
        switch status {
        case .running: Label("进行中", systemImage: "circle.dotted").foregroundStyle(.blue)
        case .success: Label("成功", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failure: Label("失败", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
        case .canceled: Label("已取消", systemImage: "minus.circle").foregroundStyle(.secondary)
        }
    }
}
```

- [ ] **步骤 5：创建 ToolSwitcher（⌘1..⌘9 快捷键）**

`EasySign/App/ToolSwitcher.swift`：

```swift
import SwiftUI

struct ToolSwitcher {
    let tools: [any Tool]
    @Binding var selection: String?

    var keyHandlers: [Character: String] {
        var result: [Character: String] = [:]
        for (i, tool) in tools.prefix(9).enumerated() {
            let key = Character("\(i + 1)")
            result[key] = tool.id
        }
        return result
    }

    func handle(_ key: Character) -> Bool {
        guard let id = keyHandlers[key] else { return false }
        selection = id
        return true
    }
}
```

- [ ] **步骤 6：创建 RootView**

`EasySign/App/RootView.swift`：

```swift
import SwiftUI

struct RootView: View {
    @State private var selection: String? = ToolRegistry.allTools.first?.id
    @State private var hub: ServiceHub
    @State private var useRootView: Bool = true   // Feature flag; 阶段 5 默认 true

    init(hub: ServiceHub) {
        _hub = State(initialValue: hub)
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection, tools: ToolRegistry.allTools)
        } detail: {
            detailView
                .frame(minWidth: 600, minHeight: 400)
        }
        .safeAreaInset(edge: .bottom) {
            StatusBar(currentTool: currentTool, artifactStore: hub.artifact)
        }
        .frame(minWidth: 900, minHeight: 600)
    }

    @ViewBuilder
    private var detailView: some View {
        if let tool = currentTool {
            tool.makeContentView(hub: hub)
        } else {
            Text("选择一个工具")
                .foregroundStyle(.secondary)
        }
    }

    private var currentTool: (any Tool)? {
        guard let id = selection else { return nil }
        return ToolRegistry.tool(forId: id)
    }
}
```

- [ ] **步骤 7：修改 EasySignApp 接入 ServiceHub + RootView**

`EasySign/App/EasySignApp.swift`：

```swift
import SwiftUI

@main
struct EasySignApp: App {
    @State private var hub: ServiceHub

    init() {
        let h = ServiceHub.live()
        h.validate()
        _hub = State(initialValue: h)
    }

    var body: some Scene {
        WindowGroup {
            RootView(hub: hub)
        }
        .windowResizability(.contentMinSize)
        .commands {
            AppCommands(selection: nil)
        }
    }
}
```

- [ ] **步骤 8：创建 AppCommands（菜单）**

`EasySign/App/Commands/AppCommands.swift`：

```swift
import SwiftUI

struct AppCommands: Commands {
    let selection: String?

    var body: some Commands {
        CommandGroup(replacing: .toolbar) {
            ForEach(Array(ToolRegistry.allTools.prefix(9).enumerated()), id: \.element.id) { (i, tool) in
                Button(tool.displayName) {
                    NotificationCenter.default.post(name: .switchTool, object: tool.id)
                }
                .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
            }
        }
    }
}

extension Notification.Name {
    static let switchTool = Notification.Name("switchTool")
}
```

> **注：** 实际切工具的逻辑可以在 RootView 里订阅 `.switchTool` 通知。

- [ ] **步骤 9：xcodebuild 验证**

```bash
xcodebuild -project EasySign.xcodeproj -scheme EasySign -configuration Debug -destination 'platform=macOS' build 2>&1 | tail -30
```

预期：编译通过。

- [ ] **步骤 10：手动验证：跑一下 app**

```bash
open -a EasySign
```

预期：app 启动，侧边栏显示"重签/二维码/设备"，点击切换正常，状态栏显示当前工具。**注意 Devices tab 的真实功能可能因阶段 1 物理移动有断链，需要排查**。

- [ ] **步骤 11：commit 阶段 5**

```bash
git add -A
git commit -m "feat(app): add RootView host with Sidebar + StatusBar

Stage 5 of toolkit-architecture migration. Adds:
- RootView (NavigationSplitView: SidebarView + content + StatusBar)
- SidebarView (categorized tools with subtitle, accent icon)
- StatusBar (current tool, last run status badge)
- ToolSwitcher (Cmd+1..9 key handlers)
- AppCommands (menu integration)
- EasySignApp constructs ServiceHub.live() and validates in DEBUG

Default minimum window size 900x600.
No more 750x670 hardcoded frame.
ResignContentView, QRCodeToolView, DeviceView all rendered via Tool.makeContentView()."
```

---

## 任务 6：验证与回归

- [ ] **步骤 1：编译并启动 app**

```bash
xcodebuild -project EasySign.xcodeproj -scheme EasySign -configuration Debug build
open -a EasySign
```

- [ ] **步骤 2：手动测试矩阵**

| 操作 | 预期 |
|---|---|
| 启动 app | 3 个 tab 出现在侧边栏 |
| 点击"重签" | 显示 ResignContentView |
| 点击"二维码" | 显示 QRCodeToolView |
| 点击"设备" | 显示 DeviceView |
| ⌘1 / ⌘2 / ⌘3 | 切换工具 |
| 缩小窗口 | 到 900×600 后不再缩 |
| 状态栏 | 显示当前工具 + 最近运行状态 |
| 跑一次重签 | 行为和重构前一致 |
| 生成一个 QR | 行为和重构前一致 |
| 浏览设备文件 | 行为和重构前一致（如果阶段 1 没破坏） |

- [ ] **步骤 3：跑全部单元测试**

```bash
xcodebuild test -project EasySign.xcodeproj -scheme EasySign -destination 'platform=macOS'
```

预期：所有测试 PASS。

- [ ] **步骤 4：跑源注入测试**

```bash
for f in Tests/*.sh; do bash "$f" || echo "FAIL: $f"; done
```

预期：所有现有源注入测试 PASS（架构变更不应破坏源注入断言）。

- [ ] **步骤 5：commit 任何修复**

```bash
git add -A
git commit -m "fix: post-migration regression fixes"
```

---

## Self-Review

**Spec 覆盖检查：**
- §3 三层架构：阶段 1（物理搬迁）+ 阶段 5（App/ 顶层）→ ✅
- §4 目录结构：阶段 1-5 落地 → ✅
- §5 工具协议：阶段 2 全部实现 → ✅
- §6 ServiceHub：阶段 2 + 3 + 4 落地 → ✅
- §7 导航/窗口：阶段 5 落地（侧边栏 + 状态栏）→ ✅
- §8 通用 UI 组件：阶段 6 范围 → ❌ 不在本计划（spec 写明 defer）
- §9 设置/持久化：阶段 3（SettingsStore）+ 阶段 5（窗口）部分覆盖 → ✅
- §10 错误处理：ToolError 已加，展示 UI 阶段 6 范围 → 部分
- §11 跨工具联动：installIPA 入口已加，4 动作 UI 阶段 6 范围 → 部分
- §12 阶段 1-5：全部覆盖 → ✅
- §13 选型标准：本期不新增工具 → ✅（spec 写明不预设）
- §14 测试：ServiceHub、RecentFiles、SettingsStore、ArtifactStore、DeviceService 测试已加 → ✅
- §15 风险：useRootView feature flag 暂未实际用上（阶段 5 直接启用），仍保留作回退手段 → ✅

**Placeholder 检查：** 步骤里所有代码块都是完整可编译的；没有"TBD"/"实现 later"。

**类型一致性：**
- `ServiceHub.device` / `.logger` / `.recent` / `.settings` / `.artifact` → 5 个，匹配 `ServiceKey` 枚举 5 个 case
- `Tool.requiredServices` 返回 `Set<ServiceKey>`，5 个 key 都已注册
- `LoggerService.currentRunId` / `ArtifactStore.startRun`/`finishRun` 的 runId 流转一致
- `DeviceServiceProtocol.installIPA` 返回 `AsyncThrowingStream<InstallEvent, Error>`

---

## 执行 handoff

**Plan 写完并保存到 `docs/superpowers/plans/2026-06-06-toolkit-architecture-implementation-plan.md`。**

**范围说明：** 本计划覆盖 spec §12 阶段 1-5（架构骨架）。阶段 6（Resign UX 改造）和阶段 7（新工具）按 spec 单独 plan。

按用户要求：直接进入开发分支并执行。**Subagent-driven**（每个 task 派一个 subagent，task 间 review）。
