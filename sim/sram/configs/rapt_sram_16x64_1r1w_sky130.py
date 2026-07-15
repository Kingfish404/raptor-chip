# OpenRAM 1R1W SRAM config for L1D data banks (RV64 default config).
# Each rapt_sram_1r1w instance: 16 entries × 64 bits = 1024 bits = 128 B.

word_size  = 64
num_words  = 16
write_size = 8

num_rw_ports = 1
num_r_ports  = 1
num_w_ports  = 0
ports_human  = "1r1w"

import os
exec(open(os.path.join(os.path.dirname(__file__), 'sky130_common.py')).read())
