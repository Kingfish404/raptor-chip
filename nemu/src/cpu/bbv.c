#include <cpu/bbv.h>
#include <cpu/sample.h>
#include <cpu/thread.h>
#include <isa.h>

#ifndef CONFIG_TARGET_AM
#include <errno.h>

typedef struct {
  word_t pc, satp;
  uint64_t count;
  unsigned privilege;
  bool used;
} Block;

bool nemu_bbv_enabled;
static FILE *output;
static Block *blocks;
static size_t capacity, occupied;
static uint64_t interval_size, retired, guest_retired, first_guest, interval_start;
static uint64_t traps, privileges[4];
static uint64_t first_signature, last_signature;
enum { PC_BAND_SIZE = 64 };
static uint64_t pc_signature, first_pc_signature, pc_band_signature[PC_BAND_SIZE];
static word_t pc_band_pc[PC_BAND_SIZE];
static word_t start_pc, stop_pc, first_pc, next_pc, last_pc;
static word_t block_pc, block_satp, expected_pc;
static unsigned block_privilege;
static bool has_start_pc, has_stop_pc, active, finished, have_block;
static char serial_line[256];
static size_t serial_length;
static bool serial_overflow;
static const char *start_marker;
static uint64_t roi_limit;
static bool activate_after_serial;
static bool user_only, thread_only;
static word_t user_satp_root, user_thread_pointer;
static bool have_next_anchor;
static word_t anchor_pc;
static uint64_t anchor_guest, anchor_signature;

static word_t satp_root(word_t satp)
{
#ifdef CONFIG_ISA64
  return satp & UINT64_C(0xf0000fffffffffff);
#else
  return satp & UINT32_C(0x803fffff);
#endif
}

void nemu_bbv_set_user_scope(word_t selected_root, bool has_thread, word_t pointer)
{
  Assert(selected_root == satp_root(selected_root), "User scope must omit SATP ASID bits");
  user_only = true;
  user_satp_root = selected_root;
  thread_only = has_thread;
  user_thread_pointer = pointer;
}

static uint64_t hash_block(word_t pc, word_t satp, unsigned privilege)
{
  uint64_t value = (uint64_t)pc ^ ((uint64_t)satp * UINT64_C(0x9e3779b97f4a7c15));
  value ^= (uint64_t)privilege << 57;
  value ^= value >> 30;
  value *= UINT64_C(0xbf58476d1ce4e5b9);
  value ^= value >> 27;
  return value;
}

static void insert(Block entry)
{
  size_t index = hash_block(entry.pc, entry.satp, entry.privilege) & (capacity - 1);
  while (blocks[index].used) {
    Block *block = &blocks[index];
    if (block->pc == entry.pc && block->satp == entry.satp &&
        block->privilege == entry.privilege) {
      block->count += entry.count;
      return;
    }
    index = (index + 1) & (capacity - 1);
  }
  blocks[index] = entry;
  occupied++;
}

static void grow(void)
{
  size_t old_capacity = capacity;
  Block *old = blocks;
  capacity = capacity ? capacity * 2 : 1024;
  blocks = calloc(capacity, sizeof(*blocks));
  Assert(blocks, "BBV allocation failed");
  occupied = 0;
  for (size_t i = 0; i < old_capacity; i++)
    if (old[i].used) insert(old[i]);
  free(old);
}

static void flush_interval(void)
{
  uint64_t instructions = retired - interval_start;
  if (!instructions) return;
  fprintf(output, "{\"schema\":\"raptor-bbv-v1\",\"start\":%" PRIu64
          ",\"instructions\":%" PRIu64 ",\"guest_start\":%" PRIu64
          ",\"start_pc\":\"0x%" PRIx64 "\",\"next_pc\":\"0x%" PRIx64
          "\",\"start_signature\":\"%016" PRIx64 "\",\"end_signature\":\"%016" PRIx64
          "\",\"trapped_attempts\":%" PRIu64 ",\"privileges\":[%" PRIu64
          ",%" PRIu64 ",%" PRIu64 ",%" PRIu64 "],\"blocks\":{",
          interval_start, instructions, first_guest, (uint64_t)first_pc,
          (uint64_t)next_pc, first_signature, last_signature,
          traps, privileges[0], privileges[1], privileges[2], privileges[3]);
  bool separator = false;
  for (size_t i = 0; i < capacity; i++) {
    const Block *block = &blocks[i];
    if (!block->used) continue;
    fprintf(output, "%s\"%u:%" PRIx64 ":%" PRIx64 "\":%" PRIu64,
            separator ? "," : "", block->privilege, (uint64_t)block->satp,
            (uint64_t)block->pc, block->count);
    separator = true;
  }
  fprintf(output, "},\"pc_digest_algorithm\":\"rotate-xor-pc-v1\","
          "\"pc_digest_start\":\"%016" PRIx64 "\",\"pc_digest_end\":\"%016" PRIx64
          "\",\"last_pc\":\"0x%" PRIx64 "\",\"pc_band\":[",
          first_pc_signature, pc_signature, (uint64_t)last_pc);
  uint64_t band = instructions < PC_BAND_SIZE ? instructions : PC_BAND_SIZE;
  for (uint64_t i = 0; i < band; i++)
    fprintf(output, "%s[\"0x%" PRIx64 "\",\"%016" PRIx64 "\"]",
            i ? "," : "", (uint64_t)pc_band_pc[i], pc_band_signature[i]);
  fputs("]}\n", output);
  bool written = !ferror(output);
  int flushed = fflush(output);
  Assert(written && flushed == 0, "BBV write failed");
  memset(blocks, 0, capacity * sizeof(*blocks));
  memset(privileges, 0, sizeof(privileges));
  occupied = 0;
  traps = 0;
  interval_start = retired;
  if (user_only) {
    // Pin the architectural boundary before a possible interrupt/switch.
    // The next selected thread instruction can execute much later.
    have_next_anchor = true;
    anchor_pc = cpu.pc;
    anchor_guest = guest_retired;
    anchor_signature = nemu_sample_signature;
  }
}

static void close_profile(void)
{
  if (!output) return;
  flush_interval();
  bool complete = finished || (nemu_state.state == NEMU_END && nemu_state.halt_ret == 0);
  fprintf(output, "{\"schema\":\"raptor-bbv-end-v1\",\"retired\":%" PRIu64
          ",\"guest_retired\":%" PRIu64 ",\"complete\":%s,\"program_complete\":%s,"
          "\"roi_limit\":%" PRIu64 ",\"execution_state\":%d", retired, guest_retired,
          complete ? "true" : "false",
          nemu_state.state == NEMU_END && nemu_state.halt_ret == 0 ? "true" : "false",
          roi_limit, nemu_state.state);
  if (user_only) {
    fprintf(output, ",\"retirement_domain\":{\"mode\":\"user\",\"satp_root\":\"0x%" PRIx64
            "\",\"include_kernel_cycles\":true", (uint64_t)user_satp_root);
    if (thread_only)
      fprintf(output, ",\"thread_pointer\":\"0x%" PRIx64 "\"", (uint64_t)user_thread_pointer);
    fputc('}', output);
  }
  fputs("}\n", output);
  int closed = fclose(output);
  Assert(closed == 0, "BBV close failed");
  output = NULL;
  free(blocks);
}

void nemu_bbv_configure(const char *path, uint64_t interval,
                        bool has_start, word_t start, bool has_stop, word_t stop,
                        const char *marker, uint64_t length)
{
  if (!path) return;
  Assert(!nemu_threaded && nemu_nr_harts == 1, "BBV requires single-hart rr execution");
  Assert(interval != 0, "BBV interval must be positive");
  Assert(!(has_start && marker), "BBV start PC and start marker are mutually exclusive");
  output = fopen(path, "wx");
  Assert(output, "Cannot create BBV '%s': %s", path, strerror(errno));
  interval_size = interval;
  has_start_pc = has_start;
  has_stop_pc = has_stop;
  start_pc = start;
  stop_pc = stop;
  start_marker = marker;
  roi_limit = length;
  active = !has_start && !marker;
  grow();
  int registered = atexit(close_profile);
  Assert(registered == 0, "Cannot register BBV cleanup");
  nemu_bbv_enabled = true;
}

static bool terminates_block(uint32_t inst)
{
  if ((inst & 3) == 3) {
    unsigned opcode = inst & 0x7f;
    return opcode == 0x63 || opcode == 0x67 || opcode == 0x6f || opcode == 0x73;
  }
  unsigned quadrant = inst & 3, funct3 = (inst >> 13) & 7;
  if (quadrant == 1) {
#ifndef CONFIG_ISA64
    if (funct3 == 1) return true; /* C.JAL, not RV64 C.ADDIW. */
#endif
    return funct3 == 5 || funct3 == 6 || funct3 == 7;
  }
  return quadrant == 2 && funct3 == 4 && (inst & 0x7c) == 0;
}

void nemu_bbv_record(const Decode *instruction, unsigned privilege, word_t satp,
                     word_t thread_pointer)
{
  if (finished) return;
  bool trapped = cpu.instruction_trapped;
  if (activate_after_serial) {
    activate_after_serial = false;
    active = true;
    have_block = false;
    guest_retired += !trapped;
    return;
  }
  if (user_only && (privilege != 0 || satp_root(satp) != user_satp_root ||
                    (thread_only && thread_pointer != user_thread_pointer))) {
    guest_retired += !trapped;
    have_block = false;
    return;
  }
  if (!active && has_start_pc && instruction->epc == start_pc && !trapped) active = true;
  if (active && has_stop_pc && instruction->epc == stop_pc) {
    flush_interval();
    finished = true;
    nemu_state.state = NEMU_QUIT;
    return;
  }
  if (!active) {
    guest_retired += !trapped;
    return;
  }
  if (trapped) {
    traps++;
    have_block = false;
    return;
  }
  if (retired == interval_start) {
    first_pc = have_next_anchor ? anchor_pc : instruction->epc;
    first_guest = have_next_anchor ? anchor_guest : guest_retired;
    first_signature = have_next_anchor ? anchor_signature : nemu_sample_previous_signature;
    first_pc_signature = pc_signature;
    have_next_anchor = false;
  }
  if (!have_block || expected_pc != instruction->epc || block_privilege != privilege ||
      block_satp != satp) {
    block_pc = instruction->epc;
    block_satp = satp;
    block_privilege = privilege;
  }
  if (occupied * 2 >= capacity) grow();
  insert((Block){block_pc, block_satp, 1, block_privilege, true});
  privileges[privilege]++;
  last_signature = nemu_sample_signature;
  // Same ordered PC digest as the FPGA observer, over exactly this domain.
  // Keeping only boundary bands avoids writing one trace row per instruction.
  pc_signature = ((pc_signature << 7) | (pc_signature >> 57)) ^
      (uint64_t)instruction->epc ^ UINT64_C(0x9e3779b97f4a7c15);
  uint64_t band_index = retired - interval_start;
  if (band_index < PC_BAND_SIZE) {
    pc_band_pc[band_index] = instruction->epc;
    pc_band_signature[band_index] = pc_signature;
  }
  last_pc = instruction->epc;
  retired++;
  guest_retired++;
  next_pc = cpu.pc;
  expected_pc = instruction->snpc;
  have_block = !terminates_block(instruction->isa.inst);
  if (retired - interval_start == interval_size) {
    flush_interval();
    // Tick captures before the next instruction/interrupt, at the same point
    // used by an ordinary second-pass capture. No checkpoint at a bounded end.
    if (!roi_limit || retired < roi_limit) nemu_sample_bbv_boundary();
  }
  if (roi_limit && retired == roi_limit) {
    flush_interval();
    finished = true;
    nemu_state.state = NEMU_QUIT;
  }
}

void nemu_bbv_serial(uint8_t byte)
{
  if (!output || finished || byte == '\r') return;
  if (byte != '\n') {
    if (serial_length + 1 < sizeof(serial_line)) serial_line[serial_length++] = byte;
    else serial_overflow = true;
    return;
  }
  serial_line[serial_length] = '\0';
  const char *text = serial_line;
  while (*text == ' ') text++;
  if (!serial_overflow && !active && start_marker && !strcmp(text, start_marker))
    activate_after_serial = true;
  if (!serial_overflow && (!strncmp(text, "Running ", 8) ||
                           !strncmp(text, "RAPTOR_WORKLOAD_", 16))) {
    fprintf(output, "{\"schema\":\"raptor-bbv-marker-v1\",\"guest_instruction\":%" PRIu64
            ",\"roi_instruction\":%" PRIu64 ",\"text\":\"", guest_retired, retired);
    for (const unsigned char *p = (const unsigned char *)text; *p; p++) {
      if (*p == '"' || *p == '\\') fputc('\\', output);
      if (*p >= 32 && *p < 127) fputc(*p, output);
      else fprintf(output, "\\u%04x", *p);
    }
    fputs("\"}\n", output);
    int flushed = fflush(output);
    Assert(flushed == 0, "BBV marker write failed");
  }
  serial_length = 0;
  serial_overflow = false;
}

#else
bool nemu_bbv_enabled;
void nemu_bbv_set_user_scope(word_t satp_root, bool thread_only, word_t thread_pointer) {}
void nemu_bbv_record(const Decode *instruction, unsigned privilege, word_t satp,
                     word_t thread_pointer) {}
void nemu_bbv_serial(uint8_t byte) { (void)byte; }
#endif
