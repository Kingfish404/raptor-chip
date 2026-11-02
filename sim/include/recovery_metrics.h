#pragma once
#include <array>
#include <cassert>
#include <cstddef>
#include <cstdint>
#include <algorithm>
#include <vector>

// Host-side observer: no counters/timestamps/checkpoints enter synthesized RTL.
// The entry count and event flags come from generated RTL constants at run time.
class RecoveryMetrics
{
public:
  struct Flags {
    unsigned allocate, resolve, mispredict, retire, trap;
  };
  RecoveryMetrics(std::size_t entry_count, Flags event_flags)
      : flags(event_flags), entries(entry_count) {}

  struct Latency {
    uint64_t count = 0, cycles = 0, maximum = 0;
    // Exact 0, exact 1, 2..3, 4..7, 8..15, 16..31, 32..63, 64+.
    std::array<uint64_t, 8> histogram{};
    void add(uint64_t age) {
      ++count; cycles += age; maximum = std::max(maximum, age);
      unsigned bucket = 0;
      if (age != 0) {
        bucket = 1;
        for (uint64_t bound = 2; bucket < 7 && age >= bound; bound <<= 1) ++bucket;
      }
      ++histogram[bucket];
    }
  } correct_retire, wrong_retire, wrong_killed;
  uint64_t cycle = 0, allocated = 0, resolved = 0, retired = 0, trap_retired = 0;
  uint64_t killed_unresolved = 0, killed_correct = 0, reset_discarded = 0;
  uint64_t pending_wrong_cycles = 0, pending_wrong_integral = 0, pending_wrong_max = 0;
  uint64_t wrong_trap_cycles = 0, wrong_reset_cycles = 0;

  struct Entry {
    bool live = false, resolved = false, wrong = false;
    uint64_t resolved_at = 0;
  };
  Flags flags;
  std::vector<Entry> entries;

  void reset_epoch() {
    for (auto &e : entries) {
      reset_discarded += e.live;
      if (e.live && e.resolved && e.wrong) wrong_reset_cycles += cycle - e.resolved_at;
      e = {};
    }
  }
  uint64_t live_count() const {
    uint64_t n = 0;
    for (const auto &e : entries) n += e.live;
    return n;
  }
  uint64_t pending_wrong() const {
    uint64_t n = 0;
    for (const auto &e : entries) n += e.live && e.resolved && e.wrong;
    return n;
  }
  uint64_t live_wrong_age() const {
    uint64_t n = 0;
    for (const auto &e : entries)
      if (e.live && e.resolved && e.wrong) n += cycle - e.resolved_at;
    return n;
  }
  bool conserved() const {
    return allocated == retired + killed_unresolved + killed_correct
        + wrong_killed.count + reset_discarded + live_count()
        && pending_wrong_integral == wrong_retire.cycles + wrong_killed.cycles
            + wrong_trap_cycles + wrong_reset_cycles + live_wrong_age();
  }

  template <typename Events>
  void sample(const Events &events, bool flush) {
    ++cycle;
    // Charge the interval that just elapsed, before processing this edge.
    const uint64_t pending = pending_wrong();
    pending_wrong_cycles += pending != 0;
    pending_wrong_integral += pending;
    pending_wrong_max = std::max(pending_wrong_max, pending);
    for (std::size_t i = 0; i < entries.size(); ++i) {
      auto &e = entries[i];
      const unsigned event = events[i];
      if (event & flags.allocate) {
        assert(!flush && !e.live);
        e = {}; e.live = true; ++allocated;
      }
      if (event & flags.resolve) {
        assert(!flush && e.live && !e.resolved);
        e.resolved = true; e.wrong = event & flags.mispredict;
        e.resolved_at = cycle; ++resolved;
      }
      if (event & flags.retire) {
        assert(e.live);
        ++retired;
        if (event & flags.trap) {
          ++trap_retired;
          if (e.resolved && e.wrong) wrong_trap_cycles += cycle - e.resolved_at;
        }
        else {
          assert(e.resolved);
          (e.wrong ? wrong_retire : correct_retire).add(cycle - e.resolved_at);
        }
        e = {};
      }
    }
    if (flush) {
      for (auto &e : entries) if (e.live) {
        if (!e.resolved) ++killed_unresolved;
        else if (e.wrong) wrong_killed.add(cycle - e.resolved_at);
        else ++killed_correct;
        e = {};
      }
    }
    assert(conserved());
  }
};
