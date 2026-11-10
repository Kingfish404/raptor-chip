#!/usr/bin/env python3
"""Cheap source guard for the portable native SystemVerilog subset.

Uses Verible's concrete syntax tree, without expanding macros or elaborating RTL.
Every conditional branch is checked. Exclusive alternatives are separate writers.
The synthesis relay remains the authority for tool compatibility.
"""

import argparse
from collections import defaultdict
import itertools
import json
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[2]
SCOPES = {"kModuleDeclaration", "kInterfaceDeclaration", "kGenerateBlock", "kModuleBlock",
          "kSeqBlock"}
PORTS = {"kPortDeclaration", "kPort", "kPortItem"}
DIRECTIVE = re.compile(
    r"(?m)^[ \t]*`(?:(ifdef|ifndef|elsif)[ \t]+(\w+)|(else|endif))\b")
ASSERTION_MACROS = {"`RAPT_SVA_IMM", "`RAPT_SVA", "`RAPT_SVA_IMPLY", "`RAPT_SVA_NEXT",
                    "`RAPT_COVER"}


def alternate_macros(text):
    """Find conditions whose alternatives may form incompatible syntax fragments."""
    stack, result = [], set()
    for match in DIRECTIVE.finditer(text):
        directive, macro = match.group(1) or match.group(3), match.group(2)
        if directive in ("ifdef", "ifndef"):
            stack.append([macro])
        elif directive == "elsif":
            stack[-1].append(macro)
            result.update(stack[-1])
        elif directive == "else":
            result.update(stack[-1])
        elif directive == "endif":
            stack.pop()
    return sorted(result)


def blank(text):
    return re.sub(r"[^\n]", " ", text)


def source_variant(text, defines):
    """Keep all unspecified branches, preserving byte offsets and inline punctuation."""
    result, stack, start, active = [], [], 0, True
    for match in DIRECTIVE.finditer(text):
        directive, macro = match.group(1) or match.group(3), match.group(2)
        body = text[start:match.start()]
        result.append(body if active else blank(body))
        result.append(blank(match.group()))
        start = match.end()
        if directive in ("ifdef", "ifndef"):
            known = macro in defines
            value = defines.get(macro, True)
            if known and directive == "ifndef":
                value = not value
            stack.append([active, known, value])
            active = active and value
        elif directive == "elsif":
            parent, known, matched = stack[-1]
            known = known or macro in defines
            value = not matched and defines.get(macro, True) if known else True
            stack[-1] = [parent, known, matched or value]
            active = parent and value
        elif directive == "else":
            parent, known, matched = stack[-1]
            active = parent and (not matched if known else True)
        else:
            active = stack.pop()[0]
    result.append(text[start:] if active else blank(text[start:]))
    return "".join(result)


def children(node):
    return [child for child in node.get("children", []) if isinstance(child, dict)]


def leaves(node):
    if "start" in node:
        yield node
    for child in children(node):
        yield from leaves(child)


def descendants(node, tag):
    if node.get("tag") == tag:
        yield node
    for child in children(node):
        yield from descendants(child, tag)


def first(node):
    return next(leaves(node))


def lvalue_roots(node):
    """Return assigned names, excluding identifiers used only in subscripts."""
    if node.get("tag") == "kReference":
        token = next((t for t in leaves(node) if t.get("tag") == "SymbolIdentifier"), None)
        if token is not None:
            yield token.get("text")
        return
    for child in children(node):
        yield from lvalue_roots(child)


def preprocessor_arms(text):
    """Source intervals and conditional arms, including nested directives."""
    stack, intervals, start = [], [], 0
    for match in DIRECTIVE.finditer(text):
        intervals.append((start, match.start(), dict(stack)))
        directive = match.group(1) or match.group(3)
        if directive in ("ifdef", "ifndef"):
            stack.append((match.start(), 0))
        elif directive in ("else", "elsif") and stack:
            key, arm = stack[-1]
            stack[-1] = key, arm + 1
        elif directive == "endif" and stack:
            stack.pop()
        start = match.end()
    intervals.append((start, len(text), dict(stack)))
    return intervals


def exclusive(left, right):
    return any(key in right and right[key] != value for key, value in left.items())


def violations(text, tree):
    findings, writers = [], defaultdict(list)
    intervals = preprocessor_arms(text)

    def line(offset):
        return text.count("\n", 0, offset) + 1

    openers = {m.start(): (m.group(1), m.group(2)) for m in DIRECTIVE.finditer(text)
               if m.group(1) in ("ifdef", "ifndef")}

    def verification_only(offset):
        for lo, hi, arms in intervals:
            if not lo <= offset < hi:
                continue
            for key, arm in arms.items():
                directive, macro = openers[key]
                if macro == "RAPT_SVA_ACTIVE":
                    if (directive == "ifdef") == (arm == 0):
                        return True
                if macro == "SYNTHESIS":
                    if (directive == "ifndef") == (arm == 0):
                        return True
        return False

    def scan_calls(node, assertion=False, interfaces=frozenset(), constant=False):
        tag = node.get("tag")
        if tag == "kModuleDeclaration":
            interfaces = set()
            for port in descendants(node, "kPortDeclaration"):
                if any(descendants(port, "kInterfacePortHeader")):
                    interfaces.update(first(child).get("text") for child in children(port)
                                      if child.get("tag") == "kUnqualifiedId")
        constant = constant or tag in ("kParamDeclaration", "kGenerateIfHeader")
        if tag == "kReference" and constant:
            tokens = list(leaves(node))
            if tokens and tokens[0].get("text") in interfaces:
                if not verification_only(tokens[0]["start"]):
                    findings.append((line(tokens[0]["start"]),
                                     "interface introspection in synthesis configuration constant"))
        if tag == "kMacroCall":
            assertion = assertion or first(node).get("text") in ASSERTION_MACROS
        if tag == "kSystemTFCall":
            token = first(node)
            if token.get("text") in ("$onehot", "$onehot0"):
                if not assertion and not verification_only(token["start"]):
                    findings.append((line(token["start"]),
                                     "onehot system function outside an assertion guard"))
        for child in children(node):
            scan_calls(child, assertion, interfaces, constant)

    def declarations(scope):
        result = {}

        def visit(node):
            tag = node.get("tag")
            if node is not scope and (tag in SCOPES or tag == "kAlwaysStatement"):
                return
            if tag == "kRegisterVariable":
                token = first(node)
                result[token.get("text")] = token["start"]
            elif tag == "kPortDeclaration" and first(node).get("tag") in (
                    "input", "output", "inout", "ref"):
                # ANSI data ports have an identifier after their type. Interface
                # modports have a different shape and name separate signals.
                for child in children(node):
                    if child.get("tag") == "kUnqualifiedId":
                        token = first(child)
                        result[token.get("text")] = token["start"]
            for child in children(node):
                visit(child)

        visit(scope)
        return result

    def walk(node, scopes, arms, parent_tag=None, in_port=False):
        tag = node.get("tag")
        in_port = in_port or tag == "kPortActualList"
        if tag == "kAssignmentPattern" and in_port:
            findings.append((line(first(node)["start"]),
                             "assignment pattern in port connection; use a typed signal"))
        if tag in ("kGenerateBlock", "kModuleBlock") and parent_tag in (
                "kModuleItemList", "kGenerateItemList"):
            findings.append((line(first(node)["start"]),
                             "standalone generate block; use a constant conditional"))
        if tag in PORTS:
            for child in children(node):
                if child.get("tag") == "kTrailingAssign":
                    kind = "function/task argument" if tag == "kPortItem" else "input port"
                    findings.append((line(first(child)["start"]), f"default value on {kind}"))
        if tag in SCOPES:
            scopes = scopes + [declarations(node)]
        if tag == "kAlwaysStatement":
            start = first(node)["start"]
            context = dict(arms)
            for lo, hi, preprocessor in intervals:
                if lo <= start < hi:
                    context.update({("preprocessor", key): value
                                    for key, value in preprocessor.items()})
                    break
            local = {first(n).get("text") for n in descendants(node, "kRegisterVariable")}
            assigned = set()
            for lvalue in descendants(node, "kLPValue"):
                for name in lvalue_roots(lvalue):
                    if name in local:
                        continue
                    owner = next((scope[name] for scope in reversed(scopes) if name in scope), None)
                    if owner is not None:
                        assigned.add((owner, name))
            for key in assigned:
                writers[key].append((line(start), context))
            return
        if tag == "kConditionalGenerateConstruct":
            key = ("generate", first(node)["start"])
            for index, child in enumerate(children(node)):
                walk(child, scopes, arms | {key: index}, tag, in_port)
            return
        for child in children(node):
            walk(child, scopes, arms, tag, in_port)

    scan_calls(tree)
    walk(tree, [], {})
    for (_, name), entries in writers.items():
        for index, (location, arms) in enumerate(entries):
            others = [other for other, context in entries[:index] if not exclusive(arms, context)]
            if others:
                findings.append((location, f"{name} is written by multiple always blocks "
                                 f"(also line {others[0]})"))
    return sorted(set(findings))


def check_file(path, syntax):
    # Latin-1 maps each source byte to one character, matching Verible's offsets
    # even when comments or string literals contain UTF-8 characters.
    text = path.read_bytes().decode("latin1")

    def parse(defines):
        run = subprocess.run([syntax, "--export_json", "--printtree", "-"],
                             input=source_variant(text, defines).encode("latin1"),
                             capture_output=True)
        try:
            parsed = json.loads(run.stdout)["-"]
            tree = parsed.get("tree")
        except (ValueError, KeyError) as error:
            raise RuntimeError(f"Cannot parse {path} with Verible: {run.stderr!r}") from error
        errors = parsed.get("errors", [])
        if tree is None and not run.returncode and not errors:
            raise RuntimeError(f"Missing Verible syntax tree for {path}")
        return tree, errors, run.returncode

    tree, errors, status = parse({})
    if not status and not errors:
        return violations(text, tree)
    # Most branches can coexist syntactically. Conditional port-list fragments
    # need separate parses; enumerate their macros consistently across the file.
    macros = alternate_macros(text)
    if len(macros) > 8:
        raise RuntimeError(f"Too many conditional syntax variants in {path}: {macros}")
    findings = set()
    for values in itertools.product((False, True), repeat=len(macros)):
        tree, errors, status = parse(dict(zip(macros, values)))
        if status or errors:
            raise RuntimeError(f"Verible syntax error in {path}: {errors}")
        findings.update(violations(text, tree))
    return sorted(findings)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("paths", nargs="*", type=Path,
                        help="files or directories; defaults to RTL and maintained wrappers")
    parser.add_argument("--syntax", default=os.environ.get("VERIBLE_SYNTAX",
                                                         "verible-verilog-syntax"))
    args = parser.parse_args()
    paths = args.paths or [ROOT / "rtl", ROOT / "synth/configs",
                          ROOT / "sim/sram/wrappers"]
    if not args.paths:
        # Simulation observation headers are module fragments, not synthesis
        # units. Their enclosing wrappers are checked here alongside the FPGA
        # and module-synthesis boundaries that instantiate the same RTL.
        for directory in ("sim/rtl", "synth/wrappers", "fpga/common/rtl",
                          "fpga/rk-xcku5p-f/rtl", "fpga/mlk-cu08-ku15p/rtl"):
            paths += sorted((ROOT / directory).glob("*.sv"))
    files = set()
    for path in paths:
        if path.is_dir():
            files.update(p for p in path.rglob("*")
                         if p.is_file() and p.suffix in (".sv", ".svh", ".v", ".vh"))
        else:
            files.add(path)
    if not files:
        parser.error("no HDL files found")
    count = 0
    for path in sorted(files):
        for location, message in check_file(path, args.syntax):
            print(f"{path}:{location}: {message}")
            count += 1
    if count:
        raise SystemExit(1)
    print(f"PASS: native SystemVerilog source guard ({len(files)} files)")


if __name__ == "__main__":
    main()
