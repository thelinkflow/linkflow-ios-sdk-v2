# LinkFlow iOS SDK

Complete iOS SDK for deferred deep linking, attribution, and rewards.

## Features

- ✅ ATT (App Tracking Transparency) helper
- ✅ IDFA/IDFV retrieval
- ✅ Deferred deep link retrieval
- ✅ Universal Link handling
- ✅ Event tracking to attribution API
- ✅ **Reward validation and redemption** (Phase 3)

## Installation

### Swift Package Manager

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/thelinkflow/linkflow-ios-sdk.git", from: "1.0.0")
]
```

### CocoaPods

```ruby
pod 'LinkFlowSDK', '~> 1.0'
```

## Quick Start

### 1. Configure SDK

```swift
import LinkFlowSDK

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication,
                    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {

        LinkFlowSDK.shared.configure(
            apiBaseUrl: "https://thelinkflow.app",
            enableLogging: true
        )
        LinkFlowSDK.shared.setAttributionCallback(self)
        LinkFlowSDK.shared.handleAppLaunch(launchOptions: launchOptions)
        return true
    }
}

extension AppDelegate: AttributionCallback {
    func onAttributionResolved(_ result: AttributionResult) {
        if result.attributed {
            result.rewards.forEach { showRewardNotification($0) }
        }
    }
    func onAttributionError(_ error: Error) {}
    func onDeepLinkReceived(_ url: URL) {}
}
```

## Reward Integration (Phase 3)

### Validate and Redeem Reward

```swift
LinkFlowSDK.shared.validateReward(rewardId: "reward_id") { validation in
    if validation?.valid == true, let token = validation?.redemptionToken {
        LinkFlowSDK.shared.redeemReward(
            redemptionToken: token,
            purchaseAmount: 29.99
        ) { success, message in
            if success { print("Redeemed!") }
        }
    }
}
```

For complete examples and documentation, see Android SDK README.
