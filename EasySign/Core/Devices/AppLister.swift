import Foundation

final class AppLister {
    private let device: Device

    init(device: Device) {
        self.device = device
    }

    /// 向 installation_proxy 索取的属性。前 9 个供列表行使用,其余供「应用详情」弹窗。
    static let lookupAttributes = [
        "CFBundleIdentifier",
        "CFBundleDisplayName",
        "CFBundleName",
        "CFBundleShortVersionString",
        "CFBundleVersion",
        "CFBundleExecutable",
        "Path",
        "SignerIdentity",
        "ApplicationType",
        // ↓ 详情弹窗
        "Container",
        "GroupContainers",
        "Entitlements",
        "MinimumOSVersion",
        "UIDeviceFamily",
        "UIFileSharingEnabled",
        "CFBundleURLTypes",
        "UIBackgroundModes",
        "ApplicationDSID",
        "IsAppClip",
        "IsUpgradeable",
        "CFBundleDevelopmentRegion",
        "CFBundleSupportedPlatforms",
        "DTSDKName",
        "DTPlatformVersion",
        "DTXcode",
    ]

    func listInstalledApps() throws -> [InstalledApp] {
        // 1. Ensure device is connected and in session
        guard let deviceRef = DeviceManager.shared.getConnectedDeviceRef(for: device.id) else {
            throw DeviceError.notConnected
        }

        // 2. Start the installation_proxy service with options
        DeviceManager.shared.logger?.log(.debug, tool: "devices", "[AppLister] Starting installation_proxy service...")
        var connection: AFCConnectionRef?
        let serviceOptions: [String: Any] = [
            "Clutch": false as Any,
            "StartSyncServiceIfNeeded": false as Any
        ]
        let serviceResult = AMDeviceStartServiceWithOptions(
            deviceRef,
            "com.apple.mobile.installation_proxy" as CFString,
            serviceOptions as CFDictionary,
            &connection,
            nil
        )
        DeviceManager.shared.logger?.log(.debug, tool: "devices", "[AppLister] AMDeviceStartServiceWithOptions result: \(serviceResult), socket: \(String(describing: connection))")

        // 3. Create options dictionary with return attributes.
        // ApplicationType distinguishes System / User / Internal / Hidden — much
        // more reliable than guessing from path prefix.
        //
        // 不传 LookupReturnAttributesKey 会返回每个 App 的**整个 Info.plist**
        // (实测一台设备上 620 个不同的键,大半是各家 App 私有配置),又慢又没用。
        // 这里显式列出要的字段;实测 319 个 App 全量返回 0.46s。
        let options: [String: Any] = [
            "LookupReturnAttributesKey": AppLister.lookupAttributes
        ]

        DeviceManager.shared.logger?.log(.debug, tool: "devices", "[AppLister] Calling AMDeviceLookupApplications with options")

        // 4. Call AMDeviceLookupApplications with options dictionary
        var result: Unmanaged<CFDictionary>?
        let status = AMDeviceLookupApplications(deviceRef, options as CFDictionary, &result)

        DeviceManager.shared.logger?.log(.debug, tool: "devices", "[AppLister] AMDeviceLookupApplications status: \(status)")

        guard status == AMDAppLEDETECT_SUCCESS,
              let dict = result?.takeRetainedValue() as? [String: Any] else {
            DeviceManager.shared.logger?.log(.debug, tool: "devices", "[AppLister] Lookup failed, result: \(String(describing: result))")
            throw DeviceError.lookupFailed
        }

        DeviceManager.shared.logger?.log(.debug, tool: "devices", "[AppLister] Lookup succeeded, dict keys: \(dict.keys)")

        // 4. Parse the returned App list
        return parseAppList(from: dict)
    }

    private func parseAppList(from dict: [String: Any]) -> [InstalledApp] {
        // AMDeviceLookupApplications with LookupReturnAttributesKey returns a flat
        // map of bundleID → attributes dict, not a nested {"ApplicationDictionaryKey": [...]}.
        return dict.compactMap { (bundleID, value) -> InstalledApp? in
            guard let appDict = value as? [String: Any] else { return nil }

            // CFBundleDisplayName is the localized user-facing name (e.g. 微信);
            // CFBundleName is the internal name (e.g. WeChat). Prefer the former.
            let displayName = appDict["CFBundleDisplayName"] as? String
            let name = displayName ?? (appDict[kCFBundleNameKey] as? String) ?? bundleID
            let version = appDict[kCFBundleShortVersionStringKey] as? String ?? ""
            let buildVersion = appDict[kCFBundleVersionKey] as? String ?? ""
            let signerIdentity = appDict["SignerIdentity"] as? String ?? ""
            let appType = appDict["ApplicationType"] as? String ?? ""
            let path = appDict[kAppLookupInfoImagePathKey] as? String ?? ""

            // ApplicationType is authoritative for System vs User. Fall back to
            // path prefix if for some reason the field is missing.
            //
            // Hidden 也算系统:实测这一档全是 /System/Library/CoreServices/ 下的 Apple
            // 组件(SpringBoard、旁白、CarPlay…)。漏掉它会连错三处 —— badge 显示
            // Unknown、被 User 筛选器收进去、还多出一个必定失败的卸载按钮。
            let isSystemApp = appType == "System"
                || appType == "Hidden"
                || path.hasPrefix("/Applications/")
                || path.hasPrefix("/System/Library/CoreServices/")
            let signingInfo = parseSigningInfo(signerIdentity, isSystem: isSystemApp)

            return InstalledApp(
                id: bundleID,
                bundleID: bundleID,
                name: name,
                version: version,
                buildVersion: buildVersion,
                signingInfo: signingInfo,
                path: path,
                isSystemApp: isSystemApp,
                device: device,
                detail: parseDetail(appDict, signerIdentity: signerIdentity, appType: appType)
            )
        }
    }

    /// SignerIdentity → 签名类型。
    ///
    /// 分支取自实测(一台设备 319 个 App)出现过的真实取值:
    ///   - "Apple iPhone OS Application Signing" —— App Store 下载,**最常见**(65/67 个用户 App)
    ///   - "TestFlight Beta Distribution"
    ///   - "iPhone Distribution: <公司>" —— 旧式命名,新式才是 "Apple Distribution: <公司>"
    /// 早期版本只认 Apple Development / Apple Distribution / Apple Enterprise,
    /// 结果上面三种全部落到 unknown —— 整列 badge 显示 Unknown,零信息量。
    ///
    /// 局限:企业签名(In-House)与普通分发签名的证书名同样是 "iPhone/Apple Distribution: 公司",
    /// 光看 SignerIdentity 区分不了,要靠描述文件里的 ProvisionsAllDevices。这里一律归 distribution,
    /// 只有证书名里明写 Enterprise 才判 enterprise。
    private func parseSigningInfo(_ signerIdentity: String, isSystem: Bool) -> InstalledApp.SigningInfo {
        if isSystem { return .system }
        if signerIdentity.isEmpty { return .unknown }
        if signerIdentity.contains("Apple iPhone OS Application Signing") { return .appStore }
        if signerIdentity.contains("TestFlight") { return .testFlight }
        if signerIdentity.contains("Apple Development") || signerIdentity.contains("iPhone Developer") {
            return .development
        }
        if signerIdentity.contains("Enterprise") { return .enterprise }
        if signerIdentity.contains("Apple Distribution") || signerIdentity.contains("iPhone Distribution") {
            return .distribution
        }
        return .unknown
    }

    private func parseDetail(_ dict: [String: Any], signerIdentity: String, appType: String) -> AppDetail {
        var d = AppDetail()
        d.applicationType = appType
        d.signerIdentity = signerIdentity
        d.executable = dict["CFBundleExecutable"] as? String ?? ""
        d.developmentRegion = dict["CFBundleDevelopmentRegion"] as? String ?? ""
        d.container = dict["Container"] as? String ?? ""
        d.minimumOSVersion = dict["MinimumOSVersion"] as? String ?? ""
        d.sdkName = dict["DTSDKName"] as? String ?? ""
        d.platformVersion = dict["DTPlatformVersion"] as? String ?? ""
        d.xcodeVersion = dict["DTXcode"] as? String ?? ""
        d.supportedPlatforms = dict["CFBundleSupportedPlatforms"] as? [String] ?? []
        d.deviceFamilies = (dict["UIDeviceFamily"] as? [NSNumber])?.map(\.intValue) ?? []
        d.fileSharingEnabled = (dict["UIFileSharingEnabled"] as? Bool) ?? false
        d.backgroundModes = dict["UIBackgroundModes"] as? [String] ?? []
        d.isAppClip = (dict["IsAppClip"] as? Bool) ?? false
        d.isUpgradeable = (dict["IsUpgradeable"] as? Bool) ?? false
        // DSID 是 64 位整数,plist 里可能是 NSNumber 也可能是字符串。
        if let n = dict["ApplicationDSID"] as? NSNumber {
            d.applicationDSID = n.stringValue
        } else {
            d.applicationDSID = dict["ApplicationDSID"] as? String ?? ""
        }

        // CFBundleURLTypes: [{ CFBundleURLSchemes: [scheme, …] }, …] → 扁平去重
        if let types = dict["CFBundleURLTypes"] as? [[String: Any]] {
            var seen = Set<String>()
            for t in types {
                for s in (t["CFBundleURLSchemes"] as? [String] ?? []) where seen.insert(s).inserted {
                    d.urlSchemes.append(s)
                }
            }
        }

        if let groups = dict["GroupContainers"] as? [String: Any] {
            d.groupContainers = groups
                .map { KeyValue(key: $0.key, value: String(describing: $0.value)) }
                .sorted { $0.key < $1.key }
        }
        if let ent = dict["Entitlements"] as? [String: Any] {
            d.entitlements = ent
                .map { KeyValue(key: $0.key, value: AppLister.displayString(for: $0.value)) }
                .sorted { $0.key < $1.key }
        }
        return d
    }

    /// entitlement 的值可能是 Bool/数字/字符串/数组/字典,统一压成一行可读文本。
    private static func displayString(for value: Any) -> String {
        // 必须先用 CFBooleanGetTypeID 认布尔:plist 里的 true/false 桥成 NSNumber,
        // 直接 `as? Bool` 会把整数 1/0 也吃掉,数值型 entitlement 就被显示成「是/否」。
        if CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID() {
            return (value as? Bool) == true ? "是" : "否"
        }
        switch value {
        case let s as String:
            return s
        case let n as NSNumber:
            return n.stringValue
        case let arr as [Any]:
            return arr.map { displayString(for: $0) }.joined(separator: ", ")
        default:
            return String(describing: value)
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "    ", with: "")
        }
    }
}