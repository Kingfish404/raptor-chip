from pathlib import Path
import sys
import tempfile
import threading
import unittest

from execution import run_logged


class ExecutionTests(unittest.TestCase):
    def test_fatal_guest_output_cannot_be_a_successful_run(self):
        with tempfile.TemporaryDirectory() as directory:
            result = run_logged([sys.executable, "-c", "print('Kernel panic - test')"],
                                Path(directory) / "run.log", 5)
        self.assertTrue(result["fatal"])
        self.assertFalse(result["timed_out"])

    def test_host_timeout_terminates_owned_process(self):
        with tempfile.TemporaryDirectory() as directory:
            result = run_logged([sys.executable, "-c", "import time; time.sleep(30)"],
                                Path(directory) / "run.log", 0.1)
        self.assertTrue(result["timed_out"])
        self.assertNotEqual(result["returncode"], 0)
        self.assertLess(result["wall_seconds"], 10)

    def test_fatal_diagnostic_before_large_log_tail_is_not_lost(self):
        with tempfile.TemporaryDirectory() as directory:
            command = "import sys; sys.stdout.write('Kernel panic\\n' + 'x' * 1048576)"
            result = run_logged([sys.executable, "-c", command],
                                Path(directory) / "run.log", 5)
        self.assertTrue(result["fatal"])

    def test_cancellation_terminates_the_owned_session(self):
        stop = threading.Event()
        timer = threading.Timer(.1, stop.set)
        with tempfile.TemporaryDirectory() as directory:
            timer.start()
            try:
                result = run_logged([sys.executable, "-c", "import time; time.sleep(30)"],
                                    Path(directory) / "run.log", 10, stop=stop)
            finally:
                timer.cancel()
        self.assertTrue(result["cancelled"])
        self.assertNotEqual(result["returncode"], 0)
        self.assertLess(result["wall_seconds"], 5)


if __name__ == "__main__":
    unittest.main()
