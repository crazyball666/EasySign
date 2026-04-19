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

        // 2. Call AMDeviceLookupApplicationImages
        var result: Unmanaged<CFDictionary>?
        let status = AMDeviceLookupApplicationImages(deviceRef, 0, &result)

        guard status == AMDAppLEDETECT_SUCCESS,
              let dict = result?.takeRetainedValue() as? [String: Any] else {
            throw DeviceError.lookupFailed
        }

        // 3. Parse the returned App list
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