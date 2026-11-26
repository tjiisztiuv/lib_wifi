import Combine
import Foundation

@MainActor
final class AutoLoginViewModel: ObservableObject {
    @Published var config: PortalAutoFillConfig
    @Published var password: String
    @Published private(set) var state: PortalConnectionState = .idle
    @Published private(set) var wifiSnapshot = WiFiNetworkSnapshot()
    @Published private(set) var detectedPortalURL: URL?
    @Published private(set) var previewURLString: String = ""
    @Published private(set) var logs: [LogEntry] = []
    @Published var isCredentialSavedBannerVisible = false

    let wifiMonitor = WiFiMonitorService()
    let webAuthenticator = PortalWebAuthenticator()

    private let configStore = AppConfigStore()
    private let probeService = CaptiveProbeService()
    private var cancellables = Set<AnyCancellable>()
    private var lastAutoTriggerAt: Date = .distantPast
    private var hasTriggeredOnLaunch = false

    init() {
        let loaded = configStore.load()
        self.config = loaded
        self.password = KeychainHelper.loadPassword(account: loaded.username)
        setupBindings()
    }

    func start() {
        wifiMonitor.startMonitoring()
        wifiSnapshot = wifiMonitor.snapshot
        addLog("应用已启动，正在监听 Wi-Fi（接口：\(wifiSnapshot.interfaceName)）", level: .info)

        if !hasTriggeredOnLaunch {
            hasTriggeredOnLaunch = true
            if config.autoTriggerOnLaunch {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    await self?.checkAndAuthenticate(isAutoTrigger: true, reason: "打开应用自动检测")
                }
            } else {
                Task { @MainActor [weak self] in
                    await self?.probeOnly()
                }
            }
        }
    }

    func saveConfigQuietly() {
        configStore.save(config)
    }

    func saveCredentials() {
        configStore.save(config)
        let saved = KeychainHelper.savePassword(password, account: config.username)
        if saved {
            addLog("配置已保存，密码已存入 macOS 钥匙串。", level: .success)
        } else {
            addLog("配置已保存，但写入钥匙串失败（请检查系统权限）。", level: .warning)
        }
        isCredentialSavedBannerVisible = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            self?.isCredentialSavedBannerVisible = false
        }
    }

    func fillCurrentNetworkInfo() {
        wifiMonitor.requestLocationPermission()
        wifiMonitor.refreshSnapshot(notifyIfChanged: false)
        if let ssid = wifiSnapshot.ssid, !ssid.isEmpty {
            config.targetSSID = ssid
            addLog("已填入当前 Wi-Fi 名称：\(ssid)", level: .info)
        } else if !wifiSnapshot.locationAuthorized {
            addLog("尚未授予“定位服务”权限，系统会隐藏 SSID；已在弹窗中申请权限，或可手动输入 Wi-Fi 名称。", level: .warning)
        }
        if let gw = wifiSnapshot.gatewayIP, !gw.isEmpty {
            config.targetGatewayIP = gw
            addLog("已填入当前网关 IP：\(gw)", level: .info)
        }
        configStore.save(config)
    }

    func connectTargetWiFiAndAuthenticate() {
        saveCredentials()
        if state.isBusy {
            webAuthenticator.cancel()
            state = .idle
        }
        let ssid = config.targetSSID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ssid.isEmpty else {
            addLog("未填写目标 Wi-Fi 名称，改为直接检测当前网络并登录。", level: .info)
            Task { await checkAndAuthenticate(isAutoTrigger: false, reason: "手动点击登录") }
            return
        }

        if let currentSSID = wifiSnapshot.ssid, currentSSID == ssid, wifiSnapshot.isWiFiConnected {
            addLog("当前已连接目标 Wi-Fi（\(ssid)），直接检测认证状态。", level: .info)
            Task { await checkAndAuthenticate(isAutoTrigger: false, reason: "手动点击登录") }
            return
        }

        state = .connectingWiFi(ssid)
        addLog("正在尝试切换到 Wi-Fi：\(ssid)...", level: .info)

        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.wifiMonitor.connectToWiFi(ssid: ssid)
            switch result {
            case .success:
                self.addLog("已连接 Wi-Fi：\(ssid)，准备检测认证页...", level: .success)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await self.checkAndAuthenticate(isAutoTrigger: false, reason: "切换 Wi-Fi 后登录")
            case .failure(let error):
                self.state = .failed(error.localizedDescription)
                self.addLog("连接 Wi-Fi 失败：\(error.localizedDescription)", level: .error)
            }
        }
    }

    func triggerManualAuth() {
        saveCredentials()
        if state.isBusy {
            webAuthenticator.cancel()
            state = .idle
            addLog("已中断上一次未完成的检测，正在重新检测并登录...", level: .info)
        }
        Task { @MainActor [weak self] in
            await self?.checkAndAuthenticate(isAutoTrigger: false, reason: "手动触发检测与登录")
        }
    }

    func probeOnly() async {
        state = .probing
        let customURL = config.customPortalURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = await probeService.probe(customPortalURL: customURL.isEmpty ? nil : customURL)
        switch result {
        case .authenticated:
            state = .authenticated
            addLog("网络检测：已认证，可正常访问外网。", level: .success)
        case .portalRequired(let url):
            detectedPortalURL = url
            state = .portalRequired(url)
            addLog("检测到需要网页认证：\(url.absoluteString)", level: .warning)
        case .networkUnavailable(let msg):
            state = .failed(msg)
            addLog("网络检测不可用：\(msg)", level: .error)
        }
    }

    func runManualFillInWebView() {
        saveCredentials()
        if webAuthenticator.currentURLString.isEmpty {
            let target = URL(string: config.customPortalURL.trimmingCharacters(in: .whitespacesAndNewlines))
                ?? detectedPortalURL
                ?? CaptiveProbeService.probeURL
            webAuthenticator.authenticate(portalURL: target, config: config, password: password)
        } else {
            webAuthenticator.runManualFill(config: config, password: password)
        }
    }

    func openProbeInPreview() {
        let target = URL(string: config.customPortalURL.trimmingCharacters(in: .whitespacesAndNewlines))
            ?? detectedPortalURL
            ?? CaptiveProbeService.probeURL
        webAuthenticator.loadPreviewURL(target, customHost: target.host)
        addLog("已在内置浏览器打开：\(target.absoluteString)", level: .info)
    }

    func clearLogs() {
        logs.removeAll()
    }

    private func setupBindings() {
        wifiMonitor.$snapshot
            .receive(on: DispatchQueue.main)
            .sink { [weak self] next in
                self?.wifiSnapshot = next
            }
            .store(in: &cancellables)

        webAuthenticator.$currentURLString
            .receive(on: DispatchQueue.main)
            .sink { [weak self] urlString in
                self?.previewURLString = urlString
            }
            .store(in: &cancellables)

        wifiMonitor.onNetworkChanged = { [weak self] snapshot, changed in
            guard let self, changed else { return }
            let ssidText = snapshot.ssid ?? (snapshot.locationAuthorized ? "未连接" : "SSID受系统隐私保护")
            let gwText = snapshot.gatewayIP ?? "无"
            self.addLog("检测到网络变化：连接=\(snapshot.isWiFiConnected ? "是" : "否")，Wi-Fi=\(ssidText)，网关=\(gwText)", level: .info)

            guard self.config.autoTriggerOnWiFiChange, snapshot.isWiFiConnected else { return }
            Task { @MainActor [weak self] in
                await self?.checkAndAuthenticate(isAutoTrigger: true, reason: "检测到 Wi-Fi 切换/上线")
            }
        }

        wifiMonitor.onSystemCaptiveAssistantDetected = { [weak self] in
            guard let self, self.config.autoCloseSystemCaptivePopup else { return }
            if self.wifiMonitor.dismissSystemCaptiveAssistantIfRunning() {
                self.addLog("检测到系统“加入网络”认证弹窗，已自动关闭并交由本应用接管认证。", level: .info)
                if self.config.autoTriggerOnWiFiChange {
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(nanoseconds: 600_000_000)
                        await self?.checkAndAuthenticate(isAutoTrigger: true, reason: "接管系统认证弹窗")
                    }
                }
            }
        }

        webAuthenticator.onLog = { [weak self] message, level in
            self?.addLog(message, level: level)
        }

        webAuthenticator.onPortalURLUpdated = { [weak self] url in
            if url.host != CaptiveProbeService.probeURL.host {
                self?.detectedPortalURL = url
            }
        }

        webAuthenticator.onAuthResult = { [weak self] success, detail in
            guard let self else { return }
            if success {
                self.state = .authenticated
                self.addLog("自动认证成功：\(detail)", level: .success)
            } else {
                self.state = .failed(detail)
                self.addLog("自动认证未成功：\(detail)", level: .error)
            }
        }
    }

    private func checkAndAuthenticate(isAutoTrigger: Bool, reason: String) async {
        if state.isBusy {
            return
        }
        if isAutoTrigger && Date().timeIntervalSince(lastAutoTriggerAt) < 4.0 {
            return
        }

        wifiMonitor.refreshSnapshot(notifyIfChanged: false)
        let snap = wifiMonitor.snapshot

        guard snap.isWiFiConnected else {
            state = .idle
            if !isAutoTrigger {
                addLog("当前 Wi-Fi 未连接，请先连接 Wi-Fi 或填写 SSID 后点击“连接 Wi-Fi 并登录”。", level: .warning)
            }
            return
        }

        if isAutoTrigger && config.onlyTriggerOnMatchedNetwork && !matchesConfiguredNetwork(snap) {
            addLog("当前网络未匹配指定目标 SSID/网关，跳过自动登录。", level: .info)
            return
        }

        if isAutoTrigger {
            lastAutoTriggerAt = Date()
        }

        if config.autoCloseSystemCaptivePopup && wifiMonitor.dismissSystemCaptiveAssistantIfRunning() {
            addLog("已关闭系统“加入网络”弹窗以释放网络通道。", level: .info)
            try? await Task.sleep(nanoseconds: 450_000_000)
        }

        state = .probing
        addLog("[\(reason)] 正在检测是否需要网页认证...", level: .info)

        let customURLString = config.customPortalURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let probeResult = await probeService.probe(customPortalURL: customURLString.isEmpty ? nil : customURLString)

        switch probeResult {
        case .authenticated:
            state = .authenticated
            addLog("当前已可直接访问外网，无需重复登录。", level: .success)

        case .portalRequired(let redirectURL):
            let portalURL = URL(string: customURLString).flatMap { customURLString.isEmpty ? nil : $0 } ?? redirectURL
            detectedPortalURL = portalURL

            let user = config.username.trimmingCharacters(in: .whitespacesAndNewlines)
            if user.isEmpty || password.isEmpty {
                state = .portalRequired(portalURL)
                webAuthenticator.loadPreviewURL(portalURL, customHost: portalURL.host)
                addLog("检测到网页认证页（\(portalURL.absoluteString)），但尚未填写账号或密码，请填写后保存并登录。", level: .warning)
                return
            }

            state = .authenticating(portalURL)
            webAuthenticator.authenticate(portalURL: portalURL, config: config, password: password)

        case .networkUnavailable(let errorMsg):
            state = .failed(errorMsg)
            addLog("探测网络失败：\(errorMsg)", level: .error)
        }
    }

    private func matchesConfiguredNetwork(_ snapshot: WiFiNetworkSnapshot) -> Bool {
        let targetSSID = config.targetSSID.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetGW = config.targetGatewayIP.trimmingCharacters(in: .whitespacesAndNewlines)

        if !targetSSID.isEmpty, let currentSSID = snapshot.ssid, !currentSSID.isEmpty {
            return currentSSID == targetSSID
        }
        if !targetGW.isEmpty, let currentGW = snapshot.gatewayIP, !currentGW.isEmpty {
            return currentGW == targetGW
        }
        return true
    }

    private func addLog(_ message: String, level: LogEntry.Level) {
        logs.insert(LogEntry(timestamp: Date(), message: message, level: level), at: 0)
        if logs.count > 100 {
            logs.removeLast(logs.count - 100)
        }
    }
}
