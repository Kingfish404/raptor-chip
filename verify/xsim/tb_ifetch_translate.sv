`include "rapt.svh"
`include "rapt_if.svh"
module tb_ifetch_translate;
  localparam int XLEN   = `RAPT_XLEN;
  localparam int Levels = XLEN == 64 ? 3 : 2;
  logic clock = 0, reset = 1, kill = 0;
  always #5 clock = ~clock;
  logic request_valid = 0, request_ready;
  logic [XLEN-1:0] request_vaddr = 'h40000ffc;
  logic mmu_en = 1, pbmte = 1, sbe = 0;
  logic [1:0] priv=`RAPT_PRIV_S;
  logic [`RAPT_CSR_SATP_PPN_W-1:0] satp_ppn='h80000;
  pmp_state_if pmp_state ();
  logic response_valid, response_fault;
  logic [XLEN-1:0] response_paddr, response_cause;
  logic [1:0] response_pbmt;
  logic bus_arvalid, bus_arready = 0, bus_rvalid = 0, bus_rerror = 0;
  logic [XLEN-1:0] bus_araddr, bus_rdata = 0;
  int responses = 0, requests = 0;
  always @(posedge clock)
    if (!reset) begin
      if (request_valid && request_ready) requests <= requests + 1;
      if (response_valid) responses <= responses + 1;
    end
  rapt_ifetch_translate dut (.*);
  `include "tb_common.svh"
  `include "tb_pmp_state_defaults.svh"
  task automatic allow_all;
    init_pmp_state_defaults(1);
    pmp_state.pmp_mode_off[0]=0;
    pmp_state.pmp_mode_napot[0]=1;
    pmp_state.pmp_raw_addr[0]='1;
    pmp_state.pmp_napot_mask[0]='1;
    pmp_state.pmp_cfg_r[0]=1;
    pmp_state.pmp_cfg_w[0]=1;
    pmp_state.pmp_cfg_x[0]=1;
  endtask
  task automatic start;
    check(request_ready, "translation owner not released");
    request_valid = 1;
    tick(1);
    request_valid = 0;
    tick(1);
  endtask
  task automatic accept_pte;
    check(bus_arvalid, "expected PTE read missing");
    bus_arready = 1;
    tick(1);
    bus_arready = 0;
    tick(2);
    check(!bus_arvalid && !response_valid && !request_ready, "accepted PTE ownership lost");
  endtask
  task automatic respond_pte(input logic [XLEN-1:0] value);
    bus_rdata=value;
    bus_rvalid=1;
    tick(1);
    bus_rvalid = 0;
  endtask
  task automatic leaf(input int attr, input logic [7:0] flags);
    for (int l = 0; l < Levels; l++) begin
      accept_pte();
      respond_pte(
          l==Levels-1
        ? ((XLEN'('h81000000)>>2) | XLEN'(flags) | (XLEN'(attr)<<61))
        : ((XLEN'('h80001000)>>2) | XLEN'(1)));
    end
  endtask
  task automatic finish_case(input bit fault, input int cause);
    for (int n = 0; n < 12 && !response_valid; n++) tick(1);
    check(response_valid && response_fault == fault, "translation completion/fault mismatch");
    if (fault) check(response_cause == XLEN'(cause), "translation fault cause mismatch");
    tick(1);
    check(request_ready && !response_valid, "translation response repeated");
    check(requests == responses, "accepted request did not produce exactly one response");
  endtask
  initial begin
    allow_all();
    tick(3);
    reset = 0;
    tick(1);
    for (int a = 0; a < (XLEN == 64 ? 3 : 1); a++) begin
      start();
      // Accepted privilege and PBMTE survive changes on the live inputs.
      priv=`RAPT_PRIV_U;
      pbmte=0;
      satp_ppn=0;
      leaf(a, 8'h4b);  // V/R/X/A, supervisor page
      finish_case(0, 0);
      check(response_paddr == XLEN'('h81000ffc) && response_pbmt == 2'(a),
            "PA/PBMT capture mismatch");
      priv=`RAPT_PRIV_S;
      pbmte=1;
      satp_ppn='h80000;
    end
    // Missing X and S-mode access to a U page must fault before data access.
    start();
    leaf(0, 8'h43);
    finish_case(1, 12);
    start();
    leaf(0, 8'h5b);
    finish_case(1, 12);
    // PTE bus errors are access faults; arbitrary returned data is discarded.
    start();
    accept_pte();
    bus_rerror = 1;
    respond_pte('1);
    bus_rerror = 0;
    finish_case(1, 1);
    // Reject a PTE read denied by PMP without issuing it externally.
    pmp_state.pmp_cfg_r[0] = 0;
    start();
    check(!bus_arvalid, "PMP-denied PTE read escaped");
    finish_case(1, 1);
    allow_all();
    if (XLEN == 64) begin
      pmp_state.pmp_mode_napot[0]=0;
      pmp_state.pmp_mode_na4[0]=1;
      pmp_state.pmp_raw_addr[0]=('h80000008>>2);
      pmp_state.pmp_napot_mask[0]=0;
      start();
      check(!bus_arvalid, "half-authorized Sv39 PTE read escaped");
      finish_case(1, 1);
      allow_all();
      request_vaddr = XLEN'(64'h0000008000000000);
      start();
      check(!bus_arvalid, "noncanonical VA emitted a PTE read");
      finish_case(1, 12);
      request_vaddr = 'h40000ffc;
    end
    // Reject the translated instruction word when PMP lacks execute permission.
    pmp_state.pmp_cfg_x[0] = 0;
    start();
    leaf(0, 8'h4b);
    finish_case(1, 1);
    allow_all();
    // The platform does not support implicit page-table reads from MMIO,
    // even when PMP grants full access. Reject before device side effects.
    satp_ppn = 'h02000;
    start();
    check(!bus_arvalid, "MMIO root PTE read escaped PMA check");
    finish_case(1, 1);
    satp_ppn = 'h80000;
    for (int depth = 1; depth < Levels; depth++) begin
      start();
      for (int l = 0; l < depth; l++) begin
        accept_pte();
        respond_pte((XLEN'(l == depth - 1 ? 'h02000000 : 'h80001000) >> 2) | XLEN'(1));
      end
      check(!bus_arvalid, "MMIO descendant PTE read escaped PMA check");
      finish_case(1, 1);
    end
    for (int depth = 0; depth < Levels; depth++) begin
      start();
      for (int l = 0; l < depth; l++) begin
        accept_pte();
        respond_pte((XLEN'('h80001000) >> 2) | XLEN'(1));
      end
      accept_pte();
      kill = 1;
      tick(1);
      kill = 0;
      #1;
      repeat (4) begin
        check(!response_valid && !request_ready && !bus_arvalid, "cancelled PTW did not drain");
        tick(1);
      end
      respond_pte('1);
      finish_case(1, 1);
    end
    start();
    accept_pte();
    kill = 1;
    respond_pte('1);
    kill = 0;
    finish_case(1, 1);
    // Cancellation before the PTW request also acknowledges the obligation.
    request_valid = 1;
    tick(1);
    request_valid=0;
    kill=1;
    tick(1);
    kill = 0;
    finish_case(0, 0);
    // Bare still checks physical execute permission and never starts a walker.
    mmu_en=0;
    request_vaddr='h81000000;
    start();
    check(!bus_arvalid, "Bare emitted a page-table request");
    finish_case(0, 0);
    check(response_paddr == request_vaddr && response_pbmt == 0, "Bare translation mismatch");
    // Exhaust all terminal PTE flags in both lower privilege modes. This
    // uses the actual walker and fetch permission/PMP composition. D is
    // deliberately varied even though instruction access only requires A.
    mmu_en=1;
    request_vaddr='h40000ffc;
    pbmte=0;
    satp_ppn='h80000;
    for (int mode = 0; mode < 2; mode++) begin
      priv = mode == 0 ? `RAPT_PRIV_S : `RAPT_PRIV_U;
      for (int flags = 0; flags < 256; flags++) begin
        automatic bit allowed;
        allowed=(flags & 1)!=0 && (flags & 8)!=0 && (flags & 64)!=0
          && !((flags & 4)!=0 && (flags & 2)==0)
          && (((flags & 16)!=0)==(mode==1));
        start();
        leaf(0, 8'(flags));
        finish_case(!allowed, 12);
        if (allowed) check(response_paddr == XLEN'('h81000ffc), "permission matrix PA mismatch");
      end
    end
    $display("PASS: real fetch translation and 512 S/U terminal-PTE permission cases XLEN=%0d",
             XLEN);
    $finish;
  end
endmodule
