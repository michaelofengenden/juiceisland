import Foundation
import Testing
@testable import JuiceCore

@MainActor
@Test func accountsStoreRoundTripsAndOrders() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("juice-accounts-\(UUID().uuidString).json")
    let store = AccountsStore(fileURL: file)
    #expect(!store.exists)
    store.add(Account(provider: .claude, folder: "/h/.claude", alias: "a"))
    store.add(Account(provider: .claude, folder: "/h/.claude-b", alias: "b"))
    store.add(Account(provider: .codex, folder: "/h/.codex", alias: "default"))
    store.add(Account(provider: .claude, folder: "/h/.claude", alias: "duplicate"))   // same folder: ignored
    #expect(store.accounts.count == 3)
    store.move(fromOffsets: IndexSet(integer: 1), toOffset: 0, provider: .claude)
    #expect(store.accounts(for: .claude).map(\.alias) == ["b", "a"])
    store.rename(id: Account.id(provider: .claude, folder: "/h/.claude"), alias: "main")
    store.setMonitored(id: Account.id(provider: .codex, folder: "/h/.codex"), false)
    try store.save()
    let reloaded = AccountsStore(fileURL: file)
    #expect(reloaded.exists)
    reloaded.load()
    #expect(reloaded.accounts(for: .claude).map(\.alias) == ["b", "main"])
    #expect(reloaded.accounts(for: .codex).first?.monitored == false)
    reloaded.remove(id: Account.id(provider: .claude, folder: "/h/.claude-b"))
    #expect(reloaded.accounts.count == 2)
}

@MainActor
@Test func moveHelperMatchesSwiftUISemantics() throws {
    func store(aliases: [String]) -> AccountsStore {
        let store = AccountsStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("juice-move-\(UUID().uuidString).json"))
        for alias in aliases { store.add(Account(provider: .claude, folder: "/h/.claude-\(alias)", alias: alias)) }
        return store
    }

    // [1,2,3] moving [1] to 0 -> [2,1,3]
    let one = store(aliases: ["a", "b", "c"])
    one.move(fromOffsets: IndexSet(integer: 1), toOffset: 0, provider: .claude)
    #expect(one.accounts(for: .claude).map(\.alias) == ["b", "a", "c"])

    // [1,2,3] moving [0] to 3 -> [2,3,1]
    let two = store(aliases: ["a", "b", "c"])
    two.move(fromOffsets: IndexSet(integer: 0), toOffset: 3, provider: .claude)
    #expect(two.accounts(for: .claude).map(\.alias) == ["b", "c", "a"])

    // [1,2,3,4] moving [0,1] to 4 -> [3,4,1,2]
    let three = store(aliases: ["a", "b", "c", "d"])
    three.move(fromOffsets: IndexSet([0, 1]), toOffset: 4, provider: .claude)
    #expect(three.accounts(for: .claude).map(\.alias) == ["c", "d", "a", "b"])
}
