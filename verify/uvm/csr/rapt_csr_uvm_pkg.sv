package rapt_csr_uvm_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  `include "rapt.svh"

  typedef virtual rapt_csr_uvm_if csr_vif_t;

  typedef enum bit [2:0] {
    CSR_IDLE,
    CSR_WRITE,
    CSR_ECALL,
    CSR_MRET,
    CSR_SRET,
    CSR_TRAP
  } csr_op_t;

  class csr_item extends uvm_sequence_item;
    csr_op_t op;
    bit [31:0] pc;
    bit [11:0] address;
    bit [31:0] data;
    bit [31:0] cause;
    bit [31:0] tval;

    bit reset;
    bit [31:0] observed_sepc;
    bit [31:0] observed_mtvec;
    bit [31:0] observed_stvec;
    bit [1:0] observed_priv;

    `uvm_object_utils(csr_item)

    function new(string name = "csr_item");
      super.new(name);
      op = CSR_IDLE;
    endfunction
  endclass

  class csr_sequencer extends uvm_sequencer #(csr_item);
    `uvm_component_utils(csr_sequencer)
    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction
  endclass

  class csr_driver extends uvm_driver #(csr_item);
    `uvm_component_utils(csr_driver)
    csr_vif_t vif;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(csr_vif_t)::get(this, "", "vif", vif))
        `uvm_fatal("NOVIF", "CSR virtual interface was not configured")
    endfunction

    task clear_request();
      vif.pc <= '0;
      vif.csr_wen <= 1'b0;
      vif.csr_wdata <= '0;
      vif.csr_addr <= '0;
      vif.ecall <= 1'b0;
      vif.ebreak <= 1'b0;
      vif.mret <= 1'b0;
      vif.sret <= 1'b0;
      vif.trap <= 1'b0;
      vif.tval <= '0;
      vif.cause <= '0;
      vif.valid <= 1'b0;
    endtask

    task run_phase(uvm_phase phase);
      clear_request();
      vif.reset <= 1'b1;
      repeat (4) @(posedge vif.clock);
      @(negedge vif.clock);
      vif.reset <= 1'b0;
      forever begin
        seq_item_port.get_next_item(req);
        @(negedge vif.clock);
        clear_request();
        vif.pc <= req.pc;
        vif.csr_addr <= req.address;
        vif.csr_wdata <= req.data;
        vif.csr_wen <= (req.op == CSR_WRITE);
        vif.ecall <= (req.op == CSR_ECALL);
        vif.mret <= (req.op == CSR_MRET);
        vif.sret <= (req.op == CSR_SRET);
        vif.trap <= (req.op == CSR_TRAP);
        vif.cause <= req.cause;
        vif.tval <= req.tval;
        vif.valid <= (req.op != CSR_IDLE);
        @(posedge vif.clock);
        #1ps;
        seq_item_port.item_done();
      end
    endtask
  endclass

  class csr_monitor extends uvm_monitor;
    `uvm_component_utils(csr_monitor)
    csr_vif_t vif;
    uvm_analysis_port #(csr_item) analysis_port;

    function new(string name, uvm_component parent);
      super.new(name, parent);
      analysis_port = new("analysis_port", this);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(csr_vif_t)::get(this, "", "vif", vif))
        `uvm_fatal("NOVIF", "CSR virtual interface was not configured")
    endfunction

    task run_phase(uvm_phase phase);
      forever begin
        csr_item sample;
        @(posedge vif.clock);
        #1ps;
        sample = csr_item::type_id::create("sample");
        sample.reset = vif.reset;
        sample.pc = vif.pc;
        sample.address = vif.csr_addr;
        sample.data = vif.csr_wdata;
        sample.cause = vif.cause;
        sample.tval = vif.tval;
        if (vif.csr_wen && vif.valid)
          sample.op = CSR_WRITE;
        else if (vif.ecall && vif.valid)
          sample.op = CSR_ECALL;
        else if (vif.mret && vif.valid)
          sample.op = CSR_MRET;
        else if (vif.sret && vif.valid)
          sample.op = CSR_SRET;
        else if (vif.trap && vif.valid)
          sample.op = CSR_TRAP;
        else
          sample.op = CSR_IDLE;
        sample.observed_sepc = vif.sepc;
        sample.observed_mtvec = vif.mtvec;
        sample.observed_stvec = vif.stvec;
        sample.observed_priv = vif.priv;
        analysis_port.write(sample);
      end
    endtask
  endclass

  class csr_scoreboard extends uvm_scoreboard;
    `uvm_component_utils(csr_scoreboard)
    uvm_analysis_imp #(csr_item, csr_scoreboard) analysis_export;
    bit [31:0] expected_sepc;
    bit [31:0] expected_mtvec;
    bit [31:0] expected_stvec;
    bit [31:0] expected_mstatus;
    bit [31:0] expected_medeleg;
    bit [31:0] expected_mideleg;
    bit [1:0] expected_priv;
    int unsigned checked_sret;
    int unsigned cov_op;
    bit [1:0] cov_priv;
    bit cov_mtvec_alias;

    covergroup csr_cg;
      option.per_instance = 1;
      cp_op: coverpoint cov_op {
        bins write = {CSR_WRITE};
        bins ecall = {CSR_ECALL};
        bins mret = {CSR_MRET};
        bins sret = {CSR_SRET};
        bins trap = {CSR_TRAP};
      }
      cp_priv: coverpoint cov_priv;
      cp_mtvec_alias: coverpoint cov_mtvec_alias { bins clean = {0}; illegal_bins contaminated = {1}; }
      op_priv: cross cp_op, cp_priv;
    endgroup

    function new(string name, uvm_component parent);
      super.new(name, parent);
      analysis_export = new("analysis_export", this);
      csr_cg = new();
      reset_model();
    endfunction

    function void reset_model();
      expected_sepc = 0;
      expected_mtvec = 0;
      expected_stvec = 0;
      expected_mstatus = 0;
      expected_medeleg = 0;
      expected_mideleg = 0;
      expected_priv = `RAPT_PRIV_M;
      checked_sret = 0;
    endfunction

    function void write(csr_item item);
      if (item.reset) begin
        reset_model();
        return;
      end

      case (item.op)
        CSR_WRITE: begin
          case (item.address)
            `RAPT_CSR_MTVEC__: expected_mtvec = {item.data[31:2], item.data[1] ? 2'b00 : item.data[1:0]};
            `RAPT_CSR_STVEC__: expected_stvec = {item.data[31:2], item.data[1] ? 2'b00 : item.data[1:0]};
            `RAPT_CSR_SEPC___: expected_sepc = {item.data[31:1], 1'b0};
            `RAPT_CSR_MSTATUS: expected_mstatus = item.data;
            `RAPT_CSR_MEDELEG: expected_medeleg = item.data;
            `RAPT_CSR_MIDELEG: expected_mideleg = item.data;
            default: ;
          endcase
        end
        CSR_ECALL: begin
          if (expected_priv != `RAPT_PRIV_M && expected_medeleg[expected_priv == `RAPT_PRIV_U ? 8 : 9]) begin
            expected_sepc = item.pc;
            expected_mstatus[`RAPT_CSR_MSTATUS_SPP_] = (expected_priv == `RAPT_PRIV_S);
            expected_priv = `RAPT_PRIV_S;
          end else begin
            expected_priv = `RAPT_PRIV_M;
          end
        end
        CSR_MRET: begin
          expected_priv = expected_mstatus[`RAPT_CSR_MSTATUS_MPP_];
          expected_mstatus[`RAPT_CSR_MSTATUS_MPP_] = `RAPT_PRIV_U;
        end
        CSR_SRET: begin
          expected_priv = expected_mstatus[`RAPT_CSR_MSTATUS_SPP_] ? `RAPT_PRIV_S : `RAPT_PRIV_U;
          expected_mstatus[`RAPT_CSR_MSTATUS_SPP_] = 1'b0;
          checked_sret++;
        end
        CSR_TRAP: begin
          if (item.cause[31] && expected_mideleg[item.cause[4:0]]) begin
            expected_sepc = item.pc;
            expected_mstatus[`RAPT_CSR_MSTATUS_SPP_] = (expected_priv == `RAPT_PRIV_S);
            expected_priv = `RAPT_PRIV_S;
          end else begin
            expected_priv = `RAPT_PRIV_M;
          end
        end
        default: ;
      endcase

      if (item.observed_sepc !== expected_sepc)
        `uvm_error("SEPC", $sformatf("op=%0d expected sepc=%08x observed=%08x", item.op, expected_sepc, item.observed_sepc))
      if (item.observed_priv !== expected_priv)
        `uvm_error("PRIV", $sformatf("op=%0d expected priv=%0d observed=%0d", item.op, expected_priv, item.observed_priv))
      if (item.observed_mtvec !== expected_mtvec)
        `uvm_error("MTVEC", $sformatf("expected mtvec=%08x observed=%08x", expected_mtvec, item.observed_mtvec))
      if (item.observed_stvec !== expected_stvec)
        `uvm_error("STVEC", $sformatf("expected stvec=%08x observed=%08x", expected_stvec, item.observed_stvec))
      if (item.op == CSR_SRET && item.observed_sepc == item.observed_mtvec)
        `uvm_error("SRET_MTVEC", "SRET return target was contaminated by mtvec")

      cov_op = item.op;
      cov_priv = item.observed_priv;
      cov_mtvec_alias = (item.op == CSR_SRET && item.observed_sepc == item.observed_mtvec);
      csr_cg.sample();
    endfunction

    function void report_phase(uvm_phase phase);
      super.report_phase(phase);
      if (checked_sret < 2000)
        `uvm_error("COVERAGE", $sformatf("only %0d SRET operations checked", checked_sret))
      else
        `uvm_info("CSR_SCOREBOARD", $sformatf("checked %0d SRET operations without mtvec contamination", checked_sret), UVM_NONE)
    endfunction
  endclass

  class csr_agent extends uvm_agent;
    `uvm_component_utils(csr_agent)
    csr_sequencer sequencer;
    csr_driver driver;
    csr_monitor monitor;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      sequencer = csr_sequencer::type_id::create("sequencer", this);
      driver = csr_driver::type_id::create("driver", this);
      monitor = csr_monitor::type_id::create("monitor", this);
    endfunction

    function void connect_phase(uvm_phase phase);
      super.connect_phase(phase);
      driver.seq_item_port.connect(sequencer.seq_item_export);
    endfunction
  endclass

  class csr_env extends uvm_env;
    `uvm_component_utils(csr_env)
    csr_agent agent;
    csr_scoreboard scoreboard;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      agent = csr_agent::type_id::create("agent", this);
      scoreboard = csr_scoreboard::type_id::create("scoreboard", this);
    endfunction

    function void connect_phase(uvm_phase phase);
      super.connect_phase(phase);
      agent.monitor.analysis_port.connect(scoreboard.analysis_export);
    endfunction
  endclass

  class linux_sret_sequence extends uvm_sequence #(csr_item);
    `uvm_object_utils(linux_sret_sequence)

    function new(string name = "linux_sret_sequence");
      super.new(name);
    endfunction

    task send(csr_op_t op, bit [31:0] pc = 0, bit [11:0] address = 0,
              bit [31:0] data = 0, bit [31:0] cause = 0);
      csr_item item = csr_item::type_id::create("item");
      start_item(item);
      item.op = op;
      item.pc = pc;
      item.address = address;
      item.data = data;
      item.cause = cause;
      finish_item(item);
    endtask

    task body();
      send(CSR_WRITE, 0, `RAPT_CSR_MTVEC__, 32'h8000_0400);
      send(CSR_WRITE, 0, `RAPT_CSR_STVEC__, 32'hc039_b7b0);
      send(CSR_WRITE, 0, `RAPT_CSR_MEDELEG, 32'h0000_0100);
      send(CSR_WRITE, 0, `RAPT_CSR_MIDELEG, 32'h0000_0020);
      send(CSR_WRITE, 0, `RAPT_CSR_MSTATUS, 32'h0000_0000);
      send(CSR_MRET, 32'h8000_0100);

      for (int round = 0; round < 2000; round++) begin
        bit [31:0] user_ecall_pc = 32'h0001_011c + ((round & 3) << 8);
        send(CSR_ECALL, user_ecall_pc);
        send(CSR_WRITE, 0, `RAPT_CSR_SEPC___, user_ecall_pc + 4);
        send(CSR_SRET, 32'hc039_b8ee);

        if ($urandom_range(0, 7) == 0) begin
          bit [31:0] interrupted_pc = user_ecall_pc + 32'h20;
          send(CSR_TRAP, interrupted_pc, 0, 0, 32'h8000_0005);
          send(CSR_WRITE, 0, `RAPT_CSR_SEPC___, interrupted_pc);
          send(CSR_SRET, 32'hc039_b8ee);
        end
      end
    endtask
  endclass

  class csr_uvm_test extends uvm_test;
    `uvm_component_utils(csr_uvm_test)
    csr_env env;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      env = csr_env::type_id::create("env", this);
    endfunction

    task run_phase(uvm_phase phase);
      linux_sret_sequence test_sequence = linux_sret_sequence::type_id::create("test_sequence");
      phase.raise_objection(this);
      test_sequence.start(env.agent.sequencer);
      repeat (2) @(posedge env.agent.driver.vif.clock);
      phase.drop_objection(this);
    endtask
  endclass
endpackage