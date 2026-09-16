#!/usr/bin/env python3
"""Append the single LiteEth MAC exported by a matching Raptor gateware build."""

import argparse
import json
from pathlib import Path
from add_linux_sdcard_dts import sdcard_node


def ethernet_node(csr):
    bases, constants = csr["csr_bases"], csr["constants"]
    memory = csr["memories"]["ethmac"]
    mac, phy = bases["ethmac"], bases["ethphy"]
    irq = constants["ethmac_interrupt"]
    rx, tx = constants["ethmac_rx_slots"], constants["ethmac_tx_slots"]
    size = constants["ethmac_slot_size"]
    if not isinstance(irq, int) or not 0 <= irq < 31:
        raise ValueError("Ethernet IRQ must map to a Raptor PLIC source 1..31")
    if min(rx, tx, size) <= 0 or (rx + tx) * size > memory["size"]:
        raise ValueError("Ethernet slots exceed the exported buffer region")
    # Raptor memory map is single-cell, including RV64. LiteEth buffers must
    # live in the uncached I/O aperture, not in the CPU's cached main RAM.
    for address, length in ((mac, 0x7c), (phy, 0x0a), (memory["base"], memory["size"])):
        if length <= 0 or not 0xc0000000 <= address < address + length <= 0x100000000:
            raise ValueError("Ethernet regions must fit in Raptor's uncached I/O aperture")
    # Register layout follows the in-tree LiteX JSON-to-Linux-DTS exporter.
    # Unlike zero-based LiteX IRQ numbering, Raptor reserves PLIC source 0.
    return f'''
&{{/soc}} {{
    mac@{mac:x} {{
        compatible = "litex,liteeth";
        reg = <0x{mac:x} 0x7c>, <0x{phy:x} 0x0a>,
              <0x{memory["base"]:x} 0x{memory["size"]:x}>;
        reg-names = "mac", "mdio", "buffer";
        litex,rx-slots = <{rx}>;
        litex,tx-slots = <{tx}>;
        litex,slot-size = <{size}>;
        interrupt-parent = <&plic>;
        interrupts = <{irq + 1}>;
        status = "okay";
    }};
}};
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("csr", type=Path)
    parser.add_argument("dts", type=Path)
    args = parser.parse_args()
    try:
        csr = json.loads(args.csr.read_text())
        node = ethernet_node(csr)
        if 'sdcard_phy_card_detect' in csr.get('csr_registers', {}):
            node += sdcard_node(csr)
        text = args.dts.read_text()
        if '"litex,liteeth"' in text:
            raise ValueError("DTS already contains Ethernet; regenerate the base DTS first")
        args.dts.write_text(text + node)
    except (KeyError, TypeError, ValueError, OSError) as error:
        parser.exit(1, f"Ethernet DTS: {error}\n")


if __name__ == "__main__":
    main()
