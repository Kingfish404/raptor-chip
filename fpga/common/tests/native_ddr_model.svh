// Independent byte-addressed AXI memory oracle. Delays each channel separately;
// it models the converter/MIG contract, not vendor PHY calibration or timing.
module native_ddr_model #(
    parameter int XLEN = `RAPT_XLEN,
    parameter int MemBytes = 131072,
    parameter bit InjectErrors = 0,
    parameter int WriteOutstanding = 8,
    parameter int WriteLatency = 29
) (
    input logic clk,
    input logic reset,
    axi4_if.slave axi
);
  localparam int Bytes = XLEN / 8;
  byte unsigned mem [MemBytes];
  logic [31:0] rng = 32'h1a5a_cafe;
  logic writing, reading;
  logic [XLEN-1:0] wa, ra;
  logic [7:0] wleft, rleft;
  logic [2:0] wsize, rsize;
  logic [1:0] wburst, rburst;
  logic [3:0] rid;
  int write_head, write_tail, write_slot, write_count, write_beat;
  int write_delay[WriteOutstanding], write_length[WriteOutstanding];
  logic write_complete[WriteOutstanding];
  logic [3:0] write_id[WriteOutstanding];
  logic [1:0] write_resp[WriteOutstanding];
  logic [XLEN-1:0] write_addr[WriteOutstanding][256];
  logic [XLEN-1:0] write_data[WriteOutstanding][256];
  logic [Bytes-1:0] write_strb[WriteOutstanding][256];
  wire write_push = axi.awvalid && axi.awready;
  wire write_pop = axi.bvalid && axi.bready;
  assign axi.awready = !reset && !writing && write_count < WriteOutstanding && rng[0];
  assign axi.wready = !reset && writing && rng[3];
  assign axi.arready = !reset && !reading && !axi.rvalid && rng[5];
  always_ff @(posedge clk) begin
    rng <= {rng[30:0], rng[31] ^ rng[21] ^ rng[1] ^ rng[0]};
    if (reset) begin
      writing <= 0;
      reading <= 0;
      write_head <= 0;
      write_tail <= 0;
      write_slot <= 0;
      write_count <= 0;
      write_beat <= 0;
      for (int i = 0; i < WriteOutstanding; i++) begin
        write_complete[i] <= 0;
        write_delay[i] <= 0;
      end
      axi.bvalid <= 0;
      axi.rvalid <= 0;
      axi.bid <= 0;
      axi.bresp <= 0;
      axi.rid <= 0;
      axi.rdata <= 0;
      axi.rresp <= 0;
      axi.rlast <= 0;
    end else begin
      case ({
        write_push, write_pop
      })
        2'b10: write_count <= write_count + 1;
        2'b01: write_count <= write_count - 1;
        default: ;
      endcase
      for (int i = 0; i < WriteOutstanding; i++)
      if (write_complete[i] && write_delay[i] > 0) write_delay[i] <= write_delay[i] - 1;
      if (write_push) begin
        writing <= 1;
        wa <= axi.awaddr;
        wleft <= axi.awlen;
        wsize <= axi.awsize;
        wburst <= axi.awburst;
        write_slot <= write_tail;
        write_id[write_tail] <= axi.awid;
        write_tail <= (write_tail + 1) % WriteOutstanding;
        write_beat <= 0;
      end
      if (axi.wvalid && axi.wready) begin
        if (axi.wlast != (wleft == 0)) $fatal(1, "DDR model WLAST mismatch");
        write_addr[write_slot][write_beat] <= wa;
        write_data[write_slot][write_beat] <= axi.wdata;
        write_strb[write_slot][write_beat] <= axi.wstrb;
        write_beat <= write_beat + 1;
        if (wleft == 0) begin
          writing <= 0;
          write_resp[write_slot] <= wa >= XLEN'(MemBytes) ? 2'b11 :
              (InjectErrors && wa == 'h10000 ? 2'b10 : 0);
          write_length[write_slot] <= write_beat;
          write_complete[write_slot] <= 1;
          write_delay[write_slot] <= WriteLatency;
        end else begin
          wleft <= wleft - 1'b1;
          if (wburst == 1) wa <= ((wa >> wsize) + 1'b1) << wsize;
        end
      end
      // Publish memory only when the response becomes available. This catches
      // a decoder that lets an overlapping read bypass an unfinished write.
      if (!axi.bvalid && write_count != 0 && write_complete[write_head] &&
          write_delay[write_head] == 0) begin
        for (int beat = 0; beat < 256; beat++) begin
          if (beat <= write_length[write_head] && write_addr[write_head][beat] < XLEN'(MemBytes)) begin
            for (int lane = 0; lane < Bytes; lane++)
            if (write_strb[write_head][beat][lane])
              mem[(int'(write_addr[write_head][beat])&~(Bytes-1))+lane] <=
                  write_data[write_head][beat][lane*8+:8];
          end
        end
        axi.bid <= write_id[write_head];
        axi.bresp <= write_resp[write_head];
        axi.bvalid <= 1;
      end
      if (write_pop) begin
        axi.bvalid <= 0;
        write_complete[write_head] <= 0;
        write_head <= (write_head + 1) % WriteOutstanding;
      end
      if (axi.arvalid && axi.arready) begin
        reading <= 1;
        ra <= axi.araddr;
        rleft <= axi.arlen;
        rsize <= axi.arsize;
        rburst <= axi.arburst;
        rid <= axi.arid;
      end
      if (reading && !axi.rvalid && rng[9]) begin
        axi.rid <= rid;
        axi.rlast <= rleft == 0;
        axi.rresp <= ra >= XLEN'(MemBytes) ? 2'b11 : (InjectErrors && ra == 'h10000 ? 2'b10 : 0);
        for (int i = 0; i < Bytes; i++)
        axi.rdata[i*8+:8] <= ra < XLEN'(MemBytes) ? mem[(int'(ra)&~(Bytes-1))+i] : 0;
        axi.rvalid <= 1;
      end
      if (axi.rvalid && axi.rready) begin
        axi.rvalid <= 0;
        if (rleft == 0) reading <= 0;
        else begin
          rleft <= rleft - 1'b1;
          if (rburst == 1) ra <= ((ra >> rsize) + 1'b1) << rsize;
        end
      end
    end
  end
endmodule
