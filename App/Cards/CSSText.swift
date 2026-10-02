import AppKit
import SwiftUI

/// CSS `font: <size>/<line-height>` for SwiftUI text. A CSS line box is `lineHeight` tall with the glyphs centred in
/// it (half the extra leading above, half below); SwiftUI lays text out at the font's own line height.
enum CSSText {
    /// The line pitch SwiftUI gives the system font on macOS, measured with `NSHostingView` in a 2x window (it lays
    /// lines out at whole points, above the font's own ascender + descender): size → pitch.
    static let measuredPitch: [CGFloat: CGFloat] = [9.5: 12, 10: 13, 10.5: 13, 11: 14, 11.5: 14, 12: 15, 12.5: 15, 13: 16, 14: 17]

    static func lineHeight(size: CGFloat, mono: Bool = false) -> CGFloat {
        if let pitch = measuredPitch[size] { return pitch }
        let font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: .regular) : NSFont.systemFont(ofSize: size)
        return (font.ascender - font.descender + font.leading + 0.6).rounded()
    }

    /// The extra space per line that turns SwiftUI's line pitch into the CSS `lineHeight`.
    static func extraLeading(size: CGFloat, lineHeight: CGFloat, mono: Bool = false) -> CGFloat {
        max(0, lineHeight - Self.lineHeight(size: size, mono: mono))
    }
}

extension View {
    /// One line of text in a CSS line box `height` tall.
    func lineBox(_ height: CGFloat) -> some View { frame(height: height) }

    /// Wrapping text whose lines are `lineHeight` apart, padded like a CSS line box.
    func cssLines(size: CGFloat, lineHeight: CGFloat, mono: Bool = false) -> some View {
        let extra = CSSText.extraLeading(size: size, lineHeight: lineHeight, mono: mono)
        return lineSpacing(extra).padding(.vertical, extra / 2)
    }
}

/// Coloured runs for one line of text (a status line, a question with its topic), without `Text + Text`.
struct TextRuns {
    private(set) var value = AttributedString()

    mutating func add(_ text: String, _ colour: Color, weight: Font.Weight? = nil, size: CGFloat? = nil, mono: Bool = false) {
        var run = AttributedString(text)
        run.foregroundColor = colour
        if let size {
            run.font = mono ? Fonts.mono(size, weight ?? .regular) : Fonts.sys(size, weight ?? .regular)
        }
        value += run
    }

    var text: Text { Text(value) }
}
