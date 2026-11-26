import Foundation

@main
struct CoreTests {
    static func main() async {
        testPrivateHostTrust()
        testRedirectExtraction()
        await testLiveCaptiveProbe()
        print("ALL_CORE_TESTS_PASSED")
    }

    static func testPrivateHostTrust() {
        assert(PrivateHostTrust.shouldTrustHost("10.10.40.1"))
        assert(PrivateHostTrust.shouldTrustHost("192.168.1.1"))
        assert(PrivateHostTrust.shouldTrustHost("172.16.5.4"))
        assert(PrivateHostTrust.shouldTrustHost("100.64.0.1"))
        assert(PrivateHostTrust.shouldTrustHost("portal.local"))
        assert(PrivateHostTrust.shouldTrustHost("localhost"))

        assert(!PrivateHostTrust.shouldTrustHost("8.8.8.8"))
        assert(!PrivateHostTrust.shouldTrustHost("172.32.0.1"))
        assert(!PrivateHostTrust.shouldTrustHost("11.0.0.1"))
        assert(!PrivateHostTrust.shouldTrustHost("example.com"))
        assert(PrivateHostTrust.shouldTrustHost("portal.library.edu", allowedCustomHost: "portal.library.edu"))
        print("testPrivateHostTrust passed")
    }

    static func testRedirectExtraction() {
        let probe = CaptiveProbeService()
        let base = URL(string: "http://captive.apple.com/hotspot-detect.html")!

        let metaHTML = #"<meta http-equiv="refresh" content="0;url=http://10.10.40.2:8080/portal?ip=10.10.46.70">"#
        let metaURL = probe.extractRedirectURL(from: metaHTML, baseURL: base)
        assert(metaURL?.absoluteString == "http://10.10.40.2:8080/portal?ip=10.10.46.70")

        let jsHTML = #"<script>top.self.location.href='/login?wlanuserip=10.10.46.70';</script>"#
        let jsURL = probe.extractRedirectURL(from: jsHTML, baseURL: base)
        assert(jsURL?.absoluteString == "http://captive.apple.com/login?wlanuserip=10.10.46.70")

        let replaceHTML = #"<script>location.replace("https://portal.lib.local/auth");</script>"#
        let replaceURL = probe.extractRedirectURL(from: replaceHTML, baseURL: base)
        assert(replaceURL?.absoluteString == "https://portal.lib.local/auth")
        print("testRedirectExtraction passed")
    }

    static func testLiveCaptiveProbe() async {
        let probe = CaptiveProbeService()
        let result = await probe.probe()
        switch result {
        case .authenticated:
            print("testLiveCaptiveProbe passed (.authenticated)")
        case .portalRequired(let url):
            print("testLiveCaptiveProbe passed (.portalRequired: \(url.absoluteString))")
        case .networkUnavailable(let msg):
            fatalError("Unexpected networkUnavailable during live probe: \(msg)")
        }
    }
}
