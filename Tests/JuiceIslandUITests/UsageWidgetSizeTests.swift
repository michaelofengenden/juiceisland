import Foundation
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// The Usage widget against the owner's complaints of 2026-10-05 ("the batteries really small", "does see the finished
/// runs"), at the sizes the renders take for macOS's and the next class down (P1402): the batteries are the panel's at
/// least, never a strip, and grow on the large face; no session, running or finished, ever draws.
@MainActor
@Suite(.serialized)
struct UsageWidgetSizeTests {
    static let now = DemoClock.now

    static func inner(_ face: WidgetFace, compact: Bool) -> CGSize {
        let size = UsageWidgetRenders.size(face, compact: compact)
        return CGSize(width: size.width - 2 * UsageWidgetRenders.margin, height: size.height - 2 * UsageWidgetRenders.margin)
    }

    /// The owner's accounts draw at the panel's size on the small and medium faces and larger on the large one, at both
    /// size classes; the crowded set (six accounts a provider) never below nine tenths of it.
    @Test func theBatteriesAreThePanelsAtEverySize() {
        for compact in [false, true] {
            let owner = UsageWidgetRenders.owner(), crowded = UsageWidgetRenders.crowded()
            #expect(UsageWidgetLayout.make(owner, face: .small, size: Self.inner(.small, compact: compact)).scale == 1)
            #expect(UsageWidgetLayout.make(owner, face: .medium, size: Self.inner(.medium, compact: compact)).scale == 1)
            let large = UsageWidgetLayout.make(owner, face: .large, size: Self.inner(.large, compact: compact))
            #expect(large.scale >= 1.5, "large grows them: \(large.scale)")
            for face in [WidgetFace.medium, .large] {
                let size = Self.inner(face, compact: compact)
                let layout = UsageWidgetLayout.make(crowded, face: face, size: size)
                #expect(layout.scale >= 0.9, "\(face) \(compact): \(layout.scale)")
                let natural = (face == .large ? 0 : Theme.Panel.markSize + Theme.Panel.markGap) + UsageWidgetLayout.runWidth(6)
                #expect(natural * layout.scale <= size.width + 0.5, "\(face) \(compact): fits the width")
            }
        }
    }

    /// Sessions never reach the Usage widget: the same snapshot with needs-you rows, running rows and the app's other
    /// rows draws pixel for pixel what it draws with none, on every face, in full colour and dimmed.
    @Test func noSessionEverDraws() throws {
        let bare = UsageWidgetRenders.owner()
        var busy = bare
        busy.rows = WidgetSnapshot.preview(at: Self.now).rows
        busy.more = 3
        for face in WidgetFace.allCases {
            for mono in [false, true] {
                let size = Self.inner(face, compact: false)
                func pixels(_ snapshot: WidgetSnapshot) throws -> [UInt8] {
                    let view = UsageWidgetView(snapshot: snapshot, face: face, size: size, date: Self.now, mono: mono)
                    return try ThemeTests.pixels(ZStack { Color.black; view }, size: size).data
                }
                #expect(try pixels(busy) == pixels(bare), "\(face) \(mono)")
            }
        }
    }
}
