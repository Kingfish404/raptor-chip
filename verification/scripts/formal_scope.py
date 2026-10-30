#!/usr/bin/env python3
"""Inventory proof scope, compare elaborated graphs and classify formal models."""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import argparse
import gzip
import hashlib
import json
import os
import re
import shlex
import shutil
import subprocess
import threading
from yosys_common import ROOT


ROOT = Path(__file__).resolve().parents[2]

LEXICAL = re.compile(r'"(?:\\.|[^"\\])*"|//[^\n]*|/\*.*?\*/', re.S)

DECLARATION = re.compile(r"(?m)^\s*(module|interface|package)\s+([A-Za-z_]\w*)")

GENERATED = ("rapt_idu_decoder.sv", "rapt_idu_decoder_c.sv")

UNBOUNDED = {"induction", "equivalence", "compositional"}

MARKERS = {
    "combinational": "SAT proof finished - no model found: SUCCESS!",
    "combinational-smt": "UNRESTRICTED COMBINATIONAL PROOF COMPLETE",
    "induction": "Induction step proven: SUCCESS!",
    "equivalence": "Equivalence successfully proven!",
    "compositional": "FORMAL COMPOSITION COMPLETE",
}

BLOCK_CONTRACTS = {
    "rapt_cache_nru": ["cold-way-priority", "epoch-rollover", "set-isolation", "invalidation"],
    "rapt_l1d_data": ["diagonal-mapping", "byte-and-line-mask", "read-latency",
                      "port-reservation", "storage-preservation", "macro-binding"],
    "rapt_rou": ["retirement-metadata", "serial-immediate", "precise-retirement",
                 "dispatch-owner", "checkpoint-recovery", "generation-reuse"],
    "rapt_recovery_pending": ["masked-port-priority", "held-tie", "owner-generation",
                              "target-transport", "cancellation"],
    "rapt_stream_queue": ["prefix-order", "capacity", "payload-transport", "wraparound",
                          "collision-forwarding"],
    "rapt_prf": ["architectural-zero", "physical-data-history", "valid-transient-priority",
                 "late-forwarding", "debug-access", "lutram-copies"],
    "rapt_lsu_ioq": ["dispatch-admission", "completion-identity", "request-response-provenance",
                     "single-completion", "store-data-owner", "atomic-semantics"],
}


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def binding_key(parameters):
    if (not isinstance(parameters, dict) or not parameters
            or any(not isinstance(name, str) or not name for name in parameters)):
        raise ValueError("Parameter binding must be a nonempty named dictionary")
    try:
        text = json.dumps(parameters, sort_keys=True, separators=(",", ":"), allow_nan=False)
    except (TypeError, ValueError) as error:
        raise ValueError("Parameter binding is not canonical JSON") from error
    return hashlib.sha256(text.encode()).hexdigest()


def required_contracts(scope):
    return {
        (unit["id"], obligation, profile, binding)
        for unit in scope["units"] for obligation in unit["obligations"]
        for profile in unit.get("reviewed_profiles", scope["profiles"])
        for binding in unit.get("reviewed_bindings", {}).get(profile, {"UNREVIEWED": None})
    }


def audit_combinational_snapshot(receipt, directory):
    from prf_formal import audit_frontend, audit_model

    snapshot = receipt.get("snapshot", {})
    names = ("frontend", "model", "query", "result", "expanded")
    if any(snapshot.get(name) not in receipt["artifacts"] for name in names):
        raise ValueError("Missing fingerprinted unrestricted snapshot artifacts")
    top = snapshot.get("top", "")
    if not isinstance(top, str) or not re.fullmatch(r"[A-Za-z_]\w*", top):
        raise ValueError("Invalid unrestricted snapshot top")
    assertions, covers = snapshot.get("assertions"), snapshot.get("covers")
    if (not isinstance(assertions, int) or assertions < 1
            or not isinstance(covers, int) or covers < 1):
        raise ValueError("Missing unrestricted assertion/activation inventory")
    frontend = member(directory, snapshot["frontend"]).read_text()
    audited = audit_frontend(frontend, assertions)
    if audited["covers_before_optimization"] != covers:
        raise ValueError("Snapshot activation inventory differs")
    model = member(directory, snapshot["model"]).read_text()
    audit_model(model, top)
    transition = f"(define-fun |{top}_t| ((state |{top}_s|) (next_state |{top}_s|)) Bool true)"
    transitions = [line.split(";", 1)[0].rstrip() for line in model.splitlines()
                   if line.startswith(f"(define-fun |{top}_t| ")]
    if transitions != [transition]:
        raise ValueError("Combinational snapshot contains a transition relation")
    query = (model + "\n" + f"(declare-fun arbitrary_snapshot () |{top}_s|)\n"
             + f"(assert (not (|{top}_a| arbitrary_snapshot)))\n(check-sat)\n")
    if member(directory, snapshot["query"]).read_text() != query:
        raise ValueError("Query does not check the unrestricted assertion predicate")
    if member(directory, snapshot["result"]).read_text().strip() != "unsat":
        raise ValueError("Unrestricted snapshot was not proved UNSAT")
    expected = {top + ": " + name for name in re.findall(
        r"^; yosys-smt2-cover \d+ (.+)$", model, re.M)}
    activation = receipt.get("property_activation", [])
    declared = [entry.get("property") for entry in activation]
    if len(expected) != covers or len(declared) != covers or set(declared) != expected:
        raise ValueError("Snapshot activation does not cover the complete model inventory")
    reached = {}
    for name in {entry.get("log") for entry in activation}:
        if name not in receipt["artifacts"]:
            raise ValueError("Snapshot activation log is not fingerprinted")
        pending = []
        for line in member(directory, name).read_text().splitlines():
            match = re.search(r"Reached cover statement in step \d+ at (.+)$", line)
            if match:
                pending.append(match[1])
            match = re.search(r"Writing trace to VCD file: (.+)$", line)
            if match:
                for property_name in pending:
                    if property_name in reached:
                        raise ValueError("Duplicate snapshot activation witness")
                    reached[property_name] = (name, match[1])
                pending = []
        if pending:
            raise ValueError("Snapshot activation is missing its waveform")
    for entry in activation:
        name, trace = reached.get(entry["property"], (None, ""))
        witness = entry.get("witness")
        if (name != entry.get("log") or witness not in receipt["artifacts"]
                or not (trace == witness or trace.endswith("/" + witness))):
            raise ValueError("Snapshot activation witness differs from the reached property")
    elaboration = receipt.get("elaboration", {})
    if any(elaboration.get(key) not in receipt["artifacts"] for key in ("model", "script")):
        raise ValueError("Missing fingerprinted parameter-binding elaboration")
    original = gzip.decompress(member(directory, elaboration["model"]).read_bytes()).decode()
    if canonical_rtlil(original) != canonical_rtlil(frontend):
        raise ValueError("Parameter-binding model differs from proved model")
    commands = member(directory, elaboration["script"]).read_text().splitlines()
    reads = [shlex.split(line) for line in commands if line.startswith("read_slang ")]
    if len(reads) != 1:
        raise ValueError("Missing unique binding read command")
    tokens = reads[0]
    supplied, defined, undefined = {}, {}, set()
    for token in tokens:
        if token.startswith("-G") or token.startswith("-D"):
            name, _, value = token[2:].partition("=")
            destination = supplied if token.startswith("-G") else defined
            if name in destination:
                raise ValueError("Duplicate elaboration parameter or define")
            destination[name] = value if "=" in token else "1"
        elif token.startswith("-U"):
            undefined.add(token[2:])
    expected = {name: str(int(value) if isinstance(value, bool) else value)
                for name, value in receipt["parameters"].items() if name != "defines"}
    defines = receipt["parameters"].get("defines", {})
    expected_defined = {name: str(int(value) if isinstance(value, bool) else value)
                        for name, value in defines.items() if value is not False}
    expected_undefined = {name for name, value in defines.items() if value is False}
    if supplied != expected or defined != expected_defined or undefined != expected_undefined:
        raise ValueError("Actual elaboration parameters/defines differ from the receipt")
    if tokens.count("--top") != 1 or tokens[tokens.index("--top") + 1] != top:
        raise ValueError("Binding top differs from unrestricted proof top")


def member(directory, name):
    if not isinstance(name, str) or not name or Path(name).is_absolute():
        raise ValueError("Evidence paths must be nonempty relative paths")
    path = (directory / name).resolve()
    if not path.is_relative_to(directory.resolve()):
        raise ValueError("Evidence path escapes its source/artifact directory")
    return path


def strip_noncode(text):
    return LEXICAL.sub(lambda match: "\n" * match.group().count("\n"), text)


def obligations(path, name, kind, sequential, body):
    if kind == "interface":
        return ["protocol", "ownership", "composition"]
    if kind == "package":
        return ["functions", "configuration", "packet-layout"]
    if name == "rapt_ieu_mul":
        return ["multiply", "divide-remainder", "mixed-arbitration", "flush-cancel"]
    if name == "rapt_vpu_memory":
        return ["rvv-memory", "response-isolation", "fault-restart", "ownership", "progress"]
    if name in {"rapt", "rapt_core", "rapt_frontend", "rapt_backend", "rapt_memory"}:
        return ["end-to-end", "precise-recovery", "ordering", "interface-contracts", "progress"]
    if name.startswith("rapt_sram_"):
        return ["read-write", "read-hold", "port-collision", "macro-equivalence"]
    if name in {"rapt_cache_plru", "rapt_cache_lru"}:
        return ["replacement", "invalid-priority", "state-update"]
    if "fpu" in path.parts or ("vpu" in path.parts and "fp_" in name):
        result = ["numeric-value", "rounding-flags", "special-values"]
    elif "vpu" in path.parts:
        result = ["rvv-functional", "mask-tail-vstart", "geometry"]
    elif "decoder" in name or name in {"rapt_idu", "rapt_decode_slot"}:
        result = ["instruction-decode", "illegal-encoding", "xlen-semantics"]
    elif name.startswith("wrap_") or name in {"axi2rnp", "rnp2axi", "ysyx_00000000"}:
        result = ["protocol", "integration", "external-boundary"]
    elif "memory" in path.parts or "lsu" in path.parts:
        result = ["functional", "ordering"]
        if any(token in name for token in ("pmp", "tlb", "ptw", "access")):
            result.append("permissions")
    else:
        result = ["functional"]
    if sequential:
        if re.search(r"\breset\b", body):
            result.append("reset")
        if re.search(r"\bflush\w*\b", body):
            result.append("recovery")
        if re.search(r"\w*valid\w*", body):
            result.append("ownership")
        if "state_t" in body:
            result.append("progress")
    return sorted(set(result) | set(BLOCK_CONTRACTS.get(name, [])))


def inventory(root):
    rtl = root / "rtl"
    sources = sorted(path for path in rtl.rglob("*")
                     if path.suffix in {".v", ".vh", ".sv", ".svh"})
    profiles = [
        f"{path.parent.name}/rv{xlen}/{memory}"
        for path in sorted((rtl / "configs").glob("*/rapt_config.svh"))
        for xlen in (32, 64) for memory in ("dff", "sram")
    ]
    units = []
    for path in sources:
        relative = str(path.relative_to(root))
        text = strip_noncode(path.read_text())
        declarations = list(DECLARATION.finditer(text))
        for index, match in enumerate(declarations):
            kind, name = match.groups()
            stop = declarations[index + 1].start() if index + 1 < len(declarations) else len(text)
            body = text[match.start():stop]
            sequential = bool(re.search(r"\b(always_ff|posedge|negedge)\b", body))
            units.append({
                "id": relative + ":" + name, "path": relative, "name": name,
                "kind": kind, "sequential": sequential,
                "obligations": obligations(path.relative_to(rtl), name, kind, sequential, body),
                "functions": sorted(set(re.findall(
                    r"\bfunction\s+(?:automatic\s+)?[^;]*?\b(\w+)\s*\(", body,
                ))),
            })
        if path.suffix in {".v", ".sv"} and not declarations:
            units.append({
                "id": relative + ":file", "path": relative, "name": path.stem,
                "kind": "external-or-conditional", "sequential": True,
                "obligations": ["external-boundary", "configuration"], "functions": [],
            })
    ids = [unit["id"] for unit in units]
    if len(set(ids)) != len(ids):
        raise ValueError("Duplicate RTL unit declaration; qualify its conditional variants")
    missing = ["rtl/generated/" + name for name in GENERATED
               if not (rtl / "generated" / name).is_file()]
    return {
        "schema_version": 2, "sources": {str(p.relative_to(root)): sha(p) for p in sources},
        "profiles": profiles, "units": units, "missing_generated": missing,
        "scope_note": "Candidate contracts for all discovered units and preset/XLEN/storage "
                      "profiles. They require semantic review, actual parameter bindings and "
                      "branch activation before qualification. No lexical coverage percentage.",
    }


def audit_receipt(receipt, scope, root, receipt_dir):
    """Validate evidence metadata and raw artifacts before matching obligations."""
    if receipt.get("status") != "PASS":
        raise ValueError("Receipt is not PASS")
    units = {unit["id"]: unit for unit in scope["units"]}
    unit = units.get(receipt.get("unit"))
    if unit is None or receipt.get("obligation") not in unit["obligations"]:
        raise ValueError("Unknown unit/obligation")
    if receipt.get("profile") not in scope["profiles"]:
        raise ValueError("Unknown configuration profile")
    method = receipt.get("method")
    if method not in MARKERS or (unit["sequential"] and method not in UNBOUNDED):
        raise ValueError("Bounded/unsupported method cannot close this obligation")
    inputs = receipt.get("inputs", {})
    if unit["path"] not in inputs or not receipt.get("harness"):
        raise ValueError("Missing DUT or harness fingerprint")
    if receipt["harness"] not in inputs:
        raise ValueError("Harness must be a fingerprinted proof input")
    if not scope["sources"].keys() <= inputs.keys():
        raise ValueError("Missing complete RTL/configuration source fingerprint")
    for name, digest in inputs.items():
        path = member(root, name)
        if not path.is_file() or sha(path) != digest:
            raise ValueError(f"Stale or missing proof input: {name}")
    if not isinstance(receipt.get("parameters"), dict) or not receipt["parameters"]:
        raise ValueError("Missing parameter bindings or explicit environment assumptions")
    if not isinstance(receipt.get("assumptions"), list):
        raise ValueError("Missing parameter bindings or explicit environment assumptions")
    binding = binding_key(receipt["parameters"])
    reviewed = unit.get("reviewed_bindings", {}).get(receipt["profile"], {})
    if binding not in reviewed:
        raise ValueError("Receipt does not match a reviewed parameter binding")
    artifacts = receipt.get("artifacts", {})
    log_name = receipt.get("log")
    if not log_name or log_name not in artifacts or len(artifacts) < 2:
        raise ValueError("Missing raw log and executable proof artifact")
    for name, digest in artifacts.items():
        path = member(receipt_dir, name)
        if not path.is_file() or sha(path) != digest:
            raise ValueError(f"Stale or missing proof artifact: {name}")
    log = member(receipt_dir, log_name).read_text()
    if MARKERS[method] not in log or "ERROR:" in log:
        raise ValueError("Raw log does not establish the declared proof result")
    if method == "combinational-smt":
        audit_combinational_snapshot(receipt, receipt_dir)
    if not receipt.get("property_activation"):
        raise ValueError("Missing non-vacuity/activation evidence")
    for activation in receipt["property_activation"]:
        if not isinstance(activation, dict) or not activation.get("property"):
            raise ValueError("Activation must identify its property and raw witness")
        log_name, witness = activation.get("log"), activation.get("witness")
        if log_name not in artifacts or witness not in artifacts:
            raise ValueError("Activation log/witness is not fingerprinted")
        text = member(receipt_dir, log_name).read_text()
        if "ERROR:" in text:
            raise ValueError("Activation log contains a tool error")
        if "SAT solving finished - model found:" not in text and "reached cover" not in text.lower():
            raise ValueError("Activation log has no reached property")
        if not member(receipt_dir, witness).stat().st_size:
            raise ValueError("Activation witness is empty")
    return receipt["unit"], receipt["obligation"], receipt["profile"], binding


def apply_contract_review(scope, review):
    """Review may extend the inventory's lower bound, never silently shrink it."""
    errors = []
    if review.get("sources") != scope["sources"]:
        errors.append("Contract review source fingerprint is stale")
    reviewed = review.get("units", {})
    for unit in scope["units"]:
        entry = reviewed.get(unit["id"], {})
        if not entry.get("rationale") or not entry.get("parameter_bindings"):
            errors.append("Missing contract/parameter review: " + unit["id"])
            continue
        obligations = entry.get("obligations", [])
        profiles = entry.get("profiles", [])
        if (not isinstance(obligations, list) or not isinstance(profiles, list)
                or any(not isinstance(v, str) or not v for v in obligations + profiles)):
            errors.append("Malformed contract/profile review: " + unit["id"])
            continue
        if not set(unit["obligations"]) <= set(obligations):
            errors.append("Contract review removes required obligations: " + unit["id"])
            continue
        if set(profiles) != set(scope["profiles"]):
            errors.append("Contract review omits or changes supported profiles: " + unit["id"])
            continue
        bindings = entry["parameter_bindings"]
        if not isinstance(bindings, dict) or set(bindings) != set(profiles):
            errors.append("Missing per-profile parameter bindings: " + unit["id"])
            continue
        reviewed_bindings = {}
        try:
            for profile in profiles:
                choices = bindings[profile]
                if not isinstance(choices, list) or not choices:
                    raise ValueError("Each profile requires a nonempty list of bindings")
                keyed = {binding_key(parameters): parameters for parameters in choices}
                if len(keyed) != len(choices):
                    raise ValueError("Duplicate parameter bindings")
                reviewed_bindings[profile] = keyed
        except ValueError as error:
            errors.append(f"Invalid parameter review for {unit['id']}: {error}")
            continue
        unit["obligations"] = sorted(set(obligations))
        unit["reviewed_profiles"] = sorted(set(profiles))
        unit["reviewed_bindings"] = reviewed_bindings
    return errors


def scope_main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", type=Path, default=ROOT)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--receipts", type=Path, nargs="*", default=[])
    parser.add_argument("--contract-review", type=Path)
    parser.add_argument("--signoff", action="store_true")
    args = parser.parse_args()
    root = args.source_root.resolve()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    scope = inventory(root)
    (output / "inventory.json").write_text(json.dumps(scope, indent=2) + "\n")
    review_errors = []
    if args.contract_review:
        review = json.loads(args.contract_review.read_text())
        review_errors.extend(apply_contract_review(scope, review))
    else:
        review_errors.append("Candidate contracts have not undergone semantic review")
    expected = required_contracts(scope)
    accepted, rejected = set(), []
    for path in args.receipts:
        try:
            receipt = json.loads(path.read_text())
            accepted.add(audit_receipt(receipt, scope, root, path.resolve().parent))
        except (OSError, ValueError, KeyError, TypeError, AttributeError) as error:
            rejected.append({"path": str(path), "reason": str(error)})
    pending = sorted(expected - accepted)
    complete = bool(expected) and not pending and not rejected and not scope["missing_generated"]
    complete &= not review_errors
    result = {
        "schema_version": 2, "whole_rtl_signoff": complete, "units": len(scope["units"]),
        "profiles": len(scope["profiles"]), "accepted": sorted(accepted), "pending": pending,
        "rejected": rejected, "missing_generated": scope["missing_generated"],
        "contract_review_errors": review_errors,
        "parameter_bindings": {unit["id"]: unit.get("reviewed_bindings", {})
                               for unit in scope["units"]},
        "note": "Coverage bookkeeping is necessary, not proof that a functional specification "
                "is complete. Contracts and composition assumptions also require review.",
    }
    (output / "signoff.json").write_text(json.dumps(result, indent=2) + "\n")
    print(f"RTL units={len(scope['units'])}, profiles={len(scope['profiles'])}, "
          f"accepted={len(accepted)}, pending={len(pending)}, rejected={len(rejected)}")
    print("WHOLE RTL SIGNOFF: " + ("PASS" if complete else "INCOMPLETE"))
    return 0 if complete or not args.signoff else 1


HDL_SUFFIXES = {'.sv', '.svh', '.v', '.vh'}


def rtl_sources(root):
    return {str(p.relative_to(root)): sha(p) for p in sorted((root / 'rtl').rglob('*'))
            if p.is_file() and p.suffix in HDL_SUFFIXES}


def canonical_rtlil(text):
    # Source locations affect diagnostics; every other attribute is retained,
    # including init, keep, blackbox, clock and formal witness metadata.
    return ''.join(line for line in text.splitlines(keepends=True)
                   if not line.lstrip().startswith('attribute \\src '))


def validate_case(case):
    if not re.fullmatch(r'[A-Za-z0-9_-]+', case['id']):
        raise ValueError('Invalid case id')
    if not re.fullmatch(r'[A-Za-z_]\w*', case['top']):
        raise ValueError('Invalid top module')
    read = case['read']
    if not read.startswith('read_slang ') or any(c in read for c in ';\n\r"'):
        raise ValueError('Expected one read_slang command without command separators')
    tokens = read.split()
    if tokens.count('--top') != 1 or tokens[tokens.index('--top') + 1] != case['top']:
        raise ValueError('Read command/top mismatch')
    if '@ROOT@' not in read or any(t.startswith('/') for t in tokens):
        raise ValueError('Read input paths must use @ROOT@')


def read_inputs(root, cases):
    """Protect direct harnesses and all files in include directories as well."""
    paths = set()
    for case in cases:
        for token in case['read'].split():
            if token.startswith('-I@ROOT@/'):
                directory = root / token.removeprefix('-I@ROOT@/')
                paths.update(p for p in directory.rglob('*') if p.is_file())
            elif token.startswith('@ROOT@/'):
                path = root / token.removeprefix('@ROOT@/')
                if not path.is_file():
                    raise ValueError('Missing read input: ' + str(path))
                paths.add(path)
                for pattern in ('*.svh', '*.vh', '*.sva', '*.inc'):
                    paths.update(path.parent.glob(pattern))
    return {str(p.relative_to(root)): sha(p) for p in sorted(paths)}


def graph_identity_main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline-root', type=Path, required=True)
    parser.add_argument('--candidate-root', type=Path, required=True)
    parser.add_argument('--commands', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--jobs', type=int, default=2)
    parser.add_argument('--timeout', type=int, default=120)
    args = parser.parse_args()
    roots = [args.baseline_root.resolve(), args.candidate_root.resolve()]
    output = args.output.resolve()
    if min(args.jobs, args.timeout) < 1:
        parser.error('Jobs and timeout must be positive')
    for path in [*roots, output]:
        if any(c.isspace() or c in ';"' for c in str(path)):
            parser.error('Yosys paths cannot contain whitespace, quotes or semicolons')
    if output.exists() and any(output.iterdir()):
        parser.error('Output must be empty')
    source_hashes = [rtl_sources(root) for root in roots]
    if set(source_hashes[0]) != set(source_hashes[1]):
        parser.error('RTL file set changed; regenerate and review the read input manifest')
    cases = json.loads(args.commands.read_text())['cases']
    if not cases or len({c['id'] for c in cases}) != len(cases):
        parser.error('Case list is empty or contains duplicates')
    for case in cases:
        validate_case(case)
    input_hashes = [read_inputs(root, cases) for root in roots]
    output.mkdir(parents=True, exist_ok=True)
    yosys = os.environ.get('RAPTOR_YOSYS_REAL', 'yosys')
    result = {'complete_graph_identity': False, 'whole_rtl_signoff': False, 'cases': [],
              'rtl_sources': source_hashes, 'read_inputs': input_hashes,
              'commands_sha256': sha(args.commands),
              'script_sha256': sha(Path(__file__)),
              'yosys': subprocess.check_output([yosys, '-V'], text=True).strip(),
              'normalization': 'Only RTLIL src attributes are removed; byte equality of '
                               'all other model text is required before any optimization.'}
    lock = threading.Lock()

    def save():
        temporary = output / 'results.tmp'
        temporary.write_text(json.dumps(result, indent=2) + '\n')
        temporary.replace(output / 'results.json')

    def run(case):
        directory = output / case['id']
        directory.mkdir()
        row = {'id': case['id'], 'top': case['top'], 'models': [], 'identical': False}
        texts = []
        for name, root in zip(('baseline', 'candidate'), roots):
            script = directory / (name + '.ys')
            model = directory / (name + '.il')
            log = directory / (name + '.log')
            script.write_text(case['read'].replace('@ROOT@', str(root))
                              + f'\nhierarchy -check -top {case["top"]}\n'
                              + f'write_rtlil {model}\n')
            with log.open('w') as stream:
                process = subprocess.run([yosys, '-Q', '-T', '-m', 'slang', '-s', str(script)],
                                         stdout=stream, stderr=subprocess.STDOUT,
                                         timeout=args.timeout)
            data = {'root': str(root), 'exit': process.returncode,
                    'script_sha256': sha(script), 'log_sha256': sha(log)}
            if process.returncode == 0 and model.exists():
                raw = model.read_bytes()
                normalized = canonical_rtlil(raw.decode())
                texts.append(normalized)
                archive = directory / (name + '.il.gz')
                archive.write_bytes(gzip.compress(raw, mtime=0))
                data.update(raw_sha256=sha(model), archive_sha256=sha(archive),
                            normalized_sha256=hashlib.sha256(normalized.encode()).hexdigest())
                model.unlink()
            row['models'].append(data)
        row['identical'] = len(texts) == 2 and texts[0] == texts[1]
        with lock:
            result['cases'].append(row)
            save()
        print(case['id'], 'IDENTICAL' if row['identical'] else 'NOT_QUALIFIED', flush=True)
        return row['identical']

    save()
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        passed = list(pool.map(run, cases))
    if source_hashes != [rtl_sources(root) for root in roots]:
        raise RuntimeError('RTL inputs changed during graph comparison')
    if input_hashes != [read_inputs(root, cases) for root in roots]:
        raise RuntimeError('Harness or include inputs changed during graph comparison')
    if sha(args.commands) != result['commands_sha256'] or sha(Path(__file__)) != result['script_sha256']:
        raise RuntimeError('Read manifest or graph checker changed during execution')
    result['complete_graph_identity'] = all(passed)
    save()
    if not all(passed):
        raise SystemExit('Elaborated graphs differ or elaboration failed')
    print('COMPLETE: unoptimized graph identity; upstream proof qualification remains required')


def model_classes_main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-root', type=Path, default=ROOT)
    parser.add_argument('--commands', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--jobs', type=int, default=2)
    parser.add_argument('--timeout', type=int, default=120)
    args = parser.parse_args()
    root, output = args.source_root.resolve(), args.output.resolve()
    if min(args.jobs, args.timeout) < 1:
        parser.error('Jobs and timeout must be positive')
    for path in (root, output):
        if any(c.isspace() or c in ';"' for c in str(path)):
            parser.error('Unsupported Yosys path')
    if output.exists() and any(output.iterdir()):
        parser.error('Output must be empty')
    cases = json.loads(args.commands.read_text())['cases']
    if not cases or len({case['id'] for case in cases}) != len(cases):
        parser.error('Require nonempty distinct model cases')
    for case in cases:
        validate_case(case)
    inputs, sources = read_inputs(root, cases), rtl_sources(root)
    protected = [args.commands, Path(__file__)]
    fingerprints = {str(p.resolve()): sha(p) for p in protected}
    yosys = shutil.which(os.environ.get('RAPTOR_YOSYS_REAL', 'yosys'))
    if not yosys:
        parser.error('Yosys executable is missing')
    state = dict(complete_model_inventory=False, whole_rtl_signoff=False, cases=[], groups={},
                 sources=sources, read_inputs=inputs, verifier_inputs=fingerprints,
                 yosys_version=subprocess.check_output([yosys, '-V'], text=True).strip(),
                 yosys_launcher_sha256=sha(Path(yosys).resolve()),
                 normalization='Only src attributes removed; all remaining RTLIL bytes must '
                               'match before optimization. No proof is granted by grouping.')
    output.mkdir(parents=True, exist_ok=True)
    lock = threading.Lock()

    def save():
        temporary = output / 'results.tmp'
        temporary.write_text(json.dumps(state, indent=2) + '\n')
        temporary.replace(output / 'results.json')

    def execute(case):
        directory = output / case['id']
        directory.mkdir()
        script, model, log = [directory / name for name in ('read.ys', 'raw.il', 'run.log')]
        script.write_text(case['read'].replace('@ROOT@', str(root))
                          + f'\nhierarchy -check -top {case["top"]}\nwrite_rtlil {model}\n')
        with log.open('w') as stream:
            try:
                child = subprocess.run([yosys, '-Q', '-T', '-m', 'slang', '-s', str(script)],
                                       stdout=stream, stderr=subprocess.STDOUT,
                                       timeout=args.timeout)
            except subprocess.TimeoutExpired:
                stream.write('TIMEOUT: Native elaboration exceeded its limit\n')
                child = subprocess.CompletedProcess([], 124)
        row = dict(id=case['id'], exit=child.returncode, read=case['read'], top=case['top'],
                   script_sha256=sha(script), log_sha256=sha(log))
        if child.returncode == 0 and model.exists():
            raw = model.read_bytes()
            canonical = canonical_rtlil(raw.decode())
            archive = directory / 'raw.il.gz'
            archive.write_bytes(gzip.compress(raw, mtime=0))
            row.update(raw_sha256=sha(model), archive_sha256=sha(archive),
                       canonical_sha256=hashlib.sha256(canonical.encode()).hexdigest())
            model.unlink()
        with lock:
            state['cases'].append(row)
            if 'canonical_sha256' in row:
                state['groups'].setdefault(row['canonical_sha256'], []).append(row['id'])
            save()
        return 'canonical_sha256' in row

    save()
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        passed = list(pool.map(execute, cases))
    if inputs != read_inputs(root, cases) or sources != rtl_sources(root):
        raise RuntimeError('Formal model inputs changed during elaboration')
    if fingerprints != {str(p.resolve()): sha(p) for p in protected}:
        raise RuntimeError('Model classifier inputs changed')
    state['complete_model_inventory'] = all(passed)
    save()
    if not all(passed):
        raise SystemExit('Incomplete formal model inventory')
    print(f'MODEL INVENTORY: {len(cases)} bindings, {len(state["groups"])} exact classes')


ENTRY_POINTS = {
    'scope': scope_main,
    'graph-identity': graph_identity_main,
    'model-classes': model_classes_main,
}


def main():
    import sys

    command = sys.argv[1] if len(sys.argv) > 1 else ''
    if command not in ENTRY_POINTS:
        parser = argparse.ArgumentParser(description=__doc__)
        parser.add_argument('command', choices=ENTRY_POINTS)
        parser.parse_args()
    del sys.argv[1]
    return ENTRY_POINTS[command]()


if __name__ == '__main__':
    raise SystemExit(main())
