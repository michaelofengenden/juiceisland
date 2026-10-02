import SwiftUI

/// The prototype's card and list icons (L1100-1107), drawn in their SVG viewBox units and scaled to the frame.
/// Owner: stream C.
private func scaled(_ path: Path, viewBox: CGSize, in rect: CGRect) -> Path {
    let scale = min(rect.width / viewBox.width, rect.height / viewBox.height)
    return path.applying(CGAffineTransform(translationX: rect.minX, y: rect.minY).scaledBy(x: scale, y: scale))
}

/// Paper plane (15, 16 viewBox): the answer field's send button.
struct SendIcon: View {
    var colour: Color

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size), box = CGSize(width: 16, height: 16)
            let scale = min(size.width / box.width, size.height / box.height)
            var plane = Path()
            plane.move(to: CGPoint(x: 14.5, y: 1.5))
            plane.addLine(to: CGPoint(x: 1.5, y: 7))
            plane.addLine(to: CGPoint(x: 6.5, y: 9))
            plane.addLine(to: CGPoint(x: 8.5, y: 14))
            plane.closeSubpath()
            var fold = Path()
            fold.move(to: CGPoint(x: 14.5, y: 1.5)); fold.addLine(to: CGPoint(x: 6.5, y: 9))
            context.stroke(scaled(plane, viewBox: box, in: rect), with: .color(colour),
                           style: StrokeStyle(lineWidth: 1.5 * scale, lineJoin: .round))
            context.stroke(scaled(fold, viewBox: box, in: rect), with: .color(colour), style: StrokeStyle(lineWidth: 1.5 * scale))
        }
        .frame(width: 15, height: 15)
    }
}

/// Chevron right (9, 10 viewBox): replaces an option's shortcut while the pointer is on the island card.
struct ChevronRightIcon: View {
    var colour: Color = IslandTheme.optionChevron

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size), box = CGSize(width: 10, height: 10)
            let scale = min(size.width / box.width, size.height / box.height)
            var chevron = Path()
            chevron.move(to: CGPoint(x: 3.5, y: 2))
            chevron.addLine(to: CGPoint(x: 6.5, y: 5))
            chevron.addLine(to: CGPoint(x: 3.5, y: 8))
            context.stroke(scaled(chevron, viewBox: box, in: rect), with: .color(colour),
                           style: StrokeStyle(lineWidth: 1.5 * scale, lineCap: .round, lineJoin: .round))
        }
        .frame(width: 9, height: 9)
    }
}

/// Check (10 viewBox): a multi-select question's picked option.
struct CheckIcon: View {
    let colour: Color

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size), box = CGSize(width: 10, height: 10)
            let scale = min(size.width / box.width, size.height / box.height)
            var check = Path()
            check.move(to: CGPoint(x: 1.8, y: 5.2))
            check.addLine(to: CGPoint(x: 4.1, y: 7.5))
            check.addLine(to: CGPoint(x: 8.2, y: 2.6))
            context.stroke(scaled(check, viewBox: box, in: rect), with: .color(colour),
                           style: StrokeStyle(lineWidth: 1.5 * scale, lineCap: .round, lineJoin: .round))
        }
        .frame(width: 10, height: 10)
    }
}

/// Archive box (14): replaces a row's time tag on hover; dismisses the row.
struct ArchiveIcon: View {
    /// Its grey, a mark's, given by the row (P559): Black's and Smoke's `grey`, Glass's `IslandPalette.idleMark`.
    var colour = Self.grey

    static let grey = Color(hex: 0x757575)

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size), box = CGSize(width: 14, height: 14)
            let scale = min(size.width / box.width, size.height / box.height)
            var path = Path(roundedRect: CGRect(x: 1, y: 2, width: 12, height: 3), cornerRadius: 1)
            path.move(to: CGPoint(x: 2.2, y: 5))
            path.addLine(to: CGPoint(x: 2.2, y: 11))
            path.addArc(tangent1End: CGPoint(x: 2.2, y: 12), tangent2End: CGPoint(x: 3.2, y: 12), radius: 1)
            path.addLine(to: CGPoint(x: 10.8, y: 12))
            path.addArc(tangent1End: CGPoint(x: 11.8, y: 12), tangent2End: CGPoint(x: 11.8, y: 11), radius: 1)
            path.addLine(to: CGPoint(x: 11.8, y: 5))
            path.move(to: CGPoint(x: 5.4, y: 7.6)); path.addLine(to: CGPoint(x: 8.6, y: 7.6))
            context.stroke(scaled(path, viewBox: box, in: rect), with: .color(colour),
                           style: StrokeStyle(lineWidth: 1.2 * scale, lineCap: .round))
        }
        .frame(width: 14, height: 14)
    }
}

/// A cross (10, 10 viewBox): a read-only card's ✕, which lets its notice go.
struct CrossIcon: View {
    var colour: Color = IslandTheme.ink

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size), box = CGSize(width: 10, height: 10)
            let scale = min(size.width / box.width, size.height / box.height)
            var cross = Path()
            cross.move(to: CGPoint(x: 2, y: 2)); cross.addLine(to: CGPoint(x: 8, y: 8))
            cross.move(to: CGPoint(x: 8, y: 2)); cross.addLine(to: CGPoint(x: 2, y: 8))
            context.stroke(scaled(cross, viewBox: box, in: rect), with: .color(colour),
                           style: StrokeStyle(lineWidth: 1.5 * scale, lineCap: .round))
        }
        .frame(width: 10, height: 10)
    }
}
