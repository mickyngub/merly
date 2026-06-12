// mascots.jsx — pixel "critter" renderer. A family of 16x16 sprites differentiated
// by palette + ear style + accessory, with mood-driven faces. Exports Mascot + helpers.

const PALETTES = {
  claudePersonal: { B:'#E8825C', D:'#C2603C', L:'#F7CBB4', O:'#80391F', E:'#3A2416', W:'#FFFFFF', M:'#8A3D24', C:'#FF9C7E', S:'#8FBFFF', A:'#F7CBB4' },
  claudeWork:     { B:'#5E80AC', D:'#3F5C84', L:'#C6D7EC', O:'#2B3F5C', E:'#1E2A3A', W:'#FFFFFF', M:'#2B3F5C', C:'#F0A2AE', S:'#8FBFFF', A:'#E8825C' },
  codex:          { B:'#41A87C', D:'#2C7E5A', L:'#BFE8D2', O:'#1B5239', E:'#143526', W:'#FFFFFF', M:'#1B5239', C:'#79D6A8', S:'#8FBFFF', A:'#A8ECC8' },
  kimi:           { B:'#8C6DE2', D:'#6A4CC2', L:'#DBCCF7', O:'#432D85', E:'#281A4D', W:'#FFFFFF', M:'#432D85', C:'#F0A2D6', S:'#8FBFFF', A:'#F5D67A' },
};

// mood from a 0..100 "used" figure
function moodFromPct(pct) {
  if (pct >= 88) return 'stressed';
  if (pct >= 66) return 'tired';
  if (pct >= 40) return 'content';
  return 'happy';
}

function blankGrid() {
  const g = [];
  for (let y = 0; y < 16; y++) g.push(new Array(16).fill('.'));
  return g;
}
function setPx(g, x, y, ch) { if (x >= 0 && x < 16 && y >= 0 && y < 16) g[y][x] = ch; }

const BODY_ROWS = { 5:[5,10], 6:[4,11], 7:[3,12], 8:[3,12], 9:[3,12], 10:[3,12], 11:[3,12], 12:[3,12], 13:[4,11], 14:[5,10] };

function buildBase(type) {
  const g = blankGrid();
  // body
  for (const y in BODY_ROWS) { const [a, b] = BODY_ROWS[y]; for (let x = a; x <= b; x++) setPx(g, x, +y, 'B'); }
  // belly highlight
  for (let y = 10; y <= 12; y++) for (let x = 6; x <= 9; x++) setPx(g, x, y, 'L');
  // feet (split the bottom into two)
  setPx(g, 7, 14, '.'); setPx(g, 8, 14, '.');
  setPx(g, 5, 14, 'D'); setPx(g, 6, 14, 'D'); setPx(g, 9, 14, 'D'); setPx(g, 10, 14, 'D');

  if (type === 'claudePersonal' || type === 'claudeWork') {
    // cat / fox ears
    setPx(g, 3, 3, 'B'); setPx(g, 3, 4, 'B'); setPx(g, 4, 4, 'B'); setPx(g, 4, 5, 'B');
    setPx(g, 12, 3, 'B'); setPx(g, 12, 4, 'B'); setPx(g, 11, 4, 'B'); setPx(g, 11, 5, 'B');
    setPx(g, 4, 4, 'D'); setPx(g, 11, 4, 'D');
    if (type === 'claudeWork') { setPx(g, 8, 12, 'A'); setPx(g, 8, 13, 'A'); } // tie
  } else if (type === 'codex') {
    // antenna
    setPx(g, 8, 4, 'A'); setPx(g, 8, 3, 'A'); setPx(g, 7, 2, 'A'); setPx(g, 8, 2, 'A');
    // side bolts
    setPx(g, 3, 9, 'D'); setPx(g, 12, 9, 'D');
  } else if (type === 'kimi') {
    // round ears
    setPx(g, 4, 4, 'B'); setPx(g, 5, 4, 'B'); setPx(g, 4, 5, 'B');
    setPx(g, 10, 4, 'B'); setPx(g, 11, 4, 'B'); setPx(g, 11, 5, 'B');
    // floating crescent moon accent
    setPx(g, 13, 3, 'A'); setPx(g, 13, 4, 'A'); setPx(g, 14, 4, 'A'); setPx(g, 13, 5, 'A');
  }
  return g;
}

const SOLID = { B:1, D:1, L:1, A:1 };
function outline(g) {
  const dirs = [[1,0],[-1,0],[0,1],[0,-1]];
  const adds = [];
  for (let y = 0; y < 16; y++) for (let x = 0; x < 16; x++) {
    if (g[y][x] !== '.') continue;
    let touch = false;
    for (const [dx, dy] of dirs) { const nx = x+dx, ny = y+dy; if (nx>=0&&nx<16&&ny>=0&&ny<16&&SOLID[g[ny][nx]]) { touch = true; break; } }
    if (touch) adds.push([x, y]);
  }
  for (const [x, y] of adds) g[y][x] = 'O';
}

function stampFace(g, mood, blink) {
  const lx = 6, rx = 9; // eye columns
  if (blink && mood !== 'stressed') {
    setPx(g, lx, 8, 'E'); setPx(g, rx, 8, 'E');
    setPx(g, lx, 8, 'E'); setPx(g, rx, 8, 'E');
    // flat smile underneath stays
    setPx(g, 7, 11, 'M'); setPx(g, 8, 11, 'M');
    return;
  }
  if (mood === 'happy') {
    setPx(g, lx, 8, 'E'); setPx(g, rx, 8, 'E');
    setPx(g, 5, 9, 'C'); setPx(g, 10, 9, 'C');           // blush
    setPx(g, 6, 11, 'M'); setPx(g, 9, 11, 'M'); setPx(g, 7, 12, 'M'); setPx(g, 8, 12, 'M'); // smile
  } else if (mood === 'content') {
    setPx(g, lx, 8, 'E'); setPx(g, rx, 8, 'E');
    setPx(g, 7, 11, 'M'); setPx(g, 8, 11, 'M');
  } else if (mood === 'tired') {
    setPx(g, lx, 8, 'E'); setPx(g, rx, 8, 'E');
    setPx(g, 5, 7, 'D'); setPx(g, 6, 7, 'D'); setPx(g, 9, 7, 'D'); setPx(g, 10, 7, 'D'); // heavy lids
    setPx(g, 7, 12, 'M'); setPx(g, 8, 12, 'M');           // low mouth
    setPx(g, 12, 7, 'S'); setPx(g, 12, 8, 'S');           // sweat drop
  } else { // stressed
    setPx(g, 5, 7, 'W'); setPx(g, 6, 7, 'W'); setPx(g, 5, 8, 'W'); setPx(g, 6, 8, 'W'); setPx(g, 6, 8, 'E');
    setPx(g, 9, 7, 'W'); setPx(g, 10, 7, 'W'); setPx(g, 9, 8, 'W'); setPx(g, 10, 8, 'W'); setPx(g, 9, 8, 'E');
    setPx(g, 7, 11, 'M'); setPx(g, 8, 11, 'M'); setPx(g, 7, 12, 'M'); setPx(g, 8, 12, 'M'); // open mouth
    setPx(g, 3, 7, 'S'); setPx(g, 12, 7, 'S');             // sweat
  }
}

function buildSprite(type, mood, blink) {
  const g = buildBase(type);
  outline(g);
  stampFace(g, mood, blink);
  return g;
}

function paint(ctx, grid, pal, S) {
  ctx.clearRect(0, 0, 16 * S, 16 * S);
  ctx.imageSmoothingEnabled = false;
  for (let y = 0; y < 16; y++) for (let x = 0; x < 16; x++) {
    const ch = grid[y][x];
    if (ch === '.') continue;
    ctx.fillStyle = pal[ch] || '#000';
    ctx.fillRect(x * S, y * S, S, S);
  }
}

function Mascot({ type, mood, px = 64, bob = true, className = '', style = {} }) {
  const ref = React.useRef(null);
  const S = Math.max(1, Math.round(px / 16));
  const size = S * 16;

  React.useEffect(() => {
    const cv = ref.current; if (!cv) return;
    const ctx = cv.getContext('2d');
    let raf, blink = false, nextToggle = performance.now() + 2200 + Math.random() * 2600;
    const render = () => paint(ctx, buildSprite(type, mood, blink), PALETTES[type], S);
    render();
    const loop = (now) => {
      if (now >= nextToggle) {
        if (!blink) { blink = true; nextToggle = now + 140; }
        else { blink = false; nextToggle = now + 2200 + Math.random() * 2800; }
        render();
      }
      raf = requestAnimationFrame(loop);
    };
    raf = requestAnimationFrame(loop);
    return () => cancelAnimationFrame(raf);
  }, [type, mood, S]);

  return (
    <span className={`mascot ${bob ? 'mascot-bob' : ''} ${className}`} style={style}>
      <canvas ref={ref} width={size} height={size} style={{ width: size, height: size, imageRendering: 'pixelated', display: 'block' }} />
    </span>
  );
}

Object.assign(window, { Mascot, PALETTES, moodFromPct, buildSprite });
