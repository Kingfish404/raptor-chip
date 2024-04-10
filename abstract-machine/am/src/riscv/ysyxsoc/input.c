#include <am.h>
#include <ysyxsoc.h>

void __am_input_keybrd(AM_INPUT_KEYBRD_T *kbd)
{
  kbd->keydown = 0;
  int keycode = inl(KBD_ADDR);
  if (keycode != 0)
  {
    kbd->keydown = 1;
    keycode = keycode;
  }
  kbd->keycode = keycode;
}
