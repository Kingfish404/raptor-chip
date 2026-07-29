task automatic init_pmp_state_defaults(input bit mode_off_value);
  begin
    pmp_state.pmp_cfg_r = '0;
    pmp_state.pmp_cfg_w = '0;
    pmp_state.pmp_cfg_x = '0;
    pmp_state.pmp_cfg_l = '0;
    pmp_state.pmp_mode_off = mode_off_value ? '1 : '0;
    pmp_state.pmp_mode_tor = '0;
    pmp_state.pmp_mode_na4 = '0;
    pmp_state.pmp_mode_napot = '0;
    for (int i = 0; i < `RAPT_PMP_NUM; i++) begin
      pmp_state.pmp_raw_addr[i] = '0;
      pmp_state.pmp_napot_mask[i] = '0;
    end
  end
endtask
