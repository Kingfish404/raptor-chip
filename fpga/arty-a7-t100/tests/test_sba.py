from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

BOARD = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BOARD / "scripts/hw"))
from common import tcl_string


class SbaScripts(unittest.TestCase):
    def run_tcl(self, body):
        for interpreter in ("tclsh", "openocd"):
            with self.subTest(interpreter=interpreter), tempfile.TemporaryDirectory() as directory:
                script = Path(directory) / "test.tcl"
                script.write_text("set OUT " + tcl_string(Path(directory) / "backups") + "\n" + body)
                command = ["tclsh", str(script)]
                if interpreter == "openocd":
                    # Dummy is entirely software; shutdown prevents adapter initialization.
                    command = ["openocd", "-c", "adapter driver dummy",
                               "-c", "rename shutdown test_real_shutdown", "-f", str(script),
                               "-c", "test_real_shutdown"]
                result = subprocess.run(command, capture_output=True, text=True,
                                        timeout=30, check=False)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("TCL_TEST_PASS", result.stdout)

    def test_standard_sba_fields_busy_errors_and_alignment(self):
        body = r'''
set capability 0x20000404
set config 0
set address 0
set value 0
set busy 0
set bus_error 0
array set ram {2147483648 305419896}
proc rapt_dmi {number data operation} {
    global capability config address value busy bus_error ram
    set number [expr {$number + 0}]
    if {$operation == 1} {
        if {$number == 0x38} {
            if {$busy > 0} {incr busy -1; return [expr {$capability | $config | 0x200000}]}
            return [expr {$capability | $config | $bus_error}]
        }
        if {$number == 0x3c} {return $value}
        error "unexpected DMI read"
    }
    switch $number {
        56 {
            if {$data & 0x407000} {set bus_error 0}
            set config [expr {$data & 0x1f8000}]
        }
        57 {
            set address [expr {$data + 0}]
            if {$config & 0x100000} {set value $ram($address); set busy 2}
        }
        60 {
            if {($config & 0xe0000) != 0x40000} {error "wrong sbaccess field"}
            set ram($address) $data
            set busy 2
        }
        default {error "unexpected DMI write"}
    }
    return 0
}
'''
        body += "source " + tcl_string(BOARD / "scripts/sba.tcl") + "\n"
        body += r'''
rapt_sba_require
if {[rapt_sba_read32 0x80000000] != 0x12345678} {error "read failed"}
rapt_sba_write32 0x80000000 0x89abcdef
if {[rapt_sba_read32 0x80000000] != 0x89abcdef} {error "write failed"}
if {![catch {rapt_sba_read32 0x80000001}]} {error "unaligned read accepted"}
if {![catch {rapt_sba_write32 0x80000002 1}]} {error "unaligned write accepted"}
set bus_error 0x2000
if {![catch {rapt_sba_wait}]} {error "bus error ignored"}
set capability 0
if {![catch {rapt_sba_require} message] || ![string match *SBA_PENDING* $message]} {
    error "absent SBA did not remain pending"
}
puts TCL_TEST_PASS
'''
        self.run_tcl(body)

    def test_flash_sba_backup_program_boundaries_and_cleanup(self):
        body = r'''
set OFFSET 0x804000
set IMAGE {}
set selected_address 0
set selected_data 0
set programs 0
set erases 0
array set flash {0 305419896 65536 2271560481}
proc rapt_sba_require {} {}
proc rapt_halt {} {}
proc rapt_dmi {args} {return 0}
proc get_word {offset} {
    global flash
    set offset [expr {$offset + 0}]
    if {[info exists flash($offset)]} {return $flash($offset)}
    return 4294967295
}
proc rapt_sba_read32 {address} {
    global selected_address selected_data
    set address [expr {$address + 0}]
    switch $address {
        268443648 {return 0x52504632}
        268443652 {return 0x0081000c}
        268443656 {return 0x2c5b19}
        268443676 {return $selected_data}
        268443684 {return 4096}
        default {
            if {$address >= 0x30000000 && $address < 0x30800000} {
                return [get_word [expr {$address - 0x30000000 + 0x800000}]]
            }
            error [format "unexpected SBA read %08x" $address]
        }
    }
}
proc rapt_sba_write32 {address value} {
    global selected_address selected_data programs erases flash
    set address [expr {$address + 0}]
    switch $address {
        268443660 {set selected_address [expr {$value + 0}]}
        268443664 {if {$value != 4} {error "PROGRAM32 length"}}
        268443676 {set selected_data $value}
        268443668 {
            if {$value == 0x52410005} {set selected_data [get_word $selected_address]; return}
            if {$selected_address < 0x800000 || $selected_address >= 0x1000000} {
                error "forbidden physical mutation"
            }
            if {$value == 0x52410001} {
                if {$selected_address & 4095} {error "unaligned erase"}
                for {set index 0} {$index < 4096} {incr index 4} {
                    set flash([expr {$selected_address + $index}]) 4294967295
                }
                incr erases
            } elseif {$value == 0x52410002} {
                set flash($selected_address) [expr {[get_word $selected_address] & $selected_data}]
                incr programs
            } else {error "unknown flash command"}
        }
        default {error "unexpected SBA write"}
    }
}
proc shutdown {args} {if {[llength $args]} {error "shutdown error"}}
'''
        body += "source " + tcl_string(BOARD / "scripts/hw/flash_sba.tcl") + "\n"
        body += r'''
if {$programs != 4 || $erases != 2} {error "incomplete mutation coverage"}
if {[get_word 0] != 0x12345678 || [get_word 65536] != 0x87654321} {
    error "protected contents changed"
}
if {![file exists [file join $OUT original-00000000.words]]} {error "missing boot backup"}
if {![catch {program_word 0x803000 0}]} {error "unowned neighbour accepted"}
puts TCL_TEST_PASS
'''
        self.run_tcl(body)
        image_body = body.replace("set IMAGE {}", "set IMAGE synthetic.bin\n"
                                  "set IMAGE_WORDS {305419896 2271560481 1437226410 0}")
        image_body = image_body.replace("$erases != 2", "$erases != 1")
        self.run_tcl(image_body)


if __name__ == "__main__":
    unittest.main()
