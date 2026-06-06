import Foundation

final class AppLister {
    private let device: Device

    init(device: Device) {
        self.device = device
    }

    func listInstalledApps() throws -> [InstalledApp] {
        // 1. Ensure device is connected and in session
        guard let deviceRef = DeviceManager.shared.getConnectedDeviceRef(for: device.id) else {
            throw DeviceError.notConnected
        }

        // 2. Start the installation_proxy service with options
        print("[AppLister] Starting installation_proxy service...")
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
        print("[AppLister] AMDeviceStartServiceWithOptions result: \(serviceResult), socket: \(String(describing: connection))")

        // 3. Create options dictionary with return attributes.
        // ApplicationType distinguishes System / User / Internal / Hidden — much
        // more reliable than guessing from path prefix.
        let options: [String: Any] = [
            "LookupReturnAttributesKey": [
                "CFBundleIdentifier",
                "CFBundleDisplayName",
                "CFBundleName",
                "CFBundleShortVersionString",
                "CFBundleVersion",
                "Path",
                "SignerIdentity",
                "ApplicationType",
            ]
        ]

        print("[AppLister] Calling AMDeviceLookupApplications with options")

        // 4. Call AMDeviceLookupApplications with options dictionary
        var result: Unmanaged<CFDictionary>?
        let status = AMDeviceLookupApplications(deviceRef, options as CFDictionary, &result)

        print("[AppLister] AMDeviceLookupApplications status: \(status)")

        guard status == AMDAppLEDETECT_SUCCESS,
              let dict = result?.takeRetainedValue() as? [String: Any] else {
            print("[AppLister] Lookup failed, result: \(String(describing: result))")
            throw DeviceError.lookupFailed
        }

        print("[AppLister] Lookup succeeded, dict keys: \(dict.keys)")

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
            let isSystemApp = (appType == "System") || path.hasPrefix("/Applications/")
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
                device: device
            )
        }
    }

    private func parseSigningInfo(_ signerIdentity: String, isSystem: Bool) -> InstalledApp.SigningInfo {
        if isSystem { return .system }
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