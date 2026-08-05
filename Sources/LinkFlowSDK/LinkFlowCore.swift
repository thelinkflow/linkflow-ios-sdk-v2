import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Configuration

/// SDK configuration.
///
/// The older `initialize(apiBaseURL:enableLogging:)` entry point still works and
/// maps onto this, so existing integrations need no changes.
public struct LinkFlowConfig {

    /// LinkFlow API base URL.
    ///
    /// Previously defaulted to `https://api.linkflow.io`, a host the rest of the
    /// system does not use — the Android and React Native SDKs both pointed at
    /// `thelinkflow.app`. All three now agree.
    public static let defaultAPIBaseURL = "https://thelinkflow.app"

    public let apiBaseURL: String

    /// Public app key issued from the dashboard. Embeddable in the app binary.
    public let appKey: String?

    /// Emit debug logs. Identifiers are redacted regardless of this setting.
    public let enableLogging: Bool

    /// When true the SDK collects and sends nothing until `setConsent(_:)` is
    /// called. Work requested while consent is pending is buffered, not dropped.
    public let requireConsent: Bool

    /// Whether the SDK may read the IDFA — and only when ATT authorization has
    /// already been granted by the host app.
    ///
    /// The SDK never triggers the ATT prompt itself. The previous version called
    /// `requestTrackingAuthorization` from inside attribution resolution, which
    /// showed Apple's prompt at a moment the host app did not control, with no
    /// priming screen. That is a common App Review rejection and it depresses
    /// opt-in rates.
    public let collectAdvertisingID: Bool

    /// Attempts for a network call before giving up on this app run.
    public let maxRetries: Int

    /// Base delay for exponential backoff, in seconds.
    public let retryBaseDelay: TimeInterval

    /// Per-request timeout, in seconds.
    public let timeout: TimeInterval

    public init(
        apiBaseURL: String = LinkFlowConfig.defaultAPIBaseURL,
        appKey: String? = nil,
        enableLogging: Bool = false,
        requireConsent: Bool = false,
        collectAdvertisingID: Bool = true,
        maxRetries: Int = 4,
        retryBaseDelay: TimeInterval = 1.0,
        timeout: TimeInterval = 15.0
    ) {
        self.apiBaseURL = apiBaseURL
        self.appKey = appKey
        self.enableLogging = enableLogging
        self.requireConsent = requireConsent
        self.collectAdvertisingID = collectAdvertisingID
        self.maxRetries = maxRetries
        self.retryBaseDelay = retryBaseDelay
        self.timeout = timeout
    }
}

/// User consent state.
public struct LinkFlowConsent {
    /// Permits attribution resolution and event reporting.
    public let attribution: Bool
    /// Permits reading the advertising identifier.
    public let advertisingID: Bool

    public init(attribution: Bool, advertisingID: Bool? = nil) {
        self.attribution = attribution
        self.advertisingID = advertisingID ?? attribution
    }
}

// MARK: - Errors

public enum LinkFlowError: Error {
    case notInitialized
    case invalidURL
    case invalidResponse
    case httpError(Int)
    case consentRequired
}

// MARK: - Retry policy

/// Exponential backoff with full jitter.
///
/// Randomising across the whole interval (rather than adding a small jitter to a
/// fixed delay) stops a fleet of devices recovering from an outage from
/// synchronising their retries into a thundering herd.
public struct RetryPolicy {
    public let maxAttempts: Int
    public let baseDelay: TimeInterval

    public init(maxAttempts: Int, baseDelay: TimeInterval) {
        self.maxAttempts = max(1, maxAttempts)
        self.baseDelay = max(0, baseDelay)
    }

    /// Delay before the given zero-based attempt. Attempt 0 runs immediately.
    public func delay(forAttempt attempt: Int, randomValue: Double) -> TimeInterval {
        guard attempt > 0 else { return 0 }

        let clamped = min(max(randomValue, 0), 1)
        let ceiling = baseDelay * pow(2.0, Double(attempt - 1))
        return baseDelay + clamped * ceiling
    }

    /// Whether a status code is worth retrying. 408 and 429 are explicitly
    /// retryable; other 4xx will never succeed no matter how often we ask.
    public static func isRetryable(statusCode: Int) -> Bool {
        statusCode == 408 || statusCode == 429 || statusCode >= 500
    }
}

// MARK: - HTTP

public enum HTTPOutcome {
    case success(Data)
    /// 4xx other than 408/429 — the request will never succeed.
    case permanentFailure(Int, Data?)
    /// Network error, timeout, 5xx, 408 or 429 — worth retrying.
    case transientFailure(Int?, Error?)
}

/// Minimal transport with retry. The previous implementation fired a single
/// request and dropped the result on any failure, so a user who opened the app
/// on a flaky connection lost their install attribution permanently.
public final class LinkFlowHTTPClient {

    private let config: LinkFlowConfig
    private let session: URLSession
    private let log: (String) -> Void

    public init(config: LinkFlowConfig, log: @escaping (String) -> Void = { _ in }) {
        self.config = config
        self.log = log

        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = config.timeout
        sessionConfig.timeoutIntervalForResource = config.timeout
        self.session = URLSession(configuration: sessionConfig)
    }

    public func send(path: String, method: String, body: Data?) async -> HTTPOutcome {
        let policy = RetryPolicy(maxAttempts: config.maxRetries, baseDelay: config.retryBaseDelay)
        var lastTransient: HTTPOutcome = .transientFailure(nil, nil)

        for attempt in 0..<policy.maxAttempts {
            if attempt > 0 {
                let seconds = policy.delay(forAttempt: attempt, randomValue: Double.random(in: 0...1))
                log("Retrying request (attempt \(attempt + 1)) after \(String(format: "%.2f", seconds))s")
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            }

            let outcome = await attemptRequest(path: path, method: method, body: body)
            switch outcome {
            case .success, .permanentFailure:
                return outcome
            case .transientFailure:
                lastTransient = outcome
            }
        }

        return lastTransient
    }

    private func attemptRequest(path: String, method: String, body: Data?) async -> HTTPOutcome {
        guard let url = URL(string: config.apiBaseURL + path) else {
            return .permanentFailure(0, nil)
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let appKey = config.appKey, !appKey.isEmpty {
            request.setValue(appKey, forHTTPHeaderField: "X-LinkFlow-App-Key")
        }
        request.httpBody = body

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .transientFailure(nil, LinkFlowError.invalidResponse)
            }

            if (200...299).contains(http.statusCode) {
                return .success(data)
            }

            return RetryPolicy.isRetryable(statusCode: http.statusCode)
                ? .transientFailure(http.statusCode, nil)
                : .permanentFailure(http.statusCode, data)
        } catch {
            return .transientFailure(nil, error)
        }
    }
}

// MARK: - Attribution result parsing

/// Platform-independent view of an attribution response.
public struct ParsedAttribution {
    public let attributed: Bool
    public let installID: String?
    public let installToken: String?
    public let deepLinkValue: String?
    public let deepLinkParams: [String: Any]
    public let campaignData: [String: Any]
    public let attributionMethod: String?
    public let confidence: Double?
    public let isReinstall: Bool

    public init(json: [String: Any]) {
        attributed = json["attributed"] as? Bool ?? false
        installID = ParsedAttribution.nonEmptyString(json["installId"])
        installToken = ParsedAttribution.nonEmptyString(json["installToken"])
        deepLinkValue = ParsedAttribution.nonEmptyString(json["deepLinkValue"])
        deepLinkParams = ParsedAttribution.dictionary(json["deepLinkParams"])
        campaignData = ParsedAttribution.dictionary(json["campaignData"])
        attributionMethod = ParsedAttribution.nonEmptyString(json["attributionMethod"])
        confidence = ParsedAttribution.double(json["confidence"])
        isReinstall = json["isReinstall"] as? Bool ?? false
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return string
    }

    private static func double(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }

    /// `deepLinkParams` arrives as a JSON object from the link's stored params, but
    /// those are persisted as a JSON *string* column, so the server may hand back
    /// either shape. Accept both rather than silently losing the payload.
    private static func dictionary(_ value: Any?) -> [String: Any] {
        if let dict = value as? [String: Any] { return dict }

        if let string = value as? String,
           let data = string.data(using: .utf8),
           let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return decoded
        }

        return [:]
    }
}

// MARK: - Event queue

/// Durable, bounded queue for events that could not be delivered.
///
/// Events used to be fired once and dropped on any failure, silently losing
/// conversions and revenue whenever the network was unavailable. Entries persist
/// across launches and are flushed on the next foreground.
///
/// Each entry carries a client-generated `eventId` that the server treats as an
/// idempotency key, so a retry that actually did land the first time does not
/// double-count revenue.
public final class EventQueue {

    /// Oldest entries are dropped beyond this, so a long offline period cannot
    /// grow the file without bound.
    public static let maxEntries = 500

    private let fileURL: URL
    private let lock = NSLock()

    public init(directory: URL, filename: String = "linkflow-events.json") {
        self.fileURL = directory.appendingPathComponent(filename)
    }

    /// Default location: Application Support, which is backed up but not
    /// user-visible. Falls back to the temporary directory if unavailable.
    public static func defaultDirectory() -> URL {
        let fm = FileManager.default
        if let support = try? fm.url(for: .applicationSupportDirectory,
                                     in: .userDomainMask,
                                     appropriateFor: nil,
                                     create: true) {
            let dir = support.appendingPathComponent("LinkFlow", isDirectory: true)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        return fm.temporaryDirectory
    }

    /// Adds an event, returning the payload actually queued (including its id).
    @discardableResult
    public func enqueue(_ payload: [String: Any]) -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }

        var entry = payload
        if entry["eventId"] == nil {
            entry["eventId"] = UUID().uuidString
        }

        var entries = readUnlocked()
        entries.append(entry)

        if entries.count > EventQueue.maxEntries {
            entries.removeFirst(entries.count - EventQueue.maxEntries)
        }

        writeUnlocked(entries)
        return entry
    }

    public func peekAll() -> [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        return readUnlocked()
    }

    public func remove(eventID: String) {
        lock.lock()
        defer { lock.unlock() }

        let remaining = readUnlocked().filter { ($0["eventId"] as? String) != eventID }
        writeUnlocked(remaining)
    }

    public func count() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return readUnlocked().count
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func readUnlocked() -> [[String: Any]] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            // A corrupt queue is not worth crashing the host app over.
            try? FileManager.default.removeItem(at: fileURL)
            return []
        }
        return parsed
    }

    private func writeUnlocked(_ entries: [[String: Any]]) {
        guard let data = try? JSONSerialization.data(withJSONObject: entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

// MARK: - URL helpers

extension URL {
    /// Query parameters as a dictionary.
    public var queryParameters: [String: Any] {
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

    /// Value of a single query parameter, or nil when absent or empty.
    public func queryValue(for name: String) -> String? {
        guard let components = URLComponents(url: self, resolvingAgainstBaseURL: false) else {
            return nil
        }
        guard let value = components.queryItems?.first(where: { $0.name == name })?.value,
              !value.isEmpty else {
            return nil
        }
        return value
    }
}

// MARK: - Redaction

enum LinkFlowRedaction {
    static let sensitiveKeys: Set<String> = [
        "advertisingId", "idfa", "idfv", "vendorId", "clickToken", "installToken", "installReferrer",
    ]

    /// Strips identifiers before a payload reaches the log.
    ///
    /// The previous implementation logged the full request body, putting the IDFA
    /// into the device console.
    static func redact(_ payload: [String: Any]) -> [String: Any] {
        var copy = payload
        for key in sensitiveKeys where copy[key] != nil {
            copy[key] = "«redacted»"
        }
        return copy
    }
}
