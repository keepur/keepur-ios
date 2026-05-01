import XCTest
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
@testable import Keepur

final class KeepurThemeFontsTests: XCTestCase {

    /// Confirms the JetBrains Mono weights referenced by KeepurTheme.FontName
    /// are both bundled and registered. Catches:
    /// - .ttf removed from Copy Bundle Resources (Bundle.main.url assert)
    /// - Wrong PostScript name / missing UIAppFonts entry / shadowed by a
    ///   system-installed JetBrains Mono on dev machines (UIFont/NSFont assert)
    func testJetBrainsMonoFontsRegister() {
        let weights: [(name: String, file: String)] = [
            (KeepurTheme.FontName.mono,       "JetBrainsMono-Regular"),
            (KeepurTheme.FontName.monoMedium, "JetBrainsMono-Medium"),
            (KeepurTheme.FontName.monoBold,   "JetBrainsMono-SemiBold"),
        ]
        for (name, file) in weights {
            XCTAssertNotNil(
                Bundle.main.url(forResource: file, withExtension: "ttf"),
                "\(file).ttf missing from bundle"
            )
            #if canImport(UIKit)
            XCTAssertNotNil(UIFont(name: name, size: 14),
                            "Font \(name) failed to register")
            #else
            XCTAssertNotNil(NSFont(name: name, size: 14),
                            "Font \(name) failed to register")
            #endif
        }
    }
}
