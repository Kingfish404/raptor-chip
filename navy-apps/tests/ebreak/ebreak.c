#include <unistd.h>
#include <stdio.h>

int main()
{
    asm volatile(
        "li a0, 0\n"
        "ebreak\n");
    printf("ebreak error!\n");
    while (1)
    {
    }
    return 0;
}
