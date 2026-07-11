# Signal Glass Workbench Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将 EasySign 完整重绘为 Signal Glass Workbench：深浅两套正式主题、可访问的动效、清晰的主画布 / context rail 工作台布局，同时保持重签、设备 AFC、互传、二维码、设置和更新的全部既有业务行为。

**Architecture:** 新建 `Core/UI` 视觉系统与纯布局决策层；`RootView` 仍使用 `NavigationSplitView`，只替换其视觉壳和呈现转场。`RootView` 不拥有工具运行状态或 context rail：每个工具 View 自己用既有 `@State` / 注入服务构造 `WorkspaceHeader + primary canvas + ContextRail`，并在 `<1180pt` 将同一 context View 放入自己的 inspector popover。主题偏好保存在 `SettingsStore`，以 Root 和 Settings 共用的 `preferredColorScheme` 生效；连续动效从 `accessibilityReduceMotion` 读取开关。

**Tech Stack:** Swift 5 / SwiftUI / AppKit，macOS 14+，无新增第三方依赖；既有独立 `swiftc @main` 测试和 `xcodebuild` Debug/Release 构建。

---

## Guardrails

- 仅修改 SwiftUI 呈现层、主题偏好和布局纯函数。不得修改 `ResignTask`、ZSign、`EntitlementReconciler`、MobileDevice/AFC 协议、互传配对/重连、传输历史格式或 `QRCodeService`。唯一新增的状态观察器是 UI 自己拥有的只读 `NWPathMonitor` 包装；它不能调用、影响或持久化 `TransferService`。
- Settings 继续是 `EasySignApp` 中既有 `Settings` scene；更新继续由 `UpdateCommands` 触发并通过既有 `UpdateSheet` 呈现。不要将它们路由进 Sidebar。
- 设备页的“队列”只呈现 `TransferState` 代表的当前单批 AFC 操作；不得新增后台队列、并行执行、跨批重试或持久化任务。
- 二维码“本次会话”只显示本 View 的 `statusText` / `scanResults`；不得写入 UserDefaults 或新增历史记录。
- 所有业务回调、确认对话框、错误 alert、快捷键、文本选择、拖放和 focus ring 必须原样保留。视觉颜色必须来自 Glass token；业务页不再直接选择深浅主题颜色。
- 视觉验收必须同时覆盖深色、浅色和 Reduce Motion。只有任务活跃时允许运行无限动画，页面离开时必须停止。

## File structure

```
EasySign/
├── App/
│   ├── EasySignApp.swift                         # 根窗口/Settings 共同应用主题偏好
│   ├── RootView.swift                            # Glass Workbench shell、工具转场（不持有工具 context）
│   ├── SidebarView.swift                         # 品牌区 + 自适应 icon rail
│   ├── SettingsView.swift                        # glass preference cards + 主题 Picker
│   └── UpdateView.swift                          # 版本中心化更新 sheet
├── Core/
│   ├── Storage/SettingsStore.swift               # interfaceTheme key、reset 覆盖
│   └── UI/
│       ├── GlassDesignSystem.swift               # tokens、主题偏好、surface/button/badge/pulse
│       ├── GlassLayout.swift                     # 响应式阈值的纯布局决策
│       ├── GlassWorkbenchComponents.swift        # WorkspaceHeader、ContextRail、ActivityCard
│       ├── FilePickerField.swift                 # 只替换为 token 化输入外观
│       ├── LogPanelView.swift                    # 只替换为 token 化活动日志外观
│       └── ProgressTimeline.swift                # token 化重签进度条
└── Features/
    ├── Resign/
    │   ├── ResignContentView.swift               # 生命周期、校验、动作回调保持原样；挂接新 section
    │   ├── ResignWorkspaceSections.swift         # 输入/签名/导出主画布和 context/activity 视图
    │   ├── ResignFormControls.swift              # File/form/dropdown/dylib 的纯呈现组件
    │   └── IPAPreviewPanelView.swift             # IPA 预览 sheet 的 glass 层
    ├── Devices/
    │   ├── DeviceView.swift                      # 宽度切换、设备主画布、保持选择/浏览状态
    │   ├── DeviceListPanel.swift                 # glass rail、状态行
    │   ├── DeviceWorkspaceChrome.swift           # top picker、连接 context rail、文件 action shell
    │   ├── SandboxBrowserView.swift              # token 化工具栏、悬浮操作栏、现有 TransferState
    │   ├── AppListView.swift                     # 应用列表的 surface/empty/error 视觉层
    │   ├── FilePreviewView.swift                 # 文件预览 action shell 和 activity surface
    │   ├── DestinationPickerSheet.swift          # AFC 目标目录 sheet 的 glass 层
    │   ├── ConflictResolutionSheet.swift          # 冲突确认 sheet 的 glass 层
    │   └── TransferProgressBar.swift             # 现有单批状态的 activity card 外观
    ├── Transfer/
    │   ├── TransferNetworkPathObserver.swift     # UI 自有、只读的本机网络路径摘要
    │   └── TransferToolView.swift                # 会话页首、activity/history/log workbench
    └── QRCode/
        ├── QRCodeTool.swift                      # 注入 hub 以使用共用 workspace chrome（不新增服务）
        └── QRCodeToolView.swift                  # 居中 QR canvas + session context rail
Tests/
├── GlassLayoutTests.swift                        # 700/820/980/1180 断点
├── GlassThemePreferenceTests.swift               # 系统/浅色/深色解析与 Settings key
└── TransferNetworkPathPresentationTests.swift    # 本机网络路径摘要的真值映射
```

`EasySign/` 使用 Xcode 文件系统同步分组，新增 Swift 文件会自动进入主 target；不手改 `project.pbxproj`。

## Verification commands

Use these commands throughout; do not hide output with pipes so failures stay visible.

```bash
swiftc EasySign/Core/UI/GlassLayout.swift Tests/GlassLayoutTests.swift -o /tmp/GlassLayoutTests
/tmp/GlassLayoutTests

swiftc EasySign/Core/UI/GlassDesignSystem.swift EasySign/Core/UI/GlassLayout.swift Tests/GlassThemePreferenceTests.swift -o /tmp/GlassThemePreferenceTests
/tmp/GlassThemePreferenceTests

xcodebuild -project EasySign.xcodeproj -scheme EasySign -configuration Debug -destination 'platform=macOS' build
xcodebuild -project EasySign.xcodeproj -scheme EasySign -configuration Release -destination 'platform=macOS' build
```

When changed code touches an existing subsystem, run that subsystem’s standalone test(s) in addition to the two new tests. Preserve the repo convention: test executables print `ALL PASS` on success.

## Task 1: Add testable theme and responsive-layout decisions

**Files:**
- Create: `Tests/GlassLayoutTests.swift`
- Create: `EasySign/Core/UI/GlassLayout.swift`
- Modify: `EasySign/Core/Storage/SettingsStore.swift`

- [ ] **Step 1: Write the failing layout test.**

  In `Tests/GlassLayoutTests.swift`, encode the approved breakpoints as assertions:

  - width `1180` keeps `.contextRail`, width `1179` uses `.contextInspector`;
  - `980` keeps the Devices rail, `979` returns `.topDevicePicker`;
  - `820` has normal labelled Sidebar, `819...700` returns icon rail, `699` returns `.systemCollapsed`;
  - values exactly at boundaries are stable and every enum case has a readable `accessibilityLabel`.

- [ ] **Step 2: Implement the minimal pure decision API.**

  Create `GlassLayout.swift` with Foundation/CoreGraphics-only types:

  ```swift
  enum GlassSidebarMode { case labelledRail, iconRail, systemCollapsed }
  enum GlassContextPresentation { case rail, inspector }
  enum GlassDeviceSelectorPresentation { case rail, topPicker }

  enum GlassLayout {
      static func sidebarMode(for width: CGFloat) -> GlassSidebarMode {
          width < 700 ? .systemCollapsed : (width < 820 ? .iconRail : .labelledRail)
      }
      static func contextPresentation(for width: CGFloat) -> GlassContextPresentation {
          width < 1180 ? .inspector : .rail
      }
      static func deviceSelectorPresentation(forDetailWidth width: CGFloat) -> GlassDeviceSelectorPresentation {
          width < 980 ? .topPicker : .rail
      }
  }
  ```

  Encode only the spec’s `<` thresholds, making equality remain in the larger layout. Do not put SwiftUI Views or animations in this file.

- [ ] **Step 3: Run the new test and make it pass.**

  ```bash
  swiftc EasySign/Core/UI/GlassLayout.swift Tests/GlassLayoutTests.swift -o /tmp/GlassLayoutTests
  /tmp/GlassLayoutTests
  ```

- [ ] **Step 4: Add the settings key (the enum test belongs to Task 2).**

  Add `.interfaceTheme` to `SettingsKey` and include it in `resetAll()`. Do not introduce a duplicate theme enum here: `GlassThemePreference` and its test are created together in Task 2, so this commit remains buildable.

- [ ] **Step 5: Commit the decision layer.**

  ```bash
  git add EasySign/Core/Storage/SettingsStore.swift EasySign/Core/UI/GlassLayout.swift Tests/GlassLayoutTests.swift
  git commit -m "feat(ui): add testable glass theme and layout decisions"
  ```

## Task 2: Build the shared Signal Glass design system

**Files:**
- Create: `EasySign/Core/UI/GlassDesignSystem.swift`
- Create: `EasySign/Core/UI/GlassWorkbenchComponents.swift`
- Create: `Tests/GlassThemePreferenceTests.swift`

- [ ] **Step 1: Complete the failing theme test.**

  Create `Tests/GlassThemePreferenceTests.swift` first. Assert `GlassThemePreference(rawValue:)` accepts `system`, `light`, `dark`, rejects other strings, and `resolvedColorScheme` returns `nil` for system, `.light` for light and `.dark` for dark. Keep this logic independent from system `ColorScheme`, so the app can follow macOS when the setting is system.

- [ ] **Step 2: Implement tokens and primitives, not feature-specific widgets.**

  In `GlassDesignSystem.swift`, add:

  - `GlassThemePreference: String, CaseIterable, Identifiable` with Chinese display names and `resolvedColorScheme: ColorScheme?`;
  - a `GlassPalette` that derives canvas, rail, surface, stroke, text, primary-gradient, success, warning, danger and muted semantic colours from `@Environment(\.colorScheme)`;
  - `GlassCanvas`, `GlassSurface` (10/14/20 radius variants), `GlassButtonStyle`, `GlassIconButtonStyle`, `StatusBadge`, and `ActivityPulse`;
  - accessibility labels for state badges, and `@Environment(\.accessibilityReduceMotion)` in `ActivityPulse` so it becomes static when requested.

  The highlight may use a single linear gradient and an `opacity + offset` repeat animation, only while `isActive == true`; call `.animation(nil, value:)`/cancel state when inactive. Use material plus a palette-backed fallback rather than a hard-coded dark fill.

- [ ] **Step 3: Add composition components.**

  In `GlassWorkbenchComponents.swift`, implement `WorkspaceHeader`, `ContextRail`, `ActivityCard`, `GlassSectionTitle`, and an inspector `Popover` helper. They accept content closures and semantic state; they must not import `ServiceHub`, own business state, or create their own timers.

  `WorkspaceHeader` displays tool icon/name/subtitle, optional status badge and trailing action closure. `ContextRail` supports a narrow header, normal detail list and an optional primary action. `ActivityCard` can render a `ProgressView` or success/failure copy and includes `ActivityPulse(isActive:)`.

- [ ] **Step 4: Pass unit checks and compile the app.**

  ```bash
  swiftc EasySign/Core/UI/GlassDesignSystem.swift EasySign/Core/UI/GlassLayout.swift Tests/GlassThemePreferenceTests.swift -o /tmp/GlassThemePreferenceTests
  /tmp/GlassThemePreferenceTests
  xcodebuild -project EasySign.xcodeproj -scheme EasySign -configuration Debug -destination 'platform=macOS' build
  ```

- [ ] **Step 5: Commit the design system.**

  ```bash
  git add EasySign/Core/UI/GlassDesignSystem.swift EasySign/Core/UI/GlassWorkbenchComponents.swift Tests/GlassThemePreferenceTests.swift
  git commit -m "feat(ui): add signal glass design system"
  ```

## Task 3: Redesign the app shell, theme setting and tool transition

**Files:**
- Modify: `EasySign/App/EasySignApp.swift`
- Modify: `EasySign/App/RootView.swift`
- Modify: `EasySign/App/SidebarView.swift`
- Modify: `EasySign/App/SettingsView.swift`

- [ ] **Step 1: Wire manual theme preference without changing scene ownership.**

  Use `@AppStorage(SettingsKey.interfaceTheme.rawValue)` in `EasySignApp` to apply `.preferredColorScheme(GlassThemePreference(rawValue: stored) ?? .system).resolvedColorScheme` to both the main `Window` root and the `Settings` root. Do not create another window or alter `MenuBarExtra`/`UpdateCommands`.

  Add a `Picker("外观", ...)` to Settings’ General tab bound through `SettingsStore.set(_:for:)`. Present the three choices as “跟随系统 / 浅色 / 深色” and add a short live-effect subtitle. Redraw existing settings sections with `GlassSurface`/`GlassSectionTitle`; keep every current Toggle, Stepper, Button and binding intact.

- [ ] **Step 2: Replace the bare navigation chrome.**

  In `RootView`, preserve persisted selection and `NavigationSplitView`. Wrap it in `GlassCanvas`; derive only Sidebar presentation using `GeometryReader` and `GlassLayout`.

  - Do not create a generic Root context rail or inspector: `Tool` has no rail API and each feature must own its stateful context View locally.
  - On tool changes, key the detail content by `tool.id` and use a 380 ms opacity + x-offset transition. Individual tool `WorkspaceHeader`s provide their own header-first/content-second stagger. Respect `accessibilityReduceMotion` with a short opacity-only animation.
  - Do not remove the existing minimum detail width or selection persistence.

- [ ] **Step 3: Turn `SidebarView` into a branded adaptive rail.**

  Add a top brand area (EasySign mark, “Signal Glass” caption), selected tool gradient treatment and tool category labels. At `.iconRail`, hide only labels/subtitles and provide a tooltip/accessibility label per icon. Let `.systemCollapsed` be handled by `NavigationSplitView`, not by an ad-hoc hidden list. Keep current tool order/category grouping and selection tags.

- [ ] **Step 4: Compile and perform shell visual QA.**

  ```bash
  xcodebuild -project EasySign.xcodeproj -scheme EasySign -configuration Debug -destination 'platform=macOS' build
  ```

  Manually launch Debug and check navigation, last-tool restore, Settings scene, keyboard focus and all three widths (>=1180, 700...819, <700) under both themes and Reduce Motion. Tool-specific rail/inspector content is verified in Tasks 5–8, not in RootView.

- [ ] **Step 5: Commit the shell.**

  ```bash
  git add EasySign/App/EasySignApp.swift EasySign/App/RootView.swift EasySign/App/SidebarView.swift EasySign/App/SettingsView.swift
  git commit -m "feat(ui): build glass workbench application shell"
  ```

## Task 4: Tokenize shared input, log and timeline components

**Files:**
- Modify: `EasySign/Core/UI/FilePickerField.swift`
- Modify: `EasySign/Core/UI/LogPanelView.swift`
- Modify: `EasySign/Core/UI/ProgressTimeline.swift`

- [ ] **Step 1: Inventory behavior before styling.**

  For each component, list existing public init parameters and interactions in comments or a scratch checklist: FilePickerField selection/drop/clear/recents; LogPanel copy/save/filter/run behavior; timeline current/failure state. Do not alter their public API or callback ordering.

- [ ] **Step 2: Apply the design system.**

  Replace direct `windowBackgroundColor`, `controlBackgroundColor`, `.quaternary`, literal grey/blue/red/green with `GlassSurface` and semantic palette/status values. Keep input errors and failed stages explicit with both icon/text and danger tint. Ensure log text remains monospace and selectable, and ProgressTimeline labels remain readable in narrow cards.

- [ ] **Step 3: Build and smoke-test existing affordances.**

  ```bash
  xcodebuild -project EasySign.xcodeproj -scheme EasySign -configuration Debug -destination 'platform=macOS' build
  ```

  In the running app, select/clear/reopen a recent IPA, copy a log line/full log, and check failed/current/completed timeline samples using the existing preview or live run. Test deep/light and keyboard focus.

- [ ] **Step 4: Commit shared tokenization.**

  ```bash
  git add EasySign/Core/UI/FilePickerField.swift EasySign/Core/UI/LogPanelView.swift EasySign/Core/UI/ProgressTimeline.swift
  git commit -m "refactor(ui): apply glass tokens to shared controls"
  ```

## Task 5: Recompose Resign as a staged workbench

**Files:**
- Create: `EasySign/Features/Resign/ResignFormControls.swift`
- Create: `EasySign/Features/Resign/ResignWorkspaceSections.swift`
- Modify: `EasySign/Features/Resign/ResignContentView.swift`
- Modify: `EasySign/Features/Resign/IPAPreviewPanelView.swift`
- Modify: `EasySign/Features/Resign/IPAContentView.swift`

- [ ] **Step 1: Extract presentation-only controls without changing bindings.**

  Move `ResignPageHeader`, `ResignSectionView`, `FormRow`, `InputField`, `DropdownPickerRow` and `InjectedDylibPickerView` out of `ResignContentView.swift`. Preserve each initializer and action closure (including field titles, file chooser behavior, secure password state and dylib removal). Replace their backgrounds with shared glass components.

- [ ] **Step 2: Add the staged main canvas.**

  In `ResignWorkspaceSections.swift`, provide three surface sections:

  1. **输入 IPA** — input picker, preview and existing info-editor popover trigger;
  2. **证书与权限** — P12, password, mobileprovision, backend/export type, dylib injection;
  3. **校验与导出** — output picker and the unchanged start action.

  Add a read-only summary card deriving only from existing `ContentViewModel` fields: selected P12/profile filenames, backend/export type, edited bundle id (if loaded), dylib count and output directory. Do not parse profiles/certificates a second time and do not add entitlements mutations.

  The spec-required entitlement rewrite count is authoritative **only after the current ZSign run reaches reconciliation**. Make `ResignContentView` explicitly observe the existing logger: declare `@ObservedObject private var logger: LoggerService`, then initialize it in `init(hub:)` with `_logger = ObservedObject(wrappedValue: hub.logger)`. Derive the count from `logger.recentEntries` for tool `resign` (the existing `onTapStart()` clears that tool before every run): count current entries whose message begins `zsign entitlement ` and contains either `移除` or `改写`. Reading the observed `logger.revision` in the derived property guarantees a body refresh as each existing backend log arrives. Before those logs arrive, render `权限改写数：待实际校验`; during the run display the accumulating actual count, and leave the final count in the completed activity summary. Do not invoke `EntitlementReconciler`, parse a profile, or mutate entitlements from the UI merely to predict this number.

- [ ] **Step 3: Add activity and responsive context presentation.**

  Make `ResignContentView` own a `WorkspaceHeader` and one `resignContextRail` View containing the read-only summary/activity state. Keep `LogPanelView(logger: hub.logger, toolId: "resign")`, moving it into an `ActivityCard`. While `viewModel.loading`, show a visible “重签进行中” badge/pulse and disable only the existing start button as today; after completion, keep the full log expandable. At `>=1180`, lay out that same `resignContextRail` beside the primary canvas; at `<1180`, pass the same View to the header’s inspector popover. Primary “开始重签” stays in the export canvas.

  Tokenize the existing `CustomLoadingView` in `ResignContentView.swift` as a compact glass activity surface: primary-gradient glyph/spinner, `ActivityPulse(isActive: true)`, readable “重签中” text and no hard-coded blue. It may simplify its initializer to `CustomLoadingView(text:)`; update its sole sheet call accordingly. Preserve `sheet(isPresented: $viewModel.loading)` exactly, so its presentation/dismissal lifecycle remains the existing `viewModel.loading` transition.

  Keep all other alerts, preview sheet, UserDefaults cache writes, `validateBeforeStart()`, `onTapStart()`, output success actions and `ResignTask(...).Start()` byte-for-byte except for moving code between files.

- [ ] **Step 3b: Re-skin every reachable Resign sheet.**

  Apply `GlassCanvas`, `GlassSurface`, semantic status badges and token-based strokes to `IPAPreviewPanelView` and `IPAContentView`. Preserve all tabs, existing parsed values, editor bindings, sheet sizing, text selection, copy actions and dismissal behavior. This step changes no preview/parser code.

- [ ] **Step 4: Build and run resign safety checks.**

  ```bash
  swiftc -o /tmp/easysign-entitlement-tests EasySign/Core/Resigning/Model/ZSignProfileContext.swift EasySign/Core/Resigning/Model/EntitlementReconciler.swift Tests/EntitlementReconcilerTests.swift
  /tmp/easysign-entitlement-tests
  swiftc -o /tmp/easysign-profile-context-tests EasySign/Core/Resigning/Model/ZSignProfileContext.swift Tests/ZSignProfileContextTests.swift
  /tmp/easysign-profile-context-tests
  xcodebuild -project EasySign.xcodeproj -scheme EasySign -configuration Debug -destination 'platform=macOS' build
  ```

  Manually verify an invalid/missing field triggers the same alert, every file chooser works, entitlement edit remains available, start invokes a run and success alert still offers Finder/copy/share.

- [ ] **Step 5: Commit Resign layout only.**

  ```bash
  git add EasySign/Features/Resign/ResignContentView.swift EasySign/Features/Resign/ResignFormControls.swift EasySign/Features/Resign/ResignWorkspaceSections.swift EasySign/Features/Resign/IPAPreviewPanelView.swift EasySign/Features/Resign/IPAContentView.swift
  git commit -m "feat(ui): redesign resign as staged glass workbench"
  ```

## Task 6: Redesign Devices with adaptive selector and AFC activity presentation

**Files:**
- Create: `EasySign/Features/Devices/DeviceWorkspaceChrome.swift`
- Modify: `EasySign/Features/Devices/DeviceView.swift`
- Modify: `EasySign/Features/Devices/DeviceListPanel.swift`
- Modify: `EasySign/Features/Devices/SandboxBrowserView.swift`
- Modify: `EasySign/Features/Devices/TransferProgressBar.swift`
- Modify: `EasySign/Features/Devices/AppListView.swift`
- Modify: `EasySign/Features/Devices/FilePreviewView.swift`
- Modify: `EasySign/Features/Devices/DestinationPickerSheet.swift`
- Modify: `EasySign/Features/Devices/ConflictResolutionSheet.swift`

- [ ] **Step 1: Build the responsive selector without changing selection state.**

  In `DeviceView`, retain `@StateObject DeviceManager.shared`, `selectedDevice`, `mode`, `selectedApp`, `previewFile` and `appListRefreshTrigger`. Use `GlassLayout.deviceSelectorPresentation(forDetailWidth:)` to show the existing `DeviceListPanel` at >=980pt and a top `DevicePickerStrip` below 980pt. Both must call the existing `onDeviceSelected` reset closure.

- [ ] **Step 2: Add chrome around, not inside, AFC operations.**

  Make `DeviceView` own a `WorkspaceHeader` and one `DeviceConnectionRail` containing selected device name, system version, transport icon, selected browse mode and explanatory connection state. No new connection calls. At `>=1180`, place the rail next to the primary device browser; at `<1180`, pass that same rail to the header’s inspector popover. This preserves the `Tool` protocol unchanged and keeps selection state local.

  Give `DeviceListPanel` a glass rail header with its existing refresh action, selected device state and VoiceOver labels. Preserve the actual device list and no-device placeholder.

- [ ] **Step 3: Re-skin file browser action and transfer state.**

  Change `SandboxBrowserView` toolbar into a compact glass action bar, retaining back/refresh/upload actions and their `.disabled(transferState.isInProgress)` conditions. Keep the List, double-click navigation, selection, menus, conflict sheet, deletion alert, loading/error branches and callback wiring unchanged.

  Render existing `TransferProgressBar(state:)` as a floating `ActivityCard` with status text, pulse only for `.inProgress`, and success state that still auto-dismisses through the existing extension. It represents exactly one existing `TransferState`; do not add a collection/queue model or change callback timing.

- [ ] **Step 3b: Complete the reachable Devices surface.**

  Tokenize `AppListView` loading/empty/error/list surfaces, `FilePreviewView` toolbar/content/error/active-transfer shell, `DestinationPickerSheet` title/toolbar/confirm bars and `ConflictResolutionSheet` warning/detail/action surfaces. Preserve all existing data loading, device calls, sheet result closures, keyboard shortcuts, selection gestures and errors. This is a visual-only pass; no AFC service, `SandboxFileOperations` or conflict-resolution decision code changes.

- [ ] **Step 4: Compile and run device regressions.**

  ```bash
  xcodebuild -project EasySign.xcodeproj -scheme EasySign -configuration Debug -destination 'platform=macOS' build
  ```

  On a connected device, test device selection, app/media switching, sandbox navigation, double-click preview, upload/drop, download, copy/move, conflict cancellation and delete. Repeat compact layout (<980pt) and Reduce Motion.

- [ ] **Step 5: Commit Devices UI.**

  ```bash
  git add EasySign/Features/Devices/DeviceView.swift EasySign/Features/Devices/DeviceListPanel.swift EasySign/Features/Devices/DeviceWorkspaceChrome.swift EasySign/Features/Devices/SandboxBrowserView.swift EasySign/Features/Devices/TransferProgressBar.swift EasySign/Features/Devices/AppListView.swift EasySign/Features/Devices/FilePreviewView.swift EasySign/Features/Devices/DestinationPickerSheet.swift EasySign/Features/Devices/ConflictResolutionSheet.swift
  git commit -m "feat(ui): redesign devices as responsive glass workspace"
  ```

## Task 7: Redesign Transfer around the live session

**Files:**
- Create: `EasySign/Features/Transfer/TransferNetworkPathObserver.swift`
- Create: `Tests/TransferNetworkPathPresentationTests.swift`
- Modify: `EasySign/Features/Transfer/TransferToolView.swift`

- [ ] **Step 1: Add a truthful, UI-owned network-path presentation test.**

  In `Tests/TransferNetworkPathPresentationTests.swift`, first assert the pure status mapper renders only facts: `checking`, `unavailable`, `Wi-Fi available`, `wired available`, and `network available`. It must not expose labels such as “excellent”, signal bars, bandwidth or latency because no such measurement exists.

  Implement `TransferNetworkPathObserver.swift` with a small `ObservableObject` wrapping `NWPathMonitor`. The observer maps `NWPath.Status` and interface type to the tested presentation enum on the main actor, starts in `.onAppear`, cancels in `.onDisappear`/`deinit`, and never references `TransferService`. It is a read-only local-path indicator, not a peer network-quality measurement.

- [ ] **Step 2: Preserve every TransferService call before re-layout.**

  Keep `host`, `portText`, pairing code state, discovery list, manual connect disclosure, all `service.connect`, `disconnect`, `retry`, `sendFile`, clipboard toggle, history actions, retry availability, confirmation dialog and log panel. Make no changes to `TransferService`, transport, pairing or history files.

- [ ] **Step 3: Create the session-first layout.**

  In `TransferToolView`, own both its `WorkspaceHeader` and a `transferContextRail` View. Replace `statusHeader` with a large session surface showing status badge, peer name, local IP/port and a semantic connection sentence. The context rail is built from the same `service.connectionState`, pairing/trust facts (paired fingerprint match versus code-required) and the `TransferNetworkPathObserver`’s local-path summary. Label the latter “本机网络路径”, not “网络质量”, so the UI never claims a measurement it does not have. At `<1180`, show the same local `transferContextRail` in the header’s inspector popover.

  Pairing/discovery/manual connect remain the primary canvas when disconnected. Connected canvas has upload drop surface and clipboard sharing; `activeTransfers` render as activity cards showing direction, file, percent and bytes.

  Use `ActivityPulse` only while `.connecting`, `.pairing`, or active transfer cards exist. Failed state must keep the existing Retry button visible in the main canvas. At `<1180`, move discovery/network explanatory detail to the tool-owned inspector but never hide pairing code, connect/retry or file-send actions there.

- [ ] **Step 4: Rework history/log as dense secondary activity.**

  Keep history’s exact clear confirmation copy and all open/reveal/copy actions. Use a Glass disclosure surface and preserve the existing 360pt bounded scroll behavior. Restyle the existing diagnostic `LogPanelView` only; do not change run filtering or the text-selection behavior.

- [ ] **Step 5: Run transport tests and visual smoke test.**

  ```bash
  swiftc -o /tmp/easysign-transfer-path-tests EasySign/Features/Transfer/TransferNetworkPathObserver.swift Tests/TransferNetworkPathPresentationTests.swift
  /tmp/easysign-transfer-path-tests
  swiftc -o /tmp/easysign-transfer-history-tests EasySign/Core/Transfer/TransferModels.swift EasySign/Core/Transfer/TransferHistoryStore.swift Tests/TransferHistoryStoreTests.swift
  /tmp/easysign-transfer-history-tests
  swiftc -o /tmp/easysign-transfer-autoreconnect-tests EasySign/Core/Transfer/TransferAutoReconnect.swift Tests/TransferAutoReconnectTests.swift
  /tmp/easysign-transfer-autoreconnect-tests
  swiftc -o /tmp/easysign-transfer-loopback-tests EasySign/Core/Logging/LogLevel.swift EasySign/Core/Logging/LoggerService.swift EasySign/Core/Transfer/*.swift Tests/TransferLoopbackTests.swift
  /tmp/easysign-transfer-loopback-tests
  xcodebuild -project EasySign.xcodeproj -scheme EasySign -configuration Debug -destination 'platform=macOS' build
  ```

  Verify both paired and unpaired connect flows, manual IP validation, file drop/send, clipboard toggle, disconnect/retry, history actions and error/log expansion in deep/light/Reduce Motion.

- [ ] **Step 6: Commit Transfer UI.**

  ```bash
  git add EasySign/Features/Transfer/TransferNetworkPathObserver.swift EasySign/Features/Transfer/TransferToolView.swift Tests/TransferNetworkPathPresentationTests.swift
  git commit -m "feat(ui): redesign transfer around live session state"
  ```

## Task 8: Redesign QR Code as a focused canvas with session context

**Files:**
- Modify: `EasySign/Features/QRCode/QRCodeTool.swift`
- Modify: `EasySign/Features/QRCode/QRCodeToolView.swift`

- [ ] **Step 1: Pass existing composition context, not stateful services.**

  Change `QRCodeTool.makeContentView(hub:)` to pass `hub` only if needed for common workspace presentation. Do not add `QRCodeService` to `ServiceHub`, new persistent data, permissions, or backend APIs.

- [ ] **Step 2: Build the focused canvas.**

  Keep `inputText`, `selectedSize`, `qrImage`, `statusText`, `scanResults` and `presentError` exactly as View state. Lay out the content editor and generation button in the primary canvas, centre the QR preview in a large glass surface, and make scan/share actions a clear vertical action group. Preserve copy/save/share/AirDrop/scan implementations, disable rules, error alert and image interpolation.

  Make `QRCodeToolView` own a `WorkspaceHeader` and a single `qrCodeContextRail` View. The rail shows image dimensions, the current result sentence and a “本次会话” scan-result list. It is not persistent; generating a new code still clears `scanResults` as it does today. At `>=1180`, place that same View next to the canvas; at `<1180`, use it in the tool-owned header inspector popover, while “生成二维码” and “扫描屏幕上的二维码” remain in the canvas.

- [ ] **Step 3: Compile and run QR regression.**

  ```bash
  swiftc -o /tmp/easysign-qrcode-tests EasySign/Core/QR/QRCodeService.swift Tests/QRCodeServiceTests.swift
  /tmp/easysign-qrcode-tests
  xcodebuild -project EasySign.xcodeproj -scheme EasySign -configuration Debug -destination 'platform=macOS' build
  ```

  Smoke-test generate/copy/save/share/AirDrop-disabled/scan actions and no-result/result layouts under both themes.

- [ ] **Step 4: Commit QR layout.**

  ```bash
  git add EasySign/Features/QRCode/QRCodeTool.swift EasySign/Features/QRCode/QRCodeToolView.swift
  git commit -m "feat(ui): redesign qr code focused workspace"
  ```

## Task 9: Redraw Update as a version-status sheet

**Files:**
- Modify: `EasySign/App/UpdateView.swift`

- [ ] **Step 1: Keep the state matrix intact.**

  Preserve the existing `readyToInstall`, `installerOpened`, `downloadProgress` and fallback branches, including all service calls (`dismissUpdate`, `installAndRelaunch`, `cancelDownload`, `startDownload`) and default-action shortcuts.

- [ ] **Step 2: Apply a version-centred surface.**

  Place the new version/current version/status badge in `WorkspaceHeader` style; show release notes in a selectable glass surface and use `ActivityCard` for downloading. Keep the sheet width, warning text and button ordering semantically identical, improving only hierarchy/spacing.

- [ ] **Step 3: Compile and manual state check.**

  ```bash
  swiftc -o /tmp/easysign-semver-tests EasySign/Core/Update/SemanticVersion.swift Tests/SemanticVersionTests.swift
  /tmp/easysign-semver-tests
  xcodebuild -project EasySign.xcodeproj -scheme EasySign -configuration Debug -destination 'platform=macOS' build
  ```

  Trigger or preview each branch and verify default buttons and cancellation behavior unchanged in deep/light themes.

- [ ] **Step 4: Commit Update UI.**

  ```bash
  git add EasySign/App/UpdateView.swift
  git commit -m "feat(ui): redesign update version status sheet"
  ```

## Task 10: Full visual accessibility and release verification

**Files:**
- Modify only if needed from documented QA defects; otherwise no source changes.

- [ ] **Step 1: Run complete required automated checks.**

  ```bash
  swiftc EasySign/Core/UI/GlassLayout.swift Tests/GlassLayoutTests.swift -o /tmp/GlassLayoutTests
  /tmp/GlassLayoutTests
  swiftc EasySign/Core/UI/GlassDesignSystem.swift EasySign/Core/UI/GlassLayout.swift Tests/GlassThemePreferenceTests.swift -o /tmp/GlassThemePreferenceTests
  /tmp/GlassThemePreferenceTests
  swiftc -o /tmp/easysign-entitlement-tests EasySign/Core/Resigning/Model/ZSignProfileContext.swift EasySign/Core/Resigning/Model/EntitlementReconciler.swift Tests/EntitlementReconcilerTests.swift
  /tmp/easysign-entitlement-tests
  swiftc -o /tmp/easysign-profile-context-tests EasySign/Core/Resigning/Model/ZSignProfileContext.swift Tests/ZSignProfileContextTests.swift
  /tmp/easysign-profile-context-tests
  swiftc -o /tmp/easysign-qrcode-tests EasySign/Core/QR/QRCodeService.swift Tests/QRCodeServiceTests.swift
  /tmp/easysign-qrcode-tests
  swiftc -o /tmp/easysign-transfer-history-tests EasySign/Core/Transfer/TransferModels.swift EasySign/Core/Transfer/TransferHistoryStore.swift Tests/TransferHistoryStoreTests.swift
  /tmp/easysign-transfer-history-tests
  swiftc -o /tmp/easysign-transfer-autoreconnect-tests EasySign/Core/Transfer/TransferAutoReconnect.swift Tests/TransferAutoReconnectTests.swift
  /tmp/easysign-transfer-autoreconnect-tests
  swiftc -o /tmp/easysign-transfer-loopback-tests EasySign/Core/Logging/LogLevel.swift EasySign/Core/Logging/LoggerService.swift EasySign/Core/Transfer/*.swift Tests/TransferLoopbackTests.swift
  /tmp/easysign-transfer-loopback-tests
  swiftc -o /tmp/easysign-transfer-path-tests EasySign/Features/Transfer/TransferNetworkPathObserver.swift Tests/TransferNetworkPathPresentationTests.swift
  /tmp/easysign-transfer-path-tests
  xcodebuild -project EasySign.xcodeproj -scheme EasySign -configuration Debug -destination 'platform=macOS' build
  xcodebuild -project EasySign.xcodeproj -scheme EasySign -configuration Release -destination 'platform=macOS' build
  ```

- [ ] **Step 2: Perform the visual QA matrix.**

  For Resign, Devices, Transfer, QR, Settings and Update, inspect:

  | Variant | Required result |
  | --- | --- |
  | Deep theme | Canvas/rail/surfaces stay distinct; primary, success, warning and danger text meet readable contrast. |
  | Light theme | No translucent white-on-white loss; controls, selection and shadows remain legible. |
  | Reduce Motion | Tool switch is a short fade; no drifting highlight or expanding pulse remains. |
  | >=1180pt | Context rail visible, main actions remain in canvas. |
  | 820...1179pt | Context becomes inspector; sidebar remains usable. |
  | 700...819pt | Sidebar is icon-only with labels available by tooltip/VoiceOver. |
  | <700pt | System `NavigationSplitView` collapse works and no action becomes unreachable. |
  | Devices <980pt | Top device picker replaces the detail rail and browser keeps a usable width. |

  Also use VoiceOver rotor/focus navigation to confirm every icon-only control has a label and error/status is not colour-only.

- [ ] **Step 3: Execute manual product smoke tests.**

  - Resign: invalid preflight, select/edit preview, one successful sample signing flow if local credentials are available.
  - Devices: selection, sandbox/media browse, one supported file operation and conflict cancel.
  - Transfer: two-machine pairing/connection, one file and one clipboard action, disconnect/retry.
  - QR: generate/copy/save/scan.

  Record unavailable hardware/credentials as test-environment limitations, not as green checks.

- [ ] **Step 4: Request final code review before merging/releasing.**

  Run `superpowers:requesting-code-review` and resolve genuine regressions. Do not alter business behavior merely to satisfy a visual preference.

- [ ] **Step 5: Commit only any QA fixes.**

  If QA did not require source changes, do not create an empty commit. Otherwise, stage only the files returned by `git status --short` that were changed to resolve a recorded QA defect; do not stage unrelated worktree changes.

  ```bash
  git status --short
  git commit -m "fix(ui): address glass workbench qa findings"
  ```

## Final acceptance criteria

- Deep and light are equally polished and system-following remains the default.
- Every page named in the spec is visually rebuilt with Glass Workbench language.
- The prescribed widths use the exact 1180/980/820/700 behavior and never hide a primary action inside a collapsed rail.
- Page transitions, highlight drift and task pulses are visible with normal motion and fully reduced with Reduce Motion.
- Existing state transitions, data storage, signing implementation, AFC transfer semantics, pairing security and QR session behavior remain unchanged.
- All listed tests/builds pass, and manual smoke tests either pass or are explicitly recorded as unavailable due to missing local device/credentials.
