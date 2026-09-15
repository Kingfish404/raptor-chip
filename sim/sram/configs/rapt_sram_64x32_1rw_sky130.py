# Default L1I word banks: 64 sets x 32 bits, one shared read/write port.
word_size  = 32
num_words  = 64
write_size = 8

num_rw_ports = 1
num_r_ports  = 0
num_w_ports  = 0
ports_human  = "1rw"

import os
exec(open(os.path.join(os.path.dirname(__file__), 'sky130_common.py')).read())
