// Binary stdin/stdout adapter: every byte travels through the RTL UART pins.
#include "Vrapt_bringup_sim.h"
#include "verilated.h"
#include "verilated_vcd_c.h"
#include <array>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <memory>
#include <stdexcept>
#include <vector>

class Simulation {
 public:
  VerilatedContext context;
  Vrapt_bringup_sim dut{&context};
  std::vector<uint8_t> received;
  int sample_timer = 0;
  int sample_bit = -1;
  uint8_t sample_data = 0;
  std::unique_ptr<VerilatedVcdC> trace;
  Simulation() {
    if (const char *path = std::getenv("BRINGUP_WAVE")) {
      context.traceEverOn(true);
      trace = std::make_unique<VerilatedVcdC>();
      dut.trace(trace.get(), 2);
      trace->open(path);
    }
  }
  ~Simulation() { if (trace) trace->close(); }
  void tick() {
    dut.clock_i = 0;
    dut.eval();
    if (trace) trace->dump(context.time());
    context.timeInc(5000);
    dut.clock_i = 1;
    dut.eval();
    if (trace) trace->dump(context.time());
    context.timeInc(5000);
    if (sample_bit < 0) {
      if (!dut.host_tx_o) {
        sample_timer = 11;
        sample_bit = 0;
        sample_data = 0;
      }
    } else if (sample_timer-- == 0) {
      if (sample_bit < 8) {
        sample_data |= uint8_t(dut.host_tx_o) << sample_bit++;
        sample_timer = 7;
      } else {
        if (!dut.host_tx_o) throw std::runtime_error("UART stop bit");
        received.push_back(sample_data);
        sample_bit = -1;
      }
    }
  }
  void ticks(uint64_t count) { while (count--) tick(); }
  void send(uint8_t byte) {
    dut.host_rx_i = 0;
    ticks(8);
    for (int bit = 0; bit < 8; bit++) {
      dut.host_rx_i = (byte >> bit) & 1;
      ticks(8);
    }
    dut.host_rx_i = 1;
    ticks(12);
  }
};

int main(int argc, char **argv) {
  try {
    Simulation sim;
    sim.context.commandArgs(argc, argv);
    sim.dut.reset_i = 1;
    sim.dut.host_rx_i = 1;
    sim.ticks(32);
    sim.dut.reset_i = 0;
    sim.ticks(32);
    std::array<uint8_t, 16> packet;
    while (std::fread(packet.data(), 1, packet.size(), stdin) == packet.size()) {
      sim.received.clear();
      for (auto byte : packet) sim.send(byte);
      uint64_t budget = 2000000;
      if (packet[1] == 3) {
        uint32_t wait = 0;
        for (int i = 0; i < 4; i++) wait |= uint32_t(packet[8+i]) << (8*i);
        budget += wait;
      }
      while (sim.received.size() < 16 && budget--) sim.tick();
      if (sim.received.size() != 16) throw std::runtime_error("RTL host timeout");
      std::fwrite(sim.received.data(), 1, 16, stdout);
      std::fflush(stdout);
      sim.ticks(64);
    }
    sim.dut.final();
    return 0;
  } catch (const std::exception &error) {
    std::fprintf(stderr, "bringup simulation: %s\n", error.what());
    return 1;
  }
}
