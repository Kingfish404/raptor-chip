#ifndef __NPC_CHECKPOINT_H__
#define __NPC_CHECKPOINT_H__

#include <common.h>
#include <stdbool.h>

/* ===== Checkpoint feature =================================================
 *
 * Plain-text architectural-state checkpoint with binary memory dumps. The
 * design intent is to let the user pause a long simulation (e.g. Linux boot)
 * at a chosen cycle, save the architectural state, modify RTL/microarch,
 * rebuild, and resume from the same architectural point -- without rerunning
 * the previous millions of cycles.
 *
 * Layout of a checkpoint directory:
 *   <dir>/state.txt       Plain text: PC, priv, GPRs, CSRs, device state,
 *                         cumulative cycle/instr counts, trigger metadata
 *   <dir>/mem_pmem.bin    Binary dump of MBASE  region
 *   <dir>/mem_sdram.bin   Binary dump of SDRAM  region
 *   <dir>/mem_sram.bin    Binary dump of SRAM   region
 *   <dir>/mem_mrom.bin    Binary dump of MROM   region (saved as captured)
 *   <dir>/mem_flash.bin   Binary dump of FLASH  region
 *
 * On restore, MROM is replaced with a generated trampoline that:
 *   1. csrw mepc,    <ckpt_pc>
 *   2. csrw mstatus, <mstatus with MPP/MPIE adjusted to restore priv+MIE>
 *   3. restore scratch GPRs (t0/x5, t1/x6) to their archi values
 *   4. mret
 * All other GPRs and CSRs are injected by the C++ runtime via direct writes
 * to the RTL's register-file / CSR backing arrays before the trampoline runs.
 * Non-RAM device state (CLINT/PLIC/PMP) is injected explicitly by the C++
 * runtime after reset.
 */

/* Configure save. Triggers are relative to the current reset/resume point:
 *   - cycle: active cycles after reset or after checkpoint trampoline resume
 *   - instr: committed guest instructions after reset/resume
 *   - pc: first committed instruction whose PC equals `pc`
 * If no trigger is enabled, save at cycle 0 for backward compatibility.
 * When `exit_after_save` is true, simulator exits after dump. */
void checkpoint_configure_save(bool has_cycle, uint64_t cycle,
							   bool has_instr, uint64_t instr,
							   bool has_pc, word_t pc,
							   const char *dir, bool exit_after_save);

/* Hook called on each committed instruction. Records PC-triggered save points. */
void checkpoint_note_commit(word_t committed_pc);

/* Configure load: read checkpoint dir and stash arch state to inject after
 * reset. Memory regions are loaded into the host buffers and an MROM
 * trampoline is generated. */
void checkpoint_configure_load(const char *dir);

/* Hook called from cpu_exec each cycle. Returns true if save just triggered
 * and the user requested exit-after-save. */
bool checkpoint_save_tick(void);

/* Hook called once after RTL reset and after `verilog_connect()` has wired
 * the npc.* pointers. Injects GPRs/CSRs into the live RTL state when load
 * is configured; no-op otherwise. */
void checkpoint_inject_after_reset(void);

/* Deferred fixup invoked from the cycle loop when the FIRST committed
 * instruction reaches ckpt_pc (i.e. the trampoline + mret has retired).
 * Used to overwrite host-visible state that the trampoline itself perturbs
 * (counters, mepc) so the resumed image is exactly the saved snapshot. */
void checkpoint_load_post_trampoline_tick(word_t committed_pc);

/* Returns 1 if a save is configured, 0 otherwise. */
int checkpoint_save_configured(void);

/* Returns 1 if a load is configured, 0 otherwise (callers can use this to
 * skip loading the original image's MROM, since restore overrides it). */
int checkpoint_load_configured(void);

#endif /* __NPC_CHECKPOINT_H__ */
