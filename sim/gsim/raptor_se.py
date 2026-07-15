#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""
gem5 SE-mode model of the Raptor chip out-of-order RISC-V core.

Mirrors the microarchitecture knobs declared in
`raptor-chip/hdl/configs/<preset>/rapt_config.svh` so DSE / perf-bug runs in
gem5 stay aligned with the RTL configuration matrix.

Why SE mode?
------------
`app/Makefile` builds bare-metal newlib ELFs (e.g.
`app/build/rv$XLEN/coremark/coremark.elf`) using
`riscv$XLEN-unknown-elf-gcc`. These use newlib syscalls (write/_exit/sbrk)
which gem5's RISCV SE workload handles directly via `RiscvEmuLinux`
(matches the ELF's `unknown` OS tag). No `pk`, no HTIF, no Linux kernel.

Param mapping (raptor → gem5 O3)
--------------------------------
* line_bytes   = 4 << LINE_LEN          (RTL stores cache line as 2^LINE_LEN
                                         32-bit words)
* num_sets     = 1 << LEN
* cache size   = line * sets * ways
* numROBEntries          = ROB_SIZE
* numPhysIntRegs         = PHY_SIZE
* numPhysFloatRegs       = max(PHY_SIZE, 64)        (gem5 needs >= 32 archregs)
* IQ numEntries          = RS_SIZE + IOQ_SIZE
* LQ/SQEntries           = SQ_SIZE
* fetch..commitWidth     = ISSUE_WIDTH
* BTB                    = SimpleBTB(numEntries=BTB_SIZE, assoc=BTB_WAYS)
* Conditional pred       = BiModeBP(globalPredictorSize=PHT_SIZE,
                                    choicePredictorSize=PHT_SIZE)
* RAS                    = ReturnAddrStack(numEntries=RSB_SIZE)

Usage
-----
scons build/RISCV/gem5.opt -j$(nproc)        # one-time, in gem5 tree

./build/RISCV/gem5.opt \
    raptor-chip/sim/gsim/raptor_se.py \
    --preset default \
    --benchmark coremark \
    --cpu o3 \
    --max-insts 200000000

./build/RISCV/gem5.opt --outdir=m5out/cmk-large \
    raptor-chip/sim/gsim/raptor_se.py \
    --preset large --rv64 --benchmark coremark

Design-space exploration (ChampSim-style)
-----------------------------------------
The JSON override accepts a ChampSim-like schema: top-level `block_size`,
`ooo_cpu`, `L1I`, `L1D`, `BTB`, `PHT`, `RAS`, `indirect_branch_predictor`,
`physical_memory`, and `simulation` sections. It is normalized internally into
the uarch/sim knobs used by this script. Config layering order (later wins):

    1. `hdl/configs/<preset>/rapt_config.svh`  (or --config-svh)
    2. `--json-config <file>`              (ChampSim-style JSON; see dse-config.json)
    3. `--set ooo_cpu.0.rob_size=128 --set L1D.mshr_size=4 ...`
  4. legacy CLI flags (--mshrs, --bp, --storeset, --clk-freq, ...) when
     explicitly passed

The effective merged config is always written to
  <outdir>/raptor_se_effective.json
for reproducibility, and can be replayed with `--json-config`.

Sweep example:
  for rob in 32 48 64 96 128; do
    ./build/RISCV/gem5.opt --outdir=m5out/sweep/rob$rob \
    raptor-chip/sim/gsim/raptor_se.py \
    --preset default --benchmark coremark \
    --set ooo_cpu.0.rob_size=$rob \
    --set ooo_cpu.0.scheduler_size=$((rob/2)) \
    --set L1D.mshr_size=4
  done
"""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

import m5
from m5.objects import (
    AddrRange,
    BadAddr,
    BiModeBP,
    BranchPredictor,
    Cache,
    Clint,
    FUPool,
    GshareBP,
    HiFiveBase,
    IntALU,
    IntMultDiv,
    L2XBar,
    LTAGE,
    LocalBP,
    FP_ALU,
    FP_MultDiv,
    Matrix_Unit,
    MultiperspectivePerceptron8KB,
    MultiperspectivePerceptron64KB,
    MultiperspectivePerceptronTAGE8KB,
    MultiperspectivePerceptronTAGE64KB,
    Plic,
    PredALU,
    Process,
    RdWrPort,
    ReadPort,
    ReturnAddrStack,
    RiscvO3CPU,
    RiscvISA,
    RiscvSystem,
    RiscvRTC,
    RiscvTimingSimpleCPU,
    SIMD_Unit,
    Root,
    SEWorkload,
    SimpleBTB,
    SimpleIndirectPredictor,
    SimpleMemory,
    SrcClockDomain,
    System_Unit,
    SystemXBar,
    TAGE,
    TAGE_SC_L_8KB,
    TAGE_SC_L_64KB,
    TournamentBP,
    VoltageDomain,
    WritePort,
)
from m5.objects.IQUnit import IQUnit
from m5.params import NULL

from raptor_dse import (
    DEFAULT_SIM_CFG,
    SUPPORTED_BP_INPUTS,
    SUPPORTED_BP_KINDS,
    _die,
    apply_overrides,
    canonical_bp_name,
    derive_uarch,
    dump_effective_config,
    equalize_bp_budget,
    load_json_config,
    parse_rapt_config,
    parse_set_flags,
)


# ----------------------------------------------------------------------------
# CPU + cache builders
# ----------------------------------------------------------------------------
def _as_gem5_value(val):
    if isinstance(val, list):
        return [_as_gem5_value(v) for v in val]
    if isinstance(val, str) and val.lower().startswith("0x"):
        return int(val, 16)
    return val


def _apply_bp_params(obj, cfg: dict, mapping: dict[str, str]) -> None:
    for cfg_key, obj_key in mapping.items():
        if cfg_key in cfg:
            setattr(obj, obj_key, _as_gem5_value(cfg[cfg_key]))


_TAGE_PARAM_MAP = {
    "n_history_tables": "nHistoryTables",
    "nHistoryTables": "nHistoryTables",
    "min_history": "minHist",
    "minHist": "minHist",
    "max_history": "maxHist",
    "maxHist": "maxHist",
    "tag_table_tag_widths": "tagTableTagWidths",
    "tagTableTagWidths": "tagTableTagWidths",
    "log_table_sizes": "logTagTableSizes",
    "logTagTableSizes": "logTagTableSizes",
    "log_ratio_bimodal_hyst_entries": "logRatioBiModalHystEntries",
    "logRatioBiModalHystEntries": "logRatioBiModalHystEntries",
    "counter_bits": "tagTableCounterBits",
    "tag_table_counter_bits": "tagTableCounterBits",
    "tagTableCounterBits": "tagTableCounterBits",
    "u_bits": "tagTableUBits",
    "tag_table_u_bits": "tagTableUBits",
    "tagTableUBits": "tagTableUBits",
    "hist_buffer_size": "histBufferSize",
    "histBufferSize": "histBufferSize",
    "path_history_bits": "pathHistBits",
    "pathHistBits": "pathHistBits",
    "log_u_reset_period": "logUResetPeriod",
    "logUResetPeriod": "logUResetPeriod",
    "num_use_alt_on_na": "numUseAltOnNa",
    "numUseAltOnNa": "numUseAltOnNa",
    "initial_t_counter_value": "initialTCounterValue",
    "initialTCounterValue": "initialTCounterValue",
    "use_alt_on_na_bits": "useAltOnNaBits",
    "useAltOnNaBits": "useAltOnNaBits",
    "max_allocations": "maxNumAlloc",
    "maxNumAlloc": "maxNumAlloc",
    "no_skip": "noSkip",
    "noSkip": "noSkip",
    "log_table_size": "logTagTableSize",
    "logTagTableSize": "logTagTableSize",
    "short_tags_factor": "shortTagsTageFactor",
    "shortTagsTageFactor": "shortTagsTageFactor",
    "long_tags_factor": "longTagsTageFactor",
    "longTagsTageFactor": "longTagsTageFactor",
    "short_tag_bits": "shortTagsSize",
    "shortTagsSize": "shortTagsSize",
    "long_tag_bits": "longTagsSize",
    "longTagsSize": "longTagsSize",
    "first_long_tag_table": "firstLongTagTable",
    "firstLongTagTable": "firstLongTagTable",
    "truncate_path_history": "truncatePathHist",
    "truncatePathHist": "truncatePathHist",
    "tuned_history_lengths": "tunedHistoryLengths",
    "tunedHistoryLengths": "tunedHistoryLengths",
}


_LOOP_PARAM_MAP = {
    "log_size": "logSizeLoopPred",
    "logSizeLoopPred": "logSizeLoopPred",
    "with_loop_bits": "withLoopBits",
    "withLoopBits": "withLoopBits",
    "age_bits": "loopTableAgeBits",
    "loopTableAgeBits": "loopTableAgeBits",
    "confidence_bits": "loopTableConfidenceBits",
    "loopTableConfidenceBits": "loopTableConfidenceBits",
    "tag_bits": "loopTableTagBits",
    "loopTableTagBits": "loopTableTagBits",
    "iter_bits": "loopTableIterBits",
    "loopTableIterBits": "loopTableIterBits",
    "assoc_log": "logLoopTableAssoc",
    "logLoopTableAssoc": "logLoopTableAssoc",
    "use_speculation": "useSpeculation",
    "useSpeculation": "useSpeculation",
    "use_hashing": "useHashing",
    "useHashing": "useHashing",
    "use_direction_bit": "useDirectionBit",
    "useDirectionBit": "useDirectionBit",
    "restrict_allocation": "restrictAllocation",
    "restrictAllocation": "restrictAllocation",
    "initial_loop_iter": "initialLoopIter",
    "initialLoopIter": "initialLoopIter",
    "initial_loop_age": "initialLoopAge",
    "initialLoopAge": "initialLoopAge",
    "optional_age_reset": "optionalAgeReset",
    "optionalAgeReset": "optionalAgeReset",
}


_SC_PARAM_MAP = {
    "num_entries_first_local_histories": "numEntriesFirstLocalHistories",
    "numEntriesFirstLocalHistories": "numEntriesFirstLocalHistories",
    "num_entries_second_local_histories": "numEntriesSecondLocalHistories",
    "numEntriesSecondLocalHistories": "numEntriesSecondLocalHistories",
    "num_entries_third_local_histories": "numEntriesThirdLocalHistories",
    "numEntriesThirdLocalHistories": "numEntriesThirdLocalHistories",
    "log_bias": "logBias",
    "logBias": "logBias",
    "log_size_up": "logSizeUp",
    "logSizeUp": "logSizeUp",
    "chooser_conf_width": "chooserConfWidth",
    "chooserConfWidth": "chooserConfWidth",
    "update_threshold_width": "updateThresholdWidth",
    "updateThresholdWidth": "updateThresholdWidth",
    "p_update_threshold_width": "pUpdateThresholdWidth",
    "pUpdateThresholdWidth": "pUpdateThresholdWidth",
    "extra_weights_width": "extraWeightsWidth",
    "extraWeightsWidth": "extraWeightsWidth",
    "sc_counters_width": "scCountersWidth",
    "scCountersWidth": "scCountersWidth",
    "initial_update_threshold_value": "initialUpdateThresholdValue",
    "initialUpdateThresholdValue": "initialUpdateThresholdValue",
    "bwnb": "bwnb",
    "bwm": "bwm",
    "log_bwnb": "logBwnb",
    "logBwnb": "logBwnb",
    "bw_weight_init_value": "bwWeightInitValue",
    "bwWeightInitValue": "bwWeightInitValue",
    "lnb": "lnb",
    "lm": "lm",
    "log_lnb": "logLnb",
    "logLnb": "logLnb",
    "l_weight_init_value": "lWeightInitValue",
    "lWeightInitValue": "lWeightInitValue",
    "gnb": "gnb",
    "gm": "gm",
    "log_gnb": "logGnb",
    "logGnb": "logGnb",
    "pnb": "pnb",
    "pm": "pm",
    "log_pnb": "logPnb",
    "logPnb": "logPnb",
    "snb": "snb",
    "sm": "sm",
    "log_snb": "logSnb",
    "logSnb": "logSnb",
    "tnb": "tnb",
    "tm": "tm",
    "log_tnb": "logTnb",
    "logTnb": "logTnb",
    "inb": "inb",
    "im": "im",
    "log_inb": "logInb",
    "logInb": "logInb",
    "imnb": "imnb",
    "imm": "imm",
    "log_imnb": "logImnb",
    "logImnb": "logImnb",
}


_PERCEPTRON_PARAM_MAP = {
    "budget_bits": "budgetbits",
    "budgetbits": "budgetbits",
    "num_filter_entries": "num_filter_entries",
    "num_local_histories": "num_local_histories",
    "local_history_length": "local_history_length",
    "block_size": "block_size",
    "pcshift": "pcshift",
    "threshold": "threshold",
    "nbest": "nbest",
    "tunebits": "tunebits",
    "hshift": "hshift",
    "imli_mask1": "imli_mask1",
    "imli_mask4": "imli_mask4",
    "recencypos_mask": "recencypos_mask",
    "fudge": "fudge",
    "n_sign_bits": "n_sign_bits",
    "pcbit": "pcbit",
    "decay": "decay",
    "record_mask": "record_mask",
    "hash_taken": "hash_taken",
    "tuneonly": "tuneonly",
    "extra_rounds": "extra_rounds",
    "speed": "speed",
    "initial_theta": "initial_theta",
    "speculative_update": "speculative_update",
    "initial_ghist_length": "initial_ghist_length",
    "ignore_path_size": "ignore_path_size",
}


def _apply_common_bp_params(
    cond_bp,
    bp_params: dict,
    *,
    has_tage=False,
    tage_sections=("tage",),
) -> None:
    if not isinstance(bp_params, dict):
        return
    if has_tage:
        for tage_section in tage_sections:
            if isinstance(bp_params.get(tage_section), dict):
                _apply_bp_params(cond_bp.tage, bp_params[tage_section], _TAGE_PARAM_MAP)
    if hasattr(cond_bp, "loop_predictor") and isinstance(bp_params.get("loop"), dict):
        _apply_bp_params(cond_bp.loop_predictor, bp_params["loop"], _LOOP_PARAM_MAP)
    if hasattr(cond_bp, "statistical_corrector") and isinstance(
        bp_params.get("statistical_corrector"), dict
    ):
        _apply_bp_params(
            cond_bp.statistical_corrector,
            bp_params["statistical_corrector"],
            _SC_PARAM_MAP,
        )

    perceptron_cfg = {}
    if isinstance(bp_params.get("capacity"), dict):
        perceptron_cfg.update(bp_params["capacity"])
    if isinstance(bp_params.get("perceptron"), dict):
        perceptron_cfg.update(bp_params["perceptron"])
    if perceptron_cfg and "MultiperspectivePerceptron" in cond_bp.__class__.__name__:
        _apply_bp_params(cond_bp, perceptron_cfg, _PERCEPTRON_PARAM_MAP)


def build_branch_pred(u: dict, sim: dict) -> BranchPredictor:
    """Build a branch predictor unit.

    Alignment with RTL (raptor-chip):
      RTL PHT: bimodal 2-bit counter table, size = RAPT_PHT_SIZE (default 256).
      RTL has NO global history register (GHR) mixing — pure PC-indexed table.
      RTL BPU predicts once per cycle for Slot A (Slot B is always not-taken).

    `sim["bp"]` selects the predictor family. The default `local` matches the
    current raptor-chip RTL most closely. `use_ras` defaults on (matching RTL
    RSB); `use_indirect` defaults off because the RTL does not model an indirect
    target cache today.
    """
    bp_kind = canonical_bp_name(sim["bp"])
    if bp_kind not in SUPPORTED_BP_KINDS:
        # NEVER use ``raise SystemExit(<string>)`` here: gem5 main casts the
        # exit code via pybind11::cast<int> and aborts with cast_error. Use
        # _die() which exits with an integer code.
        _die(
            f"[raptor_se] unsupported bp={sim['bp']!r} (canonical={bp_kind!r}); "
            f"choose from {SUPPORTED_BP_INPUTS}"
        )
    # Equalize directional-predictor storage budget across BP families so
    # bimodal / gshare / ltage / perceptron / ... runs are area-comparable
    # to the default TAGE configuration (~5.4 Kbit). Disable via
    # `--set sim.equalize_budget=false`. See raptor_dse.equalize_bp_budget
    # for the per-family sizing rules.
    equalize_bp_budget(u, sim)
    bp_params = sim.get("bp_params", {})
    ctr_bits = max(1, int(u.get("pht_ctr_bits", 2)))

    ras = ReturnAddrStack(numEntries=u["rsb_size"]) if sim.get("use_ras", True) else NULL
    indirect = NULL
    if sim.get("use_indirect", False):
        indirect = SimpleIndirectPredictor(
            indirectSets=int(sim["indirect_sets"]),
            indirectWays=int(sim["indirect_ways"]),
            indirectTagSize=int(sim["indirect_tag_bits"]),
            indirectPathLength=int(sim["indirect_path_length"]),
            indirectGHRBits=int(sim["indirect_ghr_bits"]),
            indirectHashGHR=bool(sim["indirect_hash_ghr"]),
            indirectHashTargets=bool(sim["indirect_hash_targets"]),
            instShiftAmt=1,
        )

    btb = SimpleBTB(
        numEntries=u["btb_entries"],
        associativity=u["btb_assoc"],
        tagBits=int(u.get("btb_tag_bits", 16)),
        instShiftAmt=1,
    )

    if bp_kind == "gshare":
        # gem5 25.1 models GshareBP as a BranchPredictor subclass, but the
        # Python SimObject still inherits BranchPredictor's required
        # conditionalBranchPred param. Provide a small valid conditional
        # predictor so configuration elaboration does not fail before the
        # GshareBP object is constructed.
        return GshareBP(
            global_predictor_size=max(2, int(u["pht_size"])),
            global_counter_bits=ctr_bits,
            conditionalBranchPred=LocalBP(
                localPredictorSize=max(2, int(u["pht_size"])),
                localCtrBits=ctr_bits,
            ),
            btb=btb,
            ras=ras,
            indirectBranchPred=indirect,
            instShiftAmt=1,
        )

    if bp_kind == "bimode":
        cond_bp = BiModeBP(
            globalPredictorSize=max(2, int(u["pht_size"])),
            globalCtrBits=ctr_bits,
            choicePredictorSize=max(2, int(u["pht_size"])),
            choiceCtrBits=ctr_bits,
        )
    elif bp_kind == "tournament":
        size = max(2, int(u["pht_size"]))
        cond_bp = TournamentBP(
            localPredictorSize=size,
            localCtrBits=ctr_bits,
            localHistoryTableSize=size,
            globalPredictorSize=size,
            globalCtrBits=ctr_bits,
            choicePredictorSize=size,
            choiceCtrBits=ctr_bits,
        )
    elif bp_kind == "tage":
        cond_bp = TAGE()
        _apply_common_bp_params(cond_bp, bp_params, has_tage=True)
    elif bp_kind == "ltage":
        cond_bp = LTAGE()
        _apply_common_bp_params(cond_bp, bp_params, has_tage=True, tage_sections=("ltage",))
    elif bp_kind == "tage_sc_l_8kb":
        cond_bp = TAGE_SC_L_8KB()
        _apply_common_bp_params(
            cond_bp,
            bp_params,
            has_tage=True,
            tage_sections=("tage_sc_l", "tage_sc_l_8kb"),
        )
    elif bp_kind == "tage_sc_l_64kb":
        cond_bp = TAGE_SC_L_64KB()
        _apply_common_bp_params(
            cond_bp,
            bp_params,
            has_tage=True,
            tage_sections=("tage_sc_l", "tage_sc_l_64kb"),
        )
    elif bp_kind == "mpp_8kb":
        cond_bp = MultiperspectivePerceptron8KB()
        _apply_common_bp_params(cond_bp, bp_params)
    elif bp_kind == "mpp_64kb":
        cond_bp = MultiperspectivePerceptron64KB()
        _apply_common_bp_params(cond_bp, bp_params)
    elif bp_kind == "mpp_tage_8kb":
        cond_bp = MultiperspectivePerceptronTAGE8KB()
        _apply_common_bp_params(
            cond_bp,
            bp_params,
            has_tage=True,
            tage_sections=("mpp_tage", "mpp_tage_8kb"),
        )
    elif bp_kind == "mpp_tage_64kb":
        cond_bp = MultiperspectivePerceptronTAGE64KB()
        _apply_common_bp_params(
            cond_bp,
            bp_params,
            has_tage=True,
            tage_sections=("mpp_tage", "mpp_tage_64kb"),
        )
    else:
        # gem5's LocalBP is a simple PC-indexed 2-bit bimodal table — exactly
        # what raptor-chip's PHT implements (no GHR mixing).
        size = max(2, int(u["pht_size"]))
        cond_bp = LocalBP(
            localPredictorSize=size,
            localCtrBits=ctr_bits,
        )

    bp = BranchPredictor(
        btb=btb,
        ras=ras,
        conditionalBranchPred=cond_bp,
        indirectBranchPred=indirect,
        # RV instructions are aligned to 2 (with C ext); shift by 1 to dedupe.
        instShiftAmt=1,
    )
    return bp


def build_o3_cpu(
    u: dict,
    rv64: bool,
    cpu_id: int = 0,
    sim: dict | None = None,
    storeset: bool = False,
    rtl_execution_resources: bool = False,
    fetch_queue_size: int | None = None,
) -> RiscvO3CPU:
    """Build a RiscvO3CPU configured to match raptor-chip microarchitecture.

    Alignment with RTL (raptor-chip) ISA profile:
      RV32: MISA = 0x40141107 → RV32IMACU
      RV64: MISA = 0x8000000000141107 → RV64IMACU
      Additional Z-extensions in RTL: Zicbop, Zicntr, Zicond, Zicsr, Zifencei,
                                      Zihintntl, Zihintpause, Zimop, Zcb, Zcmop,
                                      Zba, Zbb, Zbc, Zbs
      gem5 support: LocalBP (not all Z-extensions yet; evaluate per version).
    """
    cpu = RiscvO3CPU(
        cpu_id=cpu_id,
        isa=[RiscvISA(riscv_type=("RV64" if rv64 else "RV32"))],
    )
    # C5: ISA extension alignment.
    # gem5's RiscvISA sets base ISA (I/M/A/F/D + C compressed) via riscv_type;
    # IMAFDC is enabled by default for RV32/RV64. raptor-chip RTL MISA = IMACU.
    # Z-extensions (Zba/Zbb/Zbc/Zbs/Zicbop/Zicntr/Zicond/Zicsr/Zifencei/Zihintntl
    #                /Zihintpause/Zimop/Zcb/Zcmop) are not user-tunable on
    # gem5 25.x's RiscvISA — they are baked in via `enable_*` build flags
    # and reported through MISA at runtime. No-op here; documented for parity.

    # Microarchitecture parameters from raptor-chip config
    # C1: IQ configuration (unified instruction queue model).
    #   RTL has RS (8-entry OoO) + IOQ (8-entry in-order), but since gem5's IQ
    #   is unified and scheduling is implicitly hybrid (ready on operands),
    #   we model both as a single 16-entry queue. Performance-neutral for
    #   most workloads; validated against coremark baseline.
    cpu.fetchBufferSize = u.get("fetch_buffer_size", u["line_bytes"])
    if fetch_queue_size is not None:
        cpu.fetchQueueSize = fetch_queue_size
    cpu.fetchWidth = u["fetch_w"]
    cpu.decodeWidth = u["decode_w"]
    cpu.renameWidth = u["rename_w"]
    cpu.dispatchWidth = u["dispatch_w"]
    cpu.issueWidth = u["issue_w"]
    cpu.wbWidth = u["wb_w"]
    cpu.commitWidth = u["commit_w"]
    cpu.squashWidth = u["squash_w"]
    cpu.numROBEntries = u["rob"]
    cpu.numPhysIntRegs = u["phys_int"]
    cpu.numPhysFloatRegs = u["phys_fp"]
    cpu.LQEntries = u["lq"]
    cpu.SQEntries = u["sq"]
    cpu.instQueues = [IQUnit(numEntries=u["iq"])]
    if rtl_execution_resources:
        # Preserve the default pool's non-integer capabilities, while matching
        # Raptor's two ALU pipes, one MULDIV pipe, and one L1D request path.
        cpu.instQueues = [
            IQUnit(
                numEntries=u["iq"],
                fuPool=FUPool(
                    FUList=[
                        IntALU(count=2),
                        IntMultDiv(count=1),
                        FP_ALU(),
                        FP_MultDiv(),
                        ReadPort(),
                        SIMD_Unit(),
                        Matrix_Unit(),
                        System_Unit(),
                        PredALU(),
                        WritePort(),
                        RdWrPort(count=1),
                    ]
                ),
            )
        ]
        cpu.cacheLoadPorts = 1
        cpu.cacheStorePorts = 1
    cpu.branchPred = build_branch_pred(u, sim or DEFAULT_SIM_CFG)
    if not storeset:
        # C6: Memory model alignment.
        # raptor-chip LSU does NOT speculate loads past unresolved stores.
        # Disable gem5's StoreSet predictor (which would aggressively reorder
        # memory ops) to match RTL behavior: strict address-based dependency checks.
        cpu.SSITSize = "8"
        cpu.LFSTSize = 2
        cpu.LSQDepCheckShift = 0  # Widest possible address overlap check
        cpu.LSQCheckLoads = True
    return cpu


def build_l1(size: str, assoc: int, is_data: bool, mshrs: int = 1) -> Cache:
    # raptor-chip's L1 FSM today services exactly one outstanding miss
    # (LD_A -> LD_D -> back to IDLE), so default mshrs=1. Override via
    # --mshrs to explore miss-under-miss behavior.
    return Cache(
        size=size,
        assoc=assoc,
        tag_latency=1,
        data_latency=1,
        response_latency=1,
        mshrs=max(1, mshrs),
        tgts_per_mshr=8,
        writeback_clean=False,
        is_read_only=not is_data,
    )


def build_l2() -> Cache:
    # Optional shared "next-level" cache so loads have a sane refill latency
    # rather than going straight to DRAM. Sized to a small SRAM-like buffer
    # since raptor-chip's RTL today has no L2 — we model it as a refill stage.
    return Cache(
        size="64KiB",
        assoc=8,
        tag_latency=8,
        data_latency=8,
        response_latency=8,
        mshrs=16,
        tgts_per_mshr=8,
    )


# ----------------------------------------------------------------------------
# Benchmark resolution
# ----------------------------------------------------------------------------
RAPT_HOME = Path(os.environ.get("RAPTOR_HOME", Path(__file__).resolve().parents[2]))


def resolve_benchmark(name: str, rv64: bool) -> tuple[Path, list[str]]:
    """Return (elf_path, extra_argv) for a known benchmark name.

    Falls back to treating `name` as an explicit path if it ends in .elf or
    exists on disk.
    """
    xlen = 64 if rv64 else 32
    base = RAPT_HOME / "app" / "build" / f"rv{xlen}"

    def emb(name: str) -> Path:
        # Embench ELFs land in app/build/rv$XLEN/embench/<bench>/<bench>.elf
        # (one subdir per benchmark, mirroring the Embench-IoT layout).
        return base / "embench" / name / f"{name}.elf"

    catalog = {
        "coremark": (base / "coremark" / "coremark.elf", []),
        "embench-aha-mont64": (emb("aha-mont64"), []),
        "embench-crc32": (emb("crc32"), []),
        "embench-matmult-int": (emb("matmult-int"), []),
        "embench-md5sum": (emb("md5sum"), []),
        "embench-nettle-aes": (emb("nettle-aes"), []),
        "embench-nettle-sha256": (emb("nettle-sha256"), []),
        "embench-picojpeg": (emb("picojpeg"), []),
        "embench-qrduino": (emb("qrduino"), []),
        "embench-sglib-combined": (emb("sglib-combined"), []),
        "embench-slre": (emb("slre"), []),
        "embench-statemate": (emb("statemate"), []),
        "embench-ud": (emb("ud"), []),
        "embench-wikisort": (emb("wikisort"), []),
        "embench-edn": (emb("edn"), []),
        "embench-huffbench": (emb("huffbench"), []),
        "embench-nsichneu": (emb("nsichneu"), []),
        "embench-tarfind": (emb("tarfind"), []),
        "embench-depthconv": (emb("depthconv"), []),
        "embench-xgboost": (emb("xgboost"), []),
    }
    if name in catalog:
        return catalog[name]
    p = Path(name)
    if p.exists():
        return (p, [])
    raise FileNotFoundError(
        f"Benchmark '{name}' not found. Build it first under "
        f"{RAPT_HOME}/app, e.g. `make -C app coremark` "
        f"({'RV64=1 ' if rv64 else ''}for rv{xlen}). "
        f"Looked under: {base}"
    )


# ----------------------------------------------------------------------------
# main
# ----------------------------------------------------------------------------
def main(argv: list[str] | None = None) -> int:
    raw_argv = list(sys.argv[1:] if argv is None else argv)

    def has_flag(*names: str) -> bool:
        return any(
            token == name or token.startswith(f"{name}=")
            for token in raw_argv
            for name in names
        )

    ap = argparse.ArgumentParser(
        description="gem5 SE runner for raptor-chip benchmarks"
    )
    ap.add_argument(
        "--preset",
        help="raptor-chip uarch preset (matches hdl/configs/<preset>/rapt_config.svh)",
    )
    ap.add_argument(
        "--config-svh",
        type=Path,
        default=None,
        help="explicit rapt_config.svh path (overrides --preset)",
    )
    ap.add_argument("--rv64", action="store_true", help="select RV64 ELF + ISA")
    ap.add_argument(
        "--cpu",
        choices=("o3", "timing"),
        default="o3",
        help="o3 = full Raptor uarch model; timing = simple in-order baseline",
    )
    ap.add_argument(
        "--benchmark",
        default="coremark",
        help=(
            "benchmark name (e.g. coremark, embench-crc32) or path to ELF."
        ),
    )
    ap.add_argument(
        "--bp",
        choices=SUPPORTED_BP_INPUTS,
        default="local",
        help="branch predictor family (default: local, matches RTL PC-indexed bimodal table)",
    )
    ap.add_argument(
        "--no-ras",
        action="store_true",
        help="disable the return-address stack / RAS (default: enabled to match RTL RSB)",
    )
    ap.add_argument(
        "--indirect",
        action="store_true",
        help="enable gem5's indirect target predictor (default: off, stronger than RTL)",
    )
    ap.add_argument(
        "--storeset",
        action="store_true",
        help="enable gem5's StoreSet load speculation (default: disabled to match RTL)",
    )
    ap.add_argument(
        "--rtl-execution-resources",
        action="store_true",
        help=(
            "use 2 integer ALUs, 1 MULDIV, and one load/store request port "
            "instead of gem5's broader default FUPool"
        ),
    )
    ap.add_argument(
        "--fetch-queue-size",
        type=int,
        default=None,
        help=(
            "override gem5's per-thread fetch queue depth (default: 32); "
            "use a small value to measure frontend-buffer decoupling"
        ),
    )
    ap.add_argument(
        "--mshrs",
        type=int,
        default=1,
        help="L1 MSHR count per cache (default: 1, matching RTL single-outstanding FSM)",
    )
    ap.add_argument(
        "--options",
        default="",
        help='argv for the benchmark, semicolon-separated (e.g. "0x0;0x0;0x66;10")',
    )
    ap.add_argument("--cwd", default=os.getcwd())
    ap.add_argument(
        "--clk-freq", default=None,
        help="core clock (raptor RTL targets ~1GHz); overrides sim.clk_freq when set",
    )
    ap.add_argument("--mem-size", default=None,
        help="backing memory size; overrides sim.mem_size when set")
    ap.add_argument(
        "--mem-latency", default=None,
        help="flat backing-memory latency; overrides sim.mem_latency when set",
    )
    ap.add_argument(
        "--json-config", type=Path, default=None,
        help="ChampSim-style JSON override applied on top of --preset",
    )
    ap.add_argument(
        "--set", dest="set_args", action="append", default=[],
        metavar="KEY.PATH=VALUE",
        help="ad-hoc override, repeatable: --set ooo_cpu.0.rob_size=128 --set L1D.mshr_size=4",
    )
    ap.add_argument(
        "--dump-config", type=Path, default=None,
        help="path to write effective merged config (default: <outdir>/raptor_se_effective.json)",
    )
    ap.add_argument(
        "--print-config-only", action="store_true",
        help="resolve + dump effective config then exit (no simulation)",
    )
    # Default to no L2 to match RTL. Use --with-l2 to opt back into the
    # legacy 64KiB L2 (only useful for sanity baselines).
    ap.add_argument(
        "--no-l2",
        dest="no_l2",
        action="store_true",
        default=True,
        help="(default) connect L1s directly to membus (matches raptor RTL: no L2)",
    )
    ap.add_argument(
        "--with-l2",
        dest="no_l2",
        action="store_false",
        help="insert a 64KiB shared L2 (NOT representative of raptor RTL)",
    )
    ap.add_argument("--max-insts", type=int, default=0, help="0 = run to completion")
    ap.add_argument("--max-ticks", type=int, default=0, help="0 = no wall-clock cap")
    args = ap.parse_args(raw_argv)

    # ---- 1. Read raptor preset (layer 1: rapt_config.svh) --------------------
    svh = args.config_svh
    if svh is None:
        svh = RAPT_HOME / "hdl" / "configs" / args.preset / "rapt_config.svh"
    if not svh.exists():
        print(f"[raptor_se] cannot find rapt_config.svh at {svh}", file=sys.stderr)
        return 2
    # Pre-seed rv64 from CLI; JSON/--set may flip it via simulation.rv64 below.
    cfg = parse_rapt_config(svh, rv64=args.rv64)
    u = derive_uarch(cfg)
    sim = DEFAULT_SIM_CFG.copy()
    sim["rv64"] = args.rv64

    # ---- 1b. Layer JSON config (ChampSim-style DSE file) ---------------------
    if args.json_config is not None:
        if not args.json_config.exists():
            print(f"[raptor_se] --json-config not found: {args.json_config}", file=sys.stderr)
            return 2
        apply_overrides(u, sim, load_json_config(args.json_config))

    # ---- 1c. Layer --set CLI overrides (highest precedence) ------------------
    apply_overrides(u, sim, parse_set_flags(args.set_args))

    # ---- 1d. Layer explicitly supplied legacy CLI flags ----------------------
    # argparse defaults are intentionally not applied here, otherwise Makefile
    # defaults such as --bp local would mask JSON/SET DSE configs.
    if has_flag("--cpu"):
        sim["cpu"] = args.cpu
    if has_flag("--bp"):
        sim["bp"] = canonical_bp_name(args.bp)
    if has_flag("--no-ras"):
        sim["use_ras"] = False
    if has_flag("--indirect"):
        sim["use_indirect"] = True
    if has_flag("--storeset"):
        sim["storeset"] = True
    if has_flag("--with-l2"):
        sim["with_l2"] = True
    if has_flag("--no-l2"):
        sim["with_l2"] = False
    if has_flag("--mshrs"):
        sim["mshrs"] = args.mshrs
    if has_flag("--clk-freq"):
        sim["clk_freq"] = args.clk_freq
    if has_flag("--mem-size"):
        sim["mem_size"] = args.mem_size
    if has_flag("--mem-latency"):
        sim["mem_latency"] = args.mem_latency

    # Sync back any sim-section overrides into args for the rest of main().
    args.rv64     = bool(sim["rv64"])
    args.cpu      = sim["cpu"]
    args.bp       = sim["bp"]
    args.storeset = bool(sim["storeset"])
    args.no_l2    = not bool(sim["with_l2"])
    args.mshrs    = int(sim["mshrs"])
    args.clk_freq    = sim["clk_freq"]
    args.mem_size    = sim["mem_size"]
    args.mem_latency = sim["mem_latency"]
    sim["rtl_execution_resources"] = args.rtl_execution_resources
    sim["fetch_queue_size"] = args.fetch_queue_size

    print(f"[raptor_se] preset={args.preset} svh={svh}")
    if args.json_config:
        print(f"[raptor_se] json-config={args.json_config}")
    if args.set_args:
        print(f"[raptor_se] --set: {args.set_args}")
    print(f"[raptor_se] effective uarch params:")
    for k, v in sorted(u.items()):
        print(f"    {k:14s} = {v}")
    print(f"[raptor_se] effective sim params:")
    for k, v in sorted(sim.items()):
        print(f"    {k:14s} = {v}")

    # Persist merged config for reproducibility / sweep post-processing.
    outdir = Path(m5.options.outdir) if hasattr(m5, "options") and getattr(m5.options, "outdir", None) else Path("m5out")
    dump_path = args.dump_config or (outdir / "raptor_se_effective.json")
    dump_effective_config(
        dump_path, u, sim,
        meta={
            "preset": args.preset,
            "svh": str(svh),
            "json_config": str(args.json_config) if args.json_config else None,
            "set_args": args.set_args,
            "benchmark": args.benchmark,
        },
    )
    if args.print_config_only:
        return 0

    # ---- 2. Resolve benchmark -------------------------------------------------
    elf, extra = resolve_benchmark(args.benchmark, args.rv64)
    bench_argv = [str(elf)]
    if extra:
        bench_argv.extend(extra)
    if args.options:
        bench_argv.extend([s for s in args.options.split(";") if s != ""])
    print(f"[raptor_se] elf  = {elf}")
    print(f"[raptor_se] argv = {bench_argv}")

    # ---- 3. Build system ------------------------------------------------------
    system = RiscvSystem()
    system.clk_domain = SrcClockDomain(
        clock=args.clk_freq, voltage_domain=VoltageDomain()
    )
    system.mem_mode = "timing"
    system.mem_ranges = [AddrRange(args.mem_size)]
    system.cache_line_size = u["line_bytes"]

    # CPU
    if args.cpu == "o3":
        system.cpu = build_o3_cpu(
            u,
            rv64=args.rv64,
            sim=sim,
            storeset=args.storeset,
            rtl_execution_resources=args.rtl_execution_resources,
            fetch_queue_size=args.fetch_queue_size,
        )
    else:
        system.cpu = RiscvTimingSimpleCPU(
            cpu_id=0,
            isa=[RiscvISA(riscv_type=("RV64" if args.rv64 else "RV32"))],
        )

    system.cpu.createInterruptController()

    # Caches
    system.cpu.icache = build_l1(
        u["l1i_size"], u["l1i_assoc"], is_data=False, mshrs=args.mshrs
    )
    system.cpu.dcache = build_l1(
        u["l1d_size"], u["l1d_assoc"], is_data=True, mshrs=args.mshrs
    )
    system.cpu.icache.cpu_side = system.cpu.icache_port
    system.cpu.dcache.cpu_side = system.cpu.dcache_port

    system.membus = SystemXBar()
    system.membus.badaddr_responder = BadAddr()
    system.membus.default = system.membus.badaddr_responder.pio

    if args.no_l2:
        system.cpu.icache.mem_side = system.membus.cpu_side_ports
        system.cpu.dcache.mem_side = system.membus.cpu_side_ports
    else:
        system.l2bus = L2XBar()
        system.l2 = build_l2()
        system.cpu.icache.mem_side = system.l2bus.cpu_side_ports
        system.cpu.dcache.mem_side = system.l2bus.cpu_side_ports
        system.l2.cpu_side = system.l2bus.mem_side_ports
        system.l2.mem_side = system.membus.cpu_side_ports

    system.system_port = system.membus.cpu_side_ports

    # gem5's RiscvISA looks up a CLINT in the system to service `rdtime`,
    # `rdcycle`, and IPI-style CSR reads even in SE mode (faults.cc panics
    # with "Can't find CLINT in system" otherwise). Park the platform above
    # the SE memory window so it doesn't collide with `mem_ranges`.
    system.platform = HiFiveBase(
        clint=Clint(pio_addr=0xF2000000, num_threads=1),
        plic=Plic(pio_addr=0xFC000000, n_src=2, hart_config="M"),
    )
    system.platform.rtc = RiscvRTC(frequency="100MHz")
    system.platform.clint.int_pin = system.platform.rtc.int_pin
    system.platform.clint.pio = system.membus.mem_side_ports
    system.platform.plic.pio = system.membus.mem_side_ports

    # Memory (SE model): single flat backing store with fixed latency.
    system.mem = SimpleMemory(range=system.mem_ranges[0], latency=args.mem_latency)
    system.mem.port = system.membus.mem_side_ports

    # ---- 4. Workload --------------------------------------------------------
    process = Process(pid=100)
    process.executable = str(elf)
    process.cwd = args.cwd
    process.cmd = bench_argv
    system.workload = SEWorkload.init_compatible(str(elf))
    system.cpu.workload = process
    system.cpu.createThreads()

    # ---- 5. Instantiate + run ------------------------------------------------
    root = Root(full_system=False, system=system)
    m5.instantiate()

    print(f"[raptor_se] starting simulation @ {args.clk_freq}")
    if args.max_insts > 0:
        system.cpu.max_insts_any_thread = args.max_insts
    if args.max_ticks > 0:
        exit_event = m5.simulate(args.max_ticks)
    else:
        exit_event = m5.simulate()
    print(f"[raptor_se] exit @ tick {m5.curTick()} cause: {exit_event.getCause()}")
    return 0


if __name__ == "__m5_main__" or __name__ == "__main__":
    sys.exit(main())
