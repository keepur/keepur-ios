# Keepur iOS — Pairing Screen Migration to Design System

**Date**: 2026-04-30
**Status**: Draft
**Ticket**: [DOD-391](https://linear.app/dodihome/issue/DOD-391/keepur-ios-migrate-pairing-screen-to-keepurtheme-tokens)
**Parent epic**: [DOD-390](https://linear.app/dodihome/issue/DOD-390/keepur-ios-per-screen-migration-to-keepur-design-system)
**Foundation reference**: [DOD-389 spec](2026-04-30-design-system-foundation.md) (merged)

## Problem

`Views/PairingView.swift` (240 LOC, 3-step flow: host → code → name) is currently styled with inline `Color.*` / `.font(...)` / numeric paddings, system component shapes (`.roundedBorder`, `.borderedProminent`), and a `server.rack` SF Symbol as the brand mark. The app feels like a stock SwiftUI form rather than a Keepur-branded surface.

The Keepur Design System (`~/Downloads/Keepur Design System (1)/`) ships a Pairing mock at `ui_kits/ios/screens.jsx` with the brand recipe: wax-0 page background, charcoal text, JetBrains Mono pairing digits in sunken cards, a honey-amber primary CTA with honey shadow, 1px wax-200 input borders. The foundation ticket DOD-389 made the tokens for all of those available; this ticket is the first consumer.

Because Pairing is the highest-density "designed" screen in the app (logo, big heading, code grid, primary CTA, error states), it's a representative first migration. Patterns established here — the primary-button modifier, the digit-card recipe, the page background usage — propagate to every subsequent screen migration.

## Scope

### In

1. Migrate every `Color.*`, `.font(...)`, numeric padding, and corner radius in `Views/PairingView.swift` to `KeepurTheme.*` tokens.
2. Apply brand surfaces: wax page background, JetBrains Mono digit cards (charcoal-tinted sunken bg, 8pt radius), charcoal text, semantic error color, honey-tinted focus ring on text fields.
3. Extract a reusable `keepurPrimaryButton()` View modifier into `Theme/Components/PrimaryButton.swift`. Apply it to all three step CTAs.
4. Visual diff is reviewable in simulator vs main; all 4 explicit acceptance criteria from DOD-391 pass.

### Out

- SVG `keepur-mark.svg` logo from the kit. The current `server.rack` SF Symbol stays. Logo work is its own ticket so all logo placements (Pairing, Settings header, splash) are done together.
- Custom 3×4 onscreen keypad shown in the kit mock. System `numberPad` keyboard stays — it supports paste, autofill from SMS, and accessibility, which a custom grid would have to reimplement.
- Hex-comb pattern, eyebrow "STEP 1 OF 3" labels, or other speculative additions not in the kit's Pairing mock.
- Inter Tight wordmark typeface — foundation deliberately ships SF for UI; the wordmark uses `KeepurTheme.Font.h1` (SF 36pt bold).
- Any data-flow / state machine changes in `PairingView` or `APIManager.pair`. Pure styling.
- Dark-mode tuning. We use `KeepurTheme.Color.*Dynamic` aliases where they exist; the macOS static-light fallback is acceptable per foundation D2.

## Design Decisions

### D1. Fidelity level — middle ground

Retoken every value plus apply brand surfaces (page bg, primary button, digit card, focus ring). Defer SVG logo and custom keypad to their own tickets. Rationale per the brainstorm: pure retoken doesn't change the felt brand; full kit fidelity adds asset work and a debatable UX choice (custom keypad) under what should be a styling ticket.

### D2. Primary button as a reusable View modifier

Extract `keepurPrimaryButton()` into `Theme/Components/PrimaryButton.swift`. Apply with `.buttonStyle(KeepurPrimaryButtonStyle())` (SwiftUI `ButtonStyle` is the idiomatic iOS pattern, not a free-form modifier — it gets pressed-state and disabled-state for free).

```swift
struct KeepurPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(KeepurTheme.Font.button)
            .foregroundStyle(KeepurTheme.Color.fgOnHoney)
            .frame(maxWidth: .infinity)
            .padding(.vertical, KeepurTheme.Spacing.s3)
            .background(
                KeepurTheme.Color.honey500
                    .opacity(configuration.isPressed ? 0.85 : 1.0)
            )
            .clipShape(RoundedRectangle(cornerRadius: KeepurTheme.Radius.md))
            .keepurShadow(.honey)
            .opacity(isEnabled ? 1.0 : 0.4)
    }

    @Environment(\.isEnabled) private var isEnabled
}
```

Disabled state opacity matches the kit mock (0.4). Pressed state opacity (0.85) is a small interaction polish — the kit shows a static state but iOS users expect touch feedback. This is the only "speculative" addition in the spec; defensible because it's standard iOS behavior and trivial.

### D3. Pairing code digit card

Adapted from the reference snippet at the bottom of `KeepurTheme.swift` and the kit mock. The current implementation also has a critical behavior — the digit cell is a tap target that re-focuses the hidden code TextField — that **must be preserved**.

```swift
Text(digit)
    .font(.custom(KeepurTheme.FontName.monoBold, size: 32))
    .frame(maxWidth: .infinity, minHeight: 56)
    .foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)
    .background(KeepurTheme.Color.charcoal900.opacity(0.05))
    .clipShape(RoundedRectangle(cornerRadius: KeepurTheme.Radius.xs))
    .contentShape(Rectangle())
    .onTapGesture { codeFieldFocused = true }
```

Notes:
- **Tap gesture is non-negotiable**: the code TextField is hidden (`opacity: 0`, `height: 1`); without `onTapGesture` re-focusing it, dismissing the keyboard breaks the code step entirely. `contentShape(Rectangle())` ensures the entire cell area is tappable, including transparent regions.
- 32pt (down from current 36pt) matches the kit's reference snippet — leaves room for 6 digits across the screen at iPhone width without horizontal compression.
- `JetBrainsMono-SemiBold` (the `monoBold` constant) instead of `.system(.monospaced, weight: .bold)` — the foundation work explicitly bundled this for exactly this surface.
- `KeepurTheme.Radius.xs` (6pt) instead of the current 8pt — closer to the kit's tighter feel. (The reference snippet says 8pt; choosing 6pt to align with the token vocabulary. If 6pt feels too tight in simulator, fall back to inline 8pt.)

### D4. Text field treatment

iOS `.roundedBorder` style is opinionated and doesn't accept brand colors. Replace with a custom decoration so the field can show the wax-0 surface, 1px wax-200 border, and an optional honey focus ring:

```swift
TextField("beekeeper.example.com", text: $host)
    .font(KeepurTheme.Font.body)
    .padding(.vertical, KeepurTheme.Spacing.s3)
    .padding(.horizontal, KeepurTheme.Spacing.s4)
    .background(KeepurTheme.Color.bgSurfaceDynamic)
    .clipShape(RoundedRectangle(cornerRadius: KeepurTheme.Radius.sm))
    .overlay(
        RoundedRectangle(cornerRadius: KeepurTheme.Radius.sm)
            .stroke(KeepurTheme.Color.borderDefaultDynamic, lineWidth: 1)
    )
    .keepurFocusRing(hostFieldFocused, radius: KeepurTheme.Radius.sm)
```

`keepurFocusRing` already exists in the foundation. Vertical padding `s3` = 12pt is exact match for the kit's `12px`. Horizontal padding `s4` = 16pt vs the kit's 14px is a 2pt difference — visually imperceptible at iPhone resolution and keeps the value derivable from tokens (no hard-coded 14).

### D5. Page background and layout chrome

Wrap the whole `body` in:

```swift
VStack(spacing: KeepurTheme.Spacing.s6) { ... }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(KeepurTheme.Color.bgPageDynamic)
```

`bgPageDynamic` is wax-0 (`#FFFDF8`) on light, charcoal-900 on dark. This is the ticket's biggest single visual lift — the off-white background is the brand's most distinguishing surface trait.

Logo container (the existing `server.rack` SF Symbol):

```swift
Image(systemName: KeepurTheme.Symbol.server)
    .font(.system(size: 48))
    .foregroundStyle(KeepurTheme.Color.honey500)
```

Foundation already ships `KeepurTheme.Symbol.server = "server.rack"`, so this is a clean swap.

### D6. Wordmark and subtitle

```swift
Text("Keepur")
    .font(KeepurTheme.Font.h1)
    .tracking(KeepurTheme.Font.lsH1)
    .foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)

Text(subtitle)
    .font(KeepurTheme.Font.bodySm)
    .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
    .multilineTextAlignment(.center)
```

`Font.h1` is SF 36pt bold (matches kit's 36pt 700); `lsH1` is the matching tracking value. `fgPrimaryDynamic` and `fgSecondaryDynamic` give us light/dark adaptation on iOS for free.

### D7. Error message

```swift
Text(errorMessage)
    .font(KeepurTheme.Font.caption)
    .foregroundStyle(KeepurTheme.Color.danger)
```

`Font.caption` is SF 12pt medium (matches kit's footnote sizing); `Color.danger` is the foundation's `#C92A2A`. The current `.font(.footnote)` is 13pt — close enough that the visual difference is invisible.

## File Layout (after this ticket)

```
Theme/
    KeepurTheme.swift                       (UNCHANGED)
    Components/
        PrimaryButton.swift                 (NEW, ~25 LOC — KeepurPrimaryButtonStyle)
Views/
    PairingView.swift                       (REWRITTEN — same surface, new tokens)
KeeperTests/                                (UNCHANGED — existing pairing flow tests cover behavior)
```

## Implementation Outline

1. **Preconditions**:
   - On branch `DOD-391` worktree, off `main` at `6c8d0b3` (foundation merged).
   - `Theme/KeepurTheme.swift` exists and exports the tokens this spec references. Sanity-check: `grep -n "honey500\|fgPrimaryDynamic\|Spacing.s6\|Radius.md\|FontName.monoBold\|Symbol.server\|keepurFocusRing\|keepurShadow" Theme/KeepurTheme.swift` should return matches for each.
   - JetBrains Mono fonts are bundled and registered (verified by `KeepurThemeFontsTests` passing on foundation).

2. **Create `Theme/Components/PrimaryButton.swift`** with `KeepurPrimaryButtonStyle` per D2. Add to Compile Sources for the Keepur target via the `xcodeproj` Ruby gem (same script pattern as DOD-389 Task 5).

3. **Rewrite `Views/PairingView.swift`**:
   - Replace `body`'s root VStack with the page-background wrapper from D5.
   - Replace the logo `Image` with the D5 form using `KeepurTheme.Symbol.server` + `KeepurTheme.Color.honey500`.
   - Replace wordmark and subtitle with D6 forms.
   - Build a private helper view extension `KeepurTextField` (or inline modifier helper) implementing D4. Apply to host and device-name text fields. The 1px hidden code TextField stays unmodified — it's invisible.
   - Replace the digit-box helper with the D3 form.
   - Replace all three step CTAs (`Continue` × 2, `Pair device` × 1) with `.buttonStyle(KeepurPrimaryButtonStyle())`. Drop `.borderedProminent`.
   - **Restructure the name step layout**: the current `HStack(spacing: 12) { Back; Continue }` (lines 166–179) cannot keep using HStack with the new style — `KeepurPrimaryButtonStyle` applies `frame(maxWidth: .infinity)` which makes the Continue button try to fill all available width, distorting the HStack. Replace the HStack with a VStack: full-width `Continue` (primary CTA) on top, plain-text `Back` button below — mirroring the layout step 1 (code) already uses for its Back button. Functionally identical, visually consistent across steps.
   - Replace the error `Text` with D7 form.
   - Replace inline padding numbers (40, 16, 8, 32, etc.) with `KeepurTheme.Spacing.*` tokens.
   - Keep the "Back" button as a plain text button (font: `KeepurTheme.Font.bodySm`, color: `KeepurTheme.Color.fgSecondaryDynamic`) — it's not a primary CTA.

4. **Visual diff in simulator** (iOS, iPhone 17). Step through host → code → name. Confirm:
   - Wax page background visible behind every step.
   - Honey CTA with shadow on each step's primary button.
   - JetBrains Mono digits in sunken cards on the code step.
   - Honey focus ring appears when text fields are tapped.
   - Error state shows the danger color, not system red.
   - No regressions: typing, paste-into-code, back navigation all work.

5. **Run the test suite** on iOS and macOS. Existing pairing tests must still pass (no behavior change). The font smoke test from foundation must still pass.

6. **Commit boundaries**:
   - C1: `feat: add KeepurPrimaryButtonStyle (DOD-391)` — Theme/Components/PrimaryButton.swift + xcodeproj wiring.
   - C2: `feat: migrate Pairing screen to KeepurTheme tokens (DOD-391)` — Views/PairingView.swift rewrite.

## Risks & Open Questions

- **Visual judgement calls in simulator**: The spec values (32pt digits, 6pt vs 8pt radius, 14pt vs 16pt input padding) are derived from the kit + the token vocabulary. Some may need tweaking once seen on a real device. Mitigation: implementation step 4 explicitly opens these for adjustment; record the final chosen values in the PR description.
- **`KeepurPrimaryButtonStyle` lives in `Theme/Components/`**: This creates a new subdirectory pattern that future component extractions (`KeepurTextField`, `KeepurCard`, etc.) will follow. Locked-in convention. If the team later prefers `Views/Components/` or similar, this gets renamed across the codebase. Acceptable risk — the migration epic is the right time to set this convention.
- **Disabled-state styling**: The `.opacity(0.4)` on the disabled button (D2) is the only deviation from the kit's `opacity: host.trim() ? 1 : 0.4` mock. Identical effect. No risk.
- **macOS `*Dynamic` light-only fallback**: Per foundation D2, on macOS the `Dynamic` aliases return the light value. The Pairing screen will look wax-0 even in macOS dark mode. Acceptable for this ticket; epic-level concern.
- **Existing pairing flow tests** in `KeeperTests/` — verify they don't reference internal layout state (e.g., test naming a "Continue" button by exact font). Quick grep at implementation time.

## Follow-up

After this lands, the next migration ticket (likely Settings or Session List) will:
- Reuse `KeepurPrimaryButtonStyle`.
- Likely extract a second component (e.g., `KeepurTextField` if the D4 inline pattern proves repetitive).
- Consume `bgPageDynamic` as the established convention.

Logo (`keepur-mark.svg`) and custom-keypad tickets are still open under epic DOD-390 and can be filed when prioritized.
