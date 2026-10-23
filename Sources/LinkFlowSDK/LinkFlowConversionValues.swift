import Foundation

#if os(iOS) && canImport(StoreKit)
import StoreKit
#endif

#if os(iOS) && canImport(AdAttributionKit)
import AdAttributionKit
#endif

/// Hands a conversion value to Apple's frameworks.
///
/// * iOS 17.4+: AdAttributionKit `Postback.updateConversionValue(_:coarseConversionValue:lockPostback:)`.
/// * iOS 16.1+: SKAdNetwork 4 `updatePostbackConversionValue(_:coarseValue:lockWindow:)`.
/// * iOS 15.4–16.0: SKAdNetwork `updatePostbackConversionValue(_:)` (fine value only).
///
/// On 17.4+ both frameworks are called: an app can be attributed by either, and
/// Apple's interoperability between the two is not something this SDK should
/// depend on silently. Errors are logged, never thrown into the host app.
enum AppleConversionValueReporter {

    static func report(_ update: ConversionValueUpdate, log: @escaping (String) -> Void) {
        #if os(iOS)
        #if canImport(AdAttributionKit)
        if #available(iOS 17.4, *) {
            Task {
                do {
                    let coarse: AdAttributionKit.CoarseConversionValue =
                        update.coarse == .high ? .high : update.coarse == .medium ? .medium : .low
                    try await Postback.updateConversionValue(update.fine, coarseConversionValue: coarse, lockPostback: update.lockWindow)
                    log("AdAttributionKit conversion value set: \(update.fine)/\(update.coarse.rawValue)")
                } catch {
                    log("AdAttributionKit update failed: \(error)")
                }
            }
        }
        #endif

        #if canImport(StoreKit)
        if #available(iOS 16.1, *) {
            let coarse: SKAdNetwork.CoarseConversionValue =
                update.coarse == .high ? .high : update.coarse == .medium ? .medium : .low
            SKAdNetwork.updatePostbackConversionValue(update.fine, coarseValue: coarse, lockWindow: update.lockWindow) { error in
                if let error { log("SKAdNetwork update failed: \(error)") }
                else { log("SKAdNetwork conversion value set: \(update.fine)/\(update.coarse.rawValue)") }
            }
        } else if #available(iOS 15.4, *) {
            SKAdNetwork.updatePostbackConversionValue(update.fine) { error in
                if let error { log("SKAdNetwork update failed: \(error)") }
            }
        }
        #endif
        #endif
    }
}
