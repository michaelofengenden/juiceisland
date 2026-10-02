// v8 — final unified system
// Real product surfaces: pill (notch + panel + notif). Control Center is a separate window
// outside the design scope and is intentionally not modeled here.
//
// Engineering source-of-truth (Sources/OpenIslandCore/AgentSession.swift):
//   - AgentTool enum (10 cases) drives `AGENTS` below.
//   - SessionPhase enum (running / waitingForApproval / waitingForAnswer / completed)
//     drives the `state` strings used by NotchRow and Row. There is no `idle` phase
//     in the reducer — `idle` here is a pill-level UI concept meaning "no visible session".
//   - PermissionRequest carries dynamic primary/secondary action titles, which is why
//     the F1/F2 notif bodies render their button labels as placeholders.
//   - QuestionPrompt supports multi-select and freeform answers, which F3 must handle.
//
// Real agents (10): Claude Code, Codex, Cursor, Gemini CLI, Kimi CLI, OpenCode,
//                   Qoder, Qwen Code, Factory, CodeBuddy
// Real terminals & IDEs (15+): Terminal.app, Ghostty, iTerm2, WezTerm, Zellij, tmux,
//                   cmux, Kaku, VS Code, Cursor, Windsurf, Trae, JetBrains IDEs
// Real hook events: SessionStart, UserPromptSubmit, PreToolUse, PostToolUse, Stop, SessionEnd

const { useState: uS, useEffect: uE, useRef: uR } = React;

// ---------- Real product taxonomy ----------
// Colors mirror AgentTool.brandColorHex from PR #385 (v6 redesign — locked palette).
// `tool` keys align with the Swift AgentTool enum raw values.
const AGENTS = {
  claude:    { id:'claude',    name:'Claude Code', short:'CC', color:'#d97742', cli:'claude',    tool:'claudeCode', supported: true },
  codex:     { id:'codex',     name:'Codex',       short:'CX', color:'#4aa3df', cli:'codex',     tool:'codex',      supported: true },
  cursor:    { id:'cursor',    name:'Cursor',      short:'CR', color:'#7a5cff', cli:'cursor',    tool:'cursor',     supported: true },
  gemini:    { id:'gemini',    name:'Gemini CLI',  short:'GM', color:'#42e86b', cli:'gemini',    tool:'geminiCLI',  supported: true },
  kimi:      { id:'kimi',      name:'Kimi CLI',    short:'KM', color:'#fde047', cli:'kimi',      tool:'kimiCLI',    supported: true },
  opencode:  { id:'opencode',  name:'OpenCode',    short:'OC', color:'#ffb547', cli:'opencode',  tool:'openCode',   supported: true },
  qoder:     { id:'qoder',     name:'Qoder',       short:'QD', color:'#ff6b9f', cli:'qoder',     tool:'qoder',      supported: true },
  qwen:      { id:'qwen',      name:'Qwen Code',   short:'QW', color:'#c084fc', cli:'qwen',      tool:'qwenCode',   supported: true },
  factory:   { id:'factory',   name:'Factory',     short:'FA', color:'#6e9fff', cli:'droid',     tool:'factory',    supported: true },
  codebuddy: { id:'codebuddy', name:'CodeBuddy',   short:'CB', color:'#fca5a5', cli:'codebuddy', tool:'codebuddy',  supported: true },
};
const TERMS = [
  // Terminal emulators
  { id:'terminal', name:'Terminal.app', kind:'term', st:'full',    note:'TTY' },
  { id:'ghostty',  name:'Ghostty',      kind:'term', st:'full',    note:'ID match' },
  { id:'iterm2',   name:'iTerm2',       kind:'term', st:'full',    note:'AppleScript' },
  { id:'wezterm',  name:'WezTerm',      kind:'term', st:'full',    note:'CLI pane' },
  { id:'kaku',     name:'Kaku',         kind:'term', st:'full',    note:'CLI pane' },
  // Multiplexers
  { id:'zellij',   name:'Zellij',       kind:'mux',  st:'full',    note:'pane' },
  { id:'tmux',     name:'tmux',         kind:'mux',  st:'full',    note:'pane' },
  { id:'cmux',     name:'cmux',         kind:'mux',  st:'full',    note:'socket' },
  // IDEs
  { id:'vscode',   name:'VS Code',      kind:'ide',  st:'full',    note:'integrated terminal' },
  { id:'cursor-ide',name:'Cursor',      kind:'ide',  st:'full',    note:'integrated terminal' },
  { id:'windsurf', name:'Windsurf',     kind:'ide',  st:'full',    note:'integrated terminal' },
  { id:'trae',     name:'Trae',         kind:'ide',  st:'full',    note:'integrated terminal' },
  { id:'jetbrains',name:'JetBrains IDEs', kind:'ide',st:'full',    note:'IDEA / WebStorm / PyCharm / GoLand / CLion / RubyMine / PhpStorm / Rider / RustRover' },
];

// ---------- Phase taxonomy — engineering-aligned ----------
// Mirrors Sources/OpenIslandCore/AgentSession.swift `SessionPhase` plus the
// pill-only `idle` value (which is *not* a phase in the reducer — it's how the
// notch represents "no visible session" or a session with no live activity).
//
// `priority` follows v8 design: anything requiring attention sorts above
// running, completed, and idle, in that order.
//
// `glyph` collapses the 5 phases onto v6 UnifiedBars' 4 visual modes
// (idle / running / waiting / done). The two waiting phases share the same
// glyph but are still distinguished in panel grouping and notif content.
const PHASES = {
  waitingForApproval: { label:'Needs approval', short:'Approval', priority:0, glyph:'waiting', requiresAttention:true,  swift:'.waitingForApproval' },
  waitingForAnswer:   { label:'Needs answer',   short:'Answer',   priority:1, glyph:'waiting', requiresAttention:true,  swift:'.waitingForAnswer' },
  running:            { label:'Running',        short:'Running',  priority:2, glyph:'running', requiresAttention:false, swift:'.running' },
  completed:          { label:'Completed',      short:'Done',     priority:3, glyph:'done',    requiresAttention:false, swift:'.completed' },
  idle:               { label:'Idle',            short:'Idle',     priority:4, glyph:'idle',    requiresAttention:false, swift:'(UI-only)' },
};
const STATE_PRIO = Object.fromEntries(Object.entries(PHASES).map(([k,v]) => [k, v.priority]));
const isAttentionPhase = (p) => !!PHASES[p]?.requiresAttention;
const phaseGlyph = (p) => PHASES[p]?.glyph || 'idle';
const phaseLabel = (p) => PHASES[p]?.label || '';
const phaseShort = (p) => PHASES[p]?.short || '';

// ---------- Sessions, modeled after the real SessionState reducer ----------
// `state` uses raw SessionPhase names so the design 1-to-1 maps to engineering.
// `attachmentState` mirrors SessionAttachmentState — affects panel `attached/stale/detached`
// chip rendering. `isRemote` marks SSH sessions.
const fmtAge = (m) => m<1?'<1m':m<60?`${Math.round(m)}m`:m<60*24?`${Math.round(m/60)}h`:`${Math.round(m/60/24)}d`;
const SESSIONS = [
  { id:'s1', agent:'claude', state:'waitingForApproval', notifKind:'two',   project:'open-island', branch:'refactor/claude-kernel-pid-monitor', msg:'Run shell command?',                  you:'commit and push',     terminal:'Ghostty',  ttl:'TTY ttys012', attachmentState:'attached', isRemote:false, updatedAt:120 },
  { id:'s2', agent:'codex',  state:'running',            notifKind:null,    project:'open-island', branch:'main',                                msg:'swift test --filter SessionStateTests', you:'run tests',           terminal:'Terminal', ttl:'TTY ttys005', attachmentState:'attached', isRemote:false, updatedAt:3 },
  { id:'s3', agent:'claude', state:'waitingForApproval', notifKind:'three', project:'open-island', branch:'fix/external-island-width',           msg:'Edit SessionState.swift?',              you:'提个 PR',              terminal:'Ghostty',  ttl:'pane g3',     attachmentState:'attached', isRemote:false, updatedAt:240 },
  { id:'s4', agent:'claude', state:'completed',          notifKind:'done',  project:'dotfiles',    branch:'main',                                msg:'Commit pushed · 3 files',               you:'commit all and push', terminal:'Kaku',     ttl:'pane k1',     attachmentState:'attached', isRemote:false, updatedAt:12 },
  { id:'s5', agent:'codex',  state:'waitingForAnswer',   notifKind:'jump',  project:'web-deck',    branch:'main',                                msg:'pnpm or npm?',                           you:'install deps',        terminal:'WezTerm',  ttl:'pane w2',     attachmentState:'attached', isRemote:false, updatedAt:60 },
  { id:'s6', agent:'claude', state:'idle',               notifKind:null,    project:'open-island', branch:'main',                                msg:'',                                       you:'',                    terminal:'Ghostty',  ttl:'pane g1',     attachmentState:'stale',    isRemote:false, updatedAt:95 },
  { id:'s7', agent:'codex',  state:'idle',               notifKind:null,    project:'web-deck',    branch:'main',                                msg:'',                                       you:'',                    terminal:'WezTerm',  ttl:'pane w2',     attachmentState:'stale',    isRemote:true,  updatedAt:180 },
  // s8: stale completed — process detached, finished a long time ago.
  // Demonstrates the staleness derivation: phase is still `.completed`
  // (no engineering change) but the row treats it as faded / mergeable
  // into the idle group because updatedAt > STALE_THRESHOLD_SEC.
  { id:'s8', agent:'gemini', state:'completed',          notifKind:null,    project:'docs-site',   branch:'main',                                msg:'docs build · ok',                        you:'rebuild docs',        terminal:'iTerm2',   ttl:'AS s3',       attachmentState:'detached', isRemote:false, updatedAt:1800 },
];

// ---------- Staleness (UI-only derivation, no engineering counterpart) ----------
// Engineering's `SessionPhase` has 4 cases (running / waitingForApproval /
// waitingForAnswer / completed). It does NOT distinguish "just completed"
// from "completed an hour ago" — that's a display-time concern.
//
// `isStale(s)` is a pure function over `updatedAt`: a `completed` row past
// the threshold reads as "should fold into idle". The threshold lives in
// the UI; in the shipping product it'd be a Control Center > Personalization
// preference. Engineering keeps `SessionPhase` unchanged.
const STALE_THRESHOLD_SEC = 300; // 5 min · default; tune in Control Center later
const isStale = (s, threshold = STALE_THRESHOLD_SEC) =>
  s.state === 'completed' && s.updatedAt > threshold;

// Default sort: phase priority first, then for completed rows fold stale
// behind fresh, then within the phase use the per-phase tiebreaker (oldest
// first for attention rows so the most overdue is on top, newest first for
// the rest).
const sortDefault = (list) => [...list].sort((a,b)=>{
  const pa=STATE_PRIO[a.state] ?? 99, pb=STATE_PRIO[b.state] ?? 99;
  if (pa!==pb) return pa-pb;
  // stale completed sinks below fresh completed in the same phase.
  const sa=isStale(a)?1:0, sb=isStale(b)?1:0;
  if (sa!==sb) return sa-sb;
  return isAttentionPhase(a.state) ? b.updatedAt-a.updatedAt : a.updatedAt-b.updatedAt;
});
// Sort by last-update recency (smaller updatedAt = more recent in our seed data).
const sortByUpdated = (list) => [...list].sort((a,b) => a.updatedAt - b.updatedAt);

// Tinted chip helper — `hexA('#d97742', 0.15)` → `rgba(217,119,66,0.15)`.
// Used by Row to render the agent chip's background / border on top of the
// brand-colored text (avoids hard-coding 10 alpha-variants in CSS).
const hexA = (hex, a) => {
  const h = hex.replace('#','');
  const r = parseInt(h.slice(0,2),16), g = parseInt(h.slice(2,4),16), b = parseInt(h.slice(4,6),16);
  return `rgba(${r},${g},${b},${a})`;
};

// Per-phase semantic color used by row state indicators (bar / chip / tint).
// Distinct from agent brand color — these communicate "what stage is this
// session in", not "which CLI". Two waiting phases stay close in hue
// (warm reds / ambers) so they read as one family but still distinguish.
const PHASE_COLOR = {
  waitingForApproval: '#f4a4a4', // warm red — needs attention
  waitingForAnswer:   '#ffd58a', // amber   — needs attention
  running:            '#6ea7ff', // blue    — in flight
  completed:          '#6fb982', // green   — just done
  idle:               '#9a958a', // neutral — no live activity
};
const phaseColor = (p) => PHASE_COLOR[p] || PHASE_COLOR.idle;
// Dispatcher used by the playground & GroupedRows.
const sortBy = (list, mode) => mode==='updated' ? sortByUpdated(list) : sortDefault(list);
const pickSessions = (n) => SESSIONS.slice(0, n).map(s => ({...s, age: fmtAge(s.updatedAt)}));

// ---------- Icons ----------
const IS = (p, ext={}) => <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" {...ext}>{p}</svg>;
const IconSound = () => IS(<><polygon points="11 5 6 9 2 9 2 15 6 15 11 19 11 5" fill="currentColor" stroke="none"/><path d="M15.54 8.46a5 5 0 0 1 0 7.07"/></>);
const IconGear  = () => IS(<><circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 1 1-4 0v-.09a1.65 1.65 0 0 0-1-1.51 1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 1 1 0-4h.09a1.65 1.65 0 0 0 1.51-1 1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 1 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 1 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z"/></>);
const IconHook  = () => IS(<><path d="M9 4v8a3 3 0 0 0 6 0"/><path d="M12 4h0"/><circle cx="12" cy="20" r="1.5" fill="currentColor"/></>);

// ---------- BarsGlyph — delegates to v6 UnifiedBars ----------
// Visual DNA is locked to v6/notch_v6_locked.jsx. Idle/running/waiting use the
// shared <UnifiedBars> implementation (same 3-column geometry, smooth CSS
// transitions on height/y/opacity, SMIL animation for the running wave).
//
// `done` is a separate stroke-draw tick (fill="freeze" so it doesn't replay).
//
// Accepts both raw v6 modes (idle/running/waiting/done) and engineering phase
// names (waitingForApproval/waitingForAnswer/completed) — the latter are
// collapsed via phaseGlyph().
function BarsGlyph({ mode='idle', tone='ink' }){
  const visual = ['idle','running','waiting','done'].includes(mode) ? mode : phaseGlyph(mode);
  const ink = tone==='paper' ? '#0d0d0f' : '#f1ead9';
  if (visual==='done') return (
    <svg width="24" height="24" viewBox="0 0 24 24">
      <path d="M 6 12 L 10.5 16.5 L 18 9" fill="none" stroke={ink} strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round" strokeDasharray="20 20" strokeDashoffset="20">
        <animate attributeName="stroke-dashoffset" from="20" to="0" dur="0.4s" fill="freeze"/>
      </path>
    </svg>
  );
  // idle / running / waiting — delegate to v6 UnifiedBars.
  // UnifiedBars hard-codes ink #f1ead9 (correct for the dark notch background).
  // If we ever need a paper-tone variant we'll add a `tone` prop upstream.
  return (
    <svg width="24" height="24" viewBox="0 0 24 24">
      <UnifiedBars mode={visual}/>
    </svg>
  );
}

// ---------- Logo: notch shape + bar + dot (signature from v6) ----------
function LogoMark({ size=160, tone='paper' }){
  const ink = tone==='ink' ? '#f1ead9' : '#0d0d0f';
  const bg  = tone==='ink' ? '#0d0d0f' : tone==='paper' ? '#f1ead9' : '#fff';
  const w=160, h=80;
  return (
    <svg width={size} height={size*h/w} viewBox={`0 0 ${w} ${h}`}>
      {/* notch shape */}
      <path d={`M 0 0 H ${w} V ${h-40} A 40 40 0 0 1 ${w-40} ${h} H 40 A 40 40 0 0 1 0 ${h-40} Z`} fill={ink}/>
      {/* inverse bar + dot inside, evoking the M + I */}
      <rect x="44" y="30" width="44" height="14" rx="7" fill={bg}/>
      <circle cx="106" cy="37" r="7" fill={bg}/>
    </svg>
  );
}
function LogoLockup({ size=380, tone='paper' }){
  const ink = tone==='ink' ? '#f1ead9' : '#0d0d0f';
  const bg  = tone==='ink' ? '#0d0d0f' : '#f1ead9';
  const w=380, h=80;
  return (
    <svg width={size} height={size*h/w} viewBox={`0 0 ${w} ${h}`}>
      <path d={`M 0 0 H 80 V 40 A 40 40 0 0 1 40 80 A 40 40 0 0 1 0 40 Z`} fill={ink}/>
      <rect x="22" y="30" width="22" height="14" rx="7" fill={bg}/>
      <circle cx="58" cy="37" r="7" fill={bg}/>
      <text x="100" y="38" fill={ink} fontFamily="'Inter', sans-serif" fontSize="26" fontWeight="700" letterSpacing="-0.02em">Open</text>
      <text x="100" y="68" fill={ink} fillOpacity="0.6" fontFamily="'Inter', sans-serif" fontSize="26" fontWeight="400" letterSpacing="-0.02em">Island</text>
    </svg>
  );
}
function AppIcon({ size=128, tone='paper' }){
  const bg = tone==='paper' ? '#f1ead9' : tone==='ink' ? '#0d0d0f' : '#fff';
  const ink = tone==='ink' ? '#f1ead9' : '#0d0d0f';
  const inv = tone==='ink' ? '#0d0d0f' : tone==='paper' ? '#f1ead9' : '#fff';
  const r = size*0.225;
  return (
    <div style={{ width:size, height:size, background:bg, borderRadius:r, position:'relative',
      boxShadow:`inset 0 0 0 1px ${tone==='ink'?'rgba(255,255,255,0.08)':'rgba(0,0,0,0.06)'}, 0 ${size*0.015}px ${size*0.06}px rgba(0,0,0,0.2)`,
      display:'grid', placeItems:'center', overflow:'hidden' }}>
      <svg width={size*0.66} height={size*0.66*0.5} viewBox="0 0 160 80">
        <path d={`M 0 0 H 160 V 40 A 40 40 0 0 1 120 80 H 40 A 40 40 0 0 1 0 40 Z`} fill={ink}/>
        <rect x="44" y="30" width="44" height="14" rx="7" fill={inv}/>
        <circle cx="106" cy="37" r="7" fill={inv}/>
      </svg>
    </div>
  );
}

Object.assign(window, {
  BarsGlyph, LogoMark, LogoLockup, AppIcon,
  AGENTS, TERMS, SESSIONS, PHASES, STATE_PRIO,
  isAttentionPhase, phaseGlyph, phaseLabel, phaseShort, phaseColor, PHASE_COLOR,
  sortDefault, sortByUpdated, sortBy, pickSessions, fmtAge, hexA,
  isStale, STALE_THRESHOLD_SEC,
  IconSound, IconGear, IconHook,
});
