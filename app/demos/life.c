/* life.c: Conway's Game of Life — terminal animation */
#include <stdio.h>
#include <string.h>

#define W 60
#define H 25

static int cur[H][W], nxt[H][W];

static void clear_grid(int g[H][W]) { memset(g, 0, sizeof(int) * H * W); }

static int count_neighbors(int y, int x) {
    int n = 0;
    for (int dy = -1; dy <= 1; dy++)
        for (int dx = -1; dx <= 1; dx++) {
            if (dy == 0 && dx == 0) continue;
            int ny = (y + dy + H) % H;
            int nx = (x + dx + W) % W;
            n += cur[ny][nx];
        }
    return n;
}

static void step(void) {
    for (int y = 0; y < H; y++)
        for (int x = 0; x < W; x++) {
            int n = count_neighbors(y, x);
            if (cur[y][x])
                nxt[y][x] = (n == 2 || n == 3) ? 1 : 0;
            else
                nxt[y][x] = (n == 3) ? 1 : 0;
        }
    memcpy(cur, nxt, sizeof(cur));
}

static int count_alive(void) {
    int c = 0;
    for (int y = 0; y < H; y++)
        for (int x = 0; x < W; x++)
            c += cur[y][x];
    return c;
}

/* Place some classic patterns */
static void setup(void) {
    clear_grid(cur);

    /* Glider at (2,2) */
    cur[2][3] = 1; cur[3][4] = 1;
    cur[4][2] = 1; cur[4][3] = 1; cur[4][4] = 1;

    /* R-pentomino at (10,25) — chaotic growth */
    cur[10][26] = 1; cur[10][27] = 1;
    cur[11][25] = 1; cur[11][26] = 1;
    cur[12][26] = 1;

    /* Lightweight spaceship (LWSS) at (18,5) */
    cur[18][6] = 1; cur[18][9] = 1;
    cur[19][5] = 1;
    cur[20][5] = 1; cur[20][9] = 1;
    cur[21][5] = 1; cur[21][6] = 1; cur[21][7] = 1; cur[21][8] = 1;

    /* Block (still life) at (5,50) */
    cur[5][50] = 1; cur[5][51] = 1;
    cur[6][50] = 1; cur[6][51] = 1;

    /* Blinker at (1,45) */
    cur[1][45] = 1; cur[1][46] = 1; cur[1][47] = 1;
}

int main(void) {
    setup();

    printf("\x1b[2J");   /* clear screen */
    printf("\x1b[?25l"); /* hide cursor */

    int generations = 100;
    for (int gen = 0; gen < generations; gen++) {
        printf("\x1b[H");
        printf("Game of Life  gen %d/%d  alive: %d   \n", gen, generations, count_alive());

        for (int y = 0; y < H; y++) {
            for (int x = 0; x < W; x++) {
                if (cur[y][x])
                    printf("\x1b[1;33m#\x1b[0m");
                else
                    putchar(' ');
            }
            putchar('\n');
        }

        step();
    }

    printf("\x1b[?25h"); /* show cursor */
    printf("[life: %d generations, %d alive]\n", generations, count_alive());
    return 0;
}
