import SwiftUI

/// The Update control's state (P803 to P809): one control wherever an update starts, the window's toolbar and
/// Settings › About, which is itself the progress. The gear menus keep their line, which opens About (P807).
enum UpdateControlState: Equatable, Sendable {
    /// Nothing offered and nothing to say: no control.
    case hidden
    /// An update is offered: "Update", or "Restart to update" once a background prepare has it built (P711).
    case offer(restart: Bool)
    /// A run: its words inside ("Fetching", "Waiting for build", "Building 63%", "Still building", "Installing") over the
    /// fill (`fraction`, the whole run).
    case running(words: String, fraction: Double)
    /// Built and checked: the fill completes, "Updated" with a check, a brief glow, then the relaunch.
    case finished
    /// Past ready the app is still here (P98): "Restart to update" quits it.
    case restartNeeded
    /// The run failed: "Update failed" with Retry; About says the reason in plain words, its log one click away (in the
    /// toolbar the words open it).
    case failed(reason: String)
    /// This build is the one an update just opened (its short commit): "Updated", still.
    case updated(String)

    /// Where the control is: the window's toolbar, or Settings › About.
    enum Place { case toolbar, about }

    /// What a click does.
    enum Action: Equatable, Sendable { case update, restartNow, retry, openAbout, none }

    static func of(available: UpdateInfo?, phase: UpdatePhase, prepared: Bool, progress: UpdateProgress) -> UpdateControlState {
        switch phase {
        case .pulling, .waiting, .settingUp, .building, .installing:
            .running(words: UpdateText.controlWords(phase, progress: progress) ?? "", fraction: progress.fraction)
        case .restarting: .finished
        case .restartNeeded: .restartNeeded
        case let .failed(reason): .failed(reason: reason)
        case let .updated(commit): available == nil ? .updated(commit) : .offer(restart: prepared)
        case .idle: available == nil ? .hidden : .offer(restart: prepared)
        }
    }

    /// The words inside the control.
    var words: String {
        switch self {
        case .hidden: ""
        case let .offer(restart): restart ? UpdateText.restartToUpdate : "Update"
        case let .running(words, _): words
        case .finished, .updated: "Updated"
        case .restartNeeded: UpdateText.restartToUpdate
        case .failed: "Update failed"
        }
    }

    /// The fill, 0 to 1: the run's progress; whole once it is built, and on the controls that act at once.
    var fill: Double {
        switch self {
        case let .running(_, fraction): min(1, max(0, fraction))
        case .offer, .finished, .restartNeeded: 1
        case .hidden, .failed, .updated: 0
        }
    }

    /// A click: Update or Restart to update starts it, Restart to update past ready quits, Retry runs it again; in the
    /// toolbar a run, a failure or the note after one opens About, where the time left, the reason and the log, and
    /// What's new are. A run in About, and its end, take no click.
    func action(in place: Place) -> Action {
        switch self {
        case .offer: .update
        case .restartNeeded: .restartNow
        case .failed: place == .toolbar ? .openAbout : .retry
        case .running, .updated: place == .toolbar ? .openAbout : .none
        case .hidden, .finished: .none
        }
    }

    /// A failure in the toolbar is two controls (P809): its words open About, and Retry, its own half, runs it again.
    /// In About, under the reason and Show Log, the whole control retries.
    func hasOwnRetry(in place: Place) -> Bool {
        if case .failed = self { place == .toolbar } else { false }
    }

    /// The tooltip and the spoken label: what it says, in full (P898), and what a click does.
    func help(available: UpdateInfo?, progress: UpdateProgress, place: Place) -> String {
        switch self {
        case .hidden: return ""
        case let .offer(restart): return available.map { UpdateText.toolbarHelp($0, prepared: restart) } ?? words
        case let .running(words, _):
            let full = UpdateText.fullWords(words, progress: progress)
            // "Still building, the Mac is busy" says the time's reason already.
            let left = progress.overran && progress.busy ? nil : UpdateText.timeLeft(progress)
            let parts = [full, left.map { $0.prefix(1).lowercased() + $0.dropFirst() }].compactMap(\.self)
            return parts.joined(separator: " · ") + (place == .toolbar ? " · click for details" : "")
        case .finished: return "Updated · restarting"
        case .restartNeeded: return "The update is built · click to restart"
        case let .failed(reason):
            return "Update failed: \(UpdateText.plainReason(reason))" + (place == .toolbar ? " · click for details" : " · click to retry")
        case let .updated(commit): return "Updated to \(commit)" + (place == .toolbar ? " · click for What's new" : "")
        }
    }
}

/// The Update control: the state from the checker and the controller, the click, the hover, and the glow when a run
/// completes (none under Reduce Motion). Nothing moves at rest: the fill moves only while a run's progress does, and
/// the glow plays once.
struct UpdateControl: View {
    var place: UpdateControlState.Place
    @Environment(AppEnvironment.self) private var env
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @State private var hoveringRetry = false
    @State private var glow = 0.0

    var body: some View {
        let controller = env.updateController
        let available = env.updateChecker.available
        let progress = controller.progress
        let state = UpdateControlState.of(available: available, phase: controller.phase,
                                          prepared: controller.restartOffered(for: available), progress: progress)
        if state != .hidden {
            let action = state.action(in: place)
            let help = state.help(available: available, progress: progress, place: place)
            let size: UpdateControlFace.Size = place == .toolbar ? .toolbar : .about
            let ownRetry = state.hasOwnRetry(in: place)
            Button { perform(action) } label: {
                UpdateControlFace(state: state, size: size, hovering: hovering && action != .none,
                                  hoveringRetry: ownRetry && hoveringRetry, glow: glow, reduceMotion: reduceMotion)
            }
            .buttonStyle(.plain)
            .allowsHitTesting(action != .none)
            .onHover { hovering = $0 }
            .help(help)
            .accessibilityLabel(help)
            .accessibilityAddTraits(state.isRunning ? .updatesFrequently : [])
            .overlay(alignment: .trailing) {
                if ownRetry {
                    Button { perform(.retry) } label: {
                        Color.clear.frame(width: size.retryWidth, height: size.height).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { hoveringRetry = $0 }
                    .help("Retry the update")
                    .accessibilityLabel("Retry the update")
                }
            }
            .onChange(of: state == .finished) { _, finished in
                guard finished, !reduceMotion else { return }
                withAnimation(.easeOut(duration: 0.3)) { glow = 1 } completion: {
                    withAnimation(.easeInOut(duration: 0.8)) { glow = 0 }
                }
            }
        }
    }

    private func perform(_ action: UpdateControlState.Action) {
        let controller = env.updateController
        switch action {
        case .update: controller.act()
        case .restartNow: controller.restartNow()
        case .retry: controller.start()
        case .openAbout: env.actions.openSettings(.about)
        case .none: break
        }
    }
}

extension UpdateControlState {
    var isRunning: Bool { if case .running = self { true } else { false } }
}

/// The control as drawn, every input given (renders draw each state, the glow at its height too). A run is a light
/// track the fill sweeps across, its words white over the fill and blue over the rest; Reduce Motion draws the track
/// and the words only. The end is the whole fill with a check and "Updated", and the glow around it.
struct UpdateControlFace: View {
    enum Size {
        case toolbar, about

        var height: CGFloat { self == .toolbar ? WindowTheme.Metrics.segmentHeight : 28 }
        /// One width for every state, so the words change and the control does not (P808): the widest words fit,
        /// "Restart to update" with its arrow and "Update failed" with Retry.
        var width: CGFloat { self == .toolbar ? 146 : 168 }
        /// A failure's Retry half, at the trailing end (in the toolbar, a control of its own).
        var retryWidth: CGFloat { self == .toolbar ? 48 : 54 }
        var font: Font { self == .toolbar ? WindowTheme.TypeScale.segment : Fonts.sys(13, .medium) }
        var radius: CGFloat { 7 }
    }

    var state: UpdateControlState
    var size: Size
    var hovering = false
    /// The pointer is on a failure's Retry half, where it is a control of its own.
    var hoveringRetry = false
    /// 0 to 1: the glow around a run that completed.
    var glow = 0.0
    var reduceMotion = false

    /// The run's empty track, and its words where the fill has not reached.
    static let track = Color.adaptive(light: SettingsTheme.accent.opacity(0.14), dark: Color(hex: 0x0A84FF).opacity(0.24))
    static let trackInk = Color.adaptive(0x0058B8, 0x8CC4FF)
    /// After the relaunch: a quiet note.
    static let noteFill = SettingsTheme.pair(black: 0.05, white: 0.08)
    static let failedFill = Color.adaptive(light: Color(hex: 0xC42B22).opacity(0.10), dark: Color(hex: 0xFF7C75).opacity(0.16))

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size.radius, style: .continuous)
        ZStack {
            switch state {
            case .hidden: EmptyView()
            case .offer, .restartNeeded:
                shape.fill(SettingsTheme.accent.opacity(hovering ? 0.85 : 1))
                words(.white, arrow: true)
            case let .running(_, fraction):
                running(fraction: reduceMotion ? 0 : min(1, max(0, fraction)), shape: shape)
            case .finished:
                shape.fill(SettingsTheme.accent)
                words(.white, check: true)
            case .failed:
                // Hover lifts the half under the pointer: the whole control, or Retry where it is its own.
                shape.fill(Self.failedFill.opacity(hovering && !hoveringRetry ? 1.6 : 1))
                HStack(spacing: 0) {
                    Text(state.words).foregroundStyle(SettingsTheme.statusRed).frame(maxWidth: .infinity)
                    Rectangle().fill(SettingsTheme.statusRed.opacity(0.35)).frame(width: 1, height: size.height * 0.46)
                    Text("Retry").fontWeight(.semibold).foregroundStyle(SettingsTheme.accent)
                        .frame(width: size.retryWidth, height: size.height)
                        .background(Self.failedFill.opacity(hoveringRetry ? 0.6 : 0))
                }
                .font(size.font)
                .lineLimit(1)
            case .updated:
                shape.fill(Self.noteFill)
                words(SettingsTheme.ink2, check: true)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(shape)
        .background {
            if glow > 0 { shape.fill(SettingsTheme.accent).shadow(color: SettingsTheme.accent.opacity(0.85 * glow), radius: 10 * glow) }
        }
        .contentShape(shape)
    }

    /// The track, the fill from the leading edge, and the words twice: blue where the fill has not reached, white over it.
    private func running(fraction: Double, shape: RoundedRectangle) -> some View {
        let filled = size.width * fraction
        return ZStack(alignment: .leading) {
            shape.fill(Self.track)
            Rectangle().fill(SettingsTheme.accent).frame(width: filled)
            words(Self.trackInk)
                .mask(alignment: .trailing) { Rectangle().frame(width: size.width - filled) }
            words(.white)
                .mask(alignment: .leading) { Rectangle().frame(width: filled) }
        }
        .animation(reduceMotion ? nil : .linear(duration: 0.55), value: fraction)
    }

    private func words(_ ink: Color, arrow: Bool = false, check: Bool = false) -> some View {
        HStack(spacing: 6) {
            if arrow { SVGIcon(svg: ChromeIcon.update, size: CGSize(width: 11, height: 11), colour: ink) }
            if check { CheckMark().stroke(ink, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round)).frame(width: 10, height: 10) }
            Text(state.words).font(size.font).monospacedDigit().foregroundStyle(ink).lineLimit(1)
        }
        .frame(width: size.width, height: size.height)
    }
}

/// The finished run's check.
struct CheckMark: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.1, y: rect.minY + rect.height * 0.55))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.4, y: rect.minY + rect.height * 0.82))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.92, y: rect.minY + rect.height * 0.2))
        return path
    }
}
