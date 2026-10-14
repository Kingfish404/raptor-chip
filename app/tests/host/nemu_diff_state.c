#include <cpu/diffstate.h>
#include <assert.h>
#include <stdio.h>

enum { WORDS = sizeof(NemuDiffState) / sizeof(uint64_t) };

static uint64_t random_state = 1;

static uint64_t random_word(void)
{
  random_state ^= random_state << 13;
  random_state ^= random_state >> 7;
  random_state ^= random_state << 17;
  return random_state;
}

static void check(const uint64_t *words, const uint64_t *old)
{
  NemuDiffState state, previous;
  uint64_t record[2 * WORDS + 2];
  memcpy(&state, words, sizeof(state));
  memcpy(&previous, old, sizeof(previous));
  memset(record, 0xa5, sizeof(record));
  size_t count = nemu_diff_state_delta(&state, &previous, record + 1);
  size_t expected = 0;
  for (size_t index = 0; index < WORDS; index++) {
    if (words[index] != old[index]) {
      assert(expected + 2 <= count);
      assert(record[1 + expected++] == index);
      assert(record[1 + expected++] == words[index]);
    }
  }
  assert(count == expected);
  assert(record[0] == UINT64_C(0xa5a5a5a5a5a5a5a5));
  assert(record[1 + count] == UINT64_C(0xa5a5a5a5a5a5a5a5));
  assert(!memcmp(&previous, &state, sizeof(state)));
  assert(nemu_diff_state_delta(&state, &previous, record + 1) == 0);
}

int main(void)
{
  _Static_assert(sizeof(NemuDiffState) == WORDS * sizeof(uint64_t), "state word layout");
  uint64_t words[WORDS] = {0}, old[WORDS] = {0};
  check(words, old);
  for (size_t index = 0; index < WORDS; index++) {
    words[index] = UINT64_MAX;
    check(words, old);
    words[index] = 0;
  }
  for (unsigned trial = 0; trial < 256; trial++) {
    for (size_t index = 0; index < WORDS; index++) {
      old[index] = random_word();
      words[index] = trial % 2 || random_word() % 32 == 0 ? random_word() : old[index];
    }
    check(words, old);
    check(old, words);
  }
  puts("NEMU_DIFF_STATE_PASS");
  return 0;
}
