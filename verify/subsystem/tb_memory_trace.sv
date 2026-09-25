`include "rapt.svh"
`include "rapt_if.svh"
`include "rapt_soc_if.svh"

// Program-order I/D request replay against the complete memory composition.
// AXI activity and accepted request rates are measured separately.
module tb_memory_trace;
  localparam int XLEN = `RAPT_XLEN;
  localparam int MaxTrace = 200000;
  logic clock = 0, reset = 1;
  always #5 clock = ~clock;
  ifu_l1i_if ifu_l1i ();
  lsu_l1d_if lsu_l1d ();
  lsu_l1d_mmu_if exu_l1d ();
  cmu_bcast_if cmu_bcast ();
  csr_bcast_if csr_bcast ();
  pmp_update_if pmp_update ();
  axi4_if axi ();
  logic data_idle, wb_idle, wb_error, io_start;
  logic [XLEN-1:0] io_owner;
  logic sim_finish;
  logic [31:0] sim_exit_code;

  rapt_memory dut (
      .clock,
      .reset,
      .ifu_l1i,
      .lsu_l1d,
      .exu_l1d,
      .cmu_bcast,
      .csr_bcast,
      .pmp_update,
      .io_master(axi),
      .ifetch_io_authorized_i(1'b0),
      .ifetch_io_start_o(io_start),
      .ifetch_io_owner_pc_o(io_owner),
      .data_idle_o(data_idle),
      .writeback_idle_o(wb_idle),
      .writeback_drain_i(1'b0),
      .writeback_error_o(wb_error)
  );

  tb_axi_image #(
      .XLEN(XLEN)
  ) external_memory (
      .clock,
      .reset,
      .axi,
      .sim_finish,
      .sim_exit_code
  );

  logic [XLEN-1:0] inst_pc[MaxTrace], mem_addr[MaxTrace], mem_data[MaxTrace];
  int inst_seq[MaxTrace], mem_seq[MaxTrace];
  int mem_size[MaxTrace];
  byte mem_op[MaxTrace];
  int inst_count, mem_count, inst_limit, mem_limit;
  int i_index, d_index;
  bit independent;
  logic d_eligible;

  function automatic logic [4:0] load_alu(input int bytes);
    case (bytes)
      1: return `RAPT_ALU_LBU_;
      2: return `RAPT_ALU_LHU_;
      4: return `RAPT_ALU_LW__;
      8: return `RAPT_ALU_LD__;
      default: return `RAPT_ALU_LW__;
    endcase
  endfunction

  always_comb begin
    d_eligible = independent;
    if (!independent && i_index > 0 && d_index < mem_limit)
      d_eligible = mem_seq[d_index] <= inst_seq[i_index-1];
    ifu_l1i.pc = i_index < inst_limit ? inst_pc[i_index] : 'h80000000;
    ifu_l1i.invalid = 0;
    ifu_l1i.consumed = !reset && i_index < inst_limit && ifu_l1i.valid;
    ifu_l1i.cancel = 0;
    ifu_l1i.prefetch_pc = '0;
    ifu_l1i.prefetch_valid = 0;

    lsu_l1d.raddr = d_index < mem_limit ? mem_addr[d_index] : '0;
    lsu_l1d.ralu = d_index < mem_limit ? load_alu(mem_size[d_index]) : '0;
    lsu_l1d.rvalid = !reset && d_index < mem_limit && d_eligible
        && mem_op[d_index] == "r";
    lsu_l1d.rmisaligned = 0;
    lsu_l1d.rcheck_valid = 0;
    lsu_l1d.rcheck_offset = '0;
    lsu_l1d.rcheck_size_m1 = '0;
    lsu_l1d.rorig_size_m1 = '0;
    lsu_l1d.atomic_lock = 0;
    lsu_l1d.ordered = 0;
    lsu_l1d.replay_allowed = 0;
    lsu_l1d.raddr_b = '0;
    lsu_l1d.ralu_b = '0;
    lsu_l1d.rvalid_b = 0;
    lsu_l1d.waddr = d_index < mem_limit ? mem_addr[d_index] : '0;
    lsu_l1d.wpbmt = 0;
    lsu_l1d.walu = d_index < mem_limit ? 8'((1 << mem_size[d_index]) - 1) : '0;
    lsu_l1d.wzero = 0;
    lsu_l1d.wvalid = !reset && d_index < mem_limit && d_eligible
        && mem_op[d_index] == "w";
    lsu_l1d.wdata = d_index < mem_limit ? mem_data[d_index] : '0;

    exu_l1d.mmu_en = 0;
    exu_l1d.vaddr = '0;
    exu_l1d.walu = '0;
    exu_l1d.cmo_mgmt = 0;
    exu_l1d.valid = 0;
    exu_l1d.misaligned = 0;
    exu_l1d.reservation_clear = 0;
  end

  `include "tb_core_bcast_defaults.svh"

  initial begin : run
    string inst_path, mem_path;
    int fd, status, cycles, max_cycles, max_insts, max_mem, next_i, next_d;
    int source_seq, event_seq, cutoff_seq, dependency_wait;
    int inst_skipped, mem_skipped;
    int read_count, write_count, read_bytes, write_bytes;
    int i_stall, d_stall, axi_ar, axi_aw, axi_r, axi_w, axi_b, axi_read_bytes, axi_write_bytes;
    int axi_i_ar, axi_d_ar, axi_i_r, axi_d_r, axi_i_read_bytes, axi_d_read_bytes;
    logic [XLEN-1:0] pc_value, npc_value, addr_value, data_value;
    logic [31:0] inst_value;
    byte op_value;
    int size_value;
    if (!$value$plusargs("TRACE=%s", inst_path)) $fatal(1, "+TRACE required");
    if (!$value$plusargs("MEM_TRACE=%s", mem_path)) $fatal(1, "+MEM_TRACE required");
    if (!$value$plusargs("MAX_CYCLES=%d", max_cycles)) max_cycles = 300000;
    if (!$value$plusargs("MAX_INSTS=%d", max_insts)) max_insts = 20000;
    if (!$value$plusargs("MAX_MEM=%d", max_mem)) max_mem = 10000;
    independent = $test$plusargs("INDEPENDENT");
    fd = $fopen(inst_path, "r");
    if (!fd) $fatal(1, "cannot open %s", inst_path);
    inst_count = 0;
    inst_skipped = 0;
    source_seq = 0;
    while (!$feof(
        fd
    ) && inst_count < MaxTrace) begin
      status = $fscanf(fd, "%h %h %h\n", pc_value, inst_value, npc_value);
      if (status == 3) begin
        if (pc_value >= XLEN'('h80000000) && pc_value < XLEN'('h90000000)) begin
          inst_pc[inst_count] = pc_value;
          inst_seq[inst_count] = source_seq;
          inst_count++;
        end else inst_skipped++;
        source_seq++;
      end
    end
    $fclose(fd);
    fd = $fopen(mem_path, "r");
    if (!fd) $fatal(1, "cannot open %s", mem_path);
    mem_count = 0;
    mem_skipped = 0;
    while (!$feof(
        fd
    ) && mem_count < MaxTrace) begin
      status = $fscanf(
          fd,
          "%d %h %c %h %d %h\n",
          event_seq,
          pc_value,
          op_value,
          addr_value,
          size_value,
          data_value
      );
      if (status == 6 && addr_value >= XLEN'('h80000000)
          && addr_value < XLEN'('h90000000)
          && (size_value == 1 || size_value == 2 || size_value == 4 || size_value == 8)
          && (addr_value & XLEN'(size_value-1)) == 0) begin
        mem_op[mem_count] = op_value;
        mem_addr[mem_count] = addr_value;
        mem_size[mem_count] = size_value;
        mem_data[mem_count] = data_value;
        mem_seq[mem_count] = event_seq;
        mem_count++;
      end else if (status == 6) mem_skipped++;
    end
    $fclose(fd);
    if (inst_count < 100 || mem_count < 100) $fatal(1, "trace too short");
    inst_limit = inst_count < max_insts ? inst_count : max_insts;
    mem_limit = 0;
    cutoff_seq = -1;
    if (inst_limit > 0) cutoff_seq = inst_seq[inst_limit-1];
    while (mem_limit < mem_count && mem_limit < max_mem
           && (independent || mem_seq[mem_limit] <= cutoff_seq))
    mem_limit++;

    init_cmu_bcast_defaults();
    init_csr_bcast_defaults(2'b11, '0, 1'b1);
    pmp_update.addr_we = 0;
    pmp_update.addr_idx = '0;
    pmp_update.raw_addr = '0;
    pmp_update.napot_mask = '0;
    pmp_update.cfg_we = '0;
    pmp_update.cfg_r = '0;
    pmp_update.cfg_w = '0;
    pmp_update.cfg_x = '0;
    pmp_update.cfg_l = '0;
    pmp_update.mode_off = '0;
    pmp_update.mode_tor = '0;
    pmp_update.mode_na4 = '0;
    pmp_update.mode_napot = '0;
    i_index = 0;
    d_index = 0;
    cycles = 0;
    read_count = 0;
    write_count = 0;
    read_bytes = 0;
    write_bytes = 0;
    i_stall = 0;
    d_stall = 0;
    dependency_wait = 0;
    axi_ar = 0;
    axi_aw = 0;
    axi_r = 0;
    axi_w = 0;
    axi_b = 0;
    axi_read_bytes = 0;
    axi_write_bytes = 0;
    axi_i_ar = 0;
    axi_d_ar = 0;
    axi_i_r = 0;
    axi_d_r = 0;
    axi_i_read_bytes = 0;
    axi_d_read_bytes = 0;
    repeat (5) @(negedge clock);
    reset = 0;
    while ((i_index < inst_limit || d_index < mem_limit) && cycles < max_cycles) begin
      @(posedge clock);
      next_i = i_index;
      next_d = d_index;
      if (i_index < inst_limit) begin
        if (ifu_l1i.valid) next_i++;
        else i_stall++;
      end
      if (d_index < mem_limit) begin
        if (lsu_l1d.rvalid && lsu_l1d.rready) begin
          logic [63:0] mask, actual;
          mask = mem_size[d_index] >= 8 ? ~64'b0
              : (64'b1 << (8*mem_size[d_index])) - 1;
          actual = (64'(lsu_l1d.rdata)
              >> (8*(mem_addr[d_index] % XLEN'(XLEN/8)))) & mask;
          if (lsu_l1d.trap || actual != (64'(mem_data[d_index]) & mask))
            $fatal(
                1,
                "MEM read mismatch at %0d addr=%h size=%0d got=%h expected=%h trap=%b",
                d_index,
                mem_addr[d_index],
                mem_size[d_index],
                actual,
                mem_data[d_index],
                lsu_l1d.trap
            );
          read_count++;
          read_bytes += mem_size[d_index];
          next_d++;
        end else if (lsu_l1d.wvalid && lsu_l1d.wready) begin
          if (lsu_l1d.werr) $fatal(1, "committed store failed");
          write_count++;
          write_bytes += mem_size[d_index];
          next_d++;
        end else begin
          d_stall++;
          if (!d_eligible) dependency_wait++;
        end
      end
      if (axi.arvalid && axi.arready) begin
        axi_ar++;
        if (axi.arid == 1 || axi.arid == 3) axi_i_ar++;
        else axi_d_ar++;
      end
      if (axi.awvalid && axi.awready) axi_aw++;
      if (axi.rvalid && axi.rready) begin
        axi_r++;
        axi_read_bytes += XLEN / 8;
        if (axi.rid == 1 || axi.rid == 3) begin
          axi_i_r++;
          axi_i_read_bytes += XLEN / 8;
        end else begin
          axi_d_r++;
          axi_d_read_bytes += XLEN / 8;
        end
      end
      if (axi.wvalid && axi.wready) begin
        axi_w++;
        axi_write_bytes += $countones(axi.wstrb);
      end
      if (axi.bvalid && axi.bready) axi_b++;
      cycles++;
      @(negedge clock);
      i_index = next_i;
      d_index = next_d;
    end
    if (i_index < inst_limit || d_index < mem_limit)
      $fatal(1, "MEM timeout I=%0d/%0d D=%0d/%0d", i_index, inst_limit, d_index, mem_limit);
    $display(
        "PASS: MEM inst=%0d data=%0d cycles=%0d i_per_cycle=%0f d_per_cycle=%0f read=%0d write=%0d useful_read_bytes=%0d useful_write_bytes=%0d i_stall=%0d d_stall=%0d dependency_wait=%0d axi_ar=%0d axi_aw=%0d axi_r=%0d axi_w=%0d axi_b=%0d axi_read_bytes=%0d axi_write_bytes=%0d axi_bytes_per_cycle=%0f inst_skipped=%0d mem_skipped=%0d independent=%0d",
        i_index, d_index, cycles, real'(i_index) / cycles, real'(d_index) / cycles, read_count,
        write_count, read_bytes, write_bytes, i_stall, d_stall, dependency_wait, axi_ar, axi_aw,
        axi_r, axi_w, axi_b, axi_read_bytes, axi_write_bytes,
        real'(axi_read_bytes + axi_write_bytes) / cycles, inst_skipped, mem_skipped, independent);
    $display(
        "MEM traffic split: i_ar=%0d d_ar=%0d i_r=%0d d_r=%0d i_read_bytes=%0d d_read_bytes=%0d",
        axi_i_ar, axi_d_ar, axi_i_r, axi_d_r, axi_i_read_bytes, axi_d_read_bytes);
    $finish;
  end
endmodule
