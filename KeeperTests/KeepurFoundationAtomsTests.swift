import XCTest
import SwiftUI
@testable import Keepur

final class KeepurFoundationAtomsTests: XCTestCase {
    func testAvatarInstantiates() {
        let cases: [KeepurAvatar] = [
            KeepurAvatar(content: .letter("M")),
            KeepurAvatar(size: 24, content: .letter("Bob"), statusOverlay: .success),
            KeepurAvatar(size: 60, content: .emoji("🤖"), statusOverlay: .warning),
            KeepurAvatar(content: .letter("")),
        ]
        for avatar in cases {
            _ = avatar.body
        }
    }

    func testStatusPillRendersAllTints() {
        let tints: [KeepurStatusPill.Tint] = [.success, .warning, .danger, .honey, .muted]
        for tint in tints {
            _ = KeepurStatusPill("Active", tint: tint).body
        }
    }

    func testUnreadBadgeOverflowAndNullState() {
        for count in [-1, 0, 1, 9, 10, 100] {
            _ = KeepurUnreadBadge(count: count).body
        }
    }
}
