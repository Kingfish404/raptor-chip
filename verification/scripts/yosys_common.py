"""Shared Yosys execution for verification drivers."""
from pathlib import Path
import hashlib
import os
import re
import shutil
import signal
import subprocess

ROOT = Path(__file__).resolve().parents[2]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def member(directory, name):
    if not isinstance(name, str) or not name or Path(name).is_absolute():
        raise ValueError("Evidence paths must be nonempty relative paths")
    path = (directory / name).resolve()
    if not path.is_relative_to(directory.resolve()):
        raise ValueError("Evidence path escapes its source/artifact directory")
    return path


def copy_native_artifact(source, directory, name, digest):
    """Copy frozen evidence and reject changes before or during copying."""
    target = member(directory, name)
    if sha(source) != digest:
        raise ValueError('Native artifact changed: ' + str(source))
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, target)
    if sha(target) != digest:
        raise ValueError('Native artifact changed while copying: ' + str(source))
    return digest


def rtl_manifest(root):
    """Fingerprint RTL inputs independently of any implementation's state names."""
    return {str(p.relative_to(root)): sha(p) for p in sorted(root.rglob("*"))
            if p.suffix in (".sv", ".svh")}


def run_yosys(command, log, timeout):
    with log.open("w") as stream:
        result = run_bounded(
            [os.environ.get("RAPTOR_YOSYS_REAL", "yosys"),
             "-Q", "-T", "-m", "slang", "-p", command],
            stdout=stream,
            stderr=subprocess.STDOUT,
            timeout=timeout,
            cwd=ROOT,
        )
    if result.returncode == 124:
        raise subprocess.TimeoutExpired(result.args, timeout)
    result.check_returncode()
    return log.read_text()


def run_yosys_check(command, output, name, timeout, marker, witness=None):
    """Record a check only after its expected result and required witness exist."""
    script, log = output / (name + ".ys"), output / (name + ".log")
    script.write_text(command + "\n")
    text = run_yosys(command, log, timeout)
    if marker not in text or "ERROR:" in text:
        raise RuntimeError(f"Incomplete formal check: {name}; see {log}")
    row = dict(script=script.name, log=log.name, exit=0,
               log_sha256=sha(log))
    if witness is not None:
        if not witness.is_file() or not witness.stat().st_size:
            raise RuntimeError("Missing activation/counterexample witness: " + name)
        row.update(witness=witness.name, witness_sha256=sha(witness))
    return row


def run_sby_task(directory, timeout, yosys=None, *, smtbmc=None, force=False, grace=120):
    """Execute a contract; leave task-specific proof and witness checks to its caller."""
    bundled = ROOT / "third_party/oss-cad-suite/bin"
    env = dict(os.environ, PATH=str(bundled) + os.pathsep + os.environ["PATH"])
    if yosys is not None:
        env["RAPTOR_YOSYS_REAL"] = str(yosys)
    command = [str(bundled / "sby"), "--yosys",
               str(ROOT / "verification/formal/yosys-rvfi-compat.sh")]
    if smtbmc is not None:
        command += ["--smtbmc", str(smtbmc)]
        env["RAPTOR_SMTBMC_REAL"] = str(bundled / "yosys-smtbmc")
    command += ["-f", "contract.sby"] if force else ["contract.sby"]
    with (directory / "run.log").open("w") as stream:
        return run_bounded(command, cwd=directory, env=env, stdout=stream,
                           stderr=subprocess.STDOUT, timeout=timeout + grace)


def read_status(path, *, default="ERROR"):
    """Treat missing or empty task status as incomplete evidence."""
    words = path.read_text().split() if path.is_file() else []
    return words[0] if words else default


def task_status(directory, task):
    return read_status(directory / ("contract_" + task) / "status")


def activation_witnesses(log, directory):
    """Resolve each reached cover to the waveform exported by its SBY engine."""
    pending, found = [], {}
    for line in log.splitlines():
        match = re.search(r'Reached cover statement in step \d+ at (.+)$', line)
        if match:
            pending.append(match[1])
        match = re.search(r'Writing trace to VCD file: (.+)$', line)
        if match:
            path = Path(match[1])
            if not path.is_absolute():
                path = directory / 'contract_cover' / path
            path = path.resolve()
            if not path.is_relative_to(directory.resolve()) or not path.is_file():
                raise ValueError('Activation witness escapes output or is missing')
            if not path.stat().st_size:
                raise ValueError('Activation waveform is empty')
            for name in pending:
                if name in found:
                    raise ValueError('Duplicate activation property')
                found[name] = str(path.relative_to(directory))
            pending = []
    if pending:
        raise ValueError('Activation property is missing its waveform')
    return found


def run_sby(directory, timeout, *, negative=False, force=False, grace=120, yosys=None):
    """Run a standard prove/cover contract and require nonempty VCD evidence."""
    process = run_sby_task(directory, timeout, yosys, force=force, grace=grace)
    if process.returncode == 124:
        raise subprocess.TimeoutExpired(process.args, timeout + grace)
    text = (directory / "run.log").read_text()
    row = dict(exit=process.returncode, proof=task_status(directory, "prove"))
    task = "prove" if negative else "cover"
    traces = sorted((directory / ("contract_" + task) / "engine_0").glob("trace*.vcd"))
    witnessed = bool(traces) and all(p.is_file() and p.stat().st_size for p in traces)
    if negative:
        row["passed"] = (process.returncode in (0, 2) and row["proof"] == "FAIL"
                         and "Assert failed" in text
                         and "ERROR:" not in text and witnessed)
    else:
        row["cover"] = task_status(directory, "cover")
        row["passed"] = (process.returncode == 0 and row["proof"] == "PASS"
                         and row["cover"] == "PASS" and "ERROR:" not in text and witnessed)
    return row, traces


def run_bounded(command, *, timeout, capture_output=False, **kwargs):
    """Keep a tool timeout from leaving solver descendants or losing the report."""
    if capture_output:
        kwargs.update(stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    with subprocess.Popen(command, start_new_session=True, **kwargs) as child:
        try:
            output, errors = child.communicate(timeout=timeout)
            code = child.returncode
        except subprocess.TimeoutExpired:
            try:
                # SBY creates separate groups for its engines. Let its signal
                # handler clean those up before resorting to a forced kill.
                os.killpg(child.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                output, errors = child.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid, signal.SIGKILL)
                output, errors = child.communicate()
            code = 124
            message = f'\nTIMEOUT: Tool exceeded {timeout} seconds\n'
            if capture_output:
                if not kwargs.get('text', False):
                    message = message.encode()
                errors = (errors or type(message)()) + message
            elif kwargs.get('stdout') is not None:
                kwargs['stdout'].write(message)
        return subprocess.CompletedProcess(command, code, output, errors)
