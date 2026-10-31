// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DoppioDisplay",
    platforms: [.macOS(.v26)],
    targets: [
        .target(
            name: "CPrivateAPI",
            path: "Sources/CPrivateAPI",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "DoppioDisplay",
            dependencies: ["CPrivateAPI"],
            path: "Sources/DoppioDisplay",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("Carbon"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("ColorSync"),
                .linkedFramework("IOKit"),
            ]
        ),
    ]
)
