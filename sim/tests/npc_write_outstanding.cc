#include "Vrapt_npc_soc.h"
#include "verilated.h"
#include <cassert>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <unordered_map>
#include <vector>

#ifdef TEST_RV64
using word_t = int64_t;
#else
using word_t = int32_t;
#endif
static unsigned slots = 1;
static unsigned latency = 30;
static std::unordered_map<uint64_t, uint8_t> memory;
extern "C" uint32_t npc_mem_random_delay() { return 0; }
extern "C" uint32_t npc_mem_read_latency() { return 0; }
extern "C" uint32_t npc_mem_write_latency() { return latency; }
extern "C" uint32_t npc_mem_serialize_writes() { return 0; }
extern "C" uint32_t npc_mem_write_outstanding() { return slots; }
extern "C" void pmem_read(word_t addr, uint8_t, word_t *data) {
  uint64_t value = 0;
  for (unsigned i = 0; i < sizeof(word_t); i++)
    value |= uint64_t(memory[uint32_t(addr) + i]) << (i * 8);
  *data = value;
}
extern "C" void pmem_write(word_t addr, word_t data, uint8_t mask) {
  for (unsigned i = 0; i < sizeof(word_t); i++)
    if (mask & (1u << i)) memory[uint32_t(addr) + i] = uint64_t(data) >> (i * 8);
}

struct Response { unsigned id, resp, cycle; };
class Harness {
public:
  Vrapt_npc_soc dut;
  unsigned cycle = 0;
  std::vector<Response> replies;
  void eval() { dut.clock = 0; dut.eval(); }
  void tick() {
    eval();
    if (dut.out_bvalid && dut.bready)
      replies.push_back({dut.out_bid, dut.out_bresp, cycle});
    dut.clock = 1; dut.eval(); cycle++;
    eval();
  }
  template<class F> void wait(F ready) {
    unsigned end = cycle + 1000;
    while (!ready()) { assert(cycle < end); tick(); }
  }
  Harness() {
    dut.reset = 1;
    dut.awsize = dut.arsize = sizeof(word_t) == 8 ? 3 : 2;
    dut.awburst = dut.arburst = 1;
    dut.wstrb = (1u << sizeof(word_t)) - 1;
    tick(); tick(); dut.reset = 0;
    eval();
  }
  void aw(unsigned id, uint32_t addr, unsigned len = 0) {
    dut.awid = id; dut.awaddr = addr; dut.awlen = len; dut.awvalid = 1;
    eval(); wait([&] { return dut.out_awready; }); tick(); dut.awvalid = 0; eval();
  }
  unsigned w(uint64_t data, bool last = true) {
    dut.wdata = data; dut.wlast = last; dut.wvalid = 1;
    eval(); wait([&] { return dut.out_wready; });
    unsigned accepted = cycle;
    tick(); dut.wvalid = 0; eval(); return accepted;
  }
  unsigned write(unsigned id, uint32_t addr, uint64_t data) {
    aw(id, addr); return w(data);
  }
  void drain(unsigned expected) {
    dut.bready = 1;
    wait([&] { return replies.size() == expected; });
    dut.bready = 0; eval();
  }
  uint64_t read(uint32_t addr, unsigned len = 0) {
    dut.arid = 9; dut.araddr = addr; dut.arlen = len; dut.arvalid = 1;
    eval(); wait([&] { return dut.out_arready; }); tick(); dut.arvalid = 0;
    eval(); wait([&] { return dut.out_rvalid; });
    assert(dut.out_rid == 9 && dut.out_rresp == 0);
    uint64_t value = dut.out_rdata;
    dut.rready = 1;
    for (unsigned i = 0; i <= len; i++) {
      wait([&] { return dut.out_rvalid; });
      assert(dut.out_rlast == (i == len)); tick();
    }
    dut.rready = 0; eval(); return value;
  }
};

static void queue_and_latency() {
  Harness h;
  std::vector<unsigned> accepted;
  for (unsigned i = 0; i < slots; i++)
    accepted.push_back(h.write(i & 15, 0x80000000 + i * 16, 0x12340000 + i));
  assert(h.replies.empty());
  h.dut.awid = 15; h.dut.awaddr = 0x80001000; h.dut.awvalid = 1; h.eval();
  if (slots == 1) {
    assert(h.dut.out_awready); h.tick(); h.dut.awvalid = 0;
    h.dut.wvalid = 1; h.dut.wlast = 1; h.eval();
    assert(!h.dut.out_wready); h.dut.wvalid = 0;
  } else {
    assert(!h.dut.out_awready); h.dut.awvalid = 0;
  }
  while (h.cycle < accepted.back() + latency + 5) h.tick();
  assert(h.dut.out_bvalid && h.dut.out_bid == 0);
  for (unsigned i = 0; i < 5; i++) {
    h.tick(); assert(h.dut.out_bvalid && h.dut.out_bid == 0 && h.dut.out_bresp == 0);
  }
  h.drain(slots);
  for (unsigned i = 0; i < slots; i++) {
    assert(h.replies[i].id == (i & 15) && h.replies[i].resp == 0);
    if (i) assert(h.replies[i].cycle == h.replies[i - 1].cycle + 1);
  }
  if (slots == 1) { h.w(0x88); h.drain(2); }

  // Wrap the physical ring and exercise enqueue and dequeue on the same edge.
  h.dut.bready = 1;
  unsigned prior = h.replies.size();
  for (unsigned i = 0; i < 150; i++) h.write(i & 15, 0x80002000, i);
  h.drain(prior + 150);
  for (unsigned i = 0; i < 150; i++) assert(h.replies[prior + i].id == (i & 15));

  Harness exact;
  exact.dut.bready = 1;
  unsigned last = exact.write(3, 0x80000000, 7);
  exact.drain(1);
  assert(exact.replies[0].cycle == last + latency + 1);
}

static void errors_and_bursts() {
  Harness h;
  h.dut.bready = 1;
  h.write(1, 0x80000000, 0x55);
  h.write(2, 0x60000000, 0xde);
  h.aw(3, 0x80000020, 1);
  h.w(0x11223344, false); h.w(0x55667788);
  h.write(4, 0x80000000, 0x99);
  h.drain(4);
  for (unsigned i = 0; i < 4; i++) {
    assert(h.replies[i].id == i + 1);
    assert(h.replies[i].resp == (i == 1 ? 3 : 0));
  }
  assert(h.read(0x80000000) == 0x99);
  assert(h.read(0x80000020) == 0x11223344);
  assert(h.read(0x80000020 + sizeof(word_t)) == 0x55667788);
}

static void read_and_device_ordering() {
  Harness priority;
  priority.dut.awid = 1; priority.dut.arid = 9;
  priority.dut.awaddr = priority.dut.araddr = 0x80004000;
  priority.dut.awvalid = priority.dut.arvalid = 1;
  priority.eval();
  assert(priority.dut.out_awready && !priority.dut.out_arready);
  priority.tick(); priority.dut.awvalid = 0;
  // The losing AR remains valid, with unchanged payload, through W/B.
  priority.w(0x123); priority.drain(1);
  assert(priority.dut.arvalid && priority.dut.araddr == 0x80004000);
  assert(priority.dut.out_arready);
  priority.tick(); priority.dut.arvalid = 0; priority.eval();
  priority.wait([&] { return priority.dut.out_rvalid; });
  assert(priority.dut.out_rid == 9 && priority.dut.out_rresp == 0);
  assert(priority.dut.out_rlast && priority.dut.out_rdata == 0x123);
  priority.dut.rready = 1; priority.tick(); priority.dut.rready = 0;

  Harness h;
  h.write(2, 0x80000000, 0xaabbccdd);
  assert(h.read(0x80001000) == 0);  // Independent RAM read may pass pending B.
  h.dut.araddr = 0x80000000; h.dut.arvalid = 1; h.eval();
  assert(!h.dut.out_arready);
#ifdef TEST_RV64
  h.dut.araddr = 0xffffffff80000000ULL; h.eval(); assert(!h.dut.out_arready);
#endif
  h.dut.araddr = 0x10000000; h.eval(); assert(!h.dut.out_arready);
  h.dut.arvalid = 0;
  h.dut.awaddr = 0x10000000; h.dut.awvalid = 1; h.eval();
  assert(!h.dut.out_awready); h.dut.awvalid = 0;
  h.drain(1);
  assert(h.read(0x80000000) == 0xaabbccdd);
  h.write(3, 0x10000000, 0x44);
  h.dut.araddr = 0x80001000; h.dut.arvalid = 1; h.eval(); assert(!h.dut.out_arready);
  h.dut.arvalid = 0;
  h.dut.awaddr = 0x80000000; h.dut.awvalid = 1; h.eval(); assert(!h.dut.out_awready);
  h.dut.awvalid = 0; h.drain(2);

  // Hold a read response and prevent a younger write from modifying its range.
  h.dut.araddr = 0x80000000; h.dut.arlen = 1; h.dut.arvalid = 1;
  h.eval(); assert(h.dut.out_arready); h.tick(); h.dut.arvalid = 0;
  h.dut.awaddr = 0x80000000 + sizeof(word_t); h.dut.awvalid = 1; h.eval();
  assert(!h.dut.out_awready);
  h.dut.awaddr = 0x80001000; h.eval(); assert(h.dut.out_awready);
  h.dut.awvalid = 0; h.dut.rready = 1; h.tick(); h.tick(); h.dut.rready = 0;

  // A burst read must wait even when only its last beat overlaps a pending write.
  h.write(5, 0x80000000 + sizeof(word_t), 0x8877);
  h.dut.araddr = 0x80000000; h.dut.arlen = 1; h.dut.arvalid = 1; h.eval();
  assert(!h.dut.out_arready); h.dut.arvalid = 0; h.drain(3);
  assert(h.read(0x80000000 + sizeof(word_t)) == 0x8877);
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  assert(argc == 2); slots = std::strtoul(argv[1], nullptr, 0);
  assert(slots >= 1 && slots <= 64);
  queue_and_latency(); errors_and_bursts();
  if (slots > 1) read_and_device_ordering();
  std::cout << "PASS npc_write_outstanding XLEN=" << sizeof(word_t) * 8
            << " slots=" << slots << " latency=" << latency << '\n';
}
