/*
 * text.c - a simple test of the UART text output functions.
 * This is not a benchmark, just a sanity check that the text output path
 */
#include "io.h"

int main(void)
{
    for (int i = 0; i < 100; i++)
    {
        puts_uart("Lorem ipsum dolor sit amet, consectetur adipiscing elit. ");
        puts_uart("Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. ");
        puts_uart("Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur. ");
        puts_uart("Excepteur sint occaecat cupidatat non proident, sunt in culpa qui officia deserunt mollit anim id est laborum.\n");
    }
    return 0;
}
