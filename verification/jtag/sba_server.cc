// Remote-bitbang host for sba_top. Every TCK half period contains eight core
// clocks, exercising the production JTAG synchronizers rather than bypassing them.
#include "Vsba_top.h"
#include "verilated.h"
#include <arpa/inet.h>
#include <cerrno>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <netinet/tcp.h>
#include <sys/socket.h>
#include <unistd.h>

static volatile std::sig_atomic_t stopping = 0;
static void stop(int) { stopping = 1; }

int main(int argc, char **argv) {
  unsigned port = 9824;
  for (int i = 1; i < argc; ++i)
    if (std::strncmp(argv[i], "--jtag-port=", 12) == 0)
      port = std::strtoul(argv[i] + 12, nullptr, 10);
  VerilatedContext context;
  context.commandArgs(argc, argv);
  Vsba_top top{&context};
  bool reported = false;
  auto clocks = [&](int count) {
    for (int c = 0; c < count; ++c) {
      top.clock = 0;
      top.eval();
      context.timeInc(1);
      top.clock = 1;
      top.eval();
      context.timeInc(1);
      if (top.bad_trap || context.gotFinish()) std::exit(1);
      if (top.good_trap && !reported) {
        std::puts("HIT GOOD TRAP: program loaded through SBA");
        std::fflush(stdout);
        reported = true;
      }
    }
  };
  top.reset = 1;
  top.tck = 0;
  top.tms = 1;
  top.tdi = 0;
  clocks(32);
  top.reset = 0;
  clocks(32);

  std::signal(SIGTERM, stop);
  std::signal(SIGINT, stop);
  std::signal(SIGPIPE, SIG_IGN);
  int listener = socket(AF_INET, SOCK_STREAM, 0);
  int one = 1;
  setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
  sockaddr_in address{};
  address.sin_family = AF_INET;
  address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  address.sin_port = htons(port);
  if (bind(listener, reinterpret_cast<sockaddr *>(&address), sizeof(address)) ||
      listen(listener, 1)) {
    std::perror("SBA server bind/listen");
    return 1;
  }
  std::printf("waiting for OpenOCD on 127.0.0.1:%u\n", port);
  std::fflush(stdout);
  int client = accept(listener, nullptr, nullptr);
  if (client < 0) return 1;
  setsockopt(client, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
  unsigned char input[4096];
  bool quit = false;
  while (!stopping && !quit) {
    ssize_t length = recv(client, input, sizeof(input), 0);
    if (length <= 0) break;
    char output[4096];
    size_t used = 0;
    for (ssize_t i = 0; i < length; ++i) {
      unsigned char b = input[i];
      if (b >= '0' && b <= '7') {
        top.tck = ((b - '0') >> 2) & 1;
        top.tms = ((b - '0') >> 1) & 1;
        top.tdi = (b - '0') & 1;
        clocks(8);
      } else if (b == 'R') output[used++] = top.tdo ? '1' : '0';
      else if (b == 'Q') quit = true;
    }
    size_t sent = 0;
    while (sent < used) {
      ssize_t n = send(client, output + sent, used - sent, MSG_NOSIGNAL);
      if (n < 0 && errno == EINTR) continue;
      if (n <= 0) { quit = true; break; }
      sent += static_cast<size_t>(n);
    }
  }
  close(client);
  close(listener);
  return 0;
}
