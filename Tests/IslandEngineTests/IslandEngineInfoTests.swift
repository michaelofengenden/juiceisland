import Testing
@testable import IslandEngine

@Test func vendorVersionIsPinned() {
    #expect(IslandEngineInfo.vendorVersion == "1.2.1")
    #expect(IslandEngineInfo.vendorCommit == "b50f87aa7d58af1478837d48909eb68baa37f9b9")
}
