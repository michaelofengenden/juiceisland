import Foundation
import Observation

/// `forgotten.json`, next to accounts.json: the profile folders the owner told Settings › Accounts to forget, by folder
/// id (`Account.id`). A forgotten folder is out of the account list and is not offered with Add; naming it again under
/// "+" brings it back. Forgetting only hides: no folder and no file inside one is ever deleted or changed. Juice
/// Island's own file, like logins.json: standalone Juice never reads or writes it.
@MainActor
@Observable
public final class ForgottenFoldersStore {
    private struct File: Codable {
        var version: Int
        var folders: [String]
    }

    private struct SalvagedFile: Decodable {
        var folders: LossyArray<String>
    }

    public let fileURL: URL
    public private(set) var ids: Set<String> = []

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Reads the file, folder by folder; a missing or unreadable file leaves the list as it is.
    public func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let salvaged = try? JSONDecoder.juice.decode(SalvagedFile.self, from: data)
        if let salvaged { ids = Set(salvaged.folders.values) }
        StoreFile.noteLoss(fileURL, data: data, lost: salvaged?.folders.lost ?? 0, unreadable: salvaged == nil)
    }

    /// Written at once (a click in Settings), never over a file this build cannot read whole without keeping it first.
    public func save() throws {
        try StoreFile.write(JSONEncoder.juice.encode(File(version: 1, folders: ids.sorted())), to: fileURL, isReadable: Self.isReadable)
    }

    nonisolated static func isReadable(_ data: Data) -> Bool {
        (try? JSONDecoder.juice.decode(File.self, from: data)) != nil
    }

    public func contains(_ id: String) -> Bool { ids.contains(id) }

    /// The forgotten folder a name would bring back: the same provider and path, compared without case as the disk
    /// compares names.
    public func forgotten(provider: Provider, folder: String) -> String? {
        let wanted = Account.id(provider: provider, folder: folder).lowercased()
        return ids.first { $0.lowercased() == wanted }
    }

    public func forget(_ id: String) { ids.insert(id) }

    public func restore(_ id: String) { ids.remove(id) }
}
