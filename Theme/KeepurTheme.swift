//
//  KeepurTheme.swift
//  Keepur Design System — Swift port
//
//  Mirrors `colors_and_type.css`. One source of truth for the iOS client.
//
//  Honey Amber on Warm White. One accent color, warm neutrals, San Francisco
//  for UI text and JetBrains Mono for code/identifiers.
//
//  Usage:
//      Text("Pair device")
//          .font(KeepurTheme.Font.button)
//          .foregroundStyle(KeepurTheme.Color.fgPrimary)
//          .padding(.horizontal, KeepurTheme.Spacing.s4)
//          .background(KeepurTheme.Color.honey500)
//          .clipShape(RoundedRectangle(cornerRadius: KeepurTheme.Radius.lg))
//          .keepurShadow(.honey)
//
//  Drop the JetBrainsMono .ttf files into the bundle and register them
//  under `UIAppFonts` in Info.plist before using `KeepurTheme.Font.mono`.
//

import SwiftUI

// MARK: - Namespace

public enum KeepurTheme {}

// MARK: - Color

public extension KeepurTheme {
    enum Color {
        // Honey — the only accent color in the system
        public static let honey100 = SwiftUI.Color(hex: 0xFFF4DC)
        public static let honey200 = SwiftUI.Color(hex: 0xFFE6B0)
        public static let honey300 = SwiftUI.Color(hex: 0xFFD383)
        public static let honey400 = SwiftUI.Color(hex: 0xFFC163)
        public static let honey500 = SwiftUI.Color(hex: 0xF5A524) // hero
        public static let honey600 = SwiftUI.Color(hex: 0xD98A0B) // pressed / hover
        public static let honey700 = SwiftUI.Color(hex: 0xA86A05)
        public static let honey800 = SwiftUI.Color(hex: 0x704600)

        // Beeswax — warm neutrals
        public static let wax0    = SwiftUI.Color(hex: 0xFFFDF8) // page bg
        public static let wax50   = SwiftUI.Color(hex: 0xFAF6EC)
        public static let wax100  = SwiftUI.Color(hex: 0xF1EADA)
        public static let wax200  = SwiftUI.Color(hex: 0xE4D9BF)
        public static let wax300  = SwiftUI.Color(hex: 0xCDBF9B)
        public static let wax400  = SwiftUI.Color(hex: 0xA89A78)
        public static let wax500  = SwiftUI.Color(hex: 0x887B5C)
        public static let wax600  = SwiftUI.Color(hex: 0x6B5F42)
        public static let wax700  = SwiftUI.Color(hex: 0x4E442E)
        public static let wax800  = SwiftUI.Color(hex: 0x3A3122)
        public static let charcoal900 = SwiftUI.Color(hex: 0x1B1510)

        // Semantic
        public static let success = SwiftUI.Color(hex: 0x2F9E44)
        public static let warning = SwiftUI.Color(hex: 0xE0A200)
        public static let danger  = SwiftUI.Color(hex: 0xC92A2A)
        public static let info    = SwiftUI.Color(hex: 0x1971C2)

        // Foreground / background aliases (light mode values; see dynamic helpers below)
        public static let bgPage     = wax0
        public static let bgSurface  = SwiftUI.Color.white
        public static let bgBanded   = wax50
        public static let bgSunken   = wax100
        public static let bgCode     = SwiftUI.Color(hex: 0xFBF7EC)

        public static let fgPrimary   = charcoal900
        public static let fgSecondary = wax700
        public static let fgTertiary  = wax500
        public static let fgMuted     = wax400
        public static let fgOnHoney   = charcoal900
        public static let fgOnDark    = wax50

        public static let borderDefault = wax200
        public static let borderStrong  = wax300
        public static let borderSubtle  = wax100

        public static let accent       = honey500
        public static let accentHover  = honey600
        public static let accentTint   = honey100
        public static let focusRing    = SwiftUI.Color(hex: 0xF5A524, opacity: 0.35)

        // Dynamic colors that adapt to dark mode (use these when possible)
        public static let bgPageDynamic = SwiftUI.Color.dynamic(
            light: wax0,
            dark: charcoal900
        )
        public static let bgSurfaceDynamic = SwiftUI.Color.dynamic(
            light: .white,
            dark: SwiftUI.Color(hex: 0x261E16)
        )
        public static let bgSunkenDynamic = SwiftUI.Color.dynamic(
            light: wax100,
            dark: SwiftUI.Color(hex: 0x17110C)
        )
        public static let fgPrimaryDynamic = SwiftUI.Color.dynamic(
            light: charcoal900,
            dark: wax50
        )
        public static let fgSecondaryDynamic = SwiftUI.Color.dynamic(
            light: wax700,
            dark: SwiftUI.Color(hex: 0xCFC3A6)
        )
        public static let borderDefaultDynamic = SwiftUI.Color.dynamic(
            light: wax200,
            dark: SwiftUI.Color.white.opacity(0.10)
        )
    }
}

// MARK: - Spacing (4px base grid)

public extension KeepurTheme {
    enum Spacing {
        public static let s0:  CGFloat = 0
        public static let s1:  CGFloat = 4
        public static let s2:  CGFloat = 8
        public static let s3:  CGFloat = 12
        public static let s4:  CGFloat = 16
        public static let s5:  CGFloat = 24
        public static let s6:  CGFloat = 32
        public static let s7:  CGFloat = 40
        public static let s8:  CGFloat = 48
        public static let s10: CGFloat = 64
        public static let s12: CGFloat = 96
        public static let s16: CGFloat = 128
    }
}

// MARK: - Radii
//
// Mirrors the iOS client's existing values exactly:
//   bubble = 18, tool card = 14, attachment chip = 12, code block = 10, small chip = 8.

public extension KeepurTheme {
    enum Radius {
        public static let xs:   CGFloat = 6     // chips, badges
        public static let sm:   CGFloat = 10    // code blocks, small cards
        public static let md:   CGFloat = 14    // tool output, secondary cards
        public static let lg:   CGFloat = 18    // primary chat bubbles, large cards
        public static let xl:   CGFloat = 24    // modal sheets
        public static let pill: CGFloat = 999
    }
}

// MARK: - Typography
//
// iOS uses San Francisco for UI (system font). JetBrains Mono is bundled for
// code, commands, file paths, pairing codes, and `.mono` eyebrow treatments.

public extension KeepurTheme {
    enum FontName {
        public static let mono       = "JetBrainsMono-Regular"
        public static let monoMedium = "JetBrainsMono-Medium"
        public static let monoBold   = "JetBrainsMono-SemiBold"
    }

    enum Font {
        // Display tier (System SF, anchors the wordmark feel on iOS)
        public static let display = SwiftUI.Font.system(size: 48, weight: .bold,     design: .default)
        public static let h1      = SwiftUI.Font.system(size: 36, weight: .bold,     design: .default)
        public static let h2      = SwiftUI.Font.system(size: 28, weight: .semibold, design: .default)
        public static let h3      = SwiftUI.Font.system(size: 22, weight: .semibold, design: .default)
        public static let h4      = SwiftUI.Font.system(size: 18, weight: .semibold, design: .default)

        // Body tier
        public static let body    = SwiftUI.Font.system(size: 16, weight: .regular,  design: .default)
        public static let bodySm  = SwiftUI.Font.system(size: 14, weight: .regular,  design: .default)
        public static let caption = SwiftUI.Font.system(size: 12, weight: .medium,   design: .default)
        public static let eyebrow = SwiftUI.Font.system(size: 12, weight: .semibold, design: .default)
        public static let button  = SwiftUI.Font.system(size: 15, weight: .semibold, design: .default)

        // Mono — ship JetBrainsMono in the bundle. Falls back to SF Mono if missing.
        public static let mono    = SwiftUI.Font.custom(FontName.mono,       size: 14)
        public static let monoMd  = SwiftUI.Font.custom(FontName.monoMedium, size: 14)
        public static let monoLg  = SwiftUI.Font.custom(FontName.monoMedium, size: 16)

        // Letter spacing values (apply with .tracking() in SwiftUI)
        public static let lsDisplay: CGFloat = -0.96   // -0.02em * 48
        public static let lsH1:      CGFloat = -0.72   // -0.02em * 36
        public static let lsH2:      CGFloat = -0.42   // -0.015em * 28
        public static let lsH3:      CGFloat = -0.22   // -0.01em * 22
        public static let lsEyebrow: CGFloat = 0.96    // 0.08em * 12
    }
}

// MARK: - Shadow

public extension KeepurTheme {
    struct Shadow {
        public let color: SwiftUI.Color
        public let radius: CGFloat
        public let x: CGFloat
        public let y: CGFloat

        public static let xs    = Shadow(color: .black.opacity(0.06), radius: 2,  x: 0, y: 1)
        public static let sm    = Shadow(color: .black.opacity(0.06), radius: 6,  x: 0, y: 2)
        public static let md    = Shadow(color: .black.opacity(0.08), radius: 24, x: 0, y: 8)
        public static let lg    = Shadow(color: .black.opacity(0.12), radius: 48, x: 0, y: 20)
        public static let xl    = Shadow(color: .black.opacity(0.16), radius: 80, x: 0, y: 32)
        // Honey — only on the primary CTA
        public static let honey = Shadow(
            color: SwiftUI.Color(hex: 0xF5A524, opacity: 0.28),
            radius: 18, x: 0, y: 6
        )
    }
}

public extension View {
    /// Apply a Keepur shadow token: `.keepurShadow(.md)` / `.keepurShadow(.honey)`
    func keepurShadow(_ shadow: KeepurTheme.Shadow) -> some View {
        self.shadow(color: shadow.color, radius: shadow.radius, x: shadow.x, y: shadow.y)
    }
}

// MARK: - Motion

public extension KeepurTheme {
    enum Motion {
        public static let durMicro:    Double = 0.18
        public static let durStandard: Double = 0.24
        public static let durLarge:    Double = 0.40

        /// "Honey drip" easing — cubic-bezier(0.2, 0.8, 0.2, 1).
        /// SwiftUI's spring response/damping approximation.
        public static let easeHoney = SwiftUI.Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: durStandard)

        public static func easeHoney(_ duration: Double) -> SwiftUI.Animation {
            .timingCurve(0.2, 0.8, 0.2, 1, duration: duration)
        }
    }
}

// MARK: - SF Symbols
//
// Canonical icon names lifted from the Swift source. Use these constants
// instead of typing the string at the call site so the icon set stays
// auditable.

public extension KeepurTheme {
    enum Symbol {
        public static let plus        = "plus.circle.fill"
        public static let send        = "arrow.up.circle.fill"
        public static let mic         = "mic.fill"
        public static let speaker     = "speaker.wave.2"
        public static let settings    = "gearshape"
        public static let terminal    = "terminal.fill"
        public static let chat        = "bubble.left.and.bubble.right"
        public static let bolt        = "bolt.fill"
        public static let server      = "server.rack"
        public static let chevronBack = "chevron.left"
        public static let check       = "checkmark"
        public static let xmark       = "xmark"
    }
}

// MARK: - Convenience view modifiers

public extension View {
    /// 1px wax-200 resting border on cards and inputs.
    func keepurBorder(
        _ color: SwiftUI.Color = KeepurTheme.Color.borderDefault,
        radius: CGFloat = KeepurTheme.Radius.md,
        width: CGFloat = 1
    ) -> some View {
        self.overlay(
            RoundedRectangle(cornerRadius: radius)
                .stroke(color, lineWidth: width)
        )
    }

    /// Focus ring: 2px honey-500 + 3px halo at 25%.
    func keepurFocusRing(_ visible: Bool, radius: CGFloat = KeepurTheme.Radius.sm) -> some View {
        self.overlay(
            RoundedRectangle(cornerRadius: radius)
                .stroke(KeepurTheme.Color.honey500, lineWidth: visible ? 2 : 0)
                .shadow(color: KeepurTheme.Color.focusRing,
                        radius: visible ? 3 : 0)
        )
    }
}

// MARK: - Color helpers

public extension SwiftUI.Color {
    /// Build a Color from a 0xRRGGBB hex literal: `Color(hex: 0xF5A524)`.
    init(hex: UInt32, opacity: Double = 1) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >>  8) & 0xFF) / 255.0
        let b = Double( hex        & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: opacity)
    }

    /// Light/dark dynamic color. Falls back to `light` on platforms that
    /// don't support trait-based UIColor resolution.
    static func dynamic(light: SwiftUI.Color, dark: SwiftUI.Color) -> SwiftUI.Color {
        #if canImport(UIKit)
        return SwiftUI.Color(UIColor { trait in
            trait.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
        #else
        return light
        #endif
    }
}

// MARK: - Reference snippets (delete or move to your views)
//
// Primary CTA:
//
//   Button("Pair device") { /* ... */ }
//       .font(KeepurTheme.Font.button)
//       .foregroundStyle(KeepurTheme.Color.fgOnHoney)
//       .padding(.vertical, KeepurTheme.Spacing.s3)
//       .frame(maxWidth: .infinity)
//       .background(KeepurTheme.Color.honey500)
//       .clipShape(RoundedRectangle(cornerRadius: KeepurTheme.Radius.md))
//       .keepurShadow(.honey)
//
// User chat bubble (right-aligned, honey, 18pt radius with 6pt tail):
//
//   Text(message)
//       .font(KeepurTheme.Font.body)
//       .foregroundStyle(KeepurTheme.Color.fgOnHoney)
//       .padding(.horizontal, 14)
//       .padding(.vertical, 10)
//       .background(KeepurTheme.Color.honey500)
//       .clipShape(.rect(
//           topLeadingRadius:     KeepurTheme.Radius.lg,
//           bottomLeadingRadius:  KeepurTheme.Radius.lg,
//           bottomTrailingRadius: 6,
//           topTrailingRadius:    KeepurTheme.Radius.lg
//       ))
//
// Pairing code digit (mono, sunken card, 8pt radius):
//
//   Text(digit)
//       .font(.custom(KeepurTheme.FontName.monoBold, size: 32))
//       .frame(width: 48, height: 56)
//       .background(KeepurTheme.Color.charcoal900.opacity(0.05))
//       .clipShape(RoundedRectangle(cornerRadius: 8))
