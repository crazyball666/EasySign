import Foundation
import Combine

// MARK: - MobileDevice C API Declarations

@_silgen_name("AMDCreateDeviceList")
func AMDCreateDeviceList() -> CFArray?

@_silgen_name("AMDeviceConnect")
func AMDeviceConnect(_ device: AMDeviceRef) -> Int32

@_silgen_name("AMDeviceDisconnect")
func AMDeviceDisconnect(_ device: AMDeviceRef) -> Int32

@_silgen_name("AMDeviceIsPaired")
func AMDeviceIsPaired(_ device: AMDeviceRef) -> Int32

@_silgen_name("AMDeviceValidatePairing")
func AMDeviceValidatePairing(_ device: AMDeviceRef) -> Int32

@_silgen_name("AMDeviceStartSession")
func AMDeviceStartSession(_ device: AMDeviceRef) -> Int32

@_silgen_name("AMDeviceStopSession")
func AMDeviceStopSession(_ device: AMDeviceRef) -> Int32

@_silgen_name("AMDeviceCopyValue")
func AMDeviceCopyValue(_ device: AMDeviceRef, _ domain: UInt32, _ key: CFString) -> CFTypeRef?

@_silgen_name("AMDeviceNotificationSubscribe")
func AMDeviceNotificationSubscribe(
    _ callback: AMDeviceNotificationCallback,
    _ unknown1: UInt32,
    _ unknown2: UInt32,
    _ userInfo: UnsafeMutableRawPointer?,
    _ notifyPort: UnsafeMutableRawPointer?
) -> Int32

@_silgen_name("AMDeviceNotificationUnsubscribe")
func AMDeviceNotificationUnsubscribe(_ notifyPort: UnsafeMutableRawPointer) -> Int32

@_silgen_name("AMDeviceStartService")
func AMDeviceStartService(
    _ device: AMDeviceRef,
    _ serviceName: CFString,
    _ connection: UnsafeMutablePointer<AFCConnectionRef?>?,
    _ unknown: UnsafeMutableRawPointer?
) -> Int32

@_silgen_name("AMDeviceStartServiceWithOptions")
func AMDeviceStartServiceWithOptions(
    _ device: AMDeviceRef,
    _ serviceName: CFString,
    _ options: CFDictionary?,
    _ connection: UnsafeMutablePointer<AFCConnectionRef?>?,
    _ unknown: UnsafeMutableRawPointer?
) -> Int32

@_silgen_name("AMDeviceLookupApplications")
func AMDeviceLookupApplications(
    _ device: AMDeviceRef,
    _ options: CFDictionary?,
    _ result: UnsafeMutablePointer<Unmanaged<CFDictionary>?>?
) -> Int32

@_silgen_name("AFCConnectionOpen")
func AFCConnectionOpen(_ connection: AFCConnectionRef, _ unused: UInt32, _ connectionRef: UnsafeMutablePointer<AFCConnectionRef?>?) -> Int32

@_silgen_name("AFCConnectionClose")
func AFCConnectionClose(_ connection: AFCConnectionRef) -> Int32

// MARK: - Type Aliases

typealias AMDeviceRef = UnsafeMutableRawPointer
typealias AFCConnectionRef = UnsafeMutableRawPointer
typealias AMDeviceNotificationCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void

// MARK: - Error Codes

let AMDAppLEDETECT_SUCCESS: Int32 = 0
private let kAMDeviceConnected: UInt32 = 1
private let kAMDeviceDisconnected: UInt32 = 2

// MARK: - Device Errors

enum DeviceError: LocalizedError {
    case notConnected
    case lookupFailed
    case connectionFailed

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Device is not connected"
        case .lookupFailed:
            return "Failed to lookup applications on device"
        case .connectionFailed:
            return "Failed to connect to device"
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let deviceConnected = Notification.Name("DeviceConnected")
    static let deviceDisconnected = Notification.Name("DeviceDisconnected")
}

// MARK: - MobileDevice Constants

let kCFBundleIdentifierKey = "CFBundleIdentifier"
let kCFBundleNameKey = "CFBundleName"
let kCFBundleShortVersionStringKey = "CFBundleShortVersionString"
let kCFBundleVersionKey = "CFBundleVersion"
let kAppLookupInfoAppDictKey = "ApplicationDictionaryKey"
let kAppLookupInfoImagePathKey = "Path"
let kLookupReturnAttributesKey = "LookupReturnAttributesKey"

// MARK: - Global Callback Function

// This callback is called from C code on a background thread
// IMPORTANT: Don't try to access the info pointer directly - its structure is
// private and may vary between SDK versions. Just use it as a trigger to refresh.
private func deviceNotificationCallback(_ info: UnsafeMutableRawPointer?, _ userInfo: UnsafeMutableRawPointer?) {
    // Just post notification to refresh - don't try to parse the info structure
    DispatchQueue.main.async {
        NotificationCenter.default.post(name: .deviceConnected, object: nil)
    }
}

// MARK: - DeviceManager

final class DeviceManager: ObservableObject {
    static let shared = DeviceManager()

    @Published private(set) var devices: [Device] = []
    @Published private(set) var connectedDevice: Device?
    @Published private(set) var isConnected: Bool = false

    private var deviceNotificationPort: UnsafeMutableRawPointer?
    private var runLoopSource: CFRunLoopSource?
    private var connectedDeviceRef: AMDeviceRef?
    private var notificationObserverConnected: NSObjectProtocol?
    private var notificationObserverDisconnected: NSObjectProtocol?
    private var pollingTimer: Timer?

    // MARK: - Notification Names (unused now, but keeping for future use)

    enum DeviceNotification {
        static let connected = Notification.Name("DeviceConnected")
        static let disconnected = Notification.Name("DeviceDisconnected")
    }

    private init() {}

    // MARK: - Public Methods

    func refreshDevices() {
        devices = fetchDevices()
    }

    func getConnectedDeviceRef(for deviceID: String) -> AMDeviceRef? {
        guard isConnected,
              let connected = connectedDevice,
              connected.id == deviceID,
              let ref = connectedDeviceRef else {
            return nil
        }
        return ref
    }

    func connect(to device: Device) -> Bool {
        // Find the device reference
        guard let deviceListRef = AMDCreateDeviceList() else {
            return false
        }
        let typeID = CFGetTypeID(deviceListRef)
        guard typeID == CFArrayGetTypeID() else {
            return false
        }
        let deviceList = deviceListRef as! CFArray
        let count = CFArrayGetCount(deviceList)

        var foundRef: AMDeviceRef?
        for i in 0..<count {
            let cfValue = CFArrayGetValueAtIndex(deviceList, i)
            let ref = unsafeBitCast(cfValue, to: AMDeviceRef.self)

            let connectResult = AMDeviceConnect(ref)
            if connectResult != AMDAppLEDETECT_SUCCESS {
                continue
            }

            if let udid = AMDeviceCopyValue(ref, 0, "UniqueDeviceID" as CFString) as? String,
               udid == device.id {
                foundRef = ref
                break
            }
            // Not the device we want, disconnect
            _ = AMDeviceDisconnect(ref)
        }

        guard let deviceRef = foundRef else {
            print("[DeviceManager] Device not found in list")
            return false
        }

        // Connect and pair
        print("[DeviceManager] Connecting to device...")
        let connectResult = AMDeviceConnect(deviceRef)
        print("[DeviceManager] AMDeviceConnect result: \(connectResult)")
        guard connectResult == AMDAppLEDETECT_SUCCESS else {
            print("[DeviceManager] AMDeviceConnect failed")
            return false
        }

        // Skip AMDeviceIsPaired - sometimes it returns wrong result
        // Go directly to ValidatePairing
        print("[DeviceManager] Validating pairing...")
        let validateResult = AMDeviceValidatePairing(deviceRef)
        print("[DeviceManager] AMDeviceValidatePairing result: \(validateResult)")
        if validateResult != AMDAppLEDETECT_SUCCESS {
            // Try stopping session first, then validate again
            print("[DeviceManager] First validation failed, retrying...")
            _ = AMDeviceStopSession(deviceRef)
            let retryResult = AMDeviceValidatePairing(deviceRef)
            print("[DeviceManager] AMDeviceValidatePairing retry result: \(retryResult)")
            guard retryResult == AMDAppLEDETECT_SUCCESS else {
                print("[DeviceManager] AMDeviceValidatePairing failed")
                _ = AMDeviceDisconnect(deviceRef)
                return false
            }
        }

        print("[DeviceManager] Starting session...")
        guard AMDeviceStartSession(deviceRef) == AMDAppLEDETECT_SUCCESS else {
            print("[DeviceManager] AMDeviceStartSession failed")
            _ = AMDeviceDisconnect(deviceRef)
            return false
        }

        connectedDeviceRef = deviceRef
        connectedDevice = device
        isConnected = true
        print("[DeviceManager] Connected successfully!")
        return true
    }

    func disconnect() {
        guard let deviceRef = connectedDeviceRef else { return }

        _ = AMDeviceStopSession(deviceRef)
        _ = AMDeviceDisconnect(deviceRef)
        connectedDeviceRef = nil
        connectedDevice = nil
        isConnected = false
    }

    func startObserving() {
        // Only use Timer-based polling - don't register callbacks to avoid crashes
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refreshDevices()
        }
    }

    func stopObserving() {
        pollingTimer?.invalidate()
        pollingTimer = nil
        // Don't call AMDeviceNotificationUnsubscribe since we're not using callbacks
    }

    // MARK: - Private Methods

    private func fetchDevices() -> [Device] {
        // Only use AMDCreateDeviceList
        guard let deviceListRef = AMDCreateDeviceList() else {
            return []
        }

        // Verify it's actually a CFArray before using it
        let typeID = CFGetTypeID(deviceListRef)
        guard typeID == CFArrayGetTypeID() else {
            return []
        }

        let deviceList = deviceListRef as! CFArray
        let count = CFArrayGetCount(deviceList)
        guard count > 0 else {
            return []
        }

        var devices: [Device] = []
        for i in 0..<count {
            let cfValue = CFArrayGetValueAtIndex(deviceList, i)
            let deviceRef = unsafeBitCast(cfValue, to: AMDeviceRef.self)

            let connectResult = AMDeviceConnect(deviceRef)
            guard connectResult == AMDAppLEDETECT_SUCCESS else { continue }
            defer { _ = AMDeviceDisconnect(deviceRef) }

            guard let name = AMDeviceCopyValue(deviceRef, 0, "DeviceName" as CFString) as? String,
                  let udid = AMDeviceCopyValue(deviceRef, 0, "UniqueDeviceID" as CFString) as? String,
                  let model = AMDeviceCopyValue(deviceRef, 0, "ProductType" as CFString) as? String,
                  let version = AMDeviceCopyValue(deviceRef, 0, "ProductVersion" as CFString) as? String else {
                continue
            }

            let deviceClass = parseDeviceClass(from: model)
            devices.append(Device(id: udid, name: name, model: model, systemVersion: version, deviceClass: deviceClass))
        }

        return devices
    }

    // Notifications are no longer used - we use Timer polling instead

    private func setupDeviceNotification() {
        var notifyPort: UnsafeMutableRawPointer?

        // Use the global callback function - it doesn't capture context
        let result = AMDeviceNotificationSubscribe(
            deviceNotificationCallback,
            0,
            0,
            nil,
            &notifyPort
        )

        if result == AMDAppLEDETECT_SUCCESS, let port = notifyPort {
            deviceNotificationPort = port
            // Add to current run loop for callback delivery
            if let runLoop = CFRunLoopGetCurrent() {
                let source = CFRunLoopSourceCreate(nil, 0, nil)
                CFRunLoopAddSource(runLoop, source, .defaultMode)
                runLoopSource = source
            }
        }
    }

    private func parseDeviceClass(from model: String) -> Device.DeviceClass {
        let lowercaseModel = model.lowercased()
        if lowercaseModel.contains("iphone") {
            return .iPhone
        } else if lowercaseModel.contains("ipad") {
            return .iPad
        } else if lowercaseModel.contains("ipod") {
            return .iPod
        }
        return .unknown
    }
}
