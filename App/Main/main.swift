import JuiceIslandUI

// The Xcode app target is only this file and the Focus filter (QuietFocusFilter.swift). Everything else is the SwiftPM
// library JuiceIslandUI (App/ minus App/Main), so `swift test` renders every view headless without building or
// launching the app.
JuiceIslandApp.run(focusFilter: QuietFocusFilter.currentQuiet)
