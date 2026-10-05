import AppKit
import SwiftUI

/// Settings › Sound (spec §4.5, C3), one group: Mute, Volume (every sound's, P426), the Needs you sound (a system
/// sound), the Question sound (the Needs you sound until the owner picks another, P425) and the Done sound (None). Each
/// sound's pop-up offers None, Juice's own three (`JuiceSound`, P1000), the macOS sounds and Choose File… (a copy kept in
/// the app's folder, `SoundFiles`, P1001); a file it would not take says why under the row until the next choice. A
/// player is created only when one plays (P33): the engine's signals through `SignalSounds`, and here the Play buttons
/// and the volume's preview when the slider is let go. Owner: stream A.
struct SoundPane: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        @Bindable var settings = env.settings
        FormPane {
            FormSection {
                FormRow("Mute") {
                    SettingsSwitch(isOn: $settings.soundsMuted, label: "Mute")
                }
                FormRow("Volume", dimmed: settings.soundsMuted) {
                    VolumeSlider(value: $settings.soundVolume) {
                        // Let go: the first sound the owner hears most, at the new volume.
                        if !settings.soundsMuted { SoundChoices.play(SoundChoices.preview(settings), volume: SignalSounds.volume(settings)) }
                    }
                }
                SoundRow(title: "Needs you", event: .needsYou,
                         choice: Binding(get: { settings.needsYouSound }, set: { settings.needsYouSound = $0 ?? .none }),
                         plays: settings.needsYouSound, settings: settings) { SignalSounds.needsYouChoice(settings) }
                SoundRow(title: "Question", event: .question, sameAsNeedsYou: true, choice: $settings.questionSound,
                         plays: settings.questionSound ?? settings.needsYouSound, settings: settings) { SignalSounds.questionChoice(settings) }
                SoundRow(title: "Done", event: .done,
                         choice: Binding(get: { settings.doneSound }, set: { settings.doneSound = $0 ?? .none }),
                         plays: settings.doneSound, settings: settings) {
                    SignalSounds.playable(settings.doneSound, fallback: .none, support: Product.supportFolder())
                }
            }
        }
    }
}

/// One sound's row: its Play button and its pop-up. `choice` is nil only for Question's "Same as Needs you". `plays`:
/// the choice as stored, for whether there is anything to play; `resolve`: what plays when Play is clicked (a chosen
/// file that is gone plays the event's default, P1001), read only then.
private struct SoundRow: View {
    let title: String
    let event: SoundFiles.Event
    var sameAsNeedsYou = false
    @Binding var choice: SoundChoice?
    let plays: SoundChoice
    let settings: AppSettings
    let resolve: @MainActor () -> SoundChoice
    /// Why the last file picked was not taken; cleared by the next choice.
    @State private var refusal: SoundFiles.Refusal?
    /// A render's refusal to show (`previewSoundRefusals`); none in the app.
    @Environment(\.previewSoundRefusals) private var previewRefusals

    var body: some View {
        FormRow(title, subtitle: (refusal ?? previewRefusals[event])?.line, dimmed: settings.soundsMuted) {
            HStack(spacing: 8) {
                // None has nothing to play, so the button goes rather than greys out.
                if plays != .none {
                    PlayButton(label: "Play the \(title) sound") { SoundChoices.play(resolve(), volume: SignalSounds.volume(settings)) }
                }
                SoundMenu(selection: Binding(get: { choice }, set: { choice = $0; refusal = nil }), sameAsNeedsYou: sameAsNeedsYou,
                          label: title + " sound", choose: chooseFile)
            }
        }
    }

    /// The open panel, on the click only; the file picked is copied in as this event's, or the row says why not.
    private func chooseFile() {
        SoundFilePanel.choose { url in
            switch SoundFiles.adopt(url, for: event, support: Product.supportFolder()) {
            case let .success(file):
                choice = file
                refusal = nil
            case let .failure(why):
                refusal = why
            }
        }
    }
}

/// A sound's pop-up: the settings pop-up's face, and a menu of None (after "Same as Needs you" for Question), Juice's
/// sounds, the macOS sounds, the file now chosen (when one is) and Choose File….
struct SoundMenu: View {
    @Binding var selection: SoundChoice?
    var sameAsNeedsYou = false
    var label: String
    var choose: () -> Void = {}

    var body: some View {
        Menu {
            ForEach(SoundChoices.lead(sameAsNeedsYou: sameAsNeedsYou), id: \.1) { value, title in item(value, title) }
            Section("Juice") {
                ForEach(SoundChoices.juiceOptions, id: \.1) { value, title in item(value, title) }
            }
            Section("macOS") {
                ForEach(SoundChoices.systemOptions, id: \.1) { value, title in item(value, title) }
            }
            if case let .file(path)? = selection {
                Section { item(selection, SoundFiles.title(path)) }
            }
            Divider()
            Button(SoundChoices.chooseFile, action: choose)
        } label: {
            PopupFace(title: SoundChoices.title(selection, sameAsNeedsYou: sameAsNeedsYou))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(label)
    }

    private func item(_ value: SoundChoice?, _ title: String) -> some View {
        Button { selection = value } label: {
            if selection == value { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }
}

/// Volume: a 4 pt track, blue up to the switch's white knob, dragged or clicked anywhere along it; ← → step it by a
/// tenth for VoiceOver. `ended`: the drag let go.
private struct VolumeSlider: View {
    @Binding var value: Double
    var ended: () -> Void

    static let width: CGFloat = 150
    static var range: ClosedRange<Double> { SignalSounds.quietestVolume...1 }

    var body: some View {
        let knob = SettingsTheme.Metrics.switchKnob
        let fraction = (SignalSounds.stored(value) - Self.range.lowerBound) / (Self.range.upperBound - Self.range.lowerBound)
        let x = CGFloat(fraction) * (Self.width - knob)
        ZStack(alignment: .leading) {
            Capsule().fill(SettingsTheme.switchOff).frame(height: 4)
            Capsule().fill(SettingsTheme.accent).frame(width: x + knob / 2, height: 4)
            Circle().fill(.white).frame(width: knob, height: knob)
                .shadow(color: .black.opacity(0.35), radius: 1, y: 1)
                .offset(x: x)
        }
        .frame(width: Self.width, height: SettingsTheme.Metrics.switchSize.height)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { drag in value = Self.value(at: drag.location.x, knob: knob) }
            .onEnded { _ in ended() })
        .accessibilityElement()
        .accessibilityLabel("Volume")
        .accessibilityValue("\(Int((SignalSounds.stored(value) * 100).rounded())) %")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = SignalSounds.stored(value + 0.1)
            case .decrement: value = SignalSounds.stored(value - 0.1)
            @unknown default: break
            }
        }
    }

    /// The volume under the pointer at `x` along the track, the knob's centre following it, in hundredths.
    static func value(at x: CGFloat, knob: CGFloat) -> Double {
        let fraction = Double(min(max((x - knob / 2) / (width - knob), 0), 1))
        let volume = range.lowerBound + fraction * (range.upperBound - range.lowerBound)
        return (volume * 100).rounded() / 100
    }
}

/// A 20 pt circle with a play triangle: the same circle as the pop-up's chevron beside it.
private struct PlayButton: View {
    let label: String
    let action: () -> Void
    @State private var hovering = false

    static let svg = #"<svg width="10" height="10" viewBox="0 0 10 10"><path d="M2.4 1.2v7.6L9 5z" fill="currentColor"/></svg>"#

    var body: some View {
        Button(action: action) {
            SVGIcon(svg: Self.svg, size: CGSize(width: 9, height: 9), colour: SettingsTheme.ink)
                .offset(x: 0.5)
                .frame(width: 20, height: 20)
                .background(Circle().fill(hovering ? SettingsTheme.roundHover : SettingsTheme.popupCircle))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Play")
        .accessibilityLabel(label)
    }
}

/// The sounds the pop-ups offer: None, Juice's own (P1000) and the macOS system sounds, flat (`options`) or as the
/// menu's sections; Question's also "Same as Needs you" (nil), first.
enum SoundChoices {
    static let names = ["Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero", "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink"]
    static var juiceOptions: [(SoundChoice?, String)] { JuiceSound.allCases.map { (.juice($0), $0.title) } }
    static var systemOptions: [(SoundChoice?, String)] { names.map { (.system($0), $0) } }
    static var options: [(SoundChoice, String)] {
        ([(SoundChoice.none, "None")] + juiceOptions + systemOptions).compactMap { value, title in value.map { ($0, title) } }
    }
    static var questionOptions: [(SoundChoice?, String)] { [(nil, sameAsNeedsYou)] + options.map { (Optional($0.0), $0.1) } }

    static let sameAsNeedsYou = "Same as Needs you"
    static let chooseFile = "Choose File…"

    /// The menu's first items, before the sections.
    static func lead(sameAsNeedsYou same: Bool) -> [(SoundChoice?, String)] {
        (same ? [(nil, sameAsNeedsYou)] : []) + [(SoundChoice.none, "None")]
    }

    /// What the pop-up's face says for `choice`.
    static func title(_ choice: SoundChoice?, sameAsNeedsYou same: Bool = false) -> String {
        switch choice {
        case nil: same ? sameAsNeedsYou : "None"
        case .none?: "None"
        case let .system(name)?: name
        case let .juice(sound)?: sound.title
        case let .file(path)?: SoundFiles.title(path)
        }
    }

    @MainActor static func play(_ choice: SoundChoice, volume: Float) {
        SystemSoundPlayer.play(choice, volume: volume)
    }

    /// What Volume's preview plays: the Needs you sound, else the Question sound, else the Done sound, each as it plays
    /// now (a chosen file that is gone, its default).
    @MainActor static func preview(_ settings: AppSettings, support: URL = Product.supportFolder()) -> SoundChoice {
        let question = settings.questionSound == nil ? SoundChoice.none : SignalSounds.questionChoice(settings, support: support)
        return [SignalSounds.needsYouChoice(settings, support: support), question,
                SignalSounds.playable(settings.doneSound, fallback: .none, support: support)].first { $0 != .none } ?? .none
    }
}

/// The pop-up needs hashable values; `SoundChoice` is a shared enum, so the conformance is added here.
extension SoundChoice: Hashable {
    nonisolated func hash(into hasher: inout Hasher) { hasher.combine(storageValue) }
}

extension EnvironmentValues {
    /// Renders only: the line a row shows as if a file picked for its event had been refused.
    @Entry var previewSoundRefusals: [SoundFiles.Event: SoundFiles.Refusal] = [:]
}
