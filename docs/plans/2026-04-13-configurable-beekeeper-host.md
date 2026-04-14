# Configurable Beekeeper Host — Implementation Plan

> **For agentic workers:** Use `dodi-dev:implement` to execute this plan.

**Spec:** `docs/specs/2026-04-13-configurable-beekeeper-host-design.md`

**Goal:** Replace three hardcoded `beekeeper.dodihome.com` constants with a user-configurable, TLS-only host entered at a new Step 0 in `PairingView`.

**Architecture:** A new `BeekeeperConfig` enum centralizes host storage (UserDefaults) and URL construction. Three existing managers drop their hardcoded `baseURL` constants and call into `BeekeeperConfig` instead. `PairingView` gains a host-entry step. `KeepurApp.init()` runs a migration that forces re-pair for any legacy install whose token pre-dates host configuration.

**Tech Stack:** Swift 5, SwiftUI, Foundation, `UserDefaults.standard`, `URLSessionWebSocketTask`, `URLSession.shared`.

---

## File Structure

| File | Action | Responsibility |
|------|--------|---------------|
| `Managers/BeekeeperConfig.swift` | Create | Host storage, validation, `httpsURL`/`wssURL` builders, migration helper |
| `KeeperTests/BeekeeperConfigTests.swift` | Create | Unit tests for `validate`, URL builders, and migration |
| `Managers/WebSocketManager.swift` | Modify | Replace hardcoded `baseURL` with `BeekeeperConfig.wssURL` |
| `Managers/TeamWebSocketManager.swift` | Modify | Replace hardcoded `baseURL` with `BeekeeperConfig.wssURL` |
| `Managers/APIManager.swift` | Modify | Replace hardcoded `baseURL` with `BeekeeperConfig.httpsURL` |
| `Managers/KeychainManager.swift` | Modify | `clearAll()` also clears `BeekeeperConfig.host` |
| `KeepurApp.swift` | Modify | Call `BeekeeperConfig.migrateIfNeeded()` on launch |
| `Views/PairingView.swift` | Modify | Add Step 0 host entry; renumber existing steps to 1/2 |
| `Info.plist` | Modify | Remove `beekeeper.dodihome.com` ATS exception (keep `hive.dodihome.com`) |

---

## Task 1: BeekeeperConfig + Tests

**Files:**
- Create: `Managers/BeekeeperConfig.swift`
- Create: `KeeperTests/BeekeeperConfigTests.swift`

- [ ] **Step 1:** Create `Managers/BeekeeperConfig.swift` with the full contents below.

```swift
import Foundation

enum BeekeeperConfigError: Error {
    case hostNotConfigured
}

enum BeekeeperConfig {
    private static let hostKey = "beekeeperHost"
    private static let defaults: UserDefaults = .standard

    /// The configured Beekeeper host (e.g. "beekeeper.example.com" or "bee.example.com:8443").
    /// Always TLS-only — never contains a scheme or path.
    static var host: String? {
        get { defaults.string(forKey: hostKey) }
        set {
            if let newValue {
                defaults.set(newValue, forKey: hostKey)
            } else {
                defaults.removeObject(forKey: hostKey)
            }
        }
    }

    /// `https://<host>` — throws if no host is configured.
    static func httpsURL() throws -> URL {
        guard let host else { throw BeekeeperConfigError.hostNotConfigured }
        guard let url = URL(string: "https://\(host)") else {
            throw BeekeeperConfigError.hostNotConfigured
        }
        return url
    }

    /// `wss://<host>` — throws if no host is configured.
    static func wssURL() throws -> URL {
        guard let host else { throw BeekeeperConfigError.hostNotConfigured }
        guard let url = URL(string: "wss://\(host)") else {
            throw BeekeeperConfigError.hostNotConfigured
        }
        return url
    }

    /// Validate and normalize a user-entered host string.
    /// Returns the normalized `host[:port]` on success, `nil` on failure.
    static func validate(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        guard !trimmed.contains("://"),
              !trimmed.contains("/"),
              !trimmed.contains(" ") else { return nil }

        // Match host[:port] with an optional numeric port.
        let pattern = #"^[a-z0-9.-]+(:[0-9]{1,5})?$"#
        guard trimmed.range(of: pattern, options: .regularExpression) != nil else { return nil }

        // If a port is present, range-check it (regex alone accepts 0/99999).
        if let colonIndex = trimmed.firstIndex(of: ":") {
            let portString = trimmed[trimmed.index(after: colonIndex)...]
            guard let port = Int(portString), (1...65535).contains(port) else { return nil }
        }

        return trimmed
    }

    /// Force re-pair on upgrade: if a token exists but no host is configured,
    /// the legacy install pre-dates configurable hosts. Clear the token so
    /// `ContentView` drops the user into `PairingView`. Runs before any
    /// network manager is constructed, so first-launch races are impossible.
    static func migrateIfNeeded() {
        if KeychainManager.token != nil && host == nil {
            KeychainManager.clearAll()
        }
    }
}
```

- [ ] **Step 2:** Add the new file to the Xcode target. Open `Keepur.xcodeproj`, right-click the `Managers` group, "Add Files to Keepur...", select `BeekeeperConfig.swift`, ensure both `Keepur` and `Keepur (macOS)` targets are checked.

- [ ] **Step 3:** Create `KeeperTests/BeekeeperConfigTests.swift` with the full contents below.

```swift
import XCTest
@testable import Keepur

final class BeekeeperConfigTests: XCTestCase {
    override func setUp() {
        super.setUp()
        BeekeeperConfig.host = nil
    }

    override func tearDown() {
        BeekeeperConfig.host = nil
        super.tearDown()
    }

    // MARK: - validate

    func testValidateAcceptsPlainHostname() {
        XCTAssertEqual(BeekeeperConfig.validate("beekeeper.example.com"), "beekeeper.example.com")
    }

    func testValidateAcceptsHostnameWithPort() {
        XCTAssertEqual(BeekeeperConfig.validate("bee.example.com:8443"), "bee.example.com:8443")
    }

    func testValidateTrimsAndLowercases() {
        XCTAssertEqual(BeekeeperConfig.validate("  Bee.Example.COM  "), "bee.example.com")
    }

    func testValidateRejectsScheme() {
        XCTAssertNil(BeekeeperConfig.validate("https://beekeeper.example.com"))
        XCTAssertNil(BeekeeperConfig.validate("http://beekeeper.example.com"))
        XCTAssertNil(BeekeeperConfig.validate("wss://beekeeper.example.com"))
    }

    func testValidateRejectsPath() {
        XCTAssertNil(BeekeeperConfig.validate("beekeeper.example.com/pair"))
    }

    func testValidateRejectsWhitespace() {
        XCTAssertNil(BeekeeperConfig.validate("bee keeper.example.com"))
    }

    func testValidateRejectsEmpty() {
        XCTAssertNil(BeekeeperConfig.validate(""))
        XCTAssertNil(BeekeeperConfig.validate("   "))
    }

    func testValidateRejectsPortOutOfRange() {
        XCTAssertNil(BeekeeperConfig.validate("bee.example.com:0"))
        XCTAssertNil(BeekeeperConfig.validate("bee.example.com:65536"))
        XCTAssertNil(BeekeeperConfig.validate("bee.example.com:99999"))
    }

    func testValidateAcceptsPortBoundaries() {
        XCTAssertEqual(BeekeeperConfig.validate("bee.example.com:1"), "bee.example.com:1")
        XCTAssertEqual(BeekeeperConfig.validate("bee.example.com:65535"), "bee.example.com:65535")
    }

    // MARK: - URL builders

    func testHttpsURLThrowsWhenUnconfigured() {
        XCTAssertThrowsError(try BeekeeperConfig.httpsURL()) { error in
            XCTAssertEqual(error as? BeekeeperConfigError, .hostNotConfigured)
        }
    }

    func testWssURLThrowsWhenUnconfigured() {
        XCTAssertThrowsError(try BeekeeperConfig.wssURL()) { error in
            XCTAssertEqual(error as? BeekeeperConfigError, .hostNotConfigured)
        }
    }

    func testHttpsURLReturnsConfiguredHost() throws {
        BeekeeperConfig.host = "bee.example.com"
        XCTAssertEqual(try BeekeeperConfig.httpsURL().absoluteString, "https://bee.example.com")
    }

    func testWssURLReturnsConfiguredHost() throws {
        BeekeeperConfig.host = "bee.example.com:8443"
        XCTAssertEqual(try BeekeeperConfig.wssURL().absoluteString, "wss://bee.example.com:8443")
    }
}
```

- [ ] **Step 4:** Add the new test file to the `KeeperTests` target in Xcode.

- [ ] **Step 5:** Verify — run the new tests.

Run: `xcodebuild test -project Keepur.xcodeproj -scheme Keepur -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:KeeperTests/BeekeeperConfigTests`

Expected: All `BeekeeperConfigTests` cases pass. No compiler warnings in the new file.

- [ ] **Step 6:** Commit.

```bash
git add Managers/BeekeeperConfig.swift KeeperTests/BeekeeperConfigTests.swift Keepur.xcodeproj/project.pbxproj
git commit -m "feat(config): add BeekeeperConfig for user-configurable host"
```

---

## Task 2: Wire Managers to BeekeeperConfig

**Files:**
- Modify: `Managers/WebSocketManager.swift:21`, `:46`
- Modify: `Managers/TeamWebSocketManager.swift:22`, `:44`
- Modify: `Managers/APIManager.swift:4`, `:23`, `:49`
- Modify: `Info.plist:13-17`

- [ ] **Step 1:** Edit `Managers/WebSocketManager.swift`. Remove the `baseURL` property and switch URL construction to throw/guard on `BeekeeperConfig.wssURL()`.

Replace line 21:
```swift
    private let baseURL = "ws://beekeeper.dodihome.com"
```
with nothing (delete the line).

Replace line 46:
```swift
        let url = URL(string: "\(baseURL)?token=\(token)")!
```
with:
```swift
        guard let baseURL = try? BeekeeperConfig.wssURL(),
              let url = URL(string: "\(baseURL.absoluteString)?token=\(token)") else {
            handleDisconnect()
            return
        }
```

- [ ] **Step 2:** Edit `Managers/TeamWebSocketManager.swift`. Same pattern.

Delete line 22 (`private let baseURL = "wss://beekeeper.dodihome.com"`).

Replace line 44:
```swift
        let url = URL(string: "\(baseURL)/?token=\(token)&channel=team")!
```
with:
```swift
        guard let baseURL = try? BeekeeperConfig.wssURL(),
              let url = URL(string: "\(baseURL.absoluteString)/?token=\(token)&channel=team") else {
            isConnecting = false
            handleDisconnect()
            return
        }
```

- [ ] **Step 3:** Edit `Managers/APIManager.swift`. Switch `pair` and `fetchMe` to resolve `baseURL` at call time.

Delete line 4 (`private static let baseURL = "http://beekeeper.dodihome.com"`).

In `pair(code:name:)`, replace line 23:
```swift
        let url = URL(string: "\(baseURL)/pair")!
```
with:
```swift
        let baseURL = try BeekeeperConfig.httpsURL()
        let url = baseURL.appendingPathComponent("pair")
```

In `fetchMe()`, replace line 49:
```swift
        let url = URL(string: "\(baseURL)/me")!
```
with:
```swift
        let baseURL = try BeekeeperConfig.httpsURL()
        let url = baseURL.appendingPathComponent("me")
```

Note: `pair` is already `async throws`, so the added `try` propagates cleanly. `fetchMe` is also already `async throws`. No signature changes needed.

- [ ] **Step 4:** Edit `Info.plist`. Remove only the `beekeeper.dodihome.com` dictionary entry. Leave `hive.dodihome.com` intact (out of scope).

Before (lines 9–24):
```xml
	<key>NSAppTransportSecurity</key>
	<dict>
		<key>NSExceptionDomains</key>
		<dict>
			<key>beekeeper.dodihome.com</key>
			<dict>
				<key>NSExceptionAllowsInsecureHTTPLoads</key>
				<true/>
			</dict>
			<key>hive.dodihome.com</key>
			<dict>
				<key>NSExceptionAllowsInsecureHTTPLoads</key>
				<true/>
			</dict>
		</dict>
	</dict>
```

After:
```xml
	<key>NSAppTransportSecurity</key>
	<dict>
		<key>NSExceptionDomains</key>
		<dict>
			<key>hive.dodihome.com</key>
			<dict>
				<key>NSExceptionAllowsInsecureHTTPLoads</key>
				<true/>
			</dict>
		</dict>
	</dict>
```

- [ ] **Step 5:** Verify — the project builds.

Run: `xcodebuild build -project Keepur.xcodeproj -scheme Keepur -destination 'platform=iOS Simulator,name=iPhone 16'`

Expected: `BUILD SUCCEEDED`. No references to `ws://beekeeper.dodihome.com`, `wss://beekeeper.dodihome.com`, or `http://beekeeper.dodihome.com` remain in `Managers/*.swift`.

Sanity grep — expected to return zero hits:
Run via Grep tool: pattern `beekeeper\.dodihome\.com`, glob `Managers/**/*.swift`.

- [ ] **Step 6:** Commit.

```bash
git add Managers/WebSocketManager.swift Managers/TeamWebSocketManager.swift Managers/APIManager.swift Info.plist
git commit -m "feat(config): route all managers through BeekeeperConfig"
```

---

## Task 3: Migration + Keychain Cleanup

**Files:**
- Modify: `KeepurApp.swift:9`
- Modify: `Managers/KeychainManager.swift:81-86`

- [ ] **Step 1:** Edit `KeepurApp.swift`. Add the migration call immediately after `KeychainManager.migrateAccessibility()` so it runs before `ContentView` reads `KeychainManager.isPaired`.

Replace line 9:
```swift
        KeychainManager.migrateAccessibility()
```
with:
```swift
        KeychainManager.migrateAccessibility()
        BeekeeperConfig.migrateIfNeeded()
```

- [ ] **Step 2:** Edit `Managers/KeychainManager.swift`. Extend `clearAll()` to also clear the host so unpair/logout fully resets both secrets and configuration.

Replace lines 81–86:
```swift
    static func clearAll() {
        token = nil
        deviceId = nil
        deviceName = nil
        delete(key: capabilitiesKey)
    }
```
with:
```swift
    static func clearAll() {
        token = nil
        deviceId = nil
        deviceName = nil
        delete(key: capabilitiesKey)
        BeekeeperConfig.host = nil
    }
```

- [ ] **Step 3:** Verify — build succeeds and the existing test suite still passes.

Run: `xcodebuild test -project Keepur.xcodeproj -scheme Keepur -destination 'platform=iOS Simulator,name=iPhone 16'`

Expected: `TEST SUCCEEDED`. `KeychainTransientTests` still pass (they already call `clearAll` in setup/teardown; clearing `host = nil` is a no-op for those tests).

- [ ] **Step 4:** Commit.

```bash
git add KeepurApp.swift Managers/KeychainManager.swift
git commit -m "feat(config): migrate legacy installs and clear host on unpair"
```

---

## Task 4: PairingView Step 0 (Host Entry)

**Files:**
- Modify: `Views/PairingView.swift`

- [ ] **Step 1:** Edit `Views/PairingView.swift`. Renumber existing step values so code entry becomes step 1 and device name becomes step 2 (they are currently 1 and 2; the new host entry step becomes step 0). Add a new `hostEntryView` and `host` state.

Replace the `@State` block at lines 9–14:
```swift
    @State private var code = ""
    @State private var deviceName = ""
    @State private var step = 1
    @State private var isLoading = false
    @State private var errorMessage: String?
    @FocusState private var codeFieldFocused: Bool
```
with:
```swift
    @State private var host = BeekeeperConfig.host ?? ""
    @State private var code = ""
    @State private var deviceName = ""
    @State private var step = 0
    @State private var isLoading = false
    @State private var errorMessage: String?
    @FocusState private var codeFieldFocused: Bool
    @FocusState private var hostFieldFocused: Bool
```

- [ ] **Step 2:** Update the heading subtitle and the body switch to include step 0. Replace lines 26–37:

```swift
                Text(step == 1 ? "Enter the 6-digit pairing code from your admin dashboard" : "Name this device")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }

            if step == 1 {
                codeEntryView
            } else {
                nameEntryView
            }
```
with:
```swift
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }

            switch step {
            case 0: hostEntryView
            case 1: codeEntryView
            default: nameEntryView
            }
```

- [ ] **Step 3:** Add a computed `subtitle` and the new `hostEntryView` to the struct. Insert the following after the existing `body` computed property (just above the `// MARK: - Step 1: Code Entry` marker, around line 55):

```swift
    private var subtitle: String {
        switch step {
        case 0: return "Enter your Beekeeper host"
        case 1: return "Enter the 6-digit pairing code from your admin dashboard"
        default: return "Name this device"
        }
    }

    // MARK: - Step 0: Host Entry

    private var hostEntryView: some View {
        VStack(spacing: 16) {
            TextField("beekeeper.example.com", text: $host)
                .font(.title3)
                .multilineTextAlignment(.center)
                .textFieldStyle(.roundedBorder)
                #if os(iOS)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled(true)
                .focused($hostFieldFocused)
                .padding(.horizontal, 40)
                .onSubmit(continueFromHost)

            Text("Your administrator will give you this address.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Button("Continue", action: continueFromHost)
                .buttonStyle(.borderedProminent)
                .disabled(BeekeeperConfig.validate(host) == nil)
        }
        .onAppear { hostFieldFocused = true }
    }

    private func continueFromHost() {
        guard let normalized = BeekeeperConfig.validate(host) else {
            errorMessage = "Enter a valid hostname (e.g. beekeeper.example.com)"
            return
        }
        BeekeeperConfig.host = normalized
        host = normalized
        errorMessage = nil
        step = 1
        codeFieldFocused = true
    }
```

- [ ] **Step 4:** Update the existing "Back" button in `nameEntryView` (currently line 106–110) — its behavior is fine (returns to step 1). Also add a Back button flow from step 1 to step 0.

In `codeEntryView`, after the existing contents, add a back affordance. Locate the `VStack(spacing: 16)` at line 58 and append a Back button after the hidden `TextField` (which ends at line 78). Replace the trailing `}` of `codeEntryView`'s outer `VStack` (closing at line 79) to include:

```swift
            Button("Back") {
                code = ""
                errorMessage = nil
                step = 0
                hostFieldFocused = true
            }
            .font(.footnote)
```

So the final `codeEntryView` reads:
```swift
    private var codeEntryView: some View {
        VStack(spacing: 16) {
            HStack(spacing: 8) {
                ForEach(0..<6, id: \.self) { index in
                    digitBox(at: index)
                }
            }
            .padding(.horizontal, 40)

            TextField("", text: $code)
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
                .focused($codeFieldFocused)
                .opacity(0)
                .frame(height: 1)
                .onChange(of: code) {
                    code = String(code.filter(\.isNumber).prefix(6))
                    if code.count == 6 {
                        step = 2
                    }
                }

            Button("Back") {
                code = ""
                errorMessage = nil
                step = 0
                hostFieldFocused = true
            }
            .font(.footnote)
        }
        .onAppear { codeFieldFocused = true }
    }
```

- [ ] **Step 5:** Verify — build, run, and manually test the flow on a simulator.

Build:
Run: `xcodebuild build -project Keepur.xcodeproj -scheme Keepur -destination 'platform=iOS Simulator,name=iPhone 16'`
Expected: `BUILD SUCCEEDED`.

Manual check (simulator):
1. Delete the app from the simulator first (or call `BeekeeperConfig.host = nil` + `KeychainManager.clearAll()` in a debug helper) to simulate a fresh install.
2. Launch the app → should land on step 0 with host field focused.
3. Type an invalid value like `https://foo` → Continue button stays disabled.
4. Type `beekeeper.example.com` → Continue enables → tap it → advances to step 1 (code entry).
5. Tap Back → returns to step 0 with the host still populated.
6. Re-enter the code → advances to step 2 (device name) — unchanged existing flow.
7. Tap Back from step 2 → returns to step 1.

Note: actual pairing against a real host requires a Beekeeper instance that serves TLS — without one, the `pair()` call will fail at the network layer, which is expected. The UI flow is what's being verified here.

- [ ] **Step 6:** Commit.

```bash
git add Views/PairingView.swift
git commit -m "feat(pairing): add host entry as step 0"
```

---

## Task 5: Quality Gate

- [ ] **Step 1:** Run the full quality gate.

Run: `/quality-gate`

Expected: Swift compliance passes, new/changed files have test coverage where meaningful, full suite passes. Fix anything the gate surfaces and re-run until clean.

- [ ] **Step 2:** Final sanity grep — confirm no hardcoded host remains in source (docs may still reference it, which is fine).

Run via Grep tool: pattern `beekeeper\.dodihome\.com`, glob `**/*.{swift,plist}`.
Expected: zero hits.

- [ ] **Step 3:** No separate commit — the gate commits any generated tests on its own path.

---

## Notes for Implementer

- Don't touch `hive.dodihome.com` anywhere — it's a separate concern tracked elsewhere.
- `Info.plist` may be generated by Xcode build settings in some targets; if the file doesn't drive the macOS target, verify the macOS build also no longer carries the beekeeper ATS exception via `Keepur.xcodeproj/project.pbxproj` build settings.
- The `try?` usage in `WebSocketManager.connect()` and `TeamWebSocketManager.connect()` silently triggers `handleDisconnect()` when host is unconfigured. That's intentional — the only path where host is nil *and* these managers are connecting is a programming error (migration should have forced re-pair first), but failing loud would crash the app. Reconnect-backoff then retries harmlessly; `ContentView`'s `isPaired` gate prevents user-visible oscillation.
- The spec's "force re-pair" migration runs via `clearAll()` which also clears host — since host is already nil in the legacy case, this is a no-op, but the code path is safe.
