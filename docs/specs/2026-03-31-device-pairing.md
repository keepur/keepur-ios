# Keepur iOS — Device Pairing

**Date**: 2026-03-31
**Status**: Draft
**Server issue**: bot-dodi/hive#63
**Reference implementation**: dodi-shop-ios

## Problem

Keepur authenticates with a static token pasted into a text field. The server (beekeeper) is moving to device pairing with 90-day JWTs (bot-dodi/hive#63). The iOS app needs to support the new pairing flow and handle token lifecycle (expiry warnings, re-pairing on revocation).

## Server Protocol

Beekeeper exposes HTTP endpoints on the same port (3099) as the WebSocket:

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| `POST` | `/pair` | None | Exchange 6-digit code for JWT. Body: `{ "code": "123456", "userName": "My iPad" }`. Returns `{ "token": "...", "deviceId": "...", "deviceName": "..." }` |
| `GET` | `/me` | Bearer JWT | Get own device info. Returns `{ "name": "..." }`. 401 if token expired/revoked. |
| `PUT` | `/me` | Bearer JWT | Update device name. Body: `{ "name": "..." }` |

Note: `/pair` uses `userName` in the request body (matching dodi-shop-ios convention). The response uses `deviceName`. `/me` returns `name`.

WebSocket auth is unchanged: `ws://beekeeper.dodihome.com?token=<JWT>`.

JWT lifetime: 90 days. Pairing code lifetime: 10 minutes, single-use.

## ATS (App Transport Security)

Beekeeper uses cleartext `http://` and `ws://`. iOS blocks cleartext HTTP by default (ATS). This project uses `GENERATE_INFOPLIST_FILE = YES` — there is no physical `Info.plist` file. Configure the ATS exception via Xcode build settings:

In `Keepur.xcodeproj/project.pbxproj`, add to the build settings for both Debug and Release configurations:

```
INFOPLIST_KEY_NSAppTransportSecurity_NSExceptionDomains_beekeeper.dodihome.com_NSExceptionAllowsInsecureHTTPLoads = YES;
```

If this build-setting key approach is not supported by the Xcode version in use, the fallback is to disable `GENERATE_INFOPLIST_FILE`, create a physical `Info.plist`, and add the exception there:

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
    </dict>
</dict>
```

This exception covers both HTTP REST calls (`/pair`, `/me`) and the existing `ws://` WebSocket connection to the same domain. Note: the existing `ws://` connection in `WebSocketManager` has been working without an ATS exception — this may be because the app has only been tested in the simulator (which is less strict) or because WebSocket upgrades from `ws://` on port 80/3099 may behave differently. The ATS exception ensures it works correctly on physical devices.

If/when beekeeper moves to HTTPS/WSS, remove this exception.

## Changes

### 1. KeychainManager — add device identity fields

**File**: `Managers/KeychainManager.swift`

Currently stores only `auth_token`. Add:

- `deviceId` (String?) — device UUID from server, key `device_id`
- `deviceName` (String?) — user-facing device name, key `device_name`
- `isPaired` (Bool) — computed, alias for `token != nil`
- `clearAll()` — wipes token + deviceId + deviceName
- `tokenExpiryDate` (Date?) — decodes JWT payload, extracts `exp` claim (see section 5)

Remove `hasToken` (replaced by `isPaired`). Remove `clear()` (replaced by `clearAll()`).

Keep service as `io.keepur.beekeeper`. Match dodi-shop-ios `KeychainManager` pattern.

**Callers to update when renaming `hasToken` → `isPaired`**:
- `RootView.swift` lines 10, 20, 25 — `KeychainManager.hasToken`
- `WebSocketManager.swift` line 114 — `KeychainManager.hasToken` in `scheduleReconnect()`

**Callers to update when renaming `clear()` → `clearAll()`**:
- `ChatViewModel.swift` line 76 — `KeychainManager.clear()`

### 2. New APIManager — REST calls for pairing and /me

**New file**: `Managers/APIManager.swift`

Lightweight enum with static methods. Base URL: `http://beekeeper.dodihome.com`.

**Types** (all defined as nested types inside `APIManager`):

```swift
struct PairResponse {
    let token: String
    let deviceId: String
    let deviceName: String
}

enum PairError: Error {
    case invalidCode
}

enum APIError: Error {
    case requestFailed
    case unauthorized
}
```

**Methods**:

```
APIManager.pair(code:name:) async throws -> PairResponse
APIManager.fetchMe() async throws -> String?
```

**`pair(code:name:)`**: POST to `/pair` with body `{ "code": code, "userName": name }`. Returns `PairResponse`. Throws `PairError.invalidCode` on non-200 or missing fields. Other errors propagate as-is (callers catch generically for network failures). Note: the server's `verifyPairingCode(code, name?)` stores the name on the device record at pairing time — no separate `updateName` call is needed after pairing.

**`fetchMe()`**: GET `/me` with `Authorization: Bearer <token>` header. Parses `json["name"]` from response. Throws `APIError.unauthorized` on 401 (only this case — `.requestFailed` is not thrown by this method). Returns `nil` without throwing on 200 with unparseable body. Caches returned name to `KeychainManager.deviceName`. This is the canonical source for `deviceName` — whatever the server returns overwrites the locally stored value.

### 3. SetupView → PairingView — 6-digit code entry

**Delete**: `Views/SetupView.swift`
**New file**: `Views/PairingView.swift`

Replace token paste UI with two-step pairing flow (matching dodi-shop-ios):

**Callback**: `onPaired: () -> Void` (replaces `SetupView.onConnect`).

**Step 1 — Code entry**:
- Heading: "Enter the 6-digit pairing code from your admin dashboard"
- 6 individual digit boxes (monospaced, 36pt bold)
- Hidden TextField with `.numberPad`, filters to digits only
- Auto-advances to step 2 when 6 digits entered

**Step 2 — Device name**:
- Heading: "Name this device"
- Single text field for device name (centered, 24pt)
- "Back" button (resets code, returns to step 1)
- "Continue" button (disabled while name is empty)
- No language picker (unlike dodi-shop — Keepur handles voice settings in SettingsView)

**On successful pair** (inside `pair()` method):
1. Call `APIManager.pair(code:name:)` → get `PairResponse`
2. Store `PairResponse.token`, `PairResponse.deviceId` in `KeychainManager`. Store `PairResponse.deviceName` as `KeychainManager.deviceName` (the server sets this from the `userName` field at pairing time via `verifyPairingCode`; `fetchMe()` will refresh it on future launches)
3. Haptic success feedback (`UINotificationFeedbackGenerator.success`)
4. Call `onPaired()` callback

Note: unlike dodi-shop-ios which calls `APIManager.updateName()` after pairing, beekeeper's `/pair` endpoint stores the name directly — no follow-up call needed.

**Error handling**:
- `APIManager.PairError.invalidCode` (non-200 from `/pair`): "Invalid pairing code. Try again." in red, haptic error feedback, reset to step 1, re-focus code field. Catch as `catch is APIManager.PairError` (fully qualified — `PairError` is a nested type of `APIManager`, not defined locally in the view)
- Any other error (network, parsing): "Connection error. Check network." in red, stay on current step
- Loading state: `ProgressView` while request is in flight, disable inputs

### 4. RootView — auth state management

**File**: `Views/RootView.swift`

**Current architecture** (must be preserved):
- `@StateObject private var viewModel = ChatViewModel()` — owns the ViewModel
- `viewModel.configure(context:)` called on appear — wires WebSocket + SwiftData
- `scenePhase` observation reconnects WebSocket on foreground

**Changes**:

Replace `KeychainManager.hasToken && viewModel.isAuthenticated` with `KeychainManager.isPaired && viewModel.isPaired` (the ViewModel property is renamed, see section 7).

Replace `SetupView { ... }` with `PairingView(onPaired: { ... })`. The closure body stays the same: set `viewModel.isPaired = true`, call `viewModel.configure(context:)`.

Add `.task` modifier to the `SessionListView` branch (not the outer `Group`) to validate the token on launch. Attaching to the outer `Group` would re-fire on every `isPaired` transition, including immediately after pairing succeeds (redundant). Attaching to `SessionListView` ensures it only runs when the paired UI is displayed, matching dodi-shop-ios's pattern:

```swift
if KeychainManager.isPaired && viewModel.isPaired {
    SessionListView(viewModel: viewModel)
        .task {
            do {
                try await APIManager.fetchMe()
            } catch APIManager.APIError.unauthorized {
                // 401 — token expired or revoked
                viewModel.unpair()
            } catch {
                // Network error or other — don't log out, proceed normally
            }
        }
} else {
    PairingView(onPaired: {
        viewModel.isPaired = true
        viewModel.configure(context: modelContext)
    })
}
```

`viewModel.unpair()` handles both Keychain cleanup AND setting `viewModel.isPaired = false`, which triggers the view to switch to `PairingView`. This is the single source of truth for auth state transitions.

The `scenePhase` guard changes from `KeychainManager.hasToken` to `KeychainManager.isPaired`.

### 5. Token expiry warning — 7-day advance notice

**Approach**: Decode the JWT payload client-side to read the `exp` claim. JWTs are base64url-encoded JSON — no crypto library needed, just decode the middle segment.

Add to `KeychainManager`:

```
static var tokenExpiryDate: Date?
```

Decodes the middle segment of the stored JWT, parses JSON, extracts `exp` (Unix timestamp), returns as `Date`. Returns nil if token is missing or payload can't be decoded.

**Warning UI**: Show a non-dismissible banner at the top of `SessionListView`'s List when token expires within 7 days:

> "Device pairing expires in X days"

The banner is a simple `HStack` with a warning icon and text, styled in orange/yellow. Tapping the banner opens the `SettingsView` sheet (see below for new settings gear on `SessionListView`).

**State management**: `SessionListView` computes `daysRemaining` as a `@State private var daysRemaining: Int?` updated in `.onAppear` from `KeychainManager.tokenExpiryDate`. The banner only renders when `daysRemaining` is non-nil and between 0 and 7. Display text: "Device pairing expires today" when `daysRemaining == 0`, "Device pairing expires in 1 day" when 1, "Device pairing expires in X days" otherwise. Using `@State` with `.onAppear` (not a computed property) avoids redundant Keychain reads on every SwiftUI re-render.

**Settings access from SessionListView**: Add a gear icon (`gearshape`) toolbar button to `SessionListView` (in the `topBarTrailing` position, alongside the existing new-session menu). This opens a `SettingsView` sheet. Currently, Settings is only reachable from inside `ChatView` — adding it to `SessionListView` ensures users can reach "Unpair Device" without entering a chat session, which is critical for the expiry warning flow.

### 6. SettingsView — unpair + device info

**File**: `Views/SettingsView.swift`

**Device section** (new, at top of List):
- Show device name from `KeychainManager.deviceName` (or "Unknown" fallback)
- Show truncated device ID from `KeychainManager.deviceId` (first 8 chars, monospaced caption)

**Connection section** (existing): Keep status indicator and session info as-is.

**Workspace section**: Delete the entire conditional block (lines 34–53 of current `SettingsView.swift`), not just hide it — the workspace switching UI is intentionally removed from Settings. Users switch workspaces by creating new sessions via `SessionListView`'s toolbar menu, which is the canonical path going forward. The `ChatViewModel.availableWorkspaces` property and related plumbing in `SessionListView` remain untouched.

**Actions section** (replaces existing):
- Keep "Disconnect" / "Reconnect" button as-is
- Replace "Clear Token & Disconnect" with **"Unpair Device"** (destructive role)
- "Unpair Device" shows a `.confirmationDialog` before proceeding
- On confirm: calls `viewModel.unpair()` then `dismiss()`

### 7. ChatViewModel — auth state and naming updates

**File**: `ViewModels/ChatViewModel.swift`

**Renames**:
- `isAuthenticated` → `isPaired` (`@Published var isPaired = true`)
- `clearToken()` → `unpair()`

**`unpair()` implementation** (replaces `clearToken()`):
```swift
func unpair() {
    ws.disconnect()
    KeychainManager.clearAll()
    isPaired = false
}
```

This is the single method for all auth-failure paths. It handles Keychain cleanup, WebSocket disconnect, AND `@Published` state update so RootView reacts immediately.

**`onAuthFailure` handler** in `configure()`: change from `self?.isAuthenticated = false` to `self?.unpair()`. This ensures Keychain is also cleared when the WebSocket rejects the token, not just the view state.

**Re-entrancy note**: `onAuthFailure` is fired from `WebSocketManager` during its disconnect path. Calling `unpair()` → `ws.disconnect()` re-enters `disconnect()` while the WebSocket is already tearing down. This is safe: `disconnect()` is idempotent — it invalidates timers and cancels tasks regardless of current state, and sets `isReconnecting = false` which correctly prevents auto-reconnect after auth failure (you don't want to reconnect with a rejected token). Do not add an `isConnected` early-return guard to `disconnect()` — the unconditional `isReconnecting = false` is load-bearing for this path.

**`configure()`** callback wiring stays the same — `ws.onMessage`, `ws.onAuthFailure`, then `ws.connect()`.

### 8. WebSocketManager — rename only

**File**: `Managers/WebSocketManager.swift`

Single change: in `scheduleReconnect()`, replace `KeychainManager.hasToken` with `KeychainManager.isPaired` (line 114). No other changes — WebSocket connects with `?token=<JWT>` as before, the token format changing from static string to JWT is transparent.

### 9. KeepurApp — no changes needed

**File**: `KeepurApp.swift`

Injects `modelContainer` into the environment. `RootView` reads it via `@Environment(\.modelContext)`. This chain is unaffected by the pairing changes — `ChatViewModel` still receives its `ModelContext` via `configure(context:)` called from `RootView.onAppear`. No changes required.

## File Summary

| File | Action |
|------|--------|
| `Managers/KeychainManager.swift` | Modify — add deviceId, deviceName, isPaired, clearAll(), tokenExpiryDate; remove hasToken, clear() |
| `Managers/APIManager.swift` | **New** — PairResponse, pair(), fetchMe() |
| `Views/SetupView.swift` | **Delete** |
| `Views/PairingView.swift` | **New** — 6-digit code entry + device name (replaces SetupView) |
| `Views/RootView.swift` | Modify — .task on SessionListView for /me check, use isPaired, PairingView(onPaired:) |
| `Views/SessionListView.swift` | Modify — add expiry warning banner, settings gear toolbar button, @State daysRemaining |
| `Views/SettingsView.swift` | Modify — device info section, unpair button with confirmation, remove workspace section |
| `ViewModels/ChatViewModel.swift` | Modify — rename clearToken→unpair, isAuthenticated→isPaired, unpair() clears all state, re-entrancy note |
| `Managers/WebSocketManager.swift` | Modify — rename hasToken→isPaired in scheduleReconnect() |
| `KeepurApp.swift` | No changes |
| `Keepur.xcodeproj/project.pbxproj` | Modify — ATS exception for beekeeper.dodihome.com (or create Info.plist if needed) |

## Out of Scope

- Multi-session support (#64)
- Workspace browsing (#65)
- Token refresh/rotation (server doesn't support it yet)
- Admin device management in the iOS app (admin uses CLI or web)
