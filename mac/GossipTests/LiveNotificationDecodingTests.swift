import XCTest
@testable import Gossip

/// This fork's phones add `category`, `countDown` and `promoted` to upstream's `live`; the Droppy bridge forwards them.
final class LiveNotificationDecodingTests: XCTestCase {
    private func decode(_ live: String) throws -> NotificationLive? {
        let json = #"{"id":"k","appPackage":"p","appName":"A","title":"t","body":"b","hasReplyAction":false,"timestamp":1,"live":\#(live)}"#
        return try JSONDecoder().decode(NotificationPostedPayload.self, from: Data(json.utf8)).live
    }

    func testForkExtrasDecode() throws {
        let live = try decode(#"{"kind":"timer","chronometerBase":5,"category":"alarm","countDown":true,"promoted":true}"#)
        XCTAssertEqual(live?.kind, "timer")
        XCTAssertEqual(live?.chronometerBase, 5)
        XCTAssertEqual(live?.category, "alarm")
        XCTAssertEqual(live?.countDown, true)
        XCTAssertEqual(live?.promoted, true)
    }

    func testUpstreamShapeDecodesWithoutExtras() throws {
        let live = try decode(#"{"kind":"progress","progress":3,"max":10}"#)
        XCTAssertEqual(live?.max, 10)
        XCTAssertNil(live?.category)
        XCTAssertNil(live?.promoted)
    }
}
