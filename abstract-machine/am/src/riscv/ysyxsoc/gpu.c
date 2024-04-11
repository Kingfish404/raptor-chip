#include <am.h>
#include <stdint.h>
#include <ysyxsoc.h>

void __am_gpu_init()
{
    int w = VGACTL_WIDTH;
    int h = VGACTL_HEIGHT;
    uint32_t *fb = (uint32_t *)(uintptr_t)FB_ADDR;
    for (int i = 0; i < w; i++)
    {
        uint32_t h_addr = (i << 9);
        for (int j = 0; j < h; j++)
        {
            fb[(h_addr) + j] = j;
        }
    }
}

void __am_gpu_config(AM_GPU_CONFIG_T *cfg)
{
    *cfg = (AM_GPU_CONFIG_T){
        .present = true, .has_accel = false, .width = VGACTL_WIDTH, .height = VGACTL_HEIGHT, .vmemsz = 0};
}

void __am_gpu_fbdraw(AM_GPU_FBDRAW_T *ctl)
{
    int x = ctl->x, y = ctl->y, w = ctl->w, h = ctl->h;
    uint32_t *pixels = ctl->pixels;
    int H = VGACTL_WIDTH;
    int W = VGACTL_HEIGHT;
    uint32_t *fb = (uint32_t *)(uintptr_t)FB_ADDR;
    for (int j = 0; j < h && y + j < H; j++)
    {
        for (int i = 0; i < w && x + i < W; i++)
        {
            fb[((x + i) << 9) + (y + j)] = pixels[i];
        }
        pixels += w;
    }
}

void __am_gpu_status(AM_GPU_STATUS_T *status)
{
    status->ready = true;
}
