import XCTest
@testable import Keepur

final class WSMessageAttachmentTests: XCTestCase {

    // MARK: - Image message encoding

    func testImageMessageEncoding() throws {
        let data = try WSOutgoing.image(sessionId: "s1", data: "abc123==", filename: "photo.jpg").encode()
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["type"] as? String, "image")
        XCTAssertEqual(json["sessionId"] as? String, "s1")
        XCTAssertEqual(json["data"] as? String, "abc123==")
        XCTAssertEqual(json["filename"] as? String, "photo.jpg")
        XCTAssertNil(json["mimetype"], "image messages should not include mimetype")
    }

    // MARK: - File message encoding

    func testFileMessageEncoding() throws {
        let data = try WSOutgoing.file(sessionId: "s2", data: "AQID", filename: "report.pdf", mimetype: "application/pdf").encode()
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["type"] as? String, "file")
        XCTAssertEqual(json["sessionId"] as? String, "s2")
        XCTAssertEqual(json["data"] as? String, "AQID")
        XCTAssertEqual(json["filename"] as? String, "report.pdf")
        XCTAssertEqual(json["mimetype"] as? String, "application/pdf")
    }

    // MARK: - Plain message has no attachment fields

    func testPlainMessageHasNoAttachmentFields() throws {
        let data = try WSOutgoing.message(text: "Hello", sessionId: "s3").encode()
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["type"] as? String, "message")
        XCTAssertEqual(json["text"] as? String, "Hello")
        XCTAssertEqual(json["sessionId"] as? String, "s3")
        XCTAssertNil(json["data"])
        XCTAssertNil(json["filename"])
    }

    // MARK: - Large payload encoding

    func testImageWithLargeBase64Encodes() throws {
        let largeData = String(repeating: "A", count: 100_000)
        let data = try WSOutgoing.image(sessionId: "s4", data: largeData, filename: "big.png").encode()
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual((json["data"] as? String)?.count, 100_000)
    }
}
