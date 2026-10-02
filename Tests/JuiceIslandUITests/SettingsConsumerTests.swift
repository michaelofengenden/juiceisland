import Foundation
import Testing
@testable import JuiceIslandUI

/// No dead switches (the owner's rule): every persisted setting is read by something outside the places that only show
/// or flip it. A tripwire over the sources, not a proof: it looks for a read of `settings.<name>` (not an assignment, not
/// a `.toggle()`, not a `$settings` binding) in a file under App/ other than Settings' panes and model and the menus
/// that only flip a switch. Seven settings did nothing before wave 2 of 2026-09-25 (P121); this names the next one.
@MainActor
struct SettingsConsumerTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// Places that show or flip a setting without acting on it.
    static let controlSurfaces = ["App/SettingsUI/", "App/Settings/Model/", "App/Shell/GearMenu.swift"]

    /// Every observed stored property of `AppSettings` (the `@Observable` macro keeps each as `_<name>`).
    static func settingNames() -> [String] {
        Mirror(reflecting: AppSettings.ephemeral()).children.compactMap { child in
            guard let label = child.label, label.hasPrefix("_"), !label.hasPrefix("_$") else { return nil }
            return String(label.dropFirst())
        }
    }

    static func appSources() throws -> [(path: String, text: String)] {
        let app = root.appendingPathComponent("App")
        let files = try #require(FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil))
        return try files.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }.compactMap { url in
            let path = String(url.path.dropFirst(root.path.count + 1))
            guard !controlSurfaces.contains(where: { path.hasPrefix($0) }) else { return nil }
            return (path, try String(contentsOf: url, encoding: .utf8))
        }
    }

    @Test
    func everySettingIsReadByWhatItControls() throws {
        let names = Self.settingNames()
        #expect(names.count > 30 && names.contains("launchAtLogin") && names.contains("doneSound"))
        let sources = try Self.appSources()
        let unread = try names.filter { name in
            // A read: not `$settings.x`, and not followed by an assignment or `.toggle()`.
            let read = try NSRegularExpression(pattern: "(?<![$\\w])settings\\.\(name)\\b(?!\\s*=[^=]|\\.toggle\\(\\))")
            return !sources.contains { read.firstMatch(in: $0.text, range: NSRange($0.text.startIndex..., in: $0.text)) != nil }
        }
        #expect(unread.isEmpty, "settings nothing reads: \(unread)")
    }
}
