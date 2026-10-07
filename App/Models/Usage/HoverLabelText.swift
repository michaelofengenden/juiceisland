import AppKit
import JuiceCore

/// What the pointer (or keyboard focus) rests on in a usage block.
enum HoverTargetID: Hashable, Sendable {
    case account(String)
    case provider(Provider)
    case money(String)
}

/// A hover label: a name drawn 500 `ink`, then its parts with "·" separators.
struct HoverLabel: Equatable, Sendable {
    var name: String
    var parts: [String]
    var text: String { ([name] + parts).joined(separator: " · ") }
}

/// Full and short hover labels (prototype.md §3). Full labels are Juice §2.5 wording, straight from
/// `PanelModelBuilder`; short ones fit the Clean header slots (≈190 pt): name plus at most two parts that are not
/// already on screen, and never "read … ago" unless staleness is the news.
/// Owner: stream B. The island (D) reads it; B may refine the wording.
@MainActor
enum HoverLabelText {
    static func full(_ target: HoverTargetID, usage: any UsageModel) -> HoverLabel? {
        switch target {
        case let .account(id): usage.battery(id: id).map { split($0.hoverLabel, name: $0.alias) }
        case let .provider(provider): usage.row(provider).map { HoverLabel(name: provider.displayName, parts: $0.labelParts) }
        case let .money(id): usage.panel.money.first { $0.id == id }.map { split($0.hoverLabel) }
        }
    }

    static func short(_ target: HoverTargetID, usage: any UsageModel) -> HoverLabel? {
        switch target {
        case let .account(id):
            guard let battery = usage.battery(id: id) else { return nil }
            return HoverLabel(name: battery.alias, parts: accountParts(battery, record: usage.records[id], now: usage.now))
        case let .provider(provider):
            guard let row = usage.row(provider) else { return nil }
            var parts = ["\(row.availability.available) of \(row.availability.total) ready"]
            if let next = row.nextAlias { parts.append("next \(next)") }
            return HoverLabel(name: provider.displayName, parts: parts)
        case let .money(id):
            guard let row = usage.panel.money.first(where: { $0.id == id }) else { return nil }
            return HoverLabel(name: row.name, parts: usage.moneyDetails[id]?.shortParts ?? [])
        }
    }

    /// Drops parts from the end until the label fits `width` (never cuts a part, keeps at least one).
    static func fit(_ label: HoverLabel, width: CGFloat, fontSize: CGFloat = 11.5) -> HoverLabel {
        var fitted = label
        while fitted.parts.count > 1, measure(fitted, fontSize: fontSize) > width { fitted.parts.removeLast() }
        return fitted
    }

    static func measure(_ label: HoverLabel, fontSize: CGFloat = 11.5) -> CGFloat {
        let name = NSAttributedString(string: label.name, attributes: [.font: NSFont.systemFont(ofSize: fontSize, weight: .medium)])
        let rest = label.parts.map { " · " + $0 }.joined()
        let tail = NSAttributedString(string: rest, attributes: [.font: NSFont.systemFont(ofSize: fontSize)])
        return ceil(name.size().width + tail.size().width)
    }

    private static func split(_ text: String) -> HoverLabel {
        let parts = text.components(separatedBy: " · ")
        return HoverLabel(name: parts.first ?? text, parts: Array(parts.dropFirst()))
    }

    /// A battery's label, whose name can hold " · " itself ("sam · Research Lab", an organization's login, P580).
    static func split(_ text: String, name: String) -> HoverLabel {
        guard text.hasPrefix(name + " · ") else { return split(text) }
        return HoverLabel(name: name, parts: String(text.dropFirst(name.count + 3)).components(separatedBy: " · "))
    }

    /// A Codex login over 8 days old whose reads still work ends with the early word (P1553), the first part to go where
    /// room is short.
    private static func accountParts(_ battery: BatteryModel, record: AccountRecord?, now: Date) -> [String] {
        let parts = stateParts(battery, record: record, now: now)
        return battery.loginAging ? parts + [Rules.loginAgingWords] : parts
    }

    private static func stateParts(_ battery: BatteryModel, record: AccountRecord?, now: Date) -> [String] {
        // The reading as it stands now: a window past its reset is full until the next read (P460).
        let reading = record?.lastGood.map { Rules.current($0, now: now) }
        let tightest = reading.map(Rules.countedWindows)?.min { $0.percentLeft < $1.percentLeft }
        let resets = "resets " + Formatting.refillPhrase(tightest?.resetsAt, now: now)
        switch battery.state {
        case let .available(left, isLow):
            // Running out before the reset is the news (P125): it comes first, before "low".
            if let runOut = battery.runOut {
                return [UsageForecast.part(runOut, namedWindow: tightest?.displayLabel, now: now)]
                    + (runOut.window == tightest?.displayLabel ? [resets] : [])
            }
            // Then a window that reset since the read, until the next read replaces it (P460).
            if let reset = PanelModelBuilder.resetPart(reading, tightest: tightest, now: now) { return [reset, Rules.readingWord] }
            if isLow { return ["low", resets] }
            if left >= 100 { return ["full", "\(tightest?.displayLabel ?? "5h") window"] }
            return [resets]
        case let .usedUp(refill): return ["back " + Formatting.refillPhrase(refill, now: now)]
        case .stale:
            let read = record?.lastGood.map { "read " + Formatting.age(of: $0.readAt, now: now) } ?? "read ?"
            return ["stale", read]
        case .signInNeeded: return ["sign-in needed"]
        case .signingIn: return ["signing in"]
        case .unknown: return ["no reading yet"]
        case .noPlan: return ["no plan", "subscription ended?"]
        case .noLimits: return ["no limits", "billed by usage"]
        // Never "rate limited" (P1550): the short form, then what to do while there is room.
        case .loginLapsed: return [Rules.loginLapsedShort.lowercased(), "open Codex once"]
        }
    }
}
