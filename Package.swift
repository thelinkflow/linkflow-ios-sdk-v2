// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LinkFlowSDK",
    platforms: [
        .iOS(.v13),
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
