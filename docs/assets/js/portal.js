import { createTerminal } from "./terminal.js";

const portalUrl = document.body.dataset.portal;

function fillSpecs(values) {
  const grid = document.getElementById("spec-grid");
  if (!grid || !values) return;
  const keys = [
    ["decode_width", "Decode width"],
    ["commit_width", "Commit width"],
    ["rob_entries", "ROB entries"],
    ["phys_regs", "Integer registers"],
    ["l1i_kib", "L1I · KiB"],
    ["l1d_kib", "L1D · KiB"],
  ];
  grid.innerHTML = keys
    .map(([k, label]) => {
      const v = values[k];
      if (v === undefined || v === null) return "";
      return `<div><dt>${label}</dt><dd>${v}</dd></div>`;
    })
    .join("");
}

function wrapTables() {
  document.querySelectorAll("main.article table").forEach((table) => {
    if (table.parentElement?.classList.contains("table-scroll")) return;
    const wrap = document.createElement("div");
    wrap.className = "table-scroll";
    wrap.tabIndex = 0;
    wrap.setAttribute("role", "region");
    wrap.setAttribute("aria-label", "Scrollable table");
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
    "<details open><summary>On this page</summary>" +
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
      .join("") + "</details>";
  if (window.matchMedia("(max-width: 960px)").matches) toc.querySelector("details").open = false;
  const observer = new IntersectionObserver((entries) => {
    const visible = entries.filter((e) => e.isIntersecting);
    if (!visible.length) return;
    toc.querySelectorAll("a").forEach((a) => {
      if (a.hash === `#${visible[0].target.id}`) a.setAttribute("aria-current", "location");
      else a.removeAttribute("aria-current");
    });
  }, { rootMargin: "-12% 0px -65% 0px" });
  heads.forEach((h) => observer.observe(h));
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
  const close = () => {
    links?.classList.remove("is-open");
    btn?.setAttribute("aria-expanded", "false");
  };
  links?.addEventListener("click", (ev) => {
    if (ev.target.closest("a, [data-open-term]")) close();
  });
  document.addEventListener("keydown", (ev) => {
    if (ev.key === "Escape" && links?.classList.contains("is-open")) {
      close();
      btn?.focus();
    }
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
  let opener = null;
  const show = () => {
    opener = document.activeElement;
    if (home) root.closest("details").open = true;
    root.classList.add("is-open");
    term.input.focus();
  };
  const hide = () => {
    if (home) root.closest("details").open = false;
    root.classList.remove("is-open");
    opener?.focus();
  };
  openers.forEach((b) => b.addEventListener("click", show));
  closers.forEach((b) => b.addEventListener("click", hide));
  document.addEventListener("keydown", (ev) => {
    if (ev.key === "`" && !["INPUT", "TEXTAREA"].includes(ev.target.tagName)) {
      ev.preventDefault();
      if (home ? root.closest("details").open : root.classList.contains("is-open")) hide();
      else show();
    }
    if (ev.key === "Escape" && (home ? root.closest("details").open : root.classList.contains("is-open"))) hide();
  });
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

  let view = null;
  const diagram = document.getElementById("uarch-diagram");
  if (diagram) {
    const { createExplorer } = await import("./explore-view.js");
    view = createExplorer(diagram, data);
  }

  const termRoot = document.getElementById("term");
  if (termRoot) {
    const term = createTerminal(termRoot, data, {
      focusModule: (id) => view?.focus(id) ?? false,
      toggleFlow: () => view?.toggleFlow(),
      flowLabel: "occupancy playback",
      flowHelp: "play or pause the cycle occupancy",
    });
    wireTerm(term);
  }
}

main().catch((err) => {
  const inspect = document.getElementById("uarch-inspect");
  if (inspect) {
    inspect.textContent =
      "The interactive data could not be loaded. Reload to retry, or use the architecture manual.";
  }
  console.error(err);
});
