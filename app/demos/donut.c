/* donut.c: Spinning 3D donut — classic ASCII art animation
 * Based on the famous "donut math" by Andy Sloane.
 * Renders a rotating torus using fixed-point sine/cosine.
 */
#include <stdio.h>
#include <string.h>

/* Fixed-point sine table (256 entries, Q15) */
static const short sin_tab[256] = {
        0,   804,  1608,  2410,  3212,  4011,  4808,  5602,
     6393,  7179,  7962,  8739,  9512, 10278, 11039, 11793,
    12539, 13279, 14010, 14732, 15446, 16151, 16846, 17530,
    18204, 18868, 19519, 20159, 20787, 21403, 22005, 22594,
    23170, 23731, 24279, 24811, 25329, 25832, 26319, 26790,
    27245, 27683, 28105, 28510, 28898, 29268, 29621, 29956,
    30273, 30571, 30852, 31113, 31356, 31580, 31785, 31971,
    32137, 32285, 32412, 32521, 32609, 32678, 32728, 32757,
    32767, 32757, 32728, 32678, 32609, 32521, 32412, 32285,
    32137, 31971, 31785, 31580, 31356, 31113, 30852, 30571,
    30273, 29956, 29621, 29268, 28898, 28510, 28105, 27683,
    27245, 26790, 26319, 25832, 25329, 24811, 24279, 23731,
    23170, 22594, 22005, 21403, 20787, 20159, 19519, 18868,
    18204, 17530, 16846, 16151, 15446, 14732, 14010, 13279,
    12539, 11793, 11039, 10278,  9512,  8739,  7962,  7179,
     6393,  5602,  4808,  4011,  3212,  2410,  1608,   804,
        0,  -804, -1608, -2410, -3212, -4011, -4808, -5602,
    -6393, -7179, -7962, -8739, -9512,-10278,-11039,-11793,
   -12539,-13279,-14010,-14732,-15446,-16151,-16846,-17530,
   -18204,-18868,-19519,-20159,-20787,-21403,-22005,-22594,
   -23170,-23731,-24279,-24811,-25329,-25832,-26319,-26790,
   -27245,-27683,-28105,-28510,-28898,-29268,-29621,-29956,
   -30273,-30571,-30852,-31113,-31356,-31580,-31785,-31971,
   -32137,-32285,-32412,-32521,-32609,-32678,-32728,-32757,
   -32767,-32757,-32728,-32678,-32609,-32521,-32412,-32285,
   -32137,-31971,-31785,-31580,-31356,-31113,-30852,-30571,
   -30273,-29956,-29621,-29268,-28898,-28510,-28105,-27683,
   -27245,-26790,-26319,-25832,-25329,-24811,-24279,-23731,
   -23170,-22594,-22005,-21403,-20787,-20159,-19519,-18868,
   -18204,-17530,-16846,-16151,-15446,-14732,-14010,-13279,
   -12539,-11793,-11039,-10278, -9512, -8739, -7962, -7179,
    -6393, -5602, -4808, -4011, -3212, -2410, -1608,  -804,
};

static int fsin(int angle) { return sin_tab[angle & 255]; }
static int fcos(int angle) { return sin_tab[(angle + 64) & 255]; }

#define W 60
#define H 25
#define Q 15  /* Q15 fixed-point */

int main(void) {
    char screen[H][W + 1];
    int zbuf[H * W];
    const char *shade = ".,-~:;=!*#$@";
    int nframes = 50; /* number of frames to render */

    for (int frame = 0; frame < nframes; frame++) {
        int A = frame * 4;      /* rotation angle A */
        int B = frame * 3;      /* rotation angle B */

        memset(screen, ' ', sizeof(screen));
        for (int y = 0; y < H; y++) screen[y][W] = '\0';
        memset(zbuf, 0, sizeof(zbuf));

        int sA = fsin(A), cA = fcos(A);
        int sB = fsin(B), cB = fcos(B);

        /* theta loops around the tube, phi loops around the torus */
        for (int theta = 0; theta < 256; theta += 4) {
            int st = fsin(theta), ct = fcos(theta);

            for (int phi = 0; phi < 256; phi += 2) {
                int sp = fsin(phi), cp = fcos(phi);

                /* Torus params: R1=1 (tube radius), R2=2 (torus center) */
                /* Use scaled integers: R1=1<<Q, R2=2<<Q */
                long h = (long)ct + (2L << Q); /* R2 + R1*cos(theta) */
                long x = (h * cp) >> Q;
                long y_val = (h * sp) >> Q;
                long z = ((long)st * (1L << Q)) >> Q; /* R1*sin(theta) */

                /* Rotate around X by A */
                long y2 = (y_val * cA - z * sA) >> Q;
                long z2 = (y_val * sA + z * cA) >> Q;

                /* Rotate around Z by B */
                long x2 = (x * cB - y2 * sB) >> Q;
                long y3 = (x * sB + y2 * cB) >> Q;

                /* Perspective: K1/(K2+z) where K2=5 */
                long depth = z2 + (5L << Q);
                if (depth <= 0) continue;

                /* Project to screen */
                int xp = (int)(W / 2 + (x2 * (long)(W * 3 / 8) * (1L << Q)) / (depth * 2));
                int yp = (int)(H / 2 - (y3 * (long)(H * 3 / 8) * (1L << Q)) / (depth * 2));

                if (xp < 0 || xp >= W || yp < 0 || yp >= H) continue;

                int iz = (int)((1L << 20) / (depth >> (Q - 10)));
                int idx = yp * W + xp;
                if (iz > zbuf[idx]) {
                    zbuf[idx] = iz;
                    /* Compute luminance from surface normal */
                    long lum = ((long)st * sA - (long)sp * ct * cA) >> Q;
                    lum = ((long)cp * cB * lum + (long)sB * ((long)sp * ct * sA + (long)st * cA)) >> (2 * Q - Q);
                    int L = (int)((lum + (1L << Q)) * 6) >> Q;
                    if (L < 0) L = 0;
                    if (L > 11) L = 11;
                    screen[yp][xp] = shade[L];
                }
            }
        }

        printf("\x1b[H"); /* cursor home */
        for (int y = 0; y < H; y++)
            printf("%s\n", screen[y]);
    }

    printf("\n[donut: rendered %d frames]\n", nframes);
    return 0;
}
