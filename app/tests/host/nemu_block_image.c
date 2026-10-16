#define _FILE_OFFSET_BITS 64
#include <errno.h>
#include <stdint.h>
#include <unistd.h>

static unsigned faults;
static size_t transfer_limit;
static unsigned flush_calls;

void block_test_faults(unsigned enabled, size_t limit)
{
  faults = enabled;
  transfer_limit = limit;
  flush_calls = 0;
}

unsigned block_test_flush_calls(void)
{
  return flush_calls;
}

static ssize_t test_pread(int descriptor, void *buffer, size_t count, off_t offset)
{
  if (faults & 1) {
    faults &= ~1u;
    errno = EINTR;
    return -1;
  }
  if (faults & 8) {
    errno = EIO;
    return -1;
  }
  if (transfer_limit && count > transfer_limit) count = transfer_limit;
  return pread(descriptor, buffer, count, offset);
}

static ssize_t test_pwrite(int descriptor, const void *buffer, size_t count, off_t offset)
{
  if (faults & 2) {
    faults &= ~2u;
    errno = EINTR;
    return -1;
  }
  if (faults & 16) {
    errno = ENOSPC;
    return -1;
  }
  if (transfer_limit && count > transfer_limit) count = transfer_limit;
  return pwrite(descriptor, buffer, count, offset);
}

static int test_fsync(int descriptor)
{
  flush_calls++;
  if (faults & 4) {
    faults &= ~4u;
    errno = EINTR;
    return -1;
  }
  if (faults & 32) {
    errno = EIO;
    return -1;
  }
  return fsync(descriptor);
}

#define pread test_pread
#define pwrite test_pwrite
#define fsync test_fsync
#include "../../../nemu/src/device/block-image.c"
