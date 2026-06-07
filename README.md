# EasySign

> macOS 上的开发者日常工具集。最初是一个 iOS IPA 重签名工具,现已演进为承载多种日常工具的工具箱 —— 重签、二维码、连接设备文件浏览、两台电脑互传。侧边栏选择工具,窗口可自由缩放,菜单栏常驻。

## 工具一览

| 工具 | 作用 |
|---|---|
| **重签** | 为 IPA / `.app` 重签名并导出(改 Bundle ID/版本、编辑 entitlements、动态库注入、5 种导出类型) |
| **二维码** | 生成与扫描二维码 |
| **设备** | 浏览已连接 iOS 设备的文件(包括 App 沙盒),支持导入/导出 |
| **互传** | 两台电脑在局域网内直连,互传文本、文件、剪贴板图片(配对 + 加密) |

---

## 下载安装

到 [Releases](https://github.com/crazyball666/EasySign/releases/latest) 下载最新的 `EasySign-x.y.z.dmg`,打开后把 **EasySign 拖进「应用程序」**。

> **⚠️ 未签名分发说明**:本应用未做 Apple 代码签名/公证(个人项目,不办开发者账号)。从浏览器下载的 dmg 里的 app 会被 Gatekeeper 标记,首次打开请**右键 →「打开」**;若提示「已损坏」,在终端执行:
> ```bash
> xattr -dr com.apple.quarantine /Applications/EasySign.app
> ```
> (通过应用内"检查更新"下载的包会自动去除该标记,无需手动处理。)

## 应用内更新

菜单 **EasySign →「检查更新…」**(或在设置里开启"启动时自动检查")。应用会检查 GitHub 最新 Release,发现新版时弹窗显示更新说明,点"下载更新"即在应用内下载并自动挂载 dmg,你再拖进「应用程序」覆盖即可。

## 系统要求

- macOS 13.0+
- 源码编译需 Xcode 15+ 与 Command Line Tools

---

## 从源码编译

```bash
# Xcode 打开
open EasySign.xcodeproj

# 或命令行
xcodebuild -project EasySign.xcodeproj -scheme EasySign -configuration Debug build
xcodebuild -project EasySign.xcodeproj -scheme EasySign -configuration Release build
```

工程使用 Xcode 16 的文件系统同步分组(`PBXFileSystemSynchronizedRootGroup`),`EasySign/` 下新增 `.swift` 自动纳入 target,无需手改 `project.pbxproj`。纯逻辑测试位于 `Tests/`,是独立的 `@main` 可执行(用 `swiftc` 编译运行),非 XCTest target。

---

## 架构

三层结构,依赖只向下流:**App(应用外壳)→ Features(各工具 UI)→ Core(底层引擎/服务)**。工具通过统一的 `Tool` 协议接入,在 `ToolRegistry` 静态注册,共享服务由 `ServiceHub` 依赖注入。新增工具 = 实现一个 `Tool` + 一个视图,注册即出现在侧边栏。

```
EasySign/
├── App/                     # 入口、侧边栏、菜单栏常驻、设置、更新 UI
├── Features/                # 各工具的视图
│   ├── Resign/              #   重签
│   ├── QRCode/              #   二维码
│   ├── Devices/             #   设备文件浏览
│   └── Transfer/            #   互传
├── Core/                    # 底层引擎与服务(不含 UI)
│   ├── Toolkit/             #   Tool 协议 / ToolRegistry / ServiceHub
│   ├── Resigning/           #   重签核心(IPA/AppBundle/ResignTask/PKCS12/MobileProvision/zsign 桥接)
│   ├── Devices/             #   设备通信(MobileDevice.framework + 自实现 AFC / HouseArrest)
│   ├── Transfer/            #   互传(TLS 安全通道、配对、文件/剪贴板传输)
│   ├── QR/                  #   二维码生成/扫描
│   ├── Update/              #   应用内更新检查(SemanticVersion / GitHubReleaseParser / UpdateService)
│   ├── Storage/             #   设置、最近文件、产物存储
│   ├── Logging/             #   日志
│   └── UI/                  #   通用 UI 组件、Keychain 封装
├── Resources/resign_template/   # xcarchive 导出模板
└── Vendor/                  # 内置 OpenSSL.xcframework + 内嵌 zsign 源码
.github/workflows/release.yml     # 推 tag 自动构建并发布
```

---

## 工具详情

### 重签

为 IPA 或 `.app` 重签名并导出。

- 修改应用元数据:Bundle ID、应用名称、版本号、构建号
- 编辑 entitlements 权限
- App Extension(Appex)统一使用主 App 证书重签
- 两套后端:系统 `codesign` 与内嵌 `zsign`(默认 zsign)
- 动态库注入:选择/粘贴自定义 `.dylib`,注入主 App 可执行文件(通过内嵌 zsign 写入 Mach-O load command)
- 5 种导出类型:

| 类型 | 说明 | get-task-allow | beta-reports-active |
|------|------|----------------|---------------------|
| App Store | 发布到 App Store | false | true |
| Development | 开发测试 | true | - |
| Ad-Hoc | 内测分发 | true | true |
| Enterprise | 企业证书 | true | true |
| Validation | 校验模式 | true | true |

**重签流程**(`ResignTask.start()`):解压 IPA → 解析 `.app` → 更新元数据 → 清理 `.DS_Store`/`__MACOSX` →(可选)注入 dylib → 安装 P12/描述文件 → 重签 dylib/framework → 重签 Appex → 按导出类型调整 entitlements → 重签主 App → 拷入 xcarchive 模板并 `xcodebuild -exportArchive` 导出 IPA。

### 设备

浏览已连接 iOS 设备的文件,基于系统 `MobileDevice.framework` + 自实现的 AFC / HouseArrest 协议(不依赖 libimobiledevice)。可浏览设备目录与 App 沙盒、预览文件、在设备与本机之间导入/导出。

### 互传

两台电脑(目前为两台 Mac)在**同一局域网内直连**互传,绕开 AirDrop 限制:

- **自动发现**:Bonjour 发现同网设备(可关广播进入隐身模式);也支持手动输 IP
- **配对 + 加密**:首次用 6 位配对码配对,配对码经 HMAC 绑定双方证书指纹**防中间人**;传输走自签 TLS,仅放行已配对设备的证书指纹(防陌生机器接入)
- **共享剪贴板**:开关控制,文本/图片双向自动同步(防回环、跳过密码管理器的机密复制)
- **文件传输**:拖拽/选择发送,走加密通道的二进制分块流式传输,已配对自动接收到收件箱
- **双向历史**:收发记录持久化,文件可打开/在 Finder 显示,图片有缩略图
- **菜单栏常驻**:关主窗口后仍在后台工作

> 互传为个人局域网工具,安全模型假定两台已配对机器可信、同网其它机器不可信;不做公网穿透/云中转。

---

## 发版流程

版本号以 git tag 为唯一来源,CI 构建时自动注入,**无需手改工程版本号**:

```bash
git tag vX.Y.Z
git push origin vX.Y.Z
```

推送 `v*` tag 后,GitHub Actions(`.github/workflows/release.yml`)自动在 `macos-14` 上构建未签名 Release 版 → 用 `create-dmg` 打包(失败回退 `hdiutil`)→ 创建 GitHub Release 并上传 `EasySign-<版本>.dmg`(自动生成更新日志)。用户端通过"检查更新"即可获取。

---

## 技术栈

- **Swift / SwiftUI / AppKit** —— 界面与应用外壳
- **Network.framework** —— 互传的 TLS + WebSocket 安全通道、Bonjour 发现
- **CryptoKit / Security.framework** —— 配对 HMAC、证书指纹、自签身份、Keychain
- **MobileDevice.framework** —— 设备通信(配合自实现 AFC/HouseArrest)
- **OpenSSL.xcframework + 内嵌 zsign** —— 重签、打包与 Mach-O dylib 注入
- **CryptoSwift**(SPM)—— 重签相关摘要计算
- **GitHub Actions** —— 推 tag 自动发布
