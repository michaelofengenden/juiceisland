#ifndef ISLAND_HOOKS_ENTRY_H
#define ISLAND_HOOKS_ENTRY_H

/// Upstream's helper entry point (`@main OpenIslandHooksCLI` in Vendor/open-vibe-island/Sources/OpenIslandHooks),
/// compiled by path into the `OpenIslandHooksUpstream` library under this name instead of `main` (Package.swift).
int open_island_hooks_upstream_main(int argc, char * _Nullable * _Nonnull argv);

#endif
