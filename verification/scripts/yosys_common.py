"""Shared Yosys execution for verification drivers."""
from pathlib import Path
import hashlib
import os
import signal
import subprocess

ROOT = Path(__file__).resolve().parents[2]


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
               log_sha256=hashlib.sha256(log.read_bytes()).hexdigest())
    if witness is not None:
        if not witness.is_file() or not witness.stat().st_size:
            raise RuntimeError("Missing activation/counterexample witness: " + name)
        row.update(witness=witness.name,
                   witness_sha256=hashlib.sha256(witness.read_bytes()).hexdigest())
    return row


def run_sby(directory, timeout, *, negative=False, force=False, grace=120):
    """Run a standard prove/cover contract and require nonempty VCD evidence."""
    bundled = ROOT / "third_party/oss-cad-suite/bin"
    env = dict(os.environ, PATH=str(bundled) + os.pathsep + os.environ["PATH"])
    command = [str(bundled / "sby"), "--yosys",
               str(ROOT / "verification/formal/yosys-rvfi-compat.sh")]
    command += ["-f", "contract.sby"] if force else ["contract.sby"]
    log = directory / "run.log"
    with log.open("w") as stream:
        process = run_bounded(command, cwd=directory, env=env, stdout=stream,
                              stderr=subprocess.STDOUT, timeout=timeout + grace)
    if process.returncode == 124:
        raise subprocess.TimeoutExpired(command, timeout + grace)

    def status(task):
        path = directory / ("contract_" + task) / "status"
        words = path.read_text().split() if path.is_file() else []
        return words[0] if words else "ERROR"

    text = log.read_text()
    row = dict(exit=process.returncode, proof=status("prove"))
    task = "prove" if negative else "cover"
    traces = sorted((directory / ("contract_" + task) / "engine_0").glob("trace*.vcd"))
    witnessed = bool(traces) and all(p.is_file() and p.stat().st_size for p in traces)
    if negative:
        row["passed"] = (row["proof"] == "FAIL" and "Assert failed" in text
                         and "ERROR:" not in text and witnessed)
    else:
        row["cover"] = status("cover")
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
