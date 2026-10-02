import Foundation
import JuiceCore

/// The app as its own text names it (P820): "Juice Island" in the private app, the public flavor's product name
/// ("Juice") there. Every window title, menu item and sentence that names the app reads `Product.name`, never a literal.
enum Product {
    static var flavor: AppFlavor { .current }
    static var name: String { flavor.productName }

    /// `~/Library/Application Support/<folder>`: the app's own files (`money.json`, the update's status files).
    static func supportFolder(_ flavor: AppFlavor = .current) -> URL {
        library.appendingPathComponent("Application Support/\(flavor.supportFolderName)", isDirectory: true)
    }

    /// `~/Library/Logs/<folder>`.
    static func logsFolder(_ flavor: AppFlavor = .current) -> URL {
        library.appendingPathComponent("Logs/\(flavor.logsFolderName)", isDirectory: true)
    }

    private static var library: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library", isDirectory: true)
    }
}
