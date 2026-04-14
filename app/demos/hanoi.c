/* hanoi.c: Tower of Hanoi — animated solver */
#include <stdio.h>
#include <string.h>

#define NDISKS  8
#define PEGS    3
#define PEG_H   (NDISKS + 2)
#define SCREEN_W 60

static int peg[PEGS][NDISKS + 1]; /* peg[p][0] = count */
static int move_count;

static void init_pegs(void) {
    memset(peg, 0, sizeof(peg));
    peg[0][0] = NDISKS;
    for (int i = 0; i < NDISKS; i++)
        peg[0][i + 1] = NDISKS - i; /* bottom=largest */
}

static void draw(void) {
    printf("\x1b[H");
    printf("Tower of Hanoi (%d disks)  moves: %d\n\n", NDISKS, move_count);

    /* Draw from top to bottom */
    for (int row = PEG_H - 1; row >= 0; row--) {
        for (int p = 0; p < PEGS; p++) {
            int peg_center = SCREEN_W / (2 * PEGS) + p * (SCREEN_W / PEGS);
            char line[SCREEN_W + 1];
            memset(line, ' ', SCREEN_W);
            line[SCREEN_W] = '\0';

            if (row == 0) {
                /* Base */
                for (int i = peg_center - NDISKS; i <= peg_center + NDISKS && i < SCREEN_W && i >= 0; i++)
                    line[i] = '=';
            } else if (row <= peg[p][0]) {
                /* Disk */
                int disk = peg[p][row];
                for (int i = -disk; i <= disk; i++) {
                    int pos = peg_center + i;
                    if (pos >= 0 && pos < SCREEN_W)
                        line[pos] = '#';
                }
            } else {
                /* Pole */
                if (peg_center >= 0 && peg_center < SCREEN_W)
                    line[peg_center] = '|';
            }

            printf("%.*s", SCREEN_W / PEGS, line + p * (SCREEN_W / PEGS));
        }
        putchar('\n');
    }

    /* Peg labels */
    for (int p = 0; p < PEGS; p++) {
        int w = SCREEN_W / PEGS;
        for (int i = 0; i < w / 2; i++) putchar(' ');
        printf("%c", 'A' + p);
        for (int i = w / 2 + 1; i < w; i++) putchar(' ');
    }
    putchar('\n');
}

static void move_disk(int from, int to) {
    int disk = peg[from][peg[from][0]];
    peg[from][0]--;
    peg[to][0]++;
    peg[to][peg[to][0]] = disk;
    move_count++;
    draw();
}

static void hanoi(int n, int from, int to, int via) {
    if (n == 0) return;
    hanoi(n - 1, from, via, to);
    move_disk(from, to);
    hanoi(n - 1, via, to, from);
}

int main(void) {
    printf("\x1b[2J");
    printf("\x1b[?25l");

    init_pegs();
    move_count = 0;
    draw();
    hanoi(NDISKS, 0, 2, 1);

    printf("\x1b[?25h");
    printf("\n[hanoi: solved %d disks in %d moves (optimal: %d)]\n",
           NDISKS, move_count, (1 << NDISKS) - 1);
    return 0;
}
