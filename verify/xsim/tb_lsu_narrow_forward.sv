`include "rapt.svh"
`include "rapt_if.svh"
module tb_lsu_narrow_forward;
  localparam int XLEN = `RAPT_XLEN;
  localparam int LsuTbSqSize = 4;
  localparam logic [XLEN-1:0] Base = XLEN'('h80001000);
  `define TB_LSU_MANUAL_CONTEXT
  `include "tb_lsu_harness.svh"
  logic b_mmu = 0;
  assign exu_lsu.rcontext = '{
          mmu_en: csr_bcast.dmmu_en,
          eff_priv: csr_bcast.priv,
          sum: csr_bcast.sum,
          mxr: csr_bcast.mxr,
          pbmte: csr_bcast.menvcfg_pbmte,
          asid: csr_bcast.satp_asid,
          version: 8'd0
      };
  always_comb begin
    exu_lsu.rcontext_b = exu_lsu.rcontext;
    exu_lsu.rcontext_b.mmu_en = b_mmu;
  end
  assign sq_context = exu_lsu.rcontext;

  task automatic test_store(input logic [4:0] store_mask, input int offset,
                            input logic [4:0] load_op, input logic [XLEN-1:0] expected);
    reset = 1;
    init_lsu_inputs(1, 0, load_op);
    tick(3);
    reset = 0;
    tick(1);
    exu_ioq_bcast.valid = 1;
    exu_ioq_bcast.wen = 1;
    exu_ioq_bcast.alu = {1'b0,store_mask};
    exu_ioq_bcast.dest = 3;
    exu_ioq_bcast.tval = Base + XLEN'(offset);
    exu_ioq_bcast.sq_waddr = Base + XLEN'(offset);
    exu_ioq_bcast.sq_wdata = XLEN'('h876543218765a5f1);
    tick(1);
    exu_ioq_bcast.valid = 0;
    exu_ioq_bcast.wen = 0;
    exu_lsu.raddr = Base + XLEN'(offset);
    exu_lsu.ralu = load_op;
    exu_lsu.rvalid = 1;
    exu_lsu.raddr_b = exu_lsu.raddr;
    exu_lsu.ralu_b = load_op;
    exu_lsu.rvalid_b = 1;
    #1;
    check(exu_lsu.rready && exu_lsu.rdata == expected && !lsu_l1d.rvalid,
          "A narrow forward or sign extension");
    check(exu_lsu.rready_b && exu_lsu.rdata_b == expected && !lsu_l1d.rvalid_b,
          "B narrow forward or sign extension");
    // Privilege changes in this fixture make both read permissions denied.
    // A valid store match must not override a denied load permission.
    csr_bcast.priv = `RAPT_PRIV_S;
    #1;
    check(!exu_lsu.rready && !exu_lsu.rready_b, "SQ forwarding bypassed load PMP");
    csr_bcast.priv = `RAPT_PRIV_M;
    #1;
    check(exu_lsu.rready && exu_lsu.rready_b, "allowed load failed to recover");
    if (store_mask == `RAPT_SH_WSTRB) begin
      b_mmu = 1;
      #1;
      check(exu_lsu.rready && !exu_lsu.rready_b, "B narrow VA forwarded under MMU");
      b_mmu = 0;
      #1;
      check(exu_lsu.rready_b, "bare B narrow forwarding did not recover");
    end
    exu_lsu.rvalid = 0;
    exu_lsu.rvalid_b = 0;
    cmu_bcast.flush_pipe = 1;
    tick(1);
    cmu_bcast.flush_pipe = 0;
    #1;
    check(rou_lsu.sq_empty, "flush retained speculative narrow store");
  endtask
  initial begin
    test_store(`RAPT_SB_WSTRB, XLEN / 8 - 1, `RAPT_ALU_LB__, XLEN'(-15));
    test_store(`RAPT_SB_WSTRB, XLEN / 8 - 1, `RAPT_ALU_LBU_, XLEN'('hf1));
    test_store(`RAPT_SH_WSTRB, XLEN / 8 - 2, `RAPT_ALU_LH__, XLEN'(-23055));
    test_store(`RAPT_SH_WSTRB, XLEN / 8 - 2, `RAPT_ALU_LHU_, XLEN'('ha5f1));
    test_store(`RAPT_SW_WSTRB, XLEN / 8 - 4, `RAPT_ALU_LW__, XLEN'($signed(32'h8765a5f1)));
`ifdef RAPT_RV64
    test_store(`RAPT_SW_WSTRB, 4, `RAPT_ALU_LWU_, XLEN'('h8765a5f1));
    test_store(`RAPT_SD_WSTRB, 0, `RAPT_ALU_LD__, XLEN'('h876543218765a5f1));
`endif
    $display("PASS: LSU narrow A/B forwarding, sign extension, PMP and flush XLEN=%0d", XLEN);
    $finish;
  end
endmodule
