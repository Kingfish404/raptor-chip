  // Module-local L1I/L2TLB fixture and tasks. No include guard.
  localparam int XLEN = `RAPT_XLEN;
  localparam logic [XLEN-1:0] OldSupervisorPc = XLEN'(32'hc000_1000);
`ifdef RAPT_TEST_ZERO_PC
  localparam logic [XLEN-1:0] UserTargetPc = '0;
`else
  localparam logic [XLEN-1:0] UserTargetPc = XLEN'(32'h0001_0000);
`endif
  localparam logic [XLEN-1:0] RedirectedUserPc = XLEN'(32'h0002_0000);
  // PA 0x80000000 is aligned for a root-level leaf in both Sv32 and Sv39.
  localparam logic [XLEN-1:0] UserLeafPte = XLEN'(32'h2000_0059);

  logic clock = 1'b0;
  logic reset = 1'b1;

  cmu_bcast_if cmu_bcast ();
  ifu_l1i_if ifu_l1i ();
  l1i_bus_if l1i_bus ();
  csr_bcast_if csr_bcast ();
  pmp_state_if pmp_state ();

  rapt_pkg::l2tlb_req_t l2_req [2];
  rapt_pkg::l2tlb_rsp_t l2_rsp [2];
  logic [1:0] l2_ready;
  assign l2_req[1] = '0;
  rapt_l2tlb shared_tlb (
      .clock(clock),
      .reset(reset),
      .flush(cmu_bcast.fence_time),
      .req_i(l2_req),
      .ready_o(l2_ready),
      .rsp_o(l2_rsp)
  );
  rapt_l1i #(
      .L2Tlb(L2Tlb)
  ) dut (
      .l2tlb_req_o(l2_req[0]),
      .l2tlb_ready_i(l2_ready[0]),
      .l2tlb_rsp_i(l2_rsp[0]),
      .io_authorized(1'b0),
      .io_start(),
      .io_owner_pc(),
      .clock(clock),
      .cmu_bcast(cmu_bcast),
      .ifu_l1i(ifu_l1i),
      .l1i_bus(l1i_bus),
      .csr_bcast(csr_bcast),
      .pmp_state(pmp_state),
      .reset(reset)
  );

  always #5 clock = ~clock;

  `include "tb_common.svh"
  `include "tb_core_bcast_defaults.svh"
  `include "tb_pmp_state_defaults.svh"

  task automatic init_inputs;
    begin
      init_cmu_bcast_defaults();
      init_csr_bcast_defaults(`RAPT_PRIV_S, '0, 1'b0);
      init_pmp_state_defaults(1'b0);

      ifu_l1i.pc = OldSupervisorPc;
      ifu_l1i.consumed = 0;
      ifu_l1i.cancel = 0;
      ifu_l1i.invalid = 1'b0;
      ifu_l1i.prefetch_pc = '0;
      ifu_l1i.prefetch_valid = 1'b0;

      l1i_bus.rready = 1'b0;
      l1i_bus.rdata = '0;
      l1i_bus.rvalid = 1'b0;
      l1i_bus.ptw_rerr = 0;
      l1i_bus.ptw_rvalid = 1'b0;
      l1i_bus.rerr = 1'b0;

      csr_bcast.immu_en = 1'b1;
      csr_bcast.satp_ppn = `RAPT_CSR_SATP_PPN_W'(32'h8000_0);
      pmp_state.pmp_cfg_r[0] = 1'b1;
      pmp_state.pmp_cfg_w[0] = 1'b1;
      pmp_state.pmp_cfg_x[0] = 1'b1;
      pmp_state.pmp_mode_off[0] = 1'b0;
      pmp_state.pmp_mode_napot[0] = 1'b1;
      pmp_state.pmp_raw_addr[0] = '1;
      pmp_state.pmp_napot_mask[0] = '1;
    end
  endtask

  task automatic wait_for_ptw_request(input string message);
    bit found;
    begin
      found = 1'b0;
      for (int cycle = 0; cycle < 32; cycle++) begin
        #1;
        if (l1i_bus.arvalid && l1i_bus.ar_ptw) begin
          found = 1'b1;
          cycle = 32;
        end else begin
          tick(1);
        end
      end
      if (!found) fail(message);
    end
  endtask

  task automatic accept_ptw_request;
    begin
      l1i_bus.rready = 1'b1;
      tick(1);
      l1i_bus.rready = 1'b0;
    end
  endtask

  task automatic return_ptw_pte(input logic [XLEN-1:0] pte);
    begin
      l1i_bus.rdata = pte;
      l1i_bus.ptw_rvalid = 1'b1;
      tick(1);
      l1i_bus.ptw_rvalid = 1'b0;
    end
  endtask
