import AppKit
import SwiftUI

/// The key recorder: a click makes it first responder and the next key is captured in its own `keyDown` (and
/// `performKeyEquivalent`, for ⌘ keys), never through an event monitor (spec §4.4). Esc cancels, Delete clears.
/// `onRecording` hears it start and stop (the registered key is let go meanwhile, so it can be recorded again).
struct KeyRecorder: View {
    @Binding var storage: String?
    var onRecording: (Bool) -> Void = { _ in }
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
        // Settings closing mid-recording gives the key back.
        .onDisappear { if recording { onRecording(false) } }
    }

    private func record(_ event: KeyCaptureView.Captured) {
        switch event {
        case .cancel: recording = false
        case .clear:
            storage = nil
            recording = false
        case let .combo(combo):
            if combo.isAcceptable {
                storage = combo.storage
                rejected = nil
                recording = false
            } else {
                rejected = "Add ⌃, ⌥ or ⌘: a plain key would be taken from every app."
            }
        }
    }
}

/// The clear AppKit view laid over the recorder's face that takes first responder and reads keys.
struct KeyCaptureView: NSViewRepresentable {
    enum Captured { case cancel, clear, combo(KeyCombo) }

    @Binding var recording: Bool
    var onCapture: (Captured) -> Void

    func makeNSView(context: Context) -> RecorderNSView {
        let view = RecorderNSView()
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
            if let combo = KeyCombo.from(characters: event.charactersIgnoringModifiers, modifiers: event.modifierFlags) {
                onCapture?(.combo(combo))
                if combo.isAcceptable { window?.makeFirstResponder(nil) }
            }
        }
    }
}
