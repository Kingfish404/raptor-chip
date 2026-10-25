#include "axi_metrics.h"
#include <cassert>
#include <numeric>

int main()
{
  AxiMetrics m;
  AxiCycleSample s;
  m.sample(s); // Reset/invalid samples are excluded.
  assert(m.cycles == 0);
  s.valid = true;
  s.posted_capacity = 4;
  s.posted_count = 3;
  s.write_outstanding = 3;
  s.posted_fire = true;
  s.awvalid = s.awready = s.wvalid = s.wready = s.wlast = true;
  m.sample(s);
  assert(m.aw == 1 && m.wlast == 1 && m.wlast_pending == 1);
  s.posted_fire = false;
  s.posted_count = 4;
  s.write_outstanding = 4;
  s.awready = s.wready = false;
  s.write_skid = s.sq_full = true;
  for (unsigned i = 0; i < 5; ++i) m.sample(s);
  assert(m.aw == 1 && m.w == 1 && m.b_wait == 5);
  assert(m.posted_full == 5 && m.sq_and_posted_full == 5);
  assert(m.sq_and_w_stall == 5 && m.sq_and_b_wait == 5);
  s.awvalid = s.wvalid = false;
  s.bvalid = true;
  m.sample(s); // B response backpressure is not a missing response.
  assert(m.b_stall == 1 && m.b_wait == 5);
  s.bready = s.posted_response = true;
  m.sample(s);
  assert(m.b == 1 && m.wlast_pending == 0 && m.wlast_pending_sum == 7);
  assert(m.posted_peak == 4 && m.outstanding_peak == 4);
  assert(m.posted_histogram[3] == 1 && m.posted_histogram[4] == 7);
  assert(std::accumulate(m.posted_histogram.begin(), m.posted_histogram.end(), 0ull) == m.cycles);
  s.wvalid = s.wready = s.wlast = true;
  m.sample(s); // Same-edge WLAST/B is balanced.
  assert(m.wlast_pending == 0 && m.unmatched_b == 0);
  m = {};
  s.wvalid = false;
  m.sample(s); // Measurement starts mid-flight: no unsigned underflow.
  assert(m.unmatched_b == 1 && m.wlast_pending == 0 && m.b_wait == 0);
  s = {};
  s.valid = true;
  s.sq_full = true;
  m.sample(s); // PostedWrites=0 disables the full predicate.
  assert(m.posted_full == 1 && m.sq_and_posted_full == 1);
  m = {};
  s = {};
  s.valid = s.arvalid = true;
  m.sample(s);
  s.arready = true;
  m.sample(s);
  s.arvalid = false;
  s.rvalid = s.rready = true;
  m.sample(s);
  s.rlast = true;
  s.rready = false;
  m.sample(s);
  assert(m.ar == 1 && m.ar_stall == 1 && m.r == 1 && m.rlast == 0);
  s.rready = true;
  m.sample(s);
  assert(m.r == 2 && m.rlast == 1 && m.r_stall == 1);
}
