function escapeHtml(s) {
  return String(s)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;");
}

function linkify(href, label) {
  return `<a href="${href}">${escapeHtml(label)}</a>`;
}

export function createTerminal(root, data, hooks = {}) {
  const out = root.querySelector("#term-out");
  const form = root.querySelector("#term-form");
  const input = root.querySelector("#term-input");
  const history = [];
  let histAt = -1;

  const commands = data.makefile?.commands || [];
  const byName = Object.fromEntries(commands.map((c) => [c.name, c]));
  const docs = data.docs || [];
  const nodes = data.graph?.nodes || [];
  const values = data.config?.values || {};

  function write(html, cls = "") {
    const line = document.createElement("div");
    if (cls) line.className = cls;
    line.innerHTML = html;
    out.appendChild(line);
    out.scrollTop = out.scrollHeight;
  }

  function banner() {
    out.innerHTML = "";
    write(`Raptor documentation shell`, "ok");
    write(
      `Commands are parsed from <span class="dim">${escapeHtml(data.makefile?.file || "Makefile")}</span> and <span class="dim">hdl/</span>. This page does not run Verilator or NEMU.`,
      "dim",
    );
    write(`Type <span class="ok">help</span>. Toggle with <span class="ok">\`</span>.`);
  }

  const handlers = {
    help() {
      write(
        [
          "help                 this list",
          "ls                   documentation pages",
          "cat <page>           first paragraph of a manual page",
          "open <page>          navigate to that page",
          "make                 list Makefile targets (from ## comments)",
          "make <target>        show the recorded description",
          "inspect <module>     RTL node from the extracted graph",
          "config [key]         default preset values",
          "tree                 instantiation parents of display blocks",
          "focus <module>       highlight a block on the schematic",
          "flow                 play or pause the cycle occupancy",
          "payload              show the assembly source feeding the explorer",
          "about                what this shell is",
          "clear                clear the scrollback",
          "github               repository URL",
        ].join("\n"),
      );
    },
    about() {
      write(
        "A static explorer for the published manual. Topology = SystemVerilog instantiations. Numbers = hdl/configs/default. Tokens = RV32 CoreMark from the NPC ELF (matrix, list, CRC, UART MMIO), steered along the documented pipeline and PMA map. This is not a live Verilator trace.",
      );
    },
    payload() {
      const p = data.payload;
      if (!p) {
        write("no payload extracted", "err");
        return;
      }
      write(`${p.file}  XLEN=${p.xlen}`, "ok");
      write(escapeHtml(p.note || ""), "dim");
      const counts = Object.entries(p.counts || {})
        .map(([k, n]) => `${k}:${n}`)
        .join("  ");
      if (counts) write(counts);
      write(
        (p.instructions || [])
          .map((i) => `${i.domain.padEnd(8)} ${i.asm}`)
          .join("\n"),
      );
    },
    clear() {
      banner();
    },
    github() {
      write(linkify(data.github, data.github));
    },
    ls() {
      write(
        docs
          .map((d) => `${d.name.padEnd(22)} ${d.title}`)
          .join("\n"),
      );
    },
    tree() {
      const display = nodes.filter((n) => n.display);
      write(
        display
          .map((n) => `${(n.parent || "—").padEnd(22)} → ${n.id}`)
          .join("\n"),
      );
    },
    config(args) {
      if (args[0]) {
        const key = args[0];
        if (key in values) write(`${key} = ${values[key]}`);
        else write(`unknown key ${escapeHtml(key)}`, "err");
        return;
      }
      write(
        Object.entries(values)
          .map(([k, v]) => `${k.padEnd(22)} ${v}`)
          .join("\n"),
      );
      write(`source: ${data.config?.preset}`, "dim");
    },
    cat(args) {
      const q = args.join(" ").toLowerCase();
      const page = docs.find(
        (d) =>
          d.name.toLowerCase() === q ||
          d.name.toLowerCase().startsWith(q) ||
          d.title.toLowerCase().includes(q),
      );
      if (!page) {
        write("not found. try ls", "err");
        return;
      }
      write(`# ${escapeHtml(page.title)}`);
      write(escapeHtml(page.summary || ""));
      write(linkify(page.url, page.url), "dim");
    },
    open(args) {
      const q = args.join(" ").toLowerCase();
      const page = docs.find(
        (d) =>
          d.name.toLowerCase().includes(q) || d.title.toLowerCase().includes(q),
      );
      if (!page) {
        write("not found", "err");
        return;
      }
      write(`opening ${page.url}`);
      window.location.href = page.url;
    },
    make(args) {
      if (!args.length) {
        const bySec = new Map();
        for (const c of commands) {
          if (!bySec.has(c.section)) bySec.set(c.section, []);
          bySec.get(c.section).push(c);
        }
        for (const [sec, list] of bySec) {
          write(`\n${sec}:`, "ok");
          for (const c of list.slice(0, 24)) {
            write(`  ${c.name.padEnd(22)} ${escapeHtml(c.description)}`);
          }
          if (list.length > 24) write(`  … ${list.length - 24} more. make <target>`, "dim");
        }
        return;
      }
      const name = args[0];
      const cmd = byName[name];
      if (!cmd) {
        const hits = commands.filter((c) => c.name.includes(name)).slice(0, 8);
        write(`no target ${escapeHtml(name)}`, "err");
        if (hits.length) write(hits.map((c) => `  ${c.name}`).join("\n"), "dim");
        return;
      }
      write(`target: ${cmd.name}`, "ok");
      write(`section: ${cmd.section}`);
      write(escapeHtml(cmd.description));
      write("This shell does not invoke make(1).", "dim");
    },
    inspect(args) {
      const q = args.join("_").toLowerCase();
      const node = nodes.find(
        (n) =>
          n.id.toLowerCase() === q ||
          n.id.toLowerCase() === `rapt_${q}` ||
          n.short?.toLowerCase() === q,
      );
      if (!node) {
        write("unknown module. try tree", "err");
        return;
      }
      write(`${node.id}`, "ok");
      write(`file     ${node.file}`);
      write(`domain   ${node.domain}`);
      write(`parent   ${node.parent || "—"}`);
      if (node.summary) write(escapeHtml(node.summary));
      hooks.focusModule?.(node.id);
    },
    focus(args) {
      const id = args[0];
      if (!id) {
        write("focus <module>", "dim");
        return;
      }
      const ok = hooks.focusModule?.(id);
      write(ok === false ? "module not on the schematic" : `focus ${escapeHtml(id)}`, ok === false ? "err" : "ok");
    },
    flow() {
      const on = hooks.toggleFlow?.();
      write(`pipeline tokens ${on ? "on" : "off"}`);
    },
  };

  function run(line) {
    const trimmed = line.trim();
    if (!trimmed) return;
    write(`raptor$ ${escapeHtml(trimmed)}`, "dim");
    const parts = trimmed.split(/\s+/);
    let cmd = parts[0];
    let args = parts.slice(1);
    if (cmd === "make" || handlers[cmd]) {
      handlers[cmd](args);
      return;
    }
    if (byName[cmd]) {
      handlers.make([cmd, ...args]);
      return;
    }
    write(`command not found: ${escapeHtml(cmd)}. try help`, "err");
  }

  form.addEventListener("submit", (ev) => {
    ev.preventDefault();
    const line = input.value;
    input.value = "";
    history.push(line);
    histAt = history.length;
    run(line);
  });

  input.addEventListener("keydown", (ev) => {
    if (ev.key === "ArrowUp") {
      ev.preventDefault();
      histAt = Math.max(0, histAt - 1);
      input.value = history[histAt] || "";
    } else if (ev.key === "ArrowDown") {
      ev.preventDefault();
      histAt = Math.min(history.length, histAt + 1);
      input.value = history[histAt] || "";
    } else if (ev.key === "Tab") {
      ev.preventDefault();
      const cur = input.value;
      const names = [
        ...Object.keys(handlers),
        ...commands.map((c) => c.name),
        ...nodes.filter((n) => n.display).map((n) => n.short),
      ];
      const hit = names.find((n) => n.startsWith(cur.split(/\s+/).at(-1) || ""));
      if (hit) {
        const parts = cur.split(/\s+/);
        parts[parts.length - 1] = hit;
        input.value = parts.join(" ");
      }
    }
  });

  banner();
  return { run, banner, input, root };
}
