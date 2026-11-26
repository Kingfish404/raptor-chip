#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <map>
#include <random>
#include <string>
#include <vector>

#include "Vtb_l2_fuzz_top.h"
#include "verilated.h"

#ifndef L2_FUZZ_XLEN
#define L2_FUZZ_XLEN 64
#endif
#ifndef L2_FUZZ_LEN
#define L2_FUZZ_LEN 9
#endif
#ifndef L2_FUZZ_LINE_LEN
#define L2_FUZZ_LINE_LEN 3
#endif
#ifndef L2_FUZZ_N_WAYS
#define L2_FUZZ_N_WAYS 8
#endif
#ifndef L2_FUZZ_PADDR_BITS
#define L2_FUZZ_PADDR_BITS 34
#endif

static constexpr int kXlen = L2_FUZZ_XLEN;
static constexpr int kWordBytes = kXlen / 8;
static constexpr int kLineWords = 1 << L2_FUZZ_LINE_LEN;
static constexpr int kLineBytes = kLineWords * kWordBytes;
static constexpr int kSetBits = L2_FUZZ_LEN;
static constexpr uint64_t kLineMask = ~uint64_t(kLineBytes - 1);
static constexpr uint64_t kWordMask = ~uint64_t(kWordBytes - 1);
static constexpr uint64_t kWordFullMask = (kXlen == 64) ? ~uint64_t(0) : 0xffffffffULL;
static constexpr uint64_t kStrbFullMask = (1ULL << kWordBytes) - 1;
static constexpr uint64_t kPmemBase = 0x80000000ULL;
static constexpr uint64_t kMmioBase = 0x10000000ULL;

struct InnerReadReq {
  uint64_t addr;
  uint64_t cur_addr;
  uint8_t id;
  uint8_t len;
  uint8_t rem;
  uint8_t size;
  uint8_t burst;
  uint8_t cache;
  bool cacheable;
  bool d_client;
  bool had_err;
  uint64_t words[16];
};

struct InnerWriteReq {
  uint64_t addr;
  uint8_t id;
  uint8_t len;
  uint8_t size;
  uint8_t burst;
  uint8_t cache;
  bool cacheable;
  bool bufferable;
  std::vector<uint64_t> wdata;
  std::vector<uint8_t> wstrb;
  std::vector<uint64_t> beat_addrs;
  size_t w_sent;
  bool aw_sent;
};

struct OuterReadTx {
  uint64_t addr;
  uint64_t cur_addr;
  uint8_t id;
  uint8_t len;
  uint8_t rem;
  uint8_t size;
  uint8_t burst;
  uint64_t ready_cycle;
  bool inject_err;
};

struct OuterWriteTx {
  uint64_t addr;
  uint64_t cur_addr;
  uint8_t id;
  uint8_t len;
  uint8_t rem;
  uint8_t size;
  uint8_t burst;
  bool w_done;
  uint64_t b_ready_cycle;
  bool inject_err;
};

struct L1DLine {
  bool present = false;
  bool dirty = false;
  uint64_t words[kLineWords] = {};
  uint32_t dirty_mask = 0;
};

struct AxiStallShadow {
  bool valid = false;
  uint64_t addr = 0;
  uint64_t data = 0;
  uint8_t id = 0;
  uint8_t len = 0;
  uint8_t size = 0;
  uint8_t burst = 0;
  uint8_t cache = 0;
  uint8_t strb = 0;
  uint8_t resp = 0;
  bool last = false;
};

static uint64_t next_axi_addr(uint64_t cur, uint8_t size, uint8_t burst, uint8_t len) {
  uint64_t step = 1ULL << size;
  if (burst == 0) return cur;
  if (burst == 2) {
    uint64_t wrap_bytes = (uint64_t(len) + 1ULL) << size;
    uint64_t mask = wrap_bytes - 1ULL;
    return (cur & ~mask) | ((cur + step) & mask);
  }
  return cur + step;
}

static bool is_d_client(uint8_t id) {
  return id == 2 || (id >= 8 && id <= 15);
}

static uint64_t read_word(const std::map<uint64_t, uint64_t>& mem, uint64_t addr) {
  uint64_t waddr = addr & kWordMask;
  auto it = mem.find(waddr);
  if (it != mem.end()) return it->second & kWordFullMask;
  // Deterministic non-zero backing pattern per address.
  uint64_t v = (waddr * 0x9e3779b97f4a7c15ULL) ^ 0x5a5a5a5a12345678ULL;
  return v & kWordFullMask;
}

static void write_word(std::map<uint64_t, uint64_t>& mem, uint64_t addr,
                       uint64_t data, uint8_t strb) {
  uint64_t waddr = addr & kWordMask;
  uint64_t oldv = read_word(mem, waddr);
  uint64_t newv = oldv;
  for (int b = 0; b < kWordBytes; b++) {
    if (strb & (1U << b)) {
      uint64_t mask = 0xffULL << (b * 8);
      newv = (newv & ~mask) | (data & mask);
    }
  }
  mem[waddr] = newv & kWordFullMask;
}

static void fail_abort(const Vtb_l2_fuzz_top* dut, uint64_t cyc, uint64_t seed,
                       int profile, const char* msg) {
  std::fprintf(stderr,
               "L2_FUZZ FAIL [seed=%llu profile=%d cyc=%llu]: %s\n"
               "  DUT: rs=%u ws=%u cbo=%u rel=%u ms_busy=%u ms_valid=0x%02x "
               "r_id=%u r_addr=0x%016llx boom=%u dir_rdy=%u\n"
               "  AXI_S: ar=%u/%u r=%u/%u(id=%u,last=%u,resp=%u) "
               "aw=%u/%u w=%u/%u b=%u/%u\n"
               "  AXI_M: ar=%u/%u r=%u/%u aw=%u/%u w=%u/%u b=%u/%u\n"
               "  COH: probe_v=%u probe_r=%u probe_addr=0x%016llx rel_v=%u rel_r=%u rel_ack=%u\n",
               (unsigned long long)seed, profile, (unsigned long long)cyc, msg,
               (unsigned)dut->dbg_rs, (unsigned)dut->dbg_ws, (unsigned)dut->dbg_cbo,
               (unsigned)dut->dbg_rel, (unsigned)dut->dbg_ms_busy, (unsigned)dut->dbg_ms_valid,
               (unsigned)dut->dbg_r_id, (unsigned long long)dut->dbg_r_addr,
               (unsigned)dut->dbg_boom, (unsigned)dut->dbg_dir_ready,
               (unsigned)dut->s_arvalid, (unsigned)dut->s_arready,
               (unsigned)dut->s_rvalid, (unsigned)dut->s_rready,
               (unsigned)dut->s_rid, (unsigned)dut->s_rlast, (unsigned)dut->s_rresp,
               (unsigned)dut->s_awvalid, (unsigned)dut->s_awready,
               (unsigned)dut->s_wvalid, (unsigned)dut->s_wready,
               (unsigned)dut->s_bvalid, (unsigned)dut->s_bready,
               (unsigned)dut->m_arvalid, (unsigned)dut->m_arready,
               (unsigned)dut->m_rvalid, (unsigned)dut->m_rready,
               (unsigned)dut->m_awvalid, (unsigned)dut->m_awready,
               (unsigned)dut->m_wvalid, (unsigned)dut->m_wready,
               (unsigned)dut->m_bvalid, (unsigned)dut->m_bready,
               (unsigned)dut->probe_valid_o, (unsigned)dut->probe_ready_i,
               (unsigned long long)dut->probe_addr_o,
               (unsigned)dut->release_valid_i, (unsigned)dut->release_ready_o,
               (unsigned)dut->release_ack_o);
  std::exit(1);
}

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  uint64_t seed = 1;
  uint64_t max_cycles = 2000000;
  uint64_t trace_line = ~0ULL;
  int profile = 0;
  for (int i = 1; i < argc; i++) {
    if (std::strncmp(argv[i], "--seed=", 7) == 0) seed = std::strtoull(argv[i] + 7, nullptr, 0);
    else if (std::strncmp(argv[i], "--cycles=", 9) == 0)
      max_cycles = std::strtoull(argv[i] + 9, nullptr, 0);
    else if (std::strncmp(argv[i], "--profile=", 10) == 0) profile = std::atoi(argv[i] + 10);
    else if (std::strncmp(argv[i], "--trace-line=", 13) == 0)
      trace_line = std::strtoull(argv[i] + 13, nullptr, 0) & kLineMask;
  }

  std::mt19937_64 rng(seed ^ (uint64_t(profile) * 0x9e3779b97f4a7c15ULL));
  auto rand_pct = [&](int pct) -> bool { return int(rng() % 100) < pct; };

  // Profile tuning knobs.
  int m_arready_pct = 75, m_awready_pct = 75, m_wready_pct = 75;
  int s_rready_pct = 85, s_bready_pct = 85;
  int r_min_lat = 2, r_max_lat = 20, b_min_lat = 2, b_max_lat = 16;
  int err_pct = 0;
  int num_sets_hot = 4, num_tags_hot = 12;
  int ooo_r_pct = 60;
  switch (profile) {
    case 1: // Heavy WREADY / AWREADY stall torture (Bug #1 & #2)
      m_awready_pct = 20; m_wready_pct = 15; r_max_lat = 12; break;
    case 2: // Heavy ARREADY + concurrent MSHR + no-allocate bypass torture (Bug #3)
      m_arready_pct = 25; r_min_lat = 10; r_max_lat = 40; break;
    case 3: // Heavy inner RREADY / BREADY backpressure
      s_rready_pct = 20; s_bready_pct = 20; break;
    case 4: // Extreme OOO beat-by-beat R interleaving + nested voluntary releases
      ooo_r_pct = 95; r_min_lat = 4; r_max_lat = 36; break;
    case 5: // Outer SLVERR / DECERR injection + recovery
      err_pct = 8; m_wready_pct = 45; break;
    case 6: // Extreme 2-set thrashing + CBO + dirty L1D probes + burst writes
      num_sets_hot = 2; num_tags_hot = 14; m_wready_pct = 50; break;
    default: break;
  }

  Vtb_l2_fuzz_top* dut = new Vtb_l2_fuzz_top();
  auto clear_inputs = [&]() {
    dut->s_arvalid = 0; dut->s_araddr = 0; dut->s_arid = 0; dut->s_arlen = 0;
    dut->s_arsize = 0; dut->s_arburst = 1; dut->s_arcache = 0xf; dut->s_rready = 1;
    dut->s_awvalid = 0; dut->s_awaddr = 0; dut->s_awid = 0; dut->s_awlen = 0;
    dut->s_awsize = 0; dut->s_awburst = 1; dut->s_awcache = 0xf;
    dut->s_wvalid = 0; dut->s_wdata = 0; dut->s_wstrb = 0; dut->s_wlast = 0;
    dut->s_bready = 1;
    dut->m_arready = 1; dut->m_rvalid = 0; dut->m_rdata = 0; dut->m_rid = 0;
    dut->m_rresp = 0; dut->m_rlast = 0;
    dut->m_awready = 1; dut->m_wready = 1; dut->m_bvalid = 0; dut->m_bid = 0; dut->m_bresp = 0;
    dut->cbo_inval_i = 0; dut->cbo_block_i = 0;
    dut->probe_ready_i = 0; dut->probe_release_valid_i = 0;
    dut->probe_release_addr_i = 0; dut->probe_release_data_i = 0;
    dut->release_valid_i = 0; dut->release_addr_i = 0; dut->release_data_i = 0;
    dut->release_has_data_i = 0; dut->release_mask_i = 0; dut->release_last_i = 0;
    dut->l1d_writeback_pending_i = 0;
  };
  clear_inputs();
  dut->clock = 0;
  dut->reset = 1;
  for (int i = 0; i < 6; i++) {
    dut->clock = 1; dut->eval();
    dut->clock = 0; dut->eval();
  }
  dut->reset = 0;
  dut->eval();

  const bool boom_mode = dut->dbg_boom != 0;

  std::map<uint64_t, uint64_t> golden_mem;
  std::map<uint64_t, uint64_t> backing_mem;
  std::map<uint64_t, L1DLine> l1d_lines;

  // In-flight inner state.
  bool s_rd_active[16] = {};
  InnerReadReq s_rd_req[16] = {};
  std::map<uint64_t, int> line_rd_cnt;
  std::map<uint64_t, int> line_wr_cnt;

  bool has_cur_ar = false;
  InnerReadReq cur_ar = {};

  bool has_cur_wr = false;
  InnerWriteReq cur_wr = {};
  std::deque<InnerWriteReq> b_wait_q;

  // In-flight outer state.
  std::vector<OuterReadTx> m_rd_q;
  std::deque<OuterWriteTx> m_aw_q;
  bool m_r_holding = false;
  size_t m_r_hold_idx = 0;
  uint64_t m_r_hold_data = 0;
  uint8_t m_r_hold_id = 0, m_r_hold_resp = 0;
  bool m_r_hold_last = false;
  bool m_b_holding = false;
  uint8_t m_b_hold_id = 0, m_b_hold_resp = 0;

  // Probe handling state.
  bool probe_active = false;
  uint64_t probe_line = 0;
  int probe_delay = 0;
  int probe_rel_word = 0;
  bool probe_rel_done = false;
  bool probe_ready_next = false;

  // Voluntary release handling state.
  bool rel_active = false;
  bool rel_wait_ack = false;
  uint64_t rel_line = 0;
  L1DLine rel_snap = {};
  int rel_word = 0;
  bool rel_has_data = false;

  // Protocol stability shadows.
  AxiStallShadow sh_m_ar, sh_m_aw, sh_m_w, sh_s_r, sh_s_b;

  uint64_t total_reads = 0, total_writes = 0, total_probes = 0;
  uint64_t total_releases = 0, total_cbos = 0, total_errs = 0;
  uint64_t last_progress_cyc = 0;

  // Build hot cacheable address pool (colliding sets + >8 tags + high PA if PADDR_BITS>=34).
  std::vector<uint64_t> hot_lines;
  for (int s = 0; s < num_sets_hot; s++) {
    for (int t = 0; t < num_tags_hot; t++) {
      uint64_t set_off = uint64_t(s) * kLineBytes;
      uint64_t tag_stride = uint64_t(1ULL << (kSetBits + L2_FUZZ_LINE_LEN + (kXlen == 64 ? 3 : 2)));
      uint64_t base = kPmemBase;
      if (L2_FUZZ_PADDR_BITS >= 34 && (t % 3 == 2)) base = 0x100000000ULL;
      hot_lines.push_back(base + uint64_t(t) * tag_stride + set_off);
    }
  }

  auto any_inner_active = [&]() -> bool {
    for (int i = 0; i < 16; i++) if (s_rd_active[i]) return true;
    return has_cur_ar || has_cur_wr || !b_wait_q.empty() || rel_active || rel_wait_ack;
  };

  for (uint64_t cyc = 0; cyc < max_cycles; cyc++) {
    // 1. Wait for directory reset wipe to finish before injecting traffic.
    bool ready_for_traffic = (dut->dbg_dir_ready != 0) || !boom_mode;
    if (cyc < 600 && !ready_for_traffic) last_progress_cyc = cyc;

    // 2. Drive outer AXI ready/response signals for this cycle.
    dut->m_arready = rand_pct(m_arready_pct) ? 1 : 0;
    dut->m_awready = rand_pct(m_awready_pct) ? 1 : 0;
    dut->m_wready = rand_pct(m_wready_pct) ? 1 : 0;

    if (!m_r_holding && !m_rd_q.empty()) {
      std::vector<size_t> eligible;
      for (size_t i = 0; i < m_rd_q.size(); i++) {
        if (m_rd_q[i].ready_cycle <= cyc) eligible.push_back(i);
      }
      if (!eligible.empty()) {
        size_t pick = rand_pct(ooo_r_pct) ? eligible[rng() % eligible.size()] : eligible[0];
        auto& tx = m_rd_q[pick];
        m_r_holding = true;
        m_r_hold_idx = pick;
        m_r_hold_id = tx.id;
        m_r_hold_last = (tx.rem == 0);
        m_r_hold_resp = (tx.inject_err && (tx.rem == 0 || rand_pct(30))) ? 2 : 0;
        m_r_hold_data = read_word(backing_mem, tx.cur_addr);
      }
    }
    dut->m_rvalid = m_r_holding ? 1 : 0;
    dut->m_rid = m_r_hold_id;
    dut->m_rdata = m_r_hold_data;
    dut->m_rresp = m_r_hold_resp;
    dut->m_rlast = m_r_hold_last ? 1 : 0;

    if (!m_b_holding && !m_aw_q.empty() && m_aw_q.front().w_done
        && m_aw_q.front().b_ready_cycle <= cyc) {
      m_b_holding = true;
      m_b_hold_id = m_aw_q.front().id;
      m_b_hold_resp = m_aw_q.front().inject_err ? 2 : 0;
    }
    dut->m_bvalid = m_b_holding ? 1 : 0;
    dut->m_bid = m_b_hold_id;
    dut->m_bresp = m_b_hold_resp;

    // 3. Inner backpressure.
    dut->s_rready = rand_pct(s_rready_pct) ? 1 : 0;
    dut->s_bready = rand_pct(s_bready_pct) ? 1 : 0;

    // 4. Probe & probe_release handling (coherent L1D shadow).
    dut->probe_ready_i = probe_ready_next ? 1 : 0;
    probe_ready_next = false;
    dut->probe_release_valid_i = 0;
    dut->probe_release_addr_i = 0;
    dut->probe_release_data_i = 0;

    if (dut->probe_valid_o && boom_mode) {
      uint64_t pline = dut->probe_addr_o & kLineMask;
      if (!probe_active || probe_line != pline) {
        probe_active = true;
        probe_line = pline;
        probe_delay = int(rng() % 5);
        probe_rel_word = 0;
        probe_rel_done = false;
      }
      if (probe_delay > 0) {
        probe_delay--;
      } else {
        auto it = l1d_lines.find(probe_line);
        if (it != l1d_lines.end() && it->second.present && it->second.dirty && !probe_rel_done) {
          while (probe_rel_word < kLineWords && !(it->second.dirty_mask & (1U << probe_rel_word)))
            probe_rel_word++;
          if (probe_rel_word < kLineWords) {
            dut->probe_release_valid_i = 1;
            dut->probe_release_addr_i = probe_line + uint64_t(probe_rel_word) * kWordBytes;
            dut->probe_release_data_i = it->second.words[probe_rel_word];
          } else {
            probe_rel_done = true;
          }
        } else {
          probe_rel_done = true;
        }
        if (probe_rel_done) {
          if (it != l1d_lines.end()) it->second.present = false;
          probe_ready_next = true;
        }
      }
    } else {
      probe_active = false;
    }

    // 5. Voluntary L1D Release generation (BOOM mode only).
    dut->release_valid_i = 0;
    dut->release_addr_i = 0;
    dut->release_data_i = 0;
    dut->release_has_data_i = 0;
    dut->release_mask_i = 0;
    dut->release_last_i = 0;
    if (boom_mode && ready_for_traffic && !rel_active && !rel_wait_ack && !probe_active
        && !dut->probe_window_o && !l1d_lines.empty() && rand_pct(profile == 4 ? 15 : 4)) {
      // Pick a present L1D line with no active read/write race.
      std::vector<uint64_t> cands;
      for (auto& kv : l1d_lines) {
        if (kv.second.present && line_rd_cnt[kv.first] == 0 && line_wr_cnt[kv.first] == 0)
          cands.push_back(kv.first);
      }
      if (!cands.empty()) {
        rel_line = cands[rng() % cands.size()];
        rel_snap = l1d_lines[rel_line];
        l1d_lines[rel_line].present = false;
        rel_active = true;
        rel_word = 0;
        rel_has_data = rel_snap.dirty;
        line_wr_cnt[rel_line]++;
      }
    }
    if (rel_active) {
      dut->release_valid_i = 1;
      dut->release_addr_i = rel_line + uint64_t(rel_word) * kWordBytes;
      dut->release_has_data_i = rel_has_data ? 1 : 0;
      dut->release_data_i = rel_has_data ? rel_snap.words[rel_word] : 0;
      dut->release_mask_i = (rel_has_data && (rel_snap.dirty_mask & (1U << rel_word))) ? 1 : 0;
      dut->release_last_i = (!rel_has_data || rel_word == kLineWords - 1) ? 1 : 0;
    }

    // 6. Occasional L1D dirty local store into a resident L1D line (no active race).
    if (boom_mode && ready_for_traffic && err_pct == 0 && !probe_active && !l1d_lines.empty()
        && rand_pct(10)) {
      for (auto& kv : l1d_lines) {
        if (kv.second.present && line_rd_cnt[kv.first] == 0 && line_wr_cnt[kv.first] == 0
            && rand_pct(25)) {
          int w = int(rng() % kLineWords);
          uint64_t val = rng() & kWordFullMask;
          kv.second.words[w] = val;
          kv.second.dirty = true;
          kv.second.dirty_mask |= (1U << w);
          write_word(golden_mem, kv.first + uint64_t(w) * kWordBytes, val,
                     uint8_t(kStrbFullMask));
          break;
        }
      }
    }

    // 7. Inner AR request generation.
    if (ready_for_traffic && !has_cur_ar && rand_pct(profile == 2 ? 75 : 55)) {
      static const uint8_t kClientIds[] = {1, 2, 3, 4, 8, 9, 10, 11, 12, 13, 14, 15};
      uint8_t id = kClientIds[rng() % (sizeof(kClientIds) / sizeof(kClientIds[0]))];
      if (!s_rd_active[id]) {
        bool mmio = rand_pct(profile == 2 ? 20 : 8);
        uint64_t line = mmio ? (kMmioBase + (rng() % 4) * kLineBytes)
                             : hot_lines[rng() % hot_lines.size()];
        if (line_wr_cnt[line] == 0) {
          InnerReadReq req = {};
          req.id = id;
          req.cacheable = !mmio;
          req.d_client = is_d_client(id);
          int woff = int(rng() % kLineWords);
          req.addr = line + uint64_t(woff) * kWordBytes;
          req.cur_addr = req.addr;
          req.size = (kXlen == 64) ? 3 : 2;
          if (mmio) {
            req.len = 0; req.burst = 1; req.cache = 0x0;
          } else {
            int kind = int(rng() % 10);
            if (kind < 3) {
              // No-allocate cacheable read (DPTW style: arcache = 4'b0011 -> Bug #3 stress!)
              req.len = 0; req.burst = 1; req.cache = 0x3;
            } else if (kind < 6) {
              // Full-line WRAP or INCR burst refill (L1D MSHR style!)
              req.len = uint8_t(kLineWords - 1);
              req.burst = rand_pct(50) ? 2 : 1;
              if (req.burst == 1) { req.addr = line; req.cur_addr = line; }
              req.cache = 0xf;
            } else if (kind < 8) {
              // Short 2-beat or 4-beat burst within line
              uint8_t blen = rand_pct(50) ? 1 : 3;
              if (woff + blen >= kLineWords) { req.addr = line; req.cur_addr = line; }
              req.len = blen; req.burst = 1; req.cache = 0xf;
            } else {
              // Single-beat cacheable read
              req.len = 0; req.burst = 1; req.cache = 0xf;
            }
          }
          req.rem = req.len;
          // If L1D already holds dirty copy of this line and a D-client reads,
          // skip (real L1D hits locally on its own dirty copy).
          auto it = l1d_lines.find(line);
          bool skip = req.d_client && it != l1d_lines.end() && it->second.present
                      && it->second.dirty;
          if (!skip) {
            cur_ar = req;
            has_cur_ar = true;
            line_rd_cnt[line]++;
          }
        }
      }
    }
    dut->s_arvalid = has_cur_ar ? 1 : 0;
    dut->s_araddr = cur_ar.addr;
    dut->s_arid = cur_ar.id;
    dut->s_arlen = cur_ar.len;
    dut->s_arsize = cur_ar.size;
    dut->s_arburst = cur_ar.burst;
    dut->s_arcache = cur_ar.cache;

    // 8. Inner AW/W request generation (one write burst serialized at a time).
    if (ready_for_traffic && !has_cur_wr && b_wait_q.size() < 8 && rand_pct(40)) {
      bool mmio = rand_pct(8);
      uint64_t line = mmio ? (kMmioBase + (rng() % 4) * kLineBytes)
                           : hot_lines[rng() % hot_lines.size()];
      // Avoid race with active reads/writes or dirty L1D copy on the same line.
      auto it = l1d_lines.find(line);
      bool l1d_dirty = (it != l1d_lines.end() && it->second.present && it->second.dirty);
      if (line_rd_cnt[line] == 0 && line_wr_cnt[line] == 0 && !l1d_dirty) {
        InnerWriteReq wreq = {};
        wreq.id = uint8_t(rng() % 16);
        wreq.cacheable = !mmio;
        wreq.size = (kXlen == 64) ? 3 : 2;
        wreq.burst = 1;
        int woff = int(rng() % kLineWords);
        if (mmio) {
          wreq.addr = line + uint64_t(woff) * kWordBytes;
          wreq.len = 0; wreq.cache = 0x0; wreq.bufferable = false;
        } else {
          int wkind = int(rng() % 10);
          if (wkind < 5) {
            // Bufferable scalar cacheable write (partial or full strobe).
            wreq.addr = line + uint64_t(woff) * kWordBytes;
            wreq.len = 0; wreq.cache = 0xf; wreq.bufferable = true;
          } else if (wkind < 7) {
            // Cacheable non-bufferable forwarded scalar write (coherent with cached lines).
            wreq.addr = line + uint64_t(woff) * kWordBytes;
            wreq.len = 0; wreq.cache = 0xe; wreq.bufferable = false;
          } else if (wkind < 9) {
            // Full-line bufferable burst write (line overwrite / CBO.ZERO style).
            wreq.addr = line;
            wreq.len = uint8_t(kLineWords - 1);
            wreq.cache = 0xf; wreq.bufferable = true;
          } else {
            // Short multi-beat partial-mask burst write within line.
            uint8_t blen = uint8_t(1 + (rng() % (kLineWords - 1)));
            if (woff + blen >= kLineWords) woff = 0;
            wreq.addr = line + uint64_t(woff) * kWordBytes;
            wreq.len = blen; wreq.cache = 0xf; wreq.bufferable = true;
          }
        }
        uint64_t ba = wreq.addr;
        for (int b = 0; b <= int(wreq.len); b++) {
          wreq.beat_addrs.push_back(ba);
          wreq.wdata.push_back(rng() & kWordFullMask);
          uint8_t strb = rand_pct(65) ? uint8_t(kStrbFullMask)
                                      : uint8_t((rng() & kStrbFullMask) | 1U);
          wreq.wstrb.push_back(strb);
          ba = next_axi_addr(ba, wreq.size, wreq.burst, wreq.len);
        }
        wreq.w_sent = 0;
        wreq.aw_sent = false;
        cur_wr = std::move(wreq);
        has_cur_wr = true;
        line_wr_cnt[line]++;
      }
    }
    dut->s_awvalid = (has_cur_wr && !cur_wr.aw_sent) ? 1 : 0;
    dut->s_awaddr = cur_wr.addr;
    dut->s_awid = cur_wr.id;
    dut->s_awlen = cur_wr.len;
    dut->s_awsize = cur_wr.size;
    dut->s_awburst = cur_wr.burst;
    dut->s_awcache = cur_wr.cache;
    bool can_drive_w = has_cur_wr && (cur_wr.aw_sent || dut->s_awvalid)
                       && cur_wr.w_sent < cur_wr.wdata.size();
    dut->s_wvalid = can_drive_w ? 1 : 0;
    if (can_drive_w) {
      dut->s_wdata = cur_wr.wdata[cur_wr.w_sent];
      dut->s_wstrb = cur_wr.wstrb[cur_wr.w_sent];
      dut->s_wlast = (cur_wr.w_sent + 1 == cur_wr.wdata.size()) ? 1 : 0;
    }

    // 9. Occasional CBO invalidate (when no writes in flight on target line).
    dut->cbo_inval_i = 0;
    if (boom_mode && ready_for_traffic && !has_cur_wr && b_wait_q.empty() && !rel_active
        && !rel_wait_ack && rand_pct(profile == 6 ? 3 : 1)) {
      uint64_t cline = hot_lines[rng() % hot_lines.size()];
      if (line_rd_cnt[cline] == 0 && line_wr_cnt[cline] == 0) {
        dut->cbo_inval_i = 1;
        dut->cbo_block_i = cline >> 6;
        total_cbos++;
      }
    }
    dut->l1d_writeback_pending_i = rand_pct(10) ? 1 : 0;

    // 10. Combinational settle before posedge.
    dut->eval();

    // ---- Strict AXI4 Protocol Stability Checks (pre-edge) ----
    if (sh_m_ar.valid) {
      if (!dut->m_arvalid || dut->m_araddr != sh_m_ar.addr || dut->m_arid != sh_m_ar.id
          || dut->m_arlen != sh_m_ar.len || dut->m_arsize != sh_m_ar.size
          || dut->m_arburst != sh_m_ar.burst || dut->m_arcache != sh_m_ar.cache)
        fail_abort(dut, cyc, seed, profile, "AXI_M AR violated valid/payload stability under stall");
    }
    if (sh_m_aw.valid) {
      if (!dut->m_awvalid || dut->m_awaddr != sh_m_aw.addr || dut->m_awid != sh_m_aw.id
          || dut->m_awlen != sh_m_aw.len || dut->m_awsize != sh_m_aw.size
          || dut->m_awburst != sh_m_aw.burst || dut->m_awcache != sh_m_aw.cache)
        fail_abort(dut, cyc, seed, profile, "AXI_M AW violated valid/payload stability under stall");
    }
    if (sh_m_w.valid) {
      if (!dut->m_wvalid || dut->m_wdata != sh_m_w.data || dut->m_wstrb != sh_m_w.strb
          || dut->m_wlast != sh_m_w.last)
        fail_abort(dut, cyc, seed, profile, "AXI_M W violated valid/payload stability under stall");
    }
    if (sh_s_r.valid) {
      if (!dut->s_rvalid || dut->s_rdata != sh_s_r.data || dut->s_rid != sh_s_r.id
          || dut->s_rresp != sh_s_r.resp || dut->s_rlast != sh_s_r.last)
        fail_abort(dut, cyc, seed, profile, "AXI_S R violated valid/payload stability under stall");
    }
    if (sh_s_b.valid) {
      if (!dut->s_bvalid || dut->s_bid != sh_s_b.id || dut->s_bresp != sh_s_b.resp)
        fail_abort(dut, cyc, seed, profile, "AXI_S B violated valid/payload stability under stall");
    }
    // Whitebox invariants.
    if (dut->dbg_rs == 15 && dut->dbg_ms_busy)
      fail_abort(dut, cyc, seed, profile, "DEADLOCK INVARIANT: rs == R_BYPASS_WAIT && ms_busy");
    if (dut->dbg_rs == 3 && is_d_client(dut->dbg_r_id))
      fail_abort(dut, cyc, seed, profile, "INCLUSIVITY BUG: R_HIT_PROBE for L1D client ID");

    // Capture handshakes before rising edge.
    bool s_ar_fire = dut->s_arvalid && dut->s_arready;
    bool s_r_fire = dut->s_rvalid && dut->s_rready;
    bool s_aw_fire = dut->s_awvalid && dut->s_awready;
    bool s_w_fire = dut->s_wvalid && dut->s_wready;
    bool s_b_fire = dut->s_bvalid && dut->s_bready;
    bool m_ar_fire = dut->m_arvalid && dut->m_arready;
    bool m_r_fire = dut->m_rvalid && dut->m_rready;
    bool m_aw_fire = dut->m_awvalid && dut->m_awready;
    bool m_w_fire = dut->m_wvalid && dut->m_wready;
    bool m_b_fire = dut->m_bvalid && dut->m_bready;
    bool pr_rel_fire = dut->probe_release_valid_i && dut->probe_release_ready_o;
    bool rel_fire = dut->release_valid_i && dut->release_ready_o;
    bool rel_ack_fire = dut->release_ack_o != 0;
    bool probe_done = dut->probe_valid_o && dut->probe_ready_i;

    uint64_t s_rdata_cap = dut->s_rdata;
    uint8_t s_rid_cap = dut->s_rid, s_rresp_cap = dut->s_rresp;
    bool s_rlast_cap = dut->s_rlast != 0;
    uint8_t s_bid_cap = dut->s_bid, s_bresp_cap = dut->s_bresp;

    uint64_t m_araddr_cap = dut->m_araddr, m_awaddr_cap = dut->m_awaddr;
    uint8_t m_arid_cap = dut->m_arid, m_arlen_cap = dut->m_arlen, m_arsize_cap = dut->m_arsize;
    uint8_t m_arburst_cap = dut->m_arburst;
    uint8_t m_awid_cap = dut->m_awid, m_awlen_cap = dut->m_awlen, m_awsize_cap = dut->m_awsize;
    uint8_t m_awburst_cap = dut->m_awburst;
    uint64_t m_wdata_cap = dut->m_wdata;
    uint8_t m_wstrb_cap = dut->m_wstrb;
    bool m_wlast_cap = dut->m_wlast != 0;

    // Update stall shadows for next cycle check.
    sh_m_ar.valid = dut->m_arvalid && !dut->m_arready;
    if (sh_m_ar.valid) {
      sh_m_ar.addr = dut->m_araddr; sh_m_ar.id = dut->m_arid; sh_m_ar.len = dut->m_arlen;
      sh_m_ar.size = dut->m_arsize; sh_m_ar.burst = dut->m_arburst; sh_m_ar.cache = dut->m_arcache;
    }
    sh_m_aw.valid = dut->m_awvalid && !dut->m_awready;
    if (sh_m_aw.valid) {
      sh_m_aw.addr = dut->m_awaddr; sh_m_aw.id = dut->m_awid; sh_m_aw.len = dut->m_awlen;
      sh_m_aw.size = dut->m_awsize; sh_m_aw.burst = dut->m_awburst; sh_m_aw.cache = dut->m_awcache;
    }
    sh_m_w.valid = dut->m_wvalid && !dut->m_wready;
    if (sh_m_w.valid) {
      sh_m_w.data = dut->m_wdata; sh_m_w.strb = dut->m_wstrb; sh_m_w.last = dut->m_wlast != 0;
    }
    sh_s_r.valid = dut->s_rvalid && !dut->s_rready;
    if (sh_s_r.valid) {
      sh_s_r.data = dut->s_rdata; sh_s_r.id = dut->s_rid;
      sh_s_r.resp = dut->s_rresp; sh_s_r.last = dut->s_rlast != 0;
    }
    sh_s_b.valid = dut->s_bvalid && !dut->s_bready;
    if (sh_s_b.valid) {
      sh_s_b.id = dut->s_bid; sh_s_b.resp = dut->s_bresp;
    }

    // 11. Tick clock.
    const uint8_t dbg_cbo_cap = dut->dbg_cbo;
    dut->clock = 1; dut->eval();
    dut->clock = 0; dut->eval();

    // 12. Process captured handshakes & golden verification.
    if (trace_line != ~0ULL) {
      if (s_ar_fire && (cur_ar.addr & kLineMask) == trace_line)
        std::printf("[T %llu] S_AR id=%u addr=0x%llx len=%u burst=%u cache=0x%x\n",
                    (unsigned long long)cyc, cur_ar.id, (unsigned long long)cur_ar.addr,
                    cur_ar.len, cur_ar.burst, cur_ar.cache);
      if (s_r_fire && (s_rd_req[s_rid_cap].cur_addr & kLineMask) == trace_line)
        std::printf("[T %llu] S_R  id=%u addr=0x%llx data=0x%016llx exp=0x%016llx last=%u resp=%u\n",
                    (unsigned long long)cyc, s_rid_cap,
                    (unsigned long long)s_rd_req[s_rid_cap].cur_addr,
                    (unsigned long long)(s_rdata_cap & kWordFullMask),
                    (unsigned long long)read_word(golden_mem, s_rd_req[s_rid_cap].cur_addr),
                    s_rlast_cap, s_rresp_cap);
      if (s_aw_fire && (cur_wr.addr & kLineMask) == trace_line)
        std::printf("[T %llu] S_AW id=%u addr=0x%llx len=%u cache=0x%x\n",
                    (unsigned long long)cyc, cur_wr.id, (unsigned long long)cur_wr.addr,
                    cur_wr.len, cur_wr.cache);
      if (s_w_fire && (cur_wr.beat_addrs[cur_wr.w_sent] & kLineMask) == trace_line)
        std::printf("[T %llu] S_W  addr=0x%llx data=0x%016llx strb=0x%02x last=%u\n",
                    (unsigned long long)cyc, (unsigned long long)cur_wr.beat_addrs[cur_wr.w_sent],
                    (unsigned long long)cur_wr.wdata[cur_wr.w_sent], cur_wr.wstrb[cur_wr.w_sent],
                    cur_wr.w_sent + 1 == cur_wr.wdata.size());
      if (m_ar_fire && (m_araddr_cap & kLineMask) == trace_line)
        std::printf("[T %llu] M_AR id=%u addr=0x%llx len=%u\n",
                    (unsigned long long)cyc, m_arid_cap, (unsigned long long)m_araddr_cap, m_arlen_cap);
      if (m_aw_fire && (m_awaddr_cap & kLineMask) == trace_line)
        std::printf("[T %llu] M_AW id=%u addr=0x%llx len=%u\n",
                    (unsigned long long)cyc, m_awid_cap, (unsigned long long)m_awaddr_cap, m_awlen_cap);
      if (m_w_fire && !m_aw_q.empty() && (m_aw_q.front().addr & kLineMask) == trace_line)
        std::printf("[T %llu] M_W  data=0x%016llx strb=0x%02x last=%u\n",
                    (unsigned long long)cyc, (unsigned long long)m_wdata_cap, m_wstrb_cap, m_wlast_cap);
      if (pr_rel_fire && (probe_line == trace_line))
        std::printf("[T %llu] PR_REL addr=0x%llx data=0x%016llx\n",
                    (unsigned long long)cyc, (unsigned long long)dut->probe_release_addr_i,
                    (unsigned long long)dut->probe_release_data_i);
      if (probe_done && probe_line == trace_line)
        std::printf("[T %llu] PROBE_DONE line=0x%llx\n", (unsigned long long)cyc, (unsigned long long)probe_line);
      if (rel_fire && rel_line == trace_line)
        std::printf("[T %llu] VOL_REL word=%d has_data=%u mask=%u data=0x%016llx\n",
                    (unsigned long long)cyc, rel_word, rel_has_data,
                    (unsigned)dut->release_mask_i, (unsigned long long)dut->release_data_i);
    }
    if (pr_rel_fire) {
      probe_rel_word++;
      last_progress_cyc = cyc;
    }
    if (probe_done) {
      total_probes++;
      probe_active = false;
      last_progress_cyc = cyc;
    }
    if (rel_fire) {
      last_progress_cyc = cyc;
      if (!rel_has_data || rel_word == kLineWords - 1) {
        rel_active = false;
        rel_wait_ack = true;
      } else {
        rel_word++;
      }
    }
    if (rel_ack_fire) {
      total_releases++;
      rel_wait_ack = false;
      line_wr_cnt[rel_line]--;
      last_progress_cyc = cyc;
    }

    if (s_ar_fire) {
      s_rd_active[cur_ar.id] = true;
      s_rd_req[cur_ar.id] = cur_ar;
      has_cur_ar = false;
      last_progress_cyc = cyc;
    }
    if (s_r_fire) {
      if (!s_rd_active[s_rid_cap])
        fail_abort(dut, cyc, seed, profile, "AXI_S R response for inactive RID");
      auto& rq = s_rd_req[s_rid_cap];
      if (s_rlast_cap != (rq.rem == 0))
        fail_abort(dut, cyc, seed, profile, "AXI_S RLAST beat count mismatch");
      if (s_rresp_cap != 0) {
        rq.had_err = true;
        total_errs++;
      } else if (err_pct == 0) {
        uint64_t expected = read_word(golden_mem, rq.cur_addr);
        if ((s_rdata_cap & kWordFullMask) != expected) {
          char buf[256];
          std::snprintf(buf, sizeof(buf),
                        "DATA MISMATCH on read id=%u addr=0x%016llx got=0x%016llx exp=0x%016llx",
                        (unsigned)s_rid_cap, (unsigned long long)rq.cur_addr,
                        (unsigned long long)(s_rdata_cap & kWordFullMask),
                        (unsigned long long)expected);
          fail_abort(dut, cyc, seed, profile, buf);
        }
      }
      int widx = int((rq.cur_addr & (kLineBytes - 1)) / kWordBytes);
      rq.words[widx] = s_rdata_cap & kWordFullMask;
      if (s_rlast_cap) {
        uint64_t line = rq.addr & kLineMask;
        line_rd_cnt[line]--;
        s_rd_active[s_rid_cap] = false;
        total_reads++;
        // Optionally install full-line clean L1D copy on D-client cacheable read.
        if (boom_mode && rq.d_client && rq.cacheable && !rq.had_err
            && (rq.cache & 0xc) != 0 && rq.len == kLineWords - 1 && rand_pct(40)) {
          auto& ent = l1d_lines[line];
          if (!ent.present) {
            ent.present = true;
            ent.dirty = false;
            ent.dirty_mask = 0;
            for (int w = 0; w < kLineWords; w++) ent.words[w] = rq.words[w];
          }
        }
      } else {
        rq.rem--;
        rq.cur_addr = next_axi_addr(rq.cur_addr, rq.size, rq.burst, rq.len);
      }
      last_progress_cyc = cyc;
    }

    if (s_aw_fire) {
      cur_wr.aw_sent = true;
      last_progress_cyc = cyc;
    }
    if (s_w_fire) {
      if (err_pct == 0) {
        write_word(golden_mem, cur_wr.beat_addrs[cur_wr.w_sent],
                   cur_wr.wdata[cur_wr.w_sent], cur_wr.wstrb[cur_wr.w_sent]);
      }
      cur_wr.w_sent++;
      last_progress_cyc = cyc;
    }
    if (has_cur_wr && cur_wr.aw_sent && cur_wr.w_sent == cur_wr.wdata.size()) {
      b_wait_q.push_back(std::move(cur_wr));
      has_cur_wr = false;
    }
    if (s_b_fire) {
      if (b_wait_q.empty())
        fail_abort(dut, cyc, seed, profile, "AXI_S B response without pending write");
      if (b_wait_q.front().id != s_bid_cap)
        fail_abort(dut, cyc, seed, profile, "AXI_S BID ordering mismatch");
      if (s_bresp_cap != 0) total_errs++;
      uint64_t line = b_wait_q.front().addr & kLineMask;
      line_wr_cnt[line]--;
      b_wait_q.pop_front();
      total_writes++;
      last_progress_cyc = cyc;
    }

    if (m_ar_fire) {
      OuterReadTx tx = {};
      tx.addr = m_araddr_cap;
      tx.cur_addr = m_araddr_cap;
      tx.id = m_arid_cap;
      tx.len = m_arlen_cap;
      tx.rem = m_arlen_cap;
      tx.size = m_arsize_cap;
      tx.burst = m_arburst_cap;
      tx.ready_cycle = cyc + uint64_t(r_min_lat + (rng() % (r_max_lat - r_min_lat + 1)));
      tx.inject_err = (err_pct > 0) && rand_pct(err_pct);
      m_rd_q.push_back(tx);
      last_progress_cyc = cyc;
    }
    if (m_r_fire) {
      auto& tx = m_rd_q[m_r_hold_idx];
      if (tx.rem == 0) {
        m_rd_q.erase(m_rd_q.begin() + m_r_hold_idx);
      } else {
        tx.rem--;
        tx.cur_addr = next_axi_addr(tx.cur_addr, tx.size, tx.burst, tx.len);
        tx.ready_cycle = cyc + (rand_pct(40) ? 1 : uint64_t(1 + rng() % 5));
      }
      m_r_holding = false;
      last_progress_cyc = cyc;
    }
    if (m_aw_fire) {
      OuterWriteTx tx = {};
      tx.addr = m_awaddr_cap;
      tx.cur_addr = m_awaddr_cap;
      tx.id = m_awid_cap;
      tx.len = m_awlen_cap;
      tx.rem = m_awlen_cap;
      tx.size = m_awsize_cap;
      tx.burst = m_awburst_cap;
      tx.w_done = false;
      // Async CBO dirty writebacks (cbo_state == C_AW == 5) intentionally park
      // in C_ERROR if DRAM fails; inject B errors on all other outer writes.
      tx.inject_err = (err_pct > 0) && (dbg_cbo_cap != 5) && rand_pct(err_pct);
      m_aw_q.push_back(tx);
      last_progress_cyc = cyc;
    }
    if (m_w_fire) {
      // Find earliest outer AW not yet w_done.
      OuterWriteTx* target = nullptr;
      for (auto& tx : m_aw_q) {
        if (!tx.w_done) { target = &tx; break; }
      }
      if (!target) fail_abort(dut, cyc, seed, profile, "AXI_M W beat without matching AW");
      if (m_wlast_cap != (target->rem == 0))
        fail_abort(dut, cyc, seed, profile, "AXI_M WLAST beat count mismatch");
      write_word(backing_mem, target->cur_addr, m_wdata_cap, m_wstrb_cap);
      if (m_wlast_cap) {
        target->w_done = true;
        target->b_ready_cycle = cyc + uint64_t(b_min_lat + (rng() % (b_max_lat - b_min_lat + 1)));
      } else {
        target->rem--;
        target->cur_addr = next_axi_addr(target->cur_addr, target->size,
                                         target->burst, target->len);
      }
      last_progress_cyc = cyc;
    }
    if (m_b_fire) {
      m_aw_q.pop_front();
      m_b_holding = false;
      last_progress_cyc = cyc;
    }

    // 13. Deadlock watchdog.
    if (ready_for_traffic && any_inner_active() && (cyc - last_progress_cyc) > 8000) {
      fail_abort(dut, cyc, seed, profile, "DEADLOCK WATCHDOG (>8000 cycles without progress)");
    }
  }

  std::printf("L2_FUZZ PASS [seed=%llu profile=%d cycles=%llu]: "
              "reads=%llu writes=%llu probes=%llu releases=%llu cbos=%llu errs=%llu\n",
              (unsigned long long)seed, profile, (unsigned long long)max_cycles,
              (unsigned long long)total_reads, (unsigned long long)total_writes,
              (unsigned long long)total_probes, (unsigned long long)total_releases,
              (unsigned long long)total_cbos, (unsigned long long)total_errs);
  delete dut;
  return 0;
}
