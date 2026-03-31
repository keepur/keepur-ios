# Swift Compliance Check

Validates that changed files follow the project's architectural rules and Swift/SwiftUI conventions.

## Trigger

Called by `/quality-gate` as step 1, or manually via `/swift-compliance`.

## Scope

By default, check files changed on the current branch vs `main`. If on `main`, check all staged/unstaged changes.

```bash
git diff main --name-only -- '*.swift'
```

If no Swift files changed, report "no Swift changes to check" and pass.

## Compliance Rules

### 1. Architecture Layering

Views must NOT contain business logic or direct network calls. Check for violations:

- **Red flags in Views/**: Direct `URLSession` calls, `JSONDecoder` usage, `Keychain` access, raw WebSocket operations
- **Correct**: Views observe `@ObservedObject` / `@StateObject` ViewModels, call ViewModel methods

ViewModels must NOT import SwiftUI (they should use Combine/Foundation only, except for `@MainActor`).

Managers must NOT reference ViewModels or Views.

**Layering:** Views → ViewModels → Managers/Models. Never the reverse.

### 2. Concurrency Safety

- All ViewModels must be annotated `@MainActor`
- All `@Published` properties must live inside `@MainActor` classes
- No `DispatchQueue.main.async` in SwiftUI code — use `@MainActor` instead
- No force unwraps (`!`) except in tests and static constants (e.g., `URL(string: "known-good")!`)

### 3. SwiftData Model Hygiene

- All `@Model` classes must have an explicit `id` property
- No direct `ModelContext` usage in Views — must go through ViewModel
- Fetch descriptors must use `#Predicate` (not raw NSPredicate)

### 4. WebSocket Protocol Consistency

- All WebSocket message types must be defined in `WSMessage.swift`
- No raw JSON string construction — use `Codable` conformance
- No `try!` or `try?` on encode/decode — handle errors explicitly

### 5. File Organization

- Views in `Views/`, ViewModels in `ViewModels/`, Managers in `Managers/`, Models in `Models/`
- No business logic in `KeepurApp.swift` beyond app entry and SwiftData container setup
- Extracted subviews should stay in the same file as the parent view (via extension) unless reused elsewhere

## Report Format

```
## Swift Compliance Results

**Branch:** <branch-name>
**Files checked:** N

### 1. Architecture Layering
[PASS/FAIL] — details

### 2. Concurrency Safety
[PASS/FAIL] — details

### 3. SwiftData Model Hygiene
[PASS/FAIL] — details

### 4. WebSocket Protocol Consistency
[PASS/FAIL] — details

### 5. File Organization
[PASS/FAIL] — details

**Overall: [PASS/FAIL]**
```

## On Failure

Report all violations with file paths and line numbers. Developer must fix violations before proceeding. Do NOT auto-fix — compliance violations often indicate design problems that need human judgment.
