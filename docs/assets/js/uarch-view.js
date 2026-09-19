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
  ["rapt_l1i", "rapt_ifu"],
  ["rapt_bpu", "rapt_ifu"],
  ["rapt_ifu", "rapt_fqu"],
  ["rapt_fqu", "rapt_idu"],
  ["rapt_idu", "rapt_rnu"],
  ["rapt_prf", "rapt_rnu"],
  ["rapt_rnu", "rapt_rou"],
  ["rapt_rou", "rapt_dpu"],
  ["rapt_dpu", "rapt_ieu"],
  ["rapt_dpu", "rapt_feu"],
  ["rapt_dpu", "rapt_lsu"],
  ["rapt_ieu", "rapt_cdb_arb"],
  ["rapt_feu", "rapt_cdb_arb"],
  ["rapt_lsu", "rapt_cdb_arb"],
  ["rapt_cdb_arb", "rapt_cmu"],
  ["rapt_lsu", "rapt_l1d"],
  ["rapt_l1d", "rapt_bus"],
  ["rapt_bus", "rapt_l2"],
  ["rapt_l2", "rapt_axi_master"],
  ["rapt_axi_master", "soc_pmem"],
  ["rapt_axi_master", "rapt_router"],
  ["rapt_router", "soc_uart"],
  ["rapt_router", "rapt_clint"],
  ["rapt_router", "rapt_plic"],
];

const GROUPS = [
  { label: "Pipeline", ids: ["rapt_bpu", "rapt_l1i", "rapt_ifu", "rapt_fqu", "rapt_idu", "rapt_rnu", "rapt_prf", "rapt_fpr", "rapt_pmp_state", "rapt_rou", "rapt_dpu", "rapt_ieu", "rapt_feu", "rapt_lsu", "rapt_cdb_arb", "rapt_cmu", "rapt_csr"] },
  { label: "Memory and peripherals", ids: ["rapt_l1d", "rapt_bus", "rapt_l2", "rapt_axi_master", "soc_pmem", "rapt_router", "soc_uart", "rapt_clint", "rapt_plic", "rapt_dm"] },
];

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

function port(n, toward) {
  const b = boxOf(n);
  const dx = toward.x - n.x;
  const dy = toward.z - n.z;
  if (Math.abs(dx) >= Math.abs(dy)) {
    return { x: b.cx + Math.sign(dx || 1) * b.w / 2, y: b.cy };
  }
  return { x: b.cx, y: b.cy + Math.sign(dy || 1) * b.h / 2 };
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

  GROUPS.forEach((g) => {
    const boxes = g.ids.map((id) => byId[id]).filter((n) => n?.sx);
    if (!boxes.length) return;
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
    svg.append(
      el("rect", {
        class: "uarch-group",
        x: x0 - 8,
        y: y0 - 16,
        width: x1 - x0 + 16,
        height: y1 - y0 + 22,
        rx: 8,
      }),
      el("text", { class: "uarch-group-label", x: x0, y: y0 - 4 }, [g.label]),
    );
  });

  SPINE.forEach(([from, to]) => {
    const a = byId[from];
    const b = byId[to];
    if (!a?.sx || !b?.sx) return;
    const p1 = port(a, b);
    const p2 = port(b, a);
    svg.append(
      el("line", {
        class: "uarch-edge",
        x1: p1.x,
        y1: p1.y,
        x2: p2.x,
        y2: p2.y,
        markerEnd: "url(#uarch-arrow)",
      }),
    );
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
