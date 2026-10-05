import AppKit
import Foundation
import Testing
@testable import JuiceIslandUI

/// Settings › Island › Display (P940 to P944): the connected screens by their names and stable ids, Automatic and
/// Follow focus, an old made-up choice read as Automatic, the screen Follow focus picks from the window list, when the
/// island may follow, and the watch that hears it. Fake screens, windows and notification centers only.
@MainActor
@Suite(.serialized)
struct IslandDisplayTests {
    static let laptop = DIslandGeometryTests.laptop(CGSize(width: 1512, height: 982), notch: CGSize(width: 185, height: 32),
                                                    id: "LAPTOP-DISPLAY-UUID")
    static let studio = DIslandGeometryTests.external(CGRect(x: 1512, y: 0, width: 2560, height: 1440),
                                                      id: "STUDIO-DISPLAY-UUID")

    // MARK: The pop-up

    /// The list is the connected screens (P940): Automatic, Follow focus, then each screen by the name macOS gives it,
    /// a second of the same name numbered; a chosen screen that is away stays listed, and the island uses Automatic's.
    @Test func thePopUpListsTheConnectedScreens() {
        let screens = [DisplayInfo(id: "A", name: "Built-in Display"), DisplayInfo(id: "B", name: "DELL U2723QE"),
                       DisplayInfo(id: "C", name: "DELL U2723QE")]
        let choices = IslandDisplays.choices(screens, stored: nil)
        #expect(choices.map(\.0) == [nil, "follow-focus", "A", "B", "C"])
        #expect(choices.map(\.1) == ["Automatic", "Follow focus", "Built-in Display", "DELL U2723QE", "DELL U2723QE 2"])
        #expect(IslandDisplays.subtitle(screens, stored: nil) == nil)
        #expect(IslandDisplays.subtitle(screens, stored: "follow-focus") == "The screen with the active window.")
        #expect(IslandDisplays.subtitle(screens, stored: "B") == nil)

        let away = IslandDisplays.choices(Array(screens.prefix(1)), stored: "B")
        #expect(away.last?.0 == "B" && away.last?.1 == "Display not connected")
        #expect(IslandDisplays.subtitle(Array(screens.prefix(1)), stored: "B") == "On Automatic until it is back.")

        // One screen: no row, unless a choice other than Automatic waits on it.
        #expect(!IslandDisplays.showsRow(Array(screens.prefix(1)), stored: nil))
        #expect(IslandDisplays.showsRow(Array(screens.prefix(1)), stored: "follow-focus"))
        #expect(IslandDisplays.showsRow(screens, stored: nil))
        // Renders list the fixture, never this Mac's screens; the app swaps in the live list at launch.
        #expect(IslandDisplays.connected() == IslandDisplays.fixture)
    }

    /// The stored choice: nil is Automatic, "follow-focus" Follow focus, anything else a screen's id; the old pop-up's
    /// made-up ids, which no screen has, read as Automatic, so an owner who picked one is not left on a missing screen.
    @Test func theStoredChoiceReadsBackAndMadeUpScreensAreAutomatic() {
        #expect(IslandDisplayChoice(stored: nil) == .automatic && IslandDisplayChoice.automatic.stored == nil)
        #expect(IslandDisplayChoice(stored: "follow-focus") == .followFocus && IslandDisplayChoice.followFocus.stored == "follow-focus")
        #expect(IslandDisplayChoice(stored: "A") == .screen("A") && IslandDisplayChoice.screen("A").stored == "A")
        #expect(IslandDisplayChoice.reading("studio") == nil && IslandDisplayChoice.reading("built-in") == nil)
        #expect(IslandDisplayChoice.reading("A") == "A" && IslandDisplayChoice.reading(nil) == nil)

        let suite = "ji.test.display.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("studio", forKey: "ji.island.display")
        #expect(AppSettings(defaults: defaults).islandDisplay == nil)
        defaults.set(Self.studio.id, forKey: "ji.island.display")
        #expect(AppSettings(defaults: defaults).islandDisplay == Self.studio.id)
    }

    // MARK: Which screen

    /// A chosen screen while it is connected, else Automatic's (the notch's, else the first); Follow focus takes the
    /// screen heard, and Automatic's until one is heard (P38, P941).
    @Test func theResolverFollowsTheChoice() {
        let screens = [Self.studio, Self.laptop]
        #expect(IslandScreenResolver.resolve(screens, preferredID: nil) == Self.laptop)
        #expect(IslandScreenResolver.resolve(screens, preferredID: Self.studio.id) == Self.studio)
        #expect(IslandScreenResolver.resolve([Self.laptop], preferredID: Self.studio.id) == Self.laptop)
        #expect(IslandScreenResolver.resolve(screens, preferredID: "follow-focus", focusID: Self.studio.id) == Self.studio)
        #expect(IslandScreenResolver.resolve(screens, preferredID: "follow-focus", focusID: nil) == Self.laptop)
        #expect(IslandScreenResolver.resolve(screens, preferredID: "follow-focus", focusID: "gone") == Self.laptop)
        // Follow focus's id is never taken for a screen's.
        #expect(IslandScreenResolver.resolve([Self.studio, DIslandGeometryTests.external(.zero, id: "follow-focus")],
                                             preferredID: "follow-focus", focusID: nil) == Self.studio)
    }

    /// The active window is the frontmost app's frontmost normal window (level 0, shown, at least 64 pt a side), on the
    /// screen that holds most of it; none, and the island stays where it is. Core Graphics' coordinates: y down from
    /// the primary display's top.
    @Test func followFocusFindsTheScreenWithTheActiveWindow() {
        let screens = [Self.laptop, Self.studio]
        func window(_ pid: pid_t, _ rect: CGRect, layer: Int = 0, alpha: Double = 1) -> FullScreenProbe.Window {
            FullScreenProbe.Window(pid: pid, layer: layer, bounds: rect, alpha: alpha)
        }
        func screen(_ frontmost: pid_t?, _ windows: [FullScreenProbe.Window]) -> String? {
            FocusScreenProbe.screenID(frontmost: frontmost, windows: windows, screens: screens, primaryHeight: 982)
        }
        let onStudio = CGRect(x: 1700, y: 100, width: 900, height: 700)
        let onLaptop = CGRect(x: 100, y: 100, width: 900, height: 600)
        #expect(screen(42, [window(42, onStudio)]) == Self.studio.id)
        #expect(screen(42, [window(42, onLaptop), window(42, onStudio)]) == Self.laptop.id)
        // Across the seam: the screen with more of it.
        #expect(screen(42, [window(42, CGRect(x: 1300, y: 100, width: 600, height: 400))]) == Self.studio.id)
        #expect(screen(42, [window(42, CGRect(x: 1100, y: 100, width: 600, height: 400))]) == Self.laptop.id)
        // A panel, a hidden window, a palette or another app's window: skipped.
        #expect(screen(42, [window(42, onStudio, layer: 3), window(42, onLaptop)]) == Self.laptop.id)
        #expect(screen(42, [window(42, onStudio, alpha: 0), window(42, onLaptop)]) == Self.laptop.id)
        #expect(screen(42, [window(42, CGRect(x: 1700, y: 100, width: 40, height: 300)), window(42, onLaptop)]) == Self.laptop.id)
        #expect(screen(42, [window(7, onStudio)]) == nil)
        #expect(screen(nil, [window(42, onStudio)]) == nil)
        // Off every screen.
        #expect(screen(42, [window(42, CGRect(x: -5000, y: 100, width: 500, height: 500))]) == nil)
    }

    /// The island never moves out from under the owner: while it is open or the pointer is on it, it stays on its
    /// screen (if that is still connected); closed, it goes to the screen heard; before any is heard it stays put.
    @Test func followFocusWaitsWhileTheIslandIsHeld() {
        let screens = [Self.laptop, Self.studio]
        let laptop = Self.laptop.id, studio = Self.studio.id
        #expect(FocusScreenProbe.target(heard: studio, current: laptop, held: false, screens: screens) == studio)
        #expect(FocusScreenProbe.target(heard: studio, current: laptop, held: true, screens: screens) == laptop)
        #expect(FocusScreenProbe.target(heard: studio, current: "gone", held: true, screens: screens) == studio)
        #expect(FocusScreenProbe.target(heard: nil, current: laptop, held: false, screens: screens) == laptop)
        #expect(FocusScreenProbe.target(heard: nil, current: nil, held: false, screens: screens) == nil)
    }

    final class Heard {
        var screen: String?
        var probes = 0
        var changes: [String?] = []
    }

    /// The watch reads the window list at each notice (an app activated, the Space changed, the displays changed), tells
    /// a new screen once, keeps the last when no window is heard, and reads nothing after `stop()`. Nothing polls.
    @Test func theWatchHearsTheActiveWindowMove() async {
        _ = NSApplication.shared
        let heard = Heard()
        heard.screen = "A"
        let workspace = NotificationCenter(), local = NotificationCenter()
        let watch = FocusScreenWatch(workspace: workspace, local: local, settle: nil, probe: {
            heard.probes += 1
            return heard.screen
        }, changed: { heard.changes.append($0) })
        defer { watch.stop() }
        #expect(watch.screenID == "A" && heard.probes == 1 && heard.changes.isEmpty)

        heard.screen = "B"
        workspace.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        await QuietModeTests.settle { heard.changes.count == 1 }
        #expect(heard.changes == ["B"] && watch.screenID == "B")

        heard.screen = nil
        workspace.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        await QuietModeTests.settle { heard.probes >= 3 }
        #expect(heard.changes == ["B"] && watch.screenID == "B")

        heard.screen = "A"
        local.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        await QuietModeTests.settle { heard.changes.count == 2 }
        #expect(heard.changes == ["B", "A"])

        watch.stop()
        heard.screen = "B"
        workspace.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(heard.changes == ["B", "A"] && heard.probes == 4)
    }

    /// A Space's windows are listed once its slide has ended: each notice reads again `settle` later.
    @Test func aNoticeIsReadAgainOnceTheSpaceHasSettled() async {
        _ = NSApplication.shared
        let heard = Heard()
        heard.screen = "A"
        let workspace = NotificationCenter(), local = NotificationCenter()
        let watch = FocusScreenWatch(workspace: workspace, local: local, settle: 0.05, probe: {
            heard.probes += 1
            return heard.screen
        }, changed: { heard.changes.append($0) })
        defer { watch.stop() }
        workspace.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        await QuietModeTests.settle { heard.probes == 2 }
        heard.screen = "B"
        await QuietModeTests.settle { heard.changes == ["B"] }
        #expect(heard.changes == ["B"] && heard.probes == 3)
    }
}
