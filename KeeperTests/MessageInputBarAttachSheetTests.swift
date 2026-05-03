import XCTest
import SwiftUI
@testable import Keepur

final class MessageInputBarAttachSheetTests: XCTestCase {
    /// Builds the same KeepurActionSheet that MessageInputBar wires up
    /// when the user taps the `+` button. Test-only mirror of the
    /// production construction so we can assert shape and per-action
    /// dispatch without instantiating MessageInputBar.body (which
    /// requires a SpeechManager).
    private func makeAttachSheet(
        onChooseFile: @escaping () -> Void = {},
        onPhotoLibrary: @escaping () -> Void = {},
        onTakePhoto: @escaping () -> Void = {}
    ) -> KeepurActionSheet {
        KeepurActionSheet(
            title: "Attach",
            subtitle: "Add a file or photo to the message.",
            actions: [
                .init(symbol: "doc",    title: "Choose file",   subtitle: "Browse documents on this device", action: onChooseFile),
                .init(symbol: "photo",  title: "Photo library", subtitle: "Pick from your photos",          action: onPhotoLibrary),
                .init(symbol: "camera", title: "Take photo",    subtitle: "Use the camera now",              action: onTakePhoto),
            ]
        )
    }

    func testAttachSheetTitleAndSubtitle() {
        let sheet = makeAttachSheet()
        XCTAssertEqual(sheet.title, "Attach")
        XCTAssertEqual(sheet.subtitle, "Add a file or photo to the message.")
    }

    func testAttachSheetHasThreeActionsInOrder() {
        let sheet = makeAttachSheet()
        XCTAssertEqual(sheet.actions.count, 3)
        XCTAssertEqual(sheet.actions.map(\.title),    ["Choose file", "Photo library", "Take photo"])
        XCTAssertEqual(sheet.actions.map(\.symbol),   ["doc",          "photo",         "camera"])
        XCTAssertEqual(sheet.actions.map { $0.subtitle ?? "" }, [
            "Browse documents on this device",
            "Pick from your photos",
            "Use the camera now",
        ])
    }

    func testAttachSheetActionClosuresFire() {
        var fileFired = false
        var photoFired = false
        var cameraFired = false
        let sheet = makeAttachSheet(
            onChooseFile:   { fileFired   = true },
            onPhotoLibrary: { photoFired  = true },
            onTakePhoto:    { cameraFired = true }
        )
        sheet.actions[0].action()
        sheet.actions[1].action()
        sheet.actions[2].action()
        XCTAssertTrue(fileFired)
        XCTAssertTrue(photoFired)
        XCTAssertTrue(cameraFired)
    }

    func testAttachSheetBodyConstructs() {
        let sheet = makeAttachSheet()
        _ = sheet.body
    }
}
