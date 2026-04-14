/* mandelbrot.c: Mandelbrot set rendered in ASCII using fixed-point arithmetic */
#include <stdio.h>

/* Fixed-point Q12: 4 integer bits + 12 fractional bits */
#define FP_SHIFT 12
#define FP_ONE   (1 << FP_SHIFT)
#define FP_MUL(a, b) (int)(((long)(a) * (long)(b)) >> FP_SHIFT)

#define W  78
#define H  30
#define MAX_ITER 64

static const char shade[] = " .:-=+*#%@@@";

int main(void) {
    /* View window: real [-2.0, 1.0], imag [-1.2, 1.2] */
    int x_min = -2 * FP_ONE;
    int x_max = 1 * FP_ONE;
    int y_min = -1 * FP_ONE - (FP_ONE / 5);
    int y_max = 1 * FP_ONE + (FP_ONE / 5);

    int dx = (x_max - x_min) / W;
    int dy = (y_max - y_min) / H;

    printf("Mandelbrot Set (%dx%d, fixed-point Q12, max_iter=%d)\n\n", W, H, MAX_ITER);

    for (int row = 0; row < H; row++) {
        int ci = y_min + row * dy;
        for (int col = 0; col < W; col++) {
            int cr = x_min + col * dx;

            int zr = 0, zi = 0;
            int iter;
            for (iter = 0; iter < MAX_ITER; iter++) {
                int zr2 = FP_MUL(zr, zr);
                int zi2 = FP_MUL(zi, zi);
                if (zr2 + zi2 > 4 * FP_ONE) break;
                int new_zi = 2 * FP_MUL(zr, zi) + ci;
                zr = zr2 - zi2 + cr;
                zi = new_zi;
            }

            int shade_idx = (iter * ((int)sizeof(shade) - 2)) / MAX_ITER;
            if (shade_idx < 0) shade_idx = 0;
            if (shade_idx >= (int)sizeof(shade) - 1) shade_idx = (int)sizeof(shade) - 2;
            putchar(shade[shade_idx]);
        }
        putchar('\n');
    }

    printf("\n[mandelbrot: rendered %dx%d]\n", W, H);
    return 0;
}
