# Signal Glass Workbench UI 重设计

## 目标

将 EasySign 重设计为一套有明确空间层级和实时反馈的 macOS 专业工作台。改造覆盖应用外壳、重签、设备、互传、二维码、设置与更新；不改动 zsign、签名策略、MobileDevice/AFC 协议或现有业务数据模型。

设计选择：

- 信息架构：Glass Workbench。
- 主题：深色与浅色同等完成度；默认跟随系统，设置可固定选择。
- 动效：明确的页面转场、玻璃高光与状态脉冲；完整遵从 macOS Reduce Motion。

## 视觉系统

新增 `GlassDesignSystem`，作为唯一的视觉 token 与组件入口。

### 色彩与材质

| 角色 | 深色 | 浅色 | 用途 |
| --- | --- | --- | --- |
| Canvas | 墨蓝黑 | 雾白蓝 | 窗口和页面背景 |
| Rail | 深玻璃 | 半透明白玻璃 | 导航与上下文栏 |
| Surface | 半透明深蓝 | 半透明白 | 卡片、表单、popover |
| Primary | 薄荷 → 紫色渐变 | 相同渐变，降低饱和度 | 主行动与选中状态 |
| Success | 薄荷绿 | 深海松绿 | 成功、在线、可用 |
| Warning | 琥珀橙 | 琥珀橙 | 需注意状态 |
| Danger | 珊瑚红 | 珊瑚红 | 失败和破坏性操作 |

玻璃仅用于三层：窗口 canvas、导航/context rail、主要工作卡。普通表格行与小控件不重复使用重材质，以保证文本对比度与信息密度。

### 排版与组件

- 标题使用紧凑的 SF Pro Display 层级；日志、指纹、命令使用 monospaced 字体。
- 统一 8pt 间距网格，圆角分为 10/14/20 三档。
- 新增可复用组件：`GlassSurface`、`GlassCard`、`GlassButtonStyle`、`StatusBadge`、`ActivityPulse`、`WorkspaceHeader`、`ContextRail`。
- 每个状态都同时依赖文字、图标和色彩，不只依赖色彩。

## 应用外壳

`RootView` 继续使用 `NavigationSplitView`，以降低导航与键盘行为风险；视觉上改为 Glass Workbench shell。

- Sidebar 变为半透明 rail：品牌区、按类别分组的工具导航、底部设置和更新入口。
- Detail 顶部增加 `WorkspaceHeader`：breadcrumb、任务/连接状态、页面级快捷操作和主题切换入口。
- 工具切换采用 380ms 分层滑入/淡入：header 先出现、内容随后出现；Reduce Motion 时退化为短淡入。
- 自适应窗口宽度：窄窗口收缩 rail 文字与 context rail，主画布始终优先保留。

## 工具工作台

所有工具共享“主画布 + 右侧 context rail + activity/log”语言，但根据任务类型调整布局。

### 重签

- 从长表单改为阶段画布：输入 IPA → 证书与权限 → 校验与导出。
- 保留现有字段、文件选择、预览、编辑 entitlement、动态库注入与错误 alert。
- 当前任务摘要固定显示 profile、证书、目标 Bundle ID、权限改写数和输出位置。
- `LogPanelView` 成为 task activity 区的一部分；运行中显示脉冲进度和简短状态，完成后自然落入可展开的完整日志。
- 不修改 `ResignTask` 后端选择或签名/校验步骤。

### 设备

- 设备页按“设备 rail / 主内容 / 连接 context rail”组织。
- 在线、连接中、错误和传输中使用一致状态 badge 与低频 pulse。
- 应用列表、沙盒浏览和文件预览保留原行为；文件操作改为悬浮 action bar 与队列化进度卡。

### 互传

- 会话状态成为页首主内容：连接对象、信任状态、网络质量与当前任务一眼可见。
- 文件队列用可折叠的 activity cards 展示；完成项收拢至历史区，失败项保留可重试操作。
- 不改变配对、指纹验证、重连和网络传输实现。

### 二维码、设置与更新

- 二维码使用中心画布与右侧说明/最近记录，突出扫描或分享的主要动作。
- 设置改为分组的 glass preference cards，保存即时生效，并在复杂项显示变更摘要。
- 更新页以版本、变更摘要和下载/安装状态为中心，避免将它设计成通用仪表盘。

## 动效与可访问性

| 场景 | 动效 | 时长 |
| --- | --- | --- |
| 按钮、列表 hover | 高光与 1–2pt 位移 | 160ms |
| 卡片展开、popover | 透明度 + 轻微缩放 | 240ms |
| 工具切换 | 分层滑入和淡入 | 380ms |
| 签名/传输/扫描中 | 低频状态脉冲 | 1.8s 循环 |

- 所有连续动画仅在任务活跃时运行，离开页面立即停止。
- 使用 `accessibilityReduceMotion` 将转场退化为短淡入，并禁用流动高光/脉冲扩散。
- 保留现有 `KeyboardShortcut`、macOS focus ring、文本选择与 VoiceOver label。

## 实现边界

1. 新增 `Core/UI/GlassDesignSystem.swift` 和小型可组合视图文件；不引入第三方 UI 依赖。
2. 优先拆分超大的 SwiftUI 文件，将样式从业务回调中移出；服务仍通过现有 `ServiceHub` 注入。
3. 业务状态、后台队列、错误 alert 和任务生命周期维持现状。仅在呈现层新增可视状态映射。
4. 所有深浅主题颜色使用 token，禁止业务页面硬编码颜色；仅状态色可引用 token 的语义名称。

## 验证

- 在深色、浅色与 Reduce Motion 下逐页检查：重签、设备、互传、二维码、设置、更新。
- 验证窗口窄宽、长日志、多设备和多文件传输的布局不截断关键操作。
- 运行现有独立 Swift 测试、zsign 集成检查和 Debug/Release 构建。
- 对重签、设备文件操作与互传进行手动 smoke test，确认视觉重构未改变业务调用和错误处理。

## 非目标

- 不重写签名策略、描述文件 entitlement 规则或 Vendor/ZSign。
- 不改写 MobileDevice/AFC/HouseArrest/InstallationProxy 协议实现。
- 不改变配对安全模型、持久化格式或最近文件业务规则。
- 不引入 WebView、图像资源包或外部 UI 框架。
