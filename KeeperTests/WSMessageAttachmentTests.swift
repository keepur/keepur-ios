import XCTest
@testable import Keepur

final class WSMessageAttachmentTests: XCTestCase {

    // MARK: - Outgoing: message with attachment

    func testMessageWithAttachmentEncoding() throws {
        let attachment = MessageAttachment(name: "photo.jpg", mimeType: "image/jpeg", base64Data: "abc123==")
        let data = try WSOutgoing.message(text: "Check this out", sessionId: "s1", attachment: attachment).encode()
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["type"] as? String, "message")
        XCTAssertEqual(json["text"] as? String, "Check this out")
        XCTAssertEqual(json["sessionId"] as? String, "s1")

        let att = json["attachment"] as? [String: Any]
        XCTAssertNotNil(att)
        XCTAssertEqual(att?["name"] as? String, "photo.jpg")
        XCTAssertEqual(att?["mimeType"] as? String, "image/jpeg")
        XCTAssertEqual(att?["data"] as? String, "abc123==")
    }

    func testMessageWithoutAttachmentOmitsField() throws {
        let data = try WSOutgoing.message(text: "Hello", sessionId: "s2").encode()
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["type"] as? String, "message")
        XCTAssertEqual(json["text"] as? String, "Hello")
        XCTAssertEqual(json["sessionId"] as? String, "s2")
        XCTAssertNil(json["attachment"], "attachment should be omitted when nil")
    }

    func testMessageWithExplicitNilAttachment() throws {
        let data = try WSOutgoing.message(text: "Test", sessionId: "s3", attachment: nil).encode()
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertNil(json["attachment"], "explicit nil attachment should be omitted")
    }
}
