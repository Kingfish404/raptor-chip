/***************************************************************************************
 * Copyright (c) 2014-2022 Zihao Yu, Nanjing University
 *
 * NEMU is licensed under Mulan PSL v2.
 * You can use this software according to the terms and conditions of the Mulan PSL v2.
 * You may obtain a copy of Mulan PSL v2 at:
 *          http://license.coscl.org.cn/MulanPSL2
 *
 * THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND,
 * EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT,
 * MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
 *
 * See the Mulan PSL v2 for more details.
 ***************************************************************************************/

#include <common.h>
#include <utils.h>
#include <device/alarm.h>
#if !defined(CONFIG_TARGET_AM) && defined(CONFIG_VGA_SHOW_SCREEN)
#include <SDL.h>
#endif

void init_map();
void init_serial();
void init_timer();
void init_vga();
void init_i8042();
void init_audio();
void init_disk();
void init_sdcard();
void init_alarm();

void init_intr();

void send_key(uint8_t, bool);
void vga_update_screen();

#ifdef CONFIG_SERIAL_INPUT_FIFO
void serial_poll_stdin(void);
#endif

void device_update()
{
  static uint64_t skip_count = 0;
  if (++skip_count < 65536)
    return;
  skip_count = 0;

  static uint64_t last = 0;
  uint64_t now = get_time();
  if (now - last < 1000000 / TIMER_HZ)
  {
    return;
  }
  last = now;

  IFDEF(CONFIG_HAS_VGA, vga_update_screen());

#ifdef CONFIG_SERIAL_INPUT_FIFO
  serial_poll_stdin();
#endif

#if !defined(CONFIG_TARGET_AM) && defined(CONFIG_VGA_SHOW_SCREEN)
  SDL_Event event;
  while (SDL_PollEvent(&event))
  {
    switch (event.type)
    {
    case SDL_QUIT:
      nemu_state.state = NEMU_QUIT;
      break;
#ifdef CONFIG_HAS_KEYBOARD
    // If a key was pressed
    case SDL_KEYDOWN:
    case SDL_KEYUP:
    {
      uint8_t k = event.key.keysym.scancode;
      bool is_keydown = (event.key.type == SDL_KEYDOWN);
      send_key(k, is_keydown);
      break;
    }
#endif
    default:
      break;
    }
  }
#endif
}

void sdl_clear_event_queue()
{
#if !defined(CONFIG_TARGET_AM) && defined(CONFIG_VGA_SHOW_SCREEN)
  SDL_Event event;
  while (SDL_PollEvent(&event))
    ;
#endif
}

void init_device()
{
  IFDEF(CONFIG_TARGET_AM, ioe_init());
  init_map();

  IFDEF(CONFIG_HAS_SERIAL, init_serial());
  IFDEF(CONFIG_HAS_TIMER, init_timer());
  IFDEF(CONFIG_HAS_VGA, init_vga());
  IFDEF(CONFIG_HAS_KEYBOARD, init_i8042());
  IFDEF(CONFIG_HAS_AUDIO, init_audio());
  IFDEF(CONFIG_HAS_DISK, init_disk());
  IFDEF(CONFIG_HAS_SDCARD, init_sdcard());

#ifndef CONFIG_TARGET_SHARE
  IFNDEF(CONFIG_TARGET_AM, init_alarm());
#endif

  IFNDEF(CONFIG_TARGET_AM, init_intr(););
}
