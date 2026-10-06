import XCTest
@testable import OpenWeightsCore

final class HubIdentityTests: XCTestCase {
    func testIdentityAcceptsBoundedAccountAndRejectsCredentials() throws {
        let response = HubAPIResponse(status: 200, data: Data(#"{"name":"fixture-account"}"#.utf8))
        XCTAssertEqual(try HubIdentity.account(response), "fixture-account")
        for status in [401,403] {
            XCTAssertThrowsError(try HubIdentity.account(HubAPIResponse(status: status, data: Data()))) {
                XCTAssertEqual($0 as? HubIdentityFailure, .rejected)
            }
        }
    }
    func testIdentityNetworkStatusesAndInvalidPayloadAreUnavailable() {
        for status in [429,500,302] {
            XCTAssertThrowsError(try HubIdentity.account(HubAPIResponse(status: status, data: Data()))) {
                XCTAssertEqual($0 as? HubIdentityFailure, .unavailable)
            }
        }
        for payload in [#"{}"#,#"{"name":""}"#,#"{"name":"bad\nname"}"#, "{\"name\":\"" + String(repeating: "a",count:129) + "\"}","not-json"] {
            XCTAssertThrowsError(try HubIdentity.account(HubAPIResponse(status: 200, data: Data(payload.utf8)))) {
                XCTAssertEqual($0 as? HubIdentityFailure, .unavailable)
            }
        }
    }
    func testCredentialTrimsAndRejectsHeaderInjection() throws {
        XCTAssertEqual(try HubIdentity.credential("  fixture-value\n"), "fixture-value")
        for value in ["", " \n", "embedded space", "a\r\nb", "a\u{0}b", "é"] { XCTAssertThrowsError(try HubIdentity.credential(value)) }
    }
    func testEngineFeaturePresentationKeepsEnabledFlagsAndReportedBackends() {
        let info = EngineFeatures(info:"CPU : NEON = 1 | SVE = 0 | METAL = 1 | unrelated | backends: CPU Metal BLAS")
        XCTAssertEqual(info.backends,["CPU","Metal","BLAS"]); XCTAssertEqual(info.enabled,["NEON","METAL"])
        XCTAssertEqual(EngineFeatures(info:""),EngineFeatures(info:"unknown"))
        XCTAssertTrue(EngineFeatures(info:"backends:").backends.isEmpty)
        XCTAssertEqual(EngineFeatures(info:"backends: MTL CPU").backends,["MTL","CPU"])
    }
}
