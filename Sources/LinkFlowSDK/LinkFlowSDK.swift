import Foundation

#if canImport(UIKit)
import UIKit
#endif

#if canImport(AdSupport)
import AdSupport
#endif

#if canImport(AppTrackingTransparency)
import AppTrackingTransparency
#endif

// The public surface below is Objective-C facing (`@objc`, `NSObject`), which
// requires the Objective-C runtime. That is present on every Apple platform the
// SDK ships to. The guard exists so the platform-independent core in
// LinkFlowCore.swift still compiles and unit-tests on Linux CI, where ObjC
// interop is unavailable.
#if canImport(ObjectiveC)

// MARK: - Attribution result

/// Attribution result delivered to the callback.
@objc public class AttributionResult: NSObject {
    @objc public let attributed: Bool
    @objc public let deepLinkValue: String?
    @objc public let deepLinkParams: [String: Any]
    @objc public let campaignData: [String: Any]
    @objc public let error: Error?

    /// "install_referrer", "click_token", "device_id" or "fingerprint".
    @objc public let attributionMethod: String?

    /// 0.0–1.0. Deterministic matches are 1.0; fingerprint matches are scored.
    /// Reported as -1 when absent, since `Double?` is not representable in ObjC.
    @objc public let confidence: Double

    /// True when this device had already installed the app before.
    @objc public let isReinstall: Bool

    init(
        attributed: Bool,
        deepLinkValue: String? = nil,
        deepLinkParams: [String: Any] = [:],
        campaignData: [String: Any] = [:],
        error: Error? = nil,
        attributionMethod: String? = nil,
        confidence: Double? = nil,
        isReinstall: Bool = false
    ) {
        self.attributed = attributed
        self.deepLinkValue = deepLinkValue
        self.deepLinkParams = deepLinkParams
        self.campaignData = campaignData
        self.error = error
        self.attributionMethod = attributionMethod
        self.confidence = confidence ?? -1
        self.isReinstall = isReinstall
        super.init()
    }

    convenience init(parsed: ParsedAttribution) {
        self.init(
            attributed: parsed.attributed,
            deepLinkValue: parsed.deepLinkValue,
            deepLinkParams: parsed.deepLinkParams,
            campaignData: parsed.campaignData,
            error: nil,
            attributionMethod: parsed.attributionMethod,
            confidence: parsed.confidence,
            isReinstall: parsed.isReinstall
        )
    }
}

/// Attribution callback handler.
public typealias AttributionCallback = (AttributionResult) -> Void

// MARK: - SDK

/// LinkFlow SDK for iOS.
///
/// Handles deferred deep linking and attribution.
///
/// Minimal integration:
/// ```swift
/// LinkFlowSDK.initialize(config: LinkFlowConfig(appKey: "lfa_..."))
///     .setAttributionCallback { result in ... }
/// try? LinkFlowSDK.shared().handleAppLaunch()
/// ```
///
/// The SDK never presents the App Tracking Transparency prompt. Request
/// authorization at a moment your app controls, then call
/// ``setTrackingAuthorized()`` if you want the IDFA included.
@objc public class LinkFlowSDK: NSObject {

    // MARK: Properties

    private static var sharedInstance: LinkFlowSDK?

    private let config: LinkFlowConfig
    private let store: LinkFlowStore
    private let http: LinkFlowHTTPClient
    private let eventQueue: EventQueue

    private var attributionCallback: AttributionCallback?
    private let stateLock = NSLock()

    private var consent: LinkFlowConsent?
    private var pendingLaunchURL: URL?
    private var hasPendingLaunch = false
    private var cachedResult: AttributionResult?

    /// Reported to the server as `sdkVersion`.
    @objc public static let sdkVersion = "2.0.0"

    // MARK: Initialization

    private init(config: LinkFlowConfig) {
        self.config = config
        self.store = LinkFlowStore()
        self.http = LinkFlowHTTPClient(config: config)
        self.eventQueue = EventQueue(directory: EventQueue.defaultDirectory())

        if !config.requireConsent {
            self.consent = LinkFlowConsent(attribution: true, advertisingID: config.collectAdvertisingID)
        }

        super.init()
    }

    /// Initializes the SDK. Repeat calls return the existing instance.
    @discardableResult
    public static func initialize(config: LinkFlowConfig) -> LinkFlowSDK {
        if let instance = sharedInstance { return instance }
        let instance = LinkFlowSDK(config: config)
        sharedInstance = instance
        return instance
    }

    /// Legacy entry point, retained so existing integrations keep compiling.
    ///
    /// Prefer ``initialize(config:)`` — it is the only way to supply an app key
    /// or a consent policy.
    @discardableResult
    @objc public static func initialize(
        apiBaseURL: String = LinkFlowConfig.defaultAPIBaseURL,
        enableLogging: Bool = false
    ) -> LinkFlowSDK {
        initialize(config: LinkFlowConfig(apiBaseURL: apiBaseURL, enableLogging: enableLogging))
    }

    @objc public static func shared() throws -> LinkFlowSDK {
        guard let instance = sharedInstance else { throw LinkFlowError.notInitialized }
        return instance
    }

    /// Test/teardown hook.
    static func resetForTesting() {
        sharedInstance = nil
    }

    // MARK: Callbacks

    @discardableResult
    @objc public func setAttributionCallback(_ callback: @escaping AttributionCallback) -> LinkFlowSDK {
        stateLock.lock()
        attributionCallback = callback
        stateLock.unlock()
        return self
    }

    // MARK: Consent

    /// Records the user's consent decision.
    ///
    /// Only required when the SDK was configured with `requireConsent: true`.
    /// Granting consent replays a launch buffered while waiting, so no
    /// attribution is lost to the consent prompt.
    public func setConsent(_ consent: LinkFlowConsent) {
        stateLock.lock()
        self.consent = consent
        let replay = consent.attribution && hasPendingLaunch
        let url = pendingLaunchURL
        if replay {
            hasPendingLaunch = false
            pendingLaunchURL = nil
        }
        stateLock.unlock()

        log("Consent set: attribution=\(consent.attribution) advertisingID=\(consent.advertisingID)")

        if replay {
            handleAppLaunch(url: url)
        } else if consent.attribution {
            Task { await flushEventQueue() }
        }
    }

    /// Convenience for apps that have already obtained ATT authorization and want
    /// the IDFA included. Does not present any prompt.
    @objc public func setTrackingAuthorized() {
        let current = stateLock.withLock { consent } ?? LinkFlowConsent(attribution: true)
        setConsent(LinkFlowConsent(attribution: current.attribution, advertisingID: true))
    }

    // MARK: App launch

    /// Handles app launch: resolves attribution on first launch, otherwise
    /// processes any deep link and flushes queued events. Safe to call every launch.
    @objc public func handleAppLaunch(userActivity: NSUserActivity? = nil) {
        handleAppLaunch(url: userActivity?.webpageURL)
    }

    /// Overload for a launch URL obtained from a custom scheme or launch options.
    public func handleAppLaunch(url: URL?) {
        let granted = stateLock.withLock { consent }

        guard let granted, granted.attribution else {
            log("Consent pending; buffering app launch until setConsent(_:) is called")
            stateLock.lock()
            pendingLaunchURL = url
            hasPendingLaunch = true
            stateLock.unlock()
            return
        }

        Task {
            if store.attributionComplete {
                if let url { deliverDeepLink(url) }
            } else {
                await resolveAttribution(launchURL: url)
            }
            await flushEventQueue()
        }
    }

    /// Handles a universal link. Call from
    /// `application(_:continue:restorationHandler:)`.
    @objc public func handleUniversalLink(userActivity: NSUserActivity) -> Bool {
        guard userActivity.activityType == NSUserActivityTypeBrowsingWeb,
              let url = userActivity.webpageURL else {
            return false
        }

        log("Handling universal link")
        deliverDeepLink(url)
        return true
    }

    /// Handles a custom URL scheme. Call from `application(_:open:options:)`.
    @objc public func handleCustomURL(url: URL) -> Bool {
        log("Handling custom URL")
        deliverDeepLink(url)
        return true
    }

    // MARK: Events

    /// Tracks an in-app event.
    ///
    /// Events are queued durably and retried, so a call made while offline is
    /// delivered later rather than dropped. Delivery is idempotent.
    @objc public func trackEvent(
        eventName: String,
        params: [String: Any]? = nil,
        revenue: NSNumber? = nil
    ) {
        let granted = stateLock.withLock { consent }
        guard let granted, granted.attribution else {
            log("Consent pending; dropping event '\(eventName)'")
            return
        }

        var payload: [String: Any] = ["eventName": eventName]
        if let params { payload["eventParams"] = params }
        if let revenue { payload["revenue"] = revenue.doubleValue }

        eventQueue.enqueue(payload)
        Task { await flushEventQueue() }
    }

    /// The most recent attribution result, restored from disk if needed.
    @objc public func getAttributionResult() -> AttributionResult? {
        if let cached = stateLock.withLock({ cachedResult }) { return cached }
        guard let json = store.lastResultJSON else { return nil }

        let result = AttributionResult(parsed: ParsedAttribution(json: json))
        stateLock.withLock { cachedResult = result }
        return result
    }

    /// Number of events waiting to be delivered. Useful in diagnostics.
    @objc public func pendingEventCount() -> Int {
        eventQueue.count()
    }

    // MARK: - Attribution

    private func resolveAttribution(launchURL: URL?) async {
        let clickToken = launchURL?.queryValue(for: "click_token")

        var payload: [String: Any] = [
            "platform": "ios",
            "deviceFingerprint": buildDeviceFingerprint(),
            "appVersion": appVersion(),
            "osVersion": systemVersion(),
            "deviceModel": deviceModel(),
            "sdkVersion": LinkFlowSDK.sdkVersion,
        ]

        if let bundleID = Bundle.main.bundleIdentifier {
            payload["bundleId"] = bundleID
        }

        // Canonical spellings. The SDK used to send "idfa"/"idfv" while the server
        // bound "advertisingId"/"vendorId", so every iOS install stored nulls.
        if let vendorID = identifierForVendor() {
            payload["vendorId"] = vendorID
        }
        if let advertisingID = advertisingIdentifier() {
            payload["advertisingId"] = advertisingID
        }
        if let clickToken {
            payload["clickToken"] = clickToken
        }

        log("Resolving attribution: \(LinkFlowRedaction.redact(payload))")

        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            deliver(AttributionResult(attributed: false, error: LinkFlowError.invalidResponse))
            return
        }

        switch await http.send(path: "/api/attribution/resolve", method: "POST", body: body) {
        case .success(let data):
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                deliver(AttributionResult(attributed: false, error: LinkFlowError.invalidResponse))
                return
            }
            handleResolveSuccess(json)

        case .permanentFailure(let code, _):
            // A 4xx will never succeed; stop retrying on future launches.
            log("Attribution rejected (HTTP \(code)); not retrying")
            store.attributionComplete = true
            deliver(AttributionResult(attributed: false, error: LinkFlowError.httpError(code)))

        case .transientFailure(_, let error):
            // Leave the flag unset so the next launch tries again. This is the case
            // the old implementation lost permanently.
            log("Attribution could not be delivered; will retry on next launch")
            deliver(AttributionResult(attributed: false, error: error ?? LinkFlowError.invalidResponse))
        }
    }

    private func handleResolveSuccess(_ json: [String: Any]) {
        // Only now is attribution genuinely complete.
        store.attributionComplete = true

        let parsed = ParsedAttribution(json: json)

        if parsed.attributed {
            store.installID = parsed.installID
            // Returned once, at creation. Authenticates subsequent event calls.
            if let token = parsed.installToken {
                store.installToken = token
            }
            store.lastResultJSON = json
        }

        let result = AttributionResult(parsed: parsed)
        stateLock.withLock { cachedResult = result }

        log("Attribution resolved: attributed=\(parsed.attributed) method=\(parsed.attributionMethod ?? "none")")
        deliver(result)
    }

    private func deliverDeepLink(_ url: URL) {
        deliver(AttributionResult(
            attributed: false,
            deepLinkValue: url.absoluteString,
            deepLinkParams: url.queryParameters
        ))
    }

    private func deliver(_ result: AttributionResult) {
        let callback = stateLock.withLock { attributionCallback }
        guard let callback else { return }

        #if canImport(UIKit)
        DispatchQueue.main.async { callback(result) }
        #else
        callback(result)
        #endif
    }

    // MARK: - Event delivery

    private func flushEventQueue() async {
        guard let installID = store.installID else {
            if eventQueue.count() > 0 {
                log("Holding \(eventQueue.count()) event(s): attribution has not produced an install id yet")
            }
            return
        }

        for event in eventQueue.peekAll() {
            guard let eventID = event["eventId"] as? String else { continue }

            var payload = event
            payload["installId"] = installID
            if let token = store.installToken {
                payload["installToken"] = token
            }

            guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
                eventQueue.remove(eventID: eventID)
                continue
            }

            switch await http.send(path: "/api/attribution/event", method: "POST", body: body) {
            case .success:
                eventQueue.remove(eventID: eventID)
                log("Event delivered: \(event["eventName"] as? String ?? "?")")

            case .permanentFailure(let code, _):
                // Retrying a rejected event forever would block the queue.
                eventQueue.remove(eventID: eventID)
                log("Event rejected (HTTP \(code)); discarding")

            case .transientFailure:
                // Stop the flush: later events are likely to fail the same way,
                // and order is worth preserving.
                log("Event delivery deferred; \(eventQueue.count()) event(s) still queued")
                return
            }
        }
    }

    // MARK: - Device signals

    /// Signals used for probabilistic matching.
    ///
    /// No IP address: the server takes it from the connection. The old
    /// implementation omitted it here while the server required it from the
    /// request body, which disabled fingerprint matching on iOS entirely.
    ///
    /// `deviceName` is also gone — it is user-set, frequently contains a real
    /// name, and contributed nothing to matching.
    private func buildDeviceFingerprint() -> [String: Any] {
        var fingerprint: [String: Any] = [
            "timezone": TimeZone.current.identifier,
            "osVersion": systemVersion(),
            "deviceModel": deviceModel(),
        ]

        if let language = Locale.current.languageCode {
            fingerprint["language"] = language
        }

        #if canImport(UIKit)
        let screen = UIScreen.main
        fingerprint["screenWidth"] = Int(screen.bounds.width * screen.scale)
        fingerprint["screenHeight"] = Int(screen.bounds.height * screen.scale)
        #endif

        return fingerprint
    }

    /// Reads the IDFA only when the host app has already obtained ATT
    /// authorization. The SDK never presents the prompt itself.
    private func advertisingIdentifier() -> String? {
        let granted = stateLock.withLock { consent }
        guard config.collectAdvertisingID, granted?.advertisingID == true else { return nil }

        #if canImport(AppTrackingTransparency) && canImport(AdSupport)
        if #available(iOS 14, *) {
            guard ATTrackingManager.trackingAuthorizationStatus == .authorized else {
                log("IDFA unavailable: tracking not authorized by the host app")
                return nil
            }
        }

        let idfa = ASIdentifierManager.shared().advertisingIdentifier.uuidString
        return idfa == "00000000-0000-0000-0000-000000000000" ? nil : idfa
        #else
        return nil
        #endif
    }

    private func identifierForVendor() -> String? {
        #if canImport(UIKit)
        return UIDevice.current.identifierForVendor?.uuidString
        #else
        return nil
        #endif
    }

    private func systemVersion() -> String {
        #if canImport(UIKit)
        return UIDevice.current.systemVersion
        #else
        return ProcessInfo.processInfo.operatingSystemVersionString
        #endif
    }

    /// Hardware identifier such as "iPhone15,2".
    ///
    /// `UIDevice.model` returns only "iPhone"/"iPad", which is too coarse to
    /// distinguish devices during fingerprint scoring.
    private func deviceModel() -> String {
        #if canImport(UIKit)
        var systemInfo = utsname()
        uname(&systemInfo)
        let identifier = withUnsafePointer(to: &systemInfo.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 1) { String(validatingUTF8: $0) }
        }
        return identifier ?? UIDevice.current.model
        #else
        return "unknown"
        #endif
    }

    private func appVersion() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }

    // MARK: - Logging

    private func log(_ message: String) {
        guard config.enableLogging else { return }
        print("[LinkFlow] \(message)")
    }
}

// MARK: - Locking helper

extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

#endif // canImport(ObjectiveC)
