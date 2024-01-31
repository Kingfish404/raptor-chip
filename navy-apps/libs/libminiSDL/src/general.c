#include <NDL.h>

uint32_t start_time = 0;

int SDL_Init(uint32_t flags) {
  start_time = 0;
  start_time = NDL_GetTicks();
  return NDL_Init(flags);
}

void SDL_Quit() {
  NDL_Quit();
}

char *SDL_GetError() {
  return "Navy does not support SDL_GetError()";
}

int SDL_SetError(const char* fmt, ...) {
  return -1;
}

int SDL_ShowCursor(int toggle) {
  return 0;
}

void SDL_WM_SetCaption(const char *title, const char *icon) {
}
