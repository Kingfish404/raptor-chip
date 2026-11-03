// Synchronous BRAM-backed substitute for the serial engine's request interface.
// Simulation only: a 16 MiB array exceeds this FPGA's BRAM capacity. Storage
// survives engine reset and programs implement NOR AND rather than overwrite.
module rapt_arty_flash_bram #(
    parameter int MemBytes = 16 * 1024 * 1024
) (
    input logic clk_i,
    input logic rst_ni,
    input logic read_req_i,
    input logic [31:0] read_addr_i,
    output logic read_done_o,
    output logic read_error_o,
    output logic [31:0] read_data_o,
    input logic maint_req_i,
    input logic maint_permit_i,
    input logic [1:0] maint_op_i,
    input logic [31:0] maint_addr_i,
    input logic [31:0] maint_wdata_i,
    output logic maint_ready_o,
    output logic maint_done_o,
    output logic maint_error_o,
    output logic [7:0] maint_error_code_o
);
  localparam int Words = MemBytes / 4;
  (* ram_style = "block" *) logic [31:0] storage[Words];
  typedef enum logic [2:0] {
    IDLE,
    READ,
    PROGRAM,
    ERASE,
    COMPLETE,
    WAIT_RELEASE
  } state_t;
  state_t state_q;
  logic [31:0] address_q, data_q, ram_read_q;
  logic [9:0] erase_left_q;
  logic ram_write;
  logic [31:0] ram_write_data, ram_read_addr;
  initial foreach (storage[i]) storage[i] = '1;
  assign maint_ready_o = state_q == IDLE && maint_permit_i && !read_req_i;
  assign maint_done_o = state_q == COMPLETE;
  assign maint_error_o = maint_error_code_o != 0;
  assign ram_write = state_q == PROGRAM || state_q == ERASE;
  assign ram_write_data = state_q == ERASE ? '1 : ram_read_q & data_q;
  assign ram_read_addr = maint_req_i && maint_ready_o ? maint_addr_i : read_addr_i;
  always_ff @(posedge clk_i) begin
    ram_read_q <= storage[ram_read_addr[$clog2(MemBytes)-1:2]];
    if (ram_write) storage[address_q[$clog2(MemBytes)-1:2]] <= ram_write_data;
  end
  always_ff @(posedge clk_i) begin
    read_done_o <= 1'b0;
    if (!rst_ni) begin
      state_q <= IDLE;
      read_error_o <= 1'b0;
      read_data_o <= '0;
      address_q <= '0;
      data_q <= '0;
      erase_left_q <= '0;
      maint_error_code_o <= '0;
    end else begin
      case (state_q)
        IDLE:
        if (read_req_i) begin
          read_error_o <= read_addr_i >= MemBytes || read_addr_i[1:0] != 0;
          state_q <= READ;
        end else if (maint_req_i && maint_ready_o) begin
          maint_error_code_o <= '0;
          state_q <= COMPLETE;
          if (maint_op_i != 0 && maint_op_i != 1) maint_error_code_o <= 8'd11;
          else if (maint_addr_i < 32'h0080_0000 || maint_addr_i >= MemBytes
                   || maint_addr_i[1:0] != 0
                   || (maint_op_i == 1 && maint_addr_i[11:0] != 0))
            maint_error_code_o <= 8'd3;
          else begin
            address_q <= maint_addr_i;
            data_q <= maint_wdata_i;
            erase_left_q <= 10'd1023;
            state_q <= maint_op_i == 1 ? ERASE : PROGRAM;
          end
        end
        READ: begin
          read_data_o <= read_error_o ? '0 : ram_read_q;
          read_done_o <= 1'b1;
          state_q <= WAIT_RELEASE;
        end
        PROGRAM: state_q <= COMPLETE;
        ERASE: begin
          address_q <= address_q + 4;
          erase_left_q <= erase_left_q - 1'b1;
          if (erase_left_q == 0) state_q <= COMPLETE;
        end
        COMPLETE: state_q <= WAIT_RELEASE;
        WAIT_RELEASE: if (!read_req_i && !maint_req_i) state_q <= IDLE;
        default: state_q <= IDLE;
      endcase
    end
  end
endmodule
