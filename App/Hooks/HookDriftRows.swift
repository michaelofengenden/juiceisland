import IslandEngine
import SwiftUI

/// "Hooks missing in <alias> · Repair" (spec §3.5, P26): one quiet line per drifted profile, in the window under the
/// usage header and, smaller, in the island under its header. Repair is Install, on this click only; a refused click
/// says why in a few words on the same line. Nothing when no profile drifted.
struct HookDriftRows: View {
    enum Size { case window, island }

    var size: Size = .window
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let alerts = env.hooks.alerts
        let helper = env.hooks.helperUpdate
        if !alerts.isEmpty || helper != nil {
            VStack(alignment: .leading, spacing: size == .window ? 4 : 2) {
                if let helper { HookHelperLine(update: helper, size: size) }
                ForEach(alerts, id: \.targetID) { alert in
                    HookDriftLine(alert: alert, size: size)
                }
            }
            .padding(size == .window ? EdgeInsets(top: 8, leading: 22, bottom: 8, trailing: 22)
                                     : EdgeInsets(top: 2, leading: 8, bottom: 4, trailing: 8))
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) {
                if size == .window { WindowTheme.hairline.frame(height: 1) }
            }
        }
    }
}

struct HookDriftLine: View {
    let alert: HookDriftAlert
    let size: HookDriftRows.Size
    @Environment(AppEnvironment.self) private var env
    @Environment(\.juiceTheme) private var theme
    private var palette: IslandPalette { theme.island }

    var body: some View {
        let hooks = env.hooks
        let row = hooks.rows.first { $0.id == alert.targetID }
        let refusal = row?.refusal ?? hooks.clickRefusal(for: alert.targetID)
        let font = Fonts.sys(size == .window ? 12 : 11)
        HStack(spacing: 6) {
            Circle().fill(palette.tone(Self.amber)).frame(width: 6, height: 6)
            Text("Hooks missing in \(alert.alias)").font(font).foregroundStyle(Self.text(theme)).lineLimit(1)
            Text("·").font(font).foregroundStyle(Self.dot(theme))
            Button {
                hooks.perform(.repair, on: alert.targetID)
            } label: {
                Text(row?.busy == true ? "Repairing…" : "Repair").font(font.weight(.semibold)).foregroundStyle(palette.toneText(Self.amber))
            }
            .buttonStyle(.plain)
            .disabled(refusal != nil || row?.busy == true)
            .help(refusal ?? "Install the missing hooks in \(alert.alias)")
            if let refusal {
                // Black's ink2 (#8E8E93), lifted on glass.
                Text(refusal).font(font).foregroundStyle(palette.ink2).lineLimit(1).truncationMode(.tail)
            }
        }
    }

    static let amber = Color(hex: 0xFFC16E)

    /// The line's text and its "·": today's greys, or on Glass the ink and ink3 of the glass's look (P563).
    static func text(_ theme: JuiceTheme) -> Color { theme.adapts ? theme.island.ink : Color(hex: 0xE5E5E5) }
    static func dot(_ theme: JuiceTheme) -> Color { theme.adapts ? theme.island.ink3 : Color(hex: 0x6C6C70) }
}

/// "Hook helper · Update" (P163): the managed helper every hook runs is older than this build's; a click replaces it
/// (no hook config is written). A refused click says why on the same line.
struct HookHelperLine: View {
    let update: HelperUpdate
    let size: HookDriftRows.Size
    @Environment(AppEnvironment.self) private var env
    @Environment(\.juiceTheme) private var theme

    var body: some View {
        let font = Fonts.sys(size == .window ? 12 : 11)
        let palette = theme.island
        HStack(spacing: 6) {
            Circle().fill(palette.tone(HookDriftLine.amber)).frame(width: 6, height: 6)
            Text("Hook helper").font(font).foregroundStyle(HookDriftLine.text(theme)).lineLimit(1)
            Text("·").font(font).foregroundStyle(HookDriftLine.dot(theme))
            Button {
                env.hooks.updateHelper()
            } label: {
                Text(update == .updating ? "Updating…" : "Update").font(font.weight(.semibold)).foregroundStyle(palette.toneText(HookDriftLine.amber))
            }
            .buttonStyle(.plain)
            .disabled(update != .available)
            .help("Replace the hook helper with this build's")
            if case let .refused(reason) = update {
                Text(reason).font(font).foregroundStyle(theme.adapts ? palette.ink2 : Color(hex: 0x8E8E93)).lineLimit(1).truncationMode(.tail)
            }
        }
    }
}
