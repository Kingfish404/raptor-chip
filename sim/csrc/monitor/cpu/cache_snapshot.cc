// Architectural checkpoints must include dirty data which has left the SQ
// but has not reached host RAM. Read the functional SRAMs, never a store log.
#include <checkpoint.h>
#include <npc_verilog.h>
#include <type_traits>

extern TOP_NAME *top;

#define L1(m) VERILOG_CPU(CONCAT(memory_subsystem__DOT__l1d_cache__DOT__, m))
#define L2(m) VERILOG_CPU(CONCAT(memory_subsystem__DOT__l2__DOT__, m))
#define DIR(m) L2(CONCAT(g_boom_directory__DOT__u_directory__DOT__, m))

namespace {
template <typename T>
typename std::enable_if<std::is_integral<T>::value, uint64_t>::type
slice(const T &value, unsigned bit, unsigned bytes)
{
  return (uint64_t(value) >> bit) & (UINT64_MAX >> (64 - bytes * 8));
}

template <size_t N>
uint64_t slice(const VlWide<N> &value, unsigned bit, unsigned bytes)
{
  uint64_t result = 0;
  for (unsigned byte = 0; byte < bytes; ++byte)
    result |= uint64_t((value[(bit + byte * 8) / 32]
                       >> ((bit + byte * 8) % 32)) & 0xff) << (byte * 8);
  return result;
}

struct Bank
{
  const void *data = nullptr;
  size_t rows = 0;
  uint64_t (*read)(const void *, unsigned, unsigned, unsigned) = nullptr;

  uint64_t word(unsigned row, unsigned byte, unsigned bytes) const
  {
    Assert(data != nullptr && row < rows, "checkpoint: unsupported cache SRAM layout");
    return read(data, row, byte, bytes);
  }
};

template <typename Array> Bank bank(const Array &array)
{
  return {&array, array.size(), [](const void *data, unsigned row,
                                 unsigned byte, unsigned bytes) {
    return slice((*static_cast<const Array *>(data))[row], byte * 8, bytes);
  }};
}

// Generated instances are absent in smaller presets. Resolve those optional
// banks at compile time, and check the actual geometry before using a view.
#define CACHE_BANK(name, field) \
  template <typename Top> auto name(Top *top, int) -> decltype(bank(field)) \
  { return bank(field); } \
  template <typename Top> Bank name(Top *, long) { return {}; }
#define L1_BANK(w, b) CACHE_BANK(l1_##w##_##b, \
  L1(u_data__DOT__g_way__BRA__##w##__KET____DOT__g_bank__BRA__##b##__KET____DOT__u_sram__DOT__mem))
#define L1_WAY(w) L1_BANK(w, 0) L1_BANK(w, 1) L1_BANK(w, 2) L1_BANK(w, 3)
L1_WAY(0) L1_WAY(1) L1_WAY(2) L1_WAY(3)
#define DIRECTORY_BANK(w) CACHE_BANK(dir_##w, \
  DIR(g_way__BRA__##w##__KET____DOT__u_directory__DOT__mem))
DIRECTORY_BANK(0) DIRECTORY_BANK(1) DIRECTORY_BANK(2) DIRECTORY_BANK(3)
DIRECTORY_BANK(4) DIRECTORY_BANK(5) DIRECTORY_BANK(6) DIRECTORY_BANK(7)
#define L2_BANK(b) CACHE_BANK(l2_##b, \
  L2(g_boom_banked_store__DOT__u_data_array__DOT__g_bank__BRA__##b##__KET____DOT__u_data_sram__DOT__mem))
L2_BANK(0) L2_BANK(1) L2_BANK(2) L2_BANK(3)

template <typename Top>
auto writeback_l2(Top *top, int) -> decltype(L2(BoomBankedStore), bool())
{ return L2(BoomBankedStore); }
template <typename Top> bool writeback_l2(Top *, long) { return false; }

template <typename Top>
auto l1_misses_ready(Top *top, int)
    -> decltype(L1(g_mshr__DOT__misses__DOT__valid), bool())
{
  return !(L1(g_mshr__DOT__misses__DOT__valid)
      & (~L1(g_mshr__DOT__misses__DOT__done) | ~L1(g_mshr__DOT__misses__DOT__installed)));
}
template <typename Top> bool l1_misses_ready(Top *, long) { return true; }

template <typename Top>
auto l2_ready(Top *top, int) -> decltype(DIR(write_queued), bool())
{
  // A quiescent ownership window excludes dirty victims, partial releases,
  // store buffers, refills and CBOs. The directory's last queued update can
  // outlive that window by one cycle and must also finish.
  // Read functional storage/expressions rather than unused port aliases:
  // Verilator may retain an alias field without maintaining its value.
  return L2(rs) == 0 && L2(ws) == 0 && L2(cbo_state) == 0 && !L2(ms_slot_valid)
      && !L2(any_write_in_flight) && !L2(b_count) && !L2(cache_install)
      && !L2(release_pending) && !L2(cbo_busy)
      && L2(forward_replay_state) == 0 && !L2(forward_cache_pending) && !L2(dir_error_pending)
      && !L2(g_boom_banked_store__DOT__u_data_array__DOT__line_active)
      && DIR(wipe_count) == 1024 && !DIR(write_queued) && !L2(dir_write_valid);
}

// Disabled and legacy write-through L2s have no dirty SRAM directory.
template <typename Top> bool l2_ready(Top *top, long)
{
  Assert(!writeback_l2(top, 0), "checkpoint: missing write-back L2 directory");
  return true;
}

void read_l2(std::vector<CacheSnapshotWord> &words)
{
  if (!writeback_l2(top, 0)) return;
  Bank dirs[] = {dir_0(top, 0), dir_1(top, 0), dir_2(top, 0), dir_3(top, 0),
                 dir_4(top, 0), dir_5(top, 0), dir_6(top, 0), dir_7(top, 0)};
  Bank data[] = {l2_0(top, 0), l2_1(top, 0), l2_2(top, 0), l2_3(top, 0)};
  // The BOOM layout is fixed: 8 ways, 1024 sets, 64-byte lines. Directory
  // entries pack {dirty, state[1:0], client, tag[17:0]}.
  for (unsigned way = 0; way < 8; ++way)
    for (unsigned set = 0; set < 1024; ++set)
    {
      uint32_t entry = dirs[way].word(set, 0, 4);
      if (!(entry & (1u << 21)) || !(entry & (3u << 19))) continue;
      paddr_t base = (paddr_t(entry & 0x3ffffu) * 1024 + set) * 64;
      for (unsigned chunk = 0; chunk < 8; ++chunk)
      {
        unsigned row = (way * 1024 + set) * 2 + chunk / 4;
        words.push_back({base + chunk * 8, data[chunk % 4].word(row, 0, 8), 8});
      }
    }
}

void read_l1(std::vector<CacheSnapshotWord> &words)
{
  if (!L1(WriteBack)) return;
#define L1_VIEWS(w) {l1_##w##_0(top, 0), l1_##w##_1(top, 0), \
                     l1_##w##_2(top, 0), l1_##w##_3(top, 0)}
  Bank data[4][4] = {L1_VIEWS(0), L1_VIEWS(1), L1_VIEWS(2), L1_VIEWS(3)};
  const unsigned ways = L1(L1D_N_WAYS), sets = L1(L1D_SIZE);
  const unsigned line_words = L1(L1D_LINE_SIZE);
  const unsigned bank_words = L1(u_data__DOT__SubarrayWords);
  Assert(ways <= 4 && L1(u_data__DOT__Subarrays) <= 4,
         "checkpoint: unsupported L1D cache geometry");
  for (unsigned way = 0; way < ways; ++way)
    for (unsigned set = 0; set < sets; ++set)
    {
      auto dirty = L1(u_tags__DOT__dirty)[way][set];
      paddr_t base = (paddr_t(L1(u_tags__DOT__l1d_tag)[way][set]) * sets + set)
          * line_words * sizeof(word_t);
      for (unsigned word = 0; word < line_words; ++word)
        if ((dirty >> word) & 1u)
          words.push_back({paddr_t(base + word * sizeof(word_t)),
              data[way][word / bank_words].word(set, (word % bank_words) * sizeof(word_t),
                                               sizeof(word_t)), sizeof(word_t)});
    }
}
} // namespace

bool cpu_cache_snapshot_ready(void)
{
  return !L1(l1d_update) && !L1(l1d_rmw) && !L1(writeback__DOT__count)
      && L1(wb_state) == 0 && l1_misses_ready(top, 0) && l2_ready(top, 0);
}

void cpu_read_cache_snapshot(std::vector<CacheSnapshotWord> &words)
{
  Assert(cpu_cache_snapshot_ready(), "checkpoint: cache state is still changing");
  read_l2(words);
  if (!words.empty())
    Log("checkpoint: captured %zu dirty L2 bytes", words.size() * 8);
  size_t l2_words = words.size();
  read_l1(words);
  if (words.size() > l2_words)
    Log("checkpoint: captured %zu dirty L1D bytes", (words.size() - l2_words) * sizeof(word_t));
}
