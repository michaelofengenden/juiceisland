import AppKit

/// Dock icon rule (spec §4.5, P32): Window mode is a regular app; Island mode is an accessory unless "Show icon in
/// Dock" is on, or while the Settings (or app) window is open, so it is in front and reachable with ⌘Tab.
enum ActivationPolicyRule {
    static func policy(showAs: ShowAs, dockIconInIslandMode: Bool, auxiliaryWindowOpen: Bool) -> NSApplication.ActivationPolicy {
        if showAs == .window || dockIconInIslandMode || auxiliaryWindowOpen { return .regular }
        return .accessory
    }
}
