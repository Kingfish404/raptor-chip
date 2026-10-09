#!/usr/bin/env python3
"""Check preset macro references without confusing disabled switches with typos.

This is a source audit, not a preprocessor: both XLEN branches and disabled
branches count as references. The unused check conservatively counts any
occurrence outside the defining line, including comments and a macro's own ifndef.
Local RTL definitions and shared include defaults are valid declarations.
"""

import argparse
from collections import defaultdict
from pathlib import Path
import re
import subprocess


NAME = r"RAPT_[A-Za-z0-9_]+"
DEFINE = re.compile(r"^\s*`define\s+(" + NAME + r")", re.M)
REFERENCE = re.compile(r"`(?:ifdef|ifndef|elsif)\s+(" + NAME + r")|`(" + NAME + r")")
DIRECTIONS = {"RAPT_BPU_DIRP_" + name for name in ("TAGE", "GSHARE", "BIMODAL", "STATIC")}


def source_text(text):
    """Ignore comments, while retaining newlines for diagnostic locations."""
    return re.sub(r'/\*.*?\*/|//[^\n]*',
                  lambda match: "\n" * match[0].count("\n"), text, flags=re.S)


def read_manifest(path, columns):
    rows = set()
    for number, line in enumerate(path.read_text().splitlines(), 1):
        entry, _, reason = line.partition("#")
        if not entry.strip():
            continue
        fields = tuple(entry.split())
        if len(fields) != columns or not reason.strip():
            raise ValueError(f"{path}:{number}: expected {columns} fields and a # reason")
        rows.add(fields)
    return rows


def audit(root):
    # rg honors ignored build directories and includes new, untracked sources.
    names = subprocess.check_output(
        ["rg", "--files", "hdl", "sim", "verify", "lspd", "fpga"],
        cwd=root, text=True).splitlines()
    texts = {}
    uses = set()
    for name in names:
        # Audit declarations/waivers must not make themselves look like consumers.
        if name in ("verify/scripts/config_macro_optional.txt",
                    "verify/scripts/config_macro_pending.txt"):
            continue
        path = root / name
        try:
            raw = path.read_text()
        except (UnicodeDecodeError, OSError):
            continue
        # Declarations in different presets are not uses of each other.
        # Keep other names in define bodies, plus conditional/comment references.
        for line in raw.splitlines():
            references = set(re.findall(NAME, line))
            declaration = DEFINE.match(line)
            if declaration:
                references.discard(declaration[1])
            uses.update(references)
        if path.suffix in (".sv", ".svh") and name.startswith("hdl/"):
            texts[path] = source_text(raw)

    shared = {p: s for p, s in texts.items() if "configs" not in p.relative_to(root).parts}
    defaults = set().union(*(set(DEFINE.findall(s)) for p, s in shared.items()
                             if p.is_relative_to(root / "hdl/include")))
    optional = {row[0] for row in read_manifest(
        root / "verify/scripts/config_macro_optional.txt", 1)} | DIRECTIONS
    findings = []
    for preset in sorted((root / "hdl/configs").glob("*/rapt_config.svh")):
        config = preset.parent.name
        text = source_text(preset.read_text())
        defined = set(DEFINE.findall(text))
        for name in sorted(defined - uses):
            findings.append((config, "unused", name, str(preset.relative_to(root))))
        selected = {name for name in defined if name.startswith("RAPT_BPU_DIRP_")}
        if len(selected) != 1 or not selected <= DIRECTIONS:
            findings.append((config, "direction", ",".join(sorted(selected)) or "none",
                             "expected exactly one supported direction predictor"))
        missing = defaultdict(list)
        for path, source in {**shared, preset: text}.items():
            declared = defined | defaults | set(DEFINE.findall(source)) | optional
            for match in REFERENCE.finditer(source):
                name = match[1] or match[2]
                if name not in declared:
                    line = source.count("\n", 0, match.start()) + 1
                    missing[name].append(f"{path.relative_to(root)}:{line}")
        for name, locations in sorted(missing.items()):
            findings.append((config, "undefined", name, ", ".join(locations)))
    return findings


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    args = parser.parse_args()
    root = args.root.resolve()
    pending = read_manifest(root / "verify/scripts/config_macro_pending.txt", 3)
    if any(row[0] != "default-w4" for row in pending):
        parser.error("only the read-only default-w4 preset may have allowed-pending findings")
    findings = audit(root)
    errors = 0
    found = set()
    for config, kind, name, detail in findings:
        key = (config, kind, name)
        found.add(key)
        allowed = key in pending
        errors += not allowed
        print(f"{'allowed-pending' if allowed else 'FAIL'}: {config} {kind} {name}: {detail}")
    for stale in sorted(pending - found):
        errors += 1
        print(f"FAIL: stale allowed-pending entry: {' '.join(stale)}")
    if not errors:
        print(f"PASS: config macros ({len(list((root / 'hdl/configs').glob('*/rapt_config.svh')))} "
              f"presets, {len(findings)} allowed-pending)")
    return int(bool(errors))


if __name__ == "__main__":
    raise SystemExit(main())
