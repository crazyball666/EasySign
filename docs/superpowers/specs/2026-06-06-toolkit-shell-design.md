# EasySign 工具集架构设计

## 1. 背景与目标

### 1.1 现状

EasySign 起初是"iOS IPA 重签"垂直工具，重签功能做扎实之后，又陆续加入了二维码生成/扫描、设备管理两个相对独立的 tab，外加 Finder QuickLook 扩展。三个 tab 的代码各自为政：

- **重签 tab** 写在 `ContentView.swift` 主体里（750×670 固定窗口），表单 + 同步 11 步流水线
- **二维码 tab** 是一个小 SwiftUI view，AirDrop/Share 接好但和重签完全没关联
- **设备 tab** 是 1.5k LoC 的独立子系统（MobileDevice.framework / AFC / House Arrest / FileBrowser），有自己的拖拽、进度、冲突解决，但也没有和重签打通

这 4 块是 4 个半成品的独立产品，缺的是把它们串成"iOS 开发者日常工作流"的产品骨架。

### 1.2 目标

把 EasySign 从"重签工具"重新定位为 **iOS/macOS 开发者日常工作工具集**：

- 重签只是第一个工具，未来所有工具按统一规范挂到 App 宿主下
- 各工具独立可用，但又通过共享服务、跨工具联动形成工作流
- 工具集本身是个人本地开发工具：Developer ID / ad-hoc 分发，**不沙箱化**（保持现状），不要求多用户/多设备/团队协作
- 具体后续工具**待日常使用时根据痛点提炼**（见 §13 选型标准），不在本 spec 预设

### 1.3 非目标

- 不做多用户/多设备同步
- 不做 App Store 上架（沙箱化、a11y 严格、本地化完整这些都不在范围内）
- 不做运行时插件机制（5-8 个工具下属于过度设计）
- 不重写 ResignService（核心业务逻辑保留）
- 不动 QuickLook 扩展
- 不动 Vendor/

## 2. 明确决策

| 维度 | 决策 |
|---|---|
| 工具规模 | 5-8 个 |
| 架构风格 | 方案 A：轻量协议 + 静态注册 + 共享服务 |
| 导航/窗口 | 侧边栏 + 可调整窗口（最小 900×600） |
| 服务共享 | 通过 ServiceHub 注入到工具 |
| 现有工具迁移 | 重构 App 顶层 + 抽出 Core 底层；现有 View 最小改动 |
| 实现顺序 | 先架构再工具 |

参考：方案对比在脑暴过程中给出，方案 A 是最终选择。

## 3. 三层架构

整个代码库按依赖方向分为 3 层，**只能向下依赖**（App → Features → Core）。

```
┌─────────────────────────────────────────────────────────────────┐
│ Layer 0  App (顶层)                                              │
│   入口、Scene 生命周期、顶层 UI、ToolRegistry 路由、菜单           │
│   依赖：Features + Core                                          │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│ Layer 1  Features (中层：用户能感知的能力)                         │
│   每个 Feature = 一个 Tool + UI + ViewModel                      │
│   依赖：只能 Core                                                │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│ Layer 2  Core (底层：基础设施库)                                  │
│   跨 feature 复用的"能力"，按域分目录                              │
│   约束：不依赖 Features，不依赖 App                               │
│   约束：除 UI/ 子目录外不依赖 SwiftUI                             │
└─────────────────────────────────────────────────────────────────┘
```

## 4. 顶层目录结构

```
EasySign/
├── App/                                       # 顶层：入口 + 顶层 UI
│   ├── EasySignApp.swift                      # @main：构造 ServiceHub + RootView
│   ├── RootView.swift                         # 顶层布局（侧边栏 + 内容 + 状态栏）
│   ├── SidebarView.swift                      # 侧边栏（从 ToolRegistry 读）
│   ├── ToolSwitcher.swift                     # ⌘1..⌘9 快捷切换
│   ├── StatusBar.swift                        # 底部状态栏
│   └── Commands/                              # File / Edit / View / Help 菜单
│
├── Features/                                  # 中层：用户能感知的能力
│   ├── Resign/                                # 现有最小改动
│   │   ├── ResignTool.swift                   # Tool 实现
│   │   ├── ResignContentView.swift
│   │   ├── ResignViewModel.swift
│   │   ├── ResignSetting.swift
│   │   └── ...
│   ├── QRCode/
│   │   ├── QRCodeTool.swift
│   │   ├── QRCodeToolView.swift
│   │   └── ...
│   ├── Devices/
│   │   ├── DevicesTool.swift
│   │   ├── DeviceView.swift
│   │   ├── AppLister.swift                    # 实现细节
│   │   ├── AFCClient.swift                    # 实现细节
│   │   └── ...
│   └── ...                                    # 后续新工具
│
├── Core/                                      # 底层：基础设施库（被 App + Features 共用）
│   ├── Toolkit/                               # 框架契约（不依赖任何具体业务）
│   │   ├── Tool.swift                         # 工具协议
│   │   ├── ToolRegistry.swift                 # 静态注册表
│   │   ├── ToolCategory.swift
│   │   ├── ServiceHub.swift                   # 服务容器 + 启动校验
│   │   ├── ServiceKey.swift
│   │   └── ToolError.swift
│   ├── UI/                                    # 共享 SwiftUI 组件
│   │   ├── SectionView.swift
│   │   ├── FormRow.swift
│   │   ├── FilePickerField.swift
│   │   ├── LogPanelView.swift
│   │   ├── DropdownPickerRow.swift
│   │   ├── StatusBadge.swift
│   │   ├── ActionButton.swift
│   │   ├── KeyValueRow.swift
│   │   └── ProgressTimeline.swift
│   ├── Logging/                               # 结构化日志
│   │   └── LoggerService.swift
│   ├── Storage/                               # 持久化与状态
│   │   ├── SettingsStore.swift                # @AppStorage 封装
│   │   ├── RecentFilesService.swift
│   │   └── ArtifactStore.swift
│   ├── Devices/                               # 设备管理（原 DeviceService/）
│   │   ├── DeviceService.swift                # 仅保留连接 + 设备列表 + AFC 引用
│   │   ├── AFCClient.swift
│   │   ├── HouseArrestClient.swift
│   │   ├── AppLister.swift                    # 这里定义，Features/Devices/ 引用
│   │   └── ...
│   ├── Resigning/                             # 签名引擎（原 ResignService/）
│   │   ├── ResignTask.swift
│   │   ├── IPA.swift
│   │   ├── AppBundle.swift
│   │   ├── BaseBundle.swift
│   │   ├── AppexBundle.swift
│   │   ├── PKCS12.swift
│   │   ├── MobileProvision.swift
│   │   ├── SecCertificate.swift
│   │   ├── ResignTaskInfo.swift
│   │   ├── PathManager.swift
│   │   └── ...
│   └── QR/                                    # 二维码生成（原 Tools/QRCodeService.swift）
│       └── QRCodeService.swift
│
├── EasySignQuickLook/                         # Finder QuickLook 扩展（保留）
├── Vendor/                                    # 第三方源码（保留）
└── Resources/                                 # 资源（保留）
```

### 模块依赖约束（强制）

- **App/** → 可以 `import` Features/ 和 Core/
- **Features/** → **只能** `import` Core/，不能 `import` App/，不能横向 `import` 其他 Feature
- **Core/** → 不依赖 App/，不依赖 Features/；除 `Core/UI/` 外不依赖 SwiftUI

> **物理层面的检查**：Xcode target / 文件夹结构上保证 Core/ 在最底。Core 的子目录之间也按域解耦——例如 `Core/Resigning/` 不应该反向引用 `Core/Logging/`，签名时通过参数注入 Logger 而不是引用全局。

## 5. 工具协议与注册表

### 5.1 Tool 协议

```swift
// Core/Toolkit/Tool.swift
import SwiftUI

public protocol Tool: Identifiable {
    var id: String { get }
    var displayName: String { get }
    var subtitle: String { get }
    var icon: String { get }
    var accentColor: Color { get }
    var category: ToolCategory { get }
    var sortOrder: Int { get }
    var keyboardShortcut: Character? { get }
    var requiredServices: Set<ServiceKey> { get }
    
    @ViewBuilder
    func makeContentView(hub: ServiceHub) -> AnyView
}

extension Tool {
    public var id: String { String(describing: Self.self).lowercased() }
    public var sortOrder: Int { 0 }
    public var keyboardShortcut: Character? { nil }
}
```

### 5.2 ToolCategory 与动态分组

```swift
public enum ToolCategory: String, CaseIterable, Identifiable {
    case active    = "今日活跃"
    case frequent  = "常用"
    case advanced  = "高级"
}
```

**分组策略：**
- `active`：24 小时内使用过且累计次数 ≥ 3
- `frequent`：累计使用次数 ≥ 5
- `advanced`：其他

数据来源：`ArtifactStore` 的运行记录。`SidebarView` 渲染时按此动态计算每个工具所属分组。

### 5.3 静态注册表

```swift
// Core/Toolkit/ToolRegistry.swift
public enum ToolRegistry {
    public static let allTools: [any Tool] = [
        ResignTool(),
        QRCodeTool(),
        DevicesTool(),
        // CertificateLibraryTool(),   // 后续按需加入
        // CrashSymbolicatorTool(),   // 后续按需加入
    ]
    
    public static func tool(forId id: String) -> (any Tool)? {
        allTools.first { $0.id == id }
    }
}
```

### 5.4 工具实现示例

```swift
// Features/Resign/ResignTool.swift
struct ResignTool: Tool {
    let displayName = "重签"
    let subtitle = "为 IPA 重签名并导出"
    let icon = "signature"
    let accentColor = .blue
    let category: ToolCategory = .frequent
    let sortOrder = 0
    
    var requiredServices: Set<ServiceKey> {
        [.logger, .settings, .artifact]
    }
    
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

## 6. ServiceHub 与共享服务

### 6.1 ServiceHub

```swift
// Core/Toolkit/ServiceHub.swift
public final class ServiceHub {
    public let device: DeviceService
    public let logger: LoggerService
    public let recent: RecentFilesService
    public let settings: SettingsStore
    public let artifact: ArtifactStore
    
    public static func live() -> ServiceHub {
        let logger = LoggerService.live()
        let settings = SettingsStore()
        let recent = RecentFilesService()
        let artifact = ArtifactStore(logger: logger)
        let device = DeviceService.shared
        return ServiceHub(
            device: device,
            logger: logger, recent: recent, settings: settings, artifact: artifact
        )
    }
    
    /// 启动时校验：所有工具声明的服务是否都已注册。
    /// 在 DEBUG 启动时强制调用（见 §12 阶段 1 / §14.4 契约测试），
    /// Release 模式不调用以避免 release 崩溃。
    public func validate() {
        for tool in ToolRegistry.allTools {
            for key in tool.requiredServices {
                precondition(self[key] != nil, "工具 \(tool.id) 需要服务 \(key) 但未注册")
            }
        }
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

public enum ServiceKey: Hashable {
    case device, logger, recent, settings, artifact
}
```

### 6.2 DeviceService

```swift
// Core/Devices/DeviceService.swift
/// 抽自现有 DeviceService/DeviceManager.swift。
/// 保留：连接、设备列表、AFC 客户端引用。
/// 移除：HouseArrest、AppLister、FilePreview（这些是 Devices 工具的实现细节）。
public final class DeviceService {
    public static let shared = DeviceService()
    
    public var devices: AnyPublisher<[PairedDevice], Never>
    public func connect(_ device: PairedDevice) async throws
    public func disconnect(_ device: PairedDevice)
    public func afcClient(for device: PairedDevice) throws -> AFCClient
    public func installIPA(_ ipa: URL, on device: PairedDevice) -> AsyncThrowingStream<InstallEvent, Error>
}

public struct InstallEvent {
    public let stage: String
    public let progress: Double   // 0..1
    public let message: String?
}
```

### 6.5 LoggerService

```swift
// Core/Logging/LoggerService.swift
public struct LogEntry: Identifiable, Codable {
    public let id: UUID
    public let runId: UUID          // 一次"运行"（如一次重签）一个 runId
    public let timestamp: Date
    public let level: LogLevel
    public let category: String
    public let tool: String
    public let message: String
}

public enum LogLevel: String, Codable, Comparable {
    case debug, info, warn, error
}

public final class LoggerService {
    public static func live() -> LoggerService { ... }
    
    /// 当前激活的 runId（新一次"运行"开始时设置）
    public var currentRunId: UUID?
    
    public func log(_ level: LogLevel, tool: String, _ message: String)
    public func log(_ level: LogLevel, tool: String, category: String, _ message: String)
    
    /// 订阅实时日志（LogPanelView 用）
    public func subscribe(tool: String? = nil, minLevel: LogLevel = .info) -> AsyncStream<LogEntry>
    
    /// 查询某次 run 的全部日志
    public func entries(forRun runId: UUID) -> [LogEntry]
    
    /// 内存 ring buffer（最近 1000 条）
    public var recentEntries: [LogEntry] { get }
}
```

持久化：`~/Library/Logs/EasySign/runs/<runId>.log`（JSON Lines 格式）。

### 6.6 RecentFilesService

```swift
// Core/Storage/RecentFilesService.swift
public enum RecentFileKind: String, Codable {
    case ipa, p12, mobileprovision
}

public struct RecentFile: Identifiable, Codable {
    public let url: URL
    public let kind: RecentFileKind
    public let lastUsed: Date
    public var useCount: Int
    public var id: URL { url }
}

public final class RecentFilesService {
    public func record(_ url: URL, kind: RecentFileKind)
    public func all(kind: RecentFileKind) -> [RecentFile]
    public func clear(kind: RecentFileKind? = nil)
    public func remove(_ url: URL, kind: RecentFileKind)
}
```

每种 kind 保留最近 20 个。存储：`~/Library/Application Support/EasySign/recent.json`。

### 6.7 SettingsStore

```swift
// Core/Storage/SettingsStore.swift
public enum SettingsKey: String {
    case defaultOutputDir          // URL
    case autoCleanWorkspace        // Bool, default true
    case workspaceRetentionDays    // Int, default 7
    case logRetentionDays          // Int, default 30
    case recentFilesCap            // Int, default 20
    case launchRestoresLastTool    // Bool, default true
    case lastActiveTool            // String (tool id)
    case windowSize                // String ("WxH")
    case sidebarWidth              // Double
    case enableExperimental        // Bool, default false
}

public final class SettingsStore: ObservableObject {
    public func string(_ key: SettingsKey) -> String?
    public func bool(_ key: SettingsKey) -> Bool
    public func int(_ key: SettingsKey) -> Int
    public func double(_ key: SettingsKey) -> Double
    public func url(_ key: SettingsKey) -> URL?
    public func set(_ value: Any?, for key: SettingsKey)
    
    /// Combine publisher 用于订阅变化
    public func publisher(for key: SettingsKey) -> AnyPublisher<Void, Never>
    
    /// 重置全部
    public func resetAll()
}
```

### 6.8 ArtifactStore

```swift
// Core/Storage/ArtifactStore.swift
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
    public let tool: String            // 哪个工具产生的（"resign" / "ipapreview" ...）
    public let summary: String         // 用户可读总结
    
    public enum Status: String, Codable {
        case running, success, failure, canceled
    }
}

public final class ArtifactStore {
    public init(logger: LoggerService) { ... }
    
    public func startRun(tool: String, inputIPA: URL?) -> UUID
    public func finishRun(_ runId: UUID, status: ArtifactStore.Status, outputIPA: URL?, summary: String)
    
    public func artifact(forRun runId: UUID) -> ResignArtifact?
    public func allArtifacts(tool: String? = nil, limit: Int = 50) -> [ResignArtifact]
    
    /// 根据 SettingsStore 的 retention 清理过期 workspace 和 log
    public func cleanupExpired() async
    
    /// 在 Finder 中显示
    public func revealInFinder(_ url: URL)
}
```

## 7. 导航与窗口

### 7.1 RootView 布局

```
┌────────────────────────────────────────────────────────────────────┐
│ ┌──────────┐  ┌────────────────────────────────────────────────┐  │
│ │ Sidebar  │  │  ContentView (currentTool.makeContentView)     │  │
│ │          │  │                                                  │  │
│ │ 今日活跃 │  │                                                  │  │
│ │  ● 重签  │  │                                                  │  │
│ │  ● 设备  │  │                                                  │  │
│ │          │  │                                                  │  │
│ │ 常用     │  │                                                  │  │
│ │  ● 二维码│  │                                                  │  │
│ │          │  │                                                  │  │
│ │ 高级     │  │                                                  │  │
│ │  ● ...  │  │                                                  │  │
│ │          │  │                                                  │  │
│ │ [设置]   │  │                                                  │  │
│ │ [关于]   │  │                                                  │  │
│ └──────────┘  └────────────────────────────────────────────────┘  │
│ 80-200pt                       720pt+                              │
│  ── 状态栏：当前工具 · 设备 · 最近运行 ────────────────────────     │
└────────────────────────────────────────────────────────────────────┘
        最小 900×600；默认 1100×720；侧边栏 80-200pt 可拖
```

### 7.2 ToolSwitcher

- ⌘1..⌘9 切换 `ToolRegistry.allTools` 排序后的对应项
- ⌘⇧[ / ⌘⇧] 在工具间循环
- ⌘0 切换到"上次使用"
- 切换时记入 `ArtifactStore` / `SettingsStore.lastActiveTool`

### 7.3 StatusBar

- 高 24pt
- 显示：当前工具名 / 连接中的设备数 / 最近一次运行的状态徽章（成功/失败/进行中）
- 点击状态徽章 → 打开对应 run 的 log

## 8. 通用 UI 组件

继承现有的 `ResignSectionView / FormRow / DropdownPickerRow / StatusBadge / KeyValueRow`，新增：

### 8.1 FilePickerField

```swift
public struct FilePickerField: View {
    let title: String
    @Binding var path: String
    let kind: RecentFileKind
    let allowedContentTypes: [UTType]?
    let validator: ((URL) -> String?)?    // 返回 nil 表示 OK，返回 String 表示错误信息
    let serviceHub: ServiceHub
    
    // 特性：
    // - 拖拽（onDrop）
    // - 弹出 NSOpenPanel（带 allowedContentTypes）
    // - 显示当前文件名 + 清除按钮
    // - 错误状态：边框红色 + 错误文字
    // - "最近使用"下拉（来自 RecentFilesService）
    // - 选中后调 RecentFilesService.record
}
```

### 8.2 LogPanelView 升级

```swift
public struct LogPanelView: View {
    @ObservedObject var logger: LoggerService
    let toolId: String
    @State private var minLevel: LogLevel = .info
    @State private var filter: String = ""
    @State private var selectedRunId: UUID?    // 切换查看不同 run 的日志
    
    // 升级点：
    // - 级别彩色：debug=灰 / info=白 / warn=黄 / error=红
    // - 过滤栏：级别下拉 + 文本搜索
    // - 顶部工具条：复制全文 / 保存到文件 / 切换 run
    // - 失败后保留（不每次 Start 清空）
}
```

### 8.3 DropdownPickerRow 升级

新增 `description: String?` 字段：选中项右侧显示工具提示风格的描述文字。例如：

```
导出类型:  [app-store            ▼]
           ↑ "App Store 正式发布"
```

### 8.4 ProgressTimeline

```swift
public struct ProgressTimeline: View {
    let stages: [Stage]              // 11 步重签流水线
    let currentStage: Int
    
    public struct Stage: Identifiable {
        let id: String
        let label: String
        let state: State              // pending / running / done / failed
    }
}
```

横向 11 段进度条，当前段填充高亮，失败段红色。

### 8.5 ActionButton

```swift
public struct ActionButton: View {
    enum Style { case primary, secondary, destructive, ghost }
    let title: String
    let icon: String?
    let style: Style
    let action: () -> Void
    let isEnabled: Bool
}
```

## 9. 设置与持久化

### 9.1 Settings Scene

`EasySignApp.swift` 增加：

```swift
Settings {
    SettingsView(hub: hub)
}
```

⌘, 自动调起。

### 9.2 SettingsView 分组

| 分组 | 项 | 类型 | 默认 |
|---|---|---|---|
| 常规 | 启动时恢复上次工具 | Bool | true |
| 常规 | 默认输出目录 | URL 选择 | Documents |
| 文件 | 最近文件保留数量 | Int 1-50 | 20 |
| 文件 | 自动清理 workspace | Bool | true |
| 文件 | workspace 保留天数 | Int 1-30 | 7 |
| 文件 | log 保留天数 | Int 7-90 | 30 |
| 高级 | 启用实验性功能 | Bool | false |
| 高级 | 重置所有数据 | 危险按钮 | — |

## 10. 错误处理与日志

### 10.1 ToolError

```swift
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
}
```

### 10.2 错误展示三层

- **Toast**：右下角小弹窗，3 秒消失，承载 `.info` / `.warning`
- **Alert**：中间模态，承载 `.error`，可选项：取消 / 重试 / 打开 Log
- **错误页**：占满内容区，承载 `.fatal`，提供"重启 / 退出"按钮

### 10.3 关键错误自动写日志

`LoggerService.log(.error, ...)` 自动触发 alert；同时错误落到 `ArtifactStore` 的当前 run。

## 11. 跨工具联动

### 11.1 Resign 成功后的四个动作

```
┌─ 重签成功 ─────────────────────────────────┐
│ IPA 已导出到：                              │
│ /Users/.../MyApp-20260606-221530.ipa        │
│                                            │
│ [在 Finder 中显示] [复制路径] [分享]        │
│ [安装到设备] [生成安装二维码] [关闭]        │
└────────────────────────────────────────────┘
```

每个动作通过对应服务实现：
- Reveal → `NSWorkspace.activateFileViewerSelecting`
- 复制路径 → `NSPasteboard`
- 分享 → `NSSharingServicePicker`
- 装到设备 → `DeviceService.installIPA(...)`（要求先在 Devices tab 选了设备，否则提示）
- 生成 QR → `QRCodeToolView` 的 QR 生成函数（暴露为 ServiceHub.qr 的方法，或者 Resign 自己 import）

### 11.2 拖拽联动

- 拖 .ipa 到侧边栏的"重签" → 自动填入 input
- 拖 .ipa 到侧边栏的"设备" → 自动打开对应设备（如果选中）的 AppList
- 拖 .p12 到"重签" → 自动填入 p12 路径
- 拖 .mobileprovision 到"重签" → 自动填入 profile 路径

实现：每个 Tool 可选实现 `acceptDrop(urls: [URL]) -> Bool`，true 表示消费，SidebarView 根据当前 tool 决定。

### 11.3 URL Scheme

```
easysign://tool/resign
easysign://tool/devices
easysign://run/<runId>             # 打开历史 run 的 log
```

注册到 `Info.plist` 的 `CFBundleURLTypes`。`EasySignApp` 监听，路由到 `RootView`。

## 12. 现有工具迁移策略

7 阶段渐进，每阶段独立可回退：

> **实现计划拆分**：本设计对应的实现计划会按阶段拆为 7 份 plan（阶段 1 ~ 阶段 6 各自一份，阶段 7 是独立工具的 spec+plan）。本 spec 描述整体方向；具体 plan 在 `writing-plans` 阶段产出。

### 阶段 1：物理搬迁（git mv，不改代码）

把现有顶层文件夹按 3 层结构归位：

```
git mv ResignService/    Core/Resigning/
git mv DeviceService/    Core/Devices/
git mv Tools/QRCodeService.swift  Core/QR/QRCodeService.swift
git mv Views/EasySignApp.swift    App/EasySignApp.swift
git mv Views/ContentView.swift    Features/Resign/ResignContentView.swift
git mv Views/ResignContentView.swift  Features/Resign/ResignContentView.swift
git mv Views/QRCodeToolView.swift  Features/QRCode/QRCodeToolView.swift
git mv Views/DeviceView.swift      Features/Devices/DeviceView.swift
git mv Views/IPAContentView.swift  Features/Resign/IPAContentView.swift
git mv Views/IPAPreviewPanelView.swift  Features/Resign/IPAPreviewPanelView.swift
... 其他 Views/ 下的文件按所属工具搬入
```

- 创建 `App/` `Features/` `Core/` 空目录结构
- **不改任何 import 路径**——Swift module 物理位置不影响编译
- 验证：`xcodebuild` 通过
- 提交：多个小 commit（一个目录一次），便于 review

### 阶段 2：3 层骨架（Core/Toolkit/ 协议壳）

- 创建 `Core/Toolkit/Tool.swift`（协议）
- 创建 `Core/Toolkit/ToolRegistry.swift`（静态注册表）
- 创建 `Core/Toolkit/ServiceHub.swift`（services 占位）
- 创建 `Core/Toolkit/ServiceKey.swift`
- 创建 `Core/Toolkit/ToolError.swift`
- 创建 `Core/Toolkit/ToolCategory.swift`
- 添加 `ResignTool` / `QRCodeTool` / `DevicesTool` 实现壳（**不接入**到 RootView，只是协议落实）
- 验证：编译通过；新文件独立可测
- 提交：`feat(core): add toolkit contracts (Tool, Registry, ServiceHub)`

### 阶段 3：抽 Core/Logging 和 Core/Storage 基础服务

- 创建 `Core/Logging/LoggerService.swift`（基于现有 `LoggerProtocol`）
- 创建 `Core/Storage/SettingsStore.swift`（迁移 `UserDefaults` 9 个 key，键名保持一致）
- 创建 `Core/Storage/RecentFilesService.swift`
- 创建 `Core/Storage/ArtifactStore.swift`（暂时骨架）
- `ResignViewModel` 改用 `LoggerService` / `SettingsStore` / `RecentFilesService`（替换现有 9 个 `CacheKey` 写入和 `ContentViewModel.logString` 拼接）
- 验证：重签流程跑通，日志/设置行为不变
- 提交：`feat(core): extract logger, settings, recent files, artifact store`

### 阶段 4：抽 Core/Devices 业务服务

- 简化 `Core/Devices/DeviceService.swift`（从 `Core/Devices/DeviceManager.swift`，只保留连接 + 设备列表 + AFC 引用 + installIPA 入口）
- 验证：Devices tab 行为不变；Resign 的"一键装到设备"按钮可调用
- 提交：`feat(core): extract device service`

### 阶段 5：搭建 App/ 顶层 UI

- 创建 `App/RootView.swift`（侧边栏 + 内容区 + 状态栏）
- 创建 `App/SidebarView.swift`
- 创建 `App/ToolSwitcher.swift`（⌘1..⌘9）
- 创建 `App/StatusBar.swift`
- 创建 `App/Commands/`（File / Edit / View / Help 菜单）
- `EasySignApp` 构造 `ServiceHub.live()`，注入到 `RootView`
- Feature Flag `useRootView`，默认 `false`（保持原 `ContentView` 渲染）
- 切到 `true` 验证三个 tab 工作
- 验证：侧边栏显示三个工具；快捷键切换；窗口大小可调
- 提交：`feat(app): add RootView host with sidebar + statusbar`

### 阶段 6：抽 Core/UI 共享组件 + Resign 体验改造

- 把 `Views/` 里可复用的 `ResignSectionView / FormRow / DropdownPickerRow / StatusBadge / KeyValueRow` 抽到 `Core/UI/`
- 创建新组件：`Core/UI/FilePickerField.swift`（拖拽 + 校验 + 最近使用）
- 创建新组件：`Core/UI/LogPanelView.swift` 升级版（级别彩色 + 过滤 + 复制 + 切换 run）
- 创建新组件：`Core/UI/ProgressTimeline.swift`（11 段进度条）
- 创建新组件：`Core/UI/ActionButton.swift`（主/次/危险/幽灵）
- 用 `FilePickerField` 替换 Resign 的 `NSOpenPanel`
- 用 `LogPanelView` 替换日志面板
- 加 `ProgressTimeline` 显示 11 步进度
- 加取消按钮（暴露 Process 句柄）
- 成功 alert 加 4 动作（Reveal / Share / Install / QR）
- `ResignContentView` 改造为 `@Observable`（如果 macOS 14+）
- 验证：重签流程全跑通，体验与之前对比有提升
- 提交：`feat(resign): refresh UX with shared UI components`

### 阶段 7：新工具

- 根据运行时数据决定加哪些（见 §13）
- 每个新工具 = 新建 `Features/<Name>/` 目录 + 实现 `Tool` 协议
- 提交：每个新工具独立 commit

## 13. 后续新工具选型标准

**核心原则**：新工具必须满足下列所有条件，否则不收：

1. **真的痛**——你日常会高频遇到的具体场景
2. **系统/现有工具做得不够好**——Xcode/系统/通用 SaaS 解决不了或体验差
3. **能在这套 Shell 里复用服务**——拖拽、日志、文件选择、跨工具联动这些能给该工具加分
4. **不重复造轮子**——不做系统已经做得好的东西

**范围发散**：工具集**不限于 iOS/macOS 开发**。日常工作里只要是"应该有个更好工具"的场景都可以纳入。

**首批工具候选**：**待定**——靠日常使用时记录下来，按月汇总评估，而不是先列死。

### 选型流程

- 每次觉得"这事应该有工具"时，记到 `docs/superpowers/ideas.md`
- 每月底（或有空时）过一遍，按 §13 标准评估
- 通过评估的 → 写 spec → 写 plan → 实现
- 不通过的 → 标注拒绝原因

### 候选维度（仅作分类参考，不预设具体工具）

按"日常痛点"维度发散：

- 文件操作（批量改名、查重、格式转换、归档、压缩）
- 文本/数据处理（JSON/YAML/TOML/CSV 转换、查询、修复）
- 网络/接口（API 调试、Mock 抓包、状态码查询）
- 图像/媒体（批量压缩、格式转换、截图标注、录屏/动图）
- 剪贴板/输入增强（历史、转换、模板）
- 自动化（批量处理、定时任务、规则触发）
- 信息组织（笔记、片段、书签、备忘）
- 计算/查询（程序员计算器、UUID/Hash/Base64、字符编码）
- 系统/硬件（剪贴板历史、窗口管理、磁盘清理、进程/端口）
- 协作/分发（二维码、链接、文件快传）—— 二维码已经覆盖一部分

**注意**：这是分类参考，**不是工具清单**。具体工具从日常记录中提炼。

## 14. 测试策略

### 14.1 单元测试（XCTest）

- `ToolRegistry` 校验：所有 tool 都有唯一 id、displayName 不重复
- `ServiceHub.validate()`：所有 tool 的 requiredServices 都已注册
- `RecentFilesService`：增/删/上限
- `SettingsStore`：set / get / reset / publisher
- `ArtifactStore`：startRun / finishRun / cleanupExpired
- `DeviceService`：连接、installIPA 异步流

### 14.2 现有源注入测试

保留 `Tests/*.sh` 源注入测试，架构变更不破坏断言。

### 14.3 XCUITest

- 启动 → RootView 渲染正确
- ⌘1 切到第一个工具
- Resign 提交流程（仅 mock services）

### 14.4 契约测试

`ServiceHub.validate()` 在 DEBUG 启动时强制跑——这是天然的契约测试。新增 tool 但忘了注册 service 时，启动即崩。

## 15. 风险与回退

### 15.1 风险

| 风险 | 缓解 |
|---|---|
| `Core/Devices/DeviceService` 抽取破坏现有 Devices tab | 阶段 4 时**只抽骨架**，功能（HouseArrest/FileBrowser）保持原位 |
| `ContentViewModel` 改造时丢失 9 个 UserDefaults key 行为 | 阶段 3 用 `SettingsStore` 完整承接，key 字符串保持一致 |
| ServiceHub 变 god object | `ServiceKey` 显式枚举；超出 5 个就要重新拆分 |
| 现有 `Core/Resigning/` 反向依赖 `Core/UI` 或 `App` | 阶段 1 验证 `Core/Resigning/` 下没有 SwiftUI import；`Core/Resigning/` 不应引用任何 App/Features 代码 |
| 阶段 1 物理搬迁漏文件 | 用 `find Views/ -name '*.swift'` 列出全部，逐个 git mv，不留遗漏 |

### 15.2 回退

每阶段独立 commit；`useRootView` feature flag 允许一键回到旧版入口；迁移出错时不会阻塞后续阶段。

## 16. 开放问题

- [ ] ResignContentView 全面 `@Observable` 改造的优先级（macOS 14+ only?）
- [ ] SettingsView 的"重置所有数据"到底清哪些文件？
- [ ] `ArtifactStore.cleanupExpired` 的触发时机：启动时？定时器？手动？
- [ ] 工具排序是否允许用户拖拽自定义？
