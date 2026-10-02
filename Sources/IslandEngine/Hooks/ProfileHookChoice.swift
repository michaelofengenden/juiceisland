import Foundation

/// What Setup's one button does for a profile. Repair is Install on a profile whose hooks are there in part.
public enum ProfileHookAction: String, Equatable, Sendable {
    case install
    case repair
    case remove
}

/// Why a profile's button is unavailable: the same reasons, in the same order, as `ProfileHookManager`'s preflight,
/// so the button never offers what a click would refuse (spec §3.5, §4.5; P19, P22 to P25, P27).
public enum ProfileHookRefusal: Equatable, Sendable {
    case openIslandRunning
    case folderMissing
    case linkedConfig(file: String)
    case hasComments(file: String)
    case unreadable(file: String)
    case otherIslandHooks(count: Int)
    case helperMissing
    /// A click that got past the checks failed while writing (upstream's installer threw).
    case writeFailed

    /// The refusal a click's error stands for.
    public init(_ error: ProfileHookError) {
        switch error {
        case .openIslandAppRunning: self = .openIslandRunning
        case .folderMissing, .unknownProfile: self = .folderMissing
        case let .linkedConfig(file): self = .linkedConfig(file: file)
        case let .hasComments(file): self = .hasComments(file: file)
        case let .invalidConfig(file): self = .unreadable(file: file)
        case let .otherIslandHooksPresent(count): self = .otherIslandHooks(count: count)
        case .bundledHelperMissing: self = .helperMissing
        case .writeFailed: self = .writeFailed
        }
    }
}

/// The button a profile shows, and why it is unavailable when it is.
public struct ProfileHookChoice: Equatable, Sendable {
    /// nil when no action applies (a missing folder, a config nobody may touch).
    public let action: ProfileHookAction?
    /// nil when a click may go ahead.
    public let refusal: ProfileHookRefusal?

    public init(action: ProfileHookAction?, refusal: ProfileHookRefusal?) {
        self.action = action
        self.refusal = refusal
    }

    public var isAvailable: Bool { action != nil && refusal == nil }

    /// `setupState` is `HookDrift.setupState` of the same status, so a drifted profile offers Repair.
    public static func of(_ status: ProfileHookStatus, setupState: ProfileHookStatus.State, openIslandRunning: Bool,
                          helperPresent: Bool) -> ProfileHookChoice {
        let action: ProfileHookAction?
        switch setupState {
        case .notInstalled, .blockedByOtherIsland: action = .install
        case .partial, .broken, .codexFeatureOff: action = .repair
        case .installed, .codexNeedsTrust: action = .remove
        case .folderMissing, .linkedConfig, .hasComments, .unreadable: action = nil
        }
        let refusal: ProfileHookRefusal?
        if openIslandRunning {
            refusal = .openIslandRunning
        } else {
            switch setupState {
            case .folderMissing: refusal = .folderMissing
            case let .linkedConfig(file): refusal = .linkedConfig(file: file)
            case let .hasComments(file): refusal = .hasComments(file: file)
            case let .unreadable(file): refusal = .unreadable(file: file)
            default:
                if status.vibeEntryCount > 0 {
                    refusal = .otherIslandHooks(count: status.vibeEntryCount)
                } else if action != .remove, !helperPresent {
                    refusal = .helperMissing
                } else {
                    refusal = nil
                }
            }
        }
        return ProfileHookChoice(action: action, refusal: refusal)
    }
}
