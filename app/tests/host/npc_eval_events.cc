// Exercise the production half-cycle bridge with a modeled notification FIFO.
// This checks bridge ordering, not virtio execution or LR/SC liveness.
#include <npc_eval.h>
#include <cassert>
#include <cstdio>
#include <deque>
#include <utility>
#include <vector>

using Range = std::pair<uint64_t, uint64_t>;
static std::deque<Range> events;
static unsigned consumed;
bool device_write_front(uint64_t *first, uint64_t *last) {
  if (events.empty()) return false;
  *first = events.front().first;
  *last = events.front().second;
  return true;
}
void device_write_consume() {
  assert(!events.empty());
  events.pop_front();
  ++consumed;
}
void device_write_reset() { events.clear(); }

template<class Address> struct Top {
  bool clock = false, reset = false;
  bool external_write_valid_i = false, external_write_pending_i = false;
  Address external_write_first_i = 0, external_write_last_i = 0;
  std::vector<Range> append_on_eval, observed;
  void eval() {
    assert(external_write_pending_i == external_write_valid_i);
    if (reset) assert(!external_write_valid_i);
    if (clock && external_write_valid_i)
      observed.emplace_back(external_write_first_i, external_write_last_i);
    for (auto range : append_on_eval) events.push_back(range);
    append_on_eval.clear();
  }
  void edge(bool rising) { clock = rising; npc_eval(this); }
};

template<class Address> void check_bridge(uint64_t base) {
  events.clear(); consumed = 0;
  Top<Address> dut;
  const Range a{base, base + 3}, b{base + 64, base + 71};
  // A callback on an otherwise empty rising edge must survive that edge.
  dut.append_on_eval = {a};
  dut.edge(true);
  assert(events.size() == 1 && consumed == 0 && dut.observed.empty());
  dut.edge(false);
  assert(events.size() == 1 && consumed == 0);
  // Newly appended events must survive consumption of the previously shown A.
  dut.append_on_eval = {b, a};
  dut.edge(true);
  assert(events.size() == 2 && consumed == 1);
  assert(dut.observed == std::vector<Range>{a});
  dut.edge(false); dut.edge(true);
  assert(events.size() == 1 && consumed == 2);
  dut.edge(false); dut.edge(true);
  assert(events.empty() && consumed == 3);
  assert((dut.observed == std::vector<Range>{a, b, a}));
  dut.edge(false);
  assert(!dut.external_write_valid_i && !dut.external_write_pending_i);

  // A finite, continuously valid burst drains one event per rising edge.
  std::vector<Range> expected = dut.observed;
  for (unsigned i = 0; i < 1024; ++i) {
    Range range{base + 128 + i * 8, base + 131 + i * 8};
    events.push_back(range); expected.push_back(range);
  }
  for (unsigned i = 0; i < 1024; ++i) {
    dut.edge(false);
    assert(events.size() == 1024 - i);
    dut.edge(true);
    assert(events.size() == 1023 - i);
  }
  assert(dut.observed == expected && consumed == 1027);
  dut.edge(false);
  assert(!dut.external_write_pending_i);

  events.push_back(a);
  dut.reset = true; dut.edge(false); dut.edge(true);
  assert(events.empty() && consumed == 1027);
  dut.reset = false; dut.edge(false); dut.edge(true);
  assert(!dut.external_write_pending_i && dut.observed == expected);
}

int main() {
  check_bridge<uint32_t>(0x80000000);
  check_bridge<uint64_t>(0x1000080000000ULL);
  std::puts("PASS: NPC event bridge, 1027 ordered events per address width");
}
