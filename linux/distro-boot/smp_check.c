#define _GNU_SOURCE
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

enum { Iterations = 2000, MaxHarts = 4 };
static pthread_barrier_t barrier;
static _Atomic unsigned amo_counter;
static _Atomic unsigned cas_counter;
static _Atomic unsigned failures;

static void *worker(void *argument)
{
  unsigned hartid = (uintptr_t)argument;
  cpu_set_t affinity;
  CPU_ZERO(&affinity);
  CPU_SET(hartid, &affinity);
  if (pthread_setaffinity_np(pthread_self(), sizeof(affinity), &affinity))
    atomic_fetch_add(&failures, 1);
  pthread_barrier_wait(&barrier);
  volatile double value = (double)hartid;
  for (unsigned iteration = 0; iteration < Iterations; iteration++)
  {
    atomic_fetch_add_explicit(&amo_counter, 1, memory_order_seq_cst);
    unsigned expected = atomic_load(&cas_counter);
    while (!atomic_compare_exchange_weak(&cas_counter, &expected, expected + 1))
      ;
    value += 0.5;
    if ((iteration & 127) == 0 && sched_getcpu() != (int)hartid)
      atomic_fetch_add(&failures, 1);
  }
  if (value != (double)hartid + Iterations * 0.5)
    atomic_fetch_add(&failures, 1);
  return NULL;
}

int main(int argc, char **argv)
{
  unsigned harts = argc == 2 ? strtoul(argv[1], NULL, 10) : 0;
  if (harts < 1 || harts > MaxHarts || sysconf(_SC_NPROCESSORS_ONLN) != harts)
    return 1;
  pthread_t threads[MaxHarts];
  if (pthread_barrier_init(&barrier, NULL, harts))
    return 2;
  for (unsigned hartid = 0; hartid < harts; hartid++)
    if (pthread_create(&threads[hartid], NULL, worker, (void *)(uintptr_t)hartid))
      return 3;
  for (unsigned hartid = 0; hartid < harts; hartid++)
    if (pthread_join(threads[hartid], NULL))
      return 4;
  if (failures || amo_counter != harts * Iterations || cas_counter != harts * Iterations)
    return 5;
  printf("RAPTOR_SMP_PASS harts=%u operations=%u\n", harts, (unsigned)amo_counter);
  return 0;
}
