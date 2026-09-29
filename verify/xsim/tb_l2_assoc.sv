`include "rapt.svh"
`include "rapt_soc_if.svh"

module tb_l2_assoc;
  localparam int XLEN = `RAPT_XLEN;
  localparam int IdW = 4;
  localparam int LineBeats = 1 << `RAPT_L2_LINE_LEN;

  logic clock = 1'b0;
  logic reset = 1'b1;
  logic cbo_inval = 1'b0;
  logic [XLEN-1:6] cbo_block = '0;
  logic probe_valid, probe_ready = 1'b1;
  logic [XLEN-1:0] probe_addr;
  logic track_burst_merge_reads = 1'b0;
  int burst_merge_reads = 0;
  int burst_merge_writes = 0;
  int burst_sinkd_writes = 0;
  logic track_store_stream = 1'b0;
  int store_sinkd_writes = 0;
  int store_source_reads = 0;
  int store_source_writes = 0;
  logic track_block_read = 1'b0;
  int block_read_sinkd_writes = 0;
  int expected_burst_write_chunk = -1;
  int cycle_count = 0;
  int prior_burst_merge_cycle = 0;

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
      .cbo_inval_i  (cbo_inval),
      .cbo_block_i  (cbo_block),
      .probe_valid_o(probe_valid),
      .probe_addr_o (probe_addr),
      .probe_ready_i(probe_ready),
      .axi_s,
      .axi_m
  );

  always #5 clock = ~clock;
  int ar_stall_cycles = 0;
  always @(negedge clock) begin
    if (axi_s.arvalid && !axi_s.arready) ar_stall_cycles <= ar_stall_cycles + 1;
    else ar_stall_cycles <= 0;
    if (ar_stall_cycles == 60)
      $display(
          "AR STALL addr=%h id=%h rs=%0d msbusy=%b done=%b installed=%b replay=%b/%b source=%b C=%b probe=%b/%b r=%b rid=%h rready=%b",
          axi_s.araddr,
          axi_s.arid,
          dut.rs,
          dut.ms_busy,
          dut.ms_slot_done,
          dut.ms_installed,
          dut.ms_replay_pending,
          dut.ms_replay_active,
          dut.ms_source_active,
          dut.release_pending,
          probe_valid,
          probe_ready,
          axi_s.rvalid,
          axi_s.rid,
          axi_s.rready
      );
  end
  `include "tb_common.svh"
  `include "tb_l2_axi_tasks.svh"

  always @(posedge clock) begin
    cycle_count <= cycle_count + 1;
    if (!reset && track_burst_merge_reads) begin
      check(!dut.g_boom_banked_store.u_data_array.write_line_valid,
            "masked resident Put redundantly reinstalled the whole L2 line");
      if (dut.g_boom_banked_store.u_data_array.sink_d_write_valid
          && dut.g_boom_banked_store.u_data_array.sink_d_write_ready)
        burst_sinkd_writes <= burst_sinkd_writes + 1;
      if (dut.g_boom_banked_store.u_data_array.write_word_valid
          && dut.g_boom_banked_store.u_data_array.write_word_ready) begin
        if (expected_burst_write_chunk >= 0)
          check(
              dut.g_boom_banked_store.u_data_array.write_word_chunk
                == 3'(expected_burst_write_chunk),
              "masked resident Put wrote the wrong L2 bank beat");
        burst_merge_writes <= burst_merge_writes + 1;
      end
    end
    if (!reset && track_store_stream) begin
      check(!dut.g_boom_banked_store.u_data_array.write_line_valid,
            "scalar store miss reinstalled the whole L2 line");
      if (dut.g_boom_banked_store.u_data_array.sink_d_write_valid
          && dut.g_boom_banked_store.u_data_array.sink_d_write_ready)
        store_sinkd_writes <= store_sinkd_writes + 1;
      if (dut.g_boom_banked_store.u_data_array.read_valid
          && dut.g_boom_banked_store.u_data_array.read_ready)
        store_source_reads <= store_source_reads + 1;
      if (dut.g_boom_banked_store.u_data_array.write_word_valid
          && dut.g_boom_banked_store.u_data_array.write_word_ready)
        store_source_writes <= store_source_writes + 1;
    end
    if (!reset && track_block_read) begin
      check(!dut.g_boom_banked_store.u_data_array.write_line_valid,
            "blocking read miss reinstalled the whole L2 line");
      if (dut.blocking_refill_sinkd_valid
          && dut.g_boom_banked_store.u_data_array.sink_d_write_valid
          && dut.g_boom_banked_store.u_data_array.sink_d_write_ready)
        block_read_sinkd_writes <= block_read_sinkd_writes + 1;
    end
    if (!reset && track_burst_merge_reads
        && dut.g_boom_banked_store.u_data_array.read_valid
        && dut.g_boom_banked_store.u_data_array.read_ready) begin
      check(!dut.g_boom_banked_store.u_data_array.read_all_chunks,
            "masked Put merge reserved the whole L2 line");
      check(dut.g_boom_banked_store.u_data_array.read_chunk == 3'(burst_merge_reads / (64 / XLEN)),
            "masked Put merge did not read the next bank beat");
      if (burst_merge_reads != 0)
        check(cycle_count == prior_burst_merge_cycle + 1,
              "uncontended masked Put merge inserted a bubble between bank reads");
      prior_burst_merge_cycle <= cycle_count;
      burst_merge_reads <= burst_merge_reads + 1;
    end
  end

  function automatic logic [15:0] next_lfsr(input logic [15:0] value);
    return {value[14:0], value[15] ^ value[13] ^ value[12] ^ value[10]};
  endfunction

  task automatic read_line(
      input logic [XLEN-1:0] address, input bit miss, input logic [XLEN-1:0] evict_addr = '0,
      input logic [XLEN-1:0] evict_word1 = '0, input logic [XLEN-1:0] evict_word2 = '0,
      input logic [XLEN-1:0] evict_word4 = '0, input logic [1:0] evict_resp = 2'b00,
      input int interleave_outer_id = -1, input logic [XLEN-1:0] interleave_line_addr = '0,
      input int early_interleave_inner_id = -1, input bit hold_early_interleave = 1'b0,
      input bit complete_interleave_before_b = 1'b0);
    logic [IdW-1:0] id_seen;
    logic [XLEN-1:0] addr_seen;
    logic [7:0] len_seen;
    bit got_response;
    axi_s.rready = 1'b0;
    track_block_read = miss && evict_addr != '0 && evict_resp == 2'b00;
    block_read_sinkd_writes = 0;
    send_l2_ar(address, 4'h3);
    if (miss) begin
      if (evict_addr != '0) begin
        for (int cycle = 0; cycle < 64 && !axi_m.awvalid; cycle++) tick(1);
        check(
            axi_m.awvalid && axi_m.awaddr == evict_addr
                  && axi_m.awlen == 8'(LineBeats - 1) && axi_m.awid == 4'h3,
            "dirty eviction did not issue a full-line AW before refill");
        axi_m.awready = 1'b1;
        tick(1);
        axi_m.awready = 1'b0;
        axi_m.wready  = 1'b1;
        for (int beat = 0; beat < LineBeats; beat++) begin
          logic [XLEN-1:0] expected;
          expected = evict_addr + XLEN'(beat);
          if (beat == 1) expected = evict_word1;
          if (beat == 2) expected = evict_word2;
          if (beat == 4) expected = evict_word4;
          for (int cycle = 0; cycle < 64 && !axi_m.wvalid; cycle++) tick(1);
          check(
              axi_m.wvalid && axi_m.wdata == expected && (&axi_m.wstrb)
                    && axi_m.wlast == (beat == LineBeats - 1),
              $sformatf("dirty eviction beat %0d: got %h expected %h", beat, axi_m.wdata, expected
              ));
          tick(1);
        end
        axi_m.wready = 1'b0;
        check(!axi_m.arvalid, "refill AR preceded dirty eviction B");
        if (early_interleave_inner_id >= 0) begin
          check(interleave_outer_id >= 0 && evict_resp == 2'b00,
                "early interleaved response needs a successful dirty eviction");
          return_l2_downstream_r(IdW'(interleave_outer_id), interleave_line_addr, LineBeats == 1);
          for (int cycle = 0; cycle < 64 && !axi_s.rvalid; cycle++) tick(1);
          check(
              axi_s.rvalid && axi_s.rid == IdW'(early_interleave_inner_id)
                    && axi_s.rdata == interleave_line_addr && axi_s.rresp == 2'b00
                    && axi_s.rlast && dut.rs == dut.R_EVICT_B,
              "independent MSHR critical word waited for dirty eviction B");
          if (!hold_early_interleave) begin
            axi_s.rready = 1'b1;
            tick(1);
            axi_s.rready = 1'b0;
          end
          if (complete_interleave_before_b) begin
            for (int beat = 1; beat < LineBeats; beat++)
            return_l2_downstream_r(IdW'(interleave_outer_id), interleave_line_addr + XLEN'(beat),
                                   beat == LineBeats - 1);
            for (int cycle = 0; cycle < 64 && !dut.ms_installed[interleave_outer_id]; cycle++)
            tick(1);
            check(dut.ms_installed[interleave_outer_id] && dut.rs == dut.R_EVICT_B && !axi_m.bvalid,
                  "clean MSHR did not install while dirty victim B was pending");
          end
        end
        return_l2_downstream_b(4'h3, evict_resp);
      end
      if (evict_resp == 2'b00) begin
        accept_l2_downstream_ar(id_seen, addr_seen, len_seen);
        check(
            id_seen < 4'd5 && (interleave_outer_id < 0 || id_seen != IdW'(interleave_outer_id))
                  && addr_seen == address && len_seen == 8'(LineBeats - 1),
            "miss did not request the expected aligned line");
        for (int beat = 0; beat < LineBeats; beat++) begin
          if (interleave_outer_id >= 0 && !complete_interleave_before_b
              && beat + (early_interleave_inner_id >= 0) < LineBeats)
            return_l2_downstream_r(
                IdW'(interleave_outer_id),
                interleave_line_addr + XLEN'(beat + (early_interleave_inner_id >= 0)),
                beat + (early_interleave_inner_id >= 0) == LineBeats - 1);
          return_l2_downstream_r(id_seen, address + XLEN'(beat), beat == LineBeats - 1);
        end
        if (hold_early_interleave) begin
          check(
              axi_s.rvalid && axi_s.rid == IdW'(early_interleave_inner_id)
                    && axi_s.rdata == interleave_line_addr && axi_s.rresp == 2'b00
                    && axi_s.rlast,
              "blocking refill overwrote an independent MSHR response under backpressure");
          axi_s.rready = 1'b1;
          tick(1);
          axi_s.rready = 1'b0;
        end
      end else check(!axi_m.arvalid, "failed eviction still issued a refill AR");
    end
    got_response = 1'b0;
    for (int cycle = 0; cycle < 64 && !got_response; cycle++) begin
      if (!miss || evict_resp != 2'b00)
        check(!axi_m.arvalid, "resident/error path caused downstream AR");
      if (axi_s.rvalid) begin
        if (evict_resp != 2'b00)
          check(axi_s.rresp == evict_resp && axi_s.rlast,
                "failed eviction did not report the downstream error");
        else
          check(axi_s.rid == 4'h3 && axi_s.rdata == address && axi_s.rresp == 2'b00 && axi_s.rlast,
                "L2 returned the wrong resident line");
        axi_s.rready = 1'b1;
        tick(1);
        axi_s.rready = 1'b0;
        got_response = 1'b1;
      end else tick(1);
    end
    check(got_response, "L2 read response timed out");
    tick(3);  // allow the registered line install and SRAM read edge to retire
    if (track_block_read)
      check(block_read_sinkd_writes == LineBeats,
            "dirty-victim read miss did not write every refill beat through SinkD");
    track_block_read = 1'b0;
  endtask

  task automatic read_hit_word(input logic [XLEN-1:0] address, input logic [XLEN-1:0] expected);
    bit got_response, saved_probe_ready;
    axi_s.rready = 1'b0;
    send_l2_ar(address, 4'h3);
    got_response = 1'b0;
    for (int cycle = 0; cycle < 64 && !got_response; cycle++) begin
      check(!axi_m.arvalid, "resident word caused another downstream AR");
      if (probe_valid) begin
        // This foreign Get revokes the clean mock client's copy. Tests that
        // need to preserve ownership for replacement use read_d_client_hit.
        check(probe_addr == (address & ~XLEN'(63)) && !axi_s.rvalid,
              "foreign resident Get probed the wrong owner or replied early");
        saved_probe_ready = probe_ready;
        probe_ready = 1'b1;
        tick(1);
        probe_ready = saved_probe_ready;
      end
      if (axi_s.rvalid) begin
        check(axi_s.rdata == expected && axi_s.rresp == 2'b00 && axi_s.rlast,
              "L2 returned the wrong banked word");
        axi_s.rready = 1'b1;
        tick(1);
        axi_s.rready = 1'b0;
        got_response = 1'b1;
      end else tick(1);
    end
    check(got_response, "L2 banked word response timed out");
  endtask

  task automatic read_d_client_miss(input logic [XLEN-1:0] line_addr);
    logic [IdW-1:0] id_seen;
    logic [XLEN-1:0] addr_seen;
    logic [7:0] len_seen;
    bit got_response;
    axi_s.rready = 1'b0;
    send_l2_ar(line_addr, 4'h2);
    accept_l2_downstream_ar(id_seen, addr_seen, len_seen);
    check(id_seen < 4'd5 && addr_seen == line_addr && len_seen == 8'(LineBeats - 1),
          "D-client miss requested the wrong outer line");
    for (int beat = 0; beat < LineBeats; beat++)
      return_l2_downstream_r(id_seen, line_addr + XLEN'(beat), beat == LineBeats - 1);
    got_response = 1'b0;
    for (int cycle = 0; cycle < 64 && !got_response; cycle++) begin
      if (axi_s.rvalid) begin
        check(axi_s.rid == 4'h2 && axi_s.rdata == line_addr && !axi_s.rresp && axi_s.rlast,
              "D-client miss returned the wrong word");
        axi_s.rready = 1'b1;
        tick(1);
        axi_s.rready = 1'b0;
        got_response = 1'b1;
      end else tick(1);
    end
    check(got_response, "D-client miss response timed out");
    tick(3);
  endtask

  task automatic read_d_client_hit(input logic [XLEN-1:0] address, input logic [XLEN-1:0] expected,
                                   input logic [IdW-1:0] owner_id = 4'h2);
    bit got_response;
    axi_s.rready = 1'b0;
    send_l2_ar(address, owner_id);
    got_response = 1'b0;
    for (int cycle = 0; cycle < 64 && !got_response; cycle++) begin
      check(!axi_m.arvalid, "D-client hit caused another downstream AR");
      if (axi_s.rvalid) begin
        check(axi_s.rid == owner_id && axi_s.rdata == expected && !axi_s.rresp && axi_s.rlast,
              "D-client hit returned the wrong word");
        axi_s.rready = 1'b1;
        tick(1);
        axi_s.rready = 1'b0;
        got_response = 1'b1;
      end else tick(1);
    end
    check(got_response, "D-client hit response timed out");
    tick(3);
  endtask

  task automatic read_miss_after_probe(
      input logic [XLEN-1:0] victim_addr, input logic [XLEN-1:0] new_addr,
      input int interleave_outer_id = -1, input logic [XLEN-1:0] interleave_line_addr = '0,
      input int early_interleave_inner_id = -1, input bit complete_interleave_before_probe = 1'b0,
      input bit complete_interleave_during_refill = 1'b0, input bit critical_during_refill = 1'b0,
      input bit expect_last_dir_stall = 1'b0, input bit critical_collision = 1'b0);
    logic [IdW-1:0] id_seen;
    logic [XLEN-1:0] addr_seen;
    logic [7:0] len_seen;
    bit got_response;
    bit blocking_response_consumed;
    blocking_response_consumed = 1'b0;
    probe_ready = 1'b0;
    axi_s.rready = 1'b0;
    send_l2_ar(new_addr, 4'h3);
    for (int cycle = 0; cycle < 64 && !probe_valid; cycle++) tick(1);
    check(probe_valid && probe_addr == victim_addr,
          "L2 replacement did not probe the D-side victim");
    repeat (3) begin
      check(!axi_m.arvalid && !axi_m.awvalid,
            "L2 replaced a client-owned line before probe acknowledgment");
      tick(1);
    end
    if (early_interleave_inner_id >= 0 && !critical_during_refill) begin
      check(interleave_outer_id >= 0, "early probe response needs an independent MSHR");
      return_l2_downstream_r(IdW'(interleave_outer_id), interleave_line_addr, LineBeats == 1);
      for (int cycle = 0; cycle < 64 && !axi_s.rvalid; cycle++) tick(1);
      check(
          axi_s.rvalid && axi_s.rid == IdW'(early_interleave_inner_id)
                && axi_s.rdata == interleave_line_addr && axi_s.rresp == 2'b00
                && axi_s.rlast && probe_valid && !probe_ready,
          "independent MSHR critical word waited for client probe acknowledgment");
      axi_s.rready = 1'b1;
      tick(1);
      axi_s.rready = 1'b0;
      if (complete_interleave_before_probe) begin
        for (int beat = 1; beat < LineBeats; beat++)
        return_l2_downstream_r(IdW'(interleave_outer_id), interleave_line_addr + XLEN'(beat),
                               beat == LineBeats - 1);
        for (int cycle = 0; cycle < 64 && !dut.ms_direct_complete; cycle++) tick(1);
        check(dut.ms_direct_complete && dut.dir_write_clients && dut.dir_write_state == 2'b10,
              "D-client MSHR direct install did not preserve Trunk ownership");
        for (int cycle = 0; cycle < 64 && !dut.ms_installed[interleave_outer_id]; cycle++) tick(1);
        check(dut.ms_installed[interleave_outer_id] && probe_valid && !probe_ready,
              "clean MSHR did not install while client ProbeAck was pending");
      end
    end
    probe_ready = 1'b1;
    tick(1);
    probe_ready = 1'b0;
    accept_l2_downstream_ar(id_seen, addr_seen, len_seen);
    check(
        id_seen < 4'd5 && (interleave_outer_id < 0 || id_seen != IdW'(interleave_outer_id))
              && addr_seen == new_addr && len_seen == 8'(LineBeats - 1),
        "L2 did not refill after client probe acknowledgment");
    for (int beat = 0; beat < LineBeats; beat++) begin
      if (critical_during_refill && beat == 0) begin
        return_l2_downstream_r(IdW'(interleave_outer_id), interleave_line_addr, 1'b0);
        if (critical_collision) begin
          return_l2_downstream_r(id_seen, new_addr, 1'b0);
          for (int cycle = 0; cycle < 64 && !axi_s.rvalid; cycle++) tick(1);
          check(
              axi_s.rvalid && axi_s.rid == 4'h3 && axi_s.rdata == new_addr
                    && axi_s.rresp == 2'b00 && axi_s.rlast && dut.rs == dut.R_MISS_R,
              "blocking critical beat lost arbitration to independent MSHR");
          axi_s.rready = 1'b1;
          tick(1);
          axi_s.rready = 1'b0;
          blocking_response_consumed = 1'b1;
        end
        for (int cycle = 0; cycle < 64 && !axi_s.rvalid; cycle++) tick(1);
        check(
            axi_s.rvalid && axi_s.rid == IdW'(early_interleave_inner_id)
                  && axi_s.rdata == interleave_line_addr && axi_s.rresp == 2'b00
                  && axi_s.rlast && dut.rs == dut.R_MISS_R,
            "independent MSHR critical word waited for blocking refill completion");
        axi_s.rready = 1'b1;
        tick(1);
        axi_s.rready = 1'b0;
      end
      if (interleave_outer_id >= 0 && !complete_interleave_before_probe
          && beat + (early_interleave_inner_id >= 0) < LineBeats)
        return_l2_downstream_r(
            IdW'(interleave_outer_id),
            interleave_line_addr + XLEN'(beat + (early_interleave_inner_id >= 0)),
            beat + (early_interleave_inner_id >= 0) == LineBeats - 1);
      if (complete_interleave_during_refill && beat == LineBeats - 2) begin
        if (!expect_last_dir_stall)
          for (int cycle = 0; cycle < 64 && !dut.ms_direct_complete; cycle++) tick(1);
        check(
            dut.ms_direct_complete && dut.dir_write_clients && dut.dir_write_state == 2'b10
                  && dut.rs == dut.R_MISS_R,
            "D-client MSHR did not commit during a different-set outer refill");
        if (!expect_last_dir_stall) begin
          for (int cycle = 0; cycle < 64 && !dut.ms_installed[interleave_outer_id]; cycle++)
          tick(1);
          check(dut.ms_installed[interleave_outer_id],
                "D-client MSHR did not install before blocking refill ended");
        end
      end
      if (expect_last_dir_stall && beat == LineBeats - 1) begin
        check(
            dut.ms_installed[interleave_outer_id] && !dut.dir_write_ready && dut.rs == dut.R_MISS_R,
            "direct MSHR metadata write did not occupy the directory queue");
        axi_m.rid = id_seen;
        axi_m.rdata = new_addr + XLEN'(beat);
        axi_m.rlast = 1'b1;
        axi_m.rvalid = 1'b1;
        #1;
        check(!axi_m.rready,
              "blocking refill accepted its final beat before directory queue drained");
      end
      if (!(critical_collision && beat == 0))
        return_l2_downstream_r(id_seen, new_addr + XLEN'(beat), beat == LineBeats - 1);
    end
    got_response = blocking_response_consumed;
    for (int cycle = 0; cycle < 64 && !got_response; cycle++) begin
      if (axi_s.rvalid) begin
        check(axi_s.rid == 4'h3 && axi_s.rdata == new_addr && !axi_s.rresp && axi_s.rlast,
              "post-probe refill returned the wrong word");
        axi_s.rready = 1'b1;
        tick(1);
        axi_s.rready = 1'b0;
        got_response = 1'b1;
      end else tick(1);
    end
    check(got_response, "post-probe refill response timed out");
    probe_ready = 1'b1;
    tick(3);
  endtask

  task automatic read_miss_after_probe_refill_error(input logic [XLEN-1:0] victim_addr,
                                                    input logic [XLEN-1:0] new_addr);
    logic [IdW-1:0] id_seen;
    logic [XLEN-1:0] addr_seen;
    logic [7:0] len_seen;
    bit got_response;
    probe_ready = 1'b0;
    axi_s.rready = 1'b0;
    track_block_read = 1'b1;
    block_read_sinkd_writes = 0;
    send_l2_ar(new_addr + XLEN'(4 * XLEN / 8), 4'h3);
    for (int cycle = 0; cycle < 64 && !probe_valid; cycle++) tick(1);
    check(probe_valid && probe_addr == victim_addr,
          "failed-refill read did not probe its client-owned victim");
    probe_ready = 1'b1;
    tick(1);
    probe_ready = 1'b0;
    accept_l2_downstream_ar(id_seen, addr_seen, len_seen);
    check(id_seen < 4'd5 && addr_seen == new_addr && len_seen == 8'(LineBeats - 1),
          "failed-refill read requested the wrong outer line");
    for (int beat = 0; beat < LineBeats; beat++)
      return_l2_downstream_r(id_seen, new_addr + XLEN'(beat), beat == LineBeats - 1,
                             beat == 2 ? 2'b10 : 2'b00);
    got_response = 1'b0;
    for (int cycle = 0; cycle < 64 && !got_response; cycle++) begin
      if (axi_s.rvalid) begin
        check(axi_s.rid == 4'h3 && axi_s.rresp == 2'b10 && axi_s.rlast,
              "failed blocking read did not return its outer refill error");
        axi_s.rready = 1'b1;
        tick(1);
        axi_s.rready = 1'b0;
        got_response = 1'b1;
      end else tick(1);
    end
    check(got_response, "failed blocking read response timed out");
    check(block_read_sinkd_writes == 2,
          "blocking read wrote a denied or post-error refill beat to SinkD");
    track_block_read = 1'b0;
    tick(3);
    read_line(new_addr, 1'b1);
  endtask

  task automatic write_hit_word(input logic [XLEN-1:0] address, input logic [XLEN-1:0] data,
                                input logic [XLEN-1:0] interleave_read = '0);
    bit got_response;
    axi_s.bready = 1'b0;
    send_l2_aw(address, 4'h5);
    // A later AR replaces the directory's one-cycle result. The W beat must
    // use the hit/way saved for this AW in its write-buffer slot.
    if (interleave_read != '0) read_line(interleave_read, 1'b0);
    send_l2_w_full(data);
    got_response = 1'b0;
    for (int cycle = 0; cycle < 64 && !got_response; cycle++) begin
      if (axi_s.bvalid) begin
        check(axi_s.bid == 4'h5 && axi_s.bresp == 2'b00,
              "posted store returned the wrong response");
        axi_s.bready = 1'b1;
        tick(1);
        axi_s.bready = 1'b0;
        got_response = 1'b1;
      end else tick(1);
    end
    check(got_response, "posted store response timed out");
    check(!axi_m.awvalid, "resident BOOM store unexpectedly wrote through");
    tick(3);
  endtask

  task automatic write_miss_word(input logic [XLEN-1:0] line_addr, input logic [XLEN-1:0] data,
                                 output logic [XLEN-1:0] merged_word);
    logic [IdW-1:0] id_seen;
    logic [XLEN-1:0] addr_seen;
    logic [7:0] len_seen;
    bit got_response;
    store_sinkd_writes = 0;
    store_source_reads = 0;
    store_source_writes = 0;
    track_store_stream = 1'b1;
    axi_s.bready = 1'b0;
    send_l2_aw(line_addr + XLEN'(XLEN / 8), 4'h5);
    send_l2_w(data, (XLEN / 8)'(1));
    check(!axi_s.bvalid, "store miss acknowledged before refill");
    check(!axi_m.awvalid, "clean store miss wrote through");
    accept_l2_downstream_ar(id_seen, addr_seen, len_seen);
    check(id_seen == 4'h5 && addr_seen == line_addr && len_seen == 8'(LineBeats - 1),
          "store miss did not request a full aligned line");
    for (int beat = 0; beat < LineBeats; beat++) begin
      return_l2_downstream_r(4'h5, line_addr + XLEN'(beat), beat == LineBeats - 1);
      check(!axi_s.bvalid, "store miss acknowledged before line install");
    end
    merged_word  = ((line_addr + XLEN'(1)) & ~XLEN'('hff)) | (data & XLEN'('hff));
    got_response = 1'b0;
    for (int cycle = 0; cycle < 64 && !got_response; cycle++) begin
      if (axi_s.bvalid) begin
        check(axi_s.bid == 4'h5 && axi_s.bresp == 2'b00,
              "store miss returned the wrong completion");
        axi_s.bready = 1'b1;
        tick(1);
        axi_s.bready = 1'b0;
        got_response = 1'b1;
      end else tick(1);
    end
    check(got_response, "store miss completion timed out");
    track_store_stream = 1'b0;
    check(store_sinkd_writes == LineBeats && store_source_reads == 1 && store_source_writes == 1,
          "store miss did not stream refill and merge only its target word");
    check(!axi_m.awvalid, "allocated store miss also wrote through");
    read_hit_word(line_addr + XLEN'(XLEN / 8), merged_word);
    read_hit_word(line_addr, line_addr);
  endtask

  task automatic write_miss_refill_error(input logic [XLEN-1:0] line_addr);
    logic [IdW-1:0] id_seen;
    logic [XLEN-1:0] addr_seen;
    logic [7:0] len_seen;
    bit got_response;
    store_sinkd_writes = 0;
    store_source_reads = 0;
    store_source_writes = 0;
    track_store_stream = 1'b1;
    axi_s.bready = 1'b0;
    send_l2_aw(line_addr, 4'h5);
    send_l2_w_full(XLEN'('h1234));
    accept_l2_downstream_ar(id_seen, addr_seen, len_seen);
    check(id_seen == 4'h5 && addr_seen == line_addr && len_seen == 8'(LineBeats - 1),
          "failed store miss requested the wrong line");
    for (int beat = 0; beat < LineBeats; beat++)
      return_l2_downstream_r(4'h5, line_addr + XLEN'(beat), beat == LineBeats - 1,
                             beat == 2 ? 2'b10 : 2'b00);
    got_response = 1'b0;
    for (int cycle = 0; cycle < 64 && !got_response; cycle++) begin
      if (axi_s.bvalid) begin
        check(axi_s.bid == 4'h5 && axi_s.bresp == 2'b10,
              "failed store refill did not report the bus error");
        axi_s.bready = 1'b1;
        tick(1);
        axi_s.bready = 1'b0;
        got_response = 1'b1;
      end else tick(1);
    end
    check(got_response, "failed store refill did not complete");
    track_store_stream = 1'b0;
    check(store_sinkd_writes == 2 && store_source_reads == 0 && store_source_writes == 0,
          "failed store refill reached SourceD or wrote the denied outer beat");
    check(dut.g_boom_directory.u_directory.way_data[dut.victim_way_q][20:19] == 2'b00,
          "failed store refill left its partially overwritten victim valid");
    read_line(line_addr, 1'b1);
  endtask

  task automatic write_miss_evict_dirty(
      input logic [XLEN-1:0] line_addr, input logic [XLEN-1:0] victim_addr,
      input logic [XLEN-1:0] victim_word1, input logic [XLEN-1:0] new_data);
    logic [IdW-1:0] id_seen;
    logic [XLEN-1:0] addr_seen;
    logic [7:0] len_seen;
    bit got_response;
    store_sinkd_writes = 0;
    store_source_reads = 0;
    store_source_writes = 0;
    track_store_stream = 1'b1;
    axi_s.bready = 1'b0;
    send_l2_aw(line_addr + XLEN'(XLEN / 8), 4'h5);
    send_l2_w_full(new_data);
    for (int cycle = 0; cycle < 64 && !axi_m.awvalid; cycle++) tick(1);
    check(
        axi_m.awvalid && axi_m.awaddr == victim_addr
              && axi_m.awlen == 8'(LineBeats - 1) && axi_m.awid == 4'h5,
        "store miss did not write back its dirty victim");
    axi_m.awready = 1'b1;
    tick(1);
    axi_m.awready = 1'b0;
    axi_m.wready  = 1'b1;
    for (int beat = 0; beat < LineBeats; beat++) begin
      logic [XLEN-1:0] expected;
      expected = beat == 1 ? victim_word1 : victim_addr + XLEN'(beat);
      for (int cycle = 0; cycle < 64 && !axi_m.wvalid; cycle++) tick(1);
      check(
          axi_m.wvalid && axi_m.wdata == expected && (&axi_m.wstrb)
                && axi_m.wlast == (beat == LineBeats - 1),
          $sformatf(
          "store miss victim writeback beat %0d: got %h expected %h", beat, axi_m.wdata, expected));
      tick(1);
    end
    axi_m.wready = 1'b0;
    check(!axi_m.arvalid && !axi_s.bvalid, "store miss refill preceded dirty victim B");
    return_l2_downstream_b(4'h5, 2'b00);
    accept_l2_downstream_ar(id_seen, addr_seen, len_seen);
    check(id_seen == 4'h5 && addr_seen == line_addr && len_seen == 8'(LineBeats - 1),
          "store miss did not refill after dirty victim writeback");
    for (int beat = 0; beat < LineBeats; beat++)
      return_l2_downstream_r(4'h5, line_addr + XLEN'(beat), beat == LineBeats - 1);
    got_response = 1'b0;
    for (int cycle = 0; cycle < 64 && !got_response; cycle++) begin
      if (axi_s.bvalid) begin
        check(axi_s.bid == 4'h5 && axi_s.bresp == 2'b00,
              "store miss with dirty victim returned the wrong completion");
        axi_s.bready = 1'b1;
        tick(1);
        axi_s.bready = 1'b0;
        got_response = 1'b1;
      end else tick(1);
    end
    check(got_response, "store miss with dirty victim timed out");
    track_store_stream = 1'b0;
    check(store_sinkd_writes == LineBeats && store_source_reads == 1 && store_source_writes == 1,
          "dirty-victim store miss did not use SinkD then a single SourceD word");
    read_hit_word(line_addr + XLEN'(XLEN / 8), new_data);
  endtask

  task automatic send_full_line_burst(input logic [XLEN-1:0] line_addr, input bit partial,
                                      input logic [3:0] id = 4'hc,
                                      input bit expect_direct_hit = 1'b0);
    bit accepted;
    if (id == 4'hc)
      check(dut.b_count == 0, $sformatf(
            "prior B response pending before full-line burst: count=%0d rptr=%0d wptr=%0d",
            dut.b_count,
            dut.b_rptr,
            dut.b_wptr
            ));
    axi_s.bready = 1'b0;
    axi_s.awaddr = line_addr;
    axi_s.awid = id;
    axi_s.awlen = 8'(LineBeats - 1);
    axi_s.awsize = 3'($clog2(XLEN / 8));
    axi_s.awburst = 2'b01;
    axi_s.awcache = 4'hf;
    axi_s.awvalid = 1'b1;
    accepted = 1'b0;
    for (int cycle = 0; cycle < 64 && !accepted; cycle++) begin
      @(posedge clock);
      accepted = axi_s.awready;
    end
    check(accepted, "full-line burst AW was not accepted");
    #1;
    axi_s.awvalid = 1'b0;
    for (int beat = 0; beat < LineBeats; beat++) begin
      axi_s.wdata = partial ? XLEN'('h5a) : line_addr + XLEN'('h1000 + beat);
      axi_s.wstrb = partial ? (beat == 1 ? (XLEN / 8)'(1) : '0) : '1;
      axi_s.wlast = beat == LineBeats - 1;
      axi_s.wvalid = 1'b1;
      accepted = 1'b0;
      for (int cycle = 0; cycle < 64 && !accepted; cycle++) begin
        @(posedge clock);
        accepted = axi_s.wready;
      end
      check(accepted, "full-line burst W was not accepted");
      #1;
      axi_s.wvalid = 1'b0;
      if (expect_direct_hit)
        check(dut.burst_direct_hit && !dut.cache_install,
              "resident full-line Put did not select direct bank writes");
      if (beat == 0) begin
        // The first Put beat can be consumed before WLAST arrives. A gap
        // between W beats must leave the claimed list available for reuse.
        tick(2);
        check(
            !dut.burst_input_done && dut.burst_fill_count == 1
                  && dut.put_list_claimed[dut.burst_put_list]
                  && !dut.put_list_valid[dut.burst_put_list],
            "full-line Put beat did not stream across an input gap");
      end
    end
    axi_s.wlast = 1'b1;
    axi_s.wstrb = '0;
    check(dut.burst_input_done && (dut.burst_w_done || dut.put_list_valid[dut.burst_put_list]),
          "full-line burst did not finish receiving its Put beats");
    if (id == 4'hc)
      check(!axi_s.bvalid, "full-line burst B became ready before its Put beats drained");
  endtask

  task automatic expect_local_burst_b(input logic [3:0] id = 4'hc,
                                      input bit expect_direct_hit = 1'b0);
    bit got_response;
    got_response = 1'b0;
    for (int cycle = 0; cycle < 64 && !got_response; cycle++) begin
      if (expect_direct_hit)
        check(!dut.cache_install, "direct full-line Put redundantly reinstalled its line");
      check(!axi_m.awvalid && !axi_m.arvalid,
            "full-line burst sent an unnecessary outer transaction");
      if (axi_s.bvalid) begin
        check(axi_s.bid == id && axi_s.bresp == 2'b00,
              "full-line burst returned the wrong response");
        axi_s.bready = 1'b1;
        tick(1);
        axi_s.bready = 1'b0;
        got_response = 1'b1;
      end else tick(1);
    end
    check(got_response, "full-line burst local response timed out");
    if (!dut.burst_active || dut.burst_id == id)
      check(
          !dut.put_list_valid[dut.burst_put_list]
                && !dut.put_list_claimed[dut.burst_put_list]
                && $countones(
          dut.g_put_buffer.u_put_buffer.used) == 0,
          "completed full-line burst did not release its shared Put beats");
  endtask

  task automatic overlap_store_read(input logic [XLEN-1:0] store_addr, read_addr,
                                    input logic [XLEN-1:0] store_data, expected_read,
                                    input bit expect_bank_stall);
    bit got_read;
    axi_s.bready = 1'b0;
    axi_s.rready = 1'b0;
    send_l2_aw(store_addr, 4'h8);
    send_l2_ar(read_addr, 4'h9);
    axi_s.wdata  = store_data;
    axi_s.wstrb  = '1;
    axi_s.wvalid = 1'b1;
    #1;
    check(axi_s.wready, "overlap store W was not accepted");
    check(dut.l2_sram_wblock == expect_bank_stall,
          "L2 bank arbitration disagreed with bank number");
    check(dut.g_boom_banked_store.bank_read,
          "L2 bank read request must remain valid during a bank stall");
    tick(1);
    axi_s.wvalid = 1'b0;
    axi_s.wstrb = '0;
    got_read = 1'b0;
    for (int cycle = 0; cycle < 64 && !got_read; cycle++) begin
      check(!axi_m.arvalid, "overlap hit caused downstream read");
      if (axi_s.rvalid) begin
        check(axi_s.rid == 4'h9 && axi_s.rdata == expected_read && axi_s.rlast,
              "overlap read returned wrong data");
        axi_s.rready = 1'b1;
        tick(1);
        axi_s.rready = 1'b0;
        got_read = 1'b1;
      end else tick(1);
    end
    check(got_read, "overlap read timed out");
    check(axi_s.bvalid && axi_s.bid == 4'h8, "overlap posted B was lost");
    axi_s.bready = 1'b1;
    tick(1);
    axi_s.bready = 1'b0;
    check(!axi_m.awvalid, "overlap BOOM store unexpectedly wrote through");
    tick(2);
    read_hit_word(store_addr, store_data);
  endtask

  task automatic send_partial_burst(input logic [XLEN-1:0] address,
                                    input bit local_allocate = 1'b1);
    bit accepted;
    axi_s.bready = 1'b0;
    axi_s.awaddr = address;
    axi_s.awid = 4'hd;
    axi_s.awlen = 8'd1;
    axi_s.awsize = 3'($clog2(XLEN / 8));
    axi_s.awburst = 2'b01;
    axi_s.awcache = local_allocate ? 4'hf : 4'h0;
    axi_s.awvalid = 1'b1;
    accepted = 1'b0;
    for (int cycle = 0; cycle < 64 && !accepted; cycle++) begin
      @(posedge clock);
      accepted = axi_s.awready;
    end
    check(accepted, "partial burst AW was not accepted");
    #1;
    axi_s.awvalid = 1'b0;
    axi_m.awready = 1'b0;
    axi_m.wready  = 1'b0;
    for (int beat = 0; beat < 2; beat++) begin
      axi_s.wdata = beat == 0 ? XLEN'('h5a) : XLEN'('h6b00);
      axi_s.wstrb = (XLEN / 8)'(1 << beat);
      axi_s.wlast = beat == 1;
      axi_s.wvalid = 1'b1;
      accepted = 1'b0;
      for (int cycle = 0; cycle < 64 && !accepted; cycle++) begin
        @(posedge clock);
        accepted = axi_s.wready;
      end
      check(accepted, "partial burst W timed out");
      #1;
      axi_s.wvalid = 1'b0;
    end
    if (local_allocate) begin
      check(dut.burst_allocate && !axi_m.awvalid,
            "line-local cacheable partial burst did not allocate locally");
      expect_local_burst_b(4'hd);
      return;
    end
    check($countones(dut.g_put_buffer.u_put_buffer.used) == 2,
          "forwarded partial burst did not enter the shared Put pool");
    check(!axi_m.wvalid, "partial burst W preceded downstream AW");
    axi_m.awready = 1'b1;
    accepted = 1'b0;
    for (int cycle = 0; cycle < 64 && !accepted; cycle++) begin
      @(posedge clock);
      accepted = axi_m.awvalid;
      if (accepted)
        check(axi_m.awaddr == address && axi_m.awlen == 8'd1 && axi_m.awid == 4'hd,
              "partial burst changed downstream AW");
    end
    check(accepted, "partial burst downstream AW timed out");
    #1;
    axi_m.awready = 1'b0;
    for (int beat = 0; beat < 2; beat++) begin
      for (int cycle = 0; cycle < 64 && !axi_m.wvalid; cycle++) tick(1);
      check(
          axi_m.wvalid && axi_m.wdata == (beat == 0 ? XLEN'('h5a) : XLEN'('h6b00))
                && axi_m.wstrb == (XLEN / 8)'(1 << beat) && axi_m.wlast == (beat == 1),
          "partial burst changed downstream W");
      axi_m.wready = 1'b1;
      tick(1);
      axi_m.wready = 1'b0;
    end
    check($countones(dut.g_put_buffer.u_put_buffer.used) == 0,
          "partial burst retained Put beats after downstream W");
    axi_s.wlast = 1'b1;
    return_l2_downstream_b(4'hd, 2'b00);
    for (int cycle = 0; cycle < 64 && !axi_s.bvalid; cycle++) tick(1);
    check(axi_s.bvalid && axi_s.bid == 4'hd && axi_s.bresp == 2'b00,
          "partial burst upstream B was not delivered");
    axi_s.bready = 1'b1;
    tick(1);
    axi_s.bready = 1'b0;
    tick(2);
  endtask

  task automatic send_forwarded_burst_hold(input logic [XLEN-1:0] address, input logic [IdW-1:0] id,
                                           input logic [1:0] response, input bit defer_b = 1'b0,
                                           input logic [3:0] cache_attr = 4'h0);
    bit accepted;
    axi_s.bready = 1'b0;
    axi_s.awaddr = address;
    axi_s.awid = id;
    axi_s.awlen = 8'd1;
    axi_s.awsize = 3'($clog2(XLEN / 8));
    axi_s.awburst = 2'b01;
    axi_s.awcache = cache_attr;
    axi_s.awvalid = 1'b1;
    accepted = 1'b0;
    for (int cycle = 0; cycle < 64 && !accepted; cycle++) begin
      @(posedge clock);
      accepted = axi_s.awready;
    end
    check(accepted, "forwarded burst AW was not accepted");
    #1;
    axi_s.awvalid = 1'b0;
    axi_m.awready = 1'b0;
    axi_m.wready  = 1'b0;
    for (int beat = 0; beat < 2; beat++) begin
      axi_s.wdata = XLEN'(id) + XLEN'(beat);
      axi_s.wstrb = '1;
      axi_s.wlast = beat == 1;
      axi_s.wvalid = 1'b1;
      accepted = 1'b0;
      for (int cycle = 0; cycle < 64 && !accepted; cycle++) begin
        @(posedge clock);
        accepted = axi_s.wready;
      end
      check(accepted, "forwarded burst W timed out");
      #1;
      axi_s.wvalid = 1'b0;
    end
    check($countones(dut.g_put_buffer.u_put_buffer.used) == 2,
          "forwarded burst did not enter the shared Put pool");
    check(!axi_m.wvalid, "forwarded W preceded outer AW");
    axi_m.awready = 1'b1;
    accepted = 1'b0;
    for (int cycle = 0; cycle < 64 && !accepted; cycle++) begin
      @(posedge clock);
      accepted = axi_m.awvalid;
      if (accepted)
        check(axi_m.awid == id && axi_m.awaddr == address && axi_m.awlen == 8'd1,
              "forwarded burst changed outer AW");
    end
    check(accepted, "forwarded burst outer AW timed out");
    #1;
    axi_m.awready = 1'b0;
    for (int beat = 0; beat < 2; beat++) begin
      for (int cycle = 0; cycle < 64 && !axi_m.wvalid; cycle++) tick(1);
      check(
          axi_m.wvalid && axi_m.wdata == XLEN'(id) + XLEN'(beat)
                && (&axi_m.wstrb) && axi_m.wlast == (beat == 1),
          "forwarded burst changed outer W");
      axi_m.wready = 1'b1;
      tick(1);
      axi_m.wready = 1'b0;
    end
    check($countones(dut.g_put_buffer.u_put_buffer.used) == 0,
          "forwarded burst retained Put beats after downstream W");
    if (!defer_b) return_l2_downstream_b(id, response);
  endtask

  task automatic send_forwarded_burst_stream(input logic [XLEN-1:0] address);
    bit accepted;
    axi_s.bready = 1'b0;
    axi_s.awaddr = address;
    axi_s.awid = 4'hc;
    axi_s.awlen = 8'd1;
    axi_s.awsize = 3'($clog2(XLEN / 8));
    axi_s.awburst = 2'b01;
    axi_s.awcache = 4'h0;
    axi_s.awvalid = 1'b1;
    accepted = 1'b0;
    for (int cycle = 0; cycle < 64 && !accepted; cycle++) begin
      @(posedge clock);
      accepted = axi_s.awready;
    end
    check(accepted, "streamed burst AW was not accepted");
    #1;
    axi_s.awvalid = 1'b0;
    axi_m.awready = 1'b1;
    accepted = 1'b0;
    for (int cycle = 0; cycle < 64 && !accepted; cycle++) begin
      @(posedge clock);
      accepted = axi_m.awvalid;
    end
    check(accepted, "streamed burst outer AW timed out");
    #1;
    axi_m.awready = 1'b0;
    axi_m.wready  = 1'b1;
    axi_s.wvalid  = 1'b1;
    axi_s.wdata   = XLEN'('h1234);
    axi_s.wstrb   = (XLEN / 8)'(3);
    axi_s.wlast   = 1'b0;
    #1;
    check(axi_s.wready && !axi_m.wvalid, "streamed burst first beat bypassed nonflowing pool");
    tick(1);
    axi_s.wdata = XLEN'('h5678);
    axi_s.wstrb = (XLEN / 8)'(5);
    axi_s.wlast = 1'b1;
    #1;
    check(
        axi_s.wready && axi_m.wvalid && axi_m.wdata == XLEN'('h1234)
              && axi_m.wstrb == (XLEN / 8)'(3) && !axi_m.wlast,
        "streamed burst did not pop first beat while pushing second");
    tick(1);
    axi_s.wvalid = 1'b0;
    #1;
    check(
        axi_m.wvalid && axi_m.wdata == XLEN'('h5678)
              && axi_m.wstrb == (XLEN / 8)'(5) && axi_m.wlast,
        "streamed burst lost second beat on simultaneous push/pop");
    check($countones(dut.g_put_buffer.u_put_buffer.used) == 1,
          "streamed burst did not retain exactly one Put beat");
    tick(1);
    axi_m.wready = 1'b0;
    check($countones(dut.g_put_buffer.u_put_buffer.used) == 0,
          "streamed burst did not release the final Put beat");
    return_l2_downstream_b(4'hc, 2'b00);
    for (int cycle = 0; cycle < 64 && !axi_s.bvalid; cycle++) tick(1);
    check(axi_s.bvalid && axi_s.bid == 4'hc && axi_s.bresp == 2'b00,
          "streamed burst response was lost");
    axi_s.bready = 1'b1;
    tick(1);
    axi_s.bready = 1'b0;
  endtask

  initial begin
    logic [2:0] first_way;
    logic [2:0] second_way;
    logic [15:0] before_aw_lookup;
    logic [XLEN-1:0] store_miss_word;
    logic [IdW-1:0] pending_outer_id;
    logic [IdW-1:0] blocking_outer_id;
    logic [IdW-1:0] wrap_outer_id;
    logic [XLEN-1:0] pending_outer_addr;
    logic [7:0] pending_outer_len;
    localparam logic [XLEN-1:0] LineA = XLEN'('h80000000);
    localparam logic [XLEN-1:0] LineB = XLEN'('h80010000);
    localparam logic [XLEN-1:0] LineC = XLEN'('h80000040);
    localparam logic [XLEN-1:0] LineD = XLEN'('h80020000);
    localparam logic [XLEN-1:0] LineE = XLEN'('h80040000);
    localparam logic [XLEN-1:0] LineF = XLEN'('h80000080);
    localparam logic [XLEN-1:0] LineG = XLEN'('h80010080);
    localparam logic [XLEN-1:0] LineH = XLEN'('h800000c0);
    localparam logic [XLEN-1:0] LineJ = XLEN'('h80000100);
    localparam logic [XLEN-1:0] LineK = XLEN'('h80010100);
    localparam logic [XLEN-1:0] LineM = XLEN'('h80000200);
    localparam logic [XLEN-1:0] LineN = XLEN'('h80000240);
    localparam logic [XLEN-1:0] LineO = XLEN'('h80010200);
    localparam logic [XLEN-1:0] LineP = XLEN'('h80000280);
    localparam logic [XLEN-1:0] LineQ = XLEN'('h80020200);
    localparam logic [XLEN-1:0] LineR = XLEN'('h80000300);
    localparam logic [XLEN-1:0] LineS = XLEN'('h80000340);
    localparam logic [XLEN-1:0] LineT = XLEN'('h80000380);
    localparam logic [XLEN-1:0] LineU = XLEN'('h80010380);
    localparam logic [XLEN-1:0] LineV = XLEN'('h80020380);
    localparam logic [XLEN-1:0] LineW = XLEN'('h80000400);
    localparam logic [XLEN-1:0] LineX = XLEN'('h80010400);
    localparam logic [XLEN-1:0] LineY = XLEN'('h80000500);
    localparam logic [XLEN-1:0] LineZ = XLEN'('h80000540);
    localparam logic [XLEN-1:0] LineAA = XLEN'('h80000600);
    localparam logic [XLEN-1:0] LineBB = XLEN'('h80000640);
    localparam logic [XLEN-1:0] LineCC = XLEN'('h80010600);
    localparam logic [XLEN-1:0] LineDD = XLEN'('h80000700);
    localparam logic [XLEN-1:0] LineEE = XLEN'('h80000740);
    localparam logic [XLEN-1:0] LineFF = XLEN'('h80010700);
    localparam logic [XLEN-1:0] LineGG = XLEN'('h80000800);
    localparam logic [XLEN-1:0] LineHH = XLEN'('h80000840);
    localparam logic [XLEN-1:0] LineJJ = XLEN'('h80010800);
    localparam logic [XLEN-1:0] LineKK = XLEN'('h80000880);
    localparam logic [XLEN-1:0] StoreData = XLEN'('h123456789abcdef0);
    localparam logic [XLEN-1:0] BurstWord1 = ((StoreData + XLEN'(4)) & ~XLEN'('hff)) | XLEN'('h5a);
    localparam logic [XLEN-1:0] BurstWord2 = ((StoreData + XLEN'(8)) & ~XLEN'('hff00))
        | XLEN'('h6b00);

    check(`RAPT_L2_N_WAYS == 8 && `RAPT_L2_LEN == 10 && dut.TagBits == 18,
          "associativity test requires BOOM's 512 KiB and 18-bit tag geometry");
    init_l2_axi(1'b1);
    tick(4);
    reset = 1'b0;
    for (int warmup = 0; warmup < (1 << `RAPT_L2_LEN) + 64 && !axi_s.awready; warmup++) tick(1);
    check(axi_s.awready, "L2 directory reset wipe timed out");

    read_line(LineA, 1'b1);
    first_way = dut.victim_way_q;
    // Directory lookups advance the reference's random victim generator.
    // Hit the first line until the next lookup will choose another way.
    for (
        int lookup = 0;
        lookup < 32 && next_lfsr(dut.g_boom_directory.u_directory.victim_lfsr) [9:7] == first_way;
        lookup++
    )
    read_line(LineA, 1'b0);
    check(next_lfsr(dut.g_boom_directory.u_directory.victim_lfsr) [9:7] != first_way,
          "could not advance the random victim to another way");

    read_line(LineB, 1'b1);
    check(dut.victim_way_q != first_way, "second miss did not select another way");
    read_line(LineA, 1'b0);
    read_line(LineB, 1'b0);

    // The two same-set ways share one row address. The neighboring set uses
    // the other eight physical banks. RV32 word 1 shares a 64-bit bank with
    // word 0 and must only update its upper four byte lanes.
    read_line(LineC, 1'b1);
    read_hit_word(LineA + XLEN'(XLEN / 8), LineA + XLEN'(1));
    before_aw_lookup = dut.g_boom_directory.u_directory.victim_lfsr;
    write_hit_word(LineB + XLEN'(XLEN / 8), StoreData);
    check(dut.g_boom_directory.u_directory.victim_lfsr == next_lfsr(before_aw_lookup),
          "cacheable AW did not perform a BOOM directory lookup");
    read_hit_word(LineB + XLEN'(XLEN / 8), StoreData);
    read_hit_word(LineB, LineB);
    read_hit_word(LineA + XLEN'(XLEN / 8), LineA + XLEN'(1));
    write_hit_word(LineC + XLEN'(XLEN / 8), StoreData + XLEN'(1), LineB);
    read_hit_word(LineC + XLEN'(XLEN / 8), StoreData + XLEN'(1));
    read_hit_word(LineC, LineC);
    overlap_store_read(LineA + XLEN'(2 * XLEN / 8), LineC + XLEN'(XLEN / 8), StoreData + XLEN'(7),
                       StoreData + XLEN'(1), 1'b0);
    overlap_store_read(LineB + XLEN'(2 * XLEN / 8), LineA + XLEN'(2 * XLEN / 8),
                       StoreData + XLEN'(8), StoreData + XLEN'(7), 1'b1);
    overlap_store_read(LineA + XLEN'(4 * XLEN / 8), LineB + XLEN'(2 * XLEN / 8),
                       StoreData + XLEN'(9), StoreData + XLEN'(8), 1'b0);
    // The four-bank mapping conflicts across adjacent sets when the two
    // accesses use the same chunk[1:0], even though their SRAM rows differ.
    overlap_store_read(LineA + XLEN'(6 * XLEN / 8), LineC + XLEN'(6 * XLEN / 8), LineA + XLEN'(6),
                       LineC + XLEN'(6), 1'b1);
    if (XLEN == 64) begin
      // The SoC accepts sign-extended and zero-extended spellings of one
      // 32-bit physical address. They must use the same directory entry.
      read_hit_word(XLEN'('hffff_ffff_8000_0000), LineA);
      write_hit_word(XLEN'('hffff_ffff_8000_0000) + XLEN'(XLEN / 8), StoreData + XLEN'(2));
      read_hit_word(LineA + XLEN'(XLEN / 8), StoreData + XLEN'(2));
    end

    // BOOM's banked SRAM writes only selected bytes. This also exercises
    // RV32's upper four lanes of a shared 64-bit bank.
    axi_s.bready = 1'b0;
    send_l2_aw(LineB + XLEN'(XLEN / 8), 4'h6);
    send_l2_w(StoreData + XLEN'(3), {{(XLEN / 8 - 1) {1'b0}}, 1'b1});
    axi_s.bready = 1'b1;
    tick(1);
    axi_s.bready = 1'b0;
    check(!axi_m.awvalid, "partial BOOM store unexpectedly wrote through");
    read_hit_word(LineB + XLEN'(XLEN / 8),
                  (StoreData & ~XLEN'('hff)) | ((StoreData + XLEN'(3)) & XLEN'('hff)));

    // Two delayed AWs both retain a resident hit while the first partial
    // W updates a byte. The second full W then replaces that whole word.
    axi_s.bready = 1'b0;
    send_l2_aw(LineB + XLEN'(XLEN / 8), 4'h6);
    send_l2_aw(LineB + XLEN'(XLEN / 8), 4'h7);
    send_l2_w(StoreData + XLEN'(5), {{(XLEN / 8 - 1) {1'b0}}, 1'b1});
    check(dut.wbuf[dut.w_wptr].lookup_hit, "partial store lost the later AW's resident hit");
    send_l2_w_full(StoreData + XLEN'(4));
    axi_s.bready = 1'b1;
    tick(3);
    axi_s.bready = 1'b0;
    check(!axi_m.awvalid, "delayed BOOM stores unexpectedly wrote through");
    read_hit_word(LineB + XLEN'(XLEN / 8), StoreData + XLEN'(4));

    // Preserve the directory entry selected for replacement. Its metadata
    // is needed by the BOOM write-back/probe sequence before refill.
    send_l2_ar(LineY, 4'he);
    accept_l2_downstream_ar(pending_outer_id, pending_outer_addr, pending_outer_len);
    check(
        pending_outer_id < 4'd5 && pending_outer_addr == LineY
              && pending_outer_len == 8'(LineBeats - 1),
        "independent clean MSHR did not issue before dirty-victim read");
    read_hit_word(LineA, LineA);
    for (
        int lookup = 0;
        lookup < 32 && next_lfsr(dut.g_boom_directory.u_directory.victim_lfsr) [9:7] != first_way;
        lookup++
    )
    read_hit_word(LineA, LineA);
    check(next_lfsr(dut.g_boom_directory.u_directory.victim_lfsr) [9:7] == first_way,
          "could not select the resident victim way");
    read_line(LineD, 1'b1, LineA, XLEN == 64 ? StoreData + XLEN'(2) : LineA + XLEN'(1),
              StoreData + XLEN'(7), StoreData + XLEN'(9), 2'b00, int'(pending_outer_id), LineY,
              4'he, 1'b1, 1'b1);
    for (int cycle = 0; cycle < 64 && dut.ms_busy; cycle++) tick(1);
    check(!dut.ms_busy, "interleaved clean MSHR did not retire");
    read_hit_word(LineY, LineY);
    check(
        dut.victim_way_q == first_way && dut.victim_tag_q == 18'(LineA >> 16)
              && dut.victim_state_q != 2'b00 && dut.victim_dirty_q && !dut.victim_clients_q,
        "miss lost victim metadata after foreign Get revoked its client");
    read_hit_word(LineB, LineB);
    second_way = dut.r_selected_way;
    for (
        int lookup = 0;
        lookup < 32 && next_lfsr(dut.g_boom_directory.u_directory.victim_lfsr) [9:7] != second_way;
        lookup++
    )
    read_hit_word(LineB, LineB);
    check(next_lfsr(dut.g_boom_directory.u_directory.victim_lfsr) [9:7] == second_way,
          "could not select the dirty victim for error test");
    read_line(XLEN'('h80030000), 1'b1, LineB, StoreData + XLEN'(4), StoreData + XLEN'(8),
              LineB + XLEN'(4), 2'b10);
    read_hit_word(LineB + XLEN'(XLEN / 8), StoreData + XLEN'(4));
    send_partial_burst(LineB + XLEN'(XLEN / 8));
    read_hit_word(LineB + XLEN'(XLEN / 8), BurstWord1);
    read_hit_word(LineB + XLEN'(2 * XLEN / 8), BurstWord2);
    // A burst to another tag in the same set must not discard this dirty
    // line simply because the target set index matches.
    send_partial_burst(XLEN'('h80030000) + XLEN'(XLEN / 8), 1'b0);
    read_hit_word(LineB + XLEN'(XLEN / 8), BurstWord1);

    read_d_client_hit(LineB + XLEN'(XLEN / 8), BurstWord1);
    probe_ready = 1'b0;
    cbo_block   = LineB[XLEN-1:6];
    cbo_inval   = 1'b1;
    tick(1);
    cbo_inval = 1'b0;
    for (int cycle = 0; cycle < (1 << `RAPT_L2_LEN) + 64 && !probe_valid; cycle++) tick(1);
    check(probe_valid && probe_addr == LineB, "CBO did not probe its D-side owner");
    repeat (3) begin
      check(!axi_m.awvalid, "CBO wrote back before the client probe acknowledgment");
      tick(1);
    end
    probe_ready = 1'b1;
    tick(1);
    probe_ready = 1'b0;
    for (int cycle = 0; cycle < (1 << `RAPT_L2_LEN) + 64 && !axi_m.awvalid; cycle++) tick(1);
    check(axi_m.awvalid && axi_m.awaddr == LineB && axi_m.awlen == 8'(LineBeats - 1),
          "CBO did not write back its dirty line");
    axi_m.awready = 1'b1;
    tick(1);
    axi_m.awready = 1'b0;
    axi_m.wready  = 1'b1;
    for (int beat = 0; beat < LineBeats; beat++) begin
      logic [XLEN-1:0] expected;
      expected = LineB + XLEN'(beat);
      if (beat == 1) expected = BurstWord1;
      if (beat == 2) expected = BurstWord2;
      for (int cycle = 0; cycle < 64 && !axi_m.wvalid; cycle++) tick(1);
      check(
          axi_m.wvalid && axi_m.wdata == expected && (&axi_m.wstrb)
                && axi_m.wlast == (beat == LineBeats - 1),
          "CBO wrote the wrong dirty word");
      tick(1);
    end
    axi_m.wready = 1'b0;
    return_l2_downstream_b('0, 2'b00);
    probe_ready = 1'b1;
    for (int drain = 0; drain < (1 << `RAPT_L2_LEN) + 64 && !axi_s.arready; drain++) tick(1);
    check(axi_s.arready, "CBO directory clear did not finish");
    // CBO targets LineB. LineD occupies another way in the same set and
    // must remain resident after the dirty LineB write-back.
    read_line(LineD, 1'b0);

    // Two CBO requests for one set can overlap while the first directory
    // scan runs. Both physical lines must be invalidated before new reads.
    second_way = dut.r_selected_way;
    for (
        int lookup = 0;
        lookup < 32 && next_lfsr(dut.g_boom_directory.u_directory.victim_lfsr) [9:7] == second_way;
        lookup++
    )
    check(next_lfsr(dut.g_boom_directory.u_directory.victim_lfsr) [9:7] != second_way,
          "could not preserve the first CBO target during setup");
    read_line(LineE, 1'b1);
    read_line(LineD, 1'b0);
    cbo_block = LineD[XLEN-1:6];
    cbo_inval = 1'b1;
    tick(1);
    cbo_block = LineE[XLEN-1:6];
    tick(1);
    cbo_inval = 1'b0;
    for (int drain = 0; drain < (1 << `RAPT_L2_LEN) + 64 && !axi_s.arready; drain++) tick(1);
    check(axi_s.arready, "overlapping CBO requests did not drain");
    read_line(LineD, 1'b1);
    read_line(LineE, 1'b1);
    read_line(LineB, 1'b1);

    write_miss_word(LineF, StoreData + XLEN'('h3a), store_miss_word);
    first_way = dut.victim_way_q;
    for (
        int lookup = 0;
        lookup < 32 && next_lfsr(dut.g_boom_directory.u_directory.victim_lfsr) [9:7] != first_way;
        lookup++
    )
    read_hit_word(LineF, LineF);
    check(next_lfsr(dut.g_boom_directory.u_directory.victim_lfsr) [9:7] == first_way,
          "could not select the store-miss victim for writeback");
    read_line(LineG, 1'b1, LineF, store_miss_word, LineF + XLEN'(2), LineF + XLEN'(4));
    write_miss_refill_error(LineH);
    write_miss_word(LineJ, StoreData + XLEN'('h45), store_miss_word);
    first_way = dut.victim_way_q;
    for (
        int lookup = 0;
        lookup < 32 && next_lfsr(dut.g_boom_directory.u_directory.victim_lfsr) [9:7] != first_way;
        lookup++
    )
    read_hit_word(LineJ, LineJ);
    check(next_lfsr(dut.g_boom_directory.u_directory.victim_lfsr) [9:7] == first_way,
          "could not select the dirty victim for store-miss writeback");
    write_miss_evict_dirty(LineK, LineJ, store_miss_word, StoreData + XLEN'('h46));

    burst_merge_reads = 0;
    burst_merge_writes = 0;
    expected_burst_write_chunk = -1;
    track_burst_merge_reads = 1'b1;
    send_full_line_burst(LineM, 1'b0);
    expect_local_burst_b();
    track_burst_merge_reads = 1'b0;
    check(burst_merge_reads == 0 && burst_merge_writes == LineBeats,
          "full Put miss did not write all bank beats without old-data reads");
    read_hit_word(LineM, LineM + XLEN'('h1000));
    read_hit_word(LineM + XLEN'(XLEN / 8), LineM + XLEN'('h1001));
    send_full_line_burst(LineM, 1'b0, 4'hc, 1'b1);
    expect_local_burst_b(4'hc, 1'b1);
    read_hit_word(LineM + XLEN'((LineBeats - 1) * XLEN / 8), LineM + XLEN'('h1000 + LineBeats - 1));
    send_full_line_burst(LineM, 1'b1, 4'hc, 1'b1);
    expect_local_burst_b(4'hc, 1'b1);
    read_hit_word(LineM, LineM + XLEN'('h1000));
    read_hit_word(LineM + XLEN'(XLEN / 8), ((LineM + XLEN'('h1001)) & ~XLEN'('hff)) | XLEN'('h5a));

    // The first completed burst keeps its B slot while the next burst runs.
    // The two IDs must leave the ordered response queue in AW/W order.
    send_full_line_burst(LineM, 1'b1, 4'ha);
    for (int cycle = 0; cycle < 64 && !axi_s.bvalid; cycle++) tick(1);
    check(axi_s.bvalid && axi_s.bid == 4'ha && axi_s.bresp == 2'b00,
          "first queued full-line burst did not complete");
    send_full_line_burst(LineM, 1'b1, 4'hb);
    check(axi_s.bvalid && axi_s.bid == 4'ha && axi_s.bresp == 2'b00,
          "first full-line response was lost while the second burst ran");
    expect_local_burst_b(4'ha);
    expect_local_burst_b(4'hb);
    read_hit_word(LineM + XLEN'(XLEN / 8), ((LineM + XLEN'('h1001)) & ~XLEN'('hff)) | XLEN'('h5a));

    // A full PutFullData replacing a dirty line writes the victim before
    // streaming the new bank beats, without reading old target contents.
    first_way = dut.r_selected_way;
    for (
        int lookup = 0;
        lookup < 32 && next_lfsr(dut.g_boom_directory.u_directory.victim_lfsr) [9:7] != first_way;
        lookup++
    )
    read_hit_word(LineM, LineM + XLEN'('h1000));
    check(next_lfsr(dut.g_boom_directory.u_directory.victim_lfsr) [9:7] == first_way,
          "could not select the dirty full-line burst victim");
    burst_merge_reads = 0;
    burst_merge_writes = 0;
    expected_burst_write_chunk = -1;
    track_burst_merge_reads = 1'b1;
    send_full_line_burst(LineO, 1'b0);
    for (int cycle = 0; cycle < 64 && !axi_m.awvalid; cycle++) tick(1);
    check(
        axi_m.awvalid && axi_m.awaddr == LineM && axi_m.awid == 4'hc
              && axi_m.awlen == 8'(LineBeats - 1),
        "full-line burst did not write back its dirty victim");
    axi_m.awready = 1'b1;
    tick(1);
    axi_m.awready = 1'b0;
    axi_m.wready  = 1'b1;
    for (int beat = 0; beat < LineBeats; beat++) begin
      logic [XLEN-1:0] expected;
      expected = LineM + XLEN'('h1000 + beat);
      if (beat == 1) expected = (expected & ~XLEN'('hff)) | XLEN'('h5a);
      for (int cycle = 0; cycle < 64 && !axi_m.wvalid; cycle++) tick(1);
      check(
          axi_m.wvalid && axi_m.wdata == expected && (&axi_m.wstrb)
                && axi_m.wlast == (beat == LineBeats - 1),
          $sformatf(
          "full-line burst dirty victim beat=%0d data=%h expected=%h strb=%h last=%b",
          beat,
          axi_m.wdata,
          expected,
          axi_m.wstrb,
          axi_m.wlast
          ));
      tick(1);
    end
    axi_m.wready = 1'b0;
    check(!axi_m.arvalid && !axi_s.bvalid, "full-line burst completed before the dirty victim B");
    return_l2_downstream_b(4'hc, 2'b00);
    expect_local_burst_b();
    track_burst_merge_reads = 1'b0;
    check(burst_merge_reads == 0 && burst_merge_writes == LineBeats,
          "dirty-victim full Put did not write every new bank beat after outer B");
    read_hit_word(LineO, LineO + XLEN'('h1000));
    read_hit_word(LineO + XLEN'(XLEN / 8), LineO + XLEN'('h1001));

    // An outer write-back error must fail the incoming full-line write and
    // leave the old dirty line readable for a later retry.
    first_way = dut.r_selected_way;
    for (
        int lookup = 0;
        lookup < 32 && next_lfsr(dut.g_boom_directory.u_directory.victim_lfsr) [9:7] != first_way;
        lookup++
    )
    read_hit_word(LineO, LineO + XLEN'('h1000));
    check(next_lfsr(dut.g_boom_directory.u_directory.victim_lfsr) [9:7] == first_way,
          "could not select the dirty burst victim for error test");
    burst_merge_reads = 0;
    burst_merge_writes = 0;
    expected_burst_write_chunk = -1;
    track_burst_merge_reads = 1'b1;
    send_full_line_burst(LineQ, 1'b0);
    for (int cycle = 0; cycle < 64 && !axi_m.awvalid; cycle++) tick(1);
    check(axi_m.awvalid && axi_m.awaddr == LineO && axi_m.awid == 4'hc,
          "failed full-line write did not address its dirty victim");
    axi_m.awready = 1'b1;
    tick(1);
    axi_m.awready = 1'b0;
    axi_m.wready  = 1'b1;
    for (int beat = 0; beat < LineBeats; beat++) begin
      for (int cycle = 0; cycle < 64 && !axi_m.wvalid; cycle++) tick(1);
      check(
          axi_m.wvalid && axi_m.wdata == LineO + XLEN'('h1000 + beat)
                && axi_m.wlast == (beat == LineBeats - 1),
          "failed full-line write lost the dirty victim data");
      tick(1);
    end
    axi_m.wready = 1'b0;
    return_l2_downstream_b(4'hc, 2'b10);
    for (int cycle = 0; cycle < 64 && !axi_s.bvalid; cycle++) tick(1);
    check(axi_s.bvalid && axi_s.bid == 4'hc && axi_s.bresp == 2'b10 && !axi_m.arvalid,
          "dirty victim B error did not fail the full-line write");
    axi_s.bready = 1'b1;
    tick(1);
    axi_s.bready = 1'b0;
    track_burst_merge_reads = 1'b0;
    check(burst_merge_reads == 0 && burst_merge_writes == 0,
          "failed dirty-victim write exposed the incoming Put data");
    read_hit_word(LineO, LineO + XLEN'('h1000));

    burst_merge_reads = 0;
    burst_merge_writes = 0;
    burst_sinkd_writes = 0;
    expected_burst_write_chunk = 1 / (64 / XLEN);
    track_burst_merge_reads = 1'b1;
    send_full_line_burst(LineN, 1'b1);
    begin
      logic [IdW-1:0] id_seen;
      logic [XLEN-1:0] addr_seen;
      logic [7:0] len_seen;
      accept_l2_downstream_ar(id_seen, addr_seen, len_seen);
      check(id_seen == 4'hc && addr_seen == LineN && len_seen == 8'(LineBeats - 1),
            "masked full-line miss did not refill old bytes");
      for (int beat = 0; beat < LineBeats; beat++)
      return_l2_downstream_r(4'hc, LineN + XLEN'(beat), beat == LineBeats - 1);
    end
    expect_local_burst_b();
    track_burst_merge_reads = 1'b0;
    check(
        burst_sinkd_writes == LineBeats && burst_merge_reads == LineBeats
          && burst_merge_writes == 1,
        "masked miss did not stream refill through SinkD then merge through SourceD");
    read_hit_word(LineN, LineN);
    read_hit_word(LineN + XLEN'(XLEN / 8), ((LineN + XLEN'(1)) & ~XLEN'('hff)) | XLEN'('h5a));

    // Failed refill of a masked full-line write must not install a line.
    burst_merge_reads = 0;
    burst_merge_writes = 0;
    burst_sinkd_writes = 0;
    expected_burst_write_chunk = 1 / (64 / XLEN);
    track_burst_merge_reads = 1'b1;
    send_full_line_burst(LineP, 1'b1);
    begin
      logic [IdW-1:0] id_seen;
      logic [XLEN-1:0] addr_seen;
      logic [7:0] len_seen;
      accept_l2_downstream_ar(id_seen, addr_seen, len_seen);
      check(id_seen == 4'hc && addr_seen == LineP && len_seen == 8'(LineBeats - 1),
            "masked error test did not request the target line");
      for (int beat = 0; beat < LineBeats; beat++)
      return_l2_downstream_r(4'hc, LineP + XLEN'(beat), beat == LineBeats - 1,
                             beat == 2 ? 2'b10 : 2'b00);
    end
    for (int cycle = 0; cycle < 64 && !axi_s.bvalid; cycle++) tick(1);
    check(axi_s.bvalid && axi_s.bid == 4'hc && axi_s.bresp == 2'b10,
          "masked full-line refill error did not reach the writer");
    axi_s.bready = 1'b1;
    tick(1);
    axi_s.bready = 1'b0;
    track_burst_merge_reads = 1'b0;
    check(burst_sinkd_writes == 2 && burst_merge_reads == 0 && burst_merge_writes == 0,
          "failed masked refill wrote data after the first AXI error");
    check(dut.g_boom_directory.u_directory.way_data[dut.victim_way_q][20:19] == 2'b00,
          "failed masked refill left its partially overwritten victim valid");
    read_line(LineP, 1'b1);

    // A D-side refill owns a BOOM directory client bit. Later local stores
    // must retain it so replacement can identify the line to probe.
    read_d_client_miss(LineR);
    read_d_client_hit(LineR, LineR);
    check(dut.g_boom_directory.u_directory.way_data[dut.r_selected_way][18],
          "D-side refill did not record its directory client");
    write_hit_word(LineR + XLEN'(XLEN / 8), StoreData);
    read_d_client_hit(LineR + XLEN'(XLEN / 8), StoreData);
    check(dut.g_boom_directory.u_directory.way_data[dut.r_selected_way][18], $sformatf(
          "local store discarded D-side client: raw=%b lookup=%b queued=%b entry=%h",
          dut.g_boom_directory.u_directory.way_data[dut.r_selected_way][18],
          dut.dir_lookup_clients,
          dut.g_boom_directory.u_directory.write_queued,
          dut.g_boom_directory.u_directory.queued_entry
          ));

    // An I-side fill may be shared later by the D-side. A hit must register
    // the D client without changing the line's existing state or data.
    read_line(LineS, 1'b1);
    read_hit_word(LineS, LineS);
    check(!dut.g_boom_directory.u_directory.way_data[dut.r_selected_way][18],
          "I-side fill unexpectedly owns the D client");
    write_hit_word(LineS + XLEN'(XLEN / 8), StoreData);
    read_hit_word(LineS + XLEN'(XLEN / 8), StoreData);
    check(dut.g_boom_directory.u_directory.way_data[dut.r_selected_way][21],
          "resident store did not leave the I-side line dirty");
    read_d_client_hit(LineS + XLEN'(XLEN / 8), StoreData);
    read_d_client_hit(LineS + XLEN'(XLEN / 8), StoreData);
    check(dut.g_boom_directory.u_directory.way_data[dut.r_selected_way][18],
          "D-side resident hit did not register its directory client");
    check(dut.g_boom_directory.u_directory.way_data[dut.r_selected_way][21],
          "D-side resident hit lost the line's dirty metadata");

    // A client-owned masked Put must merge one beat at a time through the
    // SourceD read port; the no-client case above already uses direct writes.
    burst_merge_reads = 0;
    burst_merge_writes = 0;
    expected_burst_write_chunk = 1 / (64 / XLEN);
    track_burst_merge_reads = 1'b1;
    send_full_line_burst(LineR, 1'b1);
    expect_local_burst_b();
    track_burst_merge_reads = 1'b0;
    check(burst_merge_reads == LineBeats, "masked Put did not read every bank beat");
    check(burst_merge_writes == 1, "masked Put did not write exactly its touched bank beat");
    read_hit_word(LineR + XLEN'(XLEN / 8), (StoreData & ~XLEN'('hff)) | XLEN'('h5a));
    check(
        !dut.g_boom_directory.u_directory.way_data[dut.r_selected_way][18]
          && dut.g_boom_directory.u_directory.way_data[dut.r_selected_way][21],
        "masked Put did not clear the probed client and mark the line dirty");

    read_d_client_hit(LineR + XLEN'(XLEN / 8), (StoreData & ~XLEN'('hff)) | XLEN'('h5a));
    burst_merge_reads = 0;
    burst_merge_writes = 0;
    expected_burst_write_chunk = -1;
    track_burst_merge_reads = 1'b1;
    send_full_line_burst(LineR, 1'b0);
    expect_local_burst_b();
    track_burst_merge_reads = 1'b0;
    check(burst_merge_reads == 0 && burst_merge_writes == LineBeats,
          "client-owned full Put did not write each beat without old-data reads");
    read_hit_word(LineR, LineR + XLEN'('h1000));
    read_hit_word(LineR + XLEN'(XLEN / 8), LineR + XLEN'('h1001));
    read_hit_word(LineR + XLEN'((LineBeats - 1) * (XLEN / 8)),
                  LineR + XLEN'('h1000 + LineBeats - 1));
    check(
        !dut.g_boom_directory.u_directory.way_data[dut.r_selected_way][18]
          && dut.g_boom_directory.u_directory.way_data[dut.r_selected_way][21],
        "full Put did not clear the probed client and mark the line dirty");

    read_d_client_miss(LineT);
    send_l2_ar(LineZ, 4'h2);
    accept_l2_downstream_ar(pending_outer_id, pending_outer_addr, pending_outer_len);
    check(
        pending_outer_id < 4'd5 && pending_outer_addr == LineZ
              && pending_outer_len == 8'(LineBeats - 1),
        "independent clean MSHR did not issue before client-probe read");
    read_d_client_hit(LineT, LineT, 4'h8);
    first_way = dut.r_selected_way;
    for (
        int lookup = 0;
        lookup < 32 && next_lfsr(dut.g_boom_directory.u_directory.victim_lfsr) [9:7] != first_way;
        lookup++
    )
    read_d_client_hit(LineT, LineT, 4'h8);
    check(next_lfsr(dut.g_boom_directory.u_directory.victim_lfsr) [9:7] == first_way,
          "could not select the D-owned victim for probe test");
    read_miss_after_probe(LineT, LineU, int'(pending_outer_id), LineZ, 4'h2, 1'b0, 1'b1);
    for (int cycle = 0; cycle < 64 && dut.ms_busy; cycle++) tick(1);
    check(!dut.ms_busy, "client-probe interleaved clean MSHR did not retire");
    read_hit_word(LineZ, LineZ);

    read_d_client_hit(LineU, LineU);
    first_way = dut.r_selected_way;
    for (
        int lookup = 0;
        lookup < 32 && next_lfsr(dut.g_boom_directory.u_directory.victim_lfsr) [9:7] != first_way;
        lookup++
    )
    read_d_client_hit(LineU, LineU);
    check(next_lfsr(dut.g_boom_directory.u_directory.victim_lfsr) [9:7] == first_way,
          "could not select the D-owned full-Put victim");
    probe_ready = 1'b0;
    burst_merge_reads = 0;
    burst_merge_writes = 0;
    expected_burst_write_chunk = -1;
    track_burst_merge_reads = 1'b1;
    send_full_line_burst(LineV, 1'b0);
    for (int cycle = 0; cycle < 64 && !probe_valid; cycle++) tick(1);
    check(probe_valid && probe_addr == LineU, "full Put miss did not probe its D-owned victim");
    repeat (3) begin
      check(burst_merge_writes == 0 && !axi_s.bvalid && !axi_m.arvalid,
            "full Put miss wrote new data or responded before victim ProbeAck");
      tick(1);
    end
    probe_ready = 1'b1;
    tick(1);
    probe_ready = 1'b0;
    expect_local_burst_b();
    track_burst_merge_reads = 1'b0;
    probe_ready = 1'b1;
    check(burst_merge_reads == 0 && burst_merge_writes == LineBeats,
          "probed full Put miss did not write every new bank beat");
    read_hit_word(LineV, LineV + XLEN'('h1000));
    read_hit_word(LineV + XLEN'((LineBeats - 1) * (XLEN / 8)),
                  LineV + XLEN'('h1000 + LineBeats - 1));

    // A delayed outer B must not hold the active burst slot. Different IDs
    // may complete out of order, while upstream B remains in request order.
    send_forwarded_burst_hold(XLEN'('hf0001800), 4'ha, 2'b00, 1'b1);
    check(!axi_s.bvalid, "first forwarded burst completed before outer B");
    send_forwarded_burst_hold(XLEN'('hf0001820), 4'hb, 2'b10, 1'b1);
    check(!axi_s.bvalid, "second forwarded burst completed before outer B");
    return_l2_downstream_b(4'hb, 2'b10);
    check(!axi_s.bvalid, "later forwarded B bypassed the older upstream response");
    return_l2_downstream_b(4'ha, 2'b00);
    check(axi_s.bvalid && axi_s.bid == 4'ha && axi_s.bresp == 2'b00,
          "first forwarded burst B did not enter the ordered queue");
    axi_s.bready = 1'b1;
    tick(1);
    check(axi_s.bvalid && axi_s.bid == 4'hb && axi_s.bresp == 2'b10,
          "forwarded burst B order or error response changed");
    tick(1);
    axi_s.bready = 1'b0;
    check(!axi_s.bvalid, "forwarded burst left an extra B response");

    // Same-ID outer responses are ordered by AXI; match each to the oldest
    // pending queue slot even when both bursts use the same ID.
    send_forwarded_burst_hold(XLEN'('hf0001860), 4'ha, 2'b10, 1'b1);
    send_forwarded_burst_hold(XLEN'('hf0001880), 4'ha, 2'b00, 1'b1);
    return_l2_downstream_b(4'ha, 2'b10);
    check(axi_s.bvalid && axi_s.bid == 4'ha && axi_s.bresp == 2'b10,
          "first same-ID forwarded B matched the wrong slot");
    return_l2_downstream_b(4'ha, 2'b00);
    axi_s.bready = 1'b1;
    tick(1);
    check(axi_s.bvalid && axi_s.bid == 4'ha && axi_s.bresp == 2'b00,
          "second same-ID forwarded B matched the wrong slot");
    tick(1);
    axi_s.bready = 1'b0;
    check(!axi_s.bvalid, "same-ID forwarded bursts left an extra response");

    // A cacheable resident-hit burst may follow an older MMIO burst whose
    // outer B is still pending. Replay belongs to the cacheable B slot even
    // when that B returns first; upstream B remains in request order.
    send_forwarded_burst_hold(XLEN'('hf00018c0), 4'ha, 2'b00, 1'b1);
    send_forwarded_burst_hold(LineV, 4'hb, 2'b00, 1'b1, 4'he);
    check(dut.forward_cache_pending && !axi_s.bvalid,
          "resident forwarded hit escaped before matching outer B");
    return_l2_downstream_b(4'hb, 2'b00);
    check(!axi_s.bvalid, "cacheable forwarded B bypassed older MMIO B");
    return_l2_downstream_b(4'ha, 2'b00);
    check(axi_s.bvalid && axi_s.bid == 4'ha && axi_s.bresp == 2'b00,
          "older MMIO B was not first upstream");
    axi_s.bready = 1'b1;
    tick(1);
    check(axi_s.bvalid && axi_s.bid == 4'hb && axi_s.bresp == 2'b00,
          "cacheable forwarded B did not follow older MMIO B");
    tick(1);
    axi_s.bready = 1'b0;
    read_hit_word(LineV, XLEN'('hb));
    read_hit_word(LineV + XLEN'(XLEN / 8), XLEN'('hc));

    send_forwarded_burst_stream(XLEN'('hf0001840));

    read_d_client_miss(LineW);
    read_d_client_hit(LineW, LineW);
    first_way = dut.r_selected_way;
    for (
        int lookup = 0;
        lookup < 32 && next_lfsr(dut.g_boom_directory.u_directory.victim_lfsr) [9:7] != first_way;
        lookup++
    )
    read_d_client_hit(LineW, LineW);
    check(next_lfsr(dut.g_boom_directory.u_directory.victim_lfsr) [9:7] == first_way,
          "could not select the client-owned victim for refill-error test");
    read_miss_after_probe_refill_error(LineW, LineX);

    // Complete a different-set D-client MSHR during the blocking refill.
    // Its queued directory write must stall the blocking final R beat.
    read_d_client_miss(LineAA);
    send_l2_ar(LineBB, 4'h2);
    accept_l2_downstream_ar(pending_outer_id, pending_outer_addr, pending_outer_len);
    check(pending_outer_id < 4'd5 && pending_outer_addr == LineBB,
          "R-stage independent MSHR did not issue its outer AR");
    read_d_client_hit(LineAA, LineAA, 4'h8);
    first_way = dut.r_selected_way;
    for (
        int lookup = 0;
        lookup < 32 && next_lfsr(dut.g_boom_directory.u_directory.victim_lfsr) [9:7] != first_way;
        lookup++
    )
    read_d_client_hit(LineAA, LineAA, 4'h8);
    check(next_lfsr(dut.g_boom_directory.u_directory.victim_lfsr) [9:7] == first_way,
          "could not select the D-owned victim for R-stage overlap");
    read_miss_after_probe(LineAA, LineCC, int'(pending_outer_id), LineBB, 4'h2, 1'b0, 1'b1, 1'b1,
                          1'b1, 1'b1);
    for (int cycle = 0; cycle < 64 && dut.ms_busy; cycle++) tick(1);
    check(!dut.ms_busy, "R-stage independent MSHR did not retire");
    read_hit_word(LineBB, LineBB);

    // A multi-beat primary cannot use the scalar critical-word response.
    // Its clean refill must still install during an unrelated client probe,
    // then return every beat once the blocking read releases the shared FSM.
    read_d_client_miss(LineDD);
    send_l2_ar_len(LineEE, 4'h4, 8'd5, 2'b01);
    accept_l2_downstream_ar(pending_outer_id, pending_outer_addr, pending_outer_len);
    check(
        pending_outer_id < 4'd5 && pending_outer_addr == LineEE
              && pending_outer_len == 8'(LineBeats - 1),
        "independent burst did not allocate an ordinary MSHR");
    send_l2_ar(LineEE + XLEN'(2 * XLEN / 8), 4'h5);
    send_l2_ar_len(LineEE + XLEN'(3 * XLEN / 8), 4'h6, 8'd2, 2'b01);
    send_l2_ar_len(LineEE + XLEN'(5 * XLEN / 8), 4'h0, 8'd2, 2'b00);
    send_l2_ar_len(LineEE + XLEN'(2 * XLEN / 8), 4'h1, 8'd3, 2'b01, 4'hf, 3'd1);
    send_l2_ar_len(LineEE + XLEN'(5 * XLEN / 8), 4'hc, 8'd3, 2'b10);
    send_l2_ar_len(LineEE + XLEN'(5 * XLEN / 8 + 2), 4'hd, 8'd3, 2'b10, 4'hf, 3'd1);
    send_l2_ar(LineEE + XLEN'(64 * 1024), 4'h7);
    check(dut.ms_secondary_queue_valid[pending_outer_id],
          "same-line scalar did not queue behind the ordinary burst");
    read_d_client_hit(LineDD, LineDD);
    first_way = dut.r_selected_way;
    for (
        int lookup = 0;
        lookup < 32 && next_lfsr(dut.g_boom_directory.u_directory.victim_lfsr) [9:7] != first_way;
        lookup++
    )
    read_d_client_hit(LineDD, LineDD);
    check(next_lfsr(dut.g_boom_directory.u_directory.victim_lfsr) [9:7] == first_way,
          "could not select the D-owned victim for burst overlap");
    probe_ready = 1'b0;
    send_l2_ar(LineFF, 4'h3);
    for (int cycle = 0; cycle < 64 && !probe_valid; cycle++) tick(1);
    check(probe_valid && probe_addr == LineDD,
          "blocking burst-overlap miss did not probe its D-owned victim");
    for (int beat = 0; beat < LineBeats; beat++)
    return_l2_downstream_r(pending_outer_id, LineEE + XLEN'(beat), beat == LineBeats - 1);
    for (int cycle = 0; cycle < 64 && !dut.ms_source_active; cycle++) tick(1);
    check(dut.ms_installed[pending_outer_id] && dut.ms_source_active && probe_valid && !probe_ready,
          "ordinary burst did not enter SourceD during the blocking probe");
    for (int cycle = 0; cycle < 64 && dut.ms_source_count != 2'd3; cycle++) tick(1);
    check(dut.ms_source_count == 2'd3 && !dut.ms_source_issue_done,
          "SourceD did not fill its three-entry read queue under R backpressure");
    for (int cycle = 0; cycle < 4; cycle++) begin
      check(!dut.ms_source_read_fire && axi_s.rvalid && axi_s.rid == 4'h4 && axi_s.rdata == LineEE,
            "SourceD overran its read queue or changed a stalled R beat");
      tick(1);
    end
    for (int beat = 0; beat < 6; beat++) begin
      for (int cycle = 0; cycle < 64 && !axi_s.rvalid; cycle++) tick(1);
      check(
          axi_s.rvalid && axi_s.rid == 4'h4 && axi_s.rdata == LineEE + XLEN'(beat)
                && axi_s.rresp == 2'b00 && axi_s.rlast == (beat == 5)
                && probe_valid && !probe_ready,
          "independent SourceD lost or reordered a burst beat during the probe");
      axi_s.rready = 1'b1;
      tick(1);
      axi_s.rready = 1'b0;
    end
    for (int cycle = 0; cycle < 64 && !dut.ms_source_active; cycle++) tick(1);
    check(dut.ms_source_active && dut.ms_source_primary_secondary && probe_valid && !probe_ready,
          "same-line secondary did not enter SourceD during the held probe");
    for (int cycle = 0; cycle < 64 && !axi_s.rvalid; cycle++) tick(1);
    check(
        axi_s.rvalid && axi_s.rid == 4'h5 && axi_s.rdata == LineEE + XLEN'(2)
              && axi_s.rresp == 2'b00 && axi_s.rlast && probe_valid && !probe_ready,
        "same-line secondary waited for the blocking probe");
    axi_s.rready = 1'b1;
    tick(1);
    axi_s.rready = 1'b0;
    for (int cycle = 0; cycle < 64 && !dut.ms_source_active; cycle++) tick(1);
    check(dut.ms_source_active && dut.ms_source_primary_secondary && probe_valid && !probe_ready,
          "same-line burst secondary did not enter SourceD during the held probe");
    for (int beat = 0; beat < 3; beat++) begin
      for (int cycle = 0; cycle < 64 && !axi_s.rvalid; cycle++) tick(1);
      check(
          axi_s.rvalid && axi_s.rid == 4'h6 && axi_s.rdata == LineEE + XLEN'(3 + beat)
                && axi_s.rresp == 2'b00 && axi_s.rlast == (beat == 2)
                && probe_valid && !probe_ready,
          "same-line burst secondary lost a beat during the held probe");
      axi_s.rready = 1'b1;
      tick(1);
      axi_s.rready = 1'b0;
    end
    for (int cycle = 0; cycle < 64 && !dut.ms_source_active; cycle++) tick(1);
    check(
        dut.ms_source_active && dut.ms_source_primary_secondary
              && dut.ms_source_burst == 2'b00 && probe_valid && !probe_ready,
        "FIXED secondary did not enter SourceD during the held probe");
    for (int beat = 0; beat < 3; beat++) begin
      for (int cycle = 0; cycle < 64 && !axi_s.rvalid; cycle++) tick(1);
      check(
          axi_s.rvalid && axi_s.rid == 4'h0 && axi_s.rdata == LineEE + XLEN'(5)
                && axi_s.rlast == (beat == 2) && probe_valid && !probe_ready,
          "FIXED secondary advanced its read address or lost a beat");
      axi_s.rready = 1'b1;
      tick(1);
      axi_s.rready = 1'b0;
    end
    for (int cycle = 0; cycle < 64 && !dut.ms_source_active; cycle++) tick(1);
    check(
        dut.ms_source_active && dut.ms_source_primary_secondary
              && dut.ms_source_size == 3'd1 && probe_valid && !probe_ready,
        "narrow secondary did not enter SourceD during the held probe");
    for (int beat = 0; beat < 4; beat++) begin
      for (int cycle = 0; cycle < 64 && !axi_s.rvalid; cycle++) tick(1);
      check(
          axi_s.rvalid && axi_s.rid == 4'h1
                && axi_s.rdata == LineEE + XLEN'(2 + beat * 2 / (XLEN / 8))
                && axi_s.rlast == (beat == 3) && probe_valid && !probe_ready,
          "narrow secondary selected the wrong SRAM word");
      axi_s.rready = 1'b1;
      tick(1);
      axi_s.rready = 1'b0;
    end
    for (int cycle = 0; cycle < 64 && !dut.ms_source_active; cycle++) tick(1);
    check(
        dut.ms_source_active && dut.ms_source_primary_secondary
              && dut.ms_source_burst == 2'b10 && probe_valid && !probe_ready,
        "WRAP secondary did not enter SourceD during the held probe");
    for (int beat = 0; beat < 4; beat++) begin
      for (int cycle = 0; cycle < 64 && !axi_s.rvalid; cycle++) tick(1);
      check(
          axi_s.rvalid && axi_s.rid == 4'hc
                && axi_s.rdata == LineEE + XLEN'(beat == 3 ? 4 : beat + 5)
                && axi_s.rlast == (beat == 3) && probe_valid && !probe_ready,
          "WRAP secondary selected the wrong SRAM word");
      axi_s.rready = 1'b1;
      tick(1);
      axi_s.rready = 1'b0;
    end
    for (int cycle = 0; cycle < 64 && !dut.ms_source_active; cycle++) tick(1);
    check(
        dut.ms_source_active && dut.ms_source_size == 3'd1
              && dut.ms_source_burst == 2'b10 && probe_valid && !probe_ready,
        "narrow WRAP secondary did not enter SourceD during the held probe");
    for (int beat = 0; beat < 4; beat++) begin
      for (int cycle = 0; cycle < 64 && !axi_s.rvalid; cycle++) tick(1);
      check(
          axi_s.rvalid && axi_s.rid == 4'hd
                && axi_s.rdata == LineEE + XLEN'(XLEN == 32
                    ? (beat == 0 || beat == 3 ? 5 : 4) : 5)
                && axi_s.rlast == (beat == 3) && probe_valid && !probe_ready,
          "narrow WRAP secondary selected the wrong SRAM word");
      axi_s.rready = 1'b1;
      tick(1);
      axi_s.rready = 1'b0;
    end
    for (int cycle = 0; cycle < 64 && !dut.ms_replay_pending; cycle++) tick(1);
    check(
        dut.ms_replay_pending && dut.ms_replay_payload[0+:IdW] == 4'h7
              && probe_valid && !probe_ready,
        "different-tag secondary was not held for a directory replay");
    probe_ready = 1'b1;
    tick(1);
    probe_ready = 1'b0;
    accept_l2_downstream_ar(blocking_outer_id, pending_outer_addr, pending_outer_len);
    check(
        blocking_outer_id < 4'd5 && blocking_outer_id != pending_outer_id
              && pending_outer_addr == LineFF && pending_outer_len == 8'(LineBeats - 1),
        "blocking burst-overlap miss issued the wrong refill");
    for (int beat = 0; beat < LineBeats; beat++)
    return_l2_downstream_r(blocking_outer_id, LineFF + XLEN'(beat), beat == LineBeats - 1);
    for (int cycle = 0; cycle < 64 && !axi_s.rvalid; cycle++) tick(1);
    check(axi_s.rvalid && axi_s.rid == 4'h3 && axi_s.rdata == LineFF && axi_s.rlast,
          "blocking miss lost its critical-word response");
    axi_s.rready = 1'b1;
    tick(1);
    axi_s.rready = 1'b0;
    accept_l2_downstream_ar(pending_outer_id, pending_outer_addr, pending_outer_len);
    check(pending_outer_addr == LineEE + XLEN'(64 * 1024) && pending_outer_len == 8'(LineBeats - 1),
          "different-tag secondary did not reread the directory after the probe");
    for (int beat = 0; beat < LineBeats; beat++)
    return_l2_downstream_r(pending_outer_id, LineEE + XLEN'(64 * 1024 + beat),
                           beat == LineBeats - 1);
    for (int cycle = 0; cycle < 64 && !axi_s.rvalid; cycle++) tick(1);
    check(
        axi_s.rvalid && axi_s.rid == 4'h7
              && axi_s.rdata == LineEE + XLEN'(64 * 1024) && axi_s.rlast,
        "different-tag secondary replay lost its response");
    axi_s.rready = 1'b1;
    tick(1);
    axi_s.rready = 1'b0;
    for (int cycle = 0; cycle < 64 && dut.ms_busy; cycle++) tick(1);
    check(!dut.ms_busy, "late-response ordinary burst kept its MSHR allocated");

    // The independent bank reader also operates during another miss's
    // outer R stream, after that miss's critical response has been consumed.
    read_d_client_miss(LineGG);
    send_l2_ar_len(LineHH, 4'h4, 8'd3, 2'b01, 4'hf, 3'd1);
    accept_l2_downstream_ar(pending_outer_id, pending_outer_addr, pending_outer_len);
    check(pending_outer_id < 4'd5 && pending_outer_addr == LineHH,
          "R-stage burst did not allocate an ordinary MSHR");
    send_l2_ar(LineHH + XLEN'(XLEN / 8), 4'h5);
    send_l2_ar_len(LineKK + XLEN'(5 * XLEN / 8), 4'h6, 8'd3, 2'b10);
    accept_l2_downstream_ar(wrap_outer_id, pending_outer_addr, pending_outer_len);
    check(
        wrap_outer_id < 4'd5 && wrap_outer_id != pending_outer_id
              && pending_outer_addr == LineKK && pending_outer_len == 8'(LineBeats - 1),
        "WRAP primary did not allocate an independent ordinary MSHR");
    read_d_client_hit(LineGG, LineGG);
    first_way = dut.r_selected_way;
    for (
        int lookup = 0;
        lookup < 32 && next_lfsr(dut.g_boom_directory.u_directory.victim_lfsr) [9:7] != first_way;
        lookup++
    )
    read_d_client_hit(LineGG, LineGG);
    check(next_lfsr(dut.g_boom_directory.u_directory.victim_lfsr) [9:7] == first_way,
          "could not select the D-owned victim for R-stage burst overlap");
    probe_ready = 1'b0;
    send_l2_ar(LineJJ, 4'h3);
    for (int cycle = 0; cycle < 64 && !probe_valid; cycle++) tick(1);
    check(probe_valid && probe_addr == LineGG,
          "R-stage burst-overlap miss did not probe its D-owned victim");
    probe_ready = 1'b1;
    tick(1);
    probe_ready = 1'b0;
    accept_l2_downstream_ar(blocking_outer_id, pending_outer_addr, pending_outer_len);
    check(blocking_outer_id < 4'd5 && pending_outer_addr == LineJJ,
          "R-stage burst-overlap miss issued the wrong outer AR");
    return_l2_downstream_r(blocking_outer_id, LineJJ, 1'b0);
    for (int cycle = 0; cycle < 64 && !axi_s.rvalid; cycle++) tick(1);
    check(axi_s.rvalid && axi_s.rid == 4'h3 && axi_s.rdata == LineJJ && axi_s.rlast,
          "blocking critical word was not returned first");
    axi_s.rready = 1'b1;
    tick(1);
    axi_s.rready = 1'b0;
    for (int beat = 0; beat < LineBeats; beat++)
    return_l2_downstream_r(pending_outer_id, LineHH + XLEN'(beat), beat == LineBeats - 1);
    for (int cycle = 0; cycle < 64 && !dut.ms_source_active; cycle++) tick(1);
    check(dut.ms_source_active && dut.ms_installed[pending_outer_id] && dut.rs == dut.R_MISS_R,
          "R-stage ordinary burst did not enter independent SourceD");
    for (int beat = 0; beat < 4; beat++) begin
      for (int cycle = 0; cycle < 64 && !axi_s.rvalid; cycle++) tick(1);
      check(
          axi_s.rvalid && axi_s.rid == 4'h4
                && axi_s.rdata == LineHH + XLEN'(beat * 2 / (XLEN / 8))
                && axi_s.rresp == 2'b00 && axi_s.rlast == (beat == 3)
                && dut.rs == dut.R_MISS_R,
          "ordinary SourceD burst waited for blocking refill completion");
      axi_s.rready = 1'b1;
      tick(1);
      axi_s.rready = 1'b0;
    end
    for (int cycle = 0; cycle < 64 && !dut.ms_source_active; cycle++) tick(1);
    check(dut.ms_source_active && dut.ms_source_primary_secondary && dut.rs == dut.R_MISS_R,
          "R-stage same-line secondary did not enter independent SourceD");
    for (int cycle = 0; cycle < 64 && !axi_s.rvalid; cycle++) tick(1);
    check(
        axi_s.rvalid && axi_s.rid == 4'h5 && axi_s.rdata == LineHH + XLEN'(1)
              && axi_s.rresp == 2'b00 && axi_s.rlast && dut.rs == dut.R_MISS_R,
        "R-stage same-line secondary waited for blocking refill completion");
    axi_s.rready = 1'b1;
    tick(1);
    axi_s.rready = 1'b0;
    for (int beat = 0; beat < LineBeats; beat++)
    return_l2_downstream_r(wrap_outer_id, LineKK + XLEN'(beat), beat == LineBeats - 1);
    for (int cycle = 0; cycle < 64 && !dut.ms_source_active; cycle++) tick(1);
    check(dut.ms_source_active && dut.ms_source_burst == 2'b10 && dut.rs == dut.R_MISS_R,
          "WRAP primary did not enter SourceD during the blocking outer R stage");
    for (int beat = 0; beat < 4; beat++) begin
      for (int cycle = 0; cycle < 64 && !axi_s.rvalid; cycle++) tick(1);
      check(
          axi_s.rvalid && axi_s.rid == 4'h6
                && axi_s.rdata == LineKK + XLEN'(beat == 3 ? 4 : beat + 5)
                && axi_s.rlast == (beat == 3) && dut.rs == dut.R_MISS_R,
          "WRAP primary selected the wrong SRAM word during outer R overlap");
      axi_s.rready = 1'b1;
      tick(1);
      axi_s.rready = 1'b0;
    end
    for (int beat = 1; beat < LineBeats; beat++)
    return_l2_downstream_r(blocking_outer_id, LineJJ + XLEN'(beat), beat == LineBeats - 1);
    for (int cycle = 0; cycle < 64 && dut.ms_busy; cycle++) tick(1);
    check(!dut.ms_busy, "R-stage SourceD left its ordinary MSHR allocated");

    // The ordinary resident-hit path must use the same AXI WRAP sequence.
    send_l2_ar_len(LineJJ + XLEN'(5 * XLEN / 8), 4'hc, 8'd3, 2'b10);
    check(!axi_m.arvalid, "resident WRAP hit unexpectedly requested outer memory");
    for (int beat = 0; beat < 4; beat++) begin
      for (int cycle = 0; cycle < 64 && !axi_s.rvalid; cycle++) tick(1);
      check(
          axi_s.rvalid && axi_s.rid == 4'hc
                && axi_s.rdata == LineJJ + XLEN'(beat == 3 ? 4 : beat + 5)
                && axi_s.rlast == (beat == 3),
          "resident WRAP hit selected the wrong SRAM word");
      axi_s.rready = 1'b1;
      tick(1);
      axi_s.rready = 1'b0;
    end

    // Exercise the B matcher around every ring position, including repeated
    // IDs and a wrap from slot 39 to slot 0. No clock edge occurs while the
    // temporary queue state is injected after all functional traffic ends.
    @(negedge clock);
    for (int head = 0; head < 40; head++) begin
      for (int pattern = 0; pattern < 32; pattern++) begin
        bit expected_match;
        int expected_slot;
        dut.b_rptr = 6'(head);
        axi_m.bid  = IdW'(pattern % 4);
        for (int slot = 0; slot < 40; slot++) begin
          dut.forward_b_pending[slot] = pattern != 0 && (slot * 17 + pattern * 13) % 7 < 3;
          dut.b_id_q[slot] = IdW'((slot + pattern / 2) % 4);
        end
        #0.001;
        expected_match = 1'b0;
        expected_slot  = 0;
        for (int offset = 0; offset < 40; offset++) begin
          int slot;
          slot = (head + offset) % 40;
          if (!expected_match && dut.forward_b_pending[slot] && dut.b_id_q[slot] == axi_m.bid) begin
            expected_match = 1'b1;
            expected_slot  = slot;
          end
        end
        check(
            dut.forward_b_match == expected_match
                  && (!expected_match || int'(dut.forward_b_slot) == expected_slot),
            $sformatf("forwarded B oldest-slot mismatch head=%0d pattern=%0d", head, pattern));
      end
    end

    $display("PASS: L2 scalar/burst write-allocate, errors, dirty victims and CBO");
    $finish;
  end
endmodule
