// The bytewise reference intentionally makes no assumption about alignment
// of PMA regions. A future map with finer boundaries must still pass this.
module formal_pma_span (
    input logic [rapt_pkg::XLENPkg-1:0] address,
    input logic [3:0] size_m1,
    input logic store_access,
    output logic mismatch
);
  localparam int X = rapt_pkg::XLENPkg;
  logic [3:0] expected;
  logic [X:0] byte_addr;
  always_comb begin
    expected = rapt_pkg::addr_upper_valid(address) && size_m1 <= 7 ? 4'd8 : 4'd0;
    for (int i = 0; i < 8; i++) begin
      byte_addr = {1'b0, rapt_pkg::canonical_addr(address)} + (X + 1)'(i);
      if (expected == 8 && i <= int'(size_m1)
          && (byte_addr[X]
              || !(store_access ? rapt_pkg::addr_writable(
              byte_addr[X-1:0]
          ) : rapt_pkg::addr_mapped(
              byte_addr[X-1:0]
          ))))
        expected = 4'(i);
    end
  end
  assign mismatch = expected != rapt_pkg::addr_data_span_fault_offset(
      address, size_m1, store_access
  );
endmodule
