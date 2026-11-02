// Real-core integration oracle for the FPGA restore image. DDR is an independent
// byte-strobed AXI model; vendor PHY timing is deliberately outside this test.
#include "Vrapt_sample_sim_top.h"
#include "verilated.h"
#include <array>
#include <cstdint>
#include <cstring>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <memory>
#include <sstream>
#include <stdexcept>
#include <string>
#include <unordered_map>
#include <vector>

struct Memory {
  using Chunk = std::array<uint64_t, 8192>;
  std::unordered_map<uint32_t, std::unique_ptr<Chunk>> chunks;
  uint64_t read(uint64_t address) const {
    auto found = chunks.find(uint32_t(address >> 16));
    return found == chunks.end() ? 0 : (*found->second)[(address & 65535) >> 3];
  }
  void write(uint64_t address, uint64_t data, uint8_t mask) {
    auto &chunk = chunks[uint32_t(address >> 16)];
    if (!chunk) chunk = std::make_unique<Chunk>();
    auto &word = (*chunk)[(address & 65535) >> 3];
    for (int b = 0; b < 8; b++) {
      if (mask & (1u << b)) {
        const uint64_t byte_mask = uint64_t(255) << (8 * b);
        word = (word & ~byte_mask) | (data & byte_mask);
      }
    }
  }
  void load(const std::string &directory) {
    std::ifstream meta(directory + "/mem_pmem.bin.meta");
    std::ifstream data(directory + "/mem_pmem.bin", std::ios::binary);
    std::string line;
    while (std::getline(meta, line)) {
      if (line.rfind("chunk_size=", 0) == 0 && std::stoull(line.substr(11), nullptr, 0) != 65536)
        throw std::runtime_error("Expected native 64 KiB RAM chunks");
      if (line.rfind("chunk=", 0) != 0) continue;
      uint64_t address = std::stoull(line.substr(6), nullptr, 0);
      auto chunk = std::make_unique<Chunk>();
      data.read(reinterpret_cast<char *>(chunk->data()), 65536);
      if (data.gcount() != 65536) throw std::runtime_error("Short snapshot RAM input");
      chunks[uint32_t(address >> 16)] = std::move(chunk);
    }
    if (!meta.eof() || !data) throw std::runtime_error("Cannot read snapshot RAM");
  }
};

struct Runner {
  Vrapt_sample_sim_top top;
  Memory memory;
  uint64_t cycles = 0, ra = 0, wa = 0;
  int rleft = 0, wleft = 0, rdelay = 0, bdelay = 0;
  unsigned rsize = 0, wsize = 0, rburst = 0, wburst = 0, rid = 0, wid = 0;
  bool reading = false, writing = false, reply = false;

  void tick() {
    if (++cycles > 2000000000) throw std::runtime_error("Integration cycle limit");
    top.clk = 0;
    top.ddr_awready = !writing && !reply;
    top.ddr_wready = writing;
    top.ddr_bvalid = reply && bdelay == 0;
    top.ddr_bid = wid;
    top.ddr_bresp = 0;
    top.ddr_arready = !reading;
    top.ddr_rvalid = reading && rdelay == 0;
    top.ddr_rid = rid;
    top.ddr_rdata = memory.read(ra);
    top.ddr_rresp = 0;
    top.ddr_rlast = rleft == 0;
    top.eval();
    const bool aw = top.ddr_awvalid && top.ddr_awready;
    const bool w = top.ddr_wvalid && top.ddr_wready;
    const bool b = top.ddr_bvalid && top.ddr_bready;
    const bool ar = top.ddr_arvalid && top.ddr_arready;
    const bool r = top.ddr_rvalid && top.ddr_rready;
    const auto awaddr = top.ddr_awaddr, araddr = top.ddr_araddr;
    const auto wdata = top.ddr_wdata;
    const auto wstrb = top.ddr_wstrb;
    const bool wlast = top.ddr_wlast;
    const auto awlen = top.ddr_awlen, arlen = top.ddr_arlen;
    const auto awsize = top.ddr_awsize, arsize = top.ddr_arsize;
    const auto awburst = top.ddr_awburst, arburst = top.ddr_arburst;
    const auto awid = top.ddr_awid, arid = top.ddr_arid;
    top.clk = 1;
    top.eval();
    if (aw) {
      wa = awaddr; wleft = awlen; wsize = awsize; wburst = awburst; wid = awid;
      writing = true;
    }
    if (ar) {
      ra = araddr; rleft = arlen; rsize = arsize; rburst = arburst; rid = arid;
      reading = true; rdelay = 24;
    }
    if (w) {
      if (wlast != (wleft == 0)) throw std::runtime_error("DDR WLAST mismatch");
      memory.write(wa, wdata, wstrb);
      if (wleft-- == 0) {writing = false; reply = true; bdelay = 29;}
      if (wburst == 1) wa = (wa & ~((uint64_t(1) << wsize) - 1)) + (uint64_t(1) << wsize);
    }
    if (r) {
      if (rleft-- == 0) reading = false;
      if (rburst == 1) ra = (ra & ~((uint64_t(1) << rsize) - 1)) + (uint64_t(1) << rsize);
    }
    if (b) reply = false;
    if (rdelay) --rdelay;
    if (bdelay) --bdelay;
    top.clk = 0;
    top.eval();
    if (top.writeback_error) throw std::runtime_error("CPU writeback error");
  }

  void write(uint64_t address, uint64_t value) {
    top.host_awaddr = address;
    top.host_awvalid = 1;
    do {top.eval(); if (top.host_awready) {tick(); break;} tick();} while (true);
    top.host_awvalid = 0;
    top.host_wdata = value;
    top.host_wvalid = 1;
    do {top.eval(); if (top.host_wready) {tick(); break;} tick();} while (true);
    top.host_wvalid = 0;
    while (!top.host_bvalid) tick();
    if (top.host_bresp != 0) throw std::runtime_error("Host AXI write failed");
    top.host_bready = 1; tick(); top.host_bready = 0;
  }

  uint64_t read(uint64_t address) {
    top.host_araddr = address;
    top.host_arvalid = 1;
    do {top.eval(); if (top.host_arready) {tick(); break;} tick();} while (true);
    top.host_arvalid = 0;
    while (!top.host_rvalid) tick();
    if (top.host_rresp != 0 || !top.host_rlast) throw std::runtime_error("Host AXI read failed");
    const uint64_t result = top.host_rdata;
    top.host_rready = 1; tick(); top.host_rready = 0;
    return result;
  }
};

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  if (argc != 5 && argc != 7) {
    std::cerr << "Usage: model SNAPSHOT RESTORE_IMAGE CONFIG_WORDS RESULT_JSON"
                 " [DDR_PROBE_ADDRESS DDR_PROBE_WORDS]\n";
    return 1;
  }
  try {
    Runner run;
    run.memory.load(argv[1]);
    auto &top = run.top;
    top.reset = 1;
    top.host_awsize = top.host_arsize = 3;
    top.host_awburst = top.host_arburst = 1;
    top.host_wstrb = 255;
    top.host_wlast = 1;
    for (int i = 0; i < 10; i++) run.tick();
    top.reset = 0;
    for (int i = 0; i < 8200; i++) run.tick();
    std::ifstream image(argv[2], std::ios::binary);
    uint64_t word;
    uint64_t address = 0x0f000000;
    while (image.read(reinterpret_cast<char *>(&word), 8)) {
      run.write(address, word); address += 8;
    }
    if (!image.eof()) throw std::runtime_error("Cannot read SRAM image");
    std::ifstream config(argv[3]);
    uint64_t offset, value;
    while (config >> std::hex >> offset >> value) run.write(0x1f000000 + offset, value);
    if (!config.eof()) throw std::runtime_error("Cannot read replay config");
    std::cerr << "Restore started at cycle " << run.cycles << std::endl;
    uint64_t status, polls = 0;
    do {
      for (int i = 0; i < 10000; i++) run.tick();
      status = run.read(0x1f000008);
      if (++polls % 10 == 0) {
        std::cerr << "cycle=" << run.cycles << " status=" << std::hex << status << std::dec
                  << " retired=" << run.read(0x1f000070) << std::endl;
      }
      if (status & 8) {
        throw std::runtime_error("Hardware replay error " +
                                 std::to_string(run.read(0x1f000090)));
      }
    } while (!(status & (1u << 2)));
    const auto error = run.read(0x1f000090);
    if (error) throw std::runtime_error("Hardware replay error " + std::to_string(error));
    std::ofstream output(argv[4]);
    output << "{\"schema\":\"raptor-fpga-core-integration-v1\",\"complete\":true,\"retired\":"
           << run.read(0x1f000070) << ",\"warmup\":" << run.read(0x1f000010)
           << ",\"instructions\":" << run.read(0x1f000018)
           << ",\"start_pc\":\"0x" << std::hex << run.read(0x1f0000c0) << std::dec
           << "\",\"retirement_domain\":{\"mode\":\""
           << (run.read(0x1f0000c8) ? "user" : "all") << "\",\"satp_root\":\"0x"
           << std::hex << run.read(0x1f0000d0) << std::dec
           << "\",\"include_kernel_cycles\":true";
    if (run.read(0x1f0000d8))
      output << ",\"thread_pointer\":\"0x" << std::hex << run.read(0x1f0000e0)
             << std::dec << "\"";
    output << "},\"boundaries\":[";
    const uint64_t rows = run.read(0x1f000078);
    for (uint64_t i = 0; i < rows; i++) {
      if (i) output << ',';
      output << "{\"instructions\":" << run.read(0x1f001000 + i * 32)
             << ",\"cycle\":" << run.read(0x1f001008 + i * 32)
             << ",\"last_pc\":\"0x" << std::hex << run.read(0x1f001010 + i * 32)
             << "\",\"signature\":\"" << run.read(0x1f001018 + i * 32) << "\"}" << std::dec;
    }
    output << "],\"gpr\":[";
    for (unsigned r = 0; r < 32; r++) {
      run.write(0x1f000080, r);
      if (r) output << ',';
      output << "\"0x" << std::hex << run.read(0x1f000080) << "\"" << std::dec;
    }
    output << "]";
    if (argc == 7) {
      const uint64_t probe_address = std::stoull(argv[5], nullptr, 0);
      const uint64_t probe_words = std::stoull(argv[6], nullptr, 0);
      if ((probe_address & 7) || probe_address < 0x80000000 ||
          probe_address >= 0x100000000 || !probe_words || probe_words > 1024 ||
          probe_address + probe_words * 8 > 0x100000000)
        throw std::runtime_error("Invalid DDR memory probe");
      output << ",\"memory_probe\":{\"address\":\"0x" << std::hex << probe_address
             << "\",\"words\":[";
      // Observe the independent DDR oracle before reset. Skipping cache
      // writeback to escape a stuck drain must fail this memory comparison.
      for (uint64_t i = 0; i < probe_words; i++) {
        if (i) output << ',';
        output << "\"0x" << run.memory.read(probe_address - 0x80000000 + i * 8) << "\"";
      }
      output << "]}" << std::dec;
    }
    output << "}\n";
    std::cerr << "PASS: real-core SRAM replay, retired=" << run.read(0x1f000070) << std::endl;
  } catch (const std::exception &error) {
    std::cerr << error.what() << std::endl;
    return 1;
  }
}
