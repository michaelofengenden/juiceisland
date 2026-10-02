import Foundation

/// Which app this build is (P820): the owner's private Juice Island, or the public download, Juice. Read from the
/// bundle's Info.plist, where only the public flavor's project (`project-public.yml`) writes `JIFlavor` = `public`. A
/// bundle without it is the private flavor, and its names are exactly the ones every build used before the public
/// flavor existed: the app and its dev build, its widget, `swift test` and the renders.
///
/// The public flavor keeps everything of its own: its folders are named by its bundle id, so it never reads or writes
/// the private app's `Juice` and `Juice Island` folders, and its text names its product. What hooks share with Open
/// Island and the private app (the helper's path, the bridge socket, the context note's folder) stays as it is: only one
/// island app owns the hook socket at a time (spec §5.3).
public struct AppFlavor: Equatable, Sendable {
    public enum Kind: String, Sendable { case `private`, `public` }

    public var kind: Kind
    /// The name the app's text uses: "Juice Island", or the public flavor's product name ("Juice").
    public var productName: String
    /// The public flavor's bundle id (its folders, its log); nil for the private flavor, whose names are fixed.
    public var bundleIdentifier: String?
    /// The public repository, `owner/name` (`JIPublicRepo`, from `PUBLIC_REPO` at build time): About links to its
    /// source, as the GPL asks. nil for the private flavor.
    public var publicRepo: String?

    public static let infoKey = "JIFlavor"
    public static let productNameKey = "JIProductName"
    public static let publicRepoKey = "JIPublicRepo"
    public static let privateProductName = "Juice Island"
    public static let publicProductName = "Juice"

    public init(kind: Kind, productName: String, bundleIdentifier: String? = nil, publicRepo: String? = nil) {
        self.kind = kind
        self.productName = productName
        self.bundleIdentifier = bundleIdentifier
        self.publicRepo = publicRepo
    }

    /// From an Info.plist dictionary: the public flavor only with `JIFlavor` = `public` and a bundle id, its name from
    /// `JIProductName` (else "Juice"); anything else is the private flavor.
    public init(info: [String: Any]?) {
        guard (info?[Self.infoKey] as? String) == Kind.public.rawValue,
              let id = (info?["CFBundleIdentifier"] as? String).flatMap({ $0.isEmpty || $0.contains("$(") ? nil : $0 }) else {
            self = .private
            return
        }
        func value(_ key: String) -> String? { (info?[key] as? String).flatMap { $0.isEmpty || $0.contains("$(") ? nil : $0 } }
        let repo = value(Self.publicRepoKey).flatMap { Self.isRepo($0) ? $0 : nil }
        self.init(kind: .public, productName: value(Self.productNameKey) ?? Self.publicProductName, bundleIdentifier: id,
                  publicRepo: repo)
    }

    public static let `private` = AppFlavor(kind: .private, productName: privateProductName)

    /// This process's flavor (the widget extension reads its own Info.plist, which says the same).
    public static let current = AppFlavor(info: Bundle.main.infoDictionary)

    public var isPublic: Bool { kind == .public }

    /// The folder in Application Support that holds `accounts.json`, `readings.json` and the other usage stores: the
    /// private app's is standalone Juice's own `Juice` (spec §8 decision 10), the public flavor's is named by its bundle id.
    public var dataFolderName: String { publicName ?? "Juice" }
    /// The folder in Application Support for the app's own files (`money.json`, the update's status files).
    public var supportFolderName: String { publicName ?? Self.privateProductName }
    /// The folder in `~/Library/Logs`.
    public var logsFolderName: String { publicName ?? Self.privateProductName }
    /// The unified log's subsystem (`JuiceLog`).
    public var logSubsystem: String { publicName ?? "com.ofengenden.juice" }

    /// The repository's page on GitHub, where its source is.
    public var sourceURL: URL? { publicRepo.flatMap { URL(string: "https://github.com/\($0)") } }

    /// `owner/name`, GitHub's letters only.
    public static func isRepo(_ text: String) -> Bool {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }
        }
    }

    private var publicName: String? { isPublic ? bundleIdentifier : nil }
}
