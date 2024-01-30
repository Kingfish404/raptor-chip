#include <unistd.h>
#include <stdio.h>
#include <sys/time.h>
#include <NDL.h>

int main()
{
  struct timeval start, cur;
  gettimeofday(&start, NULL);
  NDL_Init(0);
  while (1)
  {
    gettimeofday(&cur, NULL);
    size_t us_time = (cur.tv_sec - start.tv_sec) * 1000000 + (cur.tv_usec - start.tv_usec);
    us_time = NDL_GetTicks() * 1000;
    if (us_time >= ((size_t)5e5))
    {
      printf("0.5 second passed\n");
      start = cur;
    }
  }
  return 0;
}
