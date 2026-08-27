# OpenRAM single-port (1RW) SRAM config for L1D data banks (RV32 default).
# Each rapt_sram_1rw instance: 16 entries × 32 bits = 512 bits = 64 B.
# Instantiated `L1D_N_WAYS × L1D_LINE_SIZE` times in rapt_l1d.sv.

word_size  = 32      # bits
num_words  = 16      # depth
write_size = 8       # byte-write granularity (4 byte enables for 32-bit word)

num_rw_ports = 1
num_r_ports  = 0
num_w_ports  = 0
ports_human  = "1rw"

import os
exec(open(os.path.join(os.path.dirname(__file__), 'sky130_common.py')).read())
