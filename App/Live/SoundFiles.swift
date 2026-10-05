import AppKit
import UniformTypeIdentifiers

/// Settings › Sound › Choose File… (P1001, P1002): a sound file the owner picks for one event is copied into the app's own
/// support folder, `Sounds/<event>/<its name>`, replacing that event's earlier file, so the choice survives the original
/// being moved or deleted and nothing outside the folder is ever read again. A file is taken only when this Mac plays
/// it (`NSSound` reads it), it is no bigger than `maxBytes` and no longer than `maxSeconds`. The choice is kept as the
/// path inside `Sounds`; a stored path that leaves the folder (a hand edit, `..`, a link) is no file at all.
enum SoundFiles {
    /// The events a file can be chosen for, by their folder's name.
    enum Event: String, CaseIterable, Sendable {
        case needsYou = "needs-you"
        case question
        case done
    }

    static let folderName = "Sounds"
    /// A sound this big is no notification sound, and reading it on every signal would cost.
    static let maxBytes = 5 * 1024 * 1024
    /// Longer than this, a sound would still be playing when the next signal comes.
    static let maxSeconds = 10.0

    /// Why a file was not taken: the one line the row shows until the next choice.
    enum Refusal: Error, Equatable, Sendable {
        case notASound, tooBig, tooLong, notCopied

        var line: String {
            switch self {
            case .notASound: "This Mac cannot play that file."
            case .tooBig: "That file is over 5 MB."
            case .tooLong: "That sound is over 10 seconds."
            case .notCopied: "That file could not be copied."
            }
        }
    }

    /// `~/Library/Application Support/<the app's folder>/Sounds` (tests pass a temporary support folder).
    static func folder(support: URL) -> URL { support.appendingPathComponent(folderName, isDirectory: true) }

    /// Copies `source` in as `event`'s file and returns its choice, or why it was not taken. `playable` says whether this
    /// Mac plays a file and for how long (`NSSound`; tests pass their own).
    static func adopt(_ source: URL, for event: Event, support: URL, fileManager: FileManager = .default,
                      playable: (URL) -> TimeInterval? = SoundFiles.duration) -> Result<SoundChoice, Refusal> {
        let values = try? source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values?.isRegularFile == true, let size = values?.fileSize, size > 0 else { return .failure(.notASound) }
        guard size <= maxBytes else { return .failure(.tooBig) }
        guard let seconds = playable(source) else { return .failure(.notASound) }
        guard seconds <= maxSeconds else { return .failure(.tooLong) }
        let name = safeName(source.lastPathComponent)
        let eventFolder = folder(support: support).appendingPathComponent(event.rawValue, isDirectory: true)
        let staging = folder(support: support).appendingPathComponent(".\(event.rawValue)-\(UUID().uuidString)", isDirectory: true)
        do {
            // Into a fresh folder first, then in place of the old one, so a copy that fails leaves the earlier file in place.
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
            try fileManager.copyItem(at: source, to: staging.appendingPathComponent(name))
            if fileManager.fileExists(atPath: eventFolder.path) { try fileManager.removeItem(at: eventFolder) }
            try fileManager.moveItem(at: staging, to: eventFolder)
        } catch {
            try? fileManager.removeItem(at: staging)
            return .failure(.notCopied)
        }
        return .success(.file(event.rawValue + "/" + name))
    }

    /// The copy's URL for a stored path, only when it names a file right inside one event's folder: anything else (an
    /// absolute path, `..`, a folder of no event's, a link) is nil.
    static func url(_ path: String, support: URL) -> URL? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, Event(rawValue: parts[0]) != nil, parts[1] == safeName(parts[1]), !parts[1].hasPrefix(".") else { return nil }
        let sounds = folder(support: support)
        let url = sounds.appendingPathComponent(parts[0], isDirectory: true).appendingPathComponent(parts[1])
        // Neither the file nor its event's folder may be a link out of the folder.
        let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values?.isSymbolicLink != true,
              url.resolvingSymlinksInPath().path.hasPrefix(sounds.resolvingSymlinksInPath().path + "/") else { return nil }
        return url
    }

    /// The copy is there to play now: inside the folder, a readable regular file, not empty and not too big. Read at the
    /// moment a sound would play; a file that is not goes back to the event's default (`SignalSounds.playable`).
    static func isPlayable(_ path: String, support: URL, fileManager: FileManager = .default) -> Bool {
        guard let url = url(path, support: support),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, let size = values.fileSize, size > 0, size <= maxBytes else { return false }
        return fileManager.isReadableFile(atPath: url.path)
    }

    /// What the pop-up names a file by: its name without the extension ("Doorbell").
    static func title(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        let stem = (name as NSString).deletingPathExtension
        return stem.isEmpty ? name : stem
    }

    /// A file name kept to one path component: no slash, colon or control character, and no more than 120 characters.
    static func safeName(_ name: String) -> String {
        let kept = name.unicodeScalars.map { scalar -> Character in
            CharacterSet.controlCharacters.contains(scalar) || scalar == "/" || scalar == ":" ? "-" : Character(scalar)
        }
        var text = String(kept).trimmingCharacters(in: .whitespaces)
        if text.isEmpty || text == "." || text == ".." { text = "sound" }
        if text.count > 120 {
            let ext = (text as NSString).pathExtension
            text = String(text.prefix(100)) + (ext.isEmpty ? "" : "." + ext.prefix(10))
        }
        return text
    }

    /// How long this Mac plays `url` for, or nil when it cannot play it.
    static func duration(_ url: URL) -> TimeInterval? {
        guard let sound = NSSound(contentsOf: url, byReference: false) else { return nil }
        return sound.duration
    }

    /// The types the open panel offers: any audio this Mac reads.
    static let types: [UTType] = [.audio]
}

/// Settings › Sound's Choose File…: the system's open panel, only on the owner's click (renders and tests never make
/// one). `done` gets the file picked, nothing on Cancel.
@MainActor
enum SoundFilePanel {
    static func choose(_ done: @escaping @MainActor (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = SoundFiles.types
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Choose"
        panel.message = "Pick a sound. \(Product.name) keeps a copy."
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { done(url) }
        }
    }
}

/// Makes the `NSSound` a choice plays: a system sound by name, a Juice sound from its samples, a chosen file from its
/// copy (only inside the folder). nil for None, or for a sound this Mac cannot make, so nothing plays and nothing breaks.
@MainActor
enum SoundLibrary {
    static func sound(_ choice: SoundChoice, support: URL = Product.supportFolder()) -> NSSound? {
        switch choice {
        case .none:
            return nil
        case let .system(name):
            return NSSound(named: NSSound.Name(name))
        case let .juice(sound):
            return NSSound(data: sound.wav)
        case let .file(path):
            guard SoundFiles.isPlayable(path, support: support), let url = SoundFiles.url(path, support: support) else { return nil }
            return NSSound(contentsOf: url, byReference: false)
        }
    }
}
