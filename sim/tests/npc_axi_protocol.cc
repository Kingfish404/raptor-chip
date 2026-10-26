#include "Vrapt_npc_soc.h"
#include "verilated.h"
#include <array>
#include <cassert>
#include <cstdint>
#include <cstdlib>
#include <deque>
#include <iostream>
#include <tuple>
#include <type_traits>
#include <vector>

#ifdef TEST_RV64
using word_t = int64_t;
#else
using word_t = int32_t;
#endif
using uword_t = std::make_unsigned<word_t>::type;
constexpr unsigned lanes = sizeof(word_t);
constexpr unsigned full_size = lanes == 8 ? 3 : 2;
static unsigned latency, jitter, serialize, seed = 1;
static std::vector<std::pair<uint64_t, unsigned>> reads;
struct Write { uint64_t addr, data; unsigned mask; };
static std::vector<Write> writes;
static uint64_t pattern(uint64_t addr) {
  uint64_t result = 0;
  for (unsigned i = 0; i < lanes; ++i)
    result |= uint64_t(uint8_t((uint32_t(addr) + i) * 37 + 19)) << (8 * i);
  return result;
}
extern "C" unsigned npc_mem_random_delay() {
  if (!jitter) return 0;
  seed = seed * 1664525u + 1013904223u;
  return seed % (jitter + 1);
}
extern "C" unsigned npc_mem_read_latency() { return latency; }
extern "C" unsigned npc_mem_write_latency() { return latency; }
extern "C" unsigned npc_mem_write_outstanding() { return 4; }
extern "C" unsigned npc_mem_serialize_writes() { return serialize; }
extern "C" void pmem_read(word_t addr, uint8_t size, word_t *value) {
  reads.emplace_back(uint64_t(uword_t(addr)), size);
  *value = pattern(uint64_t(addr) & ~(uint64_t(lanes) - 1));
}
extern "C" void pmem_write(word_t addr, word_t value, uint8_t mask) {
  writes.push_back({uint64_t(uword_t(addr)), uint64_t(uword_t(value)), mask});
}
struct Txn {
  uint64_t addr;
  unsigned len, size, burst, id, resp = 0, beat = 0;
  uint64_t beat_addr() const {
    uint64_t step = uint64_t(1) << size;
    if (burst == 0 || beat == 0) return addr;
    if (burst == 2) {
      uint64_t span = step * (len + 1);
      return (addr / span) * span + ((addr % span + beat * step) % span);
    }
    return (addr / step) * step + beat * step;
  }
};
class Harness {
public:
  Vrapt_npc_soc d;
  unsigned cycle = 0, received = 0;
  std::array<std::deque<Txn>, 16> pending;
  std::vector<std::pair<unsigned, unsigned>> bs;
  std::vector<unsigned> rids, rcycles;
  using R = std::tuple<unsigned, uint64_t, unsigned, unsigned>;
  R held_r;
  std::pair<unsigned, unsigned> held_b;
  bool rheld = false, bheld = false;
  void eval() { d.clock = 0; d.eval(); }
  void tick() {
    eval();
    R r{d.out_rid, d.out_rdata, d.out_rresp, d.out_rlast};
    auto b = std::make_pair(unsigned(d.out_bid), unsigned(d.out_bresp));
    if (!d.reset) {
      if (rheld) assert(d.out_rvalid && r == held_r);
      if (bheld) assert(d.out_bvalid && b == held_b);
      if (d.out_rvalid && d.rready) {
        auto &q = pending[d.out_rid];
        assert(!q.empty());
        auto &t = q.front();
        assert(d.out_rresp == t.resp && bool(d.out_rlast) == (t.beat == t.len));
        uint64_t expected = t.resp ? 0 : pattern(t.beat_addr() & ~(uint64_t(lanes) - 1));
        assert(uint64_t(d.out_rdata) == uint64_t(uword_t(expected)));
        rids.push_back(d.out_rid); rcycles.push_back(cycle); ++received;
        if (t.beat++ == t.len) q.pop_front();
      }
      if (d.out_bvalid && d.bready) bs.push_back(b);
      // Capture AR only after checking replies: a response needs a prior AR edge.
      if (d.arvalid && d.out_arready)
        pending[d.arid].push_back({d.araddr, d.arlen, d.arsize, d.arburst,
                                  d.arid, expected_resp});
      held_r = r; rheld = d.out_rvalid && !d.rready;
      held_b = b; bheld = d.out_bvalid && !d.bready;
    } else {
      rheld = bheld = false;
      for (auto &q : pending) q.clear();
    }
    unsigned before = reads.size();
    d.clock = 1; d.eval(); ++cycle; eval();
    if (!d.reset && reads.size() != before) {
      assert(reads.size() == before + 1 && d.out_rvalid && d.out_rresp == 0);
      auto &q = pending[d.out_rid];
      assert(!q.empty());
      assert(reads.back().first == uint64_t(uword_t(q.front().beat_addr())));
      assert(reads.back().second == q.front().size);
    }
  }
  unsigned expected_resp = 0;
  Harness() {
    d.reset = 1; d.arsize = d.awsize = full_size;
    d.arburst = d.awburst = 1; d.wstrb = (1u << lanes) - 1;
    tick(); tick(); d.reset = 0; eval();
  }
  template<class F> void wait(F predicate) {
    unsigned end = cycle + 10000;
    while (!predicate()) { assert(cycle < end); tick(); }
  }
  void ar(Txn t) {
    d.araddr = t.addr; d.arlen = t.len; d.arsize = t.size;
    d.arburst = t.burst; d.arid = t.id; expected_resp = t.resp;
    d.arvalid = 1; eval(); wait([&] { return d.out_arready; });
    tick(); d.arvalid = 0; eval();
  }
  void drain_reads(unsigned total) {
    unsigned end = cycle + 20000;
    while (received < total) {
      assert(cycle < end);
      d.rready = (cycle % 7) != 0 && (cycle % 7) != 1;
      tick();
    }
    d.rready = 0; eval();
    for (auto &q : pending) assert(q.empty());
  }
  void aw(Txn t) {
    d.awaddr = t.addr; d.awlen = t.len; d.awsize = t.size;
    d.awburst = t.burst; d.awid = t.id; d.awvalid = 1;
    eval(); wait([&] { return d.out_awready; }); tick(); d.awvalid = 0; eval();
  }
  void w(uint64_t data, unsigned mask, bool last) {
    d.wdata = data; d.wstrb = mask; d.wlast = last; d.wvalid = 1;
    eval(); wait([&] { return d.out_wready; }); tick(); d.wvalid = 0; eval();
  }
  void drain_b(unsigned count) {
    d.bready = 1; wait([&] { return bs.size() == count; }); d.bready = 0; eval();
  }
};
static void read_geometry() {
  Harness h;
  unsigned total = 0, callbacks = reads.size();
  for (unsigned size = 0; size <= full_size; ++size) {
    for (unsigned burst = 0; burst < 3; ++burst) {
      for (unsigned count : {2u, 4u, 8u, 16u}) {
        uint64_t addr = 0x80002000 + ((count / 2 + 1) % count) * (1u << size);
        Txn t{addr, count - 1, size, burst, size};
        h.ar(t); total += count; h.drain_reads(total);
      }
    }
    // Unaligned INCR: only the first beat is unaligned.
    h.ar({0x80004001, 3, size, 1, size}); total += 4; h.drain_reads(total);
  }
  assert(reads.size() == callbacks + total);
  std::vector<Txn> bad = {
      {0x80000fff, 1, 0, 1, 1, 2}, {0x80000000, 0, full_size + 1, 1, 2, 2},
      {0x80000000, 0, 0, 3, 3, 2}, {0x80000000, 2, 0, 2, 4, 2},
      {0x80000001, 1, 1, 2, 5, 2}, {0x80000000, 16, 0, 0, 6, 2},
      {0x60000000, 3, full_size, 1, 7, 3}};
#ifdef TEST_RV64
  bad.push_back({0x0000000180000000ULL, 0, full_size, 1, 8, 3});
  h.ar({0xffffffff80001000ULL, 0, full_size, 1, 8});
  ++total; h.drain_reads(total);
#endif
  for (auto t : bad) { h.ar(t); total += t.len + 1; h.drain_reads(total); }
  unsigned bad_beats = 0;
  for (auto t : bad) bad_beats += t.len + 1;
  assert(reads.size() == callbacks + total - bad_beats);
}
static void read_queue(unsigned depth) {
  Harness h;
  unsigned before = reads.size();
  for (unsigned i = 0; i < depth; ++i)
    h.ar({0x80008000 + 128 * i, 7, full_size, 1, i % 3});
  h.d.arvalid = 1; h.d.araddr = 0x8000c000; h.eval(); assert(!h.d.out_arready);
  h.d.arvalid = 0;
  h.wait([&] { return h.d.out_rvalid; });
  auto stable_calls = reads.size();
  for (unsigned i = 0; i < 20; ++i) h.tick();
  assert(reads.size() == stable_calls); // No repeated device side effect while R stalls.
  h.drain_reads(depth * 8);
  assert(reads.size() == before + depth * 8);
  if (depth >= 3) {
    assert(h.rids[0] == 0 && h.rids[1] == 1 && h.rids[2] == 2);
  }
  // Reuse every slot repeatedly, including non-power-of-two capacities.
  for (unsigned i = 0; i < 50; ++i) {
    h.ar({0x80010000 + i * 16, 0, full_size, 1, i % 16});
    h.drain_reads(depth * 8 + i + 1);
  }
}
static void write_geometry() {
  Harness h;
  unsigned n = 0;
  for (unsigned size = 0; size <= full_size; ++size) {
    for (unsigned burst = 0; burst < 3; ++burst) {
      for (unsigned count : {2u, 4u, 8u, 16u}) {
        Txn t{0x80020000 + (count / 2) * (1u << size), count - 1, size, burst, n % 16};
        h.aw(t);
        for (unsigned i = 0; i < count; ++i) {
          t.beat = i; uint64_t addr = t.beat_addr();
          unsigned mask = ((1u << (1u << size)) - 1) << (addr % lanes);
          unsigned calls = writes.size();
          h.w(0x34567890, mask, i + 1 == count);
          h.wait([&] { return writes.size() == calls + 1; });
          assert(writes.back().addr == (addr & ~(uint64_t(lanes) - 1)));
          assert(writes.back().data == 0x34567890 && writes.back().mask == mask);
        }
        h.drain_b(++n); assert(h.bs.back() == std::make_pair(t.id, 0u));
      }
    }
  }
  // Unaligned first INCR beat, then aligned beats, with holes in valid byte lanes.
  for (unsigned size = 0; size <= full_size; ++size) {
    Txn t{0x80024001, 3, size, 1, n % 16};
    h.aw(t);
    for (unsigned i = 0; i <= t.len; ++i) {
      t.beat = i;
      uint64_t addr = t.beat_addr();
      unsigned first = addr % lanes, step = 1u << size;
      unsigned limit = (first / step + 1) * step;
      unsigned mask = ((1u << limit) - 1) & ~((1u << first) - 1);
      if (mask & 0x55) mask &= 0x55;
      unsigned calls = writes.size();
      h.w(0x89abcdef, mask, i == t.len);
      h.wait([&] { return writes.size() == calls + 1; });
      assert(writes.back().addr == (addr & ~(uint64_t(lanes) - 1)));
      assert(writes.back().data == 0x89abcdef && writes.back().mask == mask);
    }
    h.drain_b(++n); assert(h.bs.back() == std::make_pair(t.id, 0u));
  }
  // Invalid descriptors, illegal byte lanes and malformed WLAST have no first-beat effect.
  for (Txn t : std::vector<Txn>{{0x60000000, 0, 0, 1, 1, 3},
       {0x80000fff, 1, 0, 1, 2, 2}, {0x80000000, 0, 0, 3, 3, 2},
       {0x80000001, 1, 1, 2, 4, 2}, {0x80000000, 0, full_size + 1, 1, 5, 2}}) {
    unsigned calls = writes.size(); h.aw(t);
    for (unsigned i = 0; i <= t.len; ++i) h.w(7, 1, i == t.len);
    h.drain_b(++n); assert(h.bs.back() == std::make_pair(t.id, t.resp));
    assert(writes.size() == calls);
  }
  for (unsigned kind = 0; kind < 4; ++kind) {
    unsigned calls = writes.size();
    h.aw({0x80000000, kind == 1 ? 3u : 0u, 0, 1, 6});
    h.w(7, kind == 0 ? 2 : kind == 3 ? 0 : 1, kind != 2);
    h.drain_b(++n);
    assert(h.bs.back().second == (kind == 3 ? 0u : 2u));
    assert(writes.size() == calls);
  }
}
static void read_throughput() {
  if (latency || jitter) return;
  Harness h;
  h.ar({0x80040000, 63, full_size, 1, 1});
  h.d.rready = 1;
  h.wait([&] { return h.received == 64; });
  for (unsigned i = 1; i < h.rcycles.size(); ++i)
    assert(h.rcycles[i] == h.rcycles[i - 1] + 1);
}
static void wrap_hazards() {
  Harness h;
  h.aw({0x80050000, 0, full_size, 1, 1});
  h.w(0x42, (1u << lanes) - 1, true);
  // WRAP includes addresses below its starting beat.
  h.d.araddr = 0x80050000 + lanes; h.d.arlen = 3;
  h.d.arburst = 2; h.d.arvalid = 1; h.eval();
  assert(!h.d.out_arready); h.d.arvalid = 0;
  h.drain_b(1);
  h.ar({0x80050000 + lanes, 3, full_size, 2, 2});
  h.d.awaddr = 0x80050000; h.d.awvalid = 1; h.eval();
  assert(!h.d.out_awready);
  h.d.awaddr = 0x80051000; h.eval(); assert(h.d.out_awready);
  h.d.awaddr = 0x10000000; h.eval(); assert(!h.d.out_awready);
  h.d.awvalid = 0;
  h.drain_reads(4);
  h.ar({0x40000000, 0, full_size, 1, 3}); // SDHCI BAR is mapped.
  h.d.awaddr = 0x80051000; h.d.awvalid = 1; h.eval();
  assert(!h.d.out_awready); h.d.awvalid = 0;
  h.drain_reads(5);
}
static void device_write_barrier() {
  for (bool old_device : {false, true}) {
    Harness h;
    unsigned calls = writes.size();
    h.aw({old_device ? 0x10000000u : 0x80000000u, 0, full_size, 1, 1});
    h.d.awaddr = old_device ? 0x80001000u : 0x10000000u;
    h.d.awid = 2; h.d.awvalid = 1;
    h.d.wvalid = 1; h.d.wlast = 1; h.d.wdata = 0x21;
    h.eval(); assert(!h.d.out_awready && h.d.out_wready);
    h.tick(); h.d.wvalid = 0; h.eval();
    h.wait([&] { return h.d.out_bvalid; });
    assert(!h.d.out_awready && writes.size() == calls + 1);
    for (unsigned i = 0; i < 4; ++i) h.tick();
    h.d.bready = 1; h.eval();
    if (serialize) assert(!h.d.out_awready);
    h.wait([&] { return h.d.out_awready; });
    h.tick(); h.d.awvalid = 0; h.eval();
    assert(h.bs.size() == 1 && writes.size() == calls + 1);
    h.w(0x22, (1u << lanes) - 1, true); h.drain_b(2);
    assert(h.bs.back() == std::make_pair(2u, 0u) && writes.size() == calls + 2);
  }
}
static void write_throughput() {
  if (latency || jitter || serialize) return;
  Harness h;
  unsigned calls = writes.size();
  h.d.bready = 1; h.d.awvalid = 1; h.d.wvalid = 1;
  h.d.wlast = 1; h.d.wstrb = (1u << lanes) - 1;
  for (unsigned i = 0; i < 100; ++i) {
    h.d.awid = i % 16; h.d.awaddr = 0x80030000 + i * lanes;
    h.d.wdata = i; h.eval();
    assert(h.d.out_awready && h.d.out_wready);
    h.tick();
    assert(writes.size() == calls + i + 1);
    assert(writes.back().addr == 0x80030000 + i * lanes && writes.back().data == i);
  }
  h.d.awvalid = h.d.wvalid = 0; h.drain_b(100);
  for (unsigned i = 0; i < 100; ++i) assert(h.bs[i] == std::make_pair(i % 16, 0u));
}
static void elastic_and_reset() {
  Harness h;
  unsigned calls = writes.size();
  h.w(0x57, 1, true); // W precedes AW, must remain unidentified and buffered.
  for (unsigned i = 0; i < 8; ++i) { h.tick(); assert(!h.d.out_wready); }
  assert(writes.size() == calls && !h.d.out_bvalid);
  h.aw({0x10000000, 0, 0, 1, 4});
  h.wait([&] { return h.d.out_bvalid; });
  assert(writes.size() == calls + 1);
  for (unsigned i = 0; i < 10; ++i) h.tick();
  assert(writes.size() == calls + 1); h.drain_b(1);
  // Reset cancels buffered W and held responses without extra DPI calls.
  h.ar({0x80000000, 7, full_size, 1, 7});
  h.wait([&] { return h.d.out_rvalid; });
  h.w(0x77, 1, true);
  calls = writes.size(); unsigned rcalls = reads.size();
  h.d.reset = 1; h.tick(); h.d.reset = 0;
  for (unsigned i = 0; i < 10; ++i) h.tick();
  assert(!h.d.out_bvalid && !h.d.out_rvalid && h.d.out_wready);
  assert(writes.size() == calls && reads.size() == rcalls);
  h.aw({0x80000000, 0, 0, 1, 2}); h.w(0x41, 1, true);
  h.wait([&] { return h.d.out_bvalid; });
  h.d.reset = 1; h.tick(); h.d.reset = 0; h.tick();
  assert(!h.d.out_bvalid && !h.d.out_rvalid);
}
int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  assert(argc == 6);
  unsigned depth = std::strtoul(argv[1], nullptr, 0);
  latency = std::strtoul(argv[2], nullptr, 0); jitter = std::strtoul(argv[3], nullptr, 0);
  seed = std::strtoul(argv[4], nullptr, 0); serialize = std::strtoul(argv[5], nullptr, 0);
  read_geometry(); read_queue(depth); read_throughput(); wrap_hazards();
  write_geometry(); write_throughput(); device_write_barrier(); elastic_and_reset();
  std::cout << "PASS AXI XLEN=" << lanes * 8 << " depth=" << depth
            << " latency=" << latency << " jitter=" << jitter << " strict=" << serialize << '\n';
}
