#include <NDL.h>
#include <SDL.h>
#include <string.h>

#define keyname(k) #k,

static const char *keyname[] = {
  "NONE",
  _KEYS(keyname)
};

static uint8_t key_state[sizeof(keyname) / sizeof(keyname[0])] = {0};

int SDL_PushEvent(SDL_Event *ev) {
  return 0;
}

int SDL_PollEvent(SDL_Event *ev) {
  uint8_t buf[128];
  if (NDL_PollEvent(buf, sizeof(buf)) == 0) {
    return 0;
  }

  char type[10], kname[32];
  sscanf(buf, "%s %s", type, kname);
  if (type[0] == 'k' && type[1] == 'd') {
    ev->type = SDL_KEYDOWN;
  }
  if (type[0] == 'k' && type[1] == 'u') {
    ev->type = SDL_KEYUP;
  }
  for (size_t i = 0; i < sizeof(keyname)/sizeof(keyname[0]); i++)
  {
    if (strcmp(kname, keyname[i]) == 0)
    {
      ev->key.keysym.sym = i;
      key_state[ev->key.keysym.sym] = (ev->type == SDL_KEYDOWN) ? 1 : 0;
      break;
    }
  }
  return 1;
}

int SDL_WaitEvent(SDL_Event *event) {
  for (;SDL_PollEvent(event) == 0;) { }
  return 1;
}

int SDL_PeepEvents(SDL_Event *ev, int numevents, int action, uint32_t mask) {
  return 0;
}

uint8_t* SDL_GetKeyState(int *numkeys) {
  SDL_Event ev;

  if (numkeys) {
    *numkeys = sizeof(key_state) / sizeof(key_state[0]);
  }
  return key_state;
}