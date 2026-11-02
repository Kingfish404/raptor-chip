"""Own a bounded child process group and fail early on fatal guest diagnostics."""
import os
from pathlib import Path
import signal
import subprocess
import time

FATAL = (b"Kernel panic", b"HIT BAD TRAP", b"Difftest:", b"Assertion failed",
         b"Program execution has aborted", b"SVA FAIL", b"%Error:")


def signal_owned_group(process, action):
    try:
        os.killpg(process.pid, action)
    except ProcessLookupError:
        pass


def run_logged(command, logfile: Path, timeout, *, cwd=None, env=None, stop=None):
    started = time.monotonic()
    process = None
    timed_out, fatal, cancelled = False, False, False
    if stop is not None and stop.is_set():
        return {"returncode": -signal.SIGTERM, "timed_out": False, "fatal": False,
                "cancelled": True, "wall_seconds": 0}
    with logfile.open("wb") as output, logfile.open("rb") as reader:
        try:
            process = subprocess.Popen(command, cwd=cwd, env=env, stdin=subprocess.DEVNULL,
                                       stdout=output, stderr=subprocess.STDOUT,
                                       start_new_session=True)
            tail = b""
            def scan_output(bounded=False):
                nonlocal tail, fatal
                while chunk := reader.read(65536):
                    combined = tail + chunk
                    fatal |= any(token in combined for token in FATAL)
                    tail = combined[-max(map(len, FATAL)):]
                    if bounded and (fatal or time.monotonic() - started >= timeout or
                                    (stop is not None and stop.is_set())):
                        break
            while process.poll() is None:
                scan_output(bounded=True)
                timed_out = time.monotonic() - started >= timeout
                cancelled = stop is not None and stop.is_set()
                if fatal or timed_out or cancelled:
                    break
                time.sleep(0.1)
        finally:
            if process is not None:
                signal_owned_group(process, signal.SIGTERM)
                if process.poll() is None:
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        signal_owned_group(process, signal.SIGKILL)
                        process.wait()
                # A direct child can exit while a descendant ignores SIGTERM.
                signal_owned_group(process, signal.SIGKILL)
        scan_output()
    return {"returncode": process.returncode, "timed_out": timed_out, "fatal": fatal,
            "cancelled": cancelled, "wall_seconds": time.monotonic() - started}
