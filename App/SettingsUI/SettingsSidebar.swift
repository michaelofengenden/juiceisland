import SwiftUI

/// The Settings sidebar: one column from the window's top edge to its bottom, a shade lighter than the detail with a
/// hairline on its right. The traffic lights sit in its first 52 pt; under them, 28 pt items (16 pt coloured icon,
/// 13 pt label) in unlabelled groups. No toggle: the sidebar is always shown. Watch is gone (C9).
struct SettingsSidebar: View {
    @Bindable var navigation: SettingsNavigation
    var drawsTrafficLights = false

    /// Groups without headers: the gaps between them say enough.
    static let groups: [[SettingsPane]] = [
        [.general, .island, .sound, .shortcuts],
        [.agents, .accounts, .money, .desktopPanel],
        [.diagnostics],
        [.about],
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The first item lines up with the pane's first section.
            Color.clear.frame(height: SettingsTheme.Metrics.titleBarHeight + SettingsTheme.Metrics.firstSectionTop)
            VStack(alignment: .leading, spacing: SettingsTheme.Metrics.sidebarGroupGap) {
                ForEach(Self.groups.indices, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Self.groups[index]) { pane in
                            SidebarItem(pane: pane, selected: navigation.pane == pane) { navigation.pane = pane }
                        }
                    }
                }
            }
            .padding(.horizontal, SettingsTheme.Metrics.sidebarPadding)
            Spacer(minLength: 0)
        }
        .frame(width: SettingsTheme.Metrics.sidebarWidth, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(SettingsTheme.sidebar)
        .overlay(alignment: .trailing) { SettingsTheme.sidebarStroke.frame(width: 1) }
        .overlay(alignment: .topLeading) {
            if drawsTrafficLights {
                TrafficLightsPreview(diameter: SettingsTheme.Metrics.trafficLight.diameter, gap: SettingsTheme.Metrics.trafficLight.gap)
                    .offset(x: SettingsTheme.Metrics.trafficLight.x,
                            y: (SettingsTheme.Metrics.titleBarHeight - SettingsTheme.Metrics.trafficLight.diameter) / 2)
            }
        }
    }
}

private struct SidebarItem: View {
    let pane: SettingsPane
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                SettingsPaneIcon(pane: pane)
                Text(pane.title).font(SettingsTheme.TypeScale.item).foregroundStyle(SettingsTheme.ink)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: SettingsTheme.Metrics.itemHeight)
            .background(RoundedRectangle(cornerRadius: SettingsTheme.Metrics.itemRadius)
                .fill(selected ? SettingsTheme.itemSelected : hovering ? SettingsTheme.itemHover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The 16 pt coloured pane icons, from the prototype's own SVGs (`IC`, L1632-1647), in the window's look: the dark
/// look's colours as they always were, cut out in the dark window's grey; the light look's a shade deeper, each holding
/// a mark's 3:1 on the light sidebar and on its selected or hovered item, cut out in the light window's grey (P763).
struct SettingsPaneIcon: View {
    let pane: SettingsPane
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        SVGIcon(svg: Self.svg(pane, scheme), size: CGSize(width: 16, height: 16))
    }

    static func colourHex(_ pane: SettingsPane, _ scheme: ColorScheme = .dark) -> String {
        let light = scheme == .light
        return switch pane {
        case .general, .shortcuts: light ? "#737378" : "#98989D"
        case .island, .about: light ? "#0064D2" : "#0A84FF"
        case .sound: light ? "#248A3D" : "#32D74B"
        case .accounts: light ? "#946800" : "#FFD60A"
        case .money: light ? "#248A3D" : "#30D158"
        case .desktopPanel: light ? "#5856D6" : "#5E5CE6"
        case .diagnostics: light ? "#0C7C78" : "#66D4CF"
        case .agents: light ? "#AD5D00" : "#FF9F0A"
        }
    }

    /// The window's grey the icons' holes are drawn in.
    static func cutHex(_ scheme: ColorScheme) -> String { scheme == .light ? "#F5F5F7" : "#1C1C1E" }

    static func svg(_ pane: SettingsPane, _ scheme: ColorScheme = .dark) -> String {
        let c = colourHex(pane, scheme), cut = cutHex(scheme)
        let open = ##"<svg width="16" height="16" viewBox="0 0 16 16">"##
        let body: String = switch pane {
        case .general:
            // The cog, as `CogShape` draws it (8 teeth, outer 7.4, inner 5.6, hole 2.6).
            ##"<path fill-rule="evenodd" d="\##(cogPath)" fill="\##(c)"/>"##
        case .island:
            ##"<path d="M.6 2.4h14.8v3.2a4.4 4.4 0 0 1-4.4 4.4H5a4.4 4.4 0 0 1-4.4-4.4z" fill="\##(c)"/><rect x="3.4" y="5" width="3.2" height="2.2" rx="1.1" fill="\##(cut)"/><rect x="2.6" y="12.2" width="10.8" height="1.6" rx=".8" fill="\##(c)" opacity=".6"/>"##
        case .sound:
            ##"<path d="M1.5 5.8h2.6l3.5-2.8v10l-3.5-2.8H1.5z" fill="\##(c)"/><path d="M10 5.6a3.4 3.4 0 0 1 0 4.8M11.9 3.7a6 6 0 0 1 0 8.6" fill="none" stroke="\##(c)" stroke-width="1.4" stroke-linecap="round"/>"##
        case .shortcuts:
            ##"<rect x=".8" y="3.5" width="14.4" height="9" rx="1.8" fill="\##(c)"/><path d="M3 6.2h1.2M5.6 6.2h1.2M8.2 6.2h1.2M10.8 6.2H12M3 8.4h1.2M5.6 8.4h1.2M8.2 8.4h1.2M10.8 8.4H12M4.6 10.5h6.8" stroke="\##(cut)" stroke-width="1"/>"##
        case .accounts:
            ##"<rect x=".6" y="4" width="13" height="8" rx="2.4" fill="\##(c)"/><rect x="8.4" y="5.8" width="3.4" height="4.4" rx=".9" fill="\##(cut)"/><rect x="13.9" y="6.4" width="1.6" height="3.2" rx=".7" fill="\##(c)"/>"##
        case .money:
            ##"<rect x=".6" y="3.2" width="14.8" height="9.6" rx="2" fill="\##(c)"/><circle cx="8" cy="8" r="2.4" fill="\##(cut)"/><circle cx="3.4" cy="8" r=".9" fill="\##(cut)"/><circle cx="12.6" cy="8" r=".9" fill="\##(cut)"/>"##
        case .desktopPanel:
            ##"<rect x=".6" y="1.6" width="14.8" height="10.2" rx="1.8" fill="\##(c)"/><rect x="8.8" y="3.4" width="4.8" height="3" rx=".7" fill="\##(cut)"/><path d="M6.4 11.6h3.2l.5 2.4H5.9z" fill="\##(c)"/><rect x="4.4" y="13.6" width="7.2" height="1.6" rx=".8" fill="\##(c)"/>"##
        case .diagnostics:
            ##"<path d="M.8 8.6h3l1.7-4.6 2.6 8.2 2-5.6 1.1 2h4" fill="none" stroke="\##(c)" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/>"##
        case .agents:
            // A terminal: a prompt's chevron and its cursor, cut out.
            ##"<rect x=".8" y="2.2" width="14.4" height="11.6" rx="2.2" fill="\##(c)"/><path d="M4.3 6.1 6.8 8l-2.5 1.9" fill="none" stroke="\##(cut)" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/><path d="M8.6 10.3h3.2" stroke="\##(cut)" stroke-width="1.5" stroke-linecap="round"/>"##
        case .about:
            ##"<circle cx="8" cy="8" r="7" fill="\##(c)"/><circle cx="8" cy="4.9" r="1" fill="\##(cut)"/><path d="M8 7.2v4.6" stroke="\##(cut)" stroke-width="1.8" stroke-linecap="round"/>"##
        }
        return open + body + "</svg>"
    }

    /// `CogShape`'s outline as SVG path data (16 × 16), so the sidebar cog matches the toolbar's.
    static let cogPath: String = {
        var d = ""
        let teeth = 8, outer = 7.4, inner = 5.6
        for index in 0...(teeth * 2) {
            let a0 = Double(index) / Double(teeth * 2) * 2 * .pi - .pi / 16
            let a1 = Double(index + 1) / Double(teeth * 2) * 2 * .pi - .pi / 16
            let radius = index % 2 == 1 ? inner : outer
            let p0 = (8 + radius * cos(a0), 8 + radius * sin(a0)), p1 = (8 + radius * cos(a1), 8 + radius * sin(a1))
            guard index < teeth * 2 else { break }
            d += (index == 0 ? "M" : "L") + String(format: "%.2f %.2f", p0.0, p0.1)
            d += "L" + String(format: "%.2f %.2f", p1.0, p1.1)
        }
        d += "Z M10.6 8a2.6 2.6 0 1 0 -5.2 0a2.6 2.6 0 1 0 5.2 0Z"
        return d
    }()
}
