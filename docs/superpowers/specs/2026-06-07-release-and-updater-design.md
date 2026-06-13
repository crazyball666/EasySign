# GitHub 自动发布 + 应用内更新检查设计

- 日期:2026-06-07
- 状态:设计已确认,待编写实现计划
- 仓库:`github.com/crazyball666/EasySign`(公开)

## 1. 背景与目标

让 EasySign 的发版与更新自动化:

1. **推 tag 自动发布**:`git push origin v1.0.3` → GitHub Actions 自动构建 Release 版、打成 `.dmg`、创建 GitHub Release 并上传安装包。
2. **应用内更新检查**:App 检查 GitHub 最新 Release 版本,有新版则提示 + 应内下载 `.dmg` + 挂载/Finder 打开,用户拖进 Applications 覆盖更新。

### 已确认决策

| 维度 | 决策 |
|---|---|
| 代码签名 | **不签名 / ad-hoc**(`CODE_SIGN_IDENTITY="-"`);无 Apple Developer 账号、无公证 |
| 更新机制 | **自研轻量更新器**(非 Sparkle —— Sparkle 需 App 签名才能可靠自动替换) |
| 更新体验 | 应内**下载 `.dmg`(带进度)→ 去 quarantine → 挂载/Finder 打开** → 用户手动拖进 Applications |
| 版本来源 | **直接用 GitHub Release API**(`/releases/latest`),不自建 appcast/manifest |
| 分发格式 | **`.dmg`**(带"拖到 Applications"窗口) |
| 仓库可见性 | **公开** → 更新器无需 token |
| 自动检查 | 启动时自动检查(默认开,可在设置关),节流 24h;另有手动"检查更新…" |
| 版本号 | 从 git tag 注入(`MARKETING_VERSION`),不手改工程 |

### 非目标(YAGNI)

- 不做 Developer ID 签名/公证(架构不为此预留复杂分支;以后要加另议)。
- 不做准自动替换(下载→退出→替换 .app→重启);未签名下 Gatekeeper/quarantine 摩擦大、易出错。
- 不做增量/delta 更新、不做多渠道(beta/stable)、不自建更新服务器。
- 不做 App Store 分发。

### 关键前提

- 工程版本号已参数化:`MARKETING_VERSION = 1.0.2`、`CURRENT_PROJECT_VERSION = 1`,`Info.plist` 用 `$(MARKETING_VERSION)` / `$(CURRENT_PROJECT_VERSION)`,故可由 CI 用 `xcodebuild` 命令行覆盖,无需改工程文件。
- App **未开启沙盒**(`EasySign.entitlements` 为空)→ 更新器可自由发起网络请求、写下载文件、`NSWorkspace.open`、`xattr` 去 quarantine。
- 部署目标 macOS 13.0。

## 2. Part 1 — GitHub Actions 发布 workflow

新增 `.github/workflows/release.yml`。

**触发与环境:**
```yaml
on:
  push:
    tags: ['v*']
permissions:
  contents: write
jobs:
  release:
    runs-on: macos-14    # Apple Silicon;Release 默认构建 arm64+x86_64 通用
```

**步骤:**
1. `actions/checkout@v4`
2. 选定 Xcode:`maxim-lobanov/setup-xcode@v1`(锁定一个稳定版本,如 `^15` / 16,执行时按 runner 可用版本定)
3. 取版本:`VERSION=${GITHUB_REF_NAME#v}`(`v1.0.3` → `1.0.3`)
4. 构建(未签名):
   ```bash
   xcodebuild -project EasySign.xcodeproj -scheme EasySign -configuration Release \
     -derivedDataPath build \
     MARKETING_VERSION=$VERSION CURRENT_PROJECT_VERSION=$GITHUB_RUN_NUMBER \
     CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
     build
   ```
   产物:`build/Build/Products/Release/EasySign.app`
5. 打 `.dmg`:`brew install create-dmg`,生成带 Applications 拖拽别名的窗口:
   ```bash
   create-dmg --volname "EasySign $VERSION" --app-drop-link 450 180 \
     "EasySign-$VERSION.dmg" "build/Build/Products/Release/EasySign.app"
   ```
   兜底(create-dmg 失败时):`hdiutil create -volname "EasySign $VERSION" -srcfolder <staging> -ov -format UDZO "EasySign-$VERSION.dmg"`(staging 内含 `.app` + `/Applications` 符号链接)。
6. 发布:
   ```yaml
   - uses: softprops/action-gh-release@v2
     with:
       tag_name: ${{ github.ref_name }}
       generate_release_notes: true
       files: EasySign-*.dmg
   ```

**结果:** 每个 `v*` tag → 一个 Release,挂 `EasySign-<版本>.dmg`,自动生成更新日志。更新器即读取此 Release。

**错误处理:** 构建失败 / 打包失败 → workflow 失败,不创建 Release(`action-gh-release` 在前置步骤失败时不执行)。tag 命名须为 `vX.Y.Z`。

## 3. Part 2 — 应用内更新器

沿用 App / Core 分层,新增**应用级**更新服务(非 Tool)。

```
EasySign/Core/Update/
  SemanticVersion.swift   纯逻辑:解析/比较 "X.Y.Z";处理前缀 v、缺位、非法
  UpdateInfo.swift        模型:version:String / releaseNotes:String / dmgURL:URL / publishedAt:Date?
  UpdateService.swift     ObservableObject:检查 / 下载 / 打开;@Published 状态
EasySign/App/
  UpdateView.swift        更新 sheet:版本 + 更新日志 + 下载按钮 + 进度 + quarantine 提示
  EasySignApp.swift       +菜单命令 "检查更新…"(CommandGroup);启动触发自动检查
  SettingsView.swift      +"启动时自动检查更新" 开关(默认开)
EasySign/Core/Toolkit/
  ServiceKey.swift / ServiceHub.swift   +case update / let update: UpdateService
```

### UpdateService 接口与行为

```
@Published var availableUpdate: UpdateInfo?     // 有新版时非 nil
@Published var downloadProgress: Double?        // 下载中 0...1,否则 nil
@Published var lastCheckError: String?          // 手动检查失败提示
@Published var isChecking: Bool

func checkForUpdates(silent: Bool)              // silent=true 自动(失败不打扰)
func startDownload()                            // 下载 availableUpdate.dmgURL
func maybeAutoCheckOnLaunch()                   // 开关开 && 距上次>24h 才查
```

- **检查**:`GET https://api.github.com/repos/crazyball666/EasySign/releases/latest`(`Accept: application/vnd.github+json`)。解析 `tag_name`、`body`(更新日志)、`assets[]` 中后缀 `.dmg` 的 `browser_download_url`、`published_at`。用 `SemanticVersion(tag_name)` 与 `Bundle.main` 的 `CFBundleShortVersionString` 比较,更高则置 `availableUpdate`。
- **节流**:`UserDefaults` 存 `update.lastCheckAt`;`maybeAutoCheckOnLaunch` 距上次 <24h 则跳过。设置键 `update.autoCheckEnabled`(默认 true)。
- **下载**:`URLSession` download task,`URLSessionDownloadDelegate` 报进度 → `downloadProgress`。完成后把临时文件移到 **`~/Downloads/EasySign-<版本>.dmg`**(用户可见、可复用;同名已存在则覆盖),对该文件 `xattr -d com.apple.quarantine`(尽力,失败不阻断),再 `NSWorkspace.shared.open(dmgURL)` 挂载。
- **取消**:下载中可取消(置 progress nil、cancel task)。

### UI / 接线

- **菜单命令**:`EasySignApp` 用 `.commands { CommandGroup(after: .appInfo) { Button("检查更新…") { hub.update.checkForUpdates(silent: false) } } }`。因 App 菜单栏常驻、主窗口可能已关,菜单命令在触发检查前先 `openWindow(id:"main")` 把主窗口带出来,保证 sheet/提示有宿主。
- **更新 sheet**(`UpdateView`):绑定 `hub.update`;当 `availableUpdate != nil` 时由主窗口 `.sheet` 呈现,显示新版本号、`releaseNotes`(可滚动)、"下载更新"按钮(下载中显示进度条 + 取消)、底部 quarantine 提示。下载完成挂载后可关闭。
- **手动检查反馈**:`checkForUpdates(silent:false)` 若已是最新 → 一个"已是最新版本"提示;失败 → `lastCheckError` 弹出。
- **设置**:`SettingsView` 在"通用/关于"区加"启动时自动检查更新"开关(绑定 `update.autoCheckEnabled`)。
- **启动触发**:`EasySignApp` 启动后调用 `hub.update.maybeAutoCheckOnLaunch()`。

### 错误处理与边界

| 情况 | 处理 |
|---|---|
| 无网络 / 请求失败 | silent:不打扰;manual:`lastCheckError` 友好提示,可重试 |
| latest 无 .dmg 资产 | "暂无可用安装包(请稍后再试)" |
| API 限流 403 / 超时 | 捕获,友好提示,不崩 |
| 版本号解析失败 | `SemanticVersion` 返回 nil → 视为无更新(不误报) |
| 已是最新 / 更旧 | 不弹更新;manual 提示"已是最新" |
| 下载失败 / 中断 | 进度清零 + 错误提示 + 可重试 |
| quarantine 拦截 | 下载的 .dmg 先去 quarantine;sheet 提示右键打开 / `xattr -dr` 命令 |

### 测试

- **纯逻辑(独立 `@main` swiftc 测试)**:
  - `SemanticVersion`:`1.0.10 > 1.0.9`、`v1.2.0 == 1.2.0`、缺位 `1.2 < 1.2.1`、非法返回 nil、与当前版本比较的 `isNewer(than:)`。
  - GitHub release JSON 解析:喂一段固定的 `releases/latest` 响应 JSON,断言解析出 `tag_name`/`.dmg url`/`body`;断言无 .dmg 资产时返回 nil。
- **构建门**:`xcodebuild ... build` 通过。
- **手动 E2E**:发一个测试 tag → workflow 出 Release → App 手动"检查更新"能发现、下载、挂载。

## 4. 发版流程(交付后)

1. 改完代码、确定版本号 `X.Y.Z`。
2. `git tag vX.Y.Z && git push origin vX.Y.Z`。
3. GitHub Actions 自动构建 + 发 Release(挂 `.dmg`)。
4. 用户端 App 启动自动检查(或手动)→ 发现新版 → 下载 → 拖进 Applications。

## 5. 与现有架构的契合

- `UpdateService` 注入 `ServiceHub`,与 `transfer`/`logger` 等并列;UI 走 App 层(菜单命令 + sheet + Settings),与互传菜单栏等应用级 chrome 一致。
- `SemanticVersion`/JSON 解析为纯逻辑,沿用仓库"独立 `@main` swiftc 测试"约定([[testing-convention]])。
- 未签名/quarantine 的取舍已在设计中显式说明,不隐藏代价。

## 6. Phase 2 — 自动安装 + 重启(2026-06-13 增补)

Phase 1 把「准自动替换」列为 YAGNI(未签名下 Gatekeeper 摩擦)。Phase 2 在**仍不签名**的前提下补上「一键安装并重启」:关键是替换后对**新 bundle 去 quarantine**,使重启不被 Gatekeeper 拦(与 Phase 1 去 DMG quarantine 同理)。已确认并接受的取舍:自动运行的是未签名下载物,仅靠 HTTPS + GitHub 兜底(无签名校验);确认走「路 2」。

**触发**:一键确认 —— 下载完按钮变「安装并重启」,点击才退出重启(不全自动,避免突然掩掉进行中的工作)。

### 新增 `EasySign/Core/Update/AppInstaller.swift`
- `isTranslocated(bundleURL)`:路径含 `/AppTranslocation/` → App 未正经装入,只读路径无法替换。
- `canSelfReplace()`:非 translocation 且安装目录可写。
- `mountAndStage(dmg)`:`hdiutil attach -nobrowse -mountpoint` → 找 `.app` → 校验 `CFBundleIdentifier` 与本机一致(防呆)→ `ditto` 到临时 staging → `hdiutil detach`,返回 staged。
- `installerScript(pid,staged,dest,stagingDir)`:**纯文本**,生成「等 PID 退出 → `mv dest→.bak` → `ditto staged→dest` → 成功则去 quarantine + 删 .bak / 失败则回滚 → `open dest` → 删 staging」的脱壳脚本(路径单引号转义)。
- `installAndRelaunch(staged)`:写脚本到 temp,`/bin/sh` **分离启动**(不 wait),`NSApp.terminate`。

### `UpdateService` / `UpdateView` 变更
- 下载完成:落 Downloads + 去 quarantine 后,若 `canSelfReplace()` 且 `mountAndStage` 成功 → 置 `@Published readyToInstall=true` + 暂存 staged;否则回退到原 `NSWorkspace.open(dmg)`(`installerOpened=true`,显示「拖进应用程序」)。
- 新增 `func installAndRelaunch()`;`UpdateView` 加 `readyToInstall` 分支(「安装并重启」/「以后再说」)。

### 测试
- 纯逻辑(独立 swiftc):`isTranslocated`(转移/正常路径)、`installerScript`(备份/回滚/去 quarantine/带空格路径引用)。
- 挂载/替换/重启:**需真机手动 E2E**(装入 `/Applications`,发测试 tag 走一遍);编译 + 纯逻辑测试 + 审查为自动门槛。
