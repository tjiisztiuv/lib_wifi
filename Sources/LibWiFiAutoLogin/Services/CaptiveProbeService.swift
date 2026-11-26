import Foundation

enum CaptiveProbeResult: Equatable {
    case authenticated
    case portalRequired(URL)
    case networkUnavailable(String)
}

enum PrivateHostTrust {
    static func shouldTrustHost(_ host: String?, allowedCustomHost: String? = nil) -> Bool {
        guard let host = host?.lowercased(), !host.isEmpty else { return false }
        if let custom = allowedCustomHost?.lowercased(), !custom.isEmpty, host == custom {
            return true
        }
        if host == "localhost" || host.hasSuffix(".local") {
            return true
        }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else {
            return false
        }
        let a = parts[0], b = parts[1]
        if a == 10 { return true }
        if a == 172 && (16...31).contains(b) { return true }
        if a == 192 && b == 168 { return true }
        if a == 100 && (64...127).contains(b) { return true }
        if a == 127 { return true }
        return false
    }
}

final class CaptiveProbeService: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let probeURL = URL(string: "http://captive.apple.com/hotspot-detect.html")!
    private var allowedCustomHost: String?

    func probe(customPortalURL: String? = nil) async -> CaptiveProbeResult {
        if let custom = customPortalURL, let parsed = URL(string: custom) {
            allowedCustomHost = parsed.host
        } else {
            allowedCustomHost = nil
        }

        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = 6
        config.timeoutIntervalForResource = 8
        config.httpShouldSetCookies = false

        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: Self.probeURL)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("CaptiveNetworkSupport/1.0 wispr", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return .networkUnavailable("未收到有效 HTTP 响应")
            }

            if (300...399).contains(httpResponse.statusCode),
               let location = httpResponse.value(forHTTPHeaderField: "Location"),
               let redirectURL = URL(string: location, relativeTo: Self.probeURL)?.absoluteURL {
                return .portalRequired(redirectURL)
            }

            let body = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
                ?? ""

            if httpResponse.statusCode == 200 && body.range(of: "<TITLE>Success</TITLE>", options: .caseInsensitive) != nil {
                return .authenticated
            }

            if let extracted = extractRedirectURL(from: body, baseURL: httpResponse.url ?? Self.probeURL) {
                return .portalRequired(extracted)
            }

            return .portalRequired(httpResponse.url ?? Self.probeURL)
        } catch {
            return .networkUnavailable(error.localizedDescription)
        }
    }

    func extractRedirectURL(from html: String, baseURL: URL) -> URL? {
        let patterns = [
            #"<meta[^>]+http-equiv=["']?refresh["']?[^>]+content=["'][^"']*url=([^"'\s>]+)"#,
            #"location\.href\s*=\s*["']([^"']+)["']"#,
            #"location\.replace\(\s*["']([^"']+)["']\s*\)"#,
            #"window\.location\s*=\s*["']([^"']+)["']"#
        ]

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
               let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               let range = Range(match.range(at: 1), in: html) {
                let raw = String(html[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                if let url = URL(string: raw, relativeTo: baseURL)?.absoluteURL {
                    return url
                }
            }
        }
        return nil
    }

    // Prevent URLSession from following redirects automatically so we capture the exact portal URL.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession,
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
}
