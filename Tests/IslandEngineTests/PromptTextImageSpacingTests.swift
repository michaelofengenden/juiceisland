import Foundation
import Testing
@testable import IslandEngine
import OpenIslandCore

/// An image placeholder taken out of a prompt leaves one space, never a run of them on the row (P155). The existing
/// `PromptTextTests.remindersAndImagesAreTakenOut` pins the three spaces and changes with the fix.
struct PromptTextImageSpacingTests {
    @Test
    func anImagePlaceholderLeavesOneSpace() {
        #expect(PromptText.human("look at this [Image #17] [Image #18] please") == "look at this please")
    }
}
