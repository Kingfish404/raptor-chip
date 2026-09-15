"""Check the adapter wiring without instantiating the opaque CPU RTL.

Run with fpga/litex/.venv/bin/python fpga/litex/tests/test_irq_mapping.py.
"""

import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "cores"))

from migen import Module, Signal
from migen.sim import run_simulation
from cpu.raptor.core import Raptor


class InterruptMappingTest(unittest.TestCase):
    def test_all_plic_sources(self):
        for variant in ("linux32", "linux64"):
            with self.subTest(variant=variant):
                cpu = Raptor(None, variant)
                # Finalizing the CPU would instantiate vendor/RTL blackboxes.
                # Evaluate the actual expressions passed to those RTL ports.
                wiring = Module()
                sources = Signal(31)
                legacy = Signal()
                wiring.comb += [
                    sources.eq(cpu.cpu_params["i_ext_irq_i"]),
                    legacy.eq(cpu.cpu_params["i_io_interrupt"]),
                ]

                def stimulus():
                    for value in [0, *[1 << n for n in range(32)], 0xffffffff]:
                        yield cpu.interrupt.eq(value)
                        yield
                        self.assertEqual((yield sources), value & 0x7fffffff)
                        self.assertEqual((yield legacy), 0)

                run_simulation(wiring, stimulus())


if __name__ == "__main__":
    unittest.main()
