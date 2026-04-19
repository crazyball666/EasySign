# EasySign 设备调试功能设计

## 1. 功能概述

在 EasySign 中新增**设备调试**功能，作为日常 iOS 开发的辅助工具。功能包括：

- 查看连接的真机列表
- 查看设备上已安装的 App 列表（标注证书类型）
- 筛选 Development / Distribution 类型 App
- 递归浏览任意 App 的沙盒文件系统
- 读取文件内容（文本、图片、数据库等）
- 下载文件到 Mac 本地
- 上传文件到设备指定目录

## 2. UI 设计

### 2.1 整体布局

采用**侧边栏切换**布局，不改变现有 750x670 固定窗口尺寸。

```
┌──────────┬────────────────────────────────────────────┐
│          │                                            │
│ Resign   │              Content Area                   │
│          │                                            │
│ Devices  │   (Resign Form  或  Device Debugger)      │
│          │                                            │
│          │                                            │
└──────────┴────────────────────────────────────────────┘
   80px                    670px
```

- 侧边栏宽度：80px
- 内容区域：670px
- 侧边栏包含两个导航项：Resign（重签名）、Devices（设备调试）

### 2.2 设备调试面板布局

```
┌──────────────────────────────────────────────────────────┐
│ [刷新按钮]  Devices                            [搜索框] │
├───────────────┬────────────────────────────────────────┤
│               │                                        │
│  设备列表      │           主内容区                      │
│  - iPhone 15  │                                        │
│    iPhone 14  │   (App列表  或  文件浏览  或  文件查看) │
│               │                                        │
│               │                                        │
└───────────────┴────────────────────────────────────────┘
    150px                      520px
```

### 2.3 App 列表视图

```
┌────────────────────────────────────────────────────────┐
│ Bundle ID          名称         类型        版本      │
├────────────────────────────────────────────────────────┤
│ com.xxx.app1       App1       Development  1.0.0     │
│ com.xxx.app2       App2       Distribution 2.1.0     │
│ ...                                                   │
└────────────────────────────────────────────────────────┘

筛选器：[All] [Development] [Distribution] [System]
```

- 列表展示：Bundle ID、应用名称、证书类型、版本号
- 支持搜索：按 Bundle ID 或应用名称搜索
- 支持筛选：All / Development / Distribution / System

### 2.4 文件浏览视图

```
┌────────────────────────────────────────────────────────┐
│  📁 Documents    📁 Library    📁 tmp    📁 ...       │
├────────────────────────────────────────────────────────┤
│  ..                                            📁    │
│  📁 subFolder1                                 📁    │
│  📄 config.json                            1.2 KB   │
│  📄 debug.log                              256 KB   │
│  📄 app.db                                 512 KB   │
└────────────────────────────────────────────────────────┘
        双击文件夹进入 / 单击文件预览 / 右键菜单
```

- 工具栏：返回上级、刷新、路径面包屑
- 列表：图标、名称、大小、类型
- 右键菜单：下载、上传、删除、新建文件夹

### 2.5 文件预览视图

```
┌────────────────────────────────────────────────────────┐
│  文件名：debug.log           大小：256 KB            │
├────────────────────────────────────────────────────────┤
│                                                        │
│  [文件内容显示区]                                       │
│  - 文本：直接显示内容                                   │
│  - 图片：缩略图展示                                     │
│  - 数据库：SQLite Browser 风格表格预览                   │
│  - 其他：十六进制预览或"不支持预览"提示                   │
│                                                        │
├────────────────────────────────────────────────────────┤
│  [下载到本地]                                          │
└────────────────────────────────────────────────────────┘
```

## 3. 技术实现

### 3.1 技术选型

**核心框架：MobileDevice.framework**

- macOS 系统自带框架，Xcode/Instruments/Finder 同步都在用
- 成熟稳定，20+ 年历史
- 无需额外安装依赖，开箱即用
- 完整支持：设备管理、App 列表、沙盒文件、Crash logs、截图等

**注意**：MobileDevice.framework 是 Apple 私有框架，无官方文档，社区参考资源丰富：
- Apple 内部头文件：`MobileDevice.h`
- GitHub 参考实现：`iphoneness`、`gliderlabs`、`d-PAIRES` 等开源项目

### 3.2 架构设计

```
DeviceService/
├── DeviceManager/
│   ├── DeviceManager.swift      # 设备监听、连接管理
│   ├── Device.swift             # 设备模型（UDID、名称、系统版本）
│   └── DeviceObserver.swift     # USB 插拔事件监听
├── AppManager/
│   ├── AppLister.swift          # 获取设备已安装 App 列表
│   ├── InstalledApp.swift       # App 模型（Bundle ID、名称、签名类型等）
│   └── AppFilter.swift          # App 筛选逻辑
├── SandboxBrowser/
│   ├── AFCClient.swift          # AFC 文件服务客户端
│   ├── FileNode.swift          # 文件/目录模型
│   └── SandboxBrowser.swift    # 沙盒浏览逻辑
├── FileTransfer/
│   ├── FileDownloader.swift     # 设备文件下载到本地
│   └── FileUploader.swift      # 本地文件上传到设备
└── Preview/
    ├── FilePreviewer.swift      # 文件预览工厂
    ├── TextPreviewer.swift      # 文本文件预览
    ├── ImagePreviewer.swift     # 图片预览
    └── DatabasePreviewer.swift  # SQLite 数据库预览
```

### 3.3 MobileDevice.framework 核心 API

**设备相关：**
```c
// 获取连接设备列表
AMDeviceRef* (*DeviceCopySupportedDevices)(void);

// 创建设备连接
AMDeviceRef AMDeviceCreateCopyFromDevice(AMDeviceRef, ...);
int AMDeviceConnect(AMDeviceRef);
int AMDeviceIsPaired(AMDeviceRef);
int AMDeviceValidatePairing(AMDeviceRef);
int AMDeviceStartSession(AMDeviceRef);

// 获取设备信息
CFStringRef AMDeviceCopyValue(AMDeviceRef, CFStringRef, CFStringRef);
```

**App 列表相关：**
```c
// 获取已安装 App 列表
int AMDeviceLookupApplicationImages(AMDeviceRef, CFDictionaryRef, ...);
```

**AFC 文件服务相关：**
```c
// 打开 AFC 服务
int AMDeviceStartService(AMDeviceRef, CFStringRef, AFCConnectionRef*, ...);

// AFC 操作
int AFCConnectionOpen(AFCConnectionRef, UInt32, AFCConnectionRef*);
int AFCDirectoryOpen(AFCConnectionRef, const char*, AFCDirectoryRef*);
int AFCDirectoryRead(AFCDirectoryRef, AFCDirectoryEntry*);
int AFCDirectoryCreate(AFCConnectionRef, const char*);
int AFCFileInfoOpen(AFCConnectionRef, const char*, AFCFileInfoRef*);
int AFCFileRefOpen(AFCConnectionRef, const char*, UInt32, AFCFileRef*);
int AFCFileRefRead(AFCConnectionRef, AFCFileRef, void*, UInt32*);
int AFCFileRefWrite(AFCConnectionRef, AFCFileRef, const void*, UInt32);
int AFCFileRefClose(AFCConnectionRef, AFCFileRef);
int AFCRemovePath(AFCConnectionRef, const char*);
```

### 3.4 数据流

```
[USB 插入]
    ↓
DeviceManager 监听到设备连接
    ↓
获取设备列表，更新 UI 设备列表
    ↓
[用户选择设备]
    ↓
AppLister 获取 App 列表
    ↓
显示 App 列表（带证书类型标注）
    ↓
[用户选择 App + 点击"浏览沙盒"]
    ↓
AFCClient 连接 AFC 服务
    ↓
AFCConnectionOpen 获取 AFCConnectionRef
    ↓
AFCDirectoryOpen 列出根目录
    ↓
用户递归浏览 → AFCDirectoryRead 读取目录项
    ↓
[用户选择文件]
    ↓
AFCFileRefOpen + AFCFileRefRead 读取内容
    ↓
FilePreviewer 根据文件类型预览
    ↓
[用户选择下载/上传]
    ↓
FileDownloader / FileUploader 执行传输
```

### 3.5 证书类型判断

通过 `AMDeviceLookupApplicationImages` 获取的 App 信息中，`SignerIdentity` 字段标识签名证书：

- 包含 `Apple Development`：Development 类型
- 包含 `Apple Distribution` 或无 Development：Distribution 类型
- 包含 `iPhone Developer`：Development 类型
- 系统 App（/Applications）：System 类型

### 3.6 文件类型预览支持

| 文件类型 | 预览方式 |
|---------|---------|
| .txt / .log / .json / .xml / .plist | 文本直接显示 |
| .png / .jpg / .jpeg / .gif / .bmp | NSImage / SwiftUI Image 渲染 |
| .db / .sqlite / .sqlite3 | SQLite 表格预览 |
| 其他 | 十六进制 + ASCII 预览，或提示"不支持预览" |

### 3.7 沙盒路径

iOS App 沙盒根目录通过 AFC 访问，常见路径：
- `/Documents`：持久化数据
- `/Library`：应用数据
- `/Library/Caches`：缓存
- `/tmp`：临时文件

App 的 Bundle 内容在 `/Container` 下，但 AFC 默认只能访问沙盒目录。

## 4. 依赖项

无外部依赖，直接链接系统框架：

```ruby
# EasySign.entitlements 或 Xcode 配置
# 无需额外设置，MobileDevice.framework 为系统自带
```

如需加密传输，可能额外引入 OpenSSL（项目中已有）。

## 5. 错误处理

| 场景 | 处理方式 |
|-----|---------|
| USB 断开 | DeviceObserver 监听到断开事件，UI 显示设备离线，可选自动重连 |
| AFC 连接失败 | 弹窗提示"无法访问沙盒，请确认设备已信任此电脑" |
| 文件读取失败 | 日志输出 + UI 提示"读取失败：Permission denied" |
| 文件传输中断 | 支持断点续传或重新传输 |
| App 安装/卸载事件 | 刷新 App 列表 |

## 6. 后续扩展功能（可选）

- Crash logs 查看
- 设备截图
- App 运行日志实时查看（libimobiledevice 的 idevicesyslog）
- 控制台输出监听
