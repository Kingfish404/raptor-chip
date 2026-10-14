#!/usr/bin/env python3
"""Read a NEMU transaction journal and independently replay its shared memory."""
import argparse
from collections import deque
import json
from pathlib import Path
import struct
from lib.rng import RngReplay, RNG_BASE, DMA_READ, DMA_WRITE, RNG_INPUT, RNG_IRQ
from lib.net import NetReplay, NET_BASE, NET_RX, NET_TX, NET_IRQ, NET_RX_RESULT
from lib.block import BlockReplay, BLOCK_BASE, BLOCK_MAX_IMAGE, BLOCK_IMAGE, BLOCK_PAGE, BLOCK_READ, BLOCK_WRITE, BLOCK_IRQ


HEADER = struct.Struct('<8s7Q')
RECORD = struct.Struct('<5Q')
ACCESS = struct.Struct('<QQII')
STATE_WORDS = 4165
MEMORY, STATE, BEGIN, ACCESS_KIND, END, LOCK, UNLOCK, COMPLETE = range(1, 9)
INTERRUPT = 9
CLOCK = 10
IO_REQUEST = 11
PLIC_SOURCE = 12
UART_RX, UART_IRQ, UART_TX = 13, 14, 15
UART_BASE = 0x10000000
CLINT_BASE = 0x02000000
PLIC_BASE = 0x0c000000


class JournalError(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise JournalError(message)


def records(stream):
    serial = 0
    while header := stream.read(RECORD.size):
        require(len(header) == RECORD.size, 'truncated record header')
        kind, sequence, hart, instruction, size = RECORD.unpack(header)
        require(sequence == serial, 'event sequence mismatch')
        require(size <= 2 * STATE_WORDS * 8 + 32, 'oversized record')
        payload = stream.read(size)
        require(len(payload) == size, 'truncated record payload')
        yield kind, sequence, hart, instruction, payload
        serial += 1


def read_events(path):
    """Return the header and mutable [kind, hart, instruction, payload] events."""
    with Path(path).open('rb') as stream:
        header = bytearray(stream.read(HEADER.size))
        events = [[kind, hart, instruction, bytearray(payload)]
                  for kind, _, hart, instruction, payload in records(stream)]
    return header, events


def write_events(path, header, events):
    """Write events with freshly numbered global sequences."""
    with Path(path).open('wb') as stream:
        stream.write(header)
        for sequence, (kind, hart, instruction, payload) in enumerate(events):
            stream.write(RECORD.pack(kind, sequence, hart, instruction, len(payload)))
            stream.write(payload)


def memory_consistent(path):
    """Whether the memory/device-only checker accepts a journal."""
    try:
        check_journal(path)
    except JournalError:
        return False
    return True


def interrupt_causes(events, xlen, harts):
    """Per-hart interrupt causes (interrupt bit cleared) from read_events() output."""
    mask = (1 << (xlen - 1)) - 1
    return [[struct.unpack_from('<Q', payload)[0] & mask
             for kind, hart, _, payload in events if kind == INTERRUPT and hart == target]
            for target in range(harts)]


def synchronous_traps(events):
    """Total synchronous exceptions reported by END records."""
    return sum(struct.unpack_from('<Q', payload, 8)[0] for kind, _, _, payload in events if kind == END)


def check_journal(path):
    with Path(path).open('rb') as stream:
        header = stream.read(HEADER.size)
        require(len(header) == HEADER.size, 'truncated file header')
        magic, version, xlen, harts, base, size, features, threaded = HEADER.unpack(header)
        require(magic == b'NMUJNL01' and version in (1, 2, 3, 4, 5, 6, 7, 8, 9), 'unsupported journal version')
        require(xlen in (32, 64) and 1 <= harts <= 4 and threaded in (0, 1), 'invalid machine geometry')
        require(version < 6 or threaded == 1, 'retained TLB requires threaded execution')
        require(0 < size <= 1 << 40 and base + size <= 1 << 64, 'invalid RAM span')
        pages = {}
        states = {}
        retired = [0] * harts
        active = {}
        owner = None
        complete = False
        started = False
        accesses = 0
        writes = 0
        groups = 0
        maximum_active = 0
        interleaved = 0
        last_access = None
        endings = 0
        event_count = 0
        interrupts = [0] * harts
        interruptible = set()
        msip = [0] * harts
        compare = [(1 << 64) - 1] * harts
        cpu_time = [0] * harts
        pending = [0] * harts
        request = None
        last_clock = 0
        clocks = 0
        idle_clocks = 0
        io_requests = 0
        plic_sources = 0
        source_poll = None
        priority = [0] * 33
        plic_pending = [0, 0]
        enable = [[0, 0] for _ in range(2 * harts)]
        threshold = [0] * (2 * harts)
        meip = [0] * harts
        seip = [0] * harts
        uart = dict(ier=0, fcr=0, lcr=0, mcr=0, dll=0, dlm=0, tx_pending=False)
        uart_registers = [0, 0, 1, 0, 8, 0x60, 0xb0, 0]
        uart_fifo = deque()
        uart_events = deque()
        uart_rx = uart_irqs = uart_tx = 0
        uart_poll_started = False
        rng_generator = rng_effect = None
        dma_reads = dma_writes = dma_bytes = rng_inputs = rng_irqs = 0
        net_generator = net_effect = None
        block_generator = block_effect = None
        block_reads = block_writes = block_bytes = block_irqs = block_image_size = block_pages = 0
        block_page_expected = 0
        block_last_page = -1

        def block_span(address, width):
            return version >= 9 and BLOCK_BASE <= address < BLOCK_BASE + 4096 and width == 4 and address % 4 == 0

        def block_advance():
            nonlocal block_generator, block_effect
            try:
                block_effect = next(block_generator)
            except StopIteration as finished:
                request['expected'] = finished.value
                block_generator = block_effect = None
        net_is_mmio = net_poll_started = False
        net_rx = net_tx = net_irqs = net_rx_bytes = net_tx_bytes = net_rx_drops = 0

        def net_span(address, width, write):
            if version < 8 or not NET_BASE <= address < NET_BASE + 4096:
                return False
            return ((width == 4 and address % 4 == 0) or
                    (not write and width in (1, 2) and address % width == 0 and
                     NET_BASE + 0x100 <= address and address + width <= NET_BASE + 0x108))

        def net_advance(value=None):
            nonlocal net_effect, net_generator
            try:
                net_effect = net_generator.send(value)
            except StopIteration as finished:
                if net_is_mmio:
                    request['expected'] = finished.value
                net_effect = net_generator = None

        def rng_span(address, width):
            return version >= 7 and width == 4 and address % 4 == 0 and RNG_BASE <= address < RNG_BASE + 4096

        def rng_advance(value=None):
            nonlocal rng_effect, rng_generator
            try:
                rng_effect = rng_generator.send(value)
            except StopIteration as finished:
                request['expected'] = finished.value
                rng_effect = rng_generator = None

        def uart_span(address, width):
            return version >= 5 and width == 1 and UART_BASE <= address < UART_BASE + 8

        def uart_signal(hart, executing):
            pulses = int(bool(uart['ier'] & 1 and uart_fifo)) + int(bool(uart['ier'] & 2 and uart['tx_pending']))
            uart_events.extend((UART_IRQ, 10, hart, executing) for _ in range(pulses))

        def uart_access(hart, address, value, write):
            offset = address - UART_BASE
            if write:
                if offset == 0:
                    if uart['lcr'] & 0x80:
                        uart['dll'] = value
                    elif not uart['mcr'] & 0x10:
                        uart_events.append((UART_TX, value, hart, 1))
                        uart['tx_pending'] = True
                        uart_signal(hart, 1)
                elif offset == 1:
                    if uart['lcr'] & 0x80:
                        uart['dlm'] = value
                    else:
                        uart['ier'] = value & 15
                        uart_signal(hart, 1)
                elif offset in (2, 3, 4):
                    uart[{2: 'fcr', 3: 'lcr', 4: 'mcr'}[offset]] = value
            else:
                value = uart_registers[offset]
                if offset == 0:
                    value = uart['dll'] if uart['lcr'] & 0x80 else (uart_fifo.popleft() if uart_fifo else 0)
                elif offset == 1:
                    value = uart['dlm'] if uart['lcr'] & 0x80 else uart['ier']
                elif offset == 2:
                    value = 0xc0 if uart['fcr'] & 1 else 0
                    if uart['ier'] & 1 and uart_fifo:
                        value |= 4
                    elif uart['ier'] & 2 and uart['tx_pending']:
                        value |= 2
                        uart['tx_pending'] = False
                    else:
                        value |= 1
                elif offset == 5:
                    value = 0x60 | int(bool(uart_fifo))
                elif offset == 6:
                    value = 0xb0
            uart_registers[offset] = value
            return value

        def plic_span(address, width):
            if version < 4 or width != 4 or address % 4:
                return False
            offset = address - PLIC_BASE
            return (0 <= offset < 33 * 4 or 0x1000 <= offset < 0x1008 or
                    (0x2000 <= offset < 0x2000 + 2 * harts * 0x80 and (offset - 0x2000) % 0x80 < 8) or
                    (0x200000 <= offset < 0x200000 + 2 * harts * 0x1000 and (offset - 0x200000) % 0x1000 < 8))

        def plic_pick(context):
            candidates = [source for source in range(1, 33)
                          if plic_pending[source // 32] & enable[context][source // 32] & (1 << (source % 32))
                          and priority[source] > threshold[context]]
            return max(candidates, key=lambda source: (priority[source], -source), default=0)

        def plic_update(hart):
            for target in ((hart,) if threaded else range(harts)):
                meip[target] = 0x800 if plic_pick(2 * target) else 0
                seip[target] = int(bool(plic_pick(2 * target + 1)))

        def plic_access(hart, address, value, write):
            offset = address - PLIC_BASE
            if offset < 33 * 4:
                registers, index = priority, offset // 4
            elif offset < 0x2000:
                index = (offset - 0x1000) // 4
                if write:
                    plic_pending[index] |= value & (0xffffffff if index else 0xfffffffe)
                    plic_update(hart)
                return plic_pending[index]
            elif offset < 0x200000:
                context, part = divmod(offset - 0x2000, 0x80)
                registers, index = enable[context], part // 4
            else:
                context, part = divmod(offset - 0x200000, 0x1000)
                if part == 4:
                    selected = 0 if write else plic_pick(context)
                    if selected:
                        plic_pending[selected // 32] &= ~(1 << (selected % 32))
                    plic_update(hart)
                    return selected
                registers, index = threshold, context
            if write:
                registers[index] = value
                plic_update(hart)
            return registers[index]

        def clint_span(address, width, write):
            if version < 3 or width not in (4, 8) or width > xlen // 8 or address % width:
                return False
            offset = address - CLINT_BASE
            return ((width == 4 and 0 <= offset < 4 * harts) or
                    (0x4000 <= offset and offset + width <= 0x4000 + 8 * harts) or
                    (not write and 0xbff8 <= offset and offset + width <= 0xc000))

        def mapped(address, length, write=False):
            ram = base <= address and address + length <= base + size
            rom = not (features & (1 << 5)) and not write and 0x1000 <= address and address + length <= 0x10000
            return length > 0 and (ram or rom)

        def byte(address):
            page = pages.get(address // 4096)
            return page[address % 4096] if page is not None else 0

        def store(address, data):
            for offset, value in enumerate(data):
                location = address + offset
                pages.setdefault(location // 4096, bytearray(4096))[location % 4096] = value

        rng = RngReplay(mapped, lambda address, length: bytes(byte(address + offset) for offset in range(length)), store)
        net = NetReplay(mapped, lambda address, length: bytes(byte(address + offset) for offset in range(length)), store)
        block = BlockReplay(mapped, lambda address, length: bytes(byte(address + offset) for offset in range(length)), store)
        for kind, sequence, hart, instruction, payload in records(stream):
            event_count += 1
            require(not complete, 'record after completion')
            require(hart < harts, 'invalid hart')
            require(instruction == retired[hart], 'per-hart instruction sequence mismatch')
            require(owner is None or owner == hart, 'interleaving inside a bus critical section')
            require(request is None or (kind in (CLOCK, ACCESS_KIND, PLIC_SOURCE, UART_RX, UART_IRQ, UART_TX,
                                                DMA_READ, DMA_WRITE, RNG_INPUT, RNG_IRQ,
                                                NET_RX, NET_TX, NET_IRQ, NET_RX_RESULT,
                                                BLOCK_READ, BLOCK_WRITE, BLOCK_IRQ) and request['hart'] == hart), 'incomplete IO request')
            require(version < 9 or sequence != 0 or kind == BLOCK_IMAGE, 'missing BLOCK image geometry')
            require(block_pages == block_page_expected or kind == BLOCK_PAGE, 'missing BLOCK initial pages')
            require(block_effect is None or kind == block_effect[0], 'missing or reordered BLOCK/DMA effect')
            require(not uart_events or kind == uart_events[0][0], 'missing or reordered UART effect')
            require(rng_effect is None or kind == rng_effect[0], 'missing or reordered RNG/DMA effect')
            if net_effect == (NET_RX, None) and kind != NET_RX:
                net_advance()
            require(net_effect is None or kind == net_effect[0], 'missing or reordered NET/DMA effect')
            if kind not in (CLOCK, PLIC_SOURCE, UART_RX, UART_IRQ, NET_RX, NET_IRQ, NET_RX_RESULT) and net_generator is None:
                source_poll = None
                uart_poll_started = False
                net_poll_started = False
            if kind == BLOCK_IMAGE:
                require(version >= 9 and sequence == 0 and hart == 0 and len(payload) == 16, 'invalid BLOCK image record')
                block_image_size, block_page_expected = struct.unpack('<2Q', payload)
                require(block_image_size <= BLOCK_MAX_IMAGE and block_page_expected <= (block_image_size + 4095) // 4096,
                        'invalid BLOCK image geometry')
                block.disk_size = block_image_size
            elif kind == BLOCK_PAGE:
                require(version >= 9 and hart == 0 and block_pages < block_page_expected and len(payload) > 8, 'unexpected BLOCK image page')
                offset, = struct.unpack_from('<Q', payload)
                require(offset % 4096 == 0 and block_last_page < offset < block_image_size
                        and len(payload) - 8 == min(4096, block_image_size - offset), 'invalid BLOCK initial page')
                block.disk_write(offset, payload[8:])
                block_pages += 1
                block_last_page = offset
            elif kind == MEMORY:
                require(not started and len(payload) > 8, 'late or empty initial memory')
                address, = struct.unpack_from('<Q', payload)
                data = payload[8:]
                require(address % 4096 == 0 and len(data) <= 4096 and mapped(address, len(data)), 'invalid initial memory span')
                require(address // 4096 not in pages, 'duplicate initial memory page')
                store(address, data)
            elif kind == STATE:
                require(not started and hart not in states and len(payload) == STATE_WORDS * 8, 'invalid initial state')
                states[hart] = list(struct.unpack(f'<{STATE_WORDS}Q', payload))
                require(states[hart][1] == 0 and states[hart][65 + 0xf14] == hart, 'invalid hart initial registers')
                if version >= 3:
                    require(states[hart][4162] == (1 << 64) - 1 and states[hart][4164] == 0
                            and states[hart][65 + 0x344] & 0x88 == 0, 'CLINT requires reset state')
                    cpu_time[hart] = states[hart][65 + 0xc01]
                    if xlen == 32:
                        cpu_time[hart] |= states[hart][65 + 0xc81] << 32
                if version >= 4:
                    require(states[hart][65 + 0x344] & 0x800 == 0, 'PLIC requires clear MEIP')
            elif kind in (LOCK, UNLOCK):
                require(threaded and not payload and len(states) == harts, 'invalid bus boundary')
                started = True
                if kind == LOCK:
                    require(owner is None, 'nested outer bus lock')
                    owner = hart
                    groups += 1
                else:
                    require(owner == hart, 'unowned bus unlock')
                    owner = None
            elif kind == BEGIN:
                require(len(states) == harts and hart not in active and len(payload) == 8, 'invalid instruction begin')
                require(not threaded or owner == hart, 'begin outside bus lock')
                require(threaded or not active, 'overlapping cooperative instructions')
                pc, = struct.unpack('<Q', payload)
                require(pc == states[hart][0], 'instruction PC discontinuity')
                active[hart] = instruction
                interruptible.add(hart)
                started = True
                maximum_active = max(maximum_active, len(active))
            elif kind == INTERRUPT:
                require(version >= 2 and hart in interruptible and len(payload) == 16, 'invalid interrupt entry')
                require(not threaded or owner == hart, 'interrupt outside bus lock')
                cause, pc = struct.unpack('<2Q', payload)
                require(cause in ((1 << (xlen - 1)) | code for code in (1, 3, 5, 7, 9, 11)), 'invalid interrupt cause')
                require(pc == states[hart][0], 'interrupt entry PC mismatch')
                interruptible.remove(hart)
                interrupts[hart] += 1
            elif kind == IO_REQUEST:
                require(version >= 3 and hart in active and len(payload) == ACCESS.size, 'invalid IO request')
                require(not threaded or owner == hart, 'IO request outside bus lock')
                address, value, width, write = ACCESS.unpack(payload)
                plic = plic_span(address, width)
                serial = uart_span(address, width)
                random = rng_span(address, width)
                network = net_span(address, width, write)
                disk = block_span(address, width)
                require(write in (0, 1) and (disk or network or random or serial or plic or clint_span(address, width, write)), 'unsupported IO request')
                require(value < 1 << (width * 8) and (write or value == 0), 'invalid IO request data')
                offset = address - CLINT_BASE
                if random or network or disk:
                    expected = None
                elif serial:
                    expected = uart_access(hart, address, value, write)
                elif plic:
                    expected = plic_access(hart, address, value, write)
                elif offset < 0x4000:
                    target = offset // 4
                    if write:
                        msip[target] = value & 1
                    expected = msip[target]
                elif offset < 0xbff8:
                    target, part = divmod(offset - 0x4000, 8)
                    mask = (1 << (width * 8)) - 1
                    if write:
                        compare[target] = (compare[target] & ~(mask << (part * 8))) | (value << (part * 8))
                    expected = (compare[target] >> (part * 8)) & mask
                else:
                    expected = None
                request = dict(hart=hart, address=address, value=value, width=width, write=write,
                               expected=expected, clock=plic or serial or random or network or disk)
                if disk:
                    block_generator = block.access(address, value, write)
                    block_advance()
                if network:
                    net_is_mmio = True
                    net_generator = net.access(address, value, width, write)
                    net_advance()
                if random:
                    rng_generator = rng.access(address, value, write)
                    rng_advance()
                interruptible.discard(hart)
                io_requests += 1
            elif kind == CLOCK:
                require(version >= 3 and len(states) == harts and len(payload) == 24, 'invalid clock event')
                require(not threaded or owner == hart, 'clock outside bus lock')
                ticks, action, executing = struct.unpack('<3Q', payload)
                require(ticks >= last_clock and action in (1, 2) and executing == int(hart in active), 'invalid clock order or context')
                require(action == 1 or request is not None, 'orphan CLINT read clock')
                if request is not None:
                    require(not request['clock'] and action == (1 if request['write'] else 2), 'incorrect IO clock')
                    request['clock'] = True
                    if request['expected'] is None:
                        request['expected'] = (ticks >> ((request['address'] - CLINT_BASE - 0xbff8) * 8)) & ((1 << (request['width'] * 8)) - 1)
                if action == 1:
                    for target in (range(harts) if not threaded else (hart,)):
                        cpu_time[target] = ticks
                        pending[target] = (8 if msip[target] else 0) | (0x80 if ticks >= compare[target] else 0)
                    if version >= 4 and threaded:
                        plic_update(hart)
                source_poll = (hart, instruction, executing) if action == 1 else None
                uart_poll_started = False
                net_poll_started = False
                last_clock = ticks
                clocks += 1
                idle_clocks += not executing
                started = True
            elif kind == PLIC_SOURCE:
                require(version >= 4 and len(payload) == 16 and not uart_poll_started and not net_poll_started, 'invalid PLIC source event')
                source, executing = struct.unpack('<2Q', payload)
                require(1 <= source <= 32 and source_poll == (hart, instruction, executing), 'invalid PLIC source or context')
                require(not threaded or owner == hart, 'PLIC source outside bus lock')
                plic_pending[source // 32] |= 1 << (source % 32)
                plic_update(hart)
                plic_sources += 1
            elif kind == UART_RX:
                require(version >= 5 and len(payload) == 16 and not net_poll_started, 'invalid UART input event')
                value, executing = struct.unpack('<2Q', payload)
                require(value <= 255 and source_poll == (hart, instruction, executing), 'invalid UART input byte/context')
                require(not threaded or owner == hart, 'UART input outside bus lock')
                if len(uart_fifo) < 255:
                    uart_fifo.append(value)
                uart_signal(hart, executing)
                uart_rx += 1
                uart_poll_started = True
            elif kind in (UART_IRQ, UART_TX):
                require(version >= 5 and len(payload) == 16 and uart_events, 'unexpected UART effect')
                value, executing = struct.unpack('<2Q', payload)
                require((kind, value, hart, executing) == uart_events.popleft(), 'derived UART effect mismatch')
                require(not threaded or owner == hart, 'UART effect outside bus lock')
                if kind == UART_IRQ:
                    plic_pending[0] |= 1 << 10
                    plic_update(hart)
                    uart_irqs += 1
                else:
                    uart_tx += 1
            elif kind == NET_RX:
                require(version >= 8 and owner == hart and len(payload) >= 16, 'invalid NET input scope')
                length, executing = struct.unpack_from('<2Q', payload)
                require(length <= 65524 and len(payload) == 16 + length and executing == int(hart in active), 'invalid raw NET input')
                net_rx += 1
                net_rx_bytes += length
                if net_effect == (NET_RX, None):
                    require(net_is_mmio and executing == 1, 'NET response outside TX')
                    net_advance(payload[16:])
                else:
                    require(net_generator is None and source_poll == (hart, instruction, executing), 'NET input outside serialized poll')
                    net_poll_started = True
                    net_is_mmio = False
                    net_generator = net.receive(payload[16:], bool(executing))
                    net_advance()
            elif kind in (NET_TX, NET_IRQ, NET_RX_RESULT) or (kind in (DMA_READ, DMA_WRITE) and net_effect is not None):
                require(version >= 8 and owner == hart and net_effect is not None and payload == net_effect[1], 'independent NET/DMA effect mismatch')
                if kind == NET_TX:
                    length, executing = struct.unpack_from('<2Q', payload)
                    net_tx += 1
                    net_tx_bytes += length
                elif kind == NET_IRQ:
                    plic_pending[0] |= 1 << 2
                    plic_update(hart)
                    net_irqs += 1
                elif kind == NET_RX_RESULT:
                    result, disposition, executing = struct.unpack('<3Q', payload)
                    net_rx_drops += disposition != 1
                else:
                    _, length, success = struct.unpack_from('<3Q', payload)
                    dma_reads += kind == DMA_READ
                    dma_writes += kind == DMA_WRITE
                    dma_bytes += length if success else 0
                net_advance()
            elif kind in (BLOCK_READ, BLOCK_WRITE, BLOCK_IRQ) or (kind in (DMA_READ, DMA_WRITE) and block_effect is not None):
                require(version >= 9 and request is not None and hart in active and owner == hart
                        and block_effect is not None and payload == block_effect[1], 'independent BLOCK/DMA effect mismatch')
                if kind in (BLOCK_READ, BLOCK_WRITE):
                    _, length = struct.unpack_from('<2Q', payload)
                    block_reads += kind == BLOCK_READ
                    block_writes += kind == BLOCK_WRITE
                    block_bytes += length
                elif kind == BLOCK_IRQ:
                    plic_pending[0] |= 2
                    plic_update(hart)
                    block_irqs += 1
                else:
                    _, length, success = struct.unpack_from('<3Q', payload)
                    dma_reads += kind == DMA_READ
                    dma_writes += kind == DMA_WRITE
                    dma_bytes += length if success else 0
                block_advance()
            elif kind in (DMA_READ, DMA_WRITE, RNG_INPUT, RNG_IRQ):
                require(version >= 7 and request is not None and hart in active and owner == hart
                        and rng_effect is not None, 'unexpected RNG/DMA effect')
                if kind == RNG_INPUT:
                    require(len(payload) >= 16, 'truncated entropy event')
                    length, success = struct.unpack_from('<2Q', payload)
                    require(payload[:8] == rng_effect[1] and success in (0, 1) and 0 < length <= 256
                            and len(payload) == 16 + (length if success else 0), 'invalid raw RNG entropy event')
                    rng_inputs += 1
                    rng_advance(payload[16:] if success else None)
                else:
                    require(payload == rng_effect[1], 'independent RNG/DMA effect mismatch')
                    if kind == RNG_IRQ:
                        plic_pending[0] |= 1 << 3
                        plic_update(hart)
                        rng_irqs += 1
                    else:
                        _, length, success = struct.unpack_from('<3Q', payload)
                        dma_reads += kind == DMA_READ
                        dma_writes += kind == DMA_WRITE
                        dma_bytes += length if success else 0
                    rng_advance()
            elif kind == ACCESS_KIND:
                require(hart in active and len(payload) == ACCESS.size, 'access outside instruction or wrong size')
                require(not threaded or owner == hart, 'access outside bus lock')
                address, value, width, write = ACCESS.unpack(payload)
                interruptible.discard(hart)
                require(width in (1, 2, 4, 8) and write in (0, 1) and value < 1 << (8 * width), 'invalid memory event')
                finish = (address, value, width, write) == (0x100000, 0x5555, 4, 1)
                finisher_read = (address, width, write) == (0x100000, 4, 0)
                io = clint_span(address, width, write) or plic_span(address, width) or uart_span(address, width) or rng_span(address, width) or net_span(address, width, write) or block_span(address, width)
                require(request is None or io, 'RAM access within IO request')
                require(finish or finisher_read or io or mapped(address, width, bool(write)), 'unsupported memory event')
                if finisher_read:
                    require(value == 0, 'independent finisher value mismatch')
                elif io:
                    require(request is not None and request['clock'], 'missing IO request or clock')
                    require((address, width, write) == (request['address'], request['width'], request['write']), 'IO completion mismatch')
                    device = 'BLOCK' if block_span(address, width) else ('NET' if net_span(address, width, write) else ('RNG' if rng_span(address, width) else ('UART' if uart_span(address, width) else ('PLIC' if plic_span(address, width) else 'CLINT'))))
                    require(value == (request['value'] if write else request['expected']), f'independent {device} value mismatch')
                    request = None
                elif not write:
                    expected = sum(byte(address + offset) << (8 * offset) for offset in range(width))
                    require(value == expected, f'load mismatch event={sequence} hart={hart} address={address:#x}: {value:#x} != {expected:#x}')
                elif not finish:
                    store(address, value.to_bytes(width, 'little'))
                if last_access is not None:
                    previous_hart, previous_instruction = last_access
                    if previous_hart != hart and active.get(previous_hart) == previous_instruction:
                        interleaved += 1
                last_access = (hart, instruction)
                accesses += 1
                writes += write
            elif kind == END:
                require(hart in active and len(payload) >= 32 and (len(payload) - 32) % 16 == 0, 'invalid retirement')
                require(not threaded or owner == hart, 'retirement outside bus lock')
                opcode, trapped, error, ended = struct.unpack_from('<4Q', payload)
                require(opcode < 1 << 32 and trapped <= 1 and ended <= 1 and error == 0, 'unsupported or malformed retirement')
                previous_index = -1
                for index, value in struct.iter_unpack('<QQ', payload[32:]):
                    require(previous_index < index < STATE_WORDS, 'invalid state delta ordering/index')
                    states[hart][index] = value
                    previous_index = index
                require(states[hart][1] == 0 and states[hart][65 + 0xf14] == hart, 'invalid retired hart registers')
                if version >= 3:
                    require(states[hart][4162] == compare[hart], 'CLINT compare state mismatch')
                    require(states[hart][65 + 0x344] & 0x88 == pending[hart], 'CLINT pending state mismatch')
                    require(states[hart][65 + 0xc01] == cpu_time[hart] & ((1 << xlen) - 1), 'time CSR mismatch')
                    if xlen == 32:
                        require(states[hart][65 + 0xc81] == cpu_time[hart] >> 32, 'timeh CSR mismatch')
                if version >= 4:
                    require(states[hart][65 + 0x344] & 0x800 == meip[hart], 'PLIC MEIP mismatch')
                    require(states[hart][4164] >> 32 == seip[hart], 'PLIC SEIP mismatch')
                endings += ended
                del active[hart]
                interruptible.discard(hart)
                retired[hart] += 1
            elif kind == COMPLETE:
                require(len(payload) == 48 and not active and owner is None, 'incomplete execution at footer')
                status, result, *counts = struct.unpack('<6Q', payload)
                require(status == 2 and result == 0 and endings == 1, 'unsuccessful guest termination')
                require(counts[:harts] == retired and not any(counts[harts:]) and all(retired), 'instruction totals mismatch')
                complete = True
            else:
                raise JournalError(f'unknown event kind {kind}')
        require(complete and accesses, 'missing successful completion')
        return dict(xlen=xlen, harts=harts, threaded=bool(threaded), events=event_count,
                    instructions=retired, accesses=accesses, writes=writes, bus_groups=groups,
                    maximum_active=maximum_active, interleaved_accesses=interleaved,
                    interrupts=interrupts, version=version, clocks=clocks, idle_clocks=idle_clocks,
                    io_requests=io_requests, last_clock=last_clock, plic_sources=plic_sources,
                    uart_rx=uart_rx, uart_irqs=uart_irqs, uart_tx=uart_tx,
                    dma_reads=dma_reads, dma_writes=dma_writes, dma_bytes=dma_bytes,
                    rng_inputs=rng_inputs, rng_irqs=rng_irqs,
                    net_rx=net_rx, net_tx=net_tx, net_irqs=net_irqs, net_rx_bytes=net_rx_bytes,
                    net_tx_bytes=net_tx_bytes, net_rx_drops=net_rx_drops,
                    block_reads=block_reads, block_writes=block_writes, block_bytes=block_bytes,
                    block_irqs=block_irqs, block_image_size=block_image_size, block_pages=block_pages,
                    tlb_retain=version >= 6, status='memory-consistent')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('journal', type=Path)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    try:
        result = check_journal(args.journal)
    except (JournalError, OSError) as error:
        parser.exit(1, f'NEMU_JOURNAL_CHECK_FAIL {error}\n')
    text = json.dumps(result, indent=2) + '\n'
    if args.output:
        args.output.write_text(text)
    print(text, end='')

