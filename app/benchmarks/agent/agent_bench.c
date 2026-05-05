/*
 * RAgentBench: agentic-workload CPU benchmark for the Raptor RISC-V core.
 *
 * Goal: measure CPU/SoC behavior under workloads typical of LLM-agent
 * runtimes (tool dispatch, retrieval-augmented scoring, multi-turn policy
 * loops), NOT to evaluate LLM agent capability. All inputs are deterministic
 * and synthesized from fixed seeds; no malloc, no FP, no external I/O.
 *
 * Design heritage:
 *   - Tool dispatch loop      : Berkeley Function Calling Leaderboard (BFCL v3)
 *   - Multi-turn policy loop  : tau-bench / TheAgentCompany subcheckpoints
 *   - Step-limit force-stop   : BFCL augmented inference loop (max 20 steps)
 *   - Reproducibility framing : MLCommons / Farama project standards
 *
 * Three modes: tools / rag / workflow. Headline metric: score_per_sec.
 */
#include <stddef.h>
#include <stdint.h>
#include "ragentbench_port.h"

#if defined(RAPT_LITEX_BAREMETAL)
int printf(const char *fmt, ...);
#else
#include <stdio.h>
#endif

#define AGENT_MODE_ALL 0
#define AGENT_MODE_TOOLS 1
#define AGENT_MODE_RAG 2
#define AGENT_MODE_WORKFLOW 3

#ifndef AGENT_BENCH_MODE
#define AGENT_BENCH_MODE AGENT_MODE_ALL
#endif
#ifndef AGENT_TOOL_ITERS
#define AGENT_TOOL_ITERS 16
#endif
#ifndef AGENT_RAG_QUERIES
#define AGENT_RAG_QUERIES 16
#endif
#ifndef AGENT_FLOW_TURNS
#define AGENT_FLOW_TURNS 16
#endif
#ifndef AGENT_ARCH_STRING
#define AGENT_ARCH_STRING "unknown"
#endif
#ifndef RAGENTBENCH_TARGET_STRING
#if defined(RAPT_LITEX_BAREMETAL)
#define RAGENTBENCH_TARGET_STRING "litex-baremetal"
#elif defined(RAGENTBENCH_NATIVE)
#define RAGENTBENCH_TARGET_STRING "native"
#else
#define RAGENTBENCH_TARGET_STRING "riscv-pk"
#endif
#endif

#if defined(__riscv_xlen)
#define AGENT_TARGET_XLEN __riscv_xlen
#else
#define AGENT_TARGET_XLEN ((int)(sizeof(void *) * 8))
#endif

#define AGENT_STR_IMPL(x) #x
#define AGENT_STR(x) AGENT_STR_IMPL(x)
#define AGENT_PROFILE \
    "tools" AGENT_STR(AGENT_TOOL_ITERS) "-rag" AGENT_STR(AGENT_RAG_QUERIES) "-flow" AGENT_STR(AGENT_FLOW_TURNS)

/* -------------------------------------------------------------------------- */
/* Mode-shared scaffolding (mirrors RLLMBench format).                        */
/* -------------------------------------------------------------------------- */

#define TOOL_COUNT 16
#define TOOL_CALLS_PER_ITER 32
#define INBOX_SIZE 32
#define FILES_SIZE 32
#define CALENDAR_SIZE 16
#define COUNTERS_SIZE 16

#define DOC_COUNT 32
#define DOC_LEN 64
#define VOCAB_BITS 6
#define VOCAB_MASK ((1U << VOCAB_BITS) - 1U)
#define QUERY_LEN 12
#define TOPK 4

#define FLOW_TASKS 4     /* concurrent ticket-style tasks */
#define FLOW_MAX_STEPS 8 /* per-turn nested step cap (BFCL-style)     */
#define FLOW_TOOL_COUNT 8

#define TOOL_WORK_PER_CALL 3ULL /* parse + dispatch + state update */
#define RAG_WORK_PER_QUERY ((uint64_t)DOC_COUNT * DOC_LEN + DOC_COUNT + TOPK)
#define FLOW_WORK_PER_TURN ((uint64_t)FLOW_MAX_STEPS * 4ULL) /* observe+policy+act+check */

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
    printf("RAgentBench 0.1 (RISC-V agentic-workload CPU benchmark)\n");
    printf("RAGENTBENCH_INFO version=0.1 profile=%s arch=%s xlen=%d target=%s time_unit=s score=score_per_sec\n",
           AGENT_PROFILE, AGENT_ARCH_STRING, AGENT_TARGET_XLEN, RAGENTBENCH_TARGET_STRING);
}

static void bench_mode_begin(const char *mode, const char *kind)
{
    g_mode_work = 0;
    g_mode_time_us = 0;
    g_mode_checksum = 0x811c9dc5U;
    printf("RAGENTBENCH_BEGIN mode=%s kind=%s profile=%s\n", mode, kind, AGENT_PROFILE);
    printf("RAGENTBENCH_CONFIG mode=%s arch=%s xlen=%d target=%s tool_iters=%d rag_queries=%d flow_turns=%d "
           "tools=%d docs=%d doc_len=%d topk=%d flow_max_steps=%d\n",
           mode, AGENT_ARCH_STRING, AGENT_TARGET_XLEN, RAGENTBENCH_TARGET_STRING,
           AGENT_TOOL_ITERS, AGENT_RAG_QUERIES, AGENT_FLOW_TURNS,
           TOOL_COUNT, DOC_COUNT, DOC_LEN, TOPK, FLOW_MAX_STEPS);
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
    printf("RAGENTBENCH_RESULT name=%s class=%s unit=%s work=%llu seconds=%llu.%06llu score_per_sec=%llu checksum=0x%08x\n",
           name, kind, unit, (unsigned long long)work,
           (unsigned long long)seconds_whole, (unsigned long long)seconds_fraction,
           (unsigned long long)score_per_sec, (unsigned int)checksum);
}

static void bench_mode_end(const char *mode)
{
    uint64_t seconds_whole, seconds_fraction;
    uint64_t score_per_sec = bench_score_per_sec(g_mode_work, g_mode_time_us);
    split_seconds(g_mode_time_us, &seconds_whole, &seconds_fraction);
    printf("RAGENTBENCH_SCORE mode=%s work=%llu seconds=%llu.%06llu score_per_sec=%llu checksum=0x%08x\n",
           mode, (unsigned long long)g_mode_work,
           (unsigned long long)seconds_whole, (unsigned long long)seconds_fraction,
           (unsigned long long)score_per_sec, (unsigned int)g_mode_checksum);
    printf("RAGENTBENCH_END mode=%s status=PASS sink=0x%08x\n", mode, (unsigned int)g_sink);
}

/* -------------------------------------------------------------------------- */
/* Mode 1: tools — function-calling dispatch + small state mutation.          */
/* -------------------------------------------------------------------------- */

static int16_t tool_inbox[INBOX_SIZE];
static int16_t tool_files[FILES_SIZE];
static int16_t tool_calendar[CALENDAR_SIZE];
static int16_t tool_counters[COUNTERS_SIZE];
static uint32_t tool_dispatch_count[TOOL_COUNT];
static uint32_t tool_error_count;

static void init_tool_state(void)
{
    for (int i = 0; i < INBOX_SIZE; i++)
    {
        tool_inbox[i] = (int16_t)(mix32((uint32_t)i + 1U) & 0x3FF);
    }
    for (int i = 0; i < FILES_SIZE; i++)
    {
        tool_files[i] = (int16_t)(mix32((uint32_t)i + 100U) & 0x3FF);
    }
    for (int i = 0; i < CALENDAR_SIZE; i++)
    {
        tool_calendar[i] = (int16_t)(mix32((uint32_t)i + 200U) & 0xFF);
    }
    for (int i = 0; i < COUNTERS_SIZE; i++)
    {
        tool_counters[i] = 0;
    }
    for (int i = 0; i < TOOL_COUNT; i++)
    {
        tool_dispatch_count[i] = 0;
    }
    tool_error_count = 0;
}

/*
 * Each "tool call" is encoded in a 32-bit word produced by mix32:
 *   bits[3:0]   tool id (with one out-of-range slot to exercise error path)
 *   bits[11:4]  arg0
 *   bits[19:12] arg1
 *   bits[27:20] arg2
 *   bits[31:28] reserved
 */
static uint32_t tool_call_dispatch(uint32_t encoded, uint32_t *checksum)
{
    uint32_t tid = encoded & 0x1FU; /* 0..31; ids >= TOOL_COUNT are invalid */
    uint32_t a0 = (encoded >> 4) & 0xFFU;
    uint32_t a1 = (encoded >> 12) & 0xFFU;
    uint32_t a2 = (encoded >> 20) & 0xFFU;
    int idx_in = (int)(a0 & (INBOX_SIZE - 1));
    int idx_fi = (int)(a0 & (FILES_SIZE - 1));
    int idx_ca = (int)(a0 & (CALENDAR_SIZE - 1));
    int idx_ct = (int)(a1 & (COUNTERS_SIZE - 1));
    int32_t value = (int32_t)((int8_t)a1) + (int32_t)((int8_t)a2);
    uint32_t result = 0;

    if (tid >= TOOL_COUNT)
    {
        /* "Missing tool" branch — BFCL-style augmented category. */
        tool_error_count++;
        result = 0xDEADBEEFU ^ encoded;
        *checksum = checksum_mix(*checksum, result);
        return result;
    }

    tool_dispatch_count[tid]++;

    switch (tid)
    {
    case 0: /* inbox.read */
        result = (uint32_t)tool_inbox[idx_in];
        break;
    case 1: /* inbox.write */
        tool_inbox[idx_in] = (int16_t)(tool_inbox[idx_in] + value);
        result = (uint32_t)tool_inbox[idx_in];
        break;
    case 2: /* inbox.delete */
        tool_inbox[idx_in] = 0;
        result = (uint32_t)idx_in;
        break;
    case 3: /* files.read */
        result = (uint32_t)tool_files[idx_fi];
        break;
    case 4: /* files.append */
        tool_files[idx_fi] = (int16_t)(tool_files[idx_fi] ^ (int16_t)a2);
        result = (uint32_t)tool_files[idx_fi];
        break;
    case 5: /* files.move */
    {
        int dst = (int)(a2 & (FILES_SIZE - 1));
        int16_t tmp = tool_files[idx_fi];
        tool_files[idx_fi] = tool_files[dst];
        tool_files[dst] = tmp;
        result = (uint32_t)(uint16_t)tmp;
        break;
    }
    case 6: /* calendar.add */
        tool_calendar[idx_ca] = (int16_t)(tool_calendar[idx_ca] + (int8_t)a1);
        result = (uint32_t)tool_calendar[idx_ca];
        break;
    case 7: /* calendar.cancel */
        tool_calendar[idx_ca] = 0;
        result = (uint32_t)idx_ca;
        break;
    case 8: /* counters.inc */
        tool_counters[idx_ct]++;
        result = (uint32_t)tool_counters[idx_ct];
        break;
    case 9: /* counters.dec */
        tool_counters[idx_ct]--;
        result = (uint32_t)tool_counters[idx_ct];
        break;
    case 10: /* search.inbox */
    {
        int16_t needle = (int16_t)a2;
        uint32_t hits = 0;
        for (int i = 0; i < INBOX_SIZE; i++)
        {
            hits += (uint32_t)((tool_inbox[i] & 0xFF) == needle);
        }
        result = hits;
        break;
    }
    case 11: /* search.files */
    {
        int16_t needle = (int16_t)a2;
        uint32_t hits = 0;
        for (int i = 0; i < FILES_SIZE; i++)
        {
            hits += (uint32_t)((tool_files[i] & 0xFF) == needle);
        }
        result = hits;
        break;
    }
    case 12: /* math.add */
        result = (uint32_t)(int32_t)(value + tool_counters[idx_ct]);
        break;
    case 13: /* math.mul */
        result = (uint32_t)(int32_t)((int32_t)(int8_t)a1 * (int32_t)(int8_t)a2);
        break;
    case 14: /* validate.arg (intentionally rejects half its inputs) */
        if ((a0 ^ a1 ^ a2) & 0x1U)
        {
            tool_error_count++;
            result = 0xBADC0DEU;
        }
        else
        {
            result = a0 + a1 + a2;
        }
        break;
    case 15: /* commit.batch — touches every state region */
    default:
        tool_inbox[idx_in] = (int16_t)(tool_inbox[idx_in] + 1);
        tool_files[idx_fi] = (int16_t)(tool_files[idx_fi] - 1);
        tool_calendar[idx_ca] = (int16_t)(tool_calendar[idx_ca] ^ 0x55);
        tool_counters[idx_ct]++;
        result = (uint32_t)tool_counters[idx_ct];
        break;
    }

    *checksum = checksum_mix(*checksum, result ^ encoded);
    return result;
}

static uint32_t bench_tool_dispatch(void)
{
    uint32_t checksum = 0xCAFEBABEU;
    uint32_t seed = 0x600D5EEDU;
    for (int iter = 0; iter < AGENT_TOOL_ITERS; iter++)
    {
        for (int call = 0; call < TOOL_CALLS_PER_ITER; call++)
        {
            seed = mix32(seed + (uint32_t)call + ((uint32_t)iter << 8));
            (void)tool_call_dispatch(seed, &checksum);
        }
    }
    return checksum ^ tool_error_count;
}

static int run_tools(void)
{
    init_tool_state();
    printf("RAgentBench tools suite: iters=%d calls_per_iter=%d tools=%d\n",
           AGENT_TOOL_ITERS, TOOL_CALLS_PER_ITER, TOOL_COUNT);
    bench_mode_begin("tools", "agentic-dispatch");

    uint64_t calls = (uint64_t)AGENT_TOOL_ITERS * TOOL_CALLS_PER_ITER;
    uint64_t work = calls * TOOL_WORK_PER_CALL;

    ragentbench_time_us_t start = ragentbench_get_time_us();
    uint32_t cs = bench_tool_dispatch();
    bench_record("tool_dispatch", "agentic-dispatch", "call",
                 work, ragentbench_get_time_us() - start, cs);
    g_sink ^= cs;

    bench_mode_end("tools");
    return 0;
}

/* -------------------------------------------------------------------------- */
/* Mode 2: rag — retrieval scoring + top-k selection over a synthetic corpus. */
/* -------------------------------------------------------------------------- */

static uint8_t rag_corpus[DOC_COUNT * DOC_LEN];
static uint16_t rag_doc_freq[1U << VOCAB_BITS];
static uint16_t rag_doc_len[DOC_COUNT];
static int32_t rag_scores[DOC_COUNT];
static uint8_t rag_query[QUERY_LEN];
static int32_t rag_topk_scores[TOPK];
static int16_t rag_topk_ids[TOPK];

static void init_rag_corpus(void)
{
    for (int v = 0; v < (1 << VOCAB_BITS); v++)
    {
        rag_doc_freq[v] = 0;
    }
    for (int d = 0; d < DOC_COUNT; d++)
    {
        uint32_t s = mix32((uint32_t)d + 0xA1B2C3D4U);
        rag_doc_len[d] = DOC_LEN;
        uint8_t seen[1U << VOCAB_BITS] = {0};
        for (int t = 0; t < DOC_LEN; t++)
        {
            s = mix32(s + (uint32_t)t);
            uint8_t tok = (uint8_t)(s & VOCAB_MASK);
            rag_corpus[d * DOC_LEN + t] = tok;
            if (!seen[tok])
            {
                seen[tok] = 1;
                rag_doc_freq[tok]++;
            }
        }
    }
}

static void rag_make_query(uint32_t qid)
{
    uint32_t s = mix32(qid + 0x5A5A5A5AU);
    for (int i = 0; i < QUERY_LEN; i++)
    {
        s = mix32(s + (uint32_t)i);
        rag_query[i] = (uint8_t)(s & VOCAB_MASK);
    }
}

/* BM25-lite: integer term-frequency scoring with IDF approximation. */
static void rag_score_corpus(void)
{
    for (int d = 0; d < DOC_COUNT; d++)
    {
        rag_scores[d] = 0;
    }
    for (int q = 0; q < QUERY_LEN; q++)
    {
        uint8_t qtok = rag_query[q];
        uint16_t df = rag_doc_freq[qtok];
        if (df == 0)
        {
            continue;
        }
        /* idf approximation: scaled (DOC_COUNT - df + 1) */
        int32_t idf = (int32_t)(DOC_COUNT - df + 1);
        for (int d = 0; d < DOC_COUNT; d++)
        {
            const uint8_t *doc = rag_corpus + d * DOC_LEN;
            int32_t tf = 0;
            for (int t = 0; t < DOC_LEN; t++)
            {
                tf += (int32_t)(doc[t] == qtok);
            }
            /* BM25-lite: idf * tf * (k1+1) / (tf + k1) with k1=1 */
            int32_t num = idf * tf * 2;
            int32_t den = tf + 1;
            rag_scores[d] += num / den;
        }
    }
}

static void rag_topk_select(void)
{
    for (int k = 0; k < TOPK; k++)
    {
        rag_topk_scores[k] = -2147483647 - 1;
        rag_topk_ids[k] = -1;
    }
    for (int d = 0; d < DOC_COUNT; d++)
    {
        int32_t s = rag_scores[d];
        if (s <= rag_topk_scores[TOPK - 1])
        {
            continue;
        }
        int pos = TOPK - 1;
        while (pos > 0 && rag_topk_scores[pos - 1] < s)
        {
            rag_topk_scores[pos] = rag_topk_scores[pos - 1];
            rag_topk_ids[pos] = rag_topk_ids[pos - 1];
            pos--;
        }
        rag_topk_scores[pos] = s;
        rag_topk_ids[pos] = (int16_t)d;
    }
}

static uint32_t bench_rag(void)
{
    uint32_t checksum = 0xFEEDFACEU;
    for (int q = 0; q < AGENT_RAG_QUERIES; q++)
    {
        rag_make_query((uint32_t)q + 1U);
        rag_score_corpus();
        rag_topk_select();
        for (int k = 0; k < TOPK; k++)
        {
            checksum = checksum_mix(checksum,
                                    (uint32_t)rag_topk_scores[k] ^ ((uint32_t)rag_topk_ids[k] << 16));
        }
    }
    return checksum;
}

static int run_rag(void)
{
    init_rag_corpus();
    printf("RAgentBench rag suite: queries=%d docs=%d doc_len=%d vocab=%d topk=%d\n",
           AGENT_RAG_QUERIES, DOC_COUNT, DOC_LEN, 1 << VOCAB_BITS, TOPK);
    bench_mode_begin("rag", "retrieval-scoring");

    uint64_t work = (uint64_t)AGENT_RAG_QUERIES * RAG_WORK_PER_QUERY;

    ragentbench_time_us_t start = ragentbench_get_time_us();
    uint32_t cs = bench_rag();
    bench_record("retrieve_topk", "retrieval-scoring", "doc",
                 work, ragentbench_get_time_us() - start, cs);
    g_sink ^= cs;

    bench_mode_end("rag");
    return 0;
}

/* -------------------------------------------------------------------------- */
/* Mode 3: workflow — multi-turn agent loop with policy table and subchecks.  */
/* -------------------------------------------------------------------------- */

typedef struct
{
    int16_t status;   /* 0=open, 1=in_progress, 2=blocked, 3=done */
    int16_t priority; /* 0..3 */
    int16_t resource; /* index into a resource pool */
    int16_t progress; /* 0..16 */
} flow_task_t;

static flow_task_t flow_tasks[FLOW_TASKS];
static int16_t flow_resources[FLOW_TASKS * 2];
static uint32_t flow_action_count[FLOW_TOOL_COUNT];
static uint32_t flow_subcheck_pass;
static uint32_t flow_subcheck_total;

static void init_flow_state(void)
{
    for (int i = 0; i < FLOW_TASKS; i++)
    {
        uint32_t s = mix32((uint32_t)i + 0x12345U);
        flow_tasks[i].status = 0;
        flow_tasks[i].priority = (int16_t)(s & 3);
        flow_tasks[i].resource = (int16_t)((s >> 4) % (FLOW_TASKS * 2));
        flow_tasks[i].progress = 0;
    }
    for (int i = 0; i < FLOW_TASKS * 2; i++)
    {
        flow_resources[i] = (int16_t)(mix32((uint32_t)i + 0x67890U) & 0xFF);
    }
    for (int i = 0; i < FLOW_TOOL_COUNT; i++)
    {
        flow_action_count[i] = 0;
    }
    flow_subcheck_pass = 0;
    flow_subcheck_total = 0;
}

/*
 * Action enum (8 actions form a small decision space):
 *   0 noop, 1 open, 2 inspect, 3 acquire, 4 progress, 5 release, 6 escalate, 7 close.
 * Policy table maps (status, priority) pair to an action via deterministic switch.
 */
static int flow_policy(const flow_task_t *task, int turn)
{
    int s = task->status;
    int p = task->priority;
    int hint = (turn ^ s ^ p) & 7;

    if (s == 3)
        return 0; /* done -> noop */
    if (s == 0)
        return 1; /* open -> open */
    if (s == 2)
        return (p >= 2) ? 6 : 5; /* blocked -> escalate or release */
    /* in-progress branches */
    if (task->progress >= 12)
        return 7;
    if (task->progress >= 8 && hint < 2)
        return 4;
    if (hint < 3)
        return 2;
    if (hint < 5)
        return 3;
    return 4;
}

static int flow_execute(flow_task_t *task, int action, uint32_t *checksum)
{
    if (action < 0 || action >= FLOW_TOOL_COUNT)
    {
        return 0;
    }
    flow_action_count[action]++;

    switch (action)
    {
    case 0: /* noop */
        return 0;
    case 1: /* open */
        task->status = 1;
        task->progress = 0;
        break;
    case 2: /* inspect */
    {
        int r = task->resource;
        if (r < 0 || r >= FLOW_TASKS * 2)
        {
            return -1; /* missing-parameter style failure */
        }
        *checksum = checksum_mix(*checksum, (uint32_t)flow_resources[r]);
        break;
    }
    case 3: /* acquire */
    {
        int r = task->resource;
        if (flow_resources[r] <= 0)
        {
            task->status = 2; /* blocked */
            return -1;
        }
        flow_resources[r]--;
        break;
    }
    case 4: /* progress */
        task->progress = (int16_t)(task->progress + 1);
        if (task->progress > 16)
            task->progress = 16;
        break;
    case 5: /* release */
    {
        int r = task->resource;
        flow_resources[r]++;
        task->status = 1;
        break;
    }
    case 6: /* escalate */
        task->priority = (int16_t)(task->priority + 1);
        if (task->priority > 3)
            task->priority = 3;
        task->status = 1;
        break;
    case 7: /* close */
        task->status = 3;
        break;
    default:
        return -1;
    }
    return 1;
}

/* Subcheck: tau-bench-style state-based assertions on the world. */
static void flow_subcheck(int turn)
{
    flow_subcheck_total += 4;
    /* (1) at least one resource non-negative — trivially true unless we underflowed */
    int ok1 = 1;
    for (int i = 0; i < FLOW_TASKS * 2; i++)
    {
        if (flow_resources[i] < 0)
        {
            ok1 = 0;
            break;
        }
    }
    flow_subcheck_pass += (uint32_t)ok1;
    /* (2) progress within bounds */
    int ok2 = 1;
    for (int i = 0; i < FLOW_TASKS; i++)
    {
        if (flow_tasks[i].progress < 0 || flow_tasks[i].progress > 16)
        {
            ok2 = 0;
            break;
        }
    }
    flow_subcheck_pass += (uint32_t)ok2;
    /* (3) priority within bounds */
    int ok3 = 1;
    for (int i = 0; i < FLOW_TASKS; i++)
    {
        if (flow_tasks[i].priority < 0 || flow_tasks[i].priority > 3)
        {
            ok3 = 0;
            break;
        }
    }
    flow_subcheck_pass += (uint32_t)ok3;
    /* (4) by mid-run at least one task has made progress */
    int ok4 = (turn < AGENT_FLOW_TURNS / 2);
    if (!ok4)
    {
        for (int i = 0; i < FLOW_TASKS; i++)
        {
            if (flow_tasks[i].progress > 0 || flow_tasks[i].status >= 1)
            {
                ok4 = 1;
                break;
            }
        }
    }
    flow_subcheck_pass += (uint32_t)ok4;
}

static uint32_t bench_workflow(void)
{
    uint32_t checksum = 0x1A2B3C4DU;
    for (int turn = 0; turn < AGENT_FLOW_TURNS; turn++)
    {
        /* Each turn iterates over all tasks, with a per-turn nested step cap
         * to mimic BFCL's force-termination at MAX_INFERENCE_STEPS. */
        for (int step = 0; step < FLOW_MAX_STEPS; step++)
        {
            int progressed = 0;
            for (int t = 0; t < FLOW_TASKS; t++)
            {
                if (flow_tasks[t].status == 3)
                    continue;
                int action = flow_policy(&flow_tasks[t], turn ^ step);
                int rc = flow_execute(&flow_tasks[t], action, &checksum);
                checksum = checksum_mix(checksum,
                                        ((uint32_t)action << 8) ^ ((uint32_t)flow_tasks[t].status << 4) ^
                                            (uint32_t)flow_tasks[t].progress ^ (uint32_t)rc);
                if (rc > 0)
                    progressed++;
            }
            if (!progressed)
                break; /* converge early — exercises branch mispredict */
        }
        flow_subcheck(turn);
        /* Periodic "user message" injection: bumps a random task's priority. */
        if ((turn & 3) == 3)
        {
            int idx = (int)(mix32((uint32_t)turn) % FLOW_TASKS);
            flow_tasks[idx].priority = (int16_t)((flow_tasks[idx].priority + 1) & 3);
            if (flow_tasks[idx].status == 3)
                flow_tasks[idx].status = 1;
        }
    }
    checksum = checksum_mix(checksum, flow_subcheck_pass);
    checksum = checksum_mix(checksum, flow_subcheck_total);
    return checksum;
}

static int run_workflow(void)
{
    init_flow_state();
    printf("RAgentBench workflow suite: turns=%d tasks=%d max_steps=%d actions=%d\n",
           AGENT_FLOW_TURNS, FLOW_TASKS, FLOW_MAX_STEPS, FLOW_TOOL_COUNT);
    bench_mode_begin("workflow", "agentic-loop");

    uint64_t work = (uint64_t)AGENT_FLOW_TURNS * FLOW_WORK_PER_TURN;

    ragentbench_time_us_t start = ragentbench_get_time_us();
    uint32_t cs = bench_workflow();
    bench_record("policy_loop", "agentic-loop", "step",
                 work, ragentbench_get_time_us() - start, cs);
    g_sink ^= cs;

    printf("RAGENTBENCH_TRACE name=workflow subcheck_pass=%u subcheck_total=%u\n",
           (unsigned int)flow_subcheck_pass, (unsigned int)flow_subcheck_total);

    bench_mode_end("workflow");
    return 0;
}

/* -------------------------------------------------------------------------- */
/* main                                                                        */
/* -------------------------------------------------------------------------- */

int main(void)
{
    int rc = 0;
    bench_header();
#if AGENT_BENCH_MODE == AGENT_MODE_TOOLS
    rc |= run_tools();
#elif AGENT_BENCH_MODE == AGENT_MODE_RAG
    rc |= run_rag();
#elif AGENT_BENCH_MODE == AGENT_MODE_WORKFLOW
    rc |= run_workflow();
#else
    rc |= run_tools();
    rc |= run_rag();
    rc |= run_workflow();
#endif
    printf("agent_bench_done sink=0x%08x\n", (unsigned int)g_sink);
    return rc;
}
