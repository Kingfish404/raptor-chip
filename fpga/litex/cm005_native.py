#!/usr/bin/env python3
"""Generate the native CU08 CM005 forwarder, MMIO CSR bank and scoped constraints."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import sys

REPO = Path(__file__).resolve().parents[2]
PIN_PROPERTY = re.compile(r'set_property (?:LOC|PACKAGE_PIN|IOSTANDARD|PULLTYPE|DRIVE|SLEW'
                          r'|UNAVAILABLE_DURING_CALIBRATION)\b')
# Use the fingerprinted checkout, not editable packages from another workspace.
for dependency in reversed(('migen', 'litex', 'liteeth', 'litedram')):
    sys.path.insert(0, str(REPO / 'third_party/enjoy-digital' / dependency))

from migen import Cat, Case, If, Replicate
from litex.gen import LiteXContext, LiteXModule
from litex.build.generic_platform import Pins, Subsignal
from litex.soc.interconnect.csr import CSRStatus, GenericBank

from cm005_bridge import add_cm005_forwarder
from ku15p_soc import _CRG
from mlk_cu08_ku15p import BOARD


class NativeCSRBank(GenericBank):
    """Independent read/write addresses and one-cycle reads, matching native bus.

    Read data holds during AXI response backpressure. Byte writes preserve the
    other bytes of readable storage registers. Native read/write can coincide.
    """
    def __init__(self, descriptions, bus):
        super().__init__([csr for _, bank in descriptions for csr in bank], busword=32)
        read_cases = {}
        self.registers = []
        mask = Cat(*(Replicate(bus.wstrb[i], 8) for i in range(4)))
        for index, csr in enumerate(self.simple_csrs):
            address = index * 4
            self.registers.append({'name': csr.name, 'offset': address, 'bits': csr.size})
            self.comb += [
                csr.wr_data.eq((csr.rd_data & ~mask) | (bus.wdata & mask)),
                csr.wr_stb.eq(bus.wr & (bus.waddr == address) & (bus.wstrb != 0)),
                csr.rd_stb.eq(bus.rd & (bus.raddr == address)),
            ]
            read_cases[address] = bus.rdata.eq(csr.rd_data)
        read_cases['default'] = bus.rdata.eq(0)
        self.sync += If(bus.rd, Case(bus.raddr, read_cases))


class NativeCM005Bridge(LiteXModule):
    def __init__(self, platform):
        platform.add_extension([('native', 0,
            Subsignal('clk', Pins(1)), Subsignal('reset', Pins(1)),
            Subsignal('rd', Pins(1)), Subsignal('wr', Pins(1)),
            Subsignal('raddr', Pins(16)), Subsignal('waddr', Pins(16)),
            Subsignal('wdata', Pins(32)), Subsignal('wstrb', Pins(4)),
            Subsignal('rdata', Pins(32)))])
        bus = platform.request('native')
        self.crg = _CRG(platform, 50_000_000, with_ethernet=True,
                        cm005_oversample=True, cm005_tx_split=True, cm005_tx_dual=True,
                        external_sys=(bus.clk, bus.reset))
        add_cm005_forwarder(self, platform)
        self.ident = CSRStatus(32, name='bridge_id', reset=0x434d3035)
        self.version = CSRStatus(32, name='bridge_version', reset=1)
        descriptions = [('identity', [self.ident, self.version])]
        for name in ('phy_a', 'phy_b', 'mac_a', 'mac_b', 'a_to_b', 'b_to_a'):
            csrs = getattr(self, name).get_csrs()
            for csr in csrs:
                csr.name = name + '_' + csr.name
            descriptions.append((name, csrs))
        self.native_csrs = NativeCSRBank(descriptions, bus)


SCOPED_QUERIES = r'''# Preserve the CM005 timing contract inside the native top hierarchy.
proc cm005_native_object {kind args} {
    if {[lsearch -exact $args -of_objects] >= 0 || [lsearch -exact $args -filter] >= 0} {
        return [uplevel #0 [linsert $args 0 $kind]]
    }
    set patterns [lindex $args end]
    set translated {}
    foreach pattern $patterns {
        if {$kind eq "get_nets" && $pattern eq "sys_clk"} {
            lappend translated clk
        } else {
            lappend translated cm005_bridge/$pattern
        }
    }
    return [uplevel #0 [linsert [lreplace $args end end $translated] 0 $kind]]
}
proc cm005_native_cells {args} {return [cm005_native_object get_cells {*}$args]}
proc cm005_native_pins {args} {return [cm005_native_object get_pins {*}$args]}
proc cm005_native_nets {args} {return [cm005_native_object get_nets {*}$args]}
proc cm005_native_check_partial_inputs {timing_check count} {
    # UG903: -datapath_only intentionally removes the hold requirement. The
    # asynchronous sampler instead has a 2 ns physical-path bound plus the
    # routed relative-aperture check. Do not exempt ordinary RGMII inputs.
    set pattern {\n[0-9]+\. checking partial_input_delay \([0-9]+\)\n-+\n(.*?)\n[0-9]+\. checking }
    if {$count != 6 || ![regexp $pattern $timing_check -> section]} {
        error "Unexpected partial input-delay coverage in native CM005 design"
    }
    set ports [list cm005_clocks_rx cm005_rx_ctl \
        {cm005_rx_data[0]} {cm005_rx_data[1]} {cm005_rx_data[2]} {cm005_rx_data[3]}]
    foreach port $ports lane {clock control data0 data1 data2 data3} {
        if {[string first "\n$port\n" $section] < 0} {
            error "Partial input-delay exception does not match sampler port $port"
        }
        set pin [cm005_native_pins cm005_sample_${lane}_iserdes/D]
        set path [get_timing_paths -quiet -from [get_ports $port] -to $pin -delay_type max -max_paths 1]
        if {[llength $pin] != 1 || [llength $path] != 1 || abs([get_property REQUIREMENT $path] - 2.0) > 0.000001} {
            error "Missing or changed 2 ns sampler path constraint for $port"
        }
    }
}
'''


def scoped(text):
    for kind in ('cells', 'pins', 'nets'):
        text = re.sub(r'\bget_' + kind + r'\b', 'cm005_native_' + kind, text)
    return text


def check_dependency_origins():
    """Reject editable-install fallbacks outside the fingerprinted checkout."""
    for name, module in tuple(sys.modules.items()):
        dependency = name.split('.')[0]
        if dependency not in ('migen', 'litex', 'liteeth', 'litedram'):
            continue
        filename = getattr(module, '__file__', None)
        if filename is None:
            continue
        root = REPO / 'third_party/enjoy-digital' / dependency
        if name == 'litex.soc.cores.cpu.raptor' or name.startswith('litex.soc.cores.cpu.raptor.'):
            root = REPO / 'fpga/litex/cores/cpu/raptor'
        if not Path(filename).resolve().is_relative_to(root.resolve()):
            raise RuntimeError(f'Unfingerprinted dependency {name}: {filename}')


def generate(output):
    output.mkdir(parents=True, exist_ok=True)
    platform = BOARD.platform()
    dut = NativeCM005Bridge(platform)
    # This standalone module has no SoC context. Suppress the hierarchy comment:
    # it can retain a prior SoC and its blackbox order depends on object IDs.
    previous_top = LiteXContext.top
    try:
        LiteXContext.top = None
        platform.build(dut, build_dir=str(output / 'generation'),
                       build_name='rapt_cm005_bridge', run=False)
    finally:
        LiteXContext.top = previous_top
    check_dependency_origins()
    raw = output / 'generation'
    rtl = (raw / 'rapt_cm005_bridge.v').read_text()
    rtl = re.sub(r'^// (?:Date|LiteX sha1)\s*:.*\n', '', rtl, flags=re.M)
    rtl = re.sub(r'^//  Auto-Generated by LiteX on .*\n', '', rtl, flags=re.M)
    (output / 'rapt_cm005_bridge.v').write_text(rtl)
    xdc = (raw / 'rapt_cm005_bridge.xdc').read_text()
    pins, timing = [], []
    for line in xdc.splitlines():
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        if re.search(r'get_ports\s+\{?(?:clk100|cpu_resetn|native_)', line):
            continue
        if '[current_design]' in line:
            continue
        if PIN_PROPERTY.match(line) and '[get_ports ' in line:
            pins.append(line)
        else:
            timing.append(scoped(line))
    groups = []
    for line in timing:
        if not line.startswith('set_clock_groups '):
            continue
        clocks = re.findall(r'-group (\[get_clocks -of \[cm005_native_nets [^\]]+\]\])', line)
        if len(clocks) != 2 or not line.endswith(' -asynchronous'):
            raise ValueError(f"Unexpected generated clock group: {line}")
        groups.append('set_clock_groups ' + ' '.join('-group ' + c for c in sorted(clocks)) + ' -asynchronous')
    groups.sort()
    timing = [line for line in timing if not line.startswith('set_clock_groups ')] + groups
    (output / 'cm005_pins.xdc').write_text('\n'.join(pins) + '\n')
    # The existing check uses physical cells; apply these after synthesis and
    # before opt/place. Native board.xdc owns clk100, reset, UART and LEDs.
    rendered_tcl = (raw / 'rapt_cm005_bridge.tcl').read_text()
    pre_opt = rendered_tcl.split('# Add pre-optimize commands', 1)[1].split('# Optimize design', 1)[0]
    text = SCOPED_QUERIES + '\n'.join(timing) + '\n'
    text += scoped(pre_opt) + '\n'
    text += 'set_property CLOCK_DEDICATED_ROUTE SAME_CMT_COLUMN [get_nets -of_objects [get_pins ref_buf/O]]\n'
    # MDIO is a software/initializer-paced GPIO protocol; its input has a
    # two-flop synchronizer. These exceptions never include RGMII data/clocks.
    text += '# Asynchronous MDIO management and shared PHY reset controls.\n'
    text += 'set_false_path -from [get_ports {cm005_mdio cm005_b_mdio}]\n'
    text += 'set_false_path -to [get_ports {cm005_mdio cm005_b_mdio cm005_mdc cm005_b_mdc cm005_reset_gate}]\n'
    (output / 'cm005_timing.tcl').write_text(text)
    aperture = Path(__file__).parent / 'scripts/check_cm005_aperture.tcl'
    (output / 'cm005_aperture.tcl').write_text(scoped(aperture.read_text()))
    (output / 'cm005_registers.json').write_text(json.dumps({
        'base': '0x18000000', 'version': 1, 'registers': dut.native_csrs.registers}, indent=2) + '\n')
    header = '#ifndef RAPT_CM005_REGISTERS_H\n#define RAPT_CM005_REGISTERS_H\n'
    for r in dut.native_csrs.registers:
        header += f'#define CM005_{r["name"].upper()} 0x{r["offset"]:04x}u\n'
    (output / 'cm005_registers.h').write_text(header + '#endif\n')
    manifest = {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                for p in output.iterdir() if p.is_file() and p.name != 'cm005_generated.json'}
    (output / 'cm005_generated.json').write_text(json.dumps(manifest, indent=2) + '\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    generate(args.output.resolve())
