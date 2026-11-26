import Foundation
import WebKit

@MainActor
final class PortalWebAuthenticator: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    @Published private(set) var currentURLString: String = ""
    @Published private(set) var isLoading: Bool = false

    let webView: WKWebView

    var onLog: ((String, LogEntry.Level) -> Void)?
    var onPortalURLUpdated: ((URL) -> Void)?
    var onAuthResult: ((Bool, String) -> Void)?

    private var activeConfig: PortalAutoFillConfig?
    private var activePassword: String = ""
    private var allowedCustomHost: String?
    private var autoSubmitActive = false
    private var hasSubmittedInCurrentCycle = false
    private var fillRetryCount = 0
    private var verificationTask: Task<Void, Never>?
    private var authTimeoutTask: Task<Void, Never>?

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        self.webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        self.webView.navigationDelegate = self
        self.webView.uiDelegate = self
    }

    func authenticate(
        portalURL: URL,
        config: PortalAutoFillConfig,
        password: String
    ) {
        verificationTask?.cancel()
        authTimeoutTask?.cancel()
        activeConfig = config
        activePassword = password
        allowedCustomHost = URL(string: config.customPortalURL)?.host ?? portalURL.host
        autoSubmitActive = true
        hasSubmittedInCurrentCycle = false
        fillRetryCount = 0

        onLog?("正在加载认证页面：\(portalURL.absoluteString)", .info)
        var request = URLRequest(url: portalURL)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 12
        webView.load(request)

        authTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 18_000_000_000)
            guard let self, !Task.isCancelled, self.autoSubmitActive else { return }
            self.autoSubmitActive = false
            self.webView.stopLoading()
            self.onAuthResult?(false, "认证等待超时，可再次点击立即检测并登录")
        }
    }

    func loadPreviewURL(_ url: URL, customHost: String? = nil) {
        autoSubmitActive = false
        allowedCustomHost = customHost ?? url.host
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        webView.load(request)
    }

    func runManualFill(config: PortalAutoFillConfig, password: String) {
        activeConfig = config
        activePassword = password
        autoSubmitActive = true
        hasSubmittedInCurrentCycle = false
        fillRetryCount = 0
        attemptAutoFillAndSubmit()
    }

    func cancel() {
        autoSubmitActive = false
        verificationTask?.cancel()
        authTimeoutTask?.cancel()
        webView.stopLoading()
    }

    private func attemptAutoFillAndSubmit() {
        guard autoSubmitActive, !hasSubmittedInCurrentCycle, let config = activeConfig else { return }

        let script = buildAutoFillScript(
            username: config.username,
            password: activePassword,
            usernameSelector: config.usernameSelector,
            passwordSelector: config.passwordSelector,
            submitSelector: config.submitButtonSelector,
            autoCheckBoxes: config.autoCheckAgreementCheckbox
        )

        webView.evaluateJavaScript(script) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error {
                    self.onLog?("页面脚本执行失败：\(error.localizedDescription)", .warning)
                    self.retryOrFailFill()
                    return
                }

                guard let dict = result as? [String: Any],
                      let status = dict["status"] as? String else {
                    self.retryOrFailFill()
                    return
                }

                switch status {
                case "submitted":
                    self.hasSubmittedInCurrentCycle = true
                    let detail = dict["detail"] as? String ?? ""
                    self.onLog?("已自动填入账号密码并提交登录\(detail.isEmpty ? "" : "（\(detail)）")", .info)
                    self.schedulePostSubmitVerification()

                case "missing_fields":
                    let reason = dict["detail"] as? String ?? "未找到账号或密码输入框"
                    if self.fillRetryCount < 4 {
                        self.fillRetryCount += 1
                        try? await Task.sleep(nanoseconds: 700_000_000)
                        self.attemptAutoFillAndSubmit()
                    } else {
                        self.autoSubmitActive = false
                        self.onLog?("自动填表未定位到输入框：\(reason)", .warning)
                        self.onAuthResult?(false, reason)
                    }

                case "already_logged_in":
                    self.autoSubmitActive = false
                    self.onLog?("页面显示已登录或为成功页，正在复检外网连通性...", .info)
                    self.schedulePostSubmitVerification(immediate: true)

                default:
                    self.retryOrFailFill()
                }
            }
        }
    }

    private func retryOrFailFill() {
        guard autoSubmitActive else { return }
        if fillRetryCount < 3 {
            fillRetryCount += 1
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 800_000_000)
                self?.attemptAutoFillAndSubmit()
            }
        } else {
            autoSubmitActive = false
            onAuthResult?(false, "页面未就绪或未识别到登录表单")
        }
    }

    private func schedulePostSubmitVerification(immediate: Bool = false) {
        verificationTask?.cancel()
        let customURL = activeConfig?.customPortalURL
        verificationTask = Task { @MainActor [weak self] in
            let delays: [UInt64] = immediate
                ? [400_000_000, 1_500_000_000]
                : [1_500_000_000, 2_000_000_000, 2_500_000_000]

            let probe = CaptiveProbeService()
            for delay in delays {
                if Task.isCancelled { return }
                try? await Task.sleep(nanoseconds: delay)
                if Task.isCancelled { return }

                let result = await probe.probe(customPortalURL: customURL)
                if case .authenticated = result {
                    self?.autoSubmitActive = false
                    self?.authTimeoutTask?.cancel()
                    self?.onAuthResult?(true, "外网连通性验证成功")
                    return
                }
            }

            if !Task.isCancelled {
                self?.autoSubmitActive = false
                self?.authTimeoutTask?.cancel()
                self?.onAuthResult?(false, "已提交登录但外网仍未连通，请展开网页预览查看提示")
            }
        }
    }

    private func buildAutoFillScript(
        username: String,
        password: String,
        usernameSelector: String,
        passwordSelector: String,
        submitSelector: String,
        autoCheckBoxes: Bool
    ) -> String {
        let payload: [String: Any] = [
            "username": username,
            "password": password,
            "userSel": usernameSelector.trimmingCharacters(in: .whitespacesAndNewlines),
            "passSel": passwordSelector.trimmingCharacters(in: .whitespacesAndNewlines),
            "btnSel": submitSelector.trimmingCharacters(in: .whitespacesAndNewlines),
            "autoCheck": autoCheckBoxes
        ]

        let jsonData = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
        let jsonLiteral = String(data: jsonData, encoding: .utf8) ?? "{}"

        return """
        (function() {
            const cfg = \(jsonLiteral);
            const titleText = (document.title || '').toLowerCase();
            const bodyText = (document.body ? document.body.innerText : '').trim();

            if (titleText === 'success' && bodyText.toLowerCase() === 'success') {
                return { status: 'already_logged_in', detail: 'Captive Success' };
            }

            function isVisible(el) {
                if (!el) return false;
                if (el.disabled) return false;
                const style = window.getComputedStyle(el);
                if (!style || style.display === 'none' || style.visibility === 'hidden' || parseFloat(style.opacity) === 0) {
                    return false;
                }
                const rect = el.getBoundingClientRect();
                return rect.width > 0 && rect.height > 0;
            }

            function setNativeValue(el, value) {
                const proto = el.tagName === 'TEXTAREA'
                    ? window.HTMLTextAreaElement.prototype
                    : window.HTMLInputElement.prototype;
                const descriptor = Object.getOwnPropertyDescriptor(proto, 'value');
                if (descriptor && descriptor.set) {
                    descriptor.set.call(el, value);
                } else {
                    el.value = value;
                }
                el.dispatchEvent(new Event('focus', { bubbles: true }));
                el.dispatchEvent(new Event('input', { bubbles: true }));
                el.dispatchEvent(new Event('change', { bubbles: true }));
                el.dispatchEvent(new Event('blur', { bubbles: true }));
            }

            let passInput = cfg.passSel ? document.querySelector(cfg.passSel) : null;
            if (!passInput) {
                const pwdCandidates = Array.from(document.querySelectorAll('input[type="password"]')).filter(isVisible);
                passInput = pwdCandidates[0] || Array.from(document.querySelectorAll('input[type="password"]'))[0] || null;
            }

            let userInput = cfg.userSel ? document.querySelector(cfg.userSel) : null;
            if (!userInput) {
                const textInputs = Array.from(document.querySelectorAll(
                    'input[type="text"], input[type="email"], input[type="tel"], input:not([type])'
                )).filter(isVisible);

                const preferred = textInputs.find(el => {
                    const attr = ((el.id || '') + ' ' + (el.name || '') + ' ' + (el.placeholder || '') + ' ' + (el.className || '')).toLowerCase();
                    return /user|account|name|login|uid|card|phone|mobile|id|学号|读者|卡号|账号|用户/.test(attr);
                });

                if (preferred) {
                    userInput = preferred;
                } else if (passInput && passInput.form) {
                    const formTexts = Array.from(passInput.form.querySelectorAll('input')).filter(el =>
                        isVisible(el) && el !== passInput && !['password', 'hidden', 'submit', 'button', 'checkbox', 'radio', 'reset'].includes((el.type || 'text').toLowerCase())
                    );
                    userInput = formTexts[0] || textInputs[0] || null;
                } else {
                    userInput = textInputs[0] || null;
                }
            }

            if (!userInput || !passInput) {
                if (/下线|注销|logout|已登录|认证成功/i.test(bodyText) && !passInput) {
                    return { status: 'already_logged_in', detail: 'Portal status page' };
                }
                return {
                    status: 'missing_fields',
                    detail: 'user=' + Boolean(userInput) + ', pass=' + Boolean(passInput)
                };
            }

            setNativeValue(userInput, cfg.username);
            setNativeValue(passInput, cfg.password);

            if (cfg.autoCheck) {
                const checkboxes = Array.from(document.querySelectorAll('input[type="checkbox"]')).filter(isVisible);
                for (const cb of checkboxes) {
                    if (!cb.checked) {
                        cb.click();
                    }
                }
            }

            let submitBtn = cfg.btnSel ? document.querySelector(cfg.btnSel) : null;
            if (!submitBtn) {
                const scope = passInput.form || document;
                const candidates = Array.from(scope.querySelectorAll(
                    'button, input[type="submit"], input[type="button"], a, [role="button"]'
                )).filter(isVisible);

                submitBtn = candidates.find(el => {
                    const t = ((el.innerText || el.value || el.title || el.id || el.className || '') + ' ' + (el.getAttribute('onclick') || '')).toLowerCase();
                    if (/忘记|找回|重置|注册|取消|清空|reset|forgot|cancel/.test(t)) return false;
                    return (el.type === 'submit') || /登录|认证|连接|提交|上网|login|sign\\s*in|connect|submit/.test(t);
                }) || candidates.find(el => el.tagName === 'BUTTON' || el.type === 'submit' || el.type === 'button');
            }

            if (submitBtn) {
                submitBtn.click();
                return { status: 'submitted', detail: '点击登录按钮' };
            }

            if (passInput.form) {
                if (typeof passInput.form.requestSubmit === 'function') {
                    passInput.form.requestSubmit();
                } else {
                    passInput.form.submit();
                }
                return { status: 'submitted', detail: '表单提交' };
            }

            const enterEvent = new KeyboardEvent('keydown', { key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true });
            passInput.dispatchEvent(enterEvent);
            return { status: 'submitted', detail: '回车提交' };
        })();
        """
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
        if let url = webView.url {
            currentURLString = url.absoluteString
            onPortalURLUpdated?(url)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        if let url = webView.url {
            currentURLString = url.absoluteString
            onPortalURLUpdated?(url)
        }
        if autoSubmitActive && !hasSubmittedInCurrentCycle {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 500_000_000)
                self?.attemptAutoFillAndSubmit()
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        let nsError = error as NSError
        if nsError.code == NSURLErrorCancelled { return }
        onLog?("网页加载失败：\(error.localizedDescription)", .error)
        if autoSubmitActive {
            autoSubmitActive = false
            onAuthResult?(false, error.localizedDescription)
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        let nsError = error as NSError
        if nsError.code == NSURLErrorCancelled { return }
        onLog?("连接认证页失败：\(error.localizedDescription)", .error)
        if autoSubmitActive {
            autoSubmitActive = false
            onAuthResult?(false, error.localizedDescription)
        }
    }

    func webView(
        _ webView: WKWebView,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust,
           PrivateHostTrust.shouldTrustHost(challenge.protectionSpace.host, allowedCustomHost: allowedCustomHost) {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }
        completionHandler(.performDefaultHandling, nil)
    }

    // MARK: - WKUIDelegate

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        onLog?("认证页弹窗提示：\(message)", .warning)
        completionHandler()
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        onLog?("认证页确认框：\(message)", .info)
        completionHandler(true)
    }
}
