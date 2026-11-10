#include "Vram_opt_miter.h"
#include "verilated.h"
#include <array>
#include <cstdint>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

#ifndef RAM_PROOF_BOOT_ROM
#error "Set RAM_PROOF_BOOT_ROM explicitly to match the exported peripheral"
#endif

struct Sample {
  bool arready, awready, wready, rvalid, rlast, bvalid;
  unsigned rresp, bresp, rid, bid;
  uint32_t data;
  uint64_t cycle;
};

class Check {
 public:
  VerilatedContext context;
  Vram_opt_miter dut{&context};
  std::array<uint8_t, 8192> memory;
  uint64_t cycles = 0, reads = 0, writes = 0, beats = 0, resets = 0, rom_beats = 0;
  uint32_t random;
  bool checking = false;
  static constexpr uint32_t Base = 0x0f000000;

  explicit Check(uint32_t seed) : random(seed ? seed : 1) {
#include "initial_inputs.inc"
    for (unsigned i = 0; i < memory.size(); ++i)
      memory[i] = ((i * 73) ^ (i >> 4) ^ 0x5a) & 255;
    reset();
    checking = true;
  }
  void require(bool condition, const std::string& message) {
    if (!condition) throw std::runtime_error(message + " at cycle " + std::to_string(cycles));
  }
  uint32_t next() {
    random ^= random << 13; random ^= random >> 17; random ^= random << 5;
    return random;
  }
  void equal() {
    if (checking && dut.mismatch) {
      std::cerr << "rvalid=" << unsigned(dut.o_axi_rvalid)
                << " rdata=" << std::hex << dut.o_axi_rdata << std::dec << '\n';
      require(false, "original/scoped candidate output mismatch (also invalid cycles)");
    }
  }
  Sample step() {
    dut.i_clock = 0; dut.eval(); equal();
    Sample s{bool(dut.o_axi_arready), bool(dut.o_axi_awready), bool(dut.o_axi_wready),
             bool(dut.o_axi_rvalid), bool(dut.o_axi_rlast), bool(dut.o_axi_bvalid),
             unsigned(dut.o_axi_rresp), unsigned(dut.o_axi_bresp),
             unsigned(dut.o_axi_rid), unsigned(dut.o_axi_bid), dut.o_axi_rdata, cycles};
    context.timeInc(5); dut.i_clock = 1; dut.eval(); equal();
    context.timeInc(5); ++cycles;
    require(cycles < 2000000, "global local-test cycle limit");
    return s;
  }
  void idle(unsigned count) {while (count--) step();}
  void reset() {
    dut.i_axi_arvalid = 0; dut.i_axi_awvalid = 0; dut.i_axi_wvalid = 0;
    dut.i_axi_rready = 0; dut.i_axi_bready = 0;
    dut.i_reset = 1; idle(8); dut.i_reset = 0; idle(8); ++resets;
  }
  static unsigned region(uint32_t address) {
    if ((address >= 0x30000000 && address < 0x30800000)
        || (address >= 0x20000000 && address < 0x20010000)) return 1;
    if (address >= Base && address < Base + 8192) return 2;
    if (address >= 0x00100800 && address < 0x0010083c) return 3;
    return 0;
  }
  static unsigned response(uint32_t address, unsigned size, unsigned length,
                           unsigned burst, bool writing) {
    unsigned area = region(address);
    if (!area) return 3;
    if (size > 2 || burst > 1) return 2;
    uint64_t span = uint64_t(1) << size;
    if (burst == 1) span *= length + 1;
    uint64_t last = uint64_t(address & ~((1u << size) - 1)) + span - 1;
    if (last > 0xffffffffu || (last >> 12) != (address >> 12)
        || region(uint32_t(last)) != area) return 2;
    if ((writing || area == 3) && (address & ((1u << size) - 1))) return 2;
    if (area == 3 && (size != 2 || length != 0)) return 2;
    if (writing && area == 1) return 2;
    return 0;
  }
  static uint32_t following(uint32_t address, unsigned size) {
    return (address | ((1u << size) - 1)) + 1;
  }
  static unsigned lanes(uint32_t address, unsigned size) {
    if (size > 2) return 15;
    unsigned count = (1u << size) - ((address & 3) & ((1u << size) - 1));
    unsigned mask = 0;
    for (unsigned lane = 0; lane < 4; ++lane)
      if (lane >= (address & 3) && lane < (address & 3) + count) mask |= 1u << lane;
    return mask;
  }
  static bool is_rom(uint32_t address) {
    return RAM_PROOF_BOOT_ROM && address >= 0x20000000 && address < 0x20010000;
  }
  static uint32_t expected_rom_data(uint32_t address, unsigned size) {
    uint32_t value = 0;
    for (unsigned lane = 0; lane < 4; ++lane) {
      if (!(lanes(address, size) & (1u << lane))) continue;
      uint32_t offset = ((address & 0xffffu) & ~3u) + lane;
      uint32_t instruction = offset / 4 == 0 ? 0x300002b7u
                             : offset / 4 == 1 ? 0x00028067u : 0x00000013u;
      value |= ((instruction >> (8 * (offset & 3))) & 255u) << (8 * lane);
    }
    return value;
  }
  uint32_t expected_data(uint32_t address, unsigned size) {
    uint32_t value = 0;
    for (unsigned lane = 0; lane < 4; ++lane)
      if (lanes(address, size) & (1u << lane))
        value |= uint32_t(memory[((address - Base) & ~3u) + lane]) << (lane * 8);
    return value;
  }
  void read(uint32_t address, unsigned size = 2, unsigned length = 0, unsigned burst = 1) {
    unsigned id = next() & 15;
    unsigned expected = response(address, size, length, burst, false);
    dut.i_axi_araddr = address; dut.i_axi_arsize = size; dut.i_axi_arlen = length;
    dut.i_axi_arburst = burst; dut.i_axi_arid = id; dut.i_axi_arvalid = 1;
    dut.i_axi_rready = 0;
    uint64_t ar_edge = 0;
    for (unsigned wait = 0;; ++wait) {
      require(wait < 10000, "AR handshake timeout");
      if (step().arready) {ar_edge = cycles; break;}
    }
    dut.i_axi_arvalid = 0;
    unsigned received = 0;
    bool first = true, stalled = false;
    uint32_t held = 0;
    for (unsigned wait = 0; received <= length; ++wait) {
      require(wait < 30000, "R response timeout");
      dut.i_axi_rready = (next() & 3) != 0;
      Sample s = step();
      if (!s.rvalid) {require(!stalled, "RVALID dropped under backpressure"); continue;}
      if (first) {
        if (region(address) == 2 && expected == 0)
          require(s.cycle == ar_edge + 1, "RAM AR-to-first-RVALID latency changed");
        first = false;
      }
      if (stalled) require(s.data == held, "RDATA changed while stalled");
      held = s.data; stalled = !dut.i_axi_rready;
      require(s.rid == id && s.rlast == (received == length), "R ID/last mismatch");
      if (region(address) != 1 || is_rom(address))
        require(s.rresp == expected, "R response code mismatch");
      if (region(address) == 2 && expected == 0)
        require(s.data == expected_data(address, size), "RAM content/lane/invalid-byte mismatch");
      else if (is_rom(address) && expected == 0)
        require(s.data == expected_rom_data(address, size), "ROM lane/word data mismatch");
      else if (expected != 0) require(s.data == 0, "error read returned nonzero data");
      if (dut.i_axi_rready) {
        if (is_rom(address) && expected == 0) ++rom_beats;
        ++received; ++beats;
        if (burst == 1) address = following(address, size);
      }
    }
    dut.i_axi_rready = 0; idle(next() & 3); ++reads;
  }
  void write(uint32_t address, unsigned size, const std::vector<uint32_t>& data,
             const std::vector<unsigned>& strobes, unsigned burst = 1, bool bad_last = false) {
    require(data.size() == strobes.size() && !data.empty(), "bad host write fixture");
    unsigned length = data.size() - 1, id = next() & 15;
    unsigned expected = response(address, size, length, burst, true);
    dut.i_axi_awaddr = address; dut.i_axi_awsize = size; dut.i_axi_awlen = length;
    dut.i_axi_awburst = burst; dut.i_axi_awid = id; dut.i_axi_awvalid = 1;
    dut.i_axi_bready = 0;
    for (unsigned wait = 0;; ++wait) {
      require(wait < 10000, "AW handshake timeout");
      if (step().awready) break;
    }
    dut.i_axi_awvalid = 0;
    for (unsigned beat = 0; beat <= length; ++beat) {
      idle(next() & 3);
      bool last = (beat == length) != (bad_last && beat == length);
      dut.i_axi_wdata = data[beat]; dut.i_axi_wstrb = strobes[beat];
      dut.i_axi_wlast = last; dut.i_axi_wvalid = 1;
      for (unsigned wait = 0;; ++wait) {
        require(wait < 10000, "W handshake timeout");
        if (step().wready) break;
      }
      dut.i_axi_wvalid = 0;
      bool accepted = last == (beat == length) && (strobes[beat] & ~lanes(address, size)) == 0;
      if (expected == 0 && accepted && region(address) == 2) {
        for (unsigned lane = 0; lane < 4; ++lane)
          if (strobes[beat] & (1u << lane))
            memory[((address - Base) & ~3u) + lane] = data[beat] >> (8 * lane);
      }
      if (!accepted) expected = 2;
      if (burst == 1) address = following(address, size);
    }
    idle(next() & 7);
    for (unsigned wait = 0;; ++wait) {
      require(wait < 10000, "B response timeout");
      dut.i_axi_bready = (next() & 3) != 0;
      Sample s = step();
      if (s.bvalid) {
        require(s.bid == id && s.bresp == expected, "B ID/response mismatch");
        if (dut.i_axi_bready) break;
      }
    }
    dut.i_axi_bready = 0; idle(next() & 3); ++writes;
  }
};

int main(int argc, char** argv) {
  try {
    uint32_t seed = argc > 1 ? std::stoul(argv[1]) : 1;
    Check c(seed);
    for (unsigned i = 0; i < 32; ++i) c.read(Check::Base + ((c.next() & 2047) * 4));
    for (unsigned row = 0; row < 2048; ++row)
      c.write(Check::Base + row * 4, 2, {c.next()}, {15});
    for (unsigned row = 0; row < 2048; ++row) c.read(Check::Base + row * 4);
    for (unsigned byte = 0; byte < 8192; ++byte) c.read(Check::Base + byte, 0);
    for (unsigned mask = 0; mask < 16; ++mask)
      for (unsigned i = 0; i < 16; ++i) {
        uint32_t address = Check::Base + ((c.next() & 2047) * 4);
        c.write(address, 2, {c.next()}, {mask}); c.read(address);
      }
    for (unsigned i = 0; i < 128; ++i) {
      uint32_t address = Check::Base + ((c.next() & 1023) * 4);
      unsigned lane = c.next() & 3;
      c.write(address + lane, 0, {c.next()}, {1u << lane}); c.read(address);
      c.read(address + lane, 2);  // legal unaligned first read, zero invalid lanes
      c.read(address, 2, 3, i & 1);
    }
    for (unsigned lane = 0; lane < 4; ++lane) {
      c.write(Check::Base + 100 + lane, 0, {0xffffffff}, {15}); // invalid WSTRB, no mutation
      c.read(Check::Base + 100);
    }
    c.write(Check::Base + 256, 2, {0x13579bdf, 0x2468ace0}, {15, 15}, 1, true);
    c.read(Check::Base + 256, 2, 1);  // first beat committed; no late-error rollback
    c.write(Check::Base + 4092, 2, {0x11111111, 0x22222222}, {15, 15});
    c.read(Check::Base + 4092); c.read(Check::Base + 4096); // boundary reject changed neither
    c.write(Check::Base + 1, 2, {0xffffffff}, {15}); c.read(Check::Base);
    c.read(Check::Base + 4095, 2, 1); c.read(Check::Base + 8191, 0);
    c.read(Check::Base, 3); c.read(Check::Base, 2, 0, 2); c.read(0x40000000);
    c.read(0x00100800); c.read(0x00100804); c.read(0x00100800, 0);
    c.write(0x00100804, 2, {0x0608}, {15}); c.read(0x00100804);
    c.write(0x30000000, 2, {0x11223344}, {15});
    if (RAM_PROOF_BOOT_ROM) {
      c.read(0x20000000, 2, 3); // LUI/JALR/NOP with randomized response stalls
      c.read(0x20000001, 2, 3); // unaligned first beat, then aligned INCR
      for (unsigned byte = 0; byte < 12; ++byte) c.read(0x20000000 + byte, 0);
      c.read(0x20000001, 1, 2);
      c.read(0x20000ffc, 2, 1); // reject the whole cross-page burst
      c.read(0x2000fffc); // final word of reset window is NOP
      c.write(0x20000000, 2, {0xffffffff}, {15}); // read-only SLVERR
      c.read(0x20000000, 2, 1);
      c.read(Check::Base + 256, 2, 1); // ROM and RAM share the original response FF
      c.require(c.rom_beats >= 26, "ROM oracle traffic was not exercised");
    } else {
      c.read(0x20000000); // legacy serial alias, no target response
    }
    c.read(0x30000000); // real XIP serial error path remains compared
    c.reset();
    if (RAM_PROOF_BOOT_ROM) c.read(0x20000000, 2, 1);
    for (unsigned row = 0; row < 2048; ++row) c.read(Check::Base + row * 4);
    // Reset an outstanding stalled read and an accepted AW; RAM must survive.
    c.dut.i_axi_araddr = Check::Base + 256; c.dut.i_axi_arsize = 2;
    c.dut.i_axi_arlen = 0; c.dut.i_axi_arburst = 1; c.dut.i_axi_arvalid = 1;
    while (!c.step().arready) {}
    c.dut.i_axi_arvalid = 0; c.dut.i_axi_rready = 0; c.idle(8); c.reset();
    c.read(Check::Base + 256);
    c.dut.i_axi_awaddr = Check::Base + 512; c.dut.i_axi_awsize = 2;
    c.dut.i_axi_awlen = 0; c.dut.i_axi_awburst = 1; c.dut.i_axi_awvalid = 1;
    while (!c.step().awready) {}
    c.dut.i_axi_awvalid = 0; c.reset(); c.read(Check::Base + 512);
    std::cout << "{\"pass\":true,\"seed\":" << seed << ",\"cycles\":" << c.cycles
              << ",\"reads\":" << c.reads << ",\"writes\":" << c.writes
              << ",\"read_beats\":" << c.beats << ",\"resets\":" << c.resets
              << ",\"boot_rom\":" << RAM_PROOF_BOOT_ROM << ",\"rom_beats\":" << c.rom_beats
              << ",\"all_outputs_compared_in_invalid_cycles\":true,"
              << "\"production_ram_reset_or_init_added\":false}\n";
    return 0;
  } catch (const std::exception& error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
