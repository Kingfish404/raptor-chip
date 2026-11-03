#ifndef NPC_PMU_SNAPSHOT_H
#define NPC_PMU_SNAPSHOT_H

#include <cstdint>
#include <string>
#include <utility>
#include <vector>

// Only cumulative counters belong here: interval consumers subtract snapshots.
// Occupancies and peaks need separately defined integrals, not endpoint deltas.
using PmuSnapshot = std::vector<std::pair<std::string, uint64_t>>;
using PmuSnapshotProvider = PmuSnapshot (*)();

PmuSnapshot perf_snapshot();

#endif
