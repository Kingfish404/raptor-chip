"""Small test adapter for NEMU's NPCState pointer API (one library/process)."""
import ctypes as C
from pathlib import Path


class Reference:
    def __init__(self, path, xlen):
        self.xlen = xlen
        self.mask = (1 << xlen) - 1
        self.word = C.c_uint64 if xlen == 64 else C.c_uint32
        names = ('sstatus sie stvec scounteren mcounteren sscratch sepc scause stval '
                 'sip satp mstatus misa medeleg mideleg mie mtvec menvcfg mstatush '
                 'mscratch mepc mcause mtval mip mcycle mcycleh minstret minstreth time timeh').split()
        class State(C.Structure):
            _fields_ = [('state', C.c_int), ('host_exit_ok', C.c_uint8),
                        ('gpr', C.POINTER(self.word)), ('ret', C.POINTER(self.word)),
                        ('pc', C.POINTER(self.word)), ('priv', C.POINTER(C.c_char))] + [
                            (name, C.POINTER(self.word)) for name in names]
        self.lib = C.CDLL(str(Path(path).resolve()))
        self.lib.difftest_init.argtypes = [C.c_int]
        self.lib.difftest_regcpy.argtypes = [C.c_void_p, C.c_bool]
        # Raptor NEMU uses 64-bit physical addresses for both guest XLENs.
        self.lib.difftest_memcpy.argtypes = [C.c_uint64, C.c_void_p, C.c_size_t, C.c_bool]
        self.lib.difftest_exec.argtypes = [C.c_uint64]
        self.lib.difftest_init(0)
        self.storage = C.create_string_buffer(4096)
        self.lib.difftest_regcpy(self.storage, False)
        self.state = C.cast(self.storage, C.POINTER(State)).contents
        self.names = names
        self.next_pc = 0x80000000
        # An unlocked TOR region permits the tests' S/U instruction fetches.
        self.state.gpr[1] = self.mask
        self.run([0x3b009073])
        self.state.gpr[1] = 15
        self.run([0x3a009073])

    def reset(self):
        s = self.state
        for name in self.names:
            if name != 'misa':
                getattr(s, name)[0] = 0
        s.mstatus[0] = (0xa00000000 if self.xlen == 64 else 0) | 0x6000
        s.priv[0] = b'\x03'
        s.mtvec[0] = 0x80ff0000
        s.stvec[0] = 0x80fe0000
        for i in range(32):
            s.gpr[i] = 0
        # Flush translation/decode state after directly injecting test CSRs.
        self.run([0x12000073])
        s.minstret[0] = 100
        s.mcycle[0] = 100

    def run(self, instructions):
        pc = self.next_pc
        self.next_pc += max(16, len(instructions) * 4)
        if self.next_pc >= 0x80f00000:
            raise RuntimeError('test instruction arena exhausted')
        self.write(pc, b''.join(i.to_bytes(4, 'little') for i in instructions))
        self.state.pc[0] = pc
        self.lib.difftest_exec(len(instructions))
        return pc

    def write(self, address, data):
        buf = C.create_string_buffer(data)
        self.lib.difftest_memcpy(address, buf, len(data), True)

    def read(self, address, size):
        buf = C.create_string_buffer(size)
        self.lib.difftest_memcpy(address, buf, size, False)
        return buf.raw
