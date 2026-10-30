"""RV64 projection of the same Raptor M-mode generator contract as RV32."""
from pygen_src.target.raptor_rv32imac.riscv_core_setting import *

XLEN = 64
supported_isa = supported_isa + [
    riscv_instr_group_t.RV64I,
    riscv_instr_group_t.RV64M,
    riscv_instr_group_t.RV64C,
]
