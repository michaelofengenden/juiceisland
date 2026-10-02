import Foundation
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// Settings › Island › Needs you colour (P780 to P784): Pink by default, Violet, or Orange as it was; each colour far from
/// every other colour a glyph or a mark shows and clear on the pure black; the widget carrying it.
@MainActor
struct NeedsYouColourTests {
    typealias C = GlassContrast

    /// Every needs-you colour and its tint, by name, for the contrast suites.
    static var colours: [(String, Color)] {
        NeedsYouColour.allCases.flatMap { [("wait \($0)", $0.wait), ("question \($0)", $0.question)] }
    }

    /// The colours a glyph or a mark shows besides what needs you: the states, the brand, and the agents the owner runs.
    static let others: [(String, String)] = [
        ("run", "#4e80ed"), ("done", "#6fb982"), ("delegate", "#2ba6a4"), ("stalled", "#b39263"), ("brand", "#ffb45c"),
        ("Claude", "#d97757"), ("Claude running", "#d96a5a"), ("Codex", "#5ac8fa"), ("OpenCode", "#c8c8ce"), ("Grok", "#5ee6d8"),
    ]

    static func hex(_ colour: Color) -> String { GlassGlyphTests.hex(colour, .dark).lowercased() }

    @Test func theSettingIsPinkByDefaultStoredAndRead() throws {
        #expect(AppSettings.ephemeral().needsYouColour == .pink)
        #expect(NeedsYouColour.allCases == [.pink, .violet, .orange] && NeedsYouColour.allCases.map(\.title) == ["Pink", "Violet", "Orange"])
        #expect(EnvironmentValues().needsYouColour == .pink)
        let suite = "needs-you-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(AppSettings(defaults: defaults).needsYouColour == .pink)
        let settings = AppSettings(defaults: defaults)
        for choice in NeedsYouColour.allCases {
            settings.needsYouColour = choice
            #expect(defaults.string(forKey: AppSettings.Key.needsYouColour) == choice.rawValue)
            #expect(AppSettings(defaults: defaults).needsYouColour == choice)
        }
        #expect(AppSettings.Key.needsYouColour == "ji.island.needsYouColour")
        // A word this build does not know reads as Pink.
        defaults.set("teal", forKey: AppSettings.Key.needsYouColour)
        #expect(AppSettings(defaults: defaults).needsYouColour == .pink)
    }

    /// Each choice's two colours; Orange is the island's waiting orange and its question tint, exactly.
    @Test func eachChoiceIsOneHueAtTwoLightnesses() {
        #expect(Self.hex(NeedsYouColour.pink.wait) == "#ed68af" && Self.hex(NeedsYouColour.pink.question) == "#f58ac3")
        #expect(Self.hex(NeedsYouColour.violet.wait) == "#bd7aff" && Self.hex(NeedsYouColour.violet.question) == "#d4a8ff")
        #expect(NeedsYouColour.orange.wait == Color(hex: 0xE97B36) && NeedsYouColour.orange.question == Color(hex: 0xF0A35E))
        for choice in NeedsYouColour.allCases {
            let a = C.components(choice.wait), b = C.components(choice.question)
            let (h1, _, l1) = GlassTone.hsl(a.r, a.g, a.b), (h2, _, l2) = GlassTone.hsl(b.r, b.g, b.b)
            #expect(min(abs(h1 - h2), 1 - abs(h1 - h2)) < 0.02 && l2 > l1 + 0.05, "\(choice)")
        }
    }

    /// Pink and Violet sit at least CIEDE2000 20 from every other colour a glyph or a mark shows (Orange sat 8.9 from
    /// Claude's terracotta, which is why it moved), and hold 4.5:1 on the pure black, a word's ratio, not only a mark's
    /// 3:1. The table is printed for the report.
    @Test func pinkAndVioletStandApartAndReadOnBlack() {
        var lines: [String] = []
        for choice in [NeedsYouColour.pink, .violet] {
            for (name, colour) in [("wait", choice.wait), ("question", choice.question)] {
                let hex = Self.hex(colour)
                let distances = Self.others.map { ($0.0, CIEDE2000.distance(hex, $0.1)) }.sorted { $0.1 < $1.1 }
                for (other, distance) in distances { #expect(distance >= 20, "\(choice) \(name) \(hex) from \(other): \(distance)") }
                let onBlack = C.ratio(C.luminance(colour), 0)
                #expect(onBlack >= 4.5, "\(choice) \(name) on black: \(onBlack)")
                lines.append("\(choice) \(name) \(hex) \(String(format: "%.2f:1", onBlack)): "
                             + distances.map { "\($0.0) \(String(format: "%.1f", $0.1))" }.joined(separator: ", "))
            }
        }
        print("needs-you distances:\n" + lines.joined(separator: "\n"))
        // Before: the orange read as Claude's.
        #expect(CIEDE2000.distance("#e97b36", "#d97757") < 9)
    }

    /// A stalled turn's dim amber stays the quieter word: under 60 % of every needs-you colour's chroma, and far from
    /// Pink and Violet in hue as well (P312).
    @Test func stalledStaysQuieterThanWhatNeedsYou() {
        func chroma(_ hex: String) -> Double { let lab = CIEDE2000.lab(hex); return hypot(lab.a, lab.b) }
        let stalled = "#b39263"
        for choice in NeedsYouColour.allCases {
            #expect(chroma(stalled) < chroma(Self.hex(choice.wait)) * 0.6, "\(choice)")
            if choice != .orange { #expect(CIEDE2000.distance(stalled, Self.hex(choice.wait)) > 40, "\(choice)") }
        }
    }

    /// On Glass and Solid, light and dark: a glyph draws the colour at full strength (its edge carries it, P590); a word
    /// takes Glass's text twin, 4.5:1 on each look's worst surface and 4:1 on a veil; a mark that is not a glyph its mark
    /// twin, 3:1; each keeps the colour's hue (P562).
    @Test(arguments: NeedsYouColour.allCases)
    func glassAndSolidKeepTheGlyphRules(_ choice: NeedsYouColour) {
        let p = IslandPalette.glass
        #expect(GlyphPalette.glyph(agent: .codex, state: .waiting, mode: .byState, needsYou: choice) == choice.wait)
        for look in [ColorScheme.light, .dark] {
            let word = C.worstAdaptedRatio(p.toneText(choice.wait), look)
            #expect(word >= C.text, "\(choice) \(look) word: \(word)")
            for fill in GlassVeil.judged { #expect(C.worstAdaptedRatio(p.toneText(choice.wait), look, fills: [fill]) >= C.textOnFill) }
            #expect(C.worstAdaptedRatio(p.tone(choice.wait), look) >= C.mark, "\(choice) \(look) mark")
            let a = C.components(choice.wait), b = C.components(p.toneText(choice.wait), look)
            let (h1, s1, _) = GlassTone.hsl(a.r, a.g, a.b), (h2, s2, _) = GlassTone.hsl(b.r, b.g, b.b)
            #expect(min(abs(h1 - h2), 1 - abs(h1 - h2)) < 0.01 && abs(s1 - s2) < 0.02, "\(choice) \(look): hue moved")
        }
    }

    /// Everything that says "needs you" takes the choice: the glyph, the status words, a limit's word, the tint, the
    /// selected option; under Orange each is what it drew before.
    @Test(arguments: NeedsYouColour.allCases)
    func everythingThatSaysNeedsYouTakesTheChoice(_ choice: NeedsYouColour) {
        #expect(GlyphPalette.glyph(agent: .claude, state: .waiting, mode: .byAgent, needsYou: choice) == choice.wait)
        #expect(IslandRowColours.word(.approval, needsYou: choice) == choice.wait && IslandRowColours.word(.question, needsYou: choice) == choice.wait)
        #expect(StateTint.needsYou.colour(choice) == choice.wait)
        #expect(IslandPalette.black.optionBadgeSelected(choice) == choice.wait)
        #expect(IslandPalette.glass.optionBadgeSelected(choice) == GlassTone.adapted(choice.wait))
        // Black's edge on Core Animation's outline: the light takes a new choice while what needs you shows.
        let edge = IslandStateEdgeLayers()
        edge.show(.needsYou, animated: false)
        let other = NeedsYouColour.allCases.first { $0 != choice }!
        edge.setNeedsYou(other)
        edge.setNeedsYou(choice)
        let want = IslandStateEdgeLayers.colours(.needsYou, edge: edge.edge, needsYou: choice)
        #expect((edge.light.colors as? [CGColor])?.map(\.components) == want.map(\.components))
        // A fade-out already under way ends in the colour it began in.
        edge.show(nil)
        edge.setNeedsYou(other)
        let fading = IslandStateEdgeLayers.colours(nil, fading: .needsYou, edge: edge.edge, needsYou: choice)
        #expect((edge.light.colors as? [CGColor])?.map(\.components) == fading.map(\.components))
        // The selected option's edge on Glass and Solid: the light look's mark twin at 50 %, the dark the colour at 40 %.
        let border = IslandPalette.glass.optionSelectedBorder(choice)
        #expect(border == IslandPalette.glass.optionSelectedBorder(choice) && IslandPalette.black.optionSelectedBorder(choice) == choice.wait.opacity(0.4))
        let light = C.components(border, .light), dark = C.components(border, .dark), twin = C.components(GlassTone.nudged(choice.wait, .light))
        #expect(light.r == twin.r && light.g == twin.g && light.b == twin.b && abs(light.a - 0.5) < 0.001 && abs(dark.a - 0.4) < 0.001)
    }

    /// The veil keeps one twin pair per choice (its cache is keyed by it), and Orange's is the one State tint drew before.
    @Test func theVeilIsTheChoicesOwn() {
        let veils = NeedsYouColour.allCases.map { StateTint.needsYou.veil(needsYou: $0) }
        #expect(Set(veils.map { C.components($0, .light).r }).count == 3)
        let orange = NeedsYouColour.orange.wait
        let before = Color.adaptive(light: StateTint.twin(orange, .light).opacity(StateTint.veilLight),
                                    dark: StateTint.twin(orange, .dark).opacity(StateTint.veilDark))
        for look in [ColorScheme.light, .dark] {
            let a = C.components(StateTint.needsYou.veil(needsYou: .orange), look), b = C.components(before, look)
            #expect(a.r == b.r && a.g == b.g && a.b == b.b && a.a == b.a)
        }
        #expect(StateTint.finished.veil(needsYou: .pink) == StateTint.finished.veil(needsYou: .violet))
    }

    /// The widget draws what the app wrote (P783): the choice in its snapshot, Pink for an older file, and a new choice
    /// reloads it at once.
    @Test func theWidgetCarriesTheChoice() throws {
        let settings = AppSettings.ephemeral()
        settings.needsYouColour = .violet
        let snapshot = WidgetSnapshot.make(.demo(settings: settings), at: Date(timeIntervalSince1970: 0))
        let json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        #expect(json["needsYouColour"] as? String == "violet")
        #expect(snapshot.needsYou == .violet)
        var older = snapshot
        older.needsYouColour = nil
        #expect(older.needsYou == .pink && older.urgentKey != snapshot.urgentKey)
        let decoded = try JSONDecoder().decode(WidgetSnapshot.self, from: JSONEncoder().encode(older))
        #expect(decoded.needsYou == .pink)
    }

    /// No orange of the old pair is left anywhere in the app's views but the Orange choice itself.
    @Test func theOldOrangeLivesOnlyInItsChoice() throws {
        let app = RenderHarness.root.appendingPathComponent("App")
        let files = try #require(FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil)?.allObjects as? [URL])
            .filter { $0.pathExtension == "swift" }
        #expect(files.count > 100)
        for file in files where file.lastPathComponent != "NeedsYouColour.swift" {
            let source = try String(contentsOf: file, encoding: .utf8).uppercased()
            for hex in ["E97B36", "F0A35E"] { #expect(!source.contains(hex), "\(file.lastPathComponent): \(hex)") }
        }
    }
}
