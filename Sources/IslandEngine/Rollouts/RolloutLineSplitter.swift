import Foundation

/// Cuts a rollout's bytes into lines in one pass (P83). Each chunk is searched once for newlines, a line that ends in
/// the chunk it began in is decoded straight from it, and only a line's unfinished part is copied, once, into
/// `pending`. A line longer than `maxLineLength` is dropped as it streams and never held whole.
///
/// Upstream's `extractCompleteLines` searched the whole buffer again after every 64 KB read and copied the rest of
/// it after every line it took, so one multi-megabyte line (an image, a long tool output) cost time in the square
/// of its length, and a first pass over a 3 GB rollout never ended.
struct RolloutLineSplitter {
    let maxLineLength: Int
    /// The bytes of the line not yet ended; empty while a line is skipped.
    private(set) var pending = Data()
    /// The line not yet ended is dropped up to its newline: it grew past `maxLineLength`, or a read began inside it.
    private(set) var isSkipping: Bool
    /// Lines dropped for their length.
    private(set) var skippedLineCount = 0

    /// `skippingFirstLine` drops everything up to the first newline: a read that begins inside a line.
    init(maxLineLength: Int, skippingFirstLine: Bool = false) {
        self.maxLineLength = maxLineLength
        self.isSkipping = skippingFirstLine
    }

    /// Hands every line that ends in `chunk` to `line`, without its newline; empty lines are left out, as upstream
    /// leaves them out.
    mutating func feed(_ chunk: Data, line: (String) -> Void) {
        chunk.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            guard let base = bytes.baseAddress else { return }
            let count = bytes.count
            var start = 0
            while start < count, let hit = memchr(base + start, 0x0A, count - start) {
                let end = base.distance(to: UnsafeRawPointer(hit))
                let piece = UnsafeRawBufferPointer(start: base + start, count: end - start)
                if isSkipping {
                    isSkipping = false
                } else if pending.isEmpty {
                    if piece.count > maxLineLength {
                        skippedLineCount += 1
                    } else if !piece.isEmpty {
                        line(String(decoding: piece, as: UTF8.self))
                    }
                } else if pending.count + piece.count > maxLineLength {
                    pending = Data()
                    skippedLineCount += 1
                } else {
                    pending.append(contentsOf: piece)
                    line(String(decoding: pending, as: UTF8.self))
                    pending = Data()
                }
                start = end + 1
            }
            guard start < count, !isSkipping else { return }
            if pending.count + (count - start) > maxLineLength {
                pending = Data()
                isSkipping = true
                skippedLineCount += 1
            } else {
                pending.append(contentsOf: UnsafeRawBufferPointer(start: base + start, count: count - start))
            }
        }
    }
}

/// Whether `line` holds `pattern`, compared byte for byte. `String.contains` walks characters, which on a line of
/// several megabytes took most of the tracker's start.
func rolloutLine(_ line: String, contains pattern: String) -> Bool {
    var line = line
    var pattern = pattern
    return line.withUTF8 { bytes in
        pattern.withUTF8 { needle in
            guard let base = bytes.baseAddress, let needleBase = needle.baseAddress else { return needle.isEmpty }
            return memmem(base, bytes.count, needleBase, needle.count) != nil
        }
    }
}
