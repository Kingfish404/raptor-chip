#define _FILE_OFFSET_BITS 64
#include <device/block-image.h>

#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

static bool file_transfer(NemuBlockImage *image, size_t offset, void *buffer, size_t size, bool write)
{
  uint8_t *bytes = buffer;
  size_t done = 0;
  while (done < size) {
    size_t chunk = size - done < 65536 ? size - done : 65536;
    ssize_t result = write ? pwrite(image->fd, bytes + done, chunk, (off_t)(offset + done))
                           : pread(image->fd, bytes + done, chunk, (off_t)(offset + done));
    if (result < 0 && errno == EINTR) continue;
    if (result <= 0) {
      if (!result) errno = EIO;
      return false;
    }
    done += (size_t)result;
  }
  return true;
}

void nemu_block_close(NemuBlockImage *image)
{
  if (image->fd >= 0) close(image->fd);
  free(image->data);
  *image = (NemuBlockImage){.fd = -1};
}

bool nemu_block_open(NemuBlockImage *image, const char *path, NemuBlockMode mode)
{
  if (mode < NEMU_BLOCK_VOLATILE || mode > NEMU_BLOCK_PERSISTENT) {
    errno = EINVAL;
    return false;
  }
  NemuBlockImage opened = {.fd = -1, .mode = mode};
  int access = mode == NEMU_BLOCK_PERSISTENT ? O_RDWR : O_RDONLY;
  opened.fd = open(path, access | O_CLOEXEC | O_NONBLOCK);
  if (opened.fd < 0) return false;
  struct stat metadata;
  if (fstat(opened.fd, &metadata) != 0) goto fail;
  if (!S_ISREG(metadata.st_mode) || metadata.st_size <= 0 ||
      (uintmax_t)metadata.st_size > SIZE_MAX) {
    errno = EINVAL;
    goto fail;
  }
  if (flock(opened.fd, (mode == NEMU_BLOCK_PERSISTENT ? LOCK_EX : LOCK_SH) | LOCK_NB) != 0)
    goto fail;
  opened.size = (size_t)metadata.st_size;
  if (mode == NEMU_BLOCK_VOLATILE) {
    opened.data = malloc(opened.size);
    if (!opened.data || !file_transfer(&opened, 0, opened.data, opened.size, false)) goto fail;
  }
  nemu_block_close(image);
  *image = opened;
  return true;

fail:
  {
    int error = errno;
    nemu_block_close(&opened);
    errno = error;
    return false;
  }
}

static bool valid_range(NemuBlockImage *image, size_t offset, size_t size)
{
  if (image->fd < 0 || offset > image->size || size > image->size - offset) {
    errno = EINVAL;
    return false;
  }
  return true;
}

bool nemu_block_read(NemuBlockImage *image, size_t offset, void *buffer, size_t size)
{
  if (!valid_range(image, offset, size)) return false;
  if (!size) return true;
  if (image->data) {
    memcpy(buffer, image->data + offset, size);
    return true;
  }
  return file_transfer(image, offset, buffer, size, false);
}

bool nemu_block_write(NemuBlockImage *image, size_t offset, const void *buffer, size_t size)
{
  if (!valid_range(image, offset, size)) return false;
  if (image->mode == NEMU_BLOCK_READONLY) {
    errno = EROFS;
    return false;
  }
  if (!size) return true;
  if (image->data) {
    memcpy(image->data + offset, buffer, size);
    return true;
  }
  return file_transfer(image, offset, (void *)buffer, size, true);
}

bool nemu_block_flush(NemuBlockImage *image)
{
  if (image->fd < 0) {
    errno = EBADF;
    return false;
  }
  if (image->mode != NEMU_BLOCK_PERSISTENT) return true;
  int result;
  do {
    result = fsync(image->fd);
  } while (result != 0 && errno == EINTR);
  return result == 0;
}
