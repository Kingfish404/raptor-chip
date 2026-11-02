#include <cpu/sample.h>
#include <cpu/thread.h>
#include <cpu/multidiff.h>
#include <isa.h>
#include <memory/paddr.h>

#ifndef CONFIG_TARGET_AM
#include <errno.h>
#include <sys/stat.h>

bool nemu_sample_enabled;
uint64_t nemu_sample_signature = UINT64_C(14695981039346656037);
uint64_t nemu_sample_previous_signature = UINT64_C(14695981039346656037);
static const char *output_directory;
static FILE *points_file;
static uint64_t retired, target;
static bool read_any_target;
static bool have_target;
static uint64_t bbv_stride, bbv_intervals;

bool clint_sample_state(FILE *out) __attribute__((weak));
bool plic_sample_state(FILE *out) __attribute__((weak));
bool serial_sample_state(FILE *out) __attribute__((weak));

static void read_target(void)
{
  char line[128];
  have_target = false;
  while (fgets(line, sizeof(line), points_file)) {
    if (line[0] == '#' || line[0] == '\n') continue;
    char *end;
    errno = 0;
    uint64_t next = strtoull(line, &end, 10);
    while (*end == ' ' || *end == '\t' || *end == '\r' || *end == '\n') end++;
    Assert(!errno && end != line && !*end && line[0] != '-' &&
           (!read_any_target || next > target), "Invalid or unsorted sample instruction count");
    target = next;
    read_any_target = true;
    have_target = true;
    return;
  }
  Assert(!ferror(points_file), "Cannot read sample points");
}

static void configure_directory(const char *directory)
{
  Assert(directory && !nemu_sample_enabled, "Sample output must be configured exactly once");
  Assert(!nemu_threaded && nemu_nr_harts == 1 && !multidiff_active(),
         "Sample capture requires standalone single-hart rr execution");
  Assert(CONFIG_MBASE == 0x80000000 && CONFIG_MSIZE % 65536 == 0,
         "Sample capture requires the Raptor RAM layout");
  int created = mkdir(directory, 0777);
  Assert(created == 0, "Sample directory must be new: %s", directory);
  output_directory = directory;
  nemu_sample_enabled = true;
}

void nemu_sample_configure(const char *points, const char *directory)
{
  if (!points && !directory) return;
  Assert(points && directory, "Sample capture requires both points and output directory");
  configure_directory(directory);
  points_file = fopen(points, "r");
  Assert(points_file, "Cannot open sample points '%s'", points);
  read_target();
  Assert(have_target, "Sample point list is empty");
}

void nemu_sample_configure_bbv(const char *directory, uint64_t every)
{
  Assert(every, "Periodic BBV checkpoint stride must be positive");
  configure_directory(directory);
  bbv_stride = every;
}

void nemu_sample_bbv_boundary(void)
{
  if (!bbv_stride || ++bbv_intervals % bbv_stride) return;
  Assert(!have_target, "Previous periodic checkpoint was not captured");
  target = retired;
  have_target = true;
}

void nemu_sample_retire(vaddr_t pc, uint32_t instruction, bool trapped)
{
  nemu_sample_previous_signature = nemu_sample_signature;
  if (!trapped) {
    nemu_sample_signature = (nemu_sample_signature ^ pc) * UINT64_C(1099511628211);
    nemu_sample_signature = (nemu_sample_signature ^ instruction) * UINT64_C(1099511628211);
  }
  retired += !trapped;
}

static bool device_state(FILE *out)
{
  if (clint_sample_state && !clint_sample_state(out)) return false;
  if (plic_sample_state && !plic_sample_state(out)) return false;
  if (serial_sample_state && !serial_sample_state(out)) return false;
  if (nemu_block_reset_state && !nemu_block_reset_state()) return false;
  if (nemu_net_reset_state && !nemu_net_reset_state()) return false;
  if (nemu_rng_reset_state && !nemu_rng_reset_state()) return false;
  return true;
}

static void save_state(const char *directory)
{
  char path[8192];
  int length = snprintf(path, sizeof(path), "%s/state.txt", directory);
  Assert(length > 0 && (size_t)length < sizeof(path), "Sample path too long");
  FILE *out = fopen(path, "wx");
  Assert(out, "Cannot create sample state");
  fprintf(out, "# NEMU architectural sample; caches, TLB and predictor start cold.\n");
  fprintf(out, "xlen=%zu\ncycle=0\ninstr=0\npc=0x%" PRIx64 "\npriv=%u\n",
          sizeof(word_t) * 8, (uint64_t)cpu.pc, cpu.priv);
  for (unsigned i = 0; i < 32; i++) {
    fprintf(out, "gpr%u=0x%" PRIx64 "\nfpr%u=0x%016" PRIx64 "\n",
            i, (uint64_t)cpu.gpr[i], i, cpu.fpr[i]);
  }
  static const struct { unsigned address; const char *name; } csrs[] = {
    {0x003, "fcsr"}, {0x100, "sstatus"}, {0x104, "sie"}, {0x105, "stvec"},
    {0x106, "scounteren"}, {0x140, "sscratch"}, {0x141, "sepc"},
    {0x142, "scause"}, {0x143, "stval"}, {0x144, "sip"}, {0x180, "satp"},
    {0x300, "mstatus"}, {0x302, "medeleg"}, {0x303, "mideleg"}, {0x304, "mie"},
    {0x305, "mtvec"}, {0x306, "mcounteren"}, {0x30a, "menvcfg"},
    {0x340, "mscratch"}, {0x341, "mepc"}, {0x342, "mcause"},
    {0x343, "mtval"}, {0x344, "mip"}, {0xb00, "mcycle"}, {0xb02, "minstret"},
    {0x14d, "stimecmp"},
#ifndef CONFIG_ISA64
    {0x310, "mstatush"}, {0x31a, "menvcfgh"}, {0x15d, "stimecmph"},
    {0xb80, "mcycleh"}, {0xb82, "minstreth"},
#endif
  };
  for (unsigned i = 0; i < sizeof(csrs) / sizeof(csrs[0]); i++)
    fprintf(out, "csr_%s=0x%" PRIx64 "\n", csrs[i].name, (uint64_t)cpu.sr[csrs[i].address]);
  for (unsigned i = 0; i < 16; i++) {
#ifdef CONFIG_ISA64
    word_t config = cpu.sr[CSR_PMPCFG0 + (i / 8) * 2] >> ((i % 8) * 8);
#else
    word_t config = cpu.sr[CSR_PMPCFG0 + i / 4] >> ((i % 4) * 8);
#endif
    fprintf(out, "pmpcfg%u=0x%x\npmpaddr%u=0x%" PRIx64 "\n",
            i, (unsigned)config & 255, i, (uint64_t)cpu.sr[CSR_PMPADDR0 + i]);
  }
  bool devices_ok = device_state(out);
  Assert(devices_ok, "Device changed during architectural sample capture");
  bool written = !ferror(out);
  int closed = fclose(out);
  Assert(written && closed == 0, "Sample state write failed");
}

static void save_memory(const char *directory)
{
  char path[8192];
  snprintf(path, sizeof(path), "%s/mem_pmem.bin", directory);
  FILE *out = fopen(path, "wx");
  Assert(out, "Cannot create sample RAM");
  snprintf(path, sizeof(path), "%s/mem_pmem.bin.meta", directory);
  FILE *meta = fopen(path, "wx");
  Assert(meta, "Cannot create sample RAM metadata");
  // Find nonzero chunks first so the simulator's existing sparse format can
  // declare its chunk count before the offsets. No device reads are involved.
  unsigned chunks = 0;
  for (uint64_t offset = 0; offset < CONFIG_MSIZE; offset += 65536) {
    const uint8_t *data = guest_to_host((paddr_t)CONFIG_MBASE + offset);
    bool nonzero = false;
    for (unsigned i = 0; i < 65536; i++) nonzero |= data[i] != 0;
    chunks += nonzero;
  }
  fprintf(meta, "size=0x%" PRIx64 "\nchunk_size=0x10000\nchunks=%u\n",
          (uint64_t)CONFIG_MSIZE, chunks);
  for (uint64_t offset = 0; offset < CONFIG_MSIZE; offset += 65536) {
    const uint8_t *data = guest_to_host((paddr_t)CONFIG_MBASE + offset);
    bool nonzero = false;
    for (unsigned i = 0; i < 65536; i++) nonzero |= data[i] != 0;
    if (!nonzero) continue;
    fprintf(meta, "chunk=0x%" PRIx64 "\n", offset);
    size_t written = fwrite(data, 1, 65536, out);
    Assert(written == 65536, "Sample RAM write failed");
  }
  int out_closed = fclose(out), meta_closed = fclose(meta);
  Assert(out_closed == 0 && meta_closed == 0, "Sample RAM close failed");
}

bool nemu_sample_tick(void)
{
  if (!have_target) {
    if (bbv_stride) return false;
    nemu_state.state = NEMU_QUIT;
    return true;
  }
  if (retired != target) return false;
  Assert(!cpu.virt && !cpu.reservation_bytes && !(cpu.sr[CSR_MSTATUS] & ((word_t)1 << 17)),
         "Sample point has virtual/MPRV/LR state; choose another point");
  Assert(device_state(NULL), "Sample point has unsupported or active device state");
  char directory[4096];
  int length = snprintf(directory, sizeof(directory), "%s/sample-%" PRIu64,
                        output_directory, retired);
  Assert(length > 0 && (size_t)length < sizeof(directory), "Sample path too long");
  int created = mkdir(directory, 0777);
  Assert(created == 0, "Sample point output already exists");
  save_state(directory);
  save_memory(directory);
  char path[4096];
  Assert(strlen(directory) + 13 < sizeof(path), "Sample path too long");
  snprintf(path, sizeof(path), "%s/sample.json", directory);
  FILE *meta = fopen(path, "wx");
  Assert(meta, "Cannot create sample metadata");
  fprintf(meta, "{\"schema\":\"raptor-arch-sample-v1\",\"guest_start\":%" PRIu64
          ",\"pc\":\"0x%" PRIx64 "\",\"xlen\":%zu,\"privilege\":%u,"
          "\"ram_bytes\":%" PRIu64 ",\"signature\":\"%016" PRIx64
          "\",\"scope\":\"cpu-ram-quiet-devices\"}\n",
          retired, (uint64_t)cpu.pc, sizeof(word_t) * 8, cpu.priv,
          (uint64_t)CONFIG_MSIZE, nemu_sample_signature);
  int closed = fclose(meta);
  Assert(closed == 0, "Sample metadata write failed");
  Log("sample: SAVED retired=%" PRIu64 " pc=" FMT_WORD " directory=%s",
      retired, cpu.pc, directory);
  if (bbv_stride) {
    have_target = false;
    return false;
  }
  read_target();
  if (!have_target) {
    int closed = fclose(points_file);
    Assert(closed == 0, "Sample point close failed");
    nemu_state.state = NEMU_QUIT;
    return true;
  }
  return false;
}

#else
bool nemu_sample_enabled;
uint64_t nemu_sample_signature, nemu_sample_previous_signature;
void nemu_sample_retire(vaddr_t pc, uint32_t instruction, bool trapped) {}
void nemu_sample_bbv_boundary(void) {}
bool nemu_sample_tick(void) { return false; }
#endif
