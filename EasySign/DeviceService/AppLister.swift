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

        // 3. Create options dictionary with return attributes
        let options: [String: Any] = [
            "LookupReturnAttributesKey": ["CFBundleIdentifier", "CFBundleName", "CFBundleShortVersionString", "CFBundleVersion", "Path", "SignerIdentity"]
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
                isSystemApp: isSystemApp,
                device: device
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