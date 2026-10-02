import Foundation

public enum ProfileHookIntent: String, Codable, Sendable {
    case untouched
    case installed
    case removed
}

/// What the user last chose for a profile's hooks. Written by the Install and Remove buttons, and by a drift check
/// that first reads a profile complete (`HookDrift.recordedIntent`: its hooks were there, so losing them raises the
/// row). Never read to install anything: it lets Setup and the drift row tell "you removed these" from "missing".
public final class ProfileHookIntentStore: @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func intent(for targetID: String) -> ProfileHookIntent {
        defaults.string(forKey: Self.key(targetID)).flatMap(ProfileHookIntent.init(rawValue:)) ?? .untouched
    }

    public func setIntent(_ intent: ProfileHookIntent, for targetID: String) {
        defaults.set(intent.rawValue, forKey: Self.key(targetID))
    }

    static func key(_ targetID: String) -> String { "profileHooks.intent.\(targetID)" }
}
