# EasySign zsign 后端说明

## 目标

EasySign 现在保留原有的系统重签逻辑，并新增一个内嵌的 zsign 后端。用户安装 App 后即可直接使用默认的 zsign 重签，不需要额外安装 zsign 命令行、OpenSSL 或其他运行环境。

## 后端选择

主界面新增 `Sign Backend` 选项：

- `zsign`：默认后端。使用内嵌的 zsign C++ 源码、内嵌 minizip/zlib、内嵌 OpenSSL 3.5.6，对 App 解包后的 `.app` 进行签名并直接打包 IPA。
- `系统 codesign`：原有后端。继续使用当前 EasySign 的 `codesign`、描述文件安装、`xcodebuild -exportArchive` 流程。

主界面还提供 `动态库注入` 区域，启用后可以选择一个或多个 `.dylib`，也可以直接粘贴路径；已选择的动态库支持逐个移除或一键清空。未启用时不会把动态库路径传给重签任务，也不会改变原有重签行为。

## zsign 后端流程

1. 复用 EasySign 现有逻辑解包 IPA 或复制 `.app` 到临时工作区。
2. 复用现有包信息修改逻辑，支持 Bundle ID、应用名称、外置版本号、内置版本号。
3. 复用现有 entitlements 生成和过滤逻辑，根据描述文件 Team ID、导出类型修正权利字。
4. 如果选择了注入动态库，将 dylib 路径一并交给 `ZSignBridge`。
5. 将处理后的 `.app`、p12、密码、mobileprovision、entitlements 文件交给 `ZSignBridge`。
6. `ZSignBridge` 在进程内调用 zsign 的 `ZSignAsset` 和 `ZBundle`，完成递归签名并打包 IPA。

## 动态库注入

- 选择的 `.dylib` 会按文件名复制到 App 根目录，也就是主可执行文件同级目录。
- 注入的 Mach-O load command 使用 `@executable_path/<dylib 文件名>`。
- zsign 后端使用 zsign 内部的注入能力，注入后由 zsign 统一递归签名。
- `系统 codesign` 后端同样通过内嵌 zsign 源码里的 `ZMachO::InjectDylib` 修改主可执行文件，随后复用原有动态库重签和 App 重签流程。
- 如果选择了多个同名 dylib，EasySign 会直接报错，避免互相覆盖。

## 内嵌依赖

- zsign 源码位于 `EasySign/Vendor/ZSign`。
- OpenSSL 位于 `EasySign/Vendor/OpenSSL/OpenSSL.xcframework`，当前版本为 OpenSSL 3.5.6。
- OpenSSL 通过 `scripts/build-openssl-macos-xcframework.sh` 重新构建，产物为 macOS arm64/x86_64 通用静态 framework。
- zsign 使用同一份内嵌 OpenSSL，不再引入第二套 OpenSSL。

## 已知边界

- zsign 后端当前使用 App 的 p12 和 mobileprovision 递归签名主 App 及其内嵌内容。
- 如果需要为 Appex 配置独立证书和描述文件，请选择 `系统 codesign` 后端；这条旧流程仍然保留。
- zsign 后端不会调用 `xcodebuild -exportArchive`，导出类型主要用于生成 entitlements。

## 验证

建议改动后至少运行：

```bash
swiftc EasySign/ResignService/Model/DylibInjection.swift Tests/DylibInjectionTests.swift -o /tmp/easysign-dylib-injection-tests && /tmp/easysign-dylib-injection-tests
sh Tests/SourceInjectionBackendTests.sh
xcodebuild -project EasySign.xcodeproj -scheme EasySign -configuration Debug build
xcodebuild -project EasySign.xcodeproj -scheme EasySign -configuration Release build
```

如需确认没有外部 OpenSSL 动态依赖，可对构建产物执行：

```bash
otool -L /path/to/EasySign.app/Contents/MacOS/EasySign
```
