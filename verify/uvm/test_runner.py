"""The simulator may exit 0 on UVM_FATAL: prove the runner fails closed."""
import unittest
from run import successful

PASS = "UVM_INFO chip.sv(1) @ 1: test [CHIP_PASS] all chip checks passed\n"


class ResultTests(unittest.TestCase):
    def test_complete_success(self):
        self.assertTrue(successful(0, PASS + "UVM_ERROR : 0\nUVM_FATAL : 0\n"))

    def test_zero_counts_with_alignment(self):
        self.assertTrue(successful(0, PASS + "UVM_ERROR     : 0\nUVM_FATAL     : 0\n"))

    def test_exit_zero_fatal_is_failure(self):
        self.assertFalse(successful(0, "UVM_FATAL foo.sv(4) @ 9: test [TIMEOUT] stopped\n"))

    def test_error_after_pass_is_failure(self):
        self.assertFalse(successful(0, PASS + "UVM_ERROR foo.sv(4) @ 9: test [CHECK] mismatch\n"))

    def test_reported_error_count_is_failure(self):
        self.assertFalse(successful(0, PASS + "UVM_ERROR : 1\n"))

    def test_summary_id_is_not_a_pass(self):
        self.assertFalse(successful(0, "[CHIP_PASS] 1\n"))

    def test_abnormal_exit_and_host_timeout(self):
        self.assertFalse(successful(1, PASS))
        self.assertFalse(successful(0, PASS + "HOST_TIMEOUT\n"))
        self.assertFalse(successful(0, PASS + "%Error: assertion failed\n"))


if __name__ == "__main__":
    unittest.main()
