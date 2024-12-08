#include <common.h>

#if defined(MULTIPROGRAM) && !defined(TIME_SHARING)
#define MULTIPROGRAM_YIELD() yield()
#else
#define MULTIPROGRAM_YIELD()
#endif

#define NAME(key) \
  [AM_KEY_##key] = #key,

static const char *keyname[256] __attribute__((used)) = {
    [AM_KEY_NONE] = "NONE",
    AM_KEYS(NAME)};

size_t serial_write(const void *buf, size_t offset, size_t len)
{
  yield();
  for (size_t i = 0; i < len; i++)
  {
    putch(((char *)buf)[i]);
  }
  return 0;
}

size_t events_read(void *buf, size_t offset, size_t len)
{
  yield();
  AM_INPUT_KEYBRD_T ev = io_read(AM_INPUT_KEYBRD);
  if (ev.keycode != 0)
  {
    char *p = (char *)buf;
    sprintf((char *)p, "%s %s", ev.keydown ? "kd" : "ku", keyname[ev.keycode]);
    return strlen(p);
  }
  return 0;
}

size_t dispinfo_read(void *buf, size_t offset, size_t len)
{
  size_t *p = (size_t *)buf;
  int w = io_read(AM_GPU_CONFIG).width;
  int h = io_read(AM_GPU_CONFIG).height;
  int ret = sprintf((char *)p, "WIDTH: %d\nHEIGHT: %d", w, h);
  return ret + 1;
}

static inline void outl(uintptr_t addr, uint32_t data) { *(volatile uint32_t *)addr = data; }

size_t fb_write(const void *buf, size_t offset, size_t len)
{
  yield();
  uint32_t *p = (uint32_t *)buf;
  AM_GPU_CONFIG_T config = io_read(AM_GPU_CONFIG);
  int x = offset % config.width;
  int y = offset / config.width;
  io_write(AM_GPU_FBDRAW, x, y, p, len, 1, true);
  return len;
}

void init_device()
{
  Log("Initializing devices...");
  ioe_init();
}
