#pragma once
// Independent byte-addressed bus model. Effects occur once, on final successful
// response; probes have no effects. Timing does not consume operand PRNG state.
#include <vector>
static constexpr uint64_t data_base = 0x90000000;
static std::array<uint8_t, 65536> data_ram{}, data_expected{};
struct BusRequest {
    uint64_t addr, data;
    unsigned size, tag, index, field;
    bool write, probe;
};
static std::vector<BusRequest> bus_log;
static BusRequest pending_bus{};
static bool bus_pending, bus_finish, bus_authorized;
static unsigned bus_delay, bus_stall;
// Focused final-store-response tests may stretch actual write completion.
static int store_response_delay = -1;
static uint64_t store_wait_cycles;
static uint64_t bus_requests, bus_effects, bus_probes, bus_stale, bus_zero;
static std::array<uint64_t,4> bus_stale_kind{};
static uint64_t fault_address = UINT64_MAX;
static bool fault_actual_only, non_idempotent, fault_page;
static bool bus_failed(const BusRequest& r) {
    return r.addr < data_base || r.addr-data_base+ (1u<<r.size) > data_ram.size()
        || (r.addr == fault_address && (!r.probe || !fault_actual_only));
}
static void memory_before_tick() {
    dut.mem_ready = 0; dut.mem_rsp_valid = 0; bus_finish = false;
    if (dut.reset) { bus_pending = false; bus_stall = 0; return; }
    if (!bus_pending && dut.mem_valid) {
        require(bus_authorized, "memory access without irrevocable authorization");
        // Reproducible pseudo-random stalls keyed by transaction number,
        // independent of DUT command latency and operand randomization.
        const uint64_t schedule = (bus_requests+1)*6364136223846793005ULL+1442695040888963407ULL;
        if (bus_stall++ < ((schedule>>32)%4)) return;
        bus_stall = 0; dut.mem_ready = 1;
        pending_bus = {uint64_t(dut.mem_addr), uint64_t(dut.mem_wdata),
            unsigned(dut.mem_size), unsigned(dut.mem_tag), unsigned(dut.mem_index),
            unsigned(dut.mem_field), bool(dut.mem_write), bool(dut.mem_probe)};
        bus_log.push_back(pending_bus);
        bus_pending = true;
        ++bus_requests;
        bus_delay = (schedule>>40)%6;
        if(pending_bus.write&&!pending_bus.probe&&store_response_delay>=0)
            bus_delay=unsigned(store_response_delay);
        if (!bus_delay) ++bus_zero;
    }
    if (!bus_pending) return;
    const auto& r = pending_bus;
    dut.mem_rsp_tag = r.tag; dut.mem_rsp_index = r.index;
    dut.mem_rsp_field = r.field; dut.mem_rsp_probe = r.probe;
    dut.mem_fault = bus_failed(r); dut.mem_non_idempotent = non_idempotent;
    dut.mem_cause = fault_page ? (r.write ? 15 : 13) : (r.write ? 7 : 5); dut.mem_tval = r.addr;
    dut.mem_rdata = 0;
    if (!dut.mem_fault && !r.probe && !r.write)
        for (unsigned b = 0; b < (1u<<r.size); ++b)
            dut.mem_rdata |= uint64_t(data_ram.at(r.addr-data_base+b)) << (8*b);
    if (bus_delay == 1) {
        // Wrong full ownership tuple must be consumed without progress.
        dut.mem_rsp_valid = 1;
        const unsigned kind = (bus_requests/4)%4;
        ++bus_stale_kind[kind];
        switch (kind) {
            case 0: dut.mem_rsp_tag ^= 1; break;
            case 1: dut.mem_rsp_index ^= 1; break;
            case 2: dut.mem_rsp_field ^= 1; break;
            default: dut.mem_rsp_probe ^= 1; break;
        }
        ++bus_stale;
    } else if (!bus_delay) { dut.mem_rsp_valid = 1; bus_finish = true; }
    if (bus_delay) --bus_delay;
    if(r.write&&!r.probe&&!bus_finish){
        ++store_wait_cycles;
        require(dut.busy&&!dut.rsp_valid,"store owner completed before final response");
    }
}
static void memory_after_tick() {
    if (!bus_finish) return;
    const auto& r = pending_bus;
    if (r.probe) ++bus_probes;
    else if (!bus_failed(r)) {
        ++bus_effects;
        if (r.write) for (unsigned b = 0; b < (1u<<r.size); ++b)
            data_ram.at(r.addr-data_base+b) = r.data >> (8*b);
    }
    bus_pending = false;
}
