/* Checkpoint save/restore: see include/checkpoint.h for design notes. */
#include <checkpoint.h>
#include <common.h>
#include <cpu.h>
#include <memory.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <errno.h>

extern NPCState npc;
extern PMUState pmu;

/* ---------------------------------------------------------------------------
 * Configuration (set from CLI parsing)
 * ------------------------------------------------------------------------ */
static int save_enabled = 0;
static int load_enabled = 0;
static int save_done = 0;
static int save_exit_after = 0;
static int save_triggered = 0;
static int save_cycle_valid = 0;
static int save_instr_valid = 0;
static int save_pc_valid = 0;
static int save_pc_seen = 0;
static uint64_t save_cycle = 0;
static uint64_t save_instr = 0;
static word_t save_pc = 0;
static char save_trigger_desc[128] = {0};
static char save_dir[1024] = {0};
static char load_dir[1024] = {0};
static uint64_t resume_pmu_cycle_base = 0;
static uint64_t resume_pmu_instr_base = 0;
static int resume_ready = 1;
static uint64_t quiesce_wait_cycles = 0;

/* Snapshot of arch state captured from disk; injected after reset. */
typedef struct
{
  word_t pc;
  word_t rpc;
  int priv;
  word_t gpr[GPR_SIZE];
  /* CSRs — keep in same logical groups as the live npc struct. */
  word_t sstatus, sie_, stvec, sscratch, sepc, scause, stval, sip, satp;
  word_t mstatus, medeleg, mideleg, mie_, mtvec;
  word_t mscratch, mepc, mcause, mtval, mip;
  /* Additional CSRs (see follow-up audit 2026-04-30):
   *   counteren: gates rdtime/rdcycle/rdinstret access from lower priv;
   *              if not restored, S-mode rdtime traps -> ECALL loops.
   *   mstatush:  RV32-only upper half of mstatus (SBE/MBE).
   *   m-counters: free-running but software-writable; preserves time bookkeeping.
   *   time/timeh: RTL-internal architectural counter (separate from CLINT mtime). */
  word_t scounteren, mcounteren;
  word_t mstatush;
  word_t mcycle, mcycleh, minstret, minstreth;
  word_t time_, timeh;
  uint8_t pmpcfg[NPC_PMP_NUM];
  word_t pmpaddr[NPC_PMP_NUM];
  uint64_t clint_mtime;
  uint64_t clint_mtimecmp;
  uint8_t clint_msip;
  uint8_t plic_priority[NPC_PLIC_NDEV + 1];
  uint32_t plic_pending;
  uint32_t plic_enable[NPC_PLIC_NCTX];
  uint8_t plic_threshold[NPC_PLIC_NCTX];
  uint32_t plic_ext_irq;
  uint64_t cycle, instr;
} arch_snapshot_t;

static arch_snapshot_t loaded_snap = {0};

/* Deferred-restore latch: set in checkpoint_inject_after_reset(), cleared
 * the first time a committed instruction's rpc matches loaded_snap.pc.
 * Drives the post-trampoline fixup (counters/mepc). */
static int post_trampoline_pending = 0;

/* ---------------------------------------------------------------------------
 * Memory regions to dump/restore
 * ------------------------------------------------------------------------ */
typedef struct
{
  const char *fname;
  paddr_t base;
  size_t size;
  int skip_if_zero; /* skip emitting file if region is all-zero */
} ckpt_region_t;

static const ckpt_region_t kRegions[] = {
    {"mem_pmem.bin", MBASE, MSIZE, 0},
    {"mem_mrom.bin", MROM_BASE, MROM_SIZE, 0},
    {"mem_sdram.bin", SDRAM_BASE, SDRAM_SIZE, 1},
    {"mem_sram.bin", SRAM_BASE, SRAM_SIZE, 1},
    {"mem_flash.bin", FLASH_BASE, FLASH_SIZE, 1},
};
#define NR_REGIONS (sizeof(kRegions) / sizeof(kRegions[0]))

static int region_all_zero(const uint8_t *p, size_t n)
{
  /* Cheap word-wise scan. */
  const uint64_t *q = (const uint64_t *)p;
  size_t words = n / 8;
  for (size_t i = 0; i < words; i++)
    if (q[i] != 0)
      return 0;
  for (size_t i = words * 8; i < n; i++)
    if (p[i] != 0)
      return 0;
  return 1;
}

static int mkdir_p(const char *path)
{
  struct stat st;
  if (stat(path, &st) == 0)
  {
    if (S_ISDIR(st.st_mode))
      return 0;
    errno = ENOTDIR;
    return -1;
  }
  if (mkdir(path, 0755) == 0)
    return 0;
  return -1;
}

/* ---------------------------------------------------------------------------
 * Save
 * ------------------------------------------------------------------------ */
static uint64_t current_pmu_cycle(void)
{
  return (pmu.active_cycle < 0) ? 0 : (uint64_t)pmu.active_cycle;
}

static uint64_t current_pmu_instr(void)
{
  return (pmu.instr_cnt < 0) ? 0 : (uint64_t)pmu.instr_cnt;
}

static uint64_t run_cycle_delta(void)
{
  uint64_t now = current_pmu_cycle();
  if (load_enabled && resume_ready && now >= resume_pmu_cycle_base)
    return now - resume_pmu_cycle_base;
  return load_enabled ? 0 : now;
}

static uint64_t run_instr_delta(void)
{
  uint64_t now = current_pmu_instr();
  if (load_enabled && resume_ready && now >= resume_pmu_instr_base)
    return now - resume_pmu_instr_base;
  return load_enabled ? 0 : now;
}

static uint64_t checkpoint_total_cycle(void)
{
  return load_enabled ? loaded_snap.cycle + run_cycle_delta() : current_pmu_cycle();
}

static uint64_t checkpoint_total_instr(void)
{
  return load_enabled ? loaded_snap.instr + run_instr_delta() : current_pmu_instr();
}

static void set_trigger_desc(const char *kind, uint64_t target, uint64_t actual)
{
  snprintf(save_trigger_desc, sizeof(save_trigger_desc),
           "%s target=%llu actual=%llu",
           kind, (unsigned long long)target, (unsigned long long)actual);
}

void checkpoint_configure_save(bool has_cycle, uint64_t cycle,
                               bool has_instr, uint64_t instr,
                               bool has_pc, word_t pc,
                               const char *dir, bool exit_after)
{
  save_enabled = 1;
  save_done = 0;
  save_triggered = 0;
  save_cycle_valid = has_cycle ? 1 : 0;
  save_instr_valid = has_instr ? 1 : 0;
  save_pc_valid = has_pc ? 1 : 0;
  save_pc_seen = 0;
  save_cycle = cycle;
  save_instr = instr;
  save_pc = pc;
  save_exit_after = exit_after ? 1 : 0;
  quiesce_wait_cycles = 0;
  save_trigger_desc[0] = '\0';
  if (!save_cycle_valid && !save_instr_valid && !save_pc_valid)
  {
    save_cycle_valid = 1;
    save_cycle = 0;
  }
  strncpy(save_dir, dir, sizeof(save_dir) - 1);
  save_dir[sizeof(save_dir) - 1] = '\0';
}

int checkpoint_save_configured(void) { return save_enabled; }

void checkpoint_note_commit(word_t committed_pc)
{
  if (!save_enabled || save_done || !save_pc_valid || save_triggered)
    return;
  if (load_enabled && !resume_ready)
    return;
  if (committed_pc == save_pc)
  {
    save_pc_seen = 1;
    snprintf(save_trigger_desc, sizeof(save_trigger_desc),
             "pc target=" FMT_WORD_NO_PREFIX " actual=" FMT_WORD_NO_PREFIX,
             save_pc, committed_pc);
  }
}

static void write_state_txt(const char *path)
{
  FILE *fp = fopen(path, "w");
  if (!fp)
  {
    Error("checkpoint: cannot open %s for write: %s", path, strerror(errno));
    return;
  }
  fprintf(fp, "# raptor-chip nsim checkpoint (architectural state)\n");
  fprintf(fp, "# format: key=hex_value (one per line). gprN: arch GPR x_N\n");
#ifdef CONFIG_ISA64
  fprintf(fp, "xlen=64\n");
#else
  fprintf(fp, "xlen=32\n");
#endif
  fprintf(fp, "cycle=%llu\n", (unsigned long long)checkpoint_total_cycle());
  fprintf(fp, "instr=%llu\n", (unsigned long long)checkpoint_total_instr());
  fprintf(fp, "sim_cycle=%llu\n", (unsigned long long)current_pmu_cycle());
  fprintf(fp, "sim_instr=%llu\n", (unsigned long long)current_pmu_instr());
  fprintf(fp, "run_cycle_delta=%llu\n", (unsigned long long)run_cycle_delta());
  fprintf(fp, "run_instr_delta=%llu\n", (unsigned long long)run_instr_delta());
  if (load_enabled)
  {
    fprintf(fp, "parent_cycle=%llu\n", (unsigned long long)loaded_snap.cycle);
    fprintf(fp, "parent_instr=%llu\n", (unsigned long long)loaded_snap.instr);
    fprintf(fp, "parent_checkpoint=%s\n", load_dir);
  }
  if (save_trigger_desc[0] != '\0')
    fprintf(fp, "save_trigger=%s\n", save_trigger_desc);
  fprintf(fp, "pc=" FMT_WORD "\n", *npc.pc);
  fprintf(fp, "rpc=" FMT_WORD "\n", *npc.rpc);
  fprintf(fp, "priv=%d\n", (int)*npc.priv);
  for (int i = 0; i < GPR_SIZE; i++)
    fprintf(fp, "gpr%d=" FMT_WORD "\n", i, npc.gpr[i]);
  /* CSRs */
  fprintf(fp, "csr_sstatus=" FMT_WORD "\n", *npc.sstatus);
  fprintf(fp, "csr_sie=" FMT_WORD "\n", *npc.sie____);
  fprintf(fp, "csr_stvec=" FMT_WORD "\n", *npc.stvec__);
  fprintf(fp, "csr_sscratch=" FMT_WORD "\n", *npc.sscratch);
  fprintf(fp, "csr_sepc=" FMT_WORD "\n", *npc.sepc___);
  fprintf(fp, "csr_scause=" FMT_WORD "\n", *npc.scause_);
  fprintf(fp, "csr_stval=" FMT_WORD "\n", *npc.stval__);
  fprintf(fp, "csr_sip=" FMT_WORD "\n", *npc.sip____);
  fprintf(fp, "csr_satp=" FMT_WORD "\n", *npc.satp___);
  fprintf(fp, "csr_mstatus=" FMT_WORD "\n", *npc.mstatus);
  fprintf(fp, "csr_medeleg=" FMT_WORD "\n", *npc.medeleg);
  fprintf(fp, "csr_mideleg=" FMT_WORD "\n", *npc.mideleg);
  fprintf(fp, "csr_mie=" FMT_WORD "\n", *npc.mie____);
  fprintf(fp, "csr_mtvec=" FMT_WORD "\n", *npc.mtvec__);
  fprintf(fp, "csr_mscratch=" FMT_WORD "\n", *npc.mscratch);
  fprintf(fp, "csr_mepc=" FMT_WORD "\n", *npc.mepc___);
  fprintf(fp, "csr_mcause=" FMT_WORD "\n", *npc.mcause_);
  fprintf(fp, "csr_mtval=" FMT_WORD "\n", *npc.mtval__);
  fprintf(fp, "csr_mip=" FMT_WORD "\n", *npc.mip____);

  /* Counter-enable + RV32 upper-half + counters (see audit 2026-04-30). */
  if (npc.scounte != NULL)
    fprintf(fp, "csr_scounteren=" FMT_WORD "\n", *npc.scounte);
  if (npc.mcounte != NULL)
    fprintf(fp, "csr_mcounteren=" FMT_WORD "\n", *npc.mcounte);
  if (npc.mstatush != NULL)
    fprintf(fp, "csr_mstatush=" FMT_WORD "\n", *npc.mstatush);
  if (npc.mcycle_ != NULL)
    fprintf(fp, "csr_mcycle=" FMT_WORD "\n", *npc.mcycle_);
  if (npc.mcycleh != NULL)
    fprintf(fp, "csr_mcycleh=" FMT_WORD "\n", *npc.mcycleh);
  if (npc.minstret != NULL)
    fprintf(fp, "csr_minstret=" FMT_WORD "\n", *npc.minstret);
  if (npc.minstreth != NULL)
    fprintf(fp, "csr_minstreth=" FMT_WORD "\n", *npc.minstreth);
  if (npc.time___ != NULL)
    fprintf(fp, "csr_time=" FMT_WORD "\n", *npc.time___);
  if (npc.timeh__ != NULL)
    fprintf(fp, "csr_timeh=" FMT_WORD "\n", *npc.timeh__);

  /* PMP state */
  if (npc.pmpcfg != NULL && npc.pmpaddr != NULL)
  {
    for (int i = 0; i < NPC_PMP_NUM; i++)
    {
      fprintf(fp, "pmpcfg%d=0x%02x\n", i, (unsigned int)(npc.pmpcfg[i] & 0xffu));
      fprintf(fp, "pmpaddr%d=" FMT_WORD "\n", i, npc.pmpaddr[i]);
    }
  }

  /* CLINT device state (not part of RAM image, must be persisted explicitly). */
  {
    uint64_t mtime = (npc.clint_mtime != NULL) ? *npc.clint_mtime : 0;
    uint64_t mtimecmp = (npc.clint_mtimecmp != NULL) ? *npc.clint_mtimecmp : ~0ull;
    uint8_t msip = (npc.clint_msip != NULL) ? *npc.clint_msip : 0;
    fprintf(fp, "clint_mtime=0x%016llx\n", (unsigned long long)mtime);
    fprintf(fp, "clint_mtimecmp=0x%016llx\n", (unsigned long long)mtimecmp);
    fprintf(fp, "clint_msip=0x%02x\n", (unsigned int)(msip & 0x1u));
  }

  /* PLIC device state. Claim/complete has no extra architectural storage; the
   * priority/pending/enable/threshold registers plus ext_irq edge latch fully
   * describe this RTL instance. */
  if (npc.plic_priority != NULL && npc.plic_pending != NULL &&
      npc.plic_enable != NULL && npc.plic_threshold != NULL &&
      npc.plic_ext_irq != NULL)
  {
    fprintf(fp, "plic_pending=0x%08x\n", (unsigned int)(*npc.plic_pending));
    fprintf(fp, "plic_ext_irq=0x%08x\n", (unsigned int)(*npc.plic_ext_irq));
    for (int i = 0; i <= NPC_PLIC_NDEV; i++)
      fprintf(fp, "plic_priority%d=0x%02x\n", i,
              (unsigned int)(npc.plic_priority[i] & 0x7u));
    for (int c = 0; c < NPC_PLIC_NCTX; c++)
    {
      fprintf(fp, "plic_enable%d=0x%08x\n", c, (unsigned int)npc.plic_enable[c]);
      fprintf(fp, "plic_threshold%d=0x%02x\n", c,
              (unsigned int)(npc.plic_threshold[c] & 0x7u));
    }
  }
  fclose(fp);
}

/* ---------------------------------------------------------------------------
 * Sparse region format
 *
 * Each non-empty region produces TWO files:
 *   - <region>.meta : plain-text manifest. Header keys, then chunk records.
 *       version=1
 *       size=<region_size_hex>
 *       chunk_size=<chunk_size_hex>
 *       chunks=<count_dec>
 *       chunk=<offset_hex>          (one line per non-zero chunk, in order)
 *   - <region>.bin  : binary, concatenation of non-zero chunks (each
 *                     chunk_size bytes), in the same order as the meta file.
 *
 * Backward compat on load: if `.meta` is missing but a full-size `.bin`
 * exists, treat it as a flat dump (legacy format).
 * ------------------------------------------------------------------------ */
#define CKPT_CHUNK_SIZE 4096u /* 4 KiB pages */

static void write_region(const char *dir, const ckpt_region_t *r)
{
  uint8_t *host = guest_to_host(r->base);
  if (host == NULL)
    return;
  if (r->skip_if_zero && region_all_zero(host, r->size))
  {
    Log("checkpoint: skip empty region %s (%zu bytes all-zero)", r->fname, r->size);
    return;
  }

  char meta_path[2048], bin_path[2048];
  snprintf(meta_path, sizeof(meta_path), "%s/%s.meta", dir, r->fname);
  snprintf(bin_path, sizeof(bin_path), "%s/%s", dir, r->fname);

  FILE *fmeta = fopen(meta_path, "w");
  FILE *fbin = fopen(bin_path, "wb");
  if (!fmeta || !fbin)
  {
    Error("checkpoint: cannot open %s/%s for write: %s",
          meta_path, bin_path, strerror(errno));
    if (fmeta)
      fclose(fmeta);
    if (fbin)
      fclose(fbin);
    return;
  }

  const size_t chunk = CKPT_CHUNK_SIZE;
  const size_t total = r->size;
  size_t nz_chunks = 0;
  size_t bin_bytes = 0;

  /* Two-pass would be cleaner, but we can stream: write data chunks to .bin
   * during the scan, accumulate offsets, emit meta header + offsets at end. */
  size_t *offsets = NULL;
  size_t offsets_cap = 0;

  for (size_t off = 0; off < total; off += chunk)
  {
    size_t this_chunk = (off + chunk <= total) ? chunk : (total - off);
    if (region_all_zero(host + off, this_chunk))
      continue;

    if (nz_chunks == offsets_cap)
    {
      offsets_cap = offsets_cap ? offsets_cap * 2 : 64;
      offsets = (size_t *)realloc(offsets, offsets_cap * sizeof(size_t));
    }
    offsets[nz_chunks++] = off;
    /* Always write CHUNK_SIZE bytes (zero-pad the tail chunk if any). */
    fwrite(host + off, 1, this_chunk, fbin);
    if (this_chunk < chunk)
    {
      static const uint8_t zeros[CKPT_CHUNK_SIZE] = {0};
      fwrite(zeros, 1, chunk - this_chunk, fbin);
    }
    bin_bytes += chunk;
  }

  fprintf(fmeta, "# raptor-chip nsim checkpoint region manifest\n");
  fprintf(fmeta, "version=1\n");
  fprintf(fmeta, "size=0x%zx\n", total);
  fprintf(fmeta, "chunk_size=0x%zx\n", chunk);
  fprintf(fmeta, "chunks=%zu\n", nz_chunks);
  for (size_t k = 0; k < nz_chunks; k++)
    fprintf(fmeta, "chunk=0x%zx\n", offsets[k]);
  free(offsets);

  fclose(fmeta);
  fclose(fbin);

  size_t total_chunks = (total + chunk - 1) / chunk;
  Log("checkpoint: wrote %s (%zu/%zu chunks non-zero, %zu bytes, %.1f%% sparse)",
      r->fname, nz_chunks, total_chunks, bin_bytes,
      100.0 * (1.0 - (double)bin_bytes / (double)total));
}

static void do_save(void)
{
  if (mkdir_p(save_dir) != 0)
  {
    Error("checkpoint: cannot create dir %s: %s", save_dir, strerror(errno));
    save_enabled = 0;
    return;
  }
  char path[2048];
  snprintf(path, sizeof(path), "%s/state.txt", save_dir);
  write_state_txt(path);
  Log("checkpoint: wrote %s", path);
  for (size_t i = 0; i < NR_REGIONS; i++)
    write_region(save_dir, &kRegions[i]);
  Log(FMT_GREEN("checkpoint: SAVED at cycle %llu instr %llu, pc=" FMT_WORD_NO_PREFIX " -> %s"),
      (unsigned long long)checkpoint_total_cycle(),
      (unsigned long long)checkpoint_total_instr(), *npc.pc, save_dir);
  save_done = 1;
}

bool checkpoint_save_tick(void)
{
  if (!save_enabled || save_done)
    return false;
  if (load_enabled && !resume_ready)
    return false;

  if (!save_triggered)
  {
    uint64_t cycle_delta = run_cycle_delta();
    uint64_t instr_delta = run_instr_delta();
    if (save_cycle_valid && cycle_delta >= save_cycle)
    {
      save_triggered = 1;
      set_trigger_desc("cycle", save_cycle, cycle_delta);
    }
    else if (save_instr_valid && instr_delta >= save_instr)
    {
      save_triggered = 1;
      set_trigger_desc("instr", save_instr, instr_delta);
    }
    else if (save_pc_valid && save_pc_seen)
    {
      save_triggered = 1;
      if (save_trigger_desc[0] == '\0')
        snprintf(save_trigger_desc, sizeof(save_trigger_desc),
                 "pc target=" FMT_WORD_NO_PREFIX, save_pc);
    }
    if (!save_triggered)
      return false;

    quiesce_wait_cycles = 0;
    Log("checkpoint: trigger hit (%s), waiting for pipeline quiesce",
        save_trigger_desc[0] ? save_trigger_desc : "manual");
  }

  /* Defer save until pipeline is quiesced so committed stores have drained
   * from SQ -> bus -> host backing buffer. Otherwise mem_pmem.bin loses the
   * tail of in-flight writes.
   *   - rob_empty            : ROB drained (head==tail && !head.busy)
   *   - sq_valid==0          : no post-commit store in flight
   *   - stq_valid==0         : no speculative store buffered
   * Note: SQ_SIZE=8 so sq_valid is one byte (uint8_t); STQ same.
   * If quiesce never happens (defensive cap of 100k cycles), force-save
   * with a warning so we don't hang the run forever. */
  bool rob_q = (npc.rob_empty != NULL) ? (*npc.rob_empty != 0) : true;
  bool sq_q = (npc.sq_valid != NULL) ? (*npc.sq_valid == 0) : true;
  bool stq_q = (npc.stq_valid != NULL) ? (*npc.stq_valid == 0) : true;
  if (!(rob_q && sq_q && stq_q))
  {
    quiesce_wait_cycles++;
    if (quiesce_wait_cycles < 100000)
      return false;
    Log("checkpoint: quiesce wait exceeded 100k cycles "
        "(rob_q=%d sq_q=%d stq_q=%d) — forcing save (memory may be inconsistent)",
        rob_q, sq_q, stq_q);
  }
  else if (quiesce_wait_cycles > 0)
  {
    Log("checkpoint: pipeline quiesced after %llu wait cycles",
        (unsigned long long)quiesce_wait_cycles);
  }
  do_save();
  return save_exit_after ? true : false;
}

/* ---------------------------------------------------------------------------
 * Load
 * ------------------------------------------------------------------------ */
int checkpoint_load_configured(void) { return load_enabled; }

static int parse_word(const char *s, word_t *out)
{
  unsigned long long v = 0;
  if (s[0] == '0' && (s[1] == 'x' || s[1] == 'X'))
    s += 2;
  if (sscanf(s, "%llx", &v) != 1)
    return -1;
  *out = (word_t)v;
  return 0;
}

static int read_state_txt(const char *path, arch_snapshot_t *s)
{
  FILE *fp = fopen(path, "r");
  if (!fp)
  {
    Error("checkpoint: cannot open %s: %s", path, strerror(errno));
    return -1;
  }
  char line[256];
  while (fgets(line, sizeof(line), fp))
  {
    if (line[0] == '#' || line[0] == '\n' || line[0] == '\0')
      continue;
    char key[64], val[128];
    if (sscanf(line, "%63[^=]=%127s", key, val) != 2)
      continue;
    word_t w = 0;
    if (strncmp(key, "gpr", 3) == 0)
    {
      int idx = atoi(key + 3);
      if (idx >= 0 && idx < GPR_SIZE && parse_word(val, &w) == 0)
        s->gpr[idx] = w;
      continue;
    }
    if (strncmp(key, "pmpcfg", 6) == 0)
    {
      int idx = atoi(key + 6);
      unsigned int v = 0;
      if (idx >= 0 && idx < NPC_PMP_NUM && sscanf(val, "%x", &v) == 1)
        s->pmpcfg[idx] = (uint8_t)(v & 0xffu);
      continue;
    }
    if (strncmp(key, "pmpaddr", 7) == 0)
    {
      int idx = atoi(key + 7);
      if (idx >= 0 && idx < NPC_PMP_NUM && parse_word(val, &w) == 0)
        s->pmpaddr[idx] = w;
      continue;
    }
    if (strncmp(key, "plic_priority", 13) == 0)
    {
      int idx = atoi(key + 13);
      unsigned int v = 0;
      if (idx >= 0 && idx <= NPC_PLIC_NDEV && sscanf(val, "%x", &v) == 1)
        s->plic_priority[idx] = (uint8_t)(v & 0x7u);
      continue;
    }
    if (strncmp(key, "plic_enable", 11) == 0)
    {
      int idx = atoi(key + 11);
      unsigned int v = 0;
      if (idx >= 0 && idx < NPC_PLIC_NCTX && sscanf(val, "%x", &v) == 1)
        s->plic_enable[idx] = (uint32_t)v;
      continue;
    }
    if (strncmp(key, "plic_threshold", 14) == 0)
    {
      int idx = atoi(key + 14);
      unsigned int v = 0;
      if (idx >= 0 && idx < NPC_PLIC_NCTX && sscanf(val, "%x", &v) == 1)
        s->plic_threshold[idx] = (uint8_t)(v & 0x7u);
      continue;
    }
    if (strcmp(key, "pc") == 0)
    {
      parse_word(val, &s->pc);
    }
    else if (strcmp(key, "rpc") == 0)
    {
      parse_word(val, &s->rpc);
    }
    else if (strcmp(key, "priv") == 0)
    {
      s->priv = atoi(val);
    }
    else if (strcmp(key, "cycle") == 0)
    {
      s->cycle = strtoull(val, NULL, 10);
    }
    else if (strcmp(key, "instr") == 0)
    {
      s->instr = strtoull(val, NULL, 10);
    }
    else if (strcmp(key, "csr_sstatus") == 0)
      parse_word(val, &s->sstatus);
    else if (strcmp(key, "csr_sie") == 0)
      parse_word(val, &s->sie_);
    else if (strcmp(key, "csr_stvec") == 0)
      parse_word(val, &s->stvec);
    else if (strcmp(key, "csr_sscratch") == 0)
      parse_word(val, &s->sscratch);
    else if (strcmp(key, "csr_sepc") == 0)
      parse_word(val, &s->sepc);
    else if (strcmp(key, "csr_scause") == 0)
      parse_word(val, &s->scause);
    else if (strcmp(key, "csr_stval") == 0)
      parse_word(val, &s->stval);
    else if (strcmp(key, "csr_sip") == 0)
      parse_word(val, &s->sip);
    else if (strcmp(key, "csr_satp") == 0)
      parse_word(val, &s->satp);
    else if (strcmp(key, "csr_mstatus") == 0)
      parse_word(val, &s->mstatus);
    else if (strcmp(key, "csr_medeleg") == 0)
      parse_word(val, &s->medeleg);
    else if (strcmp(key, "csr_mideleg") == 0)
      parse_word(val, &s->mideleg);
    else if (strcmp(key, "csr_mie") == 0)
      parse_word(val, &s->mie_);
    else if (strcmp(key, "csr_mtvec") == 0)
      parse_word(val, &s->mtvec);
    else if (strcmp(key, "csr_mscratch") == 0)
      parse_word(val, &s->mscratch);
    else if (strcmp(key, "csr_mepc") == 0)
      parse_word(val, &s->mepc);
    else if (strcmp(key, "csr_mcause") == 0)
      parse_word(val, &s->mcause);
    else if (strcmp(key, "csr_mtval") == 0)
      parse_word(val, &s->mtval);
    else if (strcmp(key, "csr_mip") == 0)
      parse_word(val, &s->mip);
    else if (strcmp(key, "csr_scounteren") == 0)
      parse_word(val, &s->scounteren);
    else if (strcmp(key, "csr_mcounteren") == 0)
      parse_word(val, &s->mcounteren);
    else if (strcmp(key, "csr_mstatush") == 0)
      parse_word(val, &s->mstatush);
    else if (strcmp(key, "csr_mcycle") == 0)
      parse_word(val, &s->mcycle);
    else if (strcmp(key, "csr_mcycleh") == 0)
      parse_word(val, &s->mcycleh);
    else if (strcmp(key, "csr_minstret") == 0)
      parse_word(val, &s->minstret);
    else if (strcmp(key, "csr_minstreth") == 0)
      parse_word(val, &s->minstreth);
    else if (strcmp(key, "csr_time") == 0)
      parse_word(val, &s->time_);
    else if (strcmp(key, "csr_timeh") == 0)
      parse_word(val, &s->timeh);
    else if (strcmp(key, "clint_mtime") == 0)
    {
      unsigned long long v = 0;
      if (sscanf(val, "%llx", &v) == 1)
        s->clint_mtime = (uint64_t)v;
    }
    else if (strcmp(key, "clint_mtimecmp") == 0)
    {
      unsigned long long v = 0;
      if (sscanf(val, "%llx", &v) == 1)
        s->clint_mtimecmp = (uint64_t)v;
    }
    else if (strcmp(key, "clint_msip") == 0)
    {
      unsigned int v = 0;
      if (sscanf(val, "%x", &v) == 1)
        s->clint_msip = (uint8_t)(v & 0x1u);
    }
    else if (strcmp(key, "plic_pending") == 0)
    {
      unsigned int v = 0;
      if (sscanf(val, "%x", &v) == 1)
        s->plic_pending = (uint32_t)v;
    }
    else if (strcmp(key, "plic_ext_irq") == 0)
    {
      unsigned int v = 0;
      if (sscanf(val, "%x", &v) == 1)
        s->plic_ext_irq = (uint32_t)v;
    }
  }
  fclose(fp);
  return 0;
}

static void load_region(const char *dir, const ckpt_region_t *r)
{
  char meta_path[2048], bin_path[2048];
  snprintf(meta_path, sizeof(meta_path), "%s/%s.meta", dir, r->fname);
  snprintf(bin_path, sizeof(bin_path), "%s/%s", dir, r->fname);

  uint8_t *host = guest_to_host(r->base);
  if (host == NULL)
    return; /* region not backed in this build config */

  FILE *fmeta = fopen(meta_path, "r");
  if (!fmeta)
  {
    /* Legacy fallback: full-size flat dump, or missing entirely (= all-zero). */
    FILE *fp = fopen(bin_path, "rb");
    if (!fp)
      return;
    size_t got = fread(host, 1, r->size, fp);
    fclose(fp);
    Log("checkpoint: loaded %s (legacy flat, %zu bytes)", bin_path, got);
    return;
  }

  /* Parse manifest. */
  size_t total = 0, chunk = 0, nchunks = 0;
  size_t *offsets = NULL;
  size_t offsets_cap = 0, offsets_n = 0;

  char line[128];
  while (fgets(line, sizeof(line), fmeta))
  {
    if (line[0] == '#' || line[0] == '\n')
      continue;
    if (strncmp(line, "size=", 5) == 0)
    {
      total = (size_t)strtoull(line + 5, NULL, 0);
    }
    else if (strncmp(line, "chunk_size=", 11) == 0)
    {
      chunk = (size_t)strtoull(line + 11, NULL, 0);
    }
    else if (strncmp(line, "chunks=", 7) == 0)
    {
      nchunks = (size_t)strtoull(line + 7, NULL, 10);
    }
    else if (strncmp(line, "chunk=", 6) == 0)
    {
      if (offsets_n == offsets_cap)
      {
        offsets_cap = offsets_cap ? offsets_cap * 2 : 64;
        offsets = (size_t *)realloc(offsets, offsets_cap * sizeof(size_t));
      }
      offsets[offsets_n++] = (size_t)strtoull(line + 6, NULL, 0);
    }
  }
  fclose(fmeta);

  if (chunk == 0 || total == 0 || total != r->size)
  {
    Error("checkpoint: %s has bad/mismatched header (size=0x%zx region=0x%zx)",
          meta_path, total, r->size);
    free(offsets);
    return;
  }
  if (offsets_n != nchunks)
  {
    Log("checkpoint: %s chunks=%zu but found %zu offset records (using actual)",
        meta_path, nchunks, offsets_n);
  }

  /* Zero region first; sparse load only writes the listed chunks. */
  memset(host, 0, r->size);

  FILE *fbin = fopen(bin_path, "rb");
  if (!fbin)
  {
    Error("checkpoint: meta found but %s missing", bin_path);
    free(offsets);
    return;
  }
  uint8_t *buf = (uint8_t *)malloc(chunk);
  size_t bytes = 0;
  for (size_t k = 0; k < offsets_n; k++)
  {
    if (fread(buf, 1, chunk, fbin) != chunk)
    {
      Error("checkpoint: short read at chunk %zu of %s", k, bin_path);
      break;
    }
    size_t off = offsets[k];
    if (off >= r->size)
      continue;
    size_t this_chunk = (off + chunk <= r->size) ? chunk : (r->size - off);
    memcpy(host + off, buf, this_chunk);
    bytes += this_chunk;
  }
  free(buf);
  free(offsets);
  fclose(fbin);
  Log("checkpoint: loaded %s (sparse: %zu chunks, %zu bytes -> %zu region bytes)",
      r->fname, offsets_n, offsets_n * chunk, bytes);
}

/* ---------------------------------------------------------------------------
 * Trampoline: written into MROM. After reset, the IFU fetches from MROM_BASE
 * (the reset vector), runs this restore sequence, and `mret`s into ckpt_pc
 * with priv = ckpt_priv.
 *
 * Restoration is performed via real RISC-V instructions because the rapt
 * RTL's `rf[]` is a read-only continuous-assign debug shadow — direct C++
 * writes don't propagate to the live PRF. Real load instructions go through
 * rename -> PRF write -> maptable update, so they correctly re-establish
 * architectural register state regardless of microarchitectural changes.
 *
 * Sequence (skip x0; t0/x5 and t1/x6 are clobbered as scratch — restored last):
 *
 *   auipc t0, 0                       ; t0 = MROM_BASE
 *   addi  t0, t0, DATA_OFF            ; t0 -> data table
 *   for csr in [mtvec, mscratch, mcause, mtval, medeleg, mideleg, satp,
 *               sepc, scause, stval, sscratch, stvec, mie, mip, mepc]:
 *     l[wd] t1, off(t0); csrw <csr>, t1
 *   for x in [1..4, 7..31]:           ; skip x0, x5(t0), x6(t1)
 *     l[wd] xN, off(t0)
 *   l[wd] t1, off_mstatus(t0); csrw mstatus, t1   ; mstatus LAST so MPP is set just before mret
 *   l[wd] t1, off_x6(t0)              ; restore arch t1
 *   l[wd] t0, off_x5(t0)              ; restore arch t0 (loses base ptr)
 *   mret                              ; -> ckpt_pc, priv = MPP
 *
 * Notes:
 * - sstatus/sip/sie are skipped: they are aliases of mstatus/mip/mie and are
 *   covered by writing the M-level CSRs.
 * - mstatus_for_mret is built from saved mstatus with MPP=saved priv and
 *   MPIE=saved MIE so that post-mret priv = saved priv and post-mret MIE =
 *   saved MIE.
 * - All offsets fit in 12-bit signed immediates (data table < 1KB).
 * ------------------------------------------------------------------------ */

#define ENC_CSRRW_X0(csr, rs1) \
  (((uint32_t)(csr) << 20) | ((uint32_t)(rs1) << 15) | (0x1u << 12) | (0u << 7) | 0x73u)
#define ENC_AUIPC(rd, imm20) \
  ((uint32_t)((imm20) & 0xfffff) << 12 | ((uint32_t)(rd) << 7) | 0x17u)
#define ENC_ADDI(rd, rs1, imm12) \
  (((uint32_t)((imm12) & 0xfff) << 20) | ((uint32_t)(rs1) << 15) | (0u << 12) | ((uint32_t)(rd) << 7) | 0x13u)
#define ENC_LW(rd, rs1, imm12) \
  (((uint32_t)((imm12) & 0xfff) << 20) | ((uint32_t)(rs1) << 15) | (0x2u << 12) | ((uint32_t)(rd) << 7) | 0x03u)
#define ENC_LD(rd, rs1, imm12) \
  (((uint32_t)((imm12) & 0xfff) << 20) | ((uint32_t)(rs1) << 15) | (0x3u << 12) | ((uint32_t)(rd) << 7) | 0x03u)
#define MRET_INST 0x30200073u
/* sfence.vma x0, x0 : flush all TLB entries (required after csrw satp). */
#define SFENCE_VMA_INST 0x12000073u
/* fence.i           : flush local instruction cache / prefetch buffer. */
#define FENCE_I_INST 0x0000100fu

#define X_T0 5
#define X_T1 6

#define CSR_MEPC 0x341
#define CSR_MSTATUS 0x300
#define CSR_MTVEC 0x305
#define CSR_MSCRATCH 0x340
#define CSR_MCAUSE 0x342
#define CSR_MTVAL 0x343
#define CSR_MIP 0x344
#define CSR_MIE 0x304
#define CSR_MEDELEG 0x302
#define CSR_MIDELEG 0x303
#define CSR_SATP 0x180
#define CSR_SEPC 0x141
#define CSR_SCAUSE 0x142
#define CSR_STVAL 0x143
#define CSR_SSCRATCH 0x140
#define CSR_STVEC 0x105
#define CSR_SCOUNTEREN 0x106
#define CSR_MCOUNTEREN 0x306
#define CSR_MSTATUSH 0x310

/* Pick load instruction width matching the target XLEN. */
#ifdef CONFIG_ISA64
#define ENC_LXLEN(rd, rs1, imm) ENC_LD(rd, rs1, imm)
#define XLEN_BYTES 8
#else
#define ENC_LXLEN(rd, rs1, imm) ENC_LW(rd, rs1, imm)
#define XLEN_BYTES 4
#endif

/* Data table layout (slot index, each slot is XLEN_BYTES wide):
 *   slot 0..31 : GPR x0..x31 (slot 0 unused, kept for clean indexing)
 *   slot 32    : mstatus_for_mret (written last, sets MPP)
 *   slot 33..  : other CSRs in CSR_TABLE order
 */
#define SLOT_GPR(i) (i)
#define SLOT_MSTATUS 32
#define SLOT_OTHER_CSR0 33

typedef struct
{
  uint16_t csr_addr;
  word_t arch_snapshot_t::*field;
  const char *name;
} csr_entry_t;

static const csr_entry_t kCsrRestoreList[] = {
    {CSR_MTVEC, &arch_snapshot_t::mtvec, "mtvec"},
    {CSR_MSCRATCH, &arch_snapshot_t::mscratch, "mscratch"},
    {CSR_MCAUSE, &arch_snapshot_t::mcause, "mcause"},
    {CSR_MTVAL, &arch_snapshot_t::mtval, "mtval"},
    {CSR_MEDELEG, &arch_snapshot_t::medeleg, "medeleg"},
    {CSR_MIDELEG, &arch_snapshot_t::mideleg, "mideleg"},
    {CSR_SATP, &arch_snapshot_t::satp, "satp"},
    {CSR_SEPC, &arch_snapshot_t::sepc, "sepc"},
    {CSR_SCAUSE, &arch_snapshot_t::scause, "scause"},
    {CSR_STVAL, &arch_snapshot_t::stval, "stval"},
    {CSR_SSCRATCH, &arch_snapshot_t::sscratch, "sscratch"},
    {CSR_STVEC, &arch_snapshot_t::stvec, "stvec"},
    {CSR_MIE, &arch_snapshot_t::mie_, "mie"},
    {CSR_MIP, &arch_snapshot_t::mip, "mip"},
    {CSR_MEPC, &arch_snapshot_t::mepc, "mepc"},
    {CSR_SCOUNTEREN, &arch_snapshot_t::scounteren, "scounteren"},
    {CSR_MCOUNTEREN, &arch_snapshot_t::mcounteren, "mcounteren"},
    /* mstatush: RTL write path WARL-zeros it (SBE/MBE not implemented).
     * Restore via direct-host write below to be future-proof against RTL changes. */
    /* mstatus written LAST via dedicated slot — see below. */
};
#define NR_CSR_RESTORE (sizeof(kCsrRestoreList) / sizeof(kCsrRestoreList[0]))

static inline void put_word(uint8_t *data, size_t slot, word_t v)
{
  uint8_t *p = data + slot * XLEN_BYTES;
  for (int b = 0; b < XLEN_BYTES; b++)
    p[b] = (uint8_t)((v >> (b * 8)) & 0xff);
}

static void build_trampoline(uint8_t *mrom, const arch_snapshot_t *s)
{
  /* Compute total code size first so we can place data table right after it. */
  /*   2 setup
   *   2 * NR_CSR_RESTORE      (lw + csrw per CSR)
   *   1                       (sfence.vma after satp/CSR loop, before GPRs)
   *   28                      (load 28 GPRs: skip x0/x5/x6)
   *   2                       (lw + csrw mstatus)
   *   2                       (lw t1; lw t0)
   *   1                       (fence.i — flush stale prefetch of trampoline)
   *   1                       (mret)
   */
  const int n_setup = 2;
  const int n_csr = 2 * (int)NR_CSR_RESTORE;
  const int n_sfence = 1;
  const int n_gpr = 29; /* x1..x31 minus x5(t0) and x6(t1) */
  const int n_mstatus = 2;
  const int n_final = 2;
  const int n_fencei = 1;
  const int n_mret = 1;
  const int n_total = n_setup + n_csr + n_sfence + n_gpr + n_mstatus +
                      n_final + n_fencei + n_mret;
  const int code_bytes = n_total * 4;
  const int data_off = code_bytes;

  uint32_t *code = (uint32_t *)mrom;
  int i = 0;

  /* Setup: t0 = MROM_BASE + DATA_OFF (= base of data table). */
  code[i++] = ENC_AUIPC(X_T0, 0);
  code[i++] = ENC_ADDI(X_T0, X_T0, data_off);

  /* CSR restore: lw t1, slot*XB(t0); csrw <csr>, t1. */
  for (size_t k = 0; k < NR_CSR_RESTORE; k++)
  {
    int slot = SLOT_OTHER_CSR0 + (int)k;
    code[i++] = ENC_LXLEN(X_T1, X_T0, slot * XLEN_BYTES);
    code[i++] = ENC_CSRRW_X0(kCsrRestoreList[k].csr_addr, X_T1);
  }

  /* sfence.vma after writing satp: flush TLB so post-mret S-mode fetches
   * use the restored page-table walk. (Per RISC-V Privileged spec, an
   * SFENCE.VMA is required after a satp write; rapt's ITLB/STLB/LTLB are
   * empty at reset but we still issue this for spec-compliance and to be
   * robust to any reset-time TLB initialization changes.) */
  code[i++] = SFENCE_VMA_INST;

  /* GPR restore: skip x0, x5(t0), x6(t1). Restore in reverse-arch-order
   * doesn't matter; pick natural ascending order. */
  for (int r = 1; r < 32; r++)
  {
    if (r == X_T0 || r == X_T1)
      continue;
    code[i++] = ENC_LXLEN(r, X_T0, SLOT_GPR(r) * XLEN_BYTES);
  }

  /* mstatus LAST (sets MPP for the upcoming mret). */
  code[i++] = ENC_LXLEN(X_T1, X_T0, SLOT_MSTATUS * XLEN_BYTES);
  code[i++] = ENC_CSRRW_X0(CSR_MSTATUS, X_T1);

  /* Final scratch restores. */
  code[i++] = ENC_LXLEN(X_T1, X_T0, SLOT_GPR(X_T1) * XLEN_BYTES);
  code[i++] = ENC_LXLEN(X_T0, X_T0, SLOT_GPR(X_T0) * XLEN_BYTES); /* base lost after this */

  /* fence.i: ensure any cached / prefetched fetch of the trampoline itself
   * (since we wrote MROM via host backdoor after reset deassertion) is
   * invalidated before the mret transfers control to S-mode kernel code. */
  code[i++] = FENCE_I_INST;

  /* mret -> ckpt_pc, priv = MPP. */
  code[i++] = MRET_INST;

  if (i != n_total)
  {
    Error("checkpoint: trampoline size mismatch (built %d, expected %d)", i, n_total);
  }

  /* Compose mstatus_for_mret:
   *   - MPP[12:11]  = saved priv
   *   - MPIE[7]     = saved MIE[3]   (so post-mret MIE = saved MIE)
   *   - MIE[3]      = 0              (mask M-mode interrupts during the
   *                                   1-2 cycle window between csrw mstatus
   *                                   and mret; otherwise a pending MIP bit
   *                                   would divert PC to mtvec instead of
   *                                   ckpt_pc. mret restores MIE←MPIE so
   *                                   architectural MIE post-resume is
   *                                   still saved value.)
   *   - other bits  = saved mstatus
   * We deliberately preserve fields like SUM/MXR/MPRV/SPP/SPIE so post-mret
   * S-mode behavior matches the saved point.
   */
  word_t mstatus_for_mret = s->mstatus;
  mstatus_for_mret &= ~((word_t)0x3 << 11);
  mstatus_for_mret |= ((word_t)(s->priv & 0x3) << 11);
  word_t saved_mie_bit = (s->mstatus >> 3) & 0x1;
  mstatus_for_mret &= ~((word_t)1 << 7);
  mstatus_for_mret |= (saved_mie_bit << 7);
  mstatus_for_mret &= ~((word_t)1 << 3); /* clear MIE; restored via MPIE */

  /* Special-case: for the mepc CSR write inside the loop, we want mepc to end
   * up holding ckpt_pc (so that mret jumps there). We put ckpt_pc into the
   * mepc slot regardless of whatever was saved at snapshot time. */

  /* Write data table. */
  uint8_t *data = mrom + data_off;
  /* GPRs */
  for (int r = 0; r < 32; r++)
  {
    put_word(data, SLOT_GPR(r), s->gpr[r]);
  }
  /* mstatus */
  put_word(data, SLOT_MSTATUS, mstatus_for_mret);
  /* Other CSRs — for mepc slot, override with ckpt_pc so mret targets it. */
  for (size_t k = 0; k < NR_CSR_RESTORE; k++)
  {
    word_t v = s->*(kCsrRestoreList[k].field);
    if (kCsrRestoreList[k].csr_addr == CSR_MEPC)
    {
      v = s->pc; /* mret jumps here */
    }
    put_word(data, SLOT_OTHER_CSR0 + (int)k, v);
  }

  Log("checkpoint: trampoline built (%d insns, data @+%d) — mret -> pc=" FMT_WORD_NO_PREFIX ", priv=%d, mstatus_for_mret=" FMT_WORD_NO_PREFIX,
      n_total, data_off, s->pc, s->priv, mstatus_for_mret);
}

void checkpoint_configure_load(const char *dir)
{
  load_enabled = 1;
  resume_ready = 0;
  resume_pmu_cycle_base = 0;
  resume_pmu_instr_base = 0;
  memset(&loaded_snap, 0, sizeof(loaded_snap));
  strncpy(load_dir, dir, sizeof(load_dir) - 1);
  load_dir[sizeof(load_dir) - 1] = '\0';

  /* Read state.txt + memory regions immediately. Memory injection is safe
   * here because it only touches the host buffers in memory.cc, which are
   * already allocated as static storage at program start. */
  char path[2048];
  snprintf(path, sizeof(path), "%s/state.txt", load_dir);
  if (read_state_txt(path, &loaded_snap) != 0)
  {
    Error("checkpoint: failed to read state from %s", path);
    load_enabled = 0;
    resume_ready = 1;
    return;
  }
  Log("checkpoint: loaded arch state from %s (saved at cycle %llu, pc=" FMT_WORD_NO_PREFIX ")", path,
      (unsigned long long)loaded_snap.cycle, loaded_snap.pc);

  for (size_t i = 0; i < NR_REGIONS; i++)
    load_region(load_dir, &kRegions[i]);

  /* Rewrite MROM with the trampoline (overrides whatever mem_mrom.bin loaded
   * — that copy is still useful for post-mortem inspection but we need MROM
   * to redirect PC back to ckpt_pc on first fetch). */
  uint8_t *mrom = guest_to_host(MROM_BASE);
  if (mrom == NULL)
  {
    Error("checkpoint: MROM has no host backing — cannot install trampoline");
    load_enabled = 0;
    resume_ready = 1;
    return;
  }
  memset(mrom, 0, 256); /* clear leading region; trampoline is < 256 bytes */
  build_trampoline(mrom, &loaded_snap);
}

void checkpoint_inject_after_reset(void)
{
  if (!load_enabled)
    return;

  /* WARL sanity check on host-write fields (cross-version replay safety).
   * Trampoline csrw paths are self-WARL-correcting; these direct host
   * writes are NOT, so a corrupt or mismatched-RTL state.txt could inject
   * illegal bits. We log a warning and coerce instead of asserting so
   * forward-progress is preserved during ad-hoc debugging.
   *   - mepc[0]    : must be 0 (priv spec)
   *   - mstatush   : WARL-zero (no SBE/MBE; little-endian only)
   *   - pmpcfg[6:5]: WARL-zero (reserved)
   *   - clint_msip : bit[0] only (already masked above) */
  if (loaded_snap.mepc & 0x1)
  {
    Error("checkpoint: mepc bit[0] must be 0 (got " FMT_WORD "), coercing.",
          loaded_snap.mepc);
    loaded_snap.mepc &= ~(word_t)1;
  }
  if (loaded_snap.mstatush != 0)
  {
    Error("checkpoint: mstatush is WARL-zero in this RTL (got " FMT_WORD
          "), coercing to 0.",
          loaded_snap.mstatush);
    loaded_snap.mstatush = 0;
  }
  for (int i = 0; i < NPC_PMP_NUM; i++)
  {
    if (loaded_snap.pmpcfg[i] & 0x60)
    {
      Error("checkpoint: pmpcfg[%d]=0x%02x has reserved bits[6:5] set, coercing.",
            i, (unsigned)loaded_snap.pmpcfg[i]);
      loaded_snap.pmpcfg[i] &= 0x9F;
    }
  }

  /* All architectural state is restored by the MROM trampoline via real
   * RISC-V instructions (load+csrw / load), because the RTL's exposed
   * `rf[]` and CSR backing arrays cannot be reliably written from the host
   * post-reset (rf is a read-only continuous-assign shadow of PRF, and CSR
   * writes don't update derived fields). The trampoline runs first thing
   * after reset and ends with `mret -> ckpt_pc, priv = ckpt_priv`. */

  /* Restore CLINT timer/software-interrupt registers that are not part of any
   * RAM region dump. Without this, Linux/OpenSBI timer state diverges and may
   * spin in M-mode wait loops after checkpoint load. */
  if (npc.clint_mtime != NULL)
    *npc.clint_mtime = loaded_snap.clint_mtime;
  if (npc.clint_mtimecmp != NULL)
    *npc.clint_mtimecmp = loaded_snap.clint_mtimecmp;
  if (npc.clint_msip != NULL)
    *npc.clint_msip = (uint8_t)(loaded_snap.clint_msip & 0x1u);

  if (npc.plic_priority != NULL && npc.plic_enable != NULL &&
      npc.plic_threshold != NULL)
  {
    for (int i = 0; i <= NPC_PLIC_NDEV; i++)
      npc.plic_priority[i] = (uint8_t)(loaded_snap.plic_priority[i] & 0x7u);
    npc.plic_priority[0] = 0;
    for (int c = 0; c < NPC_PLIC_NCTX; c++)
    {
      npc.plic_enable[c] = loaded_snap.plic_enable[c] & ~1u;
      npc.plic_threshold[c] = (uint8_t)(loaded_snap.plic_threshold[c] & 0x7u);
    }

    // Do not restore pending/ext_irq by directly poking RTL internal latches.
    // Those are edge-detect/runtime states and must be regenerated via the
    // synthesizable ext_irq_i[] delivery path.
    if ((loaded_snap.plic_pending & ~1u) != 0u)
    {
      Log("checkpoint: NOTE plic_pending snapshot=0x%08x is not force-restored; "
          "pending IRQ latches restart empty and will be re-driven by devices",
          (unsigned int)(loaded_snap.plic_pending & ~1u));
    }
  }

  if (npc.pmpcfg != NULL && npc.pmpaddr != NULL)
  {
    for (int i = 0; i < NPC_PMP_NUM; i++)
    {
      npc.pmpcfg[i] = loaded_snap.pmpcfg[i];
      npc.pmpaddr[i] = loaded_snap.pmpaddr[i];
    }
  }

  /* Counters / RTL-internal time CSR are restored AFTER the trampoline
   * retires (see checkpoint_load_post_trampoline_tick) so the ~70-cycle
   * trampoline skid does not accumulate into the visible counters. */
  if (npc.mstatush != NULL)
    *npc.mstatush = loaded_snap.mstatush;

  /* S-mode shadow CSRs (sstatus/sie/sip): RTL stores them as separate slots
   * from mstatus/mie/mip. csrw mstatus auto-mirrors into csr[SSTATUS], but
   * csrw mie / csrw mip do NOT mirror to csr[SIE] / csr[SIP] — only csrw
   * sie / csrw sip update them. Since the trampoline restores via csrw mie /
   * csrw mip, csr[SIE]/csr[SIP] would otherwise stay at reset (0). Restore
   * them directly so S-mode reads see correct values. csr[SSTATUS] is
   * redundantly restored for symmetry / future-proofing. */
  if (npc.sstatus != NULL)
    *npc.sstatus = loaded_snap.sstatus;
  if (npc.sie____ != NULL)
    *npc.sie____ = loaded_snap.sie_;
  if (npc.sip____ != NULL)
    *npc.sip____ = loaded_snap.sip;

  Log(FMT_GREEN("checkpoint: trampoline @MROM_BASE will restore arch state then "
                "mret to pc=" FMT_WORD_NO_PREFIX ", priv=%d (saved at cycle %llu)"),
      loaded_snap.pc, loaded_snap.priv,
      (unsigned long long)loaded_snap.cycle);

  Log("checkpoint: restored CLINT state mtime=0x%016llx mtimecmp=0x%016llx msip=%u",
      (unsigned long long)loaded_snap.clint_mtime,
      (unsigned long long)loaded_snap.clint_mtimecmp,
      (unsigned int)(loaded_snap.clint_msip & 0x1u));

  if (npc.pmpcfg != NULL && npc.pmpaddr != NULL)
  {
    Log("checkpoint: restored PMP state pmpcfg0=0x%02x pmpaddr0=" FMT_WORD,
        (unsigned int)loaded_snap.pmpcfg[0], loaded_snap.pmpaddr[0]);
  }

  if (npc.plic_enable != NULL)
  {
    Log("checkpoint: restored PLIC cfg enable0=0x%08x enable1=0x%08x "
        "(pending/ext_irq latches reset)",
        (unsigned int)npc.plic_enable[0],
        (NPC_PLIC_NCTX > 1) ? (unsigned int)npc.plic_enable[1] : 0u);
  }

  /* Arm the deferred fixup; consumed at first commit @ ckpt_pc. */
  post_trampoline_pending = 1;
}

void checkpoint_load_post_trampoline_tick(word_t committed_pc)
{
  if (!post_trampoline_pending)
    return;
  if (committed_pc != loaded_snap.pc)
    return;

  post_trampoline_pending = 0;

  /* Trampoline has retired (first commit at ckpt_pc means mret transferred
   * control). Now overwrite host-visible state that the trampoline perturbed:
   *   - mcycle/h, minstret/h, time/h: skid by ~70 cycles + ~70 retires
   *   - mepc: trampoline wrote ckpt_pc into mepc to drive mret; saved mepc
   *           is recoverable now since mret has already consumed it.
   * Note: mret itself also forced mstatus.MPP/MPIE/MPRV per spec (architectural
   * — no fixup needed; matches what would happen on any natural mret). */
  if (npc.mcycle_ != NULL)
    *npc.mcycle_ = loaded_snap.mcycle;
  if (npc.mcycleh != NULL)
    *npc.mcycleh = loaded_snap.mcycleh;
  if (npc.minstret != NULL)
    *npc.minstret = loaded_snap.minstret;
  if (npc.minstreth != NULL)
    *npc.minstreth = loaded_snap.minstreth;
  if (npc.time___ != NULL)
    *npc.time___ = loaded_snap.time_;
  if (npc.timeh__ != NULL)
    *npc.timeh__ = loaded_snap.timeh;
  if (npc.mepc___ != NULL)
    *npc.mepc___ = loaded_snap.mepc;

  resume_pmu_cycle_base = current_pmu_cycle();
  resume_pmu_instr_base = current_pmu_instr();
  if (resume_pmu_instr_base > 0)
    resume_pmu_instr_base--;
  resume_ready = 1;

  Log("checkpoint: post-trampoline fixup applied at pc=" FMT_WORD_NO_PREFIX
      " (mepc/counters restored from snapshot, relative triggers armed)",
      committed_pc);
}
