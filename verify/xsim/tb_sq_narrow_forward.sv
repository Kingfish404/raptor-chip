`include "rapt.svh"
module tb_sq_narrow_forward;
  localparam int Xlen = `RAPT_XLEN;
  localparam int Bytes = Xlen / 8;
  localparam logic [Xlen-1:0] Base = Xlen'('h80001000);
  logic [1:0] head = 3;
  logic [3:0] valid = '0, stale_context = '0;
  logic [Xlen-1:0] store_addr[4], store_data[4], load_addr[3];
  logic [3:0] load_size_m1[3];
  logic [4:0] store_alu[4];
  logic store_fp64[4];
  logic alloc_fp64 = 0;
  logic [7:0] full_store_mask = Xlen == 64 ? `RAPT_SD_WSTRB : `RAPT_SW_WSTRB;
  logic mmu_enabled = 0, alloc_valid = 0;
  logic [2:0] narrow_allowed = '1;
  logic [Xlen-1:0] alloc_addr = '0;
  logic [4:0] alloc_alu = '0;
  wire [2:0] conflict, forward_valid;
  wire [Xlen-1:0] forward_data[3];
  rapt_sq_forward #(
      .Entries(4),
      .ReadPorts(3),
      .NarrowForward(1)
  ) dut (
      .*
  );
  function automatic logic [4:0] mask_for(input int bytes);
    case (bytes)
      1: return `RAPT_SB_WSTRB;
      2: return `RAPT_SH_WSTRB;
      4: return `RAPT_SW_WSTRB;
      8: return `RAPT_SD_WSTRB;
      default: return '0;
    endcase
  endfunction
  initial begin
    foreach (store_addr[i]) begin
      store_addr[i] = Base;
      store_data[i] = Xlen'('h87654321aabbccdd);
      store_alu[i] = mask_for(Bytes);
      store_fp64[i] = 0;
    end
    valid[0] = 1;
    for (int size_s = 1; size_s <= Bytes; size_s *= 2)
    for (int off_s = 0; off_s < Bytes; off_s++)
    for (int size_l = 1; size_l <= Bytes; size_l *= 2)
    for (int off_l = 0; off_l < Bytes; off_l++) begin
      automatic bit covered;
      store_addr[0] = Base + Xlen'(off_s);
      store_alu[0] = mask_for(size_s);
      foreach (load_addr[p]) begin
        load_addr[p] = Base + Xlen'(off_l);
        load_size_m1[p] = 4'(size_l - 1);
      end
      covered = off_s + size_s <= Bytes && off_l + size_l <= Bytes
                && off_l >= off_s && off_l + size_l <= off_s + size_s;
      #1;
      if (forward_valid !== {3{covered}})
        $fatal(
            1,
            "byte coverage size_s=%0d off_s=%0d size_l=%0d off_l=%0d",
            size_s,
            off_s,
            size_l,
            off_l
        );
      if (covered && forward_data[0] !== (store_data[0] << (off_s * 8)))
        $fatal(1, "store byte alignment");
    end
    // Ring order 3 -> 0: a younger incomplete cover must block an older full store.
    valid = 4'b1001;
    store_addr[3] = Base;
    store_alu[3] = mask_for(Bytes);
    store_addr[0] = Base + 1;
    store_alu[0] = `RAPT_SB_WSTRB;
    foreach (load_addr[p]) begin
      load_addr[p] = Base;
      load_size_m1[p] = 3;
    end
    #1;
    if (conflict !== 3'b111 || forward_valid !== 0) $fatal(1, "youngest partial alias");
    // The upper half of RV64 SW -> LW is shifted into the shared word correctly.
    valid = 1;
    store_addr[0] = Base + Xlen'(Bytes-2);
    store_alu[0] = `RAPT_SH_WSTRB;
    foreach (load_addr[p]) begin
      load_addr[p] = store_addr[0];
      load_size_m1[p] = 1;
    end
    #1;
    if (forward_valid !== 3'b111) $fatal(1, "upper lanes missing");
    stale_context[0] = 1;
    #1;
    if (forward_valid !== 0) $fatal(1, "stale context forwarded");
    stale_context = 0;
    mmu_enabled = 1;
    #1;
    if (forward_valid !== 0) $fatal(1, "new partial VA forwarding under MMU");
    mmu_enabled = 0;
    alloc_valid = 1;
    alloc_addr = store_addr[0];
    alloc_alu = `RAPT_SH_WSTRB;
    #1;
    if (forward_valid !== 0) $fatal(1, "same-edge allocation alias");
    alloc_valid = 0;
    store_alu[0] = `RAPT_CBO_ZERO_WALU;
    #1;
    if (forward_valid !== 0) $fatal(1, "CBO forwarding");
    $display("PASS: SQ narrow byte coverage, youngest alias, lane shifts and context XLEN=%0d",
             Xlen);
    $finish;
  end
endmodule
