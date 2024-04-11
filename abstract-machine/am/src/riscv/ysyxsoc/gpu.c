#include <am.h>
#include <ysyxsoc.h>

#define SYNC_ADDR (VGACTL_ADDR + 4)

void __am_gpu_init()
{
    return;
    int i;
    int w = inl(VGACTL_ADDR) >> 16;
    int h = inl(VGACTL_ADDR) & 0xffff;
    uint32_t *fb = (uint32_t *)(uintptr_t)FB_ADDR;
    for (i = 0; i < w * h; i++)
        fb[i] = i;
    outl(SYNC_ADDR, 1);
}

void __am_gpu_config(AM_GPU_CONFIG_T *cfg)
{
    *cfg = (AM_GPU_CONFIG_T){
        .present = true, .has_accel = false, .width = inl(VGACTL_ADDR) >> 16, .height = inl(VGACTL_ADDR) & 0xffff, .vmemsz = 0};
}

void __am_gpu_fbdraw(AM_GPU_FBDRAW_T *ctl)
{
    int x = ctl->x, y = ctl->y, w = ctl->w, h = ctl->h;
    uint32_t *pixels = ctl->pixels;
    int H = inl(VGACTL_ADDR) & 0xffff;
    int W = inl(VGACTL_ADDR) >> 16;
    uint32_t *fb = (uint32_t *)(uintptr_t)FB_ADDR;
    for (int j = 0; j < h && y + j < H; j++)
    {
        for (int i = 0; i < w && x + i < W; i++)
        {
            fb[(y + j) * W + (x + i)] = pixels[i];
        }
        pixels += w;
    }
    if (ctl->sync)
    {
        outl(SYNC_ADDR, 1);
    }
}

void __am_gpu_status(AM_GPU_STATUS_T *status)
{
    status->ready = true;
}
