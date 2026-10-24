"""Three-port frame flooding switch and LiteEth-compatible CPU packet SRAM.

No address learning: each admitted frame is copied to the other two ports.
Independent complete-frame queues drop on congestion without blocking another
port. The CPU sees the same unfiltered Ethernet traffic as a shared segment.
"""
from litex.gen import LiteXModule
from litex.soc.interconnect import packet, stream
from litex.soc.interconnect.csr import CSRConstant, CSRStatus, CSRStorage
from litex.soc.integration.soc import SoCRegion
from liteeth.common import eth_phy_description
from liteeth.mac.wishbone import LiteEthMACWishboneInterface

from cm005_bridge_queue import EthernetFrameQueue


class CM005Switch(LiteXModule):
    def __init__(self, slots=8):
        self.sinks = [stream.Endpoint(eth_phy_description(32)) for _ in range(3)]
        self.sources = [stream.Endpoint(eth_phy_description(32)) for _ in range(3)]
        queues = {}
        for origin in range(3):
            destinations = [d for d in range(3) if d != origin]
            for destination in destinations:
                queue = EthernetFrameQueue(slots=slots)
                setattr(self, f"q{origin}_to_{destination}", queue)
                queues[origin, destination] = queue
            # Both writers accept/drop whole frames. Their only stalls are
            # bounded descriptor-finalization cycles, independent of output.
            a, b = [queues[origin, d].sink for d in destinations]
            sink = self.sinks[origin]
            self.comb += [
                sink.connect(a, omit={"valid", "ready"}),
                sink.connect(b, omit={"valid", "ready"}),
                a.valid.eq(sink.valid & b.ready),
                b.valid.eq(sink.valid & a.ready),
                sink.ready.eq(a.ready & b.ready),
            ]
        for destination in range(3):
            masters = [queues[o, destination].source for o in range(3) if o != destination]
            setattr(self, f"arbiter{destination}", packet.Arbiter(masters, self.sources[destination]))


class CPUFrameMAC(LiteXModule):
    """Standard LiteEth CSR/IRQ/SRAM ABI, attached after physical FCS checking."""
    def __init__(self, endianness):
        self.rx_slots = CSRConstant(8)
        self.tx_slots = CSRConstant(2)
        self.slot_size = CSRConstant(2048)
        self.interface = LiteEthMACWishboneInterface(32, nrxslots=8, ntxslots=2,
                                                    endianness=endianness)
        self.ev = self.interface.sram.ev
        self.bus_rx, self.bus_tx = self.interface.bus_rx, self.interface.bus_tx
        self.sink, self.source = self.interface.sink, self.interface.source
        # BIOS selects software or hardware framing from this CSR's presence.
        # The physical MACs already insert/check preamble and FCS for this
        # internal port; omitting it makes BIOS prepend a second preamble.
        self.preamble_crc = CSRStatus(reset=1)
        self.csrs = self.interface.get_csrs() + [self.preamble_crc]

    def get_csrs(self):
        return self.csrs


class CPUSegmentPHY(LiteXModule):
    """Virtual shared-segment PHY ABI; software reset never resets A/B links.

    Linux LiteEth and BIOS write the PHY reset register during NIC startup.
    This internal port has no physical clock recovery or PHY to reset. Keep
    the compatibility register local so starting the CPU NIC cannot interrupt
    KU5P traffic. Physical diagnostics remain under phy_a/phy_b CSRs.
    """
    def __init__(self):
        self.crg_reset = CSRStorage(1)


def add_cpu_frame_mac(soc):
    soc.ethphy = CPUSegmentPHY()
    soc.ethmac = mac = CPUFrameMAC(soc.cpu.endianness)
    origin = 0x18000000
    soc.bus.add_region("ethmac", SoCRegion(origin=origin, size=10 * 2048,
                                          linker=True, cached=False))
    soc.bus.add_slave("ethmac_rx", mac.bus_rx,
        SoCRegion(origin=origin, size=8 * 2048, mode="r", linker=False, cached=False))
    soc.bus.add_slave("ethmac_tx", mac.bus_tx,
        SoCRegion(origin=origin + 8 * 2048, size=2 * 2048, mode="rw", linker=False, cached=False))
    if soc.irq.enabled:
        soc.irq.add("ethmac", use_loc_if_exists=True)
    return mac


def check_dependency_origins():
    """Do not silently mix a private FPGA checkout with editable dependencies."""
    from pathlib import Path
    import sys
    repo = Path(__file__).resolve().parents[2]
    for name, module in tuple(sys.modules.items()):
        dependency = name.split('.')[0]
        if dependency not in ('migen', 'litex', 'liteeth', 'litedram', 'litesdcard'):
            continue
        filename = getattr(module, '__file__', None)
        if filename is None:
            continue
        root = repo / 'third_party/enjoy-digital' / dependency
        if name == 'litex.soc.cores.cpu.raptor' or name.startswith('litex.soc.cores.cpu.raptor.'):
            root = repo / 'fpga/litex/cores/cpu/raptor'
        if not Path(filename).resolve().is_relative_to(root.resolve()):
            raise RuntimeError(f"FPGA dependency {name} escaped this checkout: {filename}")
