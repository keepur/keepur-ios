import Foundation

/// Abstracts `KeychainManager`'s statics so the socket and the view models can be
/// tested with an in-memory store. Reference type on purpose: one instance is
/// shared between a socket and the view model that owns it.
///
/// Read-only by design: nothing writes through this protocol today — pairing
/// writes `KeychainManager`'s statics directly, and tests mutate the concrete
/// `FakeCredentialStore`. The concrete conformers (`KeychainCredentialStore`,
/// `FakeCredentialStore`) keep settable properties for those call sites.
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

    var token: String? {
        get { KeychainManager.token }
        set { KeychainManager.token = newValue }
    }

    var deviceId: String? {
        get { KeychainManager.deviceId }
        set { KeychainManager.deviceId = newValue }
    }

    var deviceName: String? {
        get { KeychainManager.deviceName }
        set { KeychainManager.deviceName = newValue }
    }

    var isPaired: Bool { KeychainManager.isPaired }

    func clearAll() { KeychainManager.clearAll() }
}
