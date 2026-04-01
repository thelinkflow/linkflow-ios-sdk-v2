import Foundation
import UIKit
import AdSupport
import AppTrackingTransparency

/// LinkFlow SDK for iOS
/// Handles deferred deep linking and attribution for iOS apps
@objc public class LinkFlowSDK: NSObject {

    // MARK: - Properties

    private static var sharedInstance: LinkFlowSDK?
    private let apiBaseURL: String
    private let enableLogging: Bool
    private var attributionCallback: AttributionCallback?
    private var installId: String?

    private let session: URLSession
    private let userDefaults = UserDefaults.standard

    // MARK: - Initialization

    private init(apiBaseURL: String, enableLogging: Bool) {
        self.apiBaseURL = apiBaseURL
        self.enableLogging = enableLogging

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 10
        self.session = URLSession(configuration: config)

        super.init()
    }

    /// Initialize the LinkFlow SDK
    /// - Parameters:
    ///   - apiBaseURL: Your LinkFlow API base URL (e.g., "https://api.linkflow.io")
    ///   - enableLogging: Enable debug logging
    /// - Returns: SDK instance
    @objc public static func initialize(apiBaseURL: String = "https://api.linkflow.io",
                                       enableLogging: Bool = false) -> LinkFlowSDK {
        if let instance = sharedInstance {
            return instance
        }

        let instance = LinkFlowSDK(apiBaseURL: apiBaseURL, enableLogging: enableLogging)
        sharedInstance = instance
        return instance
    }

    /// Get shared SDK instance
    /// - Returns: SDK instance
    /// - Throws: Error if SDK not initialized
    @objc public static func shared() throws -> LinkFlowSDK {
        guard let instance = sharedInstance else {
            throw LinkFlowError.notInitialized
        }
        return instance
    }

    // MARK: - Attribution

    /// Set attribution callback
    /// - Parameter callback: Attribution callback handler
    @objc public func setAttributionCallback(_ callback: @escaping AttributionCallback) {
        self.attributionCallback = callback
    }

    /// Handle app launch and resolve attribution
    /// Call this in your AppDelegate.application(_:didFinishLaunchingWithOptions:)
    /// - Parameter userActivity: NSUserActivity from universal link (optional)
    @objc public func handleAppLaunch(userActivity: NSUserActivity? = nil) {
        log("Handling app launch")

        let isFirstLaunch = userDefaults.bool(forKey: "linkflow_first_launch") == false

        if isFirstLaunch {
            log("First launch detected, resolving attribution")
            userDefaults.set(true, forKey: "linkflow_first_launch")
            resolveAttribution(userActivity: userActivity)
        } else {
            // Handle deep link for existing users
            if let userActivity = userActivity {
                handleDeepLink(userActivity: userActivity)
            }
        }
    }

    /// Handle universal link
    /// Call this in AppDelegate.application(_:continue:restorationHandler:)
    /// - Parameter userActivity: NSUserActivity from universal link
    /// - Returns: true if handled
    @objc public func handleUniversalLink(userActivity: NSUserActivity) -> Bool {
        guard userActivity.activityType == NSUserActivityTypeBrowsingWeb,
              let url = userActivity.webpageURL else {
            return false
        }

        log("Handling universal link: \(url)")
        handleDeepLink(userActivity: userActivity)
        return true
    }

    /// Handle custom URL scheme
    /// Call this in AppDelegate.application(_:open:options:)
    /// - Parameter url: URL from custom scheme
    /// - Returns: true if handled
    @objc public func handleCustomURL(url: URL) -> Bool {
        log("Handling custom URL: \(url)")

        DispatchQueue.main.async { [weak self] in
            self?.attributionCallback?(AttributionResult(
                attributed: false,
                deepLinkValue: url.absoluteString,
                deepLinkParams: url.queryParameters,
                campaignData: [:]
            ))
        }

        return true
    }

    // MARK: - Event Tracking

    /// Track in-app event
    /// - Parameters:
    ///   - eventName: Event name (e.g., "purchase", "add_to_cart")
    ///   - params: Event parameters (optional)
    ///   - revenue: Revenue amount (optional)
    @objc public func trackEvent(eventName: String,
                                 params: [String: Any]? = nil,
                                 revenue: NSNumber? = nil) {
        Task {
            do {
                guard let installId = self.installId ?? userDefaults.string(forKey: "linkflow_install_id") else {
                    logError("Cannot track event: install ID not found")
                    return
                }

                var requestData: [String: Any] = [
                    "installId": installId,
                    "eventName": eventName
                ]

                if let params = params {
                    requestData["eventParams"] = params
                }

                if let revenue = revenue {
                    requestData["revenue"] = revenue.doubleValue
                }

                let jsonData = try JSONSerialization.data(withJSONObject: requestData)

                _ = try await sendRequest(
                    endpoint: "/api/attribution/event",
                    method: "POST",
                    body: jsonData
                )

                log("Event tracked: \(eventName)")
            } catch {
                logError("Error tracking event: \(error)")
            }
        }
    }

    // MARK: - Private Methods

    private func resolveAttribution(userActivity: NSUserActivity?) {
        Task {
            do {
                // Request tracking permission on iOS 14+
                if #available(iOS 14, *) {
                    await requestTrackingPermission()
                }

                // Get IDFA
                let idfa = getIDFA()

                // Get IDFV
                let idfv = UIDevice.current.identifierForVendor?.uuidString

                // Extract click token from user activity
                let clickToken = userActivity?.webpageURL?.queryParameters["click_token"]

                // Build device fingerprint
                let fingerprint = buildDeviceFingerprint()

                // Create attribution request
                var requestData: [String: Any] = [
                    "platform": "ios",
                    "idfv": idfv ?? "",
                    "deviceFingerprint": fingerprint,
                    "appVersion": getAppVersion(),
                    "osVersion": UIDevice.current.systemVersion,
                    "sdkVersion": "1.0.0"
                ]

                if let idfa = idfa {
                    requestData["idfa"] = idfa
                }

                if let clickToken = clickToken {
                    requestData["clickToken"] = clickToken
                }

                log("Sending attribution request: \(requestData)")

                let jsonData = try JSONSerialization.data(withJSONObject: requestData)
                let responseData = try await sendRequest(
                    endpoint: "/api/attribution/resolve",
                    method: "POST",
                    body: jsonData
                )

                let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any]
                log("Attribution response: \(json ?? [:])")

                guard let result = json,
                      let attributed = result["attributed"] as? Bool else {
                    throw LinkFlowError.invalidResponse
                }

                if attributed {
                    // Save install ID
                    if let installId = result["installId"] as? String {
                        self.installId = installId
                        userDefaults.set(installId, forKey: "linkflow_install_id")
                    }

                    // Extract deep link data
                    let deepLinkValue = result["deepLinkValue"] as? String
                    let deepLinkParams = result["deepLinkParams"] as? [String: Any] ?? [:]
                    let campaignData = result["campaignData"] as? [String: Any] ?? [:]

                    // Notify callback
                    DispatchQueue.main.async { [weak self] in
                        self?.attributionCallback?(AttributionResult(
                            attributed: true,
                            deepLinkValue: deepLinkValue,
                            deepLinkParams: deepLinkParams,
                            campaignData: campaignData
                        ))
                    }
                } else {
                    DispatchQueue.main.async { [weak self] in
                        self?.attributionCallback?(AttributionResult(attributed: false))
                    }
                }
            } catch {
                logError("Error resolving attribution: \(error)")
                DispatchQueue.main.async { [weak self] in
                    self?.attributionCallback?(AttributionResult(
                        attributed: false,
                        error: error
                    ))
                }
            }
        }
    }

    private func handleDeepLink(userActivity: NSUserActivity) {
        guard let url = userActivity.webpageURL else { return }

        log("Handling deep link: \(url)")

        DispatchQueue.main.async { [weak self] in
            self?.attributionCallback?(AttributionResult(
                attributed: false,
                deepLinkValue: url.absoluteString,
                deepLinkParams: url.queryParameters,
                campaignData: [:]
            ))
        }
    }

    @available(iOS 14, *)
    private func requestTrackingPermission() async {
        await withCheckedContinuation { continuation in
            ATTrackingManager.requestTrackingAuthorization { status in
                self.log("Tracking permission: \(status.rawValue)")
                continuation.resume()
            }
        }
    }

    private func getIDFA() -> String? {
        if #available(iOS 14, *) {
            guard ATTrackingManager.trackingAuthorizationStatus == .authorized else {
                log("Tracking not authorized")
                return nil
            }
        }

        let idfa = ASIdentifierManager.shared().advertisingIdentifier
        return idfa.uuidString != "00000000-0000-0000-0000-000000000000" ? idfa.uuidString : nil
    }

    private func buildDeviceFingerprint() -> [String: Any] {
        let screen = UIScreen.main
        let device = UIDevice.current

        return [
            "userAgent": "iOS/\(device.systemVersion)",
            "timezone": TimeZone.current.identifier,
            "language": Locale.current.languageCode ?? "en",
            "screenWidth": Int(screen.bounds.width * screen.scale),
            "screenHeight": Int(screen.bounds.height * screen.scale),
            "deviceModel": device.model,
            "deviceName": device.name
        ]
    }

    private func getAppVersion() -> String {
        return Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }

    private func sendRequest(endpoint: String, method: String, body: Data? = nil) async throws -> Data {
        guard let url = URL(string: apiBaseURL + endpoint) else {
            throw LinkFlowError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw LinkFlowError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }

        return data
    }

    private func log(_ message: String) {
        if enableLogging {
            print("[LinkFlow] \(message)")
        }
    }

    private func logError(_ message: String) {
        if enableLogging {
            print("[LinkFlow ERROR] \(message)")
        }
    }
}

// MARK: - Attribution Result

/// Attribution result data
@objc public class AttributionResult: NSObject {
    @objc public let attributed: Bool
    @objc public let deepLinkValue: String?
    @objc public let deepLinkParams: [String: Any]
    @objc public let campaignData: [String: Any]
    @objc public let error: Error?

    init(attributed: Bool,
         deepLinkValue: String? = nil,
         deepLinkParams: [String: Any] = [:],
         campaignData: [String: Any] = [:],
         error: Error? = nil) {
        self.attributed = attributed
        self.deepLinkValue = deepLinkValue
        self.deepLinkParams = deepLinkParams
        self.campaignData = campaignData
        self.error = error
        super.init()
    }
}

// MARK: - Callback

/// Attribution callback handler
public typealias AttributionCallback = (AttributionResult) -> Void

// MARK: - Errors

/// LinkFlow SDK errors
public enum LinkFlowError: Error {
    case notInitialized
    case invalidURL
    case invalidResponse
    case httpError(Int)
}

// MARK: - URL Extensions

extension URL {
    var queryParameters: [String: Any] {
        guard let components = URLComponents(url: self, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems else {
            return [:]
        }

        var params: [String: Any] = [:]
        for item in queryItems {
            params[item.name] = item.value ?? ""
        }
        return params
    }
}
