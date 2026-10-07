import AppKit
import JuiceCore
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// The Usage widget (wave A5, P1220 to P1229; its background P1401), headless, every file `uw-*`: each face over the
/// owner's lavender sunset and dark mountain, a pale wallpaper and a night one, in a light and a dark macOS, on each
/// ground the desktop can give it:
/// - `glass`: the desktop in front, full colour, Widget background Glass: the system's thinnest material in its dark look
///   (`WidgetBackdrop`), the wallpaper blurred under it (the renders' stand-in for what the desktop shows through), the
///   white ink lifted. Only a live look shows how the desktop draws the material.
/// - `opaque`: Glass where the desktop shows nothing through the material: its own dark grey.
/// - `black`: full colour, Widget background Black: pure black.
/// - `dimmed`: an app in front: the system takes either background away and lays its own glass, here a model of the
///   dimmed widgets' glass fitted to the screenshots (`WidgetGlassRenders.widgetModel`), and the content draws in white
///   (`mono`).
/// Sheets put a wallpaper's three faces side by side (`uw-sheet-<wallpaper>-<ground>`), at the sizes the renders take for
/// macOS's (170, 364 × 170, 364 × 382) and at the next class down (`uw-sheet-compact-*`: 158, 338 × 158, 338 × 354); the
/// states (stale, not running, every battery state, many accounts) are the faces over the sunset (`uw-state-*`).
@MainActor
@Suite(.serialized)
struct UsageWidgetRenders {
    static let now = DemoClock.now
    static let margin: CGFloat = 14
    static let radius: CGFloat = 22
    static let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)

    enum Mode: String, CaseIterable {
        case glass, opaque, black, dimmed

        /// What the states show: Glass on the system's glass, Black, and dimmed.
        static let main: [Mode] = [.glass, .black, .dimmed]
    }

    /// The owner's two wallpapers first.
    nonisolated static let wallpapers: [GlassBackdrop] = [.sunset, .mountain, .nearWhite, .night]

    /// The widget's size by face: the renders' macOS sizes, or the next class down (`compact`). WidgetKit hands the face
    /// its size and margins at run time; Apple publishes no table of macOS's.
    static func size(_ face: WidgetFace, compact: Bool = false) -> CGSize {
        guard compact else { return WidgetRenders.Size.of(face) }
        switch face {
        case .small: return CGSize(width: 158, height: 158)
        case .medium: return CGSize(width: 338, height: 158)
        case .large: return CGSize(width: 338, height: 354)
        }
    }

    /// What the widget stands on in `mode`, inside its shape.
    @ViewBuilder static func ground(_ mode: Mode) -> some View {
        switch mode {
        case .glass: WidgetBackdrop(choice: .glass)
        case .opaque: WidgetBackdrop(choice: .glass).environment(\.glassRendering, .live).compositingGroup()
        case .black: WidgetBackdrop(choice: .black)
        case .dimmed:
            GlassFaceStandIn(shape: shape, style: GlassStyle.panel.clear, face: WidgetGlassRenders.widgetModel, scheme: .dark,
                             reduceTransparency: false, contrast: .standard)
        }
    }

    /// The owner's accounts as their panel showed them on 2026-10-05: Claude 83 in use, one used up for 2:04, 100; Codex 99
    /// in use, then three full; OpenRouter, OpenAI offline, RunPod.
    static func owner(at date: Date = now) -> WidgetSnapshot {
        WidgetSnapshot(
            written: date, appRunning: true, rows: [], more: 0,
            claude: [.init(state: .available(left: 83, low: false), isNext: true, inUse: true),
                     .init(state: .usedUp(refill: date.addingTimeInterval(2 * 3_600 + 4 * 60 + 30)), isNext: false),
                     .init(state: .available(left: 100, low: false), isNext: false)],
            codex: [.init(state: .available(left: 99, low: false), isNext: true, inUse: true),
                    .init(state: .available(left: 100, low: false), isNext: false),
                    .init(state: .available(left: 100, low: false), isNext: false),
                    .init(state: .available(left: 100, low: false), isNext: false)],
            glyphStyle: GlyphStyle.pixel.rawValue, glyphColour: GlyphColourMode.byState.rawValue,
            money: [.init(id: "OpenRouter", name: "OpenRouter", amount: "$6,519"),
                    .init(id: "OpenAI", name: "OpenAI", amount: nil, word: "Offline"),
                    .init(id: "RunPod", name: "RunPod", amount: "$0.00")])
    }

    /// Every battery state, six and five accounts, five money rows (one amber, one red).
    static func crowded(at date: Date = now) -> WidgetSnapshot {
        WidgetSnapshot(
            written: date, appRunning: true, rows: [], more: 0,
            claude: [.init(state: .available(left: 7, low: true), isNext: false),
                     .init(state: .usedUp(refill: date.addingTimeInterval(45 * 60)), isNext: false),
                     .init(state: .available(left: 64, low: false), isNext: true, inUse: true),
                     .init(state: .signIn, isNext: false),
                     .init(state: .stale(last: 40), isNext: false),
                     .init(state: .noPlan, isNext: false)],
            codex: [.init(state: .usedUp(refill: date.addingTimeInterval(3 * 86_400)), isNext: false),
                    .init(state: .usedUp(refill: date.addingTimeInterval(30 * 3_600)), isNext: false),
                    .init(state: .available(left: 52, low: false), isNext: true, inUse: true),
                    .init(state: .unknown, isNext: false),
                    .init(state: .signingIn, isNext: false)],
            glyphStyle: GlyphStyle.pixel.rawValue, glyphColour: GlyphColourMode.byState.rawValue,
            money: [.init(id: "OpenRouter", name: "OpenRouter", amount: "$412.80"),
                    .init(id: "Anthropic", name: "Anthropic", amount: "$38.20", isSpent: true),
                    .init(id: "OpenAI", name: "OpenAI", amount: nil, word: "No access"),
                    .init(id: "RunPod", name: "RunPod", amount: "$4.10", suffix: "9h", emphasis: .attention),
                    .init(id: "Hetzner", name: "Hetzner", amount: "$61.00", suffix: "2d", emphasis: .warn)])
    }

    /// The widget as the desktop shows it: its face in its size less the margins, on what `mode` lays under it, in its
    /// rounded shape, on `wallpaper`.
    static func scene(_ snapshot: WidgetSnapshot?, _ face: WidgetFace, wallpaper: GlassBackdrop, mode: Mode,
                      date: Date = now, compact: Bool = false) -> some View {
        let size = size(face, compact: compact)
        let inner = CGSize(width: size.width - 2 * margin, height: size.height - 2 * margin)
        return GlassStage(backdrop: wallpaper) {
            UsageWidgetView(snapshot: snapshot, face: face, size: inner, date: date, mono: mode == .dimmed)
                .padding(margin)
                .frame(width: size.width, height: size.height)
                .background { ground(mode) }
                .clipShape(shape)
                .containerShape(shape)
                .padding(24)
        }
        .frame(width: size.width + 48, height: size.height + 48)
    }

    static func sceneSize(_ face: WidgetFace, compact: Bool = false) -> CGSize {
        let size = size(face, compact: compact)
        return CGSize(width: size.width + 48, height: size.height + 48)
    }

    /// `uw-<wallpaper>-<light|dark>-<face>-<mode>`.
    @Test(arguments: Self.wallpapers)
    func eachWallpaper(_ wallpaper: GlassBackdrop) throws {
        for scheme in [ColorScheme.light, .dark] {
            for face in WidgetFace.allCases {
                for mode in Mode.allCases {
                    try RenderHarness.render(Self.scene(Self.owner(), face, wallpaper: wallpaper, mode: mode),
                                             "uw-\(wallpaper.rawValue)-\(scheme == .dark ? "dark" : "light")-\(face.rawValue)-\(mode.rawValue)",
                                             size: Self.sceneSize(face), scheme: scheme)
                }
            }
        }
    }

    /// A wallpaper's faces side by side, the small one over the medium, the large beside them.
    static func sheet(_ snapshot: WidgetSnapshot, wallpaper: GlassBackdrop, mode: Mode, compact: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                scene(snapshot, .small, wallpaper: wallpaper, mode: mode, compact: compact)
                scene(snapshot, .medium, wallpaper: wallpaper, mode: mode, compact: compact)
            }
            scene(snapshot, .large, wallpaper: wallpaper, mode: mode, compact: compact)
        }
    }

    static func sheetSize(compact: Bool = false) -> CGSize {
        let medium = size(.medium, compact: compact), large = size(.large, compact: compact)
        return CGSize(width: medium.width + 48 + large.width + 48, height: large.height + 48)
    }

    /// `uw-sheet-<wallpaper>-<mode>`, `uw-sheet-crowded-*`, and both at the next size class down, `uw-sheet-compact-*`.
    @Test func sheets() throws {
        for wallpaper in Self.wallpapers {
            for mode in Mode.allCases {
                for compact in [false, true] {
                    let prefix = compact ? "uw-sheet-compact" : "uw-sheet"
                    try RenderHarness.render(Self.sheet(Self.owner(), wallpaper: wallpaper, mode: mode, compact: compact),
                                             "\(prefix)-\(wallpaper.rawValue)-\(mode.rawValue)", size: Self.sheetSize(compact: compact),
                                             scheme: .light)
                    try RenderHarness.render(Self.sheet(Self.crowded(), wallpaper: wallpaper, mode: mode, compact: compact),
                                             "\(prefix)-crowded-\(wallpaper.rawValue)-\(mode.rawValue)", size: Self.sheetSize(compact: compact),
                                             scheme: .light)
                }
            }
        }
    }

    /// The states, medium over the sunset, both looks: stale (an hour and more since the app last wrote), the app quit,
    /// no snapshot yet, no money, and the gallery's preview.
    @Test func states() throws {
        var stale = Self.owner()
        stale.written = Self.now.addingTimeInterval(-(UsageFreshness.staleAfter + UsageFreshness.grace))
        var noMoney = Self.owner()
        noMoney.money = []
        let states: [(String, WidgetSnapshot?)] = [("stale", stale), ("closed", .closed(at: Self.now)), ("none", nil),
                                                   ("no-money", noMoney), ("preview", .usagePreview(at: Self.now))]
        for (name, snapshot) in states {
            for mode in Mode.main {
                for face in WidgetFace.allCases {
                    try RenderHarness.render(Self.scene(snapshot, face, wallpaper: .sunset, mode: mode),
                                             "uw-state-\(name)-\(face.rawValue)-\(mode.rawValue)", size: Self.sceneSize(face))
                }
            }
        }
    }

    /// WidgetKit's timer text clipped to the panel's label (P1225), drawn live at the real clock (`live`): beside each,
    /// the label the panel draws for the same refill. Over the night wallpaper, full colour. `uw-live-countdowns`.
    @Test func liveCountdowns() throws {
        let now = Date()
        let refills: [TimeInterval] = [2 * 3_600 + 4 * 60 + 30, 12 * 3_600 + 30 * 60 + 10, 45 * 60 + 30, 9 * 60 + 30]
        let view = VStack(alignment: .leading, spacing: 10) {
            ForEach(refills, id: \.self) { seconds in
                HStack(spacing: 12) {
                    UsageBattery(battery: .init(state: .usedUp(refill: now.addingTimeInterval(seconds)), isNext: false), date: now, live: true)
                    UsageBattery(battery: .init(state: .usedUp(refill: now.addingTimeInterval(seconds)), isNext: false), date: now, live: false)
                    Text(Formatting.refillLabel(now.addingTimeInterval(seconds), now: now)).font(.system(size: 11)).foregroundStyle(.white)
                }
            }
        }
        .padding(16)
        .background(Color(hex: 0x2E3558))
        try RenderHarness.render(view, "uw-live-countdowns")
        try RenderHarness.renderPixels(view, "uw-live-countdowns-zoom", scale: 4)
    }
}
