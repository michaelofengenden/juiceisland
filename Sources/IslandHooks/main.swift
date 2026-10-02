// The superset helper, shipped as Contents/Helpers/OpenIslandHooks (spec §3.2, §3.8). It sends the allowlisted
// context note to the engine's own socket, fire-and-forget. A Claude or Codex PermissionRequest goes to the engine's
// request broker, and a Codex subagent's hook ends with its note (`HookPrelude`); every other hook runs upstream's
// helper unchanged: the same stdin, stdout, bridge socket, timeouts and exit code. Upstream's code is compiled by path
// from Vendor/, never copied.
import Darwin
import Foundation
import IslandHookNotes
import IslandHooksEntry

switch HookPrelude.run() {
case let .finished(_, output):
    if let output { FileHandle.standardOutput.write(output) }
    exit(0)
case .skipped, .untouched, .forwarded:
    exit(open_island_hooks_upstream_main(CommandLine.argc, CommandLine.unsafeArgv))
}
