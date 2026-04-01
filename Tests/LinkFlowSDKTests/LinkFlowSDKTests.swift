import XCTest
@testable import LinkFlowSDK

final class LinkFlowSDKTests: XCTestCase {
    func testSDKInitialization() {
        // Initialize SDK and verify it returns a valid instance
        let sdk = LinkFlowSDK.initialize(
            apiBaseURL: "https://test.linkflow.io",
            enableLogging: false
        )
        XCTAssertNotNil(sdk)
    }
}
