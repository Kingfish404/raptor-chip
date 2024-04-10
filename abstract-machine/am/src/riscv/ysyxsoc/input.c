#include <stdint.h>
#include <am.h>
#include <ysyxsoc.h>

uint8_t ps2_keymap[256] = {
    [0x1c] = AM_KEY_A,
    [0x32] = AM_KEY_B,
    [0x21] = AM_KEY_C,
    [0x23] = AM_KEY_D,
    [0x24] = AM_KEY_E,
    [0x2b] = AM_KEY_F,
    [0x34] = AM_KEY_G,
    [0x33] = AM_KEY_H,
    [0x43] = AM_KEY_I,
    [0x3b] = AM_KEY_J,
    [0x42] = AM_KEY_K,
    [0x4b] = AM_KEY_L,
    [0x3a] = AM_KEY_M,
    [0x31] = AM_KEY_N,
    [0x44] = AM_KEY_O,
    [0x4d] = AM_KEY_P,
    [0x15] = AM_KEY_Q,
    [0x2d] = AM_KEY_R,
    [0x1b] = AM_KEY_S,
    [0x2c] = AM_KEY_T,
    [0x3c] = AM_KEY_U,
    [0x2a] = AM_KEY_V,
    [0x1d] = AM_KEY_W,
    [0x22] = AM_KEY_X,
    [0x35] = AM_KEY_Y,
    [0x1a] = AM_KEY_Z,
    [0x45] = AM_KEY_0,
    [0x16] = AM_KEY_1,
    [0x1e] = AM_KEY_2,
    [0x26] = AM_KEY_3,
    [0x25] = AM_KEY_4,
    [0x2e] = AM_KEY_5,
    [0x36] = AM_KEY_6,
    [0x3d] = AM_KEY_7,
    [0x3e] = AM_KEY_8,
    [0x46] = AM_KEY_9,
};

void __am_input_keybrd(AM_INPUT_KEYBRD_T *kbd)
{
  kbd->keydown = 0;
  uint8_t keycode = inb(KBD_ADDR);
  if (keycode != 0)
  {
    kbd->keydown = 1;
    keycode = ps2_keymap[keycode];
  }
  kbd->keycode = keycode;
}
