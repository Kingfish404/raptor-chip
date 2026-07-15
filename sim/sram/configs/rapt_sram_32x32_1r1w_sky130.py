# OpenRAM 1R1W SRAM config for L1I data banks (default config).
# Each rapt_sram_1r1w instance: 32 entries × 32 bits = 1024 bits = 128 B.
# Instantiated `L1I_N_WAYS × L1I_LINE_SIZE` times in rapt_l1i.sv.

word_size  = 32      # bits
num_words  = 32      # depth
write_size = 8       # byte-write granularity (4 byte enables for 32-bit word)

# 1 read/write + 1 read-only port; the cache controller uses port0 for
# refill writes and port1 for fetches. This matches the rapt_sram_1r1w
# 1R1W abstraction.
num_rw_ports = 1
num_r_ports  = 1
num_w_ports  = 0
ports_human  = "1r1w"

import os
exec(open(os.path.join(os.path.dirname(__file__), 'sky130_common.py')).read())
