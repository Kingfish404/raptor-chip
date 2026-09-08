#include "recovery_metrics.h"
#include <cstdio>

using Metrics = RecoveryMetrics<7, 1, 2, 4, 8, 16>;
int main()
{
  Metrics m;
  std::array<unsigned, 7> events{};
  const auto sample = [&](bool flush = false) { m.sample(events, flush); events.fill(0); };
  events[0] = 1; events[1] = 1; events[2] = 1; sample(); // allocate
  events[0] = 2 | 4; events[1] = 2 | 4; sample(); // two wrong completions
  sample(); // both wait
  events[0] = 8; sample(true); // retire one, kill wrong+unresolved younger
  assert(m.wrong_retire.count == 1 && m.wrong_retire.cycles == 2);
  assert(m.wrong_killed.count == 1 && m.wrong_killed.cycles == 2);
  assert(m.killed_unresolved == 1 && m.pending_wrong_cycles == 2);
  assert(m.pending_wrong_integral == 4 && m.pending_wrong_max == 2);
  assert(m.live_count() == 0 && m.conserved());
  events[0] = 1; sample(); // same identity reused, no old timestamp
  events[0] = 2; sample();
  events[0] = 8; sample();
  assert(m.correct_retire.count == 1 && m.correct_retire.cycles == 1);
  events[0] = 1; sample();
  events[0] = 8 | 16; sample(true); // early fault, no execution timestamp
  assert(m.trap_retired == 1 && m.retired == 3 && m.conserved());
  events[0] = 1; events[1] = 1; sample();
  events[0] = 2; sample(); sample(true);
  assert(m.killed_correct == 1 && m.killed_unresolved == 2);
  events[3] = 1; sample(); m.reset_epoch();
  assert(m.reset_discarded == 1 && m.conserved());
  events[3] = 1; sample(); events[3] = 2 | 4; sample();
  for (int i = 0; i < 100; ++i) sample();
  events[3] = 8; sample(true);
  assert(m.wrong_retire.maximum == 101 && m.wrong_retire.histogram[7] == 1);
  assert(m.wrong_retire.histogram[2] == 1);
  assert(m.conserved());
  events[0] = 1; events[1] = 1; sample();
  events[0] = 2 | 4; events[1] = 2 | 4; sample(); sample();
  events[0] = 8 | 16; sample(); // resolved control op ultimately traps
  assert(m.wrong_trap_cycles == 2 && m.live_wrong_age() == 2 && m.conserved());
  m.reset_epoch();
  assert(m.wrong_reset_cycles == 2 && m.live_wrong_age() == 0 && m.conserved());

  // Long deterministic reuse sequence, including multiple identities/edge.
  uint32_t rng = 20260905;
  for (unsigned t = 0; t < 100000; ++t) {
    rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5;
    const bool flush = (rng & 63) == 0;
    for (unsigned i = 0; i < events.size(); ++i) {
      const auto &e = m.entries[i];
      if (flush) events[i] = e.live && e.resolved && i == 0 ? 8 : 0;
      else if (!e.live) events[i] = ((rng >> i) & 1) ? 1 : 0;
      else if (!e.resolved) events[i] = ((rng >> (i+7)) & 1) ? 2 | (((rng >> i) & 1) ? 4 : 0) : 0;
      else events[i] = ((rng >> (i+14)) & 1) ? 8 : 0;
    }
    sample(flush);
    assert(m.pending_wrong_cycles <= m.cycle && m.pending_wrong_integral >= m.pending_wrong_cycles);
  }
  sample(true);
  assert(m.conserved() && m.live_count() == 0);
  std::puts("PASS: recovery lifecycle, overlapping waits, flush/retire order, reset, reuse and histograms");
}
