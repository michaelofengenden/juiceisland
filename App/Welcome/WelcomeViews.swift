import AppKit
import IslandEngine
import SwiftUI

/// The welcome's window content (P950 to P974): one screen at a time, each one line of words over its content, one main
/// button that Return presses, and four dots that say how short it is. Black draws on the pure black; Glass follows
/// Settings › General › Appearance, light or dark. Renders build it from `WelcomeModel.fixture`.
struct WelcomeView: View {
    static let size = CGSize(width: 460, height: 560)

    @Bindable var model: WelcomeModel
    @Environment(AppEnvironment.self) private var env
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let look = WelcomeLook(theme: env.settings.juiceTheme, scheme: scheme)
        VStack(spacing: 0) {
            Group {
                switch model.step {
                case .hello: WelcomeHello(model: model)
                case .agents: WelcomeAgents(model: model)
                case .look: WelcomePickLook(model: model)
                case .start: WelcomeStart(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .id(model.step)
            .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: 18)), removal: .opacity.combined(with: .offset(x: -18))))
            WelcomePager(step: model.step).padding(.top, 14).padding(.bottom, 18)
        }
        .padding(.horizontal, 28)
        .padding(.top, 34)
        .frame(width: Self.size.width, height: Self.size.height)
        .background(look.ground)
        .environment(\.welcomeLook, look)
        .animation(.smooth(duration: 0.32), value: model.step)
    }
}

// MARK: Look

/// The welcome's colours for its theme and look: Black always dark on the pure black, Glass in Appearance's light or dark.
struct WelcomeLook: Equatable {
    var dark: Bool
    var black: Bool

    init(theme: JuiceTheme, scheme: ColorScheme) {
        black = !theme.adapts
        dark = black || scheme == .dark
    }

    var ground: some View {
        ZStack {
            if black {
                Color.black
            } else if dark {
                LinearGradient(colors: [Color(hex: 0x232326), Color(hex: 0x161618)], startPoint: .top, endPoint: .bottom)
            } else {
                LinearGradient(colors: [Color(hex: 0xFFFFFF), Color(hex: 0xF2F2F5)], startPoint: .top, endPoint: .bottom)
            }
        }
    }

    var ink: Color { dark ? Color(hex: 0xF5F5F7) : Color(hex: 0x1D1D1F) }
    var ink2: Color { dark ? Color(hex: 0x9A9AA0) : Color(hex: 0x5E5E63) }
    var ink3: Color { dark ? Color(hex: 0x6C6C70) : Color(hex: 0x8A8A8E) }
    var group: Color { dark ? Color.white.opacity(black ? 0.055 : 0.06) : Color.black.opacity(0.035) }
    var groupEdge: Color { dark ? Color.white.opacity(0.08) : Color.black.opacity(0.07) }
    var hairline: Color { dark ? Color.white.opacity(0.06) : Color.black.opacity(0.06) }
    var accent: Color { dark ? Color(hex: 0x0A84FF) : Color(hex: 0x0064D2) }
    var amber: Color { dark ? Color(hex: 0xFFC16E) : Color(hex: 0xA35A00) }
    var green: Color { dark ? Color(hex: 0x32D74B) : Color(hex: 0x1F8A3B) }
    /// The main button: white on dark, near black on light.
    var primaryFill: Color { dark ? Color(hex: 0xF5F5F7) : Color(hex: 0x1D1D1F) }
    var primaryText: Color { dark ? .black : .white }
    var secondaryFill: Color { dark ? Color.white.opacity(0.09) : Color.black.opacity(0.06) }
    /// A small solid chip over the list, such as "6 more below": nothing under it shows through.
    var chip: Color { dark ? Color(hex: black ? 0x1C1C1E : 0x2C2C2E) : Color(hex: 0xFFFFFF) }
    var brand: Color { IslandTheme.brand }
    /// The agents' marks in their island colours, toned for the ground (as Settings › Agents draws them).
    var markTheme: JuiceTheme { dark ? .black : .glass }
}

extension EnvironmentValues {
    @Entry var welcomeLook = WelcomeLook(theme: .black, scheme: .dark)
}

// MARK: Pieces

/// The screen's one line, and a quieter line under it where the screen needs one.
private struct WelcomeHeadline: View {
    let text: String
    var hint: String?
    var hintColour: Color?
    @Environment(\.welcomeLook) private var look

    var body: some View {
        VStack(spacing: 6) {
            Text(text).font(.system(size: 22, weight: .semibold)).foregroundStyle(look.ink)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            if let hint {
                Text(hint).font(.system(size: 13)).foregroundStyle(hintColour ?? look.ink2)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// The main button: full width, Return presses it.
struct WelcomePrimaryButton: View {
    let title: String
    var busy = false
    let action: () -> Void
    @Environment(\.welcomeLook) private var look

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if busy { ProgressView().controlSize(.small).tint(look.primaryText) }
                Text(title).font(.system(size: 14, weight: .semibold)).contentTransition(.opacity)
            }
            .foregroundStyle(look.primaryText)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(look.primaryFill))
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(WelcomePressStyle())
        .keyboardShortcut(.defaultAction)
        .disabled(busy)
        .accessibilityLabel(title)
    }
}

/// A smaller button beside or under the main one.
private struct WelcomeSecondaryButton: View {
    let title: String
    var prominent = false
    let action: () -> Void
    @Environment(\.welcomeLook) private var look

    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(prominent ? look.ink : look.ink2)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(Capsule().fill(look.secondaryFill))
                .contentShape(Capsule())
        }
        .buttonStyle(WelcomePressStyle())
    }
}

private struct WelcomePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Four dots, the current one long.
private struct WelcomePager: View {
    let step: WelcomeModel.Step
    @Environment(\.welcomeLook) private var look

    var body: some View {
        HStack(spacing: 6) {
            ForEach(WelcomeModel.Step.allCases, id: \.self) { item in
                Capsule().fill(item == step ? look.ink : look.ink3.opacity(0.5))
                    .frame(width: item == step ? 18 : 6, height: 6)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Step \(step.rawValue + 1) of \(WelcomeModel.Step.allCases.count)")
    }
}

/// A rounded group the rows sit in.
private struct WelcomeGroup<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.welcomeLook) private var look

    var body: some View {
        VStack(spacing: 0) { content }
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(look.group))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(look.groupEdge, lineWidth: 1))
    }
}

// MARK: 1. Hello

/// Hello: the icon over the one line, and what the island above asks for (P963).
struct WelcomeHello: View {
    let model: WelcomeModel
    @Environment(\.welcomeLook) private var look
    @Environment(\.sessionGlyphsAnimated) private var animated
    @State private var tipped = false

    var body: some View {
        let answered = model.helloPhase == .running || model.helloPhase == .done
        VStack(spacing: 0) {
            Spacer(minLength: 8)
            ZStack {
                Circle().fill(RadialGradient(colors: [look.brand.opacity(look.dark ? 0.22 : 0.18), .clear], center: .center,
                                             startRadius: 4, endRadius: 120))
                    .frame(width: 240, height: 240)
                AppIconArt(style: model.env.settings.glyphStyle, side: 132)
                    .rotationEffect(.degrees(tipped ? -9 : 0), anchor: .bottom)
                    .offset(y: tipped ? -4 : 0)
            }
            .frame(height: 210)
            .accessibilityHidden(true)
            WelcomeHeadline(text: WelcomeText.headline(.hello, notch: model.hasNotch), hint: WelcomeText.helloHint(answered: answered),
                            hintColour: answered ? look.green : look.ink2)
                .padding(.top, 6)
            if !answered {
                Image(systemName: "arrow.up").font(.system(size: 12, weight: .semibold)).foregroundStyle(look.ink3)
                    .padding(.top, 8)
                    .accessibilityHidden(true)
            }
            Spacer(minLength: 12)
            WelcomePrimaryButton(title: "Start") { model.primary() }
        }
        .animation(.smooth(duration: 0.3), value: answered)
        .onAppear {
            guard animated, model.animates else { return }
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true).delay(0.4)) { tipped = true }
        }
    }
}

// MARK: 2. Agents

/// Agents: the other islands' cards, then a line per agent found (Claude and Codex unfold into their folders), each with
/// its mark, Approve or Watch, and a tick; Connect is the only click that writes, says so, and counts the lines it
/// writes. A list taller than the screen fades at its bottom under "6 more below", which scrolls there (P952 to P957,
/// P1186).
struct WelcomeAgents: View {
    @Bindable var model: WelcomeModel
    @Environment(\.welcomeLook) private var look
    @Environment(\.sessionGlyphsAnimated) private var animated
    @State private var shown = 0
    /// Each line's middle, from the top of the list's visible part, and that part's height (`WelcomeFold`).
    @State private var mids: [String: CGFloat] = [:]
    @State private var visibleHeight: CGFloat = 0

    private var dropsIn: Bool { animated && model.animates }

    var body: some View {
        let lines = model.lines
        VStack(spacing: 0) {
            WelcomeHeadline(text: WelcomeText.headline(.agents))
                .padding(.bottom, 16)
            if model.showsOpenIslandCard {
                WelcomeCard(text: WelcomeText.openIslandCard, primary: "Quit Open Island", secondary: "Keep it",
                            onPrimary: model.quitOpenIsland, onSecondary: model.keepOpenIsland)
                    .padding(.bottom, 10)
            }
            if model.showsVibeCard {
                WelcomeCard(text: WelcomeText.vibeCard(agents: model.vibeAgents.count), primary: "Switch to \(Product.name)",
                            secondary: "Keep Vibe Island", busy: model.vibeChoice == .switching,
                            onPrimary: model.switchToJuice, onSecondary: model.keepVibeIsland)
                    .padding(.bottom, 10)
            } else if model.vibeChoice == .switched {
                Text(WelcomeText.vibeSwitched(left: model.vibeFilesLeft)).font(.system(size: 11.5))
                    .foregroundStyle(model.vibeFilesLeft > 0 ? look.amber : look.ink2)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 10)
            }
            if lines.isEmpty {
                Spacer(minLength: 0)
                Text(WelcomeText.connectLine(clicked: false, nothingFound: true)).font(.system(size: 13)).foregroundStyle(look.ink2)
                    .multilineTextAlignment(.center)
                Spacer(minLength: 0)
            } else {
                let below = WelcomeFold.below(mids: lines.compactMap { mids[$0.id] }, visibleHeight: visibleHeight)
                ScrollViewReader { proxy in
                    VStack(spacing: 0) {
                        ScrollView(.vertical) {
                            WelcomeGroup {
                                ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                                    if index > 0 {
                                        look.hairline.frame(height: 1).padding(.leading, line.kind == .profile && line.detail != nil ? 40 : 12)
                                    }
                                    WelcomeAgentLine(line: line, model: model)
                                        .opacity(!dropsIn || index < shown ? 1 : 0)
                                        .offset(y: !dropsIn || index < shown ? 0 : 6)
                                        .id(line.id)
                                        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(WelcomeFold.space)).midY } action: {
                                            mids[line.id] = $0
                                        }
                                }
                            }
                        }
                        .scrollIndicators(.never)
                        .scrollBounceBehavior(.basedOnSize)
                        .coordinateSpace(.named(WelcomeFold.space))
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { visibleHeight = $0 }
                        // The lines below the fold fade out under how many there are; a click scrolls to the last.
                        .mask {
                            VStack(spacing: 0) {
                                Color.black
                                LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .top, endPoint: .bottom)
                                    .frame(height: below > 0 ? 36 : 0)
                            }
                        }
                        .animation(.smooth(duration: 0.2), value: below > 0)
                        // Under the list, never over it: the list is AppKit's scroll view, which draws over what lies on it.
                        if below > 0 {
                            Button {
                                withAnimation(.smooth(duration: 0.35)) { proxy.scrollTo(lines.last?.id, anchor: .bottom) }
                            } label: {
                                HStack(spacing: 4) {
                                    Text(WelcomeText.moreBelow(below))
                                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                                }
                                .font(.system(size: 11.5, weight: .medium)).foregroundStyle(look.ink2)
                                .padding(.horizontal, 10).frame(height: 22)
                                .background(Capsule().fill(look.chip))
                                .overlay(Capsule().strokeBorder(look.groupEdge, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                            .help("Connect writes these too")
                            .padding(.top, 8)
                            .transition(.opacity)
                        }
                    }
                }
                HStack(spacing: 6) {
                    Text(WelcomeText.connectLine(clicked: model.connectClicked, nothingFound: false))
                        .font(.system(size: 11.5)).foregroundStyle(look.ink2)
                    Button { model.showsFiles.toggle() } label: {
                        Image(systemName: "info.circle").font(.system(size: 12)).foregroundStyle(look.ink3)
                    }
                    .buttonStyle(.plain)
                    .help("The files it writes")
                    .accessibilityLabel("The files it writes")
                    .popover(isPresented: $model.showsFiles, arrowEdge: .bottom) { WelcomeFiles(files: model.files) }
                }
                .padding(.top, 10)
            }
            Spacer(minLength: 12)
            WelcomePrimaryButton(title: WelcomeText.agentsButton(model), busy: model.connecting || model.vibeChoice == .switching) {
                model.primary()
            }
        }
        .onAppear {
            guard dropsIn else { return }
            // The rows drop in one at a time, as they are found.
            for index in 0..<max(lines.count, 1) {
                withAnimation(.smooth(duration: 0.3).delay(0.08 + Double(index) * 0.07)) { shown = index + 1 }
            }
        }
        .onChange(of: lines.count) { _, count in if count > shown { withAnimation(.smooth(duration: 0.3)) { shown = count } } }
    }
}

/// Which lines of the welcome's list are below its visible part (P1186): each line's middle is measured from the top of
/// that part, in `space`, so the count follows the scroll.
enum WelcomeFold {
    static let space = "welcome.agents"

    /// The lines more than half below the bottom; none before the list has a height.
    static func below(mids: [CGFloat], visibleHeight: CGFloat) -> Int {
        guard visibleHeight > 0 else { return 0 }
        return mids.filter { $0 > visibleHeight }.count
    }
}

/// One agent or folder: a tick (or its state), the mark, the name and its tag; on the right its word, or a Copy.
private struct WelcomeAgentLine: View {
    let line: WelcomeModel.Line
    let model: WelcomeModel
    @Environment(\.welcomeLook) private var look
    @Environment(\.juiceTheme) private var theme

    var body: some View {
        let indented = line.kind == .profile && line.detail != nil
        HStack(spacing: 10) {
            WelcomeTick(state: line.state) { model.toggle(line.id) }
            if let mark = line.look { AgentLookMark(look: mark, size: 17, theme: look.markTheme).frame(width: 18, height: 18) }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(line.name).font(.system(size: 13, weight: indented ? .regular : .medium)).foregroundStyle(look.ink).lineLimit(1)
                    if let reach = line.reach { WelcomeReachTag(reach: reach) }
                }
                if let note = line.reachNote {
                    Text(note).font(.system(size: 11)).foregroundStyle(look.ink3).fixedSize(horizontal: false, vertical: true)
                }
                if let detail = line.detail {
                    Text(detail).font(.system(size: 11, design: .monospaced)).foregroundStyle(look.ink3).lineLimit(1)
                }
                // Why it waits, whole, under the name: never cut beside a button (P948).
                if line.state == .trust {
                    Text(WelcomeText.trust).font(.system(size: 11)).foregroundStyle(look.amber).fixedSize(horizontal: false, vertical: true)
                }
                // A file the switch left still runs Vibe Island's bridge (P974).
                if let left = model.vibeLeft[line.id] {
                    Text(left).font(.system(size: 11)).foregroundStyle(look.amber).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 6)
            WelcomeLineTrailing(line: line, model: model)
        }
        .padding(.leading, indented ? 40 : 12)
        .padding(.trailing, 12)
        .padding(.vertical, 3)
        .frame(minHeight: indented ? 38 : 40)
        .contentShape(Rectangle())
        .onTapGesture { model.toggle(line.id) }
        .accessibilityElement(children: .combine)
    }
}

/// The tick: a filled circle with a check when on, a ring when off; a green check once connected, a spinner while it
/// is written, an amber dot where it waits on the owner, nothing for a word.
private struct WelcomeTick: View {
    let state: WelcomeModel.LineState
    let toggle: () -> Void
    @Environment(\.welcomeLook) private var look

    var body: some View {
        Group {
            switch state {
            case let .tick(on):
                Button(action: toggle) {
                    ZStack {
                        Circle().strokeBorder(on ? look.accent : look.ink3, lineWidth: 1.5)
                        if on {
                            Circle().fill(look.accent)
                            Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(on ? "Connect: on" : "Connect: off")
            case .connected:
                ZStack {
                    Circle().fill(look.green.opacity(0.16))
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(look.green)
                }
            case .working:
                ProgressView().controlSize(.mini)
            case .trust, .addByHand, .vibe:
                Circle().fill(look.amber).frame(width: 7, height: 7)
            case .kept, .word:
                Circle().strokeBorder(look.ink3.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
            }
        }
        .frame(width: 18, height: 18)
        .animation(.smooth(duration: 0.25), value: state)
    }
}

/// The line's right side: Connected, a Copy for Codex's trust or a file to edit by hand, Vibe Island's, or a word.
private struct WelcomeLineTrailing: View {
    let line: WelcomeModel.Line
    let model: WelcomeModel
    @Environment(\.welcomeLook) private var look

    var body: some View {
        switch line.state {
        case .tick: if let note = line.note { word(note, look.ink3) }
        case .connected: word("Connected", look.green)
        case .working: word("Connecting…", look.ink2)
        case .trust:
            WelcomeCopyButton(title: "Copy /hooks", text: "/hooks", services: model.services)
        case let .addByHand(file, snippet, replaces):
            HStack(spacing: 8) {
                word("Add by hand", look.amber)
                    .help(AgentRowStatus.addByHand(file: file, snippet: snippet, replacesHooks: replaces).detail ?? "")
                WelcomeCopyButton(title: "Copy snippet", text: snippet, services: model.services)
            }
        case .vibe: word(WelcomeText.vibeStillThere, look.amber)
        case .kept: word(WelcomeText.kept, look.ink3)
        case let .word(text): word(text.isEmpty ? line.note ?? "" : text, look.ink3)
        }
    }

    private func word(_ text: String, _ colour: Color) -> some View {
        Text(text).font(.system(size: 11.5)).foregroundStyle(colour).lineLimit(1)
    }
}

private struct WelcomeCopyButton: View {
    let title: String
    let text: String
    let services: any WelcomeServices
    @State private var copied = false
    @Environment(\.welcomeLook) private var look

    var body: some View {
        Button {
            services.copy(text)
            copied = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        } label: {
            Text(copied ? "Copied" : title).font(.system(size: 11, weight: .medium)).foregroundStyle(look.ink)
                .padding(.horizontal, 8).frame(height: 22)
                .background(Capsule().fill(look.secondaryFill))
        }
        .buttonStyle(.plain)
        .fixedSize()
    }
}

/// Approve or Watch, beside the agent's name.
private struct WelcomeReachTag: View {
    let reach: AgentReach
    @Environment(\.welcomeLook) private var look

    var body: some View {
        Text(reach.title).font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(reach == .approve ? look.accent : look.ink2)
            .padding(.horizontal, 5).frame(height: 15)
            .background(Capsule().fill(reach == .approve ? look.accent.opacity(0.14) : look.secondaryFill))
            .fixedSize()
            .help(reach.help)
    }
}

/// Open Island or Vibe Island: one line and two buttons.
private struct WelcomeCard: View {
    let text: String
    let primary: String
    let secondary: String
    var busy = false
    let onPrimary: () -> Void
    let onSecondary: () -> Void
    @Environment(\.welcomeLook) private var look

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle().fill(look.amber).frame(width: 7, height: 7).alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                Text(text).font(.system(size: 12.5, weight: .medium)).foregroundStyle(look.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                WelcomeSecondaryButton(title: busy ? "Switching…" : primary, prominent: true, action: onPrimary).disabled(busy)
                WelcomeSecondaryButton(title: secondary, action: onSecondary).disabled(busy)
            }
            .padding(.leading, 15)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(look.amber.opacity(look.dark ? 0.08 : 0.07)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(look.amber.opacity(0.25), lineWidth: 1))
    }
}

/// The "i": every file Connect writes, `~/…`.
private struct WelcomeFiles: View {
    let files: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(files.isEmpty ? "Tick an agent to see its files." : "Connect writes, after a backup of each:")
                .font(.system(size: 11, weight: .medium))
            ForEach(files, id: \.self) { file in
                Text(file).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
            }
        }
        .padding(12)
        .frame(maxWidth: 380, alignment: .leading)
    }
}

// MARK: 3. Pick a look

/// Pick a look: Island or Window, a glyph style as live tiles, and Launch at Login (registered only as this screen is
/// left, P962).
struct WelcomePickLook: View {
    @Bindable var model: WelcomeModel
    @Environment(\.welcomeLook) private var look

    var body: some View {
        @Bindable var settings = model.env.settings
        VStack(spacing: 0) {
            WelcomeHeadline(text: WelcomeText.headline(.look)).padding(.bottom, 18)
            HStack(spacing: 12) {
                WelcomeSurfaceTile(surface: .island, selected: model.surface == .island) { model.surface = .island }
                WelcomeSurfaceTile(surface: .window, selected: model.surface == .window) { model.surface = .window }
            }
            HStack(spacing: 10) {
                ForEach([(GlyphStyle.pixel, "Pixel"), (.liquid, "Liquid"), (.sand, "Sand")], id: \.0) { style, name in
                    WelcomeGlyphTile(style: style, name: name, selected: settings.glyphStyle == style) { settings.glyphStyle = style }
                }
            }
            .padding(.top, 14)
            if model.showsLaunchAtLogin {
                HStack {
                    Text("Launch at Login").font(.system(size: 13)).foregroundStyle(look.ink)
                    Spacer()
                    WelcomeSwitch(isOn: $model.launchAtLogin, label: "Launch at Login")
                }
                .padding(.horizontal, 12)
                .frame(height: 40)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(look.group))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(look.groupEdge, lineWidth: 1))
                .padding(.top, 14)
            }
            Spacer(minLength: 12)
            WelcomePrimaryButton(title: "Next") { model.primary() }
        }
    }
}

/// A switch in the welcome's colours: the accent when on.
private struct WelcomeSwitch: View {
    @Binding var isOn: Bool
    let label: String
    @Environment(\.welcomeLook) private var look

    var body: some View {
        Button {
            withAnimation(.smooth(duration: 0.18)) { isOn.toggle() }
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule().fill(isOn ? look.accent : look.secondaryFill)
                Circle().fill(.white).frame(width: 18, height: 18).shadow(color: .black.opacity(0.3), radius: 1, y: 1).padding(2)
            }
            .frame(width: 38, height: 22)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

/// Island or Window, drawn: a screen with the island under its notch, or a window with its rows.
private struct WelcomeSurfaceTile: View {
    let surface: ShowAs
    let selected: Bool
    let pick: () -> Void
    @Environment(\.welcomeLook) private var look

    var body: some View {
        Button(action: pick) {
            VStack(spacing: 8) {
                ZStack(alignment: .top) {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(LinearGradient(colors: look.dark ? [Color(hex: 0x2B2D3A), Color(hex: 0x17181F)]
                                                              : [Color(hex: 0xDCE3F2), Color(hex: 0xC5CEE2)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                    // The menu bar's faint band.
                    Rectangle().fill(Color.white.opacity(look.dark ? 0.06 : 0.35)).frame(height: 9)
                    if surface == .island {
                        VStack(spacing: 0) {
                            UnevenRoundedRectangle(bottomLeadingRadius: 9, bottomTrailingRadius: 9, style: .continuous)
                                .fill(.black)
                                .frame(width: 92, height: 30)
                                .overlay(alignment: .leading) {
                                    HStack(spacing: 4) {
                                        Circle().fill(Color(hex: 0xFFB45C)).frame(width: 5, height: 5)
                                        Capsule().fill(Color.white.opacity(0.5)).frame(width: 30, height: 3)
                                    }
                                    .padding(.leading, 10).padding(.top, 10)
                                }
                            Spacer()
                        }
                    } else {
                        RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.black.opacity(look.dark ? 0.85 : 0.82))
                            .frame(width: 112, height: 60)
                            .overlay(alignment: .topLeading) {
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack(spacing: 3) {
                                        ForEach([UInt32(0xFF5F57), 0xFEBC2E, 0x28C840], id: \.self) { Circle().fill(Color(hex: $0)).frame(width: 4, height: 4) }
                                    }
                                    ForEach(0..<3, id: \.self) { row in
                                        HStack(spacing: 4) {
                                            Circle().fill(row == 0 ? Color(hex: 0xFFB45C) : Color.white.opacity(0.35)).frame(width: 4, height: 4)
                                            Capsule().fill(Color.white.opacity(0.35)).frame(width: CGFloat(56 - row * 12), height: 3)
                                        }
                                    }
                                }
                                .padding(7)
                            }
                            .padding(.top, 20)
                    }
                }
                .frame(height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                Text(surface == .island ? "Island" : "Window").font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(selected ? look.ink : look.ink2)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(look.group))
            .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(selected ? look.accent : look.groupEdge, lineWidth: selected ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        .buttonStyle(WelcomePressStyle())
        .accessibilityLabel(surface == .island ? "Island" : "Window")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A glyph style, running live on the island's black.
private struct WelcomeGlyphTile: View {
    let style: GlyphStyle
    let name: String
    let selected: Bool
    let pick: () -> Void
    @Environment(\.welcomeLook) private var look
    @Environment(\.sessionGlyphsAnimated) private var animated

    var body: some View {
        Button(action: pick) {
            VStack(spacing: 6) {
                HStack(spacing: 10) {
                    StateGlyphView(glyph: .eq, colour: GlyphPalette.colour(agent: .claude, state: .running, mode: .byState, needsYou: .pink),
                                   pixel: 2.6, animated: animated, style: style, liquidRunning: .slim)
                    StateGlyphView(glyph: .check, colour: GlyphPalette.colour(agent: .claude, state: .done, mode: .byState, needsYou: .pink),
                                   pixel: 2.6, animated: animated, style: style, liquidRunning: .slim)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black))
                .environment(\.juiceTheme, .black)
                Text(name).font(.system(size: 12, weight: .medium)).foregroundStyle(selected ? look.ink : look.ink2)
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(look.group))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(selected ? look.accent : look.groupEdge, lineWidth: selected ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(WelcomePressStyle())
        .accessibilityLabel(name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: 4. First session

/// First session: the first connected agent's command in the usual terminal, the line that says macOS asks first, Copy
/// and Later; the window closes itself once that session reaches the island (P960, P961).
struct WelcomeStart: View {
    let model: WelcomeModel
    @Environment(\.welcomeLook) private var look
    @State private var copied = false

    var body: some View {
        let agent = model.firstAgent
        let terminal = model.services.terminalName
        VStack(spacing: 0) {
            Spacer(minLength: 8)
            if let agent {
                ZStack {
                    Circle().fill(look.group).frame(width: 88, height: 88)
                    Circle().strokeBorder(look.groupEdge, lineWidth: 1).frame(width: 88, height: 88)
                    AgentLookMark(look: agent.look, size: 38, theme: look.markTheme)
                }
                .padding(.bottom, 18)
                HStack(spacing: 0) {
                    Text("$ ").foregroundStyle(look.ink3)
                    Text(WelcomeModel.command(for: agent)).foregroundStyle(look.ink)
                    Spacer(minLength: 8)
                    Button {
                        model.copyCommand()
                        copied = true
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(1.5))
                            copied = false
                        }
                    } label: {
                        Text(copied ? "Copied" : "Copy").font(.system(size: 11.5, weight: .medium)).foregroundStyle(look.ink2)
                    }
                    .buttonStyle(.plain)
                }
                .font(.system(size: 13, design: .monospaced))
                .padding(.horizontal, 14)
                .frame(height: 40)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(look.group))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(look.groupEdge, lineWidth: 1))
                .padding(.horizontal, 30)
                .padding(.bottom, 22)
            }
            WelcomeHeadline(text: WelcomeText.headline(.start), hint: hint(agent, terminal: terminal),
                            hintColour: model.startState == .failed ? look.amber : nil)
            Spacer(minLength: 12)
            WelcomePrimaryButton(title: model.startState == .opened || model.startState == .opening ? WelcomeText.waiting(agent)
                                                                                                     : WelcomeText.start(agent),
                                 busy: model.startState == .opening || model.startState == .opened) { model.primary() }
            Button("Later") { model.finish(.later) }
                .buttonStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(look.ink2)
                .keyboardShortcut(.cancelAction)
                .padding(.top, 10)
        }
    }

    private func hint(_ agent: AgentRow?, terminal: String) -> String {
        guard agent != nil else { return WelcomeText.noAgent }
        if model.startState == .failed { return WelcomeText.failed(terminal: terminal) }
        return WelcomeText.automation(terminal: terminal)
    }
}
