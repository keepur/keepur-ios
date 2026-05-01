# WorkspacePicker Migration Implementation Plan

> **For agentic workers:** Use `dodi-dev:implement` to execute this plan.

**Goal:** Migrate `Views/WorkspacePickerView.swift` to consume `KeepurTheme` tokens. Wax page bg, eyebrow section headers, JetBrains Mono paths, honey CTAs on disconnected/error states, honey-700 folder icons, semantic Active badge.

**Architecture:** Single-file rewrite. No foundation changes.

**Spec:** [docs/specs/2026-04-30-workspace-picker-migration.md](../specs/2026-04-30-workspace-picker-migration.md)

---

## File Map

| File | Change |
|------|--------|
| `Views/WorkspacePickerView.swift` | **Rewrite** |

---

## Task 1: Preflight

- [ ] **Step 1.1:** Worktree state.

```bash
pwd
git rev-parse --abbrev-ref HEAD
git log --oneline -2
```

Expected: worktree at `/Users/mayhuang/github/keepur-ios-DOD-396`, branch `DOD-396`, top commit is the spec.

- [ ] **Step 1.2:** Tokens resolve.

```bash
for sym in honey700 success fgPrimaryDynamic fgSecondaryDynamic bgPageDynamic bgSurfaceDynamic bgSunkenDynamic; do
  printf "Color.%-22s -> %s\n" "$sym" "$(grep -c "let $sym" Theme/KeepurTheme.swift)"
done
for sym in body bodySm caption eyebrow lsEyebrow; do
  printf "Font.%-23s -> %s\n" "$sym" "$(grep -c "let $sym" Theme/KeepurTheme.swift)"
done
for sym in s7; do
  printf "Spacing.%-20s -> %s\n" "$sym" "$(grep -c "let $sym:" Theme/KeepurTheme.swift)"
done
for sym in mono; do
  printf "FontName.%-19s -> %s\n" "$sym" "$(grep -c "let $sym " Theme/KeepurTheme.swift)"
done
echo "PrimaryButton:"
grep -c "KeepurPrimaryButtonStyle" Theme/Components/PrimaryButton.swift
```

Expected: every count ≥ 1.

- [ ] **Step 1.3:** No tests reference this view.

```bash
grep -rln "WorkspacePicker" KeeperTests/ 2>/dev/null || echo "(no matches)"
```

Expected: `(no matches)`.

---

## Task 2: Rewrite `Views/WorkspacePickerView.swift`

- [ ] **Step 2.1:** Replace the entire file.

```swift
import SwiftUI
import SwiftData

struct WorkspacePickerView: View {
    @ObservedObject var viewModel: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Workspace.lastUsed, order: .reverse) private var recentWorkspaces: [Workspace]

    var body: some View {
        NavigationStack {
            List {
                if !recentWorkspaces.isEmpty {
                    Section {
                        ForEach(recentWorkspaces.prefix(5), id: \.path) { workspace in
                            Button {
                                viewModel.newSession(path: workspace.path)
                                dismiss()
                            } label: {
                                HStack {
                                    Image(systemName: "clock.arrow.circlepath")
                                        .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
                                    VStack(alignment: .leading) {
                                        Text(workspace.displayName)
                                            .font(KeepurTheme.Font.body)
                                            .foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)
                                        Text(workspace.path)
                                            .font(.custom(KeepurTheme.FontName.mono, size: 12))
                                            .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
                                    }
                                }
                            }
                            .listRowBackground(KeepurTheme.Color.bgSurfaceDynamic)
                        }
                    } header: {
                        eyebrowHeader("RECENT WORKSPACES")
                    }
                }

                Section {
                    if !viewModel.ws.isConnected {
                        ContentUnavailableView {
                            Label("Disconnected", systemImage: "wifi.slash")
                        } description: {
                            Text("Connect to browse directories")
                        } actions: {
                            Button("Reconnect") {
                                viewModel.browseError = nil
                                viewModel.ws.connect()
                                viewModel.browse()
                            }
                            .buttonStyle(KeepurPrimaryButtonStyle())
                            .padding(.horizontal, KeepurTheme.Spacing.s7)
                        }
                    } else if let error = viewModel.browseError {
                        ContentUnavailableView {
                            Label("Error", systemImage: "exclamationmark.triangle")
                        } description: {
                            Text(error)
                        } actions: {
                            Button("Retry") { viewModel.browse() }
                                .buttonStyle(KeepurPrimaryButtonStyle())
                                .padding(.horizontal, KeepurTheme.Spacing.s7)
                        }
                    } else if viewModel.browsePath.isEmpty {
                        ProgressView("Loading…")
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 40)
                    } else {
                        HStack {
                            Image(systemName: "folder.fill")
                                .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
                            Text(viewModel.browsePath)
                                .font(.custom(KeepurTheme.FontName.mono, size: 12))
                                .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
                        }
                        .listRowBackground(KeepurTheme.Color.bgSunkenDynamic)

                        if !isHome {
                            Button {
                                let parent = (viewModel.browsePath as NSString).deletingLastPathComponent
                                viewModel.browse(path: parent)
                            } label: {
                                HStack {
                                    Image(systemName: "arrow.up.doc")
                                        .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
                                    Text("..")
                                        .foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)
                                }
                            }
                            .listRowBackground(KeepurTheme.Color.bgSurfaceDynamic)
                        }

                        ForEach(viewModel.browseEntries.filter(\.isDirectory), id: \.name) { entry in
                            Button {
                                let base = viewModel.browsePath
                                let childPath = base == "/" ? "/\(entry.name)"
                                    : base.hasSuffix("/") ? "\(base)\(entry.name)"
                                    : "\(base)/\(entry.name)"
                                viewModel.browse(path: childPath)
                            } label: {
                                HStack {
                                    Image(systemName: "folder")
                                        .foregroundStyle(KeepurTheme.Color.honey700)
                                    Text(entry.name)
                                        .foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)
                                }
                            }
                            .listRowBackground(KeepurTheme.Color.bgSurfaceDynamic)
                        }
                    }
                } header: {
                    eyebrowHeader("BROWSE")
                }

                if !viewModel.workspaceSessions.isEmpty {
                    Section {
                        ForEach(viewModel.workspaceSessions, id: \.sessionId) { ws in
                            Button {
                                if ws.active {
                                    viewModel.currentSessionId = ws.sessionId
                                    viewModel.currentPath = viewModel.browsePath
                                } else {
                                    viewModel.resumeSession(sessionId: ws.sessionId, path: viewModel.browsePath)
                                }
                                dismiss()
                            } label: {
                                HStack {
                                    Image(systemName: ws.active ? "bubble.left.and.bubble.right.fill" : "bubble.left.and.bubble.right")
                                        .foregroundStyle(ws.active ? KeepurTheme.Color.success : KeepurTheme.Color.fgSecondaryDynamic)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(ws.preview)
                                            .font(KeepurTheme.Font.bodySm)
                                            .foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)
                                            .lineLimit(2)
                                        Text(ws.lastActiveAt, style: .relative)
                                            .font(KeepurTheme.Font.caption)
                                            .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
                                    }
                                    Spacer()
                                    if ws.active {
                                        semanticBadge("Active", tint: KeepurTheme.Color.success)
                                    }
                                }
                            }
                            .listRowBackground(KeepurTheme.Color.bgSurfaceDynamic)
                        }
                    } header: {
                        eyebrowHeader("SESSION HISTORY")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(KeepurTheme.Color.bgPageDynamic)
            .navigationTitle("Select Workspace")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start Session Here") {
                        viewModel.newSession(path: viewModel.browsePath)
                        dismiss()
                    }
                    .disabled(viewModel.browsePath.isEmpty)
                }
            }
            .onAppear {
                viewModel.browsePath = ""
                viewModel.browseEntries = []
                viewModel.browseError = nil
                viewModel.workspaceSessions = []
                viewModel.browse()
            }
        }
    }

    private var isHome: Bool {
        viewModel.browsePath == "/" || viewModel.browsePath.hasSuffix("/~") || viewModel.browsePath == "~"
    }

    // MARK: - Eyebrow header

    private func eyebrowHeader(_ title: String) -> some View {
        Text(title)
            .font(KeepurTheme.Font.eyebrow)
            .tracking(KeepurTheme.Font.lsEyebrow)
            .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
            .textCase(nil)
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
}
```

Behavior preservation per spec checklist: prefix(5), empty-section gates, browse state machine, path joining, active vs resume branches, toolbar buttons + disabled gate, onAppear reset, isHome, navigationBarTitleDisplayMode.

The outer `.foregroundStyle(.primary)` on row Buttons (lines 31, 143 of original) is dropped per D6 — every inner Text now sets explicit foreground.

- [ ] **Step 2.2:** iOS build.

```bash
xcodebuild build -project Keepur.xcodeproj -scheme Keepur \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -quiet 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 2.3:** macOS build.

```bash
xcodebuild build -project Keepur.xcodeproj -scheme Keepur \
  -destination 'platform=macOS' \
  -quiet 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 2.4:** iOS unit tests.

```bash
set -o pipefail
xcodebuild test -project Keepur.xcodeproj -scheme Keepur \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:KeeperTests \
  -quiet > /tmp/dod-396-ios-test.log 2>&1
echo "EXIT=$?"
echo "passed: $(grep -c 'passed on' /tmp/dod-396-ios-test.log)"
echo "failed: $(grep -c 'failed on' /tmp/dod-396-ios-test.log)"
```

Expected: `EXIT=0`, `failed: 0`.

- [ ] **Step 2.5:** macOS unit tests.

```bash
set -o pipefail
xcodebuild test -project Keepur.xcodeproj -scheme Keepur \
  -destination 'platform=macOS' \
  -only-testing:KeeperTests \
  -quiet \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  > /tmp/dod-396-mac-test.log 2>&1
echo "EXIT=$?"
echo "passed: $(grep -c 'passed on' /tmp/dod-396-mac-test.log)"
echo "failed: $(grep -c 'failed on' /tmp/dod-396-mac-test.log)"
```

Expected: `EXIT=0`, `failed: 0`.

- [ ] **Step 2.6:** Commit.

```bash
git add Views/WorkspacePickerView.swift
git commit -m "$(cat <<'EOF'
feat: migrate WorkspacePicker to KeepurTheme tokens (DOD-396)

Visible changes:
- Wax page background, wax-surface row backgrounds
- Eyebrow section headers (RECENT WORKSPACES / BROWSE / SESSION HISTORY)
- Workspace paths and current browse path render in JetBrains Mono
  (consistent with Settings DOD-392 D3 and Session List DOD-393)
- Folder icons in honey-700 (warm woody) instead of system blue
- Browse current-path row uses bgSunkenDynamic for "you are here"
  visual recession
- Reconnect / Retry CTAs use KeepurPrimaryButtonStyle
- Session-history Active state: bubble icon in Color.success,
  semantic capsule pill matching SessionRow.semanticBadge from DOD-393
- All foreground colors flow from fgPrimaryDynamic / fgSecondaryDynamic
- Outer .foregroundStyle(.primary) on row Buttons dropped (every
  inner Text sets explicit foreground)

No behavior changes. Browse state machine, path joining, recent
workspace tap → newSession + dismiss, session-history active vs
resume branches, toolbar Cancel/Start Session Here with disabled
gate, onAppear browse reset all preserved.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Final sweep

- [ ] **Step 3.1:** Confirm clean tree, 2 commits ahead.

```bash
git status --short
git log --oneline main..HEAD
```
