import AppKit
import SwiftUI

/// The prototype's inline SVG icons, drawn from their own markup (as `ProviderMarkView` does), cached per string.
/// `template` icons use `currentColor` and take their colour from `foregroundStyle`; coloured icons keep their fills.
@MainActor
enum SVGIconCache {
    private static var cache: [String: NSImage] = [:]

    static func image(_ svg: String, template: Bool) -> NSImage {
        let key = (template ? "t:" : "c:") + svg
        if let image = cache[key] { return image }
        var markup = template ? svg.replacingOccurrences(of: "currentColor", with: "#000") : svg
        if !markup.contains("xmlns=") { markup = markup.replacingOccurrences(of: "<svg ", with: "<svg xmlns=\"http://www.w3.org/2000/svg\" ") }
        let image = NSImage(data: Data(markup.utf8)) ?? NSImage(size: NSSize(width: 16, height: 16))
        image.isTemplate = template
        cache[key] = image
        return image
    }
}

/// One SVG icon at its own point size.
struct SVGIcon: View {
    let svg: String
    let size: CGSize
    var colour: Color? = nil

    var body: some View {
        if let colour {
            Image(nsImage: SVGIconCache.image(svg, template: true))
                .renderingMode(.template)
                .resizable()
                .interpolation(.high)
                .foregroundStyle(colour)
                .frame(width: size.width, height: size.height)
        } else {
            Image(nsImage: SVGIconCache.image(svg, template: false))
                .resizable()
                .interpolation(.high)
                .frame(width: size.width, height: size.height)
        }
    }
}

/// The window chrome icons (prototype L1366-1368, L1654-1658), `currentColor` template SVGs.
enum ChromeIcon {
    static let window = #"<svg width="15" height="12" viewBox="0 0 15 13"><rect x=".75" y=".75" width="13.5" height="11.5" rx="2.2" fill="none" stroke="currentColor" stroke-width="1.3"/><path d="M1 4h13" stroke="currentColor" stroke-width="1.3"/></svg>"#
    static let notch = #"<svg width="17" height="12" viewBox="0 0 18 13"><rect x=".75" y=".75" width="16.5" height="11.5" rx="2.5" fill="none" stroke="currentColor" stroke-width="1.3"/><path d="M5.5 1h7v1.6a1.6 1.6 0 0 1-1.6 1.6H7.1a1.6 1.6 0 0 1-1.6-1.6z" fill="currentColor"/></svg>"#
    static let reload = #"<svg width="15" height="15" viewBox="0 0 14 14"><path d="M11.6 5.2A5 5 0 0 0 2.4 5M2.4 8.8a5 5 0 0 0 9.2.2" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round"/><path d="M12 1.8v3.6H8.4M2 12.2V8.6h3.6" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"/></svg>"#
    static let reloadSmall = #"<svg width="13" height="13" viewBox="0 0 14 14"><path d="M11.6 5.2A5 5 0 0 0 2.4 5M2.4 8.8a5 5 0 0 0 9.2.2" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/><path d="M12 1.8v3.6H8.4M2 12.2V8.6h3.6" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/></svg>"#
    static let quit = #"<svg width="13" height="13" viewBox="0 0 14 14"><path d="M8 1.5H3.2a1 1 0 0 0-1 1v9a1 1 0 0 0 1 1H8" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/><path d="M6.2 7h6.6M10.4 4.6 12.8 7l-2.4 2.4" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/></svg>"#
    static let sidebarToggle = #"<svg width="18" height="15" viewBox="0 0 18 15"><rect x=".75" y=".75" width="16.5" height="13.5" rx="3" fill="none" stroke="currentColor" stroke-width="1.4"/><path d="M6.5 1v13" stroke="currentColor" stroke-width="1.4"/><path d="M2.8 4h2M2.8 6.2h2M2.8 8.4h2" stroke="currentColor" stroke-width="1.1" stroke-linecap="round"/></svg>"#
    /// The toolbar's Update button: an arrow down onto a line.
    static let update = #"<svg width="11" height="11" viewBox="0 0 12 12"><path d="M6 1.4v6.8M3 5.4l3 3 3-3M2 10.8h8" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/></svg>"#
    /// About's disclosure for the update's changes: a chevron right, turned down while open.
    static let disclosure = #"<svg width="8" height="10" viewBox="0 0 8 10"><path d="M2.5 1.5 6 5 2.5 8.5" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/></svg>"#
    static let upDown = #"<svg width="7" height="11" viewBox="0 0 7 11"><path d="M1 4 3.5 1.5 6 4M1 7l2.5 2.5L6 7" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round"/></svg>"#
}

/// Static traffic lights for headless renders only: the real windows show AppKit's own buttons in the same place.
struct TrafficLightsPreview: View {
    var diameter: CGFloat = 12
    var gap: CGFloat = 8

    var body: some View {
        HStack(spacing: gap) {
            Circle().fill(Color(hex: 0xFF5F57))
            Circle().fill(Color(hex: 0xFEBC2E))
            Circle().fill(Color(hex: 0x28C840))
        }
        .frame(width: diameter * 3 + gap * 2, height: diameter)
    }
}
