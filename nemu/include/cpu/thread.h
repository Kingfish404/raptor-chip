#ifndef __CPU_THREAD_H__
#define __CPU_THREAD_H__

#include <common.h>
#include <cpu/replay.h>

#ifdef NEMU_HAS_THREADS
extern bool nemu_threaded;
extern unsigned nemu_thread_clock_div;
extern unsigned nemu_stop_hart;
extern NEMU_TLS bool nemu_worker;
void cpu_bus_lock(void);
void cpu_bus_unlock(void);
void cpu_bus_unwind(void);
void cpu_thread_wake(void);
bool cpu_thread_poll(void);
void cpu_threads_run(void (*execute)(uint64_t));
uint64_t cpu_thread_time_us(void);
uint64_t cpu_thread_wall_us(void);
#else
#define nemu_threaded false
#define nemu_worker false
#ifdef NEMU_HAS_REPLAY
static inline void cpu_bus_lock(void) { if (nemu_replay_lock) nemu_replay_lock(); }
static inline void cpu_bus_unlock(void) { if (nemu_replay_unlock) nemu_replay_unlock(); }
static inline void cpu_bus_unwind(void) { if (nemu_replay_unwind) nemu_replay_unwind(); }
#else
static inline void cpu_bus_lock(void) {}
static inline void cpu_bus_unlock(void) {}
static inline void cpu_bus_unwind(void) {}
#endif
static inline void cpu_thread_wake(void) {}
#endif

#endif
