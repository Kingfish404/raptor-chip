#include <difftest-replay.h>
#include <difftest-journal.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>
#include <fcntl.h>

int main(int argc, char **argv)
{
  if (argc != 3) {
    fprintf(stderr, "Usage: %s REF_SO JOURNAL|--fd=N\n", argv[0]);
    return 2;
  }
  void *library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
  if (!library) {
    fprintf(stderr, "%s\n", dlerror());
    return 2;
  }
  if (!strncmp(argv[2], "--fd=", 5)) {
    const char *value = argv[2] + 5;
    char *end = NULL;
    unsigned long descriptor = strtoul(value, &end, 10);
    if (!*value || strspn(value, "0123456789") != strlen(value) || *end || descriptor > INT_MAX) return 2;
    NemuStreamQuery stream_query = (NemuStreamQuery)dlsym(library, "nemu_difftest_stream_query");
    const NemuStreamAPI *stream = stream_query ? stream_query(NEMU_DIFF_STREAM_VERSION, sizeof(NemuStreamAPI)) : NULL;
    if (!stream || stream->version != NEMU_DIFF_STREAM_VERSION || stream->size != sizeof(*stream) ||
        stream->journal_version != NEMU_JOURNAL_VERSION || (stream->xlen != 32 && stream->xlen != 64) || !stream->run_fd ||
        stream_query(0, sizeof(*stream)) || stream_query(NEMU_DIFF_STREAM_VERSION, 0)) {
      fprintf(stderr, "NEMU stream ABI mismatch\n");
      return 2;
    }
    int result = stream->run_fd(descriptor);
    if (!result && fcntl(descriptor, F_GETFD) < 0) return 2;
    if (stream->run_fd(descriptor) == 0) return 2;
    dlclose(library);
    return result ? 1 : 0;
  }
  NemuReplayQuery query = (NemuReplayQuery)dlsym(library, "nemu_difftest_replay_query");
  const NemuReplayAPI *api = query ? query(NEMU_DIFF_REPLAY_VERSION, sizeof(NemuReplayAPI)) : NULL;
  if (!api || api->version != NEMU_DIFF_REPLAY_VERSION || api->size != sizeof(*api) ||
      api->journal_version != NEMU_JOURNAL_VERSION || (api->xlen != 32 && api->xlen != 64) ||
      !api->run || query(0, sizeof(*api)) || query(NEMU_DIFF_REPLAY_VERSION, 0)) {
    fprintf(stderr, "NEMU replay ABI mismatch\n");
    return 2;
  }
  int result = api->run(argv[2]);
  if (api->run(argv[2]) == 0) {
    fprintf(stderr, "NEMU replay incorrectly allowed session reuse\n");
    return 2;
  }
  dlclose(library);
  return result ? 1 : 0;
}
