import SwiftUI

/// A named, dashed box that marks an unbuilt slot in renders. Streams delete their use of it as they fill a slot.
struct SlotPlaceholder: View {
    let name: String
    let owner: String
    var tint: Color = Color(hex: 0x5C5C61)

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(tint, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            VStack(spacing: 2) {
                Text(name).font(Fonts.sys(12, .semibold)).foregroundStyle(Color(hex: 0x8E8E93))
                Text("stream \(owner)").font(Fonts.sys(10.5)).foregroundStyle(tint)
            }
        }
    }
}
