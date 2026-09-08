# Friendly module name -> synthesizable SystemVerilog top and clock port.
# Core hierarchy blocks and selected scalable leaves for isolated comparison.
MODULES := core bpu ifu fqu stream_queue l1i idu rnu rename_checkpoint rou prf fpr dpu dispatch_select dispatch_steer issue_select muldiv_fu ieu feu cmu csr lsu l1d bus axi l2

TOP_core := rapt_core
TOP_bpu  := rapt_bpu
TOP_ifu  := rapt_ifu
TOP_fqu  := rapt_fqu
TOP_stream_queue := rapt_stream_queue
TOP_l1i  := rapt_l1i
TOP_idu  := rapt_idu
TOP_rnu  := rapt_rnu
TOP_rename_checkpoint := rapt_rename_checkpoint
TOP_rou  := rapt_rou
TOP_prf  := rapt_prf
TOP_fpr  := rapt_fpr
TOP_dpu  := rapt_dpu_syn_top
TOP_dispatch_select := rapt_dispatch_select_syn_top
TOP_dispatch_steer := rapt_dispatch_steer_syn_top
TOP_issue_select := rapt_issue_select_syn_top
TOP_muldiv_fu := rapt_ieu_mul
TOP_ieu  := rapt_ieu_syn_top
TOP_feu  := rapt_feu_syn_top
TOP_cmu  := rapt_cmu
TOP_csr  := rapt_csr
TOP_lsu  := rapt_lsu_syn_top
TOP_l1d  := rapt_l1d
TOP_bus  := rapt_bus
TOP_axi  := rapt_axi_master
TOP_l2   := rapt_l2

$(foreach module,$(MODULES),$(eval CLOCK_$(module) := clock))
