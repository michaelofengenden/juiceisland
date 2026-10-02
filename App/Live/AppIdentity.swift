import Foundation
import JuiceCore

/// Which build this is, from its bundle id (spec §5.3, §7 amendment 7, §8 decisions 10 and 11).
/// - `production` (`com.ofengenden.juice`, the release build): the owner's island. It reads accounts itself, Live
///   sessions is on by default and there is no demo feed.
/// - `development` (`com.ofengenden.juice.dev`): mirrors standalone Juice's files read-only; Live sessions stays off
///   until the owner turns it on, and the demo sessions show meanwhile.
/// - `other` (tests, renders, a stray build): treated like a development build, and it never reads an account.
///
/// The public flavor (Juice, `AppFlavor`, P820) is a release build too: its own bundle id, read from its own Info.plist,
/// is `production` there and nowhere else, so the private app's ids keep their meaning in every build.
enum AppIdentity: Equatable, Sendable {
    case production, development, other

    static let productionBundleIdentifier = "com.ofengenden.juice"
    static let developmentBundleIdentifier = "com.ofengenden.juice.dev"

    init(bundleIdentifier: String?, flavor: AppFlavor = .current) {
        switch bundleIdentifier {
        case Self.productionBundleIdentifier: self = .production
        case Self.developmentBundleIdentifier: self = .development
        case let id? where flavor.isPublic && id == flavor.bundleIdentifier: self = .production
        default: self = .other
        }
    }

    static var current: AppIdentity { AppIdentity(bundleIdentifier: Bundle.main.bundleIdentifier) }

    /// Live sessions' default until the owner sets the switch.
    var liveSessionsByDefault: Bool { self == .production }
    /// Fixture sessions while Live sessions is off: every build but production, which shows nothing it did not see.
    var showsDemoSessions: Bool { self != .production }
}
