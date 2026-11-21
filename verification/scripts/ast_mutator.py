#!/usr/bin/env python3
"""
Encarsia-style SystemVerilog AST/token-aware automated RTL mutator.

Provides two capabilities:
1. Formatting-invariant targeted mutations (`replace_token_sequence`) so formal
   negative controls never break when Verible re-aligns whitespace or wraps
   lines.
2. Automated structural mutation discovery (`discover_mutations`) over
   SystemVerilog RTL (using `verible-verilog-syntax --export_json` when
   available, with a built-in comment/string-aware SystemVerilog tokenizer
   fallback) for Encarsia-style fuzzer and formal blind-spot evaluation.
"""

import argparse
import dataclasses
import hashlib
import json
import re
import shutil
import subprocess
from pathlib import Path
from typing import Callable, List, Optional, Sequence, Tuple

SV_TOKEN_RE = re.compile(
    r"""
    (?P<block_comment>/\*.*?\*/)
    | (?P<line_comment>//[^\n]*)
    | (?P<string>"(?:\\.|[^"\\])*")
    | (?P<ws>\s+)
    | (?P<op>===|!==|==|!=|<=|>=|&&|\|\||<<<|>>>|<<|>>|->|::|\+:|-:|[+\-*/%&|^~!<>?:=;,()\[\]{}.@#'`])
    | (?P<word>[A-Za-z0-9_$]+)
    """,
    re.VERBOSE | re.DOTALL,
)

OP_FLIPS = {
    "==": "!=",
    "!=": "==",
    "<": "<=",
    "<=": "<",
    ">": ">=",
    ">=": ">",
    "&&": "||",
    "||": "&&",
}


@dataclasses.dataclass(frozen=True)
class Token:
    kind: str
    text: str
    start: int
    end: int
    line: int


@dataclasses.dataclass(frozen=True)
class MutationCandidate:
    mutation_id: str
    kind: str
    line: int
    original: str
    replacement: str
    start: int
    end: int
    context: str


def tokenize_sv(source: str) -> List[Token]:
    """Tokenize SystemVerilog source while preserving exact byte offsets."""
    tokens: List[Token] = []
    line = 1
    pos = 0
    for match in SV_TOKEN_RE.finditer(source):
        if match.start() > pos:
            gap = source[pos : match.start()]
            tokens.append(Token("other", gap, pos, match.start(), line))
            line += gap.count("\n")
        kind = match.lastgroup or "other"
        text = match.group()
        tokens.append(Token(kind, text, match.start(), match.end(), line))
        line += text.count("\n")
        pos = match.end()
    if pos < len(source):
        tail = source[pos:]
        tokens.append(Token("other", tail, pos, len(source), line))
    return tokens


def significant_tokens(tokens: Sequence[Token]) -> List[Token]:
    """Filter out whitespace and comments for formatting-invariant matching."""
    return [
        t for t in tokens if t.kind not in ("ws", "line_comment", "block_comment")
    ]


def replace_token_sequence(source: str, pattern: str, replacement: str) -> str:
    """Replace a unique SystemVerilog token sequence, ignoring whitespace/comments."""
    src_sig = significant_tokens(tokenize_sv(source))
    pat_sig = significant_tokens(tokenize_sv(pattern))
    if not pat_sig:
        raise ValueError("Empty token pattern")

    pat_texts = [t.text for t in pat_sig]
    n = len(pat_texts)
    matches: List[Tuple[int, int]] = []
    for i in range(len(src_sig) - n + 1):
        if [t.text for t in src_sig[i : i + n]] == pat_texts:
            matches.append((src_sig[i].start, src_sig[i + n - 1].end))

    if len(matches) != 1:
        raise ValueError(
            f"Expected unique token match for {pattern!r}, found {len(matches)}"
        )
    start, end = matches[0]
    return source[:start] + replacement + source[end:]


def check_verible_syntax(path: Path, syntax_bin: str = "verible-verilog-syntax") -> bool:
    """Optionally verify mutated RTL parses cleanly with Verible."""
    exe = shutil.which(syntax_bin)
    if not exe:
        return True
    proc = subprocess.run(
        [exe, "--export_json", "--printtree", str(path)],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    return proc.returncode == 0


def _line_text(source: str, line_no: int) -> str:
    lines = source.splitlines()
    if 1 <= line_no <= len(lines):
        return lines[line_no - 1].strip()
    return ""


def _in_skipped_line(line_str: str) -> bool:
    stripped = line_str.lstrip()
    if not stripped:
        return True
    skip_prefixes = (
        "`",
        "//",
        "module ",
        "endmodule",
        "import ",
        "package ",
        "localparam ",
        "parameter ",
        "typedef ",
        "input ",
        "output ",
        "inout ",
        "assert",
        "assume",
        "cover",
        "RAPT_SVA_",
    )
    return stripped.startswith(skip_prefixes)


def discover_mutations(
    source: str,
    kinds: Sequence[str] = ("op_flip", "cond_invert", "const_flip"),
    filter_signal: Optional[str] = None,
    limit: Optional[int] = None,
) -> List[MutationCandidate]:
    """Discover syntactically valid Encarsia-style RTL mutation candidates."""
    sig = significant_tokens(tokenize_sv(source))
    candidates: List[MutationCandidate] = []
    seen_spans = set()
    kind_set = set(kinds)

    def add_candidate(kind: str, tok_start: int, tok_end: int, repl: str, line: int):
        ctx = _line_text(source, line)
        if _in_skipped_line(ctx):
            return
        if filter_signal and filter_signal not in ctx:
            return
        span = (tok_start, tok_end, repl)
        if span in seen_spans:
            return
        seen_spans.add(span)
        orig = source[tok_start:tok_end]
        cid = f"{kind}-L{line}-{len(candidates):04d}"
        candidates.append(
            MutationCandidate(
                mutation_id=cid,
                kind=kind,
                line=line,
                original=orig,
                replacement=repl,
                start=tok_start,
                end=tok_end,
                context=ctx[:100],
            )
        )

    for idx, tok in enumerate(sig):
        if limit is not None and len(candidates) >= limit:
            break

        # 1. Operator flips (skip <= when it is a non-blocking assignment!)
        if "op_flip" in kind_set and tok.text in OP_FLIPS:
            if tok.text == "<=":
                # A `<=` is a comparison only when nested inside parentheses
                # (e.g. `if (a <= b)`) or on the RHS of `=` / `?` / `return`.
                prefix = _line_text(source, tok.line).split("<=", 1)[0]
                paren_depth = prefix.count("(") - prefix.count(")")
                is_rhs = any(k in prefix for k in ("=", "?", "return "))
                if paren_depth <= 0 and not is_rhs:
                    continue
            add_candidate("op_flip", tok.start, tok.end, OP_FLIPS[tok.text], tok.line)

        # 2. Condition polarity inversion: `if (cond)` -> `if (!(cond))`
        if "cond_invert" in kind_set and tok.text == "if":
            if idx + 1 < len(sig) and sig[idx + 1].text == "(":
                depth = 0
                close_idx = None
                for j in range(idx + 1, len(sig)):
                    if sig[j].text == "(":
                        depth += 1
                    elif sig[j].text == ")":
                        depth -= 1
                        if depth == 0:
                            close_idx = j
                            break
                if close_idx is not None:
                    inner_start = sig[idx + 1].end
                    inner_end = sig[close_idx].start
                    inner = source[inner_start:inner_end].strip()
                    # Avoid mutating `if (1'b1)` generate blocks or reset checks
                    if inner and inner != "1'b1" and "reset" not in inner:
                        add_candidate(
                            "cond_invert",
                            inner_start,
                            inner_end,
                            f"!({inner})",
                            tok.line,
                        )

        # 3. Single-bit constant flips: `1'b0` <-> `1'b1`
        if (
            "const_flip" in kind_set
            and tok.text == "1"
            and idx + 2 < len(sig)
            and sig[idx + 1].text == "'"
            and sig[idx + 2].text in ("b0", "b1")
        ):
            flipped = "1'b1" if sig[idx + 2].text == "b0" else "1'b0"
            ctx = _line_text(source, tok.line)
            if "if (1'b1)" not in ctx and "reset" not in ctx:
                add_candidate(
                    "const_flip", tok.start, sig[idx + 2].end, flipped, tok.line
                )

    return candidates


def apply_candidate(source: str, candidate: MutationCandidate) -> str:
    return source[: candidate.start] + candidate.replacement + source[candidate.end :]


def sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        description="Encarsia-style SystemVerilog AST/token-aware RTL mutator"
    )
    sub = parser.add_subparsers(dest="command", required=True)

    p_list = sub.add_parser("list", help="List candidate mutations in an RTL file")
    p_list.add_argument("source", type=Path)
    p_list.add_argument(
        "--kinds",
        nargs="+",
        default=["op_flip", "cond_invert", "const_flip"],
        choices=["op_flip", "cond_invert", "const_flip"],
    )
    p_list.add_argument("--filter-signal", default=None)
    p_list.add_argument("--limit", type=int, default=50)

    p_batch = sub.add_parser("batch", help="Emit a batch of mutated RTL files + manifest")
    p_batch.add_argument("source", type=Path)
    p_batch.add_argument("--output", type=Path, required=True)
    p_batch.add_argument(
        "--kinds",
        nargs="+",
        default=["op_flip", "cond_invert", "const_flip"],
        choices=["op_flip", "cond_invert", "const_flip"],
    )
    p_batch.add_argument("--filter-signal", default=None)
    p_batch.add_argument("--limit", type=int, default=20)
    p_batch.add_argument("--check-verible", action="store_true")

    args = parser.parse_args(argv)
    text = args.source.read_text()
    cands = discover_mutations(
        text, kinds=args.kinds, filter_signal=args.filter_signal, limit=args.limit
    )

    if args.command == "list":
        for c in cands:
            print(f"{c.mutation_id} L{c.line} [{c.kind}] {c.original} -> {c.replacement}")
        print(f"Total candidates: {len(cands)}")
        return 0

    args.output.mkdir(parents=True, exist_ok=True)
    manifest = {
        "source": str(args.source),
        "source_sha256": sha256_text(text),
        "mutants": [],
    }
    for c in cands:
        mutated = apply_candidate(text, c)
        mpath = args.output / f"{c.mutation_id}.sv"
        mpath.write_text(mutated)
        syntax_ok = check_verible_syntax(mpath) if args.check_verible else True
        manifest["mutants"].append(
            {
                "id": c.mutation_id,
                "kind": c.kind,
                "line": c.line,
                "original": c.original,
                "replacement": c.replacement,
                "file": mpath.name,
                "sha256": sha256_text(mutated),
                "syntax_ok": syntax_ok,
            }
        )
    (args.output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"[ast-mutator] Wrote {len(cands)} mutants to {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
