import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The README's demo GIF (P1576, P1579), written with ImageIO alone: no third-party tool, no screen capture. The frames
/// come in as sRGB pixels. One palette of at most 255 colours is fitted to them all (one index stays free for the
/// transparency ImageIO gives the pixels a frame leaves as they were), no two in one cell of the grid ImageIO's GIF
/// writer quantizes on (5 bits a channel), so ImageIO keeps every colour as it is. Each frame is mapped onto it: flat
/// areas, edges and text to the nearest colour, gentle gradients as two colours in a fixed 4 × 4 ordered pattern (the
/// same pattern every frame, so what stands still stays the same pixels and costs nothing). Frames that come out the
/// same are joined into one longer frame, and ImageIO writes them with their delays, looping forever. Given the same
/// frames it writes the same bytes.
enum DemoGIF {
    /// sRGB pixels, 8 bits a channel, four bytes a pixel (the fourth ignored), rows top first.
    struct Pixels: Equatable {
        var width: Int
        var height: Int
        var bytes: [UInt8]
    }

    /// A frame in a palette's colours: one index a pixel, rows top first.
    struct Indexed: Equatable {
        var width: Int
        var height: Int
        var indices: [UInt8]
    }

    /// One frame of the GIF and how long it shows, in hundredths of a second.
    struct Frame: Equatable {
        var image: Indexed
        var centiseconds: Int
    }

    struct Colour: Hashable {
        var r: UInt8
        var g: UInt8
        var b: UInt8
        var key: Int { Int(r) << 16 | Int(g) << 8 | Int(b) }
        init(r: UInt8, g: UInt8, b: UInt8) { (self.r, self.g, self.b) = (r, g, b) }
        init(key: Int) { self.init(r: UInt8(key >> 16 & 0xFF), g: UInt8(key >> 8 & 0xFF), b: UInt8(key & 0xFF)) }
        /// Its cell in ImageIO's grid: 5 bits a channel.
        var cell: Int { Int(r >> 3) << 10 | Int(g >> 3) << 5 | Int(b >> 3) }
    }

    /// The most colours a palette may hold: GIF's 256 less ImageIO's transparent index.
    static let maxColours = 255

    // MARK: Delays

    /// Hundredths of a second for each of `count` frames sampled `fps` a second: frame i shows from i / fps to
    /// (i + 1) / fps, rounded so the delays add up to the reel's own length (30 a second: 3, 4, 3, 3, 4, 3…).
    static func delays(count: Int, fps: Int) -> [Int] {
        (0..<count).map { i in
            Int((Double(100 * (i + 1)) / Double(fps)).rounded()) - Int((Double(100 * i) / Double(fps)).rounded())
        }
    }

    // MARK: Palette

    /// The colours of many frames, counted: every second pixel each way of each frame added.
    final class Histogram {
        private var counts = [UInt32](repeating: 0, count: 1 << 24)
        private(set) var sampled = 0

        func add(_ frame: Pixels) {
            var sampled = 0
            counts.withUnsafeMutableBufferPointer { counts in
                frame.bytes.withUnsafeBufferPointer { bytes in
                    for y in stride(from: 0, to: frame.height, by: 2) {
                        var i = y * frame.width * 4
                        for _ in stride(from: 0, to: frame.width, by: 2) {
                            counts[Int(bytes[i]) << 16 | Int(bytes[i + 1]) << 8 | Int(bytes[i + 2])] &+= 1
                            sampled += 1
                            i += 8
                        }
                    }
                }
            }
            self.sampled += sampled
        }

        /// At most `limit` colours fitted to what was added: the colours that each cover a large flat area (the island's
        /// black, the notch, a card's white button) exactly as they are, the rest by median cut and a few rounds of
        /// k-means, so a small mark (a glyph's pink, Claude's orange) keeps a colour of its own.
        func palette(limit: Int = maxColours) -> [Colour] {
            precondition(limit >= 2 && limit <= 256)
            // Exact colours that cover at least 0.4 % of what was sampled (flat fills), the largest first, at most a tenth
            // of the palette; then the rest by ImageIO's cells, each at its own mean and weighing the square root of its
            // count, so a small mark is not outweighed by the wallpaper.
            var flat: [(key: Int, count: UInt32)] = []
            var bins = [BinSum](repeating: BinSum(), count: 1 << 15)
            let flatFloor = UInt32(max(1, sampled / 250))
            counts.withUnsafeBufferPointer { counts in
                for key in 0..<(1 << 24) where counts[key] >= flatFloor { flat.append((key, counts[key])) }
            }
            flat.sort { $0.count > $1.count || ($0.count == $1.count && $0.key < $1.key) }
            flat = Array(flat.prefix(limit / 10))
            let fixed = Set(flat.map(\.key))
            counts.withUnsafeBufferPointer { counts in
                bins.withUnsafeMutableBufferPointer { bins in
                    for key in 0..<(1 << 24) where counts[key] > 0 && !fixed.contains(key) {
                        let count = UInt64(counts[key])
                        let r = key >> 16 & 0xFF, g = key >> 8 & 0xFF, b = key & 0xFF
                        let bin = (r >> 3) << 10 | (g >> 3) << 5 | (b >> 3)
                        bins[bin].count += count
                        bins[bin].r += count * UInt64(r)
                        bins[bin].g += count * UInt64(g)
                        bins[bin].b += count * UInt64(b)
                    }
                }
            }
            var points: [WeightedPoint] = []
            for bin in bins where bin.count > 0 {
                let n = Double(bin.count)
                points.append(WeightedPoint(r: Double(bin.r) / n, g: Double(bin.g) / n, b: Double(bin.b) / n, weight: n.squareRoot()))
            }
            let fixedPoints = flat.map { entry -> (Double, Double, Double) in
                let c = Colour(key: entry.key)
                return (Double(c.r), Double(c.g), Double(c.b))
            }
            let free = max(0, limit - fixedPoints.count)
            var centres = DemoGIF.medianCut(points, boxes: min(free, points.count))
            centres = DemoGIF.kMeans(points, centres: centres, fixed: fixedPoints, rounds: 4)
            // One colour a cell of ImageIO's grid, the flat fills first: ImageIO's GIF writer puts the colours of each
            // cell (5 bits a channel) together at their mean, so a second colour in a cell would move them both.
            var palette: [Colour] = []
            var cells = Set<Int>()
            let colours = flat.map { Colour(key: $0.key) } + centres.map { centre in
                Colour(r: UInt8(max(0, min(255, centre.0.rounded()))), g: UInt8(max(0, min(255, centre.1.rounded()))),
                       b: UInt8(max(0, min(255, centre.2.rounded()))))
            }
            for var colour in colours where cells.insert(colour.cell).inserted {
                // ImageIO keeps pure black and pure white for the darkest and the lightest cells, whatever else is there.
                if colour.cell == 0 { colour = Colour(r: 0, g: 0, b: 0) }
                if colour.cell == Colour(r: 255, g: 255, b: 255).cell { colour = Colour(r: 255, g: 255, b: 255) }
                palette.append(colour)
            }
            return palette
        }
    }

    /// At most `limit` colours fitted to `frames` (`Histogram.palette`).
    static func palette(_ frames: [Pixels], limit: Int = maxColours) -> [Colour] {
        let histogram = Histogram()
        for frame in frames { histogram.add(frame) }
        return histogram.palette(limit: limit)
    }

    fileprivate struct BinSum {
        var count: UInt64 = 0
        var r: UInt64 = 0
        var g: UInt64 = 0
        var b: UInt64 = 0
    }

    fileprivate struct WeightedPoint {
        var r: Double
        var g: Double
        var b: Double
        var weight: Double
        func channel(_ c: Int) -> Double { c == 0 ? r : c == 1 ? g : b }
    }

    /// Splits the points into `boxes` boxes, each time the box whose weighted spread is largest, along its widest channel
    /// at its weighted median; each box's centre is its weighted mean.
    fileprivate static func medianCut(_ points: [WeightedPoint], boxes: Int) -> [(Double, Double, Double)] {
        guard boxes > 0, !points.isEmpty else { return [] }
        struct Box {
            var lower: Int
            var upper: Int
            var weight = 0.0
            var channel = 0
            var score = -1.0
            init(_ points: [WeightedPoint], _ lower: Int, _ upper: Int) {
                (self.lower, self.upper) = (lower, upper)
                var low = [Double.infinity, .infinity, .infinity], high = [-Double.infinity, -.infinity, -.infinity]
                for i in lower..<upper {
                    let p = points[i]
                    weight += p.weight
                    low[0] = min(low[0], p.r); high[0] = max(high[0], p.r)
                    low[1] = min(low[1], p.g); high[1] = max(high[1], p.g)
                    low[2] = min(low[2], p.b); high[2] = max(high[2], p.b)
                }
                var widest = -1.0
                for c in 0..<3 where high[c] - low[c] > widest { (channel, widest) = (c, high[c] - low[c]) }
                score = upper - lower < 2 ? -1 : widest * widest * weight
            }
        }
        var all = points
        var list = [Box(all, 0, all.count)]
        while list.count < boxes {
            var index = -1, best = 0.0
            for (i, box) in list.enumerated() where box.score > best { (index, best) = (i, box.score) }
            guard index >= 0 else { break }
            let box = list[index], channel = box.channel
            var slice = Array(all[box.lower..<box.upper])
            slice.sort { a, b in
                let x = a.channel(channel), y = b.channel(channel)
                return x < y || (x == y && (a.r, a.g, a.b) < (b.r, b.g, b.b))
            }
            all.replaceSubrange(box.lower..<box.upper, with: slice)
            var running = 0.0, cut = box.lower + 1
            for i in box.lower..<box.upper {
                running += all[i].weight
                if running >= box.weight / 2 { cut = max(box.lower + 1, min(box.upper - 1, i + 1)); break }
            }
            list[index] = Box(all, box.lower, cut)
            list.append(Box(all, cut, box.upper))
        }
        return list.map { box in
            var r = 0.0, g = 0.0, b = 0.0
            for i in box.lower..<box.upper {
                r += all[i].r * all[i].weight
                g += all[i].g * all[i].weight
                b += all[i].b * all[i].weight
            }
            return (r / box.weight, g / box.weight, b / box.weight)
        }
    }

    /// Lloyd's rounds: each point goes to its nearest centre (the fixed ones included, which never move), each free
    /// centre moves to its points' weighted mean.
    fileprivate static func kMeans(_ points: [WeightedPoint], centres start: [(Double, Double, Double)], fixed: [(Double, Double, Double)],
                               rounds: Int) -> [(Double, Double, Double)] {
        guard !start.isEmpty else { return start }
        let free = start.count
        // Every centre in one flat list, the free ones first: r, g, b.
        var flat = (start + fixed).flatMap { [$0.0, $0.1, $0.2] }
        let total = free + fixed.count
        for _ in 0..<rounds {
            var sums = [Double](repeating: 0, count: free * 4)
            flat.withUnsafeBufferPointer { c in
                sums.withUnsafeMutableBufferPointer { sums in
                    for point in points {
                        var best = 0, bestDistance = Double.infinity
                        var k = 0
                        while k < total {
                            let dr = point.r - c[3 * k], dg = point.g - c[3 * k + 1], db = point.b - c[3 * k + 2]
                            let d = 2 * dr * dr + 4 * dg * dg + 3 * db * db
                            if d < bestDistance { (best, bestDistance) = (k, d) }
                            k += 1
                        }
                        guard best < free else { continue }
                        sums[4 * best] += point.r * point.weight
                        sums[4 * best + 1] += point.g * point.weight
                        sums[4 * best + 2] += point.b * point.weight
                        sums[4 * best + 3] += point.weight
                    }
                }
            }
            for i in 0..<free where sums[4 * i + 3] > 0 {
                flat[3 * i] = sums[4 * i] / sums[4 * i + 3]
                flat[3 * i + 1] = sums[4 * i + 1] / sums[4 * i + 3]
                flat[3 * i + 2] = sums[4 * i + 2] / sums[4 * i + 3]
            }
        }
        return (0..<free).map { (flat[3 * $0], flat[3 * $0 + 1], flat[3 * $0 + 2]) }
    }

    // MARK: Mapping

    /// A palette with its nearest-colour answers kept, so each exact colour is looked up once across every frame.
    final class Mapper {
        let palette: [Colour]
        private var nearest: [UInt8]
        /// For a colour between two of the palette's: the second, and how far toward it the colour lies (0 to 254; 255:
        /// not worked out yet).
        private var second: [UInt8]
        private var toward: [UInt8]

        init(palette: [Colour]) {
            precondition(!palette.isEmpty && palette.count <= 255)
            self.palette = palette
            nearest = [UInt8](repeating: 255, count: 1 << 24)
            second = [UInt8](repeating: 0, count: 1 << 24)
            toward = [UInt8](repeating: 255, count: 1 << 24)
        }

        /// The palette's index nearest `key` (an exact sRGB colour).
        func index(_ key: Int) -> Int {
            let known = nearest[key]
            if known != 255 { return Int(known) }
            let r = Int(key >> 16 & 0xFF), g = Int(key >> 8 & 0xFF), b = Int(key & 0xFF)
            var best = 0, bestDistance = Int.max
            for (i, c) in palette.enumerated() {
                let dr = r - Int(c.r), dg = g - Int(c.g), db = b - Int(c.b)
                let d = 2 * dr * dr + 4 * dg * dg + 3 * db * db
                if d < bestDistance { (best, bestDistance) = (i, d) }
            }
            nearest[key] = UInt8(best)
            return best
        }

        /// The two palette colours `key` lies between, and how far toward the second (0 to 254): the nearest, and of
        /// the colours beyond `key` from it, the one whose mix with the nearest comes closest to `key` while standing
        /// out least (the next colour along a gradient, not a near one off to its side or a far one in a few dots).
        func pair(_ key: Int) -> (first: Int, second: Int, toward: Int) {
            let first = index(key)
            let known = toward[key]
            if known != 255 { return (first, Int(second[key]), Int(known)) }
            let r = Double(key >> 16 & 0xFF), g = Double(key >> 8 & 0xFF), b = Double(key & 0xFF)
            let p = palette[first]
            let er = r - Double(p.r), eg = g - Double(p.g), eb = b - Double(p.b)
            var best = first, bestDistance = Double.infinity, bestAmount = 0.0
            for (i, c) in palette.enumerated() where i != first {
                let qr = Double(c.r) - Double(p.r), qg = Double(c.g) - Double(p.g), qb = Double(c.b) - Double(p.b)
                let along = 2 * er * qr + 4 * eg * qg + 3 * eb * qb, length = 2 * qr * qr + 4 * qg * qg + 3 * qb * qb
                // Only a colour on the far side of this one from the nearest.
                guard along > 0, length > 0 else { continue }
                let t = min(1, along / length)
                let dr = er - t * qr, dg = eg - t * qg, db = eb - t * qb
                // How far the mix's average is from the colour, and how much the mix's two colours stand out from each
                // other where they meet (a far colour in a few dots is noise).
                let d = 2 * dr * dr + 4 * dg * dg + 3 * db * db + t * (1 - t) * length
                if d < bestDistance { (best, bestDistance, bestAmount) = (i, d, t) }
            }
            let amount = best == first ? 0 : Int((254 * bestAmount).rounded())
            second[key] = UInt8(best)
            toward[key] = UInt8(amount)
            return (first, best, amount)
        }

        /// `pixels` in the palette's colours. An edge (a step of more than `smooth` to a neighbour: text, a border) and a
        /// colour the palette has take the nearest colour; so does a flat fill. A colour on a gentle gradient (the
        /// wallpaper, a blur: within `reach` pixels the colour changes, by no more than `smooth`) is drawn as its two
        /// nearest palette colours in a fixed 4 × 4 ordered pattern, in the proportion that averages to it, so a gradient
        /// has no bands. The pattern is the same in every frame, so what stands still stays the same pixels.
        func map(_ pixels: Pixels, smooth: Int = 10, reach: Int = 8) -> Indexed {
            let w = pixels.width, h = pixels.height
            var out = [UInt8](repeating: 0, count: w * h)
            // Thresholds of the 4 × 4 Bayer matrix, in 254ths, each at its cell's middle.
            let bayer = [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5].map { (2 * $0 + 1) * 254 / 32 }
            pixels.bytes.withUnsafeBufferPointer { src in
                out.withUnsafeMutableBufferPointer { dst in
                    for y in 0..<h {
                        for x in 0..<w {
                            let i = (y * w + x) * 4
                            let r = Int(src[i]), g = Int(src[i + 1]), b = Int(src[i + 2])
                            let key = r << 16 | g << 8 | b
                            let first = index(key)
                            let c = palette[first]
                            guard Int(c.r) != r || Int(c.g) != g || Int(c.b) != b else {
                                dst[y * w + x] = UInt8(first)
                                continue
                            }
                            // The largest step to a neighbour, and the largest change within `reach`, on any channel.
                            var step = 0, change = 0
                            if x > 0 { step = max(step, Self.step(src, i - 4, r, g, b)) }
                            if x < w - 1 { step = max(step, Self.step(src, i + 4, r, g, b)) }
                            if y > 0 { step = max(step, Self.step(src, i - 4 * w, r, g, b)) }
                            if y < h - 1 { step = max(step, Self.step(src, i + 4 * w, r, g, b)) }
                            if x >= reach { change = max(change, Self.step(src, i - 4 * reach, r, g, b)) }
                            if x < w - reach { change = max(change, Self.step(src, i + 4 * reach, r, g, b)) }
                            if y >= reach { change = max(change, Self.step(src, i - 4 * w * reach, r, g, b)) }
                            if y < h - reach { change = max(change, Self.step(src, i + 4 * w * reach, r, g, b)) }
                            let gradient = step <= smooth && change > 0 && change <= smooth
                            guard gradient else {
                                dst[y * w + x] = UInt8(first)
                                continue
                            }
                            let mix = pair(key)
                            dst[y * w + x] = UInt8(mix.toward > bayer[(y & 3) * 4 + (x & 3)] ? mix.second : mix.first)
                        }
                    }
                }
            }
            return Indexed(width: w, height: h, indices: out)
        }

        @inline(__always) private static func step(_ src: UnsafeBufferPointer<UInt8>, _ j: Int, _ r: Int, _ g: Int, _ b: Int) -> Int {
            max(abs(Int(src[j]) - r), abs(Int(src[j + 1]) - g), abs(Int(src[j + 2]) - b))
        }
    }

    /// Joins each frame that comes out the same as the one before it into that one, its delay added.
    static func joined(_ frames: [Frame]) -> [Frame] {
        var out: [Frame] = []
        for frame in frames {
            if let last = out.last, last.image == frame.image {
                out[out.count - 1].centiseconds += frame.centiseconds
            } else {
                out.append(frame)
            }
        }
        return out
    }

    // MARK: Writing

    /// The GIF's bytes: every frame (palette colours only) with its delay, looping forever. ImageIO keeps each frame's
    /// colours exactly when they number 256 or fewer, and writes only the rectangle of each frame that changed.
    static func encode(_ frames: [Frame], palette: [Colour]) throws -> Data {
        guard let first = frames.first else { throw EncodeError.noFrames }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, frames.count, nil) else {
            throw EncodeError.noDestination
        }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for frame in frames {
            guard frame.image.width == first.image.width, frame.image.height == first.image.height else { throw EncodeError.sizes }
            let image = try cgImage(rgbx(frame.image, palette: palette))
            let seconds = Double(frame.centiseconds) / 100
            CGImageDestinationAddImage(destination, image, [kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: seconds, kCGImagePropertyGIFUnclampedDelayTime: seconds,
            ]] as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { throw EncodeError.finalize }
        return data as Data
    }

    /// `image` in its palette's colours, four bytes a pixel.
    static func rgbx(_ image: Indexed, palette: [Colour]) -> Pixels {
        var bytes = [UInt8](repeating: 255, count: image.indices.count * 4)
        bytes.withUnsafeMutableBufferPointer { out in
            image.indices.withUnsafeBufferPointer { indices in
                for i in 0..<indices.count {
                    let c = palette[Int(indices[i])]
                    out[4 * i] = c.r
                    out[4 * i + 1] = c.g
                    out[4 * i + 2] = c.b
                }
            }
        }
        return Pixels(width: image.width, height: image.height, bytes: bytes)
    }

    /// An opaque sRGB image of `pixels` (no alpha, so ImageIO keeps each frame over the last and writes only what
    /// changed).
    static func cgImage(_ pixels: Pixels) throws -> CGImage {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB), let provider = CGDataProvider(data: Data(pixels.bytes) as CFData),
              let image = CGImage(width: pixels.width, height: pixels.height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: pixels.width * 4, space: space,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider,
                                  decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { throw EncodeError.image }
        return image
    }

    /// `image`'s pixels in sRGB, four bytes a pixel, the fourth 255.
    static func pixels(_ image: CGImage) throws -> Pixels {
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { throw EncodeError.image }
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: w, height: h))
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { throw EncodeError.image }
        for i in stride(from: 3, to: bytes.count, by: 4) { bytes[i] = 255 }
        return Pixels(width: w, height: h, bytes: bytes)
    }

    /// Where two frames differ: how many pixels, and the first one's place and colours (nil: none, and the same size).
    /// A failing check says this, never the frames themselves.
    static func difference(_ a: Pixels, _ b: Pixels) -> String? {
        guard a.width == b.width, a.height == b.height, a.bytes.count == b.bytes.count else {
            return "sizes \(a.width)×\(a.height) and \(b.width)×\(b.height)"
        }
        var count = 0, first = -1
        a.bytes.withUnsafeBufferPointer { x in
            b.bytes.withUnsafeBufferPointer { y in
                var i = 0
                while i < x.count {
                    if x[i] != y[i] || x[i + 1] != y[i + 1] || x[i + 2] != y[i + 2] {
                        count += 1
                        if first < 0 { first = i }
                    }
                    i += 4
                }
            }
        }
        guard count > 0 else { return nil }
        let p = first / 4
        let (one, other) = (Array(a.bytes[first..<first + 3]), Array(b.bytes[first..<first + 3]))
        return "\(count) pixels, the first at (\(p % a.width), \(p / a.width)): \(one) and \(other)"
    }

    /// What a GIF says of itself: its size, its loop count, and each frame's delay in hundredths of a second, read back
    /// with ImageIO.
    struct Summary: Equatable {
        var width: Int
        var height: Int
        var loopCount: Int?
        var delays: [Int]
        var seconds: Double { Double(delays.reduce(0, +)) / 100 }
    }

    static func summary(_ data: Data) -> Summary? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              let first = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        let file = CGImageSourceCopyProperties(source, nil) as? [CFString: Any]
        let loop = (file?[kCGImagePropertyGIFDictionary] as? [CFString: Any])?[kCGImagePropertyGIFLoopCount] as? Int
        var delays: [Int] = []
        for i in 0..<CGImageSourceGetCount(source) {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let seconds = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0
            delays.append(Int((seconds * 100).rounded()))
        }
        return Summary(width: first[kCGImagePropertyPixelWidth] as? Int ?? 0, height: first[kCGImagePropertyPixelHeight] as? Int ?? 0,
                       loopCount: loop, delays: delays)
    }

    /// Each frame as a browser shows it (ImageIO composites each over the last), in sRGB.
    static func decodedFrames(_ data: Data) throws -> [Pixels] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { throw EncodeError.image }
        return try (0..<CGImageSourceGetCount(source)).map { i in
            guard let image = CGImageSourceCreateImageAtIndex(source, i, nil) else { throw EncodeError.image }
            return try pixels(image)
        }
    }

    /// What a GIF carries besides its pictures: how many comment blocks, and each application block's name. Read from
    /// the bytes (ImageIO says neither).
    struct Structure: Equatable {
        var comments = 0
        var applications: [String] = []
        var frames = 0
    }

    static func structure(_ data: Data) -> Structure? {
        let d = [UInt8](data)
        guard d.count > 13, d[0] == 0x47, d[1] == 0x49, d[2] == 0x46 else { return nil }
        var pos = 13
        if d[10] & 0x80 != 0 { pos += 3 * (1 << (Int(d[10] & 7) + 1)) }
        var out = Structure()
        func skipBlocks() -> Bool {
            while pos < d.count, d[pos] != 0 { pos += Int(d[pos]) + 1 }
            pos += 1
            return pos <= d.count
        }
        while pos < d.count {
            switch d[pos] {
            case 0x21:
                guard pos + 2 < d.count else { return nil }
                let label = d[pos + 1]
                pos += 2
                if label == 0xFE { out.comments += 1 }
                if label == 0xFF, pos + 12 <= d.count {
                    out.applications.append(String(decoding: d[(pos + 1)..<(pos + 12)], as: UTF8.self))
                }
                guard skipBlocks() else { return nil }
            case 0x2C:
                guard pos + 10 <= d.count else { return nil }
                let flags = d[pos + 9]
                pos += 10
                if flags & 0x80 != 0 { pos += 3 * (1 << (Int(flags & 7) + 1)) }
                pos += 1
                guard skipBlocks() else { return nil }
                out.frames += 1
            case 0x3B:
                return out
            default:
                return nil
            }
        }
        return nil
    }

    enum EncodeError: Error { case noFrames, noDestination, sizes, image, finalize }
}
