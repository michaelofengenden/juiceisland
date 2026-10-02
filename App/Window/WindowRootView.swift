import SwiftUI

/// The app window's content (Window mode): the header (the toolbar line in the title bar, with the usage on it or in a
/// band under it), the hook lines and What's new under it, and the session list. The content runs under the title bar, so the toolbar line shares the traffic
/// lights' line. Owner: stream A. The slots are owned by A (`WindowToolbarView`), B (`UsageHeaderView`) and C
/// (`SessionListView`).
struct WindowRootView: View {
    /// Headless renders draw the traffic lights; the real window shows AppKit's own.
    var drawsTrafficLights = false
    /// Where the window's traffic lights are (the main window measures its own).
    var chrome: WindowChromeMetrics = .standard

    init(drawsTrafficLights: Bool = false, chrome: WindowChromeMetrics = .standard) {
        self.drawsTrafficLights = drawsTrafficLights
        self.chrome = chrome
    }

    var body: some View {
        VStack(spacing: 0) {
            WindowHeaderView(drawsTrafficLights: drawsTrafficLights)
                .overlay(alignment: .bottom) { WindowTheme.hairline.frame(height: 1) }
            HookDriftRows()
            WhatsNewCard()
            SessionListView()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(minWidth: WindowTheme.Metrics.minSize.width, minHeight: WindowTheme.Metrics.minSize.height)
        .background(WindowTheme.bg)
        .ignoresSafeArea()
        .environment(\.windowChrome, chrome)
        // Black and Smoke: dark, as it always was; Glass and Solid: the Appearance's look (P762).
        .windowLookFromSettings()
    }
}

/// The window's header: the toolbar's two ends with the usage between them or under them.
struct WindowHeaderView: View {
    var drawsTrafficLights = false
    /// Renders freeze a hover caption.
    var hover: HoverTargetID?
    /// false keeps the usage in its band under the line (renders of the band).
    var allowsTitleLine = true

    init(drawsTrafficLights: Bool = false, hover: HoverTargetID? = nil, allowsTitleLine: Bool = true) {
        self.drawsTrafficLights = drawsTrafficLights
        self.hover = hover
        self.allowsTitleLine = allowsTitleLine
    }

    var body: some View {
        UsageHeaderView(hover: hover, allowsTitleLine: allowsTitleLine) {
            ToolbarLeading(drawsTrafficLights: drawsTrafficLights)
        } trailing: {
            ToolbarTrailing()
        }
    }
}
