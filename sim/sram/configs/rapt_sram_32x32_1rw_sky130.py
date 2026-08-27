# OpenRAM single-port (1RW) SRAM config for L1I data banks (default config).
# Each rapt_sram_1rw instance: 32 entries × 32 bits = 1024 bits = 128 B.
# Instantiated `L1I_N_WAYS × L1I_LINE_SIZE` times in rapt_l1i.sv.

word_size  = 32      # bits
num_words  = 32      # depth
write_size = 8       # byte-write granularity (4 byte enables for 32-bit word)

# One read/write port: the cache controller time-multiplexes refill writes
# and fetches onto the shared port. This matches the rapt_sram_1rw
# single-port abstraction.
num_rw_ports = 1
num_r_ports  = 0
num_w_ports  = 0
ports_human  = "1rw"

import os
exec(open(os.path.join(os.path.dirname(__file__), 'sky130_common.py')).read())
