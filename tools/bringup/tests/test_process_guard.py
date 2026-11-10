"""Own-child cleanup under normal close, signals, and abrupt driver death."""

import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest

GUARD = Path(__file__).resolve().parents[1] / "process_guard.py"


def wait_for(predicate, seconds=6):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(0.02)
    return False


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


class GuardTests(unittest.TestCase):
    def exercise(self, mode, nested=False):
        with tempfile.TemporaryDirectory() as directory:
            pidfile = Path(directory) / "child.pid"
            child = ("import os,signal,time; from pathlib import Path; "
                     "signal.signal(signal.SIGTERM,signal.SIG_IGN); "
                     f"Path({str(pidfile)!r}).write_text(str(os.getpid())); time.sleep(60)")
            command = [sys.executable, str(GUARD), "--grace", "0.3", "--",
                       sys.executable, "-c", child]
            if nested:
                command = [sys.executable, str(GUARD), "--grace", "1", "--", *command]
            process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
                                       stderr=subprocess.DEVNULL)
            child_pid = None
            try:
                self.assertTrue(wait_for(pidfile.exists))
                child_pid = int(pidfile.read_text())
                if mode == "eof":
                    process.stdin.close()
                else:
                    process.send_signal(signal.SIGTERM)
                process.wait(timeout=5)
                self.assertTrue(wait_for(lambda: not alive(child_pid)))
            finally:
                if process.stdin and not process.stdin.closed:
                    process.stdin.close()
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=5)
                if child_pid and alive(child_pid):
                    os.kill(child_pid, signal.SIGKILL)

    def test_eof_kills_and_reaps_child_ignoring_term(self):
        self.exercise("eof")

    def test_signal_kills_and_reaps_child(self):
        self.exercise("signal")

    def test_nested_guard_reaches_privileged_wrapper_position(self):
        self.exercise("eof", nested=True)

    def test_interrupted_transport_shutdown_or_wait_still_reaps_child(self):
        from unittest.mock import patch
        from tools.bringup.native_links import OpenOcdTarget

        for phase in ("shutdown", "wait"):
            with self.subTest(phase=phase), tempfile.TemporaryDirectory() as directory:
                pidfile = Path(directory) / "child.pid"
                child = ("import os,time; from pathlib import Path; "
                         f"Path({str(pidfile)!r}).write_text(str(os.getpid())); time.sleep(60)")
                process = subprocess.Popen(
                    [sys.executable, str(GUARD), "--grace", "0.3", "--",
                     sys.executable, "-c", child], stdin=subprocess.PIPE,
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

                class Socket:
                    def settimeout(self, timeout):
                        pass

                    def sendall(self, data):
                        if phase == "shutdown":
                            raise KeyboardInterrupt("deadline during shutdown")

                    def close(self):
                        pass

                target = OpenOcdTarget.__new__(OpenOcdTarget)
                target.socket, target.process = Socket(), process
                target.metrics_path = Path(directory) / "transport.json"
                target.metrics = {}
                target.log = (Path(directory) / "log").open("w")
                target.dmi_log = None
                child_pid = None
                real_wait = process.wait
                waits = []

                def wait(*args, **kwargs):
                    waits.append(True)
                    if phase == "wait" and len(waits) == 1:
                        raise KeyboardInterrupt("deadline during wait")
                    return real_wait(*args, **kwargs)

                try:
                    self.assertTrue(wait_for(pidfile.exists))
                    child_pid = int(pidfile.read_text())
                    with patch.object(process, "wait", side_effect=wait):
                        with self.assertRaises(KeyboardInterrupt):
                            target.close()
                    self.assertIsNotNone(process.poll())
                    self.assertTrue(wait_for(lambda: not alive(child_pid)))
                    self.assertTrue(target.log.closed)
                finally:
                    if not process.stdin.closed:
                        process.stdin.close()
                    if process.poll() is None:
                        process.terminate()
                        real_wait(timeout=5)
                    if child_pid and alive(child_pid):
                        os.kill(child_pid, signal.SIGKILL)
                    target.log.close()

    def test_driver_sigkill_closes_lifeline(self):
        with tempfile.TemporaryDirectory() as directory:
            child_pidfile = Path(directory) / "child.pid"
            guard_pidfile = Path(directory) / "guard.pid"
            child = ("import os,time; from pathlib import Path; "
                     f"Path({str(child_pidfile)!r}).write_text(str(os.getpid())); time.sleep(60)")
            command = [sys.executable, str(GUARD), "--grace", "0.3", "--",
                       sys.executable, "-c", child]
            owner = ("import subprocess,time; from pathlib import Path; "
                     f"p=subprocess.Popen({command!r},stdin=subprocess.PIPE); "
                     f"Path({str(guard_pidfile)!r}).write_text(str(p.pid)); time.sleep(60)")
            process = subprocess.Popen([sys.executable, "-c", owner], stdout=subprocess.DEVNULL,
                                       stderr=subprocess.DEVNULL)
            child_pid = guard_pid = None
            try:
                self.assertTrue(wait_for(child_pidfile.exists))
                child_pid = int(child_pidfile.read_text())
                guard_pid = int(guard_pidfile.read_text())
                process.kill()
                process.wait(timeout=5)
                self.assertTrue(wait_for(lambda: not alive(child_pid)))
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()
                for pid in (child_pid, guard_pid):
                    if pid and alive(pid):
                        os.kill(pid, signal.SIGKILL)


if __name__ == "__main__":
    unittest.main()
