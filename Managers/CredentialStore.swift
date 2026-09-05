import Foundation

/// Abstracts `KeychainManager`'s statics so the socket and the view models can be
/// tested with an in-memory store. Reference type on purpose: one instance is
/// shared between a socket and the view model that owns it.
protocol CredentialStore: AnyObject {
    var token: String? { get set }
    var deviceId: String? { get set }
    var deviceName: String? { get set }
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
