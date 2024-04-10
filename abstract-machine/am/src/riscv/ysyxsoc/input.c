#include <stdint.h>
#include <am.h>
#include <ysyxsoc.h>

uint8_t keymap[256] = {
    [0x1e] = AM_KEY_A,
    [0x30] = AM_KEY_B,
    [0x2e] = AM_KEY_C,
    [0x20] = AM_KEY_D,
    [0x12] = AM_KEY_E,
    [0x21] = AM_KEY_F,
    [0x22] = AM_KEY_G,
    [0x23] = AM_KEY_H,
    [0x17] = AM_KEY_I,
    [0x24] = AM_KEY_J,
    [0x25] = AM_KEY_K,
    [0x26] = AM_KEY_L,
    [0x32] = AM_KEY_M,
    [0x31] = AM_KEY_N,
    [0x18] = AM_KEY_O,
    [0x19] = AM_KEY_P,
    [0x10] = AM_KEY_Q,
    [0x13] = AM_KEY_R,
    [0x1f] = AM_KEY_S,
    [0x14] = AM_KEY_T,
    [0x16] = AM_KEY_U,
    [0x2f] = AM_KEY_V,
    [0x11] = AM_KEY_W,
    [0x2d] = AM_KEY_X,
    [0x15] = AM_KEY_Y,
    [0x2c] = AM_KEY_Z,
    [0x02] = AM_KEY_1,
    [0x03] = AM_KEY_2,
    [0x04] = AM_KEY_3,
    [0x05] = AM_KEY_4,
    [0x06] = AM_KEY_5,
    [0x07] = AM_KEY_6,
    [0x08] = AM_KEY_7,
    [0x09] = AM_KEY_8,
    [0x0a] = AM_KEY_9,
    [0x0b] = AM_KEY_0,
    [0x1c] = AM_KEY_RETURN,
    [0x01] = AM_KEY_ESCAPE,
    [0x0e] = AM_KEY_BACKSPACE,
    [0x0f] = AM_KEY_TAB,
    [0x39] = AM_KEY_SPACE,
    [0x0c] = AM_KEY_MINUS,
    [0x0d] = AM_KEY_EQUALS,
};

void __am_input_keybrd(AM_INPUT_KEYBRD_T *kbd)
{
  kbd->keydown = 0;
  uint8_t keycode = inb(KBD_ADDR);
  if (keycode != 0)
  {
    kbd->keydown = 1;
    keycode = keycode;
  }
  kbd->keycode = keycode;
}
