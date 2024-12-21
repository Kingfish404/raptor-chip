#include <NDL.h>
#include <SDL.h>
#include <stdint.h>

int SDL_OpenAudio(SDL_AudioSpec *desired, SDL_AudioSpec *obtained) {
  return 0;
}

void SDL_CloseAudio() {
}

void SDL_PauseAudio(int pause_on) {
}

void SDL_MixAudio(uint8_t *dst, uint8_t *src, uint32_t len, int volume) {
  for (int i = 0; i < len; i++) {
    dst[i] = (dst[i] + src[i]) * volume / SDL_MIX_MAXVOLUME;
  }
}

struct wave_header
{
  uint32_t chunk_id;
  uint32_t chunk_size;
  uint32_t format;

  uint32_t subchunk1_id;
  uint32_t subchunk1_size;
  uint16_t audio_format;
  uint16_t num_channels;
  uint32_t sample_rate;
  uint32_t byte_rate;
  uint16_t block_align;
  uint16_t bits_per_sample;

  uint32_t subchunk2_id;
  uint32_t subchunk2_size;
};


SDL_AudioSpec *SDL_LoadWAV(const char *file, SDL_AudioSpec *spec, uint8_t **audio_buf, uint32_t *audio_len) {
  FILE *f = fopen(file, "r");
  fseek(f, 0, SEEK_END);
  *(audio_len) = ftell(f);
  struct wave_header *wave_p;

  *(audio_buf) = (void *)malloc(*(audio_len));
  fseek(f, 0, SEEK_SET);
  fread(*(audio_buf), 1, *(audio_len), f);

  wave_p = (struct wave_header *)(*(audio_buf));

  spec->freq = wave_p->sample_rate;

  spec->format = wave_p->format;
  spec->channels = wave_p->num_channels;
  spec->samples = wave_p->bits_per_sample;
  spec->size = *(audio_len);

  return spec;
}

void SDL_FreeWAV(uint8_t *audio_buf) {
  free(audio_buf);
}

void SDL_LockAudio() {
}

void SDL_UnlockAudio() {
}
