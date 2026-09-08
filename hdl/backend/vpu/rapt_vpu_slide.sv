// Combinational slide element routing, independent of VRF geometry and ports.
// Caller validates instruction/group legality, supplies VLMAX for current SEW
// and LMUL, and sign-extends integer scalar data when scalar_select is asserted.
// Upward slides require disjoint source/destination groups. Downward slides may
// alias when the caller processes destination indices in increasing order.
module rapt_vpu_slide #(
    parameter int XLEN = 64,
    parameter int VLEN = 128,
    parameter int IndexBits = $clog2(VLEN)+1
) (
    input logic up,
    single,
    mask_active,
    input logic [IndexBits-1:0] index,
    vl,
    vlmax,
    vstart,
    input logic [XLEN-1:0] offset,
    output logic write_element,
    read_source,
    scalar_select,
    output logic [IndexBits-1:0] source_index
);
  logic [XLEN:0] distance, position;
  always_comb begin
    distance = single ? (XLEN+1)'(1) : {1'b0,offset};
    position = up ? (XLEN+1)'(index)-distance : (XLEN+1)'(index)+distance;
    write_element = mask_active && index >= vstart && index < vl;
    read_source = 0;
    scalar_select = 0;
    source_index = 0;
    if (write_element) begin
      if (single && ((up && index == 0) || (!up && index == vl - 1'b1))) scalar_select = 1;
      else if (up && (XLEN + 1)'(index) < distance) write_element = 0;
      else if (position < (XLEN + 1)'(vlmax)) begin
        read_source = 1;
        source_index = IndexBits'(position);
      end
      // An active downward destination with neither source nor scalar gets 0.
    end
  end
endmodule
