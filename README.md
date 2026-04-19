# EasySign

macOS 上的 iOS IPA 重签名工具，通过图形界面快速对 IPA 或 .app 包进行证书重签名。

## 功能特性

- 支持 IPA 和 .app 两种输入格式
- 支持修改应用元数据（Bundle ID、应用名称、版本号、构建号）
- 支持编辑 entitlements 权限文件
- 支持单独对 App Extension（Appex）使用不同证书重签名
- 支持 5 种导出类型：App Store、Development、Ad-Hoc、Enterprise、Validation
- 实时日志输出
- 用户配置自动保存

## 系统要求

- macOS 13.0+
- Xcode 15.2+
- 已安装 Xcode Command Line Tools

## 编译构建

```bash
# 使用 Xcode 打开并编译
open EasySign.xcodeproj

# 或使用命令行编译
xcodebuild -project EasySign.xcodeproj -scheme EasySign -configuration Debug build
xcodebuild -project EasySign.xcodeproj -scheme EasySign -configuration Release build
```

## 使用方法

1. **选择输入文件**：点击 "Select" 按钮选择 IPA 文件或 .app 目录
2. **点击 Update**：解析并显示应用的详细信息
3. **配置签名**：
   - P12 文件：选择证书文件（.p12 或 .p12）
   - P12 密码：输入证书密码
   - Mobileprovision：选择对应的描述文件（.mobileprovision）
4. **选择导出类型**：Development / Ad-Hoc / Enterprise / App Store / Validation
5. **设置输出目录**：选择重签名后 IPA 的输出位置
6. **开始重签名**：点击 "Start" 按钮，等待完成

## 项目结构

```
EasySign/
├── EasySignApp.swift          # 应用入口
├── ContentView.swift          # 主界面视图和 ViewModel
├── IPAContentView.swift       # IPA 详情编辑弹窗
├── ResignService/            # 核心重签名逻辑
│   ├── Model/
│   │   ├── IPA.swift         # IPA 文件解析
│   │   ├── AppBundle.swift   # .app 包解析和管理
│   │   ├── BaseBundle.swift  # Bundle 基类（Info.plist 读写）
│   │   ├── AppexBundle.swift # App Extension 解析
│   │   ├── ResignTask.swift  # 重签名任务编排
│   │   ├── ResignTaskInfo.swift # 重签名参数模型
│   │   ├── PKCS12.swift      # P12 证书解析
│   │   ├── MobileProvision.swift # 描述文件解析
│   │   ├── SecCertificate.swift # 证书扩展（Security.framework）
│   │   ├── SecIdentity.swift  # 证书身份扩展
│   │   └── Logger.swift       # 日志协议
│   ├── Utils/
│   │   ├── TaskCenter.swift   # Shell 命令执行器
│   │   └── PathManager.swift  # 路径管理工具
│   └── Ext/                   # 扩展
│       ├── NSError.swift      # 自定义错误初始化
│       ├── Date.swift         # 日期格式化
│       └── Data.swift         # 数据转换
├── Resources/
│   ├── resign_template/       # xcarchive 导出模板
│   │   ├── Info.plist
│   │   └── ExportOptions.plist
│   └── resign_tools/          # 重签名工具
│       └── optool
└── Vendor/                    # 第三方依赖
    └── OpenSSL/              # OpenSSL xcframework
```

## 重签名流程

`ResignTask.Start()` 完整流程：

1. **解压 IPA**：将 IPA 解压到临时工作区
2. **解析应用包**：读取 Payload/.app 目录
3. **更新元数据**：修改 Bundle ID、应用名称、版本等信息
4. **清理无用文件**：删除 .DS_Store、__MACOSX 等
5. **安装证书**：加载 P12 证书文件
6. **安装描述文件**：安装 Mobileprovision 到系统
7. **重签名动态库**：遍历 .dylib 和 .framework 进行 codesign
8. **重签名 Appex**：对插件使用指定证书重签名（可选）
9. **更新 Entitlements**：根据导出类型调整权限配置
10. **重签名主 App**：使用新证书和权限签名整个应用
11. **导出 IPA**：通过 xcodebuild -exportArchive 生成最终 IPA

## 导出类型说明

| 类型 | 说明 | get-task-allow | beta-reports-active |
|------|------|----------------|---------------------|
| App Store | 发布到 App Store | false | true |
| Development | 开发测试 | true | - |
| Ad-Hoc | 内测分发 | true | true |
| Enterprise | 企业证书 | true | true |
| Validation | 校验模式 | true | true |

## 技术依赖

- **Swift 5.0+**：主要编程语言
- **SwiftUI**：图形界面框架
- **Security.framework**：证书和密钥操作
- **CryptoSwift**：数据摘要计算（通过 SPM 引入）
- **OpenSSL.xcframework**：加密相关操作（Vendored）
- **xcodebuild**：IPA 导出工具（系统自带）
