#ifndef NPC_SAMPLE_WINDOW_H
#define NPC_SAMPLE_WINDOW_H

#include <stdint.h>
#include <pmu_snapshot.h>

/* CMU also reports fault delivery and system exceptions as debug commits. */
inline bool sample_is_retired(uint32_t instruction, bool trapped)
{
  return !trapped && instruction != 0x00000073u && instruction != 0x00100073u;
}

/* Keep a small band of exact cycle-boundary observations. Different commit
 * widths may skip a retirement count; consumers intersect the observed counts
 * instead of interpolating or comparing different instruction streams. */
void sample_window_configure(const char *path, uint64_t warmup, uint64_t instructions,
                             bool has_start_pc, uint64_t start_pc, bool checkpoint);
void sample_window_activate(void);
void sample_window_set_pmu_provider(PmuSnapshotProvider provider);
// Before this cycle's PMU updates, preserve the zero-warmup start boundary.
bool sample_window_needs_start_snapshot(void);
void sample_window_before_cycle(uint64_t pc);
void sample_window_set_user_satp(uint64_t root);
void sample_window_set_user_thread(uint64_t pointer);
bool sample_window_accept(unsigned privilege, uint64_t satp, uint64_t thread_pointer = 0);
void sample_window_commit(uint64_t pc, uint32_t instruction, uint64_t cycle,
                          uint64_t previous_instructions, bool resumed);
bool sample_window_cycle(uint64_t cycle, uint64_t instructions);
bool sample_window_finish(bool execution_ok);

#endif
