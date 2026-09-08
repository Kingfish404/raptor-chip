// Pure address-classification projection for pre/post combinational equivalence.
module formal_addr_attributes (
    input logic [rapt_pkg::XLENPkg-1:0] addr,
    input logic [1:0] pbmt,
    output logic [6:0] attributes
);
  assign attributes = {
    rapt_pkg::addr_cacheable(addr),
    rapt_pkg::addr_mapped(addr),
    rapt_pkg::addr_mmio(addr),
    rapt_pkg::axi_cache_attr(addr, pbmt)
  };
endmodule
