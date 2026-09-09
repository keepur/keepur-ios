# KPR-445 Team-layer correctness Implementation Plan

> **For agentic workers:** Use dodi-dev:implement to execute this plan.

**Goal:** Reconcile Team history without losing legitimate repeats, correlate request ownership, retain runtime-owned rows during cleanup, and bound DM creation to ten seconds.

**Architecture:** Keep `TeamViewModel` as the main-actor coordinator and retain the private socket, current codecs and synchronous reporting helper. A Foundation-only `HistoryMerger` returns value changes; a thin `TeamStore` deletes unprotected messages without saving. Add only nullable `TeamMessage.serverId` to storage; history and DM request ownership remain in memory.

**Tech Stack:** Swift 5 language mode, SwiftUI/Combine, SwiftData, XCTest, the existing real `BeekeeperSocket` plus `FakeWebSocketTask`, Xcode 26.3.

**Authority:** Clean spec `docs/specs/2026-09-08-kpr-445-team-correctness-design.md` at `02918ad1a5f8f48bba427ad8111328f3fbfebf3b`; merged D `49c3423ddf3057e9ae2b893b23dee325fe545094`; Gate 1 delegation `21fb1443`; canon through D in `/Users/mokie/github/keepur-ios-epic-kpr-441/.dodi/current-canon-20260909.md`. Spec review 1 approved with no blockers. Its advisory requires A's channel → B creation → A's late system reply to suppress A without changing B's lock/deadline. This plan is a draft, not readiness or implementation approval.

**Execution directory:** `/Users/mokie/github/keepur-ios-mature-kpr445`. All repository-relative paths below resolve there; shell commands run there. Root owns commits/pushes during maturity. During implementation, the lane owns the task commits shown below. Do not execute production changes while reviewing this plan.

## Testing Contract

### Required Test Groups

- Unit: **required**
  - Scope: `HistoryMerger`, existing Team codecs and typed values.
  - Reason: canonical identity, deterministic matching and unknown-value preservation must be independent of persistence and socket scheduling.
  - Minimum assertions: known and legacy identity; reservation of an exact legacy row across the whole batch; duplicate IDs/overlap; agent/system/own pending and acknowledged one-to-one stamps; stable local content/date/type/thread; repeated distinct rows; exact channel/sender/text comparisons including delimiter collisions; closest/date/ID ties under shuffled inputs; strict 30-second edge; distant `now`; deterministic inserts; empty input and second-merge idempotence. Retain all existing codec/typed assertions.
- Integration: **required**
  - Scope: real SwiftData models/store/VM, real socket with fake transport, production pairing bindings and instance failure seams.
  - Reason: request races, queue ownership, persistence continuation and task lifetime cross these boundaries.
  - Harness: **existing plus setup required**. Add `TeamTestHarness`, focused suites and the standalone two-version migration runner below. Reuse `eventually`, fake credentials and fake transport. Never invent an invalid container to force a persistence error.
  - Minimum assertions: nil defaults; both IDs for inserted history; reopened stamps and legacy adoption; baseline five-model store survives migration and reconciliation without recovery deletion; both seed/full reply orders; loading/cursor/hasMore/preview ownership; empty, old, wrong-channel, duplicate and retired replies; reconnection fresh latest request; save/fetch failures; silent history; queue ownership despite unpending; foreign-hive exclusion; all three cleanup sites and later orphan sweep; direct/explicit switches with original bytes/order/channel and fresh IDs; command-map retirement with/without unacked messages; dynamically changed device ID through actual re-pair; DM rejection/lock/deadline/retry/response-before-list/list-before-response/two-successive-creation races/cancellation/deallocation; vanished/valid hive and attempt-1-only refresh; missing-row drop and rejected-send stop. Assertions in the 298-test D predecessor suite remain present.
- E2E: **not-required**
  - Scope: no changed screen, layout, live-service contract or wire format.
  - Reason: the affected end-to-end client paths are exercised through public VM actions, encoded outgoing IDs, decoded fake transport frames and persisted state. A paired external Hive/account would add deployment and timing dependencies without testing a new UI behavior.
  - Harness: **not-applicable**. Do not create a UI target or require a live service in this child.
  - Minimum assertions: integration coverage above is mandatory, including production `ContentView.bindPairingTeardown`.

### Critical Flows

- Live or own pending row → matching full history → same bubble ID with server identity → disconnect → original-hive resend still occurs until a real ack/reset.
- Inactive seed → select channel → seed and full reply in either order → full alone owns rows/loading/cursor; preview text/date stay paired.
- Hive A offline attachment and unacked text → real hive B channel-list deletion → return to A → ordered correct-channel payload survives.
- `/dm A` → A channel before A reply → `/dm B` → A late reply → B remains locked until its original success/deadline.
- Pre-E five-model on-disk store → E container → nil optional values without deletion → exact legacy/live/own reconciliation → reopened stable rows.

### Regression Surface

Retain all B/C/D assertions: private sockets; dynamic credentials; ordered Team and Chat queues; attachment retention; missing-row drop/rejected-send stop; four synchronous pairing origins and repeated reset; Chat FIFO, fallback and failed full-list fetch; lazy speech; decoded publication after handler; concierge matching/identity/cancellation; isolated approvals; server-authoritative watchdog; unknown and terminal typed state; persistence error identity and one-attempt continuation. Fixtures may adopt actual request IDs; do not remove assertions or relax counts to hide regressions. D's 298 passing CI cases are predecessor evidence, not E evidence.

### Commands

`Scripts/verify-kpr445.sh` is supplied in Task 1. Every invocation creates unique logs/results and runs serially against the approved shared derived-data directory. No other lane may use that directory concurrently.

- Unit: `bash Scripts/verify-kpr445.sh unit`
- Integration, history: `bash Scripts/verify-kpr445.sh history`
- Integration, cleanup: `bash Scripts/verify-kpr445.sh cleanup`
- Integration, DM/lifecycle: `bash Scripts/verify-kpr445.sh lifecycle`
- Integration, persisted models: `bash Scripts/verify-kpr445.sh models`
- Integration, two-version migration: `bash Scripts/verify-kpr445-migration.sh`
- Integration, additive baseline: `bash Scripts/verify-kpr445.sh retained`
- E2E: not required for the reason above; no UI command.
- Broader regression before PR: `bash Scripts/verify-kpr445.sh regression` and `bash Scripts/verify-kpr445.sh macos`
- Unexcluded iOS run when supported locally: `bash Scripts/verify-kpr445.sh full`; regardless of local coverage, full unexcluded GitHub workflow `Tests / Unit tests (iOS Simulator)` at the final reviewed PR head is mandatory before child merge.
- Static audit: Task 6's exact commands, then `git diff --check`.

### Harness Requirements

- Xcode 26.3, iOS 26.3.1 iPhone 17 simulator `ABAF19FA-8DE4-4EE1-B57E-DAA88C935FDE`; re-discover only if unavailable. iOS tests retain normal ad-hoc signing because the host uses Keychain. Scheme is nonparallel.
- `/tmp/keepur-kpr443-task3-dd` may be reused serially. Unique `mktemp` evidence directories prevent stale xcresult reuse.
- KPR-446 authorizes only the local twelve `CapabilityManagerTests` exclusion; full CI remains unexcluded. Do not expand the exclusion or treat host crashes as test passes. KPR-447/448 stay external.
- Disable context autosave for failure tests. Inject operation closures into the VM/store instance and route them through `fetchOrEmpty`/`saveReporting`; no globals or alternate catch/log policy.
- DM tests use short injected `Duration` values, receive latches and bounded eventual conditions; cancellation tests wait beyond the original short deadline. No ten-second sleeps.
- Migration runner compiles actual D and E model source into separate executables with the same module name. It opens the same isolated store directly with `ModelContainer`; it never links `KeepurApp`, deletes a failed store or catches container failure. Apple documents the explicit-URL configuration used here: [ModelConfiguration](https://developer.apple.com/documentation/swiftdata/modelconfiguration).

### Non-Required Rationale

- E2E: no new UI/service behavior; deterministic client integration covers the changed path. Unit and integration are required.

### Verification Rules

- Missing harness is not a skip reason; set it up or report a concrete blocker.
- If a test failure exposes an implementation issue, fix the implementation, not the assertion.
- If testing exposes a genuine spec mismatch, demote the ticket to the spec lane; do not improvise product behavior.
- Run focused tests before each task commit, then a local compliance/coverage/build audit. Implementer completes all tasks and records its audit before pre-PR review. The lane then performs pre-PR review, coverage/verify, opens the child PR, obtains full CI and final-head child-PR review. CI is **after PR creation**, never a prerequisite that makes PR creation impossible. Any later commit needs updated final-head review and CI.
- Follow `CLAUDE.md`'s actual targets/contracts where older generic `.claude/skills` examples say `KeepurTests`, require UI tests, ban predecessor codecs/view persistence or assume an iPhone 16. New architecture violations are still blocking.

## File map and interfaces

| File | Responsibility |
|---|---|
| `Models/TeamMessage.swift` | Add nullable nonunique server ID; preserve local row identity and stored String sender. |
| `Models/HistoryMerger.swift` | Immutable snapshots and pure deterministic insert/stamp/unpend calculation. |
| `Models/TeamStore.swift` | Synchronous protected channel deletion and failure-aware true-orphan sweep, no saves. |
| `Models/TeamChannel.swift` | Remove unused model title property. |
| `ViewModels/TeamViewModel.swift` | Apply merger; own full/seed request records, DM task and suppression IDs; retain delivery order and error ownership. |
| `KeeperTests/HistoryMergerTests.swift` | Pure algorithm results and replay coverage. |
| `KeeperTests/TeamMessagePersistenceTests.swift` | Real persisted IDs/defaults/reopen. |
| `KeeperTests/TeamTestHarness.swift` | Public-action/decoded-frame Team fixture with real SwiftData/socket. |
| `KeeperTests/TeamHistoryTests.swift` | Request ownership, cursor/preview, real merger and failure continuation. |
| `KeeperTests/TeamStoreTests.swift` | Real deletion and injected fetch-failure continuations. |
| `KeeperTests/TeamCleanupTests.swift` | Three VM removal paths, orphan sweep, foreign-hive delivery. |
| `KeeperTests/TeamDMLifecycleTests.swift` | DM lock/deadline/suppression/cancellation and hive refresh/command lifetime. |
| `KeeperTests/TeamViewModelTests.swift`, `KeeperTests/PairingTeardownTests.swift` | Additive predecessor fixture/assertion extensions. |
| `Scripts/verify-kpr445.sh` | Named signed simulator groups and macOS build. |
| `Scripts/verify-kpr445-migration.sh`, `Scripts/KPR445MigrationCheck.swift` | Reproducible baseline→E store migration, outside synchronized app/test folders. |
| `CLAUDE.md` | Document implemented E boundaries after source changes. |

`Models` and `KeeperTests` are already file-system-synchronized target groups. New Swift files there need no manual PBX build entries. Keep five container model members and the existing app recovery implementation unchanged. No `TeamWSMessage` wire changes.

## Task 1: Add canonical history values, optional storage and model verification

**Files:** Create `Models/HistoryMerger.swift`, `KeeperTests/HistoryMergerTests.swift`, `KeeperTests/TeamMessagePersistenceTests.swift`, the three `Scripts` files above. Modify `Models/TeamMessage.swift`.

- [ ] **Step 1:** Add `var serverId: String? = nil` immediately after `id`; add `serverId: String? = nil` after the initializer's `id` argument and `self.serverId = serverId` after `self.id = id`. No `@Attribute(.unique)` on server ID; all live callers retain their defaults.
- [ ] **Step 2:** Create the complete pure implementation:

```swift
import Foundation

struct TeamMessageSnapshot: Equatable {
    let id: String
    let serverId: String?
    let channelId: String
    let senderId: String
    let senderType: SenderType
    let senderName: String
    let text: String
    let threadId: String?
    let createdAt: Date
    let pending: Bool
}

struct MergeResult {
    let inserts: [TeamHistoryMessage]
    let serverIdStamps: [String: String]
    let unpendIds: Set<String>
}

enum HistoryMerger {
    static func chronological(_ lhs: TeamHistoryMessage, _ rhs: TeamHistoryMessage) -> Bool {
        lhs.createdAt == rhs.createdAt ? lhs.id < rhs.id : lhs.createdAt < rhs.createdAt
    }

    static func merge(existing: [TeamMessageSnapshot], incoming: [TeamHistoryMessage],
                      ownDeviceId: String, now: Date) -> MergeResult {
        // Call-time identity and clock are deliberately not additional match filters.
        _ = ownDeviceId
        _ = now
        var known = Set(existing.compactMap(\.serverId))
        let incomingIds = Set(incoming.map(\.id))
        let legacy = existing.filter { $0.serverId == nil && incomingIds.contains($0.id) }
        let reserved = Set(legacy.map(\.id))
        var consumed = Set<String>()
        var stamps: [String: String] = [:]
        var unpend = Set<String>()
        var inserts: [TeamHistoryMessage] = []
        for message in incoming.sorted(by: chronological) {
            guard !known.contains(message.id) else { continue }
            if let row = legacy.first(where: { $0.id == message.id }) {
                stamps[row.id] = message.id
                unpend.insert(row.id)
                consumed.insert(row.id)
            } else {
                let candidate = existing.filter {
                    $0.serverId == nil && !consumed.contains($0.id) && !reserved.contains($0.id)
                    && $0.channelId == message.channelId && $0.senderId == message.senderId
                    && $0.text == message.text
                    && abs($0.createdAt.timeIntervalSince(message.createdAt)) < 30
                }.min { lhs, rhs in
                    let l = abs(lhs.createdAt.timeIntervalSince(message.createdAt))
                    let r = abs(rhs.createdAt.timeIntervalSince(message.createdAt))
                    if l != r { return l < r }
                    if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
                    return lhs.id < rhs.id
                }
                if let row = candidate {
                    stamps[row.id] = message.id
                    unpend.insert(row.id)
                    consumed.insert(row.id)
                } else {
                    inserts.append(message)
                }
            }
            known.insert(message.id)
        }
        return MergeResult(inserts: inserts, serverIdStamps: stamps, unpendIds: unpend)
    }
}
```

- [ ] **Step 3:** Create `KeeperTests/HistoryMergerTests.swift`. The value-only apply helper is independent of the VM; replay assertions check public output, not implementation internals.

```swift
import XCTest
@testable import Keepur

@MainActor
final class HistoryMergerTests: XCTestCase {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    func local(_ id: String = "local", server: String? = nil, offset: Double = 0,
               channel: String = "c", sender: String = "agent", text: String = "same",
               pending: Bool = false, type: SenderType = .agent) -> TeamMessageSnapshot {
        TeamMessageSnapshot(id: id, serverId: server, channelId: channel, senderId: sender,
            senderType: type, senderName: "Local name", text: text, threadId: "local-thread",
            createdAt: date.addingTimeInterval(offset), pending: pending)
    }
    func history(_ id: String = "server", offset: Double = 0, channel: String = "c",
                 sender: String = "agent", text: String = "same",
                 type: SenderType = .agent) -> TeamHistoryMessage {
        TeamHistoryMessage(id: id, channelId: channel, senderId: sender, senderType: type,
            senderName: "Server name", text: text, createdAt: date.addingTimeInterval(offset),
            threadId: "server-thread")
    }
    func merge(_ local: [TeamMessageSnapshot], _ page: [TeamHistoryMessage],
               now: Date? = nil) -> MergeResult {
        HistoryMerger.merge(existing: local, incoming: page, ownDeviceId: "device", now: now ?? date)
    }
    func apply(_ result: MergeResult, to existing: [TeamMessageSnapshot]) -> [TeamMessageSnapshot] {
        existing.map { row in
            TeamMessageSnapshot(id: row.id, serverId: result.serverIdStamps[row.id] ?? row.serverId,
                channelId: row.channelId, senderId: row.senderId, senderType: row.senderType,
                senderName: row.senderName, text: row.text, threadId: row.threadId,
                createdAt: row.createdAt, pending: result.unpendIds.contains(row.id) ? false : row.pending)
        } + result.inserts.map {
            TeamMessageSnapshot(id: $0.id, serverId: $0.id, channelId: $0.channelId,
                senderId: $0.senderId, senderType: $0.senderType, senderName: $0.senderName,
                text: $0.text, threadId: $0.threadId, createdAt: $0.createdAt, pending: false)
        }
    }
    func assertReplay(_ rows: [TeamMessageSnapshot], _ page: [TeamHistoryMessage],
                      file: StaticString = #filePath, line: UInt = #line) {
        let next = merge(apply(merge(rows, page), to: rows), page)
        XCTAssertTrue(next.inserts.isEmpty, file: file, line: line)
        XCTAssertTrue(next.serverIdStamps.isEmpty, file: file, line: line)
        XCTAssertTrue(next.unpendIds.isEmpty, file: file, line: line)
    }
    func testKnownLegacyReservationAndOverlappingIds() {
        let rows = [local("known", server: "k"), local("z", pending: true)]
        let page = [history("z"), history("a", offset: -1), history("k"), history("a", offset: -1)]
        let result = merge(rows, page)
        XCTAssertEqual(result.inserts.map(\.id), ["a"])
        XCTAssertEqual(result.serverIdStamps, ["z": "z"])
        XCTAssertEqual(result.unpendIds, ["z"])
        assertReplay(rows, page)
        let overlap = merge(apply(result, to: rows), [history("a"), history("new")])
        XCTAssertEqual(overlap.inserts.map(\.id), ["new"])
        XCTAssertTrue(overlap.serverIdStamps.isEmpty)
    }
    func testAgentSystemAndOwnRowsStampWithoutChangingLocalFields() {
        for sender in ["agent", "system", "device"] {
            for pending in [false, true] {
                let row = local(sender: sender, pending: pending, type: .unknown("future-local"))
                let page = [history(sender: sender)]
                let result = merge([row], page)
                XCTAssertTrue(result.inserts.isEmpty)
                XCTAssertEqual(result.serverIdStamps, ["local": "server"])
                let applied = apply(result, to: [row])[0]
                XCTAssertEqual(applied.id, row.id); XCTAssertEqual(applied.createdAt, row.createdAt)
                XCTAssertEqual(applied.text, row.text); XCTAssertEqual(applied.threadId, row.threadId)
                XCTAssertEqual(applied.senderType, .unknown("future-local"))
                XCTAssertEqual(applied.senderName, "Local name"); XCTAssertFalse(applied.pending)
                assertReplay([row], page)
            }
        }
    }
    func testDistinctRepeatsConsumeEachLocalOnlyOnce() {
        let page = [history("b"), history("a")]
        XCTAssertEqual(merge([], page).inserts.map(\.id), ["a", "b"])
        let one = merge([local()], page)
        XCTAssertEqual(one.serverIdStamps, ["local": "a"])
        XCTAssertEqual(one.inserts.map(\.id), ["b"])
        let rows = [local("l2"), local("l1")]
        let two = merge(rows, page)
        XCTAssertEqual(two.serverIdStamps, ["l1": "a", "l2": "b"])
        XCTAssertTrue(two.inserts.isEmpty); assertReplay(rows, page)
        XCTAssertEqual(merge([local(server: "old")], page).inserts.count, 2)
    }
    func testFieldEqualityAndDelimiterCollision() {
        for row in [local(channel: "other"), local(sender: "other"), local(text: "different"),
                    local(sender: "a|b", text: "c")] {
            let page = row.senderId == "a|b" ? [history(sender: "a", text: "b|c")] : [history()]
            XCTAssertEqual(merge([row], page).inserts.count, 1)
        }
        XCTAssertEqual(merge([local(sender: "device-old")], [history(sender: "device")]).inserts.count, 1)
    }
    func testClosestDateAndLexicalTiesAreOrderIndependent() {
        let rows = [local("late", offset: 2), local("b", offset: -2), local("a", offset: -2),
                    local("far", offset: -10)]
        for candidates in [rows, Array(rows.reversed())] {
            XCTAssertEqual(merge(candidates, [history()]).serverIdStamps, ["a": "server"])
        }
        XCTAssertEqual(merge(rows + [local("closest", offset: 1)], [history()]).serverIdStamps,
                       ["closest": "server"])
        let page = [history("b", offset: 8), history("a", offset: -8)]
        XCTAssertEqual(merge([], page).inserts.map(\.id), merge([], Array(page.reversed())).inserts.map(\.id))
    }
    func testStrictWindowAndDistantNow() {
        for offset in [-30.0, 30.0, 30.001] {
            XCTAssertEqual(merge([local(offset: offset)], [history()]).inserts.count, 1)
        }
        for offset in [-29.999, 29.999] {
            let rows = [local(offset: offset)]
            XCTAssertEqual(merge(rows, [history()], now: .distantFuture).serverIdStamps, ["local": "server"])
            XCTAssertEqual(merge(rows, [history()], now: .distantPast).serverIdStamps, ["local": "server"])
        }
    }
    func testEmptyChronologicalAndUnknownThreadRetention() {
        XCTAssertTrue(merge([], []).inserts.isEmpty)
        XCTAssertTrue(merge([local()], []).serverIdStamps.isEmpty)
        let result = merge([], [history("z", offset: 2), history("b", type: .unknown("future")), history("a")])
        XCTAssertEqual(result.inserts.map(\.id), ["a", "b", "z"])
        XCTAssertEqual(result.inserts[1].senderType, .unknown("future"))
        XCTAssertEqual(result.inserts[1].threadId, "server-thread")
        assertReplay([], result.inserts)
    }
}
```

- [ ] **Step 4:** Create `KeeperTests/TeamMessagePersistenceTests.swift`:

```swift
import XCTest
import SwiftData
@testable import Keepur

@MainActor
final class TeamMessagePersistenceTests: XCTestCase {
    func testDefaultsHistoryIdentityAndReopenedStableStamp() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "messages.store")
        func open() throws -> ModelContainer {
            let schema = Schema([TeamChannel.self, TeamMessage.self])
            return try ModelContainer(for: schema, configurations: [
                ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
            ])
        }
        do {
            let container = try open(), context = ModelContext(container)
            let live = TeamMessage(id: "local", channelId: "c", senderId: "agent",
                                   senderType: "future", senderName: "A", text: "same", pending: true)
            XCTAssertNil(live.serverId)
            let inserted = TeamMessage(id: "history", serverId: "history", channelId: "c",
                senderId: "agent", senderType: "agent", senderName: "A", text: "older")
            context.insert(live); context.insert(inserted)
            live.serverId = "server"; live.pending = false
            try context.save()
        }
        do {
            let container = try open(), context = ModelContext(container)
            let rows = try context.fetch(FetchDescriptor<TeamMessage>())
            XCTAssertEqual(rows.count, 2)
            let live = try XCTUnwrap(rows.first { $0.id == "local" })
            XCTAssertEqual(live.serverId, "server"); XCTAssertFalse(live.pending)
            XCTAssertEqual(live.senderType, "future"); XCTAssertEqual(live.text, "same")
            XCTAssertEqual(rows.first { $0.id == "history" }?.serverId, "history")
        }
    }
}
```

- [ ] **Step 5:** Create `Scripts/verify-kpr445.sh` with this content. Run as `bash`; no executable-bit requirement.

```bash
#!/bin/bash
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
kpr445_group="${1:?required group}"
kpr445_evidence=$(mktemp -d "/tmp/keepur-kpr445-${kpr445_group}.XXXXXX")
kpr445_dd=/tmp/keepur-kpr443-task3-dd
kpr445_sim=ABAF19FA-8DE4-4EE1-B57E-DAA88C935FDE
xcodebuild -version > "$kpr445_evidence/toolchain.txt"
git rev-parse HEAD > "$kpr445_evidence/head.txt"
git diff --stat > "$kpr445_evidence/worktree.txt"
if [ "$kpr445_group" = macos ]; then
    xcodebuild build -project Keepur.xcodeproj -scheme Keepur \
        -destination 'platform=macOS,arch=arm64' -derivedDataPath "$kpr445_dd" \
        CODE_SIGNING_ALLOWED=NO 2>&1 | tee "$kpr445_evidence/build.log"
    exit 0
fi
kpr445_tests=()
case "$kpr445_group" in
    unit) kpr445_tests=(-only-testing:KeeperTests/HistoryMergerTests -only-testing:KeeperTests/TeamWSMessageTests -only-testing:KeeperTests/TypedStateTests) ;;
    models) kpr445_tests=(-only-testing:KeeperTests/TeamMessagePersistenceTests) ;;
    history) kpr445_tests=(-only-testing:KeeperTests/TeamHistoryTests -only-testing:KeeperTests/TeamViewModelTests) ;;
    cleanup) kpr445_tests=(-only-testing:KeeperTests/TeamStoreTests -only-testing:KeeperTests/TeamCleanupTests -only-testing:KeeperTests/PairingTeardownTests) ;;
    lifecycle) kpr445_tests=(-only-testing:KeeperTests/TeamDMLifecycleTests -only-testing:KeeperTests/PairingTeardownTests) ;;
    retained) kpr445_tests=(-only-testing:KeeperTests/TeamViewModelTests -only-testing:KeeperTests/PairingTeardownTests -only-testing:KeeperTests/PersistenceTests -only-testing:KeeperTests/ChatPersistenceTests -only-testing:KeeperTests/ChatViewModelTests -only-testing:KeeperTests/ChatResilienceTests -only-testing:KeeperTests/ChatViewModelSocketTests -only-testing:KeeperTests/ConciergeViewModelTests -only-testing:KeeperTests/BusyStateRecoveryTests -only-testing:KeeperTests/ContextClearedTests -only-testing:KeeperTests/SessionReplacedTests -only-testing:KeeperTests/TypedStateTests -only-testing:KeeperTests/TeamWSMessageTests) ;;
    regression) kpr445_tests=(-only-testing:KeeperTests -skip-testing:KeeperTests/CapabilityManagerTests) ;;
    full) kpr445_tests=(-only-testing:KeeperTests) ;;
    *) exit 64 ;;
esac
xcodebuild test -project Keepur.xcodeproj -scheme Keepur \
    -destination "platform=iOS Simulator,id=$kpr445_sim" -derivedDataPath "$kpr445_dd" \
    "${kpr445_tests[@]}" -resultBundlePath "$kpr445_evidence/Tests.xcresult" \
    2>&1 | tee "$kpr445_evidence/test.log"
xcrun xcresulttool get test-results summary --path "$kpr445_evidence/Tests.xcresult" \
    > "$kpr445_evidence/summary.json"
```

- [ ] **Step 6:** Create `Scripts/KPR445MigrationCheck.swift`. `PRE_E` compiles the same harness against the actual D model sources, with no `serverId` access in that binary. Each stage is a separate process, so reopen evidence is not an in-memory container artifact.

```swift
import Foundation
import SwiftData

@main
struct KPR445MigrationCheck {
    @MainActor static func main() throws {
        let mode = CommandLine.arguments[1]
        let url = URL(fileURLWithPath: CommandLine.arguments[2])
        let schema = Schema([Session.self, Message.self, Workspace.self, TeamChannel.self, TeamMessage.self])
        let container = try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        ])
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        if mode == "seed" {
            let initialRows = try context.fetch(FetchDescriptor<TeamMessage>())
            precondition(initialRows.isEmpty)
            context.insert(Session(id: "sentinel-session", path: "/fixture", createdAt: date))
            context.insert(Workspace(path: "/fixture", lastUsed: date))
            context.insert(Message(id: "sentinel-message", sessionId: "sentinel-session", text: "retained", role: "user", timestamp: date))
            context.insert(TeamChannel(id: "c", type: "future-channel", name: "Retained", members: ["device", "agent"], updatedAt: date))
            for (id, sender, pending) in [("own", "device", true), ("live", "agent", false), ("history", "system", false)] {
                context.insert(TeamMessage(id: id, channelId: "c", threadId: "thread", senderId: sender,
                    senderType: "future-sender", senderName: "Retained", text: id, createdAt: date, pending: pending))
            }
            try context.save()
            print("PRE_E_SEEDED three Team rows and five-model sentinels")
            return
        }
        let rows = try context.fetch(FetchDescriptor<TeamMessage>())
        let channels = try context.fetch(FetchDescriptor<TeamChannel>())
        let sessions = try context.fetch(FetchDescriptor<Session>())
        let messages = try context.fetch(FetchDescriptor<Message>())
        let workspaces = try context.fetch(FetchDescriptor<Workspace>())
        precondition(Set(rows.map(\.id)) == ["own", "live", "history"])
        precondition(channels.count == 1 && channels[0].id == "c" && channels[0].type == "future-channel")
        precondition(channels[0].members == ["device", "agent"] && channels[0].updatedAt == date)
        precondition(sessions.count == 1 && sessions[0].id == "sentinel-session")
        precondition(messages.count == 1 && messages[0].id == "sentinel-message" && messages[0].text == "retained")
        precondition(workspaces.count == 1 && workspaces[0].path == "/fixture")
        precondition(rows.allSatisfy { $0.senderType == "future-sender" && $0.createdAt == date && $0.threadId == "thread" && $0.text == $0.id })
        #if PRE_E
        precondition(mode == "baseline-reopen")
        print("PRE_E_REOPENED original rows intact")
        #else
        if mode == "migrate" {
            precondition(rows.allSatisfy { $0.serverId == nil })
            precondition(rows.first { $0.id == "own" }?.pending == true)
            let snapshots = rows.map { row in
                TeamMessageSnapshot(id: row.id, serverId: row.serverId, channelId: row.channelId,
                    senderId: row.senderId, senderType: row.typedSenderType, senderName: row.senderName,
                    text: row.text, threadId: row.threadId, createdAt: row.createdAt, pending: row.pending)
            }
            let page = rows.map { row in
                TeamHistoryMessage(id: row.id == "history" ? "history" : "server-" + row.id,
                    channelId: row.channelId, senderId: row.senderId, senderType: .unknown("future-wire"),
                    senderName: "Wire", text: row.text, createdAt: row.createdAt, threadId: nil)
            }
            let result = HistoryMerger.merge(existing: snapshots, incoming: page, ownDeviceId: "device", now: .now)
            precondition(result.inserts.isEmpty && result.serverIdStamps.count == 3)
            for row in rows {
                row.serverId = result.serverIdStamps[row.id]
                if result.unpendIds.contains(row.id) { row.pending = false }
            }
            try context.save()
            print("E_MIGRATED nil defaults, stable rows reconciled, no recovery path linked")
        } else {
            precondition(mode == "verify")
            precondition(rows.allSatisfy { $0.serverId == ($0.id == "history" ? "history" : "server-" + $0.id) && !$0.pending })
            print("E_REOPENED stable local IDs, stamps and five-model sentinels intact")
        }
        #endif
    }
}
```

- [ ] **Step 7:** Create `Scripts/verify-kpr445-migration.sh`:

```bash
#!/bin/bash
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
kpr445_base=49c3423ddf3057e9ae2b893b23dee325fe545094
kpr445_work=$(mktemp -d /tmp/keepur-kpr445-migration.XXXXXX)
mkdir "$kpr445_work/baseline"
kpr445_files=(Session Message Workspace TeamChannel TeamMessage MessageRole TeamWSMessage)
kpr445_old=()
kpr445_new=()
for kpr445_name in "${kpr445_files[@]}"; do
    git show "$kpr445_base:Models/$kpr445_name.swift" > "$kpr445_work/baseline/$kpr445_name.swift"
    kpr445_old+=("$kpr445_work/baseline/$kpr445_name.swift")
    kpr445_new+=("Models/$kpr445_name.swift")
done
xcrun swiftc -target arm64-apple-macos15.0 -swift-version 5 -parse-as-library -module-name KeepurMigration -D PRE_E \
    "${kpr445_old[@]}" Scripts/KPR445MigrationCheck.swift -o "$kpr445_work/pre-e" \
    2>&1 | tee "$kpr445_work/baseline-build.log"
xcrun swiftc -target arm64-apple-macos15.0 -swift-version 5 -parse-as-library -module-name KeepurMigration \
    "${kpr445_new[@]}" Models/HistoryMerger.swift Scripts/KPR445MigrationCheck.swift \
    -o "$kpr445_work/e" 2>&1 | tee "$kpr445_work/e-build.log"
"$kpr445_work/pre-e" seed "$kpr445_work/fixture.store" | tee "$kpr445_work/seed.log"
"$kpr445_work/pre-e" baseline-reopen "$kpr445_work/fixture.store" | tee "$kpr445_work/baseline-reopen.log"
"$kpr445_work/e" migrate "$kpr445_work/fixture.store" | tee "$kpr445_work/migrate.log"
"$kpr445_work/e" verify "$kpr445_work/fixture.store" | tee "$kpr445_work/reopen.log"
git rev-parse HEAD > "$kpr445_work/head.txt"
git diff -- Models > "$kpr445_work/models.diff"
```

Expected: four named success markers, zero exit status, all rows and sentinels retained. No production migration plan, model substitution or recovery deletion is permitted. A failed direct open blocks this task and requires investigating the additive change, not removing the fixture or changing production recovery. Keep the isolated evidence directory for review.

- [ ] **Step 8:** Resolve the existing package once with `xcodebuild -resolvePackageDependencies -project Keepur.xcodeproj -scheme Keepur` (expect MarkdownUI resolution to succeed). Run `bash Scripts/verify-kpr445.sh unit`, `bash Scripts/verify-kpr445.sh models`, `bash Scripts/verify-kpr445-migration.sh`, and `git diff --check`. Expect zero failures, nonzero discovered cases in each named test suite, and all migration markers. Then commit:

```bash
git add Models/TeamMessage.swift Models/HistoryMerger.swift KeeperTests/HistoryMergerTests.swift KeeperTests/TeamMessagePersistenceTests.swift Scripts/verify-kpr445.sh Scripts/verify-kpr445-migration.sh Scripts/KPR445MigrationCheck.swift
git commit -m "feat: reconcile Team history identities as pure values"
```

## Task 2: Correlate full-page and preview history; apply value reconciliation

**Files:** Modify `ViewModels/TeamViewModel.swift`, `KeeperTests/TeamViewModelTests.swift`. Create `KeeperTests/TeamTestHarness.swift`, `KeeperTests/TeamHistoryTests.swift`.

- [ ] **Step 1:** Add these private VM values near the pending request maps. No public socket or generic broker is introduced.

```swift
private struct RequestOwner: Equatable {
    let generation: UUID
    let hive: String
}
private struct HistoryRequest {
    let id: String
    let channelId: String
    let owner: RequestOwner
}
private var connectionGeneration = UUID()
private var activeHistoryRequest: HistoryRequest?
private var seedHistoryRequests: [String: HistoryRequest] = [:]

private var currentRequestOwner: RequestOwner? {
    guard connectionState == .connected, let hive = activeHive else { return nil }
    return RequestOwner(generation: connectionGeneration, hive: hive)
}
private func retireFullHistory() {
    activeHistoryRequest = nil
    isLoadingHistory = false
}
private func retireHistoryRequests() {
    retireFullHistory()
    seedHistoryRequests.removeAll()
}
private func retireHistoryRequests(channelId: String) {
    if activeHistoryRequest?.channelId == channelId { retireFullHistory() }
    seedHistoryRequests = seedHistoryRequests.filter { $0.value.channelId != channelId }
}
private func removedChannel(_ channelId: String) {
    retireHistoryRequests(channelId: channelId)
    if activeChannelId == channelId {
        activeChannelId = nil
        activeMessages = []
        isLoadingHistory = false
    }
}
```

- [ ] **Step 2:** At the start of `selectChannel`, before changing `activeChannelId`, call `retireFullHistory()`. Preserve its cursor-reset fetch and `hasMoreHistory = true`. Replace the old dedup comment with “Reset the selected channel to its latest page; history identities prevent repeat inserts.” Replace all of `fetchHistory` with:

```swift
func fetchHistory(channelId: String) {
    guard channelId == activeChannelId, activeHistoryRequest == nil,
          let owner = currentRequestOwner else { return }
    var before: String?
    if let context = modelContext {
        let cid = channelId
        let descriptor = FetchDescriptor<TeamChannel>(predicate: #Predicate { $0.id == cid })
        before = context.fetchOrEmpty(descriptor, "team.fetchHistory.fetch").first?.lastServerMessageId
    }
    guard let id = sendWithId(.history(channelId: channelId, before: before, limit: 50)) else {
        return
    }
    activeHistoryRequest = HistoryRequest(id: id, channelId: channelId, owner: owner)
    isLoadingHistory = true
}

private func seedHistory(channelId: String) {
    guard let owner = currentRequestOwner,
          let id = sendWithId(.history(channelId: channelId, before: nil, limit: 1)) else { return }
    seedHistoryRequests[id] = HistoryRequest(id: id, channelId: channelId, owner: owner)
}
```

There is no suspension between accepted send and registration. Socket frame delivery hops to a later main-actor turn. A direct `fetchHistory` for a nonselected channel is a no-op.

- [ ] **Step 3:** Wire retirement at every existing lifecycle boundary. In `previous == .connected && state != .connected`, immediately after `moveUnackedToOffline()`, add `retireHistoryRequests()` and `connectionGeneration = UUID()`. At explicit `disconnect()` entry and `onConnected()` entry add the same two lines, before existing bookkeeping. At actual hive change (`activeHive != channel`) inside `connectIfPossible`, add those lines immediately before `socket.connect(channel:)`; retain `activeHive = channel` **after** that call. This is idempotent and sends nothing in a state sink. In `.error`, add `retireFullHistory()` before existing banner handling. Task 4 consolidates these retirement lines with DM/command cleanup without changing their order.

- [ ] **Step 4:** Replace the channel-list seed `send(.history(...limit: 1))` with `seedHistory(channelId: info.id)`. Keep its active-channel skip. Change the `.history` switch binding to `case .history(let channelId, let messages, let hasMore, let id):` and call `receiveHistory(id: id, channelId: channelId, messages: messages, hasMore: hasMore, context: context)`. Replace the entire old history-dedup section with:

```swift
// MARK: - Private: Correlated History

private func receiveHistory(id: String, channelId: String, messages: [TeamHistoryMessage],
                            hasMore: Bool, context: ModelContext) {
    if let request = activeHistoryRequest, request.id == id {
        guard request.channelId == channelId, activeChannelId == channelId,
              request.owner == currentRequestOwner else {
            Log.team.debug("ignoring history with mismatched active ownership")
            return
        }
        retireFullHistory()
        self.hasMoreHistory = hasMore
        processHistory(channelId: channelId, messages: messages, context: context)
        return
    }
    if let request = seedHistoryRequests[id] {
        guard request.channelId == channelId, request.owner == currentRequestOwner else {
            Log.team.debug("ignoring history with mismatched preview ownership")
            return
        }
        seedHistoryRequests.removeValue(forKey: id)
        if let newest = messages.max(by: HistoryMerger.chronological) {
            updateChannelPreview(channelId: channelId, text: newest.text,
                                 date: newest.createdAt, context: context)
        }
        return
    }
    Log.team.debug("ignoring unregistered history response")
}

private func processHistory(channelId: String, messages: [TeamHistoryMessage], context: ModelContext) {
    let cid = channelId
    let channelDescriptor = FetchDescriptor<TeamChannel>(predicate: #Predicate { $0.id == cid })
    if let oldest = messages.min(by: HistoryMerger.chronological),
       let channel = context.fetchOrEmpty(channelDescriptor, "team.history.cursor.fetch").first {
        channel.lastServerMessageId = oldest.id
    }
    let descriptor = FetchDescriptor<TeamMessage>(predicate: #Predicate { $0.channelId == cid })
    let fetched = context.fetchOrEmpty(descriptor, "team.history.messages.fetch")
    let foreignIds = Set(offlineEntries.filter { $0.hive != activeHive }.map(\.localId))
    let rows = fetched.filter { !foreignIds.contains($0.id) }
    let snapshots = rows.map { row in
        TeamMessageSnapshot(id: row.id, serverId: row.serverId, channelId: row.channelId,
            senderId: row.senderId, senderType: row.typedSenderType, senderName: row.senderName,
            text: row.text, threadId: row.threadId, createdAt: row.createdAt, pending: row.pending)
    }
    let result = HistoryMerger.merge(existing: snapshots, incoming: messages,
                                     ownDeviceId: deviceId, now: .now)
    for row in rows {
        if let serverId = result.serverIdStamps[row.id] { row.serverId = serverId }
        if result.unpendIds.contains(row.id) { row.pending = false }
    }
    // Do not let a conflicting incoming local ID upsert a protected foreign row.
    for incoming in result.inserts where !foreignIds.contains(incoming.id) {
        context.insert(TeamMessage(id: incoming.id, serverId: incoming.id,
            channelId: incoming.channelId, threadId: incoming.threadId,
            senderId: incoming.senderId, senderType: incoming.senderType.wireValue,
            senderName: incoming.senderName, text: incoming.text,
            createdAt: incoming.createdAt, pending: false))
    }
    save(context, "team.history.save")
    if let newest = messages.max(by: HistoryMerger.chronological) {
        updateChannelPreview(channelId: channelId, text: newest.text,
                             date: newest.createdAt, context: context)
    }
    refreshActiveMessages()
}
```

`pendingMessageIds`, `offlineEntries` and attachment bytes are deliberately untouched by the merge. Capture `deviceId` and `.now` only once at the call. Keep the one channel-row fetch and one message fetch; helper failure retains the predecessor's empty-input continuation.

- [ ] **Step 5:** Replace `updateChannelPreview` with the complete paired-field version:

```swift
private func updateChannelPreview(channelId: String, text: String, date: Date = .now,
                                  context: ModelContext) {
    let cid = channelId
    let descriptor = FetchDescriptor<TeamChannel>(predicate: #Predicate { $0.id == cid })
    guard let channel = context.fetchOrEmpty(descriptor, "team.preview.fetch").first else { return }
    if let previous = channel.lastMessageAt, date < previous { return }
    channel.lastMessageText = String(text.prefix(100))
    channel.lastMessageAt = date
    save(context, "team.preview.save")
    channels.sort { ($0.lastMessageAt ?? .distantPast) > ($1.lastMessageAt ?? .distantPast) }
    recomputeSortedAgents()
}
```

- [ ] **Step 6:** Create `KeeperTests/TeamTestHarness.swift`. This fixture retains both VM and real socket only as separate references so Task 4 can release the VM during a sleep. UserDefaults restoration belongs in `close()`, not production code. New tests inject a harmless refresh operation in Task 4; until then connect-success tests never trigger capability refresh.

```swift
import XCTest
import SwiftData
@testable import Keepur

@MainActor
final class TeamTestHarness {
    let container: ModelContainer
    let context: ModelContext
    let credentials = FakeCredentialStore(deviceId: "device-old")
    let factory = FakeWebSocketTaskFactory()
    let capability = CapabilityManager()
    let socket: BeekeeperSocket
    var vm: TeamViewModel!
    let savedHive: String?
    var task: FakeWebSocketTask { factory.latest! }
    let date = Date(timeIntervalSince1970: 1_700_000_000)

    init(saveOperation: @escaping (ModelContext) throws -> Void = { try $0.save() }) throws {
        savedHive = UserDefaults.standard.string(forKey: "selectedHive")
        UserDefaults.standard.removeObject(forKey: "selectedHive")
        let schema = Schema([Session.self, Message.self, Workspace.self, TeamChannel.self, TeamMessage.self])
        container = try ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        context = ModelContext(container)
        context.autosaveEnabled = false
        let factory = self.factory
        socket = BeekeeperSocket(credentials: credentials, endpoint: { URL(string: "wss://unit.test")! },
                                 taskFactory: { factory.make(url: $0) })
        vm = TeamViewModel(socket: socket, credentials: credentials, lastErrorAutoClear: .seconds(30),
                           saveOperation: saveOperation)
        vm.configure(context: context, capabilityManager: capability)
        capability._setHivesForTesting(["hive-a", "hive-b"])
        capability.selectedHive = "hive-a"
    }
    func close() {
        factory.made.forEach { $0.onSend = nil }
        vm?.disconnect()
        socket.disconnect()
        vm = nil
        if let savedHive { UserDefaults.standard.set(savedHive, forKey: "selectedHive") }
        else { UserDefaults.standard.removeObject(forKey: "selectedHive") }
    }
    func begin(_ hive: String = "hive-a") {
        capability.selectedHive = hive
        vm.connectIfPossible()
    }
    func finish() async throws {
        let current = task
        try await eventually("handshake armed") { current.handshakeRequested }
        current.completeHandshake()
        try await eventually("Team connected and receiving") {
            self.vm.connectionState == .connected && current.receiveRequested
        }
    }
    func connect(_ hive: String = "hive-a") async throws { begin(hive); try await finish() }
    func receive(_ object: [String: Any], on selected: FakeWebSocketTask? = nil) async throws {
        let current = selected ?? task
        try await eventually("Team receive armed") { current.receiveRequested }
        let data = try JSONSerialization.data(withJSONObject: object)
        current.deliver(String(decoding: data, as: UTF8.self))
        try await eventually("Team receive rearmed after synchronous handler") { current.receiveRequested }
    }
    func frames(_ type: String? = nil, on selected: FakeWebSocketTask? = nil) throws -> [[String: Any]] {
        try (selected ?? task).sentTexts.map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }.filter { type == nil || $0["type"] as? String == type }
    }
    func request(_ channel: String, limit: Int = 50, on selected: FakeWebSocketTask? = nil) throws -> String {
        try XCTUnwrap(frames("history", on: selected).last {
            $0["channelId"] as? String == channel && $0["limit"] as? Int == limit
        }?["id"] as? String)
    }
    func list(_ ids: [String]) async throws {
        try await receive(["type": "channel_list", "id": UUID().uuidString,
            "channels": ids.map { ["id": $0, "type": "channel", "name": $0, "members": ["device-old"]] }])
    }
    func history(_ request: String, channel: String, rows: [[String: Any]], more: Bool = false) async throws {
        try await receive(["type": "history", "id": request, "channelId": channel, "messages": rows, "hasMore": more])
    }
    func wire(_ id: String, text: String = "same", sender: String = "agent",
              type: String = "agent", date: Date? = nil) -> [String: Any] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return ["id": id, "senderId": sender, "senderType": type, "senderName": "Wire",
                "text": text, "createdAt": formatter.string(from: date ?? self.date), "threadId": "wire-thread"]
    }
    func rows() throws -> [TeamMessage] { try context.fetch(FetchDescriptor<TeamMessage>()) }
    func channel(_ id: String) throws -> TeamChannel {
        try XCTUnwrap(context.fetch(FetchDescriptor<TeamChannel>()).first { $0.id == id })
    }
    @discardableResult
    func insert(_ id: String, channel: String = "c", text: String = "same", sender: String = "agent",
                pending: Bool = false, server: String? = nil, date: Date? = nil) throws -> TeamMessage {
        let row = TeamMessage(id: id, serverId: server, channelId: channel, threadId: "local-thread",
            senderId: sender, senderType: "future-local", senderName: "Local", text: text,
            createdAt: date ?? self.date, pending: pending)
        context.insert(row); try context.save()
        return row
    }
}
```

- [ ] **Step 7:** Create `KeeperTests/TeamHistoryTests.swift`:

```swift
import XCTest
import SwiftData
@testable import Keepur

@MainActor
final class TeamHistoryTests: XCTestCase {
    func testSeedAndFullBothOrdersKeepTheirOwnState() async throws {
        for seedFirst in [true, false] {
            let h = try TeamTestHarness(); defer { h.close() }
            try await h.connect(); try await h.list(["a", "b"])
            let seed = try h.request("a", limit: 1)
            h.vm.selectChannel("a")
            let full = try h.request("a")
            XCTAssertNotEqual(seed, full); XCTAssertTrue(h.vm.isLoadingHistory)
            let newest = h.wire("newest", text: "preview", date: h.date.addingTimeInterval(20))
            let page = [h.wire("oldest", text: "page"), h.wire("middle", text: "middle", date: h.date.addingTimeInterval(10))]
            if seedFirst {
                try await h.history(seed, channel: "a", rows: [newest], more: false)
                XCTAssertTrue(h.vm.isLoadingHistory); XCTAssertTrue(h.vm.hasMoreHistory)
                XCTAssertNil(try h.channel("a").lastServerMessageId); XCTAssertTrue(try h.rows().isEmpty)
            }
            try await h.history(full, channel: "a", rows: Array(page.reversed()), more: true)
            XCTAssertFalse(h.vm.isLoadingHistory); XCTAssertTrue(h.vm.hasMoreHistory)
            XCTAssertEqual(try h.channel("a").lastServerMessageId, "oldest")
            XCTAssertEqual(Set(try h.rows().map(\.id)), ["oldest", "middle"])
            if !seedFirst { try await h.history(seed, channel: "a", rows: [newest]) }
            XCTAssertEqual(try h.channel("a").lastMessageText, "preview")
            XCTAssertEqual(try h.channel("a").lastMessageAt, h.date.addingTimeInterval(20))
            XCTAssertNil(h.vm.lastLiveMessageId)
            XCTAssertFalse(h.vm.isLoadingHistory); XCTAssertTrue(h.vm.hasMoreHistory)
            XCTAssertEqual(try h.channel("a").lastServerMessageId, "oldest")
            XCTAssertEqual(try h.rows().count, 2)
        }
    }
    func testSelectionWrongChannelDuplicateAndRetiredResponses() async throws {
        let h = try TeamTestHarness(); defer { h.close() }
        try await h.connect(); try await h.list(["a", "b"])
        h.vm.selectChannel("a"); let old = try h.request("a")
        h.vm.selectChannel("b"); let current = try h.request("b")
        XCTAssertTrue(h.vm.isLoadingHistory)
        try await h.history(old, channel: "a", rows: [h.wire("old")])
        try await h.history(current, channel: "a", rows: [h.wire("wrong")])
        XCTAssertTrue(h.vm.isLoadingHistory); XCTAssertTrue(try h.rows().isEmpty)
        XCTAssertNil(try h.channel("a").lastMessageText)
        try await h.history(current, channel: "b", rows: [h.wire("valid")])
        XCTAssertFalse(h.vm.isLoadingHistory); XCTAssertEqual(try h.rows().map(\.id), ["valid"])
        try await h.history(current, channel: "b", rows: [h.wire("duplicate", text: "bad")], more: true)
        XCTAssertEqual(try h.rows().map(\.id), ["valid"]); XCTAssertFalse(h.vm.hasMoreHistory)
        XCTAssertEqual(try h.channel("b").lastMessageText, "same")
    }
    func testPreviewWrongChannelDoesNotConsumeSeed() async throws {
        let h = try TeamTestHarness(); defer { h.close() }
        try await h.connect(); try await h.list(["a", "b"])
        let seed = try h.request("a", limit: 1)
        try await h.history(seed, channel: "b", rows: [h.wire("wrong")])
        XCTAssertNil(try h.channel("a").lastMessageText); XCTAssertNil(try h.channel("b").lastMessageText)
        try await h.history(seed, channel: "a", rows: [h.wire("right", text: "right")])
        XCTAssertEqual(try h.channel("a").lastMessageText, "right"); XCTAssertTrue(try h.rows().isEmpty)
    }
    func testCursorOrderFullyDeduplicatedPageAndEmptyResponses() async throws {
        for reverse in [false, true] {
            let h = try TeamTestHarness(); defer { h.close() }
            try await h.connect(); try await h.list(["c", "seed"])
            h.vm.selectChannel("c")
            let page = [h.wire("b"), h.wire("a"), h.wire("z", date: h.date.addingTimeInterval(1))]
            try await h.history(h.request("c"), channel: "c", rows: reverse ? Array(page.reversed()) : page, more: true)
            XCTAssertEqual(try h.channel("c").lastServerMessageId, "a")
            XCTAssertEqual(try h.channel("c").lastMessageAt, h.date.addingTimeInterval(1))
            let channel = try h.channel("c")
            channel.lastServerMessageId = "stale"
            h.vm.fetchHistory(channelId: "c")
            XCTAssertEqual(try h.frames("history").last?["before"] as? String, "stale")
            try await h.history(h.request("c"), channel: "c", rows: page, more: true)
            XCTAssertEqual(try h.rows().count, 3); XCTAssertEqual(try h.channel("c").lastServerMessageId, "a")
            h.vm.fetchHistory(channelId: "c")
            try await h.history(h.request("c"), channel: "c", rows: [], more: false)
            XCTAssertFalse(h.vm.isLoadingHistory); XCTAssertFalse(h.vm.hasMoreHistory)
            XCTAssertEqual(try h.channel("c").lastServerMessageId, "a")
            try await h.history(h.request("seed", limit: 1), channel: "seed", rows: [])
            XCTAssertNil(try h.channel("seed").lastMessageText); XCTAssertNil(try h.channel("seed").lastMessageAt)
        }
    }
    func testOlderPreviewCannotReplaceLiveTextAndTruncatesTogether() async throws {
        let h = try TeamTestHarness(); defer { h.close() }
        try await h.connect(); try await h.list(["c"])
        let seed = try h.request("c", limit: 1)
        let liveText = String(repeating: "x", count: 120)
        try await h.receive(["type": "message", "channelId": "c", "agentId": "agent", "agentName": "A", "text": liveText])
        let timestamp = try XCTUnwrap(h.channel("c").lastMessageAt)
        h.vm.selectChannel("c")
        try await h.history(seed, channel: "c", rows: [h.wire("old-seed", text: "old seed")])
        try await h.history(h.request("c"), channel: "c", rows: [h.wire("old-page", text: "old page")])
        XCTAssertEqual(try h.channel("c").lastMessageText, String(repeating: "x", count: 100))
        XCTAssertEqual(try h.channel("c").lastMessageAt, timestamp)
    }
    func testOfflineMissingChannelErrorAndReconnectRetirement() async throws {
        let h = try TeamTestHarness(); defer { h.close() }
        h.vm.selectChannel("missing")
        XCTAssertFalse(h.vm.isLoadingHistory)
        try await h.connect()
        let first = try h.request("missing")
        XCTAssertNil(try h.frames("history").last?["before"])
        h.vm.fetchHistory(channelId: "other")
        XCTAssertEqual(try h.frames("history").count, 1)
        try await h.receive(["type": "error", "message": "server refused"])
        XCTAssertFalse(h.vm.isLoadingHistory); XCTAssertEqual(h.vm.lastError?.text, "server refused")
        try await h.history(first, channel: "missing", rows: [h.wire("late-error")])
        XCTAssertTrue(try h.rows().isEmpty)
        h.vm.fetchHistory(channelId: "missing")
        let second = try h.request("missing")
        h.vm.disconnect(); XCTAssertFalse(h.vm.isLoadingHistory)
        try await h.connect()
        let third = try h.request("missing")
        XCTAssertNotEqual(second, third); XCTAssertNil(try h.frames("history").last?["before"])
        try await h.history(second, channel: "missing", rows: [h.wire("late-connection")])
        XCTAssertTrue(h.vm.isLoadingHistory); XCTAssertTrue(try h.rows().isEmpty)
        try await h.history(third, channel: "missing", rows: [])
        XCTAssertFalse(h.vm.isLoadingHistory)
        try await h.connect("hive-b")
        try await h.history(third, channel: "missing", rows: [h.wire("late-hive")])
        XCTAssertTrue(try h.rows().isEmpty); XCTAssertTrue(h.vm.isLoadingHistory)
    }
    func testRealLiveOwnAndSystemMergeIsSilentAndKeepsUnackedOwnership() async throws {
        let h = try TeamTestHarness(); defer { h.close() }
        try await h.connect(); try await h.list(["c"]); h.vm.selectChannel("c")
        h.vm.sendMessage(text: "own")
        try await h.receive(["type": "message", "channelId": "c", "agentId": "agent", "agentName": "A", "text": "live"])
        try await h.receive(["type": "message", "agentId": "system", "agentName": "System", "text": "system"])
        let rows = try h.rows(), bubbleIds = Set(rows.map(\.id)), lastLive = h.vm.lastLiveMessageId
        XCTAssertEqual(rows.first { $0.text == "system" }?.senderType, "agent")
        let page = rows.map { h.wire("server-" + $0.text, text: $0.text, sender: $0.senderId, type: "future-wire", date: $0.createdAt) }
        try await h.history(h.request("c"), channel: "c", rows: page)
        XCTAssertEqual(Set(try h.rows().map(\.id)), bubbleIds)
        XCTAssertTrue(rows.allSatisfy { $0.serverId == "server-" + $0.text && !$0.pending })
        XCTAssertEqual(h.vm.pendingMessageRequestCountForTesting, 1)
        XCTAssertEqual(h.vm.lastLiveMessageId, lastLive); XCTAssertNil(h.vm.speechManager)
        h.vm.disconnect()
        XCTAssertEqual(h.vm.offlineEntries.count, 1)
        XCTAssertEqual(h.vm.offlineEntries[0].hive, "hive-a")
        try await h.connect()
        XCTAssertEqual(try h.frames("message").map { $0["text"] as? String }, ["own"])
    }
    func testHistorySaveFailureKeepsStampLoadingAndErrorIdentity() async throws {
        var fail = false
        let h = try TeamTestHarness(saveOperation: { context in
            if fail { throw NSError(domain: "HistorySave", code: 1) }
            try context.save()
        }); defer { h.close() }
        try await h.connect(); try await h.list(["c"]); h.vm.selectChannel("c")
        let local = try h.insert("local", pending: true)
        fail = true
        try await h.history(h.request("c"), channel: "c", rows: [h.wire("server")])
        XCTAssertEqual(local.serverId, "server"); XCTAssertFalse(local.pending)
        XCTAssertFalse(h.vm.isLoadingHistory); XCTAssertFalse(h.vm.hasMoreHistory)
        XCTAssertEqual(h.vm.lastError?.text, "Couldn't save. Your last change may not be kept.")
        let error = h.vm.lastError?.id
        fail = false; h.vm.fetchHistory(channelId: "c")
        try await h.history(h.request("c"), channel: "c", rows: [])
        XCTAssertEqual(h.vm.lastError?.id, error)
        h.vm.joinChannel(channelId: "not-found")
        XCTAssertEqual(h.vm.lastError?.id, error)
    }
}
```

- [ ] **Step 8:** Update the existing `testUnknownTeamKindsAndSendersPersistWithoutKnownTypeMembership` fixture only: replace its arbitrary `"id": "history"` with the actual encoded full request ID captured after `connectHive1()`:

```swift
let historyRequest = try XCTUnwrap(sentFrames(task).last {
    $0["type"] as? String == "history" && $0["channelId"] as? String == "channel-1"
        && $0["limit"] as? Int == 50
}?["id"] as? String)
```

Use `"id": historyRequest` in the reply. Keep the existing intentionally distant live row date, two incoming unknown-sender rows, all three-row/count/type/title/loading assertions. Update the assertion's explanation to “out-of-window unknown-sender history preserves distinct IDs and raw types.” No old assertion is removed.

- [ ] **Step 9:** Run `bash Scripts/verify-kpr445.sh history` and `bash Scripts/verify-kpr445.sh unit`. Expect all focused and predecessor Team/codec assertions passing; specifically nonzero `TeamHistoryTests` execution. Run `git diff --check`, then commit:

```bash
git add ViewModels/TeamViewModel.swift KeeperTests/TeamTestHarness.swift KeeperTests/TeamHistoryTests.swift KeeperTests/TeamViewModelTests.swift
git commit -m "fix: correlate Team history requests and preserve preview ownership"
```

## Task 3: Delete true channel orphans while preserving runtime delivery ownership

**Files:** Create `Models/TeamStore.swift`, `KeeperTests/TeamStoreTests.swift`, `KeeperTests/TeamCleanupTests.swift`. Modify `ViewModels/TeamViewModel.swift`, `KeeperTests/TeamTestHarness.swift`.

- [ ] **Step 1:** Create the thin store helper. Operation injection is local to the call and uses D's single catch/log helper; default operations directly fetch. The helper does not save or own queues/banner state.

```swift
import Foundation
import SwiftData

@MainActor
enum TeamStore {
    static func deleteChannel(_ channel: TeamChannel, in context: ModelContext,
                              protecting protectedIds: Set<String>,
                              fetchOperation: (ModelContext, FetchDescriptor<TeamMessage>) throws -> [TeamMessage] = { try $0.fetch($1) }) {
        let cid = channel.id
        let descriptor = FetchDescriptor<TeamMessage>(predicate: #Predicate { $0.channelId == cid })
        var failure: Error?
        let messages = context.fetchOrEmpty(descriptor, "team.deleteChannel.messages.fetch", failure: &failure,
                                           operation: { try fetchOperation(context, $0) })
        for message in messages where !protectedIds.contains(message.id) { context.delete(message) }
        context.delete(channel)
    }

    static func deleteOrphans(in context: ModelContext, validChannelIds: Set<String>,
                              protecting protectedIds: Set<String>,
                              fetchOperation: (ModelContext, FetchDescriptor<TeamMessage>) throws -> [TeamMessage] = { try $0.fetch($1) }) {
        var failure: Error?
        let messages = context.fetchOrEmpty(FetchDescriptor<TeamMessage>(), "team.orphans.messages.fetch",
            failure: &failure, operation: { try fetchOperation(context, $0) })
        guard failure == nil else { return }
        for message in messages where !validChannelIds.contains(message.channelId)
            && !protectedIds.contains(message.id) {
            context.delete(message)
        }
    }
}
```

- [ ] **Step 2:** Add these instance closure properties and defaulted initializer arguments to `TeamViewModel`, storing each argument in its property:

```swift
private let channelInventoryOperation: (ModelContext, FetchDescriptor<TeamChannel>) throws -> [TeamChannel]
private let cleanupMessageFetchOperation: (ModelContext, FetchDescriptor<TeamMessage>) throws -> [TeamMessage]
```

Append to the initializer after `saveOperation`:

```swift
channelInventoryOperation: @escaping (ModelContext, FetchDescriptor<TeamChannel>) throws -> [TeamChannel] = { try $0.fetch($1) },
cleanupMessageFetchOperation: @escaping (ModelContext, FetchDescriptor<TeamMessage>) throws -> [TeamMessage] = { try $0.fetch($1) }
```

Assignments are `self.channelInventoryOperation = channelInventoryOperation` and `self.cleanupMessageFetchOperation = cleanupMessageFetchOperation`. Add:

```swift
private var protectedMessageIds: Set<String> {
    Set(offlineEntries.map(\.localId)).union(pendingMessageIds.values)
}
```

Extend `TeamTestHarness.init` with identically typed/defaulted arguments and forward them to `TeamViewModel`. Existing call sites keep their behavior.

- [ ] **Step 3:** Replace `syncChannels` in full:

```swift
private func syncChannels(_ channelInfos: [TeamChannelInfo], context: ModelContext) {
    let serverIds = Set(channelInfos.map(\.id))
    let protectedIds = protectedMessageIds
    var inventoryFailure: Error?
    let descriptor = FetchDescriptor<TeamChannel>()
    let localChannels = context.fetchOrEmpty(descriptor, "team.syncChannels.fetch",
        failure: &inventoryFailure, operation: { try channelInventoryOperation(context, $0) })
    for local in localChannels where !serverIds.contains(local.id) {
        TeamStore.deleteChannel(local, in: context, protecting: protectedIds,
                                fetchOperation: cleanupMessageFetchOperation)
        removedChannel(local.id)
    }
    for info in channelInfos {
        if let existing = localChannels.first(where: { $0.id == info.id }) {
            existing.name = info.name
            existing.members = info.members
            existing.updatedAt = .now
        } else {
            context.insert(TeamChannel(id: info.id, type: info.type.wireValue,
                                       name: info.name, members: info.members))
        }
    }
    if inventoryFailure == nil {
        TeamStore.deleteOrphans(in: context, validChannelIds: serverIds, protecting: protectedIds,
                                fetchOperation: cleanupMessageFetchOperation)
    }
    save(context, "team.syncChannels.save")
    loadChannels(context: context)
    if let agentId = pendingAgentDM {
        if let dm = channels.first(where: { $0.kind == .dm && $0.members.contains(agentId) }) {
            pendingAgentDM = nil
            selectChannel(dm.id)
        } else if pendingDMRequestId == nil {
            pendingAgentDM = nil
        }
    }
}
```

Task 4 replaces the final DM block with attempt-scoped success; this task keeps predecessor behavior until the timer lands. Inventory failure still permits insertion/save/load; it never establishes that all existing rows are orphans.

- [ ] **Step 4:** In the found-channel `left` and `archived` branches of `handleChannelEvent`, replace `context.delete(channel)` with:

```swift
TeamStore.deleteChannel(channel, in: context, protecting: protectedMessageIds,
                        fetchOperation: cleanupMessageFetchOperation)
removedChannel(channel.id)
```

Keep each original save label and `loadChannels(context:)` after deletion. Remove the now-redundant inline `if activeChannelId == channelId` clear blocks. Do not move any of these actions outside the successful `.first` lookup; missing-channel events remain no-ops. Non-self `left`, joined and created behavior remains unchanged.

- [ ] **Step 5:** Create `KeeperTests/TeamStoreTests.swift`:

```swift
import XCTest
import SwiftData
@testable import Keepur

@MainActor
final class TeamStoreTests: XCTestCase {
    func testDeleteChannelProtectsIdsNotPendingAndDoesNotSave() throws {
        let h = try TeamTestHarness(); defer { h.close() }
        let channel = TeamChannel(id: "c", type: "channel", name: "C")
        h.context.insert(channel)
        try h.insert("unowned-pending", pending: true)
        try h.insert("owned-unpended", pending: false)
        try h.insert("other", channel: "other")
        TeamStore.deleteChannel(channel, in: h.context, protecting: ["owned-unpended"])
        XCTAssertTrue(h.context.hasChanges)
        try h.context.save()
        XCTAssertEqual(Set(try h.rows().map(\.id)), ["owned-unpended", "other"])
        XCTAssertTrue(try h.context.fetch(FetchDescriptor<TeamChannel>()).isEmpty)
    }
    func testDeletionFetchFailureStillDeletesChannelWithoutDeletingMessages() throws {
        let h = try TeamTestHarness(); defer { h.close() }
        let channel = TeamChannel(id: "c", type: "channel", name: "C")
        h.context.insert(channel); try h.insert("retained")
        var calls = 0
        TeamStore.deleteChannel(channel, in: h.context, protecting: [], fetchOperation: { _, _ in
            calls += 1; throw NSError(domain: "CleanupFetch", code: 1)
        })
        XCTAssertEqual(calls, 1); try h.context.save()
        XCTAssertEqual(try h.rows().map(\.id), ["retained"])
        XCTAssertTrue(try h.context.fetch(FetchDescriptor<TeamChannel>()).isEmpty)
        XCTAssertNil(h.vm.lastError)
    }
    func testOrphanSweepProtectsOnlyOwnedRowsAndFetchFailureDoesNothing() throws {
        let h = try TeamTestHarness(); defer { h.close() }
        try h.insert("valid", channel: "valid")
        try h.insert("orphan", pending: true)
        try h.insert("owned", pending: false)
        TeamStore.deleteOrphans(in: h.context, validChannelIds: ["valid"], protecting: ["owned"],
            fetchOperation: { _, _ in throw NSError(domain: "OrphanFetch", code: 2) })
        XCTAssertEqual(try h.rows().count, 3)
        TeamStore.deleteOrphans(in: h.context, validChannelIds: ["valid"], protecting: ["owned"])
        try h.context.save()
        XCTAssertEqual(Set(try h.rows().map(\.id)), ["valid", "owned"])
        TeamStore.deleteOrphans(in: h.context, validChannelIds: ["valid"], protecting: [])
        try h.context.save()
        XCTAssertEqual(try h.rows().map(\.id), ["valid"])
    }
}
```

- [ ] **Step 6:** Create `KeeperTests/TeamCleanupTests.swift`:

```swift
import XCTest
import SwiftData
@testable import Keepur

@MainActor
final class TeamCleanupTests: XCTestCase {
    func testEveryRemovalPathProtectsUnackedUnpendedRowsAndRetiresHistory() async throws {
        for removal in ["sync", "left", "archived"] {
            let h = try TeamTestHarness(); defer { h.close() }
            try await h.connect(); try await h.list(["c", "other"]); h.vm.selectChannel("c")
            let retired = try h.request("c")
            h.vm.sendMessage(text: "owned")
            let owned = try XCTUnwrap(h.rows().first { $0.text == "owned" })
            try await h.history(retired, channel: "c", rows: [h.wire("server-owned", text: "owned", sender: "device-old", date: owned.createdAt)])
            XCTAssertFalse(owned.pending); XCTAssertEqual(h.vm.pendingMessageRequestCountForTesting, 1)
            let ack = try XCTUnwrap(h.frames("message").last?["id"] as? String)
            try h.insert("unowned-pending", pending: true)
            try h.insert("unrelated", channel: "other")
            h.vm.fetchHistory(channelId: "c"); let oldFull = try h.request("c")
            let oldSeed = try h.request("c", limit: 1)
            if removal == "sync" { try await h.list(["other"]) }
            else {
                try await h.receive(["type": "channel_event", "channelId": "c", "event": removal,
                    "detail": ["memberId": "device-old"], "id": "event"])
            }
            XCTAssertNil(h.vm.activeChannelId); XCTAssertTrue(h.vm.activeMessages.isEmpty)
            XCTAssertFalse(h.vm.isLoadingHistory)
            XCTAssertEqual(Set(try h.rows().map(\.id)), [owned.id, "unrelated"])
            XCTAssertEqual(h.vm.channels.map(\.id), ["other"])
            try await h.history(oldFull, channel: "c", rows: [h.wire("late-full")])
            try await h.history(oldSeed, channel: "c", rows: [h.wire("late-seed")])
            XCTAssertEqual(try h.rows().count, 2)
            try await h.receive(["type": "ack", "id": ack])
            XCTAssertEqual(try h.rows().count, 2, "ack alone does not prune orphan history")
            try await h.list(["other"])
            XCTAssertEqual(try h.rows().map(\.id), ["unrelated"])
        }
    }
    func testForeignHiveCleanupPreservesAttachmentAndUnackedTextInOrder() async throws {
        let h = try TeamTestHarness(); defer { h.close() }
        h.context.insert(TeamChannel(id: "a-channel", type: "channel", name: "A"))
        try h.context.save(); h.vm.activeChannelId = "a-channel"
        h.begin()
        let bytes = Data([4, 5, 6])
        h.vm.pendingAttachment = AttachmentData(data: bytes, name: "keep.bin", mimeType: "application/octet-stream")
        h.vm.sendMessage(text: "first")
        let firstRow = try XCTUnwrap(h.rows().first)
        h.begin("hive-b"); try await h.finish()
        try await h.list(["b-channel"])
        XCTAssertEqual(h.vm.offlineEntries, [.init(localId: firstRow.id, hive: "hive-a")])
        XCTAssertEqual(h.vm.queuedAttachmentCountForTesting, 1)
        XCTAssertEqual(try h.rows().map(\.id), [firstRow.id])
        XCTAssertTrue(try h.frames().filter { ["message", "image", "file"].contains($0["type"] as? String ?? "") }.isEmpty)
        try await h.connect()
        let returnA = h.task
        XCTAssertEqual(try h.frames().suffix(2).compactMap { $0["type"] as? String }, ["message", "file"])
        XCTAssertEqual(try h.frames("file").last?["data"] as? String, bytes.base64EncodedString())
        XCTAssertEqual(try h.frames("file").last?["channelId"] as? String, "a-channel")
        let firstRequest = try XCTUnwrap(h.frames("message").last?["id"] as? String)
        try await h.list(["a-channel"]); h.vm.selectChannel("a-channel")
        h.vm.sendMessage(text: "second")
        let secondRow = try XCTUnwrap(h.rows().first { $0.text == "second" })
        XCTAssertGreaterThanOrEqual(secondRow.createdAt, firstRow.createdAt)
        try await h.history(h.request("a-channel"), channel: "a-channel", rows: [
            h.wire("server-first", text: "first", sender: "device-old", date: firstRow.createdAt)
        ])
        XCTAssertFalse(firstRow.pending)
        try await h.connect("hive-b") // connected switch: socket must emit goingAway, not manual normal close.
        XCTAssertEqual(returnA.lastCloseCode, .goingAway)
        try await h.list(["b-channel"])
        XCTAssertEqual(h.vm.offlineMessageIds, [firstRow.id, secondRow.id])
        XCTAssertTrue(h.vm.offlineEntries.allSatisfy { $0.hive == "hive-a" })
        XCTAssertEqual(Set(try h.rows().map(\.id)), [firstRow.id, secondRow.id])
        XCTAssertTrue(try h.frames("message").isEmpty)
        try await h.connect()
        XCTAssertEqual(try h.frames("message").compactMap { $0["text"] as? String }, ["first", "second"])
        XCTAssertTrue(try h.frames("message").allSatisfy { $0["channelId"] as? String == "a-channel" })
        XCTAssertNotEqual(try h.frames("message").first?["id"] as? String, firstRequest)
        XCTAssertTrue(try h.frames("file").isEmpty, "already-submitted attachments are not replayed")
        XCTAssertTrue(h.vm.offlineEntries.isEmpty)
    }
    func testForeignHiveSameChannelHistoryDoesNotStampOrUnpendQueuedRow() async throws {
        let h = try TeamTestHarness(); defer { h.close() }
        h.vm.activeChannelId = "shared"
        h.begin(); h.vm.sendMessage(text: "same")
        let row = try XCTUnwrap(h.rows().first)
        try await h.connect("hive-b")
        try await h.list(["shared"])
        try await h.history(h.request("shared"), channel: "shared", rows: [
            h.wire("b-server", sender: "device-old", date: row.createdAt)
        ])
        XCTAssertNil(row.serverId); XCTAssertTrue(row.pending)
        XCTAssertEqual(h.vm.offlineEntries, [.init(localId: row.id, hive: "hive-a")])
        XCTAssertEqual(try h.rows().count, 2)
        XCTAssertEqual(try h.rows().first { $0.id == "b-server" }?.serverId, "b-server")
    }
    func testInventoryAndMessageFetchFailuresSkipUnsafeSweepWithoutChangingBanner() async throws {
        var inventoryFails = false, messagesFail = false, inventoryCalls = 0, messageCalls = 0
        let h = try TeamTestHarness(channelInventoryOperation: { context, descriptor in
            inventoryCalls += 1
            if inventoryFails { throw NSError(domain: "Inventory", code: 1) }
            return try context.fetch(descriptor)
        }, cleanupMessageFetchOperation: { context, descriptor in
            messageCalls += 1
            if messagesFail { throw NSError(domain: "Messages", code: 2) }
            return try context.fetch(descriptor)
        }); defer { h.close() }
        try await h.connect(); try await h.list(["c"])
        try h.insert("orphan", channel: "absent")
        h.vm.lastError = UserFacingError("existing")
        let error = h.vm.lastError?.id, before = messageCalls
        inventoryFails = true
        try await h.list(["new"])
        XCTAssertEqual(messageCalls, before, "failed inventory cannot authorize deletion or sweep")
        XCTAssertEqual(try h.rows().map(\.id), ["orphan"])
        XCTAssertNotNil(h.vm.channels.first { $0.id == "new" })
        XCTAssertEqual(h.vm.lastError?.id, error)
        inventoryFails = false; messagesFail = true
        try await h.list(["new"])
        XCTAssertEqual(try h.rows().map(\.id), ["orphan"])
        XCTAssertEqual(h.vm.channels.map(\.id), ["new"])
        XCTAssertEqual(h.vm.lastError?.id, error)
        messagesFail = false
        try await h.list(["new"])
        XCTAssertTrue(try h.rows().isEmpty); XCTAssertEqual(inventoryCalls, 4)
        XCTAssertEqual(h.vm.lastError?.id, error)
    }
    func testCleanupSaveFailureKeepsDeletionAndLoadContinuation() async throws {
        var fail = false
        let h = try TeamTestHarness(saveOperation: { context in
            if fail { throw NSError(domain: "CleanupSave", code: 1) }
            try context.save()
        }); defer { h.close() }
        try await h.connect(); try await h.list(["c", "other"])
        try h.insert("delete"); h.vm.selectChannel("c")
        fail = true; try await h.list(["other"])
        XCTAssertTrue(try h.rows().isEmpty); XCTAssertEqual(h.vm.channels.map(\.id), ["other"])
        XCTAssertNil(h.vm.activeChannelId); XCTAssertFalse(h.vm.isLoadingHistory)
        XCTAssertEqual(h.vm.lastError?.text, "Couldn't save. Your last change may not be kept.")
    }
    func testRejectedResendStopsPassAndRetainsLaterAttachment() async throws {
        let h = try TeamTestHarness(); defer { h.close() }
        h.vm.activeChannelId = "c"; h.begin()
        h.vm.sendMessage(text: "first")
        h.vm.pendingAttachment = AttachmentData(data: Data([9]), name: "later.bin", mimeType: "application/octet-stream")
        h.vm.sendMessage(text: "later")
        let original = h.vm.offlineMessageIds
        let current = h.task
        current.onSend = { [weak h] text in
            guard let h, let data = text.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["type"] as? String == "history" else { return }
            h.vm.disconnect()
        }
        current.completeHandshake()
        try await eventually("bookkeeping disconnected before resend") { h.vm.connectionState == .disconnected }
        XCTAssertEqual(h.vm.offlineMessageIds, original)
        XCTAssertEqual(h.vm.queuedAttachmentCountForTesting, 1)
        XCTAssertTrue(try h.frames("message").isEmpty)
        current.onSend = nil
        try await h.connect()
        XCTAssertEqual(try h.frames("message").compactMap { $0["text"] as? String }, ["first", "later"])
        XCTAssertEqual(try h.frames("file").last?["data"] as? String, Data([9]).base64EncodedString())
    }
}
```

The final test deliberately makes the real socket reject the resend pass after a completed bookkeeping frame, using the existing fake `onSend` hook. Because that hook can synchronously disconnect inside a send, strengthen both `fetchHistory` and `seedHistory` accepted-send guards to also require `owner == currentRequestOwner` after `sendWithId` returns. This prevents a stale request from being registered after synchronous teardown without changing normal transport semantics:

```swift
guard let id = sendWithId(.history(channelId: channelId, before: before, limit: 50)),
      owner == currentRequestOwner else { return }
```

For seeds use the same post-send owner check with their nil cursor and limit 1. The resend loop stays unchanged: `sendWithId == nil` breaks before any entry/byte removal.

- [ ] **Step 7:** Run `bash Scripts/verify-kpr445.sh cleanup` and `bash Scripts/verify-kpr445.sh history`; expect zero failures including missing-channel predecessor tests and the saved-row lifecycle assertions. Run `git diff --check`, then commit:

```bash
git add Models/TeamStore.swift ViewModels/TeamViewModel.swift KeeperTests/TeamStoreTests.swift KeeperTests/TeamCleanupTests.swift KeeperTests/TeamTestHarness.swift
git commit -m "fix: preserve queued Team rows while collecting channel orphans"
```

## Task 4: Bound DM attempts and retire connection-owned commands safely

**Files:** Modify `ViewModels/TeamViewModel.swift`, `KeeperTests/TeamTestHarness.swift`. Create `KeeperTests/TeamDMLifecycleTests.swift`.

- [ ] **Step 1:** Add the following VM properties and initializer arguments/assignments. `suppressedDMRequestIds` contains accepted open-agent-DM replies still awaiting delivery on this connection; it is neither durable nor a registry of expired replies. An expired attempt removes its own ID. A successful attempt retains its undelivered ID until reply/teardown, including after another attempt starts.

```swift
private struct DMAttempt {
    let token: UUID
    let requestId: String
    let agentId: String
    let owner: RequestOwner
}
private var dmAttempt: DMAttempt?
private var dmTask: Task<Void, Never>?
private var suppressedDMRequestIds = Set<String>()
private let dmTimeout: Duration
private let capabilityRefreshOperation: (CapabilityManager) async -> Void
```

Append defaulted initializer arguments:

```swift
dmTimeout: Duration = .seconds(10),
capabilityRefreshOperation: @escaping (CapabilityManager) async -> Void = { await $0.refresh() }
```

Store them as `self.dmTimeout = dmTimeout` and `self.capabilityRefreshOperation = capabilityRefreshOperation`. Add:

```swift
deinit {
    dmTask?.cancel()
    lastErrorTimer?.cancel()
}
```

- [ ] **Step 2:** Add the complete task and retirement helpers:

```swift
private func armDM(requestId: String, agentId: String, owner: RequestOwner) {
    let attempt = DMAttempt(token: UUID(), requestId: requestId, agentId: agentId, owner: owner)
    dmAttempt = attempt
    pendingAgentDM = agentId
    pendingDMRequestId = requestId
    suppressedDMRequestIds.insert(requestId)
    let delay = dmTimeout
    dmTask?.cancel()
    dmTask = Task { [weak self] in
        do { try await Task.sleep(for: delay) } catch { return }
        guard !Task.isCancelled else { return }
        self?.expireDM(token: attempt.token, owner: attempt.owner)
    }
}

private func expireDM(token: UUID, owner: RequestOwner) {
    guard let attempt = dmAttempt, attempt.token == token,
          attempt.owner == owner, currentRequestOwner == owner else { return }
    pendingAgentDM = nil
    if pendingDMRequestId == attempt.requestId { pendingDMRequestId = nil }
    pendingNewCommands.remove(attempt.requestId)
    pendingCommandChannels.removeValue(forKey: attempt.requestId)
    suppressedDMRequestIds.remove(attempt.requestId)
    dmAttempt = nil
    dmTask = nil
    lastError = UserFacingError("Couldn't open a direct message. Try again.")
}

private func cancelDM() {
    if let attempt = dmAttempt {
        pendingNewCommands.remove(attempt.requestId)
        pendingCommandChannels.removeValue(forKey: attempt.requestId)
    }
    dmTask?.cancel()
    dmTask = nil
    dmAttempt = nil
    pendingAgentDM = nil
    pendingDMRequestId = nil
    suppressedDMRequestIds.removeAll()
}

private func completeDMIfAvailable() {
    guard let attempt = dmAttempt, attempt.owner == currentRequestOwner,
          let dm = channels.first(where: { $0.kind == .dm && $0.members.contains(attempt.agentId) }) else { return }
    dmTask?.cancel()
    dmTask = nil
    dmAttempt = nil
    pendingAgentDM = nil
    pendingNewCommands.remove(attempt.requestId)
    pendingCommandChannels.removeValue(forKey: attempt.requestId)
    // Keep its outstanding suppression ID even if the next tap begins another DM.
    selectChannel(dm.id)
}

private func retireConnectionWork() {
    pendingCommandChannels.removeAll()
    pendingNewCommands.removeAll()
    cancelDM()
    retireHistoryRequests()
    connectionGeneration = UUID()
}
```

- [ ] **Step 3:** Consolidate lifecycle retirement. In the `previous == .connected && state != .connected` branch the complete contents become:

```swift
moveUnackedToOffline()
retireConnectionWork()
```

This ordering is mandatory even if `moveUnackedToOffline` returns early with no mappings. Replace the two history-retirement lines at `disconnect()` entry with `retireConnectionWork()`, remove its two now-redundant DM-nil assignments, then call `socket.disconnect()`. Replace the retirement lines and two DM-nil assignments at `onConnected()` entry with `retireConnectionWork()`; keep channel/agent/command list requests, cursor reset and final resend in existing order, adding `hasMoreHistory = true` with the active-channel latest-page reset. At a hive change before `socket.connect`, retire only when already **not** connected:

```swift
if activeHive != channel, connectionState != .connected { retireConnectionWork() }
socket.connect(channel: channel)
activeHive = channel
```

A connected hive switch must rely on the synchronous socket transition to move unacked messages before clearing command maps; do not pre-clear those maps before `moveUnackedToOffline`. The invalid-hive `connectIfPossible` branch calls `disconnect()` (the VM method) so even already-disconnected request state is retired. Replace its successful-connect log with the static message `Log.team.info("connectIfPossible: connecting selected hive")`.

- [ ] **Step 4:** Replace `openAgentDM` with:

```swift
func openAgentDM(agent: TeamAgentInfo) {
    if let dm = channels.first(where: { $0.kind == .dm && $0.members.contains(agent.id) }) {
        selectChannel(dm.id)
        return
    }
    guard pendingAgentDM == nil else { return }
    let command = TeamWSOutgoing.command(channelId: "", name: "dm", args: [agent.id])
    guard let owner = currentRequestOwner, let requestId = sendWithId(command),
          owner == currentRequestOwner else {
        lastError = UserFacingError(Self.notConnectedText)
        return
    }
    pendingNewCommands.insert(requestId)
    armDM(requestId: requestId, agentId: agent.id, owner: owner)
}
```

In the system-message handler, keep removal of `pendingCommandChannels` and `pendingNewCommands` plus its existing `fetchChannels()` before suppression. Replace its old single-slot suppression `if` with:

```swift
if let replyTo, suppressedDMRequestIds.remove(replyTo) != nil {
    if pendingDMRequestId == replyTo { pendingDMRequestId = nil }
    return
}
```

This does not cancel or restart the attempt timer. A's later reply removes only A's set entry; B's slot/attempt survives. Replace the final DM block in `syncChannels` with the single call `completeDMIfAvailable()`. A list without the exact `.dm` membership leaves the original timer running. In `.error`, use this full branch:

```swift
case .error(let message):
    retireFullHistory()
    cancelDM()
    Log.team.error("server error received")
    lastError = UserFacingError(message)
```

- [ ] **Step 5:** In `refreshCapabilitiesAfterConnectionLost`, capture `let refresh = capabilityRefreshOperation` after the manager guard and replace `await manager.refresh()` inside the existing weak-self Task with `await refresh(manager)`. All subsequent valid/vanished logic, the attempt-1 trigger and CapabilityManager ownership remain unchanged. Tests now control only this per-VM operation; production defaults to the existing refresh. No global networking/Keychain hooks.

- [ ] **Step 6:** Extend `TeamTestHarness.init` with `dmTimeout: Duration = .seconds(10)` and `capabilityRefreshOperation: @escaping (CapabilityManager) async -> Void = { _ in }`, forwarding both to the VM. The default **test** operation is an explicit no-op; production's default remains `manager.refresh()`. Add these complete helper methods to the harness:

```swift
func agent(_ id: String) -> TeamAgentInfo {
    TeamAgentInfo(id: id, name: id, icon: "", title: nil, model: "", status: .idle,
                  tools: [], schedule: [], channels: [], messagesProcessed: 0, lastActivity: nil)
}
func dmRequest(_ agent: String) throws -> String {
    try XCTUnwrap(frames("command").last {
        $0["name"] as? String == "dm" && $0["args"] as? [String] == [agent]
    }?["id"] as? String)
}
func systemReply(_ request: String, text: String = "created") async throws {
    try await receive(["type": "message", "agentId": "system", "agentName": "System", "text": text, "replyTo": request])
}
func dmList(_ agent: String, kind: String = "dm", others: [String] = []) async throws {
    var rows: [[String: Any]] = [["id": "dm-" + agent, "type": kind, "name": "DM", "members": ["device-old", agent]]]
    rows += others.map { ["id": "dm-" + $0, "type": "dm", "name": "DM", "members": ["device-old", $0]] }
    try await receive(["type": "channel_list", "id": UUID().uuidString, "channels": rows])
}
```

- [ ] **Step 7:** Create `KeeperTests/TeamDMLifecycleTests.swift`. Each negative timer assertion waits beyond a short injected deadline; eventual conditions have bounded failure messages.

```swift
import XCTest
import SwiftData
@testable import Keepur

@MainActor
final class TeamDMLifecycleTests: XCTestCase {
    func testOfflineAndRapidTapsThenTimeoutAndRetry() async throws {
        let h = try TeamTestHarness(dmTimeout: .milliseconds(150)); defer { h.close() }
        h.vm.openAgentDM(agent: h.agent("a"))
        XCTAssertEqual(h.vm.lastError?.text, "Not connected. Try again when reconnected.")
        try await h.connect(); h.vm.lastError = nil
        h.vm.openAgentDM(agent: h.agent("a")); let first = try h.dmRequest("a")
        h.vm.openAgentDM(agent: h.agent("a")); h.vm.openAgentDM(agent: h.agent("b"))
        XCTAssertEqual(try h.frames("command").count, 1)
        try await eventually("DM deadline") { h.vm.lastError?.text == "Couldn't open a direct message. Try again." }
        let count = try h.frames("channel_list").count
        try await h.systemReply(first, text: "late expired")
        XCTAssertEqual(try h.frames("channel_list").count, count)
        h.vm.lastError = nil; h.vm.openAgentDM(agent: h.agent("b"))
        XCTAssertEqual(try h.frames("command").count, 2)
        XCTAssertNotEqual(try h.dmRequest("b"), first)
    }
    func testSystemResponseAndMissingDMDoNotRestartOrReleaseDeadline() async throws {
        let h = try TeamTestHarness(dmTimeout: .milliseconds(300)); defer { h.close() }
        try await h.connect(); h.vm.activeChannelId = "c"
        h.vm.openAgentDM(agent: h.agent("a"))
        let request = try h.dmRequest("a")
        let start = ContinuousClock.now
        try await Task.sleep(for: .milliseconds(150))
        try await h.systemReply(request)
        XCTAssertTrue(try h.rows().isEmpty, "matching command response is suppressed")
        try await h.list([])
        h.vm.openAgentDM(agent: h.agent("b"))
        XCTAssertEqual(try h.frames("command").count, 1)
        try await eventually("original DM budget", timeout: .milliseconds(250)) { h.vm.lastError != nil }
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(550))
        XCTAssertEqual(h.vm.lastError?.text, "Couldn't open a direct message. Try again.")
    }
    func testExactDMArrivalAfterReplyCancelsDeadlineAndExistingDMSelectsImmediately() async throws {
        let h = try TeamTestHarness(dmTimeout: .milliseconds(150)); defer { h.close() }
        try await h.connect()
        h.vm.openAgentDM(agent: h.agent("a"))
        try await h.systemReply(h.dmRequest("a"))
        try await h.dmList("a")
        XCTAssertEqual(h.vm.activeChannelId, "dm-a")
        try await Task.sleep(for: .milliseconds(220))
        XCTAssertNil(h.vm.lastError)
        let count = try h.frames("command").count
        h.vm.openAgentDM(agent: h.agent("a"))
        XCTAssertEqual(try h.frames("command").count, count)
        XCTAssertEqual(h.vm.activeChannelId, "dm-a")
    }
    func testUnknownChannelKindCannotCompleteDM() async throws {
        let h = try TeamTestHarness(dmTimeout: .milliseconds(150)); defer { h.close() }
        try await h.connect(); h.vm.openAgentDM(agent: h.agent("a"))
        try await h.dmList("a", kind: "future-dm")
        XCTAssertNotEqual(h.vm.activeChannelId, "dm-a")
        h.vm.openAgentDM(agent: h.agent("b"))
        XCTAssertEqual(try h.frames("command").count, 1)
        try await eventually("unknown kind keeps waiting to timeout") { h.vm.lastError != nil }
        XCTAssertEqual(h.vm.lastError?.text, "Couldn't open a direct message. Try again.")
    }
    func testEarlyAChannelThenBThenLateAReplyPreservesBDeadlineAndSuppression() async throws {
        let h = try TeamTestHarness(dmTimeout: .milliseconds(400)); defer { h.close() }
        try await h.connect()
        h.vm.openAgentDM(agent: h.agent("a")); let a = try h.dmRequest("a")
        try await Task.sleep(for: .milliseconds(250))
        try await h.dmList("a")
        XCTAssertEqual(h.vm.activeChannelId, "dm-a")
        h.vm.openAgentDM(agent: h.agent("b")); let b = try h.dmRequest("b")
        let lists = try h.frames("channel_list").count
        try await h.systemReply(a, text: "A late success")
        XCTAssertEqual(try h.frames("channel_list").count, lists, "A completion retired its refresh mapping")
        XCTAssertTrue(try h.rows().isEmpty, "A stays suppressed after B starts")
        try await Task.sleep(for: .milliseconds(200)) // A's original deadline passed; B's did not.
        XCTAssertNil(h.vm.lastError)
        h.vm.openAgentDM(agent: h.agent("c"))
        XCTAssertEqual(try h.frames("command").count, 2, "A timer/reply cannot release B's lock")
        try await h.systemReply(b)
        XCTAssertTrue(try h.rows().isEmpty, "A reply did not clear B's suppression slot")
        try await eventually("B expires on its own deadline") { h.vm.lastError != nil }
        XCTAssertEqual(h.vm.lastError?.text, "Couldn't open a direct message. Try again.")
        h.vm.lastError = nil; h.vm.openAgentDM(agent: h.agent("c"))
        XCTAssertEqual(try h.frames("command").count, 3)
    }
    func testErrorDisconnectHiveChangeAndPairingCancelOldAttempt() async throws {
        for exit in ["error", "disconnect", "switch", "pairing"] {
            let h = try TeamTestHarness(dmTimeout: .milliseconds(120)); defer { h.close() }
            try await h.connect(); h.vm.openAgentDM(agent: h.agent("a"))
            let old = try h.dmRequest("a")
            switch exit {
            case "error": try await h.receive(["type": "error", "message": "specific server error"])
            case "disconnect": h.vm.disconnect()
            case "switch": try await h.connect("hive-b")
            default: h.vm.resetForPairingTeardown()
            }
            try await Task.sleep(for: .milliseconds(180))
            XCTAssertEqual(h.vm.lastError?.text, exit == "error" ? "specific server error" : nil)
            if h.vm.connectionState != .connected {
                h.vm.isAuthenticated = true; try await h.connect()
            }
            h.vm.lastError = nil; h.vm.activeChannelId = "c"
            h.vm.openAgentDM(agent: h.agent("b"))
            let before = try h.frames("channel_list").count
            try await h.systemReply(old, text: "late old")
            XCTAssertEqual(try h.frames("channel_list").count, before)
            XCTAssertEqual(try h.rows().first { $0.text == "late old" }?.channelId, "c")
            h.vm.openAgentDM(agent: h.agent("c"))
            XCTAssertEqual(try h.frames("command").filter { $0["args"] as? [String] == ["c"] }.count, 0)
            try await h.systemReply(h.dmRequest("b"), text: "B suppressed")
            XCTAssertFalse(try h.rows().contains { $0.text == "B suppressed" })
        }
    }
    func testSleepingDMTaskDoesNotRetainViewModel() async throws {
        let h = try TeamTestHarness(dmTimeout: .milliseconds(200)); defer { h.close() }
        try await h.connect(); h.vm.openAgentDM(agent: h.agent("a"))
        weak var released = h.vm
        h.vm = nil
        try await eventually("VM deallocated while DM task sleeping") { released == nil }
        try await Task.sleep(for: .milliseconds(260))
        XCTAssertNil(released)
    }
    func testCommandMapsRetireAfterUnackedMovementIncludingEmptyMap() async throws {
        for withMessage in [false, true] {
            let h = try TeamTestHarness(); defer { h.close() }
            try await h.connect(); h.vm.activeChannelId = "old-channel"
            if withMessage { h.vm.sendMessage(text: "queued old") }
            h.vm.sendMessage(text: "/new room")
            h.vm.sendMessage(text: "/dm agent")
            h.vm.openAgentDM(agent: h.agent("button-agent"))
            let requests = try h.frames("command").compactMap { $0["id"] as? String }
            try await h.connect("hive-b")
            h.vm.activeChannelId = "new-channel"
            XCTAssertEqual(h.vm.offlineEntries.count, withMessage ? 1 : 0)
            XCTAssertTrue(h.vm.offlineEntries.allSatisfy { $0.hive == "hive-a" })
            XCTAssertTrue(try h.frames("message").isEmpty)
            let lists = try h.frames("channel_list").count
            for request in requests { try await h.systemReply(request, text: request) }
            XCTAssertEqual(try h.frames("channel_list").count, lists)
            let routed = try h.rows().filter { requests.contains($0.text) }
            XCTAssertEqual(routed.count, requests.count)
            XCTAssertTrue(routed.allSatisfy { $0.channelId == "new-channel" })
        }
    }
    func testVanishedHiveRefreshPreservesQueueBytesAndDoesNotSendFromStateSink() async throws {
        var refreshes = 0
        let h = try TeamTestHarness(capabilityRefreshOperation: { manager in
            refreshes += 1
            manager._setHivesForTesting([])
        }); defer { h.close() }
        h.vm.activeChannelId = "c"; h.begin()
        h.vm.pendingAttachment = AttachmentData(data: Data([1, 8]), name: "stay.bin", mimeType: "application/octet-stream")
        h.vm.sendMessage(text: "keep")
        let original = h.vm.offlineEntries
        let current = h.task
        current.completeHandshake(error: URLError(.networkConnectionLost))
        try await eventually("vanished hive refresh finished") { h.vm.lastError != nil }
        XCTAssertEqual(refreshes, 1)
        XCTAssertEqual(h.vm.lastError?.text, "This hive is no longer available.")
        XCTAssertEqual(h.vm.connectionState, .disconnected)
        XCTAssertEqual(h.vm.offlineEntries, original)
        XCTAssertEqual(h.vm.queuedAttachmentCountForTesting, 1)
        XCTAssertTrue(current.sentTexts.isEmpty)
        XCTAssertEqual(try h.rows().count, 1)
        h.capability._setHivesForTesting(["hive-a"])
        try await h.connect()
        XCTAssertEqual(try h.frames("message").last?["text"] as? String, "keep")
        XCTAssertEqual(try h.frames("file").last?["data"] as? String, Data([1, 8]).base64EncodedString())
    }
    func testValidHiveRefreshRunsOnlyAtFirstReconnectAttempt() async throws {
        var refreshes = 0
        let h = try TeamTestHarness(capabilityRefreshOperation: { _ in refreshes += 1 }); defer { h.close() }
        h.begin(); let first = h.task
        first.completeHandshake(error: URLError(.networkConnectionLost))
        try await eventually("first refresh") { refreshes == 1 }
        XCTAssertEqual(h.vm.connectionState, .reconnecting(attempt: 1)); XCTAssertNil(h.vm.lastError)
        XCTAssertTrue(first.sentTexts.isEmpty)
        h.vm.reconnect(); let second = h.task
        second.completeHandshake(error: URLError(.networkConnectionLost))
        try await eventually("second attempt") { h.vm.connectionState == .reconnecting(attempt: 2) }
        XCTAssertEqual(refreshes, 1); XCTAssertNil(h.vm.lastError)
        XCTAssertTrue(second.sentTexts.isEmpty)
    }
}
```

- [ ] **Step 8:** Run `bash Scripts/verify-kpr445.sh lifecycle`, `bash Scripts/verify-kpr445.sh history`, and `bash Scripts/verify-kpr445.sh cleanup`. Expect zero failures; ensure the two-successive-DM advisory test runs. Run `git diff --check`, then commit:

```bash
git add ViewModels/TeamViewModel.swift KeeperTests/TeamTestHarness.swift KeeperTests/TeamDMLifecycleTests.swift
git commit -m "fix: scope Team DM deadlines and command replies to their connection"
```

## Task 5: Extend retained pairing and persistence behavior assertions

**Files:** Modify `KeeperTests/PairingTeardownTests.swift`, `KeeperTests/TeamHistoryTests.swift`, `KeeperTests/TeamCleanupTests.swift`, `KeeperTests/TeamTestHarness.swift`, `ViewModels/TeamViewModel.swift`.

- [ ] **Step 1:** At the end of `PairingTeardownTests.lifecycle`, **after** its existing final `oldRows.count + 1` assertion, append this integration bridge. All four production-bound teardown origins run it. The actual new sender row and a deliberately identical old-device row prove identity is read after re-pair and old-device rows do not match by name/text.

```swift
let freshRow = try XCTUnwrap(try rows(f).first { $0.text == "fresh-team" })
let stableID = freshRow.id
let oldDevice = TeamMessage(id: "same-text-old-device", channelId: "channel-1",
    senderId: "old-device", senderType: "person", senderName: "Old Device",
    text: "fresh-team", createdAt: freshRow.createdAt, pending: false)
f.context.insert(oldDevice)
try f.context.save()
let historyRequest = try XCTUnwrap(try frames(returnedTeamTask).last {
    $0["type"] as? String == "history" && $0["channelId"] as? String == "channel-1"
        && $0["limit"] as? Int == 50
}?["id"] as? String)
let formatter = ISO8601DateFormatter()
formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
let reply: [String: Any] = ["type": "history", "id": historyRequest,
    "channelId": "channel-1", "hasMore": false, "messages": [[
        "id": "fresh-server", "senderId": "new-device", "senderType": "person",
        "senderName": "New Device", "text": "fresh-team",
        "createdAt": formatter.string(from: freshRow.createdAt)
    ]]]
try await eventually("re-paired Team receiver armed") { returnedTeamTask.receiveRequested }
let data = try JSONSerialization.data(withJSONObject: reply)
returnedTeamTask.deliver(String(decoding: data, as: UTF8.self))
try await eventually("re-paired history handled") { freshRow.serverId == "fresh-server" }
XCTAssertEqual(freshRow.id, stableID)
XCTAssertEqual(freshRow.senderId, "new-device")
XCTAssertNil(oldDevice.serverId)
XCTAssertEqual(oldDevice.senderId, "old-device")
XCTAssertEqual(try rows(f).count, oldRows.count + 2)
XCTAssertEqual(f.team.pendingMessageRequestCountForTesting, 0)
```

- [ ] **Step 2:** Extend `testOrdinaryAndDirectHiveSwitchPreserveQueuedAttachment` without removing any original assertion. Before `f.capabilities.selectedHive = "hive-1"`, insert:

```swift
f.context.insert(TeamChannel(id: "channel-1", type: "channel", name: "Original"))
try f.context.save()
```

After the hive-B `other.completeHandshake(); await settle()` pair, insert real channel-list processing before the existing queue/byte assertions:

```swift
try await eventually("other hive receive armed") { other.receiveRequested }
other.deliver(#"{"type":"channel_list","id":"b-list","channels":[{"id":"b-channel","type":"channel","name":"B","members":[]}]}"#)
try await eventually("other hive list cleanup") { f.team.channels.map(\.id) == ["b-channel"] }
XCTAssertEqual(try rows(f).map(\.id), original.map(\.localId))
XCTAssertEqual(try rows(f).first?.channelId, "channel-1")
XCTAssertNil(f.team.activeChannelId)
```

After the existing returned payload assertions, add:

```swift
XCTAssertTrue(sent.allSatisfy { $0["channelId"] as? String == "channel-1" })
```

Both explicit disconnect and direct switch are retained. The broader `TeamCleanupTests` covers the connected-switch `.goingAway` evidence and unacked text after actual list cleanup.

- [ ] **Step 3:** Add a narrow per-VM operation seam for the moved history message fetch so the approved empty-input continuation is observable through the existing reporting helper. Add the property, defaulted initializer argument and assignment:

```swift
private let historyMessageFetchOperation: (ModelContext, FetchDescriptor<TeamMessage>) throws -> [TeamMessage]
```

```swift
historyMessageFetchOperation: @escaping (ModelContext, FetchDescriptor<TeamMessage>) throws -> [TeamMessage] = { try $0.fetch($1) }
```

```swift
self.historyMessageFetchOperation = historyMessageFetchOperation
```

Replace only the `fetched` assignment in `processHistory` with:

```swift
var historyFetchFailure: Error?
let fetched = context.fetchOrEmpty(descriptor, "team.history.messages.fetch", failure: &historyFetchFailure,
    operation: { try historyMessageFetchOperation(context, $0) })
```

Do not guard on the failure: the approved continuation uses an empty merger input. Forward the same defaulted argument through `TeamTestHarness.init`. This seam has no new catch, retry, rollback, state reset or global hook. Append this test inside `TeamHistoryTests`:

```swift
func testHistoryFetchFailureUsesEmptyInputAndKeepsExistingError() async throws {
    var fail = true, calls = 0
    let h = try TeamTestHarness(historyMessageFetchOperation: { context, descriptor in
        calls += 1
        if fail { throw NSError(domain: "HistoryFetch", code: 1) }
        return try context.fetch(descriptor)
    }); defer { h.close() }
    try await h.connect(); try await h.list(["c"]); h.vm.selectChannel("c")
    h.vm.lastError = UserFacingError("retained error")
    let error = h.vm.lastError?.id
    try await h.history(h.request("c"), channel: "c", rows: [h.wire("server")])
    XCTAssertEqual(calls, 1)
    XCTAssertEqual(try h.rows().map(\.id), ["server"])
    XCTAssertEqual(try h.rows().first?.serverId, "server")
    XCTAssertFalse(h.vm.isLoadingHistory); XCTAssertFalse(h.vm.hasMoreHistory)
    XCTAssertEqual(h.vm.lastError?.id, error)
    fail = false; h.vm.fetchHistory(channelId: "c")
    try await h.history(h.request("c"), channel: "c", rows: [h.wire("server")])
    XCTAssertEqual(calls, 2); XCTAssertEqual(try h.rows().count, 1)
    XCTAssertEqual(h.vm.lastError?.id, error)
}
```

- [ ] **Step 4:** Strengthen the silent-history bridge in `testRealLiveOwnAndSystemMergeIsSilentAndKeepsUnackedOwnership`: capture local field values before delivery as dictionaries keyed by local ID, then compare afterward. This complete addition proves that applying an unknown wire sender does not normalize the local type/name/date/thread:

```swift
let originalTypes = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.senderType) })
let originalNames = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.senderName) })
let originalDates = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.createdAt) })
let originalThreads = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.threadId) })
```

Insert those declarations before `let page = ...`; after the history reply insert:

```swift
for row in rows {
    XCTAssertEqual(row.senderType, originalTypes[row.id])
    XCTAssertEqual(row.senderName, originalNames[row.id])
    XCTAssertEqual(row.createdAt, originalDates[row.id])
    XCTAssertEqual(row.threadId, originalThreads[row.id] ?? nil)
}
```

History calls no `speak` and never changes `lastLiveMessageId`; the existing VM has optional weak speech and the bridge remains headless. Do not create a speech instance just to run history.

- [ ] **Step 5:** Add this test to `TeamCleanupTests`. It follows the same row and attachment through foreign-hive exclusion, original-hive submission, a history stamp that clears pending, and channel cleanup while the text still has unacked ownership.

```swift
func testAttachmentOwnershipSurvivesForeignHistoryThenOriginalHiveStampAndCleanup() async throws {
    let h = try TeamTestHarness(); defer { h.close() }
    h.vm.activeChannelId = "shared"; h.begin()
    let bytes = Data([7, 7, 1])
    h.vm.pendingAttachment = AttachmentData(data: bytes, name: "owned.bin", mimeType: "application/octet-stream")
    h.vm.sendMessage(text: "owned")
    let row = try XCTUnwrap(h.rows().first)
    try await h.connect("hive-b")
    try await h.list(["shared"])
    try await h.history(h.request("shared"), channel: "shared", rows: [
        h.wire("foreign", text: "owned", sender: "device-old", date: row.createdAt)
    ])
    XCTAssertNil(row.serverId); XCTAssertTrue(row.pending)
    XCTAssertEqual(h.vm.queuedAttachmentCountForTesting, 1)
    XCTAssertEqual(h.vm.offlineEntries, [.init(localId: row.id, hive: "hive-a")])
    try await h.list([])
    XCTAssertEqual(try h.rows().map(\.id), [row.id])
    try await h.connect()
    XCTAssertEqual(try h.frames("file").last?["data"] as? String, bytes.base64EncodedString())
    XCTAssertEqual(h.vm.pendingMessageRequestCountForTesting, 1)
    try await h.list(["shared"]); h.vm.selectChannel("shared")
    try await h.history(h.request("shared"), channel: "shared", rows: [
        h.wire("own-server", text: "owned", sender: "device-old", date: row.createdAt)
    ])
    XCTAssertEqual(row.serverId, "own-server"); XCTAssertFalse(row.pending)
    try await h.list([])
    XCTAssertEqual(try h.rows().map(\.id), [row.id])
    XCTAssertEqual(h.vm.pendingMessageRequestCountForTesting, 1)
    h.vm.disconnect()
    XCTAssertEqual(h.vm.offlineEntries, [.init(localId: row.id, hive: "hive-a")])
}
```

Queued bytes end on their actual original-hive attachment submission, and subsequent unacked recovery replays only text. Resend remains last in `onConnected`, independent of history and channel-list replies.

- [ ] **Step 6:** Run `bash Scripts/verify-kpr445.sh retained`, `bash Scripts/verify-kpr445.sh history`, `bash Scripts/verify-kpr445.sh cleanup`, and `git diff --check`. Expect every retained assertion plus new re-pair/history bridges to pass, then commit:

```bash
git add ViewModels/TeamViewModel.swift KeeperTests/PairingTeardownTests.swift KeeperTests/TeamHistoryTests.swift KeeperTests/TeamCleanupTests.swift KeeperTests/TeamTestHarness.swift
git commit -m "test: preserve pairing queue and persistence contracts through Team reconciliation"
```

## Task 6: Remove dead naming, update canon-facing documentation and complete implementer audit

**Files:** Modify `Models/TeamChannel.swift`, `KeeperTests/TeamHistoryTests.swift`, `CLAUDE.md`. Review all changed production/test/scripts files and all predecessor assertions. Record evidence in the lane's durable checkpoint; do not commit machine-local logs or the migration store.

- [ ] **Step 1:** Remove exactly this unused computed property from `TeamChannel`:

```swift
var displayName: String {
    kind == .channel ? "#\(name)" : name
}
```

`TeamViewModel.displayName(for:)` remains the single Team name rule. `Session.displayName` and `Workspace.displayName` are unrelated and stay. Add the following test inside `TeamHistoryTests` for the retained VM title rule:

```swift
func testTeamDisplayNameRetainsExactTypedMembership() throws {
    let h = try TeamTestHarness(); defer { h.close() }
    h.vm.agents = [h.agent("agent")]
    XCTAssertEqual(h.vm.displayName(for: TeamChannel(id: "c", type: "channel", name: "General")), "#General")
    XCTAssertEqual(h.vm.displayName(for: TeamChannel(id: "d", type: "dm", name: "Server", members: ["agent"])), "agent")
    XCTAssertEqual(h.vm.displayName(for: TeamChannel(id: "d2", type: "dm", name: "Fallback")), "Fallback")
    XCTAssertEqual(h.vm.displayName(for: TeamChannel(id: "u", type: "future", name: "Raw", members: ["agent"])), "Raw")
}
```

- [ ] **Step 2:** Edit `CLAUDE.md`'s E-still-pending sentences to these final implemented statements. Keep the surrounding B/C/D contracts and external follow-up entries.

Replace the state/storage bullet ending “D changes no stored schema; E's separate optional serverId work is not implemented here.” with:

> `Message.role`, `TeamMessage.senderType` and `TeamChannel.type` remain String attributes. Computed typed accessors do not rewrite data; constructor arguments serialize enum raw values at storage boundaries. SwiftData predicates use stored fields. E adds only optional nonunique `TeamMessage.serverId`; UUID local IDs remain bubble identities, history inserts use their server ID for both fields, and pre-E history rows adopt identity by exact existing row-ID equality.

Replace “New persisted schema is outside D; keep existing storage boundaries and helpers.” with:

> E's optional serverId is the only stored-schema addition; keep all other storage boundaries, the five-model container and shared reporting helper.

Replace the final “Child E still owns…” paragraph with:

> Team history uses a pure Foundation `HistoryMerger`: known server IDs skip, exact legacy row IDs adopt, otherwise one unreconciled same-channel/sender/text row within a strict 30-second window stamps and unpends; closest date, earlier local date and lexical local ID break ties. Incoming date/ID ordering and whole-page identity reservation preserve repeats and replay idempotence. Full-page requests alone merge/change cursors; seed IDs update only preview text/date together. Selection, lifecycle, removal and unscoped errors retire obsolete request ownership. History never acknowledges a transport send, and foreign-hive queued rows are excluded from mutation.
>
> `TeamStore` deletes unprotected messages before a removed channel and sweeps only true unprotected orphans after successful channel inventory. Protection is the union of offline local IDs and unacked request local IDs, independent of pending flags; queue stamps and retained bytes survive original-hive channel removal. The VM owns saves and error banners. History/cleanup operation failures use instance seams through the same reporting helper, preserving each continuation.
>
> Team DM creation has a weak cancellable ten-second attempt deadline. A system response suppresses its bubble but leaves the original deadline running until an exact DM appears. Successful early channel lists retain outstanding reply suppression across subsequent DM attempts for the same connection. Expiry, server error and connection/pairing teardown retire the appropriate attempt without affecting newer work. Unacked-to-offline movement precedes command-map clearing on departure from connected; resend remains last in onConnected. The VM remains the sole Team display-name authority. No wire/server association or exactly-once delivery guarantee is added.

- [ ] **Step 3:** Run static checks from the repository root. Commands returning exit 1 for no `rg` matches are the expected clean result; inspect every output and distinguish “no matches” from an invalid command. The complete app entry recovery is intentionally unchanged, and `try?` sleeps/codecs are outside the save/fetch query.

```bash
git diff --check
git diff 49c3423ddf3057e9ae2b893b23dee325fe545094 --stat
rg -n 'try\?[^\n]*(\.save\(|\.fetch\()' --glob '*.swift' Models Managers ViewModels Views KeepurApp.swift
rg -n 'print\(' Managers ViewModels
rg -n 'WebSocketManager|TeamSocketManager|viewModel\.socket|teamViewModel\.socket' --glob '*.swift' Managers Models ViewModels Views
rg -n 'existingContentKeys|contentKey|userMessages' ViewModels/TeamViewModel.swift
rg -n 'displayName' Models/TeamChannel.swift Views/Team KeeperTests/TeamHistoryTests.swift
rg -n 'context\.(fetch|save)\(' Models/TeamStore.swift ViewModels/TeamViewModel.swift
rg -n 'Log\.team|Log\.persistence' Models/HistoryMerger.swift Models/TeamStore.swift ViewModels/TeamViewModel.swift Managers/Persistence.swift
rg -n 'serverId|@Relationship|@Attribute' Models/TeamMessage.swift Models/TeamChannel.swift
git diff 49c3423ddf3057e9ae2b893b23dee325fe545094 -- KeepurApp.swift Models/TeamWSMessage.swift Managers/Persistence.swift
```

Expected: zero production optional-try saves/fetches, prints, old socket managers/access or content-key logic; no model `TeamChannel.displayName`; only the intended VM/test title references; raw context fetch/save calls occur only in the explicitly defaulted injected operation closures (plus the pre-existing `saveOperation` default), with all production invocations through the shared reporting helper. Logging is static except D's approved safe type/code helper output. `serverId` alone is new stored state; no relationship, unique server ID or change to container/codec/reporting catch.

- [ ] **Step 4:** Compare the predecessor test inventory and assertions before broad verification. Use this read-only command to list baseline test methods that disappeared; expected output is empty. Inspect `git diff` for assertion weakening separately—the name inventory alone does not prove coverage.

```bash
python3 - <<'PY'
import pathlib, re, subprocess
base = '49c3423ddf3057e9ae2b893b23dee325fe545094'
files = subprocess.check_output(['git', 'ls-tree', '-r', '--name-only', base, 'KeeperTests'], text=True).splitlines()
missing = []
for name in files:
    if not name.endswith('.swift'):
        continue
    before = subprocess.check_output(['git', 'show', f'{base}:{name}'], text=True)
    path = pathlib.Path(name)
    after = path.read_text() if path.exists() else ''
    old = set(re.findall(r'func\s+(test\w+)\s*\(', before))
    new = set(re.findall(r'func\s+(test\w+)\s*\(', after))
    missing.extend(f'{name}: {method}' for method in sorted(old - new))
for item in missing:
    print(item)
raise SystemExit(bool(missing))
PY
```

- [ ] **Step 5:** Run `bash Scripts/verify-kpr445.sh history`, then the whole approved local regression group, migration and macOS build:

```bash
bash Scripts/verify-kpr445.sh regression
bash Scripts/verify-kpr445-migration.sh
bash Scripts/verify-kpr445.sh macos
```

Expected: signed iOS tests succeed with only the approved local twelve CapabilityManager cases excluded; all newly added test classes are present/nonzero in results; the full predecessor suite outside that local exception remains covered; migration prints all four markers; macOS reports `BUILD SUCCEEDED`. This draft adds 38 XCTest methods, so against D's 298-case baseline the expected totals are 336 unexcluded and 324 with the twelve-case local exception; reconcile actual discovery against those counts and explain any additive review changes. Inspect xcresult summaries for failure count and executed case count instead of relying only on xcodebuild exit status. No new skip, disabled assertion or unexpected test-discovery reduction is acceptable. All commands have unique evidence paths and the actual source head/worktree state recorded. If the local exclusion has become unnecessary, run `full` and retain that evidence; it does not replace PR CI.

- [ ] **Step 6:** Record a concrete implementer audit: changed files; Testing Contract group→executed test class mapping; exact evidence directories; discovered/passed/failed counts; migration source versions and four process results; macOS result; static audit; baseline assertion retention; unresolved risks or blockers. The implementer must finish this audit, not hand verification work back as “later.” Then run `git diff --check` and commit:

```bash
git add Models/TeamChannel.swift KeeperTests/TeamHistoryTests.swift CLAUDE.md
git commit -m "docs: record implemented Team correctness boundaries"
```

## Delivery ownership after implementation

1. **Implementer:** complete Tasks 1–6 with focused verification, commits and the audit above; do not self-approve or create the child PR as part of plan drafting.
2. **Lane pre-PR review:** fresh review using `dodi-dev:review`, fix loop to clean Frontier final round. Review compares against merged D and the approved spec/canon, including the DM advisory and storage migration evidence.
3. **Lane coverage/verify:** verify the complete Testing Contract and local quality-gate evidence after fixes. Apply the repository's compliance → coverage → pre-submit checks in the approved epic lifecycle; a reviewed code fix gets fresh affected tests and, where material, broader checks. No claimed full-CI result yet.
4. **Lane submit:** `dodi-dev:submit-ticket-pr` opens a child PR targeting `epic-kpr-441` with concrete behavior and verification evidence. The PR trigger starts the existing unexcluded GitHub workflow. KPR-446's local exception must be described accurately in the PR; never add it to CI.
5. **Lane child-PR review and full CI:** collect full `KeeperTests` signed iOS CI at the final reviewed PR head; the required workflow must have no exclusions. Resolve review/CI issues and repeat final-head checks after every subsequent commit. Clean local evidence is not a substitute for this final CI gate.
6. **Resident driver:** serial child merge and coherence ruling per dedicated skills; maintain decision-register propagation and tracked follow-ups. The epic-to-main merge remains operator-owned Gate 2. This plan grants no main merge or server work.

## Technical assumptions and review package

- Envelope history IDs/ack echoes already exist; no deployed-server assertion or live stored-message-ID decoding is added. `replyTo` never populates `serverId`.
- No product ambiguity remains in this draft. Strict matching, legacy reservation, deterministic ties, protected-row retention and error continuation follow the clean spec; a contrary implementation finding returns to the spec lane.
- Small instance closures expose only the new/moved operation boundaries for deterministic failure/refresh tests; they do not replace the persistence helper or CapabilityManager's production refresh.
- Completed DM reply suppression is connection-scoped until that reply arrives, specifically required by spec review 1's advisory; expired IDs are removed and use the ordinary late-system routing rule.
- Production source changes remain in the two Team models, new pure merger/thin store and Team VM. Tests/scripts/documentation are additive. No transport, Chat, concierge, UI layout or server implementation is changed.
- Every review chunk receives the complete shared context: this plan's header/Testing Contract/file map, clean 211-line spec, canon through D, spec-review-1 digest including the advisory, actual relevant source, and all chunk dependencies. The digest records exact line ranges; no reviewer should infer missing global constraints from a clipped code block.
