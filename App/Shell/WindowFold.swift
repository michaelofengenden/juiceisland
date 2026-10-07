import AppKit
import QuartzCore

/// The switch to Island (prototype L409-419, L1476-1524): the window folds into the notch, 0.75 s on
/// cubic-bezier(.6, 0, .25, 1), shrinking to the closed pill's frame while it fades (opaque until 55 %). A snapshot
/// does the animating, so the real window never resizes below its minimum: Core Animation moves it in one still,
/// click-through window over the whole path (`Stage`), so the fold keeps every frame of the display (120 a second on a
/// ProMotion screen) on the render server, whatever the main thread does meanwhile. (A ghost window resized a step at
/// a time by `animator().setFrame` moved at the main thread's pace: 60 steps a second at best, and none while the
/// island was being built at the landing, P102.) At `landingAt` of the fold the island's panel orders in (black on black
/// under the notch) and its pill arrives from behind the notch while the ghost finishes shrinking into the same place:
/// no window fades in after it. Switching back mid-fold cancels the ghost (`Handle.cancel`). Reduce Motion: no
/// animation, the window just goes.
@MainActor
enum WindowFold {
    static let duration: TimeInterval = 0.75
    static let pillSize = CGSize(width: 244, height: 33)
    /// The island takes over this far into the fold.
    static let landingAt = 0.7
    /// The ghost starts fading this far into the fold.
    static let fadeFrom = 0.55
    static let curve = CAMediaTimingFunction(controlPoints: 0.6, 0, 0.25, 1)
    /// Room around the path for the snapshot's shadow.
    static let shadowRoom: CGFloat = 64
    /// A large move the eye tracks: 80 to 120 Hz, preferring 120 (`IslandFramePacing.motion`), asked of the display only
    /// while the fold plays.
    static let frameRate = IslandFramePacing.motion

    /// A fold in flight; `cancel()` removes its ghost at once and drops its landing and completion.
    @MainActor
    final class Handle {
        fileprivate var ghost: NSWindow?
        fileprivate var cancelled = false

        func cancel() {
            cancelled = true
            ghost?.orderOut(nil)
            ghost = nil
        }
    }

    /// Where the fold ends: the pill's frame, centred at the top of `screen` (AppKit coordinates, y up).
    static func target(screenFrame: CGRect, pill: CGSize = pillSize) -> CGRect {
        CGRect(x: screenFrame.midX - pill.width / 2, y: screenFrame.maxY - pill.height, width: pill.width, height: pill.height)
    }

    /// Opacity along the fold: 1 until 55 % of the time, then linearly to 0.
    static func opacity(at progress: Double) -> Double {
        let p = min(max(progress, 0), 1)
        return p <= fadeFrom ? 1 : max(0, (1 - p) / (1 - fadeFrom))
    }

    /// The ghost's window and the snapshot's path in it: the window covers the window's frame, the pill's and the
    /// shadow's room around them, and never moves or resizes.
    struct Stage: Equatable {
        /// The ghost window's frame (screen coordinates, y up).
        var frame: CGRect
        /// The snapshot's frame at the start (the window's) and at the end (the pill's), in the ghost's coordinates.
        var from: CGRect
        var to: CGRect
    }

    static func stage(window: CGRect, pill: CGRect) -> Stage {
        let frame = window.union(pill).insetBy(dx: -shadowRoom, dy: -shadowRoom).integral
        return Stage(frame: frame, from: window.offsetBy(dx: -frame.minX, dy: -frame.minY),
                     to: pill.offsetBy(dx: -frame.minX, dy: -frame.minY))
    }

    /// The ghost's layers at the fold's start, in a layer the size of the stage: the snapshot, rounded as the window
    /// is, over a black rounded rectangle that casts the window's shadow.
    static func layers(_ snapshot: CGImage, stage: Stage) -> CALayer {
        let ghost = CALayer()
        ghost.frame = CGRect(origin: .zero, size: stage.frame.size)
        ghost.allowsGroupOpacity = true
        let shadow = CALayer()
        shadow.backgroundColor = .black
        shadow.shadowColor = .black
        shadow.shadowOpacity = 0.5
        shadow.shadowRadius = 20
        shadow.shadowOffset = CGSize(width: 0, height: -12)
        let image = CALayer()
        image.contents = snapshot
        image.contentsGravity = .resize
        image.masksToBounds = true
        for layer in [shadow, image] {
            layer.cornerRadius = WindowTheme.Metrics.radius
            layer.frame = stage.from
            ghost.addSublayer(layer)
        }
        return ghost
    }

    /// Plays the fold on `layers(_:stage:)`: the snapshot and its shadow shrink to the pill on the fold's curve while the
    /// whole ghost fades as `opacity(at:)` says. The layers are left where the animations end, so nothing snaps back.
    static func play(_ ghost: CALayer, stage: Stage) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let moves: [(key: String, from: NSValue, to: NSValue)] = [
            ("bounds", NSValue(rect: CGRect(origin: .zero, size: stage.from.size)), NSValue(rect: CGRect(origin: .zero, size: stage.to.size))),
            ("position", NSValue(point: CGPoint(x: stage.from.midX, y: stage.from.midY)), NSValue(point: CGPoint(x: stage.to.midX, y: stage.to.midY))),
        ]
        for layer in ghost.sublayers ?? [] {
            for move in moves {
                let animation = CABasicAnimation(keyPath: move.key)
                animation.fromValue = move.from
                animation.toValue = move.to
                animation.duration = duration
                animation.timingFunction = curve
                animation.preferredFrameRateRange = frameRate
                layer.add(animation, forKey: move.key)
            }
            layer.frame = stage.to
        }
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.keyTimes = [0, NSNumber(value: fadeFrom), 1]
        fade.values = [opacity(at: 0), opacity(at: fadeFrom), opacity(at: 1)]
        fade.duration = duration
        fade.preferredFrameRateRange = frameRate
        ghost.add(fade, forKey: "opacity")
        ghost.opacity = Float(opacity(at: 1))
        CATransaction.commit()
    }

    /// A terminal window sent to the island (P1302): a plain glass shape the size of its frame, never its pixels (the app
    /// has no Screen Recording and never asks for it), rounded as a window is, with the fold's shadow.
    static func glassLayers(stage: Stage, radius: CGFloat = terminalRadius) -> CALayer {
        let ghost = CALayer()
        ghost.frame = CGRect(origin: .zero, size: stage.frame.size)
        ghost.allowsGroupOpacity = true
        let shadow = CALayer()
        shadow.backgroundColor = CGColor(gray: 0, alpha: 0.35)
        shadow.shadowColor = .black
        shadow.shadowOpacity = 0.4
        shadow.shadowRadius = 20
        shadow.shadowOffset = CGSize(width: 0, height: -12)
        // The glass: a cool frost over whatever is behind, a brighter rim, and a sheen that fades down its face.
        let glass = CAGradientLayer()
        glass.colors = [CGColor(gray: 1, alpha: 0.30), CGColor(gray: 1, alpha: 0.14)]
        glass.startPoint = CGPoint(x: 0.5, y: 1)
        glass.endPoint = CGPoint(x: 0.5, y: 0)
        glass.borderColor = CGColor(gray: 1, alpha: 0.55)
        glass.borderWidth = 1
        glass.masksToBounds = true
        for layer in [shadow, glass] {
            layer.cornerRadius = radius
            layer.frame = stage.from
            ghost.addSublayer(layer)
        }
        return ghost
    }

    /// A terminal window's corner radius on macOS 26, near enough for a shape that is gone in 0.75 s.
    static let terminalRadius: CGFloat = 12

    /// A terminal window sent to the island (P1302): its glass shape (`glassLayers`) flies from where the window was
    /// into the pill on the window fold's own path, curve and fade (`play`), in a still, click-through window of its own,
    /// while the terminal puts the window itself into the Dock. Reduce Motion: nothing moves.
    @discardableResult
    static func flyIn(from frame: CGRect, into pill: CGRect) -> Handle {
        let handle = Handle()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, frame.width > 1, frame.height > 1 else { return handle }
        let stage = stage(window: frame, pill: pill)
        let ghost = NSWindow(contentRect: stage.frame, styleMask: .borderless, backing: .buffered, defer: false)
        ghost.isOpaque = false
        ghost.backgroundColor = .clear
        ghost.hasShadow = false
        ghost.ignoresMouseEvents = true
        ghost.level = .statusBar
        ghost.isReleasedWhenClosed = false
        ghost.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        let host = NSView(frame: CGRect(origin: .zero, size: stage.frame.size))
        host.layer = CALayer()
        host.wantsLayer = true
        let layers = glassLayers(stage: stage)
        host.layer?.addSublayer(layers)
        ghost.contentView = host
        play(layers, stage: stage)
        CATransaction.flush()
        ghost.orderFrontRegardless()
        handle.ghost = ghost
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(duration))
            guard !handle.cancelled else { return }
            handle.ghost = nil
            ghost.orderOut(nil)
        }
        return handle
    }

    @discardableResult
    static func fold(_ window: NSWindow, into pill: CGRect? = nil, landing: @escaping @MainActor () -> Void = {},
                     completion: @escaping @MainActor () -> Void) -> Handle {
        let handle = Handle()
        guard window.isVisible, let screen = window.screen ?? NSScreen.main,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let content = window.contentView,
              let snapshot = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
            window.orderOut(nil)
            landing()
            completion()
            return handle
        }
        content.cacheDisplay(in: content.bounds, to: snapshot)
        guard let image = snapshot.cgImage else {
            window.orderOut(nil)
            landing()
            completion()
            return handle
        }

        let stage = stage(window: window.frame, pill: pill ?? target(screenFrame: screen.frame))
        let ghost = NSWindow(contentRect: stage.frame, styleMask: .borderless, backing: .buffered, defer: false)
        ghost.isOpaque = false
        ghost.backgroundColor = .clear
        ghost.hasShadow = false
        ghost.ignoresMouseEvents = true
        ghost.level = window.level
        ghost.isReleasedWhenClosed = false
        // A layer-hosting view: its layers are ours, and AppKit leaves them alone.
        let host = NSView(frame: CGRect(origin: .zero, size: stage.frame.size))
        host.layer = CALayer()
        host.wantsLayer = true
        let layers = layers(image, stage: stage)
        host.layer?.addSublayer(layers)
        ghost.contentView = host
        play(layers, stage: stage)
        // The ghost's layers reach the render server before it shows, so no frame goes by with neither window.
        CATransaction.flush()
        ghost.orderFront(nil)
        window.orderOut(nil)
        handle.ghost = ghost

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(duration * landingAt))
            guard !handle.cancelled else { return }
            landing()
            try? await Task.sleep(for: .seconds(duration * (1 - landingAt)))
            guard !handle.cancelled else { return }
            handle.ghost = nil
            ghost.orderOut(nil)
            completion()
        }
        return handle
    }
}
