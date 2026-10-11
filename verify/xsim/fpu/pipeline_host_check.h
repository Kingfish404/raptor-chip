#pragma once

#include <cstdint>
#include <cstdio>
#include <deque>
#include <utility>

// Exercise II=1 arithmetic with independent host results, bubbles and flushes.
// The caller keeps any wrapper output selector constant throughout one run.
// Drive returns the reference result for the inputs it places on this cycle.
template <class Top, class Drive, class Equal>
int check_pipeline_stream(Top* top, int iterations, Drive drive, Equal equal) {
  using Expected = std::pair<uint64_t, uint8_t>;
  std::deque<Expected> pending;
  int failures = 0, completed = 0;
  top->reset = 1;
  top->flush = 0;
  top->valid = 0;
  auto tick = [&] {
    top->clock = 0; top->eval();
    top->clock = 1; top->eval();
  };
  tick(); tick();
  top->reset = 0;
  for (int cycle = 0; cycle < iterations + 16; ++cycle) {
    top->valid = cycle < iterations && cycle % 17 != 0;
    top->flush = cycle < iterations && cycle % 257 == 256;
    if (top->flush) {
      pending.clear();
      top->valid = 0;
    }
    if (top->valid) pending.push_back(drive(cycle));
    top->clock = 0; top->eval();
    if (top->valid && !top->ready) {
      printf("STREAM unexpectedly blocked at cycle %d\n", cycle);
      return 1;
    }
    top->clock = 1; top->eval();
    if (top->dut_valid) {
      if (pending.empty()) {
        printf("STREAM unowned result at cycle %d\n", cycle);
        return 1;
      }
      const Expected expected = pending.front();
      pending.pop_front();
      ++completed;
      if (!equal(expected.first, top->dut_result) || expected.second != top->dut_flags) {
        if (++failures < 10)
          printf("STREAM cycle=%d expected=%016llx/%02x got=%016llx/%02x\n", cycle,
                 (unsigned long long)expected.first, expected.second,
                 (unsigned long long)top->dut_result, top->dut_flags);
      }
    }
  }
  if (!pending.empty()) {
    printf("STREAM missing %zu results\n", pending.size());
    ++failures;
  }
  printf("STREAMED=%d FAILS=%d\n", completed, failures);
  return failures;
}
