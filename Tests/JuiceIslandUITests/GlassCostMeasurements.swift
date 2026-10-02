import AppKit
import Darwin
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// What Theme Glass costs the main thread while an outline moves (P527), headless: a surface in an `NSHostingView`, in a
/// borderless window that is never ordered on screen, whose outline steps from the closed pill to the opened island and
/// back, a step a turn, as SwiftUI's outline engine steps it; each step laid out and committed, its thread CPU timed.
/// Black (the fill the surfaces draw today), the island's live glass (still, clipped by the outline, with the floor and
/// the rim), the same glass reshaped each step, Reduce Transparency's solid and the stand-in; and the AppKit twin (`GlassSurfaceNSView.setPath`) beside the black `CAShapeLayer` Core Animation's
/// outline sets. Offscreen the window server composites nothing, so this is the app's side of a frame only: the glass's
/// compositing is the window server's and is not in it. Skipped unless `JI_MEASURE_GLASS=1`:
///   JI_MEASURE_GLASS=1 swift test -c release -Xswiftc -enable-testing --filter GlassCostMeasurements
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["JI_MEASURE_GLASS"] == "1"))
struct GlassCostMeasurements {
    enum Variant: String, CaseIterable {
        /// The fill the surfaces draw today.
        case black
        /// `GlassStyle.island`: the glass still, the moving outline clipping it, the rim in the outline.
        case glassIsland
        /// The same glass reshaped with the outline every step (`glassFollowsShape`, as `GlassStyle.panel`, which never
        /// moves).
        case glassFollowingShape
        /// Reduce Transparency's solid and the rim.
        case solid
        /// The island's stand-in (renders).
        case glassStandIn
    }

    @MainActor
    @Observable
    final class Morph {
        var geometry = SurfaceGeometry(width: 244, height: 33, ear: 3, radius: 12.5)
    }

    struct Surface: View {
        let morph: Morph
        let variant: Variant

        var body: some View {
            let shape = NotchSurfaceShape(geometry: morph.geometry)
            ZStack {
                switch variant {
                case .black: shape.fill(IslandTheme.bg)
                case .glassIsland:
                    GlassSurfaceBody(shape: shape, style: .island, rendering: .live, reduceTransparency: false, contrast: .standard)
                case .glassFollowingShape:
                    GlassSurfaceBody(shape: shape, style: GlassCostMeasurements.following, rendering: .live, reduceTransparency: false,
                                     contrast: .standard)
                case .glassStandIn:
                    GlassStage(backdrop: .busy) {
                        GlassSurfaceBody(shape: shape, style: .island, rendering: .standIn, reduceTransparency: false, contrast: .standard)
                    }
                case .solid:
                    GlassSurfaceBody(shape: shape, style: .island, rendering: .live, reduceTransparency: true, contrast: .standard)
                }
            }
            .frame(width: 520, height: 400)
        }
    }

    static let steps = 480

    static var following: GlassStyle {
        var style = GlassStyle.island
        style.glassFollowsShape = true
        return style
    }

    /// The outline `i` steps in: out to the island and back, 120 steps each way (a second at 120 Hz).
    static func geometry(_ i: Int) -> SurfaceGeometry {
        let phase = Double(i % 240) / 120, t = phase <= 1 ? phase : 2 - phase
        let e = 0.5 - 0.5 * cos(t * .pi)
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * e }
        return SurfaceGeometry(width: mix(244, 480), height: mix(33, 300), ear: mix(3, 8), radius: mix(12.5, 20))
    }

    struct Result { var name: String; var ms: [Double] }

    static func threadNS() -> UInt64 { clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) }

    @Test func eachSurfaceWhileItsOutlineMoves() throws {
        _ = NSApplication.shared
        var results: [Result] = []
        for variant in Variant.allCases {
            let morph = Morph()
            let host = NSHostingView(rootView: Surface(morph: morph, variant: variant).environment(\.colorScheme, .dark))
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 520, height: 400), styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            CATransaction.flush()
            var ms: [Double] = []
            for i in 0..<(Self.steps + 60) {
                let start = Self.threadNS()
                morph.geometry = Self.geometry(i)
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
                CATransaction.flush()
                if i >= 60 { ms.append(Double(Self.threadNS() - start) / 1e6) }
            }
            results.append(Result(name: variant.rawValue, ms: ms))
            window.contentView = nil
        }
        for appKit in [false, true] {
            let glass = GlassSurfaceNSView(style: .island, backdrop: .glass, increaseContrast: false)
            let black = CAShapeLayer()
            glass.frame = CGRect(x: 0, y: 0, width: 520, height: 400)
            let window = NSWindow(contentRect: glass.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = glass
            glass.layer?.addSublayer(black)
            var ms: [Double] = []
            for i in 0..<(Self.steps + 60) {
                let path = NotchSurfaceShape.path(Self.geometry(i), originX: 20, top: 0).cgPath
                let start = Self.threadNS()
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                if appKit { glass.setPath(path) } else { black.path = path }
                CATransaction.commit()
                CATransaction.flush()
                if i >= 60 { ms.append(Double(Self.threadNS() - start) / 1e6) }
            }
            results.append(Result(name: appKit ? "appKitGlass.setPath" : "blackShapeLayer.path", ms: ms))
            window.contentView = nil
        }
        var lines = ["| surface | median ms | p95 ms | max ms | steps over 8.3 ms |", "|---|---|---|---|---|"]
        for r in results {
            let sorted = r.ms.sorted()
            func q(_ p: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] }
            lines.append("| \(r.name) | \(String(format: "%.3f", q(0.5))) | \(String(format: "%.3f", q(0.95))) | "
                + "\(String(format: "%.3f", sorted.last ?? 0)) | \(r.ms.filter { $0 > 1000.0 / 120 }.count) |")
        }
        let table = lines.joined(separator: "\n")
        print(table)
        if let out = ProcessInfo.processInfo.environment["JI_MEASURE_OUT"] { try table.write(toFile: out, atomically: true, encoding: .utf8) }
    }
}
