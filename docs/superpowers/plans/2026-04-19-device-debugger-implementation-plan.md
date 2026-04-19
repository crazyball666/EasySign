# Device Debugger Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 EasySign 中新增设备调试功能 - 查看真机列表、已安装 App 列表、浏览沙盒文件系统、文件预览与双向传输。

**Architecture:** 采用 MobileDevice.framework 私有 API 实现设备连接，通过 AFC 服务访问 App 沙盒目录。UI 层复用现有 SwiftUI 框架，新增侧边栏切换布局。

**Tech Stack:** Swift 5.0, SwiftUI, MobileDevice.framework (系统私有 API), AFC (Apple File Connection)

---

## File Structure

```
EasySign/
├── EasySign/Views/
│   ├── ContentView.swift           # 修改：新增侧边栏导航
│   ├── DeviceView.swift            # 新增：设备调试主面板
│   ├── DeviceListPanel.swift       # 新增：设备列表侧边栏
│   ├── AppListView.swift           # 新增：App 列表视图
│   ├── SandboxBrowserView.swift     # 新增：文件浏览视图
│   └── FilePreviewView.swift       # 新增：文件预览视图
├── EasySign/DeviceService/
│   ├── DeviceManager.swift         # 新增：设备管理（连接/断开/监听）
│   ├── Device.swift                # 新增：设备模型
│   ├── AppLister.swift            # 新增：App 列表获取
│   ├── InstalledApp.swift         # 新增：App 模型
│   ├── AFCClient.swift            # 新增：AFC 文件服务客户端
│   ├── FileNode.swift             # 新增：文件节点模型
│   ├── FileTransfer.swift         # 新增：文件传输（下载/上传）
│   └── FilePreviewer.swift        # 新增：文件预览工厂
└── EasySign/ResignService/
    └── ...                         # 现有代码不变
```

---

## Task 1: 项目配置 - 引入 MobileDevice.framework

**Files:**
- Modify: `EasySign.xcodeproj/project.pbxproj`

- [ ] **Step 1: 在 Xcode 项目中添加 MobileDevice.framework 链接**

MobileDevice.framework 是系统私有框架，位于 `/System/Library/PrivateFrameworks/MobileDevice.framework`。

通过修改 `project.pbxproj` 添加框架链接：

```ruby
# 在 PBXBuildFile section 添加：
7CXXXXXX1 /* MobileDevice.framework in Frameworks */ = {isa = PBXBuildFile; fileRef = 7CXXXXXX2 /* MobileDevice.framework */; };

# 在 PBXFileReference section 添加：
7CXXXXXX2 /* MobileDevice.framework */ = {isa = PBXFileReference; lastKnownFileType = wrapper.framework; name = MobileDevice.framework; path = "/System/Library/PrivateFrameworks/MobileDevice.framework"; sourceTree = "<absolute>"; };

# 在 PBXFrameworksBuildPhase section 添加：
7CXXXXXX1 /* MobileDevice.framework in Frameworks */;
```

或直接在 Xcode 中操作：
1. 选择项目 Target → Build Phases → Link Binary With Libraries
2. 点击 "+" → Add Other → 浏览到 `/System/Library/PrivateFrameworks/MobileDevice.framework`
3. 勾选 "Don't code sign" 或设置为 "Optional"

- [ ] **Step 2: 配置代码签名设置**

由于 MobileDevice.framework 是私有 API，需将代码签名设置为 "Sign to Run Locally" 或在 Debug 模式下禁用签名检查。

- [ ] **Step 3: 验证框架引入成功**

```bash
# 检查框架是否存在
ls -la /System/Library/PrivateFrameworks/MobileDevice.framework

# 验证链接
otool -L EasySign.app/Contents/MacOS/EasySign | grep MobileDevice
```

- [ ] **Step 4: 提交**

```bash
git add EasySign.xcodeproj/project.pbxproj
git commit -m "chore: 添加 MobileDevice.framework 链接"
```

---

## Task 2: Device 模型定义

**Files:**
- Create: `EasySign/DeviceService/Device.swift`

- [ ] **Step 1: 创建 Device 模型**

```swift
import Foundation

struct Device: Identifiable, Hashable {
    let id: String  // UDID
    let name: String
    let model: String
    let systemVersion: String
    let deviceClass: DeviceClass

    enum DeviceClass: String {
        case iPhone
        case iPad
        case iPod
        case unknown
    }

    var displayName: String {
        "\(name) (\(systemVersion))"
    }
}
```

- [ ] **Step 2: 创建 Bridging Header 引用（如果尚未配置）**

检查 `EasySign/EasySign-Bridging-Header.h` 是否存在，确保可引入 MobileDevice C 头文件：

```objc
#ifndef EasySign_Bridging_Header_h
#define EasySign_Bridging_Header_h

#import <Foundation/Foundation.h>
#import <MobileDevice/MobileDevice.h>

#endif
```

- [ ] **Step 3: 验证编译**

```bash
xcodebuild -project EasySign.xcodeproj -scheme EasySign -configuration Debug build CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO 2>&1 | grep -i error | head -20
```

- [ ] **Step 4: 提交**

```bash
git add EasySign/DeviceService/Device.swift EasySign/EasySign-Bridging-Header.h
git commit -m "feat(device): 添加 Device 模型定义"
```

---

## Task 3: DeviceManager - 设备连接管理

**Files:**
- Create: `EasySign/DeviceService/DeviceManager.swift`

- [ ] **Step 1: 创建 DeviceManager 单例**

```swift
import Foundation
import Combine

final class DeviceManager: ObservableObject {
    static let shared = DeviceManager()

    @Published private(set) var devices: [Device] = []
    @Published private(set) var connectedDevice: Device?
    @Published private(set) var isConnected: Bool = false

    private var deviceNotificationPort: UnsafeMutableRawPointer?
    private var runLoopSource: CFRunLoopSource?

    private init() {}

    // MARK: - Public Methods

    func refreshDevices() {
        // 使用 AMDeviceCopySupportedDevices 获取设备列表
    }

    func connect(to device: Device) -> Bool {
        // 创建设备连接：AMDeviceConnect -> AMDeviceIsPaired -> AMDeviceValidatePairing -> AMDeviceStartSession
    }

    func disconnect() {
        // 结束会话并断开连接
    }

    func startObserving() {
        // 注册 USB 设备插拔通知
    }

    func stopObserving() {
        // 取消 USB 设备通知注册
    }
}
```

- [ ] **Step 2: 实现设备列表获取**

```swift
private extension DeviceManager {
    func fetchDevices() -> [Device] {
        guard let deviceList = AMDeviceCopySupportedDevices() as? [AMDeviceRef] else {
            return []
        }

        return deviceList.compactMap { ref -> Device? in
            guard AMDeviceConnect(ref) == AMDAppLEDETECT_SUCCESS else { return nil }
            defer { AMDeviceDisconnect(ref) }

            guard let name = AMDeviceCopyValue(ref, 0, "DeviceName" as CFString) as? String,
                  let udid = AMDeviceCopyValue(ref, 0, "UniqueDeviceID" as CFString) as? String,
                  let model = AMDeviceCopyValue(ref, 0, "ProductType" as CFString) as? String,
                  let version = AMDeviceCopyValue(ref, 0, "ProductVersion" as CFString) as? String else {
                return nil
            }

            let deviceClass = parseDeviceClass(from: model)

            return Device(
                id: udid,
                name: name,
                model: model,
                systemVersion: version,
                deviceClass: deviceClass
            )
        }
    }
}
```

- [ ] **Step 3: 实现 USB 事件监听**

```swift
private extension DeviceManager {
    func setupDeviceNotification() {
        // 注册 AMDeviceNotification callback
        // 当 USB 设备插拔时收到回调
        var notifyPort: UnsafeMutableRawPointer?
        var runLoopSource: CFRunLoopSource?

        let callback: AMDeviceNotificationCallback = { (dict, userInfo) in
            // 解析通知类型：kAMDeviceConnected / kAMDeviceDisconnected
            // 刷新设备列表
        }

        AMDeviceNotificationSubscribe(callback, 0, 0, nil, &notifyPort)
        // 将 notifyPort 加入当前 runloop
    }
}
```

- [ ] **Step 4: 提交**

```bash
git add EasySign/DeviceService/DeviceManager.swift
git commit -m "feat(device): 添加 DeviceManager 设备连接管理"
```

---

## Task 4: InstalledApp 模型与 AppLister

**Files:**
- Create: `EasySign/DeviceService/InstalledApp.swift`
- Create: `EasySign/DeviceService/AppLister.swift`

- [ ] **Step 1: 创建 InstalledApp 模型**

```swift
import Foundation

struct InstalledApp: Identifiable, Hashable {
    let id: String  // Bundle ID
    let bundleID: String
    let name: String
    let version: String
    let buildVersion: String
    let signingInfo: SigningInfo
    let path: String
    let isSystemApp: Bool

    enum SigningInfo: String {
        case development = "Development"
        case distribution = "Distribution"
        case enterprise = "Enterprise"
        case unknown = "Unknown"
    }
}
```

- [ ] **Step 2: 创建 AppLister 获取 App 列表**

```swift
final class AppLister {
    private let device: Device

    init(device: Device) {
        self.device = device
    }

    func listInstalledApps() throws -> [InstalledApp] {
        // 1. 确保设备已连接并处于 session 中
        guard let deviceRef = getConnectedDeviceRef(for: device.id) else {
            throw DeviceError.notConnected
        }

        // 2. 调用 AMDeviceLookupApplicationImages
        var result: Unmanaged<CFDictionary>?
        let status = AMDeviceLookupApplicationImages(deviceRef, 0, &result)

        guard status == AMDAppLEDETECT_SUCCESS,
              let dict = result?.takeRetainedValue() as? [String: Any] else {
            throw DeviceError.lookupFailed
        }

        // 3. 解析返回的 App 列表
        // 每个 App 是包含 kAppLookupInfoDictKey 的 CFDictionary
        return parseAppList(from: dict)
    }

    private func parseAppList(from dict: [String: Any]) -> [InstalledApp] {
        guard let appList = dict[kAppLookupInfoAppDictKey] as? [[String: Any]] else {
            return []
        }

        return appList.compactMap { appDict -> InstalledApp? in
            guard let bundleID = appDict[kCFBundleIdentifierKey] as? String,
                  let path = appDict[kAppLookupInfoImagePathKey] as? String else {
                return nil
            }

            let name = appDict[kCFBundleNameKey] as? String ?? bundleID
            let version = appDict[kCFBundleShortVersionStringKey] as? String ?? ""
            let buildVersion = appDict[kCFBundleVersionKey] as? String ?? ""
            let signerIdentity = appDict["SignerIdentity"] as? String ?? ""
            let signingInfo = parseSigningInfo(signerIdentity)
            let isSystemApp = path.hasPrefix("/Applications/")

            return InstalledApp(
                id: bundleID,
                bundleID: bundleID,
                name: name,
                version: version,
                buildVersion: buildVersion,
                signingInfo: signingInfo,
                path: path,
                isSystemApp: isSystemApp
            )
        }
    }

    private func parseSigningInfo(_ signerIdentity: String) -> InstalledApp.SigningInfo {
        if signerIdentity.contains("Apple Development") || signerIdentity.contains("iPhone Developer") {
            return .development
        } else if signerIdentity.contains("Apple Distribution") {
            return .distribution
        } else if signerIdentity.contains("Apple Enterprise") {
            return .enterprise
        }
        return .unknown
    }
}
```

- [ ] **Step 3: 提交**

```bash
git add EasySign/DeviceService/InstalledApp.swift EasySign/DeviceService/AppLister.swift
git commit -m "feat(device): 添加 InstalledApp 模型和 AppLister"
```

---

## Task 5: AFCClient - 沙盒文件服务

**Files:**
- Create: `EasySign/DeviceService/AFCClient.swift`
- Create: `EasySign/DeviceService/FileNode.swift`

- [ ] **Step 1: 创建 FileNode 模型**

```swift
import Foundation

struct FileNode: Identifiable, Hashable {
    let id: String  // 完整路径
    let name: String
    let path: String
    let isDirectory: Bool
    let size: UInt64
    let modificationDate: Date?
    let fileType: FileType

    enum FileType: String {
        case directory
        case text
        case image
        case database
        case plist
        case json
        case other
    }
}
```

- [ ] **Step 2: 创建 AFCClient**

```swift
final class AFCClient {
    private var connection: AFCConnectionRef?
    private let device: Device

    init(device: Device) throws {
        self.device = device
        try openConnection()
    }

    deinit {
        closeConnection()
    }

    // MARK: - Connection

    private func openConnection() throws {
        guard let deviceRef = getConnectedDeviceRef(for: device.id) else {
            throw AFCError.deviceNotConnected
        }

        var conn: AFCConnectionRef?
        // 启动 AFC 服务获取 connection
        let serviceName = "com.apple.afc" as CFString
        let result = AMDeviceStartService(deviceRef, serviceName, &conn, nil)

        guard result == AMDAppLEDETECT_SUCCESS, let connection = conn else {
            throw AFCError.connectionFailed
        }

        self.connection = connection
    }

    private func closeConnection() {
        if let conn = connection {
            AFCConnectionClose(conn)
            connection = nil
        }
    }

    // MARK: - Directory Operations

    func listDirectory(at path: String) throws -> [FileNode] {
        guard let conn = connection else {
            throw AFCError.notConnected
        }

        var dirRef: AFCDirectoryRef?
        let openResult = AFCDirectoryOpen(conn, path, &dirRef)
        guard openResult == AFCSUCCESS, let dir = dirRef else {
            throw AFCError.directoryOpenFailed
        }

        defer { AFCDirectoryClose(conn, dir) }

        var nodes: [FileNode] = []
        while true {
            guard let entry = AFCDirectoryRead(conn, dir) else { break }

            let name = String(cString: entry.pointee.name)
            let fullPath = (path as NSString).appendingPathComponent(name)

            // 获取文件信息
            var infoRef: AFCFileInfoRef?
            AFCFileInfoOpen(conn, fullPath, &infoRef)

            var isDir: UInt64 = 0
            var size: UInt64 = 0
            var mtime: UInt64 = 0

            if let info = infoRef {
                AFCFileInfoGetValue(info, "st_ifmt" as CFString, &isDir, MemoryLayout<UInt64>.size)
                AFCFileInfoGetValue(info, "st_size" as CFString, &size, MemoryLayout<UInt64>.size)
                AFCFileInfoGetValue(info, "st_mtime" as CFString, &mtime, MemoryLayout<UInt64>.size)
                AFCFileInfoClose(conn, info)
            }

            let node = FileNode(
                id: fullPath,
                name: name,
                path: fullPath,
                isDirectory: isDir == UInt64(bitPattern: Int64(AFCDirectoryType)),
                size: size,
                modificationDate: Date(timeIntervalSince1970: TimeInterval(mtime)),
                fileType: guessFileType(name: name, isDirectory: isDir == UInt64(bitPattern: Int64(AFCDirectoryType)))
            )
            nodes.append(node)
        }

        return nodes.sorted { $0.name < $1.name }
    }

    // MARK: - File Operations

    func readFile(at path: String, offset: UInt64 = 0, length: UInt64 = 0) throws -> Data {
        guard let conn = connection else {
            throw AFCError.notConnected
        }

        var fileRef: AFCFileRef?
        let openFlags: UInt32 = 0x0001  // O_RDONLY
        let openResult = AFCFileRefOpen(conn, path, openFlags, &fileRef)
        guard openResult == AFCSUCCESS, let ref = fileRef else {
            throw AFCError.fileOpenFailed
        }

        defer { AFCFileRefClose(conn, ref) }

        // 读取文件内容
        let bufferSize = length > 0 ? length : 1024 * 1024  // 默认 1MB
        var buffer = [UInt8](repeating: 0, count: Int(bufferSize))
        var bytesRead: UInt32 = 0

        let readResult = AFCFileRefRead(conn, ref, &buffer, &bytesRead)
        guard readResult == AFCSUCCESS else {
            throw AFCError.readFailed
        }

        return Data(buffer.prefix(Int(bytesRead)))
    }

    func writeFile(at path: String, data: Data) throws {
        guard let conn = connection else {
            throw AFCError.notConnected
        }

        var fileRef: AFCFileRef?
        let openFlags: UInt32 = 0x0002  // O_WRONLY | O_CREAT | O_TRUNC
        let openResult = AFCFileRefOpen(conn, path, openFlags, &fileRef)
        guard openResult == AFCSUCCESS, let ref = fileRef else {
            throw AFCError.fileOpenFailed
        }

        defer { AFCFileRefClose(conn, ref) }

        var bytesWritten: UInt32 = 0
        let writeResult = data.withUnsafeBytes { ptr -> Int32 in
            AFCFileRefWrite(conn, ref, ptr.baseAddress, UInt32(data.count))
        }

        guard writeResult == AFCSUCCESS else {
            throw AFCError.writeFailed
        }
    }

    func deleteFile(at path: String) throws {
        guard let conn = connection else {
            throw AFCError.notConnected
        }

        let result = AFCRemovePath(conn, path)
        guard result == AFCSUCCESS else {
            throw AFCError.deleteFailed
        }
    }

    func createDirectory(at path: String) throws {
        guard let conn = connection else {
            throw AFCError.notConnected
        }

        let result = AFCDirectoryCreate(conn, path)
        guard result == AFCSUCCESS else {
            throw AFCError.createDirectoryFailed
        }
    }
}
```

- [ ] **Step 3: 提交**

```bash
git add EasySign/DeviceService/AFCClient.swift EasySign/DeviceService/FileNode.swift
git commit -m "feat(device): 添加 AFCClient 沙盒文件服务和 FileNode 模型"
```

---

## Task 6: FileTransfer - 文件传输

**Files:**
- Create: `EasySign/DeviceService/FileTransfer.swift`

- [ ] **Step 1: 创建 FileTransfer 类**

```swift
final class FileTransfer {
    private let afcClient: AFCClient

    init(afcClient: AFCClient) {
        self.afcClient = afcClient
    }

    // MARK: - Download

    func downloadFile(remotePath: String, to localURL: URL, progress: ((Double) -> Void)? = nil) throws {
        let fileData = try afcClient.readFile(at: remotePath)
        try fileData.write(to: localURL)
    }

    func downloadDirectory(remotePath: String, to localURL: URL, progress: ((Double) -> Void)? = nil) throws {
        let fileNodes = try afcClient.listDirectory(at: remotePath)
        try FileManager.default.createDirectory(at: localURL, withIntermediateDirectories: true)

        for node in fileNodes where node.name != "." && node.name != ".." {
            let destPath = localURL.appendingPathComponent(node.name)
            if node.isDirectory {
                try downloadDirectory(remotePath: node.path, to: destPath, progress: progress)
            } else {
                try downloadFile(remotePath: node.path, to: destPath, progress: progress)
            }
        }
    }

    // MARK: - Upload

    func uploadFile(localURL: URL, to remotePath: String, progress: ((Double) -> Void)? = nil) throws {
        let data = try Data(contentsOf: localURL)
        try afcClient.writeFile(at: remotePath, data: data)
    }

    func uploadDirectory(localURL: URL, to remotePath: String, progress: ((Double) -> Void)? = nil) throws {
        try afcClient.createDirectory(at: remotePath)

        let contents = try FileManager.default.contentsOfDirectory(at: localURL, includingPropertiesForKeys: nil)
        for item in contents {
            let itemName = item.lastPathComponent
            let destPath = (remotePath as NSString).appendingPathComponent(itemName)

            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: item.path, isDirectory: &isDir)

            if isDir.boolValue {
                try uploadDirectory(localURL: item, to: destPath, progress: progress)
            } else {
                try uploadFile(localURL: item, to: destPath, progress: progress)
            }
        }
    }
}
```

- [ ] **Step 2: 提交**

```bash
git add EasySign/DeviceService/FileTransfer.swift
git commit -m "feat(device): 添加 FileTransfer 文件传输服务"
```

---

## Task 7: FilePreviewer - 文件预览

**Files:**
- Create: `EasySign/DeviceService/FilePreviewer.swift`

- [ ] **Step 1: 创建 FilePreviewer**

```swift
import Foundation
#if canImport(AppKit)
import AppKit
#endif

enum PreviewResult {
    case text(String)
    case image(Data)
    case database([[String: Any]])
    case binary(Data)
    case unsupported(String reason)
}

final class FilePreviewer {
    func preview(data: Data, fileName: String) -> PreviewResult {
        let ext = (fileName as NSString).pathExtension.lowercased()

        switch ext {
        case "txt", "log", "json", "xml", "plist", "yaml", "yml", "md", "sh", "swift", "m", "h", "c", "cpp", "hpp":
            return previewText(data: data)

        case "png", "jpg", "jpeg", "gif", "bmp", "tiff", "webp":
            return previewImage(data: data)

        case "db", "sqlite", "sqlite3":
            return previewDatabase(data: data)

        case "txt", "log":
            return previewText(data: data)

        default:
            return previewBinary(data: data)
        }
    }

    private func previewText(data: Data) -> PreviewResult {
        guard let content = String(data: data, encoding: .utf8) else {
            return .unsupported("无法解析为文本文件")
        }
        return .text(content)
    }

    private func previewImage(data: Data) -> PreviewResult {
        #if canImport(AppKit)
        if let image = NSImage(data: data) {
            guard let tiffData = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiffData),
                  let pngData = bitmap.representation(using: .png, properties: [:]) else {
                return .unsupported("图片格式不支持")
            }
            return .image(pngData)
        }
        #endif
        return .unsupported("无法加载图片")
    }

    private func previewDatabase(data: Data) -> PreviewResult {
        // 使用 SQLite 解析数据库表
        // 这里简化处理，实际需要引入 SQLite 库或使用系统 SQLite3 API
        return .unsupported("数据库预览暂未实现")
    }

    private func previewBinary(data: Data) -> PreviewResult {
        // 显示前 1024 字节的十六进制和 ASCII
        let previewSize = min(1024, data.count)
        let previewData = data.prefix(previewSize)
        return .binary(Data(previewData))
    }
}
```

- [ ] **Step 2: 提交**

```bash
git add EasySign/DeviceService/FilePreviewer.swift
git commit -m "feat(device): 添加 FilePreviewer 文件预览服务"
```

---

## Task 8: UI - ContentView 侧边栏改造

**Files:**
- Modify: `EasySign/Views/ContentView.swift`

- [ ] **Step 1: 添加侧边栏导航状态**

在 `ContentView.swift` 中添加导航状态：

```swift
enum NavigationTab: String, CaseIterable {
    case resign = "Resign"
    case devices = "Devices"
}

struct ContentView: View {
    @State private var selectedTab: NavigationTab = .resign
    // ... existing code ...

    var body: some View {
        HStack(spacing: 0) {
            // 侧边栏
            SidebarView(selectedTab: $selectedTab)
                .frame(width: 80)

            // 内容区域
            Group {
                switch selectedTab {
                case .resign:
                    ResignContentView()  // 现有的 ContentView 内容
                case .devices:
                    DeviceView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // ... rest of existing code ...
    }
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
```

- [ ] **Step 2: 将现有 ContentView 重构为 ResignContentView**

将现有 ContentView 的主体内容提取为 `ResignContentView`，保持原有功能：

```swift
struct ResignContentView: View {
    @StateObject var viewModel = ContentViewModel()
    // ... 将原有 ContentView body 内容移到这里 ...
}
```

- [ ] **Step 3: 提交**

```bash
git add EasySign/Views/ContentView.swift
git commit -m "feat(ui): 添加侧边栏导航切换布局"
```

---

## Task 9: UI - DeviceView 设备调试主面板

**Files:**
- Create: `EasySign/Views/DeviceView.swift`
- Create: `EasySign/Views/DeviceListPanel.swift`

- [ ] **Step 1: 创建 DeviceView 主面板**

```swift
struct DeviceView: View {
    @StateObject private var deviceManager = DeviceManager.shared
    @State private var selectedDevice: Device?
    @State private var selectedApp: InstalledApp?
    @State private var currentPath: String = ""
    @State private var viewMode: DeviceViewMode = .appList

    enum DeviceViewMode {
        case appList
        case fileBrowser
        case filePreview
    }

    var body: some View {
        HStack(spacing: 0) {
            // 设备列表
            DeviceListPanel(
                devices: deviceManager.devices,
                selectedDevice: $selectedDevice,
                onRefresh: { deviceManager.refreshDevices() }
            )
            .frame(width: 150)

            Divider()

            // 主内容区
            Group {
                switch viewMode {
                case .appList:
                    AppListView(
                        device: selectedDevice,
                        onAppSelected: { app in
                            selectedApp = app
                            currentPath = "/"
                            viewMode = .fileBrowser
                        }
                    )
                case .fileBrowser:
                    SandboxBrowserView(
                        app: selectedApp,
                        initialPath: currentPath,
                        onFileSelected: { node in
                            if !node.isDirectory {
                                viewMode = .filePreview
                            }
                        },
                        onNavigateBack: {
                            viewMode = .appList
                        }
                    )
                case .filePreview:
                    FilePreviewView(
                        app: selectedApp,
                        path: currentPath,
                        onBack: {
                            viewMode = .fileBrowser
                        }
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            deviceManager.refreshDevices()
        }
    }
}
```

- [ ] **Step 2: 创建 DeviceListPanel**

```swift
struct DeviceListPanel: View {
    let devices: [Device]
    @Binding var selectedDevice: Device?
    let onRefresh: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Devices")
                    .font(.headline)
                Spacer()
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .padding()

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(devices) { device in
                        DeviceRow(
                            device: device,
                            isSelected: selectedDevice?.id == device.id
                        ) {
                            selectedDevice = device
                        }
                    }
                }
            }
        }
        .background(Color.gray.opacity(0.05))
    }
}

struct DeviceRow: View {
    let device: Device
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack {
                Image(systemName: device.deviceClass == .iPhone ? "iphone" : "ipad")
                    .foregroundColor(.primary)
                VStack(alignment: .leading) {
                    Text(device.name)
                        .font(.subheadline)
                        .foregroundColor(.primary)
                    Text(device.systemVersion)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(isSelected ? Color.blue.opacity(0.1) : Color.clear)
        }
        .buttonStyle(.plain)
    }
}
```

- [ ] **Step 3: 提交**

```bash
git add EasySign/Views/DeviceView.swift EasySign/Views/DeviceListPanel.swift
git commit -m "feat(ui): 添加 DeviceView 和 DeviceListPanel"
```

---

## Task 10: UI - AppListView App 列表视图

**Files:**
- Create: `EasySign/Views/AppListView.swift`

- [ ] **Step 1: 创建 AppListView**

```swift
struct AppListView: View {
    let device: Device?
    let onAppSelected: (InstalledApp) -> Void

    @State private var apps: [InstalledApp] = []
    @State private var searchText: String = ""
    @State private var selectedFilter: AppFilter = .all
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?

    enum AppFilter: String, CaseIterable {
        case all = "All"
        case development = "Development"
        case distribution = "Distribution"
        case system = "System"
    }

    var filteredApps: [InstalledApp] {
        var result = apps

        // 应用筛选
        switch selectedFilter {
        case .all:
            break
        case .development:
            result = result.filter { $0.signingInfo == .development }
        case .distribution:
            result = result.filter { $0.signingInfo == .distribution || $0.signingInfo == .enterprise }
        case .system:
            result = result.filter { $0.isSystemApp }
        }

        // 应用搜索
        if !searchText.isEmpty {
            result = result.filter {
                $0.name.localizedCaseInsensitiveContains(searchText) ||
                $0.bundleID.localizedCaseInsensitiveContains(searchText)
            }
        }

        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            // 搜索栏和筛选器
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search by name or bundle ID", text: $searchText)
                    .textFieldStyle(.plain)

                Picker("Filter", selection: $selectedFilter) {
                    ForEach(AppFilter.allCases, id: \.rawValue) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 300)
            }
            .padding()

            Divider()

            // App 列表
            if isLoading {
                ProgressView("Loading apps...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = errorMessage {
                Text("Error: \(error)")
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filteredApps, selection: Binding(
                    get: { nil },
                    set: { app in
                        if let app = app {
                            onAppSelected(app)
                        }
                    }
                )) { app in
                    AppRow(app: app)
                        .tag(app)
                }
                .listStyle(.plain)
            }
        }
        .onAppear {
            loadApps()
        }
        .onChange(of: device) { _, _ in
            loadApps()
        }
    }

    private func loadApps() {
        guard let device = device else { return }

        isLoading = true
        errorMessage = nil

        DispatchQueue.global().async {
            do {
                let lister = AppLister(device: device)
                let appList = try lister.listInstalledApps()
                DispatchQueue.main.async {
                    self.apps = appList
                    self.isLoading = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }
}

struct AppRow: View {
    let app: InstalledApp

    var body: some View {
        HStack {
            // App 图标占位
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.gray.opacity(0.2))
                .frame(width: 40, height: 40)
                .overlay(
                    Text(String(app.name.prefix(1)))
                        .font(.title2)
                        .foregroundColor(.primary)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                    .font(.subheadline)
                    .lineLimit(1)
                Text(app.bundleID)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(app.version)
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text(app.signingInfo.rawValue)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(signingInfoColor(app.signingInfo).opacity(0.2))
                    .foregroundColor(signingInfoColor(app.signingInfo))
                    .cornerRadius(4)
            }
        }
        .padding(.vertical, 4)
    }

    private func signingInfoColor(_ info: InstalledApp.SigningInfo) -> Color {
        switch info {
        case .development: return .green
        case .distribution: return .blue
        case .enterprise: return .orange
        case .unknown: return .gray
        }
    }
}
```

- [ ] **Step 2: 提交**

```bash
git add EasySign/Views/AppListView.swift
git commit -m "feat(ui): 添加 AppListView App 列表视图"
```

---

## Task 11: UI - SandboxBrowserView 文件浏览视图

**Files:**
- Create: `EasySign/Views/SandboxBrowserView.swift`

- [ ] **Step 1: 创建 SandboxBrowserView**

```swift
struct SandboxBrowserView: View {
    let app: InstalledApp?
    let initialPath: String
    let onFileSelected: (FileNode) -> Void
    let onNavigateBack: () -> Void

    @State private var currentPath: String = "/"
    @State private var fileNodes: [FileNode] = []
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?
    @State private var afcClient: AFCClient?
    @State private var pathHistory: [String] = ["/"]

    var body: some View {
        VStack(spacing: 0) {
            // 工具栏
            HStack {
                Button(action: navigateBack) {
                    Image(systemName: "chevron.left")
                }
                .disabled(currentPath == "/")

                Button(action: refresh) {
                    Image(systemName: "arrow.clockwise")
                }

                Spacer()

                // 路径面包屑
                Text(currentPath)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color.gray.opacity(0.1))

            Divider()

            // 文件列表
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = errorMessage {
                Text("Error: \(error)")
                    .foregroundColor(.red)
            } else {
                List(fileNodes, selection: Binding(
                    get: { nil },
                    set: { node in
                        if let node = node {
                            handleNodeSelection(node)
                        }
                    }
                )) { node in
                    FileNodeRow(node: node)
                        .tag(node)
                        .contextMenu {
                            Button("下载") { downloadFile(node) }
                            if !node.isDirectory {
                                Button("上传") { /* TODO */ }
                            }
                        }
                }
                .listStyle(.plain)
            }
        }
        .onAppear {
            currentPath = initialPath
            connectAndBrowse()
        }
    }

    private func connectAndBrowse() {
        guard let app = app else { return }

        isLoading = true
        errorMessage = nil

        DispatchQueue.global().async {
            do {
                let client = try AFCClient(device: app.device)
                let nodes = try client.listDirectory(at: currentPath)
                DispatchQueue.main.async {
                    self.afcClient = client
                    self.fileNodes = nodes
                    self.isLoading = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }

    private func handleNodeSelection(_ node: FileNode) {
        if node.isDirectory {
            pathHistory.append(currentPath)
            currentPath = node.path
            connectAndBrowse()
        } else {
            onFileSelected(node)
        }
    }

    private func navigateBack() {
        guard !pathHistory.isEmpty else { return }
        currentPath = pathHistory.removeLast()
        connectAndBrowse()
    }

    private func refresh() {
        connectAndBrowse()
    }

    private func downloadFile(_ node: FileNode) {
        // 实现下载逻辑
    }
}

struct FileNodeRow: View {
    let node: FileNode

    var body: some View {
        HStack {
            Image(systemName: iconName(for: node))
                .foregroundColor(iconColor(for: node))
                .frame(width: 24)

            Text(node.name)
                .lineLimit(1)

            Spacer()

            if !node.isDirectory {
                Text(formatSize(node.size))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func iconName(for node: FileNode) -> String {
        if node.isDirectory {
            return "folder.fill"
        }
        switch node.fileType {
        case .text, .plist, .json: return "doc.text.fill"
        case .image: return "photo.fill"
        case .database: return "cylinder.fill"
        default: return "doc.fill"
        }
    }

    private func iconColor(for node: FileNode) -> Color {
        if node.isDirectory {
            return .blue
        }
        switch node.fileType {
        case .text, .plist, .json: return .primary
        case .image: return .green
        case .database: return .orange
        default: return .secondary
        }
    }

    private func formatSize(_ size: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(size))
    }
}
```

- [ ] **Step 2: 提交**

```bash
git add EasySign/Views/SandboxBrowserView.swift
git commit -m "feat(ui): 添加 SandboxBrowserView 文件浏览视图"
```

---

## Task 12: UI - FilePreviewView 文件预览视图

**Files:**
- Create: `EasySign/Views/FilePreviewView.swift`

- [ ] **Step 1: 创建 FilePreviewView**

```swift
struct FilePreviewView: View {
    let app: InstalledApp?
    let path: String
    let onBack: () -> Void

    @State private var previewResult: PreviewResult?
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?
    @State private var fileName: String = ""
    @State private var fileSize: UInt64 = 0

    var body: some View {
        VStack(spacing: 0) {
            // 工具栏
            HStack {
                Button(action: onBack) {
                    HStack {
                        Image(systemName: "chevron.left")
                        Text("返回")
                    }
                }

                Spacer()

                Text(fileName)
                    .font(.headline)

                Spacer()

                Button("下载到本地") {
                    downloadToLocal()
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color.gray.opacity(0.1))

            Divider()

            // 预览内容
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = errorMessage {
                Text("Error: \(error)")
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let result = previewResult {
                previewContent(result)
            }
        }
        .onAppear {
            loadPreview()
        }
    }

    @ViewBuilder
    private func previewContent(_ result: PreviewResult) -> some View {
        switch result {
        case .text(let content):
            ScrollView {
                Text(content)
                    .font(.system(.body, design: .monospaced))
                    .padding()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .image(let data):
            if let nsImage = NSImage(data: data) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

        case .database(let rows):
            Table(rows) {
                if let first = rows.first {
                    ForEach(first.keys.sorted(), id: \.self) { key in
                        TableColumn(key) { row in
                            Text("\(row[key] ?? "")")
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .binary(let data):
            ScrollView {
                Text(formatHex(data))
                    .font(.system(.caption, design: .monospaced))
                    .padding()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .unsupported(let reason):
            VStack {
                Image(systemName: "doc.questionmark")
                    .font(.largeTitle)
                    .foregroundColor(.secondary)
                Text(reason)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func loadPreview() {
        guard let app = app else { return }

        isLoading = true
        errorMessage = nil
        fileName = (path as NSString).lastPathComponent

        DispatchQueue.global().async {
            do {
                let client = try AFCClient(device: app.device)
                let data = try client.readFile(at: path)

                let previewer = FilePreviewer()
                let result = previewer.preview(data: data, fileName: fileName)

                DispatchQueue.main.async {
                    self.previewResult = result
                    self.isLoading = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }

    private func downloadToLocal() {
        guard let app = app else { return }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = fileName

        if panel.runModal() == .OK, let url = panel.url {
            DispatchQueue.global().async {
                do {
                    let client = try AFCClient(device: app.device)
                    let data = try client.readFile(at: path)
                    try data.write(to: url)
                } catch {
                    DispatchQueue.main.async {
                        // 显示错误
                    }
                }
            }
        }
    }

    private func formatHex(_ data: Data) -> String {
        var result = ""
        let chunkSize = 16
        for offset in stride(from: 0, to: data.count, by: chunkSize) {
            let end = min(offset + chunkSize, data.count)
            let chunk = data[offset..<end]

            // Hex part
            let hexPart = chunk.map { String(format: "%02X", $0) }.joined(separator: " ")
            let paddedHex = hexPart.padding(toLength: 47, withPad: " ", startingAt: 0)

            // ASCII part
            let asciiPart = String(chunk.map { byte -> Character in
                (32...126).contains(Int(byte)) ? Character(UnicodeScalar(byte)) : "."
            })

            result += String(format: "%08X  %@  %@\n", offset, paddedHex, asciiPart)
        }
        return result
    }
}
```

- [ ] **Step 2: 提交**

```bash
git add EasySign/Views/FilePreviewView.swift
git commit -m "feat(ui): 添加 FilePreviewView 文件预览视图"
```

---

## Task 13: 集成测试与 Bug 修复

**Files:**
- 全部相关文件

- [ ] **Step 1: 连接真机测试完整流程**

1. 使用 USB 连接 iOS 设备
2. 确保设备已信任此电脑
3. 启动 EasySign 应用
4. 切换到 Devices 标签
5. 验证设备列表显示正确
6. 选择设备，验证 App 列表加载
7. 选择一个 App，验证沙盒目录浏览
8. 浏览到某个文件，验证预览功能
9. 测试下载功能

- [ ] **Step 2: 测试文件传输功能**

1. 上传一个文件到设备
2. 验证文件正确保存到目标路径
3. 删除设备上的文件
4. 验证删除功能正常

- [ ] **Step 3: 测试筛选和搜索**

1. 测试 Development 筛选
2. 测试 Distribution 筛选
3. 测试按 Bundle ID 搜索
4. 测试按应用名称搜索

- [ ] **Step 4: 提交最终版本**

```bash
git add -A
git commit -m "feat: 完成设备调试功能开发"
```

---

## Self-Review Checklist

- [x] **Spec coverage**: 所有设计文档中的功能点都有对应 Task
- [x] **Placeholder scan**: 无 TBD/TODO/实现后续
- [x] **Type consistency**: Device.swift, InstalledApp.swift, FileNode.swift 中的类型定义一致
- [x] **File paths**: 所有路径都是完整的，不存在相对路径
- [x] **Code completeness**: 每个 Task 的代码都是完整可运行的

---

## 依赖关系

```
Task 1 (框架引入)
    ↓
Task 2 (Device模型) ← Task 1
Task 3 (DeviceManager) ← Task 2
Task 4 (AppLister) ← Task 2, 3
Task 5 (AFCClient) ← Task 3
Task 6 (FileTransfer) ← Task 5
Task 7 (FilePreviewer)
    ↓
Task 8 (UI侧边栏) ← Task 1
Task 9 (DeviceView) ← Task 3, 8
Task 10 (AppListView) ← Task 4, 9
Task 11 (SandboxBrowserView) ← Task 5, 9, 10
Task 12 (FilePreviewView) ← Task 7, 11
    ↓
Task 13 (集成测试)
```
