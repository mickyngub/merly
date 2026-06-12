// app.jsx — macOS desktop + right-docked usage panel.
const { useState, useEffect, useRef, useCallback } = React;

/* ---------------- data ---------------- */
const PROVIDERS = [
  { id: 'claude-personal', type: 'claudePersonal', name: 'Claude', account: 'Personal', dir: '~/.claude',
    session: { pct: 12, resetMin: 193 },
    weekly: [ { label: 'All models', pct: 9, reset: 'Thu 7:59 PM' }, { label: 'Sonnet only', pct: 0, reset: 'Thu 7:59 PM' } ] },
  { id: 'claude-work', type: 'claudeWork', name: 'Claude', account: 'Work', dir: '~/.claude-work',
    session: { pct: 58, resetMin: 47 },
    weekly: [ { label: 'All models', pct: 41, reset: 'Mon 9:00 AM' }, { label: 'Opus only', pct: 24, reset: 'Mon 9:00 AM' } ] },
  { id: 'codex', type: 'codex', name: 'Codex', account: 'OpenAI', dir: '~/.codex', active: true,
    session: { pct: 74, resetMin: 112 },
    weekly: [ { label: 'Weekly', pct: 63, reset: 'Sun 12:00 AM' } ] },
  { id: 'kimi', type: 'kimi', name: 'Kimi', account: 'Moonshot', dir: '~/.kimi',
    session: { pct: 4, resetMin: 268 },
    weekly: [ { label: 'Weekly', pct: 6, reset: 'Sun 12:00 AM' } ] },
];

const MOOD_TAG = {
  happy:    { word: 'CHILL', fg: '#1f8a4c', bg: 'rgba(52,199,89,0.16)' },
  content:  { word: 'OK',    fg: '#1f6fd6', bg: 'rgba(31,111,214,0.15)' },
  tired:    { word: 'BUSY',  fg: '#b5710e', bg: 'rgba(232,163,61,0.18)' },
  stressed: { word: 'FRIED', fg: '#d23b3b', bg: 'rgba(229,72,77,0.18)' },
};
function ringColor(pct) { return pct >= 88 ? '#E5484D' : pct >= 66 ? '#E8A33D' : null; }

/* ---------------- icons ---------------- */
const I = {
  refresh: <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M21 12a9 9 0 1 1-2.64-6.36" /><path d="M21 3v6h-6" /></svg>,
  chevR: <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round" strokeLinejoin="round"><path d="M9 6l6 6-6 6" /></svg>,
  chevL: <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round" strokeLinejoin="round"><path d="M15 6l-6 6 6 6" /></svg>,
  clock: <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><circle cx="12" cy="12" r="9" /><path d="M12 7v5l3 2" /></svg>,
  plus: <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M12 5v14M5 12h14" /></svg>,
  folder: <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z" /></svg>,
};

/* ---------------- time helpers ---------------- */
function useClock() {
  const [now, setNow] = useState(Date.now());
  useEffect(() => { const t = setInterval(() => setNow(Date.now()), 1000); return () => clearInterval(t); }, []);
  return now;
}
function fmtDur(ms) {
  if (ms <= 0) return 'now';
  const m = Math.floor(ms / 60000), h = Math.floor(m / 60), mm = m % 60;
  if (h > 0) return `${h}h ${mm}m`;
  const s = Math.floor((ms % 60000) / 1000);
  return `${mm}m ${s}s`;
}
function fmtClock(now) {
  const d = new Date(now);
  let h = d.getHours(); const ap = h >= 12 ? 'PM' : 'AM'; h = h % 12 || 12;
  return `${['Sun','Mon','Tue','Wed','Thu','Fri','Sat'][d.getDay()]} ${h}:${String(d.getMinutes()).padStart(2,'0')} ${ap}`;
}

/* ---------------- ring ---------------- */
function Ring({ pct, color }) {
  const r = 19, c = 2 * Math.PI * r, off = c * (1 - pct / 100);
  const stroke = ringColor(pct) || color;
  return (
    <div className="ring-hold">
      <svg width="50" height="50" viewBox="0 0 50 50">
        <circle cx="25" cy="25" r={r} fill="none" stroke="var(--track)" strokeWidth="4.5" />
        <circle cx="25" cy="25" r={r} fill="none" stroke={stroke} strokeWidth="4.5" strokeLinecap="round"
          strokeDasharray={c} strokeDashoffset={off} style={{ transition: 'stroke-dashoffset 0.55s cubic-bezier(0.32,0.72,0,1), stroke 0.3s' }} />
      </svg>
      <span className="ring-num" style={{ color: stroke }}>{Math.round(pct)}<span style={{ fontSize: 8, fontWeight: 600 }}>%</span></span>
      <span className="ring-cap">used</span>
    </div>
  );
}

/* ---------------- card ---------------- */
function ProviderCard({ p, sessionPct, bob, now, endAt }) {
  const [open, setOpen] = useState(false);
  const mood = moodFromPct(sessionPct);
  const tag = MOOD_TAG[mood];
  const accent = PALETTES[p.type].B;
  const remain = fmtDur(endAt - now);

  return (
    <div className={`card ${open ? 'open' : ''}`} onClick={() => setOpen(o => !o)} data-screen-label={`${p.name} ${p.account}`}>
      <div className="card-top">
        <div className="mascot-hold" onClick={(e) => e.stopPropagation()}>
          <Mascot type={p.type} mood={mood} px={48} bob={bob} className={p.active ? 'busy' : ''} />
          {p.active && <span className="activity" title="active now" />}
        </div>
        <div className="card-id">
          <div className="card-name">{p.name}<span className="acct-chip">{p.account}</span></div>
          <div className="reset-line"><span style={{ width: 11, height: 11, color: 'var(--text3)' }}>{I.clock}</span>Resets in {remain}</div>
          <span className="mood-tag" style={{ color: tag.fg, background: tag.bg }}>{tag.word}</span>
        </div>
        <Ring pct={sessionPct} color={accent} />
      </div>

      <div className="card-detail">
        <div className="detail-inner">
          {p.weekly.map((w, i) => {
            const wc = ringColor(w.pct) || accent;
            return (
              <div className="wk-row" key={i}>
                <div className="wk-head"><span className="wk-label">{w.label}</span><span className="wk-val">{w.pct}% used</span></div>
                <div className="wk-bar"><div className="wk-fill" style={{ width: `${w.pct}%`, background: wc }} /></div>
                <div className="wk-reset">Weekly limit · resets {w.reset}</div>
              </div>
            );
          })}
          <div className="dir-line"><span style={{ width: 12, height: 12 }}>{I.folder}</span><span className="fld">{p.dir}</span></div>
        </div>
      </div>
    </div>
  );
}

/* ---------------- rail (collapsed state) ---------------- */
function Rail({ show, providers, sessions, onExpand }) {
  return (
    <div className={`rail ${show ? 'show' : ''}`} onClick={onExpand} title="Open usage">
      <span className="rail-chev">{I.chevL}</span>
      {providers.map(p => (
        <span className="rail-mini" key={p.id}><Mascot type={p.type} mood={moodFromPct(sessions[p.id])} px={32} bob={false} /></span>
      ))}
    </div>
  );
}

/* ---------------- app ---------------- */
const TWEAK_DEFAULTS = /*EDITMODE-BEGIN*/{
  "appearance": "auto",
  "dockSide": "right",
  "motion": true,
  "usePersonal": 12,
  "useWork": 58,
  "useCodex": 74,
  "useKimi": 4
}/*EDITMODE-END*/;

function App() {
  const [t, setTweak] = useTweaks(TWEAK_DEFAULTS);
  const [collapsed, setCollapsed] = useState(false);
  const [spin, setSpin] = useState(false);
  const now = useClock();

  // theme resolution
  const [sysDark, setSysDark] = useState(() => window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches);
  useEffect(() => {
    if (!window.matchMedia) return;
    const mq = window.matchMedia('(prefers-color-scheme: dark)');
    const h = (e) => setSysDark(e.matches); mq.addEventListener('change', h); return () => mq.removeEventListener('change', h);
  }, []);
  const theme = t.appearance === 'auto' ? (sysDark ? 'dark' : 'light') : t.appearance;

  const sessions = {
    'claude-personal': t.usePersonal, 'claude-work': t.useWork, 'codex': t.useCodex, 'kimi': t.useKimi,
  };

  // fixed reset end-times (computed once so the countdown ticks)
  const endRef = useRef(null);
  if (!endRef.current) { endRef.current = {}; PROVIDERS.forEach(p => { endRef.current[p.id] = Date.now() + p.session.resetMin * 60000; }); }

  const onRefresh = (e) => { e.stopPropagation(); setSpin(true); setTimeout(() => setSpin(false), 650); };

  // peak provider for the menubar extra
  const peak = PROVIDERS.reduce((a, p) => sessions[p.id] > sessions[a.id] ? p : a, PROVIDERS[0]);

  return (
    <div className={`scene ${t.dockSide === 'left' ? 'left' : ''}`} data-theme={theme}>
      <div className="wallpaper" />
      <div className="desk-icons">
        <div className="desk-ic"><div className="gly" /><span>Projects</span></div>
        <div className="desk-ic"><div className="gly" /><span>Screens</span></div>
      </div>

      {/* menu bar */}
      <div className="menubar">
        <span className="brand-dot" />
        <span className="mb-strong">Usage</span>
        <span className="mb-item">File</span>
        <span className="mb-item">View</span>
        <span className="mb-item">Providers</span>
        <span className="mb-right">
          <span className="mb-extra" onClick={() => setCollapsed(c => !c)} title="Toggle usage panel">
            <Mascot type={peak.type} mood={moodFromPct(sessions[peak.id])} px={16} bob={false} />
            <span className="mb-pct" style={{ color: ringColor(sessions[peak.id]) || 'var(--text)' }}>{Math.round(sessions[peak.id])}%</span>
          </span>
          <span className="mb-clock">{fmtClock(now)}</span>
        </span>
      </div>

      {/* collapsed rail */}
      <Rail show={collapsed} providers={PROVIDERS} sessions={sessions} onExpand={() => setCollapsed(false)} />

      {/* dock panel */}
      <div className={`dock ${collapsed ? 'collapsed' : ''}`} data-screen-label="Usage dock">
        <button className="handle" onClick={() => setCollapsed(c => !c)} title="Collapse">{t.dockSide === 'left' ? I.chevL : I.chevR}</button>

        <div className="dock-head">
          <div>
            <div className="dock-title">Usage</div>
            <div className="dock-sub">{PROVIDERS.length} providers · updated just now</div>
          </div>
          <span className="spacer" />
          <button className={`icon-btn ${spin ? 'spin' : ''}`} onClick={onRefresh} title="Refresh">{I.refresh}</button>
        </div>

        <div className="dock-scroll">
          {PROVIDERS.map((p, i) => (
            <div className="fade-in" style={{ animationDelay: `${i * 60}ms` }} key={p.id}>
              <ProviderCard p={p} sessionPct={sessions[p.id]} bob={t.motion} now={now} endAt={endRef.current[p.id]} />
            </div>
          ))}
          <button className="add-card" onClick={(e) => e.preventDefault()}>
            <span className="add-egg">{I.plus}</span>
            <span className="add-txt"><b>Add a provider</b><span>Point it at a config folder</span></span>
          </button>
        </div>
      </div>

      {/* tweaks */}
      <TweaksPanel>
        <TweakSection label="Appearance" />
        <TweakRadio label="Theme" value={t.appearance} options={['auto', 'light', 'dark']} onChange={(v) => setTweak('appearance', v)} />
        <TweakRadio label="Dock side" value={t.dockSide} options={['left', 'right']} onChange={(v) => setTweak('dockSide', v)} />
        <TweakToggle label="Mascot motion" value={t.motion} onChange={(v) => setTweak('motion', v)} />
        <TweakSection label="Simulate usage" />
        <TweakSlider label="Claude · Personal" value={t.usePersonal} min={0} max={100} unit="%" onChange={(v) => setTweak('usePersonal', v)} />
        <TweakSlider label="Claude · Work" value={t.useWork} min={0} max={100} unit="%" onChange={(v) => setTweak('useWork', v)} />
        <TweakSlider label="Codex" value={t.useCodex} min={0} max={100} unit="%" onChange={(v) => setTweak('useCodex', v)} />
        <TweakSlider label="Kimi" value={t.useKimi} min={0} max={100} unit="%" onChange={(v) => setTweak('useKimi', v)} />
      </TweaksPanel>
    </div>
  );
}

ReactDOM.createRoot(document.getElementById('root')).render(<App />);
