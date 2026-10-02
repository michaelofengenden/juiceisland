import JuiceIslandUI

// The public flavor's app target (project-public.yml): the same app as App/Main, with Sparkle as its updater when this
// build carries the feed's key (P823, P824). Everything else is the SwiftPM library JuiceIslandUI, as in the private app.
JuiceIslandApp.run(feed: SparkleFeed.make())
