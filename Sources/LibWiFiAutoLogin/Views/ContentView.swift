import AppKit
import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = AutoLoginViewModel()
    @State private var showPassword = false
    @State private var showAdvanced = false
    @State private var showWebPreview = false
    @State private var isAlwaysOnTop = false
    @State private var snapLeftTrigger = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                statusCard
                actionButtons
                credentialsSection
                triggerSection
                advancedSection
                webPreviewSection
                logsSection
            }
            .padding(18)
        }
        .frame(minWidth: 540, idealWidth: 580, minHeight: 620, idealHeight: 720)
        .background(WindowAccessor(isAlwaysOnTop: $isAlwaysOnTop, snapLeftTrigger: snapLeftTrigger))
        .onAppear {
            viewModel.start()
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 12, height: 12)

                Text(viewModel.state.title)
                    .font(.headline)

                Spacer()

                if viewModel.state.isBusy {
                    ProgressView()
                        .controlSize(.small)
                }

                Button("靠左") {
                    snapLeftTrigger += 1
                }
                .controlSize(.small)
                .help("将窗口移动到屏幕左侧，避免与系统认证弹窗重叠")

                Toggle("置顶", isOn: $isAlwaysOnTop)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .help("保持窗口显示在最前面")
            }

            Divider()

            HStack(spacing: 18) {
                infoBadge(
                    label: "Wi-Fi",
                    value: viewModel.wifiSnapshot.ssid
                        ?? (viewModel.wifiSnapshot.isWiFiConnected ? "已连接（SSID 需定位权限）" : "未连接")
                )
                infoBadge(
                    label: "本机 IP",
                    value: viewModel.wifiSnapshot.ipAddress ?? "--"
                )
                infoBadge(
                    label: "网关",
                    value: viewModel.wifiSnapshot.gatewayIP ?? "--"
                )
            }

            if let portalURL = viewModel.detectedPortalURL {
                HStack(spacing: 8) {
                    Text("捕获认证页：")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(portalURL.absoluteString)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("复制") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(portalURL.absoluteString, forType: .string)
                    }
                    .controlSize(.small)
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private var actionButtons: some View {
        HStack(spacing: 10) {
            Button {
                viewModel.triggerManualAuth()
            } label: {
                Label(viewModel.state.isBusy ? "重新检测并登录" : "立即检测并登录", systemImage: "bolt.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Button {
                viewModel.connectTargetWiFiAndAuthenticate()
            } label: {
                Label("连接目标 Wi-Fi 并登录", systemImage: "wifi")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(viewModel.config.targetSSID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var credentialsSection: some View {
        GroupBox("账号与 Wi-Fi 配置") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("认证账号")
                        .frame(width: 82, alignment: .leading)
                    TextField("请输入图书馆上网账号 / 卡号", text: $viewModel.config.username)
                        .textFieldStyle(.roundedBorder)
                }

                HStack {
                    Text("认证密码")
                        .frame(width: 82, alignment: .leading)
                    Group {
                        if showPassword {
                            TextField("请输入密码", text: $viewModel.password)
                        } else {
                            SecureField("请输入密码", text: $viewModel.password)
                        }
                    }
                    .textFieldStyle(.roundedBorder)

                    Button(showPassword ? "隐藏" : "显示") {
                        showPassword.toggle()
                    }
                    .controlSize(.small)
                }

                HStack {
                    Text("目标 Wi-Fi")
                        .frame(width: 82, alignment: .leading)
                    TextField("可选，如 Library-WiFi（用于指定连接）", text: $viewModel.config.targetSSID)
                        .textFieldStyle(.roundedBorder)

                    Button("读取当前网络") {
                        viewModel.fillCurrentNetworkInfo()
                    }
                    .controlSize(.small)
                }

                HStack {
                    Text("目标网关")
                        .frame(width: 82, alignment: .leading)
                    TextField("可选，例如 10.10.40.1", text: $viewModel.config.targetGatewayIP)
                        .textFieldStyle(.roundedBorder)

                    Spacer()

                    if viewModel.isCredentialSavedBannerVisible {
                        Text("已保存到钥匙串")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }

                    Button("保存配置") {
                        viewModel.saveCredentials()
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(6)
        }
    }

    private var triggerSection: some View {
        GroupBox("自动触发策略") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("打开 App 时自动检测并登录", isOn: $viewModel.config.autoTriggerOnLaunch)
                Toggle("检测到切换或重新连上 Wi-Fi 时自动触发", isOn: $viewModel.config.autoTriggerOnWiFiChange)
                Toggle("自动关闭系统“加入网络”认证弹窗（避免阻塞连接）", isOn: $viewModel.config.autoCloseSystemCaptivePopup)
                Toggle("仅在匹配目标 Wi-Fi 名称或网关 IP 时自动提交", isOn: $viewModel.config.onlyTriggerOnMatchedNetwork)
                Toggle("自动勾选页面中的协议复选框（如“同意协议”）", isOn: $viewModel.config.autoCheckAgreementCheckbox)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
            .onChange(of: viewModel.config.autoTriggerOnLaunch) { _ in viewModel.saveConfigQuietly() }
            .onChange(of: viewModel.config.autoTriggerOnWiFiChange) { _ in viewModel.saveConfigQuietly() }
            .onChange(of: viewModel.config.autoCloseSystemCaptivePopup) { _ in viewModel.saveConfigQuietly() }
            .onChange(of: viewModel.config.onlyTriggerOnMatchedNetwork) { _ in viewModel.saveConfigQuietly() }
            .onChange(of: viewModel.config.autoCheckAgreementCheckbox) { _ in viewModel.saveConfigQuietly() }
        }
    }

    private var advancedSection: some View {
        DisclosureGroup("高级适配选项（仅在默认识别失效时填写）", isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("固定认证 URL")
                        .frame(width: 96, alignment: .leading)
                    TextField("留空则自动探测重定向地址", text: $viewModel.config.customPortalURL)
                        .textFieldStyle(.roundedBorder)
                }
                HStack {
                    Text("账号框选择器")
                        .frame(width: 96, alignment: .leading)
                    TextField("可选 CSS 选择器，如 #username", text: $viewModel.config.usernameSelector)
                        .textFieldStyle(.roundedBorder)
                }
                HStack {
                    Text("密码框选择器")
                        .frame(width: 96, alignment: .leading)
                    TextField("可选 CSS 选择器，如 #password", text: $viewModel.config.passwordSelector)
                        .textFieldStyle(.roundedBorder)
                }
                HStack {
                    Text("登录按钮选择器")
                        .frame(width: 96, alignment: .leading)
                    TextField("可选 CSS 选择器，如 #loginBtn", text: $viewModel.config.submitButtonSelector)
                        .textFieldStyle(.roundedBorder)
                }
            }
            .padding(.top, 8)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
        )
    }

    private var webPreviewSection: some View {
        DisclosureGroup("内置认证网页视图（用于查看或手动辅助）", isExpanded: $showWebPreview) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(viewModel.previewURLString.isEmpty ? "尚未加载页面" : viewModel.previewURLString)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer()

                    Button("打开认证/探测页") {
                        viewModel.openProbeInPreview()
                    }
                    .controlSize(.small)

                    Button("执行自动填表") {
                        viewModel.runManualFillInWebView()
                    }
                    .controlSize(.small)
                }

                WebPreviewView(webView: viewModel.webAuthenticator.webView)
                    .frame(height: 320)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                    )
            }
            .padding(.top, 8)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
        )
    }

    private var logsSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("运行日志")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Button("清空") {
                        viewModel.clearLogs()
                    }
                    .controlSize(.small)
                }

                if viewModel.logs.isEmpty {
                    Text("暂无日志")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                } else {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(viewModel.logs.prefix(20)) { entry in
                            HStack(alignment: .top, spacing: 6) {
                                Text(entry.formattedTime)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                Text(entry.message)
                                    .font(.caption)
                                    .foregroundStyle(color(for: entry.level))
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
            }
            .padding(4)
        }
    }

    private func infoBadge(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.medium))
                .lineLimit(1)
        }
    }

    private var statusColor: Color {
        switch viewModel.state {
        case .authenticated:
            return .green
        case .probing, .authenticating, .connectingWiFi:
            return .orange
        case .portalRequired:
            return .yellow
        case .failed:
            return .red
        case .idle:
            return .gray
        }
    }

    private func color(for level: LogEntry.Level) -> Color {
        switch level {
        case .info:
            return .primary
        case .success:
            return .green
        case .warning:
            return .orange
        case .error:
            return .red
        }
    }
}
