import SwiftUI

/// The toolbar's Update control (`UpdateControl`), just left of the gear: only while an update is offered, runs or
/// failed, or once after one. It is the run's progress (P803): "Update" (or "Restart to update" once a background
/// prepare has it built, P711), then the fill with "Fetching", "Building 63%", "Installing", then "Updated" with a check
/// and the glow before the relaunch; "Update failed" with Retry; "Updated" once after the relaunch. A run, or the note
/// after one, opens Settings › About on a click, where the time left, the reason and the log, and What's new are.
struct UpdateToolbarButton: View {
    var body: some View { UpdateControl(place: .toolbar) }
}

/// Settings › About's Updates section: when it was checked and Check now (the build itself is named under the app's
/// name); an offered update ("12 changes", its list behind a disclosure that stays shut until the owner opens it, or
/// "Not built from origin/main") with the Update control (P803), "Preparing…" beside it while a background prepare builds
/// it; while the build runs, the time the estimate leaves under the changes (P802); after a failure, the reason in plain
/// words with Show Log under it (P809); "Updated" once after one, or this build's What's new behind its own disclosure
/// (P716) in its place; and the Prepare updates in the background switch. The public flavor's feed (P823, P824) has the
/// same rows but no log of ours and no prepare (the feed downloads on the click), and a public build made without the
/// feed's key says only that updates are off.
struct AboutUpdatesSection: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        // The control builds origin/main as GitHub has it, in the updater's own checkout, checks it, then restarts; if
        // a step fails, this app stays as it is. The public flavor's feed downloads the new version instead.
        FormSection("Updates") {
            if env.updateChecker.source == .off {
                FormRow(UpdateText.updatesOff) { EmptyView() }
            } else {
                rows
            }
        }
    }

    @ViewBuilder private var rows: some View {
        @Bindable var settings = env.settings
        let checker = env.updateChecker
        let controller = env.updateController
        let source = checker.source
        let phase = controller.phase
        let state = UpdateControlState.of(available: checker.available, phase: phase,
                                          prepared: controller.restartOffered(for: checker.available), progress: controller.progress)
        FormRow(UpdateText.status(checker.state, today: source == .feed ? Date() : nil)) {
            PushButton(title: "Check now", small: true) {
                controller.clearNotice()
                checker.checkNow()
            }
                .disabled(checker.state == .checking || phase.isRunning)
                .opacity(checker.state == .checking || phase.isRunning ? 0.45 : 1)
        }
        if Self.showsControl(state) {
            let info = checker.available
            let list = info.map { !$0.subjects.isEmpty } ?? false
            OfferRow(label: Self.offerLabel(info),
                     subtitle: phase == .building ? UpdateText.timeLeft(controller.progress) : nil,
                     expanded: list ? checker.showsChanges : nil, toggle: { checker.showsChanges.toggle() }) {
                HStack(spacing: 10) {
                    if controller.preparing, case .offer = state {
                        Text("Preparing…").font(SettingsTheme.TypeScale.rowSubtitle).foregroundStyle(SettingsTheme.ink3)
                    }
                    UpdateControl(place: .about)
                }
            }
            if let info, checker.showsChanges, list {
                ChangeList(subjects: info.subjects, more: info.newer - info.subjects.count)
            }
            if case let .failed(reason) = state {
                FormRow(UpdateText.plainReason(reason)) {
                    // The feed keeps no log of ours.
                    if source == .git { PushButton(title: "Show Log", small: true) { controller.openLog() } }
                }
            }
        }
        if let note = controller.whatsNew {
            // What changed in this build says what "Updated" would: it takes that row's place.
            OfferRow(label: "What's new", expanded: controller.showsWhatsNewList,
                     toggle: { controller.showsWhatsNewList.toggle() }) { EmptyView() }
            if controller.showsWhatsNewList {
                let lines = note.lines(limit: note.subjects.count)
                ChangeList(subjects: lines.shown, more: lines.more)
            }
        } else if UpdateText.isUpdated(phase), !Self.showsControl(state) {
            // The build line above names the commit.
            FormRow("Updated") { EmptyView() }
        }
        // The feed downloads only on the click: nothing to prepare.
        if source == .git {
            FormRow("Prepare updates in the background", subtitle: "On power only. Installing waits for your click.") {
                SettingsSwitch(isOn: Binding(get: { settings.prepareUpdates }, set: {
                    settings.prepareUpdates = $0
                    controller.prepareSettingChanged()
                }), label: "Prepare updates in the background")
            }
        }
    }

    /// The control's row label: what the offered update brings.
    /// None known (a failure restored at launch, before the first check ends): no words, since the control says it.
    static func offerLabel(_ info: UpdateInfo?) -> String { info.map(UpdateText.offer) ?? "" }

    /// The control has its row while an update is offered, runs or failed; once after one the Updated row (or What's
    /// new) says it instead.
    static func showsControl(_ state: UpdateControlState) -> Bool {
        switch state {
        case .hidden, .updated: false
        case .offer, .running, .finished, .restartNeeded, .failed: true
        }
    }
}

/// The offered update's row: "12 changes" behind a disclosure chevron (the whole label opens and shuts the list), or
/// the words alone when there is no list (`expanded` nil), with a quiet line under them (`subtitle`: the time a build
/// has left); its control at the right. What's new uses it too.
private struct OfferRow<Control: View>: View {
    let label: String
    var subtitle: String? = nil
    /// nil: no list to open.
    let expanded: Bool?
    let toggle: () -> Void
    @ViewBuilder var control: Control

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                if let expanded {
                    Button(action: toggle) {
                        HStack(spacing: 6) {
                            SVGIcon(svg: ChromeIcon.disclosure, size: CGSize(width: 8, height: 10), colour: SettingsTheme.ink2)
                                .rotationEffect(.degrees(expanded ? 90 : 0))
                            Text(label).font(SettingsTheme.TypeScale.row).foregroundStyle(SettingsTheme.ink)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(label)
                    .accessibilityValue(expanded ? "shown" : "hidden")
                } else {
                    Text(label).font(SettingsTheme.TypeScale.row).foregroundStyle(SettingsTheme.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let subtitle {
                    Text(subtitle).font(SettingsTheme.TypeScale.rowSubtitle).foregroundStyle(SettingsTheme.ink2)
                        .padding(.leading, expanded == nil ? 0 : 14)
                }
            }
            control
        }
        .padding(SettingsTheme.Metrics.rowPadding)
        .frame(minHeight: SettingsTheme.Metrics.rowMinHeight)
    }
}

/// Commit subjects, newest first; "and N more" past the list.
private struct ChangeList: View {
    let subjects: [String]
    let more: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(subjects.enumerated()), id: \.offset) { _, subject in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Circle().fill(SettingsTheme.accent).frame(width: 4, height: 4).alignmentGuide(.firstTextBaseline) { $0.height + 1 }
                    Text(subject).font(Fonts.sys(12)).foregroundStyle(SettingsTheme.ink).lineLimit(1).truncationMode(.tail)
                }
            }
            if more > 0 {
                Text("and \(more) more").font(Fonts.sys(11)).foregroundStyle(SettingsTheme.ink3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: 9, leading: 12, bottom: 10, trailing: 12))
    }
}
