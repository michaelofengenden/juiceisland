import SwiftUI

// A battery's cuts on glass (P526, P531). On Black a battery paints the surface's black where it cuts through what it
// drew: a digit over the fill, the halo that keeps a digit legible across the fill's edge, the stale slash's band. On
// glass that black would be a black mark on the glass, so the same shapes knock out instead (`destinationOut`) and the
// cut shows whatever is behind the battery: the panel's or the island's glass. A knock-out removes everything drawn
// before it in its layer, so it happens only inside the battery's own drawing group (`batteryCutGroup`), which a glass
// battery sets up exactly when it draws its cuts as `BatteryKnockOut`: a cut never reaches past its battery. A drawing
// group, not a compositing group: the battery is drawn into one image of its own, so the knock-out stays in it on every
// path. In a hosting view's layers a compositing group did not hold it, and the cut went through the panel's floor to
// the desktop (P531).
//
// Black's batteries are today's, node for node (P559): the parent says whether a battery is glass (`glass:`, from the
// theme it read), the battery reads nothing from the environment, and its cuts are `EmptyModifier`, which adds
// nothing. An environment read and a conditional wrapper on each battery, digit, halo and slash cost Black's usage fold
// a fifth to a third of a millisecond.

/// How far past its frame a battery's drawing group reaches: the stale slash (2 to 3 pt) and the window battery's Next
/// bar (4.5 pt) hang outside the body, and a drawing group keeps nothing outside its frame.
let batteryCutGroupOutset: CGFloat = 6

/// How a battery draws a cut: `EmptyModifier` (Black: the black, as it always was) or `BatteryKnockOut` (glass).
protocol BatteryCutting: ViewModifier {
    /// This cut where `cuts`, and none elsewhere (a digit on the track, a halo on the fill).
    func cutting(_ cuts: Bool) -> Self
}

extension EmptyModifier: BatteryCutting {
    func cutting(_ cuts: Bool) -> EmptyModifier { self }
}

/// A cut on glass: knocks out, inside the battery's own group.
struct BatteryKnockOut: BatteryCutting {
    var cuts = true

    func cutting(_ cuts: Bool) -> BatteryKnockOut { BatteryKnockOut(cuts: cuts) }

    func body(content: Content) -> some View {
        content.blendMode(cuts ? .destinationOut : .normal)
    }
}

extension View {
    /// A glass battery (and `batteryCutGroupOutset` around it) drawn into an image of its own, inside which its
    /// `BatteryKnockOut` cuts knock out. Black's batteries set up none.
    func batteryCutGroup() -> some View {
        padding(batteryCutGroupOutset)
            .drawingGroup()
            .padding(-batteryCutGroupOutset)
    }
}
