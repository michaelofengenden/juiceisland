import AppKit
import SwiftUI

/// The key recorder: a click makes it first responder and the next key is captured in its own `keyDown` (and
/// `performKeyEquivalent`, for ⌘ keys), never through an event monitor (spec §4.4). Esc cancels, Delete clears.
/// `onRecording` hears it start and stop (the registered key is let go meanwhile, so it can be recorded again).
struct KeyRecorder: View {
    @Binding var storage: String?
    var onRecording: (Bool) -> Void = { _ in }
    /// Why a key cannot be had though it has ⌃, ⌥ or ⌘ (another of Juice's keys, P1028), or nil.
    var refuse: (KeyCombo) -> String? = { _ in nil }
    /// Hears why the last key was not taken (nil once one is), for the line under the row.
    var onRejected: (String?) -> Void = { _ in }
    @State private var recording = false
    @State private var rejected: String?

    var body: some View {
        let combo = storage.flatMap(KeyCombo.init(storage:))
        HStack(spacing: 8) {
            Text(recording ? "Press a key…" : combo?.display ?? "Record Key")
                .font(Fonts.sys(12.5, combo == nil || recording ? .regular : .semibold))
                .foregroundStyle(recording || combo == nil ? SettingsTheme.ink2 : SettingsTheme.ink)
                .frame(minWidth: 96)
                .frame(height: 24)
                .padding(.horizontal, 8)
                .background(RoundedRectangle(cornerRadius: 6).fill(SettingsTheme.pair(black: recording ? 0.08 : 0.04, white: recording ? 0.1 : 0.06)))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(recording ? SettingsTheme.accent.opacity(0.8) : SettingsTheme.controlEdge, lineWidth: recording ? 2 : 0.5))
                .overlay {
                    KeyCaptureView(recording: $recording) { event in record(event) }
                }
                .accessibilityLabel(combo.map { "Jump key \($0.display)" } ?? "Record jump key")
            if combo != nil, !recording {
                PushButton(title: "Clear", small: true) { storage = nil }
            }
        }
        .help(rejected ?? "Click, then press the key. Esc cancels.")
        .onChange(of: recording) { _, recording in onRecording(recording) }
        .onChange(of: rejected) { _, rejected in onRejected(rejected) }
        // Settings closing mid-recording gives the key back.
        .onDisappear { if recording { onRecording(false) } }
    }

    private func record(_ event: KeyCaptureView.Captured) {
        switch event {
        case .cancel: recording = false
        case .clear:
            storage = nil
            rejected = nil
            recording = false
        case let .combo(combo):
            if !combo.isAcceptable {
                rejected = "Add ⌃, ⌥ or ⌘: a plain key would be taken from every app."
            } else if let why = refuse(combo) {
                rejected = why
                recording = false
            } else {
                storage = combo.storage
                rejected = nil
                recording = false
            }
        case .press:
            break
        }
    }
}

/// A card key's recorder (Settings › Shortcuts, P1026): its face shows the key with the pane's modifier ("⌃A"); a
/// click records the next key's character and Shift, whatever modifier is held with it (⌘ is refused: the menus').
/// Esc and Delete cancel. A key the pane refuses (`record` says why) keeps it recording, its reason on the row's line.
/// Reset, before the face while the key is not the standard one, brings that back. Never an event monitor (spec §4.4).
struct CardKeyRecorder: View {
    let action: CardKeyAction
    let keys: CardKeys
    /// Takes `key` for `action`, or says why not.
    let record: (CardKey) -> String?
    let reset: () -> Void
    /// The row's line: why the last key was refused, until one is taken or the recording stops.
    @Binding var refusal: String?
    @State private var recording = false

    var body: some View {
        HStack(spacing: 8) {
            if !keys.isStandard(action), !recording {
                PushButton(title: "Reset", small: true) {
                    reset()
                    refusal = nil
                }
            }
            Text(recording ? "Press a key…" : keys.display(action))
                .font(Fonts.sys(12.5, recording ? .regular : .semibold))
                .foregroundStyle(recording ? SettingsTheme.ink2 : SettingsTheme.ink)
                .frame(minWidth: 64)
                .frame(height: 24)
                .padding(.horizontal, 8)
                .background(RoundedRectangle(cornerRadius: 6).fill(SettingsTheme.pair(black: recording ? 0.08 : 0.04, white: recording ? 0.1 : 0.06)))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(recording ? SettingsTheme.accent.opacity(0.8) : SettingsTheme.controlEdge, lineWidth: recording ? 2 : 0.5))
                .overlay {
                    KeyCaptureView(recording: $recording, raw: true) { captured in capture(captured) }
                }
                .accessibilityLabel("\(action.title) key \(keys.display(action))")
        }
        .help("Click, then press a key. Esc cancels.")
        // A click elsewhere ends it: the last refusal goes with it.
        .onChange(of: recording) { _, recording in if !recording { refusal = nil } }
    }

    private func capture(_ captured: KeyCaptureView.Captured) {
        switch captured {
        case .cancel, .clear:
            refusal = nil
            recording = false
        case .combo:
            break
        case let .press(characters, modifiers):
            if let why = CardKeyCheck.refusal(characters: characters, modifiers: modifiers) {
                refusal = why
                return
            }
            guard let characters else { return }
            if let why = record(CardKeyCheck.key(characters: characters, modifiers: modifiers)) {
                refusal = why
            } else {
                refusal = nil
                recording = false
            }
        }
    }
}

/// The clear AppKit view laid over the recorder's face that takes first responder and reads keys.
struct KeyCaptureView: NSViewRepresentable {
    /// `press`: the key as it came (a card key's recorder, `raw`), which the recorder judges and ends itself.
    enum Captured { case cancel, clear, combo(KeyCombo), press(String?, NSEvent.ModifierFlags) }

    @Binding var recording: Bool
    var raw = false
    var onCapture: (Captured) -> Void

    func makeNSView(context: Context) -> RecorderNSView {
        let view = RecorderNSView()
        view.raw = raw
        view.onCapture = onCapture
        view.onRecordingChange = { recording = $0 }
        return view
    }

    func updateNSView(_ view: RecorderNSView, context: Context) {
        view.onCapture = onCapture
        view.onRecordingChange = { recording = $0 }
        if !recording, view.window?.firstResponder === view { view.window?.makeFirstResponder(nil) }
    }

    final class RecorderNSView: NSView {
        var raw = false
        var onCapture: ((Captured) -> Void)?
        var onRecordingChange: ((Bool) -> Void)?

        override var acceptsFirstResponder: Bool { true }

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
        }

        override func becomeFirstResponder() -> Bool {
            onRecordingChange?(true)
            return true
        }

        override func resignFirstResponder() -> Bool {
            onRecordingChange?(false)
            return true
        }

        override func keyDown(with event: NSEvent) {
            handle(event)
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard window?.firstResponder === self else { return false }
            handle(event)
            return true
        }

        private func handle(_ event: NSEvent) {
            let flags = event.modifierFlags.intersection([.control, .option, .command, .shift])
            if event.charactersIgnoringModifiers == "\u{1B}", flags.isEmpty {
                onCapture?(.cancel)
                window?.makeFirstResponder(nil)
                return
            }
            if let characters = event.charactersIgnoringModifiers, flags.isEmpty,
               characters == "\u{7F}" || characters == String(UnicodeScalar(NSDeleteFunctionKey)!) {
                onCapture?(.clear)
                window?.makeFirstResponder(nil)
                return
            }
            if raw {
                onCapture?(.press(event.charactersIgnoringModifiers, event.modifierFlags.intersection([.control, .option, .command, .shift])))
                return
            }
            if let combo = KeyCombo.from(characters: event.charactersIgnoringModifiers, modifiers: event.modifierFlags) {
                onCapture?(.combo(combo))
                if combo.isAcceptable { window?.makeFirstResponder(nil) }
            }
        }
    }
}
