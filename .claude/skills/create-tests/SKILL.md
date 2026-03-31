# Create Tests

Generates unit and UI tests for changed files on the current branch.

## Trigger

Called by `/quality-gate` as step 2, or manually via `/create-tests`.

## Scope Auto-Detection (in order)

1. Branch diff vs main (default if on feature branch)
2. Specific files (if file paths specified as args)
3. Ask user (if on main with no args)

```bash
git diff main --name-only -- '*.swift'
```

## Test Classification

Analyze each changed file and classify into test buckets:

| Changed File | Test Type | Location |
|-------------|-----------|----------|
| `Models/*.swift` | Unit | `KeepurTests/Models/` |
| `Managers/*.swift` | Unit | `KeepurTests/Managers/` |
| `ViewModels/*.swift` | Unit | `KeepurTests/ViewModels/` |
| `Views/*.swift` | UI (XCUITest) | `KeepurUITests/` |

## Unit Test Triage — Only If Valuable

**WRITE tests for:**
- Codable encode/decode (WSMessage types, models)
- State machine logic (ViewModel state transitions, reconnect backoff)
- Data transformations (message assembly, streaming chunk handling)
- Validation logic (token validation, input sanitization)
- Manager logic with mockable dependencies (WebSocket message routing, Keychain read/write)

**SKIP tests for:**
- Simple SwiftUI views with no logic (just layout)
- Trivial getters/setters on @Model properties
- SwiftData fetch descriptors (test via integration, not unit)
- App entry point (KeepurApp.swift)

## Test Patterns

### Unit Test (XCTest)

```swift
import XCTest
@testable import Keepur

final class WSMessageTests: XCTestCase {
    func testEncodeOutgoingMessage() throws {
        let msg = WSOutgoing.message(sessionId: "s1", text: "hello")
        let data = try JSONEncoder().encode(msg)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["type"] as? String, "message")
    }
}
```

### UI Test (XCUITest)

```swift
import XCTest

final class ChatFlowTests: XCTestCase {
    let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launch()
    }

    func testSendMessage() throws {
        // Navigate to chat, type message, verify it appears
    }
}
```

## Test Target Setup

If test targets don't exist yet in the Xcode project:

1. **KeepurTests** — Unit test target (XCTest), depends on Keepur app target
2. **KeepurUITests** — UI test target (XCUITest), depends on Keepur app target

Add targets to `Keepur.xcodeproj` using Xcode project file manipulation or instruct the user to add them via Xcode.

## Mandatory Run/Fix Loop

After generating tests:

1. Build tests: `xcodebuild test -project Keepur.xcodeproj -scheme Keepur -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:KeepurTests 2>&1`
2. If tests fail, determine root cause (test bug vs source bug)
3. Fix and re-run (max 5 attempts per test file)
4. Commit passing tests before proceeding

If changes don't need tests (docs-only, asset changes, spec files), report "no new tests needed" and pass.
