import Foundation
import IOKit.ps

/// Whether background work may run now (P712): the update's prepare starts only on AC power and out of Low Power Mode.
/// Read when a prepare would start, never watched: the prepare's own script stops its build when either changes.
enum PowerSource {
    static var allowsBackgroundWork: Bool { onACPower && !ProcessInfo.processInfo.isLowPowerModeEnabled }

    /// The Mac draws from AC power (a Mac with no battery always does). Unknown reads as AC: the script asks pmset too.
    static var onACPower: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return true }
        return (type as String) == kIOPSACPowerValue
    }
}
