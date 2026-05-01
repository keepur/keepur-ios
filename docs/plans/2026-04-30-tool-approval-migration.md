# ToolApproval Migration Implementation Plan

> **For agentic workers:** Use `dodi-dev:implement` to execute this plan.

**Goal:** Migrate `Views/ToolApprovalView.swift` to consume `KeepurTheme` tokens. Add `KeepurDestructiveButtonStyle` to `Theme/Components/PrimaryButton.swift`. No behavior changes.

**Spec:** [docs/specs/2026-04-30-tool-approval-migration.md](../specs/2026-04-30-tool-approval-migration.md)

---

## File Map

| File | Change |
|------|--------|
| `Theme/Components/PrimaryButton.swift` | **Modify** — append `KeepurDestructiveButtonStyle` |
| `Views/ToolApprovalView.swift` | **Rewrite** |

No new files, no project.pbxproj edits (PrimaryButton.swift is already wired into the Xcode project from DOD-391).

---

## Task 1: Preflight

- [ ] **Step 1.1:** Worktree state.

```bash
pwd
git rev-parse --abbrev-ref HEAD
git log --oneline -2
```

Expected: worktree at `/Users/mayhuang/github/keepur-ios-DOD-397`, branch `DOD-397`, top commit is the spec.

- [ ] **Step 1.2:** Tokens resolve.

```bash
for sym in warning danger fgPrimaryDynamic fgSecondaryDynamic fgOnDark bgPageDynamic bgSunkenDynamic; do
  printf "Color.%-22s -> %s\n" "$sym" "$(grep -c "let $sym" Theme/KeepurTheme.swift)"
done
for sym in h3 lsH3 bodySm caption eyebrow lsEyebrow button; do
  printf "Font.%-23s -> %s\n" "$sym" "$(grep -c "let $sym" Theme/KeepurTheme.swift)"
done
for sym in s2 s3 s4 s5; do
  printf "Spacing.%-20s -> %s\n" "$sym" "$(grep -c "let $sym:" Theme/KeepurTheme.swift)"
done
for sym in md; do
  printf "Radius.%-21s -> %s\n" "$sym" "$(grep -c "let $sym:" Theme/KeepurTheme.swift)"
done
for sym in mono; do
  printf "FontName.%-19s -> %s\n" "$sym" "$(grep -c "let $sym " Theme/KeepurTheme.swift)"
done
echo "PrimaryButton style:"
grep -c "KeepurPrimaryButtonStyle" Theme/Components/PrimaryButton.swift
```

Expected: every count ≥ 1.

- [ ] **Step 1.3:** No tests reference this view.

```bash
grep -rln "ToolApprovalView" KeeperTests/ 2>/dev/null || echo "(no matches)"
```

Expected: `(no matches)`.

---

## Task 2: Add `KeepurDestructiveButtonStyle`

- [ ] **Step 2.1:** Append to `Theme/Components/PrimaryButton.swift`. Use Edit at the end of the file (after the closing `}` of `KeepurPrimaryButtonStyle`).

The file currently ends with:

```swift
            .opacity(isEnabled ? 1.0 : 0.4)
    }
}
```

Replace with:

```swift
            .opacity(isEnabled ? 1.0 : 0.4)
    }
}

/// Danger-red destructive call-to-action with the same shape as
/// `KeepurPrimaryButtonStyle` but a red background. Used for irreversible
/// destructive actions where the user must consciously commit (Deny tool
/// approval, etc.). For inline destructive actions in lists, use
/// `Button(role: .destructive)` instead — that surface doesn't deserve the
/// full CTA chrome.
///
/// Apply with `.buttonStyle(KeepurDestructiveButtonStyle())`.
struct KeepurDestructiveButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(KeepurTheme.Font.button)
            .foregroundStyle(KeepurTheme.Color.fgOnDark)
            .frame(maxWidth: .infinity)
            .padding(.vertical, KeepurTheme.Spacing.s3)
            .background(
                KeepurTheme.Color.danger
                    .opacity(configuration.isPressed ? 0.85 : 1.0)
            )
            .clipShape(RoundedRectangle(cornerRadius: KeepurTheme.Radius.md))
            .opacity(isEnabled ? 1.0 : 0.4)
    }
}
```

(No `.keepurShadow(...)` — honey-tinted shadow is reserved for the primary CTA per the brand rule in KeepurTheme.swift's Shadow comments.)

- [ ] **Step 2.2:** Don't commit yet — Task 3 commits both changes together.

---

## Task 3: Rewrite `Views/ToolApprovalView.swift`

- [ ] **Step 3.1:** Replace the entire file.

```swift
import SwiftUI
import Combine

struct ToolApprovalView: View {
    let approval: ChatViewModel.ToolApproval
    let onApprove: () -> Void
    let onDeny: () -> Void

    @State private var remainingSeconds = 60

    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: KeepurTheme.Spacing.s5) {
            Spacer()

            Image(systemName: "exclamationmark.shield.fill")
                .font(.system(size: 48))
                .foregroundStyle(KeepurTheme.Color.warning)

            Text("Approval Required")
                .font(KeepurTheme.Font.h3)
                .tracking(KeepurTheme.Font.lsH3)
                .foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)

            VStack(spacing: KeepurTheme.Spacing.s2) {
                Text("TOOL")
                    .font(KeepurTheme.Font.eyebrow)
                    .tracking(KeepurTheme.Font.lsEyebrow)
                    .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(approval.tool)
                    .font(KeepurTheme.Font.bodySm)
                    .fontWeight(.medium)
                    .foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(approval.input)
                    .font(.custom(KeepurTheme.FontName.mono, size: 14))
                    .foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)
                    .padding(KeepurTheme.Spacing.s3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: KeepurTheme.Radius.md)
                            .fill(KeepurTheme.Color.bgSunkenDynamic)
                    )
            }
            .padding(.horizontal, KeepurTheme.Spacing.s5)

            Text("Auto-deny in \(remainingSeconds)s")
                .font(KeepurTheme.Font.caption)
                .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)

            HStack(spacing: KeepurTheme.Spacing.s4) {
                Button { onDeny() } label: {
                    Text("Deny")
                }
                .buttonStyle(KeepurDestructiveButtonStyle())

                Button { onApprove() } label: {
                    Text("Approve")
                }
                .buttonStyle(KeepurPrimaryButtonStyle())
            }
            .padding(.horizontal, KeepurTheme.Spacing.s5)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(KeepurTheme.Color.bgPageDynamic)
        .onReceive(timer) { _ in
            if remainingSeconds > 0 {
                remainingSeconds -= 1
            } else {
                onDeny()
            }
        }
        .presentationDetents([.medium])
    }
}
```

Behavior preservation: 60s countdown via `Timer.publish` + `.onReceive(timer)` decrement, auto-deny on 0, `onApprove` / `onDeny` callbacks, `presentationDetents([.medium])`.

Layout: `VStack(spacing: s5)` with two `Spacer()`s (one explicit at top, one explicit at bottom). The original had `Spacer()` then content then `Spacer()` — preserved verbatim.

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
  -quiet > /tmp/dod-397-ios-test.log 2>&1
echo "EXIT=$?"
echo "passed: $(grep -c 'passed on' /tmp/dod-397-ios-test.log)"
echo "failed: $(grep -c 'failed on' /tmp/dod-397-ios-test.log)"
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
  > /tmp/dod-397-mac-test.log 2>&1
echo "EXIT=$?"
echo "passed: $(grep -c 'passed on' /tmp/dod-397-mac-test.log)"
echo "failed: $(grep -c 'failed on' /tmp/dod-397-mac-test.log)"
```

Expected: `EXIT=0`, `failed: 0`.

- [ ] **Step 3.6:** Commit (button style + view rewrite together).

```bash
git add Theme/Components/PrimaryButton.swift Views/ToolApprovalView.swift
git commit -m "$(cat <<'EOF'
feat: migrate ToolApproval + add KeepurDestructiveButtonStyle (DOD-397)

Visible changes:
- Warning icon: Color.warning (was orange)
- Heading: Font.h3 with lsH3 tracking
- Tool name + command card: eyebrow "TOOL" label, JetBrains Mono
  command on bgSunkenDynamic with Radius.md (matches the chat
  tool-bubble recipe from DOD-394)
- Approve button: KeepurPrimaryButtonStyle (honey, full-width)
- Deny button: new KeepurDestructiveButtonStyle (danger red,
  full-width, no shadow — honey shadow is reserved for the
  primary CTA per brand rule)
- Wax page background fills the sheet

Foundation expansion: KeepurDestructiveButtonStyle added to
Theme/Components/PrimaryButton.swift as a sibling to
KeepurPrimaryButtonStyle. Same shape, danger background,
fgOnDark text. First and currently only consumer is this view —
extracted at use site rather than later because it's the natural
counterpart to the primary style.

No behavior changes. 60s countdown via Timer.publish, auto-deny
on 0, onApprove/onDeny callbacks, presentationDetents([.medium])
all preserved.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Final sweep

- [ ] **Step 4.1:** Confirm clean tree, 2 commits ahead of main.

```bash
git status --short
git log --oneline main..HEAD
```
