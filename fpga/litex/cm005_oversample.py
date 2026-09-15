"""100/1000M RGMII receive on ordinary IO, sampled at 1.25 Gsample/s.

RX_CLK is data, not an FPGA clock. Delay its sampler input by 460 ps relative
to RXD/RX_CTL, then use the data sample immediately before each detected clock
edge. With 800 ps sample spacing, the nominal selection error is -340..460 ps.
The remaining aperture must cover board skew, delay mismatch and jitter.
The sample words are oldest-bit-first. All six ISERDES lanes share clocks.
"""
from migen import *
from litex.gen import LiteXModule
from litex.soc.interconnect import stream
from liteeth.common import eth_phy_description

SAMPLE_CLK_FREQ = 625e6
SAMPLE_WORD_FREQ = SAMPLE_CLK_FREQ / 4
SAMPLE_IDELAY_FREQ = 312.5e6
SAMPLE_CLOCK_DELAY_PS = 460


class CM005SampleClocks(LiteXModule):
    """Parallel ISERDES CLK/CLKDIV buffers from one 625 MHz source."""
    def __init__(self, raw, reset, sample, word):
        self.specials += [
            Instance("BUFGCE_DIV", name="cm005_sample_fast_buf",
                p_BUFGCE_DIVIDE=1, i_I=raw, i_CE=1, i_CLR=reset, o_O=sample),
            Instance("BUFGCE_DIV", name="cm005_sample_word_buf",
                p_BUFGCE_DIVIDE=4, i_I=raw, i_CE=1, i_CLR=reset, o_O=word),
        ]


class CM005RX100Samples(LiteXModule):
    """Decode aligned 8-sample words at 156.25 MHz; physical RX cannot stall.

    As with LiteEth's other physical receivers, the MAC must consume data.
    Buffer stalls/clock glitches are flagged as receive errors, not silently
    accepted as good frames. RX_ER is recovered from both control phases.
    """
    def __init__(self):
        self.clock = Signal(8)
        self.control = Signal(8)
        self.data = [Signal(8) for _ in range(4)]
        self.source = stream.Endpoint(eth_phy_description(8))
        self.fault = Signal()
        previous = Signal(6)
        clk = Cat(previous[0], self.clock)
        ctl = Cat(previous[1], self.control)
        data = [Cat(previous[i + 2], self.data[i]) for i in range(4)]
        self.sync += previous.eq(Cat(self.clock[7], self.control[7],
                                     *[word[7] for word in self.data]))
        rises = Signal(8)
        falls = Signal(8)
        rise = Signal()
        fall = Signal()
        nibble = Signal(4)
        control_rise = Signal()
        control_fall = Signal()
        for i in range(8):
            self.comb += [rises[i].eq(~clk[i] & clk[i + 1]),
                          falls[i].eq(clk[i] & ~clk[i + 1])]
            self.comb += If(rises[i], nibble.eq(Cat(*[word[i] for word in data])),
                            control_rise.eq(ctl[i]))
            self.comb += If(falls[i], control_fall.eq(ctl[i]))
        transitions = rises | falls
        malformed = Signal()
        idle_cycles = Signal(8)
        timeout = Signal()
        self.comb += [rise.eq(rises != 0), fall.eq(falls != 0),
                      malformed.eq((transitions & (transitions - 1)) != 0),
                      timeout.eq(idle_cycles == 156)]
        self.sync += If(transitions != 0, idle_cycles.eq(0)).Elif(
            ~timeout, idle_cycles.eq(idle_cycles + 1))

        rising_seen = Signal()
        rising_data = Signal(4)
        rising_valid = Signal()
        pending = Signal()
        pending_data = Signal(5)
        frame_error = Signal()
        self.packer = packer = stream.Converter(5, 10, report_valid_token_count=True)
        self.comb += [
            packer.source.connect(self.source, omit={"data", "valid_token_count"}),
            self.source.data.eq(Cat(packer.source.data[:4],
                Mux(packer.source.valid_token_count == 2, packer.source.data[5:9], 0))),
            self.source.error.eq(packer.source.data[4] | packer.source.data[9] |
                                 (packer.source.valid_token_count != 2)),
        ]
        # One delayed nibble lets DV deassertion mark the actual final nibble.
        # Events are normally six or seven processing cycles apart.
        self.sync += [
            If(packer.sink.ready, packer.sink.valid.eq(0)),
            If(packer.sink.valid & ~packer.sink.ready,
                frame_error.eq(1), self.fault.eq(1)),
            If(malformed | timeout,
                If(pending,
                    packer.sink.valid.eq(1), packer.sink.last.eq(1),
                    packer.sink.data.eq(pending_data | 0x10)),
                pending.eq(0), rising_seen.eq(0),
                If(malformed | pending, self.fault.eq(1)), frame_error.eq(0),
            ).Else(
                If(rise,
                    If(rising_seen, frame_error.eq(1), self.fault.eq(1)),
                    rising_seen.eq(1), rising_data.eq(nibble),
                    rising_valid.eq(control_rise)),
                If(fall & rising_seen,
                    rising_seen.eq(0),
                    If(pending,
                        packer.sink.valid.eq(1),
                        packer.sink.last.eq(~rising_valid),
                        packer.sink.data.eq(pending_data | (frame_error << 4))),
                    pending.eq(rising_valid),
                    pending_data.eq(Cat(rising_data,
                        (rising_valid ^ control_fall) | frame_error)),
                    If(~rising_valid, frame_error.eq(0)),
                ),
            ),
        ]


class CM005RX1000Samples(LiteXModule):
    """Recover DDR bytes at 1 Gb/s from 6.4 ns, oldest-first sample words.

    A word can contain one rising and one falling edge, in either order.
    Select the sample *before* each edge, pairing a fall with the preceding
    rise even across word boundaries. Delay one byte to mark frame end.
    The physical input cannot stall: backpressure drops bytes and causes an
    errored frame terminator once the output becomes available again.
    """
    def __init__(self, data_sample_advance=(0, 0, 0, 0), control_sample_advance=0):
        # Board-specific calibration, in 800 ps sample steps. Zero preserves
        # the original receiver. A nonzero advance needs the following word;
        # retaining one complete word handles edges at positions 6/7 without
        # accidentally wrapping into the *same* word. Control has its own
        # calibration: a late DV transition can otherwise lose a preamble
        # byte even when all four payload lanes decode correctly.
        if (len(data_sample_advance) != 4 or
                any(type(a) is not int or not 0 <= a <= 7 for a in data_sample_advance)):
            raise ValueError("data_sample_advance must contain four integers in 0..7")
        self.data_sample_advance = tuple(data_sample_advance)
        if type(control_sample_advance) is not int or not 0 <= control_sample_advance <= 7:
            raise ValueError("control_sample_advance must be an integer in 0..7")
        self.control_sample_advance = control_sample_advance
        self.clock = Signal(8)
        self.control = Signal(8)
        self.data = [Signal(8) for _ in range(4)]
        self.source = stream.Endpoint(eth_phy_description(8))
        self.fault = Signal()
        clock_word, control_word, data_words = self.clock, self.control, self.data
        if any(data_sample_advance) or control_sample_advance:
            history = [Signal(8) for _ in range(6)]
            self.sync += [old.eq(raw) for old, raw in
                          zip(history, [self.clock, self.control, *self.data])]
            clock_word, control_word = history[:2]
            if control_sample_advance:
                a = control_sample_advance
                control_word = Cat(history[1][a:], self.control[:a])
            data_words = [Cat(old[a:], raw[:a]) if a else old
                          for old, raw, a in zip(history[2:], self.data, data_sample_advance)]
        previous = Signal(6)
        clk = Cat(previous[0], clock_word)
        ctl = Cat(previous[1], control_word)
        data = [Cat(previous[i + 2], data_words[i]) for i in range(4)]
        self.sync += previous.eq(Cat(clock_word[7], control_word[7],
                                     *[word[7] for word in data_words]))
        rises, falls = Signal(8), Signal(8)
        rise, fall = Signal(), Signal()
        rise_index, fall_index = Signal(3), Signal(3)
        low, high = Signal(4), Signal(4)
        dv, falling_ctl = Signal(), Signal()
        for i in range(8):
            self.comb += [rises[i].eq(~clk[i] & clk[i + 1]),
                          falls[i].eq(clk[i] & ~clk[i + 1])]
            self.comb += If(rises[i], rise_index.eq(i),
                low.eq(Cat(*[word[i] for word in data])), dv.eq(ctl[i]))
            self.comb += If(falls[i], fall_index.eq(i),
                high.eq(Cat(*[word[i] for word in data])), falling_ctl.eq(ctl[i]))
        same_word = Signal()
        malformed = Signal()
        idle_cycles = Signal(8)
        timeout = Signal()
        self.comb += [rise.eq(rises != 0), fall.eq(falls != 0),
            same_word.eq(rise & fall & (rise_index < fall_index)),
            malformed.eq(((rises & (rises - 1)) != 0) |
                         ((falls & (falls - 1)) != 0)),
            timeout.eq(idle_cycles == 156)]
        self.sync += If(rise | fall, idle_cycles.eq(0)).Elif(
            ~timeout, idle_cycles.eq(idle_cycles + 1))

        rising_seen = Signal()
        rising_data = Signal(4)
        rising_valid = Signal()
        byte_event, byte_valid = Signal(), Signal()
        byte_data = Signal(8)
        byte_error = Signal()
        self.comb += [
            byte_event.eq(fall & (same_word | rising_seen)),
            byte_valid.eq(Mux(same_word, dv, rising_valid)),
            byte_data.eq(Cat(Mux(same_word, low, rising_data), high)),
            byte_error.eq(byte_valid ^ falling_ctl),
        ]
        pending = Signal()
        pending_data = Signal(8)
        pending_error = Signal()
        frame_error = Signal()
        closing = Signal()
        acquired = Signal()
        available = Signal()
        self.comb += available.eq(~self.source.valid | self.source.ready)
        self.sync += [
            If(self.source.ready, self.source.valid.eq(0)),
            If(closing,
                # Preserve a stalled output and defer the errored last byte.
                # Incoming physical data while draining is intentionally lost.
                If(available,
                    self.source.valid.eq(1), self.source.last.eq(1),
                    self.source.data.eq(pending_data), self.source.error.eq(1),
                    closing.eq(0), pending.eq(0), rising_seen.eq(0), acquired.eq(0),
                    frame_error.eq(0)),
            ).Elif(~acquired,
                # ISERDES can expose a partial first word when its RX clock
                # input starts after reset. Establish an idle rise/fall pair
                # before accepting packets, rather than treating that partial
                # word as a clock glitch (or accepting the tail of a frame).
                If(malformed | timeout, rising_seen.eq(0)).Else(
                    If(rise,
                        rising_data.eq(low), rising_valid.eq(dv), rising_seen.eq(1)),
                    If(fall, rising_seen.eq(rise & ~same_word)),
                    If(byte_event & ~byte_valid, acquired.eq(1)),
                ),
            ).Elif(malformed | timeout,
                If(pending,
                    closing.eq(1), self.fault.eq(1)),
                rising_seen.eq(0), acquired.eq(0),
                If(malformed, self.fault.eq(1)),
            ).Else(
                If(rise,
                    rising_data.eq(low), rising_valid.eq(dv), rising_seen.eq(1)),
                If(fall, rising_seen.eq(rise & ~same_word)),
                If(byte_event,
                    If(pending,
                        If(available,
                            self.source.valid.eq(1),
                            self.source.last.eq(~byte_valid),
                            self.source.data.eq(pending_data),
                            self.source.error.eq(pending_error | frame_error),
                        ).Else(
                            self.fault.eq(1), frame_error.eq(1),
                            If(~byte_valid, closing.eq(1)),
                        ),
                    ),
                    pending.eq(byte_valid),
                    If(byte_valid,
                        pending_data.eq(byte_data), pending_error.eq(byte_error),
                    ).Elif(available, frame_error.eq(0)),
                ),
            ),
        ]


class CM005RXOversample(LiteXModule):
    def __init__(self, rx_clock, pads, iodelay_clk_freq=SAMPLE_IDELAY_FREQ, speed=100,
                 data_sample_advance=(0, 0, 0, 0), control_sample_advance=0):
        if speed not in (100, 1000):
            raise ValueError("CM005 oversampling speed must be 100 or 1000 Mb/s")
        if speed != 1000 and (any(data_sample_advance) or control_sample_advance):
            raise ValueError("Sample advance is supported only by the gigabit decoder")
        self.decoder = decoder = (CM005RX100Samples() if speed == 100 else
                                 CM005RX1000Samples(data_sample_advance, control_sample_advance))
        self.source = decoder.source
        self.fault = decoder.fault
        for name, pin, samples, delay in [
            ("clock", rx_clock, decoder.clock, SAMPLE_CLOCK_DELAY_PS),
            ("control", pads.rx_ctl, decoder.control, 0),
            *[(f"data{i}", pads.rx_data[i], decoder.data[i], 0) for i in range(4)],
        ]:
            buffered, delayed = Signal(), Signal()
            self.specials += [
                Instance("IBUF", name=f"cm005_sample_{name}_ibuf", i_I=pin, o_O=buffered),
                Instance("IDELAYE3", name=f"cm005_sample_{name}_delay",
                    p_DELAY_SRC="IDATAIN", p_CASCADE="NONE", p_DELAY_TYPE="FIXED",
                    p_DELAY_FORMAT="TIME", p_DELAY_VALUE=delay,
                    p_REFCLK_FREQUENCY=iodelay_clk_freq / 1e6,
                    p_UPDATE_MODE="ASYNC", p_SIM_DEVICE="ULTRASCALE_PLUS",
                    i_IDATAIN=buffered, i_DATAIN=0, i_CASC_IN=0, i_CASC_RETURN=0,
                    i_CE=0, i_CLK=0, i_INC=0, i_LOAD=0, i_CNTVALUEIN=Constant(0, 9),
                    i_RST=0, i_EN_VTC=1, o_DATAOUT=delayed),
                Instance("ISERDESE3", name=f"cm005_sample_{name}_iserdes",
                    p_DATA_WIDTH=8, p_FIFO_ENABLE="FALSE", p_FIFO_SYNC_MODE="FALSE",
                    p_IS_CLK_B_INVERTED=1, p_SIM_DEVICE="ULTRASCALE_PLUS",
                    i_CLK=ClockSignal("cm005_sample"), i_CLK_B=ClockSignal("cm005_sample"),
                    i_CLKDIV=ClockSignal("eth_rx"), i_D=delayed,
                    i_RST=ResetSignal("eth_rx"), i_FIFO_RD_CLK=0, i_FIFO_RD_EN=0,
                    o_Q=samples),
            ]


class CM005RX100Oversample(CM005RXOversample):
    """Compatibility entry point for the 100 Mb/s primitive regression."""
    def __init__(self, rx_clock, pads, iodelay_clk_freq=SAMPLE_IDELAY_FREQ):
        super().__init__(rx_clock, pads, iodelay_clk_freq, speed=100)
