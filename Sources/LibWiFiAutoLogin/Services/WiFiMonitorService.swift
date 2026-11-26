import AppKit
import CoreLocation
import CoreWLAN
import Foundation
import Network
import SystemConfiguration

struct WiFiNetworkSnapshot: Equatable {
    var interfaceName: String = "en0"
    var isWiFiConnected: Bool = false
    var ssid: String?
    var ipAddress: String?
    var gatewayIP: String?
    var locationAuthorized: Bool = false
}

@MainActor
final class WiFiMonitorService: NSObject, ObservableObject, CLLocationManagerDelegate, CWEventDelegate {
    @Published private(set) var snapshot = WiFiNetworkSnapshot()

    var onNetworkChanged: ((WiFiNetworkSnapshot, Bool) -> Void)?
    var onSystemCaptiveAssistantDetected: (() -> Void)?

    private let pathMonitor = NWPathMonitor(requiredInterfaceType: .wifi)
    private let monitorQueue = DispatchQueue(label: "com.libwifi.wifi.monitor")
    private let wifiClient = CWWiFiClient.shared()
    private let locationManager = CLLocationManager()
    private var dynamicStore: SCDynamicStore?
    private var runLoopSource: CFRunLoopSource?
    private var debounceWorkItem: DispatchWorkItem?
    private var workspaceObserver: NSObjectProtocol?
    private var lastSignature: String = ""

    override init() {
        super.init()
        locationManager.delegate = self
    }

    func startMonitoring() {
        refreshSnapshot(notifyIfChanged: false)
        startPathMonitor()
        startCoreWLANMonitoring()
        startDynamicStoreMonitoring()
        startCaptiveAssistantObserver()
    }

    func stopMonitoring() {
        pathMonitor.cancel()
        try? wifiClient.stopMonitoringAllEvents()
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
            runLoopSource = nil
        }
        if let observer = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            workspaceObserver = nil
        }
        dynamicStore = nil
    }

    @discardableResult
    func dismissSystemCaptiveAssistantIfRunning() -> Bool {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.CaptiveNetworkAssistant")
        guard !apps.isEmpty else { return false }
        var closedAny = false
        for app in apps {
            let requested = app.terminate()
            if !requested {
                _ = app.forceTerminate()
            } else {
                // Modal certificate sheets in Captive Network Assistant can stall normal terminate().
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    if !app.isTerminated {
                        _ = app.forceTerminate()
                    }
                }
            }
            closedAny = true
        }
        return closedAny
    }

    func requestLocationPermission() {
        let status = locationManager.authorizationStatus
        if status == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        } else {
            refreshSnapshot(notifyIfChanged: false)
        }
    }

    func refreshSnapshot(notifyIfChanged: Bool = true) {
        let interface = wifiClient.interface()
        let ifaceName = interface?.interfaceName ?? "en0"
        let ipv4Info = readIPv4Info(for: ifaceName)
        let ssid = interface?.ssid()
        let powerOn = interface?.powerOn() ?? false
        let connected = powerOn && (ipv4Info.ip != nil || interface?.wlanChannel() != nil)

        let authStatus = locationManager.authorizationStatus
        let locationOK = (authStatus == .authorizedAlways || authStatus == .authorized)

        let next = WiFiNetworkSnapshot(
            interfaceName: ifaceName,
            isWiFiConnected: connected,
            ssid: ssid,
            ipAddress: ipv4Info.ip,
            gatewayIP: ipv4Info.router,
            locationAuthorized: locationOK
        )

        let signature = "\(next.isWiFiConnected)|\(next.ssid ?? "")|\(next.ipAddress ?? "")|\(next.gatewayIP ?? "")"
        let changed = (signature != lastSignature)
        lastSignature = signature
        snapshot = next

        if notifyIfChanged && changed {
            onNetworkChanged?(next, true)
        }
    }

    func connectToWiFi(ssid: String) async -> Result<Void, Error> {
        let trimmed = ssid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(NSError(domain: "WiFiMonitor", code: -1, userInfo: [NSLocalizedDescriptionKey: "请先填写目标 Wi-Fi 名称（SSID）"]))
        }

        let ifaceName = snapshot.interfaceName
        if let interface = wifiClient.interface(withName: ifaceName) ?? wifiClient.interface() {
            do {
                let networks = try interface.scanForNetworks(withName: trimmed)
                if let target = networks.first {
                    try interface.associate(to: target, password: nil)
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    refreshSnapshot(notifyIfChanged: false)
                    return .success(())
                }
            } catch {
                // Fall back to networksetup below if CoreWLAN scan/associate fails (e.g. missing Location permission).
            }
        }

        return await runNetworkSetupJoin(interfaceName: ifaceName, ssid: trimmed)
    }

    private func runNetworkSetupJoin(interfaceName: String, ssid: String) async -> Result<Void, Error> {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
                process.arguments = ["-setairportnetwork", interfaceName, ssid]

                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe

                do {
                    try process.run()
                    process.waitUntilExit()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if process.terminationStatus == 0 && !output.lowercased().contains("failed") && !output.lowercased().contains("could not find") {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                            self?.refreshSnapshot(notifyIfChanged: false)
                            continuation.resume(returning: .success(()))
                        }
                    } else {
                        let msg = output.isEmpty ? "无法加入 Wi-Fi \(ssid)（错误码 \(process.terminationStatus)）" : output
                        continuation.resume(returning: .failure(NSError(domain: "WiFiMonitor", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: msg])))
                    }
                } catch {
                    continuation.resume(returning: .failure(error))
                }
            }
        }
    }

    private func startPathMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleRefresh()
            }
        }
        pathMonitor.start(queue: monitorQueue)
    }

    private func startCoreWLANMonitoring() {
        wifiClient.delegate = self
        try? wifiClient.startMonitoringEvent(with: .ssidDidChange)
        try? wifiClient.startMonitoringEvent(with: .linkDidChange)
        try? wifiClient.startMonitoringEvent(with: .powerDidChange)
    }

    private func startDynamicStoreMonitoring() {
        var context = SCDynamicStoreContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: SCDynamicStoreCallBack = { _, _, info in
            guard let info else { return }
            let monitor = Unmanaged<WiFiMonitorService>.fromOpaque(info).takeUnretainedValue()
            Task { @MainActor in
                monitor.scheduleRefresh()
            }
        }

        guard let store = SCDynamicStoreCreate(nil, "com.libwifi.autologin.store" as CFString, callback, &context) else {
            return
        }

        let patterns = [
            "State:/Network/Interface/.*/IPv4" as CFString,
            "State:/Network/Global/IPv4" as CFString
        ] as CFArray

        SCDynamicStoreSetNotificationKeys(store, nil, patterns)
        if let source = SCDynamicStoreCreateRunLoopSource(nil, store, 0) {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            runLoopSource = source
        }
        dynamicStore = store
    }

    private func scheduleRefresh() {
        debounceWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.refreshSnapshot(notifyIfChanged: true)
        }
        debounceWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: item)
    }

    private func startCaptiveAssistantObserver() {
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == "com.apple.CaptiveNetworkAssistant" else {
                return
            }
            Task { @MainActor [weak self] in
                self?.onSystemCaptiveAssistantDetected?()
            }
        }
    }

    private func readIPv4Info(for interfaceName: String) -> (ip: String?, router: String?) {
        guard let store = SCDynamicStoreCreate(nil, "com.libwifi.read" as CFString, nil, nil) else {
            return (nil, nil)
        }
        let ifKey = "State:/Network/Interface/\(interfaceName)/IPv4" as CFString
        let ifDict = SCDynamicStoreCopyValue(store, ifKey) as? [String: Any]
        let addresses = ifDict?[kSCPropNetIPv4Addresses as String] as? [String]
        var router = ifDict?[kSCPropNetIPv4Router as String] as? String

        if router == nil,
           let globalDict = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any] {
            let primaryIface = globalDict[kSCDynamicStorePropNetPrimaryInterface as String] as? String
            if primaryIface == nil || primaryIface == interfaceName {
                router = globalDict[kSCPropNetIPv4Router as String] as? String
            }
            if router == nil, let serviceID = globalDict[kSCDynamicStorePropNetPrimaryService as String] as? String {
                let svcKey = "State:/Network/Service/\(serviceID)/IPv4" as CFString
                let svcDict = SCDynamicStoreCopyValue(store, svcKey) as? [String: Any]
                router = svcDict?[kSCPropNetIPv4Router as String] as? String
            }
        }
        return (addresses?.first, router)
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in
            self?.refreshSnapshot(notifyIfChanged: false)
        }
    }

    nonisolated func ssidDidChangeForWiFiInterface(withName interfaceName: String) {
        Task { @MainActor [weak self] in
            self?.scheduleRefresh()
        }
    }

    nonisolated func linkDidChangeForWiFiInterface(withName interfaceName: String) {
        Task { @MainActor [weak self] in
            self?.scheduleRefresh()
        }
    }

    nonisolated func powerStateDidChangeForWiFiInterface(withName interfaceName: String) {
        Task { @MainActor [weak self] in
            self?.scheduleRefresh()
        }
    }
}
