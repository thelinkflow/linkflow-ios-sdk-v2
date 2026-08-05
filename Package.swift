// swift-tools-version:5.9
import PackageDescription

// iOS is the shipping platform. The package also declares macOS so the
// platform-independent core (retry policy, event queue, response parsing, URL
// handling) can be compiled and unit-tested without a device — the
// UIKit/AdSupport/AppTrackingTransparency surface is guarded with
// `#if canImport(...)`, which also lets the core build on Linux CI.
let package = Package(
    name: "LinkFlowSDK",
    platforms: [
        .iOS(.v13),
        .macOS(.v12),
    ],
    products: [
        .library(
            name: "LinkFlowSDK",
            targets: ["LinkFlowSDK"]),
    ],
    dependencies: [
        // No external dependencies - pure Swift!
    ],
    targets: [
        .target(
            name: "LinkFlowSDK",
            dependencies: [],
            path: "Sources/LinkFlowSDK"),
        .testTarget(
            name: "LinkFlowSDKTests",
            dependencies: ["LinkFlowSDK"],
            path: "Tests/LinkFlowSDKTests"),
    ]
)
