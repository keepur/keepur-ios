## Voice Transcription Fixes Implementation Plan

> **For agentic workers:** Use dodi-dev:implement to execute this plan.

**Goal:** Fix two glue-code bugs that cause Whisper transcription to truncate at 30s and to occasionally lose the final emission on stop. Issue #36.

**Architecture:** Two surgical changes. (1) `SpeechManager` accumulates confirmed segments into a persistent buffer keyed by segment end-time, so the rolling 30s window in `AudioStreamTranscriber` no longer erases earlier text. (2) `ChatView` removes the `isRecording` gate on its `liveText` subscription so the post-stop final emission isn't dropped; cumulative state is reset at the next recording start.

**Tech Stack:** Swift, SwiftUI, WhisperKit (`AudioStreamTranscriber`), Combine, Swift Testing.

---

### Task 1: Cumulative confirmed-text buffer in SpeechManager

**Files:**
- Modify: `Managers/SpeechManager.swift` (add buffer state + rewrite stream callback + reset on start)

- [ ] **Step 1:** Add cumulative buffer state.

In `Managers/SpeechManager.swift`, add two private properties just below the `streamTranscriber` property (around line 28):

```swift
    private var streamTranscriber: AudioStreamTranscriber?
    /// Accumulated text from confirmed segments that have already been absorbed
    /// across all transcription cycles. Survives the 30s rolling window slide.
    private var accumulatedConfirmedText: String = ""
    /// Highest `end` timestamp (seconds) of any confirmed segment we've already
    /// appended to `accumulatedConfirmedText`. Used to skip re-emitted segments
    /// that are still inside the current window.
    private var lastConfirmedEnd: Float = 0
```

- [ ] **Step 2:** Reset cumulative state on each new recording.

In `startRecording()`, replace the line `liveText = ""` (around line 88) with:

```swift
        liveText = ""
        accumulatedConfirmedText = ""
        lastConfirmedEnd = 0
```

- [ ] **Step 3:** Rewrite the stream callback to append-only.

Replace the closure body passed to `AudioStreamTranscriber` (the lines currently at `Managers/SpeechManager.swift:143-156`) with:

```swift
        ) { [weak self] _, newState in
            // Callback fires on each transcription cycle (~1s).
            // `confirmedSegments` only contains segments still inside the rolling
            // 30s window — earlier ones are dropped as the window slides. We must
            // accumulate them ourselves, keyed by segment end-time, so older text
            // doesn't vanish from `liveText`.
            Task { @MainActor in
                guard let self else { return }
                for segment in newState.confirmedSegments where segment.end > self.lastConfirmedEnd {
                    let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        if self.accumulatedConfirmedText.isEmpty {
                            self.accumulatedConfirmedText = text
                        } else {
                            self.accumulatedConfirmedText += " " + text
                        }
                    }
                    self.lastConfirmedEnd = segment.end
                }
                let unconfirmed = newState.unconfirmedSegments
                    .map(\.text)
                    .joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let combined = [self.accumulatedConfirmedText, unconfirmed]
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                self.liveText = combined
            }
        }
```

- [ ] **Step 4:** Build to verify it compiles.

Run: `xcodebuild -project Keepur.xcodeproj -scheme Keepur -destination 'platform=iOS Simulator,name=iPhone 16' build -quiet`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 5:** Commit.

```bash
git add Managers/SpeechManager.swift
git commit -m "fix(voice): accumulate confirmed segments across 30s window slides"
```

---

### Task 2: Remove isRecording gate on liveText subscription

**Files:**
- Modify: `Views/ChatView.swift:267-271`

- [ ] **Step 1:** Drop the gate.

Replace the `.onReceive` block at `Views/ChatView.swift:267-271`:

```swift
        .onReceive(viewModel.speechManager.$liveText) { newText in
            if viewModel.speechManager.isRecording {
                viewModel.messageText = newText
            }
        }
```

with:

```swift
        .onReceive(viewModel.speechManager.$liveText) { newText in
            // No `isRecording` gate: the stream transcriber's final callback
            // (carrying the last confirmed text) hops to MainActor *after*
            // `stopRecording()` has already flipped `isRecording` to false.
            // Gating here drops that final emission. Cumulative state is reset
            // at the start of the next recording, so stale text can't leak in.
            guard !newText.isEmpty else { return }
            viewModel.messageText = newText
        }
```

- [ ] **Step 2:** Build to verify.

Run: `xcodebuild -project Keepur.xcodeproj -scheme Keepur -destination 'platform=iOS Simulator,name=iPhone 16' build -quiet`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 3:** Commit.

```bash
git add Views/ChatView.swift
git commit -m "fix(voice): deliver final whisper emission after stopRecording"
```

---

### Task 3: Unit test for cumulative accumulation

**Files:**
- Create: `KeeperTests/SpeechAccumulationTests.swift`

The accumulation logic is currently a private closure inside `startRecording()`, which is not directly testable without spinning up WhisperKit. Extract the pure step into an internal method, then test it.

- [ ] **Step 1:** Extract pure accumulation step in `Managers/SpeechManager.swift`.

Just above the `// MARK: - TTS (unchanged)` line (around line 197), add:

```swift
    // MARK: - Test Hooks

    /// Pure accumulation step, extracted for unit testing. Mutates
    /// `accumulatedConfirmedText` and `lastConfirmedEnd`, returns the combined
    /// `liveText` value that would be published.
    /// - Parameters:
    ///   - confirmed: array of (end, text) pairs from `newState.confirmedSegments`
    ///   - unconfirmed: joined text from `newState.unconfirmedSegments`
    func absorbTranscriptionTick(confirmed: [(end: Float, text: String)], unconfirmed: String) -> String {
        for segment in confirmed where segment.end > lastConfirmedEnd {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                if accumulatedConfirmedText.isEmpty {
                    accumulatedConfirmedText = text
                } else {
                    accumulatedConfirmedText += " " + text
                }
            }
            lastConfirmedEnd = segment.end
        }
        let trimmedUnconfirmed = unconfirmed.trimmingCharacters(in: .whitespacesAndNewlines)
        let combined = [accumulatedConfirmedText, trimmedUnconfirmed]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return combined
    }

    /// Test hook: reset cumulative buffers as if a new recording were starting.
    func resetAccumulationForTesting() {
        accumulatedConfirmedText = ""
        lastConfirmedEnd = 0
        liveText = ""
    }
```

Then refactor the stream callback (from Task 1, Step 3) to call this helper. Replace the loop block inside the `Task { @MainActor in ... }` with:

```swift
            Task { @MainActor in
                guard let self else { return }
                let confirmed = newState.confirmedSegments.map { (end: $0.end, text: $0.text) }
                let unconfirmed = newState.unconfirmedSegments.map(\.text).joined(separator: " ")
                self.liveText = self.absorbTranscriptionTick(confirmed: confirmed, unconfirmed: unconfirmed)
            }
```

- [ ] **Step 2:** Create `KeeperTests/SpeechAccumulationTests.swift`.

```swift
import Testing
@testable import Keepur

@MainActor
struct SpeechAccumulationTests {

    @Test func accumulatesAcrossWindowSlide() async {
        let sm = SpeechManager()
        sm.resetAccumulationForTesting()

        // Tick 1: window contains segments at 0-2s, 2-5s.
        let r1 = sm.absorbTranscriptionTick(
            confirmed: [(2.0, "Hello world."), (5.0, "How are you?")],
            unconfirmed: "I am"
        )
        #expect(r1 == "Hello world. How are you? I am")

        // Tick 2: window has slid; the 0-2s segment was dropped by WhisperKit,
        // but the 2-5s segment is still present and a new 5-8s segment appeared.
        let r2 = sm.absorbTranscriptionTick(
            confirmed: [(5.0, "How are you?"), (8.0, "doing fine.")],
            unconfirmed: ""
        )
        #expect(r2 == "Hello world. How are you? doing fine.")

        // Tick 3: window slid again; only the 8s segment remains, plus a new one.
        let r3 = sm.absorbTranscriptionTick(
            confirmed: [(8.0, "doing fine."), (11.0, "Thanks for asking.")],
            unconfirmed: "Bye"
        )
        #expect(r3 == "Hello world. How are you? doing fine. Thanks for asking. Bye")
    }

    @Test func resetClearsState() async {
        let sm = SpeechManager()
        _ = sm.absorbTranscriptionTick(confirmed: [(1.0, "first")], unconfirmed: "")
        sm.resetAccumulationForTesting()
        let r = sm.absorbTranscriptionTick(confirmed: [(1.0, "second")], unconfirmed: "")
        #expect(r == "second")
    }

    @Test func skipsEmptyAndDuplicateSegments() async {
        let sm = SpeechManager()
        sm.resetAccumulationForTesting()
        _ = sm.absorbTranscriptionTick(confirmed: [(1.0, "  "), (2.0, "hi")], unconfirmed: "")
        // Same end-time should not be re-appended.
        let r = sm.absorbTranscriptionTick(confirmed: [(2.0, "hi")], unconfirmed: "there")
        #expect(r == "hi there")
    }
}
```

- [ ] **Step 3:** Run the test suite.

Run: `xcodebuild test -project Keepur.xcodeproj -scheme Keepur -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:KeeperTests/SpeechAccumulationTests -quiet`
Expected: tests pass; `** TEST SUCCEEDED **`

- [ ] **Step 4:** Run the full test suite to confirm no regressions.

Run: `xcodebuild test -project Keepur.xcodeproj -scheme Keepur -destination 'platform=iOS Simulator,name=iPhone 16' -quiet`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5:** Commit.

```bash
git add Managers/SpeechManager.swift KeeperTests/SpeechAccumulationTests.swift
git commit -m "test(voice): cover cumulative confirmed-segment accumulation"
```

---

### Acceptance Verification (manual)

After all tasks land, sanity-check on a real device:

1. Record continuously for 60+ seconds, speaking the whole time. All earlier text remains visible in the input bar (no chop at ~30s).
2. Tap stop after a ~2-second utterance, repeat 10 times. Text lands in the input bar every time.
3. Existing test suite still green.
