import Foundation
import SwiftUI

/// What a session glyph says, whatever Settings › Island › Glyph style draws it with: running, delegating (the main turn
/// waits on its subagents), an approval or a question waiting, done, or idle. Pixel draws it with a `PixelGlyph`; Liquid
/// and Sand draw it with their own engines.
enum GlyphMood: String, CaseIterable, Sendable {
    case running, delegating, approval, question, done, idle

    init(_ glyph: PixelGlyph) {
        switch glyph {
        case .eq: self = .running
        case .agents: self = .delegating
        case .bang: self = .approval
        case .ques: self = .question
        case .check: self = .done
        // Liquid and Sand draw a failed turn as their done mood; its waiting tone says it needs you.
        case .cross: self = .done
        case .brand: self = .idle
        }
    }

    /// Whether the glyph asks for you: an approval or a question. Delegating does not: its helpers are at work.
    var needsYou: Bool { self == .approval || self == .question }
}

/// Delegating's rhythm, the same in every style: three helpers (Pixel's dots, Liquid's droplets, Sand's clumps) rise
/// and settle one after another, left to right, then all rest, once a `period`. Slower and calmer than running (whose
/// equalizer and crest move several times a second), it still moves, since the work goes on. A function of the clock
/// alone, so every delegating glyph steps in time and a re-created row carries on where it was.
enum HelperBeat {
    /// One round of the three hops and the rest after them.
    static let period: TimeInterval = 2.4
    /// How much of a period one hop takes (0.72 s), and how far each helper's hop starts after the one before it.
    static let hop = 0.3, stagger = 0.14
    /// How many helpers there are.
    static let count = 3
    /// Where in a period all three rest: the still frame's moment (renders, Reduce Motion).
    static let restPhase = 0.8

    /// How high helper `index` (0 … 2, left to right) is at `time`: 0 resting … 1 at the top of its hop, eased up and
    /// down (a squared sine, so it leaves and lands softly).
    nonisolated static func lift(at time: TimeInterval, index: Int) -> Double {
        let turns = time / period - Double(index) * stagger
        let phase = turns - turns.rounded(.down)
        guard phase < hop else { return 0 }
        let s = sin(.pi * phase / hop)
        return s * s
    }

    /// The clock time at which a still delegating glyph rests (all three helpers down), `offset` periods on.
    nonisolated static func stillTime(offset: Int = 0) -> TimeInterval { period * (restPhase + Double(offset)) }
}
