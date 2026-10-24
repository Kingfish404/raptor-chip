"""Bounded store-and-forward Ethernet queue, with complete-frame admission."""
from migen import Cat, FSM, If, Memory, NextState, NextValue, Signal
from litex.gen import LiteXModule
from litex.soc.interconnect import stream
from litex.soc.interconnect.csr import CSRStatus
from liteeth.common import eth_phy_description
from liteeth.mac.packet import LiteEthMACPacketReader, LiteEthMACPacketWriter


class EthernetFrameQueue(LiteXModule):
    """Eight 2 KiB slots by default; retain the TX slot until its last beat.

    Input is a 32-bit MAC stream after FCS removal. Overflow drops a whole
    arriving frame. Bad/oversized frames never publish a descriptor, so no
    prefix can escape to the other PHY. Length includes the Ethernet header.
    """
    def __init__(self, slots=8, mtu=1536):
        if slots < 2 or slots & (slots - 1):
            raise ValueError("slots must be a power of two >= 2")
        if not 60 <= mtu <= 2044:
            raise ValueError("mtu must leave room for the overflow-detection word")
        slot_bits = (slots - 1).bit_length()
        self.sink = sink = stream.Endpoint(eth_phy_description(32))
        self.writer = writer = LiteEthMACPacketWriter(
            32, 512, eth_mtu=mtu, drop_when_disabled=True)
        self.reader = reader = LiteEthMACPacketReader(32, 512)
        self.source = reader.source
        self.descriptors = desc = stream.SyncFIFO(
            [("slot", slot_bits), ("length", 12)], slots)
        self.received = CSRStatus(32, description="Complete accepted frames.")
        self.forwarded = CSRStatus(32, description="Frames handed to the egress MAC.")
        self.dropped = CSRStatus(32, description="Frames dropped for overflow, error or length.")
        self.errors = CSRStatus(32, description="Drops caused by frame error or excessive length.")
        self.queued = CSRStatus(slot_bits + 1, description="Occupied frame slots, including TX.")
        write_slot = Signal(slot_bits)
        # Preserve error indications from any valid lane, including an early
        # beat whose last_be is zero. The upstream writer checks the last lane.
        error_seen = Signal()
        sink_error = sink.error != 0
        self.comb += [
            sink.connect(writer.sink, omit={"error"}),
            writer.sink.error.eq(15 * (sink_error | error_seen)),
            writer.enable.eq(desc.sink.ready), writer.source.ready.eq(1),
            desc.sink.valid.eq(writer.done), desc.sink.slot.eq(write_slot),
            desc.sink.length.eq(writer.length),
            reader.length.eq(desc.source.length), self.queued.status.eq(desc.level),
        ]
        self.sync += [
            If(sink.valid & sink.ready,
                If(sink.last, error_seen.eq(0)).Else(error_seen.eq(error_seen | sink_error)),
            ),
            If(writer.done & desc.sink.ready,
                write_slot.eq(write_slot + 1),
                self.received.status.eq(self.received.status + 1)),
            If(writer.drop, self.dropped.status.eq(self.dropped.status + 1)),
            If(writer.drop & writer.error, self.errors.status.eq(self.errors.status + 1)),
            If(desc.source.valid & desc.source.ready,
                self.forwarded.status.eq(self.forwarded.status + 1)),
        ]
        memory = Memory(32, slots * 512)
        wr = memory.get_port(write_capable=True)
        rd = memory.get_port(has_re=True)
        self.specials += memory, wr, rd
        offset = Signal(12)
        self.comb += [
            wr.adr.eq(Cat(writer.offset[2:11], write_slot)),
            wr.dat_w.eq(writer.source.data), wr.we.eq(writer.source.valid),
            rd.adr.eq(Cat(offset[2:11], desc.source.slot)),
            reader.sink.data.eq(rd.dat_r),
        ]
        self.fsm = fsm = FSM(reset_state="IDLE")
        fsm.act("IDLE",
            If(desc.source.valid & reader.idle,
                reader.enable.eq(1), rd.re.eq(1),
                NextValue(offset, 4), NextState("READ")))
        fsm.act("READ",
            reader.sink.valid.eq(1),
            reader.sink.last.eq(offset >= desc.source.length),
            If(reader.done, NextState("RELEASE")).Elif(
                reader.sink.ready & ~reader.sink.last,
                rd.re.eq(1), NextValue(offset, offset + 4)))
        fsm.act("RELEASE",
            desc.source.ready.eq(1), NextValue(offset, 0), NextState("IDLE"))
