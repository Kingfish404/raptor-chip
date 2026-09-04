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

    // Serializing scalar-FP bring-up metadata. FP architectural registers
    // live in the separate FPR bank; rd remains an integer destination only
    // for FP-to-integer moves.
    logic       fp_valid;
    logic [5:0] fp_op;
    logic [2:0] fp_rm;
    logic [4:0] fp_rs1;
    logic [4:0] fp_rs2;
    logic [4:0] fp_rs3;
    logic [4:0] fp_rd;

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
`ifdef RAPT_RVFI
    // Original fetched encoding (compressed 16-bit zero-extended, or 32-bit).
    // Used only by RVFI so `rvfi_insn` reports the architectural instruction
    // word, while `inst` keeps the decompressed form for difftest/decode.
    logic [31:0] rvfi_inst;
`endif
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
    logic fp_valid;
    logic [5:0] fp_op;
    logic [2:0] fp_rm;
    logic [4:0] fp_rs1;
    logic [4:0] fp_rs2;
    logic [4:0] fp_rs3;
    logic [4:0] fp_rd;

    // CSR access
    logic [11:0] csr_addr;  // equals uop.imm[11:0]
    logic [2:0]  csr_csw;   // CSR write strobes (W/S/C)

    // Branch / jump classification (dispatch-only; branch resolution at WB
    // updates rob_entry.btaken / mispredict instead). Used by commit path
    // to inform the BPU of the resolved direction.
    logic ben;
    logic jen;
    logic jren;

    // Atomic classification (dispatch-only; commit path uses `atom_sc` to
    // mark SC writes and `atom` to enforce serializing flush).
    logic atom;
    logic atom_sc;

    // Architectural PC (dispatch-only; the corresponding `npc` lives in
    // `rob_entry_t` because it is WB-mutable).
    logic [XLENPkg-1:0] pc;

    // Original instruction (debug / RVFI / difftest). On commit, a trap
    // entry is surfaced as `'h13` (NOP) via a read-side mux.
    logic [31:0] inst;
`ifdef RAPT_RVFI
    // Original fetched encoding for RVFI (compressed 16-bit zero-extended).
    logic [31:0] rvfi_inst;
`endif
  } uop_payload_t;

  // ROB entry - control + WB-mutable fields only. Cold, dispatch-only
  // fields (pc / ben / jen / jren / atom / atom_sc / sys / csr_*) live in
  // `uop_payload_t` above (`uop_pl[]`, indexed by ROB destination).
  typedef struct packed {
    // Physical register mapping
    logic [PLENPkg-1:0] prd;
    logic [PLENPkg-1:0] prs;

    // Architectural register
    logic [RLENPkg-1:0] rd;
    rob_state_t         state;
    logic               busy;

    // Branch / jump resolution (WB-written)
    logic               btaken;
    logic [XLENPkg-1:0] npc;
    // 1-bit BPU mispredict flag (dispatch-init 0; WB sets when computed
    // npc != predicted pnpc). Replaces an XLEN-wide `pnpc` field that was
    // only ever consumed for the `npc != pnpc` comparison at commit.
    logic               mispredict;

    // Memory
    logic               wen;
    logic               word;      // RV64 W-variant flag
    logic [5:0]         alu;
    logic [XLENPkg-1:0] sq_waddr;
    logic [XLENPkg-1:0] sq_wdata;
    logic [63:0] sq_wdata64;
    logic sq_fp64;

    // CSR (WB-written)
    logic               csr_wen;
    logic [XLENPkg-1:0] csr_wdata;
    logic               fp_flags_valid;
    logic [4:0]         fp_flags;

    // Trap (WB-mutable by EXU port-A and IOQ)
    logic               trap;
    logic [XLENPkg-1:0] tval;
    logic [XLENPkg-1:0] cause;

    // Difftest
    logic difftest_skip;
  } rob_entry_t;

  // Shared address classification functions for L1I/L1D
  function automatic logic [XLENPkg-1:0] canonical_addr(input logic [XLENPkg-1:0] addr);
    return (XLENPkg == 64) ? XLENPkg'({32'b0, addr[31:0]}) : addr;
  endfunction

  // The implemented physical map is 32-bit. RV64 code may present those
  // addresses either zero-extended or with an all-ones upper half (for
  // example, an address materialised by a sign-extending LUI). Do not simply
  // truncate any other upper half: doing so can turn an invalid speculative
  // address such as 0x00000002_8014572c into a real PMEM request.
  function automatic logic addr_upper_valid(input logic [XLENPkg-1:0] addr);
    logic [XLENPkg-1:0] zero_extended;
    logic [XLENPkg-1:0] ones_extended;
    zero_extended = XLENPkg'({32'h0000_0000, addr[31:0]});
    ones_extended = XLENPkg'({32'hffff_ffff, addr[31:0]});
    return (addr == zero_extended) || (addr == ones_extended);
  endfunction

  function automatic logic addr_cacheable(input logic [XLENPkg-1:0] addr);
    logic [XLENPkg-1:0] a;
    a = canonical_addr(addr);
    return addr_upper_valid(addr) && ((0)  // --- IGNORE ---
    || (a >= 'h0f000000 && a < 'h0f010000)  // sram (litex + raptSoC)
    || (a >= 'h20000000 && a < 'h20010000)  // mrom (64KB)
    || (a >= 'h30000000 && a < 'h40000000)  // flash
    || (a >= 'h80000000 && a < 'h90000000)  // psram (cacheable)
    || (a >= 'ha0000000 && a < 'ha2000000)  // sdram
    );
  endfunction

  // Any physical address that corresponds to a real bus target
  // (cacheable memory or MMIO).  Accesses outside of this predicate
  // are unmapped and must raise an access-fault trap to mimic sail /
  // real-hardware bus-error behaviour.
  function automatic logic addr_mapped(input logic [XLENPkg-1:0] addr);
    logic [XLENPkg-1:0] a;
    a = canonical_addr(addr);
    return addr_upper_valid(addr) && ((0)  // --- IGNORE ---
    || (a >= 'h00100000 && a < 'h00101000)  // sifive,test finisher
    || (a >= 'h02000000 && a < 'h020c0000)  // CLINT
    || (a >= 'h0c000000 && a < 'h0d000000)  // PLIC
    || (a >= 'h0f000000 && a < 'h0f010000)  // SRAM
    || (a >= 'h10000000 && a < 'h10012000)  // UART / GPIO / peripherals
    || (a >= 'h20000000 && a < 'h20010000)  // MROM
    || (a >= 'h21000000 && a < 'h21200000)  // VGA
    || (a >= 'h30000000 && a < 'h40000000)  // FLASH
    || (a >= 'h80000000 && a < 'h90000000)  // PMEM / PSRAM
    || (a >= 'ha0000000 && a < 'ha2000000)  // SDRAM
    || (a >= 'hf0008000 && a < 'hf0008100)  // LiteX SPI SD-card controller
    || (a >= 'hf0001000 && a < 'hf0001100)  // LiteX UART (egos HARDWARE)
    || (a >= 'hf0010000 && a < 'hf0020000)  // CLINT alias (egos HARDWARE)
    || (a >= 'hc0000000));  // raptSoC MMIO window
  endfunction

  // MMIO regions for difftest skip (not modelled in reference ISS)
  function automatic logic addr_mmio(input logic [XLENPkg-1:0] addr);
    logic [XLENPkg-1:0] a;
    a = canonical_addr(addr);
    return addr_upper_valid(addr) && ((0)  // --- IGNORE ---
    || (a >= 'h00100000 && a <= 'h00100fff)  // finisher (sifive,test)
    || (a >= 'h02000000 && a <= 'h020bffff)  // CLINT (mtime / mtimecmp / msip)
    || (a >= 'h0c000000 && a <= 'h0cffffff)  // PLIC (claim/complete RMW)
    || (a >= 'hf0008000 && a <= 'hf00080ff)  // LiteX SPI SD-card controller
    || (a >= 'hf0001000 && a <= 'hf00010ff)  // LiteX UART (egos HARDWARE)
    || (a >= 'hf0010000 && a <= 'hf001ffff)  // CLINT alias (egos HARDWARE)
    || (a >= 'h10001000 && a <= 'h10001fff)  // uart
    || (a >= 'h10002000 && a <= 'h1000200f)  // gpio
    || (a >= 'h10011000 && a <= 'h10012000)  // legacy ysyxSoC clint (kept for back-compat)
    || (a >= 'h21000000 && a <= 'h211fffff)  // vga
    || (a >= 'hc0000000));  // raptSoC memory-mapped I/O
  endfunction

endpackage
