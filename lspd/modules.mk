# Friendly module name -> synthesizable SystemVerilog top and clock port.
# Keep this list at the rapt_core first-level hierarchy so reports remain easy
# to compare with the core integration hierarchy.
MODULES := core bpu ifu fqu l1i idu rnu rou prf fpr dpu ieu feu cmu csr lsu l1d bus axi l2

TOP_core := rapt_core
TOP_bpu  := rapt_bpu
TOP_ifu  := rapt_ifu
TOP_fqu  := rapt_fqu
TOP_l1i  := rapt_l1i
TOP_idu  := rapt_idu
TOP_rnu  := rapt_rnu
TOP_rou  := rapt_rou
TOP_prf  := rapt_prf
TOP_fpr  := rapt_fpr
TOP_dpu  := rapt_dpu_syn_top
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
