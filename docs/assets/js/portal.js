import { createUarchView } from "./uarch-view.js";
import { createTerminal } from "./terminal.js";

const portalUrl = document.body.dataset.portal;

function fillSpecs(values) {
  const grid = document.getElementById("spec-grid");
  if (!grid || !values) return;
  const keys = [
    ["decode_width", "decode"],
    ["rename_width", "rename"],
    ["dispatch_width", "dispatch"],
    ["commit_width", "commit"],
    ["rob_entries", "ROB"],
    ["phys_regs", "int PRF"],
    ["alq_entries", "ALQ"],
    ["brq_entries", "BRQ"],
    ["mdq_entries", "MDQ"],
    ["fpq_entries", "FPQ"],
    ["ioq_entries", "IOQ"],
    ["sq_entries", "SQ"],
    ["l1i_kib", "L1I KiB"],
    ["l1d_kib", "L1D KiB"],
    ["completion_ports", "CDB ports"],
    ["pmp_usable", "PMP usable"],
    ["dirp", "DIRP"],
  ];
  grid.innerHTML = keys
    .map(([k, label]) => {
      const v = values[k];
      if (v === undefined || v === null) return "";
      return `<div><dt>${label}</dt><dd>${v}</dd></div>`;
    })
    .join("");
}

function fillDocs(docs) {
  const grid = document.getElementById("doc-grid");
  if (!grid) return;
  grid.innerHTML = docs
    .map(
      (d) =>
        `<a class="doc-card" href="${d.url}"><h3>${d.title}</h3><p>${d.summary || d.file}</p></a>`,
    )
    .join("");
}

function renderInspect(node) {
  const el = document.getElementById("uarch-inspect");
  if (!el) return;
  if (!node) {
    el.innerHTML =
      '<p class="muted">Click a block for its source. Tokens are RV32 CoreMark (matrix / list / CRC / UART MMIO).</p>';
    return;
  }
  const href = `https://github.com/Kingfish404/raptor-chip/blob/master/${node.file}`;
  const model = [
    node.capacity != null ? `capacity ${node.capacity}` : "",
    node.latency != null ? `latency ${node.latency} cyc` : "",
    node.kind || "",
  ]
    .filter(Boolean)
    .join(" · ");
  el.innerHTML = `
    <strong>${node.short} · ${node.id}</strong>
    <p>${node.summary || "No module comment captured."}</p>
    ${model ? `<p class="muted">${model}</p>` : ""}
    ${node.model_note ? `<p class="muted">${node.model_note}</p>` : ""}
    <p class="muted">${node.file}${node.parent ? " · parent " + node.parent : ""}</p>
    <p><a href="${href}">source</a> · <a href="uarch.html">µarch manual</a></p>`;
}

function wrapTables() {
  document.querySelectorAll("main.article table").forEach((table) => {
    if (table.parentElement?.classList.contains("table-scroll")) return;
    const wrap = document.createElement("div");
    wrap.className = "table-scroll";
    wrap.tabIndex = 0;
    table.replaceWith(wrap);
    wrap.appendChild(table);
  });
}

function bootToc() {
  const article = document.querySelector("main.article");
  const toc = document.getElementById("toc");
  if (!article || !toc) return;
  const heads = [...article.querySelectorAll("h2")];
  if (heads.length < 3) return;
  toc.hidden = false;
  toc.innerHTML =
    "<strong>On this page</strong>" +
    heads
      .map((h) => {
        if (!h.id) {
          h.id = h.textContent
            .trim()
            .toLowerCase()
            .replace(/[^\w]+/g, "-")
            .replace(/^-|-$/g, "");
        }
        return `<a href="#${h.id}">${h.textContent}</a>`;
      })
      .join("");
}

function bootMermaid() {
  const blocks = document.querySelectorAll("pre code.language-mermaid");
  if (!blocks.length) return;
  blocks.forEach((code) => {
    const div = document.createElement("div");
    div.className = "mermaid";
    div.textContent = code.textContent;
    code.parentElement.replaceWith(div);
  });
  const s = document.createElement("script");
  s.src = "https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.min.js";
  s.onload = () => {
    const dark = (window.raptorTheme?.resolved(window.raptorTheme.pref()) || "light") === "dark";
    window.mermaid.initialize({
      startOnLoad: true,
      theme: dark ? "dark" : "neutral",
      securityLevel: "strict",
    });
  };
  document.head.appendChild(s);
}

function bootExplore(data) {
  const list = document.getElementById("payload-list");
  if (list) {
    const insns = data.payload?.instructions || [];
    list.innerHTML = insns
      .map((i) => {
        const color = {
          integer: "#e07a3d",
          branch: "#e9c46a",
          memory: "#2ec4b6",
          system: "#8b7cff",
          mul: "#f4a261",
          fp: "#c77dff",
          mmio: "#d9480f",
        }[i.domain] || "inherit";
        return `<li style="color:${color}"><code>${i.asm}</code> · ${i.domain}${i.kernel ? " / " + i.kernel : ""}</li>`;
      })
      .join("");
  }
  const notes = document.getElementById("model-notes");
  if (notes) {
    const extra = data.trace?.notes || [];
    notes.innerHTML = [...extra, ...(data.model?.notes || [])]
      .map((n) => `<li>${n}</li>`)
      .join("");
  }
}

function bootTheme() {
  const api = window.raptorTheme;
  const buttons = document.querySelectorAll("[data-theme-set]");
  const sync = () => {
    const p = api?.pref() || "auto";
    buttons.forEach((b) => {
      b.setAttribute("aria-pressed", String(b.dataset.themeSet === p));
    });
  };
  buttons.forEach((b) => {
    b.addEventListener("click", () => {
      api?.set(b.dataset.themeSet);
      sync();
    });
  });
  window.addEventListener("raptor-theme", sync);
  sync();
}

function bootNav() {
  const btn = document.querySelector(".nav-toggle");
  const links = document.getElementById("nav-links");
  btn?.addEventListener("click", () => {
    const open = links.classList.toggle("is-open");
    btn.setAttribute("aria-expanded", String(open));
  });
  const here = location.pathname.replace(/\/index\.html$/, "/").replace(/\/$/, "") || "/";
  links?.querySelectorAll("a").forEach((a) => {
    let path = "";
    try {
      path = new URL(a.getAttribute("href"), location.href).pathname;
    } catch {
      return;
    }
    path = path.replace(/\/index\.html$/, "/").replace(/\/$/, "") || "/";
    if (path === here) a.setAttribute("aria-current", "page");
  });
}

function bootCopyButtons() {
  document.querySelectorAll("main.article .highlight").forEach((block) => {
    if (block.querySelector(".copy-code")) return;
    const pre = block.querySelector("pre");
    if (!pre) return;
    const button = document.createElement("button");
    button.type = "button";
    button.className = "copy-code";
    button.textContent = "Copy";
    button.addEventListener("click", async () => {
      const text = pre.innerText;
      try {
        await navigator.clipboard.writeText(text);
        button.textContent = "Copied";
      } catch {
        button.textContent = "Failed";
      }
      window.setTimeout(() => {
        button.textContent = "Copy";
      }, 1400);
    });
    block.append(button);
  });
}

function bootHeadingLinks() {
  document.querySelectorAll("main.article h2, main.article h3").forEach((heading) => {
    if (!heading.id) {
      heading.id = heading.textContent
        .trim()
        .toLowerCase()
        .replace(/[^\w]+/g, "-")
        .replace(/^-|-$/g, "");
    }
    if (heading.querySelector(".heading-link")) return;
    const link = document.createElement("a");
    link.className = "heading-link";
    link.href = `#${heading.id}`;
    link.textContent = "#";
    link.setAttribute("aria-label", `Link to ${heading.textContent.trim()}`);
    heading.append(link);
  });
}

function wireTerm(term) {
  const root = term.root;
  const openers = document.querySelectorAll("[data-open-term]");
  const closers = document.querySelectorAll("[data-term-close]");
  const home = document.body.classList.contains("is-home");
  const show = () => {
    root.classList.add("is-open");
    term.input.focus();
  };
  const hide = () => {
    if (home) return;
    root.classList.remove("is-open");
  };
  openers.forEach((b) => b.addEventListener("click", show));
  closers.forEach((b) => b.addEventListener("click", hide));
  document.addEventListener("keydown", (ev) => {
    if (ev.key === "`" && !["INPUT", "TEXTAREA"].includes(ev.target.tagName)) {
      ev.preventDefault();
      if (home || root.classList.contains("is-open")) hide();
      else show();
    }
    if (ev.key === "Escape") hide();
  });
  if (home) root.classList.add("is-open");
}

async function main() {
  bootTheme();
  bootNav();
  bootToc();
  bootHeadingLinks();
  wrapTables();
  bootCopyButtons();
  bootMermaid();
  if (!portalUrl) return;
  const data = await fetch(portalUrl).then((r) => {
    if (!r.ok) throw new Error(`portal data ${r.status}`);
    return r.json();
  });
  fillSpecs(data.config?.values);
  fillDocs(data.docs || []);

  let view = null;
  const diagram = document.getElementById("uarch-diagram");
  if (diagram) {
    view = createUarchView(diagram, data, {
      onSelect: renderInspect,
      onCycle: (c, _frame, n, playing) => {
        const label = document.getElementById("cycle-readout");
        const slider = document.getElementById("cycle-slider");
        const ipc = data.trace?.ipc;
        if (label) label.textContent = `cycle ${c}/${Math.max(n - 1, 0)}${ipc != null ? ` · IPC ${ipc}` : ""}`;
        if (slider) {
          slider.max = Math.max(n - 1, 0);
          slider.value = String(c);
        }
        document.querySelectorAll("[data-cycle-play], [data-uarch-flow]").forEach((play) => {
          play.textContent = playing ? "Pause" : "Play";
        });
      },
    });
    document.querySelector("[data-uarch-flow]")?.addEventListener("click", () => {
      const on = view.toggleFlow();
      const btn = document.querySelector("[data-uarch-flow]");
      if (btn) btn.textContent = on ? "Pause" : "Play";
    });
    document.querySelector("[data-uarch-reset]")?.addEventListener("click", () => view.reset());
    const playBtn = document.querySelector("[data-cycle-play]");
    playBtn?.addEventListener("click", () => {
      const on = view.toggleFlow();
      playBtn.textContent = on ? "Pause" : "Play";
    });
    document.querySelectorAll("[data-cycle-step]").forEach((b) => {
      b.addEventListener("click", () => view.step(Number(b.dataset.cycleStep) || 1));
    });
    const slider = document.getElementById("cycle-slider");
    slider?.addEventListener("input", () => view.setCycle(Number(slider.value)));
  }
  bootExplore(data);

  const termRoot = document.getElementById("term");
  if (termRoot) {
    const term = createTerminal(termRoot, data, {
      focusModule: (id) => view?.focus(id) ?? false,
      toggleFlow: () => view?.toggleFlow(),
    });
    wireTerm(term);
  }
}

main().catch((err) => {
  const inspect = document.getElementById("uarch-inspect");
  if (inspect) inspect.textContent = String(err);
  console.error(err);
});
