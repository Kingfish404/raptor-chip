#include <common.h>
#include <cstdio>
#include <cstring>

// Default-mode entry points (CPU simulation; CLI parsed by monitor.cc).
void init_monitor(int, char *[]);
void engine_start();
void engine_free();
int is_exit_status_bad();
int sig_dump_if_enabled(void);

// Alternate-mode entry points. Each owns its own simulator lifecycle and
// is selected by a single CLI flag. To add a new mode: declare its `_main`
// here and append one row to kModes[].
extern "C" int jtag_selftest_main(int argc, char *argv[]);
extern "C" int jtag_rbb_server_main(int argc, char *argv[]);

namespace
{

  struct Mode
  {
    const char *flag;
    int (*entry)(int, char *[]);
    const char *summary;
  };

  constexpr Mode kModes[] = {
      {"--jtag-selftest", jtag_selftest_main,
       "JTAG TAP/DTM/DM compliance probe (no NEMU / no image)"},
      {"--jtag-server", jtag_rbb_server_main,
       "OpenOCD remote_bitbang TCP server (--jtag-port=N, default 9824)"},
  };

} // namespace

int main(int argc, char *argv[])
{
  for (int i = 1; i < argc; ++i)
  {
    if (std::strcmp(argv[i], "--help-modes") == 0)
    {
      std::fprintf(stderr, "Alternate-mode flags:\n");
      for (const Mode &m : kModes)
      {
        std::fprintf(stderr, "  %-18s %s\n", m.flag, m.summary);
      }
      return 0;
    }
    for (const Mode &m : kModes)
      if (std::strcmp(argv[i], m.flag) == 0)
        return m.entry(argc, argv);
  }

  init_monitor(argc, argv);
  engine_start();
  sig_dump_if_enabled();
  int bad = is_exit_status_bad();
  engine_free();
  return bad;
}
