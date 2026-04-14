#include <fs.h>
#include <string.h>

typedef size_t (*ReadFn)(void *buf, size_t offset, size_t len);
typedef size_t (*WriteFn)(const void *buf, size_t offset, size_t len);

size_t ramdisk_read(void *buf, size_t offset, size_t len);
size_t ramdisk_write(const void *buf, size_t offset, size_t len);

size_t serial_write(const void *buf, size_t offset, size_t len);

size_t events_read(void *buf, size_t offset, size_t len);

size_t dispinfo_read(void *buf, size_t offset, size_t len);

size_t fb_write(const void *buf, size_t offset, size_t len);

typedef struct
{
  char *name;
  size_t size;
  size_t disk_offset;
  ReadFn read;
  WriteFn write;
  size_t open_offset;
} Finfo;

enum
{
  FD_STDIN,
  FD_STDOUT,
  FD_STDERR,
  FD_EVENTS,
  FD_DISPINFO,
  FD_FB,
};

size_t invalid_read(void *buf, size_t offset, size_t len)
{
  panic("should not reach here");
  return 0;
}

size_t invalid_write(const void *buf, size_t offset, size_t len)
{
  panic("should not reach here");
  return 0;
}

/* This is the information about all files in disk. */
static Finfo file_table[] __attribute__((used)) = {
    [FD_STDIN] = {"stdin", 0, 0, invalid_read, invalid_write},
    [FD_STDOUT] = {"stdout", 0, 0, invalid_read, serial_write},
    [FD_STDERR] = {"stderr", 0, 0, invalid_read, serial_write},
    [FD_EVENTS] = {"/dev/events", 0, 0, events_read, invalid_write},
    [FD_DISPINFO] = {"/proc/dispinfo", 0, 0, dispinfo_read, invalid_write},
    [FD_FB] = {"/dev/fb", 0, 0, invalid_read, fb_write},
#include "files.h"
};

void init_fs()
{
  for (int i = 0; i < sizeof(file_table) / sizeof(file_table[0]); i++)
  {
    Finfo *f = &file_table[i];
    f->open_offset = 0;
    if (f->read == NULL)
    {
      f->read = ramdisk_read;
    }
    if (f->write == NULL)
    {
      f->write = ramdisk_write;
    }
  }
  AM_GPU_CONFIG_T config = io_read(AM_GPU_CONFIG);
  file_table[FD_FB].size = config.width * config.height * sizeof(uint32_t);
}

int fs_open(const char *pathname, int flags, int mode)
{
  for (int i = 0; i < sizeof(file_table) / sizeof(file_table[0]); i++)
  {
    if (strcmp(pathname, file_table[i].name) == 0)
    {
      Finfo *f = &file_table[i];
      f->open_offset = 0;
      return i;
    }
  }
  Log("failed to open file %s", pathname);
  return -1;
}

size_t fs_read(int fd, void *buf, size_t len)
{
  assert(fd >= 0 && fd < sizeof(file_table) / sizeof(file_table[0]));
  Finfo *f = &file_table[fd];
  size_t usable_len = len;
  if (f->size != 0)
  {
    usable_len = f->open_offset + len <= f->size ? len : f->size - f->open_offset;
  }
  int ret = f->read(buf, f->disk_offset + f->open_offset, usable_len);
  f->open_offset += ret;
  return ret;
}

size_t fs_write(int fd, const void *buf, size_t len)
{
  assert(fd >= 0 && fd < sizeof(file_table) / sizeof(file_table[0]));
  Finfo *f = &file_table[fd];
  size_t usable_len = len;
  if (f->size != 0)
  {
    usable_len = f->open_offset + len <= f->size ? len : f->size - f->open_offset;
  }
  int ret = f->write(buf, f->disk_offset + f->open_offset, usable_len);
  f->open_offset += ret;
  return ret;
}

size_t fs_lseek(int fd, size_t offset, int whence)
{
  assert(fd >= 0 && fd < sizeof(file_table) / sizeof(file_table[0]));
  Finfo *f = &file_table[fd];
  switch (whence)
  {
  case SEEK_SET:
    f->open_offset = offset;
    break;
  case SEEK_CUR:
    f->open_offset += offset;
    break;
  case SEEK_END:
    f->open_offset = f->size + offset;
    break;
  default:
    assert(0);
  }
  return f->open_offset;
}

int fs_close(int fd)
{
  assert(fd >= 0 && fd < sizeof(file_table) / sizeof(file_table[0]));
  return 0;
}