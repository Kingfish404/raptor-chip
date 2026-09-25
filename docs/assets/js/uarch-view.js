const NS = "http://www.w3.org/2000/svg";
const S = 16;

const DOMAIN_COLOR = {
  frontend: "#c45e22",
  bpu: "#b7791f",
  backend: "#5b4fd6",
  ieu: "#4c6ef5",
  feu: "#9c36b5",
  lsu: "#0c8599",
  memory: "#0f7f76",
  cluster: "#9a7420",
  core: "#495057",
  common: "#868e96",
  vpu: "#1971c2",
  other: "#868e96",
};

const TOKEN_COLOR = {
  integer: "#c45e22",
  branch: "#9a7420",
  memory: "#0f7f76",
  system: "#5b4fd6",
  mul: "#b7791f",
  fp: "#9c36b5",
  mmio: "#d9480f",
};

const SHELLS = new Set(["rapt", "rapt_core", "rapt_frontend", "rapt_backend"]);

const SPINE = [
  ["rapt_bpu", "rapt_l1i"],
  ["rapt_l1i", "rapt_ifu"],
  ["rapt_ifu", "rapt_fqu"],
  ["rapt_fqu", "rapt_idu"],
  ["rapt_idu", "rapt_rnu"],
  ["rapt_rnu", "rapt_rou"],
  ["rapt_rou", "rapt_dpu"],
  ["rapt_dpu", "rapt_ieu"],
  ["rapt_dpu", "rapt_ieu_muldiv"],
  ["rapt_dpu", "rapt_feu"],
  ["rapt_dpu", "rapt_lsu"],
  ["rapt_ieu", "rapt_cdb_arb"],
  ["rapt_ieu_muldiv", "rapt_cdb_arb"],
  ["rapt_feu", "rapt_cdb_arb"],
  ["rapt_lsu", "rapt_cdb_arb"],
  ["rapt_cdb_arb", "rapt_cmu"],
  ["rapt_lsu", "rapt_l1d"],
  ["rapt_l1d", "rapt_bus"],
  ["rapt_bus", "rapt_l2"],
  ["rapt_l2", "rapt_axi_master"],
  ["rapt_axi_master", "soc_pmem"],
  ["rapt_axi_master", "rapt_router"],
  ["rapt_router", "rapt_plic"],
  ["rapt_router", "soc_uart"],
  ["rapt_plic", "rapt_clint"],
  ["rapt_router", "rapt_dm"],
];

const FRONTEND_IDS = ["rapt_bpu", "rapt_l1i", "rapt_ifu", "rapt_fqu", "rapt_idu", "rapt_rnu", "rapt_prf", "rapt_fpr", "rapt_pmp_state"];
const BACKEND_IDS = ["rapt_rou", "rapt_dpu", "rapt_ieu", "rapt_ieu_muldiv", "rapt_feu", "rapt_lsu", "rapt_cdb_arb", "rapt_cmu", "rapt_csr"];
const MEMORY_IDS = ["rapt_l1d", "rapt_bus", "rapt_l2", "rapt_axi_master", "soc_pmem", "rapt_router", "soc_uart", "rapt_clint", "rapt_plic", "rapt_dm"];

function el(name, attrs = {}, children = []) {
  const node = document.createElementNS(NS, name);
  Object.entries(attrs).forEach(([k, v]) => {
    if (v != null) node.setAttribute(k, String(v));
  });
  children.forEach((c) => {
    node.append(typeof c === "string" ? document.createTextNode(c) : c);
  });
  return node;
}

function boxOf(n) {
  return {
    x: (n.x - n.sx / 2) * S,
    y: (n.z - n.sz / 2) * S,
    w: n.sx * S,
    h: n.sz * S,
    cx: n.x * S,
    cy: n.z * S,
  };
}

function sidePoint(n, side) {
  const b = boxOf(n);
  if (side === "left") return { x: b.x, y: b.cy };
  if (side === "right") return { x: b.x + b.w, y: b.cy };
  if (side === "top") return { x: b.cx, y: b.y };
  return { x: b.cx, y: b.y + b.h };
}

function route(a, b) {
  const A = boxOf(a);
  const B = boxOf(b);
  const dx = B.cx - A.cx;
  const dy = B.cy - A.cy;
  const sameRow = Math.abs(dy) < Math.min(A.h, B.h) * 0.45;
  const sameCol = Math.abs(dx) < Math.min(A.w, B.w) * 0.45;
  if (sameRow) {
    const dir = dx >= 0 ? "right" : "left";
    return [sidePoint(a, dir), sidePoint(b, dx >= 0 ? "left" : "right")];
  }
  if (sameCol) {
    const dir = dy >= 0 ? "bottom" : "top";
    return [sidePoint(a, dir), sidePoint(b, dy >= 0 ? "top" : "bottom")];
  }
  const nearColumn = Math.abs(dx) < Math.max(A.w, B.w) * 1.8;
  if (nearColumn) {
    const xGutter = dx >= 0 ? (A.x + A.w + B.x) / 2 : (B.x + B.w + A.x) / 2;
    const start = sidePoint(a, dx >= 0 ? "right" : "left");
    const end = sidePoint(b, dx >= 0 ? "left" : "right");
    return [start, { x: xGutter, y: start.y }, { x: xGutter, y: end.y }, end];
  }
  const start = sidePoint(a, dy >= 0 ? "bottom" : "top");
  const end = sidePoint(b, dy >= 0 ? "top" : "bottom");
  const gutterY = dy >= 0 ? (A.y + A.h + B.y) / 2 : (B.y + B.h + A.y) / 2;
  return [start, { x: start.x, y: gutterY }, { x: end.x, y: gutterY }, end];
}

export function createUarchView(root, data, hooks = {}) {
  const nodes = (data.graph?.nodes || []).filter((n) => n.display && !SHELLS.has(n.id) && n.sx);
  const byId = Object.fromEntries((data.graph?.nodes || []).map((n) => [n.id, n]));
  const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  const insns = data.payload?.instructions || [];
  const cycleSec = data.model?.cycle_seconds || 0.18;
  const frames = data.trace?.frames || [];
  let cycle = 0;
  let playing = !reduceMotion && frames.length > 0;
  let lastTick = performance.now();
  let selected = null;
  const blockEls = new Map();

  let minx = Infinity;
  let miny = Infinity;
  let maxx = -Infinity;
  let maxy = -Infinity;
  nodes.forEach((n) => {
    const b = boxOf(n);
    minx = Math.min(minx, b.x);
    miny = Math.min(miny, b.y);
    maxx = Math.max(maxx, b.x + b.w);
    maxy = Math.max(maxy, b.y + b.h);
  });
  const pad = 28;
  const vb = `${minx - pad} ${miny - pad - 16} ${maxx - minx + pad * 2} ${maxy - miny + pad * 2 + 16}`;

  const svg = el("svg", {
    viewBox: vb,
    role: "img",
    "aria-label": "Raptor pipeline block diagram",
    class: "uarch-diagram",
  });
  svg.append(
    el("defs", {}, [
      el("marker", {
        id: "uarch-arrow",
        viewBox: "0 0 10 10",
        refX: "9",
        refY: "5",
        markerWidth: "7",
        markerHeight: "7",
        orient: "auto-start-reverse",
      }, [
        el("path", { d: "M 0 0 L 10 5 L 0 10 z", fill: "currentColor" }),
      ]),
    ]),
  );

  function bounds(ids, padX, padTop, padBottom) {
    const boxes = ids.map((id) => byId[id]).filter((n) => n?.sx);
    if (!boxes.length) return null;
    let x0 = Infinity;
    let y0 = Infinity;
    let x1 = -Infinity;
    let y1 = -Infinity;
    boxes.forEach((n) => {
      const b = boxOf(n);
      x0 = Math.min(x0, b.x);
      y0 = Math.min(y0, b.y);
      x1 = Math.max(x1, b.x + b.w);
      y1 = Math.max(y1, b.y + b.h);
    });
    return {
      x: x0 - padX,
      y: y0 - padTop,
      width: x1 - x0 + padX * 2,
      height: y1 - y0 + padTop + padBottom,
      labelX: x0,
      labelY: y0 - 4,
    };
  }
  function frame(ids, label, cls, padX, padTop, padBottom) {
    const b = bounds(ids, padX, padTop, padBottom);
    if (!b) return;
    svg.append(
      el("rect", { class: cls, x: b.x, y: b.y, width: b.width, height: b.height, rx: 8 }),
      el("text", { class: "uarch-group-label", x: b.labelX, y: b.labelY }, [label]),
    );
  }
  frame([...FRONTEND_IDS, ...BACKEND_IDS], "Pipeline", "uarch-group uarch-group-outer", 16, 28, 12);
  frame(FRONTEND_IDS, "Frontend", "uarch-group", 8, 16, 8);
  frame(BACKEND_IDS, "Backend", "uarch-group", 8, 16, 8);
  frame(MEMORY_IDS, "Memory", "uarch-group", 8, 16, 8);

  SPINE.forEach(([from, to]) => {
    const a = byId[from];
    const b = byId[to];
    if (!a?.sx || !b?.sx) return;
    const pts = route(a, b);
    const d = pts.map((p, i) => `${i === 0 ? "M" : "L"} ${p.x} ${p.y}`).join(" ");
    svg.append(el("path", { class: "uarch-edge", d, "marker-end": "url(#uarch-arrow)" }));
  });

  nodes.forEach((n) => {
    const b = boxOf(n);
    const accent = DOMAIN_COLOR[n.domain] || "#868e96";
    const fill = el("rect", { class: "uarch-occ", x: b.x + 6, y: b.y + b.h, width: b.w - 8, height: 0 });
    const meta = el("text", { class: "uarch-meta", x: b.x + 12, y: b.y + 36 }, [""]);
    const dots = el("g", { class: "uarch-dots" });
    const g = el("g", { class: "uarch-block", "data-id": n.id, tabindex: "0" }, [
      el("rect", { class: "uarch-body", x: b.x, y: b.y, width: b.w, height: b.h, rx: 6 }),
      el("rect", { fill: accent, x: b.x, y: b.y, width: 5, height: b.h, rx: 2 }),
      fill,
      el("text", { class: "uarch-title", x: b.x + 12, y: b.y + 20 }, [n.short || n.id]),
      meta,
      dots,
    ]);
    g.addEventListener("click", () => select(n));
    g.addEventListener("keydown", (ev) => {
      if (ev.key === "Enter" || ev.key === " ") {
        ev.preventDefault();
        select(n);
      }
    });
    svg.append(g);
    blockEls.set(n.id, { n, b, fill, meta, dots, g, accent });
  });

  root.replaceChildren(svg);

  function occOf(id) {
    if (!frames.length) return [];
    const c = Math.max(0, Math.min(frames.length - 1, cycle));
    return frames[c].occ?.[id] || [];
  }

  function select(node) {
    selected = node;
    blockEls.forEach((rec, id) => {
      rec.g.classList.toggle("is-active", node && id === node.id);
    });
    hooks.onSelect?.(node);
  }

  function paint() {
    blockEls.forEach((rec, id) => {
      const occ = occOf(id);
      const cap = rec.n.capacity || 0;
      const fillH = cap ? Math.min(1, occ.length / cap) * (rec.b.h - 4) : 0;
      rec.fill.setAttribute("y", String(rec.b.y + rec.b.h - fillH));
      rec.fill.setAttribute("height", String(fillH));
      rec.fill.setAttribute("fill", rec.accent);
      rec.fill.setAttribute("opacity", "0.22");
      rec.meta.textContent = [
        cap ? `${occ.length}/${cap}` : "",
        rec.n.latency != null ? `${rec.n.latency} cyc` : "",
      ]
        .filter(Boolean)
        .join(" · ");
      rec.dots.replaceChildren(
        ...occ.slice(0, 8).map((idx, k) => {
          const inst = insns[idx];
          return el("circle", {
            cx: rec.b.x + 16 + k * 11,
            cy: rec.b.y + rec.b.h - 12,
            r: 4,
            fill: TOKEN_COLOR[inst?.domain] || rec.accent,
          });
        }),
      );
    });
  }

  function emitCycle() {
    hooks.onCycle?.(cycle, frames[cycle], frames.length, playing);
    paint();
  }

  function loop() {
    if (playing && frames.length) {
      const now = performance.now();
      if (now - lastTick >= cycleSec * 1000) {
        cycle = (cycle + 1) % frames.length;
        lastTick = now;
        emitCycle();
      }
    }
    requestAnimationFrame(loop);
  }

  paint();
  requestAnimationFrame(loop);

  const legend = document.getElementById("uarch-legend");
  if (legend) {
    const ipc = data.trace?.ipc;
    legend.textContent = `pipeline block diagram · occupancy = contract-cycle model${ipc != null ? ` · IPC ${ipc}` : ""}`;
  }

  return {
    focus(id) {
      const node = byId[id] || nodes.find((n) => n.short === id);
      if (!node) return false;
      select(node);
      return true;
    },
    reset() {
      select(null);
    },
    toggleFlow() {
      playing = !playing;
      lastTick = performance.now();
      return playing;
    },
    setPlaying(on) {
      playing = !!on;
      lastTick = performance.now();
    },
    step(delta) {
      if (!frames.length) return cycle;
      playing = false;
      cycle = (cycle + delta + frames.length) % frames.length;
      emitCycle();
      return cycle;
    },
    setCycle(c) {
      if (!frames.length) return 0;
      playing = false;
      cycle = Math.max(0, Math.min(frames.length - 1, c | 0));
      emitCycle();
      return cycle;
    },
    cycleCount() {
      return frames.length;
    },
    isPlaying() {
      return playing;
    },
    nodes,
  };
}
