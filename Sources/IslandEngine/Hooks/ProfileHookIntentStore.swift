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

    /// Juice turned on Codex's hooks switch in this profile's config.toml at Install, so Remove turns it off again once no
    /// hook is left (P910). Never set for a switch that was on before.
    public func codexFeatureTurnedOn(for targetID: String) -> Bool {
        defaults.bool(forKey: Self.featureKey(targetID))
    }

    public func setCodexFeatureTurnedOn(_ on: Bool, for targetID: String) {
        if on { defaults.set(true, forKey: Self.featureKey(targetID)) } else { defaults.removeObject(forKey: Self.featureKey(targetID)) }
    }

    static func featureKey(_ targetID: String) -> String { "profileHooks.codexFeature.\(targetID)" }

    /// What Install changed in a Codex profile's config.toml to turn the switch on, so Remove puts back exactly that
    /// (P910): whether Install made the file, and the switch's line it replaced (`codex_hooks = false`), nil when it
    /// added one. The line only, never the file: config.toml can hold other settings.
    public func codexSwitch(for targetID: String) -> CodexSwitchChange {
        CodexSwitchChange(createdFile: defaults.bool(forKey: Self.createdKey(targetID)),
                          replacedLine: defaults.string(forKey: Self.lineKey(targetID)))
    }

    public func setCodexSwitch(_ change: CodexSwitchChange?, for targetID: String) {
        if change?.createdFile == true { defaults.set(true, forKey: Self.createdKey(targetID)) } else { defaults.removeObject(forKey: Self.createdKey(targetID)) }
        if let line = change?.replacedLine { defaults.set(line, forKey: Self.lineKey(targetID)) } else { defaults.removeObject(forKey: Self.lineKey(targetID)) }
    }

    static func createdKey(_ targetID: String) -> String { "profileHooks.codexConfigCreated.\(targetID)" }
    static func lineKey(_ targetID: String) -> String { "profileHooks.codexSwitchLine.\(targetID)" }
}

/// What Install changed in config.toml to turn Codex's hooks switch on (`ProfileHookIntentStore.codexSwitch`).
public struct CodexSwitchChange: Equatable, Sendable {
    public var createdFile: Bool
    public var replacedLine: String?

    public init(createdFile: Bool = false, replacedLine: String? = nil) {
        self.createdFile = createdFile
        self.replacedLine = replacedLine
    }
}
