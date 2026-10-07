import Darwin
import Foundation
import ImageIO
import Testing

/// The public README as a product page (wave 10, P1587 to P1599): every image and link it and the page it links to
/// (`PRIVACY.md`) name is a file of the public repository, every `#anchor` is a heading there, and the words keep the house
/// style. Here the pages are `docs/public/README.md` and `docs/public/PRIVACY.md`, and a published path is found through
/// the export's `put` and `license` rules; in the public repository they are `README.md` and `docs/PRIVACY.md`, and the
/// paths are its own.
struct ReadmePageTests {
    static let root = ReadmeAgentGridTests.root
    static var isPrivateTree: Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent("docs/public/README.md").path) }

    /// Each public page: its path in the public repository, and its file in this tree.
    static func pages() -> [(published: String, file: URL)] {
        let pages = ["README.md", "docs/PRIVACY.md"]
        return pages.map { published in
            (published, isPrivateTree ? root.appendingPathComponent(source(ofPublished: published) ?? published) : root.appendingPathComponent(published))
        }
    }

    /// The file in this tree the export publishes at `published` (`put` and `license` rules; a `put` to a folder keeps the
    /// name and must match its pattern), or `published` itself in the public repository. nil when no rule puts it there.
    static func source(ofPublished published: String) -> String? {
        guard isPrivateTree else { return published }
        let rules = (try? String(contentsOf: root.appendingPathComponent("scripts/export-public.rules"), encoding: .utf8)) ?? ""
        for line in rules.components(separatedBy: "\n") {
            let fields = line.split(separator: " ").map(String.init)
            guard fields.count >= 3, fields[0] == "put" || fields[0] == "license" else { continue }
            let (pattern, dest) = (fields[1], fields[2])
            if dest.hasSuffix("/") {
                guard published.hasPrefix(dest) else { continue }
                let name = String(published.dropFirst(dest.count))
                let candidate = (pattern as NSString).deletingLastPathComponent + "/" + name
                if !name.contains("/"), fnmatch(pattern, candidate, 0) == 0 { return candidate }
            } else if dest == published {
                return pattern
            }
        }
        return nil
    }

    /// The targets a page names: Markdown links and images, `src`, `href` and `srcset`.
    static func targets(in text: String) throws -> [String] {
        let markdown = try Regex(#"\]\(([^)\s]+)\)"#), html = try Regex(#"(?:src|href|srcset)="([^"]+)""#)
        return (text.matches(of: markdown) + text.matches(of: html)).compactMap { $0.output[1].substring.map(String.init) }
    }

    /// GitHub's anchor for a heading: lower case, spaces as hyphens, punctuation gone.
    static func anchor(_ heading: String) -> String {
        String(heading.lowercased().compactMap { $0 == " " ? "-" : ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : nil) })
    }

    /// A published path as GitHub resolves `target` from `page` (relative to the page's folder; a raw URL of the public
    /// repository's main branch is its path there). nil for any other web address.
    static func published(_ target: String, from page: String) -> String? {
        if target.hasPrefix("https://raw.githubusercontent.com/") {
            // https:, raw.githubusercontent.com, then owner and name (one `@PUBLIC_REPO@` before the export fills it in),
            // main, the path.
            var parts = target.split(separator: "/").map(String.init).dropFirst(2)
            parts = parts.first == "@PUBLIC_REPO@" ? parts.dropFirst() : parts.dropFirst(2)
            guard parts.first == "main", parts.count > 1 else { return "" }
            return parts.dropFirst().joined(separator: "/")
        }
        guard !target.contains("://"), !target.hasPrefix("#"), !target.hasPrefix("mailto:") else { return nil }
        let folder = (page as NSString).deletingLastPathComponent
        let joined = folder.isEmpty ? target : folder + "/" + target
        var parts: [String] = []
        for part in joined.split(separator: "/").map(String.init) {
            if part == ".." { if !parts.isEmpty { parts.removeLast() } } else if part != "." { parts.append(part) }
        }
        return parts.joined(separator: "/")
    }

    @Test func everyImageAndLinkIsAFileOfThePublicRepository() throws {
        for (page, file) in Self.pages() {
            let text = try String(contentsOf: file, encoding: .utf8)
            let targets = try Self.targets(in: text)
            #expect(!targets.isEmpty, "\(page) names nothing")
            for target in targets {
                guard let path = Self.published(target, from: page) else { continue }
                let source = try #require(Self.source(ofPublished: path), "\(page): \(target) is published by no rule")
                #expect(FileManager.default.fileExists(atPath: Self.root.appendingPathComponent(source).path), "\(page): \(target) (\(source)) is missing")
            }
        }
    }

    @Test func everyAnchorIsAHeadingOfItsPage() throws {
        for (page, file) in Self.pages() {
            let text = try String(contentsOf: file, encoding: .utf8)
            let headings = Set(text.components(separatedBy: "\n").filter { $0.hasPrefix("#") }.map {
                Self.anchor(String($0.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces))
            })
            for target in try Self.targets(in: text) where target.hasPrefix("#") {
                #expect(headings.contains(String(target.dropFirst())), "\(page): \(target) is no heading")
            }
        }
    }

    /// The README's images: each shown at half its pixels or less, so it is sharp on a 2x screen, and all of them together
    /// small enough that GitHub shows the page without a wait.
    @Test func theReadmeShowsItsImagesSharpAndLight() throws {
        let (page, file) = try #require(Self.pages().first)
        let text = try String(contentsOf: file, encoding: .utf8)
        let images = try Regex(#"<img src="([^"]+)"[^>]* width="([0-9]+)""#)
        var total = 0
        for match in text.matches(of: images) {
            let target = try #require(match.output[1].substring.map(String.init)), width = Int(match.output[2].substring ?? "") ?? 0
            let source = try #require(Self.published(target, from: page).flatMap(Self.source(ofPublished:)))
            let url = Self.root.appendingPathComponent(source)
            guard let image = imageSize(url) else {
                Issue.record("\(target) does not open")
                continue
            }
            #expect(image.width >= 2 * width, "\(target) is \(image.width) px wide, shown at \(width): not sharp at 2x")
            total += image.bytes
        }
        #expect(total < 12_000_000, "the README's images are \(total / 1_000_000) MB")
    }

    /// The hero's icon is the app's own: the asset catalog's 256-pixel icon, drawn one for one (`ReadmeProductRenders.icon`),
    /// so a new icon from `scripts/make-icon.swift` fails here until the README's is drawn again (P1593).
    @Test func theReadmeIconIsTheAppsIcon() throws {
        let readme = try #require(Self.source(ofPublished: "docs/images/readme-icon.png"))
        let shown = try #require(pixels(Self.root.appendingPathComponent(readme)), "no readme-icon.png")
        let app = try #require(pixels(Self.root.appendingPathComponent("App/Main/Resources/Assets.xcassets/AppIcon.appiconset/icon_128x128@2x.png")))
        #expect(shown.count == app.count)
        let difference = zip(shown, app).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
        #expect(Double(difference) / Double(max(app.count, 1)) < 2, "the README's icon is not the app's: draw it again")
    }

    /// Plain words: no em or en dash, no emoji, and no word a product page uses in place of a fact.
    @Test func thePagesKeepTheHouseStyle() throws {
        let fluff = ["blazing", "seamless", "effortless", "powerful", "revolutionary", "best-in-class", "magic", "simply"]
        for (page, file) in Self.pages() {
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(!text.contains("\u{2014}") && !text.contains("\u{2013}"), "\(page) has a dash")
            #expect(!text.unicodeScalars.contains { $0.properties.isEmojiPresentation }, "\(page) has an emoji")
            for word in fluff { #expect(!text.lowercased().contains(word), "\(page) says \(word)") }
        }
    }
}

/// An image file's pixel width and its size on disk; nil when it does not open as an image.
private func imageSize(_ url: URL) -> (width: Int, bytes: Int)? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? Int,
          let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int
    else { return nil }
    return (width, bytes)
}

/// An image's pixels as 8-bit RGBA, premultiplied, in sRGB at its own size; nil when it does not open.
private func pixels(_ url: URL) -> [UInt8]? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
          let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
    var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let drawn = data.withUnsafeMutableBytes { buffer -> Bool in
        guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: image.width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return true
    }
    return drawn ? data : nil
}
