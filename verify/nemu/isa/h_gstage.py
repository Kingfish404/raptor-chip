"""Exercise opt-in RV64 VS/G-stage HLV/HSV through the DiffTest ABI."""

import argparse
import ctypes
import hashlib
import json
from pathlib import Path

from isa.vector_data import VectorAPI, VectorState
from lib.reference import ISAAPI, Reference


EXTENSION = 1 << 10
SVNAPOT = 1 << 0
SSNPM = 1 << 3
VECTOR = 1 << 6
HGATP = 0x680
HSTATUS = 0x600
HEDELEG = 0x602
HIDELEG = 0x603
HIE = 0x604
HTIMEDELTA = 0x605
HCOUNTEREN = 0x606
HGEIE = 0x607
HENVCFG = 0x60A
HGEIP = 0xE12
HIP = 0x644
HVIP = 0x645
MENVCFG = 0x30A
MIDELEG = 0x303
MIE = 0x304
MCOUNTEREN = 0x306
SCOUNTEREN = 0x106
MCAUSE = 0x342
MIP = 0x344
TIME = 0xC01
SENVCFG = 0x10A
HTVAL = 0x643
HTINST = 0x64A
MTVAL2 = 0x34B
MTINST = 0x34A
VSSTATUS = 0x200
VSIE = 0x204
VSTVEC = 0x205
SSTATUS = 0x100
VSEPC = 0x241
VSCAUSE = 0x242
VSIP = 0x244
VSTIMECMP = 0x24D
VSATP = 0x280
HLV_W = 0x68004073 | (1 << 15) | (3 << 7)
HLVX_HU = 0x64304073 | (1 << 15) | (3 << 7)
HLVX_WU = 0x68304073 | (1 << 15) | (3 << 7)
HSV_W = 0x6A004073 | (2 << 20) | (1 << 15)
HFENCE_GVMA = 0x62000073
HINVAL_GVMA = 0x66000073
HFENCE_VVMA = 0x22000073
HINVAL_VVMA = 0x26000073
CBO_CLEAN = 0x0010A00F
CBO_ZERO = 0x0040A00F


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reference", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--xlen", type=int, choices=(32, 64), default=64)
    parser.add_argument("--enable", action="store_true")
    parser.add_argument("--multihart", action="store_true",
                        help="also exercise the two-hart state-copy ABI")
    parser.add_argument("--svnapot", action="store_true")
    parser.add_argument("--pointer-mask", action="store_true")
    parser.add_argument("--vector", action="store_true")
    args = parser.parse_args()
    if args.enable and args.xlen != 64:
        parser.error("G-stage preview requires RV64")
    if args.multihart and not args.enable:
        parser.error("multi-hart state checks require the hypervisor extension")
    if args.pointer_mask and not args.enable:
        parser.error("pointer masking requires the G-stage preview")
    if args.svnapot and not args.enable:
        parser.error("Svnapot guest checks require the G-stage preview")
    if args.vector and not args.enable:
        parser.error("vector guest checks require the G-stage preview")

    library = ctypes.CDLL(str(args.reference.resolve()))
    query = library.nemu_difftest_isa_query
    query.argtypes = [ctypes.c_uint32, ctypes.c_uint32]
    query.restype = ctypes.POINTER(ISAAPI)
    api = query(1, ctypes.sizeof(ISAAPI)).contents
    rows = []

    def check(name, actual, expected):
        rows.append(dict(name=name, actual=actual, expected=expected,
                         passed=actual == expected))

    check("supported", bool(api.supported & EXTENSION), args.xlen == 64)
    enabled_extensions = (EXTENSION | (SVNAPOT if args.svnapot else 0) |
                          (SSNPM if args.pointer_mask else 0) |
                          (VECTOR if args.vector else 0)) if args.enable else 0
    check("configure", api.configure(enabled_extensions), 0)
    reference = Reference(args.reference, args.xlen)
    check("locked", query(1, ctypes.sizeof(ISAAPI)).contents.locked, 1)
    check("late-config-rejected", api.configure(0), -1)
    state = reference.state

    def write_csr(csr, value, privilege=3):
        state.priv[0] = bytes([privilege])
        state.gpr[4] = value & reference.mask
        return reference.run([(csr << 20) | (4 << 15) | (1 << 12) | 0x73])

    def read_csr(csr, privilege=3):
        state.priv[0] = bytes([privilege])
        pc = reference.run([(csr << 20) | (2 << 12) | (3 << 7) | 0x73])
        return state.gpr[3], pc

    def execute(name, opcode, privilege=3):
        state.priv[0] = bytes([privilege])
        pc = reference.run([opcode])
        return pc

    reference.reset()
    check("misa-h", bool(state.misa[0] & (1 << 7)), args.enable)
    write_csr(0x301, 0)
    check("misa-write-zero-preserves-h", bool(read_csr(0x301)[0] & (1 << 7)), args.enable)
    write_csr(0x301, 1 << 7)
    check("misa-write-h-preserves-mode", bool(read_csr(0x301)[0] & (1 << 7)), args.enable)
    if not args.enable:
        for csr in (HGATP, HSTATUS, HEDELEG, HIDELEG, HIE, HIP, HVIP,
                    HTIMEDELTA, HCOUNTEREN, HGEIE, HGEIP, HENVCFG, HTVAL, HTINST, MTVAL2,
                    MTINST, VSSTATUS, VSIE, VSIP, VSTIMECMP, VSATP):
            _, pc = read_csr(csr)
            check(f"disabled-csr-{csr:x}", [state.mcause[0], state.mepc[0]], [2, pc])
        pc = execute("disabled-hlv", HLV_W)
        check("disabled-hlv", [state.mcause[0], state.mepc[0]], [2, pc])
        for name, opcode in (("hu", HLVX_HU), ("wu", HLVX_WU)):
            pc = execute(f"disabled-hlvx-{name}", opcode)
            check(f"disabled-hlvx-{name}", [state.mcause[0], state.mepc[0]], [2, pc])
        for name, opcode in (("hfence-vvma", HFENCE_VVMA),
                             ("hinval-vvma", HINVAL_VVMA)):
            pc = execute(f"disabled-{name}", opcode)
            check(f"disabled-{name}", [state.mcause[0], state.mepc[0]], [2, pc])
    else:
        write_csr(MIDELEG, 0)
        check("mideleg-virtual-forced", read_csr(MIDELEG)[0] & 0x444, 0x444)
        write_csr(HIDELEG, reference.mask)
        check("hideleg-warl", read_csr(HIDELEG)[0], 0x444)
        write_csr(HVIP, reference.mask)
        check("hvip-warl", read_csr(HVIP)[0], 0x444)
        check("hip-pending-alias", read_csr(HIP)[0], 0x444)
        check("mip-pending-alias", read_csr(MIP)[0] & 0x444, 0x444)
        check("vsip-pending-alias", read_csr(VSIP)[0], 0x222)
        write_csr(MIE, 0x444)
        check("hie-enable-alias", read_csr(HIE)[0], 0x444)
        check("vsie-enable-alias", read_csr(VSIE)[0], 0x222)
        write_csr(VSIE, 0)
        check("vsie-clear-alias", read_csr(HIE)[0], 0)
        write_csr(VSIE, 0x222)
        check("vsie-write-alias", read_csr(HIE)[0], 0x444)
        write_csr(HIP, 0)
        check("hip-software-only-write", read_csr(HVIP)[0], 0x440)
        write_csr(VSIP, 0x2)
        check("vsip-software-write", read_csr(HVIP)[0], 0x444)
        write_csr(HIDELEG, 0)
        check("vsip-hidden-without-delegation", read_csr(VSIP)[0], 0)
        check("vsie-hidden-without-delegation", read_csr(VSIE)[0], 0)
        write_csr(VSIE, 0)
        check("vsie-write-ignored-without-delegation", read_csr(HIE)[0], 0x444)
        write_csr(HVIP, 0)
        write_csr(MIE, 0)
        write_csr(HCOUNTEREN, reference.mask)
        check("hcounteren-warl", read_csr(HCOUNTEREN)[0], 0x7)
        write_csr(HGEIE, reference.mask, 1)
        check("hgeie-geilen-zero", read_csr(HGEIE, 1)[0], 0)
        check("hgeip-geilen-zero", read_csr(HGEIP, 1)[0], 0)
        pc = write_csr(HGEIP, 1, 1)
        check("hgeip-read-only", [state.mcause[0], state.mepc[0]], [2, pc])
        write_csr(MCAUSE, 0)
        write_csr(HTIMEDELTA, 5)
        check("htimedelta-write", read_csr(HTIMEDELTA)[0], 5)
        write_csr(VSTIMECMP, 105)
        check("vstimecmp-write", read_csr(VSTIMECMP)[0], 105)
        state.time[0] = 100
        write_csr(MENVCFG, 1 << 63)
        write_csr(HENVCFG, 1 << 63)
        check("vstip-comparator-assert", read_csr(HIP)[0] & 0x40, 0x40)
        write_csr(VSTIMECMP, 106)
        check("vstip-comparator-clear", read_csr(HIP)[0] & 0x40, 0)
        write_csr(HVIP, 0x40)
        check("vstip-hvip-or", read_csr(HIP)[0] & 0x40, 0x40)
        write_csr(HVIP, 0)
        write_csr(VSTIMECMP, 100)
        guest_pc = 0x80001000
        guest_handler = 0x80002000
        reference.write(guest_pc, (0x00000013).to_bytes(4, "little"))
        reference.write(guest_handler, (0x00000013).to_bytes(4, "little"))
        write_csr(HIDELEG, 0x40)
        write_csr(MIE, 0x40)
        write_csr(VSSTATUS, 0x2)
        write_csr(VSTVEC, guest_handler)
        state.mstatus[0] = ((state.mstatus[0] & ~((3 << 11) | (1 << 3))) |
                            (1 << 39) | (1 << 11))
        state.mepc[0] = guest_pc
        execute("mret-enter-vs-timer", 0x30200073)
        check("vstip-enter-vs", [state.pc[0], state.priv[0][0]], [guest_pc, 1])
        reference.lib.difftest_raise_intr.argtypes = [reference.word]
        reference.lib.difftest_raise_intr((1 << 63) | 6)
        reference.lib.difftest_exec(1)
        timer_pc = state.pc[0]
        reference.lib.difftest_raise_intr(11)
        timer_cause = read_csr(VSCAUSE)[0]
        timer_epc = read_csr(VSEPC)[0]
        check("vstip-delegated-vs", [timer_pc, timer_cause, timer_epc],
              [guest_handler + 4, (1 << 63) | 5, guest_pc])
        write_csr(MCAUSE, 0)
        write_csr(HIDELEG, 0)
        state.mstatus[0] = ((state.mstatus[0] & ~(3 << 11)) |
                            (1 << 39) | (1 << 11))
        state.mepc[0] = guest_pc
        execute("mret-enter-vs-timer-hs", 0x30200073)
        reference.lib.difftest_raise_intr((1 << 63) | 6)
        check("vstip-not-delegated-hs",
              [state.pc[0], state.scause[0], state.sepc[0]],
              [state.stvec[0], (1 << 63) | 6, guest_pc])
        reference.lib.difftest_raise_intr(11)
        write_csr(MCAUSE, 0)
        write_csr(MIE, 0)
        write_csr(HIDELEG, 0)
        write_csr(HENVCFG, 0)
        check("vstip-henvcfg-gated", read_csr(HIP)[0] & 0x40, 0)
        write_csr(MENVCFG, 0)
        write_csr(HENVCFG, 1 << 63)
        check("henvcfg-stce-machine-gated", read_csr(HENVCFG)[0] >> 63, 0)
        write_csr(VSTIMECMP, reference.mask)
        write_csr(HTIMEDELTA, 0)
        write_csr(HCOUNTEREN, 0)
        state.time[0] = 0

        root, middle, leaf = 0x82000000, 0x82004000, 0x82005000
        guest, first, second = 0x41000000, 0x81000000, 0x81001000

        def write_pte(address, value):
            reference.write(address, value.to_bytes(8, "little"))

        for table in (root, middle, leaf):
            reference.write(table, bytes(0x4000 if table == root else 0x1000))
        write_pte(root + ((guest >> 30) & 0x7FF) * 8, (middle >> 12) << 10 | 1)
        write_pte(middle + ((guest >> 21) & 0x1FF) * 8, (leaf >> 12) << 10 | 1)
        write_pte(leaf, (first >> 12) << 10 | 0xDF)
        reference.write(first, (0x12345678).to_bytes(8, "little"))
        reference.write(second, (0x55667788).to_bytes(8, "little"))

        write_csr(HGATP, reference.mask)
        check("unsupported-mode-to-bare", read_csr(HGATP)[0], 0)
        write_csr(HGATP, (8 << 60) | (0x3FFF << 44) | (root >> 12) | 3)
        check("sv39x4-vmid0-alignment", read_csr(HGATP)[0],
              (8 << 60) | (root >> 12))
        check("supervisor-hgatp", read_csr(HGATP, 1)[0], (8 << 60) | (root >> 12))

        state.gpr[1] = guest
        state.gpr[2] = 0xAABBCCDD
        pc = execute("hlv-w", HLV_W)
        check("hlv-w", [state.pc[0], state.gpr[3], state.mcause[0]],
              [pc + 4, 0x12345678, 0])
        pc = execute("hsv-w", HSV_W)
        check("hsv-w", [state.pc[0], int.from_bytes(reference.read(first, 4), "little")],
              [pc + 4, 0xAABBCCDD])
        reference.write(first, b"\x00\x11\x22\x33\x44\x00\x00\x00")
        state.gpr[1] = guest + 1
        pc = execute("hlv-w-misaligned-dram", HLV_W)
        check("hlv-w-misaligned-dram", [state.pc[0], state.gpr[3]],
              [pc + 4, 0x44332211])
        pc = execute("hlvx-wu-misaligned-dram", HLVX_WU)
        check("hlvx-wu-misaligned-dram", [state.pc[0], state.gpr[3]],
              [pc + 4, 0x44332211])
        pc = execute("hsv-w-misaligned-dram", HSV_W)
        check("hsv-w-misaligned-dram", [state.pc[0], reference.read(first + 1, 4).hex()],
              [pc + 4, "ddccbbaa"])

        third = 0x81002000
        write_pte(leaf + 8, (third >> 12) << 10 | 0xDF)
        reference.write(first + 0xFFE, b"\x11\x22")
        reference.write(third, b"\x33\x44")
        state.gpr[1] = guest + 0xFFE
        pc = execute("hlv-w-cross-page", HLV_W)
        check("hlv-w-cross-page", [state.pc[0], state.gpr[3]],
              [pc + 4, 0x44332211])
        pc = execute("hsv-w-cross-page", HSV_W)
        check("hsv-w-cross-page", [state.pc[0], reference.read(first + 0xFFE, 2).hex(),
                                    reference.read(third, 2).hex()],
              [pc + 4, "ddcc", "bbaa"])
        write_pte(leaf + 8, 0)
        reference.write(first + 0xFFE, b"\x11\x22")
        pc = execute("hsv-w-cross-page-fault", HSV_W)
        check("hsv-w-cross-page-fault",
              [state.pc[0], state.mcause[0], state.mtval[0],
               read_csr(MTVAL2)[0], reference.read(first + 0xFFE, 2).hex()],
              [0x80FF0000, 23, guest + 0x1000, (guest + 0x1000) >> 2, "1122"])
        state.gpr[1] = guest
        payload = 0xFEDCBA98F654F2D0
        reference.write(first, payload.to_bytes(8, "little"))
        for name, opcode, width, signed in (
            ("b", 0x60004073, 1, True),
            ("bu", 0x60104073, 1, False),
            ("h", 0x64004073, 2, True),
            ("hu", 0x64104073, 2, False),
            ("w", 0x68004073, 4, True),
            ("wu", 0x68104073, 4, False),
            ("d", 0x6C004073, 8, False),
        ):
            pc = execute(f"hlv-{name}", opcode | (1 << 15) | (3 << 7))
            value = payload & ((1 << (width * 8)) - 1)
            if signed and value & (1 << (width * 8 - 1)):
                value |= reference.mask ^ ((1 << (width * 8)) - 1)
            check(f"hlv-{name}", [state.pc[0], state.gpr[3]], [pc + 4, value])
        state.gpr[2] = 0x0123456789ABCDEF
        for name, opcode, width in (
            ("b", 0x62004073, 1),
            ("h", 0x66004073, 2),
            ("w", 0x6A004073, 4),
            ("d", 0x6E004073, 8),
        ):
            reference.write(first, payload.to_bytes(8, "little"))
            pc = execute(f"hsv-{name}", opcode | (2 << 20) | (1 << 15))
            value = int.from_bytes(reference.read(first, width), "little")
            check(f"hsv-{name}", [state.pc[0], value],
                  [pc + 4, state.gpr[2] & ((1 << (width * 8)) - 1)])
        reference.write(first, (0xAABBCCDD).to_bytes(8, "little"))
        state.gpr[2] = 0xAABBCCDD
        state.mstatus[0] |= (1 << 17)
        state.mstatus[0] &= ~(3 << 11)
        pc = execute("mpriv-ignored", HLV_W)
        check("mpriv-ignored", [state.pc[0], state.gpr[3]],
              [pc + 4, 0xFFFFFFFFAABBCCDD])
        state.mstatus[0] &= ~(1 << 17)
        write_pte(leaf, (second >> 12) << 10 | 0xDF)
        execute("hfence-gvma", HFENCE_GVMA)
        execute("hinval-gvma", HINVAL_GVMA)
        execute("hfence-vvma", HFENCE_VVMA)
        execute("hinval-vvma", HINVAL_VVMA)
        pc = execute("hlv-remap", HLV_W)
        check("hlv-remap", [state.pc[0], state.gpr[3]], [pc + 4, 0x55667788])

        write_pte(leaf, (second >> 12) << 10 | 0x5F)
        pc = execute("dirty-bit-fault", HSV_W)
        check("dirty-bit-fault", [state.pc[0], state.mcause[0], state.mtval[0],
                                  int.from_bytes(reference.read(second, 4), "little")],
              [0x80FF0000, 23, guest, 0x55667788])
        write_pte(leaf, (second >> 12) << 10 | 0x9F)
        pc = execute("accessed-bit-fault", HLV_W)
        check("accessed-bit-fault", [state.pc[0], state.mcause[0], state.mtval[0]],
              [0x80FF0000, 21, guest])
        write_pte(leaf, (second >> 12) << 10 | 0xD9)
        pc = execute("execute-only-fault", HLV_W)
        check("execute-only-fault", [state.pc[0], state.mcause[0]],
              [0x80FF0000, 21])
        pc = execute("hlvx-hu-execute-only", HLVX_HU)
        check("hlvx-hu-execute-only", [state.pc[0], state.gpr[3]],
              [pc + 4, 0x7788])
        pc = execute("hlvx-wu-execute-only", HLVX_WU)
        check("hlvx-wu-execute-only", [state.pc[0], state.gpr[3]],
              [pc + 4, 0x55667788])
        write_csr(0x3B0, (second >> 2) | 0x1FF)
        write_csr(0x3B1, reference.mask)
        write_csr(0x3A0, 0x1F00 | 0x19)
        pc = execute("hlvx-pmp-read-only", HLVX_WU)
        check("hlvx-pmp-read-only", [state.pc[0], state.mcause[0], state.mtval[0]],
              [0x80FF0000, 5, guest])
        write_csr(0x3A0, 0x1F00 | 0x1C)
        pc = execute("hlvx-pmp-execute-only", HLVX_WU)
        check("hlvx-pmp-execute-only", [state.pc[0], state.mcause[0], state.mtval[0]],
              [0x80FF0000, 5, guest])
        write_csr(0x3A0, 0x1F00 | 0x1D)
        pc = execute("hlvx-pmp-read-execute", HLVX_WU)
        check("hlvx-pmp-read-execute", [state.pc[0], state.gpr[3]],
              [pc + 4, 0x55667788])
        write_csr(0x3A0, 0x0F)
        write_csr(0x3B0, reference.mask)
        write_csr(0x3B1, 0)
        write_pte(leaf, (second >> 12) << 10 | 0xD3)
        pc = execute("hlvx-read-only-fault", HLVX_WU)
        check("hlvx-read-only-fault", [state.pc[0], state.mcause[0], state.mtval[0]],
              [0x80FF0000, 21, guest])
        write_pte(leaf, (second >> 12) << 10 | 0xD9)
        state.mstatus[0] |= 1 << 19
        pc = execute("execute-only-mxr", HLV_W)
        check("execute-only-mxr", [state.pc[0], state.gpr[3]],
              [pc + 4, 0x55667788])
        state.mstatus[0] &= ~(1 << 19)

        superpage = 0x83000000
        reference.write(superpage, (0xDEADBEEF).to_bytes(4, "little"))
        write_pte(middle + ((guest >> 21) & 0x1FF) * 8,
                  (superpage >> 12) << 10 | 0xDF)
        pc = execute("middle-superpage", HLV_W)
        check("middle-superpage", [state.pc[0], state.gpr[3]],
              [pc + 4, 0xFFFFFFFFDEADBEEF])
        write_pte(middle + ((guest >> 21) & 0x1FF) * 8,
                  ((superpage + 0x1000) >> 12) << 10 | 0x1F)
        pc = execute("misaligned-superpage", HLV_W)
        check("misaligned-superpage", [state.pc[0], state.mcause[0]],
              [0x80FF0000, 21])
        write_pte(middle + ((guest >> 21) & 0x1FF) * 8, (leaf >> 12) << 10 | 1)

        state.gpr[1] = (1 << 41) | guest
        pc = execute("gpa-width-fault", HLV_W)
        actual = [state.pc[0], state.mcause[0], state.mtval[0]]
        actual.append(read_csr(MTVAL2)[0])
        check("gpa-width-fault", actual,
              [0x80FF0000, 21, state.gpr[1], state.gpr[1] >> 2])
        state.gpr[1] = guest

        write_pte(leaf, (second >> 12) << 10 | 0xCF)
        pc = execute("user-bit-fault", HLV_W)
        check("user-bit-fault", [state.pc[0], state.mcause[0], state.mtval[0],
                                 read_csr(MTVAL2)[0]],
              [0x80FF0000, 21, guest, guest >> 2])

        state.medeleg[0] = 1 << 21
        pc = execute("delegated-fault", HLV_W, 1)
        check("delegated-fault", [state.pc[0], state.scause[0], state.stval[0],
                                 read_csr(HTVAL)[0]],
              [0x80FE0000, 21, guest, guest >> 2])

        write_pte(middle + ((guest >> 21) & 0x1FF) * 8,
                  (0x40000000 >> 12) << 10 | 1)
        pc = execute("page-table-access-fault", HLV_W)
        check("page-table-access-fault", [state.pc[0], state.mcause[0],
                                          state.mtval[0], read_csr(MTVAL2)[0]],
              [0x80FF0000, 5, guest, 0])
        write_pte(middle + ((guest >> 21) & 0x1FF) * 8, (leaf >> 12) << 10 | 1)

        state.medeleg[0] = 0
        guest_virtual = 0x40000000
        vs_root_guest, vs_middle_guest, vs_leaf_guest = (
            0x43000000, 0x43001000, 0x43002000)
        vs_root_host, vs_middle_host, vs_leaf_host = (
            0x84000000, 0x84001000, 0x84002000)
        for table in (vs_root_host, vs_middle_host, vs_leaf_host):
            reference.write(table, bytes(0x1000))
        write_pte(middle + ((vs_root_guest >> 21) & 0x1FF) * 8,
                  (vs_root_host >> 12) << 10 | 0xDF)
        write_pte(vs_root_host + 8, (vs_middle_guest >> 12) << 10 | 1)
        write_pte(vs_middle_host, (vs_leaf_guest >> 12) << 10 | 1)
        write_pte(vs_leaf_host, (guest >> 12) << 10 | 0xD7)
        write_pte(leaf, (second >> 12) << 10 | 0xDF)
        write_csr(VSATP, reference.mask)
        check("vsatp-unsupported-mode", read_csr(VSATP)[0], 0)
        write_csr(VSATP, (8 << 60) | (vs_root_guest >> 12))
        check("vsatp-sv39", read_csr(VSATP)[0],
              (8 << 60) | (vs_root_guest >> 12))
        check("hstatus-vsxl", read_csr(HSTATUS)[0] & (3 << 32), 2 << 32)
        write_csr(HSTATUS, 7 << 20)
        check("hstatus-virtual-control-warl", read_csr(HSTATUS)[0] & (7 << 20),
              7 << 20)
        write_csr(HSTATUS, 0x3f << 12)
        check("hstatus-vgein-geilen-zero", read_csr(HSTATUS)[0] & (0x3f << 12), 0)
        write_csr(HSTATUS, 0)
        for pmm in (1, 2, 3):
            write_csr(HENVCFG, pmm << 32)
            expected = pmm if args.pointer_mask and pmm != 1 else 0
            check(f"henvcfg-pmm-{pmm}", read_csr(HENVCFG)[0], expected << 32)
            write_csr(HSTATUS, pmm << 48)
            check(f"hupmm-{pmm}", read_csr(HSTATUS)[0] & (3 << 48), expected << 48)
        write_csr(HENVCFG, 0)
        write_csr(HSTATUS, 0)
        state.gpr[1] = guest_virtual
        pc = execute("two-stage-hlv", HLV_W)
        check("two-stage-hlv", [state.pc[0], state.gpr[3]], [pc + 4, 0x55667788])
        state.gpr[2] = 0x13572468
        pc = execute("two-stage-hsv", HSV_W)
        check("two-stage-hsv", [state.pc[0],
                                int.from_bytes(reference.read(second, 4), "little")],
              [pc + 4, 0x13572468])
        napot_host = 0x85000000
        vs_napot_pte = (1 << 63) | (((guest >> 12) | 8) << 10) | 0xD7
        g_napot_pte = (1 << 63) | (((napot_host >> 12) | 8) << 10) | 0xDF
        for page in range(16):
            write_pte(vs_leaf_host + page * 8, vs_napot_pte)
            write_pte(leaf + page * 8, g_napot_pte)
            reference.write(napot_host + page * 0x1000,
                            (0x100 + page).to_bytes(4, "little"))
        for page in ((0, 8, 15) if args.svnapot else (0,)):
            state.gpr[1] = guest_virtual + page * 0x1000
            pc = execute(f"two-stage-svnapot-{page}", HLV_W)
            if args.svnapot:
                check(f"two-stage-svnapot-{page}", [state.pc[0], state.gpr[3]],
                      [pc + 4, 0x100 + page])
            else:
                check("two-stage-svnapot-disabled",
                      [state.pc[0], state.mcause[0], state.mtval[0]],
                      [0x80FF0000, 13, guest_virtual])
        if not args.svnapot:
            write_pte(vs_leaf_host, (guest >> 12) << 10 | 0xD7)
            state.gpr[1] = guest_virtual
            pc = execute("g-napot-disabled", HLV_W)
            check("g-napot-disabled",
                  [state.pc[0], state.mcause[0], state.mtval[0], read_csr(MTVAL2)[0]],
                  [0x80FF0000, 21, guest_virtual, guest >> 2])
        if args.svnapot:
            write_pte(vs_leaf_host, vs_napot_pte ^ (1 << 10))
            state.gpr[1] = guest_virtual
            pc = execute("vs-napot-invalid-encoding", HLV_W)
            check("vs-napot-invalid-encoding",
                  [state.pc[0], state.mcause[0], state.mtval[0]],
                  [0x80FF0000, 13, guest_virtual])
            write_pte(vs_leaf_host, vs_napot_pte)
            write_pte(leaf, g_napot_pte ^ (1 << 10))
            pc = execute("g-napot-invalid-encoding", HLV_W)
            check("g-napot-invalid-encoding",
                  [state.pc[0], state.mcause[0], state.mtval[0], read_csr(MTVAL2)[0]],
                  [0x80FF0000, 21, guest_virtual, guest >> 2])
        for page in range(16):
            write_pte(vs_leaf_host + page * 8, 0)
            write_pte(leaf + page * 8, 0)
        write_pte(vs_leaf_host, (guest >> 12) << 10 | 0xD7)
        write_pte(leaf, (second >> 12) << 10 | 0xDF)
        state.gpr[1] = guest_virtual
        saved_mstatus = state.mstatus[0]
        state.mstatus[0] = ((saved_mstatus & ~((3 << 11) | (1 << 17) | (1 << 39))) |
                            (1 << 17) | (1 << 39))
        pc = execute("mprv-mpv-vu-load", 0x0000A183)
        check("mprv-mpv-vu-load", [state.pc[0], state.gpr[3]],
              [pc + 4, 0x13572468])
        state.gpr[2] = 0x24681357
        pc = execute("mprv-mpv-vu-store", 0x0020A023)
        check("mprv-mpv-vu-store", [state.pc[0],
                                    int.from_bytes(reference.read(second, 4), "little")],
              [pc + 4, 0x24681357])
        write_csr(VSSTATUS, 1 << 18)
        state.mstatus[0] = ((saved_mstatus & ~((3 << 11) | (1 << 17) | (1 << 39))) |
                            (1 << 17) | (1 << 39) | (1 << 11))
        pc = execute("mprv-mpv-vs-load", 0x0000A183)
        check("mprv-mpv-vs-load", [state.pc[0], state.gpr[3]],
              [pc + 4, 0x24681357])
        write_csr(VSSTATUS, 0)
        pc = execute("mprv-hlv-overrides-mpp", HLV_W)
        check("mprv-hlv-overrides-mpp", [state.pc[0], state.gpr[3]],
              [pc + 4, 0x24681357])
        state.mstatus[0] = ((saved_mstatus & ~((3 << 11) | (1 << 17) | (1 << 39))) |
                            (1 << 17) | (1 << 39))
        pc = execute("mprv-mpv-machine-breakpoint", 0x00100073)
        check("mprv-mpv-machine-breakpoint",
              [state.pc[0], state.mcause[0], state.mtval[0],
               state.mstatus[0] & (1 << 38)],
              [0x80FF0000, 3, pc, 0])
        state.mstatus[0] = ((saved_mstatus & ~((3 << 11) | (1 << 17) | (1 << 39))) |
                            (1 << 17) | (1 << 39))
        state.gpr[1] = guest_virtual + 0x2000
        pc = execute("mprv-mpv-guest-fault", 0x0000A183)
        check("mprv-mpv-guest-fault", [state.pc[0], state.mcause[0], state.mtval[0],
                                       state.mstatus[0] & (1 << 38)],
              [0x80FF0000, 13, guest_virtual + 0x2000, 1 << 38])
        write_pte(leaf, 0)
        state.mstatus[0] = ((saved_mstatus & ~((3 << 11) | (1 << 17) | (1 << 39))) |
                            (1 << 17) | (1 << 39))
        state.gpr[1] = guest_virtual
        execute("mprv-mpv-gstage-fault", 0x0000A183)
        fault = [state.pc[0], state.mcause[0], state.mtval[0],
                 state.mstatus[0] & (1 << 38)]
        check("mprv-mpv-gstage-fault", fault + [read_csr(MTVAL2)[0]],
              [0x80FF0000, 21, guest_virtual, 1 << 38, guest >> 2])
        write_pte(leaf, (second >> 12) << 10 | 0xDF)
        state.mstatus[0] = ((saved_mstatus & ~((3 << 11) | (1 << 17) | (1 << 39))) |
                            (1 << 17))
        state.gpr[1] = guest_virtual
        pc = execute("mprv-without-mpv-host-fault", 0x0000A183)
        check("mprv-without-mpv-host-fault",
              [state.pc[0], state.mcause[0], state.mtval[0],
               state.mstatus[0] & (1 << 38)],
              [0x80FF0000, 5, guest_virtual, 0])
        state.mstatus[0] = saved_mstatus
        write_csr(VSSTATUS, 0)
        reference.write(second, (0x13572468).to_bytes(4, "little"))
        state.gpr[1] = guest_virtual
        state.gpr[2] = 0x13572468
        write_pte(vs_leaf_host + 8, ((guest + 0x1000) >> 12) << 10 | 0xD7)
        write_pte(leaf + 8, (third >> 12) << 10 | 0xDF)
        reference.write(second + 0xFFE, b"\x11\x22")
        reference.write(third, b"\x33\x44")
        state.gpr[1] = guest_virtual + 0xFFE
        pc = execute("two-stage-hlv-cross-page", HLV_W)
        check("two-stage-hlv-cross-page", [state.pc[0], state.gpr[3]],
              [pc + 4, 0x44332211])
        pc = execute("two-stage-hsv-cross-page", HSV_W)
        check("two-stage-hsv-cross-page",
              [state.pc[0], reference.read(second + 0xFFE, 2).hex(),
               reference.read(third, 2).hex()], [pc + 4, "6824", "5713"])
        write_pte(vs_leaf_host + 8, 0)
        reference.write(second + 0xFFE, b"\x11\x22")
        pc = execute("two-stage-hsv-cross-page-vs-fault", HSV_W)
        check("two-stage-hsv-cross-page-vs-fault",
              [state.pc[0], state.mcause[0], state.mtval[0],
               reference.read(second + 0xFFE, 2).hex()],
              [0x80FF0000, 15, guest_virtual + 0x1000, "1122"])
        write_pte(leaf + 8, 0)
        state.gpr[1] = guest_virtual
        pbmte = 1 << 62
        write_csr(HENVCFG, pbmte)
        check("henvcfg-pbmte-machine-disabled", read_csr(HENVCFG)[0] & pbmte, 0)
        write_csr(MENVCFG, pbmte)
        write_csr(HENVCFG, pbmte)
        check("henvcfg-pbmte-enabled", read_csr(HENVCFG)[0] & pbmte, pbmte)
        for pbmt in (1, 2):
            write_pte(vs_leaf_host, (pbmt << 61) | (guest >> 12) << 10 | 0xD7)
            pc = execute(f"vs-pbmt-{pbmt}", HLV_W)
            check(f"vs-pbmt-{pbmt}", [state.pc[0], state.gpr[3]],
                  [pc + 4, 0x13572468])
        write_csr(HENVCFG, 0)
        pc = execute("vs-pbmt-guest-disabled", HLV_W)
        check("vs-pbmt-guest-disabled", [state.pc[0], state.mcause[0], state.mtval[0]],
              [0x80FF0000, 13, guest_virtual])
        write_csr(HENVCFG, pbmte)
        write_pte(vs_leaf_host, (3 << 61) | (guest >> 12) << 10 | 0xD7)
        pc = execute("vs-pbmt-reserved", HLV_W)
        check("vs-pbmt-reserved", [state.pc[0], state.mcause[0]], [0x80FF0000, 13])
        write_pte(vs_leaf_host, (guest >> 12) << 10 | 0xD7)
        root_entry = (vs_middle_guest >> 12) << 10 | 1
        write_pte(vs_root_host + 8, (1 << 61) | root_entry)
        pc = execute("vs-pbmt-nonleaf", HLV_W)
        check("vs-pbmt-nonleaf", [state.pc[0], state.mcause[0]], [0x80FF0000, 13])
        write_pte(vs_root_host + 8, root_entry)
        write_csr(MENVCFG, 0)
        check("henvcfg-pbmte-machine-revoked", read_csr(HENVCFG)[0] & pbmte, 0)
        write_pte(vs_leaf_host, (1 << 61) | (guest >> 12) << 10 | 0xD7)
        pc = execute("vs-pbmt-machine-disabled", HLV_W)
        check("vs-pbmt-machine-disabled", [state.pc[0], state.mcause[0]],
              [0x80FF0000, 13])
        write_pte(vs_leaf_host, (guest >> 12) << 10 | 0xD7)
        write_csr(MENVCFG, pbmte)
        write_csr(HENVCFG, pbmte)
        state.gpr[1] = guest_virtual + 1
        for vs_type, g_type, cause in ((0, 2, 5), (1, 2, 4), (2, 1, 5)):
            write_pte(vs_leaf_host, (vs_type << 61) | (guest >> 12) << 10 | 0xD7)
            write_pte(leaf, (g_type << 61) | (second >> 12) << 10 | 0xDF)
            pc = execute(f"pbmt-combine-vs{vs_type}-g{g_type}", HLV_W)
            check(f"pbmt-combine-vs{vs_type}-g{g_type}",
                  [state.pc[0], state.mcause[0], state.mtval[0]],
                  [0x80FF0000, cause, guest_virtual + 1])
        state.gpr[1] = guest_virtual
        write_pte(vs_leaf_host, (guest >> 12) << 10 | 0xD7)
        write_pte(leaf, (0x02000000 >> 12) << 10 | 0xDF)
        pc = execute("two-stage-mmio-hlv", HLV_W)
        check("two-stage-mmio-hlv", [state.pc[0], state.gpr[3]], [pc + 4, 0])
        write_pte(vs_leaf_host, (guest >> 12) << 10 | 0xDF)
        pc = execute("two-stage-mmio-hlvx", HLVX_WU)
        check("two-stage-mmio-hlvx", [state.pc[0], state.mcause[0]],
              [0x80FF0000, 5])
        write_pte(vs_leaf_host, (guest >> 12) << 10 | 0xD7)
        write_pte(leaf, (second >> 12) << 10 | 0xDF)
        write_csr(HENVCFG, 0)
        write_csr(MENVCFG, 0)
        if args.pointer_mask:
            tagged = (0x55 << 57) | guest_virtual
            state.gpr[1] = tagged
            write_csr(SENVCFG, 2 << 32)
            pc = execute("pmm-vu-hlv-s", HLV_W, 1)
            check("pmm-vu-hlv-s", [state.pc[0], state.gpr[3]],
                  [pc + 4, 0x13572468])
            state.gpr[2] = 0x24681357
            pc = execute("pmm-vu-hsv-s", HSV_W, 1)
            check("pmm-vu-hsv-s", [state.pc[0],
                                    int.from_bytes(reference.read(second, 4), "little")],
                  [pc + 4, 0x24681357])
            reference.write(second, (0x13572468).to_bytes(4, "little"))
            saved_mstatus = state.mstatus[0]
            state.mstatus[0] = ((saved_mstatus & ~((3 << 11) | (1 << 17) | (1 << 39))) |
                                (1 << 17) | (1 << 39))
            pc = execute("pmm-mprv-vu-load", 0x0000A183)
            check("pmm-mprv-vu-load", [state.pc[0], state.gpr[3]],
                  [pc + 4, 0x13572468])
            state.mstatus[0] = saved_mstatus
            write_csr(SENVCFG, 0)
            write_csr(HSTATUS, (1 << 8))
            write_csr(VSSTATUS, 1 << 18)
            write_csr(HENVCFG, 2 << 32)
            saved_mstatus = state.mstatus[0]
            state.mstatus[0] = ((saved_mstatus & ~((3 << 11) | (1 << 17) | (1 << 39))) |
                                (1 << 17) | (1 << 39) | (1 << 11))
            pc = execute("pmm-mprv-vs-load", 0x0000A183)
            check("pmm-mprv-vs-load", [state.pc[0], state.gpr[3]],
                  [pc + 4, 0x13572468])
            state.mstatus[0] = saved_mstatus
            pc = execute("pmm-vs-hlv", HLV_W, 1)
            check("pmm-vs-hlv", [state.pc[0], state.gpr[3]], [pc + 4, 0x13572468])
            state.gpr[1] = tagged + 0x1000
            pc = execute("pmm-vs-fault-address", HLV_W, 1)
            check("pmm-vs-fault-address",
                  [state.pc[0], state.mcause[0], state.mtval[0]],
                  [0x80FF0000, 13, guest_virtual + 0x1000])
            state.gpr[1] = tagged
            write_csr(HENVCFG, 0)
            write_csr(SENVCFG, 2 << 32)
            pc = execute("pmm-vs-ignores-senvcfg", HLV_W, 1)
            check("pmm-vs-ignores-senvcfg", [state.pc[0], state.mcause[0], state.mtval[0]],
                  [0x80FF0000, 13, tagged])
            write_csr(HENVCFG, 3 << 32)
            state.gpr[1] = (0xABCD << 48) | guest_virtual
            pc = execute("pmm-vs-pmlen16", HLV_W, 1)
            check("pmm-vs-pmlen16", [state.pc[0], state.gpr[3]],
                  [pc + 4, 0x13572468])
            state.gpr[1] = tagged
            pc = execute("pmm-hlvx-exempt", HLVX_WU, 1)
            check("pmm-hlvx-exempt", [state.pc[0], state.mcause[0], state.mtval[0]],
                  [0x80FF0000, 13, tagged])
            state.mstatus[0] |= 1 << 19
            pc = execute("pmm-mxr-exempt", HLV_W, 1)
            check("pmm-mxr-exempt", [state.pc[0], state.mcause[0], state.mtval[0]],
                  [0x80FF0000, 13, tagged])
            state.mstatus[0] &= ~(1 << 19)
            write_csr(HSTATUS, (2 << 48) | (1 << 9))
            write_csr(SENVCFG, 0)
            pc = execute("pmm-vu-hupmm-u", HLV_W, 0)
            check("pmm-vu-hupmm-u", [state.pc[0], state.gpr[3]],
                  [pc + 4, 0x13572468])
            write_csr(HSTATUS, 1 << 9)
            write_csr(SENVCFG, 2 << 32)
            pc = execute("pmm-vu-ignores-senvcfg-u", HLV_W, 0)
            check("pmm-vu-ignores-senvcfg-u",
                  [state.pc[0], state.mcause[0], state.mtval[0]],
                  [0x80FF0000, 13, tagged])
            write_csr(SENVCFG, 0)
            write_csr(HENVCFG, 0)
            write_csr(HSTATUS, 0)
            write_csr(VSSTATUS, 0)
            state.gpr[1] = guest_virtual
        write_pte(vs_leaf_host, (guest >> 12) << 10 | 0xD9)
        pc = execute("two-stage-hlvx", HLVX_WU)
        check("two-stage-hlvx", [state.pc[0], state.gpr[3]], [pc + 4, 0x13572468])
        write_pte(leaf, (second >> 12) << 10 | 0xD7)
        pc = execute("two-stage-hlvx-g-stage-no-execute", HLVX_WU)
        check("two-stage-hlvx-g-stage-no-execute",
              [state.pc[0], state.mcause[0], state.mtval[0], read_csr(MTVAL2)[0]],
              [0x80FF0000, 21, guest_virtual, guest >> 2])
        write_pte(leaf, (second >> 12) << 10 | 0xD9)
        pc = execute("two-stage-hlvx-both-execute-only", HLVX_WU)
        check("two-stage-hlvx-both-execute-only", [state.pc[0], state.gpr[3]],
              [pc + 4, 0x13572468])
        write_pte(leaf, (second >> 12) << 10 | 0xDF)
        pc = execute("vs-execute-only-fault", HLV_W)
        check("vs-execute-only-fault", [state.pc[0], state.mcause[0],
                                        state.mtval[0], read_csr(MTVAL2)[0]],
              [0x80FF0000, 13, guest_virtual, 0])
        write_pte(vs_leaf_host, (guest >> 12) << 10 | 0xD7)

        write_csr(HSTATUS, 1 << 8)
        pc = execute("spvp-supervisor-user-page", HLV_W)
        check("spvp-supervisor-user-page", [state.pc[0], state.mcause[0]],
              [0x80FF0000, 13])
        write_csr(VSSTATUS, 1 << 18)
        pc = execute("spvp-sum-load", HLV_W)
        check("spvp-sum-load", [state.pc[0], state.gpr[3]], [pc + 4, 0x13572468])
        write_pte(vs_leaf_host, (guest >> 12) << 10 | 0xC7)
        write_csr(VSSTATUS, 0)
        pc = execute("spvp-supervisor-page", HLV_W)
        check("spvp-supervisor-page", [state.pc[0], state.gpr[3]],
              [pc + 4, 0x13572468])
        write_pte(vs_leaf_host, (guest >> 12) << 10 | 0xD9)
        write_csr(HSTATUS, 0)
        write_csr(VSSTATUS, 1 << 19)
        pc = execute("vs-mxr-execute-only", HLV_W)
        check("vs-mxr-execute-only", [state.pc[0], state.gpr[3]],
              [pc + 4, 0x13572468])
        write_csr(VSSTATUS, 0)
        write_pte(vs_leaf_host, (guest >> 12) << 10 | 0xD7)

        write_pte(leaf, (second >> 12) << 10 | 0xD9)
        write_csr(VSSTATUS, 1 << 19)
        pc = execute("vs-mxr-does-not-override-g-stage", HLV_W)
        check("vs-mxr-does-not-override-g-stage",
              [state.pc[0], state.mcause[0], state.mtval[0], read_csr(MTVAL2)[0]],
              [0x80FF0000, 21, guest_virtual, guest >> 2])
        state.mstatus[0] |= 1 << 19
        pc = execute("hs-mxr-overrides-g-stage", HLV_W)
        check("hs-mxr-overrides-g-stage", [state.pc[0], state.gpr[3]],
              [pc + 4, 0x13572468])
        write_pte(middle + ((vs_root_guest >> 21) & 0x1FF) * 8,
                  (vs_root_host >> 12) << 10 | 0xD9)
        pc = execute("hs-mxr-does-not-override-implicit-ptw", HLV_W)
        check("hs-mxr-does-not-override-implicit-ptw",
              [state.pc[0], state.mcause[0], state.mtval[0],
               read_csr(MTVAL2)[0], read_csr(MTINST)[0]],
              [0x80FF0000, 21, guest_virtual, (vs_root_guest + 8) >> 2, 0x3000])
        state.mstatus[0] &= ~(1 << 19)
        write_csr(VSSTATUS, 0)
        write_pte(middle + ((vs_root_guest >> 21) & 0x1FF) * 8,
                  (vs_root_host >> 12) << 10 | 0xDF)
        write_pte(leaf, (second >> 12) << 10 | 0xDF)

        write_pte(vs_leaf_host, 0)
        pc = execute("vs-page-fault", HLV_W)
        check("vs-page-fault", [state.pc[0], state.mcause[0], state.mtval[0]],
              [0x80FF0000, 13, guest_virtual])
        write_pte(vs_leaf_host, (guest >> 12) << 10 | 0xD7)
        write_pte(middle + ((vs_root_guest >> 21) & 0x1FF) * 8, 0)
        pc = execute("vs-ptw-guest-fault", HLV_W)
        check("vs-ptw-guest-fault", [state.pc[0], state.mcause[0], state.mtval[0],
                                     read_csr(MTVAL2)[0], read_csr(MTINST)[0]],
              [0x80FF0000, 21, guest_virtual, (vs_root_guest + 8) >> 2, 0x3000])
        state.medeleg[0] = 1 << 21
        pc = execute("vs-ptw-delegated-fault", HLV_W, 1)
        check("vs-ptw-delegated-fault",
              [state.pc[0], state.scause[0], state.stval[0], read_csr(HTVAL)[0],
               read_csr(HTINST)[0], read_csr(HSTATUS)[0] & (1 << 6)],
              [0x80FE0000, 21, guest_virtual, (vs_root_guest + 8) >> 2,
               0x3000, 1 << 6])
        state.medeleg[0] = 0
        write_pte(middle + ((vs_root_guest >> 21) & 0x1FF) * 8,
                  (vs_root_host >> 12) << 10 | 0xDF)
        write_pte(leaf, 0)
        pc = execute("two-stage-data-guest-fault", HLV_W)
        check("two-stage-data-guest-fault", [state.pc[0], state.mcause[0],
                                              read_csr(MTVAL2)[0], read_csr(MTINST)[0]],
              [0x80FF0000, 21, guest >> 2, 0])
        write_pte(leaf, (second >> 12) << 10 | 0xDF)

        write_csr(HSTATUS, 1 << 9)
        pc = execute("hu-u-mode-load", HLV_W, 0)
        check("hu-u-mode-load", [state.pc[0], state.gpr[3]], [pc + 4, 0x13572468])
        write_csr(HSTATUS, 0)
        pc = execute("hu-disabled-illegal", HLV_W, 0)
        check("hu-disabled-illegal", [state.pc[0], state.mcause[0]],
              [0x80FF0000, 2])
        write_csr(VSATP, 0)
        state.gpr[1] = guest

        state.mstatus[0] |= 1 << 20
        pc = write_csr(HGATP, 0, 1)
        check("tvm-hgatp", [state.mcause[0], state.mepc[0]], [2, pc])
        pc = execute("tvm-hfence", HFENCE_GVMA, 1)
        check("tvm-hfence", [state.mcause[0], state.mepc[0]], [2, pc])
        for name, opcode in (("hfence", HFENCE_VVMA), ("hinval", HINVAL_VVMA)):
            pc = execute(f"tvm-{name}-vvma", opcode, 1)
            check(f"tvm-{name}-vvma", state.pc[0], pc + 4)
        pc = execute("u-hlv", HLV_W, 0)
        check("u-hlv", [state.mcause[0], state.mepc[0]], [2, pc])

        write_pte(vs_leaf_host, (guest >> 12) << 10 | 0xDF)
        write_pte(leaf, (second >> 12) << 10 | 0xDF)
        reference.write(second, (0x0080A183).to_bytes(4, "little") +
                        (0x00000073).to_bytes(4, "little") +
                        (0x24681357).to_bytes(4, "little"))
        write_csr(HGATP, (8 << 60) | (root >> 12))
        write_csr(VSATP, (8 << 60) | (vs_root_guest >> 12))
        state.medeleg[0] = 0
        state.mstatus[0] &= ~((3 << 11) | (1 << 20))
        state.mstatus[0] |= 1 << 39
        state.mepc[0] = guest_virtual
        state.gpr[1] = guest_virtual
        execute("mret-enter-vu", 0x30200073)
        check("mret-enter-vu", [state.pc[0], state.priv[0][0]],
              [guest_virtual, 0])
        reference.lib.difftest_exec(1)
        check("vu-two-stage-fetch-load", [state.pc[0], state.gpr[3]],
              [guest_virtual + 4, 0x24681357])
        reference.lib.difftest_exec(1)
        check("vu-ecall-to-m", [state.pc[0], state.mcause[0], state.mepc[0],
                                state.mstatus[0] & (1 << 39)],
              [0x80FF0000, 8, guest_virtual + 4, 1 << 39])

        state.mepc[0] = guest_virtual + 0x1000
        execute("mret-enter-vu-unmapped", 0x30200073)
        reference.lib.difftest_exec(1)
        check("vu-vs-fetch-page-fault", [state.pc[0], state.mcause[0],
                                          state.mtval[0],
                                          state.mstatus[0] & (3 << 38)],
              [0x80FF0000, 12, guest_virtual + 0x1000, 3 << 38])

        write_pte(leaf, 0)
        state.mepc[0] = guest_virtual
        execute("mret-enter-vu-gfault", 0x30200073)
        reference.lib.difftest_exec(1)
        check("vu-g-fetch-page-fault", [state.pc[0], state.mcause[0],
                                         state.mtval[0], read_csr(MTVAL2)[0]],
              [0x80FF0000, 20, guest_virtual, guest >> 2])

        write_pte(leaf, (second >> 12) << 10 | 0xDF)
        write_pte(vs_leaf_host, (guest >> 12) << 10 | 0xCF)
        vs_program = [
            (SSTATUS << 20) | (4 << 15) | (1 << 12) | (3 << 7) | 0x73,
            (SSTATUS << 20) | (2 << 12) | (5 << 7) | 0x73,
            0x10200073,
        ]
        reference.write(second, b"".join(opcode.to_bytes(4, "little")
                                           for opcode in vs_program))
        write_csr(VSSTATUS, 0)
        check("vsstatus-uxl", read_csr(VSSTATUS)[0] & (3 << 32), 2 << 32)
        write_csr(VSEPC, guest_virtual + 0x20)
        check("vsepc-write", read_csr(VSEPC)[0], guest_virtual + 0x20)
        host_sstatus = state.sstatus[0]
        state.gpr[4] = (1 << 18) | (1 << 1)
        state.mstatus[0] &= ~((3 << 11) | (1 << 20))
        state.mstatus[0] |= (1 << 39) | (1 << 11)
        state.mepc[0] = guest_virtual
        execute("mret-enter-vs", 0x30200073)
        reference.lib.difftest_exec(2)
        check("vs-sstatus-alias", [state.pc[0], state.gpr[3], state.gpr[5],
                                   state.sstatus[0]],
              [guest_virtual + 8, 2 << 32,
               (2 << 32) | (1 << 18) | (1 << 1), host_sstatus])
        reference.lib.difftest_exec(1)
        check("vs-sret-to-vu", [state.pc[0], state.priv[0][0]],
              [guest_virtual + 0x20, 0])
        reference.lib.difftest_exec(1)
        check("vu-supervisor-page-fault", [state.pc[0], state.mcause[0],
                                            state.mtval[0]],
              [0x80FF0000, 12, guest_virtual + 0x20])

        hstatus_read = (HSTATUS << 20) | (2 << 12) | (6 << 7) | 0x73
        reference.write(second, hstatus_read.to_bytes(4, "little"))
        state.mstatus[0] &= ~(3 << 11)
        state.mstatus[0] |= (1 << 39) | (1 << 11)
        state.mepc[0] = guest_virtual
        execute("mret-enter-vs-hcsr", 0x30200073)
        reference.lib.difftest_exec(1)
        check("vs-hcsr-virtual-instruction", [state.pc[0], state.mcause[0],
                                               state.mtval[0]],
              [0x80FF0000, 22, hstatus_read])

        state.medeleg[0] = 1 << 12
        state.mstatus[0] &= ~(3 << 11)
        state.mstatus[0] |= (1 << 39) | (1 << 11)
        state.mepc[0] = guest_virtual + 0x1000
        execute("mret-enter-vs-delegated", 0x30200073)
        reference.lib.difftest_exec(1)
        hstatus, _ = read_csr(HSTATUS, 1)
        check("vs-fault-delegated-hs", [state.scause[0], state.stval[0],
                                        hstatus & (3 << 7)],
              [12, guest_virtual + 0x1000, 3 << 7])
        reference.write(second, (0x00700313).to_bytes(4, "little"))
        state.sepc[0] = guest_virtual
        execute("hs-sret-enter-vs", 0x10200073, 1)
        check("hs-sret-enter-vs", [state.pc[0], state.priv[0][0]],
              [guest_virtual, 1])
        reference.lib.difftest_exec(1)
        check("hs-sret-vs-fetch", [state.pc[0], state.gpr[6]],
              [guest_virtual + 4, 7])

        reference.write(second + 4, (0x00000073).to_bytes(4, "little"))
        reference.lib.difftest_exec(1)
        check("vs-ecall-to-m", [state.pc[0], state.mcause[0], state.mepc[0]],
              [0x80FF0000, 10, guest_virtual + 4])

        time_read = (TIME << 20) | (2 << 12) | (12 << 7) | 0x73
        reference.write(second, time_read.to_bytes(4, "little") +
                        (0x00000073).to_bytes(4, "little"))
        write_csr(MCOUNTEREN, 2)
        write_csr(HCOUNTEREN, 2)
        write_csr(HTIMEDELTA, 7)
        state.time[0] = 100
        state.mstatus[0] &= ~(3 << 11)
        state.mstatus[0] |= (1 << 39) | (1 << 11)
        state.mepc[0] = guest_virtual
        execute("mret-enter-vs-time", 0x30200073)
        reference.lib.difftest_exec(1)
        check("vs-time-offset", [state.pc[0], state.gpr[12]],
              [guest_virtual + 4, 107])
        reference.lib.difftest_exec(1)
        write_csr(HCOUNTEREN, 0)
        state.mstatus[0] &= ~(3 << 11)
        state.mstatus[0] |= (1 << 39) | (1 << 11)
        state.mepc[0] = guest_virtual
        execute("mret-enter-vs-time-gated", 0x30200073)
        reference.lib.difftest_exec(1)
        check("vs-time-virtual-instruction", [state.pc[0], state.mcause[0]],
              [0x80FF0000, 22])

        stimecmp_read = (0x14D << 20) | (2 << 12) | (12 << 7) | 0x73
        reference.write(second, stimecmp_read.to_bytes(4, "little") +
                        (0x00000073).to_bytes(4, "little"))
        write_csr(MENVCFG, 1 << 63)
        write_csr(HENVCFG, 1 << 63)
        write_csr(HCOUNTEREN, 2)
        write_csr(VSTIMECMP, 0x12345)
        state.mstatus[0] &= ~(3 << 11)
        state.mstatus[0] |= (1 << 39) | (1 << 11)
        state.mepc[0] = guest_virtual
        execute("mret-enter-vs-vstimecmp", 0x30200073)
        reference.lib.difftest_exec(1)
        check("vs-stimecmp-alias", [state.pc[0], state.gpr[12]],
              [guest_virtual + 4, 0x12345])
        reference.lib.difftest_exec(1)
        write_csr(HENVCFG, 0)
        state.mstatus[0] &= ~(3 << 11)
        state.mstatus[0] |= (1 << 39) | (1 << 11)
        state.mepc[0] = guest_virtual
        execute("mret-enter-vs-vstimecmp-gated", 0x30200073)
        reference.lib.difftest_exec(1)
        check("vs-stimecmp-virtual-instruction", [state.pc[0], state.mcause[0]],
              [0x80FF0000, 22])
        write_csr(MENVCFG, 0)
        write_csr(HCOUNTEREN, 0)
        write_csr(HTIMEDELTA, 0)
        write_csr(VSTIMECMP, reference.mask)
        state.time[0] = 0

        for name, control, opcode in (
            ("vtsr-sret", 1 << 22, 0x10200073),
            ("vtw-wfi", 1 << 21, 0x10500073),
            ("vtvm-sfence", 1 << 20, 0x12000073),
            ("vtvm-sinval", 1 << 20, 0x16000073),
            ("vtvm-satp-read", 1 << 20,
             (0x180 << 20) | (2 << 12) | (12 << 7) | 0x73),
            ("vtvm-satp-write", 1 << 20,
             (0x180 << 20) | (4 << 15) | (1 << 12) | 0x73),
        ):
            write_csr(HSTATUS, control)
            reference.write(second, opcode.to_bytes(4, "little"))
            state.mstatus[0] &= ~((3 << 11) | (7 << 20))
            state.mstatus[0] |= (1 << 39) | (1 << 11)
            state.mepc[0] = guest_virtual
            execute(f"mret-enter-vs-{name}", 0x30200073)
            reference.lib.difftest_exec(1)
            check(name, [state.pc[0], state.mcause[0], state.mtval[0],
                         state.mepc[0]],
                  [0x80FF0000, 22, opcode, guest_virtual])

        write_csr(HSTATUS, 0)
        reference.write(second, (0x12000073).to_bytes(4, "little") +
                        (0x00000073).to_bytes(4, "little"))
        state.mstatus[0] &= ~((3 << 11) | (7 << 20))
        state.mstatus[0] |= (1 << 39) | (1 << 11) | (1 << 20)
        state.mepc[0] = guest_virtual
        execute("mret-enter-vs-ignore-mstatus-tvm", 0x30200073)
        reference.lib.difftest_exec(1)
        check("vs-ignore-mstatus-tvm", [state.pc[0], state.priv[0][0]],
              [guest_virtual + 4, 1])
        reference.lib.difftest_exec(1)
        state.mstatus[0] &= ~(1 << 20)

        write_pte(vs_leaf_host, (guest >> 12) << 10 | 0xDF)
        for name, opcode, cause in (
            ("vu-sstatus", (SSTATUS << 20) | (2 << 12) | (12 << 7) | 0x73, 22),
            ("vu-satp", (0x180 << 20) | (2 << 12) | (12 << 7) | 0x73, 22),
            ("vu-vsstatus-direct", (VSSTATUS << 20) | (2 << 12) | (12 << 7) | 0x73, 22),
            ("vu-hstatus-direct", (HSTATUS << 20) | (2 << 12) | (12 << 7) | 0x73, 22),
            ("vu-vs-csr-unimplemented", (0x206 << 20) | (2 << 12) | (12 << 7) | 0x73, 2),
            ("vu-sfence", 0x12000073, 22),
            ("vu-sret", 0x10200073, 22),
            ("vu-wfi", 0x10500073, 22),
        ):
            reference.write(second, opcode.to_bytes(4, "little"))
            state.mstatus[0] &= ~((3 << 11) | (7 << 20))
            state.mstatus[0] |= 1 << 39
            state.mepc[0] = guest_virtual
            execute(f"mret-enter-{name}", 0x30200073)
            reference.lib.difftest_exec(1)
            check(f"{name}-exception",
                  [state.pc[0], state.mcause[0], state.mtval[0]],
                  [0x80FF0000, cause, opcode])
        write_pte(vs_leaf_host, (guest >> 12) << 10 | 0xCF)
        for name, csr, cause in (
            ("vs-vsstatus-direct", VSSTATUS, 22),
            ("vs-hstatus-direct", HSTATUS, 22),
            ("vs-vs-csr-unimplemented", 0x206, 2),
        ):
            opcode = (csr << 20) | (2 << 12) | (12 << 7) | 0x73
            reference.write(second, opcode.to_bytes(4, "little"))
            state.mstatus[0] &= ~((3 << 11) | (7 << 20))
            state.mstatus[0] |= (1 << 39) | (1 << 11)
            state.mepc[0] = guest_virtual
            execute(f"mret-enter-{name}", 0x30200073)
            reference.lib.difftest_exec(1)
            check(f"{name}-exception",
                  [state.pc[0], state.mcause[0], state.mtval[0]],
                  [0x80FF0000, cause, opcode])
        opcode = (VSSTATUS << 20) | (2 << 12) | (12 << 7) | 0x73
        pc = execute("u-vsstatus-direct", opcode, 0)
        check("u-vsstatus-direct-illegal",
              [state.pc[0], state.mcause[0], state.mepc[0]],
              [0x80FF0000, 2, pc])

        write_csr(HEDELEG, reference.mask)
        check("hedeleg-warl", read_csr(HEDELEG)[0], 0xCB1FE)
        write_csr(HEDELEG, 1 << 2)
        state.medeleg[0] = 0
        handler_guest = guest + 0x1000
        handler_host = second + 0x1000
        handler_virtual = guest_virtual + 0x1000
        write_pte(vs_leaf_host, (guest >> 12) << 10 | 0xDF)
        write_pte(vs_leaf_host + 8, (handler_guest >> 12) << 10 | 0xCF)
        write_pte(leaf + 8, (handler_host >> 12) << 10 | 0xDF)
        write_csr(VSTVEC, handler_virtual)
        write_csr(VSSTATUS, 1 << 1)
        illegal_guest_instruction = 0xFFFFFFFF
        reference.write(second, illegal_guest_instruction.to_bytes(4, "little") +
                        (0x00B00593).to_bytes(4, "little") +
                        (0x00000073).to_bytes(4, "little"))
        handler = [
            (0x142 << 20) | (2 << 12) | (8 << 7) | 0x73,
            (0x141 << 20) | (2 << 12) | (9 << 7) | 0x73,
            (SSTATUS << 20) | (2 << 12) | (10 << 7) | 0x73,
            (0x143 << 20) | (2 << 12) | (13 << 7) | 0x73,
            0x00448493,
            (0x141 << 20) | (9 << 15) | (1 << 12) | 0x73,
            0x10200073,
        ]
        reference.write(handler_host, b"".join(opcode.to_bytes(4, "little")
                                               for opcode in handler))
        state.mstatus[0] &= ~(3 << 11)
        state.mstatus[0] |= 1 << 39
        state.mepc[0] = guest_virtual
        execute("mret-enter-vu-no-medeleg", 0x30200073)
        reference.lib.difftest_exec(1)
        check("hedeleg-needs-medeleg", [state.pc[0], state.mcause[0]],
              [0x80FF0000, 2])
        state.medeleg[0] = 1 << 2
        state.mstatus[0] &= ~(3 << 11)
        state.mstatus[0] |= 1 << 39
        state.mepc[0] = guest_virtual
        execute("mret-enter-vu-hedeleg", 0x30200073)
        reference.lib.difftest_exec(1)
        check("vu-illegal-delegated-vs", [state.pc[0], state.priv[0][0]],
              [handler_virtual, 1])
        reference.lib.difftest_exec(4)
        check("vs-trap-csrs", [state.pc[0], state.gpr[8], state.gpr[9],
                                state.gpr[10] & 0x122, state.gpr[13]],
              [handler_virtual + 16, 2, guest_virtual, 1 << 5,
               illegal_guest_instruction])
        reference.lib.difftest_exec(3)
        check("vs-handler-sret-to-vu", [state.pc[0], state.priv[0][0]],
              [guest_virtual + 4, 0])
        reference.lib.difftest_exec(2)
        check("vu-resumed-ecall-to-m", [state.pc[0], state.mcause[0],
                                         state.gpr[11]],
              [0x80FF0000, 8, 11])

        write_csr(HEDELEG, 1 << 3)
        state.medeleg[0] = 1 << 3
        reference.write(second, (0x00100073).to_bytes(4, "little"))
        state.mstatus[0] &= ~(3 << 11)
        state.mstatus[0] |= 1 << 39
        state.mepc[0] = guest_virtual
        execute("mret-enter-vu-breakpoint", 0x30200073)
        reference.lib.difftest_exec(1)
        check("vu-breakpoint-delegated-vs", [state.pc[0], state.priv[0][0]],
              [handler_virtual, 1])
        reference.lib.difftest_exec(4)
        check("vstval-breakpoint", [state.gpr[8], state.gpr[9], state.gpr[13]],
              [3, guest_virtual, guest_virtual])
        reference.lib.difftest_raise_intr(11)
        write_csr(MCAUSE, 0)

        saved_menvcfg = read_csr(MENVCFG)[0]
        saved_henvcfg = read_csr(HENVCFG)[0]
        write_csr(MENVCFG, saved_menvcfg | (1 << 62))
        write_csr(HENVCFG, saved_henvcfg | (1 << 62))
        write_pte(vs_leaf_host, (2 << 61) | (guest >> 12) << 10 | 0xDF)
        for name, opcode, cause in (("load", 0x00032383, 5),
                                    ("store", 0x00732023, 7)):
            write_csr(HEDELEG, 1 << cause)
            state.medeleg[0] = 1 << cause
            reference.write(second, opcode.to_bytes(4, "little"))
            state.gpr[6] = guest_virtual + 1
            state.mstatus[0] &= ~(3 << 11)
            state.mstatus[0] |= 1 << 39
            state.mepc[0] = guest_virtual
            execute(f"mret-enter-vu-pbmt-io-misaligned-{name}", 0x30200073)
            reference.lib.difftest_exec(1)
            check(f"vu-pbmt-io-misaligned-{name}-delegated-vs",
                  [state.pc[0], state.priv[0][0]], [handler_virtual, 1])
            reference.lib.difftest_exec(4)
            check(f"vstval-pbmt-io-misaligned-{name}",
                  [state.gpr[8], state.gpr[9], state.gpr[13]],
                  [cause, guest_virtual, guest_virtual + 1])
            reference.lib.difftest_raise_intr(11)
            write_csr(MCAUSE, 0)
        write_pte(vs_leaf_host, (guest >> 12) << 10 | 0xDF)
        write_csr(MENVCFG, saved_menvcfg)
        write_csr(HENVCFG, saved_henvcfg)

        fault_address = guest_virtual + 0x3000
        for name, opcode, cause in (("load", 0x00032383, 13),
                                    ("store", 0x00732023, 15)):
            write_csr(HEDELEG, 1 << cause)
            state.medeleg[0] = 1 << cause
            reference.write(second, opcode.to_bytes(4, "little"))
            state.gpr[6] = fault_address
            state.mstatus[0] &= ~(3 << 11)
            state.mstatus[0] |= 1 << 39
            state.mepc[0] = guest_virtual
            execute(f"mret-enter-vu-{name}-page-fault", 0x30200073)
            reference.lib.difftest_exec(1)
            check(f"vu-{name}-page-fault-delegated-vs", [state.pc[0], state.priv[0][0]],
                  [handler_virtual, 1])
            reference.lib.difftest_exec(4)
            check(f"vstval-{name}-page-fault", [state.gpr[8], state.gpr[9], state.gpr[13]],
                  [cause, guest_virtual, fault_address])
            reference.lib.difftest_raise_intr(11)
            write_csr(MCAUSE, 0)

        write_pte(vs_leaf_host + 24, ((guest + 0x3000) >> 12) << 10 | 0xDF)
        write_pte(leaf + 24, (0x40000000 >> 12) << 10 | 0xDF)
        for name, opcode, cause in (("load", 0x00032383, 5),
                                    ("store", 0x00732023, 7)):
            write_csr(HEDELEG, 1 << cause)
            state.medeleg[0] = 1 << cause
            reference.write(second, opcode.to_bytes(4, "little"))
            state.gpr[6] = fault_address
            state.mstatus[0] &= ~(3 << 11)
            state.mstatus[0] |= 1 << 39
            state.mepc[0] = guest_virtual
            execute(f"mret-enter-vu-{name}-access-fault", 0x30200073)
            reference.lib.difftest_exec(1)
            check(f"vu-{name}-access-fault-delegated-vs", [state.pc[0], state.priv[0][0]],
                  [handler_virtual, 1])
            reference.lib.difftest_exec(4)
            check(f"vstval-{name}-access-fault", [state.gpr[8], state.gpr[9], state.gpr[13]],
                  [cause, guest_virtual, fault_address])
            reference.lib.difftest_raise_intr(11)
            write_csr(MCAUSE, 0)
        write_pte(vs_leaf_host + 24, 0)
        write_pte(leaf + 24, 0)

        write_pte(leaf, (0x40000000 >> 12) << 10 | 0xDF)
        write_csr(HEDELEG, 1 << 1)
        state.medeleg[0] = 1 << 1
        state.mstatus[0] &= ~(3 << 11)
        state.mstatus[0] |= 1 << 39
        state.mepc[0] = guest_virtual
        execute("mret-enter-vu-fetch-access-fault", 0x30200073)
        reference.lib.difftest_exec(1)
        check("vu-fetch-access-fault-delegated-vs", [state.pc[0], state.priv[0][0]],
              [handler_virtual, 1])
        reference.lib.difftest_exec(4)
        check("vstval-fetch-access-fault", [state.gpr[8], state.gpr[9], state.gpr[13]],
              [1, guest_virtual, guest_virtual])
        reference.lib.difftest_raise_intr(11)
        write_csr(MCAUSE, 0)
        write_pte(leaf, (second >> 12) << 10 | 0xDF)

        write_csr(HEDELEG, 1 << 12)
        state.medeleg[0] = 1 << 12
        state.mstatus[0] &= ~(3 << 11)
        state.mstatus[0] |= 1 << 39
        state.mepc[0] = fault_address
        execute("mret-enter-vu-fetch-page-fault", 0x30200073)
        reference.lib.difftest_exec(1)
        check("vu-fetch-page-fault-delegated-vs", [state.pc[0], state.priv[0][0]],
              [handler_virtual, 1])
        reference.lib.difftest_exec(4)
        check("vstval-fetch-page-fault", [state.gpr[8], state.gpr[9], state.gpr[13]],
              [12, fault_address, fault_address])
        reference.lib.difftest_raise_intr(11)
        write_csr(MCAUSE, 0)

        reference.write(second, (0x00000073).to_bytes(4, "little"))
        write_csr(HSTATUS, (1 << 7) | (1 << 8))
        state.mstatus[0] &= ~(1 << 8)
        state.sepc[0] = guest_virtual
        execute("hs-sret-spp-over-spvp", 0x10200073, 1)
        check("hs-sret-spp-over-spvp", [state.pc[0], state.priv[0][0]],
              [guest_virtual, 0])
        reference.lib.difftest_exec(1)
        check("hs-sret-vu-ecall", [state.pc[0], state.mcause[0]],
              [0x80FF0000, 8])
        check("hs-sret-preserves-spvp-vu", read_csr(HSTATUS)[0] & (3 << 7),
              1 << 8)
        write_pte(vs_leaf_host, (guest >> 12) << 10 | 0xCF)
        write_csr(HSTATUS, 1 << 7)
        state.mstatus[0] |= 1 << 8
        state.sepc[0] = guest_virtual
        execute("hs-sret-spp-over-spvp-vs", 0x10200073, 1)
        check("hs-sret-spp-over-spvp-vs", [state.pc[0], state.priv[0][0]],
              [guest_virtual, 1])
        reference.lib.difftest_exec(1)
        check("hs-sret-vs-ecall", [state.pc[0], state.mcause[0]],
              [0x80FF0000, 10])
        check("hs-sret-preserves-spvp-vs", read_csr(HSTATUS)[0] & (3 << 7), 0)

        write_csr(HEDELEG, 1 << 8)
        state.medeleg[0] = 1 << 8
        write_pte(vs_leaf_host, (guest >> 12) << 10 | 0xDF)
        reference.write(second, (0x00000073).to_bytes(4, "little"))
        state.mstatus[0] &= ~(3 << 11)
        state.mstatus[0] |= 1 << 39
        state.mepc[0] = guest_virtual
        execute("mret-enter-vu-ecall-delegated", 0x30200073)
        reference.lib.difftest_exec(1)
        check("vu-ecall-delegated-vs", [state.pc[0], state.priv[0][0]],
              [handler_virtual, 1])
        reference.lib.difftest_exec(4)
        check("vu-ecall-vs-trap-csrs", [state.gpr[8], state.gpr[9], state.gpr[13]],
              [8, guest_virtual, 0])
        reference.lib.difftest_raise_intr(11)
        write_csr(MCAUSE, 0)

        write_csr(HEDELEG, 1 << 19)
        state.medeleg[0] = 1 << 19
        state.mstatus[0] &= ~(3 << 11)
        state.mstatus[0] |= 1 << 39
        state.mepc[0] = guest_virtual
        execute("mret-enter-vu-hardware-error", 0x30200073)
        reference.lib.difftest_raise_intr(19)
        check("vu-hardware-error-delegated-vs", [state.pc[0], state.priv[0][0]],
              [handler_virtual, 1])
        reference.lib.difftest_exec(4)
        check("vu-hardware-error-vs-trap-csrs",
              [state.gpr[8], state.gpr[9], state.gpr[13]],
              [19, guest_virtual, 0])
        reference.lib.difftest_raise_intr(11)
        write_csr(MCAUSE, 0)

        write_csr(HEDELEG, 0)
        state.medeleg[0] = 1 << 8
        state.mstatus[0] &= ~(3 << 11)
        state.mstatus[0] |= 1 << 39
        state.mepc[0] = guest_virtual
        execute("mret-enter-vu-ecall-host", 0x30200073)
        reference.lib.difftest_exec(1)
        hstatus, _ = read_csr(HSTATUS, 1)
        check("vu-ecall-hedeleg-disabled", [state.scause[0], state.sepc[0],
                                             hstatus & (3 << 7)],
              [8, guest_virtual, 1 << 7])

        execute("hs-ecall-to-m", 0x00000073, 1)
        state.medeleg[0] = 1 << 10
        write_pte(vs_leaf_host, (guest >> 12) << 10 | 0xCF)
        state.mstatus[0] &= ~(3 << 11)
        state.mstatus[0] |= (1 << 39) | (1 << 11)
        state.mepc[0] = guest_virtual
        execute("mret-enter-vs-ecall", 0x30200073)
        reference.lib.difftest_exec(1)
        check("vs-ecall-delegated-hs", [state.pc[0], state.scause[0],
                                        state.sepc[0]],
              [0x80FE0000, 10, guest_virtual])

        write_csr(HENVCFG, 0x20)
        check("henvcfg-cbie-reserved-normalized", read_csr(HENVCFG)[0] & 0xF0, 0x30)
        write_csr(HENVCFG, 0xF0)
        check("henvcfg-cmo-bits", read_csr(HENVCFG)[0] & 0xF0, 0xF0)
        state.medeleg[0] = 0
        state.mstatus[0] &= ~(1 << 19)
        write_csr(VSSTATUS, 0)
        write_pte(vs_leaf_host, (guest >> 12) << 10 | 0xDF)
        write_pte(leaf, (second >> 12) << 10 | 0xDF)
        reference.write(second, CBO_CLEAN.to_bytes(4, "little") +
                        (0x00000073).to_bytes(4, "little"))
        state.gpr[1] = guest_virtual

        def run_guest_cmo(name, supervisor=False):
            state.mstatus[0] &= ~(3 << 11)
            state.mstatus[0] |= (1 << 39) | ((1 << 11) if supervisor else 0)
            state.mepc[0] = guest_virtual
            execute(f"{name}-enter", 0x30200073)
            reference.lib.difftest_exec(1)

        reference.write(second, time_read.to_bytes(4, "little") +
                        (0x00000073).to_bytes(4, "little"))
        write_csr(MCOUNTEREN, 2)
        write_csr(HCOUNTEREN, 2)
        write_csr(SCOUNTEREN, 0)
        state.time[0] = 100
        run_guest_cmo("vu-time-scounteren-off")
        check("vu-time-scounteren-off", [state.pc[0], state.mcause[0],
                                          state.mtval[0]],
              [0x80FF0000, 22, time_read])
        write_csr(SCOUNTEREN, 2)
        run_guest_cmo("vu-time-enabled")
        check("vu-time-enabled", [state.pc[0], state.gpr[12]],
              [guest_virtual + 4, 100])
        reference.lib.difftest_exec(1)
        write_csr(HCOUNTEREN, 0)
        run_guest_cmo("vu-time-hcounteren-off")
        check("vu-time-hcounteren-off", [state.pc[0], state.mcause[0]],
              [0x80FF0000, 22])
        write_csr(HCOUNTEREN, 2)
        write_csr(MCOUNTEREN, 0)
        run_guest_cmo("vu-time-mcounteren-off")
        check("vu-time-mcounteren-off", [state.pc[0], state.mcause[0]],
              [0x80FF0000, 2])
        write_csr(MCOUNTEREN, 2)
        write_csr(SCOUNTEREN, 0)
        pc = execute("u-time-scounteren-off", time_read, 0)
        check("u-time-scounteren-off", [state.pc[0], state.mcause[0], state.mepc[0]],
              [0x80FF0000, 2, pc])
        write_csr(MCOUNTEREN, 0)
        write_csr(HCOUNTEREN, 0)
        write_csr(SCOUNTEREN, 0)
        state.time[0] = 0
        reference.write(second, CBO_CLEAN.to_bytes(4, "little") +
                        (0x00000073).to_bytes(4, "little"))

        write_csr(MENVCFG, 0x40)
        write_csr(SENVCFG, 0x40)
        write_csr(HENVCFG, 0)
        run_guest_cmo("vu-cmo-henvcfg-off")
        check("vu-cmo-henvcfg-off", [state.pc[0], state.mcause[0], state.mepc[0]],
              [0x80FF0000, 22, guest_virtual])
        write_csr(MENVCFG, 0)
        write_csr(HENVCFG, 0x40)
        run_guest_cmo("vu-cmo-menvcfg-off")
        check("vu-cmo-menvcfg-off", [state.pc[0], state.mcause[0], state.mepc[0]],
              [0x80FF0000, 2, guest_virtual])
        write_csr(MENVCFG, 0x40)
        write_csr(SENVCFG, 0)
        run_guest_cmo("vu-cmo-senvcfg-off")
        check("vu-cmo-senvcfg-off", [state.pc[0], state.mcause[0], state.mepc[0]],
              [0x80FF0000, 22, guest_virtual])
        write_csr(SENVCFG, 0x40)
        run_guest_cmo("vu-cmo-enabled")
        check("vu-cmo-enabled", state.pc[0], guest_virtual + 4)
        reference.lib.difftest_exec(1)
        check("vu-cmo-enabled-return", [state.pc[0], state.mcause[0]],
              [0x80FF0000, 8])

        write_pte(vs_leaf_host, (guest >> 12) << 10 | 0xCF)
        write_csr(SENVCFG, 0)
        write_csr(HENVCFG, 0)
        run_guest_cmo("vs-cmo-henvcfg-off", supervisor=True)
        check("vs-cmo-henvcfg-off", [state.pc[0], state.mcause[0], state.mepc[0]],
              [0x80FF0000, 22, guest_virtual])
        write_csr(HENVCFG, 0x40)
        run_guest_cmo("vs-cmo-senvcfg-ignored", supervisor=True)
        check("vs-cmo-senvcfg-ignored", state.pc[0], guest_virtual + 4)
        reference.lib.difftest_exec(1)
        check("vs-cmo-enabled-return", [state.pc[0], state.mcause[0]],
              [0x80FF0000, 10])

        write_csr(SENVCFG, 0x40)
        write_pte(vs_leaf_host, (guest >> 12) << 10 | 0x5B)
        run_guest_cmo("vu-cmo-read-only-no-dirty")
        check("vu-cmo-read-only-no-dirty", state.pc[0], guest_virtual + 4)
        reference.lib.difftest_exec(1)
        write_pte(leaf, (second >> 12) << 10 | 0x5B)
        run_guest_cmo("vu-cmo-g-read-only-no-dirty")
        check("vu-cmo-g-read-only-no-dirty", state.pc[0], guest_virtual + 4)
        reference.lib.difftest_exec(1)
        write_pte(leaf, (second >> 12) << 10 | 0xDF)
        write_pte(vs_leaf_host, (guest >> 12) << 10 | 0x59)
        run_guest_cmo("vu-cmo-vs-page-fault")
        check("vu-cmo-vs-page-fault", [state.pc[0], state.mcause[0],
                                        state.mtval[0]],
              [0x80FF0000, 15, guest_virtual])
        write_pte(vs_leaf_host, (guest >> 12) << 10 | 0x5B)
        write_pte(leaf, (second >> 12) << 10 | 0x59)
        run_guest_cmo("vu-cmo-g-page-fault")
        check("vu-cmo-g-page-fault", [state.pc[0], state.mcause[0],
                                       state.mtval[0], read_csr(MTVAL2)[0]],
              [0x80FF0000, 23, guest_virtual, guest >> 2])
        write_pte(leaf, (second >> 12) << 10 | 0xDF)

        zero_operand = guest_virtual + 0x90
        zero_physical = second + 0x80
        reference.write(second, CBO_ZERO.to_bytes(4, "little") +
                        (0x00000073).to_bytes(4, "little"))
        reference.write(zero_physical, bytes([0xA5]) * 64)
        state.gpr[1] = zero_operand
        write_pte(vs_leaf_host, (guest >> 12) << 10 | 0xDF)
        write_csr(MENVCFG, 0x80)
        write_csr(SENVCFG, 0x80)
        write_csr(HENVCFG, 0)
        run_guest_cmo("vu-zero-henvcfg-off")
        check("vu-zero-henvcfg-off", [state.pc[0], state.mcause[0],
                                       reference.read(zero_physical, 64).hex()],
              [0x80FF0000, 22, (bytes([0xA5]) * 64).hex()])
        write_csr(HENVCFG, 0x80)
        run_guest_cmo("vu-zero-enabled")
        check("vu-zero-enabled", [state.pc[0], reference.read(zero_physical, 64).hex()],
              [guest_virtual + 4, bytes(64).hex()])
        reference.lib.difftest_exec(1)

        reference.write(zero_physical, bytes([0xA5]) * 64)
        write_pte(vs_leaf_host, (guest >> 12) << 10 | 0x5B)
        run_guest_cmo("vu-zero-vs-read-only")
        check("vu-zero-vs-read-only", [state.pc[0], state.mcause[0], state.mtval[0],
                                        reference.read(zero_physical, 64).hex()],
              [0x80FF0000, 15, zero_operand, (bytes([0xA5]) * 64).hex()])
        write_pte(vs_leaf_host, (guest >> 12) << 10 | 0x5F)
        run_guest_cmo("vu-zero-vs-no-dirty")
        check("vu-zero-vs-no-dirty", [state.pc[0], state.mcause[0], state.mtval[0],
                                       reference.read(zero_physical, 64).hex()],
              [0x80FF0000, 15, zero_operand, (bytes([0xA5]) * 64).hex()])
        write_pte(vs_leaf_host, (guest >> 12) << 10 | 0xDF)
        write_pte(leaf, (second >> 12) << 10 | 0x5B)
        run_guest_cmo("vu-zero-g-read-only")
        check("vu-zero-g-read-only", [state.pc[0], state.mcause[0], state.mtval[0],
                                       read_csr(MTVAL2)[0],
                                       reference.read(zero_physical, 64).hex()],
              [0x80FF0000, 23, zero_operand, (guest + 0x90) >> 2,
               (bytes([0xA5]) * 64).hex()])
        write_pte(leaf, (second >> 12) << 10 | 0xDF)

        if args.vector:
            vsetvli = (0xD0 << 20) | (1 << 15) | (7 << 12) | (3 << 7) | 0x57
            state.gpr[1] = 4
            reference.write(second, vsetvli.to_bytes(4, "little") +
                            (0x00000073).to_bytes(4, "little"))
            write_csr(0x300, (state.mstatus[0] & ~0x600) | 0x200)
            write_csr(VSSTATUS, 0)
            run_guest_cmo("vu-vector-vs-off")
            check("vu-vector-vs-off", [state.pc[0], state.mcause[0], state.mepc[0]],
                  [0x80FF0000, 2, guest_virtual])
            write_csr(VSSTATUS, 0x200)
            write_csr(0x300, state.mstatus[0] & ~0x600)
            run_guest_cmo("vu-vector-host-vs-off")
            check("vu-vector-host-vs-off", [state.pc[0], state.mcause[0], state.mepc[0]],
                  [0x80FF0000, 2, guest_virtual])
            write_csr(0x300, state.mstatus[0] | 0x200)
            run_guest_cmo("vu-vector-config-enabled")
            check("vu-vector-config-enabled", [state.pc[0], state.gpr[3],
                                                state.mstatus[0] & 0x600],
                  [guest_virtual + 4, 4, 0x600])
            reference.lib.difftest_exec(1)
            check("vu-vector-vs-dirty", read_csr(VSSTATUS)[0] & ((1 << 63) | 0x600),
                  (1 << 63) | 0x600)

            vector_csr_read = (0xC21 << 20) | (2 << 12) | (3 << 7) | 0x73
            reference.write(second, vector_csr_read.to_bytes(4, "little") +
                            (0x00000073).to_bytes(4, "little"))
            write_csr(VSSTATUS, 0)
            run_guest_cmo("vu-vector-csr-vs-off")
            check("vu-vector-csr-vs-off", [state.pc[0], state.mcause[0],
                                            state.mepc[0]],
                  [0x80FF0000, 2, guest_virtual])
            write_csr(VSSTATUS, 0x200)
            run_guest_cmo("vu-vector-csr-enabled")
            check("vu-vector-csr-enabled", [state.pc[0], state.gpr[3]],
                  [guest_virtual + 4, 0xD0])
            reference.lib.difftest_exec(1)

            vmv_v_x = (0x17 << 26) | (1 << 25) | (1 << 15) | (4 << 12) | (1 << 7) | 0x57
            vmv_x_s = (0x10 << 26) | (1 << 25) | (1 << 20) | (2 << 12) | (3 << 7) | 0x57
            reference.write(second, vmv_v_x.to_bytes(4, "little") +
                            vmv_x_s.to_bytes(4, "little") +
                            (0x00000073).to_bytes(4, "little"))
            state.gpr[1] = 7
            write_csr(VSSTATUS, 0)
            run_guest_cmo("vu-vector-exec-vs-off")
            check("vu-vector-exec-vs-off", [state.pc[0], state.mcause[0]],
                  [0x80FF0000, 2])
            write_csr(VSSTATUS, 0x200)
            run_guest_cmo("vu-vector-exec-enabled")
            check("vu-vector-exec-enabled", state.pc[0], guest_virtual + 4)
            reference.lib.difftest_exec(1)
            check("vu-vector-exec-readback", [state.pc[0], state.gpr[3]],
                  [guest_virtual + 8, 7])
            reference.lib.difftest_exec(1)
            check("vu-vector-exec-vs-dirty", read_csr(VSSTATUS)[0] & 0x600, 0x600)

            vmv_s_x = (0x10 << 26) | (1 << 25) | (1 << 15) | (6 << 12) | (2 << 7) | 0x57
            vmv_x_s_v2 = (vmv_x_s & ~(31 << 20)) | (2 << 20)
            reference.write(second, vmv_s_x.to_bytes(4, "little") +
                            vmv_x_s_v2.to_bytes(4, "little") +
                            (0x00000073).to_bytes(4, "little"))
            state.gpr[1] = 0x80000001
            write_csr(VSSTATUS, 0)
            run_guest_cmo("vu-vector-insert-vs-off")
            check("vu-vector-insert-vs-off", [state.pc[0], state.mcause[0]],
                  [0x80FF0000, 2])
            write_csr(VSSTATUS, 0x200)
            run_guest_cmo("vu-vector-insert-enabled")
            check("vu-vector-insert-enabled", state.pc[0], guest_virtual + 4)
            reference.lib.difftest_exec(1)
            check("vu-vector-insert-readback", [state.pc[0], state.gpr[3]],
                  [guest_virtual + 8, 0xFFFFFFFF80000001])
            reference.lib.difftest_exec(1)

            vle32 = (1 << 25) | (1 << 15) | (6 << 12) | (2 << 7) | 0x07
            reference.write(second, vle32.to_bytes(4, "little") +
                            vmv_x_s_v2.to_bytes(4, "little") +
                            (0x00000073).to_bytes(4, "little"))
            reference.write(second + 0x80, (0x12345678).to_bytes(4, "little") * 4)
            state.gpr[1] = guest_virtual + 0x80
            write_csr(VSSTATUS, 0)
            run_guest_cmo("vu-vector-load-vs-off")
            check("vu-vector-load-vs-off", [state.pc[0], state.mcause[0]],
                  [0x80FF0000, 2])
            write_csr(VSSTATUS, 0x200)
            run_guest_cmo("vu-vector-load-enabled")
            check("vu-vector-load-enabled", state.pc[0], guest_virtual + 4)
            reference.lib.difftest_exec(1)
            check("vu-vector-load-readback", [state.pc[0], state.gpr[3]],
                  [guest_virtual + 8, 0x12345678])
            reference.lib.difftest_exec(1)

            vfadd = (1 << 25) | (4 << 20) | (3 << 15) | (1 << 12) | (2 << 7) | 0x57
            reference.write(second, vfadd.to_bytes(4, "little") +
                            (0x00000073).to_bytes(4, "little"))
            write_csr(VSSTATUS, 0x200)
            run_guest_cmo("vu-vector-fp-guest-fs-off")
            check("vu-vector-fp-guest-fs-off", [state.pc[0], state.mcause[0]],
                  [0x80FF0000, 2])
            write_csr(VSSTATUS, 0x2200)
            run_guest_cmo("vu-vector-fp-enabled")
            check("vu-vector-fp-enabled", [state.pc[0], state.mstatus[0] & 0x6600],
                  [guest_virtual + 4, 0x6600])
            reference.lib.difftest_exec(1)
            check("vu-vector-fp-vs-dirty", read_csr(VSSTATUS)[0] & 0x6600,
                  0x6600)

            fadd_s = (1 << 7) | 0x53
            reference.write(second, fadd_s.to_bytes(4, "little") +
                            (0x00000073).to_bytes(4, "little"))
            write_csr(VSSTATUS, 0x600)
            run_guest_cmo("vu-scalar-fp-guest-fs-off")
            check("vu-scalar-fp-guest-fs-off", [state.pc[0], state.mcause[0]],
                  [0x80FF0000, 2])
            write_csr(VSSTATUS, 0x2600)
            write_csr(0x300, state.mstatus[0] & ~0x6000)
            run_guest_cmo("vu-scalar-fp-host-fs-off")
            check("vu-scalar-fp-host-fs-off", [state.pc[0], state.mcause[0]],
                  [0x80FF0000, 2])
            write_csr(0x300, state.mstatus[0] | 0x2000)
            run_guest_cmo("vu-scalar-fp-enabled")
            check("vu-scalar-fp-enabled", [state.pc[0], state.mstatus[0] & 0x6000],
                  [guest_virtual + 4, 0x6000])
            reference.lib.difftest_exec(1)
            check("vu-scalar-fp-vs-dirty", read_csr(VSSTATUS)[0] & 0x6000,
                  0x6000)

            vset_e8 = (0xC0 << 20) | (1 << 15) | (7 << 12) | (3 << 7) | 0x57
            vle8ff = (1 << 25) | (16 << 20) | (6 << 15) | (2 << 7) | 0x07
            read_vl = (0xC20 << 20) | (2 << 12) | (7 << 7) | 0x73
            read_vstart = (0x008 << 20) | (2 << 12) | (8 << 7) | 0x73
            reference.write(second, vset_e8.to_bytes(4, "little") +
                            vle8ff.to_bytes(4, "little") +
                            read_vl.to_bytes(4, "little") +
                            read_vstart.to_bytes(4, "little") +
                            (0x00000073).to_bytes(4, "little"))
            reference.write(second + 0xFFE, b"\x11\x22")
            saved_vs_leaf = reference.read(vs_leaf_host + 8, 8)
            saved_g_leaf = reference.read(leaf + 8, 8)
            write_pte(vs_leaf_host + 8, ((guest + 0x1000) >> 12) << 10 | 0xD7)
            write_pte(leaf + 8, 0)
            state.gpr[1] = 4
            state.gpr[6] = guest_virtual + 0xFFE
            state.gpr[7] = 0
            state.gpr[8] = 1
            write_csr(VSSTATUS, 0x2600)
            run_guest_cmo("vu-vector-fof-later-g-fault")
            check("vu-vector-fof-vset", state.pc[0], guest_virtual + 4)
            reference.lib.difftest_exec(1)
            check("vu-vector-fof-later-g-fault-trim", state.pc[0], guest_virtual + 8)
            reference.lib.difftest_exec(2)
            check("vu-vector-fof-later-g-fault-guest-vl", state.gpr[7], 2)
            check("vu-vector-fof-later-g-fault-vstart", state.gpr[8], 0)
            vector_query = library.nemu_difftest_vector_query
            vector_query.argtypes = [ctypes.c_uint32, ctypes.c_uint32]
            vector_query.restype = ctypes.POINTER(VectorAPI)
            vector_api = vector_query(1, ctypes.sizeof(VectorAPI)).contents
            vector_state = VectorState()
            check("vu-vector-fof-get-state", vector_api.get_state(
                0, ctypes.byref(vector_state)), 0)
            check("vu-vector-fof-later-g-fault-data", list(vector_state.reg[2][:2]),
                  [0x11, 0x22])

            reference.lib.difftest_exec(1)
            check("vu-vector-fof-return-to-m", state.pc[0], 0x80FF0000)
            state.gpr[1] = 4
            state.gpr[6] = guest_virtual + 0x1000
            run_guest_cmo("vu-vector-fof-first-g-fault")
            reference.lib.difftest_exec(1)
            check("vu-vector-fof-first-g-fault-trap",
                  [state.pc[0], state.mcause[0], state.mtval[0], read_csr(MTVAL2)[0]],
                  [0x80FF0000, 21, guest_virtual + 0x1000,
                   (guest + 0x1000) >> 2])
            check("vu-vector-fof-first-g-fault-vl", read_csr(0xC20)[0], 4)
            reference.write(vs_leaf_host + 8, saved_vs_leaf)
            reference.write(leaf + 8, saved_g_leaf)

    if args.enable and args.multihart:
        class MultiState(ctypes.Structure):
            _fields_ = [("pc", ctypes.c_uint64),
                        ("gpr", ctypes.c_uint64 * 32),
                        ("fpr", ctypes.c_uint64 * 32),
                        ("csr", ctypes.c_uint64 * 4096),
                        ("reservation", ctypes.c_uint64),
                        ("mtimecmp", ctypes.c_uint64),
                        ("privilege", ctypes.c_uint32),
                        ("reservation_bytes", ctypes.c_uint32),
                        ("stip", ctypes.c_uint32),
                        ("seip", ctypes.c_uint32)]

        class MultiMemory(ctypes.Structure):
            _fields_ = [("address", ctypes.c_uint64),
                        ("data", ctypes.c_uint64),
                        ("size", ctypes.c_uint32),
                        ("write", ctypes.c_uint32)]

        class MultiFrame(ctypes.Structure):
            _fields_ = [("state", MultiState),
                        ("memory", MultiMemory * 64),
                        ("count", ctypes.c_uint32),
                        ("error", ctypes.c_uint32),
                        ("trapped", ctypes.c_uint32),
                        ("ended", ctypes.c_uint32)]

        class MultiAPI(ctypes.Structure):
            _fields_ = [("version", ctypes.c_uint32),
                        ("size", ctypes.c_uint32),
                        ("xlen", ctypes.c_uint32),
                        ("max_harts", ctypes.c_uint32),
                        ("capabilities", ctypes.c_uint64),
                        ("ram_base", ctypes.c_uint64),
                        ("ram_size", ctypes.c_uint64),
                        ("isa_features", ctypes.c_uint64),
                        ("init", ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_uint32)),
                        ("set_state", ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_uint32,
                                                        ctypes.POINTER(MultiState))),
                        ("get_state", ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_uint32,
                                                        ctypes.POINTER(MultiState))),
                        ("memory_copy", ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_uint64,
                                                          ctypes.c_void_p, ctypes.c_size_t,
                                                          ctypes.c_uint32)),
                        ("step", ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_uint32,
                                                   ctypes.c_uint64,
                                                   ctypes.POINTER(MultiFrame)))]

        multi_query = library.nemu_difftest_query
        multi_query.argtypes = [ctypes.c_uint32, ctypes.c_uint32]
        multi_query.restype = ctypes.POINTER(MultiAPI)
        multi_api = multi_query(1, ctypes.sizeof(MultiAPI)).contents
        check("multi-init", multi_api.init(2), 0)
        if args.vector:
            vector_query = library.nemu_difftest_vector_query
            vector_query.argtypes = [ctypes.c_uint32, ctypes.c_uint32]
            vector_query.restype = ctypes.POINTER(VectorAPI)
            vector_api = vector_query(1, ctypes.sizeof(VectorAPI)).contents
            check("multi-vector-api", [vector_api.xlen, vector_api.max_harts], [64, 4])
            vector_program = (
                (0xD0 << 20) | (1 << 15) | (7 << 12) | (3 << 7) | 0x57,
                (0x17 << 26) | (1 << 25) | (1 << 15) | (4 << 12) | (1 << 7) | 0x57,
                (0x10 << 26) | (1 << 25) | (1 << 20) | (2 << 12) | (3 << 7) | 0x57,
                (0x10 << 26) | (1 << 25) | (1 << 15) | (6 << 12) | (2 << 7) | 0x57,
                (0x10 << 26) | (1 << 25) | (2 << 20) | (2 << 12) | (3 << 7) | 0x57,
            )
            vector_code = ctypes.create_string_buffer(
                b"".join(opcode.to_bytes(4, "little") for opcode in vector_program))
            check("multi-vector-program", multi_api.memory_copy(
                0x80001000, vector_code, 20, 1), 0)
        program = ctypes.create_string_buffer(
            (0x00500193).to_bytes(4, "little") +
            (0x00600213).to_bytes(4, "little") +
            (0).to_bytes(4, "little"))
        check("multi-program", multi_api.memory_copy(0x80000000, program, 12, 1), 0)
        for hart, privilege in ((0, 4), (1, 5)):
            guest_state = MultiState()
            check(f"multi-get-{hart}", multi_api.get_state(hart, guest_state), 0)
            guest_state.pc = 0x80000000 + 4 * hart
            guest_state.privilege = privilege
            guest_state.csr[0x3A0] = 15
            guest_state.csr[0x3B0] = reference.mask
            guest_state.csr[HTIMEDELTA] = 5 + hart
            guest_state.csr[HCOUNTEREN] = 2
            guest_state.csr[VSTIMECMP] = 100 + hart
            guest_state.csr[HSTATUS] |= 1 << (20 + hart)
            if args.vector:
                guest_state.csr[0x300] |= 0x200
                guest_state.csr[VSSTATUS] |= 0x200
                guest_state.gpr[1] = 4 + hart
                seeded_vector = VectorState()
                seeded_vector.reg[1][0] = 0x80 + hart
                check(f"multi-vector-seed-{hart}", vector_api.set_state(
                    hart, ctypes.byref(seeded_vector)), 0)
            if hart == 0:
                guest_state.csr[0x302] = 1 << 2
                guest_state.csr[HEDELEG] = 1 << 2
                guest_state.csr[VSTVEC] = 0x80001000
            check(f"multi-set-{hart}", multi_api.set_state(hart, guest_state), 0)
        frame = MultiFrame()
        check("multi-step-vu", multi_api.step(0, 0, frame), 0)
        check("multi-state-vu", [frame.state.privilege, frame.state.gpr[3],
                                  frame.state.pc, frame.trapped,
                                  frame.state.csr[HTIMEDELTA],
                                  frame.state.csr[VSTIMECMP],
                                  frame.state.csr[HSTATUS] & (7 << 20)],
              [4, 5, 0x80000004, 0, 5, 100, 1 << 20])
        check("multi-step-vs", multi_api.step(1, 1, frame), 0)
        check("multi-state-vs", [frame.state.privilege, frame.state.gpr[4],
                                  frame.state.pc, frame.trapped,
                                  frame.state.csr[HTIMEDELTA],
                                  frame.state.csr[VSTIMECMP],
                                  frame.state.csr[HSTATUS] & (7 << 20)],
              [5, 6, 0x80000008, 0, 6, 101, 1 << 21])
        check("multi-step-vu-next", multi_api.step(0, 2, frame), 0)
        check("multi-vu-delegation-state", [frame.state.privilege,
                                            frame.state.csr[0x302] & 4,
                                            frame.state.csr[HEDELEG] & 4,
                                            frame.state.pc],
              [4, 4, 4, 0x80000008])
        check("multi-step-vu-illegal", multi_api.step(0, 3, frame), 0)
        check("multi-vu-to-vs-trap", [frame.state.privilege, frame.state.pc,
                                      frame.state.csr[0x242],
                                      frame.state.csr[VSEPC], frame.trapped],
              [5, 0x80001000, 2, 0x80000008, 1])
        if args.vector:
            for sequence in range(4, 9):
                check(f"multi-vector-step-{sequence}", multi_api.step(0, sequence, frame), 0)
            check("multi-vector-vs-result", [frame.state.privilege, frame.state.pc,
                                              frame.state.gpr[3], frame.trapped,
                                              frame.state.csr[0x300] & 0x600,
                                              frame.state.csr[VSSTATUS] & 0x600],
                  [5, 0x80001014, 4, 0, 0x600, 0x600])
            for hart in range(2):
                observed_vector = VectorState()
                check(f"multi-vector-get-{hart}", vector_api.get_state(
                    hart, ctypes.byref(observed_vector)), 0)
                expected = (4).to_bytes(4, "little") * 4 if hart == 0 else (
                    bytes([0x81]) + bytes(15))
                check(f"multi-vector-isolation-{hart}", bytes(observed_vector.reg[1]).hex(),
                      expected.hex())
                inserted = (4).to_bytes(4, "little") + bytes(12) if hart == 0 else bytes(16)
                check(f"multi-vector-insert-isolation-{hart}",
                      bytes(observed_vector.reg[2]).hex(), inserted.hex())

    failures = [row for row in rows if not row["passed"]]
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(dict(
        xlen=args.xlen, enabled=args.enable, svnapot=args.svnapot,
        pointer_mask=args.pointer_mask,
        vector=args.vector,
        multihart=args.multihart,
        reference_sha256=hashlib.sha256(args.reference.read_bytes()).hexdigest(),
        checker_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        cases=rows, failures=len(failures)), indent=2) + "\n")
    for failure in failures:
        print("FAIL", failure)
    print(f"NEMU_H_GSTAGE cases={len(rows)} failures={len(failures)} "
          f"xlen={args.xlen} enabled={args.enable}")
    return bool(failures)


if __name__ == "__main__":
    raise SystemExit(main())
