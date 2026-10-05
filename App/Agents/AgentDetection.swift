import Foundation
import JuiceCore

/// What says an agent is on this Mac: any of its executables by name, or any of its config folders (`~/…`). Named apart
/// from the engine's agents table and its own presence check, which may take its directories from `AgentDetector`.
struct AgentFootprint: Equatable, Sendable {
    var executables: [String]
    var folders: [String]
    /// Homebrew formulae whose command of one of those names is another program (`AgentHookSpec.namesakeFormulae`).
    var namesakes: [String] = []
}

/// Finds the agents on this Mac (P937): an executable in the login shell's PATH or one of the places installers put
/// one that a login shell may not list, or a config folder. Reads names and file kinds only: no file is opened, nothing
/// is run but the login shell `ToolLocator` already asks for its PATH, and nothing is written.
enum AgentDetector {
    /// The login shell's PATH, then Homebrew's, `~/.local/bin`, Bun's, and the places npm, nvm, Volta, pnpm and Yarn
    /// put global commands, each once, in that order. npm's default global bin is node's own folder, which the PATH or
    /// Homebrew already lists; `~/.npmrc` is never read, since it can hold a registry token (P937).
    static func searchDirectories(home: String, loginPATH: String, fileManager: FileManager = .default) -> [String] {
        var dirs = loginPATH.split(separator: ":").map(String.init)
        dirs += ["/opt/homebrew/bin", "/usr/local/bin", home + "/.local/bin", home + "/.bun/bin", home + "/.npm-global/bin"]
        let nvm = home + "/.nvm/versions/node"
        if let versions = try? fileManager.contentsOfDirectory(atPath: nvm) {
            dirs += versions.filter { !$0.hasPrefix(".") }.sorted(by: >).map { "\(nvm)/\($0)/bin" }
        }
        dirs += [home + "/.volta/bin", home + "/Library/pnpm", home + "/.yarn/bin"]
        var seen: Set<String> = []
        return dirs.map { expand($0, home: home) }.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// `~/x` and `$HOME/x` under `home`.
    static func expand(_ path: String, home: String) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + path.dropFirst(1) }
        if path.hasPrefix("$HOME/") { return home + path.dropFirst(5) }
        return path
    }

    /// Found: one of its executables in `directories` (a file that may run, a link followed to one; never a folder of
    /// that name, nor one that resolves into the Cellar of a formula that ships another program by that name), or one
    /// of its folders under `home`.
    static func isPresent(_ footprint: AgentFootprint, home: String, directories: [String], fileManager: FileManager = .default) -> Bool {
        for name in footprint.executables where !name.isEmpty && !name.contains("/") {
            if directories.contains(where: { directory in
                let path = directory + "/" + name
                return isCommand(path, fileManager: fileManager) && !isNamesake(path, formulae: footprint.namesakes)
            }) { return true }
        }
        return footprint.folders.contains { isFolder(expand($0, home: home), fileManager: fileManager) }
    }

    static func isCommand(_ path: String, fileManager: FileManager) -> Bool {
        fileManager.isExecutableFile(atPath: path) && !isFolder(path, fileManager: fileManager)
    }

    /// The command resolves into `…/Cellar/<formula>/…` of one of `formulae`: Homebrew's `amp`, a text editor, and not
    /// the agent (P1187). Reads the links only.
    static func isNamesake(_ path: String, formulae: [String]) -> Bool {
        guard !formulae.isEmpty else { return false }
        let parts = URL(fileURLWithPath: path).resolvingSymlinksInPath().pathComponents
        return zip(parts, parts.dropFirst()).contains { $0 == "Cellar" && formulae.contains($1) }
    }

    static func isFolder(_ path: String, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// This Mac's: the login shell's PATH (asked once, `ToolLocator`) and the places above.
    static func appDirectories() -> [String] {
        searchDirectories(home: NSHomeDirectory(), loginPATH: ToolLocator.loginShellPATH())
    }
}
