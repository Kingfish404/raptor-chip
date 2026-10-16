"""Block replay, host-image storage, virtio completions and Linux boot supervision."""

from isa.storage_linux import FAIL_MARKERS, network_round_trip, verdict
from lib.block import BlockReplay, BLOCK_BASE, BLOCK_READ, BLOCK_WRITE, BLOCK_IRQ
from lib.console import run_console
from lib.rng import DMA_READ, DMA_WRITE
from pathlib import Path
import ctypes
import errno
import fcntl
import os
import struct
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import MagicMock, patch


ROOT = Path(__file__).resolve().parents[3]


class BlockModelTest(unittest.TestCase):
    def setUp(self):
        self.memory = bytearray(262144)
        self.model = BlockReplay(lambda address, size, write=False: 0 <= address < len(self.memory) and 0 < size <= len(self.memory) - address,
                                 lambda address, size: bytes(self.memory[address:address + size]), self.store)
        self.model.disk_size = 131072
        self.disk = bytes((index * 7 + 3) & 255 for index in range(256)) * 512
        self.model.disk_write(0, self.disk)
        self.configure()

    def store(self, address, data):
        self.memory[address:address + len(data)] = data

    def configure(self, kind=0, sector=0):
        self.access(0x70, 0)
        for offset, value in ((0x38, 8), (0x80, 128), (0x90, 256), (0xa0, 320), (0x44, 1), (0x70, 4)):
            self.access(offset, value)
        struct.pack_into('<QIHH', self.memory, 128, 400, 16, 1, 1)
        struct.pack_into('<QIHH', self.memory, 144, 4096, 512, 1 if kind == 1 else 3, 2)
        struct.pack_into('<QIHH', self.memory, 160, 450, 1, 2, 0)
        struct.pack_into('<IIQ', self.memory, 400, kind, 0, sector)
        struct.pack_into('<HHH', self.memory, 256, 0, 1, 0)
        self.memory[320:388] = bytes(68)
        self.memory[450] = 0xa5

    def drive(self, generator):
        events = []
        while True:
            try:
                events.append(next(generator))
            except StopIteration as finished:
                return finished.value, events

    def access(self, offset, value=0, write=True):
        return self.drive(self.model.access(BLOCK_BASE + offset, value, write))

    def test_read_disk_to_guest(self):
        _, events = self.access(0x50)
        self.assertEqual(self.memory[4096:4608], self.disk[:512])
        self.assertEqual(self.memory[450], 0)
        self.assertEqual(struct.unpack_from('<HHII', self.memory, 320), (0, 1, 0, 513))
        self.assertIn((BLOCK_READ, struct.pack('<2Q', 0, 512) + self.disk[:512]), events)
        self.assertIn((BLOCK_IRQ, struct.pack('<2Q', 1, 1)), events)

    def test_write_readback_survives_reset(self):
        self.configure(1, 4)
        self.memory[4096:4608] = b'\x6c' * 512
        _, events = self.access(0x50)
        self.assertIn((BLOCK_WRITE, struct.pack('<2Q', 2048, 512) + b'\x6c' * 512), events)
        self.assertEqual(struct.unpack_from('<I', self.memory, 328)[0], 1)
        self.configure(0, 4)
        self.memory[4096:4608] = bytes(512)
        self.access(0x50)
        self.assertEqual(self.memory[4096:4608], b'\x6c' * 512)
        self.assertEqual(self.model.disk_read(0, 2048), self.disk[:2048])

    def test_sector_overflow_bounds_and_direction(self):
        for kind, sector, flags in ((0, 1 << 55, 3), (0, 256, 3), (0, 0, 1), (1, 0, 3), (99, 0, 3)):
            self.configure(kind, sector)
            struct.pack_into('<H', self.memory, 156, flags)
            _, events = self.access(0x50)
            self.assertEqual(self.memory[450], 1)
            self.assertEqual(struct.unpack_from('<I', self.memory, 328)[0], 1)
            self.assertFalse(any(kind in (BLOCK_READ, BLOCK_WRITE) for kind, _ in events))

    def test_partial_chunk_preserves_writes(self):
        for kind in (0, 1):
            self.configure(kind)
            struct.pack_into('<QIHH', self.memory, 144, len(self.memory) - 65536, 65568, 1 if kind else 3, 2)
            self.memory[-65536:] = b'\xa5' * 65536
            _, events = self.access(0x50)
            self.assertEqual(self.memory[450], 1)
            self.assertEqual(struct.unpack_from('<I', self.memory, 328)[0], 1 if kind else 65537)
            if kind:
                self.assertEqual(self.model.disk_read(0, 65536), b'\xa5' * 65536)
                self.assertEqual(self.model.disk_read(65536, 32), self.disk[65536:65568])
                self.assertEqual(sum(event == BLOCK_WRITE for event, _ in events), 1)
            else:
                self.assertEqual(self.memory[-65536:], self.disk[:65536])
                self.assertEqual(sum(event == BLOCK_READ for event, _ in events), 2)

    def test_get_id_and_sparse_zero_page(self):
        self.configure(8, (1 << 64) - 1)
        _, events = self.access(0x50)
        self.assertEqual(self.memory[4096:4608], b'NEMU-VIRTIO-BLK'.ljust(512, b'\0'))
        self.assertFalse(any(kind in (BLOCK_READ, BLOCK_WRITE) for kind, _ in events))
        self.configure(0, 8)
        del self.model.disk_pages[1]
        self.access(0x50)
        self.assertEqual(self.memory[4096:4608], bytes(512))

    def test_used_failure_and_wrap(self):
        self.access(0xa0, len(self.memory) - 4)
        _, events = self.access(0x50)
        self.assertEqual(self.memory[450], 0)
        self.assertFalse(any(kind == BLOCK_IRQ for kind, _ in events))
        self.assertEqual(events[-1], (DMA_WRITE, struct.pack('<3Q', len(self.memory), 4, 0) + bytes(4)))
        self.configure()
        struct.pack_into('<H', self.memory, 322, 65535)
        self.access(0x50)
        self.assertEqual(struct.unpack_from('<H', self.memory, 322)[0], 0)
        self.assertEqual(struct.unpack_from('<II', self.memory, 380), (0, 513))

    def test_failed_head_read_and_invalid_header(self):
        self.access(0x90, len(self.memory) - 4)
        struct.pack_into('<H', self.memory, len(self.memory) - 2, 1)
        _, events = self.access(0x50)
        self.assertEqual(events[-1], (DMA_READ, struct.pack('<3Q', len(self.memory), 2, 0)))
        self.assertEqual(self.model.consumed, 0)
        self.configure()
        struct.pack_into('<H', self.memory, 140, 3)
        self.access(0x50)
        self.assertEqual(struct.unpack_from('<HHII', self.memory, 320), (0, 1, 0, 0))
        self.assertEqual(self.memory[450], 0xa5)

    def test_cycles_lengths_and_zero_data(self):
        struct.pack_into('<H', self.memory, 158, 1)
        self.access(0x50)
        self.assertEqual(struct.unpack_from('<I', self.memory, 328)[0], 7 * 512)
        self.assertEqual(self.memory[450], 0xa5)
        for size, expected in ((0, 0), (0x100001, 1)):
            self.configure()
            struct.pack_into('<I', self.memory, 152, size)
            self.access(0x50)
            self.assertEqual(self.memory[450], expected)
            self.assertEqual(struct.unpack_from('<I', self.memory, 328)[0], 1)

    def test_disabled_image_and_registers(self):
        self.model.disk_size = 0
        self.assertEqual(self.access(8, write=False)[0], 0)
        self.assertEqual(self.access(0x34, write=False)[0], 0)
        self.assertEqual(self.access(0x50)[1], [])
        self.access(0x38, 999)
        self.assertEqual(self.model.queue_size(), 256)
        self.access(0x14, 2)
        self.assertEqual(self.access(0x10, write=False)[0], 6)


VOLATILE, READONLY, PERSISTENT = range(3)


class BlockImage(ctypes.Structure):
    _fields_ = [('fd', ctypes.c_int), ('mode', ctypes.c_int), ('size', ctypes.c_size_t),
                ('data', ctypes.c_void_p)]


class BlockImageTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.build.cleanup)
        binary = Path(cls.build.name) / 'block.so'
        subprocess.run(['cc', '-std=gnu11', '-O2', '-Wall', '-Wextra', '-Werror', '-shared', '-fPIC',
                        '-I' + str(ROOT / 'nemu/include'), str(ROOT / 'app/tests/host/nemu_block_image.c'),
                        '-o', str(binary)], check=True, capture_output=True)
        cls.library = ctypes.CDLL(str(binary), use_errno=True)
        pointer = ctypes.POINTER(BlockImage)
        cls.library.nemu_block_open.argtypes = [pointer, ctypes.c_char_p, ctypes.c_int]
        cls.library.nemu_block_open.restype = ctypes.c_bool
        cls.library.nemu_block_close.argtypes = [pointer]
        for operation in ('read', 'write'):
            function = getattr(cls.library, 'nemu_block_' + operation)
            function.argtypes = [pointer, ctypes.c_size_t, ctypes.c_void_p, ctypes.c_size_t]
            function.restype = ctypes.c_bool
        cls.library.nemu_block_flush.argtypes = [pointer]
        cls.library.nemu_block_flush.restype = ctypes.c_bool
        cls.library.block_test_faults.argtypes = [ctypes.c_uint, ctypes.c_size_t]

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name) / 'disk.raw'
        self.original = bytes(range(256)) * 1024
        self.path.write_bytes(self.original)
        self.library.block_test_faults(0, 0)

    def attach(self, mode, path=None):
        image = BlockImage(fd=-1)
        self.assertTrue(self.library.nemu_block_open(ctypes.byref(image), os.fsencode(path or self.path), mode),
                        os.strerror(ctypes.get_errno()))
        self.addCleanup(self.library.nemu_block_close, ctypes.byref(image))
        return image

    def test_volatile_snapshot_never_writes_host_file(self):
        image = self.attach(VOLATILE)
        self.assertTrue(image.data)
        contents = b'changed' * 10000
        self.assertTrue(self.library.nemu_block_write(ctypes.byref(image), 13, contents, len(contents)))
        output = ctypes.create_string_buffer(len(contents))
        self.assertTrue(self.library.nemu_block_read(ctypes.byref(image), 13, output, len(contents)))
        self.assertEqual(output.raw, contents)
        self.assertTrue(self.library.nemu_block_flush(ctypes.byref(image)))
        self.assertEqual(self.library.block_test_flush_calls(), 0)
        self.assertEqual(self.path.read_bytes(), self.original)

    def test_persistent_short_transfers_interrupts_and_reopen(self):
        image = self.attach(PERSISTENT)
        self.assertIsNone(image.data)
        contents = b'persist' * 20000
        self.library.block_test_faults(2, 137)
        self.assertTrue(self.library.nemu_block_write(ctypes.byref(image), 19, contents, len(contents)))
        self.library.block_test_faults(4, 0)
        self.assertTrue(self.library.nemu_block_flush(ctypes.byref(image)))
        self.assertEqual(self.library.block_test_flush_calls(), 2)
        self.library.nemu_block_close(ctypes.byref(image))
        image = self.attach(READONLY)
        self.assertIsNone(image.data)
        self.library.block_test_faults(1, 113)
        output = ctypes.create_string_buffer(len(contents))
        self.assertTrue(self.library.nemu_block_read(ctypes.byref(image), 19, output, len(contents)))
        self.assertEqual(output.raw, contents)
        self.assertFalse(self.library.nemu_block_write(ctypes.byref(image), 0, b'x', 1))
        self.assertEqual(ctypes.get_errno(), errno.EROFS)
        self.assertEqual(self.path.read_bytes(), self.original[:19] + contents + self.original[19 + len(contents):])

    def test_locking_and_failed_open_preserve_existing_handle(self):
        image = self.attach(VOLATILE)
        reader = self.attach(READONLY)
        alias = self.path.with_name('hardlink.raw')
        os.link(self.path, alias)
        other = BlockImage(fd=-1)
        self.assertFalse(self.library.nemu_block_open(ctypes.byref(other), os.fsencode(alias), PERSISTENT))
        self.assertIn(ctypes.get_errno(), (errno.EAGAIN, errno.EACCES))
        descriptor = image.fd
        self.assertFalse(self.library.nemu_block_open(ctypes.byref(image), b'/no/such/nemu-disk', PERSISTENT))
        self.assertEqual(image.fd, descriptor)
        self.library.nemu_block_close(ctypes.byref(image))
        self.library.nemu_block_close(ctypes.byref(reader))
        writer = self.attach(PERSISTENT, alias)
        for mode in (VOLATILE, READONLY, PERSISTENT):
            self.assertFalse(self.library.nemu_block_open(ctypes.byref(other), os.fsencode(self.path), mode))
        self.library.nemu_block_close(ctypes.byref(writer))
        self.attach(READONLY)

    def test_ranges_truncation_and_io_failures(self):
        image = self.attach(PERSISTENT)
        output = ctypes.create_string_buffer(512)
        for offset, size in ((image.size, 1), (image.size - 1, 2), (2**64 - 1, 2), (1, 2**64 - 1)):
            self.assertFalse(self.library.nemu_block_read(ctypes.byref(image), offset, output, size))
            self.assertFalse(self.library.nemu_block_write(ctypes.byref(image), offset, output, size))
        self.library.block_test_faults(16, 0)
        self.assertFalse(self.library.nemu_block_write(ctypes.byref(image), 0, b'no', 2))
        self.assertEqual(ctypes.get_errno(), errno.ENOSPC)
        self.library.block_test_faults(32, 0)
        self.assertFalse(self.library.nemu_block_flush(ctypes.byref(image)))
        self.assertEqual(ctypes.get_errno(), errno.EIO)
        self.library.block_test_faults(0, 0)
        self.assertEqual(self.path.read_bytes(), self.original)
        os.truncate(self.path, 0)
        self.assertFalse(self.library.nemu_block_read(ctypes.byref(image), 0, output, 512))
        self.assertEqual(ctypes.get_errno(), errno.EIO)

    def test_sparse_large_disk_does_not_allocate_an_image_buffer(self):
        os.truncate(self.path, 4 * 1024**3)
        image = self.attach(PERSISTENT)
        self.assertEqual(image.size, 4 * 1024**3)
        self.assertIsNone(image.data)
        contents = b'end' * 100
        self.assertTrue(self.library.nemu_block_write(ctypes.byref(image), image.size - len(contents), contents,
                                                    len(contents)))
        self.assertTrue(self.library.nemu_block_flush(ctypes.byref(image)))
        with self.path.open('rb') as source:
            source.seek(-len(contents), os.SEEK_END)
            self.assertEqual(source.read(), contents)

    def test_reject_nonfiles_and_failed_snapshot_read_releases_lock(self):
        empty = self.path.with_name('empty')
        empty.touch()
        fifo = self.path.with_name('fifo')
        os.mkfifo(fifo)
        image = BlockImage(fd=-1)
        for path in (empty, fifo, Path(self.directory.name)):
            self.assertFalse(self.library.nemu_block_open(ctypes.byref(image), os.fsencode(path), READONLY))
        self.library.block_test_faults(8, 0)
        self.assertFalse(self.library.nemu_block_open(ctypes.byref(image), os.fsencode(self.path), VOLATILE))
        self.assertEqual(ctypes.get_errno(), errno.EIO)
        self.library.block_test_faults(0, 0)
        self.attach(PERSISTENT)


class StorageDeviceTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.build.cleanup)
        directory = Path(cls.build.name)
        cls.libraries = []
        for xlen in (32, 64):
            config = directory / str(xlen)
            (config / 'generated').mkdir(parents=True)
            (config / 'generated/autoconf.h').write_text(
                '#define CONFIG_ISA_riscv 1\n#define CONFIG_TARGET_NATIVE_ELF 1\n' +
                '#define CONFIG_MBASE 0x80000000\n#define CONFIG_MSIZE 0x4000\n' +
                ('#define CONFIG_RV64 1\n#define CONFIG_ISA64 1\n' if xlen == 64 else ''))
            binary = config / 'device.so'
            result = subprocess.run(['cc', '-std=gnu11', '-O2', '-Wall', '-Werror', '-shared', '-fPIC',
                            '-I' + str(config), '-I' + str(ROOT / 'nemu/include'),
                            '-I' + str(ROOT / 'nemu/src/isa/riscv/include'),
                            str(ROOT / 'app/tests/host/nemu_storage.c'),
                            str(ROOT / 'app/tests/host/nemu_block_image.c'), '-o', str(binary)],
                                    capture_output=True)
            if result.returncode:
                raise AssertionError(result.stderr.decode())
            library = ctypes.CDLL(str(binary))
            library.storage_test_attach.argtypes = [ctypes.c_char_p, ctypes.c_int]
            library.storage_test_memory.restype = ctypes.c_void_p
            library.storage_test_read.argtypes = [ctypes.c_uint]
            library.storage_test_read.restype = ctypes.c_uint32
            library.storage_test_write.argtypes = [ctypes.c_uint, ctypes.c_uint32]
            library.block_test_faults.argtypes = [ctypes.c_uint, ctypes.c_size_t]
            cls.libraries.append((xlen, library))

    def test_modes_and_flush_completion(self):
        for xlen, library in self.libraries:
            for mode in range(3):
                with self.subTest(xlen=xlen, mode=mode), tempfile.TemporaryDirectory() as temporary:
                    path = Path(temporary) / 'disk'
                    path.write_bytes(bytes(4096))
                    library.storage_test_attach(os.fsencode(path), mode)
                    try:
                        features = library.storage_test_read(0x10)
                        self.assertEqual(features, 6 | (32 if mode == 1 else 512 if mode == 2 else 0))
                        memory = library.storage_test_memory()
                        write_reg = library.storage_test_write

                        def request(kind, negotiated=True, faults=0, sector=1, extra_data=False):
                            write_reg(0x70, 0)
                            library.block_test_faults(faults, 17)
                            ctypes.memset(memory, 0, 16384)
                            header = struct.pack('<IIQ', kind, 0, sector)
                            ctypes.memmove(memory + 1024, header, len(header))
                            has_data = kind != 4 or extra_data
                            descriptors = struct.pack('<QIHH', 0x80000400, 16, 1, 1)
                            if has_data:
                                descriptors += struct.pack('<QIHH', 0x80000800, 512, 1 if kind == 1 else 3, 2)
                            descriptors += struct.pack('<QIHH', 0x80000c00, 1, 2, 0)
                            ctypes.memmove(memory, descriptors, len(descriptors))
                            ctypes.memmove(memory + 512, struct.pack('<HHH', 0, 1, 0), 6)
                            ctypes.memset(memory + 2048, 0x93, 512)
                            ctypes.memset(memory + 3072, 0xa5, 1)
                            write_reg(0x20, features if negotiated else 0)
                            write_reg(0x38, 8)
                            write_reg(0x80, 0x80000000)
                            write_reg(0x90, 0x80000200)
                            write_reg(0xa0, 0x80001000)
                            write_reg(0x44, 1)
                            write_reg(0x70, 4)
                            write_reg(0x50, 0)
                            self.assertEqual(struct.unpack('<H', ctypes.string_at(memory + 4098, 2))[0], 1)
                            self.assertEqual(library.storage_test_read(0x60), 1)
                            return ctypes.string_at(memory + 3072, 1)[0]

                        self.assertEqual(request(1), 1 if mode == 1 else 0)
                        self.assertEqual(library.block_test_flush_calls(), 0)
                        self.assertEqual(request(0), 0)
                        self.assertEqual(ctypes.string_at(memory + 2048, 512), bytes([0 if mode == 1 else 0x93]) * 512)
                        self.assertEqual(request(4, sector=0), 0 if mode == 2 else 1)
                        self.assertEqual(library.block_test_flush_calls(), int(mode == 2))
                        if mode == 2:
                            self.assertEqual(request(1, negotiated=False), 0)
                            self.assertEqual(library.block_test_flush_calls(), 1)
                            self.assertEqual(request(1, faults=16), 1)
                            self.assertEqual(request(0, faults=8), 1)
                            self.assertEqual(request(4, faults=32, sector=0), 1)
                            self.assertEqual(request(1, negotiated=False, faults=32), 1)
                            self.assertEqual(request(4, sector=1), 1)
                            self.assertEqual(library.block_test_flush_calls(), 0)
                            self.assertEqual(request(4, sector=0, extra_data=True), 1)
                            self.assertEqual(library.block_test_flush_calls(), 0)
                        self.assertEqual(path.read_bytes(), bytes(512) +
                                         (bytes([0x93]) * 512 if mode == 2 else bytes(512)) + bytes(3072))
                    finally:
                        library.block_test_faults(0, 0)
                        library.storage_test_close()


class StorageLinuxTest(unittest.TestCase):
    def test_network_round_trip_checks_partial_tcp_replies(self):
        tcp = MagicMock()
        tcp.__enter__.return_value = tcp
        reply = bytes(((index * 37 + 11) & 255) ^ 0x5a for index in range(8192))
        with patch('isa.storage_linux.socket.create_connection', return_value=tcp):
            tcp.recv.side_effect = [reply[:13], reply[13:]]
            network_round_trip(2222, 5)
            tcp.sendall.assert_called_with(b'K')
            for received, message in (([b''], 'ended early'), ([bytes(8192)], 'TCP reply mismatch')):
                tcp.recv.side_effect = received
                with self.assertRaisesRegex(ValueError, message):
                    network_round_trip(2222, 5)
            with self.assertRaises(TimeoutError):
                network_round_trip(2222, 0)

    def test_readiness_callback_runs_once_and_failures_stop_the_guest(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            release = directory / 'release'
            script = ('from pathlib import Path; import time\nprint("READY", flush=True)\n'
                      f'while not Path({str(release)!r}).exists(): time.sleep(0.01)\n'
                      'time.sleep(0.2)\n')
            calls = []
            def ready(timeout):
                calls.append(timeout)
                release.touch()
            result = run_console([sys.executable, '-c', script], directory / 'log', 5,
                                 ready_marker=b'READY', on_ready=ready)
            self.assertEqual(result, (0, False))
            self.assertEqual(len(calls), 1)
            self.assertGreater(calls[0], 0)
            release.unlink()
            def failed(timeout):
                raise RuntimeError('host client failed')
            with self.assertRaisesRegex(RuntimeError, 'host client failed'):
                run_console([sys.executable, '-c', script], directory / 'failed.log', 5,
                            ready_marker=b'READY', on_ready=failed)

    def test_requires_phase_marker_clean_poweroff_and_no_errors(self):
        for marker in (b'NEMU_STORAGE_WRITE_PASS', b'NEMU_STORAGE_READ_PASS', b'NEMU_STORAGE_READONLY_PASS'):
            output = marker + b'\nNEMU_STORAGE_LINUX_PASS\nFinisher: poweroff\n'
            self.assertTrue(verdict(0, output, marker))
            self.assertFalse(verdict(0, output, marker, network=True))
            self.assertTrue(verdict(0, output + b'NEMU_NETWORK_PASS\n', marker, network=True))
            for missing in (marker, b'NEMU_STORAGE_LINUX_PASS', b'Finisher: poweroff'):
                self.assertFalse(verdict(0, output.replace(missing, b''), marker))
            for error in FAIL_MARKERS:
                self.assertFalse(verdict(0, output + error, marker))
            self.assertFalse(verdict(1, output, marker))
            self.assertFalse(verdict(0, output, marker, timed_out=True))

    def test_stops_on_storage_failure_and_preserves_console(self):
        with tempfile.TemporaryDirectory() as temporary:
            log = Path(temporary) / 'boot.log'
            command = [sys.executable, '-c', "import time;print('NEMU_STORAGE_FAIL', flush=True);time.sleep(30)"]
            returncode, timed_out = run_console(command, log, 5, failure_markers=FAIL_MARKERS)
            self.assertNotEqual(returncode, 0)
            self.assertFalse(timed_out)
            self.assertIn(b'NEMU_STORAGE_FAIL', log.read_bytes())

    def test_stops_descendants_and_releases_their_disk_locks(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            lock = directory / 'disk'
            ready = directory / 'ready'
            child = ('import fcntl, signal, time; from pathlib import Path; '
                     'signal.signal(signal.SIGTERM, signal.SIG_IGN); '
                     f'lock = open({str(lock)!r}, "w"); fcntl.flock(lock, fcntl.LOCK_EX); '
                     f'Path({str(ready)!r}).touch(); time.sleep(30)')
            parent = ('import subprocess, sys, time; from pathlib import Path\n'
                      f'subprocess.Popen([sys.executable, "-c", {child!r}])\n'
                      f'while not Path({str(ready)!r}).exists(): time.sleep(0.01)\n'
                      'print("NEMU_STORAGE_FAIL", flush=True)\ntime.sleep(30)\n')
            returncode, timed_out = run_console([sys.executable, '-c', parent], directory / 'boot.log',
                                                5, failure_markers=FAIL_MARKERS)
            self.assertNotEqual(returncode, 0)
            self.assertFalse(timed_out)
            self.assertTrue(ready.exists())
            with lock.open('r') as stream:
                deadline = time.monotonic() + 2
                while True:
                    try:
                        fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
                        break
                    except BlockingIOError:
                        if time.monotonic() >= deadline:
                            raise
                        time.sleep(0.01)


if __name__ == '__main__':
    unittest.main()
