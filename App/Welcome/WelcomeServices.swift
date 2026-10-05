import AppKit
import Foundation
import IslandEngine
import JuiceCore

/// The app's welcome services: this Mac's screens, terminals and other islands. Each acts only when the welcome's
/// buttons call it, on the owner's click (P955, P958, P960).
@MainActor
final class LiveWelcomeServices: WelcomeServices {
    private let settings: AppSettings
    private let host: FreshSessionLaunch.Host

    init(settings: AppSettings) {
        self.settings = settings
        host = FreshSessionLaunch.liveUsualHost()
    }

    var openIslandRunning: Bool { SingleIslandGuard.otherIslandIsRunning() }
    var hasNotch: Bool { NSScreen.screens.contains { IslandScreen($0).hasNotch } }
    var terminalName: String { host.name }

    func findVibeIsland() async -> [VibeIslandHooks.Found] {
        await Task.detached(priority: .utility) { Self.vibeIsland(home: NSHomeDirectory()) }.value
    }

    /// Vibe Island's entries under `home`: in each Claude and Codex folder found there, and in the agents table's places.
    /// Reads only.
    nonisolated static func vibeIsland(home: String) -> [VibeIslandHooks.Found] {
        let profiles = LiveProfiles.discovered(home: home).map { (provider: $0.provider, folder: $0.folder) }
        return VibeIslandHooks.scan(VibeIslandHooks.places(home: URL(fileURLWithPath: home, isDirectory: true), profiles: profiles))
    }

    func switchFromVibeIsland(_ found: [VibeIslandHooks.Found]) async -> [URL: VibeIslandHooks.Outcome] {
        // Asked to quit first, so it is not mid-write; it writes its hooks back only when it opens again.
        if SingleIslandGuard.askVibeIslandToQuit() {
            for _ in 0..<20 where SingleIslandGuard.vibeIslandIsRunning() { try? await Task.sleep(for: .milliseconds(150)) }
        }
        return await Task.detached(priority: .userInitiated) { VibeIslandHooks.remove(found) }.value
    }

    func askOpenIslandToQuit() { SingleIslandGuard.askOpenIslandToQuit() }

    func start(command: String, folder: String?) async -> Bool {
        await FreshSessionLaunch.openLive(.firstSession(command: command, host: host, folder: folder))
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func chime() {
        guard !settings.soundsMuted else { return }
        SystemSoundPlayer.play(WelcomeSound.chime, volume: SignalSounds.volume(settings))
    }
}

enum WelcomeSound {
    /// A turn done, the island's own default for a finish.
    static let chime = "Glass"
}

/// Renders' and tests' services: a made-up Mac, every call recorded and nothing done.
@MainActor
final class FixtureWelcomeServices: WelcomeServices {
    var openIslandRunning: Bool
    var hasNotch: Bool
    var terminalName: String
    var vibe: [VibeIslandHooks.Found]
    var opens: Bool
    /// What Switch to Juice reports for each file (none: every file came out).
    var switchOutcomes: [URL: VibeIslandHooks.Outcome] = [:]
    private(set) var calls: [String] = []

    init(openIslandRunning: Bool = false, hasNotch: Bool = true, terminalName: String = "Terminal",
         vibe: [VibeIslandHooks.Found] = [], opens: Bool = true) {
        self.openIslandRunning = openIslandRunning
        self.hasNotch = hasNotch
        self.terminalName = terminalName
        self.vibe = vibe
        self.opens = opens
    }

    func findVibeIsland() async -> [VibeIslandHooks.Found] { vibe }

    func switchFromVibeIsland(_ found: [VibeIslandHooks.Found]) async -> [URL: VibeIslandHooks.Outcome] {
        calls.append("switch \(found.count)")
        vibe = []
        return switchOutcomes
    }

    func askOpenIslandToQuit() {
        calls.append("quit Open Island")
        openIslandRunning = false
    }

    func start(command: String, folder: String?) async -> Bool {
        calls.append(folder.map { "start \(command) in \($0)" } ?? "start \(command)")
        return opens
    }

    func copy(_ text: String) { calls.append("copy \(text)") }
    func chime() { calls.append("chime") }
}
