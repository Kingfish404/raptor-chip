"""Own one child process group; stdin EOF or a signal terminates and reaps it.

The caller keeps stdin's pipe open as a lifeline. Place this guard after sudo
in privileged wrappers so it has permission to kill its own OpenOCD child.
It does not accept process IDs or signal unrelated processes.
"""

import argparse
import os
import select
import signal
import subprocess
import sys
import time


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--grace", type=float, default=3)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    command = args.command
    if command and command[0] == "--":
        command = command[1:]
    if not command or not 0 < args.grace <= 10:
        parser.error("give a child command and a 0..10 second cleanup grace period")
    stopping = False

    def stop(signum, frame):
        nonlocal stopping
        stopping = True

    for signum in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(signum, stop)
    child = subprocess.Popen(command, stdin=subprocess.PIPE, start_new_session=True)
    print(f"PROCESS_GUARD child={child.pid} owner={os.getpid()}", file=sys.stderr, flush=True)
    try:
        while child.poll() is None and not stopping:
            if select.select([sys.stdin.fileno()], [], [], 0.1)[0]:
                if not os.read(sys.stdin.fileno(), 4096):
                    break
        return child.returncode if child.returncode is not None else 124
    finally:
        # Closing the child's lifeline also reaches a guard placed after sudo.
        child.stdin.close()
        try:
            os.killpg(child.pid, signal.SIGTERM)
        except (ProcessLookupError, PermissionError):
            pass
        deadline = time.monotonic() + args.grace
        while child.poll() is None and time.monotonic() < deadline:
            time.sleep(0.02)
        try:
            os.killpg(child.pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass
        try:
            child.wait(timeout=args.grace)
        except subprocess.TimeoutExpired:
            # A privileged wrapper must run this guard after sudo, as documented.
            print("PROCESS_GUARD cleanup failed: privileged child lacks a guard",
                  file=sys.stderr, flush=True)
            raise


if __name__ == "__main__":
    raise SystemExit(main())
