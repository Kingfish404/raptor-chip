import "DPI-C" function void npc_exu_ebreak ();
import "DPI-C" function void npc_illegal_inst ();
import "DPI-C" function void npc_difftest_skip_ref();

import "DPI-C" function void pmem_read (input int raddr, output int rdata);
import "DPI-C" function void pmem_write (input int waddr, input int wdata, input byte wmask);
