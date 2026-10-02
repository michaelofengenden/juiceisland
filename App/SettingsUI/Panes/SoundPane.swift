import AppKit
import SwiftUI

/// Settings › Sound (spec §4.5, C3), one group: Mute, Volume (every sound's, P426), the Needs you sound (a system
/// sound), the Question sound (the Needs you sound until the owner picks another, P425) and the Done sound (None).
/// Sounds are system sounds by name; a player is created only when one plays (P33): the engine's signals through
/// `SignalSounds`, and here the Play buttons and the volume's preview when the slider is let go. Owner: stream A.
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
                SoundRow(title: "Needs you", choice: $settings.needsYouSound, options: SoundChoices.options,
                         plays: settings.needsYouSound, settings: settings)
                SoundRow(title: "Question", choice: $settings.questionSound, options: SoundChoices.questionOptions,
                         plays: settings.questionSound ?? settings.needsYouSound, settings: settings)
                SoundRow(title: "Done", choice: $settings.doneSound, options: SoundChoices.options,
                         plays: settings.doneSound, settings: settings)
            }
        }
    }
}

/// One sound's row: its Play button and its pop-up. `plays`: what the choice sounds like (Question's "Same as Needs you"
/// plays the Needs you sound).
private struct SoundRow<Value: Hashable>: View {
    let title: String
    @Binding var choice: Value
    let options: [(Value, String)]
    let plays: SoundChoice
    let settings: AppSettings

    var body: some View {
        FormRow(title, dimmed: settings.soundsMuted) {
            HStack(spacing: 8) {
                // None has nothing to play, so the button goes rather than greys out.
                if plays != .none {
                    PlayButton(label: "Play the \(title) sound") { SoundChoices.play(plays, volume: SignalSounds.volume(settings)) }
                }
                SettingsPopup(selection: $choice, options: options, label: title + " sound")
            }
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

/// The macOS system sounds the pop-ups offer, and None; Question's also "Same as Needs you" (nil), first.
enum SoundChoices {
    static let names = ["Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero", "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink"]
    static var options: [(SoundChoice, String)] { [(.none, "None")] + names.map { (.system($0), $0) } }
    static var questionOptions: [(SoundChoice?, String)] { [(nil, "Same as Needs you")] + options.map { (Optional($0.0), $0.1) } }

    @MainActor static func play(_ choice: SoundChoice, volume: Float) {
        guard case let .system(name) = choice else { return }
        SystemSoundPlayer.play(name, volume: volume)
    }

    /// What Volume's preview plays: the Needs you sound, else the Question sound, else the Done sound.
    @MainActor static func preview(_ settings: AppSettings) -> SoundChoice {
        [settings.needsYouSound, settings.questionSound ?? .none, settings.doneSound].first { $0 != .none } ?? .none
    }
}

/// The pop-up needs hashable values; `SoundChoice` is a shared enum, so the conformance is added here.
extension SoundChoice: Hashable {
    nonisolated func hash(into hasher: inout Hasher) { hasher.combine(storageValue) }
}
