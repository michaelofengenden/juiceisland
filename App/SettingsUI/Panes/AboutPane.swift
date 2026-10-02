import JuiceCore
import SwiftUI

/// Settings › About (prototype L1735-1737, spec §4.5): the icon, name, the build this is (its stamp: commit and date),
/// the engine credit, Updates (the check's state with Check now, new changes, Update now; §8 decision 12) and Quit.
/// Owner: stream A.
struct AboutPane: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 8) {
                AppIconView()
                Text(Product.name).font(Fonts.sys(22, .bold)).foregroundStyle(SettingsTheme.ink).padding(.top, 4)
                Text(Self.buildLine(env.updateChecker.stamp)).font(Fonts.sys(11)).foregroundStyle(SettingsTheme.ink2)
                Text("Engine from Open Island (GPL-3.0)").font(Fonts.sys(11)).foregroundStyle(SettingsTheme.ink3)
                if let licence = Self.licenceLine() {
                    if let text = Self.licenceURL(resources: Bundle.main.resourceURL) {
                        Link(licence, destination: text).font(Fonts.sys(11))
                    } else {
                        Text(licence).font(Fonts.sys(11)).foregroundStyle(SettingsTheme.ink3)
                    }
                }
                if let source = Product.flavor.sourceURL {
                    Link("Source code", destination: source).font(Fonts.sys(11))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 24)
            .padding(.bottom, 28)
            AboutUpdatesSection()
            FormSection {
                Button { env.actions.quit() } label: {
                    AboutAction(icon: ChromeIcon.quit, title: "Quit \(Product.name)", colour: SettingsTheme.destructive)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, SettingsTheme.Metrics.sectionTop)
        }
    }

    /// The public flavor's licence line (P857), which opens the GPL text the app carries; nil in the private app.
    static func licenceLine(flavor: AppFlavor = Product.flavor) -> String? {
        flavor.isPublic ? "Free software under GPL-3.0, with no warranty" : nil
    }

    /// The licence text in the app's resources (`build-public.sh` puts it there), opened on this Mac; nil without it.
    static func licenceURL(resources: URL?) -> URL? {
        guard let file = resources?.appendingPathComponent("LICENSE.txt"),
              FileManager.default.fileExists(atPath: file.path) else { return nil }
        return file
    }

    /// The build: its stamp; the public flavor's starts with its version ("Version 1.2.0 · Build 1a2b3c4 · …").
    static func buildLine(_ stamp: BuildStamp, flavor: AppFlavor = Product.flavor,
                          version: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) -> String {
        guard flavor.isPublic, let version, !version.isEmpty else { return stamp.aboutLine() }
        return "Version \(version) · " + stamp.aboutLine()
    }
}

/// A whole-row action: icon and label at the rows' inset and size, the row itself the click target.
private struct AboutAction: View {
    let icon: String
    let title: String
    let colour: Color

    var body: some View {
        HStack(spacing: 8) {
            SVGIcon(svg: icon, size: CGSize(width: 13, height: 13), colour: colour)
            Text(title).font(SettingsTheme.TypeScale.row).foregroundStyle(colour)
            Spacer(minLength: 0)
        }
        .padding(SettingsTheme.Metrics.rowPadding)
        .frame(minHeight: SettingsTheme.Metrics.rowMinHeight)
        .contentShape(Rectangle())
    }
}

/// The app icon as About draws it: the Dock's art in the Glyph style (`AppIconArt`), its body 56 pt across. The
/// square's margins and shadow overhang the 56 pt it takes in the layout.
struct AppIconView: View {
    @Environment(AppEnvironment.self) private var env

    static let bodySide: CGFloat = 56

    var body: some View {
        AppIconArt(style: env.settings.glyphStyle, side: Self.bodySide * 1024 / (1024 - 2 * AppIconArt.inset))
            .frame(width: Self.bodySide, height: Self.bodySide)
    }
}
