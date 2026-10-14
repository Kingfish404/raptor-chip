#include <cpu/cpu.h>
#include <cpu/thread.h>
#include <cpu/diffjournal.h>
#include <cpu/multidiff.h>
#include <isa.h>

#ifdef NEMU_HAS_THREADS
#include <pthread.h>
#include <time.h>
#include <errno.h>

bool nemu_threaded;
unsigned nemu_thread_clock_div = 16;
unsigned nemu_stop_hart;
NEMU_TLS bool nemu_worker;
static NEMU_TLS unsigned bus_depth;
static pthread_mutex_t bus_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t wake_cond = PTHREAD_COND_INITIALIZER;
static clockid_t wake_clock = CLOCK_REALTIME;
static bool start_workers;
static uint64_t clock_epoch;
static void (*worker_execute)(uint64_t);
extern NEMU_TLS uint64_t g_nr_guest_inst;
void pmp_hart_switch(void);
void clint_update_mip(void);
void device_update_slow(void);

typedef struct {
  pthread_t thread;
  unsigned hartid;
  uint64_t instructions;
  uint64_t host_cpu_ns;
  uint64_t wfi_waits;
} HartWorker;

static HartWorker workers[NEMU_MAX_HARTS];

static void check_pthread(int result)
{
  if (result != 0)
  {
    fprintf(stderr, "NEMU: pthread operation failed: %s\n", strerror(result));
    abort();
  }
}

static uint64_t clock_ns(clockid_t clock_id)
{
  struct timespec now;
  int result = clock_gettime(clock_id, &now);
  assert(result == 0);
  return (uint64_t)now.tv_sec * 1000000000 + now.tv_nsec;
}

uint64_t cpu_thread_wall_us(void)
{
  return clock_epoch ? (clock_ns(CLOCK_MONOTONIC) - clock_epoch) / 1000 : 0;
}

uint64_t cpu_thread_time_us(void)
{
  return cpu_thread_wall_us() / nemu_thread_clock_div;
}

void cpu_bus_lock(void)
{
  if (nemu_threaded && bus_depth++ == 0)
  {
    check_pthread(pthread_mutex_lock(&bus_mutex));
    if (nemu_journal_bus) nemu_journal_bus(true);
  }
}

void cpu_bus_unlock(void)
{
  if (nemu_threaded)
  {
    assert(bus_depth != 0);
    if (--bus_depth == 0)
    {
      if (nemu_journal_bus) nemu_journal_bus(false);
      check_pthread(pthread_mutex_unlock(&bus_mutex));
    }
  }
}

void cpu_bus_unwind(void)
{
  if (nemu_threaded && bus_depth)
  {
    bus_depth = 1;
    cpu_bus_unlock();
  }
}

void cpu_thread_wake(void)
{
  if (nemu_threaded)
    check_pthread(pthread_cond_broadcast(&wake_cond));
}

bool cpu_thread_poll(void)
{
  cpu_bus_lock();
  for (;;)
  {
    clint_update_mip();
    if (nemu_state.state != NEMU_RUNNING)
    {
      cpu_bus_unlock();
      return false;
    }
    if (!nemu_hart_waiting[nemu_hartid] || (riscv_mip_value() & cpu.sr[CSR_MIE]))
    {
      nemu_hart_waiting[nemu_hartid] = false;
      cpu_bus_unlock();
      return true;
    }
    struct timespec deadline;
    clock_gettime(wake_clock, &deadline);
    deadline.tv_nsec += 1000000;
    if (deadline.tv_nsec >= 1000000000)
    {
      deadline.tv_sec++;
      deadline.tv_nsec -= 1000000000;
    }
    assert(bus_depth == 1);
    if (nemu_journal_bus) nemu_journal_bus(false);
    workers[nemu_hartid].wfi_waits++;
    int result = pthread_cond_timedwait(&wake_cond, &bus_mutex, &deadline);
    if (nemu_journal_bus) nemu_journal_bus(true);
    if (result != ETIMEDOUT) check_pthread(result);
  }
}

static void *hart_worker(void *argument)
{
  HartWorker *worker = argument;
  nemu_worker = true;
  cpu_select_hart(worker->hartid);
  pmp_hart_switch();
  cpu_bus_lock();
  while (!start_workers)
    check_pthread(pthread_cond_wait(&wake_cond, &bus_mutex));
  cpu_bus_unlock();
  uint64_t started = clock_ns(CLOCK_THREAD_CPUTIME_ID);
  if (nemu_journal_start_worker) nemu_journal_start_worker();
  worker_execute(UINT64_MAX);
  cpu_bus_unwind();
  worker->instructions = g_nr_guest_inst;
  worker->host_cpu_ns = clock_ns(CLOCK_THREAD_CPUTIME_ID) - started;
  return NULL;
}

void cpu_threads_run(void (*execute)(uint64_t))
{
  pthread_condattr_t attributes;
  check_pthread(pthread_condattr_init(&attributes));
#ifdef __linux__
  check_pthread(pthread_condattr_setclock(&attributes, CLOCK_MONOTONIC));
  wake_clock = CLOCK_MONOTONIC;
#endif
  check_pthread(pthread_cond_destroy(&wake_cond));
  check_pthread(pthread_cond_init(&wake_cond, &attributes));
  check_pthread(pthread_condattr_destroy(&attributes));
  worker_execute = execute;
  start_workers = false;
  clock_epoch = clock_ns(CLOCK_MONOTONIC);
  unsigned created = 0;
  for (unsigned hartid = 0; hartid < nemu_nr_harts; hartid++)
  {
    workers[hartid].hartid = hartid;
    workers[hartid].wfi_waits = 0;
    int result = pthread_create(&workers[hartid].thread, NULL, hart_worker, &workers[hartid]);
    if (result != 0)
    {
      fprintf(stderr, "NEMU: pthread_create hart %u: %s\n", hartid, strerror(result));
      set_nemu_state(NEMU_ABORT, 0, result);
      break;
    }
    created++;
  }
  cpu_bus_lock();
  start_workers = true;
  cpu_thread_wake();
  cpu_bus_unlock();
  const struct timespec interval = {.tv_nsec = 1000000};
  while (nemu_state.state == NEMU_RUNNING)
  {
    cpu_bus_lock();
    if (!multidiff_active()) device_update_slow();
    cpu_bus_unlock();
    nanosleep(&interval, NULL);
  }
  cpu_bus_lock();
  cpu_thread_wake();
  cpu_bus_unlock();
  for (unsigned hartid = 0; hartid < created; hartid++)
  {
    check_pthread(pthread_join(workers[hartid].thread, NULL));
    g_nr_guest_inst += workers[hartid].instructions;
    printf("NEMU_THREAD hart=%u instructions=%" PRIu64 " host_cpu_ns=%" PRIu64 " wfi_waits=%" PRIu64 "\n",
           hartid, workers[hartid].instructions, workers[hartid].host_cpu_ns, workers[hartid].wfi_waits);
  }
  printf("NEMU_THREADED harts=%u wall_us=%" PRIu64 " clock_div=%u\n",
         created, cpu_thread_wall_us(), nemu_thread_clock_div);
  cpu_select_hart(nemu_stop_hart);
}
#endif
