`include "rapt.svh"
`include "rapt_if.svh"

// IDU bounded count against an independent ordered-list model. IFU widths are
// covered by tb_ifu_response_stage; this isolates decode refill/consume races.
module tb_frontend_count;
  localparam int XLEN  = `RAPT_XLEN;
  localparam int Width = rapt_pkg::DecodeWidth;
  logic clock = 0, reset = 1;
  always #5 clock = ~clock;
  cmu_bcast_if cmu_bcast ();
  csr_bcast_if csr_bcast ();
  ifu_idu_if ifu_idu ();
  idu_rnu_if idu_rnu ();
  idu_bpu_if idu_bpu ();
  rapt_recovery_if recovery ();
  rapt_idu dut (.*);
  `include "tb_core_bcast_defaults.svh"
  logic [XLEN-1:0] expected[$];
  logic [XLEN-1:0] next_offer = XLEN'('h80000000);
  logic [XLEN-1:0] discarded;
  logic [31:0] rng = 32'hbeaf3219;
  int accepted = 0, retired = 0, full_cycles = 0, replacements = 0;
  function automatic logic [31:0] random_word();
    rng ^= rng << 13;
    rng ^= rng >> 17;
    rng ^= rng << 5;
    return rng;
  endfunction
  initial begin
    init_cmu_bcast_defaults();
    init_csr_bcast_defaults(`RAPT_PRIV_M, '0, 0);
    recovery.pending=0;
    recovery.redirect_valid=0;
    recovery.target=0;
    idu_bpu.ras_valid=0;
    idu_bpu.ras_addr=0;
    ifu_idu.valid='{default:0};
    ifu_idu.slot='{default:'0};
    idu_rnu.ready='{default:0};
    assert ($bits(dut.count) == $clog2(Width + 1))
    else $fatal(1, "IDU count shape");
    repeat (2) @(negedge clock);
    reset = 0;
    for (int cycle = 0; cycle < 2000; cycle++) begin
      automatic int offer_count = cycle < 64 ? Width : int'(random_word() % (Width+1));
      automatic int ready_count = cycle < 16 ? 0 : cycle < 64 ? Width
          : int'(random_word() % (Width+1));
      int popped, pushed;
      cmu_bcast.flush_pipe = cycle % 53 == 52;
      cmu_bcast.sys_resume = cycle % 79 == 78;
      recovery.pending = cycle % 97 inside {94, 95, 96};
      for (int s = 0; s < Width; s++) begin
        ifu_idu.valid[s] = s < offer_count;
        ifu_idu.slot[s] = '0;
        ifu_idu.slot[s].inst = 32'h00000013;
        ifu_idu.slot[s].pc = next_offer + XLEN'(4*s);
        ifu_idu.slot[s].pnpc = next_offer + XLEN'(4)*(XLEN'(s)+1);
        idu_rnu.ready[s] = s < ready_count;
      end
      #1;
      assert (32'(dut.count) == expected.size())
      else $fatal(1, "resident count");
      if (expected.size() == Width) full_cycles++;
      popped=0;
      pushed=0;
      if (cmu_bcast.flush_pipe || cmu_bcast.sys_resume || recovery.pending) begin
        assert (!ifu_idu.ready[0] && !idu_rnu.valid[0])
        else $fatal(1, "recovery accepted");
        expected.delete();
      end else begin
        for (int s = 0; s < Width; s++) begin
          // IDU exposes an ordered prefix through the first stalled slot;
          // younger slots are suppressed when an older slot is not accepted.
          assert (idu_rnu.valid[s] == (s < expected.size() && s <= ready_count))
          else $fatal(1, "output validity");
          if (idu_rnu.valid[s]) begin
            assert (!idu_rnu.slot[s].uop.trap
                    && idu_rnu.slot[s].uop.pc == expected[s]
                    && idu_rnu.slot[s].uop.pnpc == expected[s] + XLEN'(4))
            else $fatal(1, "decode stream corruption");
            if (idu_rnu.ready[s]) popped++;
          end
        end
        repeat (popped) discarded = expected.pop_front();
        for (int s = 0; s < Width; s++)
        if (ifu_idu.valid[s] && ifu_idu.ready[s]) begin
          expected.push_back(ifu_idu.slot[s].pc);
          pushed++;
        end
      end
      accepted += pushed;
      retired += popped;
      if (popped != 0 && pushed != 0) replacements++;
      next_offer += XLEN'(4 * pushed);
      @(posedge clock);
      #1;
      assert (32'(dut.count) == expected.size())
      else $fatal(1, "post-edge count");
      @(negedge clock);
    end
    assert (full_cycles > 10 && replacements > 20 && accepted > 100 && retired > 100)
    else $fatal(1, "insufficient count boundary coverage");
    $display(
        "PASS: IDU bounded count XLEN=%0d width=%0d accepted=%0d consumed=%0d full=%0d replacements=%0d",
        XLEN, Width, accepted, retired, full_cycles, replacements);
    $finish;
  end
  initial begin
    #100000;
    $fatal(1, "IDU count watchdog");
  end
endmodule
