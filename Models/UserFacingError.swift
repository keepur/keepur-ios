import Foundation

/// A toast-style message for the connection banner. `Identifiable` so the
/// auto-clear timer can tell "still the same error" from a newer one.
struct UserFacingError: Identifiable, Equatable {
    let id = UUID()
    let text: String

    init(_ text: String) {
        self.text = text
    }
}
