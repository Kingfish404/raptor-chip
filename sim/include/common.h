#ifndef __NPC_COMMON_H__
#define __NPC_COMMON_H__

#include <generated/autoconf.h>
#include <stdio.h>
#include <stdlib.h>
#include <assert.h>
#include <pthread.h>
#include <string.h>
#include <stdint.h>
#include <inttypes.h>

#ifdef CONFIG_ISA64
typedef uint64_t word_t;
#define FMT_WORD "0x%016" PRIx64
#define FMT_WORD_NO_PREFIX "%016" PRIx64
#else
typedef uint32_t word_t;
#define FMT_WORD "0x%08x"
#define FMT_WORD_NO_PREFIX "%08x"
#endif
typedef word_t paddr_t;
typedef word_t vaddr_t;

#define GPR_SIZE 32
#define NPC_PMP_NUM 16
#define NPC_PLIC_NDEV 31
#define NPC_PLIC_NCTX 2

// CLINT `mtime` tick rate (MHz). MUST match RAPT_MTIME_FREQ_MHZ in
// rtl_sv/include/<soc>/rapt_soc.svh and the DTS `timebase-frequency`
// (which is in Hz, so multiply by 1_000_000).
// Override at build time with -DRAPT_MTIME_FREQ_MHZ=...
#ifndef RAPT_MTIME_FREQ_MHZ
#define RAPT_MTIME_FREQ_MHZ 10ULL
#endif

#define MBASE 0x80000000
#define MSIZE 0x08000000

#define PSRAM_BASE 0x80000000
#define PSRAM_SIZE 0x08000000

#define SDRAM_BASE 0xa0000000
#define SDRAM_SIZE 0x02000000

#define SRAM_BASE 0x0f000000
#define SRAM_SIZE 0x00002000

#define MROM_BASE 0x20000000
#define MROM_SIZE 0x00010000

#define FLASH_BASE 0x30000000
#define FLASH_SIZE 0x10000000

#ifdef CONFIG_SOFT_MMIO
#define DEVICE_BASE 0xa0000000

#define MMIO_BASE 0xa0000000

#define SERIAL_PORT (DEVICE_BASE + 0x00003f8)
#define KBD_ADDR_ (DEVICE_BASE + 0x0000060)
#define RTC_ADDR_ (DEVICE_BASE + 0x0000048)
#define VGACTL_ADDR (DEVICE_BASE + 0x0000100)
#define AUDIO_ADDR (DEVICE_BASE + 0x0000200)
#define DISK_ADDR (DEVICE_BASE + 0x0000300)
#define FB_ADDR__ (MMIO_BASE + 0x1000000)
#define AUDIO_SBUF_ADDR (MMIO_BASE + 0x1200000)
#endif

#define FMT_RED(x) "\33[1;31m" x "\33[0m"
#define FMT_GREEN(x) "\33[1;32m" x "\33[0m"
#define FMT_BLUE(x) "\33[1;34m" x "\33[0m"

#define ARRLEN(arr) (int)(sizeof(arr) / sizeof(arr[0]))

#define _CONCAT(x, y) x##y
#define CONCAT(x, y) _CONCAT(x, y)
#define CONCAT_HEAD(x) <x.h>

#define STRINGIZE_NX(A) #A
#define STRINGIZE(A) STRINGIZE_NX(A)

#define _Log(...)        \
  do                     \
  {                      \
    printf(__VA_ARGS__); \
  } while (0)

#define __FILENAME__ (strrchr(__FILE__, '/') ? strrchr(__FILE__, '/') + 1 : __FILE__)

#define Log(format, ...)                  \
  _Log(FMT_BLUE("%s:%d %s ") format "\n", \
       __FILENAME__, __LINE__, __func__, ##__VA_ARGS__)

#define Error(format, ...)                \
  _Log(FMT_RED("%s:%3d %s ") format "\n", \
       __FILENAME__, __LINE__, __func__, ##__VA_ARGS__)

#define Assert(cond, format, ...) \
  Error(format, ##__VA_ARGS__);   \
  assert(cond)

enum
{
  DIFFTEST_TO_DUT,
  DIFFTEST_TO_REF
};

typedef enum
{
  NPC_RUNNING,
  NPC_STOP,
  NPC_END,
  NPC_ABORT,
  NPC_QUIT
} NPC_STATE_CODE;

typedef struct
{
  NPC_STATE_CODE state;
  uint8_t host_exit_ok;
  word_t *gpr;
  word_t *ret;
  word_t *pc;
  char *priv;

  // csr
  word_t *sstatus;
  word_t *sie____;
  word_t *stvec__;

  word_t *scounte;
  word_t *mcounte;

  word_t *sscratch;
  word_t *sepc___;
  word_t *scause_;
  word_t *stval__;
  word_t *sip____;
  word_t *satp___;

  word_t *mstatus;
  word_t *misa___;
  word_t *medeleg;
  word_t *mideleg;
  word_t *mie____;
  word_t *mtvec__;
  word_t *menvcfg;
  word_t *mstatush;

  word_t *mscratch;
  word_t *mepc___;
  word_t *mcause_;
  word_t *mtval__;
  word_t *mip____;

  word_t *mcycle_;
  word_t *mcycleh;
  word_t *minstret;
  word_t *minstreth;
  word_t *time___;
  word_t *timeh__;

  // for mem diff
  word_t vwaddr;
  word_t pwaddr;
  word_t wdata;
  word_t wstrb;
  word_t len;

  // for load diff
  word_t rvaddr;
  word_t rpaddr;
  word_t rdata;
  word_t rlen;

  // for iomm
  word_t iomm_addr;
  word_t skip;

  // for itrace
  uint32_t *inst;
  word_t *rpc;
  uint32_t last_inst;

  // for soc
  uint8_t *soc_sram;

  // for CLINT checkpoint persistence
  uint64_t *clint_mtime;
  uint64_t *clint_mtimecmp;
  uint8_t *clint_msip;

  // for PLIC checkpoint persistence
  uint8_t *plic_priority; // [NPC_PLIC_NDEV + 1]
  uint32_t *plic_pending;
  uint32_t *plic_enable;   // [NPC_PLIC_NCTX]
  uint8_t *plic_threshold; // [NPC_PLIC_NCTX]
  uint32_t *plic_ext_irq;

  // for PMP checkpoint persistence
  uint8_t *pmpcfg;
  word_t *pmpaddr;

  // for checkpoint quiesce check (pipeline drain detection before save).
  // Phase A unified SQ: width-stable 1-bit probes (independent of SQ_SIZE).
  // ROB exposes a dedicated rob_empty signal.
  uint8_t *rob_empty;
  uint8_t *sq_empty;  // 1-bit: SQ fully drained (no store buffered, FSM idle)
  uint8_t *sq_full;   // 1-bit: all SQ entries occupied
  uint8_t *sq_snapshot_capacity;
  uint8_t *sq_snapshot_head;
  uint32_t *sq_snapshot_valid;
  uint32_t *sq_snapshot_committed;
  uint8_t *sq_snapshot_alu;
  word_t *sq_snapshot_paddr;
  word_t *sq_snapshot_wdata;
} NPCState;

typedef struct
{
  // for microarch
  long long int active_cycle;
  long long int instr_cnt;
  long long int ifu_fetch_cnt;
  long long int ifu_fetch_inst_cnt;
  long long int ifu_fetch_response_cnt;
  long long int ifu_dual_fetch_cnt;
  long long int ifu_fetch_bpu_taken_cnt;
  long long int ifu_fetch_slot_a_control_cnt;
  long long int ifu_fetch_slot_b_control_cnt;
  long long int ifu_fetch_slot_b_jal_pack_cnt;
  long long int ifu_fetch_slot_b_cond_pack_cnt;
  long long int ifu_fetch_n1_unavailable_cnt;
  long long int ifu_fetch_n1_unavailable_unaligned_cnt;
  long long int ifu_fetch_n1_unavailable_l1i_cnt;
  long long int ifu_fetch_downstream_blocked_cycle;
  long long int ifu_fetch_target_steer_cnt;
  long long int lsu_load_cnt;

  long long int ifu_stall_cycle;
  long long int exu_ooo_stall_cycle;
  long long int exu_ioq_stall_cycle;
  long long int lsu_l1d_stall_cycle;
  long long int lsu_sq_stall_cycle;
  long long int lsu_fwd_cnt;
  long long int lsu_sq_conflict_cnt;
  long long int lsu_stq_conflict_cnt;
  long long int wbu_stall_cycle;

  long long int ifu_sys_hazard_cycle;
  long long int rou_hazard_cycle;

  // bpu
  long long int bpu_cnt;
  long long int bpu_fail_cnt;
  long long int bpu_b_fail;
  long long int bpu_j_fail;
  long long int bpu_jr_fail;

  // for inst
  long long int ld_inst_cnt;
  long long int st_inst_cnt;
  long long int alu_inst_cnt;
  long long int b_inst_cnt;
  long long int jal_inst_cnt;
  long long int jalr_inst_cnt;
  long long int csr_inst_cnt;
  long long int other_inst_cnt;
  long long int call_inst_cnt;
  long long int ret_inst_cnt;

  // for cache
  long long int l1i_cache_hit_cnt;
  long long int l1i_cache_hit_cycle;
  long long int l1i_cache_miss_cnt;
  long long int l1i_cache_miss_cycle;
  long long int l1d_cache_hit_cnt;
  long long int l1d_cache_miss_cnt;
  long long int l1d_cache_miss_cycle;

  // for tlb & page table walk
  long long int itlb_ptw_cycle;
  long long int stlb_ptw_cycle;
  long long int ltlb_ptw_cycle;

  // dual commit
  long long int dual_commit_cnt;

  // early resteer (IDU detects BPU alias on non-branch)
  long long int early_resteer_cnt;

  // Commit-flush classification and the measured wait from a branch-caused
  // flush to the first resumed IFU fetch packet.
  long long int branch_flush_events;
  long long int nonbranch_flush_events;
  long long int branch_recovery_completed;
  long long int branch_recovery_wait_cycles;
  long long int branch_recovery_overlap_events;

  // -------------------------------------------------------------------
  // Extended PMU counters (gem5-aligned). Sampled in perf_sample_per_cycle.
  // -------------------------------------------------------------------
  // Exact IFU stall decomposition from mutually-exclusive RTL probes.
  long long int ifu_icache_miss_cycle; // no L1I/PTW response
  long long int ifu_flush_cycle;       // response staging after an invalid interval
  long long int ifu_empty_cycle;       // serialization/trap hold
  long long int ifu_response_after_redirect_cycle;
  long long int ifu_response_after_l1i_gap_cycle;
  long long int ifu_response_bypass_candidate_cycle;
  long long int ifu_no_response_refill_cycle;
  long long int ifu_no_response_sram_warmup_cycle;
  long long int ifu_no_response_tag_miss_cycle;
  long long int ifu_no_response_nextword_miss_cycle;
  long long int l1i_refill_start_line_miss;
  long long int l1i_refill_start_current_hole;
  long long int l1i_refill_start_next_line_miss;
  long long int l1i_refill_start_next_hole;
  long long int fqu_full_cycle;
  long long int fqu_buffered_cycle;
  long long int fqu_occupancy_sum;

  // Structural-full events  (gem5: iqFullEvents / robFullEvents / sqFullEvents)
  // *_cycle  = cycles spent fully occupied;  *_events = rising-edge count.
  long long int rs_full_cycle;
  long long int rs_full_events;
  long long int ioq_full_cycle;
  long long int ioq_full_events;
  // RNU has renamed work but ROU cannot enqueue it. This is UOQ/downstream
  // dispatch backpressure, not an all-busy ROB.
  long long int uoq_blocked_cycle;
  long long int uoq_blocked_events;
  // Exact all-ROB-entries-busy rising-edge probe exported by rapt_rou.
  long long int rob_full_events;
  long long int sq_full_cycle;
  long long int sq_full_events;

  // Commit-width distribution  (gem5: commit.committed_per_cycle / numIssuedDist)
  //   commit_0_cycle == wbu_stall_cycle (no commit)
  //   commit_1_cycle  = wbu_valid && !wbu_valid_b
  //   commit_2_cycle == dual_commit_cnt  (kept separate for clarity)
  long long int commit_1_cycle;
  long long int commit_2_cycle;

  // Rename/dispatch status mix  (gem5: rename.status::Running/Blocked/Idle/Squashing)
  long long int dispatch_running_cycle; // rnu_valid && rou_ready
  long long int dispatch_blocked_cycle; // rnu_valid && !rou_ready  (== rou_hazard_cycle)
  long long int dispatch_idle_cycle;    // !rnu_valid && !squash
  long long int dispatch_squash_cycle;  // flush_pipe_r drain window
} PMUState;

#define panic(format, ...) Assert(0, format, ##__VA_ARGS__)

#define TODO() panic("please implement me")

int reg_str2idx(const char *reg);

void reg_display(int n = GPR_SIZE);

uint64_t get_time();

#endif /* __NPC_COMMON_H__ */