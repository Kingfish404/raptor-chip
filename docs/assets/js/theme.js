(function (w) {
  const KEY = "raptor-theme";
  const root = document.documentElement;

  function pref() {
    try {
      const v = localStorage.getItem(KEY);
      if (v === "light" || v === "dark" || v === "auto") return v;
    } catch (_) { /* private mode */ }
    return "auto";
  }

  function resolved(p) {
    if (p === "light" || p === "dark") return p;
    return w.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
  }

  function apply(p) {
    p = p || pref();
    root.dataset.themePref = p;
    if (p === "auto") root.removeAttribute("data-theme");
    else root.setAttribute("data-theme", p);
    const res = resolved(p);
    root.style.colorScheme = res;
    const meta = document.querySelector('meta[name="theme-color"]');
    if (meta) meta.content = res === "dark" ? "#1a1d24" : "#f4f1ea";
    w.dispatchEvent(new CustomEvent("raptor-theme", { detail: { pref: p, theme: res } }));
  }

  function set(p) {
    if (p !== "light" && p !== "dark" && p !== "auto") p = "auto";
    try { localStorage.setItem(KEY, p); } catch (_) { /* ignore */ }
    apply(p);
  }

  apply();
  const mq = w.matchMedia("(prefers-color-scheme: dark)");
  mq.addEventListener("change", () => {
    if (pref() === "auto") apply("auto");
  });

  w.raptorTheme = { pref, resolved, apply, set };
})(window);
