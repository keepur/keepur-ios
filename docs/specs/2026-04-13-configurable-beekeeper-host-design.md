# Configurable Beekeeper Host

**Date:** 2026-04-13
**Status:** Draft
**Author:** brainstorm session

## Problem

The Beekeeper host `beekeeper.dodihome.com` is hardcoded in three places with inconsistent schemes:

- `Managers/WebSocketManager.swift:21` — `ws://beekeeper.dodihome.com`
- `Managers/APIManager.swift:4` — `http://beekeeper.dodihome.com`
- `Managers/TeamWebSocketManager.swift:22` — `wss://beekeeper.dodihome.com`

This blocks the commercial rollout: every customer who installs their own Beekeeper instance needs to point the Keepur iOS/macOS client at their own host. There is no way to do that today without rebuilding the app.

## Goals

- End users can enter their own Beekeeper host during first-run pairing.
- Host is persisted and used by all network layers (REST, chat WebSocket, team WebSocket).
- TLS is required for every user-configured host — no cleartext fallback.
- The iOS spec is independent of which server-side TLS strategy (Cloudflare Tunnel, native TLS, Tailscale) the installer chooses; all three expose a TLS hostname to the client.

## Non-Goals

- Settings UI to edit the host after pairing. To change hosts, user unpairs and re-pairs.
- Multi-host history or host switching within a single install.
- Cleartext (`ws://`/`http://`) support for LAN or dev hosts.
- Server-side TLS provisioning. Beekeeper currently serves plain HTTP behind a Cloudflare Tunnel; that decision lives in the server-side installer spec.

## Design

### Storage

- Key: `beekeeperHost` in `UserDefaults.standard`
- Value: normalized `host[:port]` string (e.g. `shop.dodihome.com` or `bee.example.com:8443`)
- Cleared alongside the token on unpair/logout so the next pairing starts from a fresh host entry.

Rationale: the host is not secret, and keeping it in `UserDefaults` avoids cluttering the Keychain. Clearing both in the same code path keeps token and host lifetimes coupled.

### Config Layer

New file: `Managers/BeekeeperConfig.swift`

```swift
enum BeekeeperConfigError: Error { case hostNotConfigured }

enum BeekeeperConfig {
    static var host: String? { get set }                 // UserDefaults-backed
    static func httpsURL() throws -> URL                 // https://<host>
    static func wssURL() throws -> URL                   // wss://<host>
    static func validate(_ input: String) -> String?     // returns normalized host[:port] or nil
}
```

Validation rules for `validate`:

- Trim whitespace, lowercase.
- Reject if empty, contains a scheme (`://`), contains a path (`/`), or contains whitespace.
- Match `^[a-z0-9.-]+(:[0-9]{1,5})?$`.
- If a port is present, parse it and require `1...65535`. The regex alone accepts `00000`/`99999`, so the numeric range check is a separate step.
- Return the normalized string on success, `nil` on failure.

`httpsURL` and `wssURL` throw `BeekeeperConfigError.hostNotConfigured` if `host` is nil — callers that reach the network without a configured host are a programming error, and the error should be loud.

### Manager Updates

| File | Change |
|------|--------|
| `Managers/WebSocketManager.swift` | Replace `private let baseURL = "ws://beekeeper.dodihome.com"` with `BeekeeperConfig.wssURL`. Scheme changes from `ws` to `wss`. |
| `Managers/TeamWebSocketManager.swift` | Replace `private let baseURL = "wss://beekeeper.dodihome.com"` with `BeekeeperConfig.wssURL`. Scheme unchanged; host becomes dynamic. |
| `Managers/APIManager.swift` | Replace `private static let baseURL = "http://beekeeper.dodihome.com"` with `BeekeeperConfig.httpsURL`. Scheme changes from `http` to `https`. |

Any query-string or path assembly that currently concatenates against `baseURL` must use the resolved `URL` from `BeekeeperConfig` instead.

### Info.plist

Remove the `NSAppTransportSecurity.NSExceptionDomains.beekeeper.dodihome.com` entry entirely. With TLS-only hosts there is no need for an ATS exception. This also removes the temptation to grandfather cleartext later.

### PairingView — New Step 0

Add a host entry step before the existing code entry.

- **Step 0 (new):** Host field. Continue button enabled only when `BeekeeperConfig.validate` returns non-nil. On Continue, persist the normalized host to `BeekeeperConfig.host` and advance to step 1.
- **Step 1 (existing):** Six-digit code. Back button returns to step 0.
- **Step 2 (existing):** Device name. Back button returns to step 1.

Copy for step 0: heading "Enter your Beekeeper host", placeholder `beekeeper.example.com`, helper text "Your administrator will give you this address."

Field configuration (iOS): `.keyboardType(.URL)`, `.textInputAutocapitalization(.never)`, `.autocorrectionDisabled(true)`. Prevents iOS from capitalizing or autocorrecting hostnames.

Validation feedback is inline below the field — no alerts.

### Migration

Force re-pair on upgrade. On app launch, if `KeychainManager.token` is non-nil and `BeekeeperConfig.host` is nil, clear the token (and any paired device metadata) so `RootView` drops the user into `PairingView`. This check must run **before** any network manager (`WebSocketManager`, `TeamWebSocketManager`, `APIManager`) is allowed to connect, so a first-launch session cannot race the token-clear. No grandfather seeding — the existing `beekeeper.dodihome.com` host does not serve TLS and any seeded value would fail on first connection.

This affects a single existing install (the developer's own). The friction is acceptable and avoids carrying migration branches forever.

### Unpair / Logout

Wherever the token is cleared today, also clear `BeekeeperConfig.host`. This is the only post-pairing path that changes the host.

## Dependencies

- **Server-side TLS:** The user-entered host must serve `https://` and `wss://`. How the server achieves that — Cloudflare Tunnel, native Let's Encrypt, Tailscale MagicDNS — is out of scope for this spec and tracked separately in the installer design. This spec assumes TLS is already in place for any host a user would enter.

## Open Questions

None blocking. All forks above are decided.

## Files Touched

| File | Change |
|------|--------|
| `Managers/BeekeeperConfig.swift` | **New** — config enum, validation, URL builders |
| `Managers/WebSocketManager.swift` | Replace hardcoded baseURL |
| `Managers/TeamWebSocketManager.swift` | Replace hardcoded baseURL |
| `Managers/APIManager.swift` | Replace hardcoded baseURL |
| `Managers/KeychainManager.swift` | Clear host alongside token on unpair (if clearing lives here) |
| `Views/PairingView.swift` | Add step 0 host entry, renumber existing steps |
| `Views/RootView.swift` | Migration: force re-pair when token exists but host does not |
| `Info.plist` | Remove `beekeeper.dodihome.com` ATS exception |
| `KeeperTests/` | Unit tests for `BeekeeperConfig.validate` and URL builders |

## Test Plan

- `BeekeeperConfig.validate` accepts plain hostnames, hostnames with ports, rejects schemes, paths, whitespace, empty, and port > 65535.
- `httpsURL` / `wssURL` throw when host is nil, return correctly-schemed URLs otherwise.
- Pairing flow: step 0 → step 1 → step 2 → successful pair persists host and token; back navigation preserves entered host.
- Pairing flow: invalid host input disables Continue.
- Migration: launching with a token but no host clears token and shows pairing.
- Unpair clears both token and host.
