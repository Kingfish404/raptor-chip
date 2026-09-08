// Independent platform-region specification for supported-access PMAs.
// This proves address capability logic, not bus atomicity/coherence/progress.
module formal_pma_capabilities (
    input logic [rapt_pkg::XLENPkg-1:0] address,
    input logic [3:0] size_m1,
    output logic mismatch
);
  localparam int X = rapt_pkg::XLENPkg;
  // Platform contract: SRAM 8 KiB, PMEM 256 MiB, SDRAM 32 MiB;
  // MROM 64 KiB and flash 256 MiB are read-only executable storage.
  localparam logic [31:0] Base[5] = '{
      32'h0f000000,
      32'h80000000,
      32'ha0000000,
      32'h20000000,
      32'h30000000
  };
  localparam logic [32:0] Limit[5] = '{
      33'h00f002000,
      33'h090000000,
      33'h0a2000000,
      33'h020010000,
      33'h040000000
  };
  logic valid_alias, in_storage, span_storage, span_ram, span_rom, zero_ram;
  logic [31:0] physical;
  logic [32:0] end_byte, zero_end;
  logic expected_fetch, expected_ptw, expected_atomic;
  assign physical = address[31:0];
  if (X == 64) begin : g_rv64
    assign valid_alias = address[63:32] == 32'b0 || &address[63:32];
  end else begin : g_rv32
    assign valid_alias = 1'b1;
  end
  assign end_byte = {1'b0,physical} + 33'(size_m1);
  assign zero_end = {1'b0,physical[31:6],6'b111111};
  always_comb begin
    in_storage=0;
    span_storage=0;
    span_ram=0;
    span_rom=0;
    zero_ram=0;
    for (int region = 0; region < 5; region++) begin
      in_storage |= {1'b0, physical} >= {1'b0, Base[region]} && {1'b0, physical} < Limit[region];
      span_storage |= {1'b0, physical} >= {1'b0, Base[region]} && end_byte < Limit[region];
      if (region >= 3)
        span_rom |= {1'b0, physical} >= {1'b0, Base[region]} && end_byte < Limit[region];
      if (region < 3) begin
        span_ram |= {1'b0, physical} >= {1'b0, Base[region]} && end_byte < Limit[region];
        zero_ram |= {1'b0,physical[31:6],6'b0} >= {1'b0,Base[region]}
            && zero_end < Limit[region];
      end
    end
  end
  assign expected_fetch = valid_alias && span_storage && (size_m1==1 || size_m1==3);
  assign expected_ptw = valid_alias && span_storage
      && ((size_m1==3 && physical[1:0]==0) || (size_m1==7 && physical[2:0]==0));
  assign expected_atomic = valid_alias && span_ram
      && ((size_m1==3 && physical[1:0]==0) || (X==64 && size_m1==7 && physical[2:0]==0));
  assign mismatch = (rapt_pkg::addr_cacheable(address) != (valid_alias && in_storage))
      || (rapt_pkg::addr_executable(address,size_m1) != expected_fetch)
      || (rapt_pkg::addr_ptw_readable(address,size_m1) != expected_ptw)
      || (rapt_pkg::addr_atomic_capable(address,size_m1) != expected_atomic)
      || (rapt_pkg::addr_zero_capable(address) != (valid_alias && zero_ram))
      // Every byte of an ordinary supported RAM scalar span is readable and
      // writable. Device policy and partial-fault offset are separate checks.
      || (valid_alias && span_ram && size_m1<=7
          && (!rapt_pkg::addr_data_span_capable(address,size_m1,0)
              || !rapt_pkg::addr_data_span_capable(address,size_m1,1)))
      || (valid_alias && span_rom && size_m1<=7
          && (!rapt_pkg::addr_data_span_capable(address,size_m1,0)
              || rapt_pkg::addr_data_span_capable(address,size_m1,1)));
endmodule
