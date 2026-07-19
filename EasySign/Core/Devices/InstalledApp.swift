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
    let device: Device
    let detail: AppDetail

    enum SigningInfo: String {
        case appStore = "App Store"
        case testFlight = "TestFlight"
        case development = "Development"
        case distribution = "Distribution"
        case enterprise = "Enterprise"
        case system = "System"
        case unknown = "Unknown"
    }

    // What to show on the badge in the app row.
    var badgeLabel: String {
        isSystemApp ? SigningInfo.system.rawValue : signingInfo.rawValue
    }
}

/// installation_proxy 一次 Lookup 就能带回的附加属性(实测 319 个 App 全量 0.46s),
/// 供「应用详情」弹窗展示。只放**可显示的标量/字符串**,不放 [String: Any] ——
/// InstalledApp 需要保持 Hashable。
struct AppDetail: Hashable {
    /// User / System / Hidden —— 比 isSystemApp 多一档,系统隐藏 App 走 Hidden。
    var applicationType: String = ""
    var signerIdentity: String = ""
    var executable: String = ""
    var developmentRegion: String = ""
    /// 数据容器(sandbox)真实路径。
    var container: String = ""
    var groupContainers: [KeyValue] = []
    var minimumOSVersion: String = ""
    var sdkName: String = ""
    var platformVersion: String = ""
    var xcodeVersion: String = ""
    var supportedPlatforms: [String] = []
    var deviceFamilies: [Int] = []
    /// 开启后 Documents 才对 house_arrest 可见;关着的话文件浏览必然失败。
    var fileSharingEnabled: Bool = false
    var urlSchemes: [String] = []
    var backgroundModes: [String] = []
    /// 购买该 App 的 Apple 账号 DSID,只有 App Store 安装的才有。
    var applicationDSID: String = ""
    var isAppClip: Bool = false
    var isUpgradeable: Bool = false
    var entitlements: [KeyValue] = []

    /// Entitlements 里的 application-identifier 前缀就是 Team ID。
    var teamID: String {
        if let v = entitlements.first(where: { $0.key == "com.apple.developer.team-identifier" })?.value {
            return v
        }
        guard let appID = entitlements.first(where: { $0.key == "application-identifier" })?.value,
              let dot = appID.firstIndex(of: ".") else { return "" }
        return String(appID[appID.startIndex..<dot])
    }

    /// UIDeviceFamily 数字 → 人话。
    var deviceFamilyText: String {
        let names = deviceFamilies.map { code -> String in
            switch code {
            case 1: "iPhone"
            case 2: "iPad"
            case 3: "Apple TV"
            case 4: "Apple Watch"
            case 6: "Mac"
            case 7: "Vision"
            default: "未知(\(code))"
            }
        }
        return names.joined(separator: " / ")
    }
}

/// 详情弹窗里的一行键值。值统一压成字符串,保住 Hashable。
struct KeyValue: Hashable, Identifiable {
    var id: String { key }
    let key: String
    let value: String
}
