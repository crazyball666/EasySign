// swift-tools-version: 5.9
import PackageDescription

// PreviewKit —— IPA / mobileprovision 的解析与预览渲染。
// 主 App、EasySignQuickLook、EasySignThumbnail 三个 target 共享这一份代码,
// 由本地包提供(编译期强制),取代原先在 pbxproj 里逐文件挂 target membership。
let package = Package(
    name: "PreviewKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PreviewKit", targets: ["PreviewKit"]),
    ],
    targets: [
        .target(name: "PreviewKit"),
    ]
)
