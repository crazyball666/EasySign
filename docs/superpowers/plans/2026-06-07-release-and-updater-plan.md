# GitHub 自动发布 + 应用内更新器 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 推 `v*` tag 自动构建并发布 `.dmg` 到 GitHub Release;App 内检查 GitHub 最新 Release,有新版则下载 `.dmg` 并挂载,用户拖进 Applications 更新。

**Architecture:** 两部分。(1) `.github/workflows/release.yml` 在 tag 推送时用 `xcodebuild`(未签名)构建 → `create-dmg` 打包 → `action-gh-release` 发布。(2) `Core/Update/` 三个文件(纯逻辑 `SemanticVersion`、`GitHubReleaseParser`/`UpdateInfo`、网络层 `UpdateService`)+ App 层 UI(菜单命令、sheet、设置开关),`UpdateService` 注入 `ServiceHub`。

**Tech Stack:** GitHub Actions(macos-14 runner)/ `xcodebuild` / `create-dmg` / `softprops/action-gh-release` / Swift / SwiftUI / `URLSession`(下载 + 进度)/ GitHub Release REST API。

---

## 范围与测试约定

单一计划,两部分各自可独立验收。本仓库**无 XCTest target**;纯逻辑用 `Tests/` 下独立 `@main` swiftc 可执行测试(`swiftc -O -parse-as-library <impl> <test> -o /tmp/x && /tmp/x`,见 [[testing-convention]]);网络/UI/CI 用「编译/语法门 + 手动 E2E」。仓库公开,更新器无需 token。固定常量:仓库 `crazyball666/EasySign`。

## File Structure

新建:
```
.github/workflows/release.yml                推 tag 构建+打 dmg+发 Release
EasySign/Core/Update/SemanticVersion.swift   纯逻辑:解析/比较 X.Y.Z
EasySign/Core/Update/UpdateInfo.swift         模型 + GitHubReleaseParser(纯逻辑 JSON 解析)
EasySign/Core/Update/UpdateService.swift      NSObject/ObservableObject:检查/下载/打开
EasySign/App/UpdateView.swift                 更新 sheet UI
Tests/SemanticVersionTests.swift
Tests/GitHubReleaseParserTests.swift
```
修改:
```
EasySign/Core/Toolkit/ServiceKey.swift        +case update
EasySign/Core/Toolkit/ServiceHub.swift        +let update + live() 构造 + subscript
EasySign/App/EasySignApp.swift                +菜单命令 + 启动自动检查 + 主窗口 sheet
EasySign/App/SettingsView.swift               +"启动时自动检查更新" 开关
```

---

## Task 1: GitHub Actions 发布 workflow

无法在本地真实跑 GHA;验收 = YAML 语法通过 + 推一个 tag 实测(Task 6)。

**Files:**
- Create: `.github/workflows/release.yml`

- [ ] **Step 1: 写 workflow**

`.github/workflows/release.yml`:
```yaml
name: Release

on:
  push:
    tags:
      - 'v*'

permissions:
  contents: write

jobs:
  release:
    runs-on: macos-14
    steps:
      - uses: actions/checkout@v4

      - name: Select Xcode
        uses: maxim-lobanov/setup-xcode@v1
        with:
          xcode-version: latest-stable

      - name: Derive version from tag
        id: ver
        run: echo "version=${GITHUB_REF_NAME#v}" >> "$GITHUB_OUTPUT"

      - name: Build (unsigned, Release)
        run: |
          xcodebuild -project EasySign.xcodeproj -scheme EasySign -configuration Release \
            -derivedDataPath build \
            MARKETING_VERSION=${{ steps.ver.outputs.version }} \
            CURRENT_PROJECT_VERSION=${{ github.run_number }} \
            CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
            build

      - name: Package .dmg
        run: |
          brew install create-dmg
          APP="build/Build/Products/Release/EasySign.app"
          DMG="EasySign-${{ steps.ver.outputs.version }}.dmg"
          create-dmg \
            --volname "EasySign ${{ steps.ver.outputs.version }}" \
            --app-drop-link 450 180 \
            --window-size 660 400 \
            "$DMG" "$APP" \
          || hdiutil create -volname "EasySign ${{ steps.ver.outputs.version }}" \
               -srcfolder "$APP" -ov -format UDZO "$DMG"

      - name: Publish Release
        uses: softprops/action-gh-release@v2
        with:
          tag_name: ${{ github.ref_name }}
          generate_release_notes: true
          files: EasySign-*.dmg
```
> 注:`create-dmg` 偶尔对单 `.app` 源目录报非零(它会把源目录整个放进 dmg)。若实测 create-dmg 行为不符,改为先把 `.app` 拷进一个 staging 目录再传该目录给 create-dmg;`|| hdiutil ...` 兜底已能产出可用 dmg。执行 Task 6 时以真实 runner 行为为准微调。

- [ ] **Step 2: 校验 YAML 语法**

Run:
```bash
python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/release.yml')); print('YAML OK')"
```
Expected: `YAML OK`

- [ ] **Step 3: Commit**
```bash
git add .github/workflows/release.yml
git commit -m "ci(release): build + dmg + GitHub Release on tag push"
```

---

## Task 2: SemanticVersion(纯逻辑,TDD)

**Files:**
- Create: `EasySign/Core/Update/SemanticVersion.swift`
- Test: `Tests/SemanticVersionTests.swift`

- [ ] **Step 1: 写失败测试**

`Tests/SemanticVersionTests.swift`:
```swift
import Foundation

@main
struct SemanticVersionTests {
    static func main() {
        // 解析:去 v 前缀、缺位补 0
        expect(SemanticVersion("v1.2.3") == SemanticVersion("1.2.3"), "v-prefix")
        expect(SemanticVersion("1.2")?.patch == 0, "missing patch → 0")
        expect(SemanticVersion("1")?.minor == 0, "missing minor → 0")
        // 非法 → nil
        expect(SemanticVersion("abc") == nil, "invalid nil")
        expect(SemanticVersion("") == nil, "empty nil")
        // 比较:数值而非字典序
        expect(SemanticVersion("1.0.10")! > SemanticVersion("1.0.9")!, "10 > 9 numeric")
        expect(SemanticVersion("1.2.0")! > SemanticVersion("1.1.9")!, "minor wins")
        expect(SemanticVersion("2.0.0")! > SemanticVersion("1.9.9")!, "major wins")
        expect(SemanticVersion("1.2.3")! == SemanticVersion("1.2.3")!, "equal")
        // isNewer / displayString
        expect(SemanticVersion("1.0.3")!.isNewer(than: SemanticVersion("1.0.2")!), "isNewer")
        expect(!SemanticVersion("1.0.2")!.isNewer(than: SemanticVersion("1.0.2")!), "same not newer")
        expect(SemanticVersion("v1.0.3")!.displayString == "1.0.3", "displayString")
        print("ALL PASS")
    }
    static func expect(_ c: Bool, _ m: String) {
        if !c { FileHandle.standardError.write(Data("FAIL: \(m)\n".utf8)); exit(1) }
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run:
```bash
swiftc -O -parse-as-library Tests/SemanticVersionTests.swift -o /tmp/sv 2>&1 | tail -3
```
Expected: 编译失败 `cannot find 'SemanticVersion' in scope`。

- [ ] **Step 3: 实现**

`EasySign/Core/Update/SemanticVersion.swift`:
```swift
import Foundation

/// 语义版本号 X.Y.Z(容忍前缀 v、缺位补 0;非法返回 nil)。
struct SemanticVersion: Comparable, Equatable {
    let major: Int
    let minor: Int
    let patch: Int

    init?(_ string: String) {
        var s = string.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        guard !s.isEmpty else { return nil }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 1, parts.count <= 3 else { return nil }
        var nums = [0, 0, 0]
        for (i, p) in parts.enumerated() {
            guard let n = Int(p), n >= 0 else { return nil }
            nums[i] = n
        }
        major = nums[0]; minor = nums[1]; patch = nums[2]
    }

    var displayString: String { "\(major).\(minor).\(patch)" }

    func isNewer(than other: SemanticVersion) -> Bool { self > other }

    static func < (l: SemanticVersion, r: SemanticVersion) -> Bool {
        (l.major, l.minor, l.patch) < (r.major, r.minor, r.patch)
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run:
```bash
swiftc -O -parse-as-library EasySign/Core/Update/SemanticVersion.swift Tests/SemanticVersionTests.swift -o /tmp/sv && /tmp/sv
```
Expected: `ALL PASS`

- [ ] **Step 5: Commit**
```bash
git add EasySign/Core/Update/SemanticVersion.swift Tests/SemanticVersionTests.swift
git commit -m "feat(update): add SemanticVersion + tests"
```

---

## Task 3: UpdateInfo + GitHubReleaseParser(纯逻辑,TDD)

**Files:**
- Create: `EasySign/Core/Update/UpdateInfo.swift`
- Test: `Tests/GitHubReleaseParserTests.swift`

- [ ] **Step 1: 写失败测试**

`Tests/GitHubReleaseParserTests.swift`:
```swift
import Foundation

@main
struct GitHubReleaseParserTests {
    static func main() throws {
        let json = """
        {
          "tag_name": "v1.0.3",
          "body": "修复若干问题\\n- a\\n- b",
          "published_at": "2026-06-07T10:00:00Z",
          "assets": [
            { "name": "EasySign-1.0.3.dmg", "browser_download_url": "https://github.com/crazyball666/EasySign/releases/download/v1.0.3/EasySign-1.0.3.dmg" },
            { "name": "source.zip", "browser_download_url": "https://example.com/x.zip" }
          ]
        }
        """
        let p = try GitHubReleaseParser.parse(Data(json.utf8))
        expect(p.tagName == "v1.0.3", "tagName")
        expect(p.body.contains("修复若干问题"), "body")
        expect(p.dmgURL?.absoluteString.hasSuffix("EasySign-1.0.3.dmg") == true, "dmg url picked")
        expect(p.publishedAt != nil, "date parsed")

        // 无 .dmg 资产 → dmgURL nil(body 缺失 → 空串)
        let noDmg = """
        { "tag_name": "v1.0.4", "assets": [ { "name": "x.zip", "browser_download_url": "https://e/x.zip" } ] }
        """
        let p2 = try GitHubReleaseParser.parse(Data(noDmg.utf8))
        expect(p2.dmgURL == nil, "no dmg → nil")
        expect(p2.body == "", "missing body → empty")

        // 坏 JSON → 抛错
        do { _ = try GitHubReleaseParser.parse(Data("not json".utf8)); fail("should throw") } catch {}
        print("ALL PASS")
    }
    static func expect(_ c: Bool, _ m: String) { if !c { fail(m) } }
    static func fail(_ m: String) -> Never { FileHandle.standardError.write(Data("FAIL: \(m)\n".utf8)); exit(1) }
}
```

- [ ] **Step 2: 运行确认失败**

Run:
```bash
swiftc -O -parse-as-library Tests/GitHubReleaseParserTests.swift -o /tmp/gh 2>&1 | tail -3
```
Expected: 编译失败 `cannot find 'GitHubReleaseParser' in scope`。

- [ ] **Step 3: 实现**

`EasySign/Core/Update/UpdateInfo.swift`:
```swift
import Foundation

/// 一个可用更新的展示信息。
struct UpdateInfo: Equatable, Identifiable {
    var id: String { version }
    let version: String        // 规范化版本,如 "1.0.3"
    let releaseNotes: String
    let dmgURL: URL
    let publishedAt: Date?
}

/// 纯逻辑:把 GitHub `/releases/latest` 的 JSON 解析成可用字段。
enum GitHubReleaseParser {
    struct Parsed: Equatable {
        let tagName: String
        let body: String
        let dmgURL: URL?
        let publishedAt: Date?
    }

    private struct Release: Decodable {
        let tag_name: String
        let body: String?
        let published_at: String?
        let assets: [Asset]?
        struct Asset: Decodable { let name: String; let browser_download_url: String }
    }

    static func parse(_ data: Data) throws -> Parsed {
        let r = try JSONDecoder().decode(Release.self, from: data)
        let dmgAsset = (r.assets ?? []).first { $0.name.lowercased().hasSuffix(".dmg") }
        let dmgURL = dmgAsset.flatMap { URL(string: $0.browser_download_url) }
        let date = r.published_at.flatMap { ISO8601DateFormatter().date(from: $0) }
        return Parsed(tagName: r.tag_name, body: r.body ?? "", dmgURL: dmgURL, publishedAt: date)
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run:
```bash
swiftc -O -parse-as-library EasySign/Core/Update/UpdateInfo.swift Tests/GitHubReleaseParserTests.swift -o /tmp/gh && /tmp/gh
```
Expected: `ALL PASS`

- [ ] **Step 5: Commit**
```bash
git add EasySign/Core/Update/UpdateInfo.swift Tests/GitHubReleaseParserTests.swift
git commit -m "feat(update): add UpdateInfo + GitHubReleaseParser + tests"
```

---

## Task 4: UpdateService + ServiceHub 接线(编译门)

**Files:**
- Create: `EasySign/Core/Update/UpdateService.swift`
- Modify: `EasySign/Core/Toolkit/ServiceKey.swift`
- Modify: `EasySign/Core/Toolkit/ServiceHub.swift`

- [ ] **Step 1: 实现 UpdateService**

`EasySign/Core/Update/UpdateService.swift`:
```swift
import Foundation
import AppKit

/// 应用内更新:检查 GitHub 最新 Release、下载 .dmg、去 quarantine、挂载。
final class UpdateService: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let repo = "crazyball666/EasySign"

    @Published var availableUpdate: UpdateInfo?
    @Published var downloadProgress: Double?     // 0...1 下载中,否则 nil
    @Published var isChecking = false
    @Published var lastCheckError: String?
    @Published var upToDateNotice = false         // 手动检查且已是最新 → true(UI 弹一下)

    private let defaults = UserDefaults.standard
    private let lastCheckKey = "update.lastCheckAt"
    private let autoCheckKey = "update.autoCheckEnabled"
    private var session: URLSession!
    private var downloadTask: URLSessionDownloadTask?

    let logger: LoggerService

    init(logger: LoggerService) {
        self.logger = logger
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }

    var autoCheckEnabled: Bool {
        get { defaults.object(forKey: autoCheckKey) == nil ? true : defaults.bool(forKey: autoCheckKey) }
        set { defaults.set(newValue, forKey: autoCheckKey) }
    }

    private var currentVersion: SemanticVersion? {
        SemanticVersion(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0")
    }

    /// 启动时调用:开关开 && 距上次检查 >24h 才静默检查。
    func maybeAutoCheckOnLaunch() {
        guard autoCheckEnabled else { return }
        if let last = defaults.object(forKey: lastCheckKey) as? Date,
           Date().timeIntervalSince(last) < 24 * 3600 { return }
        checkForUpdates(silent: true)
    }

    /// 检查更新。silent=true(自动):失败/无更新都不打扰。
    func checkForUpdates(silent: Bool) {
        guard !isChecking else { return }
        isChecking = true
        lastCheckError = nil
        upToDateNotice = false
        defaults.set(Date(), forKey: lastCheckKey)

        let url = URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("EasySign", forHTTPHeaderField: "User-Agent")

        session.dataTask(with: req) { [weak self] data, resp, err in
            guard let self else { return }
            DispatchQueue.main.async {
                self.isChecking = false
                if let err {
                    if !silent { self.lastCheckError = "检查失败:\(err.localizedDescription)" }
                    return
                }
                if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                    if !silent { self.lastCheckError = "检查失败:GitHub 返回 \(http.statusCode)" }
                    return
                }
                guard let data, let parsed = try? GitHubReleaseParser.parse(data) else {
                    if !silent { self.lastCheckError = "检查失败:无法解析响应" }
                    return
                }
                guard let latest = SemanticVersion(parsed.tagName), let current = self.currentVersion else {
                    if !silent { self.lastCheckError = "检查失败:版本号无法解析" }
                    return
                }
                guard latest.isNewer(than: current), let dmg = parsed.dmgURL else {
                    if !silent { self.upToDateNotice = true }   // 已是最新
                    return
                }
                self.availableUpdate = UpdateInfo(version: latest.displayString,
                                                  releaseNotes: parsed.body,
                                                  dmgURL: dmg, publishedAt: parsed.publishedAt)
                self.logger.log(.info, tool: "update", "发现新版本 \(latest.displayString)")
            }
        }.resume()
    }

    /// 下载当前 availableUpdate 的 .dmg。
    func startDownload() {
        guard let update = availableUpdate, downloadTask == nil else { return }
        downloadProgress = 0
        let task = session.downloadTask(with: update.dmgURL)
        downloadTask = task
        task.resume()
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        downloadProgress = nil
    }

    func dismissUpdate() { availableUpdate = nil }

    // MARK: URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let p = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        DispatchQueue.main.async { self.downloadProgress = p }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        let version = availableUpdate?.version ?? "latest"
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let dest = downloads.appendingPathComponent("EasySign-\(version).dmg")
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.moveItem(at: location, to: dest)
        } catch {
            DispatchQueue.main.async { self.lastCheckError = "保存失败:\(error.localizedDescription)"; self.downloadProgress = nil; self.downloadTask = nil }
            return
        }
        stripQuarantine(dest)
        DispatchQueue.main.async {
            self.downloadProgress = nil
            self.downloadTask = nil
            NSWorkspace.shared.open(dest)        // 挂载 dmg,弹出拖拽窗口
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, (error as NSError).code != NSURLErrorCancelled else { return }
        DispatchQueue.main.async {
            self.lastCheckError = "下载失败:\(error.localizedDescription)"
            self.downloadProgress = nil
            self.downloadTask = nil
        }
    }

    private func stripQuarantine(_ url: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        p.arguments = ["-d", "com.apple.quarantine", url.path]
        p.standardError = Pipe(); p.standardOutput = Pipe()
        try? p.run(); p.waitUntilExit()   // 失败(本就无此属性)无所谓
    }
}
```

- [ ] **Step 2: ServiceKey 加 case**

`EasySign/Core/Toolkit/ServiceKey.swift` — enum 内加:
```swift
    case update
```

- [ ] **Step 3: ServiceHub 接线**

`EasySign/Core/Toolkit/ServiceHub.swift`:
- 加属性 `let update: UpdateService`
- `init` 加参数 `update: UpdateService` 并赋值 `self.update = update`
- `live()` 内 `return` 前加 `let update = UpdateService(logger: logger)`,并把 `update: update` 传入构造
- `subscript` 的 switch 加 `case .update: return update`

- [ ] **Step 4: 编译验证**

Run:
```bash
xcodebuild -project EasySign.xcodeproj -scheme EasySign -configuration Debug build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`(忽略 SourceKit "cannot find type" 噪声)。

- [ ] **Step 5: Commit**
```bash
git add EasySign/Core/Update/UpdateService.swift EasySign/Core/Toolkit/
git commit -m "feat(update): add UpdateService (check/download/open) + ServiceHub wiring"
```

---

## Task 5: UI — 更新 sheet + 菜单命令 + 启动检查 + 设置开关(编译门)

**Files:**
- Create: `EasySign/App/UpdateView.swift`
- Modify: `EasySign/App/EasySignApp.swift`
- Modify: `EasySign/App/SettingsView.swift`

- [ ] **Step 1: UpdateView**

`EasySign/App/UpdateView.swift`:
```swift
import SwiftUI

struct UpdateView: View {
    @ObservedObject var service: UpdateService
    let update: UpdateInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill").font(.system(size: 28)).foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("发现新版本 \(update.version)").font(.headline)
                    Text("当前 \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Divider()
            ScrollView {
                Text(update.releaseNotes.isEmpty ? "(无更新说明)" : update.releaseNotes)
                    .font(.callout).frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 160)
            .padding(8).background(.quaternary.opacity(0.4)).cornerRadius(8)

            if let p = service.downloadProgress {
                ProgressView(value: p) { Text("下载中… \(Int(p * 100))%").font(.caption) }
                HStack { Spacer(); Button("取消") { service.cancelDownload() } }
            } else {
                Text("未签名分发:下载后若提示"已损坏",右键打开,或终端执行 xattr -dr com.apple.quarantine /Applications/EasySign.app")
                    .font(.caption2).foregroundStyle(.secondary)
                HStack {
                    Button("以后再说") { service.dismissUpdate() }
                    Spacer()
                    Button("下载更新") { service.startDownload() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
```

- [ ] **Step 2: EasySignApp — 菜单命令 + 启动检查 + sheet**

`EasySign/App/EasySignApp.swift` 改动:
- `init()` 末尾(`h.transfer.start()` 之后)加 `h.update.maybeAutoCheckOnLaunch()`。
- 主窗口内容包一层以承载 sheet:把 `RootView(hub: hub)` 改为
  ```swift
        Window("EasySign", id: "main") {
            RootView(hub: hub)
                .modifier(UpdateSheet(service: hub.update))
        }
        .windowResizability(.contentSize)
  ```
- 在 `body` 的 scene 链上加菜单命令:
  ```swift
        .commands {
            CommandGroup(after: .appInfo) {
                Button("检查更新…") {
                    NSApp.activate(ignoringOtherApps: true)
                    hub.update.checkForUpdates(silent: false)
                }
            }
        }
  ```
  (`.commands` 挂在某个 Scene 上,例如紧跟主 `Window` 之后。)
- 文件内新增 sheet 修饰器 + 一个"已是最新/错误"提示:
  ```swift
  /// 把更新 sheet 与"已是最新/错误"提示挂到主窗口。
  struct UpdateSheet: ViewModifier {
      @ObservedObject var service: UpdateService
      func body(content: Content) -> some View {
          content
              .sheet(item: $service.availableUpdate) { info in
                  UpdateView(service: service, update: info)
              }
              .alert("已是最新版本", isPresented: $service.upToDateNotice) {
                  Button("好") { }
              }
              .alert("检查更新", isPresented: Binding(
                  get: { service.lastCheckError != nil },
                  set: { if !$0 { service.lastCheckError = nil } }
              )) { Button("好") { } } message: { Text(service.lastCheckError ?? "") }
      }
  }
  ```
  > `.sheet(item:)` 需要 `UpdateInfo: Identifiable`(已满足)。`$service.availableUpdate` 是对 `@Published` 的绑定,设为 nil 即关闭 sheet(`dismissUpdate()`/`startDownload` 完成后由用户关或保留)。

- [ ] **Step 3: SettingsView — 自动检查开关**

`EasySign/App/SettingsView.swift`:把 `hub.update` 传进来(改 `EasySignApp` 的 `Settings { SettingsView(settings: hub.settings, transfer: hub.transfer, update: hub.update) }`),并在合适分区加:
```swift
    Toggle("启动时自动检查更新", isOn: Binding(
        get: { update.autoCheckEnabled },
        set: { update.autoCheckEnabled = $0 }
    ))
    Button("检查更新…") { update.checkForUpdates(silent: false) }
```
`SettingsView` 加 `let update: UpdateService` 存储属性(或 `@ObservedObject`,因要读 isChecking 可用 `@ObservedObject`)。按现有 `SettingsView` 的分区风格放进"通用/关于"区。

- [ ] **Step 4: 编译验证**

Run:
```bash
xcodebuild -project EasySign.xcodeproj -scheme EasySign -configuration Debug build 2>&1 | tail -6
```
Expected: `** BUILD SUCCEEDED **`。

> 若 `.commands` 里访问 `hub` 报作用域问题,或 `.sheet(item:)` 类型推断失败,按编译器提示微调(语义不变:菜单触发 `checkForUpdates(silent:false)`;`availableUpdate` 非 nil 时弹 `UpdateView`)。`Text("...\"已损坏\"...")` 内的中文引号注意转义或改用中文引号「」避免字符串提前结束。

- [ ] **Step 5: Commit**
```bash
git add EasySign/App/UpdateView.swift EasySign/App/EasySignApp.swift EasySign/App/SettingsView.swift
git commit -m "feat(update): update sheet + check-for-updates menu + auto-check setting"
```

---

## Task 6: 手动 E2E + 首个 Release

- [ ] **Step 1: 纯逻辑回归**

Run:
```bash
swiftc -O -parse-as-library EasySign/Core/Update/SemanticVersion.swift Tests/SemanticVersionTests.swift -o /tmp/sv && /tmp/sv
swiftc -O -parse-as-library EasySign/Core/Update/UpdateInfo.swift Tests/GitHubReleaseParserTests.swift -o /tmp/gh && /tmp/gh
```
Expected: 两个 `ALL PASS`。

- [ ] **Step 2: 全量编译**

Run:
```bash
xcodebuild -project EasySign.xcodeproj -scheme EasySign -configuration Debug build 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **`。

- [ ] **Step 3: 推送代码 + 打首个 tag(需用户执行)**

> 此步会触发真实 GHA + 发布 Release,由用户决定执行时机:
```bash
git push                              # 推送 main(含本计划所有提交)
git tag v1.0.3 && git push origin v1.0.3
```
预期:GitHub Actions 跑完,Release `v1.0.3` 出现并挂 `EasySign-1.0.3.dmg`。若 workflow 失败,看 Actions 日志按 Task 1 注释微调 create-dmg/xcodebuild 参数。

- [ ] **Step 4: App 内验证(需用户执行)**

在低于该版本的本地构建里:菜单"检查更新…" → 应弹出"发现新版本 1.0.3" → 点"下载更新" → 进度跑满 → 自动挂载 dmg。手动右键打开/拖入 Applications 验证可运行。

---

## Self-Review

**Spec 覆盖:**
- Workflow(tag→build→dmg→release)→ Task 1 ✅
- 版本从 tag 注入 → Task 1 Step 1(`MARKETING_VERSION=...`)✅
- SemanticVersion → Task 2 ✅
- GitHub JSON 解析 → Task 3 ✅
- UpdateService 检查/下载/去quarantine/挂载/节流/自动检查开关 → Task 4 ✅
- ServiceHub 接线 → Task 4 ✅
- 更新 sheet + 菜单命令 + 启动检查 + 设置开关 → Task 5 ✅
- ~/Downloads 落盘 → Task 4 `didFinishDownloadingTo` ✅
- 错误处理(无网/限流/无dmg/已最新/下载失败)→ Task 4 ✅
- quarantine 提示文案 → Task 5 UpdateView ✅
- 纯逻辑独立测试 + 手动 E2E → Task 2/3/6 ✅

**占位符:** 无 TBD/TODO 空步骤;CI/网络/UI 任务给出完整文件 + 真实校验命令(YAML lint / xcodebuild / 手动)。

**类型一致性:** `SemanticVersion(_:)`/`displayString`/`isNewer(than:)`(Task2)→ Task4 使用一致;`GitHubReleaseParser.parse → Parsed{tagName,body,dmgURL,publishedAt}`(Task3)→ Task4 使用一致;`UpdateInfo{version,releaseNotes,dmgURL,publishedAt}` Identifiable(Task3)→ Task4 构造、Task5 `.sheet(item:)` 一致;`UpdateService` 的 `availableUpdate/downloadProgress/checkForUpdates/startDownload/cancelDownload/dismissUpdate/autoCheckEnabled/upToDateNotice/lastCheckError/maybeAutoCheckOnLaunch`(Task4)→ Task5 UI 使用一致。

**已知执行期微调点(非占位,是真实集成细节):** create-dmg 在 runner 上对单 app 源的行为(Task1 注释);`.commands` 内访问 `hub`、`.sheet(item:)` 推断、中文引号转义(Task5 Step4 注释)。
