// The superset helper, shipped as Contents/Helpers/OpenIslandHooks and installed as `<home>/bin/JuiceHooks` (spec
// §3.2, §3.8; P900). It sends the allowlisted context note to the engine's own socket, fire-and-forget. A Claude or
// Codex PermissionRequest goes to the engine's request broker, a Codex subagent's hook ends with its note, and a
// Claude-format hook from Copilot, Devin or another agent behind Claude's hooks is run by `ClaudeFamilyRunner`
// (`HookPrelude`); every other hook runs upstream's helper unchanged: the same stdin, stdout, timeouts and exit code.
// Installed in a home, it dials that home's bridge: upstream's half is told so through `OPEN_ISLAND_SOCKET_PATH`, which
// upstream's helper reads first. At any other path (Open Island's old managed copy) it keeps upstream's socket.
// Upstream's code is compiled by path from Vendor/, never copied.
import Darwin
import Foundation
import IslandHookNotes
import IslandHooksEntry

if let home = HookHome.ofCurrentHelper() {
    setenv("OPEN_ISLAND_SOCKET_PATH", home.bridgeURL.path, 1)
}

switch HookPrelude.run() {
case let .finished(_, output):
    if let output { FileHandle.standardOutput.write(output) }
    exit(0)
case .skipped, .untouched, .forwarded:
    exit(open_island_hooks_upstream_main(CommandLine.argc, CommandLine.unsafeArgv))
}
