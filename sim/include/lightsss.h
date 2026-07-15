#ifndef __NPC_LIGHTSSS_H__
#define __NPC_LIGHTSSS_H__

#include <common.h>
#include <stdbool.h>

/* ===== LightSSS: lightweight simulation snapshot ==========================
 *
 * Inspired by XiangShan difftest's LightSSS
 * (https://github.com/OpenXiangShan/difftest).
 *
 * Deep difftest divergences (e.g. a Linux-boot mismatch at cycle 1.6e9) are
 * painful to debug: re-running the whole boot with waveform tracing enabled
 * is slow and produces an enormous trace. LightSSS exploits copy-on-write
 * fork() to keep a "rewind point" a short distance behind the live run.
 *
 * Mechanism:
 *   - At every periodic `cpu_exec progress` print, the simulator fork()s a
 *     throwaway snapshot child that immediately blocks. The parent keeps
 *     simulating. Only one snapshot child is alive at a time.
 *   - When the parent reaches the NEXT progress print without an error, the
 *     window was clean: the previous child is reaped and a fresh snapshot is
 *     forked at the new (closer) point.
 *   - When the parent hits a difftest divergence, the still-blocked child
 *     (whose COW memory image is frozen at the last progress point, i.e. only
 *     a window behind the failure) is woken up to dump an architectural
 *     checkpoint to a fixed directory, then exits.
 *
 * The resulting checkpoint can be reloaded with `--ckpt-load=DIR` and replayed
 * with waveform dumping (`-c 0`) to capture only the final, failing window
 * instead of the whole multi-billion-cycle run.
 * ------------------------------------------------------------------------ */

/* Enable LightSSS and set the directory the snapshot child writes its
 * checkpoint into when a divergence is detected. */
void lightsss_configure(const char *dir);

/* Returns true if LightSSS was enabled via lightsss_configure(). */
bool lightsss_enabled(void);

/* Called at each periodic progress point. Reaps the previous snapshot child
 * (window was clean) and forks a fresh snapshot frozen at the current state. */
void lightsss_fork_at_progress(void);

/* Called from the parent when a difftest divergence is detected. Wakes the
 * most recent snapshot child to dump its checkpoint and waits for it to
 * finish. No-op when LightSSS is disabled or no child is alive. */
void lightsss_trigger_save(void);

/* Called once at the end of a run to reap any lingering snapshot child. */
void lightsss_finish(void);

#endif /* __NPC_LIGHTSSS_H__ */
