"""Block transports must preserve boundaries and uncertain-operation semantics."""

from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from tools.bringup.client import BringupError
from tools.bringup.native_flash import Sba32
from tools.bringup.native_links import OpenOcdTarget, TransportError


class BatchTarget:
    batch_sba = True

    def __init__(self):
        self.calls = []

    def sba_read_words(self, address, count, timeout):
        self.calls.append(("read", address, count))
        return list(range(count))

    def sba_write_words(self, address, words, timeout):
        self.calls.append(("write", address, words))


class BatchTests(unittest.TestCase):
    def test_bus_dispatch_and_full_preflight(self):
        target = BatchTarget()
        bus = Sba32(target)
        self.assertEqual(bus.read_words(0xfffffffc, 1), [0])
        bus.write_words(0x1000, [0, 0xffffffff])
        before = list(target.calls)
        for address, words in ((0xfffffffc, [0, 0]), (0, [1, -1]), (2, [0]),
                               (0, [True]), (0, [])):
            with self.assertRaises(ValueError):
                bus.write_words(address, words)
        self.assertEqual(target.calls, before)

    def transport(self, reply):
        target = OpenOcdTarget.__new__(OpenOcdTarget)
        target.metrics = dict(read_blocks=0, read_words=0, write_blocks=0, write_words=0)
        target.calls = []

        def rpc(command):
            target.calls.append(command)
            return reply(command)

        target.rpc = rpc
        return target

    def test_sector_crosses_rpc_boundary_four_times_without_extra_read(self):
        target = self.transport(lambda c: "{" + " ".join(["ffffffff"] * int(c.split()[2])) + "}")
        self.assertEqual(target.sba_read_words(0x307ff000, 1024, 2), [0xffffffff] * 1024)
        self.assertEqual(len(target.calls), 4)
        self.assertEqual([int(c.split()[1]) for c in target.calls],
                         [0x307ff000, 0x307ff400, 0x307ff800, 0x307ffc00])
        self.assertEqual(target.metrics["read_words"], 1024)

    def test_write_batches_validate_entire_input_before_first_rpc(self):
        target = self.transport(lambda c: "256" if c.count(" ") > 256 else "1")
        with self.assertRaises(ValueError):
            target.sba_write_words(0, [0] * 256 + [-1], 2)
        self.assertFalse(target.calls)
        target.sba_write_words(0x1000, [0] * 257, 2)
        self.assertEqual(len(target.calls), 2)
        self.assertEqual(target.metrics["write_words"], 257)

    def test_malformed_read_or_lost_write_ack_is_never_replayed(self):
        for write in (False, True):
            target = self.transport(lambda c: "bad")
            with self.assertRaises(BringupError):
                if write:
                    target.sba_write_words(0, [1], 2)
                else:
                    target.sba_read_words(0, 1, 2)
            self.assertEqual(len(target.calls), 1)

    def test_disconnect_is_distinct_from_target_error_and_not_retried(self):
        class Socket:
            def sendall(self, data):
                pass

            def recv(self, length):
                return b""

        target = OpenOcdTarget.__new__(OpenOcdTarget)
        target.metrics = {"rpc_calls": 0}
        target.socket = Socket()
        with self.assertRaises(TransportError):
            target.rpc("rapt_batch_read 0 1 1000")
        self.assertEqual(target.metrics["rpc_calls"], 1)


# Runs the actual OpenOCD Jim interpreter with a mock DMI procedure. The script
# shuts down during configuration, before init: no adapter or USB is ever opened.
MOCK = r'''
set cfg 0
set addr 0
set data 0
set reads {}
set writes {}
set calls {}
set fault 0
set fault_after_write 0
proc trigger {} {
    global addr cfg data reads
    lappend reads $addr
    set data [expr {$addr ^ 0x12345678}]
    if {$cfg & 0x10000} {incr addr 4}
}
proc rapt_dmi {reg value op} {
    global cfg addr data reads writes calls fault fault_after_write
    lappend calls [list $reg $value $op]
    if {$reg == 0x38} {
        if {$op == 2} {set cfg $value}
        return [expr {0x20000004 | $cfg | $fault}]
    }
    if {$reg == 0x39 && $op == 2} {
        set addr $value
        if {$cfg & 0x100000} {trigger}
    }
    if {$reg == 0x3c} {
        if {$op == 1} {
            set result $data
            if {$cfg & 0x8000} {trigger}
            return $result
        }
        lappend writes [list $addr $value]
        if {$fault_after_write} {set fault 0x2000}
        if {$cfg & 0x10000} {incr addr 4}
    }
    return 0
}
proc assert {condition} {
    if {![uplevel 1 [list expr $condition]]} {error "assertion failed: $condition"}
}
'''


@unittest.skipUnless(shutil.which("openocd"), "OpenOCD Jim interpreter unavailable")
class TclBatchTests(unittest.TestCase):
    def run_script(self, body):
        source = Path(__file__).resolve().parents[1] / "sba_batch.tcl"
        with tempfile.TemporaryDirectory() as directory:
            script = Path(directory) / "check.tcl"
            script.write_text(MOCK + f"\nsource {{{source}}}\n" + body + "\nshutdown\n")
            result = subprocess.run([shutil.which("openocd"), "-f", str(script)],
                                    capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_boundary_autoincrement_and_no_trailing_access(self):
        self.run_script('''
set words [rapt_batch_read 0xfffffff4 3 1000]
assert {[llength $words] == 3}
assert {[llength $reads] == 3}
foreach actual $reads expected {4294967284 4294967288 4294967292} {
    assert {$actual == $expected}
}
assert {($cfg & 0x8000) == 0}
rapt_batch_write 0x1000 {1 2 4294967295} 1000
assert {[llength $writes] == 3}
foreach pair $writes address {4096 4100 4104} value {1 2 4294967295} {
    assert {[lindex $pair 0] == $address && [lindex $pair 1] == $value}
}
''')

    def test_all_data_and_bounds_checked_before_io(self):
        self.run_script('''
foreach command {
    {rapt_batch_read 0xfffffffc 2 1000}
    {rapt_batch_read 0 257 1000}
    {rapt_batch_write 0 {0 -1} 1000}
    {rapt_batch_write 2 {0} 1000}
    {rapt_batch_write 0 {0 1.5} 1000}
    {rapt_batch_read 0 1.5 1000}
} {
    assert {[catch {eval $command}] == 1}
    assert {[llength $calls] == 0}
}
''')

    def test_busy_and_target_error_never_clear_or_replay(self):
        self.run_script('''
foreach fault {0x200000 0x2000} {
    set calls {}
    assert {[catch {rapt_batch_write 0 {7} 2}] == 1}
    foreach call $calls {assert {[lindex $call 2] == 1}}
    assert {[llength $writes] == 0}
}
''')


    def test_error_after_accepted_write_stops_before_next_word(self):
        self.run_script('''
set fault_after_write 1
assert {[catch {rapt_batch_write 0x1000 {7 8} 1000}] == 1}
assert {[llength $writes] == 1}
assert {[lindex [lindex $writes 0] 1] == 7}
foreach call $calls {
    if {[lindex $call 0] == 0x38 && [lindex $call 2] == 2} {
        assert {([lindex $call 1] & 0x407000) == 0}
    }
}
''')


from tools.bringup.tests import test_native_flash as fixtures
from tools.bringup.native_flash import NativeFlash


class FastBus(fixtures.Bus):
    def write_words(self, address, words):
        for index, word in enumerate(words):
            self.write32(address + 4 * index, word)


class FastFlashSafetyTests(fixtures.HostSafetyTests):
    """Run the existing adversarial Flash cases through batched command staging."""

    def setUp(self):
        self.bus = FastBus()
        self.flash = NativeFlash(self.bus)


if __name__ == "__main__":
    unittest.main()
