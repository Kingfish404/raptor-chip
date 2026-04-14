/* langton.c: Langton's Ant — cellular automaton on a terminal grid */
#include <stdio.h>
#include <string.h>

#define W 60
#define H 30

static int grid[H][W]; /* 0=white, 1=black */

int main(void) {
    memset(grid, 0, sizeof(grid));

    int x = W / 2, y = H / 2;
    int dir = 0; /* 0=up, 1=right, 2=down, 3=left */

    int steps = 2000;

    printf("\x1b[2J");   /* clear screen */
    printf("\x1b[?25l"); /* hide cursor */

    for (int step = 0; step < steps; step++) {
        /* Rule: on white -> turn right, on black -> turn left */
        if (grid[y][x] == 0)
            dir = (dir + 1) & 3; /* turn right */
        else
            dir = (dir + 3) & 3; /* turn left */

        /* Flip cell color */
        grid[y][x] ^= 1;

        /* Move forward */
        switch (dir) {
            case 0: y--; break;
            case 1: x++; break;
            case 2: y++; break;
            case 3: x--; break;
        }

        /* Wrap around */
        if (x < 0) x = W - 1;
        if (x >= W) x = 0;
        if (y < 0) y = H - 1;
        if (y >= H) y = 0;

        /* Draw every 10 steps */
        if (step % 10 == 0 || step == steps - 1) {
            printf("\x1b[H"); /* cursor home */
            printf("Langton's Ant  step %d/%d\n", step + 1, steps);
            for (int r = 0; r < H; r++) {
                for (int c = 0; c < W; c++) {
                    if (r == y && c == x)
                        printf("\x1b[1;31m@\x1b[0m"); /* ant */
                    else if (grid[r][c])
                        printf("\x1b[40m \x1b[0m"); /* black cell */
                    else
                        putchar('.'); /* white cell */
                }
                putchar('\n');
            }
        }
    }

    /* Count black cells */
    int black = 0;
    for (int r = 0; r < H; r++)
        for (int c = 0; c < W; c++)
            black += grid[r][c];

    printf("\x1b[?25h"); /* show cursor */
    printf("[langton: %d steps, %d black cells]\n", steps, black);
    return 0;
}
