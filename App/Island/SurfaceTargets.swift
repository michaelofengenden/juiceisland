import CoreGraphics

/// The island's one surface at rest, per state, from the notch and the pill's content (never hard-coded, P37):
/// - idle on a notch: exactly the notch, radius 12 (at least any real notch's corner), so it hides in the hardware;
/// - the pill: the notch and its two wings, 3 pt ears, radius 12.5, inside the menu bar (the no-notch bar: its menu
///   bar's height, radius half of that, no ears);
/// - the swell, the pointer on it: 6 pt wider in all, shared by the two sides in proportion to their reach (so the pill
///   keeps its shape), and up to 2 pt taller but never taller than the pill's body, so it never hangs below the menu bar
///   (on the owner's display it only widens);
/// - the island: Settings › Island › Width wide (480 by default, `IslandSize`), as tall as its content, 8 pt shoulders,
///   radius 20;
/// - hide when idle without a notch: a zero-height sliver at the top edge, which draws nothing (the bar also folds into
///   it and drops from it as Show as switches between Window and Island).
struct SurfaceTargets: Equatable, Sendable {
    /// nil: the no-notch top bar.
    var notch: CGSize?
    var pill: PillContent
    /// Settings › Hide the pill when idle.
    var hideWhenIdle = false
    /// Settings › Island › Width: the opened island's, shoulders included (`IslandSize.outer`, P401).
    var islandWidth = IslandSize.standard.outer

    var topBar: Bool { notch == nil }

    /// Nothing to show: the notch alone, or (no notch) the idle bar, or its sliver when hidden.
    var idle: SurfaceGeometry {
        let m = IslandTheme.Metrics.self
        if let notch { return SurfaceGeometry(width: notch.width, height: notch.height, ear: 0, radius: m.idleRadius) }
        guard !hideWhenIdle else { return sliver }
        return SurfaceGeometry(width: pill.barWidth, height: pill.bodyHeight, ear: 0, radius: pill.bodyHeight / 2)
    }

    /// No notch: the bar folded away into the top edge.
    var sliver: SurfaceGeometry { SurfaceGeometry(width: pill.barWidth, height: 0, ear: 0, radius: 0) }

    /// The closed surface: the pill, or idle when it has nothing to show.
    var closed: SurfaceGeometry {
        if pill.isEmpty { return idle }
        let e = pill.extent
        if topBar { return SurfaceGeometry(left: e.left, right: e.right, height: e.height, ear: 0, radius: e.height / 2) }
        return SurfaceGeometry(left: e.left, right: e.right, height: e.height, ear: IslandTheme.Metrics.pillEar,
                               radius: IslandTheme.Metrics.pillRadius)
    }

    /// The closed surface swollen under the pointer ("the notch noticed you" when idle), as Hover has it. A hidden sliver
    /// never swells.
    func swell(_ tuning: MotionTuning = MotionTuning()) -> SurfaceGeometry {
        Self.swollen(closed, idleNotch: notch != nil && pill.isEmpty, limit: pill.bodyHeight, tuning: tuning)
    }

    /// `g` swollen, no taller than `limit` (the pill's body, which stays inside the menu bar) unless it already is.
    static func swollen(_ g: SurfaceGeometry, idleNotch: Bool, limit: CGFloat, tuning: MotionTuning = MotionTuning()) -> SurfaceGeometry {
        let growth = tuning.swellGrowth
        guard g.height > 0, g.width > 0 else { return g }
        var s = g
        s.left += growth.width * g.left / g.width
        s.right += growth.width * g.right / g.width
        s.height = max(g.height, min(g.height + growth.height, limit))
        if idleNotch {
            s.ear = 2
        } else {
            s.radius += tuning.swellRadius
            // Hover: Quick's wider ear is the notch pill's; the no-notch bar has none, and grows none.
            if g.ear > 0 { s.ear += tuning.swellEar }
        }
        return s
    }

    /// The opened island, `height` tall.
    func island(height: CGFloat) -> SurfaceGeometry {
        let m = IslandTheme.Metrics.self
        return SurfaceGeometry(width: islandWidth, height: height, ear: m.shoulder, radius: m.bottomRadius)
    }

    /// The header's brand glyph and gear show as the surface's width crosses this span (`IslandSize.shoulderGate`).
    var shoulderGate: ClosedRange<CGFloat> { IslandSize.shoulderGate(outer: islandWidth) }
}
