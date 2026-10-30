// Select a harness explicitly so unused hierarchical monitors are not elaborated.
`ifdef RAPT_FORMAL_RVFI_EFFECTS
// ---- formal_rvfi_effects ----
`include "rapt.svh"
`include "rapt_if.svh"

// Retirement metadata contract. Instruction execution, memory contents and
// the producer's retirement-prefix contract are separate obligations.
module formal_rvfi_effects #(
    parameter int XLEN = 32,
    parameter int Width = 2
) (
    input logic clock,
    reset,
    input logic [Width-1:0] valid,
    trap,
    input logic [Width*32-1:0] instruction,
    input logic [Width*5-1:0] destination,
    input logic [Width*XLEN-1:0] result,
    memory_result,
    address,
    payload,
    input logic [Width-1:0] memory_write,
    input logic [1:0] privilege,
    output logic correct,
    output logic [8:0] activated
);
  localparam int Bytes = XLEN / 8;
  rou_cmu_if #(
      .Width(Width),
      .XLEN(XLEN)
  ) rou_cmu ();
  csr_bcast_if #(.XLEN(XLEN)) csr_bcast ();
  logic [XLEN-1:0] rf[32], rd_wdata[Width];
  wire [Width-1:0] observed_valid, observed_trap;
  wire [Width*64-1:0] observed_order;
  wire [Width*5-1:0] observed_rd;
  wire [Width*XLEN-1:0] observed_result, observed_address;
  wire [Width*Bytes-1:0] observed_read, observed_write;
  wire [Width*XLEN-1:0] observed_read_data, observed_write_data;
  wire [Width*32-1:0] observed_instruction;
  wire [Width*2-1:0] observed_mode, observed_ixl;

  for (genvar r = 0; r < 32; r++) assign rf[r] = '0;
  assign csr_bcast.priv = privilege;
  for (genvar c = 0; c < Width; c++) begin : g_slot
    always_comb begin
      rou_cmu.slot[c] = '0;
      rou_cmu.slot[c].valid = valid[c];
      rou_cmu.slot[c].rvfi_trap = trap[c];
      rou_cmu.slot[c].inst = instruction[c*32+:32];
      rou_cmu.slot[c].rvfi_inst = instruction[c*32+:32];
      rou_cmu.slot[c].rd = destination[c*5+:5];
      rou_cmu.slot[c].rvfi_mem_addr = address[c*XLEN+:XLEN];
      rou_cmu.slot[c].rvfi_mem_wdata = payload[c*XLEN+:XLEN];
      rou_cmu.slot[c].rvfi_mem_result = memory_result[c*XLEN+:XLEN];
      rou_cmu.slot[c].rvfi_mem_wen = memory_write[c];
      rd_wdata[c] = result[c*XLEN+:XLEN];
    end
    if (c > 0) always_comb assume (!valid[c] || valid[c-1]);
  end

  rapt_rvfi #(
      .NRET(Width),
      .XLEN(XLEN),
      .RNUM(32)
  ) dut (
      .clock,
      .reset,
      .rou_cmu,
      .csr_bcast,
      .rf,
      .rd_wdata,
      .rvfi_valid(observed_valid),
      .rvfi_trap(observed_trap),
      .rvfi_order(observed_order),
      .rvfi_rd_addr(observed_rd),
      .rvfi_rd_wdata(observed_result),
      .rvfi_insn(observed_instruction),
      .rvfi_mode(observed_mode),
      .rvfi_ixl(observed_ixl),
      .rvfi_mem_addr(observed_address),
      .rvfi_mem_rmask(observed_read),
      .rvfi_mem_wmask(observed_write),
      .rvfi_mem_rdata(observed_read_data),
      .rvfi_mem_wdata(observed_write_data),
      .rvfi_halt(),
      .rvfi_intr(),
      .rvfi_rs1_addr(),
      .rvfi_rs2_addr(),
      .rvfi_rs1_rdata(),
      .rvfi_rs2_rdata(),
      .rvfi_pc_rdata(),
      .rvfi_pc_wdata()
  );

  logic [Width-1:0] field_correct;
  wire [8:0] events[Width];
  for (genvar c = 0; c < Width; c++) begin : g_check
    wire [31:0] insn = instruction[c*32+:32];
    wire [XLEN-1:0] value = result[c*XLEN+:XLEN];
    wire [4:0] rd = destination[c*5+:5];
    logic [Bytes-1:0] byte_mask;
    wire load = insn[6:0] == 7'h03;
    wire store = insn[6:0] == 7'h23;
    wire atomic = insn[6:0] == 7'h2f;
    wire lr = atomic && insn[31:27] == 5'b00010;
    wire sc = atomic && insn[31:27] == 5'b00011;
    wire amo = atomic && !lr && !sc;
    wire reading = !trap[c] && (load || lr || amo);
    wire writing = !trap[c] && memory_write[c] && (store || sc || amo);
    always_comb begin
      case (insn[13:12])
        0: byte_mask = Bytes'(1);
        1: byte_mask = Bytes'(3);
        2: byte_mask = Bytes'(15);
        3: byte_mask = Bytes'(255);
      endcase
      field_correct[c] = observed_valid[c] == valid[c]
          && observed_order[c*64+:64] == observed_order[0+:64] + 64'(c);
      if (valid[c]) begin
        field_correct[c] &= observed_trap[c] == trap[c]
            && observed_rd[c*5+:5] == (trap[c] ? 5'b0 : rd)
            && observed_result[c*XLEN+:XLEN] == (trap[c] || rd == 0 ? '0 : value)
            && observed_instruction[c*32+:32] == insn
            && observed_mode[c*2+:2] == privilege
            && observed_ixl[c*2+:2] == (XLEN == 64 ? 2'd2 : 2'd1)
            && observed_read[c*Bytes+:Bytes] == (reading ? byte_mask : '0)
            && observed_write[c*Bytes+:Bytes] == (writing ? byte_mask : '0);
        if (reading || writing)
          field_correct[c] &= observed_address[c*XLEN+:XLEN] == address[c*XLEN+:XLEN];
        if (reading)
          field_correct[c] &= observed_read_data[c*XLEN+:XLEN] == memory_result[c*XLEN+:XLEN];
        if (writing) field_correct[c] &= observed_write_data[c*XLEN+:XLEN] == payload[c*XLEN+:XLEN];
      end
    end
    assign events[c] = {
      valid[c] && reading && rd == 0 && value == 0 && memory_result[c*XLEN+:XLEN] != 0,
      valid[c] && !trap[c] && !load && !store && !atomic && rd != 0,
      valid[c] && !trap[c] && !load && !store && !atomic && rd == 0 && value != 0,
      valid[c] && !trap[c] && amo,
      valid[c] && !trap[c] && lr,
      valid[c] && !trap[c] && sc && memory_write[c] && memory_result[c*XLEN+:XLEN] == 0,
      valid[c] && !trap[c] && sc && !memory_write[c] && rd == 0 && value == 0
          && memory_result[c*XLEN+:XLEN] != 0,
      valid[c] && trap[c] && load && rd != 0 && value != 0,
      valid[c] && trap[c] && store
    };
  end
  // Covers exercise the last channel, so a wide configuration cannot satisfy
  // every activation by retiring only on channel zero.
  assign activated = events[Width-1];

  logic past_valid = 0;
  logic history_correct;
  logic previous_reset;
  logic [63:0] previous_order;
  logic [Width-1:0] previous_valid;
  always_ff @(posedge clock) begin
    past_valid <= 1;
    previous_reset <= reset;
    previous_order <= observed_order[0+:64];
    previous_valid <= valid;
  end
  always_comb begin
    history_correct = 1;
    if (past_valid) begin
      if (previous_reset) history_correct = observed_order[0+:64] == 0;
      else
        history_correct = observed_order[0+:64] == previous_order + 64'($countones(previous_valid));
    end
    correct = (&field_correct) && history_correct;
  end
endmodule
`endif

`ifdef RAPT_FORMAL_RVFI_HINTS
// ---- formal_rvfi_hints ----
`include "rapt.svh"
`include "rapt_if.svh"

module formal_rvfi_hints #(
    parameter int XLEN = 32,
    parameter int Width = 2,
    parameter int Channel = 1,
    parameter int PassThrough = 0
) (
    input logic clock,
    reset,
    trap,
    input logic [1:0] kind,
    input logic [4:0] register_index,
    physical_rd,
    input logic [31:0] expanded,
    input logic [XLEN-1:0] physical_result,
    input logic [32*XLEN-1:0] registers,
    input logic [Width-1:0] older_valid,
    input logic [Width*5-1:0] older_rd,
    input logic [Width*XLEN-1:0] older_result,
    output logic correct
);
  rou_cmu_if #(
      .Width(Width),
      .XLEN(XLEN)
  ) rou_cmu ();
  csr_bcast_if #(.XLEN(XLEN)) csr_bcast ();
  logic [XLEN-1:0] rf[32], rd_wdata[Width];
  logic [Width*5-1:0] observed_rs1, observed_rs2, observed_rd;
  logic [Width*XLEN-1:0] observed_source1, observed_source2, observed_result;
  logic [Width*32-1:0] observed_insn;
  for (genvar r = 0; r < 32; r++) assign rf[r] = registers[r*XLEN+:XLEN];

  rapt_rvfi #(
      .NRET(Width),
      .XLEN(XLEN),
      .RNUM(32)
  ) dut (
      .clock,
      .reset,
      .rou_cmu,
      .csr_bcast,
      .rf,
      .rd_wdata,
      .rvfi_rs1_addr(observed_rs1),
      .rvfi_rs2_addr(observed_rs2),
      .rvfi_rd_addr(observed_rd),
      .rvfi_rs1_rdata(observed_source1),
      .rvfi_rs2_rdata(observed_source2),
      .rvfi_rd_wdata(observed_result),
      .rvfi_insn(observed_insn),
      .rvfi_valid(),
      .rvfi_order(),
      .rvfi_trap(),
      .rvfi_halt(),
      .rvfi_intr(),
      .rvfi_mode(),
      .rvfi_ixl(),
      .rvfi_pc_rdata(),
      .rvfi_pc_wdata(),
      .rvfi_mem_addr(),
      .rvfi_mem_rmask(),
      .rvfi_mem_wmask(),
      .rvfi_mem_rdata(),
      .rvfi_mem_wdata()
  );

  logic [15:0] raw_hint;
  logic [4:0] expected_rs1, expected_rs2, expected_rd;
  logic [XLEN-1:0] expected_source1, expected_source2, expected_result;
  always_comb begin
    case (kind)
      0: raw_hint = {4'b1001, 5'b00000, register_index, 2'b10};
      1: raw_hint = {4'b1000, 5'b00000, register_index, 2'b10};
      2: raw_hint = {4'b0000, register_index, 5'b00000, 2'b01};
      3: raw_hint = 16'h0001;
    endcase
    if (kind != 3) assume (register_index != 0);
    if (PassThrough == 1) assume (expanded[1:0] == 2'b11);
    if (PassThrough == 2) assume (expanded != 32'h0000_0013 || physical_rd != 0);

    csr_bcast.priv = 2'b11;
    for (int s = 0; s < Width; s++) begin
      rou_cmu.slot[s] = '0;
      rd_wdata[s] = '0;
      if (s < Channel) begin
        rou_cmu.slot[s].valid = older_valid[s];
        rou_cmu.slot[s].rd = older_rd[s*5+:5];
        rd_wdata[s] = older_rd[s*5+:5] != 0 ? older_result[s*XLEN+:XLEN] : '0;
      end
    end
    rou_cmu.slot[Channel].valid = 1;
    rou_cmu.slot[Channel].c = PassThrough != 1;
    rou_cmu.slot[Channel].rvfi_trap = trap;
    rou_cmu.slot[Channel].inst = PassThrough != 0 ? expanded : 32'h0000_0013;
    rou_cmu.slot[Channel].rd = PassThrough != 0 ? physical_rd : 5'b0;
    rou_cmu.slot[Channel].rvfi_inst = PassThrough == 1 ? expanded : {16'b0, raw_hint};
    rd_wdata[Channel] = PassThrough != 0 && physical_rd != 0 ? physical_result : '0;

    if (PassThrough == 0) begin
      expected_rs1 = kind == 2 ? register_index : 5'b0;
      expected_rs2 = kind < 2 ? register_index : 5'b0;
      expected_rd = kind == 2 && !trap ? register_index : 5'b0;
    end else begin
      expected_rs1 = expanded[19:15];
      expected_rs2 = expanded[24:20];
      expected_rd = trap ? 5'b0 : physical_rd;
    end
    expected_source1 = expected_rs1 != 0 ? rf[expected_rs1] : '0;
    expected_source2 = expected_rs2 != 0 ? rf[expected_rs2] : '0;
    for (int older = 0; older < Channel; older++) begin
      if (older_valid[older] && older_rd[older*5+:5] != 0) begin
        if (older_rd[older*5+:5] == expected_rs1) expected_source1 = older_result[older*XLEN+:XLEN];
        if (older_rd[older*5+:5] == expected_rs2) expected_source2 = older_result[older*XLEN+:XLEN];
      end
    end
    expected_result = trap || expected_rd == 0 ? '0 : PassThrough != 0 ? rd_wdata[Channel]
        : kind == 2 && !trap ? expected_source1 : '0;
    correct = observed_rs1[Channel*5+:5] == expected_rs1
        && observed_rs2[Channel*5+:5] == expected_rs2
        && observed_rd[Channel*5+:5] == expected_rd
        && observed_source1[Channel*XLEN+:XLEN] == expected_source1
        && observed_source2[Channel*XLEN+:XLEN] == expected_source2
        && observed_result[Channel*XLEN+:XLEN] == expected_result
        && observed_insn[Channel*32+:32] == rou_cmu.slot[Channel].rvfi_inst;
  end
endmodule
`endif

`ifdef RAPT_FORMAL_RVFI_PLATFORM
// ---- formal_rvfi_platform_pma ----
// Qualify the independent RVFI reference against the selected RTL policy.
// This is an address-policy proof, not translation or integrated fault delivery.
module formal_rvfi_platform_pma (
    input logic [rapt_pkg::XLENPkg-1:0] address,
    input logic [1:0] log2len,
    output logic correct,
    output logic [5:0] activated
);
  localparam int X = rapt_pkg::XLENPkg;
  wire readable, writable, executable;
  wire [3:0] size_m1 = (4'd1 << log2len) - 4'd1;
  wire aligned = (address & X'(size_m1)) == 0;
  wire data_ok = rapt_pkg::addr_device_width_capable(address, size_m1)
      && (!rapt_pkg::addr_device(address) || aligned);
  // Exercise the same macro-selected default width as the upstream checker.
  rvfi_platform_pma reference_dut (
      .address,
      .log2len,
      .R(readable),
      .W(writable),
      .X(executable)
  );
  assign correct = readable == (data_ok && rapt_pkg::addr_data_span_capable(
      address, size_m1, 1'b0
  )) && writable == (data_ok && rapt_pkg::addr_data_span_capable(
      address, size_m1, 1'b1
  )) && executable == rapt_pkg::addr_executable(address, size_m1);
  assign activated = {
    !rapt_pkg::addr_upper_valid(address) && !readable && !writable && !executable,
    address == X'(32'h0c000000) && log2len == 2 && readable && writable && !executable,
    address == X'(32'h0c000000) && log2len == 0 && !readable && !writable,
    address == X'(32'h20000000) && log2len == 2 && readable && !writable && executable,
    address == X'(32'ha1fffff9) && log2len == 2 && readable && writable,
    address == X'(32'ha1fffffd) && log2len == 2 && !readable && !writable
  };
endmodule
`endif

`ifdef RAPT_FORMAL_RVFI_PLATFORM
// ---- platform_pma ----
// Independent physical-access policy for the default/formal 32-bit platform
// map: 256 MiB PMEM, 32 MiB legacy SDRAM, 8 KiB SRAM and the device windows.
// This is a Bare physical-address model. Translated virtual addresses require
// a separate translation/permission model, even when XLEN is 64.
module rvfi_platform_pma #(
`ifdef RISCV_FORMAL_XLEN
    parameter integer XLEN = `RISCV_FORMAL_XLEN
`else
    parameter integer XLEN = 32
`endif
) (
    input [XLEN-1:0] address,
    input [1:0] log2len,
    output R,
    W,
    X
);
  // Attribute bits are readable, writable, executable. Decode each byte
  // independently so a transfer cannot borrow permission across a map hole.
  function automatic [2:0] attributes;
    input [32:0] byte_address;
    begin
      attributes = 3'b000;
      if ((byte_address >= 33'h00f000000 && byte_address < 33'h00f002000)
          || (byte_address >= 33'h080000000 && byte_address < 33'h090000000)
          || (byte_address >= 33'h0a0000000 && byte_address < 33'h0a2000000))
        attributes = 3'b111;
      if ((byte_address >= 33'h020000000 && byte_address < 33'h020010000)
          || (byte_address >= 33'h030000000 && byte_address < 33'h040000000))
        attributes = 3'b101;
      if ((byte_address >= 33'h000100000 && byte_address < 33'h000101000)
          || (byte_address >= 33'h002000000 && byte_address < 33'h0020c0000)
          || (byte_address >= 33'h00c000000 && byte_address < 33'h00d000000)
          || (byte_address >= 33'h010000000 && byte_address < 33'h010012000)
          || (byte_address >= 33'h011000000 && byte_address < 33'h012000000)
          || (byte_address >= 33'h018000000 && byte_address < 33'h019000000)
          || (byte_address >= 33'h021000000 && byte_address < 33'h021200000))
        attributes = 3'b110;
    end
  endfunction

  wire [32:0] first_byte = {1'b0, address[31:0]};
  wire [2:0] first_attributes = attributes(first_byte);
  wire valid_upper;
  if (XLEN == 64) begin : g_rv64
    assign valid_upper = address[63:32] == 32'b0 || &address[63:32];
  end else begin : g_rv32
    assign valid_upper = 1'b1;
  end
  wire aligned = (4'(address[2:0]) & ((4'd1 << log2len) - 4'd1)) == 0;
  wire plic = first_byte >= 33'h00c000000 && first_byte < 33'h00d000000;
  wire device_width_ok = !plic || log2len == 2;
  wire alignment_ok = first_attributes[0] || aligned;
  reg readable, writable, executable;
  reg [2:0] byte_attributes;
  always @* begin
    readable = 1;
    writable = 1;
    executable = 1;
    byte_attributes = 0;
    for (integer offset = 0; offset < 8; offset = offset + 1) begin
      if (offset < (1 << log2len)) begin
        byte_attributes = attributes(first_byte + 33'(offset));
        readable = readable && byte_attributes[2];
        writable = writable && byte_attributes[1];
        executable = executable && byte_attributes[0];
      end
    end
  end
  assign R = valid_upper && readable && alignment_ok && device_width_ok;
  assign W = valid_upper && writable && alignment_ok && device_width_ok;
  assign X = valid_upper && executable && (log2len == 1 || log2len == 2);
endmodule
`endif
