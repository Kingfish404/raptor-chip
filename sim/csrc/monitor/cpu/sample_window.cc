#include <sample_window.h>
#include <common.h>
#include <vector>

namespace {
struct Boundary {
  uint64_t instructions, cycle, pc, signature;
};
FILE *output;
uint64_t warmup_length, window_length, base_count, base_cycle, target_pc;
uint64_t signature = UINT64_C(14695981039346656037), next_pc;
uint64_t measurement_pc;
bool wait_checkpoint, has_target_pc, armed, complete, activated;
bool user_only;
uint64_t user_satp;
bool thread_only;
uint64_t user_thread_pointer;
std::vector<Boundary> boundaries;
constexpr uint64_t Band = 64;

void observe(uint64_t cycle, uint64_t count)
{
  if (boundaries.empty() || boundaries.back().instructions != count)
    boundaries.push_back({count, cycle - base_cycle, next_pc, signature});
}
}

void sample_window_set_user_satp(uint64_t root)
{
  user_only = true;
  user_satp = root;
}

void sample_window_set_user_thread(uint64_t pointer)
{
  thread_only = true;
  user_thread_pointer = pointer;
}

bool sample_window_accept(unsigned privilege, uint64_t satp, uint64_t thread_pointer)
{
#ifdef CONFIG_ISA64
  constexpr uint64_t mask = UINT64_C(0xf0000fffffffffff);
#else
  constexpr uint64_t mask = UINT64_C(0x803fffff);
#endif
  return !user_only || (privilege == 0 && (satp & mask) == user_satp &&
                       (!thread_only || thread_pointer == user_thread_pointer));
}

void sample_window_configure(const char *path, uint64_t warmup, uint64_t instructions,
                             bool has_start_pc, uint64_t start_pc, bool checkpoint)
{
  if (!path) return;
  if (thread_only && !user_only) {
    fprintf(stderr, "A sample user thread requires --sample-user-satp\n");
    exit(1);
  }
  if (!instructions || instructions > UINT64_MAX - Band ||
      warmup > UINT64_MAX - instructions - Band) {
    fprintf(stderr, "Invalid sample window lengths\n");
    exit(1);
  }
  output = fopen(path, "wx");
  if (!output) {
    perror("sample output");
    exit(1);
  }
  warmup_length = warmup;
  window_length = instructions;
  has_target_pc = has_start_pc;
  target_pc = start_pc;
  wait_checkpoint = checkpoint;
}

void sample_window_commit(uint64_t pc, uint32_t instruction, uint64_t cycle,
                          uint64_t previous_instructions, bool resumed)
{
  if (!output || !activated) return;
  if (!armed) {
    if (wait_checkpoint) {
      if (!resumed) return;
      wait_checkpoint = false;
    }
    if (has_target_pc && pc != target_pc) return;
    armed = true;
    base_count = previous_instructions;
    base_cycle = cycle - 1;
    next_pc = pc;
    if (!warmup_length) observe(base_cycle, 0);
  }
  // Include the complete PC/instruction stream up to each observed boundary.
  // A/B comparison rejects equal lengths with divergent control flow.
  if (previous_instructions - base_count == warmup_length) measurement_pc = pc;
  signature = (signature ^ pc) * UINT64_C(1099511628211);
  signature = (signature ^ instruction) * UINT64_C(1099511628211);
  next_pc = pc;
}

bool sample_window_cycle(uint64_t cycle, uint64_t instructions)
{
  if (!output || !activated || !armed) return false;
  uint64_t count = instructions - base_count;
  uint64_t end = warmup_length + window_length;
  if ((count >= warmup_length && count <= warmup_length + Band) ||
      (count >= end && count <= end + Band))
    observe(cycle, count);
  // Stop only after all candidate end boundaries have been differentially
  // checked. No drain or extra checkpoint is needed for a performance sample.
  complete = count > end + Band;
  return complete;
}

bool sample_window_finish(bool execution_ok)
{
  if (!output || !activated) return true;
  bool passed = armed && complete && execution_ok;
  fprintf(output, "{\"schema\":\"raptor-window-v1\",\"complete\":%s,"
          "\"warmup\":%" PRIu64 ",\"instructions\":%" PRIu64
          ",\"start_pc\":\"0x%" PRIx64 "\",\"boundary_band\":%" PRIu64 ",\"boundaries\":[",
          passed ? "true" : "false", warmup_length, window_length, measurement_pc, Band);
  bool separator = false;
  for (const auto &boundary : boundaries) {
    fprintf(output, "%s{\"instructions\":%" PRIu64 ",\"cycle\":%" PRIu64
            ",\"last_pc\":\"0x%" PRIx64 "\",\"signature\":\"%016" PRIx64 "\"}",
            separator ? "," : "", boundary.instructions, boundary.cycle,
            boundary.pc, boundary.signature);
    separator = true;
  }
  fprintf(output, "],\"retirement_domain\":{\"mode\":\"%s\",\"satp_root\":\"0x%" PRIx64
          "\",\"include_kernel_cycles\":true", user_only ? "user" : "all", user_satp);
  if (thread_only)
    fprintf(output, ",\"thread_pointer\":\"0x%" PRIx64 "\"", user_thread_pointer);
  fputs("}}\n", output);
  bool written = !ferror(output);
  if (fclose(output)) written = false;
  output = nullptr;
  return passed && written;
}

void sample_window_activate(void)
{
  activated = true;
}
