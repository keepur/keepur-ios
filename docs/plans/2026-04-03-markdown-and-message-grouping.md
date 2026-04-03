# Markdown Rendering + Message Grouping Implementation Plan

> **For agentic workers:** Use dodi-dev:implement to execute this plan.

**Goal:** Render assistant messages as proper markdown (code blocks, headers, lists, links) and fix multi-round message grouping so each streaming segment gets its own bubble.

**Architecture:** Add MarkdownUI (SPM) as the project's first external dependency and swap `Text(LocalizedStringKey(...))` for `Markdown(...)` in assistant bubbles. Separately, clear `streamingMessageIds` on status transitions that mark round boundaries (`thinking`, `tool_starting`, `tool_running`) so subsequent streaming segments create new messages.

**Tech Stack:** MarkdownUI 2.x (SPM), SwiftUI, SwiftData

---

### Task 1: Fix message grouping across rounds

**Files:**
- Modify: `ViewModels/ChatViewModel.swift:168-169`

The server streams text, then transitions to `tool_starting`/`tool_running`, then streams more text. If `final: true` wasn't sent (or was lost) between rounds, `streamingMessageIds[sessionId]` still holds the old message ID and the next streaming segment appends to the previous bubble.

- [ ] **Step 1:** Add streaming ID cleanup on round-boundary status transitions

In `ChatViewModel.swift`, insert after line 168 (the closing `}` of the tool-name else block) and before line 170 (the `// Stale-busy watchdog` comment):

```swift
                // Clear streaming ID on round boundaries so the next
                // streaming segment creates a new message bubble.
                if state == "thinking" || state == "tool_starting" || state == "tool_running" {
                    streamingMessageIds.removeValue(forKey: effectiveId)
                }
```

The full context after the edit (lines 166-175):

```swift
                } else {
                    sessionToolNames.removeValue(forKey: effectiveId)
                }

                // Clear streaming ID on round boundaries so the next
                // streaming segment creates a new message bubble.
                if state == "thinking" || state == "tool_starting" || state == "tool_running" {
                    streamingMessageIds.removeValue(forKey: effectiveId)
                }

                // Stale-busy watchdog
```

- [ ] **Step 2:** Verify

Run: `xcodebuild build -project Keepur.xcodeproj -scheme Keepur -destination 'platform=iOS Simulator,name=iPhone 16' -quiet 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3:** Commit

```bash
git add ViewModels/ChatViewModel.swift
git commit -m "fix: clear streaming ID on status transitions to prevent message merging

When the server transitions to thinking/tool_starting/tool_running between
streaming segments, clear streamingMessageIds so the next batch of chunks
creates a new message bubble instead of appending to the previous one."
```

---

### Task 2: Add MarkdownUI SPM dependency

**Files:**
- Modify: `Keepur.xcodeproj/project.pbxproj`

The project has zero SPM dependencies. We need to add MarkdownUI as the first one. This requires four new pbxproj sections/entries.

- [ ] **Step 1:** Add the SPM package reference and product dependency to the pbxproj

Add a new `XCRemoteSwiftPackageReference` section before the closing `};` / `rootObject` (after `XCConfigurationList` section, before line 525):

```
/* Begin XCRemoteSwiftPackageReference section */
		C1D2E3F4A5B6C7D8E9F0A1B2 /* XCRemoteSwiftPackageReference "swift-markdown-ui" */ = {
			isa = XCRemoteSwiftPackageReference;
			repositoryURL = "https://github.com/gonzalezreal/swift-markdown-ui";
			requirement = {
				kind = upToNextMajorVersion;
				minimumVersion = 2.4.1;
			};
		};
/* End XCRemoteSwiftPackageReference section */
```

Add a new `XCSwiftPackageProductDependency` section immediately after:

```
/* Begin XCSwiftPackageProductDependency section */
		D2E3F4A5B6C7D8E9F0A1B2C3 /* MarkdownUI */ = {
			isa = XCSwiftPackageProductDependency;
			package = C1D2E3F4A5B6C7D8E9F0A1B2 /* XCRemoteSwiftPackageReference "swift-markdown-ui" */;
			productName = MarkdownUI;
		};
/* End XCSwiftPackageProductDependency section */
```

Add `packageReferences` to the `PBXProject` section (after `targets` array, line 192):

```
			packageReferences = (
				C1D2E3F4A5B6C7D8E9F0A1B2 /* XCRemoteSwiftPackageReference "swift-markdown-ui" */,
			);
```

Add the product dependency to the Keepur target's `packageProductDependencies` (line 133-134, currently empty parens):

```
			packageProductDependencies = (
				D2E3F4A5B6C7D8E9F0A1B2C3 /* MarkdownUI */,
			);
```

- [ ] **Step 2:** Resolve and verify the dependency

Run: `xcodebuild -resolvePackageDependencies -project Keepur.xcodeproj -scheme Keepur 2>&1 | tail -5`
Expected: Package resolution succeeds (downloads MarkdownUI + its transitive deps)

Run: `xcodebuild build -project Keepur.xcodeproj -scheme Keepur -destination 'platform=iOS Simulator,name=iPhone 16' -quiet 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3:** Commit

```bash
git add Keepur.xcodeproj/project.pbxproj
git commit -m "feat: add MarkdownUI SPM dependency

First external dependency. MarkdownUI 2.4.1+ provides full CommonMark
rendering for assistant chat bubbles (code blocks, headers, lists, links)."
```

---

### Task 3: Create custom MarkdownUI theme

**Files:**
- Create: `Views/MarkdownTheme+Keepur.swift`

Auto-discovered by Xcode via `PBXFileSystemSynchronizedRootGroup` on the `Views/` directory — no pbxproj edit needed.

- [ ] **Step 1:** Create the theme file

```swift
import MarkdownUI
import SwiftUI

extension MarkdownUI.Theme {
    static let keepur = Theme()
        .text {
            ForegroundColor(.primary)
            FontSize(.em(1))
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(.em(0.85))
            ForegroundColor(.primary)
            BackgroundColor(Color(.systemGray6))
        }
        .codeBlock { configuration in
            ScrollView(.horizontal, showsIndicators: false) {
                configuration.label
                    .markdownTextStyle {
                        FontFamilyVariant(.monospaced)
                        FontSize(.em(0.85))
                    }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(.tertiarySystemBackground))
            )
        }
        .link {
            ForegroundColor(.accentColor)
        }
        .heading1 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontWeight(.bold)
                    FontSize(.em(1.3))
                }
                .markdownMargin(top: 16, bottom: 8)
        }
        .heading2 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(.em(1.15))
                }
                .markdownMargin(top: 12, bottom: 6)
        }
        .heading3 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(.em(1.05))
                }
                .markdownMargin(top: 8, bottom: 4)
        }
}
```

- [ ] **Step 2:** Verify build

Run: `xcodebuild build -project Keepur.xcodeproj -scheme Keepur -destination 'platform=iOS Simulator,name=iPhone 16' -quiet 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3:** Commit

```bash
git add Views/MarkdownTheme+Keepur.swift
git commit -m "feat: add custom MarkdownUI theme for chat bubbles

Defines .keepur theme with monospaced code blocks on tertiary background,
scaled heading sizes, accent-colored links, and primary body text."
```

---

### Task 4: Wire up Markdown rendering in MessageBubble

**Files:**
- Modify: `Views/MessageBubble.swift:1,67-68`

- [ ] **Step 1:** Add `import MarkdownUI` at the top of the file

Change line 1 from:

```swift
import SwiftUI
```

to:

```swift
import MarkdownUI
import SwiftUI
```

- [ ] **Step 2:** Replace the `Text(LocalizedStringKey(...))` with `Markdown(...)` in the assistant bubble

Change lines 67-68 from:

```swift
                Text(LocalizedStringKey(message.text))
                    .font(.body)
```

to:

```swift
                Markdown(message.text)
                    .markdownTheme(.keepur)
```

Note: `.font(.body)` is removed because MarkdownUI manages its own text sizing via the theme. `.textSelection(.enabled)` on line 69 stays — MarkdownUI's `Markdown` view supports it.

- [ ] **Step 3:** Verify build

Run: `xcodebuild build -project Keepur.xcodeproj -scheme Keepur -destination 'platform=iOS Simulator,name=iPhone 16' -quiet 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4:** Commit

```bash
git add Views/MessageBubble.swift
git commit -m "feat: render assistant messages as rich markdown

Replace Text(LocalizedStringKey(...)) with MarkdownUI's Markdown view
using the .keepur theme. Code blocks, headers, lists, and links now
render properly in assistant chat bubbles."
```

---

### Task 5: Update CLAUDE.md

**Files:**
- Modify: `CLAUDE.md:9,29`

- [ ] **Step 1:** Update line 9

Change:

```
- No external dependencies — native frameworks only
```

to:

```
- MarkdownUI (SPM) for rich markdown rendering in chat bubbles
```

- [ ] **Step 2:** Update line 29

Change:

```
- **No external deps**: URLSessionWebSocketTask, AVFoundation, Speech framework, Security (Keychain)
```

to:

```
- **MarkdownUI** (SPM) for assistant bubble rendering; otherwise native: URLSessionWebSocketTask, AVFoundation, Speech framework, Security (Keychain)
```

- [ ] **Step 3:** Commit

```bash
git add CLAUDE.md
git commit -m "docs: update CLAUDE.md to reflect MarkdownUI dependency"
```
