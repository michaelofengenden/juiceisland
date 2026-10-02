// v8 — Pill component family. The pill IS the panel + notification.
const { useState: pS } = React;

// ---------- Notch row (top 32px) ----------
// Real engineering surface: glyph (state) + optional label/right slot + agent color dot.
// REMOVED in v8.final: mini progress meter, ETA — hooks don't expose those.
//
// `state` accepts either raw v6 glyph modes (`idle/running/waiting/done`) or
// engineering phase names (`waitingForApproval/waitingForAnswer/running/completed`).
// BarsGlyph collapses both forms onto v6's 4 visual modes.
function NotchRow({ state='idle', label=null, right=null, macbook=false, agentDot=null }){
  if (macbook) {
    return (
      <div className="oi-notch-row">
        <div style={{ display:'flex', alignItems:'center' }}>
          <div className="glyph"><BarsGlyph mode={state}/></div>
        </div>
        <div className="phys-gap"/>
        <div className="right">{right}</div>
      </div>
    );
  }
  return (
    <div className="oi-notch-row">
      <div style={{ display:'flex', alignItems:'center' }}>
        <div className="glyph"><BarsGlyph mode={state}/></div>
        {agentDot && <span className={`agent-dot ${agentDot}`}/>}
        {label && <span className="label">{label}</span>}
      </div>
      <div className="spacer"/>
      {right && <div className="right">{right}</div>}
    </div>
  );
}

// ---------- Session row ----------
// state-dot CSS class collapses the two waiting phases onto a single
// `waiting` token so existing panel styling keeps working; phase distinction
// shows up in the group header instead.
function stateDotClass(phase){
  if (phase === 'waitingForApproval' || phase === 'waitingForAnswer') return 'waiting';
  return phase;
}

// Row state indicator variants — see Tweaks > "State indicator". `dot` is
// the baseline; `bar`/`glyph`/`tint` are design candidates the user
// is comparing.
//
// dot   — colored dot in the leading slot (current baseline)
// bar   — full-height brand strip on the row-wrapper's left edge,
//         spanning row + expanded detail so it reads as "this whole
//         session is in state X" (drawn via .oi-row-wrap.ind-bar::before)
// glyph — v6 UnifiedBars miniaturized in the leading slot
// tint  — no leading slot at all; the project name carries the phase color
//         inline. Idle is excluded so dim-gray text doesn't clash with the
//         detached row's already-dim look.
function StateIndicator({ phase, kind }){
  if (kind === 'bar') {
    // bar is painted on the wrapper, not the row itself.
    return null;
  }
  if (kind === 'glyph') {
    // Idle glyph (v6 UnifiedBars middle-bar breathing) is too busy when
    // half the panel is idle — replace with a static dim dot. Other
    // phases delegate to BarsGlyph as before.
    if (phase === 'idle') return <span className="state-glyph state-glyph-idle"/>;
    return <span className="state-glyph"><BarsGlyph mode={phase}/></span>;
  }
  // dot — Row uses phaseColor() inline so approval (warm red) and answer
  // (amber) can be told apart at a glance, even though both share the
  // `waiting` UnifiedBars glyph at the notch level. The shared
  // `.state-dot.waiting` class fallback in styles_v7.css still handles
  // the panel-head and prio-head aggregate chips, where we deliberately
  // simplify back to a single 'waiting' tone.
  return <span className={`state-dot ${stateDotClass(phase)}`} style={{ background: phaseColor(phase) }}/>;
}

// Row click semantics — spatial split, jump-first:
//
//   Row body (proj / branch / msg / chips)   →  jump to terminal
//   Row trailing ▾ chevron                    →  expand inline detail
//
// Rationale: the panel is a navigator, the terminal is the controller.
// In real use the user almost always wants to land back in the terminal
// to react — Allow/Deny via prompt, see streaming output, type the next
// instruction. So the primary click goes there. Expand is the rarer
// "peek" path and gets the secondary trailing affordance. Same pixel
// always does the same thing, regardless of phase.
function Row({ s, onJump=()=>{}, density, variant, stateIndicator='dot' }){
  const compact = density === 'compact';
  const attached = s.attachmentState !== 'detached';
  const stale = isStale(s);
  // Rows are expanded by default — the panel exists to surface what each
  // session is doing, so making the user click to peek defeats it. Stale
  // completed rows are the exception: they collapse so they don't crowd
  // the panel with a wall of "Done" replies. The chevron lets the user
  // override either way.
  const [expanded, setExpanded] = pS(!stale);
  const onToggle = () => setExpanded(e => !e);
  // tint: no leading indicator — phase color leaks onto the project name
  // text instead. Idle / stale stay the default ink color (neither is
  // actionable, both should fade rather than carry phase ink).
  const projTint = stateIndicator === 'tint' && s.state !== 'idle' && !stale
    ? phaseColor(s.state)
    : undefined;
  const leadingIndicator = stateIndicator !== 'tint';
  // bar mode pushes its color up to the wrapper via a CSS variable so the
  // wrapper's ::before can stretch over both the row and the (optional)
  // expanded detail block.
  const wrapStyle = stateIndicator === 'bar'
    ? { '--phase-color': phaseColor(s.state) }
    : undefined;
  return (
    <div className={`oi-row-wrap ind-${stateIndicator} ${stale?'is-stale':''}`} style={wrapStyle}>
      <div className={`oi-row ${compact?'compact':''} ${attached?'':'detached'} ${stale?'stale':''} ind-${stateIndicator}`} onClick={() => onJump(s)}>
        {leadingIndicator && <StateIndicator phase={s.state} kind={stateIndicator}/>}
        <div className="oi-main">
          <div className="title">
            <span className="proj" style={projTint?{ color: projTint }:undefined}>{s.project}</span>
            {s.branch && s.branch !== 'main' && <span className="branch"> ({s.branch})</span>}
            {s.isRemote && <span className="remote-tag" title="SSH session"> ⟂</span>}
            {s.msg && !compact && <><span className="sep">·</span><span className="msg">{s.msg}</span></>}
          </div>
          {!compact && s.you && <div className="sub"><span className="you">You:</span> {s.you}</div>}
        </div>
        <div className="side">
          <span className="agent-name" style={{
            color: AGENTS[s.agent].color,
            backgroundColor: hexA(AGENTS[s.agent].color, 0.13),
            borderColor: hexA(AGENTS[s.agent].color, 0.35),
          }} title={AGENTS[s.agent].name}>{AGENTS[s.agent].cli}</span>
          <span className="oi-badge">{s.terminal}</span>
          <span className="oi-age">{s.age}</span>
          <button
            type="button"
            className={`row-expand-btn ${expanded?'open':''}`}
            title={expanded ? 'Collapse' : 'Expand inline detail'}
            onClick={(e) => { e.stopPropagation(); onToggle(); }}
          >
            <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round" strokeLinejoin="round">
              <polyline points="6 9 12 15 18 9"/>
            </svg>
          </button>
        </div>
      </div>
      {expanded && (
        <div className="oi-detail-notif">
          {s.notifKind ? (
            <NotifBody kind={s.notifKind} onClose={()=>{}} embed={true}/>
          ) : s.state==='running' ? (
            <div className="oi-detail-running">
              <div className="k">Currently running</div>
              <div className="cmd">{s.msg}</div>
              <div className="acts">
                {/* No "Jump to terminal" — row body click already does that.
                    Stop is a true inline action: kill the agent without
                    switching to the terminal to ⌃C it. */}
                <button className="act" onClick={(e)=>e.stopPropagation()}>Stop session</button>
              </div>
            </div>
          ) : null}
        </div>
      )}
    </div>
  );
}

// ---------- Grouped list ----------
// Single, generic grouper. Subsumes the old GroupedRows (by agent) and
// PriorityRows (by phase). Two orthogonal knobs:
//
//   groupBy : 'none' | 'state' | 'agent' | 'project'
//   sort    : 'attention' | 'updated'
//
// Group order is deterministic — state → phase priority, agent → AGENTS key
// order, project → alphabetical. Within each group rows are ordered by `sort`.
// In `state` mode, idle collapses by default (it's UI-only and noisy); other
// modes show idle inline so the user still sees every session.
const STATE_GROUP_DEFS = [
  { key:'waitingForApproval', dot:'waiting', label:phaseLabel('waitingForApproval') },
  { key:'waitingForAnswer',   dot:'waiting', label:phaseLabel('waitingForAnswer')   },
  { key:'running',            dot:'running', label:'In progress' },
  { key:'completed',          dot:'done',    label:'Just done'   },
  { key:'idle',               dot:'idle',    label:'Idle'        },
];

function GroupedRows({ sessions, groupBy='none', sort='attention', onJump, density, stateIndicator='dot' }){
  const ordered = sortBy(sessions, sort);
  const [idleOpen, setIdleOpen] = pS(false);

  if (groupBy === 'none') {
    return (
      <div className="oi-list">
        {ordered.map(s => <Row key={s.id} s={s} density={density} stateIndicator={stateIndicator} onJump={onJump}/>)}
      </div>
    );
  }

  if (groupBy === 'state') {
    // Stale completed rows fold into the idle group rather than crowding
    // the "Just done" group — by definition they're past the point where
    // a fresh-completion CTA is useful. Keeping them in completed would
    // also bury the genuinely fresh ones.
    const groups = STATE_GROUP_DEFS.map(g => {
      let list;
      if (g.key === 'idle')           list = ordered.filter(s => s.state === 'idle' || isStale(s));
      else if (g.key === 'completed') list = ordered.filter(s => s.state === 'completed' && !isStale(s));
      else                            list = ordered.filter(s => s.state === g.key);
      return { ...g, list };
    });
    return (
      <div className="oi-list">
        {groups.map(g => {
          if (!g.list.length) return null;
          if (g.key === 'idle') return (
            <div key={g.key} className="oi-prio-group prio-idle">
              <div className="oi-prio-head idle-toggle" onClick={(e)=>{ e.stopPropagation(); setIdleOpen(o=>!o); }}>
                <span className={`state-dot ${g.dot}`}/>
                <span className="lbl">{g.label}</span>
                <span className="ct">{g.list.length}</span>
                <span className="caret">{idleOpen?'▾':'▸'}</span>
              </div>
              {idleOpen && g.list.map(s => <Row key={s.id} s={s} density={density} stateIndicator={stateIndicator} variant="priority" onJump={onJump}/>)}
            </div>
          );
          return (
            <div key={g.key} className={`oi-prio-group prio-${g.key}`}>
              <div className="oi-prio-head">
                <span className={`state-dot ${g.dot}`}/>
                <span className="lbl">{g.label}</span>
                <span className="ct">{g.list.length}</span>
              </div>
              {g.list.map(s => <Row key={s.id} s={s} density={density} stateIndicator={stateIndicator} variant="priority" onJump={onJump}/>)}
            </div>
          );
        })}
      </div>
    );
  }

  if (groupBy === 'agent') {
    const groups = Object.keys(AGENTS)
      .map(k => ({ key:k, label: AGENTS[k].name, color: AGENTS[k].color, list: ordered.filter(s => s.agent === k) }))
      .filter(g => g.list.length);
    return (
      <div className="oi-list">
        {groups.map(g => (
          <div key={g.key} className="oi-grp">
            <div className="oi-grp-head" style={{ color: g.color }}>
              <span className="lbl">{g.label}</span>
              <span className="ct">{g.list.length}</span>
            </div>
            {g.list.map(s => <Row key={s.id} s={s} density={density} stateIndicator={stateIndicator} variant="grouped" onJump={onJump}/>)}
          </div>
        ))}
      </div>
    );
  }

  // groupBy === 'project'
  const projects = [...new Set(ordered.map(s=>s.project))].sort();
  return (
    <div className="oi-list">
      {projects.map(p => {
        const list = ordered.filter(s=>s.project===p);
        return (
          <div key={p} className="oi-grp">
            <div className="oi-grp-head">
              <span className="lbl">{p}</span>
              <span className="ct">{list.length}</span>
            </div>
            {list.map(s => <Row key={s.id} s={s} density={density} stateIndicator={stateIndicator} variant="grouped" onJump={onJump}/>)}
          </div>
        );
      })}
    </div>
  );
}

// ---------- Panel content ----------
// Header is a slim mode-switch row, not a usage strip — usage requires per-agent rate APIs we don't have for all 10 agents.
// Waiting chip aggregates both waiting phases (approval + answer); the panel rows
// still split them so users can tell why each session is blocked.
//
// The waiting / running dots inside these chips deliberately stay on the
// `dot` style (4-tone simplification) regardless of the row-level
// `stateIndicator` tweak — head chips are aggregate counters, not per-
// session indicators, and dot is the most compact visual at chip scale.
function PanelHead({ sessions }){
  const waiting = sessions.filter(s=>isAttentionPhase(s.state)).length;
  const running = sessions.filter(s=>s.state==='running').length;
  return (
    <div className="oi-panel-head">
      <span className="t">Sessions</span>
      {waiting>0 && <span className="chip waiting"><span className="state-dot waiting"/>{waiting} waiting</span>}
      {running>0 && <span className="chip running"><span className="state-dot running"/>{running} running</span>}
      <span className="spacer"/>
      <button className="icon-btn" title="Open Control Center window"><IconGear/></button>
    </div>
  );
}
// Translates the old `variant` prop ('default'|'priority'|'grouped') into the
// new (groupBy, sort) pair so existing call sites (other sections, edge cases)
// keep working without churn. The 03 playground passes groupBy/sort directly.
function resolveListMode({ variant, groupBy, sort }){
  if (groupBy != null) return { groupBy, sort: sort || 'attention' };
  if (variant === 'priority') return { groupBy: 'state',  sort: 'attention' };
  if (variant === 'grouped')  return { groupBy: 'agent',  sort: 'attention' };
  return { groupBy: 'none', sort: 'attention' };
}

function PanelBody({ sessions, onJump, density, variant, groupBy, sort, stateIndicator='dot' }){
  const empty = sessions.length===0;
  const mode = resolveListMode({ variant, groupBy, sort });
  return (
    <>
      <PanelHead sessions={sessions}/>
      {empty ? (
        <div className="oi-empty">
          <svg width="44" height="44" viewBox="0 0 44 44" fill="none"><path d="M 6 4 H 38 V 16 A 8 8 0 0 1 30 24 H 14 A 8 8 0 0 1 6 16 Z" fill="none" stroke="rgba(241,234,217,0.2)" strokeWidth="1.5" strokeDasharray="3 3"/></svg>
          <div className="t">No active sessions</div>
          <div className="h">Start any of <b>10 supported agents</b> in a terminal — <code>claude</code>, <code>codex</code>, <code>cursor</code>, <code>gemini</code>, <code>kimi</code>, <code>opencode</code>, <code>qoder</code>, <code>qwen</code>, <code>droid</code>, <code>codebuddy</code> — sessions auto-appear here.</div>
        </div>
      ) : (
        <GroupedRows sessions={sessions} groupBy={mode.groupBy} sort={mode.sort} density={density} stateIndicator={stateIndicator} onJump={onJump}/>
      )}
      <div className="oi-foot">
        <span>{sessions.length} session{sessions.length===1?'':'s'} · {sessions.filter(s=>isAttentionPhase(s.state)).length} waiting</span>
        <span className="spacer"/>
        <span style={{ opacity:0.45, fontSize:10.5 }}>⌃⌥ Space</span>
      </div>
    </>
  );
}

// ---------- Notification body (4 kinds: 2-way, 3-way, jump, done) ----------
// `hook-warn` from v7 was dropped — v8 §00 commits to "only paint what
// hooks expose", and hook-missing detection isn't part of that contract.
function NotifBody({ kind, onClose, embed=false }){
  const map = {
    // Permission notifs come from PreToolUse / pre_tool_use hooks.
    // The exact prompt text + option set differs per agent (Claude / Codex / Cursor / Gemini / …).
    // Until we wire each agent's real prompt parser, we render a structural placeholder.
    two: {
      // Phase: .waitingForApproval — engine receives PreToolUse hook payload.
      state:'waitingForApproval', label:'Approval', right:'Claude · Ghostty',
      title:'Tool permission requested',
      // TODO[engineering]: replace `code` block with the agent's actual prompt body (tool name + args).
      // Hooks DO expose tool name + raw args; not a guaranteed unified diff.
      code:'<agent prompt body · injected by PreToolUse hook>',
      sub:'open-island · refactor/claude-kernel-pid-monitor',
      // TODO[engineering]: use the agent's actual options. PermissionRequest in
      // Sources/OpenIslandCore/AgentSession.swift carries primaryActionTitle /
      // secondaryActionTitle (default "Allow"/"Deny") and may include
      // suggestedUpdates for "always allow" rules.
      acts:[{k:'deny',l:'Option B',cls:'danger'},{k:'ok',l:'Option A',cls:'primary'}],
      hint:<><kbd>↵</kbd> primary · <kbd>esc</kbd> dismiss · <span style={{opacity:0.5}}>options injected from agent</span></>,
    },
    three: {
      // Phase: .waitingForApproval — same as `two` but with 3+ options
      // (e.g. Claude's edit-file confirm: Allow / Allow-and-don't-ask / Deny).
      state:'waitingForApproval', label:'Approval', right:'Claude · Ghostty',
      title:'Tool permission requested',
      code:'<agent prompt body · injected by pre_tool_use hook>',
      sub:'open-island · main',
      acts:[{k:'a',l:'Option C'},{k:'b',l:'Option B'},{k:'c',l:'Option A',cls:'primary'}],
      hint:<><kbd>1</kbd> <kbd>2</kbd> <kbd>3</kbd> pick · <span style={{opacity:0.5}}>options injected from agent</span></>,
    },
    jump: {
      // Phase: .waitingForAnswer — agent emitted a QuestionPrompt via
      // UserPromptSubmit/Stop hook. QuestionPrompt supports multi-select and
      // freeform answers; this card models the single-select case. Multi-select
      // and freeform-only variants are TODO.
      state:'waitingForAnswer', label:'Answer', right:'Codex · WezTerm',
      title:'Should I use pnpm or npm?',
      sub:'web-deck · main · pane w2',
      options:[
        { k:'1', l:'pnpm',   hint:'recommended · faster, dedupe' },
        { k:'2', l:'npm',    hint:'default Node package manager' },
        { k:'3', l:'Cancel', hint:'abort and return to prompt' },
      ],
    },
    done: {
      // Phase: .completed — Stop hook fired; reply is written back to stdin.
      state:'completed', label:'Done', right:'Claude · Ghostty',
      title:'open-island · refactor/claude-kernel-pid-monitor',
      sub:'Claude Code · just now · 142/142 tests',
      reply:`PR 已提上去 ✓

主要改动:
1. 修复 \`SessionState.reducer\` 在 process 终止时未清理子 PID 监控的 bug — 之前会留下 zombie watcher。
2. 加了 \`SessionStateTests.testKernelPIDCleanup\`,覆盖三种终止路径(SIGTERM / SIGKILL / 自然退出)。
3. 在 \`docs/hooks.md\` 里补了 \`onSessionTerminate\` hook 的契约说明。

Tests: 142/142 (+1 new). PR #324 ready for review。`,
      acts:[{k:'jmp',l:'Jump back ↗',cls:'primary'}],
    },
  };
  const c = map[kind];
  if (!c) return null;
  const [reply, setReply] = pS('');
  const [picked, setPicked] = pS(null);
  const isDone = kind==='done';
  const isJump = kind==='jump';

  return (
    <>
      {!embed && <NotchRow state={c.state} label={c.label} right={c.right}/>}
      <div className={`oi-notif-body ${isDone?'done':''} ${isJump?'jump':''} ${embed?'embed':''}`}>
        <div className="title">{c.title}</div>
        <div className="sub">{c.sub}</div>
        {isDone ? (
          <>
            <div className="reply">{c.reply}</div>
            <div className="quick-reply">
              <input type="text" placeholder="Reply to agent…" value={reply} onChange={(e)=>setReply(e.target.value)} onClick={(e)=>e.stopPropagation()}/>
              <button className="send" disabled={!reply.trim()} title="Send (↵)">↵</button>
            </div>
            {/* In notif mode the pill is the whole notification, so a
                "Jump back" button is the only way to land in the terminal.
                When embedded as row detail, row body click already jumps,
                so the acts row collapses to nothing. */}
            {!embed && <div className="acts">{c.acts.map(a => <button key={a.k} className={`btn ${a.cls||''}`}>{a.l}</button>)}</div>}
          </>
        ) : isJump ? (
          <>
            <div className="opts">
              {c.options.map(o => (
                <button key={o.k} className={`opt ${picked===o.k?'picked':''}`} onClick={(e)=>{ e.stopPropagation(); setPicked(o.k); }}>
                  <span className="opt-key">{o.k}</span>
                  <span className="opt-body">
                    <span className="opt-label">{o.l}</span>
                    <span className="opt-hint">{o.hint}</span>
                  </span>
                  {picked===o.k && <span className="opt-check">✓</span>}
                </button>
              ))}
            </div>
            <div className="quick-reply">
              <input type="text" placeholder="或者自己输入回复…" value={reply} onChange={(e)=>{ setReply(e.target.value); if (e.target.value) setPicked(null); }} onClick={(e)=>e.stopPropagation()}/>
              <button className="send" disabled={!reply.trim()} title="Send (↵)">↵</button>
            </div>
            <div className="acts">
              <button className="btn" onClick={(e)=>{ e.stopPropagation(); onClose?.(); }}>Dismiss</button>
              {/* Jump button only in standalone notif mode — embedded row
                  detail relies on row body click for the same action. */}
              {!embed && <button className="btn" onClick={(e)=>e.stopPropagation()}>Jump to terminal ↗</button>}
              <button className={`btn ${(picked||reply.trim())?'primary':''}`} disabled={!picked && !reply.trim()} onClick={(e)=>e.stopPropagation()}>{reply.trim()?'Send reply':picked?`Send ${picked}`:'Pick or type'}</button>
            </div>
            {!embed && <div className="hint"><kbd>1</kbd> <kbd>2</kbd> <kbd>3</kbd> pick · <kbd>↵</kbd> send · <kbd>esc</kbd> dismiss</div>}
          </>
        ) : (
          <>
            {c.code && <div className="code">{c.code}</div>}
            <div className={`acts ${c.acts.length>2?'wrap':''}`}>{c.acts.map(a => <button key={a.k} className={`btn ${a.cls||''}`} onClick={(e)=>{ e.stopPropagation(); if (a.k==='later') onClose?.(); }}>{a.l}</button>)}</div>
            {c.hint && !embed && <div className="hint">{c.hint}</div>}
          </>
        )}
      </div>
    </>
  );
}

// ---------- The Pill shell ----------
function Pill({ mode, macbook, width, children, onClick, tone='ink' }){
  return (
    <div className={`oi-pill ${macbook?'macbook':''}`} data-mode={mode} data-tone={tone} style={{ width }} onClick={onClick}>
      {macbook && (
        <div style={{ position:'absolute', top:0, left:'50%', transform:'translateX(-50%)', width:180, height:32, pointerEvents:'none' }}>
          <svg width="180" height="32" viewBox="0 0 180 32"><path d="M 0 0 H 180 V 16 A 16 16 0 0 1 164 32 H 16 A 16 16 0 0 1 0 16 Z" fill="#000"/></svg>
        </div>
      )}
      {children}
    </div>
  );
}

Object.assign(window, { NotchRow, PanelHead, Row, GroupedRows, PanelBody, NotifBody, Pill });
