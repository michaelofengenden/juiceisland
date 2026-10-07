import JuiceIslandUI
import SwiftUI
import WidgetKit

// The widget extension's target is only this file (project.yml). The widgets themselves, their timelines and their views
// are the SwiftPM library JuiceIslandUI (App/Widget), so `swift test` renders them headless without building the
// extension. The gallery shows them in this order: the Usage widget first, the panel's replacement on the desktop, then
// the sessions widget.
@main
struct JuiceIslandWidgets: WidgetBundle {
    var body: some Widget {
        JuiceIslandUsageWidget()
        JuiceIslandWidget()
    }
}
