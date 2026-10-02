# Open Island · v8 design bundle

Engineering-aligned redesign that consolidates **notch / session panel /
notification** into a single shape-shifting pill (the "pill is the product"
thesis). Companion to `design/v6-bundle/`, which holds the locked v6 visual
DNA — v8 inherits the closed-pill geometry (flat-top + rounded-bottom) and
the `UnifiedBars` glyph from v6 unchanged.

## Open it

```
open "design/v8-bundle/project/Open Island - v8 (final) v2.html"
```

The HTML is self-contained: React 18 / babel-standalone via CDN, no build
step. If the browser blocks `file://` cross-file `fetch` (Chrome does), serve
the folder instead:

```
cd design/v8-bundle/project && python3 -m http.server 8765
# then open http://localhost:8765/Open%20Island%20-%20v8%20%28final%29%20v2.html
```

## Layout

```
v8-bundle/
├── project/
│   ├── Open Island - v8 (final) v2.html    ← entry
│   ├── styles_v3.css   ← page chrome (shared with v3-v6)
│   ├── styles_v7.css   ← pill / panel / notif base
│   ├── styles_v8.css   ← v8 overrides + engineering-aligned additions
│   └── components/
│       ├── notch_v6_locked.jsx   ← v6 source-of-truth: NotchV6 + UnifiedBars
│       ├── logos_v7.jsx          ← Bar+Dot logo system (v6-locked)
│       ├── v8_core.jsx           ← AGENTS, PHASES, SESSIONS, PHASE_COLOR,
│       │                          BarsGlyph, sortBy, hexA, logos
│       ├── v8_pill.jsx           ← NotchRow / Row / StateIndicator /
│       │                          GroupedRows / PanelBody / NotifBody / Pill
│       └── v8_app.jsx            ← V8App page (live stage + state gallery)
└── chats/                ← design conversation transcripts
```

## What's modeled

`v8_core.jsx` mirrors `Sources/OpenIslandCore/AgentSession.swift`:

| design                         | engineering                                  |
| ------------------------------ | -------------------------------------------- |
| `AGENTS` (10 entries)          | `AgentTool` enum                             |
| `AgentTool.brandColorHex`      | locked v6 palette (PR #385)                  |
| `PHASES.waitingForApproval`    | `SessionPhase.waitingForApproval`            |
| `PHASES.waitingForAnswer`      | `SessionPhase.waitingForAnswer`              |
| `PHASES.running`               | `SessionPhase.running`                       |
| `PHASES.completed`             | `SessionPhase.completed`                     |
| `PHASES.idle`                  | UI-only — no live activity / no visible session |
| `s.attachmentState`            | `SessionAttachmentState` (attached/stale/detached) |
| `s.isRemote`                   | SSH session marker                           |

The two waiting phases share v6 `UnifiedBars`'s `waiting` glyph (same
outer-bar pulse) but split in panel grouping and notif bodies — approval
fires from `PreToolUse` hooks, answer from `QuestionPrompt`.

### Row click — spatial split, jump-first

Each row has two click targets that **never change semantics**:

- **Row body** (project / branch / msg / chips / state indicator) →
  jump to the originating terminal.
- **Trailing ▾ chevron** at the row's right end → toggle inline detail
  (rotates to ▴ when open).

The panel is the navigator; the terminal is the controller. In real
use, almost every row interaction ends with the user back in the
terminal — to handle a permission prompt, see streaming output, type
the next instruction. The primary click sends them there.

**Detail is open by default**, except for stale rows. Asking the user
to click "expand" before they can see what's going on defeats the
panel — they came here precisely to see it. The chevron is mostly a
*collapse* affordance for users who want to clean up a busy panel
(or the only way to peek into a stale row that's auto-folded). Each
row owns its own `expanded` state (mirrors `isManuallyExpanded` in
SwiftUI's `IslandSessionRow`) so user toggles are local and don't
collapse other rows.

Earlier iterations (and the current engine, `IslandPanelView.swift`)
used `state-dependent click` — actionable rows skipped expand and
jumped; inactive rows expanded first, jumped second. Reviewing
claude-island / Raycast / Linear inbox / macOS Notification Center all
converged on the same principle: *same pixel always does the same
thing*. The redesign drops state-dependent click; phase only affects
visual weight (state indicator, agent chip), never the click outcome.

`onJump(session)` is wired from Live Stage; static cards (sections
03 / 05) take a noop default. The shipping engine should mirror this
by letting the row body's `onTapGesture` always call `jumpToSession`,
and pulling expand into a separate disclosure button.

### Staleness — UI-only, no engineering counterpart

Engineering's `SessionPhase` does not distinguish "just completed" from
"completed an hour ago" — both are `.completed`. The design layer adds a
derived flag, `isStale(session)`, that returns true when `state ===
'completed'` and `updatedAt` is past `STALE_THRESHOLD_SEC` (default
5 min).

Stale rows:

- dim to opacity 0.7 (lighter than detached's 0.55, since they're still
  actionable — jump-back / re-prompt still work).
- in `groupBy:'state'`, fold into the **idle** group instead of crowding
  "Just done" — by definition they're past the freshness window.
- in `sortDefault`, sink below fresh completed within the same phase.

Engineering keeps `SessionPhase` at 4 cases. `STALE_THRESHOLD_SEC` is a
UI preference and would live in Control Center > Personalization in the
shipping product.

## Live Stage tweaks

The Live Stage (section 01) is the single playground — every tweak is
applied there in real time. Other sections (02 / 03 / 05) are static
spec grids by default.

- **Group by** — `none` · `state` · `agent` · `project` (driven by
  the session's `project` field, i.e. its working-directory basename).
- **Sort** — `attention` (waiting first; equivalent to the engineering
  `sortDefault`) · `updated` (most recent first).
- **State indicator** — how each row carries its session phase visually:
  `dot` (current baseline), `bar` (capsule strip on the row wrapper's
  left edge spanning row + expanded detail), `glyph` (16x16 v6
  UnifiedBars), `tint` (no leading slot — phase color is set inline on
  the project name; idle excluded).
- **Multi-agent · notch** — `priority` (one top phase + agent dot) vs
  `aggregate` (counts only).
- Other knobs: `wallpaper`, `sessions` count, `density`, `device`
  (external display vs MacBook physical notch), `logo tone`.

In the shipping product, `Group by` / `Sort` live in Control Center's
"Personalization" page — they are user preferences, not panel-header
chrome. The other tweaks are design-explore knobs only.

## Helpers worth knowing

- `PHASE_COLOR` (in `v8_core.jsx`) — semantic per-phase colors used by
  `bar` / `glyph` / `tint` indicators. Distinct from `AGENTS[].color`
  (which identifies the CLI brand).
- `hexA(hex, alpha)` — turns `#d97742` + `0.13` into `rgba(217,119,66,0.13)`.
  Used by the row's agent chip + tinted state indicators so we don't
  hand-author 10 alpha-variants in CSS.
- `sortBy(list, mode)` — dispatcher that routes to `sortDefault` or
  `sortByUpdated` depending on the `Sort` tweak.

## What's intentionally missing (vs. v7)

- ETA / progress meters · diff line counts · last-tool-call detail · usage
  strip · hook-missing warnings — hooks don't expose them, so the design
  doesn't fabricate them.
- **Control Center**. CC stays a separate window outside this design's
  scope; the panel's gear icon opens that existing window.

## Open follow-ups

**Content / data**

- F1/F2 permission option text is `<placeholder>` until per-agent prompt
  parsers land. `PermissionRequest.primaryActionTitle` / `secondaryActionTitle`
  + `suggestedUpdates` are the real source of truth.
- F3 (`waitingForAnswer`) currently models single-select. Multi-select
  (`QuestionPrompt.multiSelect`) and freeform-only variants are TODO.
- State indicator's final pick (dot / bar / glyph / tint) — ship one as
  default; the others stay in this design bundle as spec-only references.

**Motion** (not yet drawn)

- notch ↔ panel cross-fade on open/close (mass-conserving morph rather
  than width tween, since the pill *is* the panel).
- done-tick collapse — `.completed` glyph stroke-draws in 0.4s, then row
  auto-collapses back to idle after ~2s if the user doesn't interact.
- new-session enter (slide + fade from bottom).
- detached → attached re-attach pulse.

**Keyboard / accessibility** (not yet mapped)

- Panel focus order, expandable-row keyboard shortcuts, notif hotkeys
  (`1` / `2` / `3` / `↵` / `esc`).
- **Modifier-key shortcut** (Raycast pattern, follow-up — confirmed
  wanted): with a row focused, `↵` runs the primary action (jump to
  terminal), `⌘↵` runs the secondary (expand inline detail). Surface a
  small `↵ Jump` / `⌘↵ Peek` hint at the row's right end so the key
  binding is discoverable.
- VoiceOver labels for every phase glyph + agent chip.
- `prefers-reduced-motion` rules — at minimum, kill UnifiedBars SMIL
  and notch breathing.
