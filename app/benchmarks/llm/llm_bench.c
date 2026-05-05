#include <stddef.h>
#include <stdint.h>
#include "rllmbench_port.h"

#if defined(RAPT_LITEX_BAREMETAL)
int printf(const char *fmt, ...);
#else
#include <stdio.h>
#endif

#define LLM_MODE_ALL 0
#define LLM_MODE_OPS 1
#define LLM_MODE_INFER 2
#define LLM_MODE_TRAIN 3

#ifndef LLM_BENCH_MODE
#define LLM_BENCH_MODE LLM_MODE_ALL
#endif
#ifndef LLM_OP_ITERS
#define LLM_OP_ITERS 8
#endif
#ifndef LLM_GEN_TOKENS
#define LLM_GEN_TOKENS 12
#endif
#ifndef LLM_TRAIN_STEPS
#define LLM_TRAIN_STEPS 4
#endif
#ifndef LLM_INFER_REPEATS
#define LLM_INFER_REPEATS 1
#endif
#ifndef LLM_ARCH_STRING
#define LLM_ARCH_STRING "unknown"
#endif
#ifndef RLLMBENCH_TARGET_STRING
#if defined(RAPT_LITEX_BAREMETAL)
#define RLLMBENCH_TARGET_STRING "litex-baremetal"
#elif defined(RLLMBENCH_NATIVE)
#define RLLMBENCH_TARGET_STRING "native"
#else
#define RLLMBENCH_TARGET_STRING "riscv-pk"
#endif
#endif

#if defined(__riscv_xlen)
#define LLM_TARGET_XLEN __riscv_xlen
#else
#define LLM_TARGET_XLEN ((int)(sizeof(void *) * 8))
#endif

#define LLM_STR_IMPL(x) #x
#define LLM_STR(x) LLM_STR_IMPL(x)
#define LLM_PROFILE "ops" LLM_STR(LLM_OP_ITERS) "-gen" LLM_STR(LLM_GEN_TOKENS) "x" LLM_STR(LLM_INFER_REPEATS) "-train" LLM_STR(LLM_TRAIN_STEPS)

#define DIM 32
#define HIDDEN 64
#define N_LAYERS 2
#define N_HEADS 4
#define HEAD_DIM (DIM / N_HEADS)
#define SEQ_LEN 16
#define VOCAB 64

#define TRAIN_B 2
#define TRAIN_T 8
#define TRAIN_C 24
#define TRAIN_V 32

#define MATMUL_WORK ((uint64_t)LLM_OP_ITERS * 16ULL * 16ULL * 32ULL)
#define ATTENTION_WORK ((uint64_t)LLM_OP_ITERS * N_HEADS * ((SEQ_LEN * (SEQ_LEN + 1ULL)) / 2ULL) * HEAD_DIM * 2ULL)
#define RMSNORM_WORK ((uint64_t)LLM_OP_ITERS * 64ULL * DIM)
#define ADAMW_WORK ((uint64_t)LLM_OP_ITERS * 8ULL * 512ULL)

static volatile uint32_t g_sink;
static uint64_t g_mode_work;
static uint64_t g_mode_time_us;
static uint32_t g_mode_checksum;

static uint32_t mix32(uint32_t x)
{
    x ^= x >> 16;
    x *= 0x7feb352dU;
    x ^= x >> 15;
    x *= 0x846ca68bU;
    x ^= x >> 16;
    return x;
}

static uint32_t checksum_mix(uint32_t seed, uint32_t value)
{
    return mix32(seed ^ value ^ 0x9e3779b9U);
}

static void split_seconds(uint64_t seconds_us, uint64_t *whole, uint64_t *fraction)
{
    *whole = seconds_us / 1000000ULL;
    *fraction = seconds_us % 1000000ULL;
}

static uint64_t scale_u64(uint64_t value, uint64_t numerator, uint64_t denominator)
{
    if (denominator == 0ULL)
    {
        return 0;
    }
#if defined(__SIZEOF_INT128__)
    return (uint64_t)(((unsigned __int128)value * numerator) / denominator);
#else
    return (value / denominator) * numerator + ((value % denominator) * numerator) / denominator;
#endif
}

static uint64_t bench_score_per_sec(uint64_t work, uint64_t time_us)
{
    if (time_us == 0ULL)
    {
        return 0;
    }
    return scale_u64(work, 1000000ULL, time_us);
}

static void bench_header(void)
{
    printf("RLLMBench 0.1 (RISC-V fixed-point LLM benchmark)\n");
    printf("RLLMBENCH_INFO version=0.1 profile=%s arch=%s xlen=%d target=%s time_unit=s score=score_per_sec\n",
           LLM_PROFILE, LLM_ARCH_STRING, LLM_TARGET_XLEN, RLLMBENCH_TARGET_STRING);
}

static void bench_mode_begin(const char *mode, const char *kind)
{
    g_mode_work = 0;
    g_mode_time_us = 0;
    g_mode_checksum = 0x811c9dc5U;
    printf("RLLMBENCH_BEGIN mode=%s kind=%s profile=%s\n", mode, kind, LLM_PROFILE);
    printf("RLLMBENCH_CONFIG mode=%s arch=%s xlen=%d target=%s op_iters=%d gen_tokens=%d infer_repeats=%d train_steps=%d dim=%d layers=%d heads=%d seq=%d vocab=%d\n",
           mode, LLM_ARCH_STRING, LLM_TARGET_XLEN, RLLMBENCH_TARGET_STRING,
           LLM_OP_ITERS, LLM_GEN_TOKENS, LLM_INFER_REPEATS,
           LLM_TRAIN_STEPS, DIM, N_LAYERS, N_HEADS, SEQ_LEN, VOCAB);
}

static void bench_record(const char *name, const char *kind, const char *unit,
                         uint64_t work, uint64_t time_us, uint32_t checksum)
{
    uint64_t seconds_whole, seconds_fraction;
    uint64_t score_per_sec = bench_score_per_sec(work, time_us);
    split_seconds(time_us, &seconds_whole, &seconds_fraction);
    g_mode_work += work;
    g_mode_time_us += time_us;
    g_mode_checksum = checksum_mix(g_mode_checksum, checksum);
    printf("RLLMBENCH_RESULT name=%s class=%s unit=%s work=%llu seconds=%llu.%06llu score_per_sec=%llu checksum=0x%08x\n",
           name, kind, unit, (unsigned long long)work,
           (unsigned long long)seconds_whole, (unsigned long long)seconds_fraction,
           (unsigned long long)score_per_sec, (unsigned int)checksum);
}

static void bench_mode_end(const char *mode)
{
    uint64_t seconds_whole, seconds_fraction;
    uint64_t score_per_sec = bench_score_per_sec(g_mode_work, g_mode_time_us);
    split_seconds(g_mode_time_us, &seconds_whole, &seconds_fraction);
    printf("RLLMBENCH_SCORE mode=%s work=%llu seconds=%llu.%06llu score_per_sec=%llu checksum=0x%08x\n",
           mode, (unsigned long long)g_mode_work,
           (unsigned long long)seconds_whole, (unsigned long long)seconds_fraction,
           (unsigned long long)score_per_sec, (unsigned int)g_mode_checksum);
    printf("RLLMBENCH_END mode=%s status=PASS sink=0x%08x\n", mode, (unsigned int)g_sink);
}

static int8_t weight8(uint32_t index)
{
    uint32_t x = mix32(index + 0x9e3779b9U);
    return (int8_t)((int)(x % 31U) - 15);
}

static int16_t weight16(uint32_t index)
{
    uint32_t x = mix32(index + 0x85ebca6bU);
    return (int16_t)((int)(x % 257U) - 128);
}

static int16_t sat16(int32_t value)
{
    if (value > 32767)
    {
        return 32767;
    }
    if (value < -32768)
    {
        return -32768;
    }
    return (int16_t)value;
}

static uint32_t isqrt32(uint32_t value)
{
    uint32_t root = 0;
    uint32_t bit = 1UL << 30;
    while (bit > value)
    {
        bit >>= 2;
    }
    while (bit != 0)
    {
        if (value >= root + bit)
        {
            value -= root + bit;
            root = (root >> 1) + bit;
        }
        else
        {
            root >>= 1;
        }
        bit >>= 2;
    }
    return root;
}

static uint32_t checksum16(const int16_t *data, int n, uint32_t seed)
{
    uint32_t h = seed;
    for (int i = 0; i < n; i++)
    {
        h ^= (uint16_t)data[i];
        h *= 16777619U;
        h ^= h >> 13;
    }
    return h;
}

static void matvec_i8_i16(int16_t *out, const int16_t *in,
                          const int8_t *weight, int rows, int cols, int shift)
{
    for (int row = 0; row < rows; row++)
    {
        int32_t acc = 0;
        const int8_t *wrow = weight + row * cols;
        for (int col = 0; col < cols; col++)
        {
            acc += (int32_t)in[col] * wrow[col];
        }
        out[row] = sat16(acc >> shift);
    }
}

static void rmsnorm_i16(int16_t *out, const int16_t *in, const int16_t *weight, int n)
{
    uint32_t ss = 0;
    for (int i = 0; i < n; i++)
    {
        int32_t x = in[i];
        ss += (uint32_t)((x * x) >> 4);
    }
    uint32_t rms = isqrt32(ss / (uint32_t)n + 1U) + 1U;
    for (int i = 0; i < n; i++)
    {
        int32_t scaled = ((int32_t)in[i] * weight[i] * 16) / (int32_t)rms;
        out[i] = sat16(scaled >> 7);
    }
}

static void softmax_q15(uint16_t *prob, const int32_t *score, int n)
{
    static const uint16_t exp_lut[17] = {
        1, 1, 2, 3, 4, 6, 8, 11, 16, 23, 32, 45, 64, 91, 128, 181, 256};
    int32_t max_score = score[0];
    for (int i = 1; i < n; i++)
    {
        if (score[i] > max_score)
        {
            max_score = score[i];
        }
    }

    uint32_t sum = 0;
    for (int i = 0; i < n; i++)
    {
        int delta = (int)(score[i] - max_score);
        if (delta < -16)
        {
            prob[i] = 0;
        }
        else if (delta > 0)
        {
            prob[i] = 256;
        }
        else
        {
            prob[i] = exp_lut[delta + 16];
        }
        sum += prob[i];
    }
    if (sum == 0)
    {
        sum = 1;
    }
    for (int i = 0; i < n; i++)
    {
        prob[i] = (uint16_t)(((uint32_t)prob[i] << 15) / sum);
    }
}

static int8_t op_a[16 * 32];
static int8_t op_b[16 * 32];
static int32_t op_c[16 * 16];
static int16_t op_q[SEQ_LEN * DIM];
static int16_t op_k[SEQ_LEN * DIM];
static int16_t op_v[SEQ_LEN * DIM];
static int16_t op_out[SEQ_LEN * DIM];
static int16_t op_norm_in[DIM];
static int16_t op_norm_out[DIM];
static int16_t op_norm_w[DIM];
static int16_t op_param[512];
static int16_t op_moment[512];
static int16_t op_vel[512];
static int16_t op_grad[512];

static void init_operator_tensors(void)
{
    for (int i = 0; i < 16 * 32; i++)
    {
        op_a[i] = weight8((uint32_t)i);
        op_b[i] = weight8((uint32_t)i + 1000U);
    }
    for (int i = 0; i < SEQ_LEN * DIM; i++)
    {
        op_q[i] = weight16((uint32_t)i + 2000U);
        op_k[i] = weight16((uint32_t)i + 3000U);
        op_v[i] = weight16((uint32_t)i + 4000U);
    }
    for (int i = 0; i < DIM; i++)
    {
        op_norm_in[i] = weight16((uint32_t)i + 5000U);
        op_norm_w[i] = (int16_t)(128 + (i % 9));
    }
    for (int i = 0; i < 512; i++)
    {
        op_param[i] = weight16((uint32_t)i + 6000U);
        op_moment[i] = weight16((uint32_t)i + 7000U) >> 2;
        op_vel[i] = (int16_t)(32 + (i & 31));
        op_grad[i] = weight16((uint32_t)i + 8000U) >> 1;
    }
}

static uint32_t bench_matmul(void)
{
    for (int iter = 0; iter < LLM_OP_ITERS; iter++)
    {
        for (int row = 0; row < 16; row++)
        {
            for (int col = 0; col < 16; col++)
            {
                int32_t acc = op_c[row * 16 + col] >> 4;
                for (int k = 0; k < 32; k++)
                {
                    acc += (int32_t)op_a[row * 32 + k] * op_b[col * 32 + k];
                }
                op_c[row * 16 + col] = acc;
            }
        }
    }
    uint32_t h = 2166136261U;
    for (int i = 0; i < 16 * 16; i++)
    {
        h = (h ^ (uint32_t)op_c[i]) * 16777619U;
    }
    return h;
}

static uint32_t bench_attention(void)
{
    int32_t scores[SEQ_LEN];
    uint16_t prob[SEQ_LEN];
    for (int iter = 0; iter < LLM_OP_ITERS; iter++)
    {
        for (int head = 0; head < N_HEADS; head++)
        {
            int base = head * HEAD_DIM;
            for (int tq = 0; tq < SEQ_LEN; tq++)
            {
                for (int tk = 0; tk <= tq; tk++)
                {
                    int32_t acc = 0;
                    for (int d = 0; d < HEAD_DIM; d++)
                    {
                        acc += (int32_t)op_q[tq * DIM + base + d] * op_k[tk * DIM + base + d];
                    }
                    scores[tk] = acc >> 11;
                }
                softmax_q15(prob, scores, tq + 1);
                for (int d = 0; d < HEAD_DIM; d++)
                {
                    int32_t acc = 0;
                    for (int tk = 0; tk <= tq; tk++)
                    {
                        acc += (int32_t)prob[tk] * op_v[tk * DIM + base + d];
                    }
                    op_out[tq * DIM + base + d] = sat16(acc >> 15);
                }
            }
        }
    }
    return checksum16(op_out, SEQ_LEN * DIM, 0x12345678U);
}

static uint32_t bench_rmsnorm(void)
{
    for (int iter = 0; iter < LLM_OP_ITERS * 64; iter++)
    {
        rmsnorm_i16(op_norm_out, op_norm_in, op_norm_w, DIM);
        for (int i = 0; i < DIM; i++)
        {
            op_norm_in[i] = sat16(op_norm_in[i] + (op_norm_out[(i + 7) & (DIM - 1)] >> 5));
        }
    }
    return checksum16(op_norm_out, DIM, 0x90abcdefU);
}

static uint32_t bench_adamw(void)
{
    for (int iter = 0; iter < LLM_OP_ITERS * 8; iter++)
    {
        for (int i = 0; i < 512; i++)
        {
            int32_t grad = op_grad[i] + ((int32_t)op_param[i] >> 6);
            op_moment[i] = sat16(((int32_t)op_moment[i] * 9 + grad) / 10);
            op_vel[i] = sat16(((int32_t)op_vel[i] * 31 + ((grad * grad) >> 8)) / 32);
            op_param[i] = sat16((int32_t)op_param[i] - (op_moment[i] >> 4) - (op_param[i] >> 10));
        }
    }
    return checksum16(op_param, 512, 0xfeed1234U);
}

static int run_ops(void)
{
    init_operator_tensors();
    printf("RLLMBench operator suite: iters=%d dim=%d seq=%d\n", LLM_OP_ITERS, DIM, SEQ_LEN);
    bench_mode_begin("ops", "kernel-suite");

    rllmbench_time_us_t start = rllmbench_get_time_us();
    uint32_t sum = bench_matmul();
    bench_record("q8_matmul", "kernel", "mac", MATMUL_WORK, rllmbench_get_time_us() - start, sum);
    g_sink ^= sum;

    start = rllmbench_get_time_us();
    sum = bench_attention();
    bench_record("attention", "kernel", "attn_mac", ATTENTION_WORK, rllmbench_get_time_us() - start, sum);
    g_sink ^= sum;

    start = rllmbench_get_time_us();
    sum = bench_rmsnorm();
    bench_record("rmsnorm", "kernel", "element", RMSNORM_WORK, rllmbench_get_time_us() - start, sum);
    g_sink ^= sum;

    start = rllmbench_get_time_us();
    sum = bench_adamw();
    bench_record("adamw", "kernel", "param", ADAMW_WORK, rllmbench_get_time_us() - start, sum);
    g_sink ^= sum;

    bench_mode_end("ops");
    return 0;
}

static int8_t tok_embed[VOCAB * DIM];
static int16_t norm_att[N_LAYERS * DIM];
static int16_t norm_ffn[N_LAYERS * DIM];
static int16_t norm_final[DIM];
static int8_t wq[N_LAYERS * DIM * DIM];
static int8_t wk[N_LAYERS * DIM * DIM];
static int8_t wv[N_LAYERS * DIM * DIM];
static int8_t wo[N_LAYERS * DIM * DIM];
static int8_t w1[N_LAYERS * HIDDEN * DIM];
static int8_t w2[N_LAYERS * DIM * HIDDEN];
static int8_t w3[N_LAYERS * HIDDEN * DIM];
static int16_t key_cache[N_LAYERS * SEQ_LEN * DIM];
static int16_t value_cache[N_LAYERS * SEQ_LEN * DIM];
static int16_t xbuf[DIM], xb[DIM], xb2[DIM], qbuf[DIM], kbuf[DIM], vbuf[DIM];
static int16_t hb[HIDDEN], hb2[HIDDEN];
static int32_t logits[VOCAB];

static void init_infer_model(void)
{
    for (int i = 0; i < VOCAB * DIM; i++)
    {
        tok_embed[i] = weight8((uint32_t)i + 11000U);
    }
    for (int i = 0; i < N_LAYERS * DIM; i++)
    {
        norm_att[i] = (int16_t)(128 + (i % 13));
        norm_ffn[i] = (int16_t)(128 + (i % 11));
    }
    for (int i = 0; i < DIM; i++)
    {
        norm_final[i] = (int16_t)(128 + (i % 7));
    }
    for (int i = 0; i < N_LAYERS * DIM * DIM; i++)
    {
        wq[i] = weight8((uint32_t)i + 12000U);
        wk[i] = weight8((uint32_t)i + 13000U);
        wv[i] = weight8((uint32_t)i + 14000U);
        wo[i] = weight8((uint32_t)i + 15000U);
    }
    for (int i = 0; i < N_LAYERS * HIDDEN * DIM; i++)
    {
        w1[i] = weight8((uint32_t)i + 16000U);
        w3[i] = weight8((uint32_t)i + 17000U);
    }
    for (int i = 0; i < N_LAYERS * DIM * HIDDEN; i++)
    {
        w2[i] = weight8((uint32_t)i + 18000U);
    }
    for (int i = 0; i < N_LAYERS * SEQ_LEN * DIM; i++)
    {
        key_cache[i] = 0;
        value_cache[i] = 0;
    }
}

static void attention_one_layer(int layer, int pos)
{
    int32_t scores[SEQ_LEN];
    uint16_t prob[SEQ_LEN];
    int layer_off = layer * SEQ_LEN * DIM;

    for (int i = 0; i < DIM; i++)
    {
        key_cache[layer_off + pos * DIM + i] = kbuf[i];
        value_cache[layer_off + pos * DIM + i] = vbuf[i];
        xb2[i] = 0;
    }
    for (int head = 0; head < N_HEADS; head++)
    {
        int base = head * HEAD_DIM;
        for (int t = 0; t <= pos; t++)
        {
            int32_t acc = 0;
            for (int d = 0; d < HEAD_DIM; d++)
            {
                acc += (int32_t)qbuf[base + d] * key_cache[layer_off + t * DIM + base + d];
            }
            scores[t] = acc >> 12;
        }
        softmax_q15(prob, scores, pos + 1);
        for (int d = 0; d < HEAD_DIM; d++)
        {
            int32_t acc = 0;
            for (int t = 0; t <= pos; t++)
            {
                acc += (int32_t)prob[t] * value_cache[layer_off + t * DIM + base + d];
            }
            xb2[base + d] = sat16(acc >> 15);
        }
    }
}

static int transformer_step(int token, int pos)
{
    for (int i = 0; i < DIM; i++)
    {
        xbuf[i] = (int16_t)tok_embed[token * DIM + i] << 4;
    }
    for (int layer = 0; layer < N_LAYERS; layer++)
    {
        int dim_off = layer * DIM;
        int mat_off = layer * DIM * DIM;
        int ffn1_off = layer * HIDDEN * DIM;
        int ffn2_off = layer * DIM * HIDDEN;

        rmsnorm_i16(xb, xbuf, norm_att + dim_off, DIM);
        matvec_i8_i16(qbuf, xb, wq + mat_off, DIM, DIM, 8);
        matvec_i8_i16(kbuf, xb, wk + mat_off, DIM, DIM, 8);
        matvec_i8_i16(vbuf, xb, wv + mat_off, DIM, DIM, 8);
        attention_one_layer(layer, pos);
        matvec_i8_i16(xb, xb2, wo + mat_off, DIM, DIM, 8);
        for (int i = 0; i < DIM; i++)
        {
            xbuf[i] = sat16((int32_t)xbuf[i] + xb[i]);
        }
        rmsnorm_i16(xb, xbuf, norm_ffn + dim_off, DIM);
        matvec_i8_i16(hb, xb, w1 + ffn1_off, HIDDEN, DIM, 8);
        matvec_i8_i16(hb2, xb, w3 + ffn1_off, HIDDEN, DIM, 8);
        for (int i = 0; i < HIDDEN; i++)
        {
            int16_t gate = hb2[i] > 0 ? hb2[i] : (hb2[i] >> 3);
            hb[i] = sat16(((int32_t)hb[i] * gate) >> 8);
        }
        matvec_i8_i16(xb, hb, w2 + ffn2_off, DIM, HIDDEN, 8);
        for (int i = 0; i < DIM; i++)
        {
            xbuf[i] = sat16((int32_t)xbuf[i] + xb[i]);
        }
    }

    rmsnorm_i16(xb, xbuf, norm_final, DIM);
    int best = 0;
    int32_t best_score = -2147483647 - 1;
    for (int v = 0; v < VOCAB; v++)
    {
        int32_t acc = 0;
        for (int i = 0; i < DIM; i++)
        {
            acc += (int32_t)xb[i] * tok_embed[v * DIM + i];
        }
        logits[v] = acc;
        if (acc > best_score)
        {
            best_score = acc;
            best = v;
        }
    }
    return best;
}

static int run_infer(void)
{
    int tokens = LLM_GEN_TOKENS;
    if (tokens > SEQ_LEN)
    {
        tokens = SEQ_LEN;
    }
    init_infer_model();
    printf("RLLMBench e2e inference: layers=%d dim=%d heads=%d seq=%d vocab=%d tokens=%d repeats=%d\n",
           N_LAYERS, DIM, N_HEADS, SEQ_LEN, VOCAB, tokens, LLM_INFER_REPEATS);
    bench_mode_begin("infer", "e2e");

    uint64_t attention_work = (uint64_t)N_LAYERS * ((uint64_t)tokens * (tokens + 1ULL) / 2ULL) * 2ULL * DIM;
    uint64_t layer_work = (uint64_t)tokens * N_LAYERS * (4ULL * DIM * DIM + 3ULL * HIDDEN * DIM);
    uint64_t output_work = (uint64_t)tokens * VOCAB * DIM;
    uint64_t infer_work = (attention_work + layer_work + output_work) * (uint64_t)LLM_INFER_REPEATS;

    rllmbench_time_us_t start = rllmbench_get_time_us();
    int token = 7;
    uint32_t checksum = 0x31415926U;
    for (int rep = 0; rep < LLM_INFER_REPEATS; rep++)
    {
        for (int pos = 0; pos < tokens; pos++)
        {
            token = transformer_step(token, pos);
            checksum = mix32(checksum ^ (uint32_t)token ^ (uint32_t)logits[token]);
        }
    }
    bench_record("e2e_infer", "e2e", "work", infer_work, rllmbench_get_time_us() - start, checksum);
    printf("last_token=%d logit=%d\n", token, (int)logits[token]);
    g_sink ^= checksum;
    bench_mode_end("infer");
    return 0;
}

static int16_t tr_wte[TRAIN_V * TRAIN_C];
static int16_t tr_wpe[TRAIN_T * TRAIN_C];
static int16_t tr_wout[TRAIN_V * TRAIN_C];
static int16_t tr_bias[TRAIN_V];
static int16_t tr_x[TRAIN_C];
static int32_t tr_logits[TRAIN_V];
static uint16_t tr_prob[TRAIN_V];
static int16_t tr_grad_x[TRAIN_C];
static const uint8_t train_stream[TRAIN_B * TRAIN_T + 1] = {
    3, 5, 8, 13, 21, 2, 7, 11,
    18, 29, 15, 4, 9, 14, 23, 31,
    3};

static void init_train_model(void)
{
    for (int i = 0; i < TRAIN_V * TRAIN_C; i++)
    {
        tr_wte[i] = weight16((uint32_t)i + 21000U) >> 1;
        tr_wout[i] = weight16((uint32_t)i + 22000U) >> 1;
    }
    for (int i = 0; i < TRAIN_T * TRAIN_C; i++)
    {
        tr_wpe[i] = weight16((uint32_t)i + 23000U) >> 2;
    }
    for (int i = 0; i < TRAIN_V; i++)
    {
        tr_bias[i] = weight16((uint32_t)i + 24000U) >> 3;
    }
}

static uint32_t train_one_step(int step)
{
    uint32_t loss_proxy = 0;
    uint32_t checksum = 0x27182818U ^ (uint32_t)step;
    for (int b = 0; b < TRAIN_B; b++)
    {
        for (int t = 0; t < TRAIN_T; t++)
        {
            int stream_pos = (b * TRAIN_T + t + step) % (TRAIN_B * TRAIN_T);
            int token = train_stream[stream_pos] % TRAIN_V;
            int target = train_stream[stream_pos + 1] % TRAIN_V;

            for (int c = 0; c < TRAIN_C; c++)
            {
                tr_x[c] = sat16((int32_t)tr_wte[token * TRAIN_C + c] + tr_wpe[t * TRAIN_C + c]);
                tr_grad_x[c] = 0;
            }
            for (int v = 0; v < TRAIN_V; v++)
            {
                int32_t acc = (int32_t)tr_bias[v] << 8;
                for (int c = 0; c < TRAIN_C; c++)
                {
                    acc += (int32_t)tr_wout[v * TRAIN_C + c] * tr_x[c];
                }
                tr_logits[v] = acc >> 9;
            }
            softmax_q15(tr_prob, tr_logits, TRAIN_V);
            loss_proxy += 32768U - tr_prob[target];

            for (int v = 0; v < TRAIN_V; v++)
            {
                int32_t grad = (int32_t)tr_prob[v] - (v == target ? 32768 : 0);
                for (int c = 0; c < TRAIN_C; c++)
                {
                    int32_t old_w = tr_wout[v * TRAIN_C + c];
                    int32_t dw = (grad * tr_x[c]) >> 15;
                    tr_wout[v * TRAIN_C + c] = sat16(old_w - (dw >> 5));
                    tr_grad_x[c] = sat16((int32_t)tr_grad_x[c] + ((grad * old_w) >> 15));
                }
                tr_bias[v] = sat16((int32_t)tr_bias[v] - (grad >> 9));
            }
            for (int c = 0; c < TRAIN_C; c++)
            {
                int32_t dx = tr_grad_x[c] >> 4;
                tr_wte[token * TRAIN_C + c] = sat16((int32_t)tr_wte[token * TRAIN_C + c] - dx);
                tr_wpe[t * TRAIN_C + c] = sat16((int32_t)tr_wpe[t * TRAIN_C + c] - (dx >> 1));
            }
            checksum = mix32(checksum ^ loss_proxy ^ (uint32_t)tr_wout[target * TRAIN_C]);
        }
    }
    printf("RLLMBENCH_TRACE name=train_step step=%d loss_proxy=%u checksum=0x%08x\n",
           step, (unsigned int)loss_proxy, (unsigned int)checksum);
    return checksum ^ loss_proxy;
}

static int run_train(void)
{
    init_train_model();
    printf("RLLMBench e2e train: B=%d T=%d C=%d V=%d steps=%d\n",
           TRAIN_B, TRAIN_T, TRAIN_C, TRAIN_V, LLM_TRAIN_STEPS);
    bench_mode_begin("train", "e2e");

    uint64_t train_items = (uint64_t)LLM_TRAIN_STEPS * TRAIN_B * TRAIN_T;
    uint64_t train_work = train_items * (3ULL * TRAIN_V * TRAIN_C + TRAIN_C);

    rllmbench_time_us_t start = rllmbench_get_time_us();
    uint32_t checksum = 0xabcdef01U;
    for (int step = 0; step < LLM_TRAIN_STEPS; step++)
    {
        checksum = mix32(checksum ^ train_one_step(step));
    }
    bench_record("e2e_train", "e2e", "work", train_work, rllmbench_get_time_us() - start, checksum);
    g_sink ^= checksum;
    bench_mode_end("train");
    return 0;
}

int main(void)
{
    int rc = 0;
    bench_header();
#if LLM_BENCH_MODE == LLM_MODE_OPS
    rc |= run_ops();
#elif LLM_BENCH_MODE == LLM_MODE_INFER
    rc |= run_infer();
#elif LLM_BENCH_MODE == LLM_MODE_TRAIN
    rc |= run_train();
#else
    rc |= run_ops();
    rc |= run_infer();
    rc |= run_train();
#endif
    printf("llm_bench_done sink=0x%08x\n", (unsigned int)g_sink);
    return rc;
}