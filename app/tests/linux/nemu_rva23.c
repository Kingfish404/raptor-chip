#include <asm/hwprobe.h>
#include <asm/unistd.h>
#include <fcntl.h>
#include <linux/kvm.h>
#include <linux/prctl.h>
#include <linux/reboot.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/mman.h>

#ifndef RVA23_TEST_HARTS
#define RVA23_TEST_HARTS 1
#endif

#ifndef PR_PMLEN_SHIFT
#define PR_PMLEN_SHIFT 24
#endif

static long system_call(unsigned long number, unsigned long first, unsigned long second,
                        unsigned long third, unsigned long fourth, unsigned long fifth,
                        unsigned long sixth)
{
  register unsigned long arg0 __asm__("a0") = first;
  register unsigned long arg1 __asm__("a1") = second;
  register unsigned long arg2 __asm__("a2") = third;
  register unsigned long arg3 __asm__("a3") = fourth;
  register unsigned long arg4 __asm__("a4") = fifth;
  register unsigned long arg5 __asm__("a5") = sixth;
  register unsigned long syscall_number __asm__("a7") = number;
  __asm__ volatile("ecall" : "+r"(arg0) : "r"(arg1), "r"(arg2), "r"(arg3),
                   "r"(arg4), "r"(arg5), "r"(syscall_number) : "memory");
  return (long)arg0;
}

static void message(const char *text)
{
  unsigned long length = 0;
  while (text[length]) length++;
  system_call(__NR_write, 1, (unsigned long)text, length, 0, 0, 0);
}

static void require(int passed, const char *name)
{
  if (passed) return;
  message("RVA23_LINUX_FAIL ");
  message(name);
  message("\n");
  system_call(__NR_exit_group, 1, 0, 0, 0, 0, 0);
  for (;;) {}
}

static long control(long descriptor, unsigned long operation, unsigned long argument)
{
  return system_call(__NR_ioctl, descriptor, operation, argument, 0, 0, 0);
}

static void vector_probe(void)
{
  uint8_t input[18] = {0};
  uint8_t output[18] = {0};
  for (unsigned index = 0; index < 4; index++) input[1 + index * 4] = index + 1;
  require(system_call(__NR_getpid, 0, 0, 0, 0, 0, 0) > 0, "vector-system-call");
  __asm__ volatile("vsetivli zero, 4, e32, m1, tu, mu\n"
                   "vle32.v v8, (%0)\n"
                   "vadd.vi v8, v8, 5\n"
                   "vse32.v v8, (%1)"
                   : : "r"(input + 1), "r"(output + 1) : "v8", "memory");
  for (unsigned index = 0; index < sizeof(output); index++)
  {
    unsigned expected = index >= 1 && index <= 13 && index % 4 == 1 ? index / 4 + 6 : 0;
    require(output[index] == expected, "unaligned-vector-result");
  }
  message("RVA23_VECTOR_PASS\n");
}

static void pointer_probe(void)
{
  unsigned long setting = PR_TAGGED_ADDR_ENABLE | (7UL << PR_PMLEN_SHIFT);
  require(system_call(__NR_prctl, PR_SET_TAGGED_ADDR_CTRL, setting, 0, 0, 0, 0) == 0,
          "pointer-mask-enable");
  require(system_call(__NR_prctl, PR_GET_TAGGED_ADDR_CTRL, 0, 0, 0, 0, 0) == (long)setting,
          "pointer-mask-query");
  volatile unsigned long value = 0x12345678;
  volatile unsigned long *tagged = (void *)((unsigned long)&value | (0x5aUL << 57));
  require(*tagged == value, "tagged-load");
  *tagged = 0x87654321;
  require(value == 0x87654321, "tagged-store");
  require(system_call(__NR_prctl, PR_SET_TAGGED_ADDR_CTRL, 0, 0, 0, 0, 0) == 0,
          "pointer-mask-disable");
  message("RVA23_POINTER_MASK_PASS\n");
}

static void cache_probe(void)
{
  struct riscv_hwprobe block_size = {.key = RISCV_HWPROBE_KEY_ZICBOZ_BLOCK_SIZE};
  require(system_call(__NR_riscv_hwprobe, (unsigned long)&block_size, 1, 0, 0, 0, 0) == 0 &&
          block_size.value == 64, "cache-block-size");
  volatile uint8_t blocks[192] __attribute__((aligned(64)));
  for (unsigned index = 0; index < sizeof(blocks); index++) blocks[index] = 0xa5;
  __asm__ volatile(".insn i 0x0f, 2, x0, %0, 4" : : "r"(blocks + 95) : "memory");
  for (unsigned index = 0; index < sizeof(blocks); index++)
    require(blocks[index] == (index >= 64 && index < 128 ? 0 : 0xa5), "cache-block-zero");
  message("RVA23_CACHE_BLOCK_PASS\n");
}

static void kvm_probe(void)
{
  long device = system_call(__NR_openat, AT_FDCWD, (unsigned long)"/dev/kvm", O_RDWR, 0, 0, 0);
  require(device >= 0, "kvm-open");
  require(control(device, KVM_GET_API_VERSION, 0) == 12, "kvm-api");
  long machine = control(device, KVM_CREATE_VM, 0);
  require(machine >= 0, "kvm-create-vm");
  long memory = system_call(__NR_mmap, 0, 4096, PROT_READ | PROT_WRITE,
                            MAP_PRIVATE | MAP_ANONYMOUS, -1UL, 0);
  require(memory > 0, "kvm-memory");
  uint32_t *code = (uint32_t *)memory;
  code[0] = 0x100002b7;
  code[1] = 0x12300313;
  code[2] = 0x0062a023;
  code[3] = 0x0000006f;
  struct kvm_userspace_memory_region region = {
    .slot = 0, .flags = 0, .guest_phys_addr = 0x80000000,
    .memory_size = 4096, .userspace_addr = memory,
  };
  require(control(machine, KVM_SET_USER_MEMORY_REGION, (unsigned long)&region) == 0,
          "kvm-memory-slot");
  long vcpu = control(machine, KVM_CREATE_VCPU, 0);
  require(vcpu >= 0, "kvm-create-vcpu");
  unsigned long entry = 0x80000000;
  struct kvm_one_reg register_value = {
    .id = KVM_REG_RISCV | KVM_REG_SIZE_U64 | KVM_REG_RISCV_CORE |
          KVM_REG_RISCV_CORE_REG(regs.pc),
    .addr = (unsigned long)&entry,
  };
  require(control(vcpu, KVM_SET_ONE_REG, (unsigned long)&register_value) == 0, "kvm-entry");
  long run_size = control(device, KVM_GET_VCPU_MMAP_SIZE, 0);
  require(run_size >= (long)sizeof(struct kvm_run), "kvm-run-size");
  long run_address = system_call(__NR_mmap, 0, run_size, PROT_READ | PROT_WRITE,
                                 MAP_SHARED, vcpu, 0);
  require(run_address > 0, "kvm-run-map");
  struct kvm_run *run = (void *)run_address;
  long result;
  do { result = control(vcpu, KVM_RUN, 0); } while (result == -4);
  require(result == 0 && run->exit_reason == KVM_EXIT_MMIO, "kvm-run-mmio");
  require(run->mmio.phys_addr == 0x10000000 && run->mmio.is_write && run->mmio.len == 4 &&
          run->mmio.data[0] == 0x23 && run->mmio.data[1] == 1 &&
          run->mmio.data[2] == 0 && run->mmio.data[3] == 0, "kvm-mmio-data");
  message("RVA23_KVM_PASS\n");
}

#if RVA23_TEST_HARTS > 1
static void context_probe(unsigned worker, unsigned *ready)
{
  unsigned long cpu_mask = 1UL << (worker % RVA23_TEST_HARTS);
  require(system_call(__NR_sched_setaffinity, 0, sizeof(cpu_mask), (unsigned long)&cpu_mask,
                      0, 0, 0) == 0, "worker-affinity");
  unsigned actual_cpu = -1U;
  require(system_call(__NR_getcpu, (unsigned long)&actual_cpu, 0, 0, 0, 0, 0) == 0 &&
          actual_cpu == worker % RVA23_TEST_HARTS, "worker-cpu");
  __atomic_fetch_add(ready, 1, __ATOMIC_SEQ_CST);
  while (__atomic_load_n(ready, __ATOMIC_SEQ_CST) != 2 * RVA23_TEST_HARTS)
    require(system_call(__NR_sched_yield, 0, 0, 0, 0, 0, 0) == 0, "worker-barrier");
  unsigned long expected = 0x12340000UL + worker;
  unsigned long expected_fcsr = (worker % 5) << 5 | (1U << (worker % 5));
  unsigned long expected_vcsr = (worker & 3) << 1 | (worker & 1);
  __asm__ volatile("vsetivli zero, 2, e64, m1, tu, mu\n"
                   "vmv.v.x v8, %0\n"
                   "csrw fcsr, %1\n"
                   "csrw vcsr, %2"
                   : : "r"(expected), "r"(expected_fcsr), "r"(expected_vcsr) : "v8");
  unsigned partner = (worker + RVA23_TEST_HARTS) % (2 * RVA23_TEST_HARTS);
  for (unsigned iteration = 1; iteration <= 4; iteration++)
  {
    __atomic_store_n(ready + 1 + worker, iteration, __ATOMIC_SEQ_CST);
    while (__atomic_load_n(ready + 1 + partner, __ATOMIC_SEQ_CST) < iteration) {}
    unsigned long output[2], actual_fcsr, actual_vcsr, actual_vl, actual_vtype;
    __asm__ volatile("csrr %0, fcsr\n"
                     "csrr %1, vcsr\n"
                     "csrr %2, vl\n"
                     "csrr %3, vtype\n"
                     "vse64.v v8, (%4)"
                     : "=&r"(actual_fcsr), "=&r"(actual_vcsr), "=&r"(actual_vl), "=&r"(actual_vtype)
                     : "r"(output) : "memory");
    require(actual_fcsr == expected_fcsr && actual_vcsr == expected_vcsr &&
            actual_vl == 2 && actual_vtype == 24 && output[0] == expected && output[1] == expected,
            "worker-fp-vector-context");
  }
  __asm__ volatile("csrw fcsr, zero\ncsrw vcsr, zero");
  vector_probe();
  cache_probe();
  pointer_probe();
  kvm_probe();
}

static void smp_probe(void)
{
  unsigned long cpu_mask = 0;
  require(system_call(__NR_sched_getaffinity, 0, sizeof(cpu_mask), (unsigned long)&cpu_mask,
                      0, 0, 0) == sizeof(cpu_mask) && cpu_mask == (1UL << RVA23_TEST_HARTS) - 1,
          "online-cpu-mask");
  long shared = system_call(__NR_mmap, 0, 4096, PROT_READ | PROT_WRITE,
                            MAP_SHARED | MAP_ANONYMOUS, -1UL, 0);
  require(shared > 0, "worker-shared-memory");
  long children[2 * RVA23_TEST_HARTS];
  for (unsigned worker = 0; worker < 2 * RVA23_TEST_HARTS; worker++)
  {
    long child = system_call(__NR_clone, 17, 0, 0, 0, 0, 0);
    require(child >= 0, "fork-worker");
    if (child == 0)
    {
      context_probe(worker, (unsigned *)shared);
      system_call(__NR_exit_group, 0, 0, 0, 0, 0, 0);
      for (;;) {}
    }
    children[worker] = child;
  }
  for (unsigned worker = 0; worker < 2 * RVA23_TEST_HARTS; worker++)
  {
    int status = -1;
    require(system_call(__NR_wait4, children[worker], (unsigned long)&status, 0, 0, 0, 0) ==
            children[worker] && status == 0, "worker-exit");
  }
  char marker[] = "RVA23_SMP_PASS harts=0 workers=0\n";
  marker[21] = '0' + RVA23_TEST_HARTS;
  marker[31] = '0' + 2 * RVA23_TEST_HARTS;
  message(marker);
}
#endif

int main(void)
{
  long process_id = system_call(__NR_getpid, 0, 0, 0, 0, 0, 0);
  if (process_id == 1)
    require(system_call(__NR_mount, (unsigned long)"devtmpfs", (unsigned long)"/dev",
                        (unsigned long)"devtmpfs", 0, 0, 0) == 0, "mount-devtmpfs");
  struct riscv_hwprobe extension = {.key = RISCV_HWPROBE_KEY_IMA_EXT_0};
  require(system_call(__NR_riscv_hwprobe, (unsigned long)&extension, 1, 0, 0, 0, 0) == 0,
          "hwprobe");
  uint64_t required = RISCV_HWPROBE_IMA_FD | RISCV_HWPROBE_IMA_C | RISCV_HWPROBE_IMA_V |
      RISCV_HWPROBE_EXT_ZBA | RISCV_HWPROBE_EXT_ZBB | RISCV_HWPROBE_EXT_ZBS |
      RISCV_HWPROBE_EXT_ZVBB | RISCV_HWPROBE_EXT_ZFA | RISCV_HWPROBE_EXT_ZFHMIN |
      RISCV_HWPROBE_EXT_ZICOND | RISCV_HWPROBE_EXT_ZICBOZ | RISCV_HWPROBE_EXT_ZVKT |
      (UINT64_C(1) << 31);
  require((extension.value & required) == required, "hwprobe-extensions");
  vector_probe();
  cache_probe();
  pointer_probe();
  kvm_probe();
#if RVA23_TEST_HARTS > 1
  smp_probe();
#endif
  message("RVA23_LINUX_PASS\n");
  if (process_id == 1)
  {
    system_call(__NR_reboot, LINUX_REBOOT_MAGIC1, LINUX_REBOOT_MAGIC2,
                LINUX_REBOOT_CMD_POWER_OFF, 0, 0, 0);
    require(0, "poweroff-returned");
  }
  return 0;
}
