`include "rapt.svh"
`include "rapt_if.svh"
module tb_ifu_l1i_stream;
  localparam int XLEN = `RAPT_XLEN;
  logic clock = 0, reset = 1;
  always #5 clock = ~clock;
  cmu_bcast_if cmu_bcast ();
  csr_bcast_if csr_bcast ();
  pmp_state_if pmp_state ();
  ifu_l1i_if ifu_l1i ();
  l1i_bus_if l1i_bus ();
  rapt_l1i cache_dut (
      .clock,
      .reset,
      .cmu_bcast,
      .csr_bcast,
      .pmp_state,
      .ifu_l1i,
      .l1i_bus,
      .io_authorized(1'b0),
      .io_start(),
      .io_owner_pc()
  );
  `include "tb_core_bcast_defaults.svh"
  `include "tb_pmp_state_defaults.svh"
  int unsigned requests[$], address;
  ifu_bpu_if ifu_bpu ();
  ifu_idu_if ifu_idu ();
  rapt_recovery_if #(.XLEN(XLEN)) recovery ();
  rapt_ifu dut (
      .clock,
      .reset,
      .cmu_bcast,
      .recovery,
      .ifu_bpu,
      .ifu_l1i,
      .ifu_idu,
      .ifu_hazard()
  );
  function automatic logic [15:0] half_at(input int unsigned addr);
    case ((addr >> 1) & 3)
      1: return 16'h0093; // ADDI x1,x0,imm starts at halfword offset 2.
      2: return 16'(((addr>>3)&1023)<<4);
      default: return 16'h0001; // C.NOP
    endcase
  endfunction
  function automatic logic [31:0] word_at(input int unsigned addr);
    return {half_at(addr + 2), half_at(addr)};
  endfunction
  assign l1i_bus.rready = l1i_bus.arvalid;
  always @(posedge clock)
    if (!reset && l1i_bus.arvalid && l1i_bus.rready) begin
      assert (!l1i_bus.ar_ptw)
      else $fatal(1, "unexpected PTW");
      requests.push_back(l1i_bus.araddr);
    end
  always @(negedge clock) begin
    l1i_bus.rvalid = 0;
    if (!reset && requests.size() != 0 && (cycles % 4) == 0) begin
      address = requests.pop_front();
      // AXI word reads occupy the addressed lane of the XLEN-wide data bus.
      l1i_bus.rdata = XLEN'(word_at(address)) << ((XLEN == 64 && address[2]) ? 32 : 0);
      l1i_bus.rvalid = 1;
    end
  end
  int cycles = 0, delivered = 0, compressed = 0, fullword = 0;
  int unsigned expected_pc;
  logic checking=0;
  always @(posedge clock) begin
    if (!reset) begin
      cycles++;
      if (checking && !cmu_bcast.flush_pipe && !recovery.pending) begin
        for (int slot = 0; slot < `RAPT_DECODE_WIDTH; slot++) begin
          if (ifu_idu.valid[slot] && ifu_idu.ready[slot]) begin
            if (ifu_idu.slot[slot].pc != XLEN'(expected_pc))
              $fatal(1, "stream PC got=%h expected=%h", ifu_idu.slot[slot].pc, expected_pc);
            if (ifu_idu.slot[slot].inst[15:0] != half_at(expected_pc))
              $fatal(1, "stream instruction low half mismatch pc=%h", expected_pc);
            if ((half_at(expected_pc) & 16'h3) == 16'h3) begin
              if (ifu_idu.slot[slot].inst[31:16] != half_at(expected_pc + 2))
                $fatal(1, "stream instruction high half mismatch pc=%h", expected_pc);
              expected_pc += 4;
              fullword++;
            end else begin
              expected_pc += 2;
              compressed++;
            end
            delivered++;
          end
        end
      end
    end
  end
  task automatic segment(input int unsigned target, input int kind);
    int start_count;
    @(negedge clock);
    checking=0;
    ifu_idu.ready='{default:0};
    if (kind == 1) begin
      recovery.pending=1;
      recovery.redirect_valid=1;
      recovery.target=XLEN'(target);
    end else begin
      cmu_bcast.flush_pipe=1;
      cmu_bcast.cpc=XLEN'(target);
      cmu_bcast.fence_i=(kind==2);
    end
    @(negedge clock);
    cmu_bcast.flush_pipe=0;
    cmu_bcast.fence_i=0;
    recovery.pending=0;
    recovery.redirect_valid=0;
    expected_pc=target;
    checking=1;
    start_count=delivered;
    while (delivered - start_count < 120) begin
      // Prefix ready masks include stalls and partial held-group acceptance.
      for (int slot = 0; slot < `RAPT_DECODE_WIDTH; slot++)
      ifu_idu.ready[slot] = (slot < (cycles % 5));
      @(negedge clock);
    end
    checking = 0;
  endtask
  initial begin
    init_cmu_bcast_defaults();
    init_csr_bcast_defaults(`RAPT_PRIV_M, '0, 1);
    init_pmp_state_defaults(1);
    ifu_bpu.taken=0;
    ifu_bpu.npc=0;
    ifu_bpu.aux_taken=0;
    ifu_idu.ready='{default:0};
    ifu_idu.resteer=0;
    ifu_idu.resteer_pc=0;
    recovery.pending=0;
    recovery.redirect_valid=0;
    recovery.target=0;
    l1i_bus.rvalid=0;
    l1i_bus.rdata=0;
    l1i_bus.ptw_rerr=0;
    l1i_bus.ptw_rvalid=0;
    l1i_bus.rlast=1;
    l1i_bus.rerr=0;
    l1i_bus.wready=0;
    l1i_bus.werr=0;
    l1i_bus.ptw_wready=0;
    l1i_bus.ptw_werr=0;
    repeat (4) @(negedge clock);
    reset = 0;
    for (int n = 0; n < 9; n++)
    segment('h80000000 + n * 4096 + (n % 3 == 0 ? 2 : n % 3 == 1 ? 62 : 4090), n % 3);
    if (compressed == 0 || fullword == 0) $fatal(1, "missing instruction length coverage");
    $display("PASS: IFU/L1I stream RV%0d segments=9 delivered=%0d compressed=%0d fullword=%0d",
             XLEN, delivered, compressed, fullword);
    $finish;
  end
  initial begin
    #2000000;
    $fatal(1, "IFU/L1I progress timeout");
  end
endmodule
