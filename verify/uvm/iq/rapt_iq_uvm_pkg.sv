package rapt_iq_uvm_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"

  localparam int IQSize = 8;
  localparam int XLEN = 32;
  localparam int PLEN = 7;
  localparam int RLEN = 5;
  localparam int ROBLEN = 6;

  typedef virtual rapt_iq_uvm_if iq_vif_t;

  class iq_cycle_item extends uvm_sequence_item;
    bit flush_pipe;
    bit accept_a;
    bit accept_b;
    bit iss_b_block_a;
    bit iss_b_block_b;
    bit [XLEN-1:0] pc_a;
    bit [XLEN-1:0] op1_a;
    bit [XLEN-1:0] op2_a;
    bit [PLEN-1:0] pr1_a;
    bit [PLEN-1:0] pr2_a;
    bit [PLEN-1:0] prd_a;
    bit [RLEN-1:0] rd_a;
    bit [ROBLEN-1:0] dest_a;
    bit [XLEN-1:0] pc_b;
    bit [XLEN-1:0] op1_b;
    bit [XLEN-1:0] op2_b;
    bit [PLEN-1:0] pr1_b;
    bit [PLEN-1:0] pr2_b;
    bit [PLEN-1:0] prd_b;
    bit [RLEN-1:0] rd_b;
    bit [ROBLEN-1:0] dest_b;
    bit [3:0] wb_valid;
    bit [PLEN-1:0] wb_prd_0;
    bit [PLEN-1:0] wb_prd_1;
    bit [PLEN-1:0] wb_prd_2;
    bit [PLEN-1:0] wb_prd_3;
    bit [XLEN-1:0] wb_result_0;
    bit [XLEN-1:0] wb_result_1;
    bit [XLEN-1:0] wb_result_2;
    bit [XLEN-1:0] wb_result_3;
    bit load_fast_valid;
    bit load_fast_rebusy;
    bit [PLEN-1:0] load_fast_prd;

    bit reset;
    bit [$clog2(IQSize)-1:0] b_rs_idx;
    bit free_found_a;
    bit free_found_b;
    bit [$clog2(IQSize)-1:0] free_idx_a;
    bit [$clog2(IQSize)-1:0] free_idx_b;
    bit [$clog2(IQSize):0] occ;
    bit pmu_iq_full;
    bit iss_valid;
    bit [XLEN-1:0] iss_pc;
    bit [XLEN-1:0] iss_op1;
    bit [XLEN-1:0] iss_op2;
    bit [PLEN-1:0] iss_prd;
    bit [RLEN-1:0] iss_rd;
    bit [ROBLEN-1:0] iss_dest;
    bit iss_b_valid;
    bit [XLEN-1:0] iss_b_pc;
    bit [XLEN-1:0] iss_b_op1;
    bit [XLEN-1:0] iss_b_op2;
    bit [PLEN-1:0] iss_b_prd;
    bit [RLEN-1:0] iss_b_rd;
    bit [ROBLEN-1:0] iss_b_dest;

    `uvm_object_utils(iq_cycle_item)

    function new(string name = "iq_cycle_item");
      super.new(name);
    endfunction

    function void clear_stimulus();
      flush_pipe = 0;
      accept_a = 0;
      accept_b = 0;
      iss_b_block_a = 0;
      iss_b_block_b = 0;
      pc_a = 0;
      op1_a = 0;
      op2_a = 0;
      pr1_a = 0;
      pr2_a = 0;
      prd_a = 0;
      rd_a = 0;
      dest_a = 0;
      pc_b = 0;
      op1_b = 0;
      op2_b = 0;
      pr1_b = 0;
      pr2_b = 0;
      prd_b = 0;
      rd_b = 0;
      dest_b = 0;
      wb_valid = 0;
      wb_prd_0 = 0;
      wb_prd_1 = 0;
      wb_prd_2 = 0;
      wb_prd_3 = 0;
      wb_result_0 = 0;
      wb_result_1 = 0;
      wb_result_2 = 0;
      wb_result_3 = 0;
      load_fast_valid = 0;
      load_fast_rebusy = 0;
      load_fast_prd = 0;
    endfunction

    function void generate_random_stimulus();
      clear_stimulus();
      flush_pipe = ($urandom_range(0, 99) == 0);
      accept_a = ($urandom_range(0, 99) < 55);
      accept_b = ($urandom_range(0, 99) < 45);
      iss_b_block_a = ($urandom_range(0, 99) < 20);
      iss_b_block_b = ($urandom_range(0, 99) < 20);
      pr1_a = ($urandom_range(0, 99) < 45) ? 0 : $urandom_range(1, 31);
      pr2_a = ($urandom_range(0, 99) < 45) ? 0 : $urandom_range(1, 31);
      pr1_b = ($urandom_range(0, 99) < 45) ? 0 : $urandom_range(1, 31);
      pr2_b = ($urandom_range(0, 99) < 45) ? 0 : $urandom_range(1, 31);
      prd_a = $urandom_range(1, 63);
      prd_b = $urandom_range(1, 63);
      rd_a = $urandom_range(1, 31);
      rd_b = $urandom_range(1, 31);
      dest_a = $urandom;
      dest_b = $urandom;
      op1_a = $urandom;
      op2_a = $urandom;
      op1_b = $urandom;
      op2_b = $urandom;
      wb_valid[0] = ($urandom_range(0, 99) < 20);
      wb_valid[1] = ($urandom_range(0, 99) < 20);
      wb_valid[2] = ($urandom_range(0, 99) < 20);
      wb_valid[3] = ($urandom_range(0, 99) < 20);
      wb_prd_0 = $urandom_range(1, 31);
      wb_prd_1 = $urandom_range(1, 31);
      wb_prd_2 = $urandom_range(1, 31);
      wb_prd_3 = $urandom_range(1, 31);
      wb_result_0 = $urandom;
      wb_result_1 = $urandom;
      wb_result_2 = $urandom;
      wb_result_3 = $urandom;
      load_fast_valid = ($urandom_range(0, 99) < 12);
      load_fast_rebusy = ($urandom_range(0, 9) == 0);
      load_fast_prd = $urandom_range(1, 31);
    endfunction
  endclass

  class iq_sequencer extends uvm_sequencer #(iq_cycle_item);
    `uvm_component_utils(iq_sequencer)
    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction
  endclass

  class iq_driver extends uvm_driver #(iq_cycle_item);
    `uvm_component_utils(iq_driver)
    iq_vif_t vif;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(iq_vif_t)::get(this, "", "vif", vif))
        `uvm_fatal("NOVIF", "issue queue virtual interface was not configured")
    endfunction

    task run_phase(uvm_phase phase);
      vif.drv_cb.reset <= 1'b1;
      @(vif.drv_cb);
      @(vif.drv_cb);
      @(vif.drv_cb);
      @(vif.drv_cb);
      vif.drv_cb.reset <= 1'b0;
      drive_next_item();
    endtask

    task drive_next_item();
      seq_item_port.get_next_item(req);
      @(vif.drv_cb);
      drive_item(req);
      seq_item_port.item_done();
      drive_next_item();
    endtask

    task drive_item(iq_cycle_item item);
      vif.drv_cb.flush_pipe <= item.flush_pipe;
      vif.drv_cb.accept_a <= item.accept_a && vif.drv_cb.free_found_a;
      vif.drv_cb.accept_b <= item.accept_b && vif.drv_cb.free_found_b;
      vif.drv_cb.b_rs_idx <= vif.drv_cb.free_idx_b;
      vif.drv_cb.iss_b_block_a <= item.iss_b_block_a;
      vif.drv_cb.iss_b_block_b <= item.iss_b_block_b;
      vif.drv_cb.pc_a <= item.pc_a;
      vif.drv_cb.op1_a <= item.op1_a;
      vif.drv_cb.op2_a <= item.op2_a;
      vif.drv_cb.pr1_a <= item.pr1_a;
      vif.drv_cb.pr2_a <= item.pr2_a;
      vif.drv_cb.prd_a <= item.prd_a;
      vif.drv_cb.rd_a <= item.rd_a;
      vif.drv_cb.dest_a <= item.dest_a;
      vif.drv_cb.pc_b <= item.pc_b;
      vif.drv_cb.op1_b <= item.op1_b;
      vif.drv_cb.op2_b <= item.op2_b;
      vif.drv_cb.pr1_b <= item.pr1_b;
      vif.drv_cb.pr2_b <= item.pr2_b;
      vif.drv_cb.prd_b <= item.prd_b;
      vif.drv_cb.rd_b <= item.rd_b;
      vif.drv_cb.dest_b <= item.dest_b;
      vif.drv_cb.wb_valid <= item.wb_valid;
      vif.drv_cb.wb_prd_0 <= item.wb_prd_0;
      vif.drv_cb.wb_prd_1 <= item.wb_prd_1;
      vif.drv_cb.wb_prd_2 <= item.wb_prd_2;
      vif.drv_cb.wb_prd_3 <= item.wb_prd_3;
      vif.drv_cb.wb_result_0 <= item.wb_result_0;
      vif.drv_cb.wb_result_1 <= item.wb_result_1;
      vif.drv_cb.wb_result_2 <= item.wb_result_2;
      vif.drv_cb.wb_result_3 <= item.wb_result_3;
      vif.drv_cb.load_fast_valid <= item.load_fast_valid;
      vif.drv_cb.load_fast_rebusy <= item.load_fast_rebusy;
      vif.drv_cb.load_fast_prd <= item.load_fast_prd;
    endtask
  endclass

  class iq_monitor extends uvm_monitor;
    `uvm_component_utils(iq_monitor)
    iq_vif_t vif;
    uvm_analysis_port #(iq_cycle_item) analysis_port;

    function new(string name, uvm_component parent);
      super.new(name, parent);
      analysis_port = new("analysis_port", this);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(iq_vif_t)::get(this, "", "vif", vif))
        `uvm_fatal("NOVIF", "issue queue virtual interface was not configured")
    endfunction

    task run_phase(uvm_phase phase);
      capture_next_cycle();
    endtask

    task capture_next_cycle();
      iq_cycle_item sample = iq_cycle_item::type_id::create("sample");
      @(vif.mon_cb);
      sample.reset = vif.mon_cb.reset;
        sample.flush_pipe = vif.mon_cb.flush_pipe;
        sample.accept_a = vif.mon_cb.accept_a;
        sample.accept_b = vif.mon_cb.accept_b;
        sample.b_rs_idx = vif.mon_cb.b_rs_idx;
        sample.iss_b_block_a = vif.mon_cb.iss_b_block_a;
        sample.iss_b_block_b = vif.mon_cb.iss_b_block_b;
        sample.pc_a = vif.mon_cb.pc_a;
        sample.op1_a = vif.mon_cb.op1_a;
        sample.op2_a = vif.mon_cb.op2_a;
        sample.pr1_a = vif.mon_cb.pr1_a;
        sample.pr2_a = vif.mon_cb.pr2_a;
        sample.prd_a = vif.mon_cb.prd_a;
        sample.rd_a = vif.mon_cb.rd_a;
        sample.dest_a = vif.mon_cb.dest_a;
        sample.pc_b = vif.mon_cb.pc_b;
        sample.op1_b = vif.mon_cb.op1_b;
        sample.op2_b = vif.mon_cb.op2_b;
        sample.pr1_b = vif.mon_cb.pr1_b;
        sample.pr2_b = vif.mon_cb.pr2_b;
        sample.prd_b = vif.mon_cb.prd_b;
        sample.rd_b = vif.mon_cb.rd_b;
        sample.dest_b = vif.mon_cb.dest_b;
        sample.wb_valid = vif.mon_cb.wb_valid;
        sample.wb_prd_0 = vif.mon_cb.wb_prd_0;
        sample.wb_prd_1 = vif.mon_cb.wb_prd_1;
        sample.wb_prd_2 = vif.mon_cb.wb_prd_2;
        sample.wb_prd_3 = vif.mon_cb.wb_prd_3;
        sample.wb_result_0 = vif.mon_cb.wb_result_0;
        sample.wb_result_1 = vif.mon_cb.wb_result_1;
        sample.wb_result_2 = vif.mon_cb.wb_result_2;
        sample.wb_result_3 = vif.mon_cb.wb_result_3;
        sample.load_fast_valid = vif.mon_cb.load_fast_valid;
        sample.load_fast_rebusy = vif.mon_cb.load_fast_rebusy;
        sample.load_fast_prd = vif.mon_cb.load_fast_prd;
        sample.free_found_a = vif.mon_cb.free_found_a;
        sample.free_found_b = vif.mon_cb.free_found_b;
        sample.free_idx_a = vif.mon_cb.free_idx_a;
        sample.free_idx_b = vif.mon_cb.free_idx_b;
        sample.occ = vif.mon_cb.occ;
        sample.pmu_iq_full = vif.mon_cb.pmu_iq_full;
        sample.iss_valid = vif.mon_cb.iss_valid;
        sample.iss_pc = vif.mon_cb.iss_pc;
        sample.iss_op1 = vif.mon_cb.iss_op1;
        sample.iss_op2 = vif.mon_cb.iss_op2;
        sample.iss_prd = vif.mon_cb.iss_prd;
        sample.iss_rd = vif.mon_cb.iss_rd;
        sample.iss_dest = vif.mon_cb.iss_dest;
        sample.iss_b_valid = vif.mon_cb.iss_b_valid;
        sample.iss_b_pc = vif.mon_cb.iss_b_pc;
        sample.iss_b_op1 = vif.mon_cb.iss_b_op1;
        sample.iss_b_op2 = vif.mon_cb.iss_b_op2;
        sample.iss_b_prd = vif.mon_cb.iss_b_prd;
        sample.iss_b_rd = vif.mon_cb.iss_b_rd;
        sample.iss_b_dest = vif.mon_cb.iss_b_dest;
      analysis_port.write(sample);
      capture_next_cycle();
    endtask
  endclass

  typedef struct {
    bit valid;
    bit b_block;
    bit [XLEN-1:0] pc;
    bit [XLEN-1:0] op1;
    bit [XLEN-1:0] op2;
    bit [PLEN-1:0] pr1;
    bit [PLEN-1:0] pr2;
    bit pr1_busy;
    bit pr2_busy;
    bit pr1_fast;
    bit pr2_fast;
    bit [PLEN-1:0] prd;
    bit [RLEN-1:0] rd;
    bit [ROBLEN-1:0] dest;
    longint unsigned age;
  } iq_model_entry_t;

  class iq_scoreboard extends uvm_scoreboard;
    `uvm_component_utils(iq_scoreboard)
    uvm_analysis_imp #(iq_cycle_item, iq_scoreboard) analysis_export;
    iq_model_entry_t entries[IQSize];
    longint unsigned next_age;
    int unsigned checked_cycles;

    function new(string name, uvm_component parent);
      super.new(name, parent);
      analysis_export = new("analysis_export", this);
    endfunction

    function bit [PLEN-1:0] wb_prd_at(iq_cycle_item item, int port);
      case (port)
        0: return item.wb_prd_0;
        1: return item.wb_prd_1;
        2: return item.wb_prd_2;
        default: return item.wb_prd_3;
      endcase
    endfunction

    function bit [XLEN-1:0] wb_result_at(iq_cycle_item item, int port);
      case (port)
        0: return item.wb_result_0;
        1: return item.wb_result_1;
        2: return item.wb_result_2;
        default: return item.wb_result_3;
      endcase
    endfunction

    function bit wb_hit(iq_cycle_item item, bit [PLEN-1:0] pr);
      wb_hit = 0;
      for (int p = 0; p < 4; p++)
        wb_hit |= (pr != 0) && item.wb_valid[p] && (wb_prd_at(item, p) == pr);
    endfunction

    function bit [XLEN-1:0] wb_value(iq_cycle_item item, bit [PLEN-1:0] pr,
                                     bit [XLEN-1:0] old_value);
      wb_value = old_value;
      for (int p = 3; p >= 0; p--)
        if ((pr != 0) && item.wb_valid[p] && (wb_prd_at(item, p) == pr))
          wb_value = wb_result_at(item, p);
    endfunction

    function bit fast_wake(iq_cycle_item item, bit [PLEN-1:0] pr);
      return (pr != 0) && item.load_fast_valid && !item.load_fast_rebusy
             && (item.load_fast_prd == pr);
    endfunction

    function bit fast_confirm(iq_cycle_item item, bit is_fast, bit [PLEN-1:0] pr);
      return is_fast && item.wb_valid[0] && (item.wb_prd_0 == pr);
    endfunction

    function bit fast_rebusy(iq_cycle_item item, bit is_fast, bit [PLEN-1:0] pr);
      return is_fast && item.load_fast_valid && item.load_fast_rebusy
             && (item.load_fast_prd == pr);
    endfunction

    function bit entry_ready(iq_cycle_item item, int index);
      return entries[index].valid
             && !entries[index].pr1_busy && !entries[index].pr2_busy
             && (!entries[index].pr1_fast
                 || fast_confirm(item, entries[index].pr1_fast, entries[index].pr1))
             && (!entries[index].pr2_fast
                 || fast_confirm(item, entries[index].pr2_fast, entries[index].pr2));
    endfunction

    function int oldest_ready(iq_cycle_item item, bit port_b, int exclude);
      int winner = -1;
      for (int i = 0; i < IQSize; i++) begin
        if (i != exclude && entry_ready(item, i) && (!port_b || !entries[i].b_block)) begin
          if (winner < 0 || entries[i].age < entries[winner].age) winner = i;
        end
      end
      return winner;
    endfunction

    function int model_occ();
      model_occ = 0;
      for (int i = 0; i < IQSize; i++) model_occ += entries[i].valid;
    endfunction

    function void check_issue(iq_cycle_item item, int index, bit port_b);
      string port_name = port_b ? "B" : "A";
      bit actual_valid = port_b ? item.iss_b_valid : item.iss_valid;
      bit [XLEN-1:0] actual_pc = port_b ? item.iss_b_pc : item.iss_pc;
      bit [XLEN-1:0] actual_op1 = port_b ? item.iss_b_op1 : item.iss_op1;
      bit [XLEN-1:0] actual_op2 = port_b ? item.iss_b_op2 : item.iss_op2;
      bit [PLEN-1:0] actual_prd = port_b ? item.iss_b_prd : item.iss_prd;
      bit [XLEN-1:0] expected_op1;
      bit [XLEN-1:0] expected_op2;

      if (actual_valid != (index >= 0))
        `uvm_error("IQ_VALID", $sformatf("port %s valid=%0b expected=%0b", port_name,
                                        actual_valid, index >= 0))
      if (index < 0 || !actual_valid) return;
      expected_op1 = fast_confirm(item, entries[index].pr1_fast, entries[index].pr1)
                     ? item.wb_result_0 : entries[index].op1;
      expected_op2 = fast_confirm(item, entries[index].pr2_fast, entries[index].pr2)
                     ? item.wb_result_0 : entries[index].op2;
      if (actual_pc != entries[index].pc || actual_prd != entries[index].prd
          || actual_op1 != expected_op1 || actual_op2 != expected_op2)
        `uvm_error("IQ_PAYLOAD", $sformatf(
          {"port %s got pc=%08h prd=%0d op1=%08h op2=%08h ",
           "expected pc=%08h prd=%0d op1=%08h op2=%08h"},
          port_name, actual_pc, actual_prd, actual_op1, actual_op2,
          entries[index].pc, entries[index].prd, expected_op1, expected_op2))
    endfunction

    function void allocate_entry(int index, bit slot_b, iq_cycle_item item,
                                 longint unsigned age_value);
      entries[index].valid = 1;
      entries[index].b_block = slot_b ? item.iss_b_block_b : item.iss_b_block_a;
      entries[index].pc = slot_b ? item.pc_b : item.pc_a;
      entries[index].op1 = slot_b ? item.op1_b : item.op1_a;
      entries[index].op2 = slot_b ? item.op2_b : item.op2_a;
      entries[index].pr1 = slot_b ? item.pr1_b : item.pr1_a;
      entries[index].pr2 = slot_b ? item.pr2_b : item.pr2_a;
      entries[index].prd = slot_b ? item.prd_b : item.prd_a;
      entries[index].rd = slot_b ? item.rd_b : item.rd_a;
      entries[index].dest = slot_b ? item.dest_b : item.dest_a;
      entries[index].pr1_busy = (entries[index].pr1 != 0)
                                && !fast_wake(item, entries[index].pr1);
      entries[index].pr2_busy = (entries[index].pr2 != 0)
                                && !fast_wake(item, entries[index].pr2);
      entries[index].pr1_fast = fast_wake(item, entries[index].pr1);
      entries[index].pr2_fast = fast_wake(item, entries[index].pr2);
      entries[index].age = age_value;
    endfunction

    function void update_operand(iq_cycle_item item, int index, bit operand_two);
      bit [PLEN-1:0] pr = operand_two ? entries[index].pr2 : entries[index].pr1;
      bit is_fast = operand_two ? entries[index].pr2_fast : entries[index].pr1_fast;
      bit is_busy = operand_two ? entries[index].pr2_busy : entries[index].pr1_busy;
      bit [XLEN-1:0] value = operand_two ? entries[index].op2 : entries[index].op1;

      if (fast_confirm(item, is_fast, pr)) begin
        value = item.wb_result_0;
        pr = 0;
        is_busy = 0;
        is_fast = 0;
      end else if (fast_rebusy(item, is_fast, pr)) begin
        is_busy = 1;
        is_fast = 0;
      end else if (is_busy && wb_hit(item, pr)) begin
        value = wb_value(item, pr, value);
        pr = 0;
        is_busy = 0;
        is_fast = 0;
      end else if (is_busy && fast_wake(item, pr)) begin
        is_busy = 0;
        is_fast = 1;
      end

      if (operand_two) begin
        entries[index].pr2 = pr;
        entries[index].pr2_busy = is_busy;
        entries[index].pr2_fast = is_fast;
        entries[index].op2 = value;
      end else begin
        entries[index].pr1 = pr;
        entries[index].pr1_busy = is_busy;
        entries[index].pr1_fast = is_fast;
        entries[index].op1 = value;
      end
    endfunction

    function void write(iq_cycle_item item);
      int issue_a;
      int issue_b;
      bit ready[IQSize];
      checked_cycles++;

      if (item.reset) begin
        foreach (entries[i]) entries[i] = '{default: 0};
        next_age = 0;
        return;
      end

      if (item.occ != model_occ())
        `uvm_error("IQ_OCC", $sformatf("occupancy=%0d expected=%0d", item.occ, model_occ()))

      issue_a = oldest_ready(item, 0, -1);
      issue_b = oldest_ready(item, 1, issue_a);
      check_issue(item, issue_a, 0);
      check_issue(item, issue_b, 1);
      for (int i = 0; i < IQSize; i++) ready[i] = entry_ready(item, i);

      if (item.flush_pipe) begin
        foreach (entries[i]) entries[i] = '{default: 0};
        return;
      end

      for (int i = 0; i < IQSize; i++) begin
        if (item.accept_b && i == item.b_rs_idx) begin
          allocate_entry(i, 1, item, next_age + (item.accept_a ? 1 : 0));
        end else if (item.accept_a && item.free_found_a && i == item.free_idx_a) begin
          allocate_entry(i, 0, item, next_age);
        end else if (entries[i].valid && ready[i]) begin
          update_operand(item, i, 0);
          update_operand(item, i, 1);
          if (i == issue_a || i == issue_b) entries[i].valid = 0;
        end else if (entries[i].valid) begin
          update_operand(item, i, 0);
          update_operand(item, i, 1);
        end
      end
      if (item.accept_a && item.free_found_a) next_age++;
      if (item.accept_b) next_age++;
    endfunction

    function void report_phase(uvm_phase phase);
      `uvm_info("IQ_SCOREBOARD",
            $sformatf("checked %0d issue-queue cycles", checked_cycles), UVM_LOW)
    endfunction
  endclass

  class iq_coverage extends uvm_subscriber #(iq_cycle_item);
    `uvm_component_utils(iq_coverage)
    int unsigned occ_empty_hits;
    int unsigned occ_partial_hits;
    int unsigned occ_full_hits;
    int unsigned dispatch_a_hits;
    int unsigned dispatch_b_hits;
    int unsigned dual_dispatch_hits;
    int unsigned wb_port_hits[4];
    int unsigned fast_wake_hits;
    int unsigned fast_rebusy_hits;
    int unsigned flush_hits;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void write(iq_cycle_item t);
      if (t.reset) return;
      if (t.occ == 0) occ_empty_hits++;
      else if (t.occ == IQSize) occ_full_hits++;
      else occ_partial_hits++;
      dispatch_a_hits += t.accept_a;
      dispatch_b_hits += t.accept_b;
      dual_dispatch_hits += t.accept_a && t.accept_b;
      for (int i = 0; i < 4; i++) wb_port_hits[i] += t.wb_valid[i];
      fast_wake_hits += t.load_fast_valid && !t.load_fast_rebusy;
      fast_rebusy_hits += t.load_fast_valid && t.load_fast_rebusy;
      flush_hits += t.flush_pipe;
    endfunction

    function void report_phase(uvm_phase phase);
      `uvm_info("IQ_COVERAGE", $sformatf(
        {"occ(empty/partial/full)=%0d/%0d/%0d dispatch(A/B/dual)=%0d/%0d/%0d ",
         "wb=%0d/%0d/%0d/%0d fast(wake/rebusy)=%0d/%0d flush=%0d"},
        occ_empty_hits, occ_partial_hits, occ_full_hits,
        dispatch_a_hits, dispatch_b_hits, dual_dispatch_hits,
        wb_port_hits[0], wb_port_hits[1], wb_port_hits[2], wb_port_hits[3],
        fast_wake_hits, fast_rebusy_hits, flush_hits), UVM_LOW)
    endfunction
  endclass

  class iq_agent extends uvm_agent;
    `uvm_component_utils(iq_agent)
    iq_sequencer sequencer;
    iq_driver driver;
    iq_monitor monitor;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      sequencer = iq_sequencer::type_id::create("sequencer", this);
      driver = iq_driver::type_id::create("driver", this);
      monitor = iq_monitor::type_id::create("monitor", this);
    endfunction

    function void connect_phase(uvm_phase phase);
      driver.seq_item_port.connect(sequencer.seq_item_export);
    endfunction
  endclass

  class iq_env extends uvm_env;
    `uvm_component_utils(iq_env)
    iq_agent agent;
    iq_scoreboard scoreboard;
    iq_coverage coverage_collector;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      agent = iq_agent::type_id::create("agent", this);
      scoreboard = iq_scoreboard::type_id::create("scoreboard", this);
      coverage_collector = iq_coverage::type_id::create("coverage_collector", this);
    endfunction

    function void connect_phase(uvm_phase phase);
      agent.monitor.analysis_port.connect(scoreboard.analysis_export);
      agent.monitor.analysis_port.connect(coverage_collector.analysis_export);
    endfunction
  endclass

  class iq_directed_sequence extends uvm_sequence #(iq_cycle_item);
    `uvm_object_utils(iq_directed_sequence)
    int unsigned next_pc = 32'h1000;

    function new(string name = "iq_directed_sequence");
      super.new(name);
    endfunction

    task send_idle();
      iq_cycle_item item = iq_cycle_item::type_id::create("directed_item");
      start_item(item);
      item.clear_stimulus();
      finish_item(item);
    endtask

    task body();
      iq_cycle_item item;

      item = iq_cycle_item::type_id::create("item");
      start_item(item);
      item.clear_stimulus();
      item.accept_a = 1;
      item.accept_b = 1;
      item.pc_a = next_pc++;
      item.pc_b = next_pc++;
      item.op1_a = 32'haaaa0001;
      item.op2_a = 32'haaaa0002;
      item.op1_b = 32'hbbbb0001;
      item.op2_b = 32'hbbbb0002;
      item.prd_a = 1;
      item.prd_b = 2;
      item.rd_a = 1;
      item.rd_b = 2;
      finish_item(item);
      send_idle();

      item = iq_cycle_item::type_id::create("item");
      start_item(item);
      item.clear_stimulus();
      item.accept_a = 1;
      item.pc_a = next_pc++;
      item.op1_a = 32'hdead0000;
      item.pr1_a = 7'd10;
      item.prd_a = 3;
      item.rd_a = 3;
      item.load_fast_valid = 1;
      item.load_fast_prd = 7'd10;
      finish_item(item);
      send_idle();

      item = iq_cycle_item::type_id::create("item");
      start_item(item);
      item.clear_stimulus();
      item.wb_valid[0] = 1;
      item.wb_prd_0 = 7'd10;
      item.wb_result_0 = 32'hc001cafe;
      finish_item(item);
      send_idle();

      item = iq_cycle_item::type_id::create("item");
      start_item(item);
      item.clear_stimulus();
      item.accept_a = 1;
      item.pc_a = next_pc++;
      item.pr1_a = 7'd11;
      item.prd_a = 4;
      item.rd_a = 4;
      item.load_fast_valid = 1;
      item.load_fast_prd = 7'd11;
      finish_item(item);

      item = iq_cycle_item::type_id::create("item");
      start_item(item);
      item.clear_stimulus();
      item.load_fast_valid = 1;
      item.load_fast_rebusy = 1;
      item.load_fast_prd = 7'd11;
      finish_item(item);

      item = iq_cycle_item::type_id::create("item");
      start_item(item);
      item.clear_stimulus();
      item.wb_valid[2] = 1;
      item.wb_prd_2 = 7'd11;
      item.wb_result_2 = 32'h51515151;
      finish_item(item);
      send_idle();
      send_idle();

      item = iq_cycle_item::type_id::create("item");
      start_item(item);
      item.clear_stimulus();
      item.flush_pipe = 1;
      finish_item(item);
      send_idle();
    endtask
  endclass

  class iq_random_sequence extends uvm_sequence #(iq_cycle_item);
    `uvm_object_utils(iq_random_sequence)
    int unsigned cycles = 500;

    function new(string name = "iq_random_sequence");
      super.new(name);
    endfunction

    task send_random_cycles(int unsigned remaining, ref int unsigned next_pc);
      iq_cycle_item item;
      if (remaining == 0) return;
      item = iq_cycle_item::type_id::create($sformatf("random_%0d", remaining));
      start_item(item);
      item.generate_random_stimulus();
      item.pc_a = next_pc++;
      item.pc_b = next_pc++;
      finish_item(item);
      send_random_cycles(remaining - 1, next_pc);
    endtask

    task send_drain_cycles(int unsigned remaining);
      iq_cycle_item drain;
      if (remaining == 0) return;
      drain = iq_cycle_item::type_id::create("drain");
      start_item(drain);
      drain.clear_stimulus();
      drain.flush_pipe = 1;
      finish_item(drain);
      send_drain_cycles(remaining - 1);
    endtask

    task body();
      int unsigned next_pc = 32'h10000;
      void'($value$plusargs("IQ_CYCLES=%d", cycles));
      send_random_cycles(cycles, next_pc);
      send_drain_cycles(12);
    endtask
  endclass

  class iq_uvm_test extends uvm_test;
    `uvm_component_utils(iq_uvm_test)
    iq_env env;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      env = iq_env::type_id::create("env", this);
    endfunction

    task run_phase(uvm_phase phase);
      iq_directed_sequence directed = iq_directed_sequence::type_id::create("directed");
      iq_random_sequence random_seq = iq_random_sequence::type_id::create("random_seq");
      phase.raise_objection(this);
      directed.start(env.agent.sequencer);
      random_seq.start(env.agent.sequencer);
      @(env.agent.driver.vif.drv_cb);
      @(env.agent.driver.vif.drv_cb);
      @(env.agent.driver.vif.drv_cb);
      phase.drop_objection(this);
    endtask
  endclass
endpackage
