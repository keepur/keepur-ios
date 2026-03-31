# Pre-Submit Testing

Builds the project and runs the full test suite. Fixes failures along the way.

## Trigger

Called by `/quality-gate` as step 3, or manually via `/pre-submit-testing`.

## Workflow

### 1. Discover Test Files

```bash
git diff main --name-only | grep -E 'Tests?\.swift$'
```

Classify into: UNIT_TESTS (KeepurTests/), UI_TESTS (KeepurUITests/).

### 2. Build Check

Verify the project compiles cleanly before running tests:

```bash
xcodebuild build -project Keepur.xcodeproj -scheme Keepur -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1
```

**On build failure:** STOP. Report errors. Developer must fix compilation before tests can run.

### 3. Run Unit Tests

```bash
xcodebuild test -project Keepur.xcodeproj -scheme Keepur -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:KeepurTests 2>&1
```

### 4. Run UI Tests

```bash
xcodebuild test -project Keepur.xcodeproj -scheme Keepur -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:KeepurUITests 2>&1
```

### 5. Failure Handling

For each failing test:
1. Read the failing test and the source code it exercises
2. Determine root cause: test bug, source bug, data setup issue, timing/async issue
3. Fix the issue
4. Re-run the specific test file
5. Repeat until green (max 5 attempts per test file)

Pre-existing failures (tests that also fail on `main`) are noted but don't block.

### 6. Report

```
## Pre-Submit Test Results

**Branch:** <branch-name>

### Build
[PASS/FAIL]

### Unit Tests (KeepurTests)
[PASS/FAIL] — N/N passed
- details of any fixes applied

### UI Tests (KeepurUITests)
[PASS/FAIL] — N/N passed
- details of any fixes applied

**Ready for PR:** [YES/NO]
```

## No Tests Exist Yet

If test targets haven't been created in the Xcode project, run a build check only and report:

```
## Pre-Submit Test Results

### Build
[PASS/FAIL]

### Tests
⚠️ No test targets exist yet. Build check only.

**Ready for PR:** [YES — build clean] or [NO — build failed]
```
