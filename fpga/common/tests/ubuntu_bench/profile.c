#define _GNU_SOURCE
#include "profile.h"
#include <errno.h>
#include <fcntl.h>
#include <linux/perf_event.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

static const char *bench_name;
static int sample_fd = -1, use_csr;
static unsigned long sample_ns;
static struct perf_event_mmap_page *ring;
static size_t ring_bytes;
static struct timespec begin_wall, end_wall;
static struct rusage begin_usage, end_usage;
static uint64_t begin_cycle, end_cycle, begin_instret, end_instret;

static uint64_t read_cycle(void)
{
    uint64_t value;
    __asm__ volatile("rdcycle %0" : "=r"(value) :: "memory");
    return value;
}

static uint64_t read_instret(void)
{
    uint64_t value;
    __asm__ volatile("rdinstret %0" : "=r"(value) :: "memory");
    return value;
}

static void fail(const char *what)
{
    perror(what);
    exit(2);
}

void profile_init(const char *name)
{
    bench_name = name;
    setbuf(stdout, NULL);
    const char *value = getenv("RAPTOR_SAMPLE_NS");
    sample_ns = value ? strtoul(value, NULL, 0) : 0;
    value = getenv("RAPTOR_READ_CSR");
    use_csr = value && !strcmp(value, "1");
    if (sample_ns) {
        struct perf_event_attr attr = {
            .type = PERF_TYPE_SOFTWARE,
            .size = sizeof(attr),
            .config = PERF_COUNT_SW_CPU_CLOCK,
            .sample_period = sample_ns,
            .sample_type = PERF_SAMPLE_IP | PERF_SAMPLE_TIME,
            .read_format = PERF_FORMAT_LOST,
            .disabled = 1,
        };
        sample_fd = syscall(SYS_perf_event_open, &attr, 0, -1, -1, 0);
        if (sample_fd < 0)
            fail("perf_event_open CPU_CLOCK");
        size_t page = sysconf(_SC_PAGESIZE);
        ring_bytes = page * 513; /* 2 MiB, plus the metadata page. */
        ring = mmap(NULL, ring_bytes, PROT_READ | PROT_WRITE, MAP_SHARED, sample_fd, 0);
        if (ring == MAP_FAILED)
            fail("mmap perf ring");
        /* Fault the mapping in before warmup and the timed region. */
        volatile unsigned char *bytes = (void *)ring;
        for (size_t i = 0; i < ring_bytes; i += page)
            (void)bytes[i];
    }
    printf("PROFILE_BEGIN_CONFIG name=%s sample_ns=%lu csr=%d\n",
           bench_name, sample_ns, use_csr);
}

void profile_begin(void)
{
    if (getrusage(RUSAGE_SELF, &begin_usage))
        fail("getrusage begin");
    if (sample_fd >= 0 && ioctl(sample_fd, PERF_EVENT_IOC_ENABLE, 0))
        fail("enable perf");
    if (clock_gettime(CLOCK_MONOTONIC, &begin_wall))
        fail("clock_gettime begin");
    if (use_csr) {
        begin_instret = read_instret();
        begin_cycle = read_cycle();
    }
}

void profile_end(void)
{
    if (use_csr) {
        end_cycle = read_cycle();
        end_instret = read_instret();
    }
    if (clock_gettime(CLOCK_MONOTONIC, &end_wall))
        fail("clock_gettime end");
    if (sample_fd >= 0 && ioctl(sample_fd, PERF_EVENT_IOC_DISABLE, 0))
        fail("disable perf");
    if (getrusage(RUSAGE_SELF, &end_usage))
        fail("getrusage end");
}

uint64_t profile_elapsed_ns(void)
{
    return (end_wall.tv_sec - begin_wall.tv_sec) * UINT64_C(1000000000)
           + end_wall.tv_nsec - begin_wall.tv_nsec;
}

static uint64_t tv_us(struct timeval value)
{
    return value.tv_sec * UINT64_C(1000000) + value.tv_usec;
}

static FILE *output_file(const char *prefix, const char *suffix)
{
    char path[1024];
    if (snprintf(path, sizeof(path), "%s.%s", prefix, suffix) >= (int)sizeof(path)) {
        errno = ENAMETOOLONG;
        fail("profile output path");
    }
    FILE *file = fopen(path, "wb");
    if (!file)
        fail(path);
    return file;
}

void profile_report(void)
{
    uint64_t lost = 0, head = 0;
    const char *prefix = getenv("RAPTOR_PROFILE_PREFIX");
    if (sample_fd >= 0) {
        uint64_t values[2];
        if (read(sample_fd, values, sizeof(values)) != sizeof(values))
            fail("read perf lost count");
        lost = values[1];
        head = __atomic_load_n(&ring->data_head, __ATOMIC_ACQUIRE);
        if (head > ring->data_size) {
            fputs("perf ring overflow: samples cannot be trusted\n", stderr);
            exit(2);
        }
        if (!prefix) {
            fputs("RAPTOR_PROFILE_PREFIX is required for sampling\n", stderr);
            exit(2);
        }
        FILE *out = output_file(prefix, "samples");
        if (fwrite((char *)ring + ring->data_offset, 1, head, out) != head || fclose(out))
            fail("write samples");
        __atomic_store_n(&ring->data_tail, head, __ATOMIC_RELEASE);
        munmap(ring, ring_bytes);
        close(sample_fd);
        sample_fd = -1;
        out = output_file(prefix, "maps");
        FILE *in = fopen("/proc/self/maps", "r");
        if (!in)
            fail("open maps");
        char data[4096];
        size_t n;
        while ((n = fread(data, 1, sizeof(data), in)))
            if (fwrite(data, 1, n, out) != n)
                fail("write maps");
        if (ferror(in))
            fail("read maps");
        fclose(in);
        if (fclose(out))
            fail("close maps");
    }
    printf("PROFILE_JSON {\"name\":\"%s\",\"wall_ns\":%llu,"
           "\"user_us\":%llu,\"system_us\":%llu,"
           "\"hart_cycles\":%llu,\"hart_instructions\":%llu,"
           "\"minor_faults\":%ld,\"major_faults\":%ld,"
           "\"voluntary_switches\":%ld,\"involuntary_switches\":%ld,"
           "\"sample_ns\":%lu,\"sample_bytes\":%llu,\"lost_samples\":%llu}\n",
           bench_name, (unsigned long long)profile_elapsed_ns(),
           (unsigned long long)(tv_us(end_usage.ru_utime) - tv_us(begin_usage.ru_utime)),
           (unsigned long long)(tv_us(end_usage.ru_stime) - tv_us(begin_usage.ru_stime)),
           (unsigned long long)(end_cycle - begin_cycle),
           (unsigned long long)(end_instret - begin_instret),
           end_usage.ru_minflt - begin_usage.ru_minflt,
           end_usage.ru_majflt - begin_usage.ru_majflt,
           end_usage.ru_nvcsw - begin_usage.ru_nvcsw,
           end_usage.ru_nivcsw - begin_usage.ru_nivcsw,
           sample_ns, (unsigned long long)head, (unsigned long long)lost);
}
