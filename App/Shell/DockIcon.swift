import AppKit
import Observation
import SwiftUI

/// The Dock icon follows Settings › Island › Glyph style (the owner, 2026-09-25: "if we're on juice or sand mode the
/// dock icon should mirror that style too"). Pixel is the bundle's own icon; Liquid and Sand draw `AppIconArt` once,
/// `pixels` square, and hand it to `NSApp.applicationIconImage`, which the Dock and the app switcher show.
///
/// It draws only while the app has a Dock tile (a regular app: Window mode, Island mode with Dock icon on, or Settings
/// open over the island) and only when the style changed since its last drawing; a style changed while the app has no
/// tile is drawn when the tile comes back. A tile that comes back is set again from the kept drawing a moment later and
/// when the app next becomes active, since the Dock builds it on its own schedule. No animation, one image kept.
@MainActor
final class DockIcon {
    /// What the tile shows: the bundle's icon, or the art drawn for a style.
    enum Tile: Equatable, Sendable {
        case bundle
        case drawn(GlyphStyle)
    }

    /// Pixel keeps the bundle's icon, which is its art already, with hand-drawn small sizes.
    nonisolated static func tile(for style: GlyphStyle) -> Tile { style == .pixel ? .bundle : .drawn(style) }

    /// The drawing's side in pixels: the Dock's largest tile (128 pt) at 2×, with room to magnify.
    static let pixels = 512
    /// The side `AppIconArt` is laid out at: the engines pick their grain and detail by the side in points, so the art
    /// is laid out as large as the Dock shows it and drawn at 2×.
    static let points: CGFloat = 256

    private let settings: AppSettings
    /// Sets the app's icon, nil for the bundle's (`NSApp.applicationIconImage`; tests record the calls).
    private let setIcon: @MainActor (NSImage?) -> Void
    /// Draws a style's art (`DockIcon.draw`; tests count the calls).
    private let draw: @MainActor (GlyphStyle) -> NSImage?
    /// Where the app's activation is heard, and how long after a tile comes back it is set once more.
    private let center: NotificationCenter
    private let settleDelay: Duration
    private var hasTile = false
    /// The tile last handed to `setIcon`.
    private var shown: Tile?
    /// The last drawing, kept while its style is chosen so the tile can be set again without drawing.
    private var drawing: (style: GlyphStyle, image: NSImage)?
    /// Whether the app's icon is a drawing now, not the bundle's.
    private var customised = false
    /// The sets after a tile came back: the next turn's and `settleDelay`'s, and the one at the next activation.
    private var lateSets: Task<Void, Never>?
    private var activation: NSObjectProtocol?

    init(settings: AppSettings,
         setIcon: @escaping @MainActor (NSImage?) -> Void = { NSApp.applicationIconImage = $0 },
         draw: @escaping @MainActor (GlyphStyle) -> NSImage? = DockIcon.draw,
         center: NotificationCenter = .default, settleDelay: Duration = .milliseconds(300)) {
        self.settings = settings
        self.setIcon = setIcon
        self.draw = draw
        self.center = center
        self.settleDelay = settleDelay
        observe()
    }

    /// The activation policy was set: `hasTile` is whether the app now has a Dock tile. A tile that has just come back
    /// is set at once, again on the next turn, after `settleDelay` and when the app next becomes active, all from the
    /// kept drawing: the Dock builds the new tile from the bundle's icon after the policy changes, on its own schedule,
    /// and could drop an image set before it has (Settings opened over the island, launch in Window mode).
    func update(hasTile: Bool) {
        let gained = hasTile && !self.hasTile
        self.hasTile = hasTile
        refresh(again: gained)
        if gained { setAgainLater() }
    }

    private func setAgainLater() {
        lateSets?.cancel()
        let delay = settleDelay
        lateSets = Task { @MainActor [weak self] in
            self?.refresh(again: true)
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.refresh(again: true)
        }
        if let activation { center.removeObserver(activation) }
        activation = center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.becameActive() }
        }
    }

    /// Once per tile that came back.
    private func becameActive() {
        if let activation { center.removeObserver(activation) }
        activation = nil
        refresh(again: true)
    }

    private func observe() {
        withObservationTracking {
            _ = settings.glyphStyle
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.refresh()
                self?.observe()
            }
        }
    }

    private func refresh(again: Bool = false) {
        guard hasTile else { return }
        let tile = Self.tile(for: settings.glyphStyle)
        guard again || tile != shown else { return }
        switch tile {
        case .bundle:
            // Only a drawing set before is taken back: a Pixel app never touches its icon.
            drawing = nil
            if customised { setIcon(nil) }
            customised = false
        case .drawn(let style):
            if drawing?.style != style { drawing = draw(style).map { (style, $0) } }
            if let image = drawing?.image {
                setIcon(image)
                customised = true
            } else if customised {
                setIcon(nil)
                customised = false
            }
        }
        shown = tile
    }

    /// `style`'s art, `pixels` square, on a clear ground outside the squircle.
    static func draw(_ style: GlyphStyle) -> NSImage? {
        let renderer = ImageRenderer(content: AppIconArt(style: style, side: points).environment(\.colorScheme, .dark))
        renderer.scale = CGFloat(pixels) / points
        guard let image = renderer.cgImage else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: points, height: points))
    }
}
