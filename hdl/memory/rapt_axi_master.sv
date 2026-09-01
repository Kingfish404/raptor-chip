`include "rapt.svh"
`include "rapt_soc_if.svh"

module rapt_axi_master #(
    parameter int XLEN = `RAPT_XLEN,
    parameter int ID_W = 4,
    parameter int MAX_READ_OUTSTANDING = 8
) (
    input logic clock,
    input logic reset,

    mem_link_if.slave mem,
    axi4_if.master axi
);
  localparam int ReadCountW = $clog2(MAX_READ_OUTSTANDING + 1);
  localparam int IdCount = 1 << ID_W;
  localparam int AddrLsbW = $clog2(XLEN / 8);

  logic [ReadCountW-1:0] read_outstanding;
  logic [ReadCountW-1:0] read_id_outstanding[IdCount];
  logic read_capacity;
  logic read_request_fire;
  logic read_response_fire;

  assign read_capacity = read_outstanding < ReadCountW'(MAX_READ_OUTSTANDING);
  assign axi.arvalid = mem.rd_req_valid && read_capacity;
  assign axi.arid = mem.rd_req_id;
  assign axi.araddr = mem.rd_req_addr;
  assign axi.arsize = mem.rd_req_size;
  assign axi.arlen = mem.rd_req_len;
  assign axi.arburst = mem.rd_req_burst;
  assign mem.rd_req_ready = axi.arready && read_capacity;
  assign read_request_fire = mem.rd_req_valid && mem.rd_req_ready;

  assign mem.rd_rsp_valid = axi.rvalid;
  assign mem.rd_rsp_id = axi.rid;
  assign mem.rd_rsp_data = axi.rdata;
  assign mem.rd_rsp_last = axi.rlast;
  assign mem.rd_rsp_error = axi.rresp != 2'b00;
  assign axi.rready = mem.rd_rsp_ready;
  assign read_response_fire = mem.rd_rsp_valid && mem.rd_rsp_ready && mem.rd_rsp_last;

  always_ff @(posedge clock) begin
    if (reset) begin
      read_outstanding <= '0;
      for (int id = 0; id < IdCount; id++) begin
        read_id_outstanding[id] <= '0;
      end
    end else begin
      unique case ({
        read_request_fire, read_response_fire
      })
        2'b10: read_outstanding <= read_outstanding + 1'b1;
        2'b01: read_outstanding <= read_outstanding - 1'b1;
        default: read_outstanding <= read_outstanding;
      endcase

      for (int id = 0; id < IdCount; id++) begin
        unique case ({
          read_request_fire && (mem.rd_req_id == ID_W'(id)),
          read_response_fire && (mem.rd_rsp_id == ID_W'(id))
        })
          2'b10: read_id_outstanding[id] <= read_id_outstanding[id] + 1'b1;
          2'b01: read_id_outstanding[id] <= read_id_outstanding[id] - 1'b1;
          default: read_id_outstanding[id] <= read_id_outstanding[id];
        endcase
      end
    end
  end

  logic write_busy;
  logic write_aw_pending;
  logic write_w_pending;
  logic [ID_W-1:0] write_id;
  logic [XLEN-1:0] write_addr;
  logic [2:0] write_size;
  logic [XLEN-1:0] write_data;
  logic [XLEN/8-1:0] write_strb;
  logic write_request_fire;
  logic write_response_fire;
  logic [AddrLsbW-1:0] write_addr_offset;

  assign mem.wr_req_ready = !write_busy;
  assign write_request_fire = mem.wr_req_valid && mem.wr_req_ready;
  assign write_addr_offset = mem.wr_req_addr[AddrLsbW-1:0];

  assign axi.awvalid = write_busy && write_aw_pending;
  assign axi.awid = write_id;
  assign axi.awaddr = write_addr;
  assign axi.awsize = write_size;
  assign axi.awlen = 8'h00;
  assign axi.awburst = 2'b00;

  assign axi.wvalid = write_busy && write_w_pending;
  assign axi.wdata = write_data;
  assign axi.wstrb = write_strb;
  assign axi.wlast = axi.wvalid;

  assign mem.wr_rsp_valid = write_busy && !write_aw_pending && !write_w_pending && axi.bvalid;
  assign mem.wr_rsp_id = axi.bid;
  assign mem.wr_rsp_error = axi.bresp != 2'b00;
  assign axi.bready = write_busy && !write_aw_pending && !write_w_pending && mem.wr_rsp_ready;
  assign write_response_fire = mem.wr_rsp_valid && mem.wr_rsp_ready;

  always_ff @(posedge clock) begin
    if (reset) begin
      write_busy <= 1'b0;
      write_aw_pending <= 1'b0;
      write_w_pending <= 1'b0;
      write_id <= '0;
      write_addr <= '0;
      write_size <= '0;
      write_data <= '0;
      write_strb <= '0;
    end else begin
      if (write_request_fire) begin
        write_busy <= 1'b1;
        write_aw_pending <= 1'b1;
        write_w_pending <= 1'b1;
        write_id <= mem.wr_req_id;
        write_addr <= mem.wr_req_addr;
        write_size <= mem.wr_req_size;
        write_data <= mem.wr_req_data << (write_addr_offset * 8);
        write_strb <= mem.wr_req_strb << write_addr_offset;
      end else begin
        if (axi.awvalid && axi.awready) begin
          write_aw_pending <= 1'b0;
        end
        if (axi.wvalid && axi.wready) begin
          write_w_pending <= 1'b0;
        end
        if (write_response_fire) begin
          write_busy <= 1'b0;
        end
      end
    end
  end

  `RAPT_SVA_IMPLY(
      clock, reset, AXI_READ_RESPONSE_OWNED, axi.rvalid,
      (read_id_outstanding[axi.rid] != '0) || (read_request_fire && (mem.rd_req_id == axi.rid)))
  `RAPT_SVA_IMPLY(clock, reset, AXI_WRITE_RESPONSE_OWNED, axi.bvalid,
                  write_busy && !write_aw_pending && !write_w_pending)
  `RAPT_SVA_IMPLY(clock, reset, AXI_WRITE_RESPONSE_ID, axi.bvalid, axi.bid == write_id)

endmodule
