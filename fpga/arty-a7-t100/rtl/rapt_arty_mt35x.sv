// FPGA port of the MCU reference rapt_smc_ctrl serial engine.
// Retains the qualified SDR setup, DDR framing, falling-edge DQ launch,
// DQS sampling, pre/post SR+FSR checks, deadlines and hardware RESET# recovery.
// The bus frontend and protection storage are specific to this FPGA vehicle.
// Sampling DQS as data at 10 MHz is the reference low-speed implementation.
module rapt_arty_mt35x #(
    parameter int unsigned ClockHz = 10_000_000,
    parameter int unsigned READ_BUFFER_BYTES = 16,
    parameter int unsigned POWERUP_WAIT_CYCLES = ClockHz / 10000,
    parameter int unsigned READ_TIMEOUT_CYCLES = ClockHz / 1000,
    parameter int unsigned POLL_TIMEOUT_CYCLES = ClockHz / 10,
    parameter int unsigned ERASE_TIMEOUT_CYCLES = ClockHz * 5,
    parameter int unsigned RESET_RECOVERY_CYCLES = ClockHz / 10000
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
    output logic [7:0] maint_error_code_o,
    output logic init_done_o,
    output logic flash_ready_o,
    output logic flash_init_trusted_o,
    output logic flash_mode_known_o,
    output logic recovery_required_o,
    output logic [7:0] flash_sr_o,
    output logic [7:0] flash_fsr_o,
    output logic [23:0] flash_id_o,
    output logic xspi_ck_o,
    output logic xspi_csn_o,
    output logic xspi_reset_no,
    output logic [7:0] xspi_io_o,
    output logic [7:0] xspi_io_oe_o,
    input logic [7:0] xspi_io_i,
    input logic xspi_dqs_i
);
  localparam logic [1:0] FlashOpProgram = 2'd0;
  localparam logic [1:0] FlashOpErase = 2'd1;
  localparam logic [1:0] FlashOpRecover = 2'd2;
  localparam logic [31:0] FlashBytes = 32'h0100_0000;
  localparam logic [7:0] FlashOk = 8'd0;
  localparam logic [7:0] FlashErrAddress = 8'd3;
  localparam logic [7:0] FlashErrWel = 8'd5;
  localparam logic [7:0] FlashErrDevice = 8'd6;
  localparam logic [7:0] FlashErrTimeout = 8'd7;
  localparam logic [7:0] FlashErrMode = 8'd9;
  localparam logic [7:0] FlashErrSuspend = 8'd10;
  localparam logic [7:0] FlashErrCommand = 8'd11;
  // -----------------------------------------------------------------------
  // MT35X opcodes
  // -----------------------------------------------------------------------
  localparam logic [7:0] CMD_READ = 8'hFD;  // Octal I/O Fast Read DTR (DDR + DQS)
  localparam logic [7:0] CMD_PROGRAM = 8'h8E;  // 4-byte Extended Octal Input Fast Program
  localparam logic [7:0] CMD_WREN = 8'h06;  // Write Enable
  localparam logic [7:0] CMD_RDSR = 8'h05;  // Read Status Register (WIP = bit 0)
  localparam logic [7:0] CMD_RDFSR = 8'h70;
  localparam logic [7:0] CMD_RDID = 8'h9f;
  localparam logic [7:0] CMD_ERASE = 8'h21;
  localparam logic [7:0] CMD_CLRFSR = 8'h50;
  localparam logic [7:0] CMD_WRDI = 8'h04;
  localparam logic [7:0] CMD_WRVCR = 8'h81;  // Write Volatile Configuration Register
  localparam logic [7:0] CMD_RSTEN = 8'h66;  // Reset Enable
  localparam logic [7:0] CMD_RSTMEM = 8'h99;  // Reset Memory

  // VCR sub-addresses (only the LSB selects the register) and values.
  localparam logic [7:0] VCR_A_IOMODE = 8'h00;  // I/O mode
  localparam logic [7:0] VCR_A_DUMMY = 8'h01;  // dummy-cycle count
  localparam logic [7:0] VCR_A_ADDRB = 8'h05;  // 3/4-byte address select
  localparam logic [7:0] VCR_V_OCTDDR = 8'hE7;  // octal DDR + DQS
  localparam logic [7:0] VCR_V_4BYTE = 8'hFE;  // 4-byte addressing
  localparam logic [7:0] VCR_V_DUMMY = 8'd16;

  // Length of the CSn-high gap inserted between frames (clk cycles).
  localparam logic [4:0] GAP_LEN = 5'd4;

  // -----------------------------------------------------------------------
  // State machine
  // -----------------------------------------------------------------------
  typedef enum logic [5:0] {
    S_BOOT_RSTEN,       // power-on: single-lane 0x66 (Reset Enable)
    S_BOOT_GAP,         // CSn high between 0x66 and 0x99
    S_BOOT_RST,         // single-lane 0x99 (Reset Memory)
    S_BOOT_WAIT,        // CSn high, wait tRST
    S_CFG_CMD,          // single-lane config opcode (WREN / WRVCR)
    S_CFG_ADDR,         // single-lane WRVCR 24-bit register address
    S_CFG_DATA,         // single-lane WRVCR 8-bit data
    S_CFG_TAIL,         // CSn-low hold after WRVCR data
    S_CFG_GAP,          // CSn high between config frames; advance cfg_idx
    S_IDLE,
    S_WREN_CMD,         // octal WREN (0x06) before a program
    S_WREN_TAIL,        // hold WREN through its trailing edge
    S_WREN_GAP,         // CSn high after WREN
    S_CMD,              // octal opcode (0xFD read / 0x8E program)
    S_CMD_TAIL,         // hold opcode through command-to-address transition edge
    S_ADDR,             // octal address (4 bytes)
    S_DATA,             // octal data (read: DQS-gated in; program: 4 bytes out)
    S_WR_TAIL,          // CSn-low hold after program data (clean last-byte sample)
    S_PROG_GAP,         // CSn high after program, before status poll
    S_POLL_CMD,         // octal RDSR (0x05)
    S_POLL_CMD_TAIL,    // hold RDSR through command-to-data transition edge
    S_POLL_DATA,        // octal status byte in (check WIP)
    S_POLL_GAP,         // CSn high between poll attempts (WIP still set)
    S_RMW_GAP,          // Legacy encoding: maintenance WREN preparation gap
    S_DONE,
    // Append new states to preserve existing ILA state encodings.
    S_BOOT_POWER_WAIT,
    S_ABORT,
    S_HWRESET,
    S_STATUS_GAP,
    S_ERASE_TAIL,
    S_CLEAR_CMD,
    S_CLEAR_TAIL,
    S_CLEAR_GAP,
    S_EXEC_GAP
  } state_e;
  state_e state_q, state_d;

  // Beat counter: single-lane bit index, or octal byte index.
  logic [4:0] bit_cnt_q, bit_cnt_d;

  // Reuse the counter for the pre-command power-up wait and post-reset tRST.
  localparam int unsigned BOOT_WAIT_CYC = ClockHz / 10000;
  localparam int unsigned MaxBootReset =
      (POWERUP_WAIT_CYCLES > RESET_RECOVERY_CYCLES) ? POWERUP_WAIT_CYCLES : RESET_RECOVERY_CYCLES;
  localparam int unsigned MaxBootWait =
      (MaxBootReset > BOOT_WAIT_CYC) ? MaxBootReset : BOOT_WAIT_CYC;
  localparam int unsigned BootWaitW = $clog2(MaxBootWait + 1);
  logic [BootWaitW-1:0] boot_wait_q, boot_wait_d;

  // Boot-config microcode index (0..CFG_LAST).
  localparam logic [2:0] CFG_LAST = 3'd5;
  logic [2:0] cfg_idx_q, cfg_idx_d;

  // SCK divider (toggles every clk while a frame is active).
  logic sck_q;
  logic csn_q;

  // Octal shift registers (cmd/addr/write-data present the MSB byte).
  logic [7:0] cmd_q, cmd_d;
  logic [31:0] addr_q, addr_d;  // {8'h00, addr[23:0]} for octal; unused for config
  logic [31:0] wdat_q, wdat_d;  // octal write-data shifter
  logic [31:0] rdat_q, rdat_d;  // octal read-data / status capture

  // Latched serial operation; public AXI writes never reach this datapath.
  logic op_we_q, op_we_d;  // 1 = current octal data phase is a program
  logic [23:0] addr_hold_q, addr_hold_d;
  logic [31:0] wdat_hold_q, wdat_hold_d;  // program data (byte-swapped)
  logic [1:0] maint_op_q, maint_op_d;
  logic maint_active_q, maint_active_d;
  logic startup_q, startup_d;
  logic protocol_known_q, protocol_known_d;
  logic init_trusted_q, init_trusted_d;
  logic recovery_q, recovery_d;
  logic [7:0] error_q, error_d;
  logic [7:0] sr_q, sr_d, fsr_q, fsr_d;
  logic [23:0] id_q, id_d;
  logic recovery_cleared_q, recovery_cleared_d;
  logic clear_wel_q, clear_wel_d;
  typedef enum logic [3:0] {
    P_INIT_ID,
    P_INIT_SR,
    P_INIT_FSR,
    P_PRE_SR,
    P_PRE_FSR,
    P_WEL_SR,
    P_POST_SR,
    P_POST_FSR,
    P_REC_SR,
    P_REC_FSR
  } poll_e;
  poll_e poll_q, poll_d;
  logic bus_read_active_q;
  logic read_accept, maint_accept, public_reject;
  wire frontend_rst_n = rst_ni;
  wire bus_rst_ni = rst_ni;
  wire req = read_req_i;
  wire we = 1'b0;
  wire [23:0] addr = read_addr_i[23:0];
  logic ready;
  logic [31:0] rdata;
  logic timeout_q, timeout_d;
  state_e timeout_state_q, timeout_state_d;

  localparam int unsigned ReadWords   = READ_BUFFER_BYTES / 4;
  localparam int unsigned ReadOffsetW = $clog2(READ_BUFFER_BYTES);
  localparam int unsigned ReadWordW   = (ReadWords > 1) ? $clog2(ReadWords) : 1;
  localparam int unsigned ReadBaseW   = 24 - ReadOffsetW;
  logic [ReadBaseW-1:0] read_base_q, read_base_d;
  logic read_valid_q, read_valid_d, read_live_q, read_live_d;
  logic read_unaligned_q, read_unaligned_d;
  logic [31:0] read_words_q[ReadWords];
  logic read_word_ue[ReadWords];
  logic [ReadWordW-1:0] read_word_index;
  logic read_buffer_hit;
  logic read_word_capture, read_fill_complete;
  logic [ReadWords-1:0] read_word_valid_q, read_word_valid_d;
  logic public_fill_busy, timeout_event;

  initial begin
    if (READ_BUFFER_BYTES < 4 || READ_BUFFER_BYTES > 32 ||
        (READ_BUFFER_BYTES & (READ_BUFFER_BYTES - 1)) != 0)
      $fatal(1, "READ_BUFFER_BYTES must be 4, 8, 16 or 32");
  end
  assign read_word_index = ReadWordW'((32'(addr) >> 2) & (ReadWords - 1));
  // A reset revokes the old bus operation and every partial-fill claim. New
  // requests must see BUSY/error while that orphaned serial frame drains.
  assign public_fill_busy = !maint_active_q && !op_we_q &&
      (read_live_q || bus_read_active_q || read_valid_q) &&
      ((state_q == S_DATA) || (state_q == S_DONE));
  assign read_buffer_hit = (addr[1:0] == 0) &&
      (addr[23:ReadOffsetW] == read_base_q) && !read_word_ue[read_word_index] &&
      ((read_valid_q && ((state_q == S_IDLE) || (state_q == S_DONE))) ||
       (read_live_q && public_fill_busy && read_word_valid_q[read_word_index])) &&
      !timeout_event && !recovery_q && bus_rst_ni;

  assign read_done_o = (public_reject && state_q != S_ABORT)
      || (req && read_buffer_hit) || (ready && bus_read_active_q && !maint_active_q);
  assign read_error_o = public_reject || timeout_q;
  assign read_data_o = rdata;
  assign public_reject = req && !bus_read_active_q
      && (!init_trusted_q || recovery_q || maint_req_i
          || (state_q != S_IDLE && !public_fill_busy));
  assign read_accept = req && !public_reject && state_q == S_IDLE && !read_buffer_hit;
  assign maint_ready_o = state_q == S_IDLE && !req && maint_permit_i
      && protocol_known_q && (maint_op_i == FlashOpRecover || (init_trusted_q && !recovery_q));
  assign maint_accept = maint_req_i && maint_ready_o;
  assign init_done_o = !startup_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) bus_read_active_q <= 1'b0;
    else bus_read_active_q <= read_accept || (bus_read_active_q && !read_done_o);
  end

  // Byte-swap helper: wire (big-endian, low address first) <-> CPU little-endian.
  function automatic logic [31:0] bswap(input logic [31:0] w);
    bswap = {w[7:0], w[15:8], w[23:16], w[31:24]};
  endfunction

  // -----------------------------------------------------------------------
  // Boot-config microcode decode (single-lane frames)
  // -----------------------------------------------------------------------
  logic [7:0] cfg_cmd;
  logic       cfg_is_wrvcr;
  logic [7:0] cfg_vaddr;
  logic [7:0] cfg_vdata;
  always_comb begin
    unique case (cfg_idx_q)
      3'd0: begin
        cfg_cmd = CMD_WREN;
        cfg_is_wrvcr = 1'b0;
        cfg_vaddr = 8'h0;
        cfg_vdata = 8'h0;
      end
      3'd1: begin
        cfg_cmd = CMD_WRVCR;
        cfg_is_wrvcr = 1'b1;
        cfg_vaddr = VCR_A_DUMMY;
        cfg_vdata = VCR_V_DUMMY;
      end
      3'd2: begin
        cfg_cmd = CMD_WREN;
        cfg_is_wrvcr = 1'b0;
        cfg_vaddr = 8'h0;
        cfg_vdata = 8'h0;
      end
      3'd3: begin
        cfg_cmd = CMD_WRVCR;
        cfg_is_wrvcr = 1'b1;
        cfg_vaddr = VCR_A_ADDRB;
        cfg_vdata = VCR_V_4BYTE;
      end
      3'd4: begin
        cfg_cmd = CMD_WREN;
        cfg_is_wrvcr = 1'b0;
        cfg_vaddr = 8'h0;
        cfg_vdata = 8'h0;
      end
      default: begin  // 3'd5: last frame flips the device into octal DDR
        cfg_cmd = CMD_WRVCR;
        cfg_is_wrvcr = 1'b1;
        cfg_vaddr = VCR_A_IOMODE;
        cfg_vdata = VCR_V_OCTDDR;
      end
    endcase
  end
  // WRVCR starts with a 24-bit register address. After cfg_idx 3 enables
  // four-byte addressing, the final I/O-mode WRVCR must use 32 address bits.
  logic [31:0] cfg_addr;
  assign cfg_addr = {24'h000000, cfg_vaddr};

  // -----------------------------------------------------------------------
  // Phase classification + SCK / CSn generation
  // -----------------------------------------------------------------------
  logic csn_high;
  logic csn_high_d;
  always_comb begin
    unique case (state_q)
      S_IDLE, S_BOOT_POWER_WAIT, S_BOOT_GAP, S_BOOT_WAIT, S_CFG_GAP, S_WREN_GAP,
      S_PROG_GAP, S_POLL_GAP, S_RMW_GAP, S_DONE, S_HWRESET, S_STATUS_GAP, S_CLEAR_GAP,
      S_EXEC_GAP:
      csn_high = 1'b1;
      default: csn_high = 1'b0;
    endcase
  end
  always_comb begin
    unique case (state_d)
      S_IDLE, S_BOOT_POWER_WAIT, S_BOOT_GAP, S_BOOT_WAIT, S_CFG_GAP, S_WREN_GAP,
      S_PROG_GAP, S_POLL_GAP, S_RMW_GAP, S_DONE, S_HWRESET, S_STATUS_GAP, S_CLEAR_GAP,
      S_EXEC_GAP:
      csn_high_d = 1'b1;
      default: csn_high_d = 1'b0;
    endcase
  end

  logic single_lane;  // bit-serial 1-1-1 frame on IO[0]
  always_comb begin
    unique case (state_q)
      S_BOOT_RSTEN, S_BOOT_RST, S_CFG_CMD, S_CFG_ADDR, S_CFG_DATA: single_lane = 1'b1;
      default: single_lane = 1'b0;
    endcase
  end

  logic sck_d;
  always_comb begin
    if (state_q == S_ABORT) sck_d = 1'b1;
    else if (csn_high || (state_q == S_CFG_TAIL)) sck_d = 1'b0;
    else if (csn_high_d && !single_lane) sck_d = sck_q;
    else sck_d = ~sck_q;
  end
  rapt_arty_flash_reg #(
      .WIDTH(2),
      .RESET_VALUE(2'b01)
  ) u_clock_select_tmr (
      .clk_i,
      .rst_ni,
      .write_en_i(1'b1),
      .data_i({sck_d, csn_high_d}),
      .data_o({sck_q, csn_q}),
      .mismatch_o()
  );
  assign xspi_ck_o = sck_q;
  assign xspi_csn_o = csn_q;
  assign xspi_reset_no = rst_ni && (state_q != S_HWRESET);

  // Single-lane bit advance: one bit per SCK period (evaluated on SCK high).
  logic bit_adv;
  assign bit_adv = single_lane && (sck_q == 1'b1);

  // Octal read inputs.
  logic [7:0] io_in_byte;
  logic       dqs_valid;
  logic       dqs_prev_q;
  logic       control_byte_defined;
  assign io_in_byte = xspi_io_i;
  assign dqs_valid  = xspi_dqs_i ^ dqs_prev_q;

  // A four-state control response must positively establish its value. An X/Z
  // comparison in an if-condition otherwise falls through as if it were false.
  // This simulation check is not an electrical/metastability detector: synthesis
  // sees binary inputs and removes the unreachable default case.
  always_comb begin
    control_byte_defined = 1'b0;
    case (^io_in_byte)
      1'b0, 1'b1: control_byte_defined = 1'b1;
      default: ;
    endcase
  end

  // A history-bit upset would insert/drop a received byte before ECC exists.
  rapt_arty_flash_reg #(
      .WIDTH(1)
  ) u_dqs_history_tmr (
      .clk_i,
      .rst_ni,
      .write_en_i(1'b1),
      .data_i(xspi_dqs_i),
      .data_o(dqs_prev_q),
      .mismatch_o()
  );

  // Bound the whole read/status data phase, including a stalled partial read.
  // A separate deadline spans all program-status polls, even if WIP never clears.
  localparam int unsigned ReadWaitW = (READ_TIMEOUT_CYCLES > 1) ? $clog2(READ_TIMEOUT_CYCLES) : 1;
  localparam int unsigned MaxPollWait = (ERASE_TIMEOUT_CYCLES > POLL_TIMEOUT_CYCLES) ?
      ERASE_TIMEOUT_CYCLES : POLL_TIMEOUT_CYCLES;
  localparam int unsigned PollWaitW = (MaxPollWait > 1) ? $clog2(MaxPollWait + 1) : 1;
  logic [ReadWaitW-1:0] read_wait_q, read_wait_d;
  logic [PollWaitW-1:0] poll_wait_q, poll_wait_d;
  logic read_wait_active, poll_wait_active;
  logic read_expired, poll_expired, read_complete, poll_complete;
  logic [PollWaitW-1:0] poll_limit;

  assign read_wait_active = ((state_q == S_DATA) && !op_we_q) || (state_q == S_POLL_DATA);
  assign poll_wait_active = (maint_active_q || (startup_q && protocol_known_q)) &&
      (state_q != S_DONE) && (state_q != S_ABORT);
  assign poll_limit = PollWaitW'((maint_active_q && maint_op_q != FlashOpProgram) ?
      ERASE_TIMEOUT_CYCLES : POLL_TIMEOUT_CYCLES);
  assign read_expired = (READ_TIMEOUT_CYCLES != 0) && read_wait_active &&
      (read_wait_q == ReadWaitW'(READ_TIMEOUT_CYCLES - 1));
  assign poll_expired = poll_wait_active && (poll_wait_q >= poll_limit - PollWaitW'(1));
  assign read_complete = (state_q == S_DATA) && !op_we_q && dqs_valid && (bit_cnt_q == 0);
  assign poll_complete = (state_q == S_POLL_DATA) && dqs_valid && control_byte_defined &&
      ((poll_q == P_POST_FSR) || (poll_q == P_INIT_FSR) || (poll_q == P_REC_FSR)) &&
      (io_in_byte == 8'h81) && (sr_q[1:0] == 0);
  assign timeout_event =
      (read_expired && !read_complete && !((state_q == S_POLL_DATA) && dqs_valid)) ||
      (poll_expired && !poll_complete);

  always_comb begin
    read_wait_d = '0;
    poll_wait_d = '0;
    timeout_state_d = timeout_state_q;
    if (read_wait_active && (READ_TIMEOUT_CYCLES != 0)) begin
      read_wait_d = read_expired ? read_wait_q : read_wait_q + ReadWaitW'(1);
    end
    if (poll_wait_active) begin
      poll_wait_d = poll_expired ? poll_wait_q : poll_wait_q + PollWaitW'(1);
    end
    if (timeout_event) begin
      timeout_state_d = state_q;
    end
  end
  assign timeout_d = timeout_event ? 1'b1 : ((read_accept || maint_accept) ? 1'b0 : timeout_q);

  rapt_arty_flash_reg #(
      .WIDTH(ReadWaitW + PollWaitW + 7)
  ) u_timeout_tmr (
      .clk_i,
      .rst_ni,
      .write_en_i(1'b1),
      .data_i({read_wait_d, poll_wait_d, timeout_d, timeout_state_d}),
      .data_o({read_wait_q, poll_wait_q, timeout_q, timeout_state_q}),
      .mismatch_o()
  );

  // -----------------------------------------------------------------------
  // IO drive + output-enable mux
  // -----------------------------------------------------------------------
  logic [7:0] io_drive;
  logic [7:0] io_oe;
  logic [7:0] io_drive_q;
  logic [7:0] io_oe_q;
  logic       sl_bit;  // single-lane bit currently presented on IO[0]
  always_comb begin
    unique case (state_q)
      S_BOOT_RSTEN: sl_bit = CMD_RSTEN[bit_cnt_q[2:0]];
      S_BOOT_RST:   sl_bit = CMD_RSTMEM[bit_cnt_q[2:0]];
      S_CFG_CMD:    sl_bit = cfg_cmd[bit_cnt_q[2:0]];
      S_CFG_ADDR:   sl_bit = cfg_addr[bit_cnt_q[4:0]];
      S_CFG_DATA:   sl_bit = cfg_vdata[bit_cnt_q[2:0]];
      default:      sl_bit = 1'b0;
    endcase
  end
  always_comb begin
    unique case (state_q)
      S_BOOT_RSTEN, S_BOOT_RST, S_CFG_CMD, S_CFG_ADDR, S_CFG_DATA: begin
        io_drive = {7'b0, sl_bit};
        io_oe    = 8'b0000_0001;  // single-lane: drive IO[0] only
      end
      S_WREN_CMD, S_WREN_TAIL, S_CMD, S_CMD_TAIL, S_POLL_CMD, S_POLL_CMD_TAIL,
      S_CLEAR_CMD, S_CLEAR_TAIL: begin
        io_drive = cmd_q[7:0];  // octal command byte
        io_oe    = 8'hFF;
      end
      S_ADDR: begin
        io_drive = addr_q[31:24];  // octal address byte (MSB first)
        io_oe    = 8'hFF;
      end
      S_DATA: begin
        io_drive = op_we_q ? wdat_q[31:24] : 8'h00;
        io_oe    = op_we_q ? 8'hFF : 8'h00;  // read: release IO for the device
      end
      default: begin
        io_drive = 8'h00;
        io_oe    = 8'h00;
      end
    endcase
  end
  wire io_launch_clk = ~clk_i;
  rapt_arty_flash_reg #(
      .WIDTH(16)
  ) u_io_launch_tmr (
      .clk_i(io_launch_clk),
      .rst_ni,
      .write_en_i(1'b1),
      .data_i({io_drive, io_oe}),
      .data_o({io_drive_q, io_oe_q}),
      .mismatch_o()
  );
  assign xspi_io_o    = io_drive_q;
  assign xspi_io_oe_o = io_oe_q;

  // -----------------------------------------------------------------------
  // Serial payload and boot configuration. Maintenance payload is captured once.
  // -----------------------------------------------------------------------
  always_comb begin
    cmd_d = cmd_q;
    addr_d = addr_q;
    wdat_d = wdat_q;
    rdat_d = rdat_q;
    op_we_d = op_we_q;
    addr_hold_d = addr_hold_q;
    wdat_hold_d = wdat_hold_q;
    maint_op_d = maint_op_q;
    cfg_idx_d = cfg_idx_q;

    if (state_q == S_BOOT_WAIT) cfg_idx_d = 3'd0;
    else if ((state_q == S_CFG_GAP) && (bit_cnt_q == 0) && (cfg_idx_q != CFG_LAST))
      cfg_idx_d = cfg_idx_q + 3'd1;
    if (read_accept) begin
      // Preserve the original four-byte wire transaction for an unaligned
      // public address; such a request must not select a different word.
      addr_d = (addr[1:0] != 0) ? {8'h00, addr}
            : {8'h00, addr[23:ReadOffsetW], {ReadOffsetW{1'b0}}};
      op_we_d = 1'b0;
      cmd_d = CMD_READ;
    end
    if (maint_accept) begin
      maint_op_d = maint_op_i;
      addr_hold_d = maint_addr_i[23:0];
      wdat_hold_d = bswap(maint_wdata_i);
      op_we_d = maint_op_i == FlashOpProgram;
    end
    case (state_q)
      S_ADDR: addr_d = {addr_q[23:0], 8'h0};
      S_DATA: begin
        if (op_we_q) wdat_d = {wdat_q[23:0], 8'h0};
        else if (dqs_valid) rdat_d = {rdat_q[23:0], io_in_byte};
      end
      S_STATUS_GAP, S_POLL_GAP: begin
        case (poll_q)
          P_INIT_ID: cmd_d = CMD_RDID;
          P_INIT_FSR, P_PRE_FSR, P_POST_FSR, P_REC_FSR: cmd_d = CMD_RDFSR;
          default: cmd_d = CMD_RDSR;
        endcase
      end
      S_WREN_GAP: cmd_d = CMD_RDSR;
      S_PROG_GAP: cmd_d = CMD_RDSR;
      S_POLL_DATA:
      if (dqs_valid) begin
        rdat_d = {rdat_q[23:0], io_in_byte};
        if (poll_q == P_PRE_FSR) cmd_d = CMD_WREN;
        if (poll_q == P_WEL_SR) begin
          cmd_d  = maint_op_q == FlashOpErase ? CMD_ERASE : CMD_PROGRAM;
          addr_d = {8'h00, addr_hold_q};
          wdat_d = wdat_hold_q;
        end
      end
      S_CLEAR_GAP: cmd_d = clear_wel_q ? CMD_WRDI : CMD_CLRFSR;
      default: ;
    endcase
  end
  localparam int unsigned SerialPayloadW = 8 + 32 + 32 + 32 + 1 + 24 + 32 + 2 + 3;
  rapt_arty_flash_reg #(
      .WIDTH(SerialPayloadW),
      .RESET_VALUE({CMD_READ, 32'b0, 32'b0, 32'b0, 1'b0, 24'b0, 32'b0, FlashOpProgram, 3'b0})
  ) u_serial_payload_tmr (
      .clk_i,
      .rst_ni,
      .write_en_i(1'b1),
      .data_i({
        cmd_d, addr_d, wdat_d, rdat_d, op_we_d, addr_hold_d, wdat_hold_d, maint_op_d, cfg_idx_d
      }),
      .data_o({
        cmd_q, addr_q, wdat_q, rdat_q, op_we_q, addr_hold_q, wdat_hold_q, maint_op_q, cfg_idx_q
      }),
      .mismatch_o()
  );

  // -----------------------------------------------------------------------
  // Beat counter + state transitions
  // -----------------------------------------------------------------------
  always_comb begin
    state_d            = state_q;
    bit_cnt_d          = bit_cnt_q;
    boot_wait_d        = boot_wait_q;
    maint_active_d     = maint_active_q;
    startup_d          = startup_q;
    protocol_known_d   = protocol_known_q;
    init_trusted_d     = init_trusted_q;
    recovery_d         = recovery_q;
    error_d            = error_q;
    sr_d               = sr_q;
    fsr_d              = fsr_q;
    id_d               = id_q;
    poll_d             = poll_q;
    recovery_cleared_d = recovery_cleared_q;
    clear_wel_d        = clear_wel_q;
    unique case (state_q)
      S_HWRESET: begin
        if (boot_wait_q == 0) begin
          state_d = S_BOOT_POWER_WAIT;
          boot_wait_d = BootWaitW'(RESET_RECOVERY_CYCLES);
        end else boot_wait_d = boot_wait_q - BootWaitW'(1);
      end
      // ---- power-on reset sequence (single-lane) ----
      S_BOOT_POWER_WAIT: begin
        if (boot_wait_q == '0) begin
          state_d   = S_BOOT_RSTEN;
          bit_cnt_d = 5'd7;
        end else boot_wait_d = boot_wait_q - BootWaitW'(1);
      end
      S_BOOT_RSTEN:
      if (bit_adv) begin
        if (bit_cnt_q == 5'd0) begin
          state_d   = S_BOOT_GAP;
          bit_cnt_d = GAP_LEN;
        end else bit_cnt_d = bit_cnt_q - 5'd1;
      end
      S_BOOT_GAP: begin
        if (bit_cnt_q == 5'd0) begin
          state_d   = S_BOOT_RST;
          bit_cnt_d = 5'd7;  // 8 bits of 0x99
        end else bit_cnt_d = bit_cnt_q - 5'd1;
      end
      S_BOOT_RST:
      if (bit_adv) begin
        if (bit_cnt_q == 5'd0) begin
          state_d     = S_BOOT_WAIT;
          boot_wait_d = BootWaitW'(BOOT_WAIT_CYC);
        end else bit_cnt_d = bit_cnt_q - 5'd1;
      end
      S_BOOT_WAIT: begin
        if (boot_wait_q == '0) begin
          state_d   = S_CFG_CMD;
          bit_cnt_d = 5'd7;  // 8 config-opcode bits
        end else boot_wait_d = boot_wait_q - BootWaitW'(1);
      end

      // ---- boot-config microcode (single-lane WREN / WRVCR) ----
      S_CFG_CMD:
      if (bit_adv) begin
        if (bit_cnt_q == 5'd0) begin
          if (cfg_is_wrvcr) begin
            state_d   = S_CFG_ADDR;
            bit_cnt_d = (cfg_idx_q == CFG_LAST) ? 5'd31 : 5'd23;
          end else begin
            state_d   = S_CFG_GAP;  // WREN: no address / data
            bit_cnt_d = GAP_LEN;
          end
        end else bit_cnt_d = bit_cnt_q - 5'd1;
      end
      S_CFG_ADDR:
      if (bit_adv) begin
        if (bit_cnt_q == 5'd0) begin
          state_d   = S_CFG_DATA;
          bit_cnt_d = 5'd7;  // 8 data bits
        end else bit_cnt_d = bit_cnt_q - 5'd1;
      end
      S_CFG_DATA:
      if (bit_adv) begin
        if (bit_cnt_q == 5'd0) begin
          state_d   = S_CFG_TAIL;
          bit_cnt_d = GAP_LEN;
        end else bit_cnt_d = bit_cnt_q - 5'd1;
      end
      S_CFG_TAIL: state_d = S_CFG_GAP;
      S_CFG_GAP: begin
        if (bit_cnt_q == 5'd0) begin
          if (cfg_idx_q == CFG_LAST) begin
            // Establish protocol and device identity before permitting reads.
            protocol_known_d = 1'b1;
            poll_d = P_INIT_ID;
            state_d = S_STATUS_GAP;
            bit_cnt_d = GAP_LEN;
          end else begin
            state_d   = S_CFG_CMD;  // cfg_idx_q advances in the datapath block
            bit_cnt_d = 5'd7;
          end
        end else bit_cnt_d = bit_cnt_q - 5'd1;
      end

      // ---- idle / dispatch ----
      S_IDLE: begin
        if (maint_accept) begin
          maint_active_d = 1'b1;
          error_d = FlashOk;
          recovery_cleared_d = 1'b0;
          poll_d = maint_op_i == FlashOpRecover ? P_REC_SR : P_PRE_SR;
          state_d = S_STATUS_GAP;
          bit_cnt_d = GAP_LEN;
          if (maint_op_i > FlashOpRecover) begin
            error_d = FlashErrCommand;
            state_d = S_DONE;
          end else if (maint_op_i != FlashOpRecover &&
              (maint_addr_i < 32'h0080_0000 || maint_addr_i >= FlashBytes ||
               maint_addr_i[1:0] != 0 ||
               (maint_op_i == FlashOpErase && maint_addr_i[11:0] != 0))) begin
            error_d = FlashErrAddress;
            state_d = S_DONE;
          end
        end else if (read_accept) begin
          state_d   = S_CMD;
          bit_cnt_d = 0;
          error_d   = FlashOk;
        end
      end

      // ---- octal WREN (1 byte) ----
      S_WREN_CMD: begin
        state_d   = S_WREN_TAIL;
        bit_cnt_d = 5'd1;
      end
      S_WREN_TAIL: begin
        if (bit_cnt_q != 0) bit_cnt_d = bit_cnt_q - 5'd1;
        else begin
          state_d   = S_WREN_GAP;
          bit_cnt_d = GAP_LEN;
        end
      end
      S_WREN_GAP: begin
        if (bit_cnt_q == 5'd0) begin
          state_d = S_POLL_CMD;
          poll_d = P_WEL_SR;
          bit_cnt_d = 5'd0;
        end else bit_cnt_d = bit_cnt_q - 5'd1;
      end

      // ---- octal command / address / data ----
      S_CMD: begin
        state_d   = S_CMD_TAIL;
        bit_cnt_d = 5'd0;
      end
      S_CMD_TAIL: begin
        state_d   = S_ADDR;
        bit_cnt_d = 5'd3;  // 4 octal address bytes
      end
      S_ADDR:
      if (bit_cnt_q == 5'd0) begin
        state_d = (maint_active_q && maint_op_q == FlashOpErase) ? S_ERASE_TAIL : S_DATA;
        bit_cnt_d = (!maint_active_q && !op_we_q && !read_unaligned_q)
            ? 5'(READ_BUFFER_BYTES - 1) : 5'd3;
      end else bit_cnt_d = bit_cnt_q - 5'd1;
      S_DATA:
      if (op_we_q) begin
        if (bit_cnt_q == 5'd0) begin
          state_d = S_WR_TAIL;  // hold CSn low after the final data edge
        end else bit_cnt_d = bit_cnt_q - 5'd1;
      end else if (dqs_valid) begin
        if (bit_cnt_q == 5'd0) begin
          state_d = S_DONE;
        end else bit_cnt_d = bit_cnt_q - 5'd1;
      end

      // ---- program status poll (WREN -> program -> poll) ----
      S_WR_TAIL, S_ERASE_TAIL: begin
        state_d = S_PROG_GAP;  // last data byte now sampled with CSn low
        bit_cnt_d = GAP_LEN;
        poll_d = P_POST_SR;
      end
      S_PROG_GAP, S_POLL_GAP, S_STATUS_GAP: begin
        if (bit_cnt_q == 5'd0) begin
          state_d   = S_POLL_CMD;
          bit_cnt_d = poll_q == P_INIT_ID ? 5'd2 : 5'd0;
        end else bit_cnt_d = bit_cnt_q - 5'd1;
      end
      S_POLL_CMD: begin
        state_d = S_POLL_CMD_TAIL;
      end
      S_POLL_CMD_TAIL: begin
        state_d = S_POLL_DATA;
      end
      S_POLL_DATA:
      if (dqs_valid) begin
        state_d   = S_STATUS_GAP;
        bit_cnt_d = GAP_LEN;
        case (poll_q)
          P_INIT_ID: begin
            id_d = {id_q[15:0], io_in_byte};
            if (bit_cnt_q != 0) begin
              state_d   = S_POLL_DATA;
              bit_cnt_d = bit_cnt_q - 5'd1;
            end else if ({id_q[15:0], io_in_byte} !== 24'h2c5b19) begin
              error_d = FlashErrMode;
              protocol_known_d = 1'b0;
              recovery_d = 1'b1;
              state_d = S_DONE;
            end else poll_d = P_INIT_SR;
          end
          P_INIT_SR, P_PRE_SR, P_POST_SR, P_REC_SR, P_WEL_SR: begin
            sr_d = io_in_byte;
            if (io_in_byte[0]) begin
              // Preserve the operation-wide deadline across status frames.
              state_d = S_POLL_GAP;
            end else if (poll_q == P_WEL_SR) begin
              if (!io_in_byte[1]) begin
                error_d = FlashErrWel;
                state_d = S_DONE;
              end else state_d = S_EXEC_GAP;
            end else if (poll_q == P_REC_SR && io_in_byte[1]) begin
              clear_wel_d = 1'b1;
              state_d = S_CLEAR_GAP;
            end else if ((poll_q == P_POST_SR || poll_q == P_INIT_SR) && io_in_byte[1]) begin
              // WIP=0 with WEL still set can mean an ignored command.
              error_d = FlashErrWel;
              recovery_d = 1'b1;
              state_d = S_DONE;
            end else begin
              case (poll_q)
                P_INIT_SR: poll_d = P_INIT_FSR;
                P_PRE_SR:  poll_d = P_PRE_FSR;
                P_POST_SR: poll_d = P_POST_FSR;
                default:   poll_d = P_REC_FSR;
              endcase
            end
          end
          default: begin
            fsr_d = io_in_byte;
            if (!io_in_byte[0]) begin
              error_d = FlashErrMode;
              recovery_d = 1'b1;
              protocol_known_d = 1'b0;
              state_d = S_DONE;
            end else if (io_in_byte[6] || io_in_byte[2]) begin
              error_d = FlashErrSuspend;
              recovery_d = 1'b1;
              state_d = S_DONE;
            end else if (!io_in_byte[7]) begin
              state_d = S_POLL_GAP;
            end else if (|(io_in_byte & 8'h32)) begin
              if (poll_q == P_REC_FSR && !recovery_cleared_q) begin
                clear_wel_d = 1'b0;
                recovery_cleared_d = 1'b1;
                state_d = S_CLEAR_GAP;
              end else begin
                error_d = FlashErrDevice;
                recovery_d = 1'b1;
                state_d = S_DONE;
              end
            end else if (poll_q == P_PRE_FSR) begin
              state_d = S_RMW_GAP;  // preserved state number; now WREN preparation only
            end else begin
              init_trusted_d = 1'b1;
              recovery_d = 1'b0;
              state_d = S_DONE;
            end
          end
        endcase
        if (!control_byte_defined) begin
          error_d = FlashErrMode;
          protocol_known_d = 1'b0;
          init_trusted_d = 1'b0;
          recovery_d = 1'b1;
          state_d = S_DONE;
        end
      end

      // No array RMW exists. These CS-high intervals separate status commands
      // from WREN and the program/erase frame without changing legacy encodings.
      S_RMW_GAP: begin
        if (bit_cnt_q == 0) state_d = S_WREN_CMD;
        else bit_cnt_d = bit_cnt_q - 5'd1;
      end
      S_EXEC_GAP: begin
        if (bit_cnt_q == 0) state_d = S_CMD;
        else bit_cnt_d = bit_cnt_q - 5'd1;
      end
      S_CLEAR_GAP: begin
        if (bit_cnt_q == 0) state_d = S_CLEAR_CMD;
        else bit_cnt_d = bit_cnt_q - 5'd1;
      end
      S_CLEAR_CMD: begin
        state_d   = S_CLEAR_TAIL;
        bit_cnt_d = 5'd1;
      end
      S_CLEAR_TAIL: begin
        if (bit_cnt_q != 0) bit_cnt_d = bit_cnt_q - 5'd1;
        else begin
          state_d = S_STATUS_GAP;
          poll_d = P_REC_SR;
          bit_cnt_d = GAP_LEN;
        end
      end

      // Release DQ in this state and hold CK high for a full cycle before CS
      // rises. The following S_DONE returns an AXI error instead of stale data.
      S_ABORT: if (sck_q) state_d = S_DONE;
      S_DONE: begin
        state_d = S_IDLE;
        maint_active_d = 1'b0;
        startup_d = 1'b0;
      end
      default: state_d = S_IDLE;
    endcase
    // A response that completes on the deadline still succeeds.
    if (timeout_event) begin
      state_d = csn_high ? S_DONE : S_ABORT;
      error_d = FlashErrTimeout;
      recovery_d = 1'b1;
      if (startup_q) protocol_known_d = 1'b0;
    end
  end

  localparam int unsigned ControlW = 6 + 5 + BootWaitW;
  logic [ControlW-1:0] control_q;

  rapt_arty_flash_reg #(
      .WIDTH(ControlW),
      .RESET_VALUE({S_HWRESET, 5'd7, BootWaitW'(POWERUP_WAIT_CYCLES)})
  ) u_control_tmr (
      .clk_i,
      .rst_ni,
      .write_en_i(1'b1),
      .data_i({state_d, bit_cnt_d, boot_wait_d}),
      .data_o(control_q),
      .mismatch_o()
  );

  assign {state_q, bit_cnt_q, boot_wait_q} = control_q;

  localparam int unsigned StatusW = 7 + 8 + 8 + 8 + 24 + 4;
  rapt_arty_flash_reg #(
      .WIDTH(StatusW),
      .RESET_VALUE({1'b0, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 8'd0, 8'd0, 8'd0, 24'd0, P_INIT_ID})
  ) u_status_tmr (
      .clk_i,
      .rst_ni,
      .write_en_i(1'b1),
      .data_i({
        maint_active_d,
        startup_d,
        protocol_known_d,
        init_trusted_d,
        recovery_d,
        recovery_cleared_d,
        clear_wel_d,
        error_d,
        sr_d,
        fsr_d,
        id_d,
        poll_d
      }),
      .data_o({
        maint_active_q,
        startup_q,
        protocol_known_q,
        init_trusted_q,
        recovery_q,
        recovery_cleared_q,
        clear_wel_q,
        error_q,
        sr_q,
        fsr_q,
        id_q,
        poll_q
      }),
      .mismatch_o()
  );
  assign maint_done_o = (state_q == S_DONE) && maint_active_q;
  assign maint_error_o = error_q != FlashOk;
  assign maint_error_code_o = error_q;
  assign flash_ready_o = init_trusted_q && !recovery_q && (state_q == S_IDLE);
  assign flash_init_trusted_o = init_trusted_q;
  assign flash_mode_known_o = protocol_known_q;
  assign recovery_required_o = recovery_q;
  assign flash_sr_o = sr_q;
  assign flash_fsr_o = fsr_q;
  assign flash_id_o = id_q;

  // -----------------------------------------------------------------------
  // Handshake outputs
  // -----------------------------------------------------------------------
  assign ready = (state_q == S_DONE);
  // Byte-swap rdat_q (wire/big-endian) -> CPU bus (little-endian).
  assign rdata = timeout_q ? 32'h0 : read_unaligned_q ? bswap(
      rdat_q
  ) : read_words_q[read_word_index];

  assign read_word_capture = (state_q == S_DATA) && !op_we_q &&
      !maint_active_q && !read_unaligned_q && dqs_valid && (bit_cnt_q[1:0] == 0);
  assign read_fill_complete = read_word_capture && (bit_cnt_q == 0);

  always_comb begin
    read_base_d = read_base_q;
    read_valid_d = read_valid_q;
    read_live_d = read_live_q;
    read_unaligned_d = read_unaligned_q;
    read_word_valid_d = read_word_valid_q;
    if (read_word_capture && read_live_q)
      read_word_valid_d[(READ_BUFFER_BYTES-1-int'(bit_cnt_q))/4] = 1'b1;
    if (read_accept) begin
      read_word_valid_d = '0;
      read_base_d = addr[23:ReadOffsetW];
      read_valid_d = 1'b0;
      read_live_d = addr[1:0] == 0;
      read_unaligned_d = addr[1:0] != 0;
    end
    if (read_fill_complete && read_live_q) begin
      read_valid_d = 1'b1;
      read_live_d  = 1'b0;
    end
    // A partial fill never becomes visible after a bus reset, timeout or
    // maintenance session. Program/erase/recovery all invalidate this buffer.
    if (!bus_rst_ni || maint_accept || recovery_q || timeout_event) begin
      read_word_valid_d = '0;
      read_valid_d = 1'b0;
      read_live_d = 1'b0;
    end
  end

  rapt_arty_flash_reg #(
      .WIDTH(ReadBaseW + 3)
  ) u_read_buffer_meta (
      .clk_i,
      .rst_ni(frontend_rst_n),
      .write_en_i({read_base_d, read_valid_d, read_live_d, read_unaligned_d} !=
                  {read_base_q, read_valid_q, read_live_q, read_unaligned_q}),
      .data_i({read_base_d, read_valid_d, read_live_d, read_unaligned_d}),
      .data_o({read_base_q, read_valid_q, read_live_q, read_unaligned_q}),
      .mismatch_o()
  );

  rapt_arty_flash_reg #(
      .WIDTH(ReadWords)
  ) u_read_word_valid_tmr (
      .clk_i,
      .rst_ni(frontend_rst_n),
      .write_en_i(1'b1),
      .data_i(read_word_valid_d),
      .data_o(read_word_valid_q),
      .mismatch_o()
  );

  for (genvar word_idx = 0; word_idx < ReadWords; word_idx++) begin : g_read_word
    rapt_arty_flash_data #(
        .DATA_W(32)
    ) u_data (
        .clk_i,
        .rst_ni,
        .check_enable_i(1'b1),
        .write_en_i(read_word_capture &&
            ((READ_BUFFER_BYTES - 1 - int'(bit_cnt_q)) / 4 == word_idx)),
        .data_i(bswap({rdat_q[23:0], io_in_byte})),
        .data_o(read_words_q[word_idx]),
        .corrected_event_o(),
        .uncorrectable_active_o(read_word_ue[word_idx]),
        .uncorrectable_event_o()
    );
  end

endmodule

// Ordinary FPGA registers replace the reference's protection primitives.
/* verilator lint_off DECLFILENAME */
module rapt_arty_flash_reg #(
    parameter int WIDTH = 1,
    parameter logic [WIDTH-1:0] RESET_VALUE = '0
) (
    input logic clk_i,
    input logic rst_ni,
    input logic write_en_i,
    input logic [WIDTH-1:0] data_i,
    output logic [WIDTH-1:0] data_o,
    output wire mismatch_o
);
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) data_o <= RESET_VALUE;
    else if (write_en_i) data_o <= data_i;
  end
  assign mismatch_o = 1'b0;
endmodule

module rapt_arty_flash_data #(
    parameter int DATA_W = 32
) (
    input logic clk_i,
    input logic rst_ni,
    input logic check_enable_i,
    input logic write_en_i,
    input logic [DATA_W-1:0] data_i,
    output logic [DATA_W-1:0] data_o,
    output wire corrected_event_o,
    output wire uncorrectable_active_o,
    output wire uncorrectable_event_o
);
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) data_o <= '0;
    else if (write_en_i) data_o <= data_i;
  end
  assign corrected_event_o = 1'b0;
  assign uncorrectable_active_o = 1'b0;
  assign uncorrectable_event_o = 1'b0;
endmodule
/* verilator lint_on DECLFILENAME */
