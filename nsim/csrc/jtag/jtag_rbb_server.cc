// =============================================================================
// OpenOCD `remote_bitbang` server bridging into the live Raptor RTL TAP.
//
// What this provides:
//   * Standalone nsim mode (--jtag-server) that owns its own VerilatedContext
//     and DUT instance (no NEMU, no MROM, no images), spins the RTL clock,
//     and exposes the JTAG TAP (jtag_tck / jtag_tms / jtag_tdi / jtag_tdo)
//     over OpenOCD's documented `remote_bitbang` TCP protocol.
//
//   * One byte per TCK cycle: '0'..'7' encode {TRSTn, TMS, TDI} and request
//     a TCK rising edge; 'R' samples TDO; 'r'/'s' / 'B'/'b' / 't' / 'Q' have
//     the standard OpenOCD meanings (reset, blink, sync, quit). See
//     https://github.com/openocd-org/openocd/blob/master/doc/manual/jtag/drivers/remote_bitbang.txt
//
// Pairing:
//   * verify/jtag/openocd.cfg points OpenOCD at TCP 127.0.0.1:9824 (default;
//     overridable via `--jtag-port=<n>`).
//   * Build: only the npc top exposes JTAG pins; ysyxSoC ties them off
//     internally, so this mode is a no-op there (matches jtag_selftest).
//
// Scope today (matches rapt_dm capability):
//   * OpenOCD `scan_chain` returns IDCODE = 0x10001913 (verified end-to-end).
//   * `riscv dmi_read 0x11` (dmstatus), `0x16` (abstractcs), `0x10`
//     (dmcontrol), `0x04` (data0) all transact correctly.
//   * `target halt` will *fail* -- `haltreq_o` is wired but the core's
//     CMU/IFU do not yet act on it. That is expected and is the next RTL
//     milestone in docs-ref/dev.jtag.md.
// =============================================================================

#include <common.h>
#include <cstdio>

#ifdef RAPT_SOC

extern "C" int jtag_rbb_server_main(int /*argc*/, char * /*argv*/[]) {
  fprintf(stderr,
          "[jtag-server] not supported in ysyxSoC build (RAPT_SOC defined): "
          "JTAG pins are tied off internally. Use the npc build instead.\n");
  return 1;
}

#else  // !RAPT_SOC -- npc build with JTAG pins on the Verilator top

#include <arpa/inet.h>
#include <cerrno>
#include <csignal>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <unistd.h>

#include "verilated.h"

#include CONCAT_HEAD(TOP_NAME)

namespace {

constexpr uint16_t kDefaultPort  = 9824;
// Hard cap so a pathological client cannot stall the simulation forever.
// 100M cycles is well above any sane OpenOCD `scan_chain` + DMI sequence
// while still terminating cleanly on a wedged client.
constexpr uint64_t kMaxCycles    = 100ull * 1000ull * 1000ull;

VerilatedContext *g_ctx = nullptr;
TOP_NAME *g_top = nullptr;

volatile std::sig_atomic_t g_should_quit = 0;
void sigint_handler(int) { g_should_quit = 1; }

// One Verilator clock pulse with current jtag_* port values latched.
inline void clk_pulse() {
  g_top->clock = 0;
  g_top->eval();
  g_ctx->timeInc(1);
  g_top->clock = 1;
  g_top->eval();
  g_ctx->timeInc(1);
}

// Apply a remote_bitbang command byte. Returns true if the command needs
// a TDO sample to be sent back to the client (i.e. 'R').
//
// Protocol reference: OpenOCD remote_bitbang.txt
//   '0'..'7' encode three booleans in (b - '0'): bit2=TCK, bit1=TMS, bit0=TDI.
//   OpenOCD drives TCK explicitly, sending one byte for the falling phase
//   and one for the rising phase of every TAP cycle. Our RTL TAP advances
//   on the system clock (there is no dedicated jtag_tck pin), so we must
//   pulse the DUT clock *only* on the simulated TCK rising edge.
bool apply_rbb_byte(uint8_t b, uint8_t *tdo_out) {
  // Latched simulated TCK level. OpenOCD initialises TCK low.
  static uint8_t prev_tck = 0;

  switch (b) {
    case '0': case '1': case '2': case '3':
    case '4': case '5': case '6': case '7': {
      uint8_t v       = static_cast<uint8_t>(b - '0');
      uint8_t new_tck = (v >> 2) & 1;
      g_top->jtag_tms = (v >> 1) & 1;
      g_top->jtag_tdi = (v >> 0) & 1;
      if (new_tck && !prev_tck) {
        // Rising TCK edge: latch one TAP step.
        clk_pulse();
      }
      prev_tck = new_tck;
      return false;
    }
    case 'R':  // sample TDO
      *tdo_out = g_top->jtag_tdo & 1;
      return true;
    case 'r':  // System reset deassert (per OpenOCD convention)
    case 's':  // System reset assert: ignored -- we don't model SRST here.
      return false;
    case 't':  // TRST deassert
      g_top->jtag_trst_n = 1;
      return false;
    case 'u':  // TRST assert
      g_top->jtag_trst_n = 0;
      return false;
    case 'B': case 'b':  // LED blink: harmless to ignore in sim.
      return false;
    case 'Q':  // quit
      g_should_quit = 1;
      return false;
    default:
      // Unknown byte: treat as no-op rather than fatal so OpenOCD CLI noise
      // (e.g. extra whitespace from buggy scripts) does not kill the run.
      return false;
  }
}

void apply_rapt_reset() {
  g_top->reset      = 1;
  g_top->jtag_trst_n = 0;
  g_top->jtag_tms    = 1;
  g_top->jtag_tdi    = 0;
  for (int i = 0; i < 16; ++i) clk_pulse();
  g_top->reset      = 0;
  g_top->jtag_trst_n = 1;
  // Park TAP in TLR via 5x TMS=1 then drop into RTI.
  for (int i = 0; i < 6; ++i) {
    g_top->jtag_tms = 1;
    clk_pulse();
  }
  g_top->jtag_tms = 0;
  clk_pulse();
}

int listen_socket(uint16_t port) {
  int s = ::socket(AF_INET, SOCK_STREAM, 0);
  if (s < 0) {
    fprintf(stderr, "[jtag-server] socket(): %s\n", std::strerror(errno));
    return -1;
  }
  int one = 1;
  ::setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));

  sockaddr_in addr {};
  addr.sin_family      = AF_INET;
  addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  addr.sin_port        = htons(port);
  if (::bind(s, reinterpret_cast<sockaddr *>(&addr), sizeof(addr)) < 0) {
    fprintf(stderr, "[jtag-server] bind(127.0.0.1:%u): %s\n", port,
            std::strerror(errno));
    ::close(s);
    return -1;
  }
  if (::listen(s, 1) < 0) {
    fprintf(stderr, "[jtag-server] listen(): %s\n", std::strerror(errno));
    ::close(s);
    return -1;
  }
  return s;
}

int accept_one_client(int listener) {
  fprintf(stderr, "[jtag-server] waiting for OpenOCD on 127.0.0.1...\n");
  while (!g_should_quit) {
    fd_set rfds;
    FD_ZERO(&rfds);
    FD_SET(listener, &rfds);
    timeval tv { 1, 0 };
    int n = ::select(listener + 1, &rfds, nullptr, nullptr, &tv);
    if (n < 0) {
      if (errno == EINTR) continue;
      fprintf(stderr, "[jtag-server] select(accept): %s\n",
              std::strerror(errno));
      return -1;
    }
    if (n > 0 && FD_ISSET(listener, &rfds)) {
      int c = ::accept(listener, nullptr, nullptr);
      if (c < 0) {
        if (errno == EINTR) continue;
        fprintf(stderr, "[jtag-server] accept(): %s\n", std::strerror(errno));
        return -1;
      }
      // Disable Nagle so each TCK command round-trips immediately --
      // remote_bitbang is latency-sensitive at small batch sizes.
      int one = 1;
      ::setsockopt(c, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
      fprintf(stderr, "[jtag-server] OpenOCD connected.\n");
      return c;
    }
  }
  return -1;
}

}  // namespace

extern "C" int jtag_rbb_server_main(int argc, char *argv[]) {
  uint16_t port = kDefaultPort;
  for (int i = 1; i < argc; ++i) {
    if (std::strncmp(argv[i], "--jtag-port=", 12) == 0) {
      int p = std::atoi(argv[i] + 12);
      if (p > 0 && p < 65536) port = static_cast<uint16_t>(p);
    }
  }

  std::signal(SIGINT,  sigint_handler);
  std::signal(SIGTERM, sigint_handler);
  std::signal(SIGPIPE, SIG_IGN);

  fprintf(stderr,
          "[jtag-server] OpenOCD remote_bitbang bridge starting "
          "(127.0.0.1:%u)\n", port);

  g_ctx = new VerilatedContext;
  g_ctx->commandArgs(argc, argv);
  g_top = new TOP_NAME{g_ctx};

  apply_rapt_reset();

  int listener = listen_socket(port);
  if (listener < 0) {
    delete g_top;
    delete g_ctx;
    return 1;
  }

  int rc = 0;
  uint64_t cycle_count = 0;

  while (!g_should_quit) {
    int client = accept_one_client(listener);
    if (client < 0) break;

    // Per-connection inner loop. We read up to 256 RBB bytes per `recv`,
    // process each by stepping the DUT, and batch any 'R' replies into
    // a single send() to keep TCP traffic compact.
    uint8_t in_buf[256];
    uint8_t out_buf[256];

    bool client_alive = true;
    while (!g_should_quit && client_alive) {
      ssize_t n = ::recv(client, in_buf, sizeof(in_buf), 0);
      if (n < 0) {
        if (errno == EINTR) continue;
        fprintf(stderr, "[jtag-server] recv(): %s\n", std::strerror(errno));
        client_alive = false;
        break;
      }
      if (n == 0) {
        fprintf(stderr, "[jtag-server] client closed connection.\n");
        client_alive = false;
        break;
      }
      size_t out_len = 0;
      for (ssize_t i = 0; i < n && !g_should_quit; ++i) {
        uint8_t tdo = 0;
        if (apply_rbb_byte(in_buf[i], &tdo)) {
          out_buf[out_len++] = tdo ? '1' : '0';
        }
        if (++cycle_count > kMaxCycles) {
          fprintf(stderr,
                  "[jtag-server] cycle cap (%llu) hit -- closing client\n",
                  (unsigned long long)kMaxCycles);
          g_should_quit = 1;
          rc = 2;
          break;
        }
      }
      if (out_len > 0) {
        const uint8_t *p = out_buf;
        size_t left = out_len;
        while (left > 0) {
          ssize_t s = ::send(client, p, left, 0);
          if (s < 0) {
            if (errno == EINTR) continue;
            fprintf(stderr, "[jtag-server] send(): %s\n",
                    std::strerror(errno));
            client_alive = false;
            break;
          }
          p    += s;
          left -= static_cast<size_t>(s);
        }
      }
    }

    ::close(client);
    if (g_should_quit) break;
    fprintf(stderr,
            "[jtag-server] ready for next client (Ctrl-C to exit)\n");
  }

  ::close(listener);
  delete g_top;
  delete g_ctx;
  g_top = nullptr;
  g_ctx = nullptr;

  fprintf(stderr, "[jtag-server] shutdown.\n");
  return rc;
}

#endif  // !RAPT_SOC
