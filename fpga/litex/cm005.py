"""CM005 (20230821) YT8531 RGMII interface, 1.8 V, fixed 100/1000 Mb/s.

Pin sources: fpga/docs/MLK-FMC-CM005-ETH-LAN-20230821/02_原理图,
sheet 5; H5P-CU07 20241115 and H13-CU08 20251125 baseboard schematics,
and the CU08 FMC_C connector on sheet 7. FMC_C/ETHA RX clock is a
non-GC input: use the oversampling receiver, not a fabric clock route.
"""

from migen import *
from migen.fhdl.specials import Tristate
from migen.genlib.cdc import MultiReg
from migen.genlib.resetsync import AsyncResetSynchronizer
from litex.gen import LiteXModule
from litex.build.generic_platform import IOStandard, Pins, Subsignal
from litex.soc.interconnect import stream
from litex.soc.interconnect.csr import CSRStorage, CSRStatus, CSRField
from liteeth.common import eth_phy_description
from liteeth.phy.usrgmii import LiteEthPHYRGMIITX, LiteEthPHYRGMIIRX


# Ordered as RX clock, TX clock, RX control, RX[0:3], TX control,
# TX[0:3], MDC, MDIO, reset gate. Reset gate HIGH asserts PHY reset.
# FMC: C22 D20 C18 C15 C14 C11 C10 D21 D18 D17 C23 C19 D14 D15 G16.
PINOUTS = {
    ("mlk_cu07_ku15p", "a", "a"):
        "P24 M25 R23 R22 R21 M21 N21 M26 T25 T24 P25 P23 P20 P21 AD28".split(),
    ("mlk_cu08_ku15p", "a", "a"):
        "E18 E16 C19 G14 G15 K17 K18 D16 C17 C18 E17 B19 G19 F19 F24".split(),
    ("mlk_cu08_ku15p", "c", "a"):
        "L19 F18 D14 B16 B17 A18 A19 F17 D15 E15 L18 C14 B15 A15 E8".split(),
}


def add_pads(platform, board, slot, port):
    key = (board, slot.lower(), port.lower())
    if key not in PINOUTS:
        raise ValueError(f"CM005 pin mapping not verified for {key}; supported: {list(PINOUTS)}")
    p = PINOUTS[key]
    platform.add_extension([
        ("cm005_clocks", 0,
            Subsignal("rx", Pins(p[0])), Subsignal("tx", Pins(p[1])), IOStandard("LVCMOS18")),
        ("cm005", 0,
            Subsignal("rx_ctl", Pins(p[2])), Subsignal("rx_data", Pins(" ".join(p[3:7]))),
            Subsignal("tx_ctl", Pins(p[7])), Subsignal("tx_data", Pins(" ".join(p[8:12]))),
            Subsignal("mdc", Pins(p[12])), Subsignal("mdio", Pins(p[13])),
            Subsignal("reset_gate", Pins(p[14])), IOStandard("LVCMOS18")),
    ])
    return platform.request("cm005_clocks"), platform.request("cm005")


class CM005Reset(LiteXModule):
    def __init__(self, sys_clk_freq):
        # YT8531 requires >=10 ms after stable power and >=10 ms low reset.
        # Hold the NMOS gate HIGH for 20 ms after startup or a restart.
        cycles = max(1, int(sys_clk_freq * 0.020))
        remaining = Signal(max=cycles + 1, reset=cycles)
        self.active = Signal()
        self.restart = Signal()
        self.comb += self.active.eq(remaining != 0)
        self.sync += If(self.restart, remaining.eq(cycles)).Elif(
            remaining != 0, remaining.eq(remaining - 1))


class CM005TX100(LiteXModule):
    """Byte stream to repeated RGMII nibbles, low nibble first at 25 MHz."""
    def __init__(self):
        self.sink = stream.Endpoint(eth_phy_description(8))
        self.source = stream.Endpoint(eth_phy_description(8))
        self.converter = conv = stream.Converter(8, 4)
        self.comb += [
            self.sink.connect(conv.sink, omit={"data", "error", "last_be"}),
            conv.sink.data.eq(self.sink.data),
            conv.source.connect(self.source, omit={"data", "valid_token_count"}),
            self.source.data.eq(Cat(conv.source.data, conv.source.data)),
        ]


class CM005RX100(LiteXModule):
    """Pack the rising-edge nibbles; retain frame end and flag odd lengths."""
    def __init__(self):
        self.sink = stream.Endpoint(eth_phy_description(8))
        self.source = stream.Endpoint(eth_phy_description(8))
        self.converter = conv = stream.Converter(4, 8, report_valid_token_count=True)
        self.comb += [
            self.sink.connect(conv.sink, omit={"data", "error", "last_be"}),
            conv.sink.data.eq(self.sink.data[:4]),
            conv.source.connect(self.source, omit={"valid_token_count"}),
            self.source.error.eq(conv.source.valid_token_count != 2),
        ]


class CM005RXFrameError(LiteXModule):
    """Keep an RX error asserted through the accepted end of its frame."""
    def __init__(self):
        self.sink = sink = stream.Endpoint(eth_phy_description(8))
        self.source = source = stream.Endpoint(eth_phy_description(8))
        error_seen = Signal()
        self.comb += [
            sink.connect(source, omit={"error"}),
            source.error.eq(sink.error | error_seen),
        ]
        self.sync += If(sink.valid & sink.ready,
            If(sink.last, error_seen.eq(0)).Else(
                error_seen.eq(error_seen | sink.error)))


class CM005TX1000(LiteXModule):
    """Native DDR TX with one MMCM output for the 250/125 MHz clocks.

    Sample the divided 125 MHz clock on the *falling* 250 MHz edge, 2 ns
    away from its transitions. A 250 MHz ODDR emits phase/~phase, forwarding
    a 125 MHz clock centered on the native 125 MHz DDR data. All physical
    launch/capture edges are constrained; no repeated-slot exception is used.
    """
    def __init__(self, clocks, pads):
        self.sink = sink = stream.Endpoint(eth_phy_description(8))
        self.comb += sink.ready.eq(1)
        valid = sink.valid
        phase = Signal()
        forwarded = Signal()
        self.specials += [
            Instance("FDRE", name="cm005_tx_phase",
                p_IS_C_INVERTED=1, i_C=ClockSignal("cm005_tx_serial"),
                i_CE=1, i_R=0, i_D=ClockSignal("eth_tx"), o_Q=phase),
            Instance("ODDRE1", name="cm005_tx_clock_ddr",
                i_C=ClockSignal("cm005_tx_serial"), i_SR=0,
                i_D1=phase, i_D2=~phase, o_Q=forwarded),
            Instance("OBUF", name="cm005_tx_clock_obuf", i_I=forwarded, o_O=clocks.tx),
        ]
        lanes = [("control", pads.tx_ctl, valid, valid ^ sink.error),
                 *[(f"data{i}", pads.tx_data[i], sink.data[i], sink.data[i + 4])
                   for i in range(4)]]
        for name, pin, low, high in lanes:
            serialized = Signal()
            self.specials += [
                Instance("ODDRE1", name=f"cm005_tx_{name}_ddr",
                    i_C=ClockSignal("eth_tx"), i_SR=0,
                    i_D1=low, i_D2=high, o_Q=serialized),
                Instance("OBUF", name=f"cm005_tx_{name}_obuf", i_I=serialized, o_O=pin),
            ]


class CM005MDIOInit(LiteXModule):
    """Clause 22 writes after *each* hardware reset; no host/OS dependency.

    YT8531 datasheet 5.2 guarantees address 0 responds after reset. Advertise
    only the configured full-duplex speed (no pause), then restart AN.
    Expose the bit-level signals separately for peripheral-only simulation.
    """
    def __init__(self, sys_clk_freq, speed=1000):
        if speed not in (100, 1000):
            raise ValueError("CM005 speed must be 100 or 1000 Mb/s")
        self.reset = Signal()
        self.done = Signal()
        self.mdc = Signal()
        self.data = Signal(reset=1)
        self.oe = Signal()
        half_period = max(1, int((sys_clk_freq + 2e6 - 1) // 2e6))
        settle_cycles = max(1, int(sys_clk_freq * 0.010))
        settle = Signal(max=settle_cycles + 1, reset=settle_cycles)
        divider = Signal(max=half_period + 1)
        bit = Signal(6)
        transaction = Signal(max=3)
        # Preamble | ST=01 | OP=01 | PHYAD=0 | REGAD | TA=10 | DATA.
        frames = Array(Constant((0xffffffff << 32) | (0b0101 << 28) |
                                (reg << 18) | (0b10 << 16) | value, 64)
                       for reg, value in ((9, 0x0200 if speed == 1000 else 0x0000),
                                          (4, 0x0001 if speed == 1000 else 0x0101),
                                          (0, 0x1200)))
        shift = Signal(64)
        self.comb += [self.data.eq(shift[63]),
                      self.oe.eq(~self.done & (settle == 0) & ~self.reset)]
        self.sync += If(self.reset,
            settle.eq(settle_cycles), divider.eq(0), bit.eq(0),
            transaction.eq(0), self.done.eq(0), self.mdc.eq(0), shift.eq(frames[0]),
        ).Elif(settle != 0,
            settle.eq(settle - 1), shift.eq(frames[0]),
        ).Elif(~self.done,
            If(divider == half_period - 1,
                divider.eq(0), self.mdc.eq(~self.mdc),
                If(self.mdc,
                    If(bit == 63,
                        bit.eq(0),
                        If(transaction == 2, self.done.eq(1)).Else(
                            transaction.eq(transaction + 1),
                            shift.eq(frames[transaction + 1]),
                        ),
                    ).Else(bit.eq(bit + 1), shift.eq(Cat(Constant(1, 1), shift[:63]))),
                ),
            ).Else(divider.eq(divider + 1)),
        )


class CM005MDIOInit100(CM005MDIOInit):
    """Compatibility entry point for existing 100 Mb/s tests."""
    def __init__(self, sys_clk_freq):
        super().__init__(sys_clk_freq, speed=100)


class CM005MDIO(LiteXModule):
    """Keep LiteEth's MDIO CSR ABI; hand ownership to software after init."""
    def __init__(self, pads, reset, sys_clk_freq, speed=1000):
        self._w = CSRStorage(fields=[CSRField("mdc"), CSRField("oe"), CSRField("w")], name="w")
        self._r = CSRStatus(fields=[CSRField("r")], name="r")
        self.init = init = CM005MDIOInit(sys_clk_freq, speed)
        data_r = Signal()
        data_w = Signal()
        data_oe = Signal()
        self.comb += [
            init.reset.eq(reset),
            pads.mdc.eq(Mux(init.done & ~reset, self._w.storage[0], init.mdc)),
            data_oe.eq(Mux(init.done & ~reset, self._w.storage[1], init.oe)),
            data_w.eq(Mux(init.done & ~reset, self._w.storage[2], init.data)),
        ]
        self.specials += [MultiReg(data_r, self._r.status[0]),
                          Tristate(pads.mdio, data_w, data_oe, data_r)]


class CM005MDIO100(CM005MDIO):
    """Compatibility entry point with the original 100 Mb/s default."""
    def __init__(self, pads, reset, sys_clk_freq):
        super().__init__(pads, reset, sys_clk_freq, speed=100)


class CM005CRG(LiteXModule):
    def __init__(self, clocks, pads, sys_clk_freq, rx_oversample=False, tx_serial=False):
        self._reset = CSRStorage(description="Assert CM005 PHY reset (active-high NMOS gate).")
        self.power_reset = CM005Reset(sys_clk_freq)
        self.clock_unlocked = Signal()
        # Keep the direct reset assertion below, but synchronize the request
        # used by the sys-domain counter. Re-arm after every lock/calibration
        # loss, including a short gap before IDELAYCTRL starts calibration.
        restart = Signal(reset=1)
        self.specials += MultiReg(self.clock_unlocked | self._reset.storage,
                                 restart, reset=1)
        self.reset = Signal()
        self.cd_eth_rx = ClockDomain()
        self.cd_eth_tx = ClockDomain()
        if rx_oversample:
            # RX_CLK is sampled as data by the oversampling receiver.
            self.comb += self.cd_eth_rx.clk.eq(ClockSignal("cm005_sample_div"))
        else:
            rx_ibuf = Signal()
            self.specials += [Instance("IBUF", i_I=clocks.rx, o_O=rx_ibuf),
                             Instance("BUFG", i_I=rx_ibuf, o_O=self.cd_eth_rx.clk)]
        self.comb += [
            self.power_reset.restart.eq(restart),
            self.reset.eq(self._reset.storage | self.power_reset.active | self.clock_unlocked),
            pads.reset_gate.eq(self.reset),
            self.cd_eth_tx.clk.eq(ClockSignal("cm005_tx")),
        ]
        self.specials += [
            AsyncResetSynchronizer(self.cd_eth_rx, self.reset | ResetSignal("sys")),
            AsyncResetSynchronizer(self.cd_eth_tx, self.reset | ResetSignal("sys")),
        ]
        if not tx_serial:
            self.specials += Instance("ODDRE1", name="cm005_txclk_ddr",
                i_C=ClockSignal("cm005_tx_shifted"), i_SR=0, i_D1=1, i_D2=0,
                o_Q=clocks.tx)


class CM005PHY(LiteXModule):
    dw = 8
    tx_clk_freq = rx_clk_freq = 125e6

    def __init__(self, clocks, pads, sys_clk_freq, iodelay_clk_freq=300e6,
                 rx_delay=1e-9, rx_ctl_delay=None, speed=1000, rx_oversample=False,
                 rx_data_sample_advance=(0, 0, 0, 0), rx_control_sample_advance=0):
        if speed not in (100, 1000):
            raise ValueError("CM005 speed must be 100 or 1000 Mb/s")
        if (any(rx_data_sample_advance) or rx_control_sample_advance) and not rx_oversample:
            raise ValueError("RX sample advance requires oversampled receive")
        self.tx_clk_freq = self.rx_clk_freq = 25e6 if speed == 100 else 125e6
        # The MAC gap counter counts clocks, not accepted stream bytes.
        if speed == 100:
            self.tx_gap_cycles = 24
        if rx_oversample:
            from cm005_oversample import SAMPLE_WORD_FREQ
            self.rx_clk_freq = SAMPLE_WORD_FREQ
        tx_serial = rx_oversample and speed == 1000
        self.crg = CM005CRG(clocks, pads, sys_clk_freq, rx_oversample=rx_oversample,
                           tx_serial=tx_serial)
        self.tx = ClockDomainsRenamer("eth_tx")(
            CM005TX1000(clocks, pads) if tx_serial else LiteEthPHYRGMIITX(pads))
        # CM005 straps RXD0 high (PHY adds 2 ns RX delay at 1G, 8 ns at 100M), RXD1 low
        # (no PHY TX delay). FPGA forwards a 90-degree shifted TX clock.
        # Compensate FPGA input-clock insertion with calibrated data delay. This
        # is not a second PHY clock delay: it delays data relative to the
        # internal sampling clock. The target selects board-specific values;
        # routed setup/hold must still be checked for each board/build.
        if rx_oversample:
            from cm005_oversample import CM005RXOversample
            rx = CM005RXOversample(clocks.rx, pads, iodelay_clk_freq, speed=speed,
                                  data_sample_advance=rx_data_sample_advance,
                                  control_sample_advance=rx_control_sample_advance)
        else:
            rx = LiteEthPHYRGMIIRX(
                pads, rx_delay=rx_delay, iodelay_clk_freq=iodelay_clk_freq, usp=True)
        if rx_ctl_delay is not None and not rx_oversample:
            # LiteEth exposes one shared delay. Customize only the control
            # path before fragment finalization, following actual connections
            # rather than generated instance names or construction order.
            # Fail elaboration if an upstream implementation change breaks
            # this topology; never silently trim a different input.
            instances = [s for s in rx._fragment.specials if isinstance(s, Instance)]
            buffers = [s for s in instances
                       if s.of == "IBUF" and s.get_io("I") is pads.rx_ctl]
            if len(buffers) != 1:
                raise ValueError("CM005 RX control must have exactly one IBUF")
            delays = [s for s in instances if s.of == "IDELAYE3"
                      and s.get_io("IDATAIN") is buffers[0].get_io("O")]
            if len(delays) != 1:
                raise ValueError("CM005 RX control must have exactly one IDELAYE3")
            parameters = [p for p in delays[0].items
                          if isinstance(p, Instance.Parameter) and p.name == "DELAY_VALUE"]
            if len(parameters) != 1:
                raise ValueError("CM005 RX control delay parameter is missing")
            parameters[0].value = Constant(round(rx_ctl_delay * 1e12))
        self.rx = ClockDomainsRenamer("eth_rx")(rx)
        if speed == 100:
            self.tx100 = ClockDomainsRenamer("eth_tx")(CM005TX100())
            self.comb += self.tx100.source.connect(self.tx.sink)
            self.sink = self.tx100.sink
            if rx_oversample:
                self.source = self.rx.source
            else:
                self.rx100 = ClockDomainsRenamer("eth_rx")(CM005RX100())
                self.comb += self.rx.source.connect(self.rx100.sink)
                self.source = self.rx100.source
        else:
            self.sink, self.source = self.tx.sink, self.rx.source
        # The byte-domain CRC checker consumes last_be before the MAC width
        # converter. A byte-wide PHY has exactly one valid byte on last.
        # The sys-datapath converter already derives this, but relying on it
        # would silently disable CRC error detection in the byte datapath.
        self.comb += self.source.last_be.eq(self.source.last)
        if speed == 1000 and rx_oversample:
            # LiteEth's byte CRC checker fills four bytes before producing
            # output, but forwards the current sink.error, not FIFO.error.
            # Retain even an early RX_ER through FCS removal and conversion.
            self.rx_frame_error = ClockDomainsRenamer("eth_rx")(CM005RXFrameError())
            self.comb += self.source.connect(self.rx_frame_error.sink)
            self.source = self.rx_frame_error.source
        # A fixed-rate MAC must not negotiate a different line rate. Repeat
        # this setup after every hardware reset, including clock lock loss.
        self.mdio = CM005MDIO(pads, self.crg.reset, sys_clk_freq, speed=speed)
