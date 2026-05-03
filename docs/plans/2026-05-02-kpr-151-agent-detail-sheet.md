# KPR-151 — Agent Detail Half-Sheet (Implementation Plan)

**Date:** 2026-05-02
**Spec:** [docs/specs/2026-05-02-kpr-151-agent-detail-sheet.md](../specs/2026-05-02-kpr-151-agent-detail-sheet.md)
**Ticket:** [KPR-151](https://linear.app/keepur/issue/KPR-151)

## Strategy

Single-file rewrite of `Views/Team/AgentDetailSheet.swift` body + helpers, plus one new test file. All foundation components (`KeepurAvatar`, `KeepurStatusPill`, `KeepurMetricGrid`, `KeepurChipCluster`, `KeepurCard`) are already on the epic branch from KPR-144 and KPR-145 — no new components introduced.

`Views/` is a synchronized folder group, so editing the existing view file requires no Xcode project change. The new test file does need project wiring into `KeeperTests`.

Order of work:
1. Refactor helpers in `AgentDetailSheet.swift` (pure functions first — no UI yet — to make them unit-testable in isolation)
2. Rewrite `body` to consume the helpers + foundation components
3. Write tests against the helpers
4. Wire test file into Xcode project
5. Build + test on iOS and macOS

## Steps

### Step 1: Refactor `AgentDetailSheet.swift` helpers

**File:** `Views/Team/AgentDetailSheet.swift`

Replace the existing computed helpers (`statusColor`, `iconText`, `lastActivityDate`) with the spec's new helper set. Keep them `private` on the struct unless tests force promotion to `internal`.

New / rewritten helpers:

```swift
// Status string → semantic tint
private func statusTint(for status: String) -> KeepurStatusPill.Tint {
    switch status {
    case "idle":             return .success
    case "processing":       return .warning
    case "error", "stopped": return .danger
    default:                 return .muted
    }
}

// Status string → display text (title-cased)
private func statusDisplay(for status: String) -> String {
    status.prefix(1).uppercased() + status.dropFirst()
}

// ISO 8601 string → relative display ("2m ago" / "Never")
private func lastActiveDisplay(from iso: String?) -> String {
    guard let iso, let date = parseISO8601(iso) else { return "Never" }
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: date, relativeTo: Date())
}

private func parseISO8601(_ str: String) -> Date? {
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = iso.date(from: str) { return d }
    iso.formatOptions = [.withInternetDateTime]
    return iso.date(from: str)
}

// Agent → avatar content (emoji preferred, letter fallback, "?" final fallback)
private func headerAvatarContent(for agent: TeamAgentInfo) -> KeepurAvatar.Content {
    if !agent.icon.isEmpty {
        return .emoji(agent.icon)
    }
    if !agent.name.isEmpty {
        return .letter(agent.name)
    }
    return .letter("?")
}

// Display value for MODEL metric cell
private func modelDisplay(for agent: TeamAgentInfo) -> String {
    agent.model.isEmpty ? "—" : agent.model
}
```

Test access strategy: tests need to call these helpers. Easiest path is to make them `internal` (drop `private`) on the struct, then call as `AgentDetailSheet.statusTint(for:)` from tests via `@testable import Keepur`. Since they don't reference instance state, also mark them `static`.

**Verification:** file compiles with `xcodebuild ... build`; helpers are reachable as `AgentDetailSheet.statusTint(for:)` etc.

### Step 2: Rewrite `body`

Replace the existing `body` with the new structure. Preserve `var body: some View { NavigationStack { ScrollView { VStack(spacing: Spacing.s5) { ... } .padding(.horizontal) } .background(...).navigationTitle("Agent Info") } }` outer scaffolding. Inner sections become:

```swift
// Header
VStack(spacing: KeepurTheme.Spacing.s2) {
    KeepurAvatar(
        size: 60,
        content: AgentDetailSheet.headerAvatarContent(for: agent)
    )
    Text(agent.name)
        .font(KeepurTheme.Font.h2)
        .tracking(KeepurTheme.Font.lsH3)
        .foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)
    if let title = agent.title, !title.isEmpty {
        Text(title)
            .font(KeepurTheme.Font.bodySm)
            .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
    }
    KeepurStatusPill(
        AgentDetailSheet.statusDisplay(for: agent.status),
        tint: AgentDetailSheet.statusTint(for: agent.status)
    )
}
.padding(.top)

// Metric grid
KeepurMetricGrid([
    .init(label: "MODEL",       value: AgentDetailSheet.modelDisplay(for: agent)),
    .init(label: "MESSAGES",    value: "\(agent.messagesProcessed)"),
    .init(label: "LAST ACTIVE", value: AgentDetailSheet.lastActiveDisplay(from: agent.lastActivity)),
])

// Tools
if !agent.tools.isEmpty {
    eyebrowSection(title: "TOOLS") {
        KeepurChipCluster(agent.tools, maxVisible: 6)
    }
}

// Channels
if !agent.channels.isEmpty {
    eyebrowSection(title: "CHANNELS") {
        KeepurChipCluster(agent.channels.map { "#\($0)" }, maxVisible: 6)
    }
}

// Schedule
if !agent.schedule.isEmpty {
    eyebrowSection(title: "SCHEDULE") {
        VStack(alignment: .leading, spacing: KeepurTheme.Spacing.s2) {
            ForEach(Array(agent.schedule.enumerated()), id: \.offset) { _, entry in
                if let cron = entry["cron"], let task = entry["task"] {
                    HStack(alignment: .firstTextBaseline, spacing: KeepurTheme.Spacing.s2) {
                        cronChip(cron)
                        Text(task)
                            .font(KeepurTheme.Font.bodySm)
                            .foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)
                    }
                }
            }
        }
    }
}

// Voice (existing NavigationLink, wrapped in KeepurCard)
voiceSection
```

Two new private view helpers replace the old `sectionCard` / inline pill:

```swift
@ViewBuilder
private func eyebrowSection<Content: View>(
    title: String,
    @ViewBuilder content: () -> Content
) -> some View {
    VStack(alignment: .leading, spacing: KeepurTheme.Spacing.s2) {
        Text(title)
            .font(KeepurTheme.Font.eyebrow)
            .tracking(KeepurTheme.Font.lsEyebrow)
            .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
            .textCase(nil)
        content()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
}

private func cronChip(_ cron: String) -> some View {
    Text(cron)
        .font(.custom(KeepurTheme.FontName.mono, size: 12))
        .foregroundStyle(KeepurTheme.Color.fgSecondary)
        .padding(.horizontal, KeepurTheme.Spacing.s2)
        .padding(.vertical, KeepurTheme.Spacing.s1)
        .background(KeepurTheme.Color.wax100)
        .clipShape(RoundedRectangle(cornerRadius: KeepurTheme.Radius.xs))
}
```

Update `voiceSection`: wrap its inner `HStack { ... }` in `KeepurCard { ... }` instead of the inline `.background(...).clipShape(...)`. The `NavigationLink { AgentVoicePickerView(...) } label: { ... }` outer scaffold stays.

Delete the old helpers: `infoRow(label:value:)`, `infoRow(label:date:)`, `sectionCard(title:content:)`, `iconText`, `lastActivityDate` (computed Date), `statusColor` (replaced by `statusTint`).

**Verification:** file compiles; `xcodebuild` succeeds for iOS + macOS.

### Step 3: Create `KeeperTests/AgentDetailSheetTests.swift`

**File:** `KeeperTests/AgentDetailSheetTests.swift`

```swift
import XCTest
@testable import Keepur

final class AgentDetailSheetTests: XCTestCase {

    // MARK: statusTint

    func testStatusTintMapping() {
        XCTAssertEqual(AgentDetailSheet.statusTint(for: "idle"),       .success)
        XCTAssertEqual(AgentDetailSheet.statusTint(for: "processing"), .warning)
        XCTAssertEqual(AgentDetailSheet.statusTint(for: "error"),      .danger)
        XCTAssertEqual(AgentDetailSheet.statusTint(for: "stopped"),    .danger)
        XCTAssertEqual(AgentDetailSheet.statusTint(for: "unknown"),    .muted)
        XCTAssertEqual(AgentDetailSheet.statusTint(for: ""),           .muted)
    }

    // MARK: statusDisplay

    func testStatusDisplayTitleCases() {
        XCTAssertEqual(AgentDetailSheet.statusDisplay(for: "idle"),       "Idle")
        XCTAssertEqual(AgentDetailSheet.statusDisplay(for: "processing"), "Processing")
        XCTAssertEqual(AgentDetailSheet.statusDisplay(for: "error"),      "Error")
        XCTAssertEqual(AgentDetailSheet.statusDisplay(for: ""),           "")
    }

    // MARK: lastActiveDisplay

    func testLastActiveDisplayHandlesNilAndMalformed() {
        XCTAssertEqual(AgentDetailSheet.lastActiveDisplay(from: nil),         "Never")
        XCTAssertEqual(AgentDetailSheet.lastActiveDisplay(from: "garbage"),   "Never")
        XCTAssertEqual(AgentDetailSheet.lastActiveDisplay(from: ""),          "Never")
    }

    func testLastActiveDisplayParsesValidISO() {
        // Don't assert exact string ("2 min. ago" varies by locale + formatter version);
        // just assert it's non-empty and not the "Never" fallback.
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let recent = iso.string(from: Date().addingTimeInterval(-120))
        let result = AgentDetailSheet.lastActiveDisplay(from: recent)
        XCTAssertFalse(result.isEmpty)
        XCTAssertNotEqual(result, "Never")
    }

    func testLastActiveDisplayParsesISOWithoutFractionalSeconds() {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let recent = iso.string(from: Date().addingTimeInterval(-60))
        let result = AgentDetailSheet.lastActiveDisplay(from: recent)
        XCTAssertNotEqual(result, "Never")
    }

    // MARK: headerAvatarContent

    func testHeaderAvatarContentPrefersIconThenLetterThenQuestion() {
        let withIcon = makeAgent(icon: "🤖", name: "Coder")
        if case .emoji(let raw) = AgentDetailSheet.headerAvatarContent(for: withIcon) {
            XCTAssertEqual(raw, "🤖")
        } else {
            XCTFail("expected emoji content")
        }

        let withName = makeAgent(icon: "", name: "Coder")
        if case .letter(let raw) = AgentDetailSheet.headerAvatarContent(for: withName) {
            XCTAssertEqual(raw, "Coder")
        } else {
            XCTFail("expected letter content")
        }

        let bare = makeAgent(icon: "", name: "")
        if case .letter(let raw) = AgentDetailSheet.headerAvatarContent(for: bare) {
            XCTAssertEqual(raw, "?")
        } else {
            XCTFail("expected letter fallback")
        }
    }

    // MARK: modelDisplay

    func testModelDisplayEmDashWhenEmpty() {
        XCTAssertEqual(AgentDetailSheet.modelDisplay(for: makeAgent(model: "")),                "—")
        XCTAssertEqual(AgentDetailSheet.modelDisplay(for: makeAgent(model: "claude-sonnet-4")), "claude-sonnet-4")
    }

    // MARK: helpers

    private func makeAgent(
        icon: String = "🤖",
        name: String = "Test Agent",
        model: String = "claude-sonnet-4",
        status: String = "idle"
    ) -> TeamAgentInfo {
        TeamAgentInfo(
            id: "a1",
            name: name,
            icon: icon,
            title: nil,
            model: model,
            status: status,
            tools: [],
            schedule: [],
            channels: [],
            messagesProcessed: 0,
            lastActivity: nil
        )
    }
}
```

Note: `KeepurStatusPill.Tint` must be `Equatable` (or have synthesized conformance from being a plain enum) for `XCTAssertEqual` to work. From `KeepurStatusPill.swift` it's a plain case enum with no associated values — Swift synthesizes `Equatable` automatically. No code change needed.

**Verification:** file compiles inside test target.

### Step 4: Wire test file into Xcode project

`Views/` is a synchronized folder group — no edit for the rewritten view. `KeeperTests/` is wired explicitly per file (per the convention used by `KeepurFoundationDataDisplayTests.swift` and similar).

Use the `xcodeproj` Ruby gem (per the project convention from prior layer-1 tickets):

```ruby
require 'xcodeproj'
project = Xcodeproj::Project.open('Keepur.xcodeproj')
group_tests = project.main_group['KeeperTests']

ref = group_tests.new_reference('KeeperTests/AgentDetailSheetTests.swift')
project.targets.each do |t|
  next unless t.name.include?('Tests')
  t.source_build_phase.add_file_reference(ref)
end

project.save
```

**Verification:** `git diff Keepur.xcodeproj/project.pbxproj` shows the new test file reference added to test target source build phases.

### Step 5: Build verification (iOS + macOS)

Sequential builds (parallel iOS + macOS collide on SourcePackages — known issue from prior tickets):

```bash
xcodebuild -project Keepur.xcodeproj -scheme Keepur \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -quiet build

xcodebuild -project Keepur.xcodeproj -scheme Keepur \
  -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  -quiet build
```

**Verification:** both exit 0.

### Step 6: Run new tests + full suite

```bash
xcodebuild test -project Keepur.xcodeproj -scheme Keepur \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing KeeperTests/AgentDetailSheetTests \
  -quiet
```

Then full suite to confirm no regression:

```bash
xcodebuild test -project Keepur.xcodeproj -scheme Keepur \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -quiet
```

**Verification:** both exit 0; `AgentDetailSheetTests` shows 7 passes; total test count = previous + 7.

### Step 7: Commit

```
feat: agent detail sheet design v2 (KPR-151)

Rewrite AgentDetailSheet around foundation components:
- 60pt KeepurAvatar in header + KeepurStatusPill replacing inline dot
- KeepurMetricGrid (MODEL / MESSAGES / LAST ACTIVE) replacing 4-row info card
- KeepurChipCluster for Tools and Channels with +N overflow
- Mono cron pill chip + plain task label for schedule entries
- Voice section wrapped in KeepurCard

Pure helper logic extracted to static methods (statusTint, statusDisplay,
lastActiveDisplay, headerAvatarContent, modelDisplay) and covered by
AgentDetailSheetTests. Sheet detents already correctly configured at
TeamChatView call site — no change.

Closes KPR-151
```

## Test Groups

| Group | Coverage | File |
|---|---|---|
| **Unit (helpers)** | Status mapping, display formatting, ISO parsing fallbacks, avatar content selection, model em-dash | `KeeperTests/AgentDetailSheetTests.swift` |
| **Smoke (view body)** | N/A — `body` depends on `SpeechManager`, which is a `@MainActor ObservableObject` touching `AVSpeechSynthesizer`; per project conventions we don't smoke-test full View bodies depending on `@StateObject`/system services | — |
| **Integration** | N/A — call site (`TeamChatView`) unchanged | — |
| **E2E** | N/A — no test infrastructure for sheet presentation | — |

## Risks / Mitigations

| Risk | Mitigation |
|---|---|
| Helpers being `private` blocks tests | Promote to `static internal` (drop `private`); they're stateless utilities so no encapsulation loss |
| `KeepurStatusPill.Tint` not `Equatable` for `XCTAssertEqual` | It's a plain case enum — Swift auto-synthesizes `Equatable`. Confirmed by reading `KeepurStatusPill.swift` |
| `RelativeDateTimeFormatter` locale variance breaks string-equality tests | Tests assert non-empty + `!= "Never"` instead of exact string |
| `KeepurMetricGrid` truncating long model names mid-cell looks bad | Component is designed to truncate with `.tail`; mockup shows truncation as expected behavior. Acceptable |
| Project file (`project.pbxproj`) corrupted by `xcodeproj` gem | Run `git diff project.pbxproj` after script; revert if anything looks off |
| `AgentDetailSheet` is initialized with `let agent: TeamAgentInfo` (value type) — `static` helpers can't reach instance state, but they don't need to | Helpers are pure functions of their inputs; no instance reach needed |
| `eyebrowSection` and `cronChip` are instance methods (use `@ViewBuilder`); promoting to `static` would conflict with `@ViewBuilder`'s `Self` capture | Keep them as instance methods (still `private`); they're tested transitively via the body, not in isolation |
| Helpers conflict with future `KeepurStatusPill` extension on `String` | Helpers live as `static` methods on `AgentDetailSheet`, namespaced; no global pollution |

## Dependencies Check

- **Foundation components (epic branch):** `KeepurAvatar`, `KeepurStatusPill`, `KeepurMetricGrid`, `KeepurChipCluster`, `KeepurCard` — all confirmed present in `Theme/Components/`
- **Theme tokens:** `KeepurTheme.Font.{h2, bodySm, eyebrow}`, `KeepurTheme.Font.{lsH3, lsEyebrow}`, `KeepurTheme.FontName.mono`, `KeepurTheme.Color.{fgPrimaryDynamic, fgSecondaryDynamic, fgSecondary, wax100}`, `KeepurTheme.Spacing.{s1, s2, s5}`, `KeepurTheme.Radius.xs` — all confirmed present in `Theme/KeepurTheme.swift`
- **Model:** `TeamAgentInfo` (read-only consumption) — confirmed present in `Models/TeamWSMessage.swift`
- **Call site:** `Views/Team/TeamChatView.swift:78-83` already presents the sheet with `[.medium, .large]` detents — no change
- **Test target:** existing test files (`KeepurFoundationDataDisplayTests.swift` etc.) confirm `@testable import Keepur` pattern works with `static` helper access

## Human Signoff

Pre-approved per durable user delegation (KPR-142 design v2 epic). No human plan-review checkpoint required.
