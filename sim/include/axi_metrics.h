#ifndef AXI_METRICS_H
#define AXI_METRICS_H

#include <algorithm>
#include <cstdint>
#include <vector>

// Inputs are captured before the rising edge; post-edge ready/valid can already
// describe the next transfer and must not be used to count the preceding one.
struct AxiCycleSample
{
  bool valid = false;
  bool arvalid = false, arready = false, rvalid = false, rready = false, rlast = false;
  bool awvalid = false, awready = false, wvalid = false, wready = false, wlast = false;
  bool bvalid = false, bready = false;
  bool posted_fire = false, posted_response = false, write_skid = false, sq_full = false;
  unsigned posted_count = 0, posted_capacity = 0, write_outstanding = 0;
};

struct AxiMetrics
{
  uint64_t cycles = 0;
  uint64_t ar = 0, r = 0, rlast = 0, aw = 0, w = 0, wlast = 0, b = 0;
  uint64_t ar_stall = 0, r_stall = 0, aw_stall = 0, w_stall = 0, b_stall = 0;
  uint64_t wlast_pending = 0, wlast_pending_sum = 0, b_wait = 0, unmatched_b = 0;
  uint64_t posted_fire = 0, posted_response = 0, posted_sum = 0, posted_busy = 0;
  uint64_t posted_full = 0, posted_peak = 0, posted_capacity = 0;
  uint64_t outstanding_sum = 0, outstanding_peak = 0, skid_busy = 0;
  uint64_t sq_full = 0, sq_and_posted_full = 0, sq_and_w_stall = 0, sq_and_b_wait = 0;
  std::vector<uint64_t> posted_histogram;

  void sample(const AxiCycleSample &s)
  {
    if (!s.valid) return;
    ++cycles;
    const bool wh = s.wvalid && s.wready && s.wlast;
    const bool bh = s.bvalid && s.bready;
    const bool waiting_b = wlast_pending != 0 && !s.bvalid;
    const bool full = s.posted_capacity != 0 && s.posted_count >= s.posted_capacity;
    ar += s.arvalid && s.arready;
    r += s.rvalid && s.rready;
    rlast += s.rvalid && s.rready && s.rlast;
    aw += s.awvalid && s.awready;
    w += s.wvalid && s.wready;
    wlast += wh;
    b += bh;
    ar_stall += s.arvalid && !s.arready;
    r_stall += s.rvalid && !s.rready;
    aw_stall += s.awvalid && !s.awready;
    w_stall += s.wvalid && !s.wready;
    b_stall += s.bvalid && !s.bready;
    wlast_pending_sum += wlast_pending;
    b_wait += waiting_b;
    // A host-side PMU reset may cut an in-flight write. Count that unmatched
    // response explicitly instead of underflowing and inventing long B waits.
    if (wh) ++wlast_pending;
    if (bh)
    {
      if (wlast_pending) --wlast_pending;
      else ++unmatched_b;
    }
    posted_fire += s.posted_fire;
    posted_response += s.posted_response;
    posted_sum += s.posted_count;
    posted_busy += s.posted_count != 0;
    posted_full += full;
    posted_peak = std::max(posted_peak, uint64_t(s.posted_count));
    posted_capacity = s.posted_capacity;
    if (posted_histogram.size() <= s.posted_count) posted_histogram.resize(s.posted_count + 1);
    ++posted_histogram[s.posted_count];
    outstanding_sum += s.write_outstanding;
    outstanding_peak = std::max(outstanding_peak, uint64_t(s.write_outstanding));
    skid_busy += s.write_skid;
    sq_full += s.sq_full;
    sq_and_posted_full += s.sq_full && full;
    sq_and_w_stall += s.sq_full && s.wvalid && !s.wready;
    sq_and_b_wait += s.sq_full && waiting_b;
  }
};

#endif
