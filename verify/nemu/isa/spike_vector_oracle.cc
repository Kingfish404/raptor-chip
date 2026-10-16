#include <array>
#include <cstring>
#include <iostream>
#include <memory>
#include "processor.h"
#include "mmu.h"
#include "simif.h"

class vector_sim_t : public simif_t
{
public:
  cfg_t config;
  std::array<char, 4096> memory{};
  std::array<uint8_t, 4096> data{};
  std::map<size_t, processor_t *> harts;
  std::unique_ptr<processor_t> processor;

  explicit vector_sim_t(unsigned xlen)
  {
    config.pmpregions = 0;
    config.hartids = {0};
    processor = std::make_unique<processor_t>(
        xlen == 64 ? "rv64gcv_zicclsm_zvbb_zvfhmin" : "rv32gcv_zicclsm_zvbb_zvfhmin",
        "MSU", &config, this, 0, false, nullptr, std::cerr);
    harts[0] = processor.get();
  }

  char *addr_to_mem(reg_t address) override
  {
    if (address >= 0x81000000 && address < 0x81001000)
      return reinterpret_cast<char *>(data.data() + address - 0x81000000);
    return address >= 0x80000000 && address < 0x80001000
        ? memory.data() + address - 0x80000000 : nullptr;
  }
  bool mmio_load(reg_t, size_t, uint8_t *) override { return false; }
  bool mmio_store(reg_t, size_t, const uint8_t *) override { return false; }
  void proc_reset(unsigned) override {}
  const cfg_t &get_cfg() const override { return config; }
  const std::map<size_t, processor_t *> &get_harts() const override { return harts; }
  const char *get_symbol(uint64_t) override { return nullptr; }
};

struct vector_result_t
{
  uint8_t registers[512];
  uint64_t scalar;
  uint64_t floating;
  uint64_t flags;
  uint64_t saturated;
  uint64_t vl;
  uint64_t vstart;
  uint64_t trapped;
  uint64_t cause;
  uint8_t memory[4096];
};

static std::unique_ptr<vector_sim_t> simulator;

extern "C" void vector_oracle_init(unsigned xlen)
{
  simulator = std::make_unique<vector_sim_t>(xlen);
}

extern "C" void vector_oracle(uint32_t instruction, uint32_t vtype, uint32_t vl,
                              uint32_t vxrm, uint32_t frm, uint64_t scalar,
                              uint64_t floating, const uint8_t *registers,
                              vector_result_t *result)
{
  auto &processor = *simulator->processor;
  auto &state = *processor.get_state();
  state.pc = 0x80000000;
  state.mstatus->write(0x6600);
  state.mtvec->write(0x80000800);
  state.mcause->write(0);
  state.fflags->write(0);
  state.frm->write(frm);
  state.vxsat->write(0);
  processor.VU.vxrm->write(vxrm);
  processor.VU.set_vl(1, 1, vl, vtype);
  processor.VU.vstart->write(0);
  std::memcpy(processor.VU.reg_file, registers, 512);
  state.XPR.write(16, processor.get_xlen() == 32 ? reg_t(int32_t(scalar)) : scalar);
  state.XPR.write(24, 0x1234);
  state.FPR.write(16, freg_t{floating, UINT64_MAX});
  state.FPR.write(24, freg_t{0x1234, UINT64_MAX});
  std::memcpy(simulator->memory.data(), &instruction, sizeof(instruction));
  processor.get_mmu()->flush_icache();
  processor.step(1);
  std::memcpy(result->registers, processor.VU.reg_file, 512);
  result->scalar = state.XPR[24];
  result->floating = state.FPR[24].v[0];
  result->flags = state.fflags->read();
  result->saturated = state.vxsat->read();
  result->vl = processor.VU.vl->read();
  result->vstart = processor.VU.vstart->read();
  result->trapped = (state.pc & (processor.get_xlen() == 32 ? UINT32_MAX : UINT64_MAX))
      != 0x80000004;
  result->cause = state.mcause->read();
  std::memcpy(result->memory, simulator->data.data(), simulator->data.size());
}

extern "C" void vector_memory_oracle(uint32_t instruction, uint32_t vtype,
                                     uint32_t vl, uint64_t base, uint64_t stride,
                                     const uint8_t *registers, const uint8_t *memory,
                                     vector_result_t *result)
{
  std::memcpy(simulator->data.data(), memory, simulator->data.size());
  simulator->processor->get_state()->XPR.write(17,
      simulator->processor->get_xlen() == 32 ? reg_t(int32_t(stride)) : stride);
  vector_oracle(instruction, vtype, vl, 0, 0, base, 0, registers, result);
}
