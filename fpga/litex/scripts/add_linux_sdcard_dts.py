#!/usr/bin/env python3
"""Describe LiteSDCard from matching CSR registers; use Linux polling mode."""
import argparse
import json
from pathlib import Path


def sdcard_node(csr):
    registers = csr['csr_registers']
    def address(name):
        return registers['sdcard_' + name]['addr']
    groups = [
        ('phy', 'phy_card_detect', 0x1c,
         {'phy_card_detect': (0, 1), 'phy_clocker_divider': (4, 1), 'phy_init_initialize': (8, 1)}),
        ('core', 'core_cmd_argument', 0x2c,
         {'core_cmd_argument': (0, 1), 'core_cmd_command': (4, 1), 'core_cmd_send': (8, 1),
          'core_cmd_response': (12, 4), 'core_cmd_event': (28, 1), 'core_data_event': (32, 1),
          'core_block_length': (36, 1), 'core_block_count': (40, 1)}),
    ]
    for name, prefix in [('reader', 'block2mem'), ('writer', 'mem2block')]:
        groups.append((name, prefix + '_dma_base', 0x20,
                       {prefix + '_dma_' + reg: (offset, size) for reg, offset, size in
                        [('base', 0, 2), ('length', 8, 1), ('enable', 12, 1),
                         ('done', 16, 1), ('loop', 20, 1)]}))
    regions = []
    for _, first, size, members in groups:
        base = address(first)
        if not 0xc0000000 <= base < base + size <= 0x100000000:
            raise ValueError('SD registers must be in the uncached I/O aperture')
        for name, (offset, width) in members.items():
            if address(name) != base + offset or registers['sdcard_' + name]['size'] != width:
                raise ValueError('unsupported LiteSDCard register layout: ' + name)
        if any(base < old + length and old < base + size for old, length in regions):
            raise ValueError('SD register regions overlap')
        regions.append((base, size))
    clock = csr['constants']['config_clock_frequency']
    if not isinstance(clock, int) or not 0 < clock < 2**32:
        raise ValueError('invalid SD reference clock')
    reg = ', '.join(f'<0x{base:x} 0x{size:x}>' for base, size in regions)
    return f'''
/ {{
    raptor_sdclk: sd-reference-clock {{
        compatible = "fixed-clock";
        #clock-cells = <0>;
        clock-frequency = <{clock}>;
    }};
    raptor_sd_vcc: sd-regulator {{
        compatible = "regulator-fixed";
        regulator-name = "sd-3v3";
        regulator-min-microvolt = <3300000>;
        regulator-max-microvolt = <3300000>;
        regulator-always-on;
    }};
}};
&{{/soc}} {{
    mmc@{regions[0][0]:x} {{
        compatible = "litex,mmc";
        reg = {reg};
        reg-names = "phy", "core", "reader", "writer";
        clocks = <&raptor_sdclk>;
        vmmc-supply = <&raptor_sd_vcc>;
        bus-width = <4>;
        /* No IRQ: use the driver's polling path for initial board validation.
         * DMA is noncoherent; do not add dma-coherent here. */
        status = "okay";
    }};
}};
'''


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('csr', type=Path)
    parser.add_argument('dts', type=Path)
    args = parser.parse_args()
    source = args.dts.read_text()
    if '"litex,mmc"' in source:
        parser.error('DTS already has MMC; regenerate the base DTS')
    args.dts.write_text(source + sdcard_node(json.loads(args.csr.read_text())))
