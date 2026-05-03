import XCTest
import SwiftUI
@testable import Keepur

final class KeepurFoundationCompositesTests: XCTestCase {
    func testChatHeaderInstantiates() {
        let cases: [KeepurChatHeader] = [
            KeepurChatHeader(title: "Chat"),
            KeepurChatHeader(title: "hive-dodi", onBack: {}),
            KeepurChatHeader(title: "T", statusText: "working", isStatusActive: true),
            KeepurChatHeader(title: "T", statusDate: .now),
            KeepurChatHeader(
                title: "Long title that should truncate cleanly at the tail end",
                statusText: "working",
                statusDate: .now,
                isStatusActive: true,
                onBack: {},
                trailingActions: [
                    .init(symbol: "speaker.wave.2", action: {}),
                    .init(symbol: "info.circle",    action: {}),
                    .init(symbol: "ellipsis",       action: {}),
                ]
            ),
        ]
        for header in cases {
            _ = header.body
        }
    }

    func testActionSheetInstantiates() {
        let cases: [KeepurActionSheet] = [
            KeepurActionSheet(title: "Empty", actions: []),
            KeepurActionSheet(
                title: "One",
                actions: [.init(symbol: "doc", title: "Choose file", action: {})]
            ),
            KeepurActionSheet(
                title: "Attach",
                subtitle: "Add a file or photo to the message.",
                actions: [
                    .init(symbol: "doc",    title: "Choose file",   subtitle: "Browse documents on this device", action: {}),
                    .init(symbol: "photo",  title: "Photo library", subtitle: "Pick from your photos",          action: {}),
                    .init(symbol: "camera", title: "Take photo",    subtitle: "Use the camera now",              action: {}),
                ]
            ),
            KeepurActionSheet(
                title: String(repeating: "Long title ", count: 8),
                subtitle: String(repeating: "Long subtitle ", count: 6),
                actions: [.init(symbol: "doc", title: "Pick", subtitle: "x", action: {})]
            ),
        ]
        for sheet in cases {
            _ = sheet.body
        }
    }
}
