# Session List Migration Implementation Plan

> **For agentic workers:** Use `dodi-dev:implement` to execute this plan.

**Goal:** Migrate `Views/SessionListView.swift` (and its inline `SessionRow`) to consume `KeepurTheme` tokens with brand surfaces, plus add `KeepurTheme.Symbol.compose = "square.and.pencil"` to the foundation. No behavior changes.

**Architecture:** Single-file view rewrite + one-line foundation addition. Two atomic commits.

**Tech Stack:** SwiftUI, SwiftData. iOS 26.2+ / macOS 15.0+. No xcodeproj edits.

**Spec:** [docs/specs/2026-04-30-session-list-migration.md](../specs/2026-04-30-session-list-migration.md)

**Out of scope:** SessionRow extraction, NavigationSplitView chrome, data-flow changes.

---

## File Map

| File | Change |
|------|--------|
| `Theme/KeepurTheme.swift` | **Modify** — add `Symbol.compose = "square.and.pencil"` |
| `Views/SessionListView.swift` | **Rewrite** — same surface, retoken + brand surfaces |

---

## Task 1: Preflight verification

- [ ] **Step 1.1:** Confirm worktree state.

```bash
pwd
git rev-parse --abbrev-ref HEAD
git log --oneline -3
```

Expected: worktree at `/Users/mayhuang/github/keepur-ios-DOD-393`, branch `DOD-393`, top commit is the spec, parent is the Settings merge `bd47212`.

- [ ] **Step 1.2:** Confirm every cited token exists.

```bash
for sym in honey100 honey500 honey700 success warning danger fgPrimaryDynamic fgSecondaryDynamic fgTertiary fgOnHoney bgPageDynamic; do
  printf "Color.%-22s -> %s\n" "$sym" "$(grep -c "let $sym" Theme/KeepurTheme.swift)"
done
for sym in body bodySm caption; do
  printf "Font.%-23s -> %s\n" "$sym" "$(grep -c "let $sym" Theme/KeepurTheme.swift)"
done
for sym in s1 s2 s7; do
  printf "Spacing.%-20s -> %s\n" "$sym" "$(grep -c "let $sym:" Theme/KeepurTheme.swift)"
done
for sym in mono; do
  printf "FontName.%-19s -> %s\n" "$sym" "$(grep -c "let $sym " Theme/KeepurTheme.swift)"
done
for sym in bolt settings; do
  printf "Symbol.%-21s -> %s\n" "$sym" "$(grep -c "let $sym " Theme/KeepurTheme.swift)"
done
echo "compose (should be 0 — being added):"
grep -c "let compose " Theme/KeepurTheme.swift
echo ""
echo "PrimaryButton style:"
grep -c "KeepurPrimaryButtonStyle" Theme/Components/PrimaryButton.swift
```

Expected: all `Color`/`Font`/`Spacing`/`FontName`/`Symbol` counts ≥ 1 (`Font.body` returns 2 due to `FontName.mono` shadowing). `compose` returns 0 (we're adding it). `KeepurPrimaryButtonStyle` returns ≥ 1.

- [ ] **Step 1.3:** Confirm no SessionListView test references.

```bash
grep -rln "SessionListView\|SessionRow" KeeperTests/ 2>/dev/null || echo "(no matches)"
```

Expected: `(no matches)`.

- [ ] **Step 1.4:** No commit.

---

## Task 2: Add `Symbol.compose` to the foundation

**Files:**
- Modify: `Theme/KeepurTheme.swift`

- [ ] **Step 2.1:** Add `compose` to `KeepurTheme.Symbol`. The existing block is sorted alphabetically; insert after `chat`:

Use Edit with old_string:
```
        public static let chat        = "bubble.left.and.bubble.right"
        public static let bolt        = "bolt.fill"
```

new_string:
```
        public static let chat        = "bubble.left.and.bubble.right"
        public static let bolt        = "bolt.fill"
        public static let compose     = "square.and.pencil"
```

Note: the existing block is *not* strictly alphabetical — `bolt` follows `chat`. Inserting `compose` after `bolt` keeps it next to its closest semantic neighbors (icons that tend to share toolbar usage). Acceptable.

- [ ] **Step 2.2:** Verify the addition compiles.

```bash
xcrun swiftc -parse Theme/KeepurTheme.swift 2>&1 | tail -3
echo "exit: $?"
```

Expected: exit 0, empty output.

- [ ] **Step 2.3:** Don't commit yet — Task 3 commits the symbol with the rewrite that consumes it. Atomic for review.

---

## Task 3: Rewrite `Views/SessionListView.swift`

**Files:**
- Modify: `Views/SessionListView.swift` (full rewrite, same surface, same behavior)

- [ ] **Step 3.1:** Replace the entire file with the version below.

```swift
import SwiftUI
import SwiftData

struct SessionListView: View {
    @ObservedObject var viewModel: ChatViewModel
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Session.createdAt, order: .reverse) private var sessions: [Session]
    @State private var selectedSessionId: String?
    @State private var daysRemaining: Int?
    @State private var showSettings = false
    @State private var showWorkspacePicker = false
    @State private var renamingSession: Session?
    @State private var renameText = ""

    var body: some View {
        #if os(macOS)
        macOSBody
        #else
        iOSBody
        #endif
    }

    // MARK: - Session List Content

    private var sessionList: some View {
        List(selection: $selectedSessionId) {
            if let daysRemaining, daysRemaining >= 0, daysRemaining <= 7 {
                Button {
                    showSettings = true
                } label: {
                    HStack(spacing: KeepurTheme.Spacing.s2) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(KeepurTheme.Color.warning)
                        Text(daysRemaining == 0
                            ? "Device pairing expires today"
                            : daysRemaining == 1
                                ? "Device pairing expires in 1 day"
                                : "Device pairing expires in \(daysRemaining) days")
                            .font(KeepurTheme.Font.bodySm)
                            .fontWeight(.medium)
                            .foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, KeepurTheme.Spacing.s1)
                }
                .listRowBackground(KeepurTheme.Color.honey100)
            }

            ForEach(sessions, id: \.id) { session in
                SessionRow(
                    session: session,
                    isActive: session.id == viewModel.currentSessionId,
                    modelContext: modelContext
                )
                .opacity(session.isStale ? 0.5 : 1.0)
                .tag(session.id)
                .contentShape(Rectangle())
                #if os(iOS)
                .onTapGesture {
                    guard !session.isStale else { return }
                    viewModel.currentSessionId = session.id
                    viewModel.currentPath = session.path
                    selectedSessionId = session.id
                }
                #endif
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        viewModel.clearSession(sessionId: session.id)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
                .contextMenu {
                    Button {
                        renameText = session.name ?? ""
                        renamingSession = session
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        viewModel.clearSession(sessionId: session.id)
                        if selectedSessionId == session.id {
                            selectedSessionId = nil
                        }
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(KeepurTheme.Color.bgPageDynamic)
    }

    private var sessionToolbar: some ToolbarContent {
        Group {
            ToolbarItem(placement: .navigation) {
                Circle()
                    .fill(viewModel.ws.isConnected ? KeepurTheme.Color.success : KeepurTheme.Color.danger)
                    .frame(width: 8, height: 8)
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: KeepurTheme.Symbol.settings)
                        .font(.title3)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showWorkspacePicker = true
                } label: {
                    Image(systemName: KeepurTheme.Symbol.compose)
                        .font(.title3)
                }
            }
        }
    }

    private var sessionOverlay: some View {
        Group {
            if sessions.isEmpty {
                ContentUnavailableView {
                    Label("No Sessions", systemImage: "bubble.left.and.bubble.right")
                } description: {
                    Text("Start a new session to chat with Claude Code")
                } actions: {
                    Button("New Session") { showWorkspacePicker = true }
                        .buttonStyle(KeepurPrimaryButtonStyle())
                        .padding(.horizontal, KeepurTheme.Spacing.s7)
                }
            }
        }
    }

    private var sessionSheets: some View {
        EmptyView()
            .sheet(isPresented: $showSettings) {
                SettingsView(viewModel: viewModel)
            }
            .sheet(isPresented: $showWorkspacePicker) {
                WorkspacePickerView(viewModel: viewModel)
            }
            .alert("Rename Session", isPresented: Binding(
                get: { renamingSession != nil },
                set: { if !$0 { renamingSession = nil } }
            )) {
                TextField("Session name", text: $renameText)
                Button("Save") {
                    if let session = renamingSession {
                        session.name = renameText.isEmpty ? nil : renameText
                        try? modelContext.save()
                    }
                    renamingSession = nil
                }
                Button("Cancel", role: .cancel) {
                    renamingSession = nil
                }
            }
    }

    // MARK: - macOS Layout

    #if os(macOS)
    private var macOSBody: some View {
        NavigationSplitView {
            sessionList
                .navigationTitle("Sessions")
                .toolbar { sessionToolbar }
                .overlay { sessionOverlay }
        } detail: {
            if let selectedSessionId {
                ChatView(viewModel: viewModel, sessionId: selectedSessionId)
            } else {
                ContentUnavailableView {
                    Label("No Session Selected", systemImage: "bubble.left")
                } description: {
                    Text("Select a session from the sidebar")
                }
            }
        }
        .onChange(of: selectedSessionId) {
            if let selectedSessionId,
               let session = sessions.first(where: { $0.id == selectedSessionId }),
               !session.isStale {
                viewModel.currentSessionId = session.id
                viewModel.currentPath = session.path
            }
        }
        .onChange(of: viewModel.currentSessionId) { _, newValue in
            // Mirror VM → local nav state so that when the server hands us a new
            // session id (e.g. after /clear), the sidebar selection and detail
            // pane follow without a flash back to "No Session Selected".
            if let newValue, selectedSessionId != nil, selectedSessionId != newValue {
                selectedSessionId = newValue
            }
        }
        .onAppear {
            if let expiry = KeychainManager.tokenExpiryDate {
                daysRemaining = Calendar.current.dateComponents([.day], from: .now, to: expiry).day
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(viewModel: viewModel)
                .frame(minWidth: 450, minHeight: 500)
        }
        .sheet(isPresented: $showWorkspacePicker) {
            WorkspacePickerView(viewModel: viewModel)
                .frame(minWidth: 500, minHeight: 550)
        }
        .alert("Rename Session", isPresented: Binding(
            get: { renamingSession != nil },
            set: { if !$0 { renamingSession = nil } }
        )) {
            TextField("Session name", text: $renameText)
            Button("Save") {
                if let session = renamingSession {
                    session.name = renameText.isEmpty ? nil : renameText
                    try? modelContext.save()
                }
                renamingSession = nil
            }
            Button("Cancel", role: .cancel) {
                renamingSession = nil
            }
        }
    }
    #endif

    // MARK: - iOS Layout

    #if os(iOS)
    private var iOSBody: some View {
        NavigationStack {
            sessionList
                .navigationTitle("Sessions")
                .toolbar { sessionToolbar }
                .overlay { sessionOverlay }
                // `isPresented:` (not `item:`) so that when the session id swaps
                // mid-chat during a /clear handoff (HIVE-113), the ChatView stays
                // mounted instead of being popped & re-pushed.
                .navigationDestination(
                    isPresented: Binding(
                        get: { selectedSessionId != nil },
                        set: { if !$0 { selectedSessionId = nil } }
                    )
                ) {
                    if let sessionId = selectedSessionId {
                        ChatView(viewModel: viewModel, sessionId: sessionId)
                    }
                }
        }
        .onAppear {
            if let expiry = KeychainManager.tokenExpiryDate {
                daysRemaining = Calendar.current.dateComponents([.day], from: .now, to: expiry).day
            }
        }
        .onChange(of: viewModel.currentSessionId) { _, newValue in
            // Mirror VM → local nav state so that when the server hands us a new
            // session id (e.g. after /clear), the navigation follows without a pop.
            if let newValue, selectedSessionId != nil, selectedSessionId != newValue {
                selectedSessionId = newValue
            }
        }
        .background { sessionSheets }
    }
    #endif
}

// MARK: - Session Row

struct SessionRow: View {
    let session: Session
    let isActive: Bool
    let modelContext: ModelContext

    var body: some View {
        HStack(spacing: KeepurTheme.Spacing.s3) {
            Circle()
                .fill(isActive ? KeepurTheme.Color.honey500 : KeepurTheme.Color.honey100)
                .frame(width: 44, height: 44)
                .overlay {
                    Image(systemName: isActive ? KeepurTheme.Symbol.bolt : "bubble.left.fill")
                        .foregroundStyle(isActive ? KeepurTheme.Color.fgOnHoney : KeepurTheme.Color.honey700)
                }

            VStack(alignment: .leading, spacing: KeepurTheme.Spacing.s1) {
                HStack {
                    Text(session.displayName)
                        .font(KeepurTheme.Font.body)
                        .fontWeight(.medium)
                        .foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)
                    if isActive {
                        semanticBadge("Active", tint: KeepurTheme.Color.success)
                    }
                    if session.isStale {
                        semanticBadge("Stale", tint: KeepurTheme.Color.warning)
                    }
                }

                Text(session.path)
                    .font(.custom(KeepurTheme.FontName.mono, size: 12))
                    .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
                    .lineLimit(1)

                if let preview = lastMessagePreview {
                    Text(preview)
                        .font(KeepurTheme.Font.bodySm)
                        .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
                        .lineLimit(1)
                }
            }

            Spacer()

            Text(session.createdAt, style: .relative)
                .font(KeepurTheme.Font.caption)
                .foregroundStyle(KeepurTheme.Color.fgTertiary)
        }
        .padding(.vertical, KeepurTheme.Spacing.s1)
    }

    private func semanticBadge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(KeepurTheme.Font.caption)
            .padding(.horizontal, KeepurTheme.Spacing.s2)
            .padding(.vertical, 2)
            .background(tint.opacity(0.15))
            .clipShape(Capsule())
            .foregroundStyle(tint)
    }

    private var lastMessagePreview: String? {
        let sid = session.id
        var descriptor = FetchDescriptor<Message>(
            predicate: #Predicate { $0.sessionId == sid },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        guard let msg = try? modelContext.fetch(descriptor).first else { return nil }
        return msg.role == "user" ? msg.text : "Claude: \(msg.text)"
    }
}
```

Notes vs current:
- iOS NavigationStack and macOS NavigationSplitView bodies are unchanged in structure — only `sessionList`, `sessionToolbar`, `sessionOverlay`, and `SessionRow` are retokened.
- All behaviors preserved verbatim: tap-to-select, swipeActions, contextMenu, navigationDestination handoff, macOS split-view onChange mirror, expiry banner trigger, empty-state CTA, sheets, alert.
- Avatar redesign per spec D3 (honey-500/honey-100, charcoal-bolt/honey-700-chat).
- Badges via `semanticBadge` helper.
- Path uses JetBrains Mono.
- Empty-state CTA uses `KeepurPrimaryButtonStyle` with horizontal padding to constrain width.

- [ ] **Step 3.2:** iOS build.

```bash
xcodebuild build -project Keepur.xcodeproj -scheme Keepur \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -quiet 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3.3:** macOS build.

```bash
xcodebuild build -project Keepur.xcodeproj -scheme Keepur \
  -destination 'platform=macOS' \
  -quiet 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3.4:** iOS unit tests.

```bash
set -o pipefail
xcodebuild test -project Keepur.xcodeproj -scheme Keepur \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:KeeperTests \
  -quiet > /tmp/dod-393-ios-test.log 2>&1
echo "EXIT=$?"
echo "passed: $(grep -c 'passed on' /tmp/dod-393-ios-test.log)"
echo "failed: $(grep -c 'failed on' /tmp/dod-393-ios-test.log)"
```

Expected: `EXIT=0`, `failed: 0`.

- [ ] **Step 3.5:** macOS unit tests.

```bash
set -o pipefail
xcodebuild test -project Keepur.xcodeproj -scheme Keepur \
  -destination 'platform=macOS' \
  -only-testing:KeeperTests \
  -quiet \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  > /tmp/dod-393-mac-test.log 2>&1
echo "EXIT=$?"
echo "passed: $(grep -c 'passed on' /tmp/dod-393-mac-test.log)"
echo "failed: $(grep -c 'failed on' /tmp/dod-393-mac-test.log)"
```

Expected: `EXIT=0`, `failed: 0`.

- [ ] **Step 3.6:** Commit (foundation symbol + rewrite together — they're a coupled change since the rewrite consumes the symbol).

```bash
git add Theme/KeepurTheme.swift Views/SessionListView.swift
git commit -m "$(cat <<'EOF'
feat: migrate Session List to KeepurTheme tokens (DOD-393)

Visible changes:

- Wax page background (bgPageDynamic) behind plain-style list
- SessionRow avatar redesigned: honey-500 fill + charcoal bolt for
  the active session, honey-100 fill + honey-700 chat icon for
  inactive — replaces the prior green/accent treatment that
  conflated selection and connection state
- Active and Stale badges use semantic tints (Color.success /
  Color.warning) at 0.15 opacity instead of green/orange at 0.2
- Session path renders in JetBrains Mono Regular 12pt (was system
  caption); aligns with the foundation's intent that file paths
  use mono
- Connection status dot in the toolbar uses Color.success /
  Color.danger semantics
- New-session toolbar icon now references a foundation symbol
  constant: KeepurTheme.Symbol.compose (added in this commit;
  per the foundation's "audit-able icon set" rule, per-screen
  migrations are the natural driver of new symbol additions)
- Expiry warning banner uses Color.honey100 row background +
  Color.warning icon (was orange + orange-tinted)
- Empty-state "New Session" CTA uses KeepurPrimaryButtonStyle —
  first reuse of the component extracted in DOD-391

No behavior changes. iOS NavigationStack body, macOS
NavigationSplitView body, tap-to-select, swipeActions delete,
contextMenu rename/delete, navigationDestination handoff for
/clear, expiry trigger, sheets, and rename alert all preserved.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Final regression sweep

- [ ] **Step 4.1:** Confirm clean tree.

```bash
git status --short
git log --oneline main..HEAD
```

Expected: empty status, 2 commits ahead of main (spec + rewrite).

---

## Summary of commits this plan produces

1. (Spec already committed) `docs: design spec for Session List migration (DOD-393)`
2. `feat: migrate Session List to KeepurTheme tokens (DOD-393)` — Tasks 2 + 3 combined

## After the plan

1. `/quality-gate`
2. `dodi-dev:review`
3. `dodi-dev:submit` — PR + cleanup, **no auto-merge**
