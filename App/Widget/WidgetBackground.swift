import SwiftUI

/// Settings › Desktop Panel › Widget background (P1401): what both widgets stand on in full colour. Glass, the default:
/// the system's own material, nothing of ours. Black: pure black, as the island. The app writes it into the snapshot in
/// the App Group (`WidgetSnapshot.widgetBackground`), which the widget reads: WidgetKit hands the container background
/// none of the entry view's environment (P1224).
enum WidgetBackgroundChoice: String, CaseIterable, Codable, Sendable {
    case glass, black

    /// A stored or written choice; none, or one this build does not know, reads as Glass.
    init(stored: String?) { self = stored.flatMap(Self.init(rawValue:)) ?? .glass }

    var title: String {
        switch self {
        case .glass: "Glass"
        case .black: "Black"
        }
    }
}

/// Both widgets' container background (P1401). Glass is the system's own material, its thinnest, in its dark look, and
/// nothing of ours over it: no veil, no rim, no floor (P1224's 8 % white veil and lit rim read as white on the owner's
/// wallpaper, the ink straight on the background). Black is pure black, the island's. Either stays removable
/// (WidgetKit's default), so where macOS lays its own glass (the dimmed desktop, the Clear and Tinted widget styles) it
/// takes ours away and the content draws in white (P542).
///
/// No public API asks for the platter macOS's own widgets sit on in full colour: Apple's (Batteries, Shortcuts, World
/// Clock, Home, People) ask WidgetKit for it through a private configuration (`preferredBackgroundStyle(.blur)`, in
/// their binaries' imports and in no SDK interface), and Apple's DTS says there is no API for it and points to the
/// materials instead. A background left nearly clear showed the owner the ink straight on the wallpaper. So Glass is the
/// nearest the public API gives: the system's material, which the desktop draws itself, dark so the white ink holds on
/// any wallpaper.
///
/// It reads nothing of the entry's environment (WidgetKit hands it none): the choice comes in as a value, from the
/// snapshot. Its own dark look it sets on itself. In renders only (`GlassRendering.standIn`) the stage's wallpaper,
/// blurred, stands under the material, where live the desktop shows through it.
struct WidgetBackdrop: View {
    let choice: WidgetBackgroundChoice

    /// Glass's material: the system's thinnest.
    static let glass = Material.ultraThinMaterial

    @Environment(\.glassRendering) private var rendering

    var body: some View {
        switch choice {
        case .glass:
            ZStack {
                if rendering == .standIn { GlassStandIn(shape: Rectangle(), style: .panel) }
                Rectangle().fill(Self.glass)
            }
            .environment(\.colorScheme, .dark)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        case .black:
            Color.black
        }
    }
}
