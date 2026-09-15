"""Run with python3 fpga/litex/tests/test_ethernet_dts.py."""
import copy
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "scripts"))
from add_linux_ethernet_dts import ethernet_node


class EthernetDTTest(unittest.TestCase):
    def setUp(self):
        self.csr = {
            "csr_bases": {"ethmac": 0xf0002800, "ethphy": 0xf0003000},
            "constants": {"ethmac_interrupt": 3, "ethmac_rx_slots": 2,
                          "ethmac_tx_slots": 2, "ethmac_slot_size": 2048},
            "memories": {"ethmac": {"base": 0xc1000000, "size": 8192}},
        }

    def test_irq_and_regions(self):
        node = ethernet_node(self.csr)
        self.assertIn("interrupts = <4>;", node)
        self.assertIn("<0xc1000000 0x2000>", node)
        self.assertIn("litex,slot-size = <2048>;", node)

    def test_rejects_invalid_contract(self):
        for section, key, value in [("constants", "ethmac_interrupt", 31),
                                    ("constants", "ethmac_rx_slots", 10)]:
            csr = copy.deepcopy(self.csr)
            csr[section][key] = value
            with self.assertRaises(ValueError):
                ethernet_node(csr)
        self.csr["memories"]["ethmac"]["base"] = 0x80000000
        with self.assertRaises(ValueError):
            ethernet_node(self.csr)

    @unittest.skipUnless(shutil.which("dtc"), "dtc is required")
    def test_compiles_and_resolves_plic(self):
        base = '''/dts-v1/;
        / { #address-cells = <1>; #size-cells = <1>;
            soc { #address-cells = <1>; #size-cells = <1>; ranges;
                plic: interrupt-controller@c000000 {
                    reg = <0xc000000 0x4000000>;
                    interrupt-controller; #interrupt-cells = <1>;
                    #address-cells = <0>;
                };
            };
        };
        '''
        with tempfile.TemporaryDirectory() as tmp:
            source = pathlib.Path(tmp) / "soc.dts"
            source.write_text(base + ethernet_node(self.csr))
            subprocess.run(["dtc", "-I", "dts", "-O", "dtb", "-o",
                            str(source.with_suffix(".dtb")), str(source)], check=True)


if __name__ == "__main__":
    unittest.main()
