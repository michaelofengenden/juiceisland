import AppIntents
import JuiceIslandUI

// The app's Focus filter (P1006, P1007), in the app targets themselves (project.yml's App/Main, and project-public.yml
// names this file for the public flavor), so Xcode writes it into the app's App Intents metadata and System Settings ›
// Focus lists the app under Focus filters. It is the one public way an app hears a Focus without the Communication
// Notifications entitlement `INFocusStatusCenter` needs (P333): no permission is asked, and nothing happens until the
// owner adds the filter to a Focus and turns Quiet on. macOS calls `perform()` with Quiet on as that Focus starts, and
// with the default (off) once it ends, which is why the default must be off. Everything it does is `FocusFilterState`'s,
// in JuiceIslandUI, where it is tested.

struct QuietFocusFilter: SetFocusFilterIntent {
    static let title: LocalizedStringResource = "Quiet the island"
    static let description: IntentDescription? = IntentDescription("No sounds or pop-ups while this Focus is on.")

    @Parameter(title: "Quiet", default: false)
    var quiet: Bool

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: quiet ? "Quiet" : "Sounds and pop-ups on")
    }

    /// Offered in a Focus's suggestions with Quiet on, so adding it is one click.
    static func suggestedFocusFilters(for context: FocusFilterSuggestionContext) async -> [QuietFocusFilter] {
        let filter = QuietFocusFilter()
        filter.quiet = true
        return [filter]
    }

    func perform() async throws -> some IntentResult {
        let quiet = quiet
        await MainActor.run { FocusFilterState.shared.apply(quiet: quiet) }
        return .result()
    }

    /// The filter in force now, read once at launch (`JuiceIslandApp.run`); nil when macOS does not say.
    @Sendable static func currentQuiet() async -> Bool? {
        guard let filter = try? await QuietFocusFilter.current else { return nil }
        return filter.quiet
    }
}
