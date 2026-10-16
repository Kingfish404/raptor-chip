#ifndef NEMU_DEVICE_BLOCK_IMAGE_H
#define NEMU_DEVICE_BLOCK_IMAGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef enum {
  NEMU_BLOCK_VOLATILE,
  NEMU_BLOCK_READONLY,
  NEMU_BLOCK_PERSISTENT
} NemuBlockMode;

typedef struct {
  int fd;
  NemuBlockMode mode;
  size_t size;
  uint8_t *data;
} NemuBlockImage;

bool nemu_block_open(NemuBlockImage *image, const char *path, NemuBlockMode mode);
void nemu_block_close(NemuBlockImage *image);
bool nemu_block_read(NemuBlockImage *image, size_t offset, void *buffer, size_t size);
bool nemu_block_write(NemuBlockImage *image, size_t offset, const void *buffer, size_t size);
bool nemu_block_flush(NemuBlockImage *image);

#endif
