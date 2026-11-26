// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "LibWiFiAutoLogin",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "LibWiFiAutoLogin",
            targets: ["LibWiFiAutoLogin"]
        )
    ],
    targets: [
        .executableTarget(
            name: "LibWiFiAutoLogin",
            path: "Sources/LibWiFiAutoLogin",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("WebKit"),
                .linkedFramework("Network"),
                .linkedFramework("CoreWLAN"),
                .linkedFramework("CoreLocation"),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("Security")
            ]
        )
    ]
)
