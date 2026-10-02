import Foundation

/// The usage model the app runs: one small decision, so the live readers can only ever start in the release identity.
enum UsageModelKind: Equatable, Sendable {
    /// JuiceCore's readers in the app (`LiveUsageModel`), writing standalone Juice's store.
    case live
    /// Standalone Juice's `accounts.json` and `readings.json`, read only (`JuiceReadingsUsageModel`).
    case juiceReadings
    /// Fictional accounts (`DemoUsageModel`).
    case demo

    static func choose(identity: AppIdentity, source: UsageSource) -> UsageModelKind {
        switch source {
        case .demo: .demo
        case .juiceReadings: identity == .production ? .live : .juiceReadings
        }
    }
}

extension UsageSource {
    /// The Usage source pop-up's words: in the release build Juice's readings are the app's own.
    func title(in identity: AppIdentity) -> String {
        switch (self, identity) {
        case (.juiceReadings, .production): "Live"
        default: title
        }
    }
}
