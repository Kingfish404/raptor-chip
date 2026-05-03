/* verilator lint_off UNUSEDPARAM */
package rapt_pkg;
  `include "rapt.svh"

  localparam int XLENPkg = `RAPT_XLEN;

  localparam unsigned RNUMPkg = `RAPT_REG_SIZE;
  localparam unsigned RLENPkg = `RAPT_REG_LEN;

  localparam unsigned PNUMPkg = `RAPT_PHY_SIZE;
  localparam unsigned PLENPkg = `RAPT_PHY_LEN;

  typedef struct packed {
    logic       c;
    logic       word;  // RV64 W-variant: operate on lower 32 bits, sign-extend result
    logic [5:0] alu;
    logic       ben;
    logic       jen;
    logic       jren;
    logic       wen;
    logic       ren;
    logic       atom;

    logic system;
    logic ecall;
    logic ebreak;
    logic f_i;
    logic f_time;
    logic mret;
    logic sret;
    logic [2:0] csr_csw;

    logic trap;
    logic [XLENPkg-1:0] tval;
    logic [XLENPkg-1:0] cause;

    logic [RLENPkg-1:0] rd;
    logic [XLENPkg-1:0] imm;

    logic [XLENPkg-1:0] pnpc;
    logic [31:0] inst;
    logic [XLENPkg-1:0] pc;
  } uop_t;

  typedef struct packed {
    logic [XLENPkg-1:0] op1;
    logic [XLENPkg-1:0] op2;

    logic [PLENPkg-1:0] pr1;
    logic [PLENPkg-1:0] pr2;
    logic [PLENPkg-1:0] prd;
    logic [PLENPkg-1:0] prs;
  } prd_t;

  // ROB entry state
  typedef enum logic [1:0] {
    ROB_CM = 2'b00,  // Committed / empty
    ROB_WB = 2'b01,  // Written back, waiting to commit
    ROB_EX = 2'b10   // Executing
  } rob_state_t;

  // UOP payload: dispatch-write-only, never modified during RS/ROB residence.
  // Stored in a separate `uop_pl[ROB_SIZE]` array (flop) indexed by ROB
  // destination. Read by RS at issue time and by commit path, eliminating
  // duplicated copies that previously lived in both `rob_entry_t` and RS.
  typedef struct packed {
    // System / trap dispatch classification
    logic sys;     // CSR access (former rob_entry.sys / uop.system)
    logic ecall;
    logic ebreak;
    logic mret;
    logic sret;
    logic f_i;
    logic f_time;

    // CSR access
    logic [11:0] csr_addr;  // equals uop.imm[11:0]
    logic [2:0]  csr_csw;   // CSR write strobes (W/S/C)

    // Original instruction (debug / RVFI / difftest). On commit, a trap
    // entry is surfaced as `'h13` (NOP) via a read-side mux.
    logic [31:0] inst;
  } uop_payload_t;

  // ROB entry - control + WB-mutable fields only. Cold, dispatch-only
  // fields live in `uop_payload_t` above.
  typedef struct packed {
    // Physical register mapping
    logic [PLENPkg-1:0] prd;
    logic [PLENPkg-1:0] prs;

    // Architectural register
    logic [RLENPkg-1:0] rd;
    rob_state_t         state;
    logic               busy;

    // Branch / jump
    logic               ben;
    logic               jen;
    logic               jren;
    logic               btaken;
    logic [XLENPkg-1:0] npc;
    logic [XLENPkg-1:0] pnpc;

    // Memory
    logic               wen;
    logic               word;      // RV64 W-variant flag
    logic [5:0]         alu;
    logic [XLENPkg-1:0] sq_waddr;
    logic [XLENPkg-1:0] sq_wdata;

    // Atomics
    logic atom;
    logic atom_sc;

    // CSR (WB-written)
    logic               csr_wen;
    logic [XLENPkg-1:0] csr_wdata;

    // Trap (WB-mutable by EXU port-A and IOQ)
    logic               trap;
    logic [XLENPkg-1:0] tval;
    logic [XLENPkg-1:0] cause;

    // Difftest
    logic difftest_skip;

    // PC (commit path)
    logic [XLENPkg-1:0] pc;
  } rob_entry_t;

  // Shared address classification functions for L1I/L1D
  function automatic logic addr_cacheable(input logic [XLENPkg-1:0] addr);
    return (0)  // --- IGNORE ---
    || (addr >= 'h0f000000 && addr < 'h0f010000)  // sram (litex + raptSoC)
    || (addr >= 'h20000000 && addr < 'h20010000)  // mrom (64KB)
    || (addr >= 'h30000000 && addr < 'h40000000)  // flash
    || (addr >= 'h80000000 && addr < 'h90000000)  // psram (256MB, covers 128MB & 256MB configs)
    || (addr >= 'ha0000000 && addr < 'ha2000000)  // sdram
    ;
  endfunction

  // Any physical address that corresponds to a real bus target
  // (cacheable memory or MMIO).  Accesses outside of this predicate
  // are unmapped and must raise an access-fault trap to mimic sail /
  // real-hardware bus-error behaviour.
  function automatic logic addr_mapped(input logic [XLENPkg-1:0] addr);
    return (0)  // --- IGNORE ---
    || (addr >= 'h00100000 && addr < 'h00101000)  // sifive,test finisher
    || (addr >= 'h02000000 && addr < 'h020c0000)  // CLINT
    || (addr >= 'h0c000000 && addr < 'h0d000000)  // PLIC
    || (addr >= 'h0f000000 && addr < 'h0f010000)  // SRAM
    || (addr >= 'h10000000 && addr < 'h10012000)  // UART / GPIO / peripherals
    || (addr >= 'h20000000 && addr < 'h20010000)  // MROM
    || (addr >= 'h21000000 && addr < 'h21200000)  // VGA
    || (addr >= 'h30008000 && addr < 'h30009000)  // QEMU SDHCI PCI ECAM stub
    || (addr >= 'h30000000 && addr < 'h40000000)  // FLASH
    || (addr >= 'h40000000 && addr < 'h40000100)  // QEMU SDHCI controller
    || (addr >= 'h80000000 && addr < 'h90000000)  // PMEM / PSRAM
    || (addr >= 'ha0000000 && addr < 'ha2000000)  // SDRAM
    || (addr >= 'hc0000000);  // raptSoC MMIO window
  endfunction

  // MMIO regions for difftest skip (not modelled in reference ISS)
  function automatic logic addr_mmio(input logic [XLENPkg-1:0] addr);
    return (0)  // --- IGNORE ---
    || (addr >= 'h00100000 && addr <= 'h00100fff)  // finisher (sifive,test)
    || (addr >= 'h02000000 && addr <= 'h020bffff)  // CLINT (mtime / mtimecmp / msip)
    || (addr >= 'h0c000000 && addr <= 'h0cffffff)  // PLIC (claim/complete RMW)
    || (addr >= 'h30008000 && addr <= 'h30008fff)  // QEMU SDHCI PCI ECAM stub
    || (addr >= 'h40000000 && addr <= 'h400000ff)  // QEMU SDHCI controller
    || (addr >= 'h10001000 && addr <= 'h10001fff)  // uart
    || (addr >= 'h10002000 && addr <= 'h1000200f)  // gpio
    || (addr >= 'h10011000 && addr <= 'h10012000)  // legacy ysyxSoC clint (kept for back-compat)
    || (addr >= 'h21000000 && addr <= 'h211fffff)  // vga
    || (addr >= 'hc0000000);  // raptSoC memory-mapped I/O
  endfunction

endpackage
