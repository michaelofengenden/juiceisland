import Foundation
import Observation

/// `accounts.json`: the monitored accounts in the user's order. Order within a provider is the order used for Next.
/// Read account by account (one this build cannot read, a provider it does not know, costs only itself), and written
/// like readings.json (`ReadingsStore`): only when it changed, through `writer` when one is set, never over a file this
/// build cannot read whole without keeping it first.
@MainActor
@Observable
public final class AccountsStore {
    public struct File: Codable, Sendable, Equatable {
        public var version: Int
        public var accounts: [Account]
    }

    private struct SalvagedFile: Decodable {
        var accounts: LossyArray<Account>
    }

    public let fileURL: URL
    public private(set) var accounts: [Account] = []
    /// Writes off the main thread when set; `save()` writes at once when nil.
    @ObservationIgnored public var writer: StoreWriter?
    /// What the file holds as far as this store knows; a save of the same is skipped.
    @ObservationIgnored private var saved: File?

    public nonisolated static var defaultFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        // Standalone Juice's folder in the private app; the public flavor's own (P820).
        return base.appendingPathComponent(AppFlavor.current.dataFolderName, isDirectory: true).appendingPathComponent("accounts.json")
    }

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public var exists: Bool { FileManager.default.fileExists(atPath: fileURL.path) }

    /// Reads the file: whole, or account by account. A missing or unreadable file leaves the list as it is.
    public func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        if let file = try? JSONDecoder.juice.decode(File.self, from: data) {
            accounts = file.accounts
            saved = file
            return
        }
        saved = nil
        let salvaged = try? JSONDecoder.juice.decode(SalvagedFile.self, from: data)
        if let salvaged { accounts = salvaged.accounts.values }
        StoreFile.noteLoss(fileURL, data: data, lost: salvaged?.accounts.lost ?? 0, unreadable: salvaged == nil)
    }

    public func save() throws {
        let file = File(version: 1, accounts: accounts)
        if file == saved, exists { return }
        if let writer {
            writer.write(fileURL, isReadable: Self.isReadable) { try JSONEncoder.juice.encode(file) }
        } else {
            try StoreFile.write(JSONEncoder.juice.encode(file), to: fileURL, isReadable: Self.isReadable)
        }
        saved = file
    }

    /// The file reads whole.
    nonisolated static func isReadable(_ data: Data) -> Bool {
        (try? JSONDecoder.juice.decode(File.self, from: data)) != nil
    }

    /// The accounts a file lists, account by account, off the main actor (the profile list's reload); none when it is
    /// missing or unreadable.
    public nonisolated static func accounts(in data: Data) -> [Account] {
        if let file = try? JSONDecoder.juice.decode(File.self, from: data) { return file.accounts }
        return (try? JSONDecoder.juice.decode(SalvagedFile.self, from: data))?.accounts.values ?? []
    }

    public func accounts(for provider: Provider) -> [Account] { accounts.filter { $0.provider == provider } }

    public func add(_ account: Account) {
        guard !accounts.contains(where: { $0.id == account.id }) else { return }
        accounts.append(account)
    }

    public func remove(id: String) { accounts.removeAll { $0.id == id } }

    public func rename(id: String, alias: String) { update(id) { $0.alias = alias } }
    public func setMonitored(id: String, _ monitored: Bool) { update(id) { $0.monitored = monitored } }
    public func setKnownEmail(id: String, _ email: String?) { update(id) { $0.knownEmail = email } }

    /// Reorders within one provider's group; offsets are relative to `accounts(for:)`.
    public func move(fromOffsets source: IndexSet, toOffset destination: Int, provider: Provider) {
        var group = accounts(for: provider)
        group.moveElements(fromOffsets: source, toOffset: destination)
        var groupIterator = group.makeIterator()
        accounts = accounts.map { $0.provider == provider ? (groupIterator.next() ?? $0) : $0 }
    }

    public func replaceAll(_ newAccounts: [Account]) { accounts = newAccounts }

    private func update(_ id: String, _ change: (inout Account) -> Void) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        change(&accounts[index])
    }
}

private extension Array {
    /// Same semantics as SwiftUI's `move(fromOffsets:toOffset:)`: the elements at `source` are removed and reinserted
    /// so that the first of them lands at `destination` as counted in the original array.
    mutating func moveElements(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.map { self[$0] }
        let shift = source.filter { $0 < destination }.count
        for offset in source.sorted(by: >) { remove(at: offset) }
        insert(contentsOf: moving, at: destination - shift)
    }
}
