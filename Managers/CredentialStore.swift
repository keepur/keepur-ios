import Foundation

/// Abstracts `KeychainManager`'s statics so the socket and the view models can be
/// tested with an in-memory store. Reference type on purpose: one instance is
/// shared between a socket and the view model that owns it.
///
/// Read-only by design: nothing writes through this protocol today — pairing
/// writes `KeychainManager`'s statics directly. Only the test fake
/// (`FakeCredentialStore`) is mutable; the concrete production conformer
/// (`KeychainCredentialStore`) exposes these as read-only computed properties.
protocol CredentialStore: AnyObject {
    var token: String? { get }
    var deviceId: String? { get }
    var deviceName: String? { get }
    var isPaired: Bool { get }
    func clearAll()
}

/// Production store. Stateless; every access hits the Keychain through `KeychainManager`.
final class KeychainCredentialStore: CredentialStore {
    init() {}

    var token: String? { KeychainManager.token }

    var deviceId: String? { KeychainManager.deviceId }

    var deviceName: String? { KeychainManager.deviceName }

    var isPaired: Bool { KeychainManager.isPaired }

    func clearAll() { KeychainManager.clearAll() }
}
