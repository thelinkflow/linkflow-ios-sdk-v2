import XCTest
@testable import LinkFlowSDK

// MARK: - Configuration

final class LinkFlowConfigTests: XCTestCase {

    func testDefaultBaseURLMatchesTheOtherSDKs() {
        // Previously defaulted to https://api.linkflow.io, a host the rest of the
        // system does not use, while Android and React Native pointed at
        // thelinkflow.app.
        XCTAssertEqual(LinkFlowConfig.defaultAPIBaseURL, "https://thelinkflow.app")
        XCTAssertEqual(LinkFlowConfig().apiBaseURL, "https://thelinkflow.app")
    }

    func testConsentIsNotRequiredByDefault() {
        XCTAssertFalse(LinkFlowConfig().requireConsent)
    }

    func testAdvertisingConsentDefaultsToTheAttributionDecision() {
        XCTAssertTrue(LinkFlowConsent(attribution: true).advertisingID)
        XCTAssertFalse(LinkFlowConsent(attribution: false).advertisingID)
    }

    func testAdvertisingConsentCanBeWithheldIndependently() {
        let consent = LinkFlowConsent(attribution: true, advertisingID: false)
        XCTAssertTrue(consent.attribution)
        XCTAssertFalse(consent.advertisingID)
    }

    func testRetryDefaultsAreBounded() {
        let config = LinkFlowConfig()
        XCTAssertTrue((1...10).contains(config.maxRetries))
        XCTAssertGreaterThan(config.timeout, 0)
    }
}

// MARK: - Retry policy

final class RetryPolicyTests: XCTestCase {

    func testFirstAttemptRunsImmediately() {
        let policy = RetryPolicy(maxAttempts: 4, baseDelay: 1.0)
        XCTAssertEqual(policy.delay(forAttempt: 0, randomValue: 1.0), 0)
    }

    func testBackoffGrowsWithEachAttempt() {
        let policy = RetryPolicy(maxAttempts: 5, baseDelay: 1.0)

        // Compare at a fixed random value so growth, not jitter, is measured.
        let first = policy.delay(forAttempt: 1, randomValue: 1.0)
        let second = policy.delay(forAttempt: 2, randomValue: 1.0)
        let third = policy.delay(forAttempt: 3, randomValue: 1.0)

        XCTAssertLessThan(first, second)
        XCTAssertLessThan(second, third)
    }

    func testJitterSpansTheWholeInterval() {
        // Full jitter is what stops a fleet recovering from an outage from
        // synchronising into a thundering herd.
        let policy = RetryPolicy(maxAttempts: 5, baseDelay: 2.0)

        let low = policy.delay(forAttempt: 3, randomValue: 0.0)
        let high = policy.delay(forAttempt: 3, randomValue: 1.0)

        XCTAssertEqual(low, 2.0, accuracy: 0.0001)
        XCTAssertGreaterThan(high, low * 2)
    }

    func testDelayNeverNegativeForOutOfRangeRandomValues() {
        let policy = RetryPolicy(maxAttempts: 3, baseDelay: 1.0)
        XCTAssertGreaterThanOrEqual(policy.delay(forAttempt: 2, randomValue: -5), 0)
        XCTAssertGreaterThanOrEqual(policy.delay(forAttempt: 2, randomValue: 5), 0)
    }

    func testAttemptCountIsAlwaysAtLeastOne() {
        XCTAssertEqual(RetryPolicy(maxAttempts: 0, baseDelay: 1).maxAttempts, 1)
        XCTAssertEqual(RetryPolicy(maxAttempts: -3, baseDelay: 1).maxAttempts, 1)
    }

    func testRetryableStatusCodes() {
        // 408 and 429 are explicitly retryable; other 4xx never succeed.
        XCTAssertTrue(RetryPolicy.isRetryable(statusCode: 408))
        XCTAssertTrue(RetryPolicy.isRetryable(statusCode: 429))
        XCTAssertTrue(RetryPolicy.isRetryable(statusCode: 500))
        XCTAssertTrue(RetryPolicy.isRetryable(statusCode: 503))

        XCTAssertFalse(RetryPolicy.isRetryable(statusCode: 400))
        XCTAssertFalse(RetryPolicy.isRetryable(statusCode: 401))
        XCTAssertFalse(RetryPolicy.isRetryable(statusCode: 404))
    }
}

// MARK: - Attribution response parsing

final class ParsedAttributionTests: XCTestCase {

    func testParsesFullSuccessResponse() {
        let parsed = ParsedAttribution(json: [
            "attributed": true,
            "installId": "11111111-2222-3333-4444-555555555555",
            "installToken": "tok_abc",
            "attributionMethod": "install_referrer",
            "confidence": 1.0,
            "isReinstall": false,
            "deepLinkParams": ["screen": "promo"],
            "campaignData": ["utmSource": "newsletter"],
        ])

        XCTAssertTrue(parsed.attributed)
        XCTAssertEqual(parsed.installID, "11111111-2222-3333-4444-555555555555")
        XCTAssertEqual(parsed.installToken, "tok_abc")
        XCTAssertEqual(parsed.attributionMethod, "install_referrer")
        XCTAssertEqual(parsed.confidence, 1.0)
        XCTAssertFalse(parsed.isReinstall)
        XCTAssertEqual(parsed.deepLinkParams["screen"] as? String, "promo")
    }

    func testParsesUnattributedResponse() {
        let parsed = ParsedAttribution(json: ["attributed": false, "message": "No matching click found"])

        XCTAssertFalse(parsed.attributed)
        XCTAssertNil(parsed.installID)
        XCTAssertNil(parsed.attributionMethod)
        XCTAssertTrue(parsed.deepLinkParams.isEmpty)
    }

    func testAcceptsDeepLinkParamsAsAJSONString() {
        // The link's params are stored as a JSON string column, so the server can
        // hand back either shape. Losing the payload to the wrong one would
        // silently break deferred deep linking.
        let parsed = ParsedAttribution(json: [
            "attributed": true,
            "deepLinkParams": "{\"screen\":\"promo\",\"id\":42}",
        ])

        XCTAssertEqual(parsed.deepLinkParams["screen"] as? String, "promo")
    }

    func testTreatsEmptyStringsAsAbsent() {
        let parsed = ParsedAttribution(json: [
            "attributed": true,
            "installId": "",
            "attributionMethod": "",
        ])

        XCTAssertNil(parsed.installID)
        XCTAssertNil(parsed.attributionMethod)
    }

    func testHandlesMissingAndMalformedFields() {
        let parsed = ParsedAttribution(json: [:])

        XCTAssertFalse(parsed.attributed)
        XCTAssertNil(parsed.confidence)
        XCTAssertFalse(parsed.isReinstall)
        XCTAssertTrue(parsed.campaignData.isEmpty)
    }

    func testParsesConfidenceFromNumberOrString() {
        XCTAssertEqual(ParsedAttribution(json: ["confidence": 0.82]).confidence, 0.82)
        XCTAssertEqual(ParsedAttribution(json: ["confidence": "0.82"]).confidence, 0.82)
    }
}

// MARK: - Event queue

final class EventQueueTests: XCTestCase {

    private var directory: URL!
    private var queue: EventQueue!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkflow-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        queue = EventQueue(directory: directory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testEnqueueAssignsAnIdempotencyKey() {
        let stored = queue.enqueue(["eventName": "purchase", "revenue": 9.99])

        // The id is what stops a retry that actually landed from double-counting.
        XCTAssertNotNil(stored["eventId"] as? String)
        XCTAssertEqual(queue.count(), 1)
    }

    func testEnqueuePreservesACallerSuppliedId() {
        let stored = queue.enqueue(["eventName": "purchase", "eventId": "fixed-id"])
        XCTAssertEqual(stored["eventId"] as? String, "fixed-id")
    }

    func testEventsSurviveANewQueueInstance() {
        queue.enqueue(["eventName": "purchase"])

        // Simulates the app being killed and relaunched.
        let reopened = EventQueue(directory: directory)
        XCTAssertEqual(reopened.count(), 1)
        XCTAssertEqual(reopened.peekAll().first?["eventName"] as? String, "purchase")
    }

    func testRemoveDeletesOnlyTheNamedEvent() {
        let first = queue.enqueue(["eventName": "a"])
        queue.enqueue(["eventName": "b"])

        queue.remove(eventID: first["eventId"] as! String)

        XCTAssertEqual(queue.count(), 1)
        XCTAssertEqual(queue.peekAll().first?["eventName"] as? String, "b")
    }

    func testQueueIsBounded() {
        for index in 0..<(EventQueue.maxEntries + 25) {
            queue.enqueue(["eventName": "event-\(index)"])
        }

        XCTAssertEqual(queue.count(), EventQueue.maxEntries)
        // Oldest are dropped, so the newest event must still be present.
        XCTAssertEqual(queue.peekAll().last?["eventName"] as? String,
                       "event-\(EventQueue.maxEntries + 24)")
    }

    func testFIFOOrderIsPreserved() {
        queue.enqueue(["eventName": "first"])
        queue.enqueue(["eventName": "second"])

        let names = queue.peekAll().compactMap { $0["eventName"] as? String }
        XCTAssertEqual(names, ["first", "second"])
    }

    func testCorruptQueueFileIsDiscardedNotFatal() {
        let file = directory.appendingPathComponent("linkflow-events.json")
        try? "this is not json".data(using: .utf8)!.write(to: file)

        XCTAssertEqual(queue.count(), 0)

        // And the queue remains usable afterwards.
        queue.enqueue(["eventName": "recovered"])
        XCTAssertEqual(queue.count(), 1)
    }
}

// MARK: - URL handling

final class URLHelperTests: XCTestCase {

    func testExtractsClickTokenFromLaunchURL() {
        let url = URL(string: "https://thelinkflow.app/r/abc?click_token=tok123&utm_source=email")!

        XCTAssertEqual(url.queryValue(for: "click_token"), "tok123")
        XCTAssertEqual(url.queryParameters["utm_source"] as? String, "email")
    }

    func testMissingParameterIsNil() {
        let url = URL(string: "https://thelinkflow.app/r/abc")!
        XCTAssertNil(url.queryValue(for: "click_token"))
    }

    func testEmptyParameterIsTreatedAsAbsent() {
        let url = URL(string: "https://thelinkflow.app/r/abc?click_token=")!
        XCTAssertNil(url.queryValue(for: "click_token"))
    }

    func testHandlesEncodedValues() {
        let url = URL(string: "https://thelinkflow.app/r/abc?utm_campaign=spring%20sale")!
        XCTAssertEqual(url.queryParameters["utm_campaign"] as? String, "spring sale")
    }
}

// MARK: - Redaction

final class RedactionTests: XCTestCase {

    func testStripsIdentifiersFromLoggedPayloads() {
        // The previous implementation logged the full request body, putting the
        // IDFA into the device console.
        let redacted = LinkFlowRedaction.redact([
            "platform": "ios",
            "advertisingId": "AEBE52E7-03EE-455A-B3C4-E57283966239",
            "vendorId": "11111111-2222-3333-4444-555555555555",
            "clickToken": "tok123",
        ])

        XCTAssertEqual(redacted["platform"] as? String, "ios")
        XCTAssertEqual(redacted["advertisingId"] as? String, "«redacted»")
        XCTAssertEqual(redacted["vendorId"] as? String, "«redacted»")
        XCTAssertEqual(redacted["clickToken"] as? String, "«redacted»")
    }

    func testLeavesUnrelatedKeysAlone() {
        let redacted = LinkFlowRedaction.redact(["appVersion": "1.2.3"])
        XCTAssertEqual(redacted["appVersion"] as? String, "1.2.3")
    }
}

// MARK: - ObjC-facing surface

#if canImport(ObjectiveC)
final class LinkFlowSDKSurfaceTests: XCTestCase {

    override func tearDown() {
        LinkFlowSDK.resetForTesting()
        super.tearDown()
    }

    func testLegacyInitializerStillWorks() {
        // Source compatibility for existing 1.x integrations.
        let sdk = LinkFlowSDK.initialize(apiBaseURL: "https://test.thelinkflow.app", enableLogging: false)
        XCTAssertNotNil(sdk)
    }

    func testInitializeIsIdempotent() {
        let first = LinkFlowSDK.initialize(config: LinkFlowConfig())
        let second = LinkFlowSDK.initialize(config: LinkFlowConfig())
        XCTAssertTrue(first === second)
    }

    func testSharedThrowsBeforeInitialization() {
        LinkFlowSDK.resetForTesting()
        XCTAssertThrowsError(try LinkFlowSDK.shared())
    }

    func testAttributionResultReportsMissingConfidenceAsNegativeOne() {
        // Double? is not representable in Objective-C, so absence is -1.
        let result = AttributionResult(attributed: false)
        XCTAssertEqual(result.confidence, -1)
    }

    func testAttributionResultCarriesEngineMetadata() {
        let result = AttributionResult(parsed: ParsedAttribution(json: [
            "attributed": true,
            "attributionMethod": "fingerprint",
            "confidence": 0.78,
            "isReinstall": true,
        ]))

        XCTAssertTrue(result.attributed)
        XCTAssertEqual(result.attributionMethod, "fingerprint")
        XCTAssertEqual(result.confidence, 0.78)
        XCTAssertTrue(result.isReinstall)
    }
}
#endif
