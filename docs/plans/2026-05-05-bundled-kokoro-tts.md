# Bundled Kokoro On-Device Neural TTS — Implementation Plan

> **For agentic workers:** Use `dodi-dev:implement` to execute this plan.

**Goal:** Bundle Kokoro-82M neural TTS in the Keepur app as the default engine for English voices, while keeping every system voice available as a fallback / non-English option.

**Architecture:** A `TTSEngine` protocol with two implementations — `KokoroEngine` (new, wraps `mlalma/kokoro-ios` Swift Package) and `SystemTTSEngine` (thin wrapper over the existing `AVSpeechSynthesizer` path). `SpeechManager` holds both and dispatches `speak(text, voiceId)` based on a `kokoro:` prefix on the voice identifier. A static `KokoroVoiceCatalog` lists curated English voices with friendly display names. Pickers gain a "ON-DEVICE NEURAL" section above the existing system list.

**Tech Stack:** Swift 5, SwiftUI, AVFoundation, MLX Swift (transitively via `mlalma/kokoro-ios`), SwiftData, XCTest. Targets: iOS 26.2+, macOS 15+.

**Source spec:** `docs/specs/2026-05-05-bundled-kokoro-tts-design.md`

## Testing Contract

### Required Test Groups

- Unit: **required**
  - Scope: `KokoroVoiceCatalog`, `SpeechManager` dispatch logic, voice ID prefix parsing, fallback behavior on engine failure.
  - Reason: Dispatch correctness is the load-bearing seam between engines. Catalog data drives the picker UI and must be self-consistent. Fallback must work without audio output, so unit-level mocks are the only practical surface.
  - Minimum assertions:
    - `KokoroVoiceCatalog.voices` is non-empty; every entry has `id` (with `kokoro:` prefix), `displayName`, `description`.
    - Catalog IDs are unique.
    - `SpeechManager.speak(text:agentId:)` routes `kokoro:*` IDs to the Kokoro engine and other IDs to the system engine (verified via injected mocks).
    - When the Kokoro engine throws on `speak`, `SpeechManager` invokes the system engine fallback and does **not** clear the stored voice ID.
    - `selectedVoiceId` defaults to `kokoro:af_heart` for fresh installs (no prior `UserDefaults` value).

- Integration: **not-required**
  - Reason: There is no harness for synthesizing real audio in tests, and `AVSpeechSynthesizer` / `KokoroTTS` are exactly the boundary we mock at the unit layer. No DB, no network, no OS service interaction beyond the engines themselves.

- E2E: **not-required**
  - Reason: This is a swap-in replacement for an existing engine; user-visible flows (tap mic, speak reply) are unchanged in shape. There is no CI E2E harness for audio output. Manual verification is captured below in **Critical Flows**.

### Critical Flows

(Manual verification — no automated coverage.)

- **Default voice on fresh install (iOS):** Wipe app, launch, open Settings → Voice. The first ON-DEVICE NEURAL voice is checked.
- **Preview Kokoro voice:** Tap each Kokoro voice row in Settings → hear the preview phrase rendered by Kokoro (audibly different from system voices).
- **Send + receive a chat message:** Connect to Beekeeper, send "hi", receive a reply with auto-read-aloud on. Reply is read aloud in the selected Kokoro voice.
- **Fallback path:** Force engine failure (e.g. delete bundled `.mlpackage` in a debug build), send a message, hear the system voice. No crash, no error UI.
- **Existing user upgrade:** Install previous version, set a system voice (e.g. Samantha), upgrade to this build. Voice stays Samantha. Picker now shows the new ON-DEVICE NEURAL section above SYSTEM.
- **Per-agent override:** In an agent detail sheet, tap "Voice…", pick a Kokoro voice, hear preview, return. That agent's replies use the overridden voice.
- **macOS:** Same default-voice + preview flow on macOS 15 build.

### Regression Surface

- `Managers/SpeechManager.swift` (existing API: `speak(_:agentId:)`, `speak(_:voice:)`, `setVoice(_:forAgent:)`, `selectedVoiceId`, `agentVoiceIds`) must keep its public shape. Callers in `ChatViewModel`, `TeamViewModel`, `ContentView`, `SettingsView`, `AgentVoicePickerView`, `MessageInputBar` must compile unchanged.
- Speech recognition (mic / `SFSpeechRecognizer`) path is untouched — `loadModel()`, `startRecording()`, `stopRecording()`, `liveText` must continue working.
- App launch time must not regress noticeably (engine load is lazy; cold path on launch is no different than today).

### Commands

- Unit: `xcodebuild test -project Keepur.xcodeproj -scheme Keepur -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:KeeperTests`
- Integration: not-applicable
- E2E: not-applicable
- Broader regression: same `xcodebuild test` command — runs the full unit suite (~24 existing test files).

### Harness Requirements

- iOS 26.2 simulator (iPhone 16 or similar) for the test command.
- macOS 15 build target available on the dev machine for cross-platform smoke.
- For manual verification: a paired Beekeeper instance reachable at `ws://beekeeper.dodihome.com` (already configured for the project).
- Kokoro model weights downloaded from Hugging Face and committed via Git LFS, or fetched as a pre-implementation prerequisite (see Task 2).

### Non-Required Rationale

- Integration: the only "integration" boundary is the Swift Package's `KokoroTTS` engine, which is itself the unit under test from our side. We mock it at the protocol seam.
- E2E: audio output has no automated assertion path on iOS / macOS CI (and there is no CI today). Manual flows above replace it.

### Verification Rules

- Missing harness is not a skip reason; set it up or report a concrete blocker.
- If a test failure exposes an implementation issue, fix the implementation, not the test.
- If testing exposes a spec or plan mismatch, demote the ticket to the spec lane.

---

## File Structure

### Created

| Path | Responsibility |
|---|---|
| `Managers/TTSEngine.swift` | Protocol + `SystemTTSEngine` wrapping `AVSpeechSynthesizer`. Single-purpose adapter file. |
| `Managers/KokoroEngine.swift` | `KokoroEngine` adapter — owns the `KokoroTTS` instance, lazy model load, voice embedding cache, audio playback via `AVAudioPlayer`. |
| `Managers/KokoroVoiceCatalog.swift` | Static catalog of curated English Kokoro voices: ID, display name, description, language. Single source of truth for the picker. |
| `Resources/Kokoro/kokoro-v1_0.mlpackage` | Bundled model weights (~80 MB, INT8 from FluidInference/kokoro-82m-coreml). Tracked via Git LFS. |
| `Resources/Kokoro/voices/<name>.npy` | One file per voice in the curated shortlist (~1 KB each). Tracked via Git LFS. |
| `Resources/Kokoro/LICENSE-Kokoro.txt` | Apache 2.0 NOTICE for the model. |
| `Resources/Kokoro/LICENSE-mlalma.txt` | MIT NOTICE for the Swift Package. |
| `KeeperTests/KokoroVoiceCatalogTests.swift` | Catalog data tests. |
| `KeeperTests/SpeechManagerDispatchTests.swift` | Dispatch + fallback tests using injected mock engines. |

### Modified

| Path | Change |
|---|---|
| `Keepur.xcodeproj/project.pbxproj` | Add `mlalma/kokoro-ios` SPM ref; add `Resources/Kokoro/` group as **non-synchronized** with explicit file references; add Copy Bundle Resources entries. |
| `Managers/SpeechManager.swift` | Refactor to compose `TTSEngine` instances and dispatch by voice-ID prefix. Public API preserved. New default for fresh installs. New `warmKokoroIfNeeded()`. Optional initializer with engine injection for tests. |
| `Views/SettingsView.swift` | Split voice section into "ON-DEVICE NEURAL" (Kokoro) and "SYSTEM" (existing). Add credits link in `footerSection`. |
| `Views/Team/AgentVoicePickerView.swift` | Same two-section split. |
| `Views/ChatView.swift` | Call `viewModel.speechManager.warmKokoroIfNeeded()` in the existing `.onAppear` at line 159. |
| `Info.plist` | (No change — Kokoro adds no new permissions; reuses the existing audio-session category.) |

---

## Pre-Implementation Discovery (Task 0)

Two facts about the `mlalma/kokoro-ios` Swift Package are not fully documented in its README and must be confirmed before writing the engine code. **Do these first** — the resulting answers feed Tasks 4 and 5.

- [ ] **D0.1:** Clone `mlalma/KokoroTestApp` to a scratch directory and read it. Document:
  - The exact return type of `KokoroTTS.generateAudio(voice:language:text:)` (Data? `AVAudioPCMBuffer`? `[Float]`?).
  - The output sample rate (Kokoro is documented as 24 kHz — confirm).
  - How voice-style `.npy` files are loaded into the `MLXArray` parameter (the test app shows the pattern).
  - Whether the model path expects a directory, an `.mlpackage` bundle, or some other shape.
- [ ] **D0.2:** Identify the latest tagged release of `mlalma/kokoro-ios` (or pin to a specific commit SHA if no tag exists). Record version in this plan and the Xcode SPM ref.
- [ ] **D0.3:** Identify exact filenames and SHA256 hashes for:
  - The Kokoro INT8 CoreML weights (from `FluidInference/kokoro-82m-coreml` or whatever the test app uses).
  - The `.npy` voice embedding files for the curated shortlist (Task 4 lists them).
- [ ] **D0.4:** Re-read [VOICES.md](https://huggingface.co/hexgrad/Kokoro-82M/blob/main/VOICES.md) and lock the curated shortlist (everything graded B- or above for English). Update Task 4's catalog if the spec's illustrative list is now stale.

Output of Task 0: a short note appended to this plan (or a comment in the relevant task) capturing the four answers. **Do not start Task 1 until Task 0 is complete.**

---

## Task 1: Add `mlalma/kokoro-ios` Swift Package dependency

**Files:**
- Modify: `Keepur.xcodeproj/project.pbxproj`
- Create: `Keepur.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` (Xcode regenerates this)

- [ ] **Step 1.1:** Open `Keepur.xcodeproj` in Xcode. File → Add Package Dependencies… → URL `https://github.com/mlalma/kokoro-ios`. Pin the version recorded in D0.2 (exact tag or commit). Add the `KokoroSwift` library product to the **Keepur** target only (not KeeperTests).

- [ ] **Step 1.2:** Verify the pbxproj diff added a new `XCRemoteSwiftPackageReference` block (around line 696 in the existing pbxproj) and a `XCSwiftPackageProductDependency` entry. Confirm only one new package is registered.

- [ ] **Step 1.3:** Build for iOS Simulator (Cmd+B). Resolve any missing transitive deps (MLX Swift, MisakiSwift, MLXUtilsLibrary) — Xcode pulls these automatically from the package's `Package.swift`.

  Run: `xcodebuild -resolvePackageDependencies -project Keepur.xcodeproj`
  Expected: exit code 0, console mentions resolving `kokoro-ios`, `mlx-swift`, `MisakiSwift`.

- [ ] **Step 1.4:** Add a one-line import test to confirm the module is callable.

  Create `KeeperTests/KokoroSwiftImportTests.swift`:

  ```swift
  import XCTest
  @testable import Keepur
  import KokoroSwift

  final class KokoroSwiftImportTests: XCTestCase {
      func testKokoroSwiftModuleIsImportable() {
          // Compilation alone proves the dep is wired.
          XCTAssertNotNil(String(describing: KokoroTTS.self))
      }
  }
  ```

  Wire this test file into the KeeperTests target manually (KeeperTests is already a non-synchronized group — add a `PBXFileReference` and a corresponding `PBXBuildFile` entry, following the pattern of existing test files like `BeekeeperConfigTests.swift` at lines 35 and 201 of the pbxproj).

  Run: `xcodebuild test -project Keepur.xcodeproj -scheme Keepur -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:KeeperTests/KokoroSwiftImportTests`
  Expected: 1 test passed.

- [ ] **Step 1.5:** Commit.

  ```bash
  git add Keepur.xcodeproj/project.pbxproj \
          Keepur.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved \
          KeeperTests/KokoroSwiftImportTests.swift
  git commit -m "feat: add mlalma/kokoro-ios SPM dependency"
  ```

---

## Task 2: Set up `Resources/Kokoro/` folder and bundle weights

**Files:**
- Create: `.gitattributes` (or extend if exists)
- Create: `Resources/Kokoro/kokoro-v1_0.mlpackage` (LFS)
- Create: `Resources/Kokoro/voices/<voice>.npy` × N (LFS)
- Create: `Resources/Kokoro/LICENSE-Kokoro.txt`
- Create: `Resources/Kokoro/LICENSE-mlalma.txt`
- Modify: `Keepur.xcodeproj/project.pbxproj` (manual non-synchronized group + Copy Bundle Resources)

- [ ] **Step 2.1:** Initialize Git LFS for the repo if not already.

  Run:
  ```bash
  git lfs install
  ```
  Expected: `Git LFS initialized.` (or no-op if already done).

- [ ] **Step 2.2:** Add LFS tracking for binary asset extensions.

  Append to `.gitattributes` (create if missing):
  ```
  *.mlpackage filter=lfs diff=lfs merge=lfs -text
  Resources/Kokoro/**/*.mlpackage filter=lfs diff=lfs merge=lfs -text
  Resources/Kokoro/**/*.mlmodel filter=lfs diff=lfs merge=lfs -text
  Resources/Kokoro/**/*.mlmodelc filter=lfs diff=lfs merge=lfs -text
  Resources/Kokoro/voices/*.npy filter=lfs diff=lfs merge=lfs -text
  ```

  Note: an `.mlpackage` is a directory. LFS tracks its contained files. Run `git lfs track` from the repo root if Xcode complains about specific inner files.

- [ ] **Step 2.3:** Download model + voice files. Use the source identified in D0.3.

  Run from repo root:
  ```bash
  mkdir -p Resources/Kokoro/voices
  # Source URLs come from D0.3 — typically Hugging Face hexgrad/Kokoro-82M
  # or FluidInference/kokoro-82m-coreml depending on which the Swift Package consumes.
  # Example (replace with actual URLs from D0.3):
  # curl -L -o Resources/Kokoro/kokoro-v1_0.mlpackage.tar https://...
  # tar xf Resources/Kokoro/kokoro-v1_0.mlpackage.tar -C Resources/Kokoro/
  # for v in af_heart af_bella af_nicole af_aoede am_michael am_puck bf_emma bm_george bm_fenrir; do
  #   curl -L -o Resources/Kokoro/voices/${v}.npy https://huggingface.co/hexgrad/Kokoro-82M/resolve/main/voices/${v}.pt
  # done
  ```

  Verify SHA256 hashes against D0.3.

  Expected: `du -sh Resources/Kokoro/` shows ~80 MB.

- [ ] **Step 2.4:** Commit license files.

  Create `Resources/Kokoro/LICENSE-Kokoro.txt` with the verbatim Apache 2.0 license text plus a header line:
  ```
  Kokoro-82M model weights — Apache License 2.0
  Source: https://huggingface.co/hexgrad/Kokoro-82M
  ```

  Create `Resources/Kokoro/LICENSE-mlalma.txt` with the verbatim MIT license text from `mlalma/kokoro-ios` plus a header line:
  ```
  kokoro-ios Swift Package — MIT License
  Source: https://github.com/mlalma/kokoro-ios
  ```

- [ ] **Step 2.5:** Wire `Resources/Kokoro/` into `project.pbxproj` as a **non-synchronized group**, following the `Theme/` and `KeeperTests/` pattern (per project memory: synchronized folders break manual `xcodeproj` gem operations; we want full manual control here).

  Edit `Keepur.xcodeproj/project.pbxproj`:

  1. **Add `PBXFileReference` entries** for the `.mlpackage` (as `wrapper`), each `.npy` voice (as `file.binary` or `file`), and the two LICENSE files (as `text`). Use stable random hex IDs (24-char uppercase) — generate once and reuse.

  2. **Add `PBXBuildFile` entries** for the `.mlpackage` and each `.npy` (these get into the Copy Bundle Resources phase). The two LICENSE files do **not** ship in the bundle — they go into the source tree only for license compliance and to be embedded into the credits screen at compile time.

  3. **Create a `PBXGroup`** for `Resources/Kokoro/voices/` (children: all `.npy` refs) and a parent group for `Resources/Kokoro/` (children: voices group, `kokoro-v1_0.mlpackage`, two LICENSE refs). Name = `Kokoro`, path = `Resources/Kokoro`, sourceTree = `"<group>"`.

  4. **Create a `PBXGroup`** for `Resources/` (child: Kokoro group). Name = `Resources`, path = `Resources`, sourceTree = `"<group>"`.

  5. **Add the `Resources` group to the root group's children list** (the root group is at `A1ABEBB82F79E16C009B0AFC` per the existing pbxproj at line 172).

  6. **Append the `.mlpackage` and each `.npy` build-file ref to the existing Resources build phase** (`A1ABEBBF2F79E16C009B0AFC /* Resources */`, referenced at pbxproj line 255). Find this phase's `files = (...)` block (alongside the existing `Assets.xcassets` and JetBrainsMono entries) and add new lines.

  7. **Do NOT add `Resources/Kokoro/` to `fileSystemSynchronizedGroups`** (line 261). That list stays as-is.

  This step is mechanically fiddly. Do it in Xcode's UI if practical: right-click the root → Add Files → select `Resources/Kokoro/` → "Create groups" (not folder reference) → check "Copy items if needed" off (files are already on disk) → check "Keepur" target. Verify the resulting pbxproj diff matches the structure above.

- [ ] **Step 2.6:** Verify bundle inclusion.

  Build for iOS Simulator (Cmd+B), then:
  ```bash
  BUILT=$(find ~/Library/Developer/Xcode/DerivedData -name "Keepur.app" -path "*Debug-iphonesimulator*" | head -1)
  ls "$BUILT/kokoro-v1_0.mlpackage" && ls "$BUILT/voices/" | head
  ```
  Expected: `.mlpackage` directory exists in the app bundle, `voices/` directory contains the curated `.npy` files.

- [ ] **Step 2.7:** Commit.

  ```bash
  git add .gitattributes Resources/Kokoro/ Keepur.xcodeproj/project.pbxproj
  git commit -m "feat: bundle Kokoro-82M weights and voice embeddings via Git LFS"
  ```

  Note IPA size impact in the commit body: run `du -sh Resources/Kokoro/` and record.

---

## Task 3: Define `TTSEngine` protocol + `SystemTTSEngine` wrapper

**Files:**
- Create: `Managers/TTSEngine.swift`

- [ ] **Step 3.1:** Define the protocol seam and the system implementation.

  Create `Managers/TTSEngine.swift`:

  ```swift
  import Foundation
  import AVFoundation

  /// Common surface for any text-to-speech engine. Implementations are owned by
  /// `SpeechManager` which dispatches based on the voice ID's prefix.
  @MainActor
  protocol TTSEngine: AnyObject {
      /// Speak `text` using `voiceId`. Throws if synthesis fails — the caller
      /// (SpeechManager) handles fallback. Implementations must update their
      /// own internal isSpeaking state.
      func speak(text: String, voiceId: String) async throws

      /// Stop any in-flight speech immediately.
      func stop()
  }

  /// Wraps `AVSpeechSynthesizer` behind the `TTSEngine` protocol. This is what
  /// SpeechManager uses for any voice ID that does NOT start with `kokoro:`.
  @MainActor
  final class SystemTTSEngine: NSObject, TTSEngine, AVSpeechSynthesizerDelegate {
      var onIsSpeakingChange: ((Bool) -> Void)?

      private let synthesizer = AVSpeechSynthesizer()

      override init() {
          super.init()
          synthesizer.delegate = self
      }

      func speak(text: String, voiceId: String) async throws {
          synthesizer.stopSpeaking(at: .immediate)

          #if os(iOS)
          let session = AVAudioSession.sharedInstance()
          try? session.setCategory(.playback, mode: .default)
          try? session.setActive(true)
          #endif

          let utterance = AVSpeechUtterance(string: text)
          utterance.rate = 0.52
          utterance.pitchMultiplier = 1.05
          utterance.voice = resolve(voiceId: voiceId)
          onIsSpeakingChange?(true)
          synthesizer.speak(utterance)
      }

      func stop() {
          synthesizer.stopSpeaking(at: .immediate)
          onIsSpeakingChange?(false)
      }

      // MARK: - Voice resolution

      private func resolve(voiceId: String) -> AVSpeechSynthesisVoice? {
          if let voice = AVSpeechSynthesisVoice(identifier: voiceId) {
              return voice
          }
          // Fall through to bestVoice() heuristic if the stored ID is no
          // longer installed (user removed an Enhanced voice in iOS Settings).
          return bestSystemVoice()
      }

      private func bestSystemVoice() -> AVSpeechSynthesisVoice? {
          let voices = AVSpeechSynthesisVoice.speechVoices()
              .filter { $0.language.lowercased().hasPrefix("en") }
          if let premium = voices.first(where: { $0.quality == .premium }) { return premium }
          if let enhanced = voices.first(where: { $0.quality == .enhanced }) { return enhanced }
          return AVSpeechSynthesisVoice(language: "en-US")
      }

      // MARK: - AVSpeechSynthesizerDelegate

      nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
          Task { @MainActor in self.onIsSpeakingChange?(false) }
      }

      nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
          Task { @MainActor in self.onIsSpeakingChange?(false) }
      }
  }
  ```

- [ ] **Step 3.2:** Build. The file should compile clean — no other code references it yet.

  Run: `xcodebuild -project Keepur.xcodeproj -scheme Keepur -destination 'platform=iOS Simulator,name=iPhone 16' build`
  Expected: BUILD SUCCEEDED.

- [ ] **Step 3.3:** Commit.

  ```bash
  git add Managers/TTSEngine.swift
  git commit -m "feat: introduce TTSEngine protocol and SystemTTSEngine wrapper"
  ```

---

## Task 4: Define `KokoroVoiceCatalog`

**Files:**
- Create: `Managers/KokoroVoiceCatalog.swift`
- Create: `KeeperTests/KokoroVoiceCatalogTests.swift`

- [ ] **Step 4.1:** Define the static catalog.

  Create `Managers/KokoroVoiceCatalog.swift`:

  ```swift
  import Foundation

  /// Curated English Kokoro voices exposed in the picker. Source of truth — both
  /// the picker UI and the engine pull from this list. Adding a voice requires:
  ///   1. Bundle the `.npy` file under `Resources/Kokoro/voices/<rawId>.npy`
  ///   2. Add it to `fileSystemSynchronizedGroups`-adjacent build phase (see plan Task 2)
  ///   3. Add an entry below
  ///
  /// IDs include the `kokoro:` prefix so they can be stored alongside
  /// AVSpeechSynthesisVoice identifiers in UserDefaults.
  enum KokoroVoiceCatalog {
      struct Voice: Equatable, Hashable {
          /// Stored ID — has the `kokoro:` prefix. e.g. `kokoro:af_heart`.
          let id: String
          /// Friendly name in the picker. e.g. `"Heart"`.
          let displayName: String
          /// Caption row under the name. e.g. `"American · Female · Warm"`.
          let description: String
          /// The raw voice key inside the `.npy` filename. e.g. `"af_heart"`.
          var rawId: String {
              String(id.dropFirst("kokoro:".count))
          }
      }

      /// Curated English shortlist. Re-confirm at implementation time against
      /// https://huggingface.co/hexgrad/Kokoro-82M/blob/main/VOICES.md
      /// Cut line: include all English voices graded B- or above.
      static let voices: [Voice] = [
          Voice(id: "kokoro:af_heart",   displayName: "Heart",   description: "American · Female · Warm"),
          Voice(id: "kokoro:af_bella",   displayName: "Bella",   description: "American · Female · Bright"),
          Voice(id: "kokoro:af_nicole",  displayName: "Nicole",  description: "American · Female · Soft"),
          Voice(id: "kokoro:af_aoede",   displayName: "Aoede",   description: "American · Female · Calm"),
          Voice(id: "kokoro:am_michael", displayName: "Michael", description: "American · Male · Deep"),
          Voice(id: "kokoro:am_puck",    displayName: "Puck",    description: "American · Male · Energetic"),
          Voice(id: "kokoro:bf_emma",    displayName: "Emma",    description: "British · Female · Refined"),
          Voice(id: "kokoro:bm_george",  displayName: "George",  description: "British · Male · Warm"),
          Voice(id: "kokoro:bm_fenrir",  displayName: "Fenrir",  description: "British · Male · Deep"),
      ]

      /// The default voice for fresh installs.
      static let defaultVoiceId = "kokoro:af_heart"

      /// Returns true iff `voiceId` is one our pickers can render. Orphan IDs
      /// (a stored ID that no longer matches the catalog) return false — the
      /// caller falls back to the system default.
      static func contains(_ voiceId: String) -> Bool {
          voices.contains(where: { $0.id == voiceId })
      }

      /// Lookup by full prefixed ID.
      static func voice(for voiceId: String) -> Voice? {
          voices.first(where: { $0.id == voiceId })
      }

      /// True iff the ID belongs to the Kokoro engine namespace (regardless of
      /// whether it matches a current catalog entry — a stale install might
      /// have a kokoro: ID we removed).
      static func isKokoroId(_ voiceId: String) -> Bool {
          voiceId.hasPrefix("kokoro:")
      }
  }
  ```

- [ ] **Step 4.2:** Add catalog tests.

  Create `KeeperTests/KokoroVoiceCatalogTests.swift`:

  ```swift
  import XCTest
  @testable import Keepur

  final class KokoroVoiceCatalogTests: XCTestCase {
      func testCatalogIsNonEmpty() {
          XCTAssertFalse(KokoroVoiceCatalog.voices.isEmpty)
      }

      func testEveryEntryHasRequiredFields() {
          for voice in KokoroVoiceCatalog.voices {
              XCTAssertTrue(voice.id.hasPrefix("kokoro:"), "ID must use kokoro: prefix: \(voice.id)")
              XCTAssertFalse(voice.displayName.isEmpty, "displayName empty for \(voice.id)")
              XCTAssertFalse(voice.description.isEmpty, "description empty for \(voice.id)")
              XCTAssertFalse(voice.rawId.isEmpty, "rawId empty for \(voice.id)")
              XCTAssertFalse(voice.rawId.contains(":"), "rawId must not contain prefix delimiter: \(voice.rawId)")
          }
      }

      func testIDsAreUnique() {
          let ids = KokoroVoiceCatalog.voices.map(\.id)
          XCTAssertEqual(ids.count, Set(ids).count)
      }

      func testDefaultVoiceIsInCatalog() {
          XCTAssertTrue(
              KokoroVoiceCatalog.contains(KokoroVoiceCatalog.defaultVoiceId),
              "defaultVoiceId must resolve via the catalog so the picker check-mark renders"
          )
      }

      func testIsKokoroIdRecognizesPrefix() {
          XCTAssertTrue(KokoroVoiceCatalog.isKokoroId("kokoro:af_heart"))
          XCTAssertTrue(KokoroVoiceCatalog.isKokoroId("kokoro:retired_voice"))
          XCTAssertFalse(KokoroVoiceCatalog.isKokoroId("com.apple.voice.compact.en-US.Samantha"))
          XCTAssertFalse(KokoroVoiceCatalog.isKokoroId(""))
      }

      func testRawIdStripsPrefix() {
          let voice = KokoroVoiceCatalog.Voice(
              id: "kokoro:af_heart", displayName: "Heart", description: "American · Female · Warm"
          )
          XCTAssertEqual(voice.rawId, "af_heart")
      }

      func testEveryCatalogVoiceHasBundledNpy() {
          // Sanity check: every catalog voice has a corresponding .npy in the bundle.
          for voice in KokoroVoiceCatalog.voices {
              let url = Bundle.main.url(forResource: voice.rawId, withExtension: "npy", subdirectory: "voices")
              XCTAssertNotNil(url, "Missing voice file: voices/\(voice.rawId).npy")
          }
      }
  }
  ```

- [ ] **Step 4.3:** Wire the catalog file into the Keepur target's source list. Since `Managers/` is a synchronized folder, the new file is auto-included — no pbxproj edit needed for the catalog source. The new test file goes into the manually-wired `KeeperTests` group (following Step 1.4's pattern).

- [ ] **Step 4.4:** Run tests.

  Run: `xcodebuild test -project Keepur.xcodeproj -scheme Keepur -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:KeeperTests/KokoroVoiceCatalogTests`
  Expected: 7 tests passed.

  Note: `testEveryCatalogVoiceHasBundledNpy` will fail until Task 2's `.npy` files are in the bundle — that's why Task 2 runs first.

- [ ] **Step 4.5:** Commit.

  ```bash
  git add Managers/KokoroVoiceCatalog.swift KeeperTests/KokoroVoiceCatalogTests.swift Keepur.xcodeproj/project.pbxproj
  git commit -m "feat: KokoroVoiceCatalog with curated English shortlist"
  ```

---

## Task 5: Implement `KokoroEngine`

**Files:**
- Create: `Managers/KokoroEngine.swift`

- [ ] **Step 5.1:** Implement the engine.

  Discovery from Task 0 informs three TODO points below — replace them with the actual API calls before the file compiles.

  Create `Managers/KokoroEngine.swift`:

  ```swift
  import Foundation
  import AVFoundation
  import KokoroSwift
  // import MLX  // confirm transitive import surface from D0.1

  /// Wraps `KokoroTTS` from mlalma/kokoro-ios. Owns the model lifecycle,
  /// caches voice embeddings, and plays synthesized PCM via AVAudioPlayer.
  ///
  /// Lifecycle: lazy. The first `speak()` call triggers model load. A
  /// `warmUp()` call from view code (e.g. ChatView.onAppear) primes the
  /// engine ahead of the user's first message.
  @MainActor
  final class KokoroEngine: TTSEngine {
      var onIsSpeakingChange: ((Bool) -> Void)?

      private var tts: KokoroTTS?
      private var voiceCache: [String: /* MLXArray */ AnyObject] = [:]
      private var player: AVAudioPlayer?
      private var loadTask: Task<KokoroTTS, Error>?

      // MARK: - Lifecycle

      /// Idempotent. Safe to call from multiple call sites; concurrent callers
      /// await the same load task.
      func warmUp() async throws {
          _ = try await loadEngineIfNeeded()
      }

      private func loadEngineIfNeeded() async throws -> KokoroTTS {
          if let tts { return tts }
          if let task = loadTask { return try await task.value }
          let task = Task<KokoroTTS, Error> {
              guard let modelURL = Bundle.main.url(forResource: "kokoro-v1_0", withExtension: "mlpackage") else {
                  throw KokoroEngineError.modelNotFound
              }
              // TODO[D0.1]: confirm KokoroTTS init signature — modelPath may need
              // to point at the .mlpackage directory or its parent.
              return KokoroTTS(modelPath: modelURL, g2p: .misaki)
          }
          loadTask = task
          let loaded = try await task.value
          tts = loaded
          return loaded
      }

      private func loadVoiceEmbedding(rawId: String) throws -> /* MLXArray */ AnyObject {
          if let cached = voiceCache[rawId] { return cached }
          guard let url = Bundle.main.url(forResource: rawId, withExtension: "npy", subdirectory: "voices") else {
              throw KokoroEngineError.voiceNotFound(rawId: rawId)
          }
          // TODO[D0.1]: load .npy → MLXArray using whatever the test app shows.
          // Likely something like:
          //     let data = try Data(contentsOf: url)
          //     let array = try MLXArray.fromNpy(data: data)
          //     voiceCache[rawId] = array
          //     return array
          fatalError("D0.1: implement .npy → MLXArray load")
      }

      // MARK: - TTSEngine

      func speak(text: String, voiceId: String) async throws {
          stop()

          guard let voice = KokoroVoiceCatalog.voice(for: voiceId) else {
              // Stored ID was a kokoro: ID we no longer ship. Caller will
              // catch and fall back to the system engine.
              throw KokoroEngineError.unknownVoice(voiceId: voiceId)
          }

          let engine = try await loadEngineIfNeeded()
          let embedding = try loadVoiceEmbedding(rawId: voice.rawId)

          // TODO[D0.1]: confirm signature and return type.
          //     let buffer = try engine.generateAudio(voice: embedding, language: .enUS, text: text)
          // Then convert `buffer` to a Data the player can consume. If the API
          // returns AVAudioPCMBuffer, we attach it to AVAudioEngine instead.
          // The simplest path for batch audio is to write a temp WAV file and
          // hand it to AVAudioPlayer.

          let wavURL = try await synthesizeToTempWav(engine: engine, embedding: embedding, text: text)
          try playWav(at: wavURL)
      }

      func stop() {
          player?.stop()
          player = nil
          onIsSpeakingChange?(false)
      }

      // MARK: - Audio plumbing

      private func synthesizeToTempWav(engine: KokoroTTS, embedding: AnyObject, text: String) async throws -> URL {
          // TODO[D0.1]: bridge `engine.generateAudio(...)` output → 16-bit PCM
          // WAV file at 24 kHz (Kokoro's documented rate). Place in
          // FileManager.default.temporaryDirectory with a unique name.
          fatalError("D0.1: implement audio buffer → temp WAV")
      }

      private func playWav(at url: URL) throws {
          #if os(iOS)
          let session = AVAudioSession.sharedInstance()
          try? session.setCategory(.playback, mode: .default)
          try? session.setActive(true)
          #endif

          let p = try AVAudioPlayer(contentsOf: url)
          p.delegate = AudioPlayerDelegateBridge { [weak self] in
              Task { @MainActor in self?.onIsSpeakingChange?(false) }
          }
          // Hold the delegate alive — AVAudioPlayer.delegate is a weak ref.
          objc_setAssociatedObject(p, &AudioPlayerDelegateBridge.assocKey, p.delegate, .OBJC_ASSOCIATION_RETAIN)
          player = p
          onIsSpeakingChange?(true)
          p.play()
      }
  }

  // MARK: - Errors

  enum KokoroEngineError: Error {
      case modelNotFound
      case voiceNotFound(rawId: String)
      case unknownVoice(voiceId: String)
      case synthesisFailed(underlying: Error)
  }

  // MARK: - AVAudioPlayer delegate bridge

  private final class AudioPlayerDelegateBridge: NSObject, AVAudioPlayerDelegate {
      static var assocKey: UInt8 = 0
      let onFinish: () -> Void
      init(onFinish: @escaping () -> Void) {
          self.onFinish = onFinish
      }
      func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
          onFinish()
      }
      func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
          onFinish()
      }
  }
  ```

- [ ] **Step 5.2:** Replace the three `TODO[D0.1]` markers using the answers from Task 0. Specifically:

  - **Engine init:** confirm `KokoroTTS(modelPath:g2p:)` signature — direct from D0.1.
  - **Voice load:** the test app's pattern for converting an `.npy` file to whatever the `voice:` parameter expects.
  - **Audio bridge:** the actual return type of `generateAudio(...)` and how to write it to a 24 kHz WAV file. If the package returns an `AVAudioPCMBuffer`, prefer playing it directly via `AVAudioEngine` + `AVAudioPlayerNode` and skip the temp file.

- [ ] **Step 5.3:** Build and confirm clean compile.

  Run: `xcodebuild -project Keepur.xcodeproj -scheme Keepur -destination 'platform=iOS Simulator,name=iPhone 16' build`
  Expected: BUILD SUCCEEDED.

- [ ] **Step 5.4:** Commit.

  ```bash
  git add Managers/KokoroEngine.swift
  git commit -m "feat: KokoroEngine adapter with lazy load and voice embedding cache"
  ```

---

## Task 6: Refactor `SpeechManager` to dispatch via `TTSEngine`

**Files:**
- Modify: `Managers/SpeechManager.swift`

- [ ] **Step 6.1:** Refactor SpeechManager to compose two engines and dispatch by prefix. Public surface preserved; internal engine path swapped.

  Replace the entire content of `Managers/SpeechManager.swift`. The recording / SFSpeechRecognizer half is unchanged — only the TTS half gets rewritten. The full updated file is included in the implementer's working copy of this plan; the diff outline:

  - Add stored `private let kokoroEngine: KokoroEngine` and `private let systemEngine: SystemTTSEngine` properties.
  - Add an `init(kokoro: KokoroEngine? = nil, system: SystemTTSEngine? = nil)` overload to support test injection. Default args produce real engines.
  - Hook `onIsSpeakingChange` callbacks on both engines to mirror state into `@Published var isSpeaking`.
  - Update the `selectedVoiceId` initial value: if `UserDefaults` has no value, default to `KokoroVoiceCatalog.defaultVoiceId`.
  - Rewrite `speak(_ text: String, agentId: String? = nil)` to:
    1. Resolve the voice ID (per-agent override falls back to global).
    2. If `KokoroVoiceCatalog.isKokoroId(id)`: try `kokoroEngine.speak(...)`; on throw, log + delegate to `systemEngine.speak(text:voiceId:)` using `bestSystemVoice().identifier`.
    3. Else: `systemEngine.speak(text:voiceId:)` directly.
  - Rewrite `speak(_ text: String, voice: AVSpeechSynthesisVoice)` to delegate to `systemEngine.speak(text:voiceId: voice.identifier)`. (Used by preview rows for system voices.)
  - Add `speak(_ text: String, kokoroVoiceId: String)` for preview rows in the new picker section.
  - Add `warmKokoroIfNeeded()` — calls `kokoroEngine.warmUp()` only if the currently selected voice (global or any per-agent) is a Kokoro ID. Fire-and-forget Task; swallows errors.
  - Replace `bestVoice()` with a delegation to `systemEngine`'s internal best voice (extract that helper into `TTSEngine.swift` as a static helper, or call through to `SystemTTSEngine`).
  - Drop the synthesizer / delegate code since it now lives in `SystemTTSEngine`.

  Implementation outline (preserves existing recording code; replaces only the TTS half):

  ```swift
  import Foundation
  import AVFoundation
  import Speech
  import Combine
  #if os(iOS)
  import UIKit
  #endif

  @MainActor
  final class SpeechManager: NSObject, ObservableObject {
      // --- Recording state (UNCHANGED — copy verbatim from current file) ---
      @Published var isRecording = false
      @Published var liveText: String = ""
      @Published var modelReady = false
      @Published var showMicPermissionAlert = false
      // (recording properties + methods unchanged)

      // --- TTS state ---
      @Published var isSpeaking = false
      @Published var selectedVoiceId: String? {
          didSet { UserDefaults.standard.set(selectedVoiceId, forKey: "selectedVoiceId") }
      }
      @Published var agentVoiceIds: [String: String] {
          didSet { UserDefaults.standard.set(agentVoiceIds, forKey: "agentVoiceIds") }
      }

      private let kokoroEngine: KokoroEngine
      private let systemEngine: SystemTTSEngine

      init(kokoroEngine: KokoroEngine? = nil, systemEngine: SystemTTSEngine? = nil) {
          self.kokoroEngine = kokoroEngine ?? KokoroEngine()
          self.systemEngine = systemEngine ?? SystemTTSEngine()

          // Default new installs to Kokoro; existing users keep their pick.
          if let stored = UserDefaults.standard.string(forKey: "selectedVoiceId") {
              self.selectedVoiceId = stored
          } else {
              self.selectedVoiceId = KokoroVoiceCatalog.defaultVoiceId
          }
          self.agentVoiceIds = (UserDefaults.standard.dictionary(forKey: "agentVoiceIds") as? [String: String]) ?? [:]
          super.init()

          // Mirror engine speaking state into our @Published.
          let mirror: (Bool) -> Void = { [weak self] in self?.isSpeaking = $0 }
          self.kokoroEngine.onIsSpeakingChange = mirror
          self.systemEngine.onIsSpeakingChange = mirror
      }

      // MARK: - TTS — dispatch

      func speak(_ text: String, agentId: String? = nil) {
          let voiceId = resolveVoiceId(agentId: agentId)
          Task {
              if KokoroVoiceCatalog.isKokoroId(voiceId) {
                  do {
                      try await kokoroEngine.speak(text: text, voiceId: voiceId)
                  } catch {
                      // Silent fallback per spec D7.
                      if let fallbackId = SystemTTSEngine.bestEnglishVoice()?.identifier {
                          try? await systemEngine.speak(text: text, voiceId: fallbackId)
                      }
                  }
              } else {
                  try? await systemEngine.speak(text: text, voiceId: voiceId)
              }
          }
      }

      /// Preview path used by SettingsView / AgentVoicePickerView system rows.
      func speak(_ text: String, voice: AVSpeechSynthesisVoice) {
          Task { try? await systemEngine.speak(text: text, voiceId: voice.identifier) }
      }

      /// Preview path used by the new Kokoro picker rows.
      func speak(_ text: String, kokoroVoiceId: String) {
          Task {
              do { try await kokoroEngine.speak(text: text, voiceId: kokoroVoiceId) }
              catch { /* picker preview fallback is silent */ }
          }
      }

      func stopSpeaking() {
          kokoroEngine.stop()
          systemEngine.stop()
      }

      /// Fire-and-forget. Warms the Kokoro engine if the selected voice (global
      /// or any per-agent override) is in the Kokoro namespace.
      func warmKokoroIfNeeded() {
          let usesKokoro = (selectedVoiceId.map(KokoroVoiceCatalog.isKokoroId) ?? false)
              || agentVoiceIds.values.contains(where: KokoroVoiceCatalog.isKokoroId)
          guard usesKokoro else { return }
          Task { try? await kokoroEngine.warmUp() }
      }

      // MARK: - Voice resolution

      private func resolveVoiceId(agentId: String?) -> String {
          if let agentId, let override = agentVoiceIds[agentId] {
              return override
          }
          if let id = selectedVoiceId { return id }
          // No selection at all (unusual after init's default-write) — pick a system voice.
          return SystemTTSEngine.bestEnglishVoice()?.identifier ?? "com.apple.voice.compact.en-US.Samantha"
      }

      func voiceForAgent(_ agentId: String?) -> AVSpeechSynthesisVoice? {
          guard let agentId, let voiceId = agentVoiceIds[agentId] else { return nil }
          return AVSpeechSynthesisVoice(identifier: voiceId)
      }

      func setVoice(_ voiceId: String?, forAgent agentId: String) {
          if let voiceId {
              agentVoiceIds[agentId] = voiceId
          } else {
              agentVoiceIds.removeValue(forKey: agentId)
          }
      }

      // MARK: - Recording (unchanged — copy from current file)
      // loadModel(), startRecording(), stopRecording(), cleanupRecording(), etc.
  }
  ```

  Promote `bestSystemVoice()` → `SystemTTSEngine.bestEnglishVoice()` as a `static func` so SpeechManager can call it without owning an instance.

- [ ] **Step 6.2:** Build and run the existing test suite to confirm no regression.

  Run: `xcodebuild test -project Keepur.xcodeproj -scheme Keepur -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:KeeperTests`
  Expected: all existing tests pass.

- [ ] **Step 6.3:** Commit.

  ```bash
  git add Managers/SpeechManager.swift Managers/TTSEngine.swift
  git commit -m "feat: SpeechManager dispatches by voice-ID prefix; new installs default to Kokoro"
  ```

---

## Task 7: `SpeechManager` dispatch tests

**Files:**
- Create: `KeeperTests/SpeechManagerDispatchTests.swift`

- [ ] **Step 7.1:** Add dispatch and fallback tests using injected mocks.

  Note: `KokoroEngine` and `SystemTTSEngine` are concrete types, not the protocol, in `SpeechManager`'s init. To make them mockable, switch the init signature to accept `TTSEngine` instances directly (still defaulting to the real types). Adjust Task 6's init signature accordingly:

  ```swift
  init(kokoroEngine: TTSEngine? = nil, systemEngine: TTSEngine? = nil)
  ```

  (And cast/store as `any TTSEngine`.) This keeps the production behavior identical and lets tests pass mock instances.

  Create `KeeperTests/SpeechManagerDispatchTests.swift`:

  ```swift
  import XCTest
  @testable import Keepur

  @MainActor
  final class SpeechManagerDispatchTests: XCTestCase {
      func testKokoroIdRoutesToKokoroEngine() async throws {
          let kokoro = MockTTSEngine()
          let system = MockTTSEngine()
          let mgr = SpeechManager(kokoroEngine: kokoro, systemEngine: system)
          mgr.selectedVoiceId = "kokoro:af_heart"

          mgr.speak("hello")
          try await Task.sleep(nanoseconds: 50_000_000)

          XCTAssertEqual(kokoro.spokenTexts, ["hello"])
          XCTAssertEqual(system.spokenTexts, [])
      }

      func testSystemIdRoutesToSystemEngine() async throws {
          let kokoro = MockTTSEngine()
          let system = MockTTSEngine()
          let mgr = SpeechManager(kokoroEngine: kokoro, systemEngine: system)
          mgr.selectedVoiceId = "com.apple.voice.compact.en-US.Samantha"

          mgr.speak("hello")
          try await Task.sleep(nanoseconds: 50_000_000)

          XCTAssertEqual(kokoro.spokenTexts, [])
          XCTAssertEqual(system.spokenTexts, ["hello"])
      }

      func testKokoroFailureFallsBackToSystem() async throws {
          let kokoro = MockTTSEngine()
          kokoro.shouldFail = true
          let system = MockTTSEngine()
          let mgr = SpeechManager(kokoroEngine: kokoro, systemEngine: system)
          mgr.selectedVoiceId = "kokoro:af_heart"

          mgr.speak("fallback please")
          try await Task.sleep(nanoseconds: 50_000_000)

          XCTAssertEqual(kokoro.spokenTexts, ["fallback please"])
          XCTAssertEqual(system.spokenTexts, ["fallback please"])
          // Stored ID is preserved on transient failure (per spec D7).
          XCTAssertEqual(mgr.selectedVoiceId, "kokoro:af_heart")
      }

      func testFreshInstallDefaultsToKokoro() async throws {
          // Wipe any prior selectedVoiceId set by another test in the same suite.
          UserDefaults.standard.removeObject(forKey: "selectedVoiceId")

          let mgr = SpeechManager(kokoroEngine: MockTTSEngine(), systemEngine: MockTTSEngine())

          XCTAssertEqual(mgr.selectedVoiceId, KokoroVoiceCatalog.defaultVoiceId)
      }

      func testExistingUserSelectionPreserved() async throws {
          UserDefaults.standard.set("com.apple.voice.compact.en-US.Samantha", forKey: "selectedVoiceId")
          defer { UserDefaults.standard.removeObject(forKey: "selectedVoiceId") }

          let mgr = SpeechManager(kokoroEngine: MockTTSEngine(), systemEngine: MockTTSEngine())

          XCTAssertEqual(mgr.selectedVoiceId, "com.apple.voice.compact.en-US.Samantha")
      }

      func testAgentOverrideWins() async throws {
          let kokoro = MockTTSEngine()
          let system = MockTTSEngine()
          let mgr = SpeechManager(kokoroEngine: kokoro, systemEngine: system)
          mgr.selectedVoiceId = "kokoro:af_heart"
          mgr.agentVoiceIds = ["agent-1": "com.apple.voice.compact.en-US.Samantha"]

          mgr.speak("hi", agentId: "agent-1")
          try await Task.sleep(nanoseconds: 50_000_000)

          XCTAssertEqual(kokoro.spokenTexts, [])
          XCTAssertEqual(system.spokenTexts, ["hi"])
      }
  }

  // MARK: - Mock

  @MainActor
  final class MockTTSEngine: TTSEngine {
      var onIsSpeakingChange: ((Bool) -> Void)?
      var spokenTexts: [String] = []
      var shouldFail = false

      func speak(text: String, voiceId: String) async throws {
          spokenTexts.append(text)
          if shouldFail { throw TestError.boom }
      }

      func stop() {}

      enum TestError: Error { case boom }
  }
  ```

- [ ] **Step 7.2:** Wire the new test file into the KeeperTests pbxproj group (manual references — same pattern as Task 1.4).

- [ ] **Step 7.3:** Run.

  Run: `xcodebuild test -project Keepur.xcodeproj -scheme Keepur -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:KeeperTests/SpeechManagerDispatchTests`
  Expected: 6 tests passed.

- [ ] **Step 7.4:** Commit.

  ```bash
  git add KeeperTests/SpeechManagerDispatchTests.swift Keepur.xcodeproj/project.pbxproj
  git commit -m "test: SpeechManager dispatch and fallback coverage"
  ```

---

## Task 8: Voice picker UI — `SettingsView` and `AgentVoicePickerView`

**Files:**
- Modify: `Views/SettingsView.swift`
- Modify: `Views/Team/AgentVoicePickerView.swift`

- [ ] **Step 8.1:** Update `SettingsView.voiceSection` to render two sections — Kokoro first, System below. Keep all existing system rows; do not filter or remove any.

  Replace the existing `voiceSection` computed property in `Views/SettingsView.swift` (currently lines 168–182) with:

  ```swift
  private var voiceSection: some View {
      VStack(alignment: .leading, spacing: KeepurTheme.Spacing.s4) {
          // Kokoro section (NEW, top)
          VStack(alignment: .leading, spacing: KeepurTheme.Spacing.s2) {
              eyebrowHeader("ON-DEVICE NEURAL")
              KeepurCard(bordered: true) {
                  VStack(spacing: 0) {
                      ForEach(Array(KokoroVoiceCatalog.voices.enumerated()), id: \.element.id) { index, voice in
                          kokoroVoiceRow(voice)
                          if index < KokoroVoiceCatalog.voices.count - 1 {
                              Divider()
                          }
                      }
                  }
              }
          }
          // System section (EXISTING, demoted)
          VStack(alignment: .leading, spacing: KeepurTheme.Spacing.s2) {
              eyebrowHeader("SYSTEM")
              KeepurCard(bordered: true) {
                  VStack(spacing: 0) {
                      ForEach(Array(englishVoices.enumerated()), id: \.element.identifier) { index, voice in
                          voiceRow(voice)
                          if index < englishVoices.count - 1 {
                              Divider()
                          }
                      }
                  }
              }
          }
      }
  }

  @ViewBuilder
  private func kokoroVoiceRow(_ voice: KokoroVoiceCatalog.Voice) -> some View {
      Button {
          viewModel.speechManager.selectedVoiceId = voice.id
          viewModel.speechManager.speak("Hello, I'm \(voice.displayName).", kokoroVoiceId: voice.id)
      } label: {
          HStack {
              VStack(alignment: .leading, spacing: 2) {
                  Text(voice.displayName)
                      .font(KeepurTheme.Font.body)
                      .foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)
                  Text(voice.description)
                      .font(KeepurTheme.Font.caption)
                      .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
              }
              Spacer()
              if viewModel.speechManager.selectedVoiceId == voice.id {
                  Image(systemName: KeepurTheme.Symbol.check)
                      .foregroundStyle(KeepurTheme.Color.honey500)
              }
          }
          .padding(.vertical, KeepurTheme.Spacing.s3)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
  }
  ```

  Leave `voiceRow(_ voice: AVSpeechSynthesisVoice)` and `qualityLabel(...)` unchanged.

  Note: per project memory `feedback_swiftui_body_perf.md`, the `body` must stay cheap. `KokoroVoiceCatalog.voices` is a static, no-allocation array — safe to read in `body`. `englishVoices` is already async-loaded into `@State`.

- [ ] **Step 8.2:** Update `Views/Team/AgentVoicePickerView.swift` similarly. Replace the single `Section { ForEach(voices) ... }` block (currently lines 48–55) with two sections:

  ```swift
  Section {
      ForEach(KokoroVoiceCatalog.voices, id: \.id) { voice in
          kokoroVoiceRow(voice)
              .listRowBackground(KeepurTheme.Color.bgSurfaceDynamic)
      }
  } header: {
      eyebrowHeader("ON-DEVICE NEURAL")
  }

  Section {
      ForEach(voices, id: \.identifier) { voice in
          voiceRow(voice)
              .listRowBackground(KeepurTheme.Color.bgSurfaceDynamic)
      }
  } header: {
      eyebrowHeader("SYSTEM")
  }
  ```

  Add the `kokoroVoiceRow` helper:

  ```swift
  @ViewBuilder
  private func kokoroVoiceRow(_ voice: KokoroVoiceCatalog.Voice) -> some View {
      Button {
          speechManager.setVoice(voice.id, forAgent: agent.id)
          speechManager.speak("Hello, I'm \(agent.name).", kokoroVoiceId: voice.id)
      } label: {
          HStack {
              VStack(alignment: .leading, spacing: 2) {
                  Text(voice.displayName)
                      .font(KeepurTheme.Font.body)
                      .foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)
                  Text(voice.description)
                      .font(KeepurTheme.Font.caption)
                      .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
              }
              Spacer()
              if selectedVoiceId == voice.id {
                  Image(systemName: KeepurTheme.Symbol.check)
                      .foregroundStyle(KeepurTheme.Color.honey500)
              }
          }
      }
  }
  ```

  Leave the "Use default" section, `voiceRow(_ voice: AVSpeechSynthesisVoice)`, and `qualityLabel(...)` unchanged.

- [ ] **Step 8.3:** Build for both platforms.

  Run iOS:
  ```bash
  xcodebuild -project Keepur.xcodeproj -scheme Keepur -destination 'platform=iOS Simulator,name=iPhone 16' build
  ```
  Run macOS:
  ```bash
  xcodebuild -project Keepur.xcodeproj -scheme Keepur -destination 'platform=macOS' build CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO
  ```
  (macOS flags per project memory `reference_xcode_scheme.md`.)
  Expected: both BUILD SUCCEEDED.

- [ ] **Step 8.4:** Commit.

  ```bash
  git add Views/SettingsView.swift Views/Team/AgentVoicePickerView.swift
  git commit -m "feat: voice pickers split into Kokoro and System sections"
  ```

---

## Task 9: Warm-up on chat open + license-attribution surface

**Files:**
- Modify: `Views/ChatView.swift`
- Modify: `Views/SettingsView.swift`

- [ ] **Step 9.1:** Trigger Kokoro warm-up when ChatView appears.

  Edit `Views/ChatView.swift` at the existing `.onAppear` block at line 159. Append the warm-up call:

  ```swift
  .onAppear {
      viewModel.autoReadAloud = autoReadAloud
      viewModel.speechManager.warmKokoroIfNeeded()
  }
  ```

  Rationale: this is the latest possible point before the user sends a message that produces speech. `warmKokoroIfNeeded()` is idempotent and bails immediately if no Kokoro voice is selected, so users on system voices pay zero cost.

- [ ] **Step 9.2:** Add a "Credits" entry to Settings footer for license attribution (per spec Risk 6).

  In `Views/SettingsView.swift`, modify `footerSection` to insert a Credits button before the existing Disconnect button:

  ```swift
  private var footerSection: some View {
      KeepurCard(bordered: true) {
          VStack(spacing: 0) {
              NavigationLink {
                  CreditsView()
              } label: {
                  HStack {
                      Text("Credits & Open Source")
                          .foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)
                      Spacer()
                      Image(systemName: "chevron.right")
                          .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
                          .font(KeepurTheme.Font.caption)
                  }
                  .padding(.vertical, KeepurTheme.Spacing.s3)
                  .contentShape(Rectangle())
              }
              .buttonStyle(.plain)

              Divider()

              // ... existing Disconnect / Unpair buttons unchanged
          }
      }
  }
  ```

  Add a `CreditsView` at the bottom of `SettingsView.swift` (or as a new file `Views/CreditsView.swift` if preferred — the synchronized `Views/` group will pick it up automatically):

  ```swift
  struct CreditsView: View {
      var body: some View {
          ScrollView {
              VStack(alignment: .leading, spacing: KeepurTheme.Spacing.s5) {
                  KeepurCard(bordered: true) {
                      VStack(alignment: .leading, spacing: KeepurTheme.Spacing.s3) {
                          Text("Kokoro-82M")
                              .font(KeepurTheme.Font.heading)
                              .foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)
                          Text("Apache License 2.0 — hexgrad/Kokoro-82M")
                              .font(KeepurTheme.Font.caption)
                              .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
                          if let url = Bundle.main.url(forResource: "LICENSE-Kokoro", withExtension: "txt"),
                             let text = try? String(contentsOf: url) {
                              Text(text)
                                  .font(.custom(KeepurTheme.FontName.mono, size: 11))
                                  .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
                          }
                      }
                  }

                  KeepurCard(bordered: true) {
                      VStack(alignment: .leading, spacing: KeepurTheme.Spacing.s3) {
                          Text("kokoro-ios Swift Package")
                              .font(KeepurTheme.Font.heading)
                              .foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)
                          Text("MIT License — mlalma/kokoro-ios")
                              .font(KeepurTheme.Font.caption)
                              .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
                          if let url = Bundle.main.url(forResource: "LICENSE-mlalma", withExtension: "txt"),
                             let text = try? String(contentsOf: url) {
                              Text(text)
                                  .font(.custom(KeepurTheme.FontName.mono, size: 11))
                                  .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
                          }
                      }
                  }
              }
              .padding(KeepurTheme.Spacing.s4)
          }
          .background(KeepurTheme.Color.bgPageDynamic)
          .navigationTitle("Credits")
          #if os(iOS)
          .navigationBarTitleDisplayMode(.inline)
          #endif
      }
  }
  ```

  For the LICENSE files to appear in `Bundle.main`, they must be in the Copy Bundle Resources phase — Task 2 step 2.5 already wired them. If you skipped them there as "source-tree only," add them to the build phase now.

- [ ] **Step 9.3:** Build + smoke (iOS sim launches, settings opens, credits entry visible, navigates).

- [ ] **Step 9.4:** Commit.

  ```bash
  git add Views/ChatView.swift Views/SettingsView.swift
  git commit -m "feat: warm Kokoro on chat open; add Credits screen for licenses"
  ```

---

## Task 10: Final verification + measurement

- [ ] **Step 10.1:** Run the full test suite on iOS Simulator.

  Run: `xcodebuild test -project Keepur.xcodeproj -scheme Keepur -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:KeeperTests`
  Expected: all tests green (no regressions in the existing 24 test files).

- [ ] **Step 10.2:** Run the full test suite on macOS.

  Run:
  ```bash
  xcodebuild test -project Keepur.xcodeproj -scheme Keepur -destination 'platform=macOS' \
    CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO -only-testing:KeeperTests
  ```
  Expected: all tests green.

- [ ] **Step 10.3:** Manual flows from the **Critical Flows** section above. Record results in the PR description.

- [ ] **Step 10.4:** Measure final IPA size impact.

  Run:
  ```bash
  xcodebuild -project Keepur.xcodeproj -scheme Keepur -destination 'generic/platform=iOS' \
    -archivePath /tmp/Keepur.xcarchive archive
  du -sh /tmp/Keepur.xcarchive/Products/Applications/Keepur.app
  ```
  Record the number in the PR body. Spec target: ~100 MB total binary growth. If it's >150 MB, flag for human review per spec Risk 1 (consider ODR re-evaluation).

- [ ] **Step 10.5:** Final commit if any cleanup remains. Otherwise the branch is ready for `dodi-dev:review` and PR.

---

## Risks at Implementation Time

1. **Task 0 discovery surprises** — if the Swift Package's API signature differs materially from what the README implies, Tasks 4–5 may need restructuring. Surface immediately.
2. **`.mlpackage` directory wiring in pbxproj** — `.mlpackage` is a directory bundle. Xcode normally treats it as a single file via `wrapper.application` / similar `lastKnownFileType`. The manual pbxproj entry must use the right `lastKnownFileType` (`wrapper.application` or empty for auto-detect). If Xcode mistreats it, fall back to wiring via the Xcode UI rather than hand-editing.
3. **Git LFS in CI** — there is no CI today, but local builds and any future CI need `git lfs install`. Document in CLAUDE.md after completion.
4. **macOS audio session** — `AVAudioSession` is iOS-only. The `KokoroEngine` audio path must `#if os(iOS)`-gate session setup; macOS plays via `AVAudioPlayer` directly without session setup. The included code already has this guard.
5. **MLX Swift on iOS 26** — if MLX init fails on iOS 26 simulator (newer than the package's tested range), capture the error in Task 0 and either pin the package to a known-good commit or pin MLX directly via SPM.

## Open Items to Resolve Pre-PR

- Final IPA size number recorded in the PR body.
- Confirmation that all 9 (or revised list) bundled `.npy` files are present in the built app bundle.
- Confirmation that fallback path was exercised at least once during manual testing (e.g. by temporarily renaming the bundled `.mlpackage`).
