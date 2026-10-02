import Foundation

/// The `BROWSER` helper the vendor's login opens its page through (Juice spec §7 step 2), the same script standalone
/// Juice keeps next to `accounts.json`: it opens the page in the chosen Chrome profile, or in the default browser.
/// Nothing opens a browser without the owner's click on Sign In.
enum BrowserHelper {
    static let fileName = "open-in-browser-profile.sh"

    static let script = """
    #!/bin/sh
    # Juice's BROWSER helper. Opens $1 in the chosen Chrome profile, or in the default browser when none is chosen.
    if [ -n "$JUICE_BROWSER_PROFILE" ]; then
      exec open -na "Google Chrome" --args --profile-directory="$JUICE_BROWSER_PROFILE" "$1"
    else
      exec open "$1"
    fi

    """

    /// Writes the helper into `directory` (mode 755) unless it is already there as written; nil when it can't.
    static func install(in directory: URL) -> URL? {
        let target = directory.appendingPathComponent(fileName)
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            if (try? String(contentsOf: target, encoding: .utf8)) != script {
                try Data(script.utf8).write(to: target, options: .atomic)
            }
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
            return target
        } catch {
            return nil
        }
    }
}

/// A Chrome profile sign-in pages can open in.
struct ChromeProfile: Identifiable, Hashable, Sendable {
    var directory: String   // "Default", "Profile 1", …
    var name: String        // the name Chrome shows
    var id: String { directory }
}

/// Chrome's profiles, and the one chosen for sign-ins. The choice is standalone Juice's own defaults key, so the
/// release build (which shares Juice's bundle id) keeps the owner's choice.
enum ChromeProfiles {
    static let defaultsKey = "browserProfileDirectory"

    /// Chrome's profile folders, each with the name from its Preferences file. Empty when Chrome is not installed.
    static func list(chromeFolder: URL = FileManager.default.homeDirectoryForCurrentUser
                        .appendingPathComponent("Library/Application Support/Google/Chrome")) -> [ChromeProfile] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: chromeFolder.path) else { return [] }
        struct Preferences: Decodable { struct Profile: Decodable { var name: String? }; var profile: Profile? }
        return entries.filter { $0 == "Default" || $0.hasPrefix("Profile ") }.sorted().map { directory in
            let url = chromeFolder.appendingPathComponent(directory).appendingPathComponent("Preferences")
            let prefs = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Preferences.self, from: $0) }
            return ChromeProfile(directory: directory, name: prefs?.profile?.name ?? directory)
        }
    }

    /// nil means the default browser.
    static var selectedDirectory: String? {
        get { UserDefaults.standard.string(forKey: defaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }
}
