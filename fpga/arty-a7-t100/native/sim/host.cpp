// Binary JTAG pin adapter. Python executes the same DMI/SBA operations as on a probe.
#include "Vrapt_arty_native_sim.h"
#include "verilated.h"
#include <array>
#include <cstdint>
#include <cstdio>
#include <stdexcept>
#include <unistd.h>
#include <vector>

#ifndef NATIVE_CORE_HZ
#define NATIVE_CORE_HZ 10000000
#endif
#ifndef NATIVE_UART_DIVISOR
#define NATIVE_UART_DIVISOR 11
#endif

class Simulation {
 public:
  VerilatedContext context;
  Vrapt_arty_native_sim dut{&context};
  std::vector<uint8_t> console;
  int uart_bit = -1;
  uint64_t uart_sample = 0;
  uint8_t uart_data = 0;
  static constexpr uint64_t BitPs = 1000000000000LL * 16 * NATIVE_UART_DIVISOR / NATIVE_CORE_HZ;

  void watch_uart() {
    if (uart_bit < 0 && !dut.uart1_tx) {
      uart_bit = 0;
      uart_data = 0;
      uart_sample = context.time() + BitPs + BitPs / 2;
    }
  }
  void evaluate() {
    dut.eval();
    watch_uart();
    if (context.gotFinish()) throw std::runtime_error("RTL stopped during a native operation");
  }
  void advance(uint64_t delta) {
    const uint64_t end = context.time() + delta;
    evaluate();
    while (true) {
      uint64_t next = end + 1;
      if (dut.eventsPending()) next = dut.nextTimeSlot();
      if (uart_bit >= 0 && uart_sample < next) next = uart_sample;
      if (next > end) break;
      context.time(next);
      evaluate();
      if (uart_bit >= 0 && uart_sample == next) {
        if (uart_bit < 8) {
          uart_data |= uint8_t(dut.uart1_tx) << uart_bit++;
          uart_sample += BitPs;
        } else {
          if (!dut.uart1_tx) throw std::runtime_error("Native UART1 stop bit failed");
          console.push_back(uart_data);
          uart_bit = -1;
        }
      }
    }
    context.time(end);
    evaluate();
  }
  void ticks(uint32_t count) { advance(uint64_t(count) * 10000); }
  uint32_t scan(uint8_t count, uint32_t tms, uint32_t tdi) {
    if (!count || count > 32) throw std::runtime_error("JTAG scan length");
    uint32_t result = 0;
    for (unsigned bit = 0; bit < count; ++bit) {
      dut.jtag_tck = 0;
      dut.jtag_tms = (tms >> bit) & 1;
      dut.jtag_tdi = (tdi >> bit) & 1;
      ticks(100);  // 500 kHz TCK, matching the native board flow.
      result |= uint32_t(dut.jtag_tdo) << bit;
      dut.jtag_tck = 1;
      ticks(100);
    }
    dut.jtag_tck = 0;
    ticks(100);
    return result;
  }
};

static uint32_t word(const std::array<uint8_t, 10> &packet, unsigned at) {
  uint32_t value = 0;
  for (unsigned n = 0; n < 4; ++n) value |= uint32_t(packet[at + n]) << (8 * n);
  return value;
}

int main(int argc, char **argv) {
  // Keep RTL diagnostics separate from the binary protocol stream.
  FILE *responses = fdopen(dup(STDOUT_FILENO), "wb");
  if (!responses || dup2(STDERR_FILENO, STDOUT_FILENO) < 0) return 2;
  try {
    Simulation sim;
    sim.context.commandArgs(argc, argv);
    sim.dut.clk100 = 0;
    sim.dut.btn = 3;
    sim.dut.jtag_tck = 0;
    sim.dut.jtag_tms = 1;
    sim.dut.jtag_tdi = 1;
    sim.ticks(100);
    sim.dut.btn = 2;
    sim.ticks(1000);
    sim.dut.btn = 0;
    sim.ticks(1000);
    std::array<uint8_t, 10> packet;
    while (std::fread(packet.data(), 1, packet.size(), stdin) == packet.size()) {
      uint32_t result = 0;
      switch (packet[0]) {
        case 'J': result = sim.scan(packet[1], word(packet, 2), word(packet, 6)); break;
        case 'B': {
          // Remote-bitbang test adapter: actual pins, one 500 kHz half period.
          const uint32_t pins = word(packet, 2);
          sim.dut.jtag_tck = (pins >> 2) & 1;
          sim.dut.jtag_tms = (pins >> 1) & 1;
          sim.dut.jtag_tdi = pins & 1;
          sim.ticks(100);
          result = sim.dut.jtag_tdo;
          break;
        }
        case 'W': sim.ticks(word(packet, 2)); break;
        case 'R': sim.dut.btn = word(packet, 2) & 3; sim.ticks(1000); break;
        case 'S': result = sim.dut.flash_reset_n; break;
        case 'D': result = sim.dut.host_ds_oe_o; break;
        case 'P': result = sim.dut.programs_o; break;
        case 'E': result = sim.dut.erases_o; break;
        case 'F': result = sim.dut.octal_frames_o; break;
        case 'A': result = sim.dut.last_program_o; break;
        case 'Z': result = sim.dut.last_erase_o; break;
        case 'T': result = uint32_t(sim.context.time()); break;
        case 'H': result = uint32_t(sim.context.time() >> 32); break;
        case 'M': {
          const unsigned metric = packet[1];
          if (metric < 8) result = sim.dut.lane_min_ps_o[metric];
          else if (metric < 16) result = sim.dut.lane_max_ps_o[metric - 8];
          else if (metric < 24) result = sim.dut.lane_count_o[metric - 16];
          else if (metric < 36) result = sim.dut.timing_ps_o[metric - 24];
          else if (metric < 44) result = sim.dut.lane_rise_count_o[metric - 36];
          else if (metric < 52) result = sim.dut.lane_fall_count_o[metric - 44];
          else if (metric < 55) result = sim.dut.core_period_ps_o[metric - 52];
          else throw std::runtime_error("Unknown pin monitor metric");
          break;
        }
        case 'U':
          if (!sim.console.empty()) {
            result = 0x100 | sim.console.front();
            sim.console.erase(sim.console.begin());
          }
          break;
        default: throw std::runtime_error("Unknown simulation command");
      }
      uint8_t reply[4];
      for (unsigned n = 0; n < 4; ++n) reply[n] = (result >> (8 * n)) & 255;
      if (std::fwrite(reply, 1, 4, responses) != 4 || std::fflush(responses)) return 2;
    }
    sim.dut.final();
    std::fclose(responses);
    return 0;
  } catch (const std::exception &error) {
    std::fprintf(stderr, "native simulation: %s\n", error.what());
    return 1;
  }
}
