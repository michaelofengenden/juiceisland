import SwiftUI

/// The prototype's own icons that both the window toolbar and the island header draw (16 × 16 viewBox).
/// Other icons are SF Symbols (prototype.md §5.5) or live with the one stream that uses them.
struct CogShape: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 16
        var path = Path()
        let teeth = 8, outer = 7.4, inner = 5.6
        for index in 0..<(teeth * 2) {
            let a0 = Double(index) / Double(teeth * 2) * 2 * .pi - .pi / 16
            let a1 = Double(index + 1) / Double(teeth * 2) * 2 * .pi - .pi / 16
            let radius = index % 2 == 1 ? inner : outer
            let p0 = CGPoint(x: 8 + radius * cos(a0), y: 8 + radius * sin(a0))
            let p1 = CGPoint(x: 8 + radius * cos(a1), y: 8 + radius * sin(a1))
            if index == 0 { path.move(to: p0) } else { path.addLine(to: p0) }
            path.addLine(to: p1)
        }
        path.closeSubpath()
        path.addEllipse(in: CGRect(x: 5.4, y: 5.4, width: 5.2, height: 5.2))
        return path.applying(CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: rect.minX / scale, y: rect.minY / scale))
    }
}

struct CogIcon: View {
    var size: CGFloat = 15
    var colour: Color = IslandTheme.headerIcon
    var body: some View {
        CogShape().fill(colour, style: FillStyle(eoFill: true)).frame(width: size, height: size)
    }
}

/// Speaker with two waves; `muted` swaps the waves for an x.
struct SpeakerIcon: View {
    var size: CGFloat = 15
    var colour: Color = IslandTheme.headerIcon
    var muted = false

    var body: some View {
        Canvas { context, canvas in
            let s = canvas.width / 16
            var cone = Path()
            cone.move(to: CGPoint(x: 1.5 * s, y: 5.8 * s))
            cone.addLine(to: CGPoint(x: 4.1 * s, y: 5.8 * s))
            cone.addLine(to: CGPoint(x: 7.6 * s, y: 3 * s))
            cone.addLine(to: CGPoint(x: 7.6 * s, y: 13 * s))
            cone.addLine(to: CGPoint(x: 4.1 * s, y: 10.2 * s))
            cone.addLine(to: CGPoint(x: 1.5 * s, y: 10.2 * s))
            cone.closeSubpath()
            context.fill(cone, with: .color(colour))
            var waves = Path()
            if muted {
                waves.move(to: CGPoint(x: 10 * s, y: 6 * s)); waves.addLine(to: CGPoint(x: 14 * s, y: 10 * s))
                waves.move(to: CGPoint(x: 14 * s, y: 6 * s)); waves.addLine(to: CGPoint(x: 10 * s, y: 10 * s))
            } else {
                waves.addArc(center: CGPoint(x: 7.6 * s, y: 8 * s), radius: 3.4 * s, startAngle: .degrees(-45), endAngle: .degrees(45), clockwise: false)
                waves.move(to: CGPoint(x: 7.6 * s + 6 * s * cos(.pi / 4.5), y: 8 * s - 6 * s * sin(.pi / 4.5)))
                waves.addArc(center: CGPoint(x: 7.6 * s, y: 8 * s), radius: 6 * s, startAngle: .degrees(-40), endAngle: .degrees(40), clockwise: false)
            }
            context.stroke(waves, with: .color(colour), style: StrokeStyle(lineWidth: 1.4 * s, lineCap: .round))
        }
        .frame(width: size, height: size)
    }
}
