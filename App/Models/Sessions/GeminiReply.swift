import Foundation
import OpenIslandCore

/// A Gemini CLI turn's reply as upstream's own Done card shows it (`AgentSession.completionAssistantMessageText`):
/// the hook's `prompt_response` (the last 8,000 characters, `lastAssistantMessageBody`), its last part after three
/// blank lines, less the copy of its end Gemini sometimes appends; else the 110-character preview. Upstream finds that
/// copy by comparing every tail with every earlier stretch, cubic in the reply's length: seconds to minutes for a
/// long reply, on every mapping (P152). This finds the same tail in one pass (a Z-array over the reversed text) and
/// otherwise follows upstream step for step. `GeminiReplyTests` hold it equal to upstream's on its fixtures.
enum GeminiReply {
    /// Upstream's shortest copy it removes, in non-blank characters.
    static let minimumRepeat = 30

    static func text(_ metadata: GeminiSessionMetadata) -> String? {
        if let body = metadata.lastAssistantMessageBody?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty,
           let reply = lastPart(of: body) {
            return reply
        }
        return metadata.lastAssistantMessage
    }

    /// Upstream's `extractGeminiCompletionBody`.
    static func lastPart(of body: String) -> String? {
        let normalized = normalizedBlankLines(body).replacingOccurrences(of: "\n{3,}", with: "\n\n\n", options: .regularExpression)
        let parts = normalized.components(separatedBy: "\n\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard let last = parts.last else { return nil }
        let kept = withoutRepeatedTail(last).trimmingCharacters(in: .whitespacesAndNewlines)
        return kept.isEmpty ? nil : kept
    }

    /// Upstream's `normalizeGeminiBlankLines`: CR and CRLF become LF, and a line of spaces an empty line.
    static func normalizedBlankLines(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces).isEmpty ? "" : $0 }
            .joined(separator: "\n")
    }

    /// Upstream's `removeRepeatedTrailingGeminiContent`: the text up to the longest tail (at least `minimumRepeat`
    /// non-blank characters) that also appears, whole and before it, earlier in the text, blanks ignored.
    static func withoutRepeatedTail(_ text: String) -> String {
        var characters: [Character] = []
        var indices: [String.Index] = []
        for index in text.indices where !text[index].isWhitespace {
            characters.append(text[index])
            indices.append(index)
        }
        guard characters.count >= minimumRepeat * 2, let start = repeatedTailStart(characters) else { return text }
        let boundary = adjustedBoundary(in: text, from: indices[start])
        return String(text[..<boundary]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Where the longest repeated tail starts, as upstream's `longestRepeatedGeminiTailStart` finds it: the longest
    /// length L ≤ n/2 whose last L characters equal L characters ending at or before n − L. Reversed, the tail is the
    /// text's first L characters, and a copy ending at n − i − … is a match at i with i ≥ L; the Z-array gives every
    /// match length at once, so the longest L is the largest min(Z[i], i).
    static func repeatedTailStart(_ characters: [Character]) -> Int? {
        let reversed = Array(characters.reversed())
        let z = zArray(reversed)
        var longest = 0
        for i in 1..<reversed.count { longest = max(longest, min(z[i], i)) }
        guard longest >= minimumRepeat else { return nil }
        return characters.count - longest
    }

    /// z[i]: how many characters from `i` on equal the text's first ones (z[0] is the whole count).
    static func zArray(_ s: [Character]) -> [Int] {
        let n = s.count
        var z = [Int](repeating: 0, count: n)
        guard n > 0 else { return z }
        z[0] = n
        var left = 0, right = 0
        for i in 1..<n {
            if i < right { z[i] = min(right - i, z[i - left]) }
            while i + z[i] < n, s[z[i]] == s[i + z[i]] { z[i] += 1 }
            if i + z[i] > right { left = i; right = i + z[i] }
        }
        return z
    }

    /// Upstream's `adjustedGeminiDuplicateBoundary`, unchanged: back over blanks, then to a paragraph break just before
    /// the copy when at most 12 non-blank characters lie between them.
    static func adjustedBoundary(in text: String, from index: String.Index) -> String.Index {
        var boundary = index
        while boundary > text.startIndex {
            let previous = text.index(before: boundary)
            guard text[previous].isWhitespace else { break }
            boundary = previous
        }
        var searchIndex = boundary
        while searchIndex > text.startIndex {
            let candidate = text.index(before: searchIndex)
            if text[candidate] != "\n" {
                searchIndex = candidate
                continue
            }
            var newlines = 1
            var probe = candidate
            while probe > text.startIndex {
                let previous = text.index(before: probe)
                if text[previous] == "\n" {
                    newlines += 1
                    probe = previous
                } else if text[previous].isWhitespace {
                    probe = previous
                } else {
                    break
                }
            }
            if newlines >= 2 {
                let between = text[searchIndex..<index].reduce(into: 0) { count, character in if !character.isWhitespace { count += 1 } }
                return between <= 12 ? searchIndex : boundary
            }
            searchIndex = candidate
        }
        return boundary
    }
}
