// v8 — main app · combines pill states + panel + notifications + control center + brand
const { useState: aS, useEffect: aE } = React;

// ---------- Stage (menubar + wallpaper + pill at top) ----------
function MenuBarStage({ wallpaper='plum', children, tall=720, app='Xcode' }){
  const bg = {
    plum:'linear-gradient(135deg, #3c2344, #5f2e58 60%, #a8517a)',
    slate:'linear-gradient(135deg, #1e2530, #3a4a5c)',
    forest:'linear-gradient(135deg, #1b2e22, #3a5a3f)',
    sand:'linear-gradient(135deg, #c8a576, #e8d4a0 60%, #f1ead9)',
  }[wallpaper];
  return (
    <div className="v7-stage" data-wall={wallpaper} style={{ background:bg, minHeight: tall }}>
      <div className="menubar">
         <span className="m" style={{fontWeight:700, marginRight:12}}></span>
         <span className="m" style={{fontWeight:600}}>{app}</span>
         <span className="m">File  Edit  View</span>
         <span className="spacer"/>
         <span className="time">Apr 27  14:22</span>
      </div>
      <div style={{ padding:'72px 40px', color:'rgba(255,255,255,0.4)', fontFamily:'JetBrains Mono, monospace', fontSize:12 }}>
        <div style={{ opacity:0.3 }}>// 点 notch 开合 · 通知从同一个 pill 里长出来 · 永远是那条平直的顶边</div>
      </div>
      {children}
    </div>
  );
}

// ---------- Mini stage (for variant cards) ----------
function MiniStage({ wallpaper='plum', children, height=null, footer=null }){
  return (
    <div className="v8-mini" data-wall={wallpaper} style={ height?{ minHeight:height }:undefined }>
      {children}
      {footer}
    </div>
  );
}

// ---------- Live interactive stage ----------
// Multi-agent display strategy (Tweak):
//   'priority'  — show ONE highest-priority session's phase. Phase priority
//                 mirrors STATE_PRIO from v8_core.jsx (approval > answer >
//                 running > completed > idle). Ties (e.g. two
//                 waitingForApproval sessions) break by `updatedAt`
//                 descending — the *most overdue* one wins, which is the
//                 same rule sortDefault uses for attention groups.
//   'aggregate' — show counts only (e.g. "2 needs approval" + "×N"). No
//                 per-agent attribution; useful when many agents are running.
function LiveStage({ wallpaper, sessionCount, density, groupBy, sort, stateIndicator, macbook, multiStrat }){
  const [mode, setMode] = aS('panel');
  const [notif, setNotif] = aS(null);
  // Row owns its own expanded state now (default = !isStale(s)), mirroring
  // SwiftUI's IslandSessionRow `isManuallyExpanded`. Live Stage doesn't
  // track expansion — it only owns pill mode + notif kind + the jump
  // acknowledgement toast.
  const [jumpToast, setJumpToast] = aS(null);
  const handleJump = (s) => {
    setJumpToast(`↗ Jumped to ${s.terminal} · ${s.ttl || s.project}`);
    setTimeout(() => setJumpToast(null), 1500);
  };
  const sessions = pickSessions(sessionCount);
  // `idle` is a UI bucket for sessions with no live activity — they appear in
  // the panel's collapsed "Idle" group but don't drive the notch state/label.
  const visibleSessions = sessions.filter(s => s.state !== 'idle');
  const approval  = sessions.filter(s=>s.state==='waitingForApproval').length;
  const answer    = sessions.filter(s=>s.state==='waitingForAnswer').length;
  const running   = sessions.filter(s=>s.state==='running').length;
  const completed = sessions.filter(s=>s.state==='completed').length;
  const top = [...visibleSessions].sort((a,b)=>{
    const dp = (STATE_PRIO[a.state]??99) - (STATE_PRIO[b.state]??99);
    if (dp) return dp;
    // ties: oldest updatedAt wins (most overdue) — matches sortDefault.
    return b.updatedAt - a.updatedAt;
  })[0];
  const notchState = top ? top.state : 'idle';

  let notchLabel = null, notchRight = null, notchAgent = null;
  if (mode==='notch' && !macbook && visibleSessions.length>0) {
    if (multiStrat === 'aggregate') {
      if (approval>0)       notchLabel = `${approval} needs approval`;
      else if (answer>0)    notchLabel = `${answer} needs answer`;
      else if (running>0)   notchLabel = `${running} running`;
      else if (completed>0) notchLabel = `${completed} done`;
      notchRight = visibleSessions.length>1 ? `×${visibleSessions.length}` : null;
    } else {
      notchAgent = top.agent;
      notchLabel = phaseShort(top.state);
      notchRight = visibleSessions.length>1 ? `+${visibleSessions.length-1}` : null;
    }
  }
  if (mode==='notch' && macbook) {
    notchRight = visibleSessions.length>0 ? `×${visibleSessions.length}` : null;
  }

  const widths = {
    notch: macbook ? 280 : (notchLabel ? 210 : (notchRight ? 140 : 100)),
    panel: macbook ? 540 : 520,
    notif: macbook ? 480 : (notif==='three'?460:440),
  };

  const togglePanel = () => { setNotif(null); setMode(mode==='panel'?'notch':'panel'); };
  const fire = (k) => { setNotif(k); setMode('notif'); };

  return (
    <div className="v8-live">
      {jumpToast && <div className="oi-jump-toast">{jumpToast}</div>}
      <MenuBarStage wallpaper={wallpaper} tall={760}>
        <Pill mode={mode} macbook={macbook} width={widths[mode]} onClick={mode==='notch'?togglePanel:undefined}>
          {mode==='notch' && <NotchRow state={notchState} label={notchLabel} right={notchRight} macbook={macbook} agentDot={notchAgent}/>}
          {mode==='panel' && (
            <div onClick={(e)=>e.stopPropagation()}>
              <div onClick={()=>setMode('notch')} style={{ cursor:'pointer' }}>
                <NotchRow state={notchState} label={null} right={<span style={{opacity:0.5}}>close ⌃</span>} macbook={macbook}/>
              </div>
              <PanelBody sessions={sessions} onJump={handleJump} density={density} groupBy={groupBy} sort={sort} stateIndicator={stateIndicator}/>
            </div>
          )}
          {mode==='notif' && (
            <div onClick={(e)=>e.stopPropagation()}>
              <NotifBody kind={notif} onClose={()=>setMode('notch')}/>
            </div>
          )}
        </Pill>
      </MenuBarStage>

      <div className="v8-triggers">
        <div className="hd">pill mode</div>
        <button className={mode==='notch'?'on':''} onClick={()=>{ setNotif(null); setMode('notch'); }}>◦ notch</button>
        <button className={mode==='panel'?'on':''} onClick={()=>{ setNotif(null); setMode('panel'); }}>▼ session panel</button>
        <div className="hd">fire notif</div>
        <button className={mode==='notif'&&notif==='two'?'on':''} onClick={()=>fire('two')}>permission · 2-way</button>
        <button className={mode==='notif'&&notif==='three'?'on':''} onClick={()=>fire('three')}>permission · 3-way</button>
        <button className={mode==='notif'&&notif==='jump'?'on':''} onClick={()=>fire('jump')}>jump · pick</button>
        <button className={mode==='notif'&&notif==='done'?'on':''} onClick={()=>fire('done')}>task done</button>
      </div>
    </div>
  );
}

// ---------- State gallery card ----------
function StateCard({ num, name, desc, state, label, right, w=180, macbook=false, mini=null, agentDot=null, wall='plum', tone='ink' }){
  return (
    <div className="v8-state">
      <div className="stage" data-wall={wall}>
        <div className={`oi-pill ${macbook?'macbook':''}`} data-mode="notch" data-tone={tone} style={{ width: w }}>
          {macbook && (
            <div style={{ position:'absolute', top:0, left:'50%', transform:'translateX(-50%)', width:180, height:32, pointerEvents:'none' }}>
              <svg width="180" height="32" viewBox="0 0 180 32"><path d="M 0 0 H 180 V 16 A 16 16 0 0 1 164 32 H 16 A 16 16 0 0 1 0 16 Z" fill="#000"/></svg>
            </div>
          )}
          <NotchRow state={state} label={label} right={right} macbook={macbook} mini={mini} agentDot={agentDot}/>
        </div>
      </div>
      <div className="meta">
        <div className="name"><span className="num">{num}</span> {name}</div>
        <div className="desc">{desc}</div>
      </div>
    </div>
  );
}

// ---------- Root ----------
function V8App(){
  const [wallpaper, setWall] = aS('plum');
  const [sessionCount, setSC] = aS(6);
  const [density, setDen] = aS('comfortable');
  const [groupBy, setGroupBy] = aS('none');
  const [sort, setSort] = aS('attention');
  const [stateIndicator, setSI] = aS('dot');
  const [macbook, setMB] = aS(false);
  const [tone, setTone] = aS('paper');
  const [multiStrat, setMS] = aS('priority');

  aE(() => {
    const h = (e) => {
      const p = document.getElementById('tweaks-v8');
      if (!p) return;
      if (e.data?.type === '__activate_edit_mode') p.style.display = 'block';
      if (e.data?.type === '__deactivate_edit_mode') p.style.display = 'none';
    };
    window.addEventListener('message', h);
    window.parent.postMessage({ type: '__edit_mode_available' }, '*');
    return () => window.removeEventListener('message', h);
  }, []);

  const sessions = pickSessions(sessionCount);

  return (
    <div className="app v3 v8">
      <header className="topbar">
        <div className="brand"><span className="dot-v3"/><span>Open Island · v8 — engineering-aligned</span></div>
        <span className="meta mono">// 只画工程能拿到的</span>
        <div className="spacer"/>
        <span className="meta-pill"><span className="dot"/>10 agents · 15+ terminals · 4 session states</span>
      </header>

      <main className="main main-v3">
        {/* ============================================================
             00 · System
             ============================================================ */}
        <section className="section" data-screen-label="00 System">
          <div className="section-head"><h2>System</h2><span className="tag mono">// 锁定在工程能给的范围内</span><div className="line"/></div>
          <div className="assumption" style={{ display:'grid', gap:10 }}>
            <div>🪩 <b>Pill 是产品</b>。Notch / 会话面板 / 通知 — 同一块形状在变形。形状基因来自 v6 锁定版(平顶 + 圆底)。</div>
            <div>📡 <b>映射真实产品</b>。Agents = <b>10 个 CLI</b>(Claude Code / Codex / Cursor / Gemini / Kimi / OpenCode / Qoder / Qwen / Factory / CodeBuddy)· Terminals & IDEs = <b>15+</b>(Terminal / Ghostty / iTerm2 / WezTerm / Zellij / tmux / cmux / Kaku / VS Code / Cursor / Windsurf / Trae / JetBrains 全家桶)。</div>
            <div>✅ <b>仅画能拿到的</b>:4 种 session 状态(idle / running / waiting / done)、hooks 明确合同(SessionStart / UserPromptSubmit / PreToolUse / PostToolUse / Stop)、agent 颜色区分、快速回复写回 stdin。</div>
            <div>⏳ <b>Staleness</b>(UI 派生 · 工程不变):<code>completed</code> 超过 5 分钟自动视为 stale — 整行降权 + 在 group=state 时归入 idle 组。阈值后续可放 Control Center · 个性化页。</div>
            <div>❌ <b>删除不可赋能项</b>(vs v7):mini progress · ETA 倒计时 · 代码 diff 行数 · hook-missing 警告 · Last-tool-call 详情 · Usage strip。</div>
            <div>🔗 <b>Permission 选项</b>:各 agent prompt 不同 · 本设计稿用 placeholder 标记 · 待工程调研后接入。</div>
          </div>
        </section>

        {/* ============================================================
             01 · Live stage
             ============================================================ */}
        <section className="section" data-screen-label="01 Live stage">
          <div className="section-head"><h2>01 · Live stage</h2><span className="tag mono">// 点 notch / 按钮触发各种状态</span><div className="line"/></div>
          <LiveStage wallpaper={wallpaper} sessionCount={sessionCount} density={density} groupBy={groupBy} sort={sort} stateIndicator={stateIndicator} macbook={macbook} multiStrat={multiStrat}/>
        </section>

        {/* ============================================================
             02 · Pill collapsed states (notch states)
             ============================================================ */}
        <section className="section" data-screen-label="02 Notch states">
          <div className="section-head"><h2>02 · Notch · collapsed states</h2><span className="tag mono">// 5 phase × (single · multi) · 1-to-1 对齐 SessionPhase</span><div className="line"/></div>
          <div className="assumption" style={{ marginBottom:18, fontSize:12.5 }}>
            Phase 完全对齐 <code>Sources/OpenIslandCore/AgentSession.swift</code> 的 <code>SessionPhase</code>:<code>.waitingForApproval</code> · <code>.waitingForAnswer</code> · <code>.running</code> · <code>.completed</code>,加上 UI-only 的 <code>idle</code>(reducer 里没有,代表"无 visible session")。<br/>
            两种 waiting 视觉上共享同一个 v6 <b>UnifiedBars · waiting</b> glyph(外柱交叉脉动),但 label/通知体不同 — approval 来自 <code>PreToolUse</code>,answer 来自 <code>QuestionPrompt</code>。多 session 时默认取最高优先级一条(approval &gt; answer &gt; running &gt; completed)。
          </div>
          <div className="v8-grid four">
            <StateCard num="N1" name="Idle"                       desc="无 visible session · pill 收回" state="idle" w={100}/>
            <StateCard num="N1+" name="Idle · w/ history"         desc="后台有 idle session · 仅显示计数 ×N" state="idle" right="×6" w={140}/>
            <StateCard num="N2" name="Running · single"            desc="1 agent 运行 · priority 策略 · agent dot" state="running" label="Running" agentDot="claude" w={210}/>
            <StateCard num="N3" name="Running · multi"             desc="多 agent · aggregate 策略" state="running" label="3 running" right="×3" w={210}/>
            <StateCard num="N4" name="Needs approval · single"     desc=".waitingForApproval · PreToolUse hook" state="waitingForApproval" label="Approval" agentDot="codex" w={210}/>
            <StateCard num="N5" name="Needs approval · multi"      desc="多 session 等批准 · aggregate" state="waitingForApproval" label="2 needs approval" right="×2" w={240}/>
            <StateCard num="N6" name="Needs answer · single"       desc=".waitingForAnswer · QuestionPrompt" state="waitingForAnswer" label="Answer" agentDot="gemini" w={210}/>
            <StateCard num="N7" name="Needs answer · multi"        desc="多 session 等回答 · aggregate" state="waitingForAnswer" label="2 needs answer" right="×2" w={240}/>
            <StateCard num="N8" name="Completed"                   desc=".completed · tick 描边 · 2s 后收回到 idle" state="completed" label="Done" agentDot="claude" w={210}/>
          </div>
        </section>

        {/* ============================================================
             03 · Panel · group / sort reference grid (static)
             ============================================================ */}
        <section className="section" data-screen-label="03 Panel group/sort">
          <div className="section-head">
            <h2>03 · Session panel · group × sort</h2>
            <span className="tag mono">// spec doc · 实时预览见 01 Live Stage</span>
            <div className="line"/>
          </div>
          <div className="assumption" style={{ marginBottom:18 }}>
            分组和排序是两个 <b>正交</b>维度,列表的样子 = <code>groupBy</code> × <code>sort</code>。<br/>
            <b>Group by</b>: <code>None</code> · <code>State</code>(phase 优先级)· <code>Agent</code>(按 AGENTS 顺序)· <code>Project</code>(按工作目录字母序)。<br/>
            <b>Sort</b>: <code>Attention</code>(等同 sortDefault — waiting 置顶,组内最久优先)· <code>Last update</code>(最近更新优先,纯时间序)。<br/>
            产品里这两个 knob 落在 <b>Control Center · 个性化页</b>。Live Stage(01)的 Tweaks 是这页的设计版预览 — 任何组合都可以现场切。下面 4 张是有代表性的静态对照。默认值 = <code>None</code> + <code>Attention</code>。
          </div>
          <div className="v8-grid two">
            {[
              { num:'P1', name:'None · Attention',     hint:'默认 · waiting 置顶 · 单层列表',           groupBy:'none',    sort:'attention' },
              { num:'P2', name:'State · Attention',    hint:'phase 分组 · idle 折叠 · 锁定要关注的组',  groupBy:'state',   sort:'attention' },
              { num:'P3', name:'Agent · Updated',      hint:'按 agent 分组 · 组内最近更新优先',         groupBy:'agent',   sort:'updated'   },
              { num:'P4', name:'Project · Attention',  hint:'按工作目录分组 · 多 repo 并行场景',        groupBy:'project', sort:'attention' },
            ].map(c => (
              <div key={c.num} className="v7-card">
                <div className="label"><span className="num">{c.num}</span><span className="name">{c.name}</span></div>
                <MiniStage wallpaper={wallpaper}>
                  <div className="oi-pill" data-mode="panel" style={{ width:480 }}>
                    <NotchRow state="waiting" label={null} right={`×${sessions.length}`}/>
                    <PanelBody sessions={sessions} density={density} groupBy={c.groupBy} sort={c.sort} stateIndicator={stateIndicator}/>
                  </div>
                </MiniStage>
                <div className="hint">{c.hint}</div>
              </div>
            ))}
          </div>
        </section>

        {/* ============================================================
             04 · Notifications (5 kinds)
             ============================================================ */}
        <section className="section" data-screen-label="04 Notifications">
          <div className="section-head"><h2>04 · Notifications · 4 种</h2><span className="tag mono">// pill 本体变成通知 · 不堆 card</span><div className="line"/></div>
          <div className="assumption" style={{ marginBottom:18 }}>
            每一种都绑 hook。F1/F2 来自 PreToolUse · F3 来自 agent 主动问 prompt · F4 来自 Stop hook · reply 可写回 stdin。选项文本作为 placeholder 渲染 · 待真实调研。
          </div>
          <div className="v8-grid two">
            {[
              { k:'two',      n:'F1', name:'Permission · 2-option',  hint:'PreToolUse · 选项走真实 agent prompt (TODO)',  w:440 },
              { k:'three',    n:'F2', name:'Permission · 3-option',  hint:'PreToolUse · 选项多于 2 个 · 1/2/3 热键',     w:460 },
              { k:'jump',     n:'F3', name:'Agent prompt · pick',    hint:'agent 主动问 · island 直接选 · 或 jump 回',     w:440 },
              { k:'done',     n:'F4', name:'Task complete',           hint:'Stop hook · reply 会写回 stdin · 2s 自动收回',  w:440 },
            ].map(c => (
              <div key={c.k} className="v7-card">
                <div className="label"><span className="num">{c.n}</span><span className="name">{c.name}</span></div>
                <MiniStage wallpaper={wallpaper}>
                  <div className="oi-pill" data-mode="notif" style={{ width: c.w }}>
                    <NotifBody kind={c.k} onClose={()=>{}}/>
                  </div>
                </MiniStage>
                <div className="hint">{c.hint}</div>
              </div>
            ))}
          </div>
        </section>

        {/* ============================================================
             05 · Edge cases
             ============================================================ */}
        <section className="section" data-screen-label="05 Edge cases">
          <div className="section-head"><h2>05 · Edge cases</h2><span className="tag mono">// 真实使用中会撞到的情况</span><div className="line"/></div>
          <div className="v8-grid two">
            <div className="v7-card">
              <div className="label"><span className="num">E1</span><span className="name">Zero sessions</span></div>
              <MiniStage wallpaper={wallpaper}>
                <div className="oi-pill" data-mode="panel" style={{ width:460 }}>
                  <NotchRow state="idle" label={null} right={null}/>
                  <PanelBody sessions={[]} density={density} variant="default" stateIndicator={stateIndicator}/>
                </div>
              </MiniStage>
              <div className="hint">从未启动 claude/codex · 引导 user 在终端打开会话</div>
            </div>
            <div className="v7-card">
              <div className="label"><span className="num">E2</span><span className="name">MacBook · 物理刘海</span></div>
              <MiniStage wallpaper={wallpaper}>
                <div className="oi-pill macbook" data-mode="panel" style={{ width:540 }}>
                  <div style={{ position:'absolute', top:0, left:'50%', transform:'translateX(-50%)', width:180, height:32, pointerEvents:'none' }}>
                    <svg width="180" height="32" viewBox="0 0 180 32"><path d="M 0 0 H 180 V 16 A 16 16 0 0 1 164 32 H 16 A 16 16 0 0 1 0 16 Z" fill="#000"/></svg>
                  </div>
                  <NotchRow state="waiting" label={null} right="×4" macbook={true}/>
                  <PanelBody sessions={sessions.slice(0,4)} density={density} variant="priority" stateIndicator={stateIndicator}/>
                </div>
              </MiniStage>
              <div className="hint">Pill 包住物理刘海 · 内容贴在两侧 · 整体下垂展开</div>
            </div>
            <div className="v7-card">
              <div className="label"><span className="num">E3</span><span className="name">External display · top-bar</span></div>
              <MiniStage wallpaper={wallpaper}>
                <div className="oi-pill" data-mode="panel" style={{ width:520 }}>
                  <NotchRow state="running" label={null} right="×3"/>
                  <PanelBody sessions={sessions.slice(0,5)} density={density} variant="priority" stateIndicator={stateIndicator}/>
                </div>
              </MiniStage>
              <div className="hint">外接屏没有物理刘海 · pill 自由从顶部 fluid 展开</div>
            </div>
            <div className="v7-card">
              <div className="label"><span className="num">E4</span><span className="name">Many sessions · scroll</span></div>
              <MiniStage wallpaper={wallpaper} height={500}>
                <div className="oi-pill" data-mode="panel" style={{ width:480 }}>
                  <NotchRow state="waiting" label={null} right="×8"/>
                  <PanelBody sessions={pickSessions(8)} density="compact" variant="priority" stateIndicator={stateIndicator}/>
                </div>
              </MiniStage>
              <div className="hint">8+ session 自动滚动 · 配 compact density 一屏看完</div>
            </div>
            <div className="v7-card">
              <div className="label"><span className="num">E5</span><span className="name">Stale completed</span></div>
              <MiniStage wallpaper={wallpaper}>
                <div className="oi-pill" data-mode="panel" style={{ width:480 }}>
                  <NotchRow state="waiting" label={null} right="×8"/>
                  <PanelBody sessions={pickSessions(8)} density={density} groupBy="state" sort="attention" stateIndicator={stateIndicator}/>
                </div>
              </MiniStage>
              <div className="hint">s8 是 completed 但 updatedAt 已 30min · group=state 时归入 idle 组 · 整行降权 (.oi-row.stale)</div>
            </div>
          </div>
        </section>

        {/* ============================================================
             07 · Brand
             ============================================================ */}
        <section className="section" data-screen-label="07 Brand">
          <div className="section-head"><h2>07 · Brand · logo + app icon</h2><span className="tag mono">// 沿用 v6 锁定的 Bar + Dot</span><div className="line"/></div>
          <div className="assumption" style={{ marginBottom:18 }}>
            Logo / App icon 沿用 v6 (locked) 的 <b>L6 · Bar + Dot</b>:粗杠来自 notch 的 Breathing bar(M),尾点来自 Pulse line(I)的扫描亮点停在终点。已定稿,这里只做迁移。
          </div>
          <div className="v8-brand-grid">
            <div className="v8-brand-card">
              <div className="plate" data-tone={tone}><Logo_WordLockup size={460} tone={tone} mark="bardot"/></div>
              <div className="meta"><div className="n">Wordmark lockup</div><div className="d">Bar + Dot mark + "Open / Island"</div></div>
            </div>
            <div className="v8-brand-card">
              <div className="plate" data-tone={tone}><Logo_BarDot size={280} tone={tone}/></div>
              <div className="meta"><div className="n">Primary mark</div><div className="d">独立的 Bar + Dot · 用作 favicon / avatar</div></div>
            </div>
          </div>

          <div className="section-head" style={{ marginTop:24 }}><h3 style={{margin:0,fontSize:15}}>App icons · dock</h3><div className="line"/></div>
          <div className="v8-icons">
            <div className="cell"><AppIcon_BarDot size={128} tone={tone}/><span className="lbl">Bar + Dot</span></div>
            <div className="cell"><AppIcon_BarDot size={128} tone={tone === 'paper' ? 'ink' : 'paper'}/><span className="lbl">Inverse</span></div>
            <div className="cell"><AppIcon_BarDot size={128} tone="bw"/><span className="lbl">B/W</span></div>
            <div className="cell" style={{ display:'flex', flexDirection:'row', gap:10, alignItems:'flex-end' }}>
              {[16,32,64,128].map(sz => <AppIcon_BarDot key={sz} size={sz} tone={tone}/>)}
            </div>
          </div>
        </section>

        {/* ============================================================
             Footer note
             ============================================================ */}
        <section className="section" data-screen-label="08 Notes">
          <div className="section-head"><h2>08 · hand-off · 待工程调研项</h2><span className="tag mono">// engineering follow-ups</span><div className="line"/></div>
          <div className="assumption" style={{ display:'grid', gap:10 }}>
            <div>🔴 <b>待调研</b>:每个 agent 的真实 permission prompt 选项文本。F1/F2 中是占位子 · 调研后需替换为各 agent 自己的选项集。</div>
            <div>1. <b>默认列表行为</b> = <code>group:none + sort:attention</code>(单层列表 · waiting 置顶)。<code>group</code> / <code>sort</code> 落在 Control Center · 个性化页,panel 头部不暴露。</div>
            <div>2. <b>Control Center</b> 仍是独立窗口,不在 v8 design scope 内 · panel 头部齿轮图标负责打开它。</div>
            <div>3. <b>Logo 系统</b>已定:notch shape + 反白 bar + dot,统一 mark / lockup / app icon · 不再做 v3-v5 的方向。</div>
            <div>4. <b>Tweaks</b> 是 design playground:group / sort / state indicator / multi-agent / wallpaper / sessions / density / device / logo tone — 切完 01 Live Stage 实时变。</div>
            <div>5. <b>State indicator 终稿待选</b>:dot / bar(胶囊)/ glyph(v6 UnifiedBars 微缩)/ tint(文字着色)四个候选,选定后保留默认值 · 其余作为 spec 留档或删除。</div>
          </div>
        </section>
      </main>

      <aside className="tweaks" id="tweaks-v8">
        <h3>Tweaks</h3>
        <div className="grp"><div className="grp-title">Group by</div>
          <div className="btn-group">
            <button className={groupBy==='none'?'on':''}    onClick={()=>setGroupBy('none')}>none</button>
            <button className={groupBy==='state'?'on':''}   onClick={()=>setGroupBy('state')}>state</button>
            <button className={groupBy==='agent'?'on':''}   onClick={()=>setGroupBy('agent')}>agent</button>
            <button className={groupBy==='project'?'on':''} onClick={()=>setGroupBy('project')}>project</button>
          </div>
          <div className="hint" style={{ marginTop:6 }}>列表分组维度 · 产品里落在 Control Center · 个性化页</div>
        </div>
        <div className="grp"><div className="grp-title">Sort</div>
          <div className="btn-group">
            <button className={sort==='attention'?'on':''} onClick={()=>setSort('attention')}>attention</button>
            <button className={sort==='updated'?'on':''}   onClick={()=>setSort('updated')}>last update</button>
          </div>
          <div className="hint" style={{ marginTop:6 }}>attention = waiting 置顶 · updated = 纯按时间序</div>
        </div>
        <div className="grp"><div className="grp-title">State indicator</div>
          <div className="btn-group">
            <button className={stateIndicator==='dot'?'on':''}   onClick={()=>setSI('dot')}>dot</button>
            <button className={stateIndicator==='bar'?'on':''}   onClick={()=>setSI('bar')}>bar</button>
            <button className={stateIndicator==='glyph'?'on':''} onClick={()=>setSI('glyph')}>glyph</button>
            <button className={stateIndicator==='tint'?'on':''}  onClick={()=>setSI('tint')}>tint</button>
          </div>
          <div className="hint" style={{ marginTop:6 }}>session row 状态视觉:dot 圆点 · bar 胶囊 · glyph v6 微缩 · tint 文字着色(无 leading)<br/><span style={{opacity:0.7}}>design playground · 终稿后选一种保留作默认,其余作为 spec 留档</span></div>
        </div>
        <div className="grp"><div className="grp-title">Multi-agent · notch</div>
          <div className="btn-group">
            <button className={multiStrat==='priority'?'on':''} onClick={()=>setMS('priority')}>priority</button>
            <button className={multiStrat==='aggregate'?'on':''} onClick={()=>setMS('aggregate')}>aggregate</button>
          </div>
          <div className="hint" style={{ marginTop:6 }}>priority = 取一个 session 显示 · aggregate = 仅显示计数</div>
        </div>
        <div className="grp"><div className="grp-title">Wallpaper</div>
          <div className="btn-group">{['plum','slate','forest','sand'].map(w => <button key={w} className={wallpaper===w?'on':''} onClick={()=>setWall(w)}>{w}</button>)}</div></div>
        <div className="grp"><div className="grp-title">Sessions</div>
          <div className="btn-group">{[0,1,3,6,8].map(n => <button key={n} className={sessionCount===n?'on':''} onClick={()=>setSC(n)}>{n}</button>)}</div></div>
        <div className="grp"><div className="grp-title">Density</div>
          <div className="btn-group"><button className={density==='comfortable'?'on':''} onClick={()=>setDen('comfortable')}>comfortable</button><button className={density==='compact'?'on':''} onClick={()=>setDen('compact')}>compact</button></div></div>
        <div className="grp"><div className="grp-title">Device · live</div>
          <div className="btn-group"><button className={!macbook?'on':''} onClick={()=>setMB(false)}>external</button><button className={macbook?'on':''} onClick={()=>setMB(true)}>MacBook</button></div></div>
        <div className="grp"><div className="grp-title">Logo tone</div>
          <div className="btn-group">{['paper','ink'].map(t => <button key={t} className={tone===t?'on':''} onClick={()=>setTone(t)}>{t}</button>)}</div></div>
        <div className="grp"><div className="grp-title">System</div>
          <div className="hint" style={{ lineHeight:1.55 }}>Pill 是产品。<br/>Notch · panel · notif · control center<br/>= 同一只 pill 的不同状态。</div>
        </div>
      </aside>
    </div>
  );
}

ReactDOM.createRoot(document.getElementById('root')).render(<V8App/>);
