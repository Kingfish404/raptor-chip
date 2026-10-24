#!/usr/bin/env python3
"""Read CM005 bridge counters and Clause-22 PHY status over UARTBone.

Requires the matching bridge csr.csv and an already programmed CU08 board.
No PHY configuration writes are issued; MDIO CSR writes only clock reads.
"""
import argparse
import json
import os
import time
from pathlib import Path

from litex.tools.remote.comm_uart import CommUART


class BoundedUART(CommUART):
    def _read(self, length):
        deadline = time.monotonic() + 3
        result = bytearray()
        while len(result) < length:
            result.extend(self.port.read(length - len(result)))
            if time.monotonic() >= deadline:
                raise TimeoutError("UARTBone response timed out; check the loaded bitstream and port")
        return bytes(result)


def require_free_uart(device):
    target = os.stat(device).st_rdev
    for process in Path('/proc').glob('[0-9]*'):
        if process.name == str(os.getpid()):
            continue
        try:
            for descriptor in (process / 'fd').iterdir():
                try:
                    info = descriptor.stat()
                except OSError:
                    continue
                if target and info.st_rdev == target:
                    raise RuntimeError(f"UART already open by PID {process.name}")
        except (PermissionError, FileNotFoundError):
            continue


def mdio_read(bus, write_address, read_address, phy, register):
    if not 0 <= phy < 32 or not 0 <= register < 32:
        raise ValueError("Clause-22 address out of range")
    # mdc=bit0, output-enable=bit1, output-data=bit2.
    bits = [1]*32 + [0, 1, 1, 0]
    bits += [(phy >> shift) & 1 for shift in range(4, -1, -1)]
    bits += [(register >> shift) & 1 for shift in range(4, -1, -1)]
    waveform = [value for bit in bits for value in (2 | (bit << 2), 3 | (bit << 2))]
    bus.write(write_address, waveform, burst='fixed')
    values = []
    for _ in range(18):
        bus.write(write_address, [0, 1], burst='fixed')
        values.append(bus.read(read_address) & 1)
    bus.write(write_address, 0)
    value = 0
    for bit in values[2:]:
        value = (value << 1) | bit
    return {'value': value, 'hex': f'0x{value:04x}', 'turnaround': values[:2]}


def probe(bus, scan=False, counters_only=False):
    old = bus.regs.ctrl_scratch.read()
    try:
        bus.regs.ctrl_scratch.write(0x5c005a5b)
        if bus.regs.ctrl_scratch.read() != 0x5c005a5b:
            raise RuntimeError("UARTBone scratch-register verification failed")
    finally:
        bus.regs.ctrl_scratch.write(old)
    result = {'unix_time': time.time(), 'uartbone': 'passed', 'counters': {}, 'phys': {}}
    names = [name for name in vars(bus.regs)
             if name.startswith(('a_to_b_', 'b_to_a_', 'mac_a_', 'mac_b_'))]
    result['counters'] = {name: getattr(bus.regs, name).read() for name in names}
    if counters_only:
        return result
    for port in ('a', 'b'):
        write_address = getattr(bus.regs, f'phy_{port}_mdio_w').addr
        read_address = getattr(bus.regs, f'phy_{port}_mdio_r').addr
        entries = {}
        for address in (range(32) if scan else (0,)):
            phy_id = mdio_read(bus, write_address, read_address, address, 2)
            if phy_id['value'] in (0, 0xffff):
                continue
            regs = {2: phy_id}
            for reg in (0, 1, 3, 4, 5, 9, 10, 17):
                regs[reg] = mdio_read(bus, write_address, read_address, address, reg)
            # BMSR link-down is latched; a second read reports current link.
            regs[1] = mdio_read(bus, write_address, read_address, address, 1)
            entries[str(address)] = {'registers': regs, 'link_up': bool(regs[1]['value'] & 4),
                                     'autoneg_complete': bool(regs[1]['value'] & 32)}
        result['phys'][port] = entries
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', required=True)
    parser.add_argument('--csr-csv', required=True)
    parser.add_argument('--output', required=True, type=Path)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--scan', action='store_true')
    mode.add_argument('--counters-only', action='store_true',
                      help='Read packet/error counters without issuing MDIO transactions')
    args = parser.parse_args()
    require_free_uart(args.port)
    bus = BoundedUART(args.port, csr_csv=args.csr_csv)
    bus.port.exclusive = True
    bus.port.timeout = 0.2
    bus.port.write_timeout = 3
    try:
        # Let the gateware's 100 ms timeout discard an interrupted request
        # left by an earlier client before sending the scratch transaction.
        time.sleep(0.3)
        result = probe(bus, args.scan, args.counters_only)
        bus.port.flush()
        args.output.write_text(json.dumps(result, indent=2) + '\n')
        print(json.dumps(result, indent=2))
    finally:
        bus.close()


if __name__ == '__main__':
    main()
