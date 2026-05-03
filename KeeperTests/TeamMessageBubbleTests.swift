import XCTest
import SwiftUI
@testable import Keepur

final class TeamMessageBubbleTests: XCTestCase {
    private func makeMessage(
        senderId: String = "agent-1",
        senderType: String = "agent",
        senderName: String = "claude-bot",
        pending: Bool = false
    ) -> TeamMessage {
        TeamMessage(
            channelId: "c1",
            senderId: senderId,
            senderType: senderType,
            senderName: senderName,
            text: "hello",
            pending: pending
        )
    }

    func testSystemBubbleInstantiates() {
        let msg = makeMessage(senderId: "system", senderType: "system", senderName: "system")
        let bubble = TeamMessageBubble(message: msg, isOwnMessage: false)
        _ = bubble.body
    }

    func testUserBubbleInstantiates() {
        let msg = makeMessage(senderId: "device-self", senderType: "person", senderName: "me")
        _ = TeamMessageBubble(message: msg, isOwnMessage: true).body

        let pending = makeMessage(senderId: "device-self", senderType: "person", senderName: "me", pending: true)
        _ = TeamMessageBubble(message: pending, isOwnMessage: true).body
    }

    func testAgentBubbleInstantiates() {
        let msg = makeMessage()
        _ = TeamMessageBubble(message: msg, isOwnMessage: false, onSpeak: { _ in }).body

        _ = TeamMessageBubble(message: msg, isOwnMessage: false).body

        let nameless = makeMessage(senderName: "")
        _ = TeamMessageBubble(message: nameless, isOwnMessage: false).body
    }
}
