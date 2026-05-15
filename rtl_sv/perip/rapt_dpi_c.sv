`include "rapt_dpi_c.svh"

`ifdef USE_DPI_C
import "DPI-C" function void npc_exu_ebreak();
import "DPI-C" function void npc_difftest_skip_ref();

// Pull-and-clear pending external-interrupt bitmap from the C++ side.
// Returns a 32-bit pulse vector indexed by IRQ number; the call atomically
// clears the value so each pulse is delivered exactly once (PLIC edge-detect
// FSM latches the rising edge as pending). This is the synthesizable
// equivalent of the legacy `*npc.plic_pending |= ...` backdoor; only used by
// nsim/rtl/ TB wrappers to drive `ext_irq_i[]` on rapt.sv.
import "DPI-C" function void npc_consume_ext_irq_vector(output int rdata);

`ifdef RAPT_RV64
import "DPI-C" function void npc_difftest_mem_diff(
  input longint waddr,
  input longint wdata,
  input byte    wstrb
);
import "DPI-C" function void pmem_read(
  input  longint raddr,
  output longint rdata
);
import "DPI-C" function void pmem_write(
  input longint waddr,
  input longint wdata,
  input byte    wmask
);
`else
import "DPI-C" function void npc_difftest_mem_diff(
  input int  waddr,
  input int  wdata,
  input byte wstrb
);
import "DPI-C" function void pmem_read(
  input  int raddr,
  output int rdata
);
import "DPI-C" function void pmem_write(
  input int  waddr,
  input int  wdata,
  input byte wmask
);
`endif
`endif
