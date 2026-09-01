`include "rapt.svh"

// Only needed to elaborate the pmp_state companion module that shares
// rapt_pmp.sv; the checker under proof has a flattened port list.
interface pmp_update_if #(
    parameter int PADDR_BITS = `RAPT_PADDR_BITS,
    parameter int N = `RAPT_PMP_NUM,
    parameter int IDX_W = $clog2(N)
);
  localparam int AW = PADDR_BITS - 2;
  logic addr_we;
  logic [IDX_W-1:0] addr_idx;
  logic [AW-1:0] raw_addr, napot_mask;
  logic [N-1:0] cfg_we, cfg_r, cfg_w, cfg_x, cfg_l;
  logic [N-1:0] mode_off, mode_tor, mode_na4, mode_napot;
  modport in(input addr_we, addr_idx, raw_addr, napot_mask, cfg_we, cfg_r,
             cfg_w, cfg_x, cfg_l, mode_off, mode_tor, mode_na4, mode_napot);
endinterface

interface pmp_state_if #(
    parameter int PADDR_BITS = `RAPT_PADDR_BITS,
    parameter int N = `RAPT_PMP_NUM
);
  localparam int AW = PADDR_BITS - 2;
  logic [AW-1:0] pmp_raw_addr[N], pmp_napot_mask[N];
  logic [N-1:0] pmp_cfg_r, pmp_cfg_w, pmp_cfg_x, pmp_cfg_l;
  logic [N-1:0] pmp_mode_off, pmp_mode_tor, pmp_mode_na4, pmp_mode_napot;
  modport out(output pmp_raw_addr, pmp_napot_mask, pmp_cfg_r, pmp_cfg_w,
              pmp_cfg_x, pmp_cfg_l, pmp_mode_off, pmp_mode_tor,
              pmp_mode_na4, pmp_mode_napot);
endinterface
