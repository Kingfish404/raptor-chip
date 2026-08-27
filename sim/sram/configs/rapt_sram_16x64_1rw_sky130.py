# OpenRAM single-port (1RW) SRAM config for L1D data banks (RV64 default).
# Each rapt_sram_1rw instance: 16 entries × 64 bits = 1024 bits = 128 B.
# Instantiated `L1D_N_WAYS × (L1D_LINE_SIZE/2)` times in rapt_l1d.sv.

word_size  = 64      # bits
num_words  = 16      # depth
write_size = 8       # byte-write granularity (8 byte enables for 64-bit word)

num_rw_ports = 1
num_r_ports  = 0
num_w_ports  = 0
ports_human  = "1rw"

import os
exec(open(os.path.join(os.path.dirname(__file__), 'sky130_common.py')).read())
