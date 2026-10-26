# Shared directed-rule table. Keep custom multi-command recipes in Makefile.
# Every rule defined here is registered in VERILATOR_DIRECTED_REGISTERED;
# verilator-directed-all runs every verilator-* rule, so new checks are gated
# without a second list (see scripts/directed_registry.py).
VERILATOR_DIRECTED_REGISTERED :=

# DIRECTED_TEST: target suffixes, build stem, top, helper sources, flags,
# plusargs, follow-up. Runtime expressions use $$ to survive eval.
define DIRECTED_TEST
VERILATOR_DIRECTED_REGISTERED += $(addprefix verilator-,$(1))
.PHONY: $(addprefix verilator-,$(1))
$(addprefix verilator-,$(1)):
	$$(call VERILATOR_DIRECTED_RUN,$(2),$(3),$(4),$(5),$(6),$(7))
endef

# Paired directed regressions: name, top, extra sources, defines, plusargs, follow-up.
# Keep special one-off recipes in Makefile. Runtime options use $$ in rows so
# eval preserves target-specific variables and late command-line overrides.
define XLEN_TEST
VERILATOR_DIRECTED_REGISTERED += verilator-$(1)-rv32 verilator-$(1)-rv64
.PHONY: verilator-$(1)-rv32 verilator-$(1)-rv64
verilator-$(1)-rv32 verilator-$(1)-rv64:
	$$(call VERILATOR_DIRECTED_XLEN_RUN,$(2),$(3),$(4),$(5),$(6))
endef

# DIRECTED_PRESET: target names, preset. Builds those targets against
# rtl/configs/<preset> whatever XSIM_RAPT_CONFIG the caller selected, for
# checks that probe preset-only structure (wide fetch, BOOM L2 geometry).
define DIRECTED_PRESET
$(1): override XSIM_COMMON_INCLUDES := $(subst /configs/$(XSIM_RAPT_CONFIG),/configs/$(2),$(XSIM_COMMON_INCLUDES))
endef

$(eval $(call XLEN_TEST,ptw-global,tb_ptw_global,,-d RAPT_ASSERT_EN))
$(eval $(call XLEN_TEST,zfhmin-decode-slot,tb_zfhmin_decode_slot))
$(eval $(call XLEN_TEST,uop-instruction-metadata,tb_uop_instruction_metadata,,-d SYNTHESIS))
$(eval $(call XLEN_TEST,idu-privileged,tb_idu_privileged,,-d RAPT_ASSERT_EN))
$(eval $(call XLEN_TEST,csr-sret-roundtrip,tb_csr_sret_roundtrip))
$(eval $(call XLEN_TEST,csr-architectural,tb_csr_architectural))
$(eval $(call XLEN_TEST,status-view,tb_status_view,,-d RAPT_ASSERT_EN))
$(eval $(call XLEN_TEST,addr-classification-ku15p,tb_addr_classification,,-d RAPT_PMEM_BYTES=2147483648))
$(eval $(call XLEN_TEST,addr-classification-litedram,tb_addr_classification,,-d RAPT_PMEM_BYTES=1073741824))
$(eval $(call XLEN_TEST,pmp-window-uniform,tb_pmp_window_uniform)) ## Lookahead PMP window never claims uniformity across a region edge
$(eval $(call XLEN_TEST,memory-coherence-progress,tb_memory_coherence_progress,,-d RAPT_ASSERT_EN,+BUS_DELAY_MAX=$$(VERILATOR_DIRECTED_DELAY) +SEED=$$(VERILATOR_DIRECTED_SEED)))
$(eval $(call XLEN_TEST,l1d-page-permissions,tb_l1d_page_permissions))
$(eval $(call XLEN_TEST,l1d-translated-pipeline,tb_translated_load_pipeline,,-d RAPT_ASSERT_EN))
$(eval $(call XLEN_TEST,translated-atomics,tb_translated_atomics,,-d RAPT_ASSERT_EN))
$(eval $(call XLEN_TEST,pmp-reset-napot,tb_pmp_reset_napot,"$$(VERIFY_HOME)/formal/pmp_formal_if.sv"))
$(eval $(call XLEN_TEST,hum-request-stage,tb_hum_request_stage,,-d RAPT_ASSERT_EN))
$(eval $(call XLEN_TEST,ioq-mmio-retry,tb_mmio_load_retry,,-d RAPT_ASSERT_EN))
$(eval $(call XLEN_TEST,translated-mmio-retry,tb_translated_mmio_retry,,-d RAPT_ASSERT_EN))
$(eval $(call XLEN_TEST,l1d-mmio-retry-wb,tb_l1d_mmio_retry_wb,,-d RAPT_ASSERT_EN))
$(eval $(call XLEN_TEST,split-load-retry,tb_split_load_retry,,-d RAPT_ASSERT_EN))
$(eval $(call XLEN_TEST,ioq-store-pbmt,tb_ioq_store_pbmt,,-d RAPT_ASSERT_EN))
$(eval $(call XLEN_TEST,sq-store-pbmt,tb_sq_store_pbmt,,-d RAPT_ASSERT_EN))
$(eval $(call XLEN_TEST,l1d-store-pbmt,tb_l1d_store_pbmt,,-d RAPT_ASSERT_EN))
# Registered SQ drain view and early L1D SRAM addressing.
$(eval $(call XLEN_TEST,sq-registered-drain,tb_registered_store_drain,,-d RAPT_ASSERT_EN))
$(eval $(call XLEN_TEST,l1d-registered-store-path,tb_registered_store_path,,-d RAPT_ASSERT_EN))
$(eval $(call XLEN_TEST,l1d-registered-sram-address,tb_registered_sram_address))
# C1: registered retirement-window and SQ-empty equivalence assertions.
$(eval $(call XLEN_TEST,c1-head-flags,tb_rou_dual_commit,,-d RAPT_ASSERT_EN))
$(eval $(call XLEN_TEST,c1-sq-empty,tb_registered_store_drain,,-d RAPT_ASSERT_EN))
# C1 end
$(eval $(call XLEN_TEST,clint-strobe,tb_clint_strobe))
$(eval $(call XLEN_TEST,router-clint-strobe,tb_router_clint_strobe,,-d RAPT_ASSERT_EN))
$(eval $(call XLEN_TEST,lsu-split-fault,tb_lsu_split_fault,,-d RAPT_ASSERT_EN))
$(eval $(call XLEN_TEST,ioq-store-snapshot,tb_ioq_store_translation_snapshot,,-d RAPT_ASSERT_EN))
$(eval $(call XLEN_TEST,ioq-store-stage,tb_ioq_store_stage,,-d RAPT_ASSERT_EN))
$(eval $(call XLEN_TEST,ioq-mem-context,tb_ioq_mem_context,,-d RAPT_ASSERT_EN))
$(eval $(call XLEN_TEST,lsu-mem-context,tb_lsu_mem_context,,-d RAPT_ASSERT_EN))
$(eval $(call XLEN_TEST,ioq-readonly-pma,tb_ioq_readonly_pma,,-d RAPT_ASSERT_EN))
$(eval $(call XLEN_TEST,ioq-amo-fault,tb_ioq_amo_fault,,-d RAPT_ASSERT_EN))
$(eval $(call XLEN_TEST,ioq-amo-registered,tb_ioq_amo_registered,,-d RAPT_ASSERT_EN))
$(eval $(call XLEN_TEST,bus-pbmt,tb_bus_pbmt,,-d RAPT_ASSERT_EN))
$(eval $(call XLEN_TEST,l1d-ptw-pma,tb_l1d_ptw_pma,,-d RAPT_ASSERT_EN))
$(eval $(call XLEN_TEST,ifetch-word,tb_ifetch_word))
$(eval $(call XLEN_TEST,ifetch-translate,tb_ifetch_translate))
$(eval $(call XLEN_TEST,data-page-permissions,tb_data_page_permissions))
$(eval $(call XLEN_TEST,ptw-pmp-span,tb_ptw_pmp_span))
$(eval $(call XLEN_TEST,l1i-word-path,tb_l1i_word_path,,-d RAPT_ASSERT_EN))
$(eval $(call XLEN_TEST,ifetch-io-guard,tb_ifetch_io_guard,,-d RAPT_ASSERT_EN))
$(eval $(call XLEN_TEST,ioq-atomic-pma,tb_ioq_atomic_pma,,-d RAPT_ASSERT_EN))
$(eval $(call XLEN_TEST,l1d-lr-pma,tb_l1d_pma,,-d RAPT_ASSERT_EN))
$(eval $(call XLEN_TEST,ioq-zero-pma,tb_ioq_zero_pma,,-d RAPT_ASSERT_EN))
$(eval $(call XLEN_TEST,l1d-sram-pma,tb_l1d_pma,,-d RAPT_ASSERT_EN,+SRAM))
$(eval $(call XLEN_TEST,ioq-data-span,tb_ioq_data_span,,-d RAPT_ASSERT_EN))
$(eval $(call XLEN_TEST,l1d-read-error,tb_l1d_read_error,,-d RAPT_ASSERT_EN))
$(eval $(call XLEN_TEST,l1d-ptw-error,tb_l1d_ptw_error,,-d RAPT_ASSERT_EN))
$(eval $(call XLEN_TEST,l1d-ptw-axi-error,tb_l1d_ptw_axi_error,,-d RAPT_ASSERT_EN))
$(eval $(call XLEN_TEST,l1d-write-error,tb_l1d_write_error,,-d RAPT_ASSERT_EN))
$(eval $(call XLEN_TEST,sq-write-error,tb_sq_write_error,,-d RAPT_ASSERT_EN))
$(eval $(call XLEN_TEST,csr-bus-error,tb_csr_bus_error,,-d RAPT_ASSERT_EN))
$(eval $(call XLEN_TEST,lsu-hum-pmp,tb_lsu_hum_pmp,,-d RAPT_ASSERT_EN))
$(eval $(call XLEN_TEST,fp-registers,tb_fp_registers,,-d RAPT_ASSERT_EN))
$(eval $(call XLEN_TEST,ioq-fp-ooo,tb_ioq_fp_ooo,,-d RAPT_ASSERT_EN))
$(eval $(call XLEN_TEST,feu-ooo,tb_feu_ooo,,-d RAPT_ASSERT_EN))
$(eval $(call XLEN_TEST,csr-pmp-warl,tb_csr_pmp_warl))
$(eval $(call XLEN_TEST,l1d-reservation-external,tb_l1d_reservation_external,,-d RAPT_ASSERT_EN))
$(eval $(call XLEN_TEST,ioq-sc-external,tb_ioq_sc_external,,-d RAPT_ASSERT_EN))
$(eval $(call XLEN_TEST,ioq-completion-kill,tb_ioq_completion_kill,,-d RAPT_ASSERT_EN))
$(eval $(call XLEN_TEST,lsu-forward-cancel,tb_lsu_forward_cancel,,-d RAPT_ASSERT_EN))
$(eval $(call XLEN_TEST,ioq-reservation-extent,tb_ioq_reservation_extent,,-d RAPT_ASSERT_EN))
$(eval $(call XLEN_TEST,lsu-lr-alignment,tb_lsu_lr_alignment,,-d RAPT_ASSERT_EN))
$(eval $(call XLEN_TEST,ioq-acquire-publish,tb_ioq_acquire_publish,,-d RAPT_ASSERT_EN,$$(IOQ_ACQUIRE_PLUSARGS)))
$(eval $(call XLEN_TEST,ioq-early-load-bcast,tb_ioq_early_load_bcast,,-d RAPT_ASSERT_EN))
$(eval $(call XLEN_TEST,ioq-b-wake-alias,tb_ioq_b_wake_alias,,-d RAPT_ASSERT_EN))
$(eval $(call XLEN_TEST,lsu-atomic-release,tb_lsu_atomic_release,,-d RAPT_ASSERT_EN))
$(eval $(call XLEN_TEST,ioq-atomic-release,tb_ioq_atomic_release,,-d RAPT_ASSERT_EN))
$(eval $(call XLEN_TEST,ioq-amo-acquire-publish,tb_ioq_acquire_publish,,-d RAPT_ASSERT_EN,+AMO $$(IOQ_ACQUIRE_PLUSARGS)))
$(eval $(call XLEN_TEST,atomic-replay,tb_rou_dual_commit, ,-d RAPT_ASSERT_EN -d RAPT_TEST_ATOMIC_REPLAY))
$(eval $(call XLEN_TEST,lsu-atomic-acquire,tb_lsu_atomic_acquire,,-d RAPT_ASSERT_EN))
$(eval $(call XLEN_TEST,fence-replay,tb_rou_dual_commit, ,-d RAPT_ASSERT_EN -d RAPT_TEST_ATOMIC_REPLAY -d RAPT_TEST_FENCE_REPLAY -d RAPT_TEST_REGISTERED_DRAIN -d RAPT_TEST_COMPACT_FP -d RAPT_TEST_REGISTERED_PAYLOAD))
$(eval $(call XLEN_TEST,lsu-axi-io-order,tb_lsu_axi_io_order,,-d RAPT_ASSERT_EN))
$(eval $(call XLEN_TEST,l1i-invalidate-pending,tb_l1i_invalidate_pending,,-d RAPT_ASSERT_EN))
$(eval $(call XLEN_TEST,l1i-response-error,tb_l1i_response_error,,-d RAPT_ASSERT_EN,$$(L1I_ERROR_PLUSARGS)))
$(eval $(call XLEN_TEST,l1i-mapping-epoch,tb_l1i_mapping_epoch,,-d RAPT_ASSERT_EN))
$(eval $(call XLEN_TEST,idu-hints,tb_idu_hints))
$(eval $(call XLEN_TEST,sq-context,tb_sq_context,,-d RAPT_ASSERT_EN))
$(eval $(call XLEN_TEST,sq-branch-context,tb_sq_branch_context,,-d RAPT_ASSERT_EN -d RAPT_LSU_TB_CMU))
$(eval $(call XLEN_TEST,sq-atomic-context,tb_sq_atomic_context,,-d RAPT_ASSERT_EN -d RAPT_LSU_TB_CMU))
$(eval $(call XLEN_TEST,ioq-overlap,tb_ioq_overlap,,-d RAPT_ASSERT_EN))
$(eval $(call XLEN_TEST,lsu-load-footprint,tb_lsu_load_footprint,,-d RAPT_ASSERT_EN))
$(eval $(call XLEN_TEST,l1d-plic-width,tb_l1d_plic_width,,-d RAPT_ASSERT_EN))
$(eval $(call XLEN_TEST,l1d-load-footprint,tb_l1d_load_footprint,,-d RAPT_ASSERT_EN))
$(eval $(call XLEN_TEST,router-clint-width,tb_router_clint_width))
$(eval $(call XLEN_TEST,clint-csr-time,tb_clint_csr_time))
$(eval $(call XLEN_TEST,ioq-plic-width,tb_ioq_plic_width,,-d RAPT_ASSERT_EN))
$(eval $(call XLEN_TEST,router-clint-subword,tb_router_clint_subword,,-d RAPT_ASSERT_EN))
$(eval $(call XLEN_TEST,compressed-legality,tb_compressed_legality)) ## Check compressed register, immediate, HINT and MOP legality
$(eval $(call XLEN_TEST,ioq-dispatch-stable,tb_ioq_dispatch_stable,,-d RAPT_ASSERT_EN -d RAPT_IOQ_LOAD_RESPONSE_STAGE=0))
$(eval $(call XLEN_TEST,mshr-fill-selection,tb_mshr_fill_selection,,-d RAPT_ASSERT_EN)) ## Compare refill selection with exclusive line invalidation
$(eval $(call XLEN_TEST,l2tlb,tb_l2tlb))
$(eval $(call XLEN_TEST,cached-ptw,tb_cached_ptw))
$(eval $(call XLEN_TEST,l2tlb-l1i-epoch,tb_l1i_mapping_epoch,,-d RAPT_ASSERT_EN))
$(eval $(call XLEN_TEST,l2tlb-l1i-sret,tb_l1i_sret_priv_epoch,,-d RAPT_ASSERT_EN))
$(eval $(call XLEN_TEST,l2tlb-cbo,tb_cbo_tlb,,-d RAPT_ASSERT_EN))
$(eval $(call XLEN_TEST,wb-mshr,tb_wb_mshr,,-d RAPT_ASSERT_EN -d RAPT_L1D_MSHRS=4))
$(eval $(call XLEN_TEST,wb-mshr-l2,tb_cache_stream,,-d RAPT_ASSERT_EN,+WB_MSHR_L2))
$(eval $(call XLEN_TEST,mshr-ioq-translated,tb_mshr_ioq,,-d RAPT_ASSERT_EN -GMmu=1))
$(eval $(call XLEN_TEST,fp-arch-bank,tb_fp_arch_bank,,-d RAPT_ASSERT_EN -d RAPT_FPGA_LUTRAM=$$(FP_ARCH_BANK_LUTRAM)))
$(eval $(call XLEN_TEST,ioq-paddr-preload,tb_ioq_paddr_preload,,-d RAPT_ASSERT_EN))
$(eval $(call XLEN_TEST,fp-registers-compact,tb_fp_registers,,-d RAPT_ASSERT_EN -d RAPT_TEST_COMPACT_FP)) ## Exercise physical FP source-slot ownership and wake/reuse
$(eval $(call XLEN_TEST,rou-fp-compact,tb_rou_dual_commit,,-d RAPT_ASSERT_EN -d RAPT_TEST_COMPACT_FP -d RAPT_TEST_REGISTERED_DRAIN -d RAPT_TEST_FP_OOO -d RAPT_TEST_FP_IRQ_COMPOSE -d RAPT_TEST_REGISTERED_PAYLOAD)) ## Exercise compact FP sources with the real FEU and accepted wake fabric
$(eval $(call XLEN_TEST,l1d-ptw-permission-stage,tb_l1d_ptw_permission_stage,,-d RAPT_ASSERT_EN)) ## Exercise held PTW permission across backpressure and cancellation
$(eval $(call XLEN_TEST,l1d-ptw-permission-l2tlb,tb_l1d_ptw_permission_stage,,-d RAPT_ASSERT_EN -d RAPT_TEST_PTW_L2TLB)) ## Exercise the permission boundary with the shared L2 TLB
$(eval $(call XLEN_TEST,rou-payload-boundary,tb_rou_dual_commit,,-d RAPT_ASSERT_EN -d RAPT_TEST_REGISTERED_DRAIN -d RAPT_TEST_COMPACT_FP -d RAPT_TEST_REGISTERED_PAYLOAD -d RAPT_TEST_PAYLOAD_BOUNDARY)) ## Check registered immutable dispatch ownership and full-width throughput
$(eval $(call XLEN_TEST,iq-local-wake,tb_iq_local_wake,,-d RAPT_ASSERT_EN)) ## Check local integer capture and delayed global owner handoff
$(eval $(call XLEN_TEST,iq-local-load-wake,tb_iq_local_wake,,-d RAPT_ASSERT_EN -d RAPT_TEST_LOCAL_MEMORY_WAKE)) ## Check local load capture without combinational issue wake
$(eval $(call XLEN_TEST,rou-fp-irq-compact,tb_rou_dual_commit,,-d RAPT_ASSERT_EN -d RAPT_TEST_REGISTERED_DRAIN -d RAPT_TEST_COMPACT_FP -d RAPT_TEST_REGISTERED_PAYLOAD -d RAPT_TEST_FP_IRQ_BOUNDARY -d RAPT_TEST_FP_IRQ_COMPOSE)) ## Check empty-ROB IRQ with compact FP and registered payload

# Explicit names and flags preserve the older build stems and parameter matrices.
$(eval $(call DIRECTED_TEST,alu-zbb-strlen,alu_zbb_strlen,tb_alu_zbb_strlen,,-d RAPT_RV64))
$(eval $(call DIRECTED_TEST,alu-cpop,alu_cpop,tb_alu_cpop))
$(eval $(call DIRECTED_TEST,alu-clmul-rv32 alu-clmul-rv64,$$(subst -,_,$$@),tb_alu_clmul,,$$(if $$(findstring rv64,$$@),-d RAPT_RV64)))
$(eval $(call DIRECTED_TEST,l2,l2,tb_l2_ordered_mmio,,-d RAPT_L2_EN))
$(eval $(call DIRECTED_TEST,l2-pmem2g,l2_pmem2g,tb_l2_ordered_mmio,,-d RAPT_L2_EN -d RAPT_PMEM_BYTES=2147483648))
$(eval $(call DIRECTED_TEST,l2-assoc-rv32 l2-assoc-rv64,$$(subst -,_,$$@),tb_l2_assoc,,$$(if $$(findstring rv64,$$@),-d RAPT_RV64) -d RAPT_L2_EN))
$(eval $(call DIRECTED_TEST,l2-line-local-put-rv32 l2-line-local-put-rv64,$$(subst -,_,$$@),tb_l2_line_local_put,,$$(if $$(findstring rv64,$$@),-d RAPT_RV64) -d RAPT_L2_EN))
$(eval $(call DIRECTED_TEST,l2-cross-line-put-rv32 l2-cross-line-put-rv64,$$(subst -,_,$$@),tb_l2_cross_line_put,,$$(if $$(findstring rv64,$$@),-d RAPT_RV64) -d RAPT_L2_EN))
$(eval $(call DIRECTED_TEST,l2-forwarded-error-rv32 l2-forwarded-error-rv64,$$(subst -,_,$$@),tb_l2_forwarded_error,,$$(if $$(findstring rv64,$$@),-d RAPT_RV64) -d RAPT_L2_EN -d RAPT_ASSERT_EN))
$(eval $(call DIRECTED_TEST,l2-forwarded-client-rv32 l2-forwarded-client-rv64,$$(subst -,_,$$@),tb_l2_forwarded_client,,$$(if $$(findstring rv64,$$@),-d RAPT_RV64) -d RAPT_L2_EN -d RAPT_ASSERT_EN))
$(eval $(call DIRECTED_TEST,axi-r-buffer-rv32 axi-r-buffer-rv64,$$(subst -,_,$$@),tb_axi_r_buffer,,$$(if $$(findstring rv64,$$@),-d RAPT_RV64)))
$(eval $(call DIRECTED_TEST,l2-put-buffer-rv32 l2-put-buffer-rv64,$$(subst -,_,$$@),tb_l2_put_buffer,,$$(if $$(findstring rv64,$$@),-d RAPT_RV64) -d RAPT_L2_EN))
$(eval $(call DIRECTED_TEST,l2-put-list-rv32 l2-put-list-rv64,$$(subst -,_,$$@),tb_l2_put_list_buffer,,$$(if $$(findstring rv64,$$@),-d RAPT_RV64)))
$(eval $(call DIRECTED_TEST,l2-secondary-buffer,l2_secondary_buffer,tb_l2_secondary_buffer))
$(eval $(call DIRECTED_TEST,l2-secondary-buffer-rv32,l2_secondary_buffer_rv32,tb_l2_secondary_buffer,,-d RAPT_L2_RV32_GEOMETRY))
$(eval $(call DIRECTED_TEST,l2-release-buffer-rv32 l2-release-buffer-rv64,$$(subst -,_,$$@),tb_l2_release_buffer,,$$(if $$(findstring rv64,$$@),-d RAPT_RV64)))
$(eval $(call DIRECTED_TEST,l2-release-admission-rv32 l2-release-admission-rv64,$$(subst -,_,$$@),tb_l2_release_admission,,$$(if $$(findstring rv64,$$@),-d RAPT_RV64) -d RAPT_L2_EN))
$(eval $(call DIRECTED_TEST,l2-release-probe-rv32 l2-release-probe-rv64,$$(subst -,_,$$@),tb_l2_release_probe,,$$(if $$(findstring rv64,$$@),-d RAPT_RV64) -d RAPT_L2_EN))
$(eval $(call DIRECTED_TEST,l2-owned-read-rv32 l2-owned-read-rv64,$$(subst -,_,$$@),tb_l2_owned_read,,$$(if $$(findstring rv64,$$@),-d RAPT_RV64) -d RAPT_L2_EN))
$(eval $(call DIRECTED_TEST,l2-mshr-scheduler,l2_mshr_scheduler,tb_l2_mshr_scheduler))
$(eval $(call DIRECTED_TEST,l2-mshr-frontend,l2_mshr_frontend,tb_l2_mshr_frontend))
$(eval $(call DIRECTED_TEST,l2-refill-mshrs-rv32 l2-refill-mshrs-rv64,$$(subst -,_,$$@),tb_l2_refill_mshrs,,$$(if $$(findstring rv32,$$@),-GXLEN=32,)))
$(eval $(call DIRECTED_TEST,l2-mshr-concurrent-rv32 l2-mshr-concurrent-rv64,$$(subst -,_,$$@),tb_l2_mshr_concurrent,,$$(if $$(findstring rv64,$$@),-d RAPT_RV64) -d RAPT_L2_EN))
$(eval $(call DIRECTED_TEST,l2-mshr-different-tag-rv32 l2-mshr-different-tag-rv64,$$(subst -,_,$$@),tb_l2_mshr_different_tag,,$$(if $$(findstring rv64,$$@),-d RAPT_RV64) -d RAPT_L2_EN))
$(eval $(call DIRECTED_TEST,l2-adapter-write-rv32 l2-adapter-write-rv64,$$(subst -,_,$$@),tb_l2_adapter_write_allocate,,$$(if $$(findstring rv64,$$@),-d RAPT_RV64) -d RAPT_L2_EN))
$(eval $(call DIRECTED_TEST,l2-data-array,l2_data_array,tb_l2_data_array))
$(eval $(call DIRECTED_TEST,l2-directory,l2_directory,tb_l2_directory))
$(eval $(call DIRECTED_TEST,l2-directory-oneway,l2_directory_oneway,tb_l2_directory_oneway))
$(eval $(call DIRECTED_TEST,cache-replacement,cache_replacement,tb_cache_replacement))
$(eval $(call DIRECTED_TEST,l1d-replacement,l1d_replacement,tb_l1d_replacement))
$(eval $(call DIRECTED_TEST,l1i-width-window-4way,l1i_width_window_4way,tb_l1i_width_window,,-d RAPT_ASSERT_EN))
$(eval $(call DIRECTED_TEST,l1i-width-window-8way,l1i_width_window_8way,tb_l1i_width_window,,-d RAPT_ASSERT_EN))
$(eval $(call DIRECTED_TEST,sq-forward-ports,sq_forward_ports,tb_sq_forward_ports))
$(eval $(call DIRECTED_TEST,sq-forward-ports-rv64,sq_forward_ports_rv64,tb_sq_forward_ports,,-d RAPT_RV64))
$(eval $(call DIRECTED_TEST,sq-forward-ring-rv32 sq-forward-ring-rv64,$$(subst -,_,$$@),tb_store_queue_forward_ring,,$$(if $$(findstring rv64,$$@),-d RAPT_RV64)))
$(eval $(call DIRECTED_TEST,l1d-data,l1d_data,tb_l1d_data))
$(eval $(call DIRECTED_TEST,l1d-writeback,l1d_writeback,tb_writeback))
$(eval $(call DIRECTED_TEST,l1d-tags,l1d_tags,tb_l1d_tags))
$(eval $(call DIRECTED_TEST,l1d-byte-rom,l1d_byte_rom,tb_l1d_byte_rom))
$(eval $(call DIRECTED_TEST,l1d-store-coherence,l1d_store_coherence,tb_l1d_store_coherence,,,+BUS_DELAY_MAX=$$(VERILATOR_DIRECTED_DELAY) +SEED=$$(VERILATOR_DIRECTED_SEED)))
$(eval $(call DIRECTED_TEST,l1d-writeback-rv32 l1d-writeback-rv64,$$(subst -,_,$$@),tb_l1d_store_coherence,,$$(if $$(findstring rv64,$$@),-d RAPT_RV64),+BUS_DELAY_MAX=$$(VERILATOR_DIRECTED_DELAY) +SEED=$$(VERILATOR_DIRECTED_SEED)))
$(eval $(call DIRECTED_TEST,l1d-writeback-line-rv32 l1d-writeback-line-rv64,$$(subst -,_,$$@),tb_l1d_store_coherence,,$$(if $$(findstring rv64,$$@),-d RAPT_RV64),+BUS_DELAY_MAX=$$(VERILATOR_DIRECTED_DELAY) +SEED=$$(VERILATOR_DIRECTED_SEED)))
# Final refill tag installation must precede a nonposted store response.
$(eval $(call DIRECTED_TEST,l1d-refill-store-rv32 l1d-refill-store-rv64,$$(subst -,_,$$@),tb_l1d_store_coherence,,$$(if $$(findstring rv64,$$@),-d RAPT_RV64),+MIN_REFILL_STORE +BUS_DELAY_MAX=0))
$(eval $(call DIRECTED_TEST,l1d-writeback-bscan-rv64,l1d_writeback_bscan_rv64,tb_l1d_store_coherence,,-d RAPT_RV64,+MIN_WB_B $$(if $$(filter 1,$$(L1D_BSCAN_TRACE)),+TRACE_WB_B +WAVE_FILE=$$(VERILATOR_DIRECTED_BUILD_DIR)/l1d_writeback_bscan_rv64/wave.vcd,)))
$(eval $(call DIRECTED_TEST,l1d-flush-ordered,l1d_flush_ordered,tb_l1d_flush_ordered,,-d RAPT_ASSERT_EN))
$(eval $(call DIRECTED_TEST,l1d-cmo-permissions,l1d_cmo_permissions,tb_l1d_cmo_permissions,,-d RAPT_RV64 -d RAPT_ASSERT_EN))
$(eval $(call DIRECTED_TEST,cbo-set-rv32 cbo-set-rv64,$$(subst -,_,$$@),tb_cbo_set,,-d RAPT_ASSERT_EN $$(if $$(findstring rv64,$$@),-d RAPT_RV64)))
$(eval $(call DIRECTED_TEST,cbo-tlb-rv32 cbo-tlb-rv64,$$(subst -,_,$$@),tb_cbo_tlb,,-d RAPT_ASSERT_EN $$(if $$(findstring rv64,$$@),-d RAPT_RV64)))
$(eval $(call DIRECTED_TEST,l1i-sret-priv-epoch,l1i_sret_priv_epoch,tb_l1i_sret_priv_epoch,,-d RAPT_ASSERT_EN))
$(eval $(call DIRECTED_TEST,l1i-zero-va,l1i_zero_va,tb_l1i_sret_priv_epoch,,-d RAPT_ASSERT_EN -d RAPT_TEST_ZERO_PC))
$(eval $(call DIRECTED_TEST,l1i-zero-va-rv64,l1i_zero_va_rv64,tb_l1i_sret_priv_epoch,,-d RAPT_ASSERT_EN -d RAPT_TEST_ZERO_PC -d RAPT_RV64))
$(eval $(call DIRECTED_TEST,l1i-sret-priv-epoch-rv64,l1i_sret_priv_epoch_rv64,tb_l1i_sret_priv_epoch,,-d RAPT_ASSERT_EN -d RAPT_RV64))
$(eval $(call DIRECTED_TEST,ptw-kill-drain,ptw_kill_drain,tb_ptw_kill_drain,,-d RAPT_ASSERT_EN))
$(eval $(call DIRECTED_TEST,ptw-profile-negative,ptw_profile_negative,tb_ptw_profile_negative,,-d RAPT_RV64 -d RAPT_ASSERT_EN))
$(eval $(call DIRECTED_TEST,ptw-pbmt,ptw_pbmt,tb_ptw_pbmt,,-d RAPT_RV64 -d RAPT_ASSERT_EN))
$(eval $(call DIRECTED_TEST,idu-illegal-stval,idu_illegal_stval,tb_idu_illegal_stval,,-d RAPT_RV64 -d RAPT_ASSERT_EN))
$(eval $(call DIRECTED_TEST,idu-zfhmin,idu_zfhmin,tb_idu_zfhmin,,-d RAPT_RV64 -d RAPT_ASSERT_EN))
$(eval $(call DIRECTED_TEST,idu-cmo,idu_cmo,tb_idu_cmo,,-d RAPT_RV64 -d RAPT_ASSERT_EN))
$(eval $(call DIRECTED_TEST,tlb-flush-asid-rv64,tlb_flush_asid_rv64,tb_tlb_flush_asid,,-d RAPT_RV64 -d RAPT_ASSERT_EN))
$(eval $(call DIRECTED_TEST,tlb-flush-asid,tlb_flush_asid,tb_tlb_flush_asid,,-d RAPT_ASSERT_EN))
$(eval $(call DIRECTED_TEST,bus-axi,bus_axi,tb_bus_l1d_rlast))
$(eval $(call DIRECTED_TEST,axi-storage-rv32 axi-storage-rv64 axi-storage-synthesis-rv32 axi-storage-synthesis-rv64,$$(subst -,_,$$@),tb_axi_master_storage,,-d RAPT_ASSERT_EN $$(if $$(findstring rv64,$$@),-d RAPT_RV64) $$(if $$(findstring synthesis,$$@),-d SYNTHESIS)))
$(eval $(call DIRECTED_TEST,axi-write-lanes-rv32 axi-write-lanes-rv64,$$(subst -,_,$$@),tb_axi_write_lanes,,-d RAPT_ASSERT_EN $$(if $$(findstring rv64,$$@),-d RAPT_RV64)))
$(eval $(call DIRECTED_TEST,bus-read-ownership,bus_read_ownership,tb_bus_read_ownership))
$(eval $(call DIRECTED_TEST,bus-read-ownership-rv32 bus-read-ownership-rv64,$$(subst -,_,$$@),tb_bus_read_ownership,,-d RAPT_ASSERT_EN $$(if $$(findstring rv64,$$@),-d RAPT_RV64)))
$(eval $(call DIRECTED_TEST,fpr-payload-reset-rv32 fpr-payload-reset-rv64,$$(subst -,_,$$@),tb_fpr_payload_reset,,$$(if $$(findstring rv64,$$@),-d RAPT_RV64)))
$(eval $(call DIRECTED_TEST,csr-trap-payload-rv32 csr-trap-payload-rv64,$$(subst -,_,$$@),tb_csr_trap_payload,,$$(if $$(findstring rv64,$$@),-d RAPT_RV64)))
$(eval $(call DIRECTED_TEST,addr-classification-rv32,addr_classification_rv32,tb_addr_classification))
$(eval $(call DIRECTED_TEST,addr-classification,addr_classification,tb_addr_classification,,-d RAPT_RV64))
$(eval $(call DIRECTED_TEST,pmp-endpoint,pmp_endpoint,tb_pmp_endpoint))
$(eval $(call DIRECTED_TEST,pmp-permissions-rv32 pmp-permissions-rv64,$$(subst -,_,$$@),tb_pmp_permissions,,$$(if $$(findstring rv64,$$@),-d RAPT_RV64)))
$(eval $(call DIRECTED_TEST,l1d-pmp-shared-rv32 l1d-pmp-shared-rv64,$$(subst -,_,$$@),tb_l1d_pmp_shared,,$$(if $$(findstring rv64,$$@),-d RAPT_RV64)))
$(eval $(call DIRECTED_TEST,lsu-lr-sq-forward,lsu_lr_sq_forward,tb_lsu_lr_sq_forward,,-d RAPT_ASSERT_EN))
$(eval $(call DIRECTED_TEST,lsu-cbo-zero,lsu_cbo_zero,tb_lsu_cbo_zero,,-d RAPT_RV64 -d RAPT_ASSERT_EN))
$(eval $(call DIRECTED_TEST,lsu-sq-random,lsu_sq_random,tb_lsu_sq_random,,-d RAPT_ASSERT_EN,+SEED=$$(VERILATOR_DIRECTED_SEED)))
$(eval $(call DIRECTED_TEST,ioq,ioq,tb_ioq_pending_lock))
$(eval $(call DIRECTED_TEST,split-load-fault-reset-rv32 split-load-fault-reset-rv64,$$(subst -,_,$$@),tb_split_load_fault_reset,,-d RAPT_ASSERT_EN $$(if $$(findstring rv64,$$@),-d RAPT_RV64)))
$(eval $(call DIRECTED_TEST,clint,clint,tb_clint))
$(eval $(call DIRECTED_TEST,plic-gateway,plic_gateway,tb_plic_gateway))
$(eval $(call DIRECTED_TEST,muldiv-flush-reuse,muldiv_flush_reuse,tb_muldiv_flush_reuse,,-d RAPT_ASSERT_EN))
$(eval $(call DIRECTED_TEST,muldiv-word-rv64,muldiv_word_rv64,tb_muldiv_flush_reuse,,-d RAPT_RV64 -d RAPT_ASSERT_EN))
$(eval $(call DIRECTED_TEST,mdq-zkt-rv32 mdq-zkt-rv64,$$(subst -,_,$$@),tb_muldiv_flush_reuse,,-d RAPT_ASSERT_EN -GCheckOperandIndependence=1 $$(if $$(findstring rv64,$$@),-d RAPT_RV64)))
$(eval $(call DIRECTED_TEST,mdq-selective-recovery-rv32 mdq-selective-recovery-rv64,$$(subst -,_,$$@),tb_mdq_selective_recovery,,-d RAPT_ASSERT_EN $$(if $$(findstring rv64,$$@),-d RAPT_RV64)))
$(eval $(call DIRECTED_TEST,muldiv-stream muldiv-stream-rv64,$$(subst -,_,$$@),tb_muldiv_stream,,$$(if $$(findstring rv64,$$@),-d RAPT_RV64)))
$(eval $(call DIRECTED_TEST,muldiv-fpga-rv32 muldiv-fpga-rv64,$$(subst -,_,$$@),tb_muldiv_fpga,,$$(if $$(findstring rv64,$$@),-d RAPT_RV64)))
$(eval $(call DIRECTED_TEST,div-iterations div-iterations-rv64,$$(subst -,_,$$@),tb_div_word_iterations,,$$(if $$(findstring rv64,$$@),-d RAPT_RV64)))
$(eval $(call DIRECTED_TEST,rou-dual-commit,rou_dual_commit,tb_rou_dual_commit,,-d RAPT_ASSERT_EN))
$(eval $(call DIRECTED_TEST,rou-exception-rd-rv32 rou-exception-rd-rv64,$$(subst -,_,$$@),tb_rou_dual_commit,,-d RAPT_ASSERT_EN -d RAPT_TEST_EXCEPTION_RD $$(if $$(findstring rv64,$$@),-d RAPT_RV64)))
$(eval $(call DIRECTED_TEST,rou-zkt-rv32 rou-zkt-rv64,$$(subst -,_,$$@),tb_rou_dual_commit,,-d RAPT_ASSERT_EN -GCheckOperandIndependence=1 $$(if $$(findstring rv64,$$@),-d RAPT_RV64)))
$(eval $(call DIRECTED_TEST,rou-fence-commit-rv32 rou-fence-commit-rv64,$$(subst -,_,$$@),tb_rou_dual_commit,,-d RAPT_ASSERT_EN -d RAPT_TEST_FENCE_COMMIT $$(if $$(findstring rv64,$$@),-d RAPT_RV64)))
$(eval $(call DIRECTED_TEST,rou-dual-commit-rv64,rou_dual_commit_rv64,tb_rou_dual_commit,,-d RAPT_RV64 -d RAPT_ASSERT_EN))
$(eval $(call DIRECTED_TEST,rou-rvfi,rou_rvfi,tb_rou_dual_commit,,-d RAPT_RVFI -d RAPT_ASSERT_EN))
$(eval $(call DIRECTED_TEST,rou-rvfi-rv64,rou_rvfi_rv64,tb_rou_dual_commit,,-d RAPT_RVFI -d RAPT_RV64 -d RAPT_ASSERT_EN))
$(eval $(call DIRECTED_TEST,lsu-store-observation,lsu_store_observation,tb_lsu_store_observation,,-d RAPT_ASSERT_EN))
$(eval $(call DIRECTED_TEST,lsu-store-observation-rv64,lsu_store_observation_rv64,tb_lsu_store_observation,,-d RAPT_RV64 -d RAPT_ASSERT_EN))
$(eval $(call DIRECTED_TEST,backend-extensibility,backend_extensibility,tb_backend_extensibility,,-d RAPT_ASSERT_EN))
$(eval $(call DIRECTED_TEST,backend-recovery,backend_recovery,tb_backend_extensibility,,-d RAPT_ASSERT_EN))
$(eval $(call DIRECTED_TEST,backend-recovery-rv64,backend_recovery_rv64,tb_backend_extensibility,,-d RAPT_ASSERT_EN))
$(eval $(call DIRECTED_TEST,iq-type-family,iq_type_family,tb_iq_type_family,,-d RAPT_ASSERT_EN))
$(eval $(call DIRECTED_TEST,width-1 width-2 width-3 width-4,width_$$(lastword $$(subst -, ,$$@)),tb_superscalar_widths,,-d RAPT_ASSERT_EN -d RAPT_DECODE_WIDTH=$$(lastword $$(subst -, ,$$@)) -d RAPT_RENAME_WIDTH=$$(lastword $$(subst -, ,$$@)) -d RAPT_DISPATCH_WIDTH=$$(lastword $$(subst -, ,$$@)) -d RAPT_COMMIT_WIDTH=$$(lastword $$(subst -, ,$$@))))
$(eval $(call DIRECTED_TEST,width-mixed,width_mixed,tb_superscalar_widths,,-d RAPT_ASSERT_EN -d RAPT_DECODE_WIDTH=3 -d RAPT_RENAME_WIDTH=4 -d RAPT_DISPATCH_WIDTH=3 -d RAPT_COMMIT_WIDTH=4))
$(eval $(call DIRECTED_TEST,width-mixed-rv64,width_mixed_rv64,tb_superscalar_widths,,-d RAPT_ASSERT_EN -d RAPT_RV64 -d RAPT_DECODE_WIDTH=3 -d RAPT_RENAME_WIDTH=4 -d RAPT_DISPATCH_WIDTH=3 -d RAPT_COMMIT_WIDTH=4))
$(eval $(call DIRECTED_TEST,width-contract,width_contract,tb_superscalar_widths,,-d RAPT_ASSERT_EN -d RAPT_DECODE_WIDTH=4 -d RAPT_RENAME_WIDTH=1 -d RAPT_DISPATCH_WIDTH=2 -d RAPT_COMMIT_WIDTH=3))
$(eval $(call DIRECTED_TEST,width-odd,width_odd,tb_superscalar_widths,,-d RAPT_ASSERT_EN -d RAPT_TEST_ODD_DEPTHS -d RAPT_DECODE_WIDTH=4 -d RAPT_RENAME_WIDTH=3 -d RAPT_DISPATCH_WIDTH=1 -d RAPT_COMMIT_WIDTH=2))
$(eval $(call DIRECTED_TEST,stream-queue,stream_queue,tb_stream_queue,,-d RAPT_ASSERT_EN))
$(eval $(call DIRECTED_TEST,stream-queue-bram,stream_queue_bram,tb_stream_queue,,-d RAPT_ASSERT_EN -d RAPT_FPGA_STREAM_BRAM=1))
$(eval $(call DIRECTED_TEST,stream-queue-lutram,stream_queue_lutram,tb_stream_queue,,-d RAPT_ASSERT_EN -d RAPT_FPGA_LUTRAM=1))
$(eval $(call DIRECTED_TEST,stream-queue-sweep,stream_queue_sweep,tb_stream_queue,,-d RAPT_ASSERT_EN -GSweepDepth=5))
$(eval $(call DIRECTED_TEST,rename-checkpoint,rename_checkpoint,tb_rename_checkpoint,,-d RAPT_ASSERT_EN))
$(eval $(call DIRECTED_TEST,rename-checkpoint-pipeline,rename_checkpoint_pipeline,tb_rename_checkpoint_pipeline,,-d RAPT_ASSERT_EN -d RAPT_DECODE_WIDTH=2 -d RAPT_RENAME_WIDTH=2 -d RAPT_COMMIT_WIDTH=2 -d RAPT_BRANCH_CHECKPOINTS=2))
$(eval $(call DIRECTED_TEST,rename-checkpoint-pipeline-rv64,rename_checkpoint_pipeline_rv64,tb_rename_checkpoint_pipeline,,-d RAPT_ASSERT_EN -d RAPT_RV64 -d RAPT_DECODE_WIDTH=2 -d RAPT_RENAME_WIDTH=2 -d RAPT_COMMIT_WIDTH=2 -d RAPT_BRANCH_CHECKPOINTS=2))
$(eval $(call DIRECTED_TEST,rename-width-recovery,rename_width_recovery,tb_rename_width_recovery,,-d RAPT_ASSERT_EN -d RAPT_DECODE_WIDTH=4 -d RAPT_RENAME_WIDTH=4 -d RAPT_COMMIT_WIDTH=4))
$(eval $(call DIRECTED_TEST,rename-width-recovery-bram-rv32 rename-width-recovery-bram-rv64,$$(subst -,_,$$@),tb_rename_width_recovery,,-d RAPT_ASSERT_EN -d RAPT_FPGA_STREAM_BRAM=1 -d RAPT_DECODE_WIDTH=4 -d RAPT_RENAME_WIDTH=4 -d RAPT_COMMIT_WIDTH=4 $$(if $$(findstring rv64,$$@),-d RAPT_RV64)))
$(eval $(call DIRECTED_TEST,l1i-width-window,l1i_width_window,tb_l1i_width_window,,-d RAPT_ASSERT_EN))
$(eval $(call DIRECTED_TEST,ifu-stream-events,ifu_stream_events,tb_ifu_stream_events,,-d RAPT_ASSERT_EN -d RAPT_DECODE_WIDTH=4))
$(eval $(call DIRECTED_TEST,ifu-stream-events-rv64,ifu_stream_events_rv64,tb_ifu_stream_events,,-d RAPT_ASSERT_EN -d RAPT_DECODE_WIDTH=4 -d RAPT_RV64))
$(eval $(call DIRECTED_TEST,ifu-wide-pack-rv32 ifu-wide-pack-rv64,$$(subst -,_,$$@),tb_ifu_wide_pack,,-d RAPT_ASSERT_EN $$(if $$(findstring rv64,$$@),-d RAPT_RV64)))
$(eval $(call DIRECTED_TEST,ifu-l1i-wide-rv32 ifu-l1i-wide-rv64,$$(subst -,_,$$@),tb_ifu_l1i_stream,,-d RAPT_ASSERT_EN -d RAPT_TEST_ALL_32 $$(if $$(findstring rv64,$$@),-d RAPT_RV64)))
$(eval $(call DIRECTED_TEST,ifu-response-stage-rv32 ifu-response-stage-rv64,$$(subst -,_,$$@),tb_ifu_response_stage,,-d RAPT_ASSERT_EN -d RAPT_FETCH_RESPONSE_STAGE=1 $$(if $$(findstring rv64,$$@),-d RAPT_RV64)))
$(eval $(call DIRECTED_TEST,frontend-recovery,frontend_recovery,tb_frontend_recovery,,-d RAPT_ASSERT_EN -d RAPT_DECODE_WIDTH=4))
$(eval $(call DIRECTED_TEST,rename-random,rename_random,tb_rename_random,,-d RAPT_ASSERT_EN -d RAPT_DECODE_WIDTH=4 -d RAPT_RENAME_WIDTH=3 -d RAPT_COMMIT_WIDTH=4,+SEED=$$(VERILATOR_DIRECTED_SEED)))
$(eval $(call DIRECTED_TEST,rename-random-bram-rv32 rename-random-bram-rv64,$$(subst -,_,$$@),tb_rename_random,,-d RAPT_ASSERT_EN -d RAPT_FPGA_STREAM_BRAM=1 -d RAPT_DECODE_WIDTH=4 -d RAPT_RENAME_WIDTH=4 -d RAPT_COMMIT_WIDTH=4 $$(if $$(findstring rv64,$$@),-d RAPT_RV64),+SEED=$$(VERILATOR_DIRECTED_SEED)))
$(eval $(call DIRECTED_TEST,rename-random-rv64,rename_random_rv64,tb_rename_random,,-d RAPT_ASSERT_EN -d RAPT_RV64 -d RAPT_DECODE_WIDTH=4 -d RAPT_RENAME_WIDTH=3 -d RAPT_COMMIT_WIDTH=4,+SEED=$$(VERILATOR_DIRECTED_SEED)))
$(eval $(call DIRECTED_TEST,rename-random-expand,rename_random_expand,tb_rename_random,,-d RAPT_ASSERT_EN -d RAPT_DECODE_WIDTH=2 -d RAPT_RENAME_WIDTH=4 -d RAPT_COMMIT_WIDTH=2,+SEED=$$(VERILATOR_DIRECTED_SEED)))
$(eval $(call DIRECTED_TEST,issue-select,issue_select,tb_issue_select, "$$(RAPTOR_HOME)/verification/formal/formal_issue_select.sv",,+SEED=$$(VERILATOR_DIRECTED_SEED)))
$(eval $(call DIRECTED_TEST,issue-select-large,issue_select_large,tb_issue_select_large))
$(eval $(call DIRECTED_TEST,dispatch-admit,dispatch_admit,tb_dispatch_admit, "$$(RAPTOR_HOME)/verification/formal/formal_dispatch_admit.sv",,+SEED=$$(VERILATOR_DIRECTED_SEED)))
$(eval $(call DIRECTED_TEST,rob-dispatch-select,rob_dispatch_select,tb_rob_dispatch_select,,,+SEED=$$(VERILATOR_DIRECTED_SEED)))
$(eval $(call DIRECTED_TEST,operand-spill,operand_spill,tb_operand_spill,,-d RAPT_ASSERT_EN,+SEED=$$(VERILATOR_DIRECTED_SEED)))
$(eval $(call DIRECTED_TEST,operand-value-spill,operand_value_spill,tb_operand_value_spill,,-d RAPT_ASSERT_EN,+SEED=$$(VERILATOR_DIRECTED_SEED)))
$(eval $(call DIRECTED_TEST,operand-value-spill-lutram,operand_value_spill_lutram,tb_operand_value_spill,,-d RAPT_ASSERT_EN -d RAPT_FPGA_LUTRAM=1,+SEED=$$(VERILATOR_DIRECTED_SEED)))
$(eval $(call DIRECTED_TEST,dispatch-compact,dispatch_compact,tb_dispatch_compact,,-d RAPT_ASSERT_EN,+SEED=$$(VERILATOR_DIRECTED_SEED)))
$(eval $(call DIRECTED_TEST,recovery-pending,recovery_pending,tb_recovery_pending, "$$(RAPTOR_HOME)/verification/formal/formal_recovery_pending.sv",-d RAPT_ASSERT_EN,+SEED=$$(VERILATOR_DIRECTED_SEED)))
$(eval $(call DIRECTED_TEST,completion-guard,completion_guard,tb_completion_guard,,,+SEED=$$(VERILATOR_DIRECTED_SEED)))
$(eval $(call DIRECTED_TEST,completion-stage-rv32 completion-stage-rv64,$$(subst -,_,$$@),tb_completion_stage,,-d RAPT_ASSERT_EN $$(if $$(findstring rv64,$$@),-d RAPT_RV64)))
$(eval $(call DIRECTED_TEST,completion-packets-rv32 completion-packets-rv64,$$(subst -,_,$$@),tb_completion_packets,,-d RAPT_ASSERT_EN $$(if $$(findstring rv64,$$@),-d RAPT_RV64)))
$(eval $(call DIRECTED_TEST,iq-reclaim-random,iq_reclaim_random,tb_iq_reclaim_random,,-d RAPT_ASSERT_EN -d RAPT_DISPATCH_WIDTH=3,+SEED=$$(VERILATOR_DIRECTED_SEED)))
$(eval $(call DIRECTED_TEST,iq-recovery-window-rv64,iq_recovery_window_rv64,tb_iq_recovery_window,,-d RAPT_ASSERT_EN -d RAPT_RV64))
$(eval $(call DIRECTED_TEST,iq-recovery-window,iq_recovery_window,tb_iq_recovery_window,,-d RAPT_ASSERT_EN))
$(eval $(call DIRECTED_TEST,iq-reclaim-random-rv64,iq_reclaim_random_rv64,tb_iq_reclaim_random,,-d RAPT_ASSERT_EN -d RAPT_RV64 -d RAPT_DISPATCH_WIDTH=3,+SEED=$$(VERILATOR_DIRECTED_SEED)))
$(eval $(call DIRECTED_TEST,iq-deferred-reclaim-rv32 iq-deferred-reclaim-rv64,$$(subst -,_,$$@),tb_iq_reclaim_random,,-d RAPT_ASSERT_EN -d RAPT_DISPATCH_WIDTH=3 -GReclaimOnIssue=0 $$(if $$(findstring rv64,$$@),-d RAPT_RV64),+SEED=$$(VERILATOR_DIRECTED_SEED)))
$(eval $(call DIRECTED_TEST,iq-zkt-dependencies-rv32 iq-zkt-dependencies-rv64,$$(subst -,_,$$@),tb_iq_recovery_window,,-d RAPT_ASSERT_EN -GCheckOperandIndependence=1 -GCheckDependencyCases=1 $$(if $$(findstring rv64,$$@),-d RAPT_RV64)))
$(eval $(call DIRECTED_TEST,iq-zkt-recovery-rv32 iq-zkt-recovery-rv64,$$(subst -,_,$$@),tb_iq_recovery_window,,-d RAPT_ASSERT_EN -GCheckOperandIndependence=1 $$(if $$(findstring rv64,$$@),-d RAPT_RV64)))
$(eval $(call DIRECTED_TEST,iq-zkt-rv32 iq-zkt-rv64,$$(subst -,_,$$@),tb_iq_reclaim_random,,-d RAPT_ASSERT_EN -GCheckOperandIndependence=1 -GEntries=8 $$(if $$(findstring rv64,$$@),-d RAPT_RV64),+SEED=$$(VERILATOR_DIRECTED_SEED)))
$(eval $(call DIRECTED_TEST,iq-reclaim-single,iq_reclaim_single,tb_iq_reclaim_random,,-d RAPT_ASSERT_EN -d RAPT_INTEGER_ISSUE_PORTS=1 -d RAPT_DISPATCH_WIDTH=1 -GEntries=1,+SEED=$$(VERILATOR_DIRECTED_SEED)))
$(eval $(call DIRECTED_TEST,iq-reclaim-three,iq_reclaim_three,tb_iq_reclaim_random,,-d RAPT_ASSERT_EN -d RAPT_INTEGER_ISSUE_PORTS=3 -d RAPT_DISPATCH_WIDTH=4 -GEntries=7,+SEED=$$(VERILATOR_DIRECTED_SEED)))
$(eval $(call DIRECTED_TEST,iq-reclaim-six-rv64,iq_reclaim_six_rv64,tb_iq_reclaim_random,,-d RAPT_ASSERT_EN -d RAPT_RV64 -d RAPT_INTEGER_ISSUE_PORTS=6 -d RAPT_DISPATCH_WIDTH=4 -GEntries=11,+SEED=$$(VERILATOR_DIRECTED_SEED)))
$(eval $(call DIRECTED_TEST,iq-ordered-head iq-ordered-head-rv64,$$(subst -,_,$$@),tb_iq_reclaim_random,,-d RAPT_ASSERT_EN -GInOrder=1 -GPorts=1 -GEntries=7 $$(if $$(findstring rv64,$$@),-d RAPT_RV64),+SEED=$$(VERILATOR_DIRECTED_SEED)))
$(eval $(call DIRECTED_TEST,iq-repair-three,iq_repair_three,tb_iq_reclaim_random,,-d RAPT_ASSERT_EN -d RAPT_INTEGER_ISSUE_PORTS=3 -d RAPT_DISPATCH_WIDTH=4 -GEntries=7 -GRebalance=1,+SEED=$$(VERILATOR_DIRECTED_SEED)))
$(eval $(call DIRECTED_TEST,iq-repair-six-rv64,iq_repair_six_rv64,tb_iq_reclaim_random,,-d RAPT_ASSERT_EN -d RAPT_RV64 -d RAPT_INTEGER_ISSUE_PORTS=6 -d RAPT_DISPATCH_WIDTH=4 -GEntries=11 -GRebalance=1,+SEED=$$(VERILATOR_DIRECTED_SEED)))
$(eval $(call DIRECTED_TEST,prf-state-arch16,prf_state_arch16,tb_prf_state,,-d RAPT_RVFI -GArchRegs=16,+SEED=$$(VERILATOR_DIRECTED_SEED)))
$(eval $(call DIRECTED_TEST,prf-state,prf_state,tb_prf_state,,-d RAPT_RVFI,+SEED=$$(VERILATOR_DIRECTED_SEED)))
$(eval $(call DIRECTED_TEST,prf-state-rv64,prf_state_rv64,tb_prf_state,,-d RAPT_RVFI -d RAPT_RV64,+SEED=$$(VERILATOR_DIRECTED_SEED)))
$(eval $(call DIRECTED_TEST,ras,ras,tb_ras,,-d RAPT_ASSERT_EN,+SEED=$$(VERILATOR_DIRECTED_SEED)))
$(eval $(call DIRECTED_TEST,ras-rv64,ras_rv64,tb_ras,,-d RAPT_ASSERT_EN -d RAPT_RV64,+SEED=$$(VERILATOR_DIRECTED_SEED)))
$(eval $(call DIRECTED_TEST,btb-storage-rv32 btb-storage-rv64,$$(subst -,_,$$@),tb_btb_storage,,$$(if $$(findstring rv64,$$@),-d RAPT_RV64)))
$(eval $(call DIRECTED_TEST,tage-read-storage-rv32 tage-read-storage-rv64,$$(subst -,_,$$@),tb_tage_read_storage,,-d RAPT_ASSERT_EN $$(if $$(findstring rv64,$$@),-d RAPT_RV64)))
$(eval $(call DIRECTED_TEST,tage-aux-read-rv32 tage-aux-read-rv64,$$(subst -,_,$$@),tb_tage_aux_read,,-d RAPT_ASSERT_EN $$(if $$(findstring rv64,$$@),-d RAPT_RV64)))
$(eval $(call DIRECTED_TEST,frontend-count-rv32 frontend-count-rv64,$$(subst -,_,$$@),tb_frontend_count,,-d RAPT_ASSERT_EN $$(if $$(findstring rv64,$$@),-d RAPT_RV64)))
$(eval $(call DIRECTED_TEST,predict-history,predict_history,tb_predict_history, "$$(RAPTOR_HOME)/verification/formal/formal_predict_history.sv",,+SEED=$$(VERILATOR_DIRECTED_SEED)))
$(eval $(call DIRECTED_TEST,l1d-load-pbmt,l1d_load_pbmt,tb_l1d_load_pbmt,,-d RAPT_RV64 -d RAPT_ASSERT_EN))
$(eval $(call DIRECTED_TEST,ioq-pbmt-order,ioq_pbmt_order,tb_ioq_pbmt_order,,-d RAPT_RV64 -d RAPT_ASSERT_EN))
$(eval $(call DIRECTED_TEST,sq-pbmt-order,sq_pbmt_order,tb_sq_pbmt_order,,-d RAPT_RV64 -d RAPT_ASSERT_EN))
$(eval $(call DIRECTED_TEST,l1d-io-size,l1d_io_size,tb_l1d_io_size,,-d RAPT_RV64 -d RAPT_ASSERT_EN))
$(eval $(call DIRECTED_TEST,lsu-l1d-io-split,lsu_l1d_io_split,tb_lsu_l1d_io_split,$$(sort  ),-d RAPT_RV64 -d RAPT_ASSERT_EN))
$(eval $(call DIRECTED_TEST,l2-pbmt,l2_pbmt,tb_l2_pbmt,,-d RAPT_L2_EN))
$(eval $(call DIRECTED_TEST,l2-pbmt-rv64,l2_pbmt_rv64,tb_l2_pbmt,,-d RAPT_RV64 -d RAPT_L2_EN))
$(eval $(call DIRECTED_TEST,l2-pbmt-boom-rv32 l2-pbmt-boom-rv64,$$(subst -,_,$$@),tb_l2_pbmt_boom,,$$(if $$(findstring rv64,$$@),-d RAPT_RV64) -d RAPT_L2_EN -d RAPT_ASSERT_EN))
$(eval $(call DIRECTED_TEST,l1i-access-sizes-rv32 l1i-access-sizes-rv64,$$(subst -,_,$$@),tb_l1i_access_sizes,,$$(if $$(findstring rv64,$$@),-d RAPT_RV64)))
$(eval $(call DIRECTED_TEST,l1i-io-guard-rv64,l1i_io_guard_rv64,tb_l1i_word_path,,-d RAPT_RV64 -d RAPT_ASSERT_EN))
$(eval $(call DIRECTED_TEST,pmp-endpoint-rv64,pmp_endpoint_rv64,tb_pmp_endpoint,,-d RAPT_RV64))
$(eval $(call DIRECTED_TEST,fpu-product-share,fpu_product_share,tb_fpu_product_share,,-d RAPT_ASSERT_EN))
$(eval $(call DIRECTED_TEST,csr-pmp-address-rv64,csr_pmp_address_rv64,tb_csr_pmp_address,,-d RAPT_RV64))
$(eval $(call DIRECTED_TEST,ptw-kill-drain-rv64,ptw_kill_drain_rv64,tb_ptw_kill_drain,,-d RAPT_RV64 -d RAPT_ASSERT_EN))
$(eval $(call DIRECTED_TEST,idu-m-encodings-rv32 idu-m-encodings-rv64,$$(subst -,_,$$@),tb_idu_m_encodings,,$$(if $$(findstring rv64,$$@),-d RAPT_RV64)))
$(eval $(call DIRECTED_TEST,idu-bit-immediates-rv32 idu-bit-immediates-rv64,$$(subst -,_,$$@),tb_idu_bit_immediates,,$$(if $$(findstring rv64,$$@),-d RAPT_RV64)))
$(eval $(call DIRECTED_TEST,zexth-decode-alu-rv32 zexth-decode-alu-rv64,$$(subst -,_,$$@),tb_zexth_decode_alu,,$$(if $$(findstring rv64,$$@),-d RAPT_RV64)))
$(eval $(call DIRECTED_TEST,csr-write-intent-rv32 csr-write-intent-rv64,$$(subst -,_,$$@),tb_csr_write_intent,,$$(if $$(findstring rv64,$$@),-d RAPT_RV64)))
$(eval $(call DIRECTED_TEST,half-axi-write-rv32 half-axi-write-rv64,$$(subst -,_,$$@),tb_half_axi_write,,-d RAPT_ASSERT_EN $$(if $$(findstring rv64,$$@),-d RAPT_RV64)))
$(eval $(call DIRECTED_TEST,half-store-visibility-rv32 half-store-visibility-rv64,$$(subst -,_,$$@),tb_half_store_visibility, $$(filter-out ,),-d RAPT_ASSERT_EN $$(if $$(findstring rv64,$$@),-d RAPT_RV64)))
$(eval $(call DIRECTED_TEST,rou-fp-ooo-rv32 rou-fp-ooo-rv64,$$(subst -,_,$$@),tb_rou_dual_commit,,-d RAPT_ASSERT_EN -d RAPT_TEST_FP_OOO -d RAPT_TEST_FP_IRQ_COMPOSE $$(if $$(findstring rv64,$$@),-d RAPT_RV64)))
$(eval $(call DIRECTED_TEST,rou-fp-irq-compose-rv32 rou-fp-irq-compose-rv64,$$(subst -,_,$$@),tb_rou_dual_commit,,-d RAPT_ASSERT_EN -d RAPT_TEST_FP_IRQ_BOUNDARY -d RAPT_TEST_FP_IRQ_COMPOSE $$(if $$(findstring rv64,$$@),-d RAPT_RV64)))
$(eval $(call DIRECTED_TEST,rou-fp-irq-boundary-rv32 rou-fp-irq-boundary-rv64,$$(subst -,_,$$@),tb_rou_dual_commit,,-d RAPT_ASSERT_EN -d RAPT_TEST_FP_IRQ_BOUNDARY $$(if $$(findstring rv64,$$@),-d RAPT_RV64)))
$(eval $(call DIRECTED_TEST,rou-retire-count-rv32 rou-retire-count-rv64,$$(subst -,_,$$@),tb_rou_dual_commit,,-d RAPT_ASSERT_EN -d RAPT_TEST_RETIRE_COUNT $$(if $$(findstring rv64,$$@),-d RAPT_RV64)))
$(eval $(call DIRECTED_TEST,csr-counter-priority-rv32 csr-counter-priority-rv64,$$(subst -,_,$$@),tb_csr_counter_priority,,$$(if $$(findstring rv64,$$@),-d RAPT_RV64)))
$(eval $(call DIRECTED_TEST,csr-difftest-policy-rv32 csr-difftest-policy-rv64,$$(subst -,_,$$@),tb_csr_difftest_policy,,$$(if $$(findstring rv64,$$@),-d RAPT_RV64)))
$(eval $(call DIRECTED_TEST,counter-permissions-rv32 counter-permissions-rv64,$$(subst -,_,$$@),tb_counter_permissions,,$$(if $$(findstring rv64,$$@),-d RAPT_RV64)))
$(eval $(call DIRECTED_TEST,l1i-width-window-rv64,l1i_width_window_rv64,tb_l1i_width_window,,-d RAPT_RV64))
$(eval $(call DIRECTED_TEST,svinval-decode-rv32 svinval-decode-rv64,$$(subst -,_,$$@),tb_svinval_decode,,$$(if $$(findstring rv64,$$@),-d RAPT_RV64)))
$(eval $(call DIRECTED_TEST,l1i-data-integrity,l1i_data_integrity,tb_l1i_data_integrity,,,+SEED=$$(L1I_DATA_SEED)))
$(eval $(call DIRECTED_TEST,l1d-trap-owner-rv32 l1d-trap-owner-rv64,$$(subst -,_,$$@),tb_l1d_trap_owner,,-d RAPT_ASSERT_EN $$(if $$(findstring rv64,$$@),-d RAPT_RV64)))
$(eval $(call DIRECTED_TEST,l1d-permission-stage-rv32 l1d-permission-stage-rv64,$$(subst -,_,$$@),tb_l1d_permission_stage,,-d RAPT_ASSERT_EN $$(if $$(findstring rv64,$$@),-d RAPT_RV64)))
$(eval $(call DIRECTED_TEST,idu-fence-i-fields-rv32 idu-fence-i-fields-rv64,$$(subst -,_,$$@),tb_idu_fence_i_fields,,$$(if $$(findstring rv64,$$@),-d RAPT_RV64)))
$(eval $(call DIRECTED_TEST,csr-satp-warl-rv32 csr-satp-warl-rv64,$$(subst -,_,$$@),tb_csr_contract,,$$(if $$(findstring rv64,$$@),-d RAPT_RV64),+CASE=satp_warl))
$(eval $(call DIRECTED_TEST,csr-envcfg-warl-rv32 csr-envcfg-warl-rv64,$$(subst -,_,$$@),tb_csr_envcfg_warl,,$$(if $$(findstring rv64,$$@),-d RAPT_RV64)))
$(eval $(call DIRECTED_TEST,ifu-l1i-stream-rv32 ifu-l1i-stream-rv64,$$(subst -,_,$$@),tb_ifu_l1i_stream,,-d RAPT_ASSERT_EN -d RAPT_DECODE_WIDTH=4 $$(if $$(findstring rv64,$$@),-d RAPT_RV64)))
$(eval $(call DIRECTED_TEST,csr-pmp-lock-rv32 csr-pmp-lock-rv64,$$(subst -,_,$$@),tb_csr_pmp_lock,,$$(if $$(findstring rv64,$$@),-d RAPT_RV64)))
$(eval $(call DIRECTED_TEST,idu-csr-addresses-rv32 idu-csr-addresses-rv64,$$(subst -,_,$$@),tb_idu_csr_addresses,,$$(if $$(findstring rv64,$$@),-d RAPT_RV64)))
$(eval $(call DIRECTED_TEST,csr-trap-storage-rv32 csr-trap-storage-rv64,$$(subst -,_,$$@),tb_csr_contract,,$$(if $$(findstring rv64,$$@),-d RAPT_RV64),+CASE=trap_storage))
$(eval $(call DIRECTED_TEST,csr-status-fields-rv32 csr-status-fields-rv64,$$(subst -,_,$$@),tb_csr_contract,,$$(if $$(findstring rv64,$$@),-d RAPT_RV64),+CASE=status_fields))
$(eval $(call DIRECTED_TEST,csr-fp-aliases-rv32 csr-fp-aliases-rv64,$$(subst -,_,$$@),tb_csr_contract,,$$(if $$(findstring rv64,$$@),-d RAPT_RV64),+CASE=fp_aliases))
$(eval $(call DIRECTED_TEST,csr-stimecmp-rv32 csr-stimecmp-rv64,$$(subst -,_,$$@),tb_csr_contract,,$$(if $$(findstring rv64,$$@),-d RAPT_RV64),+CASE=stimecmp))
$(eval $(call DIRECTED_TEST,csr-identity-time-rv32 csr-identity-time-rv64,$$(subst -,_,$$@),tb_csr_contract,,$$(if $$(findstring rv64,$$@),-d RAPT_RV64),+CASE=identity_time))
$(eval $(call DIRECTED_TEST,csr-tvec-routes-rv32 csr-tvec-routes-rv64,$$(subst -,_,$$@),tb_csr_contract,,$$(if $$(findstring rv64,$$@),-d RAPT_RV64),+CASE=tvec_routes))
$(eval $(call DIRECTED_TEST,l2-response-error-rv32,l2_response_error_rv32,tb_l2_response_error,,-d RAPT_L2_EN -d RAPT_ASSERT_EN))
$(eval $(call DIRECTED_TEST,l2-response-error-rv64,l2_response_error_rv64,tb_l2_response_error,,-d RAPT_L2_EN -d RAPT_ASSERT_EN -d RAPT_RV64))
$(eval $(call DIRECTED_TEST,l2-response-error-boom-rv32,l2_response_error_boom_rv32,tb_l2_response_error,,-d RAPT_L2_EN -d RAPT_ASSERT_EN -d RAPT_TEST_BOOM_L2))
$(eval $(call DIRECTED_TEST,l2-response-error-boom-rv64,l2_response_error_boom_rv64,tb_l2_response_error,,-d RAPT_L2_EN -d RAPT_ASSERT_EN -d RAPT_RV64 -d RAPT_TEST_BOOM_L2))
$(eval $(call DIRECTED_TEST,router-early-write-rv32,router_early_write_rv32,tb_chip_router_early_write,,-d RAPT_ASSERT_EN))
$(eval $(call DIRECTED_TEST,router-early-write-rv64,router_early_write_rv64,tb_chip_router_early_write,,-d RAPT_ASSERT_EN -d RAPT_RV64))
$(eval $(call DIRECTED_TEST,rnp-handshake-rv32,rnp_handshake_rv32,tb_rnp_handshake,,-d RAPT_ASSERT_EN))
$(eval $(call DIRECTED_TEST,cache-default-rv32 cache-default-rv64,$$(subst -,_,$$@),tb_cache_stream,,-d RAPT_ASSERT_EN $$(if $$(findstring rv64,$$@),-d RAPT_RV64)))
$(eval $(call DIRECTED_TEST,wb-ptw-rv32 wb-ptw-rv64,$$(subst -,_,$$@),tb_cache_stream,,-d RAPT_ASSERT_EN $$(if $$(findstring rv64,$$@),-d RAPT_RV64),+WB_PTW_READ +WB_PTW_PENDING_STORE))
$(eval $(call DIRECTED_TEST,l1i-16k-rv32 l1i-16k-rv64,$$(subst -,_,$$@),tb_l1i_16k,,-d RAPT_ASSERT_EN $$(if $$(findstring rv64,$$@),-d RAPT_RV64)))
$(eval $(call DIRECTED_TEST,l1d-16k-rv32 l1d-16k-rv64,$$(subst -,_,$$@),tb_l1d_16k,,-d RAPT_ASSERT_EN $$(if $$(findstring rv64,$$@),-d RAPT_RV64)))
$(eval $(call DIRECTED_TEST,cache-stream-wb-rv32 cache-stream-wb-rv64 cache-stream-wb-l2-rv32 cache-stream-wb-l2-rv64,$$(subst -,_,$$@),tb_cache_stream,,-d RAPT_ASSERT_EN $$(if $$(findstring rv64,$$@),-d RAPT_RV64) $$(if $$(findstring -l2-,$$@),-d RAPT_L2_EN)))
$(eval $(call DIRECTED_TEST,cache-stream-rv32 cache-stream-rv64 cache-stream-l2-rv32 cache-stream-l2-rv64 cache-stream-rnp-rv32,$$(subst -,_,$$@),tb_cache_stream,,-d RAPT_ASSERT_EN $$(if $$(findstring -rnp-,$$@),-d RAPT_TEST_RNP) $$(if $$(findstring rv64,$$@),-d RAPT_RV64) $$(if $$(findstring -l2-,$$@),-d RAPT_L2_EN)))
$(eval $(call DIRECTED_TEST,ioq-address-stage-rv32 ioq-address-stage-rv64,$$(subst -,_,$$@),tb_ioq_address_stage,,-d RAPT_ASSERT_EN $$(if $$(findstring rv64,$$@),-d RAPT_RV64)))
$(eval $(call DIRECTED_TEST,ioq-forward-nonalias-rv32 ioq-forward-nonalias-rv64,$$(subst -,_,$$@),tb_ioq_forward_nonalias,,-d RAPT_ASSERT_EN $$(if $$(findstring rv64,$$@),-d RAPT_RV64)))
$(eval $(call DIRECTED_TEST,port-priority,port_priority,tb_port_priority))
$(eval $(call DIRECTED_TEST,dispatch-iq-index-rv32 dispatch-iq-index-rv64,$$(subst -,_,$$@),tb_dispatch_iq_index,,-d RAPT_ASSERT_EN $$(if $$(findstring rv64,$$@),-d RAPT_RV64)))
$(eval $(call DIRECTED_TEST,iq-cdb-wake-rv32 iq-cdb-wake-rv64,$$(subst -,_,$$@),tb_iq_cdb_wake,,-d RAPT_ASSERT_EN $$(if $$(findstring rv64,$$@),-d RAPT_RV64)))
$(eval $(call DIRECTED_TEST,iq-registered-wake-rv32 iq-registered-wake-rv64,$$(subst -,_,$$@),tb_iq_cdb_wake,,-d RAPT_ASSERT_EN -GComboCdbWake=0 $$(if $$(findstring rv64,$$@),-d RAPT_RV64)))
$(eval $(call DIRECTED_TEST,iq-port-priority-rv32 iq-port-priority-rv64,$$(subst -,_,$$@),tb_iq_reclaim_random,,-d RAPT_ASSERT_EN $$(if $$(findstring rv64,$$@),-d RAPT_RV64) -d RAPT_INTEGER_ISSUE_PORTS=3 -d RAPT_INTEGER_SYSTEM_PORT=1 -GLastIssuePort=1 -GReclaimOnIssue=0,+SEED=$$(VERILATOR_DIRECTED_SEED)))
$(eval $(call DIRECTED_TEST,cdb-streaming-rv32 cdb-streaming-rv64,$$(subst -,_,$$@),tb_cdb_streaming,,-d RAPT_ASSERT_EN $$(if $$(findstring rv64,$$@),-d RAPT_RV64)))
$(eval $(call DIRECTED_TEST,fmax-boundaries-rv32 fmax-boundaries-rv64,$$(subst -,_,$$@),tb_fmax_boundaries,,-d RAPT_ASSERT_EN $$(if $$(findstring rv64,$$@),-d RAPT_RV64)))
$(eval $(call DIRECTED_TEST,mshr-cache-rv32 mshr-cache-rv64,$$(subst -,_,$$@),tb_mshr_cache,,-d RAPT_ASSERT_EN -d RAPT_L1D_MSHRS=2 $$(if $$(findstring rv64,$$@),-d RAPT_RV64)))
$(eval $(call DIRECTED_TEST,mshr-ioq-rv32 mshr-ioq-rv64,$$(subst -,_,$$@),tb_mshr_ioq,,-d RAPT_ASSERT_EN $$(if $$(findstring rv64,$$@),-d RAPT_RV64)))
$(eval $(call DIRECTED_TEST,ioq-response-stage-rv32 ioq-response-stage-rv64,$$(subst -,_,$$@),tb_ioq_load_response_stage,,-d RAPT_ASSERT_EN -d RAPT_IOQ_LOAD_RESPONSE_STAGE=1 $$(if $$(findstring rv64,$$@),-d RAPT_RV64)))
$(eval $(call DIRECTED_TEST,operand-value-spill-banked-rv32 operand-value-spill-banked-rv64,$$(subst -,_,$$@),tb_operand_value_spill_banked,,-d RAPT_ASSERT_EN -d RAPT_FPGA_LUTRAM=1 $$(if $$(findstring rv64,$$@),-d RAPT_RV64,-GXlen=32)))
$(eval $(call DIRECTED_TEST,iq-banked-w4-rv32 iq-banked-w4-rv64,$$(subst -,_,$$@),tb_iq_reclaim_random,,-d RAPT_ASSERT_EN -d RAPT_FPGA_LUTRAM=1 -GEntries=16 $$(if $$(findstring rv64,$$@),-d RAPT_RV64),+SEED=$$(VERILATOR_DIRECTED_SEED)))
$(eval $(call DIRECTED_TEST,memory-drain-rv32 memory-drain-rv64,$$(subst -,_,$$@),tb_memory_drain,,-d RAPT_ASSERT_EN $$(if $$(findstring rv64,$$@),-d RAPT_RV64)))
$(eval $(call DIRECTED_TEST,rou-drain-handshake-rv32 rou-drain-handshake-rv64,$$(subst -,_,$$@),tb_rou_dual_commit,,-d RAPT_ASSERT_EN -d RAPT_TEST_DRAIN_HANDSHAKE -d RAPT_TEST_REGISTERED_DRAIN -d RAPT_TEST_COMPACT_FP -d RAPT_TEST_REGISTERED_PAYLOAD $$(if $$(findstring rv64,$$@),-d RAPT_RV64)))
$(eval $(call DIRECTED_TEST,ifu-response-bypass-rv32 ifu-response-bypass-rv64,$$(subst -,_,$$@),tb_ifu_response_stage,,-d RAPT_ASSERT_EN -d RAPT_FETCH_RESPONSE_STAGE=0 $$(if $$(findstring rv64,$$@),-d RAPT_RV64)))
$(eval $(call DIRECTED_TEST,frontend-recovery-stage-rv32 frontend-recovery-stage-rv64,$$(subst -,_,$$@),tb_frontend_recovery,,-d RAPT_ASSERT_EN -d RAPT_DECODE_WIDTH=4 -d RAPT_FETCH_RESPONSE_STAGE=1 $$(if $$(findstring rv64,$$@),-d RAPT_RV64)))

# Public help descriptions remain visible to the Makefile help scanner.
verilator-l2-assoc-rv32 verilator-l2-assoc-rv64: ## Check 8-way L2 and CBO (XSIM_RAPT_CONFIG=default-l2)
verilator-l2-line-local-put-rv32 verilator-l2-line-local-put-rv64: ## Check short cacheable Put line allocation and refill merge
verilator-l2-cross-line-put-rv32 verilator-l2-cross-line-put-rv64: ## Check segmented cacheable Put and failed-refill W drain
verilator-l2-forwarded-error-rv32 verilator-l2-forwarded-error-rv64: ## Check failed cacheable forwarded B preserves resident dirty data
verilator-l2-forwarded-client-rv32 verilator-l2-forwarded-client-rv64: ## Check forwarded D-client Probe and overlapping C Release
verilator-axi-r-buffer-rv32 verilator-axi-r-buffer-rv64: ## Check registered AXI R buffering and outer-channel passthrough
verilator-l2-put-buffer-rv32 verilator-l2-put-buffer-rv64: ## Check 40-entry BOOM-size L2 put buffer (XSIM_RAPT_CONFIG=default-l2)
verilator-l2-put-list-rv32 verilator-l2-put-list-rv64: ## Check BOOM's 40 lists and 40 shared put beats
verilator-l2-secondary-buffer: ## Check BOOM's 21 virtual secondary queues and 33 shared entries
verilator-l2-secondary-buffer-rv32: ## Check 15 RV32 secondary queues and 35 shared entries
verilator-l2-release-buffer-rv32 verilator-l2-release-buffer-rv64: ## Check two Release lists and shared lowest-free beat pool
verilator-l2-release-admission-rv32 verilator-l2-release-admission-rv64: ## Reserve L2 admission from the first ReleaseData beat
verilator-l2-release-probe-rv32 verilator-l2-release-probe-rv64: ## Check nested C Release pre-emption and victim metadata forwarding
verilator-l2-owned-read-rv32 verilator-l2-owned-read-rv64: ## Check Get owner Probe and same-tag MSHR metadata reuse
verilator-l2-mshr-scheduler: ## Check BOOM's five ordinary plus two reserved L2 MSHR slots
verilator-l2-mshr-frontend: ## Check BOOM-sized MSHR admission and secondary replay together
verilator-l2-refill-mshrs-rv32 verilator-l2-refill-mshrs-rv64: ## Check RV32 five/RV64 seven refill contexts with interleaved RIDs
verilator-l2-mshr-concurrent-rv32 verilator-l2-mshr-concurrent-rv64: ## Check RV32 three/RV64 five live L2 clean misses before outer R
verilator-l2-mshr-different-tag-rv32 verilator-l2-mshr-different-tag-rv64: ## Check live same-set different-tag secondary replay
verilator-l2-adapter-write-rv32 verilator-l2-adapter-write-rv64: ## Check adapter stores allocate in default-l2
verilator-l2-data-array: ## Check BOOM four-bank data array and its single-port arbitration
verilator-l2-directory: ## Check BOOM-style L2 directory wipe, metadata and queued-write bypass
verilator-l2-directory-oneway: ## Check a one-way L2 directory never chooses an invalid victim
verilator-axi-write-lanes-rv32 verilator-axi-write-lanes-rv64: ## Check AXI byte-lane spans, independent AW/W stalls and B errors
verilator-iq-recovery-window: ## Measure resident wrong-path issue before precise flush
verilator-tage-aux-read-rv32 verilator-tage-aux-read-rv64: ## Auxiliary TAGE read against the full-PC hash oracle
verilator-l2-pbmt-boom-rv32 verilator-l2-pbmt-boom-rv64: ## Check PBMT bypass and typed AXI responses with the 8-way SRAM L2
verilator-l2-response-error-rv32: ## Check failed L2 refills complete, drain and retry in RV32
verilator-l2-response-error-rv64: ## Check failed L2 refills complete, drain and retry in RV64
verilator-l2-response-error-boom-rv32: ## Check RV32 failed writes through the 8-way SRAM directory
verilator-l2-response-error-boom-rv64: ## Check failed writes through the 8-way SRAM directory
verilator-router-early-write-rv32: ## Check W-before-AW routing and response ownership in RV32
verilator-router-early-write-rv64: ## Check W-before-AW routing and response ownership in RV64
verilator-rnp-handshake-rv32: ## Check RNP AW/W serialization, IDs and response stalls

# The 4x32 fetch-window checks probe ifu_l1i.inst_n3/n4 (RAPT_FETCH_WIDE).
$(eval $(call DIRECTED_PRESET,verilator-ifu-wide-pack-rv32 verilator-ifu-wide-pack-rv64 \
	verilator-ifu-l1i-wide-rv32 verilator-ifu-l1i-wide-rv64,default-w4))
# These L2 checks assume the 8-way BOOM-geometry L2 of default-l2.
$(eval $(call DIRECTED_PRESET,$(foreach t,assoc line-local-put cross-line-put forwarded-error \
	forwarded-client put-buffer release-admission release-probe owned-read mshr-concurrent \
	mshr-different-tag adapter-write response-error-boom,verilator-l2-$(t)-rv32 verilator-l2-$(t)-rv64),default-l2))
# Write-through L1D: cacheable stores also hold younger IO reads until B.
$(eval $(call XLEN_TEST,lsu-axi-io-order-wt,tb_lsu_axi_io_order,,-d RAPT_ASSERT_EN -d RAPT_L1D_WRITEBACK=0))

$(eval $(call XLEN_TEST,bpu-recovery-state,tb_bpu_recovery_state,,-d RAPT_ASSERT_EN))
$(eval $(call XLEN_TEST,rou-early-recovery,tb_rou_dual_commit,,-d RAPT_ASSERT_EN -d RAPT_TEST_EARLY_RECOVERY))

# F1: registered decode correction and wrong-path containment.
$(eval $(call XLEN_TEST,frontend-delayed-correction,tb_frontend_delayed_correction,,-d RAPT_ASSERT_EN))
$(eval $(call XLEN_TEST,frontend-delayed-correction-w3,tb_frontend_delayed_correction,,-d RAPT_ASSERT_EN -d RAPT_DECODE_WIDTH=3))
$(eval $(call XLEN_TEST,frontend-delayed-correction-w4,tb_frontend_delayed_correction,,-d RAPT_ASSERT_EN -d RAPT_DECODE_WIDTH=4))
# F1 end

# P2c
$(eval $(call XLEN_TEST,dtlb-table,tb_dtlb_table))
$(eval $(call XLEN_TEST,dtlb-table-2way,tb_dtlb_table,,-GWays=2))
$(eval $(call XLEN_TEST,dtlb-verdict,tb_dtlb_verdict,,-d RAPT_ASSERT_EN))
$(eval $(call XLEN_TEST,dtlb-l2-conflict,tb_dtlb_l2_conflict,,-d RAPT_ASSERT_EN))
$(eval $(call XLEN_TEST,dtlb-table-cam,tb_dtlb_table,,-GWays=0))
$(eval $(call XLEN_TEST,pmp-page-uniform,tb_pmp_page_uniform))
$(eval $(call XLEN_TEST,csr-pmp-flush,tb_csr_pmp_flush,"$$(VERIFY_HOME)/xsim/tb_csr_pmp_flush.sv"))

# Explicit XLEN parameters in integer execution units.
$(eval $(call XLEN_TEST,ieu-xlen-parameter,tb_ieu_xlen_parameter))
$(eval $(call XLEN_TEST,muldiv-xlen-parameter,tb_ieu_xlen_parameter,,-GCheckMuldiv=1))

# L2 refill address stability under backpressure.
$(eval $(call XLEN_TEST,l2-refill-ar-stable,tb_l2_refill_ar_stable))

# Debug reset and halt sequencing.
$(eval $(call XLEN_TEST,dm-step-reset,tb_rtop_dm_reset))
$(eval $(call XLEN_TEST,dm-step-halt,tb_rtop_dm_reset,,-GExplicitHalt=1))

# Memory / LSU boundary ownership and collision checks.
$(eval $(call XLEN_TEST,l1d-response-boundary,tb_l1d_response_boundary,,-d RAPT_ASSERT_EN -d RAPT_L1D_MSHRS=4))
$(eval $(call XLEN_TEST,lsu-killed-consumer,tb_lsu_killed_consumer,,-d RAPT_ASSERT_EN -d RAPT_L1D_MSHRS=4))
$(eval $(call XLEN_TEST,lsu-request-boundary,tb_lsu_request_boundary,,-d RAPT_ASSERT_EN))

# Rename skid buffering and branch recovery latency.
E67_SKID_DEFINES := -d RAPT_ASSERT_EN -d RAPT_TEST_E67 -d RAPT_TEST_REGISTERED_PAYLOAD
e67_width = -d RAPT_RENAME_WIDTH=$(1) -d RAPT_DISPATCH_WIDTH=$(1) -d RAPT_COMMIT_WIDTH=$(1)
$(eval $(call XLEN_TEST,e67-skid,tb_rou_dual_commit,,$(E67_SKID_DEFINES)))
$(eval $(call XLEN_TEST,e67-skid-w3,tb_rou_dual_commit,,$(E67_SKID_DEFINES) $(call e67_width,3)))
$(eval $(call XLEN_TEST,e67-skid-w4,tb_rou_dual_commit,,$(E67_SKID_DEFINES) $(call e67_width,4)))
$(eval $(call XLEN_TEST,e67-latency,tb_e67_latency,"$$(RAPTOR_HOME)/sim/tb/rapt_tb_mem.sv",-d RAPT_ASSERT_EN))

# Frontend refill ownership, prediction and hint collisions.
$(eval $(call XLEN_TEST,fetch-refill,tb_fetch_refill,,-d RAPT_ASSERT_EN))
$(eval $(call XLEN_TEST,fetch-prediction,tb_fetch_prediction,,-d RAPT_ASSERT_EN))
$(eval $(call XLEN_TEST,fetch-hints,tb_fetch_hints,,-d RAPT_ASSERT_EN))
$(eval $(call XLEN_TEST,fetch-tage-query,tb_fetch_tage_query,,-d RAPT_ASSERT_EN))
$(eval $(call XLEN_TEST,fetch-hint-alias,tb_fetch_hint_alias,,-d RAPT_ASSERT_EN))

# Store/load admission, address ownership and split payloads.
$(eval $(call XLEN_TEST,ioq-prepared-address,tb_ioq_prepared_address,,-d RAPT_ASSERT_EN))
$(eval $(call XLEN_TEST,l1d-mshr-fill-owner,tb_l1d_mshr_fill_owner,,-d RAPT_ASSERT_EN))
$(eval $(call XLEN_TEST,l1d-lr-admission,tb_l1d_lr_admission,,-d RAPT_ASSERT_EN -d RAPT_L1D_MSHRS=2))
$(eval $(call XLEN_TEST,ioq-store-payload,tb_ioq_store_payload,,-d RAPT_ASSERT_EN))
$(eval $(call XLEN_TEST,lsu-split-payload,tb_lsu_split_payload,,-d RAPT_ASSERT_EN))

# SFENCE preserves physical caches and prediction state while killing stale walks.
$(eval $(call XLEN_TEST,sfence-keeps-l1d,tb_l1d_16k,,-d RAPT_ASSERT_EN))
$(eval $(call XLEN_TEST,sfence-keeps-l1i,tb_l1i_16k,,-d RAPT_ASSERT_EN))
$(eval $(call XLEN_TEST,sfence-mapping-epoch,tb_l1i_mapping_epoch,,-d RAPT_ASSERT_EN -GInvalidateCache=0))
$(eval $(call XLEN_TEST,sfence-commit,tb_rou_dual_commit,,-d RAPT_ASSERT_EN -d RAPT_TEST_FENCE_COMMIT))
$(eval $(call XLEN_TEST,sfence-keeps-bpu,tb_bpu_recovery_state,,-d RAPT_ASSERT_EN))
$(eval $(call XLEN_TEST,sfence-data-remap-wt,tb_sfence_data_remap,,-d RAPT_ASSERT_EN -d RAPT_L1D_WRITEBACK=0))
$(eval $(call XLEN_TEST,sfence-data-remap-wb,tb_sfence_data_remap,,-d RAPT_ASSERT_EN -d RAPT_L1D_WRITEBACK=1))
$(eval $(call XLEN_TEST,sfence-mapping-epoch-l2,tb_l1i_mapping_epoch,,-d RAPT_ASSERT_EN -GInvalidateCache=0 -GL2Tlb=1))

# Assemble whole-core RV64 guests without rebuilding a simulator. Run the
# resulting .bin with an existing RV64 NPC and its bare-metal MROM (-b -n).
SFENCE_REMAP_KIND ?= 4k
SFENCE_REMAP_ASID ?= 7
.PHONY: sfence-instruction-remap-build sfence-instruction-remap-superpage-build
sfence-instruction-remap-superpage-build: SFENCE_REMAP_KIND = superpage
sfence-instruction-remap-build sfence-instruction-remap-superpage-build: ## Build RV64 predictor-trained instruction remap guest
	@mkdir -p "$(BUILD_DIR)/sfence-instruction-remap"
	$(CROSS_COMPILE)gcc -march=rv64imac_zicsr_zifencei -mabi=lp64 -nostdlib -nostartfiles -Wl,--no-relax \
		$(if $(filter superpage,$(SFENCE_REMAP_KIND)),-DSFENCE_REMAP_SUPERPAGE) -DSFENCE_REMAP_ASID=$(SFENCE_REMAP_ASID) \
		-T "$(VERIFY_HOME)/scripts/fuzz_link.ld" -o "$(BUILD_DIR)/sfence-instruction-remap/$(SFENCE_REMAP_KIND).elf" \
		"$(VERIFY_HOME)/xsim/sfence_instruction_remap.S"
	$(CROSS_COMPILE)objcopy -O binary "$(BUILD_DIR)/sfence-instruction-remap/$(SFENCE_REMAP_KIND).elf" \
		"$(BUILD_DIR)/sfence-instruction-remap/$(SFENCE_REMAP_KIND).bin"

# Selective SFENCE masks and leaf-granularity invalidation.
$(eval $(call XLEN_TEST,sfence-selective-tlb,tb_sfence_selective_tlb,,-d RAPT_ASSERT_EN))
$(eval $(call XLEN_TEST,sfence-selective-l2,tb_sfence_selective_l2,,-d RAPT_ASSERT_EN))
$(eval $(call XLEN_TEST,sfence-selective-walk,tb_sfence_selective_walk,,-d RAPT_ASSERT_EN))
$(eval $(call XLEN_TEST,sfence-selective-operands,tb_sfence_selective_operands,,-d RAPT_ASSERT_EN))

# Targeted write-back coherence with independently delayed R/B channels.
$(eval $(call XLEN_TEST,l1d-targeted-coherence,tb_targeted_coherence,,-d RAPT_ASSERT_EN -d RAPT_L1D_WRITEBACK=1 -d RAPT_L1D_TARGETED_COHERENCE=1,+BUS_DELAY_MAX=$$(VERILATOR_DIRECTED_DELAY)))
$(eval $(call XLEN_TEST,dirty-line-select,tb_dirty_line_select,,-d RAPT_ASSERT_EN))
$(eval $(call XLEN_TEST,cbo-refill-order,tb_cbo_refill_order,,-d RAPT_ASSERT_EN -d RAPT_L1D_WRITEBACK=1 -d RAPT_L1D_TARGETED_COHERENCE=1))
# Buffered writebacks retain payload and line hazards through ordered B responses.
$(eval $(call XLEN_TEST,bus-buffered-writeback,tb_bus_buffered_writeback,,-d RAPT_ASSERT_EN))
$(eval $(call XLEN_TEST,wb-posted-coherence,tb_memory_coherence_progress,,-d RAPT_ASSERT_EN -GPostedWrites=4,+BUS_DELAY_MAX=$$(VERILATOR_DIRECTED_DELAY) +SEED=$$(VERILATOR_DIRECTED_SEED)))
$(eval $(call XLEN_TEST,router-write-single,tb_chip_router_early_write,,-d RAPT_ASSERT_EN -GWriteOutstanding=1))

# Optional true-LRU and TLB tree-PLRU replacement policies.
$(eval $(call DIRECTED_TEST,cache-lru,cache_lru,tb_cache_lru))
$(eval $(call XLEN_TEST,tlb-lru,tb_tlb_lru))
$(eval $(call XLEN_TEST,l1d-replacement-lru,tb_l1d_replacement,,-d RAPT_CACHE_LRU=1))
$(eval $(call XLEN_TEST,tlb-plru,tb_tlb_lru,,-GPlru=1))

# Packed immediate sign extension and exact fetch/decode trap values.
$(eval $(call XLEN_TEST,uop-payload,tb_uop_payload,,-d RAPT_ASSERT_EN))

$(eval $(call DIRECTED_TEST,uop-rou-contract-rv32 uop-rou-contract-rv64,$$(subst -,_,$$@),tb_rou_dual_commit,,-d RAPT_ASSERT_EN -d RAPT_TEST_UOP_COMPACT $$(if $$(findstring rv64,$$@),-d RAPT_RV64)))
