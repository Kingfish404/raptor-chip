#include <am.h>
#include <amdev.h>
#include <ysyxsoc.h>

void __am_input_keybrd(AM_INPUT_KEYBRD_T *kbd)
{
  kbd->keydown = 0;
  kbd->keycode = AM_KEY_NONE;
  uint8_t keycode = inb(KBD_ADDR);
  if (keycode)
  {
    kbd->keydown = 1;
    kbd->keycode = keycode;
  }
}
