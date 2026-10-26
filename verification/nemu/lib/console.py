"""Keep boot logs available while bounding long-running native processes."""

import subprocess
import time

from lib.stream import finish_processes


def run_console(command, log_path, timeout, failure_markers=(), environment=None,
                ready_marker=None, on_ready=None):
    if on_ready is not None and not ready_marker:
        raise ValueError('on_ready requires a nonempty readiness marker')
    timed_out = False
    deadline = time.monotonic() + timeout
    with log_path.open('wb') as log, subprocess.Popen(
            command, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT,
            env=environment, start_new_session=True) as process:
        try:
            while process.poll() is None:
                output = log_path.read_bytes()
                timed_out = time.monotonic() >= deadline
                if timed_out or any(marker in output for marker in failure_markers):
                    finish_processes({'console': process})
                    break
                if on_ready is not None and ready_marker in output:
                    callback, on_ready = on_ready, None
                    callback(max(0, deadline - time.monotonic()))
                time.sleep(0.1)
            returncode = process.wait()
        finally:
            finish_processes({'console': process})
    return returncode, timed_out
