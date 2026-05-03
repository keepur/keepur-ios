import XCTest
import SwiftUI
@testable import Keepur

final class SavedWorkspacesPlaceholderViewTests: XCTestCase {
    func testPlaceholderInstantiates() {
        let view = SavedWorkspacesPlaceholderView()
        _ = view.body
    }
}
