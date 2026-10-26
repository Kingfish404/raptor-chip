`include "rapt.svh"
`include "rapt_soc_if.svh"

module tb_l2_release_probe;
  localparam int XLEN = `RAPT_XLEN;
  localparam int IdW = 4;
  localparam int LineBeats = 64 / (XLEN / 8);
  localparam logic [XLEN-1:0] OwnerAddr = XLEN'('h80000100);
  localparam logic [XLEN-1:0] MissAddr = OwnerAddr + XLEN'('h10000);
  localparam logic [XLEN-1:0] OtherOwnerAddr = OwnerAddr + XLEN'('h20000);
  logic clock = 1'b0, reset = 1'b1;
  logic probe_valid, probe_ready = 1'b0;
  logic cbo_inval = 1'b0;
  logic writeback_pending = 1'b0;
  logic [XLEN-1:6] cbo_block = '0;
  logic [XLEN-1:0] probe_addr;
  logic release_valid = 1'b0, release_ready, release_ack;
  logic [XLEN-1:0] release_addr = '0, release_data = '0;
  logic release_has_data = 1'b1, release_mask = 1'b1, release_last = 1'b0;
  axi4_if #(
      .XLEN(XLEN),
      .ID_W(IdW)
  ) axi_s ();
  axi4_if #(
      .XLEN(XLEN),
      .ID_W(IdW)
  ) axi_m ();
  rapt_l2 #(
      .XLEN(XLEN),
      .ID_W(IdW)
  ) dut (
      .clock,
      .reset,
      .cbo_inval_i(cbo_inval),
      .cbo_block_i(cbo_block),
      .l1d_writeback_pending_i(writeback_pending),
      .probe_valid_o(probe_valid),
      .probe_addr_o(probe_addr),
      .probe_ready_i(probe_ready),
      .release_valid_i(release_valid),
      .release_addr_i(release_addr),
      .release_data_i(release_data),
      .release_has_data_i(release_has_data),
      .release_mask_i(release_mask),
      .release_last_i(release_last),
      .release_ready_o(release_ready),
      .release_ack_o(release_ack),
      .axi_s,
      .axi_m
  );
  always #5 clock = ~clock;
  `include "tb_common.svh"
  `include "tb_l2_axi_tasks.svh"
  function automatic logic [15:0] next_lfsr(input logic [15:0] value);
    return {value[14:0], value[15] ^ value[13] ^ value[12] ^ value[10]};
  endfunction
  task automatic run_case(input bit with_data, input bit partial, input bit fail_writeback,
                          input bit other_tag = 1'b0, input bit control_request = 1'b0);
    logic [IdW-1:0] outer_id, write_id;
    logic [XLEN-1:0] outer_addr;
    logic [7:0] outer_len;
    logic [2:0] owner_way;
    bit got_ack;
    release_valid = 1'b0;
    cbo_inval = 1'b0;
    writeback_pending = 1'b0;
    reset = 1'b1;
    init_l2_axi(1'b1);
    tick(5);
    reset = 1'b0;
    for (int cycle = 0; cycle < 1100 && !axi_s.awready; cycle++) tick(1);
    check(axi_s.awready, "directory wipe timed out");
    axi_s.rready = 1'b0;
    send_l2_ar(OwnerAddr, 4'h2);
    accept_l2_downstream_ar(outer_id, outer_addr, outer_len);
    owner_way = dut.ms_way[0];
    for (int beat = 0; beat < LineBeats; beat++)
      return_l2_downstream_r(outer_id, XLEN'('h1000 + beat), beat == LineBeats - 1);
    for (int cycle = 0; cycle < 64 && !axi_s.rvalid; cycle++) tick(1);
    check(axi_s.rvalid && axi_s.rdata == XLEN'('h1000), "owner refill failed");
    axi_s.rready = 1'b1;
    for (int cycle = 0; cycle < 64 && (dut.ms_busy || dut.rs != 0); cycle++) tick(1);
    axi_s.rready = 1'b0;
    if (other_tag) begin
      // Preserve the first owner while installing another owned way in the
      // same set. Its voluntary Release must not change the victim snapshot.
      for (
          int attempt = 0;
          attempt < 64 && next_lfsr(
              dut.g_boom_directory.u_directory.victim_lfsr
          ) [9:7] == owner_way;
          attempt++
      ) begin
        send_l2_ar(OwnerAddr, 4'h2);
        for (int cycle = 0; cycle < 64 && !axi_s.rvalid; cycle++) tick(1);
        check(axi_s.rvalid && axi_s.rdata == XLEN'('h1000), "owner preservation hit failed");
        axi_s.rready = 1'b1;
        tick(1);
        axi_s.rready = 1'b0;
      end
      check(next_lfsr(dut.g_boom_directory.u_directory.victim_lfsr) [9:7] != owner_way,
            "could not preserve the first owned way");
      send_l2_ar(OtherOwnerAddr, 4'h2);
      accept_l2_downstream_ar(outer_id, outer_addr, outer_len);
      for (int beat = 0; beat < LineBeats; beat++)
      return_l2_downstream_r(outer_id, XLEN'('h2000 + beat), beat == LineBeats - 1);
      for (int cycle = 0; cycle < 64 && !axi_s.rvalid; cycle++) tick(1);
      check(axi_s.rvalid && axi_s.rdata == XLEN'('h2000), "second owner refill failed");
      axi_s.rready = 1'b1;
      for (int cycle = 0; cycle < 64 && (dut.ms_busy || dut.rs != 0); cycle++) tick(1);
      axi_s.rready = 1'b0;
    end
    for (
        int attempt = 0;
        attempt < 64 && next_lfsr(dut.g_boom_directory.u_directory.victim_lfsr) [9:7] != owner_way;
        attempt++
    ) begin
      send_l2_ar(OwnerAddr, 4'h2);
      for (int cycle = 0; cycle < 64 && !axi_s.rvalid; cycle++) tick(1);
      check(axi_s.rvalid && axi_s.rdata == XLEN'('h1000), "replacement advance hit failed");
      axi_s.rready = 1'b1;
      tick(1);
      axi_s.rready = 1'b0;
    end
    check(next_lfsr(dut.g_boom_directory.u_directory.victim_lfsr) [9:7] == owner_way,
          "could not select the owned victim");
    probe_ready = 1'b0;
    if (control_request) begin
      // Hold the control scheduler while two tags coalesce into a broad
      // request, then let its first owned way wait for a different-tag C.
      writeback_pending = other_tag;
      cbo_block = OwnerAddr[XLEN-1:6];
      cbo_inval = 1'b1;
      tick(1);
      if (other_tag) begin
        cbo_block = OtherOwnerAddr[XLEN-1:6];
        tick(1);
      end
      cbo_inval = 1'b0;
      writeback_pending = 1'b0;
    end else send_l2_ar(MissAddr, 4'h3);
    for (int cycle = 0; cycle < 64 && !probe_valid; cycle++) tick(1);
    check(probe_valid && probe_addr == OwnerAddr, "miss did not probe the owned victim");
    // The owner is finishing a voluntary Release before it can answer Probe.
    // C must pre-empt the ordinary request and forward its dirty metadata.
    for (int beat = 0; beat < (with_data ? LineBeats : 1); beat++) begin
      release_addr = (other_tag ? OtherOwnerAddr : OwnerAddr) + XLEN'(beat * (XLEN / 8));
      release_data = XLEN'('h9000 + beat);
      release_has_data = with_data;
      release_mask = with_data && (!partial || beat == 2);
      release_last = !with_data || beat == LineBeats - 1;
      release_valid = 1'b1;
      #1;
      check(release_ready, "C data was blocked while Probe waited");
      tick(1);
      release_valid = 1'b0;
    end
    got_ack = 1'b0;
    for (int cycle = 0; cycle < 128 && !got_ack; cycle++) begin
      #1;
      check(!axi_m.awvalid && !axi_m.arvalid, "ordinary miss escaped before C metadata commit");
      got_ack = release_ack;
      tick(1);
    end
    check(got_ack, "C ReleaseAck deadlocked behind the ordinary victim Probe");
    if (other_tag) begin
      for (int cycle = 0; cycle < 8; cycle++) begin
        check(probe_valid && probe_addr == OwnerAddr && !axi_m.awvalid && !axi_m.arvalid,
              "different-tag C incorrectly completed the victim Probe");
        if (control_request)
          check(!dut.cbo_entry[21] && dut.cbo_entry[18],
                "different-tag C changed the current CBO way metadata");
        else
          check(!dut.victim_dirty_q && dut.victim_clients_q,
                "different-tag C changed the saved victim metadata");
        tick(1);
      end
      probe_ready = 1'b1;
      tick(1);
      probe_ready = 1'b0;
    end
    if (with_data && (!other_tag || control_request)) begin
      for (int cycle = 0; cycle < 64 && !axi_m.awvalid; cycle++) begin
        if (control_request && other_tag)
          check(!probe_valid, "broad CBO probed a later way after its C ReleaseAck");
        tick(1);
      end
      check(axi_m.awvalid && axi_m.awaddr == (other_tag ? OtherOwnerAddr : OwnerAddr),
            "nested C dirty metadata was not forwarded to victim writeback");
      write_id = axi_m.awid;
      axi_m.awready = 1'b1;
      tick(1);
      axi_m.awready = 1'b0;
      axi_m.wready = 1'b1;
      for (int beat = 0; beat < LineBeats; beat++) begin
        for (int cycle = 0; cycle < 64 && !axi_m.wvalid; cycle++) tick(1);
        check(
            axi_m.wvalid && axi_m.wdata == XLEN'((!partial || beat == 2 ? 'h9000 : 'h1000) + beat)
            && axi_m.wlast == (beat == LineBeats - 1),
            "nested C victim data was lost");
        tick(1);
      end
      axi_m.wready = 1'b0;
      return_l2_downstream_b(write_id, fail_writeback ? 2'b10 : 2'b00);
    end
    if (control_request) begin
      for (int cycle = 0; cycle < 64 && dut.cbo_busy; cycle++) tick(1);
      check(!dut.cbo_busy, "pre-empted CBO did not complete");
      send_l2_ar(OwnerAddr, 4'h1);
      accept_l2_downstream_ar(outer_id, outer_addr, outer_len);
      check(outer_addr == OwnerAddr, "CBO failed to invalidate the released line");
      for (int beat = 0; beat < LineBeats; beat++)
      return_l2_downstream_r(outer_id, XLEN'('hb000 + beat), beat == LineBeats - 1);
      for (int cycle = 0; cycle < 64 && !axi_s.rvalid; cycle++) tick(1);
      check(
          axi_s.rvalid && axi_s.rid == 4'h1 && axi_s.rdata == XLEN'('hb000) && axi_s.rresp == 2'b00,
          "post-CBO read failed");
    end else if (fail_writeback) begin
      for (int cycle = 0; cycle < 64 && !axi_s.rvalid; cycle++) tick(1);
      check(axi_s.rvalid && axi_s.rid == 4'h3 && axi_s.rresp == 2'b10,
            "failed nested victim writeback did not report the primary error");
      axi_s.rready = 1'b1;
      tick(1);
      axi_s.rready = 1'b0;
      send_l2_ar(OwnerAddr, 4'h1);
      for (int cycle = 0; cycle < 64 && !axi_s.rvalid; cycle++) begin
        check(!axi_m.arvalid, "failed writeback discarded the released resident line");
        tick(1);
      end
      check(axi_s.rvalid && axi_s.rdata == XLEN'('h9000) && axi_s.rresp == 2'b00,
            "failed writeback lost already-acknowledged ReleaseData");
    end else begin
      accept_l2_downstream_ar(outer_id, outer_addr, outer_len);
      check(outer_addr == MissAddr, "ordinary request resumed at the wrong address");
      for (int beat = 0; beat < LineBeats; beat++)
      return_l2_downstream_r(outer_id, XLEN'('ha000 + beat), beat == LineBeats - 1);
      for (int cycle = 0; cycle < 64 && !axi_s.rvalid; cycle++) tick(1);
      check(
          axi_s.rvalid && axi_s.rid == 4'h3 && axi_s.rdata == XLEN'('ha000) && axi_s.rresp == 2'b00,
          "pre-empted ordinary request did not resume");
      if (other_tag) begin
        axi_s.rready = 1'b1;
        tick(1);
        axi_s.rready = 1'b0;
        send_l2_ar(OtherOwnerAddr, 4'h1);
        for (int cycle = 0; cycle < 64 && !axi_s.rvalid; cycle++) begin
          check(!axi_m.arvalid, "different-tag Release was evicted with the victim");
          tick(1);
        end
        check(axi_s.rvalid && axi_s.rdata == XLEN'('h9000) && axi_s.rresp == 2'b00,
              "different-tag ReleaseData was lost");
      end
    end
    $display("PASS: nested C data=%0d partial=%0d failed-B=%0d other-tag=%0d CBO=%0d", with_data,
             partial, fail_writeback, other_tag, control_request);
  endtask
  initial begin
    run_case(1'b1, 1'b0, 1'b0);
    run_case(1'b0, 1'b0, 1'b0);
    run_case(1'b1, 1'b1, 1'b0);
    run_case(1'b1, 1'b0, 1'b1);
    run_case(1'b1, 1'b0, 1'b0, 1'b1);
    run_case(1'b1, 1'b0, 1'b0, 1'b0, 1'b1);
    run_case(1'b0, 1'b0, 1'b0, 1'b0, 1'b1);
    run_case(1'b1, 1'b1, 1'b0, 1'b0, 1'b1);
    run_case(1'b1, 1'b0, 1'b0, 1'b1, 1'b1);
    $display("PASS: nested C Release pre-empts victim Probe and forwards dirty metadata");
    $finish;
  end
endmodule
