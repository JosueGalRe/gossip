import XCTest
@testable import Gossip

final class TailnetAddressesTests: XCTestCase {
    func testAcceptsTailscalesRange() {
        XCTAssertTrue(TailnetAddresses.isTailnet("100.64.0.1"))
        XCTAssertTrue(TailnetAddresses.isTailnet("100.102.56.78"))
        XCTAssertTrue(TailnetAddresses.isTailnet("100.127.255.255"))
    }

    func testRefusesEverythingElse() {
        XCTAssertFalse(TailnetAddresses.isTailnet("100.63.255.255"))
        XCTAssertFalse(TailnetAddresses.isTailnet("100.128.0.1"))
        XCTAssertFalse(TailnetAddresses.isTailnet("192.168.1.12"))
        XCTAssertFalse(TailnetAddresses.isTailnet("100.64.0"))
        XCTAssertFalse(TailnetAddresses.isTailnet("100.64..1"))
        XCTAssertFalse(TailnetAddresses.isTailnet("evil.example.com"))
    }
}
