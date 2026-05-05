# Keepur — Bundled Kokoro On-Device Neural TTS

**Date**: 2026-05-05
**Status**: Draft
**Ticket**: TBD (will be filed under the Keepur Linear org as KPR-*)

## Problem

`Managers/SpeechManager.swift` uses `AVSpeechSynthesizer` for TTS, picking the best installed system voice (`.premium` → `.enhanced` → default). Even on the premium tier, the system voices sound dated and robotic compared with modern neural TTS. Hosted alternatives (ElevenLabs, Google Chirp 3 / Gemini TTS) sound dramatically better but introduce per-utterance network calls, API key management, and recurring cost.

[Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M) is an Apache 2.0 licensed neural TTS model that runs on the Apple Neural Engine via MLX. At ~80 MB INT8, it fits in the app bundle and renders speech ~3.3× faster than realtime on iPhone 13 Pro. Quality is competitive with hosted models for English (best voices graded A / A-) while keeping all synthesis on-device — no network, no keys, no cost, no privacy concern.

This ticket bundles Kokoro as the default TTS engine for English while keeping every system voice (Apple's en-* voices, Mandarin, every other language Apple supports) available as a second-tier section in the picker.

## Scope

### In

1. Add `mlalma/kokoro-ios` as a Swift Package dependency.
2. Bundle the Kokoro-82M CoreML/MLX weight files (~80 MB) inside the app target.
3. Bundle the curated voice-style files (`.npy` per voice, ~1 KB each).
4. New `KokoroEngine` adapter inside `Managers/` that wraps the Swift Package's API.
5. Update `SpeechManager` to dispatch `speak(_:)` to either Kokoro or `AVSpeechSynthesizer` based on stored voice ID.
6. Update both voice pickers (`Views/SettingsView.swift` global default; `Views/Team/AgentVoicePickerView.swift` per-agent) to show the new "ON-DEVICE NEURAL" section above the existing "SYSTEM" section.
7. Default `selectedVoiceId` for fresh installs to a curated Kokoro voice.
8. Both platforms: iOS 26.2+ and macOS 15+ (one multi-platform scheme — both targets get the engine).

### Out

- Streaming / sentence-by-sentence chunking. Today `speak()` is called once per assistant message; that stays. Future work if first-byte latency on long replies becomes an issue.
- Mandarin / non-English Kokoro voices. Project-graded D across the board with only 1–10 hours of training data total. System voices win for these languages; users keep them via the System section.
- Voice cloning / Personal Voice integration.
- Hosted TTS (ElevenLabs, Google Chirp). Out of scope; on-device wins on cost / privacy / offline for a chat client.
- Replacing or removing `AVSpeechSynthesizer`. It stays — both as a fallback path and as the canonical engine for non-English voices.

## Design Decisions

### D1. Bundle weights, don't download

The Kokoro-82M INT8 weights total ~80 MB. We commit them to the repo (or to a Git LFS pointer) and ship them inside the app bundle.

**Rationale:** The cellular-download cap on App Store binaries was lifted years ago; an 80 MB increase is well-tolerated for a chat client. Downloading on first run requires backend hosting, retry/integrity logic, and creates a "model loading…" first-experience friction that undercuts the win. ODR is Apple's tag-gated download system but adds asset-catalog complexity for marginal binary savings. Bundling is the simplest correct choice and matches the "always works offline" property we want.

**Storage:** weights live under `Models/Kokoro/` in the source tree (alongside the existing SwiftData models, an unfortunate naming collision — see D8).

### D2. Engine: `mlalma/kokoro-ios` Swift Package

Both Kokoro Swift packages I evaluated (`mlalma/kokoro-ios`, `adriancmurray/kokoro-ios`) are MIT, target iOS 18+/macOS 15+, depend on MLX Swift + MisakiSwift (G2P) + MLXUtilsLibrary, and offer batch synthesis at ~3.3× realtime. Neither bundles weights. They are nearly identical — `adriancmurray/kokoro-ios` appears to be a near-fork of `mlalma/kokoro-ios`.

We pick **`mlalma/kokoro-ios`** because it has the slightly longer commit history and the cleaner README. If it goes unmaintained we can swap to the fork with minimal changes.

**Pinned version:** the latest tagged release at the time of implementation. If no semantic version tag exists, we pin to a specific commit SHA to keep the build reproducible.

**Transitive deps:** MLX Swift (Apple's ML framework) and MisakiSwift (grapheme-to-phoneme) — both add ~10–20 MB of framework code. Total IPA growth target: ~100 MB.

### D3. Voice ID namespacing — `kokoro:` prefix

`SpeechManager` already stores voice identifiers as `String`:

- `selectedVoiceId: String?` — global default
- `agentVoiceIds: [String: String]` — per-agent overrides

System voice IDs look like `com.apple.voice.compact.en-US.Samantha`. Kokoro voice IDs are short names like `af_heart`, `bm_george`. To dispatch on a single string, we namespace Kokoro IDs with a `kokoro:` prefix:

```
kokoro:af_heart       // Kokoro engine, voice `af_heart`
com.apple.voice....   // AVSpeechSynthesizer (no prefix, anything not starting with `kokoro:`)
```

**Rationale:** The string-storage shape of `UserDefaults` already in place doesn't change. Migrations are nil — existing users keep their stored Apple identifier; new installs get `kokoro:af_heart` written by D5's default.

### D4. Curated English voice shortlist

Kokoro ships ~50 voices total. Project-graded English voices range from F+ (`am_adam`) to A (`af_heart`). We expose only A / A- / B+ English voices to keep the picker scannable and ensure every choice is a quality win.

**Initial shortlist** (subject to confirmation against [VOICES.md](https://huggingface.co/hexgrad/Kokoro-82M/blob/main/VOICES.md) at implementation time):

| Voice ID | Display Name | Description | Grade |
|---|---|---|---|
| `kokoro:af_heart` | Heart | American · Female · Warm | A |
| `kokoro:af_bella` | Bella | American · Female · Bright | A- |
| `kokoro:af_nicole` | Nicole | American · Female · Soft | B- |
| `kokoro:af_aoede` | Aoede | American · Female · Calm | C+ |
| `kokoro:am_michael` | Michael | American · Male · Deep | C+ |
| `kokoro:am_puck` | Puck | American · Male · Energetic | C+ |
| `kokoro:bf_emma` | Emma | British · Female · Refined | B- |
| `kokoro:bm_george` | George | British · Male · Warm | B |
| `kokoro:bm_fenrir` | Fenrir | British · Male · Deep | C+ |

The actual cut line is "include all A / A- / B+ / B / B- English voices". The list above is illustrative — implementation reads the current grading and includes everything at B- or above.

The catalog lives as a static struct (`KokoroVoiceCatalog`) so it's a single place to add/remove/relabel voices without touching engine code. Orphan IDs (a stored ID that no longer matches a catalog entry) fall back to the engine default.

### D5. Default voice for new installs — `kokoro:af_heart`

Fresh install with no `selectedVoiceId` in `UserDefaults`: write `kokoro:af_heart`. If Kokoro engine fails to initialize on first speak (D7), fall back transparently to the existing system-voice resolution (`bestVoice()` in `SpeechManager.swift:244`) for that utterance, but do not overwrite the stored ID — the user might be on a device where Kokoro is temporarily unavailable (e.g. low memory) and we want it to retry on the next utterance.

**Existing users:** their `selectedVoiceId` already points at a system voice — that path keeps working unchanged. They opt into Kokoro by picking it in the Settings voice picker.

### D6. Picker layout — Kokoro section first, System section second

Both pickers (`SettingsView.voiceSection`, `AgentVoicePickerView.body`) gain a new section structure:

```
[ON-DEVICE NEURAL]   ← new, top
  Heart      American · Female · Warm
  Bella      American · Female · Bright
  ...

[SYSTEM]             ← existing rows, demoted
  Samantha   Premium
  Tingting   Enhanced (zh-CN)
  ...
```

Section headers use the existing `eyebrowHeader(_:)` helper. Row taps still preview the voice via `speechManager.speak(preview, voice: voice)` (system) or a new sibling `speak(preview, kokoroVoiceId:)` overload. Selection check uses the same identifier-equality logic as today.

### D7. Engine lifecycle — lazy load, warm on chat open, silent fallback

**Initialization:** `KokoroEngine` is lazy. We do not load the model at app start. The first call to `speak(text)` with a `kokoro:*` voice ID triggers async model load → cache. Subsequent calls reuse the loaded model.

**Warm-up:** When `ChatView` appears (or any view that's likely to trigger TTS soon), call `speechManager.warmKokoroIfNeeded()` — fire-and-forget async. This pays the load cost (~500 ms–1 s on iPhone 15) before the user hits send, so first-utterance feels instant.

**Failure mode:** If Kokoro engine fails to load (corrupt weights, MLX unavailable, OOM):
1. Log the error (no user-facing alert).
2. For the current utterance, fall back to `AVSpeechSynthesizer` using `bestVoice()`.
3. Do **not** clear the stored Kokoro voice ID. Future calls will retry initialization — failure can be transient.

This matches the spirit of the existing code: TTS is best-effort entertainment, not a critical path. Silent degradation beats a modal error.

### D8. File-system layout — avoid `Models/` collision

Existing source tree:

```
Models/
  Session.swift          ← SwiftData @Model
  Message.swift
  Workspace.swift
  WSMessage.swift
```

The CoreML weight files conventionally live in a folder named `Models/` too. To avoid confusion, we put the Kokoro assets in a separate top-level folder:

```
Resources/Kokoro/
  kokoro-v1_0.mlpackage       ← model weights
  voices/
    af_heart.npy
    af_bella.npy
    ...
```

`Resources/` is referenced by Xcode's project as a folder (Group with synchronized children, per the project convention recorded in memory). We add a build-phase rule to copy `*.mlpackage` and `voices/*.npy` into the app bundle.

### D9. Both platforms get Kokoro

The app uses a single `Keepur` multi-platform scheme. iOS and macOS are built from the same source. MLX Swift supports both Apple Silicon Macs (macOS 14+) and iOS devices with A12 / M1+ chips. Our deployment targets (iOS 26.2+, macOS 15+) easily satisfy this.

We do not gate Kokoro behind Apple-silicon checks for macOS — Intel Mac support was already unofficial in this project (no Rosetta path tested) and shipping Kokoro to Apple Silicon Macs only follows the project's existing direction.

### D10. Audio session handling

The current `speak` path sets `AVAudioSession` category to `.playback` before each system utterance (iOS only). The Kokoro path produces 24 kHz PCM audio that we play via `AVAudioPlayer` (or whatever the Swift Package returns — TBD at implementation; if it returns a `Data`/`Buffer` we wrap it in an `AVAudioPlayer`). Same audio session setup applies. macOS does not use `AVAudioSession`.

If the engine returns a non-finalised stream (some versions of MLX-Kokoro emit chunks), we prefer the simplest path — wait for the full utterance, then play. Streaming playback is a future optimization (covered by "Out of scope" — first-byte latency improvements).

## Risks

1. **Bundle size growth.** ~100 MB IPA increase. Mitigated by the cellular-cap removal and the chat-client UX expectation of "premium-feeling" apps. We measure final IPA size in the implementation phase and surface the number in the PR description.
2. **MLX Swift maturity on iOS 26.** MLX is newer than CoreML; possible compatibility wrinkles on the latest iOS major. Mitigation: pin the MLX dep to a known-good version; smoke test on iOS 26 simulator and a physical device early.
3. **Voice grading drift.** The Kokoro project occasionally re-grades voices as new training data lands. Our shortlist (D4) reads grades at implementation time and may need a periodic refresh. Acceptable — a follow-up is cheap.
4. **First-utterance latency.** Cold-start model load ~500 ms–1 s. Warm-up on `ChatView.onAppear` (D7) hides this. If users still notice, we can move warm-up earlier (app foreground) at the cost of always-on memory.
5. **Memory footprint.** 82 M params at INT8 ≈ 80 MB resident. On iPhone with 4–6 GB RAM this is fine; on the simulator it's negligible. We do not unload after speak — the warmup payoff disappears if we do.

## Testing Strategy

- **Unit:** `KokoroVoiceCatalog` data tests (catalog non-empty, each entry has display name + description, IDs prefix-correct). `SpeechManager.dispatch` tests confirming `kokoro:*` IDs route to `KokoroEngine` and other IDs route to `AVSpeechSynthesizer`. Use protocol seam to mock both engines.
- **Unit (fallback):** When `KokoroEngine.speak` throws, `SpeechManager` falls back to `bestVoice()` system path and the stored ID is preserved.
- **Smoke:** App launches, ChatView appears, warm-up fires, no crash. (Cannot assert audio output in tests.)
- **Manual:** Pick each Kokoro voice in Settings, hit preview, hear the right voice. Same for AgentVoicePickerView. Disconnect from network, send a message, hear assistant reply (proves on-device).
- **Manual cross-platform:** Same flow on macOS 15 build.

We follow the existing `View body must stay cheap` guideline (per project memory) — the picker rows compute display labels eagerly off the body path.

## Open Questions

None blocking implementation. Items deferred to implementation time:

- Exact pinned MLX version after evaluating compatibility on iOS 26.
- Final voice shortlist after re-checking VOICES.md.
- Whether the Swift Package returns audio as `Data` (use `AVAudioPlayer`) or as PCM samples (use `AVAudioEngine` / `AVAudioPlayerNode`). Affects the playback wrapper choice but not the broader design.

## References

- [hexgrad/Kokoro-82M model card](https://huggingface.co/hexgrad/Kokoro-82M)
- [VOICES.md (quality grades)](https://huggingface.co/hexgrad/Kokoro-82M/blob/main/VOICES.md)
- [mlalma/kokoro-ios Swift Package](https://github.com/mlalma/kokoro-ios)
- [FluidInference/kokoro-82m-coreml weights](https://huggingface.co/FluidInference/kokoro-82m-coreml)
- [MLX Swift](https://github.com/ml-explore/mlx-swift)
