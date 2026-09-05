import Foundation
@testable import Keepur

/// `CredentialStore` is @MainActor (app-target default isolation); the conformer
/// inherits it. Only constructed from @MainActor test classes.
@MainActor
final class FakeCredentialStore: CredentialStore {
    var token: String?
    var deviceId: String?
    var deviceName: String?
    private(set) var clearAllCalls = 0

    init(token: String? = "test-token", deviceId: String? = "device-1", deviceName: String? = "Test Device") {
        self.token = token
        self.deviceId = deviceId
        self.deviceName = deviceName
    }

    var isPaired: Bool { token != nil }

    func clearAll() {
        clearAllCalls += 1
        token = nil
        deviceId = nil
        deviceName = nil
    }
}
