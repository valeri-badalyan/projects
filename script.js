// ===== Данные игр =====
const games = [
  { title: "Neon Dodge", genre: "action", label: "Экшен", emoji: "⚡", desc: "Аркада на реакцию в неоновом мире. Играй прямо на сайте!", rating: 4.9, platform: "Браузер", color: "#ff2e88", link: "#play" },
  { title: "Память", genre: "puzzle", label: "Головоломка", emoji: "🧱", desc: "Запомни башню из кубиков за 2 секунды и собери её точно так же.", rating: null, tag: "Новинка", platform: "Браузер", color: "#2effa1", link: "#memory" },
  { title: "Pixel Kingdoms", genre: "strategy", label: "Стратегия", emoji: "🏰", desc: "Строй королевство, заключай союзы и захватывай земли.", rating: 4.8, platform: "ПК", color: "#7b5cff" },
  { title: "Void Runner", genre: "action", label: "Экшен", emoji: "🚀", desc: "Космический раннер на бешеной скорости. Скоро!", rating: null, platform: "ПК / Mobile", color: "#19e3ff" },
  { title: "Cube Logic", genre: "puzzle", label: "Головоломка", emoji: "🧩", desc: "200 уровней головоломок с кубами и порталами.", rating: 4.7, platform: "Mobile", color: "#ffd23f" },
  { title: "Tower Tactics", genre: "strategy", label: "Стратегия", emoji: "🛡️", desc: "Tower defense с прокачкой героев и боссами.", rating: 4.6, platform: "ПК / Mobile", color: "#2effa1" },
  { title: "Glitch Maze", genre: "puzzle", label: "Головоломка", emoji: "🌀", desc: "Лабиринт, который меняется каждый раз, когда ты моргаешь.", rating: 4.8, platform: "Браузер", color: "#ff7a2e" },
];

const grid = document.getElementById("gamesGrid");
function renderGames(filter = "all") {
  grid.innerHTML = games
    .filter(g => filter === "all" || g.genre === filter)
    .map(g => `
      <article class="card">
        <div class="card-art" style="background: radial-gradient(circle at 50% 60%, ${g.color}55, ${g.color}11 70%)">
          <span class="badge" style="color:${g.color}">${g.label}</span>${g.emoji}
        </div>
        <div class="card-body">
          <h3>${g.title}</h3>
          <p>${g.desc}</p>
          <div class="card-meta">
            <span class="rating">${g.rating ? "★ " + g.rating : (g.tag || "Скоро")}</span>
            <span class="platform">${g.platform}</span>
          </div>
          ${g.link ? `<a class="card-play" href="${g.link}">Играть ▶</a>` : ""}
        </div>
      </article>`)
    .join("");
}
renderGames();

document.querySelectorAll(".chip").forEach(chip => {
  chip.addEventListener("click", () => {
    document.querySelector(".chip.active").classList.remove("active");
    chip.classList.add("active");
    renderGames(chip.dataset.filter);
  });
});

// ===== Меню на мобильных =====
const burger = document.querySelector(".burger");
const menu = document.querySelector(".menu");
burger.addEventListener("click", () => {
  const open = menu.classList.toggle("open");
  burger.setAttribute("aria-expanded", open);
});
menu.querySelectorAll("a").forEach(a => a.addEventListener("click", () => menu.classList.remove("open")));

// ===== Год в футере, форма =====
document.getElementById("year").textContent = new Date().getFullYear();
document.getElementById("contactForm").addEventListener("submit", e => {
  e.preventDefault();
  e.target.reset();
  document.getElementById("formOk").hidden = false;
});

// ===== Счётчики =====
document.querySelectorAll("[data-count]").forEach(el => {
  const target = parseFloat(el.dataset.count);
  const decimals = parseInt(el.dataset.decimals || "0", 10);
  const start = performance.now();
  const step = now => {
    const t = Math.min((now - start) / 1500, 1);
    el.textContent = (target * (1 - Math.pow(1 - t, 3))).toFixed(decimals) + (t === 1 && !decimals ? "+" : "");
    if (t < 1) requestAnimationFrame(step);
  };
  requestAnimationFrame(step);
});

// ===== Звёздный фон =====
(() => {
  const c = document.getElementById("stars");
  const ctx = c.getContext("2d");
  let stars = [];
  function resize() {
    c.width = c.offsetWidth; c.height = c.offsetHeight;
    stars = Array.from({ length: Math.floor(c.width * c.height / 6000) }, () => ({
      x: Math.random() * c.width, y: Math.random() * c.height,
      r: Math.random() * 1.6 + .2, s: Math.random() * .4 + .1,
    }));
  }
  function draw() {
    ctx.clearRect(0, 0, c.width, c.height);
    for (const st of stars) {
      st.y += st.s;
      if (st.y > c.height) { st.y = 0; st.x = Math.random() * c.width; }
      ctx.fillStyle = `rgba(200,200,255,${st.r / 1.8})`;
      ctx.fillRect(st.x, st.y, st.r, st.r);
    }
    requestAnimationFrame(draw);
  }
  window.addEventListener("resize", resize);
  resize(); draw();
})();

// ===== Мини-игра Neon Dodge =====
(() => {
  const canvas = document.getElementById("game");
  const ctx = canvas.getContext("2d");
  const W = canvas.width, H = canvas.height;
  const overlay = document.getElementById("overlay");
  const overlayTitle = document.getElementById("overlayTitle");
  const scoreEl = document.getElementById("score");
  const bestEl = document.getElementById("best");

  let best = 0;
  try { best = +localStorage.getItem("fdm1-neon-best") || 0; } catch (_) {}
  bestEl.textContent = best;

  const keys = {};
  let player, blocks, gems, particles, score, speed, running = false, last = 0, spawnT = 0, gemT = 0;

  function reset() {
    player = { x: W / 2 - 20, y: H - 60, w: 40, h: 18, vx: 0 };
    blocks = []; gems = []; particles = [];
    score = 0; speed = 3; spawnT = 0; gemT = 0;
  }

  function burst(x, y, color, n = 16) {
    for (let i = 0; i < n; i++) {
      const a = Math.random() * Math.PI * 2, v = Math.random() * 4 + 1;
      particles.push({ x, y, vx: Math.cos(a) * v, vy: Math.sin(a) * v, life: 1, color });
    }
  }

  const hit = (a, b) => a.x < b.x + b.w && a.x + a.w > b.x && a.y < b.y + b.h && a.y + a.h > b.y;

  function update(dt) {
    const dir = (keys.ArrowRight || keys.d || keys.D || keys.touchR ? 1 : 0) - (keys.ArrowLeft || keys.a || keys.A || keys.touchL ? 1 : 0);
    player.vx += dir * 1.2;
    player.vx *= 0.82;
    player.x = Math.max(0, Math.min(W - player.w, player.x + player.vx));

    speed += dt * 0.00025;
    score += dt * 0.01;

    spawnT -= dt;
    if (spawnT <= 0) {
      const w = 30 + Math.random() * 70;
      blocks.push({ x: Math.random() * (W - w), y: -30, w, h: 22, hue: Math.random() * 60 + 300 });
      spawnT = Math.max(220, 700 - speed * 60);
    }
    gemT -= dt;
    if (gemT <= 0) {
      gems.push({ x: Math.random() * (W - 18), y: -20, w: 18, h: 18 });
      gemT = 1800 + Math.random() * 1500;
    }

    const k = dt / 16;
    for (const b of blocks) b.y += speed * k;
    for (const g of gems) g.y += speed * 0.8 * k;
    blocks = blocks.filter(b => b.y < H + 30);

    gems = gems.filter(g => {
      if (hit(player, g)) { score += 50; burst(g.x + 9, g.y + 9, "#19e3ff"); return false; }
      return g.y < H + 20;
    });

    if (blocks.some(b => hit(player, b))) {
      burst(player.x + player.w / 2, player.y, "#ff2e88", 40);
      gameOver();
    }

    for (const p of particles) { p.x += p.vx; p.y += p.vy; p.life -= 0.03; }
    particles = particles.filter(p => p.life > 0);
    scoreEl.textContent = Math.floor(score);
  }

  function draw() {
    ctx.fillStyle = "#06060f";
    ctx.fillRect(0, 0, W, H);
    // сетка
    ctx.strokeStyle = "#ffffff0d";
    const off = (performance.now() / 20) % 40;
    for (let y = off; y < H; y += 40) { ctx.beginPath(); ctx.moveTo(0, y); ctx.lineTo(W, y); ctx.stroke(); }
    for (let x = 0; x < W; x += 40) { ctx.beginPath(); ctx.moveTo(x, 0); ctx.lineTo(x, H); ctx.stroke(); }

    ctx.shadowBlur = 16;
    for (const b of blocks) {
      ctx.shadowColor = ctx.fillStyle = `hsl(${b.hue} 100% 60%)`;
      ctx.fillRect(b.x, b.y, b.w, b.h);
    }
    ctx.shadowColor = ctx.fillStyle = "#19e3ff";
    for (const g of gems) {
      ctx.beginPath();
      ctx.moveTo(g.x + 9, g.y); ctx.lineTo(g.x + 18, g.y + 9);
      ctx.lineTo(g.x + 9, g.y + 18); ctx.lineTo(g.x, g.y + 9);
      ctx.fill();
    }
    if (running) {
      ctx.shadowColor = ctx.fillStyle = "#ffd23f";
      ctx.beginPath();
      ctx.moveTo(player.x + player.w / 2, player.y - 14);
      ctx.lineTo(player.x + player.w, player.y + player.h);
      ctx.lineTo(player.x, player.y + player.h);
      ctx.fill();
    }
    ctx.shadowBlur = 0;
    for (const p of particles) {
      ctx.globalAlpha = p.life;
      ctx.fillStyle = p.color;
      ctx.fillRect(p.x, p.y, 3, 3);
    }
    ctx.globalAlpha = 1;
  }

  function loop(now) {
    const dt = Math.min(now - last, 50);
    last = now;
    if (running) update(dt);
    else for (const p of particles) { p.x += p.vx; p.y += p.vy; p.life -= 0.03; }
    draw();
    requestAnimationFrame(loop);
  }

  function start() {
    reset();
    running = true;
    overlay.classList.add("hidden");
  }

  function gameOver() {
    running = false;
    const s = Math.floor(score);
    if (s > best) {
      best = s;
      try { localStorage.setItem("fdm1-neon-best", best); } catch (_) {}
    }
    bestEl.textContent = best;
    overlayTitle.textContent = `ИГРА ОКОНЧЕНА: ${s}`;
    document.getElementById("startBtn").textContent = "Ещё раз";
    overlay.classList.remove("hidden");
  }

  document.getElementById("startBtn").addEventListener("click", start);
  window.addEventListener("keydown", e => {
    if (["ArrowLeft", "ArrowRight"].includes(e.key) && running) e.preventDefault();
    keys[e.key] = true;
    if ((e.key === " " || e.key === "Enter") && !running && isInView()) { e.preventDefault(); start(); }
  });
  window.addEventListener("keyup", e => { keys[e.key] = false; });

  function isInView() {
    const r = canvas.getBoundingClientRect();
    return r.top < innerHeight && r.bottom > 0;
  }

  // касания: левая/правая половина экрана
  function touch(e) {
    e.preventDefault();
    keys.touchL = keys.touchR = false;
    const r = canvas.getBoundingClientRect();
    for (const t of e.touches) {
      if (t.clientX - r.left < r.width / 2) keys.touchL = true; else keys.touchR = true;
    }
  }
  canvas.addEventListener("touchstart", touch, { passive: false });
  canvas.addEventListener("touchmove", touch, { passive: false });
  canvas.addEventListener("touchend", touch, { passive: false });

  reset();
  requestAnimationFrame(t => { last = t; loop(t); });
})();

// ===== Мини-игра «Память» =====
(() => {
  const COLORS = [
    { name: "розовый", c: "#ff2e88" },
    { name: "голубой", c: "#19e3ff" },
    { name: "жёлтый", c: "#ffd23f" },
    { name: "зелёный", c: "#2effa1" },
    { name: "фиолетовый", c: "#9b5cff" },
  ];
  const SHOW_MS = 2000;
  const $ = id => document.getElementById(id);
  const card = $("memCard"), target = $("memTarget"), build = $("memBuild");
  const timer = $("memTimer"), msg = $("memMsg"), palette = $("memPalette");
  const startBtn = $("memStart"), levelEl = $("memLevel"), bestEl = $("memBest");

  let level = 1, seq = [], built = [], accepting = false, showTimeout = null;
  let best = 0;
  try { best = +localStorage.getItem("fdm1-memory-best") || 0; } catch (_) {}
  bestEl.textContent = best;

  const cube = (i, extra = "") => `<div class="cube ${extra}" style="--c:${COLORS[i].c}" title="${COLORS[i].name}"></div>`;

  function renderTower(el, list, total, wrongAt = -1) {
    let html = "";
    for (let k = 0; k < total; k++) {
      if (k < list.length) html += cube(list[k], (k === wrongAt ? "wrong " : "") + (k === list.length - 1 ? "pop" : ""));
      else html += '<div class="cube slot"></div>';
    }
    el.innerHTML = html;
  }

  function setMsg(text, kind = "") { msg.textContent = text; msg.className = "mem-msg " + kind; }
  function setPalette(on) { palette.querySelectorAll("button").forEach(b => (b.disabled = !on)); }

  palette.innerHTML = COLORS.map((col, i) =>
    `<button type="button" data-i="${i}" style="--c:${col.c}" aria-label="Поставить ${col.name} кубик" disabled></button>`).join("");
  palette.addEventListener("click", e => {
    const b = e.target.closest("button");
    if (b) pick(+b.dataset.i);
  });

  function nextRound() {
    const len = Math.min(2 + level, 10);
    seq = Array.from({ length: len }, () => Math.floor(Math.random() * COLORS.length));
    built = [];
    levelEl.textContent = level;
    renderTower(target, seq, len);
    renderTower(build, [], len);
    card.classList.remove("covered");
    timer.classList.remove("run"); void timer.offsetWidth; timer.classList.add("run");
    setPalette(false);
    accepting = false;
    setMsg(`Запоминай! ${len} кубиков`);
    clearTimeout(showTimeout);
    showTimeout = setTimeout(() => {
      card.classList.add("covered");
      timer.classList.remove("run");
      accepting = true;
      setPalette(true);
      setMsg("Собери башню снизу вверх");
    }, SHOW_MS);
  }

  function pick(i) {
    if (!accepting) return;
    const k = built.length;
    built.push(i);
    if (i !== seq[k]) {
      renderTower(build, built, seq.length, k);
      lose();
      return;
    }
    renderTower(build, built, seq.length);
    if (built.length === seq.length) {
      accepting = false;
      setPalette(false);
      setMsg("Верно! Следующая башня выше", "good");
      level++;
      showTimeout = setTimeout(nextRound, 1000);
    }
  }

  function lose() {
    accepting = false;
    setPalette(false);
    card.classList.remove("covered");
    const passed = level - 1;
    if (passed > best) {
      best = passed;
      try { localStorage.setItem("fdm1-memory-best", best); } catch (_) {}
      bestEl.textContent = best;
    }
    setMsg(`Неправильно! Проигрыш. Пройдено уровней: ${passed}`, "bad");
    startBtn.textContent = "Ещё раз";
    startBtn.hidden = false;
  }

  startBtn.addEventListener("click", () => {
    level = 1;
    startBtn.hidden = true;
    nextRound();
  });

  // пример башни до старта
  seq = [0, 1, 2];
  renderTower(target, seq, 3);
  renderTower(build, [], 3);
})();
