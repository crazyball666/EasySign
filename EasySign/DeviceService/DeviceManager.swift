import Foundation
import Combine

// MARK: - MobileDevice C API Declarations

@_silgen_name("AMDeviceCopySupportedDevices")
func AMDeviceCopySupportedDevices() -> CFArray?

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

@_silgen_name("AFCConnectionOpen")
func AFCConnectionOpen(_ connection: AFCConnectionRef, _ unused: UInt32, _ connectionRef: UnsafeMutablePointer<AFCConnectionRef?>?) -> Int32

@_silgen_name("AFCConnectionClose")
func AFCConnectionClose(_ connection: AFCConnectionRef) -> Int32

// MARK: - Type Aliases

typealias AMDeviceRef = UnsafeMutableRawPointer
typealias AFCConnectionRef = UnsafeMutableRawPointer
typealias AMDeviceNotificationCallback = @convention(c) (CFDictionary?, UnsafeMutableRawPointer?) -> Void

// MARK: - Error Codes

private let AMDAppLEDETECT_SUCCESS: Int32 = 0
private let kAMDeviceConnected: UInt32 = 1
private let kAMDeviceDisconnected: UInt32 = 2

// MARK: - Notification Names

extension Notification.Name {
    static let deviceConnected = Notification.Name("DeviceConnected")
    static let deviceDisconnected = Notification.Name("DeviceDisconnected")
}

// MARK: - Global Callback Function

// This callback is called from C code, so it cannot capture any Swift context
private func deviceNotificationCallback(_ dict: CFDictionary?, _ userInfo: UnsafeMutableRawPointer?) {
    guard let dict = dict else { return }

    // Extract notification type from the CFDictionary
    // The dictionary contains a key "AMDeviceNotificationNoteType" with a UInt32 value
    let key = "AMDeviceNotificationNoteType" as CFString
    guard let noteTypeRef = CFDictionaryGetValue(dict, Unmanaged.passUnretained(key).toOpaque()) else { return }

    // The value is a pointer to UInt32
    let noteTypeValue = noteTypeRef.assumingMemoryBound(to: UInt32.self)
    let noteType = noteTypeValue.pointee

    // Post notification to main thread
    DispatchQueue.main.async {
        if noteType == kAMDeviceConnected {
            NotificationCenter.default.post(name: .deviceConnected, object: nil)
        } else if noteType == kAMDeviceDisconnected {
            NotificationCenter.default.post(name: .deviceDisconnected, object: nil)
        }
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

    private init() {}

    // MARK: - Public Methods

    func refreshDevices() {
        devices = fetchDevices()
    }

    func connect(to device: Device) -> Bool {
        // Find the device reference
        guard let deviceList = AMDeviceCopySupportedDevices() as? [AMDeviceRef],
              let deviceRef = deviceList.first(where: { ref in
                  guard AMDeviceConnect(ref) == AMDAppLEDETECT_SUCCESS else { return false }
                  defer { _ = AMDeviceDisconnect(ref) }
                  guard let udid = AMDeviceCopyValue(ref, 0, "UniqueDeviceID" as CFString) as? String else {
                      return false
                  }
                  return udid == device.id
              }) else {
            return false
        }

        // Connect and pair
        guard AMDeviceConnect(deviceRef) == AMDAppLEDETECT_SUCCESS else {
            return false
        }

        guard AMDeviceIsPaired(deviceRef) == AMDAppLEDETECT_SUCCESS else {
            _ = AMDeviceDisconnect(deviceRef)
            return false
        }

        guard AMDeviceValidatePairing(deviceRef) == AMDAppLEDETECT_SUCCESS else {
            _ = AMDeviceDisconnect(deviceRef)
            return false
        }

        guard AMDeviceStartSession(deviceRef) == AMDAppLEDETECT_SUCCESS else {
            _ = AMDeviceDisconnect(deviceRef)
            return false
        }

        connectedDeviceRef = deviceRef
        connectedDevice = device
        isConnected = true
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
        setupNotifications()
        setupDeviceNotification()
    }

    func stopObserving() {
        if let observer = notificationObserverConnected {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = notificationObserverDisconnected {
            NotificationCenter.default.removeObserver(observer)
        }

        guard let port = deviceNotificationPort else { return }
        _ = AMDeviceNotificationUnsubscribe(port)
        deviceNotificationPort = nil
        runLoopSource = nil
    }

    // MARK: - Private Methods

    private func fetchDevices() -> [Device] {
        guard let deviceList = AMDeviceCopySupportedDevices() as? [AMDeviceRef] else {
            return []
        }

        return deviceList.compactMap { ref -> Device? in
            guard AMDeviceConnect(ref) == AMDAppLEDETECT_SUCCESS else { return nil }
            defer { _ = AMDeviceDisconnect(ref) }

            guard let name = AMDeviceCopyValue(ref, 0, "DeviceName" as CFString) as? String,
                  let udid = AMDeviceCopyValue(ref, 0, "UniqueDeviceID" as CFString) as? String,
                  let model = AMDeviceCopyValue(ref, 0, "ProductType" as CFString) as? String,
                  let version = AMDeviceCopyValue(ref, 0, "ProductVersion" as CFString) as? String else {
                return nil
            }

            let deviceClass = parseDeviceClass(from: model)

            return Device(
                id: udid,
                name: name,
                model: model,
                systemVersion: version,
                deviceClass: deviceClass
            )
        }
    }

    private func setupNotifications() {
        notificationObserverConnected = NotificationCenter.default.addObserver(
            forName: .deviceConnected,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshDevices()
        }

        notificationObserverDisconnected = NotificationCenter.default.addObserver(
            forName: .deviceDisconnected,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshDevices()
            // If disconnected device was our connected device, clear it
            if let self = self,
               let connectedId = self.connectedDevice?.id,
               !self.devices.contains(where: { $0.id == connectedId }) {
                self.connectedDeviceRef = nil
                self.connectedDevice = nil
                self.isConnected = false
            }
        }
    }

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
