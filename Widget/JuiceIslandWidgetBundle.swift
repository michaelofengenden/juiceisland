import JuiceIslandUI
import SwiftUI
import WidgetKit

// The widget extension's target is only this file (project.yml). The widget itself, its timeline and its views are the
// SwiftPM library JuiceIslandUI (App/Widget), so `swift test` renders them headless without building the extension.
@main
struct JuiceIslandWidgets: WidgetBundle {
    var body: some Widget {
        JuiceIslandWidget()
    }
}
