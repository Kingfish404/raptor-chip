/* cmatrix.c: Matrix rain effect (terminal animation) */
#include <stdio.h>
#include <string.h>

#define COLS 60
#define ROWS 24

static unsigned int rng_state = 0xBADCAFE;

static unsigned int rng(void) {
    rng_state ^= rng_state << 13;
    rng_state ^= rng_state >> 17;
    rng_state ^= rng_state << 5;
    return rng_state;
}

static char rand_char(void) {
    /* Mix of digits, katakana-like, and symbols */
    const char *charset = "0123456789"
                          "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
                          "!@#$%^&*(){}[]|;:<>?/~";
    return charset[rng() % 58];
}

int main(void) {
    int head[COLS];   /* current head row for each column */
    int speed[COLS];  /* drop speed per column */
    int len[COLS];    /* trail length */
    char grid[ROWS][COLS + 1];

    /* Initialize */
    for (int c = 0; c < COLS; c++) {
        head[c] = -(int)(rng() % (unsigned)ROWS);
        speed[c] = 1 + (int)(rng() % 3);
        len[c] = 4 + (int)(rng() % 12);
    }
    memset(grid, ' ', sizeof(grid));
    for (int r = 0; r < ROWS; r++) grid[r][COLS] = '\0';

    printf("\x1b[2J");  /* clear screen */
    printf("\x1b[?25l"); /* hide cursor */

    int nframes = 80;
    for (int frame = 0; frame < nframes; frame++) {
        /* Update columns */
        for (int c = 0; c < COLS; c++) {
            /* Clear old tail */
            int tail = head[c] - len[c];
            if (tail >= 0 && tail < ROWS)
                grid[tail][c] = ' ';

            /* Advance head */
            if (frame % speed[c] == 0)
                head[c]++;

            /* Draw head and trail */
            for (int r = head[c]; r > head[c] - len[c] && r >= 0; r--) {
                if (r < ROWS) {
                    if (r == head[c])
                        grid[r][c] = rand_char();
                    else if (grid[r][c] == ' ')
                        grid[r][c] = rand_char();
                }
            }

            /* Reset column when fully past screen */
            if (head[c] - len[c] >= ROWS) {
                head[c] = -(int)(rng() % (unsigned)ROWS) - 5;
                speed[c] = 1 + (int)(rng() % 3);
                len[c] = 4 + (int)(rng() % 12);
            }
        }

        /* Render frame */
        printf("\x1b[H"); /* cursor home */
        for (int r = 0; r < ROWS; r++) {
            for (int c = 0; c < COLS; c++) {
                char ch = grid[r][c];
                if (ch == ' ') {
                    putchar(' ');
                } else if (head[c] >= 0 && r == head[c] && head[c] < ROWS) {
                    /* Bright white head */
                    printf("\x1b[1;37m%c\x1b[0m", ch);
                } else {
                    /* Green trail */
                    int dist = head[c] - r;
                    if (dist < 3)
                        printf("\x1b[1;32m%c\x1b[0m", ch);
                    else if (dist < 6)
                        printf("\x1b[0;32m%c\x1b[0m", ch);
                    else
                        printf("\x1b[2;32m%c\x1b[0m", ch);
                }
            }
            putchar('\n');
        }
    }

    printf("\x1b[?25h"); /* show cursor */
    printf("\x1b[0m");   /* reset colors */
    printf("[cmatrix: rendered %d frames]\n", nframes);
    return 0;
}
