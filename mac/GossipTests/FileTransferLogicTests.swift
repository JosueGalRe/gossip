import XCTest
@testable import Gossip

final class FileTransferLogicTests: XCTestCase {
    func testSanitizedNameDropsPathsControlCharactersAndLeadingDots() {
        XCTAssertEqual(FileTransferLogic.sanitizedName("../../etc/passwd"), "etcpasswd")
        XCTAssertEqual(FileTransferLogic.sanitizedName("a\\b:c\u{0}d.txt"), "abcd.txt")
        XCTAssertEqual(FileTransferLogic.sanitizedName("...hidden"), "hidden")
        XCTAssertEqual(FileTransferLogic.sanitizedName("  "), "file")
        XCTAssertEqual(FileTransferLogic.sanitizedName(String(repeating: "x", count: 300)).count, 200)
    }

    func testUniqueNameNumbersBeforeTheExtension() {
        let taken: Set = ["photo.jpg", "photo (2).jpg", "notes"]
        XCTAssertEqual(FileTransferLogic.uniqueName("photo.jpg") { taken.contains($0) }, "photo (3).jpg")
        XCTAssertEqual(FileTransferLogic.uniqueName("notes") { taken.contains($0) }, "notes (2)")
        XCTAssertEqual(FileTransferLogic.uniqueName("new.pdf") { taken.contains($0) }, "new.pdf")
    }

    func testReceiverWritesOnlyTheNextSlice() {
        XCTAssertEqual(FileTransferLogic.decide(offset: 0, length: 10, received: 0, size: 20), .write)
        XCTAssertEqual(FileTransferLogic.decide(offset: 0, length: 10, received: 10, size: 20), .ignore)
        XCTAssertEqual(FileTransferLogic.decide(offset: 15, length: 5, received: 10, size: 20), .ignore)
        XCTAssertEqual(FileTransferLogic.decide(offset: 10, length: 11, received: 10, size: 20), .reject)
    }

    func testSenderKeepsAtMostTheWindowInFlight() {
        var sending = FileTransferLogic.Sending(size: 10 << 20)
        sending.accept(offset: 0)
        var offsets: [Int64] = []
        while let chunk = sending.nextChunk {
            offsets.append(chunk.offset)
            sending.sent(chunk.length)
        }
        XCTAssertEqual(offsets, [0, 1 << 20, 2 << 20, 3 << 20])
        XCTAssertTrue(sending.ack(received: 1 << 20))
        XCTAssertEqual(sending.nextChunk?.offset, 4 << 20)
    }

    func testSenderResumesFromTheAcceptedOffsetAndIgnoresStaleAcks() {
        var sending = FileTransferLogic.Sending(size: 3 << 20)
        sending.accept(offset: 0)
        while let chunk = sending.nextChunk { sending.sent(chunk.length) }
        XCTAssertTrue(sending.ack(received: 2 << 20))
        XCTAssertFalse(sending.ack(received: 1 << 20))
        // A reconnect lost the last slice: the receiver says where it is.
        sending.accept(offset: 2 << 20)
        XCTAssertEqual(sending.nextChunk?.offset, 2 << 20)
        XCTAssertEqual(sending.nextChunk?.length, 1 << 20)
        sending.sent(1 << 20)
        XCTAssertTrue(sending.ack(received: 3 << 20))
        XCTAssertTrue(sending.isComplete)
        XCTAssertNil(sending.nextChunk)
    }

    func testEmptyFileIsCompleteOnceAccepted() {
        var sending = FileTransferLogic.Sending(size: 0)
        sending.accept(offset: 0)
        XCTAssertNil(sending.nextChunk)
        XCTAssertTrue(sending.isComplete)
    }
}
