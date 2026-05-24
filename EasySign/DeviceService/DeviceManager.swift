import Foundation
import Combine

// MARK: - MobileDevice C API Declarations

@_silgen_name("AMDCreateDeviceList")
func AMDCreateDeviceList() -> CFArray?

@_silgen_name("AMDeviceConnect")
func AMDeviceConnect(_ device: AMDeviceRef) -> Int32

@_silgen_name("AMDeviceDisconnect")
func AMDeviceDisconnect(_ device: AMDeviceRef) -> Int32

@_silgen_name("AMDeviceValidatePairing")
func AMDeviceValidatePairing(_ device: AMDeviceRef) -> Int32

@_silgen_name("AMDeviceStartSession")
func AMDeviceStartSession(_ device: AMDeviceRef) -> Int32

@_silgen_name("AMDeviceStopSession")
func AMDeviceStopSession(_ device: AMDeviceRef) -> Int32

@_silgen_name("AMDeviceCopyValue")
func AMDeviceCopyValue(_ device: AMDeviceRef, _ domain: UInt32, _ key: CFString) -> CFTypeRef?

@_silgen_name("AMDeviceNotificationSubscribeWithOptions")
func AMDeviceNotificationSubscribeWithOptions(
    _ callback: AMDeviceNotificationCallback,
    _ unknown1: UInt32,
    _ unknown2: UInt32,
    _ userInfo: UnsafeMutableRawPointer?,
    _ notifyPort: UnsafeMutablePointer<UnsafeMutableRawPointer?>?,
    _ options: CFDictionary?
) -> Int32

@_silgen_name("AMDeviceGetInterfaceType")
func AMDeviceGetInterfaceType(_ device: AMDeviceRef) -> Int32

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

// MARK: - AMDServiceConnection (SSL-aware service connection — used for
// services that lockdownd marks as encrypted, like com.apple.mobile.house_arrest
// on iOS 13+). AMDServiceConnectionSend/Receive transparently apply the SSL
// context the framework set up at start time.

@_silgen_name("AMDeviceSecureStartService")
func AMDeviceSecureStartService(
    _ device: AMDeviceRef,
    _ serviceName: CFString,
    _ options: CFDictionary?,
    _ serviceConn: UnsafeMutablePointer<AMDServiceConnectionRef?>
) -> Int32

// Return type is Int32 — these are `int` in the framework, not ssize_t. -1
// means error, otherwise byte count (fits in Int32). Caller must cast to Int
// when accumulating into a 64-bit counter.
@_silgen_name("AMDServiceConnectionSend")
func AMDServiceConnectionSend(_ conn: AMDServiceConnectionRef, _ data: UnsafeRawPointer, _ size: Int) -> Int32

@_silgen_name("AMDServiceConnectionReceive")
func AMDServiceConnectionReceive(_ conn: AMDServiceConnectionRef, _ buffer: UnsafeMutableRawPointer, _ size: Int) -> Int32

@_silgen_name("AMDServiceConnectionInvalidate")
func AMDServiceConnectionInvalidate(_ conn: AMDServiceConnectionRef)

// MARK: - Type Aliases

typealias AMDeviceRef = UnsafeMutableRawPointer
typealias AFCConnectionRef = UnsafeMutableRawPointer
typealias AMDServiceConnectionRef = UnsafeMutableRawPointer
typealias AMDeviceNotificationCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void

// MARK: - Error Codes

let AMDAppLEDETECT_SUCCESS: Int32 = 0
private let kAMDeviceConnected: UInt32 = 1
private let kAMDeviceDisconnected: UInt32 = 2

// AMDeviceGetInterfaceType return values
private let kAMDeviceInterfaceTypeUSB: Int32 = 1
private let kAMDeviceInterfaceTypeWiFi: Int32 = 2

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

// MARK: - MobileDevice Constants

let kCFBundleIdentifierKey = "CFBundleIdentifier"
let kCFBundleNameKey = "CFBundleName"
let kCFBundleShortVersionStringKey = "CFBundleShortVersionString"
let kCFBundleVersionKey = "CFBundleVersion"
let kAppLookupInfoAppDictKey = "ApplicationDictionaryKey"
let kAppLookupInfoImagePathKey = "Path"
let kLookupReturnAttributesKey = "LookupReturnAttributesKey"

// MARK: - Global Callback Function

// Called from C on a framework-internal thread. We don't parse the info struct
// (private layout, varies by SDK), just ask DeviceManager to coalesce a refresh.
// refreshDevices() is debounced + thread-safe, so calling it directly from this
// thread is fine.
private func deviceNotificationCallback(_ info: UnsafeMutableRawPointer?, _ userInfo: UnsafeMutableRawPointer?) {
    DeviceManager.shared.refreshDevices()
}

// MARK: - DeviceManager

final class DeviceManager: ObservableObject {
    static let shared = DeviceManager()

    @Published private(set) var devices: [Device] = []
    // Internal session state — not observed by any view, so plain properties to
    // avoid the "publishing from background thread" warning when connect() runs.
    private(set) var connectedDevice: Device?
    private(set) var isConnected: Bool = false

    private var deviceNotificationPort: UnsafeMutableRawPointer?
    private var connectedDeviceRef: AMDeviceRef?
    // Holds the CFArray that owns connectedDeviceRef. Without this, the underlying
    // AMDevice object can be released (especially for wireless), turning the ref
    // into a dangling pointer for subsequent AFC / installation_proxy calls.
    private var connectedDeviceList: CFArray?
    private var pollingTimer: Timer?
    private var wirelessDiscoveryEnabled = false

    // Wireless devices get new ref pointers on every poll, so we must cache by UDID.
    // lastSeenRefs is the fast-path lookup for stable refs (USB) — skips the readMetadata
    // round-trip when we recognize a ref from the previous poll.
    // Touched only on refreshQueue.
    private let refreshQueue = DispatchQueue(label: "com.crazyball.easysign.deviceRefresh")
    private var deviceCache: [String: Device] = [:]
    private var lastSeenRefs: [Int: String] = [:]

    // Leading-edge debounce — coalesces bursts of callback+timer+user-tap triggers.
    private var lastRefreshAt: Date = .distantPast
    private let refreshDebounce: TimeInterval = 0.5

    // Wireless devices' refs change every poll, so the ref cache is useless for
    // them. To avoid Connect+Session every 5s, we throttle wireless metadata
    // reads to once every N seconds and reuse the cached Device in between.
    private var lastWirelessReadAt: Date = .distantPast
    private let wirelessReadInterval: TimeInterval = 30.0

    // Hysteresis — don't clear the UI on a single empty AMDCreateDeviceList result
    // (wireless transports can blip). Require two consecutive empties.
    private var consecutiveEmptyResults: Int = 0

    private init() {}

    // MARK: - Public Methods

    func refreshDevices() {
        refreshQueue.async { [weak self] in
            guard let self = self else { return }

            // Leading-edge debounce: first call runs, subsequent calls within
            // the window are dropped. The 5s timer is our safety net so we never
            // miss a real state change for long.
            let now = Date()
            if now.timeIntervalSince(self.lastRefreshAt) < self.refreshDebounce {
                return
            }
            self.lastRefreshAt = now

            let newDevices = self.fetchDevices()
            DispatchQueue.main.async {
                // Hysteresis: a sudden empty result while we have devices is
                // often a transient blip (especially over Wi-Fi). Wait for a
                // second empty to confirm before clearing the UI.
                if newDevices.isEmpty && !self.devices.isEmpty {
                    self.consecutiveEmptyResults += 1
                    if self.consecutiveEmptyResults < 2 {
                        return
                    }
                } else {
                    self.consecutiveEmptyResults = 0
                }
                if !Self.devicesEqual(self.devices, newDevices) {
                    self.devices = newDevices
                }
            }
        }
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
        // Take a fresh AMDCreateDeviceList and HOLD ONTO IT for the lifetime of the
        // session. The device refs live as long as this CFArray does — releasing it
        // mid-session would let the framework deallocate the AMDevice for wireless
        // connections and turn our ref into garbage.
        guard let deviceList = AMDCreateDeviceList(),
              CFGetTypeID(deviceList) == CFArrayGetTypeID() else {
            print("[DeviceManager] AMDCreateDeviceList failed")
            return false
        }
        let count = CFArrayGetCount(deviceList)

        // Identify the requested device by reading metadata (handles wireless UDID
        // via session fallback).
        var targetRef: AMDeviceRef?
        for i in 0..<count {
            let cfValue = CFArrayGetValueAtIndex(deviceList, i)
            let ref = unsafeBitCast(cfValue, to: AMDeviceRef.self)
            let interfaceType = parseInterfaceType(from: AMDeviceGetInterfaceType(ref))
            if let metadata = readDeviceMetadata(ref: ref, interfaceType: interfaceType),
               metadata.id == device.id {
                targetRef = ref
                break
            }
        }

        guard let deviceRef = targetRef else {
            print("[DeviceManager] Device not found in list")
            return false
        }

        print("[DeviceManager] Connecting to device...")
        let connectResult = AMDeviceConnect(deviceRef)
        print("[DeviceManager] AMDeviceConnect result: \(connectResult)")
        guard connectResult == AMDAppLEDETECT_SUCCESS else {
            print("[DeviceManager] AMDeviceConnect failed")
            return false
        }

        // Skip AMDeviceIsPaired (unreliable) and go straight to ValidatePairing
        print("[DeviceManager] Validating pairing...")
        var validateResult = AMDeviceValidatePairing(deviceRef)
        print("[DeviceManager] AMDeviceValidatePairing result: \(validateResult)")
        if validateResult != AMDAppLEDETECT_SUCCESS {
            print("[DeviceManager] First validation failed, retrying...")
            _ = AMDeviceStopSession(deviceRef)
            validateResult = AMDeviceValidatePairing(deviceRef)
            print("[DeviceManager] AMDeviceValidatePairing retry result: \(validateResult)")
        }
        guard validateResult == AMDAppLEDETECT_SUCCESS else {
            print("[DeviceManager] AMDeviceValidatePairing failed")
            _ = AMDeviceDisconnect(deviceRef)
            return false
        }

        print("[DeviceManager] Starting session...")
        guard AMDeviceStartSession(deviceRef) == AMDAppLEDETECT_SUCCESS else {
            print("[DeviceManager] AMDeviceStartSession failed")
            _ = AMDeviceDisconnect(deviceRef)
            return false
        }

        connectedDeviceList = deviceList
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
        connectedDeviceList = nil
        connectedDevice = nil
        isConnected = false
    }

    func startObserving() {
        enableWirelessDiscovery()
        // The framework callback drives immediate refresh; the timer is a safety
        // net for missed events. Both go through the debounce in refreshDevices.
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.refreshDevices()
        }
    }

    func stopObserving() {
        pollingTimer?.invalidate()
        pollingTimer = nil
        // Wireless subscribe (deviceNotificationPort) is intentionally kept for the
        // app's lifetime — unsubscribing has been observed to crash older builds.
        // The callback just calls refreshDevices(), which short-circuits when
        // nothing has changed, so leaving it active is cheap.
    }

    // Without this, AMDCreateDeviceList() returns USB devices only.
    // Subscribe is one-shot for the app's lifetime — the callback intentionally
    // does nothing risky; we don't deref the info pointer.
    private func enableWirelessDiscovery() {
        guard !wirelessDiscoveryEnabled else { return }
        let options: CFDictionary = [
            "NotificationOptions": ["WiFiConnections": true]
        ] as CFDictionary
        var notifyPort: UnsafeMutableRawPointer?
        let result = AMDeviceNotificationSubscribeWithOptions(
            deviceNotificationCallback,
            0, 0, nil,
            &notifyPort,
            options
        )
        if result == AMDAppLEDETECT_SUCCESS {
            deviceNotificationPort = notifyPort
            wirelessDiscoveryEnabled = true
            print("[DeviceManager] Wireless discovery enabled")
        } else {
            print("[DeviceManager] Failed to enable wireless discovery: \(result)")
        }
    }

    // MARK: - Private Methods

    // Called on refreshQueue. CFArray is kept alive across the whole iteration so
    // the device ref pointers it owns remain valid. Cache is keyed by ref pointer
    // so repeated polls don't AMDeviceConnect to known devices.
    private func fetchDevices() -> [Device] {
        guard let deviceList = AMDCreateDeviceList(),
              CFGetTypeID(deviceList) == CFArrayGetTypeID() else {
            deviceCache.removeAll()
            lastSeenRefs.removeAll()
            return []
        }
        let count = CFArrayGetCount(deviceList)
        guard count > 0 else {
            deviceCache.removeAll()
            lastSeenRefs.removeAll()
            return []
        }

        let now = Date()
        let wirelessCooldown = now.timeIntervalSince(lastWirelessReadAt) < wirelessReadInterval
        var newCache: [String: Device] = [:]
        var newLastSeenRefs: [Int: String] = [:]
        var devices: [Device] = []

        for i in 0..<count {
            let cfValue = CFArrayGetValueAtIndex(deviceList, i)
            let ref = unsafeBitCast(cfValue, to: AMDeviceRef.self)
            let refKey = Int(bitPattern: ref)
            let interfaceType = parseInterfaceType(from: AMDeviceGetInterfaceType(ref))

            // Active session — never disturb. Match by ref pointer (USB only really;
            // wireless ref churns so this rarely hits, but harmless).
            if ref == connectedDeviceRef, let connected = connectedDevice {
                newCache[connected.id] = connected
                newLastSeenRefs[refKey] = connected.id
                devices.append(connected)
                continue
            }

            // Fast path: same ref pointer as last poll AND interface unchanged → reuse
            // cached Device. This is the big win for USB (stable refs).
            if let udid = lastSeenRefs[refKey],
               let cached = deviceCache[udid],
               cached.interfaceType == interfaceType {
                newCache[udid] = cached
                newLastSeenRefs[refKey] = udid
                devices.append(cached)
                continue
            }

            // Wireless throttle: a wireless ref always misses the ref-pointer cache
            // (the framework recycles them every poll), but doing the full Connect+
            // Session dance every 5 seconds is wasteful. If we already have a
            // cached wireless Device and the cooldown hasn't elapsed, claim it for
            // this ref. Per-refresh claim-tracking via newCache.keys ensures we
            // don't reuse the same UDID twice when there are multiple wireless refs.
            if interfaceType == .wireless && wirelessCooldown {
                if let cached = deviceCache.values.first(where: {
                    $0.interfaceType == .wireless && !newCache.keys.contains($0.id)
                }) {
                    newCache[cached.id] = cached
                    newLastSeenRefs[refKey] = cached.id
                    devices.append(cached)
                    continue
                }
                // No cached wireless available — fall through and do the full read.
            }

            // Cache miss — do the full read.
            guard let device = readDeviceMetadata(ref: ref, interfaceType: interfaceType) else {
                print("[DeviceManager]   [\(i)] readDeviceMetadata FAILED (interface=\(interfaceType))")
                continue
            }
            if interfaceType == .wireless {
                lastWirelessReadAt = now
            }

            // Reuse the existing instance if we already had this UDID — keeps
            // Hashable identity stable for SwiftUI diffing.
            let toAppend = (deviceCache[device.id]?.interfaceType == interfaceType)
                ? (deviceCache[device.id] ?? device) : device
            newCache[device.id] = toAppend
            newLastSeenRefs[refKey] = device.id
            devices.append(toAppend)
        }

        deviceCache = newCache
        lastSeenRefs = newLastSeenRefs
        return devices
    }

    // Reads lockdown metadata. For wireless devices, "UniqueDeviceID" requires an
    // active session — so if the session-less path returns nil UDID, we fall back
    // to ValidatePairing + StartSession + read + StopSession.
    private func readDeviceMetadata(ref: AMDeviceRef, interfaceType: Device.InterfaceType) -> Device? {
        let connectResult = AMDeviceConnect(ref)
        guard connectResult == AMDAppLEDETECT_SUCCESS else {
            print("[DeviceManager]     AMDeviceConnect failed: \(connectResult)")
            return nil
        }
        defer { _ = AMDeviceDisconnect(ref) }

        let name = AMDeviceCopyValue(ref, 0, "DeviceName" as CFString) as? String
        let model = AMDeviceCopyValue(ref, 0, "ProductType" as CFString) as? String
        let version = AMDeviceCopyValue(ref, 0, "ProductVersion" as CFString) as? String
        var udid = AMDeviceCopyValue(ref, 0, "UniqueDeviceID" as CFString) as? String

        if udid?.isEmpty != false {
            // Wireless: need pair+session to expose UDID.
            udid = readUDIDViaSession(ref: ref)
        }

        guard let udid = udid, !udid.isEmpty,
              let name = name, let model = model, let version = version else {
            print("[DeviceManager]     incomplete metadata udid=\(udid ?? "nil") name=\(name ?? "nil") model=\(model ?? "nil") version=\(version ?? "nil")")
            return nil
        }

        return Device(
            id: udid,
            name: name,
            model: model,
            systemVersion: version,
            deviceClass: parseDeviceClass(from: model),
            interfaceType: interfaceType
        )
    }

    // Caller must have already called AMDeviceConnect successfully. We open a short
    // session purely to read the UDID, then close it so we don't keep the device busy.
    private func readUDIDViaSession(ref: AMDeviceRef) -> String? {
        var pairResult = AMDeviceValidatePairing(ref)
        if pairResult != AMDAppLEDETECT_SUCCESS {
            _ = AMDeviceStopSession(ref)
            pairResult = AMDeviceValidatePairing(ref)
        }
        guard pairResult == AMDAppLEDETECT_SUCCESS else {
            print("[DeviceManager]     ValidatePairing failed: \(pairResult)")
            return nil
        }
        guard AMDeviceStartSession(ref) == AMDAppLEDETECT_SUCCESS else {
            print("[DeviceManager]     StartSession failed")
            return nil
        }
        defer { _ = AMDeviceStopSession(ref) }
        return AMDeviceCopyValue(ref, 0, "UniqueDeviceID" as CFString) as? String
    }

    private func parseInterfaceType(from code: Int32) -> Device.InterfaceType {
        switch code {
        case kAMDeviceInterfaceTypeUSB: return .usb
        case kAMDeviceInterfaceTypeWiFi: return .wireless
        default: return .unknown
        }
    }

    private static func devicesEqual(_ a: [Device], _ b: [Device]) -> Bool {
        guard a.count == b.count else { return false }
        for (x, y) in zip(a, b) {
            if x.id != y.id || x.interfaceType != y.interfaceType {
                return false
            }
        }
        return true
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
