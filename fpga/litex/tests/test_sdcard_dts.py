"""MMC resource bounds and hardware-layout checks; no FPGA build needed."""
import copy
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from add_linux_sdcard_dts import sdcard_node


def csr_fixture():
    registers = {}
    names = [('phy_card_detect', 0, 1), ('phy_clocker_divider', 4, 1), ('phy_init_initialize', 8, 1),
             ('core_cmd_argument', 28, 1), ('core_cmd_command', 32, 1), ('core_cmd_send', 36, 1),
             ('core_cmd_response', 40, 4), ('core_cmd_event', 56, 1), ('core_data_event', 60, 1),
             ('core_block_length', 64, 1), ('core_block_count', 68, 1)]
    for prefix, base in [('block2mem', 72), ('mem2block', 104)]:
        names.extend((prefix + '_dma_' + name, base + offset, size) for name, offset, size in
                     [('base', 0, 2), ('length', 8, 1), ('enable', 12, 1), ('done', 16, 1), ('loop', 20, 1)])
    for name, offset, size in names:
        registers['sdcard_' + name] = {'addr': 0xf0002000 + offset, 'size': size}
    return {'csr_registers': registers, 'constants': {'config_clock_frequency': 50000000}}


class SdcardDtsTest(unittest.TestCase):
    def test_current_layout_polling_and_separate_dma_resources(self):
        node = sdcard_node(csr_fixture())
        self.assertIn('<0xf0002048 0x20>, <0xf0002068 0x20>', node)
        self.assertIn('clock-frequency = <50000000>', node)
        self.assertNotIn('interrupts =', node)
        self.assertNotIn('dma-coherent;', node)

    def test_unknown_dma_layout_rejected(self):
        for field, value in [('addr', 0xf0002050), ('size', 1)]:
            csr = copy.deepcopy(csr_fixture())
            csr['csr_registers']['sdcard_block2mem_dma_base'][field] = value
            with self.assertRaisesRegex(ValueError, 'layout'):
                sdcard_node(csr)

    def test_cached_mmio_and_invalid_clock_rejected(self):
        csr = csr_fixture()
        for register in csr['csr_registers'].values():
            register['addr'] -= 0x70000000
        with self.assertRaisesRegex(ValueError, 'uncached'):
            sdcard_node(csr)
        csr = csr_fixture()
        csr['constants']['config_clock_frequency'] = 0
        with self.assertRaisesRegex(ValueError, 'clock'):
            sdcard_node(csr)


if __name__ == '__main__':
    unittest.main()
