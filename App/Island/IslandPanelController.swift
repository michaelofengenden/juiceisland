import AppKit
import JuiceCore
import Observation
import SwiftUI

/// Island mode's panel: a nonactivating `NSPanel` over the notch (placement from the screen, never hard-coded, P37;
/// no screen or a gone display falls back without crashing, P38), one tracking area and the pure hover state machine
/// (P35), keys only in the panel's own event path (P39, P40), no event monitor. The panel never animates: a still
/// SwiftUI canvas (`IslandRootView`) draws all the motion, `IslandMotionDirector` plays the choreography, and the panel
/// only snaps between the sizes the choreography asks for, growing before a growth and shrinking once the shape fits,
/// so at rest it is exactly the visible surface (P36). The shell calls `show()` when Show as becomes Island and
/// `hide()` when it becomes Window. Owner: stream D.
@MainActor
final class IslandPanelController {
    private let env: AppEnvironment
    let ui = IslandUIState()
    private var panel: IslandPanel?
    private var container: IslandContainerView?
    private var hosting: IslandHostingView?
    /// The canvas's views, drawn with the outline Diagnostics › Motion › Outline asks for (`IslandCanvas`).
    private var canvas: IslandCanvas?
    /// An outline switch that waits for the island to rest (it never lands mid-motion).
    private var outlineWaits = false
    /// Whether anyone can see the panel: its glyphs pause while it is ordered out (Window mode, the idle pill hidden),
    /// the displays sleep, the screen saver runs or the screen locks (P89).
    private let motion = SurfaceMotion(.hidden)
    private var motionWatch: SurfaceMotionWatch?
    private var machine = IslandHoverMachine()
    private var director: IslandMotionDirector?
    private var screen: IslandScreen?
    /// The canvas's place on the screen: it never moves while the display stays.
    private var canvasRect = CGRect.zero
    /// Settings › Island › Width and Text size as the canvas was last built for (P401, P402).
    private var size = IslandSize.standard
    private var shown = false
    /// Bumped by every `show()`, so an observer left pending by an earlier show never re-registers (no doubled observers).
    private var generation = 0
    private var lastRows: [SessionRow] = []
    /// The live engine's last Done the island has heard (`FinishSource`), so each is heard once.
    private var lastFinish: ReleasedFinish?
    /// The last quota notice the island heard of (P125), shown or not: one notice is handled once.
    private var lastNotice: String?
    /// A notice that came while the owner was at a card: it shows once that card is gone, unless it is old by then.
    private var pendingNotice: QuotaNotice?
    private var screenObserver: NSObjectProtocol?
    /// A right-click menu's end: menus are modal, so the pointer is read again once one closes (P320).
    private var menuObserver: NSObjectProtocol?
    /// Reduce Transparency and Increase Contrast: Core Animation's glass reads them when made, so it is made again.
    private var accessibilityObserver: NSObjectProtocol?
    private var finishedTask: Task<Void, Never>?
    /// A card built ahead under the pointer, after a short dwell on its row (P133).
    private var hoverMount: Task<Void, Never>?
    /// The row with a card the pointer rests on, for a build ahead the island's motion put off.
    private var hoveredRow: SessionRow?
    /// A card to build ahead waited for the island to rest (E4): the next that waits, or the hovered row's.
    private var aheadWaits = false
    private let menuActions = MenuActions()
    /// The pointer as the machine last heard it: inside the target shape or not.
    private var pointerInside = false
    private var speed = PointerSpeed()
    /// Samples the pointer 60 times a second while the island waits for a rest, or while it strays in the band outside
    /// the panel (a strict timer).
    private var poll: StrictTimer?
    /// The one timer the hover machine asked for last (its rest, a grace, the Done card's life): an older one is stale to
    /// the machine, so a new one takes its place.
    private var hoverTimer: StrictTimer?
    /// A close has run and its reset (the list, Show all, the strip) has not yet: a reverse keeps what was there.
    private var resetPending = false
    /// The card the open island has come to rest on (`IslandMotion.cardRest`): the next that waits is built beside it.
    private var restingCard: String?
    /// A card's arrival: it settles (`IslandUIState.arrivingCard`), then the island rests on it.
    private var arrival: Task<Void, Never>?
    /// Where Diagnostics › Motion › Record island motion writes.
    private let motionFolder = MotionReportFolder()
    /// Where the owner is (P270): the apps that become active and the panel losing its keys, while the island shows.
    private var focusWatch: IslandFocusWatch?
    /// The app in front when the island last opened: its own activation, heard just after an open it came before,
    /// never folds the island.
    private var frontAtOpen: pid_t?
    /// Whether the pointer on the island moved there, rather than the island opening under it (P271).
    private var engagement = PointerEngagement()
    /// The requests the island folded away from: they stay on the pill and never open it again by themselves (P272).
    private var putAway = IslandPutAway()
    /// A row's peek after the pointer rests on it (P311).
    private lazy var peeker = IslandPeeker(ui: ui, settings: env.settings, sessions: { [unowned self] in self.env.sessions })
    /// Whether the frontmost app is in full screen on the island's display, heard only while Hide in full screen is on
    /// (`FullScreenWatch`, P330).
    private var fullScreen = false
    private var fullScreenWatch: FullScreenWatch?
    /// The request whose card the island last told the sessions it shows (`syncShownRequest`, P350).
    private var reportedShown: String?
    /// Session → the request key of each needs-you heard while the owner was away with Quiet while locked on: the
    /// catch-up once they are back opens on the one that has waited longest (`LockCatchUp`, P423).
    private var awayArrivals: [String: String] = [:]
    /// The catch-up's short wait after the unlock.
    private var catchUp: Task<Void, Never>?

    /// On every Space and over full-screen apps: the pill is always there to see, so no full-screen app pauses its
    /// glyph (P89).
    static let behaviour: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

    init(env: AppEnvironment) {
        self.env = env
        ui.holdsGlyphs = true
    }

    // MARK: Show and hide

    /// Island mode: the panel is built at the idle geometry (black on black under a notch), ordered in, and the pill
    /// arrives from behind the notch a turn later.
    func show() {
        guard !shown else { return }
        shown = true
        generation &+= 1
        lastRows = env.sessions.rows
        // What waits now is what the island has heard: a close before the first batch puts it away (P272).
        _ = putAway.hear([], rows: lastRows, pending: pendingKeys(lastRows))
        if case let .engine(last) = env.sessions.finishSource { lastFinish = last }
        // A notice from before the island showed (Window mode) is old news.
        lastNotice = env.usage.quotaNotice?.id
        pendingNotice = nil
        // What came while the island was away (Window mode) is on the pill, as ever: nothing to catch up on.
        awayArrivals = [:]
        if panel == nil { panel = makePanel() }
        watchFocus()
        syncFullScreenWatch()
        observeSessions()
        observeSettings()
        observeMotionSettings()
        observeTheme()
        observeNotices()
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.canvas?.rebuildGlass() }
        }
        observeSize()
        observeUpdate()
        observeScreenLock()
        observeNudges()
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.displayChanged() }
        }
        // A row's or a card header's menu (and the gear's) holds the pointer's events while it shows: a leave it held back
        // still closes the island once it goes, a turn later, after the item it ran (P270, P320).
        menuObserver = NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil,
                                                              queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.resyncPointer() }
        }
        guard let screen = resolveScreen() else { return }
        build(on: screen)
        director?.send(.show)
        let generation = generation
        Task { @MainActor [weak self] in
            guard let self, self.shown, self.generation == generation else { return }
            self.pillChanged()
        }
    }

    /// Window mode: whatever shows folds into the notch, then the panel goes (at once under Reduce Motion).
    func hide() {
        guard shown else { return }
        shown = false
        unlightRim()
        _ = machine.handle(.dismissed)
        syncShownRequest()
        stopPolling()
        hoverTimer?.cancel()
        hoverTimer = nil
        catchUp?.cancel()
        catchUp = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        if let menuObserver { NotificationCenter.default.removeObserver(menuObserver) }
        menuObserver = nil
        if let accessibilityObserver { NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver) }
        accessibilityObserver = nil
        focusWatch?.stop()
        focusWatch = nil
        syncFullScreenWatch()
        giveUpKey()
        guard let director, screen != nil else {
            teardown()
            return
        }
        director.send(.reduceMotion(reduceMotion))
        director.send(.hide)
    }

    /// Nothing is drawn while the window shows instead; `show()` builds the island again for its display.
    private func teardown() {
        panel?.orderOut(nil)
        motionWatch?.refresh()
        hosting?.rootView = AnyView(Color.clear)
        canvas?.setRimRoot(AnyView(EmptyView()))
        screen = nil
    }

    /// Where the closed pill sits, for the window's fold into the notch; nil without a display.
    var pillFrame: CGRect? {
        guard let screen = resolveScreen() else { return nil }
        return NotchGeometry.frame(pillContent(on: screen).extent, on: screen)
    }

    /// What the closed pill shows on `screen`, from the sessions and Settings.
    private func pillContent(on screen: IslandScreen) -> PillContent {
        Self.pill(rows: env.sessions.rows, settings: env.settings, glance: ui.glance, recentlyFinished: ui.recentlyFinished,
                  now: env.sessions.now, on: screen, fullScreen: fullScreen, update: updateWaits)
    }

    /// An update waits for the owner's click (the gear's Update, P403): offered and not running, or a restart asked for.
    private var updateWaits: Bool {
        UpdateText.menuEnabled(available: env.updateChecker.available, phase: env.updateController.phase)
    }

    /// The pill with nothing to show on `screen`: the notch alone, or the idle bar.
    private func idlePill(on screen: IslandScreen) -> PillContent {
        Self.idlePill(settings: env.settings, on: screen)
    }

    /// The closed pill for `rows` on `screen`: its notch (or the top bar), its menu bar and its scale.
    static func pill(rows: [SessionRow], settings: AppSettings, glance: Bool, recentlyFinished: GlyphPalette.Agent?,
                     now: Date, on screen: IslandScreen, fullScreen: Bool = false, update: Bool = false) -> PillContent {
        PillContent.make(rows: rows, settings: settings, glance: glance, recentlyFinished: recentlyFinished, now: now,
                         notch: NotchGeometry.notchSize(on: screen), menuBar: screen.menuBarHeight, displayScale: screen.scale,
                         fullScreen: fullScreen, update: update)
    }

    /// The pill's idle rest hides (the panel ordered out, the no-notch bar folded into the top edge): Hide the pill when
    /// idle, or full screen hiding the pill on a display without a notch, whose idle bar would show. Under a notch the
    /// hidden pill is the notch itself, black on black, and a rest or a click there still opens the island (P56, P330).
    static func hidesIdlePill(settings: AppSettings, fullScreen: Bool, on screen: IslandScreen) -> Bool {
        settings.hidePillWhenIdle || (fullScreen && settings.hideInFullScreen && !screen.hasNotch)
    }

    private func hidesIdlePill(on screen: IslandScreen) -> Bool {
        Self.hidesIdlePill(settings: env.settings, fullScreen: fullScreen, on: screen)
    }

    static func idlePill(settings: AppSettings, on screen: IslandScreen) -> PillContent {
        PillContent.make(lead: nil, count: nil, glance: false, style: settings.glyphStyle, edgeLine: settings.glyphEdgeLine,
                         notch: NotchGeometry.notchSize(on: screen), menuBar: screen.menuBarHeight, displayScale: screen.scale)
    }

    // MARK: Panel

    private func makePanel() -> IslandPanel {
        let panel = IslandPanel(contentRect: CGRect(x: 0, y: 0, width: 185, height: 32),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = Self.behaviour
        IslandPanel.configureKeyViewLoop(panel)
        panel.keyHandler = { [weak self] key in self?.handleKey(key) ?? false }

        // The hosting view is the canvas, a subview that SwiftUI can never resize and the panel never stretches (U2).
        let container = IslandContainerView(frame: panel.contentLayoutRect)
        container.autoresizesSubviews = false
        container.pointer = { [weak self] kind, event in
            let sample = PointerSample(event: event)
            self?.pointer(kind, sample)
            self?.lightRim(kind, sample)
        }
        let hosting = IslandHostingView(rootView: AnyView(Color.clear))
        hosting.sizingOptions = []
        hosting.safeAreaRegions = []
        hosting.autoresizingMask = []
        let canvas = IslandCanvas(ui: ui, hosting: hosting, container: container)
        canvas.fellBack = { [weak self] in self?.outlineFellBack() }
        panel.contentView = container
        self.container = container
        self.hosting = hosting
        self.canvas = canvas
        motionWatch = SurfaceMotionWatch(window: panel, motion: motion, island: true)
        return panel
    }

    /// The canvas, the root view and a fresh choreography at the idle geometry on `screen`.
    private func build(on screen: IslandScreen) {
        placeCanvas(on: screen)
        let layout = director?.model.layout ?? ContentLayout()
        machine.tuning = tuning
        let metrics = IslandChoreography.Metrics(targets: SurfaceTargets(notch: NotchGeometry.notchSize(on: screen), pill: idlePill(on: screen),
                                                                         hideWhenIdle: hidesIdlePill(on: screen), islandWidth: size.outer),
                                                 layout: layout, reduceMotion: reduceMotion, tuning: tuning,
                                                 outline: canvas?.outline ?? .swiftUI, maxHeight: IslandPanelSizing.maxIslandHeight(screen))
        let model = IslandChoreography(metrics: metrics, ordered: false, at: IslandMotionDirector.now)
        (director ?? makeDirector(model)).reset(model)
        syncRecorder()
        syncOutline()
    }

    /// The canvas on `screen` (its rect never changes while the display stays) and the root view for its notch.
    private func placeCanvas(on screen: IslandScreen) {
        self.screen = screen
        size = IslandSize(env.settings)
        let notch = NotchGeometry.notchSize(on: screen)
        canvasRect = IslandPanelSizing.canvasRect(centreX: NotchGeometry.centreX(on: screen), top: screen.frame.maxY,
                                                  screenHeight: screen.frame.height, size: size)
        let idle = SurfaceTargets(notch: notch, pill: idlePill(on: screen), islandWidth: size.outer)
        let director = director ?? makeDirector(IslandChoreography(metrics: .init(targets: idle), ordered: false))
        hosting?.rootView = AnyView(IslandRootView(ui: ui, notch: notch, canvas: canvasRect.size,
                                                   maxHeight: IslandPanelSizing.maxIslandHeight(screen), size: size, actions: viewActions(),
                                                   pillClicked: { [weak self] in self?.feed(.clicked(at: IslandMotionDirector.now)) },
                                                   measured: { [weak director] in director?.measured($0) })
            .juiceThemeFromSettings().environment(env).glyphMotion(motion)
            // A row's or a card header's Jump to session folds the island and hands back its keys, as a row click's jump.
            .environment(\.sessionJump, { [weak self] (id: String) in self?.jump(id) }))
        canvas?.setRimRoot(AnyView(IslandRimView(ui: ui, notch: notch, width: canvasRect.width).juiceThemeFromSettings().environment(env)
            .glyphMotion(motion)))
        canvas?.resize(canvasRect.size)
        canvas?.setNotch(notch)
        canvas?.setTheme(env.settings.juiceTheme)
        canvas?.setStateTint(env.settings.islandStateTint)
        canvas?.setNeedsYou(env.settings.needsYouColour)
    }

    private func makeDirector(_ model: IslandChoreography) -> IslandMotionDirector {
        let director = IslandMotionDirector(model: model, ui: ui)
        director.applyPanel = { [weak self] extent in self?.applyPanel(extent) }
        director.perform = { [weak self] effect in self?.perform(effect) }
        director.targetChanged = { [weak self] in self?.relocatePointer() }
        director.rested = { [weak self] in self?.islandRested() }
        director.surface = canvas?.outline == .coreAnimation ? canvas?.layers : nil
        self.director = director
        return director
    }

    /// Snaps the panel to `extent` hanging from the top edge, the canvas staying where it is on the screen. Never
    /// animated and never from inside a SwiftUI update: only from the director's commands.
    private func applyPanel(_ extent: IslandExtent) {
        guard let panel, let canvas, let screen else { return }
        let frame = NotchGeometry.frame(extent, on: screen)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        canvas.place(IslandPanelSizing.hostingOrigin(canvas: canvasRect, panel: frame))
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        // Core Animation's layers checked, and put back, before this turn commits (P240).
        canvas.ensure()
        CATransaction.commit()
        relocatePointer()
    }

    private func perform(_ effect: IslandChoreography.Effect) {
        switch effect {
        case .orderIn:
            panel?.orderFrontRegardless()
            motionWatch?.refresh()
        case .orderOut:
            director?.recorder?.interrupt()
            panel?.orderOut(nil)
            motionWatch?.refresh()
            if !shown { teardown() }
        case .resetAfterFold:
            guard !ui.isOpen else { return }
            resetPending = false
            if case let .card(id) = ui.presentation, QuotaNoticeCard.isNotice(id) { env.islandNotice = nil }
            ui.presentation = .list
            // A card built ahead that the island never showed goes with the rest.
            if director?.model.cardMounted == nil { ui.card = nil }
            ui.aheadCard = nil
            ui.showAll = false
            ui.stripOpen = false
            ui.keyHover(nil)
            peeker.reset()
            ui.selectedRow = nil
            ui.switching = false
        case let .cardSnapshot(id):
            // Written only when it changes: a card built ahead in the card layer is already there (E4).
            let card = id.flatMap { env.card(for: $0) ?? ui.card }
            if ui.card != card { ui.card = card }
            // A card mounted while the owner types in the island: its field joins the key view loop once it is built.
            if id != nil { keyViewLoopChanged() }
            // The card built ahead for it now shows, in the same views.
            if ui.aheadCard != nil, ui.aheadCard?.sessionID == id || id == nil { ui.aheadCard = nil }
        case .islandLive, .pillLive, .cardLeaving, .list, .bud:
            break
        }
        syncShownRequest()
    }

    private func resolveScreen() -> IslandScreen? {
        IslandScreenResolver.resolve(NSScreen.screens.map(IslandScreen.init), preferredID: env.settings.islandDisplay)
    }

    /// A display came, went or changed (P38): no screen, and the panel just leaves; a screen back, and the island is
    /// built again from its idle geometry; another display or notch, and the canvas and root are placed again and
    /// everything snaps to the rest of the current state on the new geometry, with no animation.
    private func displayChanged() {
        guard shown, let panel else { return }
        guard let screen = resolveScreen() else {
            // No display: the island closes and the panel leaves; nothing polls or waits for a rest until one is back.
            self.screen = nil
            stopPolling()
            pointerInside = false
            unlightRim()
            feed(.dismissed)
            syncShownRequest()
            director?.recorder?.interrupt()
            panel.orderOut(nil)
            motionWatch?.refresh()
            return
        }
        guard screen != self.screen else { return }
        guard self.screen != nil, let director else {
            build(on: screen)
            // A close the missing display cut short never reached its reset.
            if resetPending { perform(.resetAfterFold) }
            self.director?.send(.show)
            pillChanged()
            return
        }
        placeCanvas(on: screen)
        var metrics = director.model.metrics
        metrics.targets = SurfaceTargets(notch: NotchGeometry.notchSize(on: screen), pill: pillContent(on: screen),
                                         hideWhenIdle: hidesIdlePill(on: screen), islandWidth: size.outer)
        metrics.reduceMotion = reduceMotion
        metrics.maxHeight = IslandPanelSizing.maxIslandHeight(screen)
        director.send(.display(metrics))
    }

    // MARK: The pill

    /// The closed pill follows the sessions and Settings: it arrives, departs or resizes (stored while open).
    private func pillChanged() {
        guard let screen, let director else { return }
        syncReduceMotion()
        director.send(.pill(pillContent(on: screen)))
    }

    /// Reduce Motion as the next transition reads it, in the model and the views; the views' copy is written only when it
    /// changed, so the minute clock's call at rest redraws nothing (P92).
    private func syncReduceMotion() {
        let on = reduceMotion
        director?.send(.reduceMotion(on))
        if ui.reduceMotion != on { ui.reduceMotion = on }
    }

    // MARK: Pointer

    /// A pointer sample from the tracking area (a move's own place on the screen and time, an entry or an exit the
    /// pointer now: `PointerSample(event:)`) or the poll: inside or outside the target shape (with the band while the
    /// landed island is open), its speed, and whether a poll is needed.
    private func pointer(_ kind: IslandContainerView.PointerEvent, _ sample: PointerSample) {
        // Folding away for Show as Window, the panel is still visible but no longer drives the machine.
        guard shown, let screen, panel?.isVisible == true else { return }
        let t = IslandMotionDirector.now
        let location = sample.location
        let inside = isInside(location, on: screen, at: t)
        // Speed in real points a second, timed by when each sample happened (E1): the model's clock runs slow under
        // `IslandMotion.slowdown`, and a busy main thread handles a burst of events at once.
        let speed = self.speed.add(location, at: sample.time)
        engagement.sample(location, inside: inside)
        if ownerEngaged { env.followUps?.looked() }
        if inside != pointerInside {
            pointerInside = inside
            feed(inside ? .pointerEntered(at: t) : .pointerExited(at: t))
        }
        if inside, kind == .moved { feed(.pointerMoved(speed: speed, at: t)) }
        updatePolling(location)
    }

    private func isInside(_ location: CGPoint, on screen: IslandScreen, at t: TimeInterval) -> Bool {
        let band = machine.landed(at: t) ? IslandHoverMachine.band : 0
        // Motion: Liquid's bud (L2): the card in its bud, and the gap above it, are the island's.
        return IslandHitRegion.contains(location, target: ui.budHit ?? ui.target.extent, centreX: NotchGeometry.centreX(on: screen),
                                        top: screen.frame.maxY, band: band)
    }

    /// The target moved under a still pointer, or the panel snapped: tell the machine which side the pointer is on
    /// now, never as an entry or an exit (a resize must not open or close the island). A pointer the island left is no
    /// longer over it: Glass's rim light goes too (P635).
    private func relocatePointer() {
        guard shown, let screen, panel?.isVisible == true else { return }
        let location = NSEvent.mouseLocation
        let inside = isInside(location, on: screen, at: IslandMotionDirector.now)
        guard inside != pointerInside else { return }
        pointerInside = inside
        if !inside { unlightRim() }
        engagement.relocated(to: location)
        feed(.pointerRelocated(inside: inside))
        updatePolling(location)
    }

    /// Polls the pointer 60 times a second only while the island waits for a rest (so a rest is measured even when
    /// moves do not arrive) or while the pointer strays in the band outside the landed island's panel; never at rest.
    private func updatePolling(_ location: CGPoint) {
        let waiting = machine.phase == .opening
        let inBand = machine.phase == .open && pointerInside && !(panel?.frame.contains(location) ?? true)
        guard waiting || inBand else { return stopPolling() }
        guard poll == nil else { return }
        poll = StrictTimer(after: Self.pollInterval, every: Self.pollInterval) { [weak self] in
            self?.pointer(.moved, PointerSample.now())
        }
    }

    static let pollInterval: TimeInterval = 1.0 / 60

    private func stopPolling() {
        poll?.cancel()
        poll = nil
    }

    // MARK: Hover machine

    private func feed(_ event: IslandHoverMachine.Event) {
        // After `hide()` only a dismissal reaches the machine: a click on the folding pill, a hover rest or a timer the
        // machine asked for earlier would open the island again in Window mode.
        guard shown || event == .dismissed else { return }
        machine.holdOpen = env.settings.keepOpenUntilDecision && showsWaitingCard
        // The owner typing on the card (a field's draft, the keys): a card that opened by itself does not fold (P292).
        machine.drafting = ui.cardDraft || panel?.isKeyWindow == true
        // A card the island answers keeps its Allow in sight: it never folds by itself (P292).
        machine.answerable = showsAnswerableCard
        let fromClosed = machine.phase == .closed
        for effect in machine.handle(event) {
            switch effect {
            case let .open(reason):
                // The owner opened it (a rest, a click, a key): what shows is looked at, and no reminder comes (P410).
                if reason != .attention { env.followUps?.looked() }
                if reason == .hover, env.settings.hapticOnHover {
                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                }
                frontAtOpen = NSWorkspace.shared.frontmostApplication?.processIdentifier
                // Opened by itself under a pointer that was already there: not the owner's until it moves (P271).
                engagement.opened(reason, fromClosed: fromClosed, at: NSEvent.mouseLocation)
                // A reverse keeps what was there (its reset has not run); a fresh open shows the list.
                if reason != .attention, !resetPending { ui.presentation = .list }
                // The accounts in use, taken while nothing of the island shows (P812).
                ui.opens(reverse: resetPending, env: env)
                resetPending = false
                if ui.glance {
                    ui.glance = false
                    pillChanged()
                }
                syncReduceMotion()
                director?.send(.open(reason, ui.presentation))
            case let .close(style):
                giveUpKey()
                // What waits, as the island last heard it, stays on the pill: none of it opens the island again by
                // itself; a request no batch has brought yet is not put away (P272).
                putAway.folded()
                resetPending = true
                syncReduceMotion()
                director?.send(.close(style))
            case .retreat:
                director?.send(.retreat)
            case .resume:
                director?.send(.resume)
            case let .swell(on):
                director?.send(.swell(on))
            case let .schedule(delay, generation):
                hoverTimer?.cancel()
                hoverTimer = StrictTimer(after: delay * IslandMotion.slowdown) { [weak self] in
                    self?.hoverTimer = nil
                    self?.feed(.timerFired(generation: generation, at: IslandMotionDirector.now))
                }
            }
        }
        if machine.phase != .opening, machine.phase != .open { stopPolling() }
        syncShownRequest()
    }

    /// Tells the sessions which request's card the owner sees on the island now, when that changes (P350): a subagent's
    /// request held for the island is held only while it shows, so a fold (once it starts: the leave grace, which the
    /// pointer may take back, still shows it), another app (the pointer resting on the island too, P353), Esc, the list,
    /// another card or Window mode ends its hold at once.
    private func syncShownRequest() {
        let open = IslandAttention.ownerSees(machine, visible: shown && screen != nil && panel?.isVisible == true)
        let id = IslandAttention.requestOnScreen(open: open, presentation: ui.presentation, drawn: shownCard)
        guard id != reportedShown else { return }
        reportedShown = id
        env.sessions.islandShows(requestID: id)
    }

    /// The owner is at the open island: the pointer on it, having moved there, or the island has the keys. What arrives
    /// now is seen, and gets no reminder (P410).
    var ownerEngaged: Bool {
        guard shown, machine.isOpen else { return false }
        return (pointerInside && engagement.engaged) || panel?.isKeyWindow == true
    }

    /// The card layer's card while it is the one presented: what the owner sees, and what card keys act on.
    private var shownCard: SessionCard? {
        guard case let .card(id) = ui.presentation, ui.card?.sessionID == id else { return nil }
        return ui.card
    }

    private var showsWaitingCard: Bool {
        guard case let .card(id) = ui.presentation else { return false }
        return env.sessions.row(id: id)?.bucket == .needsYou
    }

    /// A card whose buttons answer here shows: an approval, a plan or a question the island holds (not a read-only one,
    /// answered in the agent's own prompt).
    private var showsAnswerableCard: Bool {
        guard case let .card(id) = ui.presentation else { return false }
        return env.card(for: id)?.request?.answerable == true
    }

    /// An approval, a plan or a question shows: its agent waits on the owner's answer (a failed turn's card does not).
    private var showsCardThatWaits: Bool {
        guard case let .card(id) = ui.presentation else { return false }
        return env.sessions.row(id: id)?.hasCard == true
    }

    /// The open island shows the card the owner is at, which a finish never replaces: one that waits for them, or a Done
    /// card whose field holds text or that has the keys, the owner having clicked into it (P96).
    private var cardInUse: Bool {
        guard machine.isOpen, case .card = ui.presentation else { return false }
        return showsWaitingCard || ui.cardDraft || panel?.isKeyWindow == true
    }

    /// List ⇄ card: the choreography glides the row and swaps the layers (stored while closed). Whatever it shows now is
    /// no longer the Done card that closes by itself (a finish marks its own card again once presented).
    private func present(_ presentation: IslandPresentation) {
        machine.endBrief()
        if presentation != .list { peeker.reset() }
        ui.presentation = presentation
        director?.send(.present(presentation))
        if case let .card(id) = presentation { cardArrives(id) }
        syncShownRequest()
    }

    /// A card comes in: for `IslandMotion.cardSettle` it takes no click and no card key, so the second click of a
    /// double-click on Yes, or a key meant for the card it replaced, never answers it (P138); once the island rests on
    /// it, the next card that waits is built beside it (P133).
    private func cardArrives(_ id: String) {
        arrival?.cancel()
        restingCard = nil
        ui.arrivingCard = id
        arrival = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(IslandMotion.cardSettle * IslandMotion.slowdown))
            guard !Task.isCancelled, let self else { return }
            if self.ui.arrivingCard == id { self.ui.arrivingCard = nil }
            try? await Task.sleep(for: .seconds((IslandMotion.cardRest - IslandMotion.cardSettle) * IslandMotion.slowdown))
            guard !Task.isCancelled, self.ui.presentation == .card(sessionID: id) else { return }
            self.restingCard = id
            self.mountNextWaiting()
        }
    }

    /// While the open island rests on a card that waits, the next that waits is built beside it (`mountAhead`), so the
    /// swap an answer brings builds nothing in its frame (P130, P133). A card built ahead whose session no longer has
    /// one goes.
    private func mountNextWaiting() {
        guard machine.phase == .open, case let .card(shown) = ui.presentation, restingCard == shown else { return }
        if let next = IslandAttention.buildAhead(shown: shown, waits: showsCardThatWaits, waiting: env.sessions.waiting) {
            mountAhead(next)
        } else if let ahead = ui.aheadCard, env.card(for: ahead.sessionID) == nil {
            ui.aheadCard = nil
        }
    }

    /// Before a jump or at a close, the panel stops being key so keys go back to the terminal (P39). It is ordered
    /// back in where it is, never re-placed, so nothing moves.
    private func giveUpKey() {
        guard let panel, panel.isKeyWindow else { return }
        panel.makeFirstResponder(nil)
        // `resignKey()` only notifies (AppKit: never call it); ordering the panel out is what hands key focus back to
        // the terminal's window. The panel comes straight back, ordered front without key.
        panel.orderOut(nil)
        if director?.model.ordered == true { panel.orderFrontRegardless() }
        if NSApp.isActive { NSApp.deactivate() }
    }

    // MARK: Focus

    /// Hears where the owner goes while the island shows (P270). Each change is handled a turn later: a notice the
    /// panel posts as it gives up its keys for a close or a jump then finds the island already closed.
    private func watchFocus() {
        focusWatch?.stop()
        guard let panel else { return }
        focusWatch = IslandFocusWatch(window: panel) { [weak self] change in
            Task { @MainActor [weak self] in self?.focusChanged(change) }
        }
    }

    /// Another app became active, or a click outside took the panel's keys: the open island folds back into the pill
    /// with the normal fold, unless the pointer is on it, having moved there (P270, P271). What waits stays on the pill.
    private func focusChanged(_ change: IslandFocusChange) {
        guard shown, machine.phase != .closed, IslandFocus.ownerLeft(change, frontAtOpen: frontAtOpen) else { return }
        resyncPointer()
        feed(.focusLeft(pointerHolds: pointerInside && engagement.engaged, at: IslandMotionDirector.now))
    }

    /// Reads the pointer now, as an entry or an exit, never a move: an exit a modal menu's tracking held back, or a move
    /// outside the panel that no event reported, reaches the machine.
    private func resyncPointer() {
        pointer(.entered, PointerSample.now())
    }

    /// The request keys of the rows that need you (`IslandAttention.requestKey`).
    private func pendingKeys(_ rows: [SessionRow]) -> [String: String] {
        IslandAttention.pendingKeys(rows) { env.card(for: $0) }
    }

    // MARK: Sessions

    private func observeSessions() {
        let generation = generation
        withObservationTracking {
            _ = env.sessions.rows
            // The minute clock too: a finished session leaves the Active count with no event of its own (P92).
            _ = env.sessions.now
            _ = env.sessions.finishSource
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.shown, self.generation == generation else { return }
                self.sessionsChanged()
                self.observeSessions()
            }
        }
    }

    private func sessionsChanged() {
        let rows = env.sessions.rows
        let previous = lastRows
        // The card the owner sees, before this batch redraws it.
        let drawn = shownCard
        let source = env.sessions.finishSource
        let pending = pendingKeys(rows)
        // A request the island folded away from never opens it again by itself; a new one does (P272). A session a mute
        // rule matches opens nothing at all (P421).
        let heard = MuteRules.unmuted(putAway.hear(IslandAttention.signals(old: previous, new: rows, source: source, seen: lastFinish),
                                                   rows: rows, pending: pending),
                                      rows: rows, rules: env.settings.muteRules)
        // Quiet (full screen, Quiet hours, a lock): nothing opens the island by itself, and what waits stays on the pill
        // (P331); what came during a lock is shown once the owner is back (P423).
        let away = lockQuiets
        let quiet = away || holdsAttention
        let batch = QuietMode.quieted(heard, finish: env.settings.whenSessionFinishes, quiet: quiet)
        if batch.putsAway { putAway.folded() }
        if away {
            for case let .needsYou(id) in heard { awayArrivals[id] = pending[id] }
        }
        // Questions open the island off: a question stays on the pill ("?") and never opens the island by itself (P411).
        let held = QuestionsOpen.held(batch.signals, rows: rows, opens: env.settings.questionsOpenIsland)
        if !held.sessions.isEmpty { putAway.putAway(held.sessions) }
        let signals = held.signals
        // A draft goes with its card (P273).
        if !ui.drafts.isEmpty { ui.drafts.prune(keeping: rows.compactMap { env.card(for: $0.id) }) }
        peeker.rowsChanged(rows)
        lastRows = rows
        if case let .engine(last) = source { lastFinish = last }
        let response = IslandAttention.respond(to: signals, rows: rows,
                                               finish: batch.finish,
                                               cardInUse: cardInUse, waitingCardShows: machine.isOpen && showsCardThatWaits)
        // A banner only for what the island does not show itself (P412).
        env.banners?.islandHeard(signals, opened: response.card, islandOpen: machine.isOpen,
                                 visible: screen != nil && panel != nil, quiet: quiet)
        if let id = response.glance {
            if !ui.isOpen { ui.glance = true }
            if let row = rows.first(where: { $0.id == id }) { flashFinished(row.agent) }
        }
        if let id = response.card { openByItself(id, brief: response.brief) }
        let validated = IslandAttention.validated(ui.presentation) { env.card(for: $0) != nil }
        if validated != ui.presentation, case let .card(gone) = ui.presentation {
            // Answered: the next card that waits, oldest first, while the island is open; the list (or a close, the
            // pointer away) once none remain (P130).
            let wasWaiting = previous.first { $0.id == gone }?.hasCard == true
            if machine.isOpen, let next = IslandAttention.next(after: gone, wasWaiting: wasWaiting, waiting: env.sessions.waiting) {
                present(.card(sessionID: next))
                feed(.attention(at: IslandMotionDirector.now))
            } else {
                present(validated)
                if machine.closesWithItsCard { feed(.dismissed) }
            }
        } else if machine.isOpen, response.card == nil, case let .card(id) = ui.presentation {
            // The request the card showed went and the same session's next one (or its finished turn) took its place, or
            // a Done card became a request: never drawn in place as if it were the card the owner was at (P172).
            let current = env.card(for: id)
            switch IslandAttention.shownCardChanged(drawn: drawn, current: current, waiting: env.sessions.waiting) {
            case let .next(next):
                present(.card(sessionID: next))
                feed(.attention(at: IslandMotionDirector.now))
            case .arrives:
                cardArrives(id)
                if current?.request != nil { feed(.attention(at: IslandMotionDirector.now)) }
            case .settles:
                // A subagent's hold ran out (P350): Open and ✕ take no click yet, and an island kept only for its Yes
                // folds, left alone past its time.
                cardArrives(id)
                feed(.answerEnded(at: IslandMotionDirector.now))
            case .none:
                break
            }
        }
        // The card layer's card stays live while it shows; a field it gains while the panel is key joins the loop.
        if case let .card(id) = ui.presentation, let card = env.card(for: id), card != ui.card {
            ui.card = card
            keyViewLoopChanged()
        }
        if response.card == nil, let pending = pendingNotice { showNotice(pending) }
        mountNextWaiting()
        pillChanged()
        syncShownRequest()
    }

    // MARK: Width, text size and the update dot

    /// Settings › Island › Width and Text size (P401, P402): observed on their own, so a change never folds the strip or
    /// sends the pill again by itself.
    private func observeSize() {
        let generation = generation
        withObservationTracking {
            _ = env.settings.islandWidth
            _ = env.settings.islandTextSize
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.shown, self.generation == generation else { return }
                self.sizeChanged()
                self.observeSize()
            }
        }
    }

    /// A new width or text size builds the canvas and the root again for it, and everything snaps to the rest of the
    /// current state on the new geometry, as a new display does (never animated: it comes from a click in Settings).
    private func sizeChanged() {
        guard let screen, let director, IslandSize(env.settings) != size else { return }
        placeCanvas(on: screen)
        var metrics = director.model.metrics
        metrics.targets.islandWidth = size.outer
        metrics.reduceMotion = reduceMotion
        director.send(.display(metrics))
    }

    /// Whether an update waits (P403): the pill's dot follows the checker's and the updater's own state; nothing new
    /// polls for it. A snooze's moon follows its setting the same way, set and cleared (`SnoozeEnd`, P726).
    private func observeUpdate() {
        let generation = generation
        withObservationTracking {
            _ = updateWaits
            _ = env.settings.pillUpdateDot
            _ = env.settings.snoozedUntil
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.shown, self.generation == generation else { return }
                self.pillChanged()
                self.observeUpdate()
            }
        }
    }

    // MARK: Opening by itself

    /// The island opens on `id`'s card by itself: a card that needs you, or, `brief`, a finish's Done card or a stall's
    /// notice. The card is built now and shown a turn later, so the frame that starts the motion does not also build it
    /// (15 to 25 ms), and the choreography finds it measured and moves straight to its height (P133), mid-fold too, where
    /// the reversing open would otherwise head for the list's height and turn again once it is built.
    private func openByItself(_ id: String, brief: Bool) {
        if !machine.isOpen { ui.presentation = .card(sessionID: id) }
        mountAhead(id, presenting: true)
        Task { @MainActor [weak self] in
            guard let self, self.shown, self.env.card(for: id) != nil else { return }
            if self.machine.isOpen { self.present(.card(sessionID: id)) } else {
                self.ui.presentation = .card(sessionID: id)
                self.cardArrives(id)
            }
            // A finish's Done card closes by itself (P95); a card that needs you never does. Neither makes the panel key:
            // keys stay with the terminal until the owner clicks the island.
            self.feed(brief ? .finished(at: IslandMotionDirector.now) : .attention(at: IslandMotionDirector.now))
        }
    }

    // MARK: Screen lock (P422, P423)

    /// The owner's returns after a lock or a switch-out (`ScreenLockWatch.returns`).
    private func observeScreenLock() {
        guard let lock = env.screenLock else { return }
        let generation = generation
        withObservationTracking {
            _ = lock.returns
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.shown, self.generation == generation else { return }
                self.ownerReturned()
                self.observeScreenLock()
            }
        }
    }

    /// Back after a lock: once the lock screen has gone, the island opens on the card that has waited longest of those
    /// that came meanwhile (`LockCatchUp`), unless the island is quiet for another reason now (Quiet hours, full screen:
    /// they stay on the pill, P331) or the owner is at a card that waits (it waits its turn behind it, P130). Nothing
    /// sounds; a finish that came meanwhile lit Glance's dot already.
    private func ownerReturned() {
        let arrivals = awayArrivals
        awayArrivals = [:]
        catchUp?.cancel()
        guard !arrivals.isEmpty else { return }
        let generation = generation
        catchUp = Task { @MainActor [weak self] in
            try? await Task.sleep(for: LockCatchUp.delay)
            guard !Task.isCancelled, let self, self.shown, self.generation == generation else { return }
            self.catchUp = nil
            guard !self.lockQuiets, !self.holdsAttention, !(self.machine.isOpen && self.showsWaitingCard), !self.cardInUse else { return }
            let rows = self.env.sessions.rows
            let waiting = LockCatchUp.candidates(self.env.sessions.waiting, rules: self.env.settings.muteRules,
                                                 questionsOpen: self.env.settings.questionsOpenIsland)
            guard let id = LockCatchUp.card(arrivals: arrivals, waiting: waiting, pending: self.pendingKeys(rows)) else { return }
            self.openByItself(id, brief: false)
        }
    }

    // MARK: Reminders

    /// Remind again (P410): each reminder pulses the pill's lead once (`ClosedPillView.nudge`).
    private func observeNudges() {
        guard let followUps = env.followUps else { return }
        let generation = generation
        ui.pillNudge = followUps.pulse
        withObservationTracking {
            _ = followUps.pulse
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.shown, self.generation == generation else { return }
                self.observeNudges()
            }
        }
    }

    // MARK: Quota notices

    /// The usage model's newest quota notice (P125), and the usage model itself when the usage source changes.
    private func observeNotices() {
        let generation = generation
        withObservationTracking {
            _ = env.usage.quotaNotice
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.shown, self.generation == generation else { return }
                self.noticeChanged()
                self.observeNotices()
            }
        }
    }

    private func noticeChanged() {
        guard let notice = env.usage.quotaNotice, notice.id != lastNotice else { return }
        lastNotice = notice.id
        guard env.settings.quotaAlerts else { return }
        showNotice(notice)
    }

    /// A notice shows as a finish's Done card does: brief, closing by itself, held by the pointer. It never takes the
    /// place of a card the owner is at (one that waits for them, a field holding text, the keys): it waits for that card
    /// to go, and is dropped when it is old by then or Quota alerts was turned off.
    private func showNotice(_ notice: QuotaNotice) {
        pendingNotice = nil
        // Quiet: dropped, as an old one is; the usage it is about still shows (P331).
        guard !holdsAttention, !lockQuiets else { return }
        switch QuotaNoticeGate.decide(notice, alertsOn: env.settings.quotaAlerts, ownerAtCard: cardInUse || (machine.isOpen && showsWaitingCard),
                                      now: Date()) {
        case .drop: return
        case .wait:
            pendingNotice = notice
            return
        case .show: break
        }
        env.islandNotice = notice
        // Built ahead and shown a turn later, as a session's card is (P133).
        let id = QuotaNoticeCard(notice: notice).sessionID
        if !machine.isOpen { ui.presentation = .card(sessionID: id) }
        mountAhead(id, presenting: true)
        Task { @MainActor [weak self] in
            guard let self, self.shown, self.env.card(for: id) != nil else { return }
            if self.machine.isOpen { self.present(.card(sessionID: id)) } else {
                self.ui.presentation = .card(sessionID: id)
                self.cardArrives(id)
            }
            self.feed(.finished(at: IslandMotionDirector.now))
        }
    }

    /// Builds `id`'s card before the island shows it: in the card layer when no card is mounted (out of focus until the
    /// choreography brings it in, and measured by then), else beside the card that shows, out of sight, to take its
    /// place in the same views (P133). A card built for later (the next that waits, the hovered row's) waits while the
    /// island moves (E4: the build is a 10 to 29 ms turn) and is built once it rests (`islandRested`); one the next
    /// turn is `presenting` is built at once, in a turn of its own: its present follows anyway, and must find it built.
    private func mountAhead(_ id: String, presenting: Bool = false) {
        guard let card = env.card(for: id) else { return }
        if let director, !Self.buildsAhead(director.model, presenting: presenting) {
            aheadWaits = true
            return
        }
        let mounted = director?.model.cardMounted
        if mounted == nil {
            guard ui.card != card else { return }
            ui.card = card
        } else {
            guard mounted != id, ui.aheadCard != card else { return }
            ui.aheadCard = card
        }
        // Built and laid out now, in an update of its own, never in the one that starts the motion.
        hosting?.layoutSubtreeIfNeeded()
    }

    /// The fields the owner can Tab between changed (a card mounted, or changed in place): while the panel is key, the
    /// loop is worked out again once they are built (`IslandPanel.configureKeyViewLoop`).
    private func keyViewLoopChanged() {
        guard let panel, panel.isKeyWindow else { return }
        DispatchQueue.main.async { [weak panel] in panel?.recalculateKeyViewLoop() }
    }

    /// Whether a card may be built ahead now: one the next turn presents, always; one built for later, only while the
    /// island is not in motion (E4).
    static func buildsAhead(_ model: IslandChoreography, presenting: Bool = false) -> Bool { presenting || !model.inMotion }

    /// The island came to rest: a card that waited to be built ahead is built now, if it is still wanted.
    private func islandRested() {
        if outlineWaits { syncOutline() }
        guard aheadWaits, shown else { return }
        aheadWaits = false
        mountNextWaiting()
        if let row = hoveredRow, ui.isOpen, ui.presentation == .list { mountAhead(row.id) }
    }

    /// The pointer rests on a row that has a card: the card is built ahead, so the click that opens it only moves.
    private func rowHovered(_ row: SessionRow, inside: Bool) {
        peeker.hovered(row, inside: inside)
        if inside, row.hasCard { hoveredRow = row } else if hoveredRow?.id == row.id { hoveredRow = nil }
        hoverMount?.cancel()
        hoverMount = nil
        guard inside, row.hasCard else { return }
        hoverMount = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled, let self, self.ui.isOpen, self.ui.presentation == .list else { return }
            self.mountAhead(row.id)
        }
    }

    private func flashFinished(_ agent: GlyphPalette.Agent) {
        finishedTask?.cancel()
        ui.recentlyFinished = agent
        finishedTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, let self else { return }
            self.ui.recentlyFinished = nil
            self.pillChanged()
        }
    }

    private func observeSettings() {
        let generation = generation
        withObservationTracking {
            _ = env.settings.islandUsagePlacement
            _ = env.settings.islandDisplay
            _ = env.settings.hidePillWhenIdle
            _ = env.settings.glyphStyle
            _ = env.settings.glyphEdgeLine
            _ = env.settings.closedPillCount
            _ = env.settings.hideInFullScreen
            _ = env.settings.fullScreenShowsNeedsYou
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.shown, self.generation == generation else { return }
                self.settingsChanged()
                self.observeSettings()
            }
        }
    }

    /// Settings › Island › Motion and Hover, and Diagnostics › Motion: observed on their own, so a switch there never
    /// folds the strip or sends the pill again.
    private func observeMotionSettings() {
        let generation = generation
        withObservationTracking {
            _ = env.settings.islandMotion
            _ = env.settings.islandHover
            _ = env.settings.recordIslandMotion
            _ = env.settings.paceIslandMotion
            _ = env.settings.islandOutline
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.shown, self.generation == generation else { return }
                self.syncTuning()
                self.syncOutline()
                self.syncRecorder()
                self.observeMotionSettings()
            }
        }
    }

    /// Settings › Island › Theme: Core Animation's outline draws Glass in the canvas (`IslandCanvas.setTheme`); the views
    /// read the theme themselves (`juiceThemeFromSettings`). Observed on its own, so a new theme folds nothing. State
    /// tint and Needs you colour too: Black's edge on that outline is the canvas's.
    private func observeTheme() {
        let generation = generation
        withObservationTracking {
            _ = env.settings.juiceTheme
            _ = env.settings.islandStateTint
            _ = env.settings.needsYouColour
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.shown, self.generation == generation else { return }
                self.canvas?.setTheme(self.env.settings.juiceTheme)
                self.canvas?.setStateTint(self.env.settings.islandStateTint)
                self.canvas?.setNeedsYou(self.env.settings.needsYouColour)
                if self.env.settings.juiceTheme != .glass { self.unlightRim() }
                self.observeTheme()
            }
        }
    }

    /// Glass's rim catches the light where the pointer is (`RimLight`): from the tracking area's own events only (never
    /// the poll, never a monitor), while the pointer is over the island; it goes when the pointer leaves. Nothing is
    /// written in any other theme.
    private func lightRim(_ kind: IslandContainerView.PointerEvent, _ sample: PointerSample) {
        guard env.settings.juiceTheme == .glass, shown, kind != .exited, pointerInside, canvasRect.width > 0 else { return unlightRim() }
        let point = CGPoint(x: sample.location.x - canvasRect.minX, y: canvasRect.maxY - sample.location.y)
        let place = RimLight.place(pointer: point, extent: ui.budHit ?? ui.target.extent, midX: canvasRect.width / 2)
        let spot = IslandRimLight.Spot(centre: place.centre, radius: place.radius)
        ui.rimLight.set(spot)
        canvas?.setRimLight(spot)
    }

    private func unlightRim() {
        guard ui.rimLight.spot != nil || canvas?.glassView?.isLit == true else { return }
        ui.rimLight.set(nil)
        canvas?.setRimLight(nil)
    }

    /// Diagnostics › Motion › Outline into the canvas, the director and the model, at rest (a switch asked for mid-motion
    /// waits for the island to rest, `islandRested`): Core Animation's outline plays the model's plan from here on.
    private func syncOutline() {
        guard let canvas, let director else { return }
        let wanted = env.settings.islandOutline
        guard canvas.outline != wanted || director.model.metrics.outline != canvas.outline else {
            outlineWaits = false
            return
        }
        guard !director.model.inMotion else {
            outlineWaits = true
            return
        }
        outlineWaits = false
        canvas.setOutline(wanted)
        director.surface = canvas.outline == .coreAnimation ? canvas.layers : nil
        director.send(.outline(canvas.outline))
    }

    /// Core Animation's layers could not be put back (`IslandCanvas.ensure`): SwiftUI's outline from now on, until the
    /// next build (a show, a display back) or a change in Settings › Island or Diagnostics › Motion tries Core Animation's
    /// again (`syncOutline`); its layers still out of place, it falls back again in the same turn, before any commit.
    private func outlineFellBack() {
        director?.surface = nil
        director?.send(.outline(.swiftUI))
    }

    /// Motion and Hover as the next transition plays them.
    private var tuning: MotionTuning { MotionTuning(motion: env.settings.islandMotion, hover: env.settings.islandHover) }

    /// Motion and Hover into the hover machine, the model and the views (written only when it changed).
    private func syncTuning() {
        let tuning = tuning
        machine.tuning = tuning
        if ui.tuning != tuning { ui.tuning = tuning }
        guard let director, director.model.tuning != tuning else { return }
        director.send(.tuning(tuning))
    }

    /// Diagnostics › Motion: either switch gives the director a recorder whose display link runs only while the island
    /// moves, at 80 to 120 Hz when it asks for 120 Hz and at 30 when it only records (never asking the display for more
    /// than the island's own frames do); with neither there is none. Last motions starts over when the 120 Hz vote,
    /// Motion or Hover changes (`MotionLog.recordUnder`).
    private func syncRecorder() {
        guard let director, let container else { return }
        env.motionLog.recordUnder(MotionLog.Setup(pace: env.settings.paceIslandMotion, tuning: tuning,
                                                  outline: env.settings.islandOutline))
        let mode = MotionRecorder.Mode(record: env.settings.recordIslandMotion, pace: env.settings.paceIslandMotion)
        guard director.recorder?.mode != mode else { return }
        director.recorder?.interrupt()
        director.recorder = mode.map { mode in
            MotionRecorder(clock: DisplayLinkClock(view: container, range: mode.range), mode: mode,
                           model: { [weak director] in director?.model },
                           write: { [weak self] report in
                               // Which outline drew it: Core Animation's frames are the render server's, which a report
                               // made on the main thread cannot see (judge those on the display).
                               var report = report
                               report.outline = self?.canvas?.outline ?? .swiftUI
                               self?.motionFolder.write(report)
                               self?.env.motionLog.add(report)
                           })
        }
    }

    private func settingsChanged() {
        ui.stripOpen = false
        syncFullScreenWatch()
        restAgain()
    }

    /// The pill, and whether its idle rest hides, as Settings and full screen have them now.
    private func restAgain() {
        guard let screen = resolveScreen(), screen == self.screen, let director else { return displayChanged() }
        guard hidesIdlePill(on: screen) == director.model.targets.hideWhenIdle else {
            // The idle pill hides now, or shows again: snap to the new rest, ordered out or in.
            var metrics = director.model.metrics
            metrics.targets.hideWhenIdle = hidesIdlePill(on: screen)
            metrics.targets.pill = pillContent(on: screen)
            director.send(.display(metrics))
            return
        }
        pillChanged()
    }

    // MARK: Quiet

    /// Nothing opens the island by itself now: full screen with Hide in full screen on, or Quiet hours on the wall clock
    /// (`QuietMode`, P331). Read as each batch or notice comes, never on a timer.
    private var holdsAttention: Bool { QuietMode.holdsAttention(env.settings, fullScreen: fullScreen, now: Date()) }

    /// Quiet while locked holds the island now: the screen is locked or the owner's session switched out (P422).
    private var lockQuiets: Bool { QuietMode.lockQuiets(env.settings, away: env.screenLock?.isAway == true) }

    /// A watch on full screen while the island shows and Hide in full screen is on; none otherwise, so nothing reads the
    /// window list while the switch is off (P330).
    private func syncFullScreenWatch() {
        guard shown, env.settings.hideInFullScreen else {
            fullScreenWatch?.stop()
            fullScreenWatch = nil
            fullScreen = false
            return
        }
        if fullScreenWatch == nil {
            fullScreenWatch = FullScreenWatch(probe: { [weak self] in self?.probeFullScreen() ?? false }) { [weak self] on in
                self?.fullScreenChanged(on)
            }
        }
        fullScreen = fullScreenWatch?.isFullScreen ?? false
    }

    /// The frontmost app in full screen on the island's display, from the windows on screen now.
    private func probeFullScreen() -> Bool {
        guard let screen = resolveScreen() else { return false }
        return FullScreenProbe.isFullScreen(frontmost: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                                            windows: FullScreenProbe.onScreenWindows(), screen: screen,
                                            primaryHeight: NSScreen.screens.first?.frame.height ?? screen.frame.maxY)
    }

    /// Full screen began or ended: the pill tucks behind the notch or comes back out; without a notch the bar snaps away
    /// or back, as a switch in Settings does (the Space's own slide covers it).
    private func fullScreenChanged(_ on: Bool) {
        guard shown, fullScreen != on else { return }
        fullScreen = on
        restAgain()
    }

    // MARK: Actions

    private func viewActions() -> IslandViewActions {
        IslandViewActions(
            openRow: { [weak self] row in self?.open(row) },
            hoverRow: { [weak self] row, inside in self?.rowHovered(row, inside: inside) },
            showAll: { [weak self] in self?.showAllRows() },
            toggleStrip: { [weak self] in
                guard let self, let director = self.director else { return }
                director.send(.list(.strip(!(director.model.stripAfterSwap ?? self.ui.stripOpen))))
            },
            gear: { [weak self] in self?.showGearMenu() },
            showAsWindow: { [weak self] in self?.env.actions.setShowAs(.window) },
            toggleSound: { [weak self] in self?.env.settings.soundsMuted.toggle() })
    }

    private func open(_ row: SessionRow) {
        if row.hasCard {
            present(.card(sessionID: row.id))
        } else {
            jump(row.id)
        }
    }

    private func jump(_ sessionID: String) {
        giveUpKey()
        feed(.dismissed)
        env.sessions.jump(sessionID)
    }

    /// A widget's tap (`WidgetLink`, spec §4.7): what a click on that row does in the open island (`open`). Its card
    /// comes in as a request that arrives does (built first, shown a turn later, P133), any other row jumps, and the
    /// widget's other taps, or a row whose session has gone since, open the list. The tap made Juice Island the app in
    /// front, so its own activation, which may come just after the open, never folds the island; another app's does
    /// (P270, P343).
    func openFromWidget(_ link: WidgetLink) {
        guard shown else { return }
        var row: SessionRow?
        if case let .session(id) = link { row = env.sessions.row(id: id) }
        if let row, !row.hasCard {
            jump(row.id)
            return
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        // The owner asked for it: never an idle fold, as for a card that opened by itself (P292).
        guard let id = row?.id, env.card(for: id) != nil else {
            if machine.isOpen { present(.list) } else { feed(.clicked(at: IslandMotionDirector.now)) }
            machine.ownerAsked()
            frontAtOpen = ownPID
            return
        }
        // A second tap on the card the open island shows changes nothing (a new arrival would take its clicks away).
        if machine.isOpen, ui.presentation == .card(sessionID: id) {
            machine.ownerAsked()
            frontAtOpen = ownPID
            return
        }
        if !machine.isOpen { ui.presentation = .card(sessionID: id) }
        mountAhead(id, presenting: true)
        Task { @MainActor [weak self] in
            guard let self, self.shown, self.env.card(for: id) != nil else { return }
            if self.machine.isOpen { self.present(.card(sessionID: id)) } else {
                self.ui.presentation = .card(sessionID: id)
                self.cardArrives(id)
            }
            self.feed(.attention(at: IslandMotionDirector.now))
            self.machine.ownerAsked()
            self.frontAtOpen = ownPID
        }
    }

    /// The gear's menu (`GearMenu`). The header keeps only the gear; mute and quit live here.
    private func showGearMenu() {
        GearMenu.popUp(env: env, showing: .island, actions: menuActions)
        // The menu is modal: where the pointer went meanwhile is read now, so a leave it held back still closes (P270).
        resyncPointer()
    }

    // MARK: Keys

    private func handleKey(_ key: IslandKeyPress) -> Bool {
        // The one card a card key acts on, what the owner sees (P351), and its exact request (P170, P172).
        let card = IslandKeyRouter.targetCard(presentation: ui.presentation, sessions: env.sessions, showAll: ui.showAll,
                                              drawn: shownCard, selected: ui.selectedRow)
        guard let command = IslandKeyRouter.command(for: key, card: card, arriving: ui.arrivingCard,
                                                    listing: ui.presentation == .list) else { return false }
        switch command {
        case .close:
            feed(.dismissed)
        case .jumpToNextNeedsYou:
            giveUpKey()
            feed(.dismissed)
            env.sessions.jumpToNextNeedsYou()
        case let .approve(id, decision):
            // The card goes once the decision went (the next that waits takes its place, `sessionsChanged`); one that
            // could not be sent stays, with Retry (P129, P130). It goes to the request the card shows (P170).
            env.sessions.approve(id, decision, request: card?.request?.id)
        case let .chooseOption(id, index):
            // A pick that answers the last question sends them all, and the card goes once they went; one on an earlier
            // question, or on a multi-select one, keeps the card for the next step.
            env.sessions.answerQuestion(id, .option(index), request: card?.request?.id)
        case .showAsWindow:
            env.actions.setShowAs(.window)
        case .openSettings:
            // The gear's Settings item's key.
            GearMenu.perform(.settings(.island), env: env)
        case let .moveSelection(step):
            moveSelection(step)
        case .openSelection:
            openSelection()
        case .cycleUsage:
            cycleUsage()
        case .swallow:
            break
        }
        return true
    }

    /// ↑ or ↓ over the list (P321): the keys' row moves through the rows the list shows, and stops at either end; ↓ from
    /// the last row, with rows behind the footer, shows them all first, as the footer does. A row with a card has it built
    /// ahead, as the pointer resting on it does (P133), so Return only moves.
    private func moveSelection(_ step: Int) {
        guard ui.presentation == .list else { return }
        select(RowSelection.islandMove(ui.selectedRow, sessions: env.sessions, style: env.settings.islandStyle,
                                       showAll: ui.showAll, by: step))
    }

    private func select(_ move: (row: SessionRow?, showsAll: Bool)) {
        if move.showsAll { showAllRows() }
        guard let row = move.row, row.id != ui.selectedRow else { return }
        ui.selectedRow = row.id
        if row.hasCard { rowHovered(row, inside: true) }
    }

    /// Return over the list: the keys' row opens its card, or jumps, as a click on it does (P321). Opened by the
    /// system-wide key set to Switch sessions, it jumps whatever the row is (P462).
    private func openSelection() {
        guard ui.presentation == .list, let id = ui.selectedRow,
              let row = RowSelection.islandOrder(env.sessions, style: env.settings.islandStyle, showAll: ui.showAll)
                  .shown.first(where: { $0.id == id }) else { return }
        if RowSelection.onReturn(row, switching: ui.switching) == .jump { jump(row.id) } else { open(row) }
    }

    /// U over the list (P461): the next battery in the usage block, as the pointer resting on it would show it (its
    /// ring, and its label across the header, Hover details or not), Claude's batteries then Codex's; after the last,
    /// none again. In Header strip placement the block unfolds for it and folds back after the last. Nothing is read.
    private func cycleUsage() {
        guard ui.presentation == .list, env.settings.islandShowsUsage, let director else { return }
        let ids = UsageCycle.order(env.usage, inUse: ui.inUse, first: env.settings.usageFirst)
        guard !ids.isEmpty else { return }
        let next = UsageCycle.next(after: ui.hover, in: ids)
        if env.settings.islandUsagePlacement == .headerStrip, (next != nil) != (director.model.stripAfterSwap ?? ui.stripOpen) {
            director.send(.list(.strip(next != nil)))
        }
        ui.keyHover(next.map(HoverTargetID.account))
    }

    /// The footer's Show all (and ↓ past the last row, P321): back to the list from a card, and every row, through the
    /// choreography (E6): what leaves fades first, and the change moves the rows on the edge's curve.
    private func showAllRows() {
        if ui.presentation != .list { present(.list) }
        director?.send(.list(.showAll))
    }

    /// The system-wide key set to Open (P323): the island opens at once, as a click on the pill opens it, with its first
    /// row selected, and takes the keys. The panel is nonactivating, so the app in front stays active (P270's watch hears
    /// no activation) and the keys come back to it with Esc, a jump or a click outside. Pressed again while the island
    /// has the keys, it closes.
    func openWithKeys() {
        guard shown, let panel, screen != nil else { return }
        if machine.isOpen, panel.isKeyWindow {
            feed(.dismissed)
            return
        }
        takeKeys(panel)
    }

    /// The system-wide key set to Switch sessions (P462): the first press opens the island with the keys, as Open does,
    /// its ring on the first row; each press after it, while the island has the keys, moves the ring to the next row
    /// (↓'s move, the rows behind the footer shown first), and after the last row back to the first. Return then jumps
    /// to the ring's session, whatever it is (`openSelection`); Esc closes, as ever.
    func switchWithKeys() {
        guard shown, let panel, screen != nil else { return }
        guard machine.isOpen, panel.isKeyWindow else {
            takeKeys(panel)
            ui.switching = machine.isOpen
            return
        }
        ui.switching = true
        if ui.presentation != .list { present(.list) }
        select(RowSelection.islandSwitch(ui.selectedRow, sessions: env.sessions, style: env.settings.islandStyle, showAll: ui.showAll))
    }

    /// Opens the island as a click on the pill does, its first row selected, and makes the panel key.
    private func takeKeys(_ panel: IslandPanel) {
        feed(.clicked(at: IslandMotionDirector.now))
        guard machine.isOpen else { return }
        if ui.presentation == .list, ui.selectedRow == nil {
            ui.selectedRow = RowSelection.islandOrder(env.sessions, style: env.settings.islandStyle, showAll: ui.showAll).shown.first?.id
        }
        panel.makeKey()
    }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}

/// The island's panel. Keys go through its own event path only: `performKeyEquivalent` (so ⌘Q never reaches the
/// menu) and `sendEvent` for key-downs, before the field editor, so ⌃A means Yes on an approval (P39), except while a
/// text field is edited, where ⌃A and ⌃D stay the field's (P138). While an input method composes, keys are left alone
/// (P40). Its tooltips show while another app is in front, which is always: the panel never activates Juice Island,
/// and AppKit otherwise shows a tooltip only in the active app (a Clean row's repo and a long title's text, P210).
final class IslandPanel: NSPanel {
    var keyHandler: ((IslandKeyPress) -> Bool)?

    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType,
                  defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        allowsToolTipsWhenApplicationIsInactive = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// AppKit does not work the key view loop out again on every change of the views (E2): with it on, SwiftUI's
    /// `FocusBridge.updateDefaultKeyViewLoop` can run in every frame of a motion (campaign wave 1: 5 to 17 % of a frame's
    /// CPU). AppKit turns it on only for a hosting view that is the window's content view; the island's is a container
    /// view, so it was already off (a sample of the island's motion found no such call either way), and this keeps it
    /// off whatever the content view becomes. With it off, Tab between a card's fields moves only along a loop worked
    /// out by hand (never worked out, it stays on the field it is in, as it did before round A): the panel works it out
    /// as it becomes key (a click into a card; keys reach nothing in the island before that), and when a card mounts or
    /// changes in place while it is key (`KeyViewLoopTests`).
    static func configureKeyViewLoop(_ window: NSWindow) {
        window.autorecalculatesKeyViewLoop = false
    }

    override func becomeKey() {
        recalculateKeyViewLoop()
        super.becomeKey()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if keyHandler?(key(event)) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, !event.modifierFlags.contains(.command), keyHandler?(key(event)) == true { return }
        super.sendEvent(event)
    }

    /// The key as the router reads it; a field being edited has its field editor (an `NSText`) as first responder.
    private func key(_ event: NSEvent) -> IslandKeyPress {
        IslandKeyPress(event: event, hasMarkedText: (firstResponder as? NSTextInputClient)?.hasMarkedText() ?? false,
                       editing: firstResponder is NSText)
    }
}

/// The panel's content view: it holds the canvas (`IslandHostingView`) and the panel's one tracking area (entered,
/// exited and moved, always active, the visible rect), and reports each pointer event; the controller judges inside and
/// outside against the target shape itself.
final class IslandContainerView: NSView {
    enum PointerEvent: Equatable { case entered, moved, exited }

    /// Each pointer event with the event itself: the island reads its place and time from it (`PointerSample`).
    var pointer: ((PointerEvent, NSEvent) -> Void)?
    private var area: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        self.area = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        pointer?(.entered, event)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        pointer?(.moved, event)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        pointer?(.exited, event)
    }
}

/// The island's canvas: a hosting view that SwiftUI never sizes (`sizingOptions` empty), placed by the controller.
final class IslandHostingView: NSHostingView<AnyView> {}
