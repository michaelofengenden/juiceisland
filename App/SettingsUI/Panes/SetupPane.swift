import SwiftUI

/// Settings › Setup (spec §4.5, P19-P27): one row per profile with its hook state and Install, Remove or Repair, or
/// the reason it is unavailable. The app's rows come from `ProfileHooks`; renders show `DemoHooksModel`'s fixtures.
struct SetupPane: View {
    var body: some View { HookSetupView() }
}
