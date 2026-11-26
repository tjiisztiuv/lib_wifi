import Foundation

enum PortalConnectionState: Equatable {
    case idle
    case probing
    case authenticated
    case portalRequired(URL)
    case authenticating(URL)
    case connectingWiFi(String)
    case failed(String)

    var title: String {
        switch self {
        case .idle:
            return "等待检测"
        case .probing:
            return "正在检测网络状态..."
        case .authenticated:
            return "已连接外网（认证通过）"
        case .portalRequired:
            return "需要网页认证"
        case .authenticating:
            return "正在自动填充并登录..."
        case .connectingWiFi(let ssid):
            return "正在连接 Wi-Fi：\(ssid)"
        case .failed(let message):
            return "认证未通过：\(message)"
        }
    }

    var isBusy: Bool {
        switch self {
        case .probing, .authenticating, .connectingWiFi:
            return true
        default:
            return false
        }
    }
}

struct LogEntry: Identifiable, Equatable {
    let id = UUID()
    let timestamp: Date
    let message: String
    let level: Level

    enum Level {
        case info
        case success
        case warning
        case error
    }

    var formattedTime: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: timestamp)
    }
}

struct PortalAutoFillConfig: Codable, Equatable {
    var targetSSID: String = ""
    var targetGatewayIP: String = "10.10.40.1"
    var onlyTriggerOnMatchedNetwork: Bool = false
    var autoTriggerOnLaunch: Bool = true
    var autoTriggerOnWiFiChange: Bool = true
    var autoCloseSystemCaptivePopup: Bool = true
    var autoCheckAgreementCheckbox: Bool = false
    var customPortalURL: String = ""
    var usernameSelector: String = ""
    var passwordSelector: String = ""
    var submitButtonSelector: String = ""
    var username: String = ""
}

final class AppConfigStore {
    private let defaultsKey = "com.libwifi.autologin.config.v1"

    func load() -> PortalAutoFillConfig {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let config = try? JSONDecoder().decode(PortalAutoFillConfig.self, from: data) else {
            return PortalAutoFillConfig()
        }
        return config
    }

    func save(_ config: PortalAutoFillConfig) {
        guard let data = try? JSONEncoder().encode(config) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}
