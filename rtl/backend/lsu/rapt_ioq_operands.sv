// Ordered source reads for IOQ address preparation and integer store operands.
// The entry owns its physical source tags until preparation/retirement. Only
// effective addresses remain in the entry; a small cache holds store operands.
module rapt_ioq_operands #(
    parameter int Entries = 8,
    parameter int Slots = 2,
    parameter int ReadPorts = 1,
    parameter int Xlen = 64,
    parameter int PhysBits = 6,
    parameter int IndexBits = $clog2(Entries),
    parameter int StoreValues = 2
) (
    input logic clock,
    input logic reset,
    input logic flush,
    input logic [Entries-1:0] entry_valid,
    input logic [IndexBits-1:0] head,
    input logic retire,
    input logic alloc_valid[Slots],
    input logic [IndexBits-1:0] alloc_index[Slots],
    input logic [1:0][PhysBits-1:0] alloc_sources[Slots],
    input logic alloc_addr_valid[Slots],
    input logic [Xlen-1:0] alloc_addr[Slots],
    input logic [11:0] immediate[Entries],
    input logic [Entries-1:0] base_ready,
    input logic [Entries-1:0] data_ready,
    input logic [Entries-1:0] base_wake,
    input logic [Entries-1:0] data_wake,
    input logic [Entries-1:0] needs_data,
    input logic relay_valid,
    input logic [IndexBits-1:0] relay_index,
    input logic [Xlen-1:0] relay_addr,
    output logic [PhysBits-1:0] base_source[Entries],
    output logic [PhysBits-1:0] data_source[Entries],
    output logic [PhysBits-1:0] read_address[ReadPorts],
    input logic [Xlen-1:0] read_value[ReadPorts],
    input logic read_valid[ReadPorts],
    output logic [Xlen-1:0] addr_storage[Entries],
    output logic [Xlen-1:0] addr[Entries],
    output logic [Entries-1:0] addr_ready,
    output logic [Entries-1:0] addr_cacheable,
    output logic [Entries-1:0] prepared,
    output logic head_data_ready,
    output logic [Xlen-1:0] head_data
);
  localparam int CacheBits = StoreValues > 1 ? $clog2(StoreValues) : 1;
  logic [StoreValues-1:0] cache_valid;
  logic [IndexBits-1:0] cache_owner[StoreValues];
  logic [Xlen-1:0] cache_data[StoreValues];
  logic [Entries-1:0] cached, cacheable_storage;
  logic [ReadPorts-1:0] request_valid, request_addr;
  logic [IndexBits-1:0] request_index[ReadPorts];
  logic [CacheBits-1:0] request_cache[ReadPorts];
  wire [Xlen-1:0] request_sum[ReadPorts];
  logic [StoreValues-1:0] cache_write;
  logic [IndexBits-1:0] cache_write_owner[StoreValues];
  logic [Xlen-1:0] cache_write_data[StoreValues];

  localparam int AllocationBanks = 1 << $clog2(Slots);
  logic [AllocationBanks-1:0] bank_alloc_valid, bank_addr_valid;
  logic [IndexBits-1:0] bank_alloc_index[AllocationBanks];
  logic [1:0][PhysBits-1:0] bank_sources[AllocationBanks];
  logic [Xlen-1:0] bank_addr[AllocationBanks];
  for (genvar b = 0; b < AllocationBanks; b++) begin : g_allocation_bank
    always_comb begin
      bank_alloc_valid[b] = 1'b0;
      bank_alloc_index[b] = '0;
      bank_sources[b] = '0;
      bank_addr_valid[b] = 1'b0;
      bank_addr[b] = '0;
      for (int s = 0; s < Slots; s++) begin
        if (alloc_valid[s] && int'(alloc_index[s]) % AllocationBanks == b) begin
          bank_alloc_valid[b] = 1'b1;
          bank_alloc_index[b] = alloc_index[s];
          bank_sources[b] = alloc_sources[s];
          bank_addr_valid[b] = alloc_addr_valid[s];
          bank_addr[b] = alloc_addr[s];
        end
      end
    end
  end

  always_comb begin
    cached = '0;
    head_data_ready = data_source[head] == '0;
    head_data = '0;
    for (int c = 0; c < StoreValues; c++) begin
      if (cache_valid[c]) begin
        cached[cache_owner[c]] = 1'b1;
        if (cache_owner[c] == head) begin
          head_data_ready = 1'b1;
          head_data = cache_data[c];
        end
      end
    end
  end

  // Reserve cache destinations before allocating newly dispatched data.
  // An older ready store may replace a younger cached operand: otherwise
  // two younger values could prevent the head from ever obtaining a slot.
  always_comb begin
    logic [Entries-1:0] taken_addr, taken_data;
    logic [StoreValues-1:0] reserved_cache;
    taken_addr = '0;
    taken_data = '0;
    reserved_cache = '0;
    request_valid = '0;
    request_addr = '0;
    for (int p = 0; p < ReadPorts; p++) begin
      request_index[p] = head;
      request_cache[p] = '0;
      read_address[p] = '0;
      for (int age = 0; age < Entries; age++) begin
        automatic logic [IndexBits-1:0] idx;
        automatic logic cache_space;
        automatic logic [CacheBits-1:0] cache_slot;
        automatic logic [IndexBits-1:0] replace_age;
        idx = head + IndexBits'(age);
        cache_space = 1'b0;
        cache_slot = '0;
        replace_age = IndexBits'(age);
        for (int c = 0; c < StoreValues; c++) begin
          if (!reserved_cache[c] && !cache_valid[c]) begin
            cache_space = 1'b1;
            cache_slot = CacheBits'(c);
          end
        end
        if (!cache_space) begin
          for (int c = 0; c < StoreValues; c++) begin
            if (!reserved_cache[c] && cache_valid[c] && (cache_owner[c] - head) > replace_age) begin
              cache_space = 1'b1;
              cache_slot = CacheBits'(c);
              replace_age = cache_owner[c] - head;
            end
          end
        end
        if (!request_valid[p] && entry_valid[idx]) begin
          if (!taken_addr[idx] && !prepared[idx] && (base_ready[idx] || base_wake[idx])) begin
            request_valid[p] = 1'b1;
            request_addr[p] = 1'b1;
            request_index[p] = idx;
            read_address[p] = base_source[idx];
            taken_addr[idx] = 1'b1;
          end else if (!taken_data[idx] && needs_data[idx] && !cached[idx]
              && data_source[idx] != '0 && (data_ready[idx] || data_wake[idx])
              && cache_space) begin
            request_valid[p] = 1'b1;
            request_index[p] = idx;
            request_cache[p] = cache_slot;
            read_address[p] = data_source[idx];
            taken_data[idx] = 1'b1;
            reserved_cache[cache_slot] = 1'b1;
          end
        end
      end
    end
  end

  // A source read may also name the relay's entry. Bank arbitration gives
  // the relay priority, so query selection never needs late address/data
  // qualification and rejected relays keep wake-edge ordinary preparation.
  // Keep PRF addresses independent of the returned data. Each granted
  // source read writes its reserved cache slot; the bank has no dispatch
  // data inputs and therefore needs no allocation-time wake value mux.
  always_comb begin
    cache_write = '0;
    for (int c = 0; c < StoreValues; c++) begin
      cache_write_owner[c] = '0;
      cache_write_data[c] = '0;
    end
    for (int p = 0; p < ReadPorts; p++) begin
      if (request_valid[p] && !request_addr[p] && read_valid[p]) begin
        cache_write[request_cache[p]] = 1'b1;
        cache_write_owner[request_cache[p]] = request_index[p];
        cache_write_data[request_cache[p]] = read_value[p];
      end
    end
  end

  for (genvar p = 0; p < ReadPorts; p++) begin : g_sum
    assign request_sum[p] = (read_address[p] == '0 ? Xlen'(0) : read_value[p]) + Xlen'($signed(
        immediate[request_index[p]]
    ));
  end
  localparam int BankEntries = Entries / AllocationBanks;
  wire [AllocationBanks-1:0] address_write;
  logic [IndexBits-1:0] address_index[AllocationBanks];
  logic [Xlen-1:0] address_value[AllocationBanks];
  for (genvar b = 0; b < AllocationBanks; b++) begin : g_address_bank
    logic write_valid;
    logic [Xlen-1:0] words[BankEntries];
    logic cacheable[BankEntries];
    // One indexed write per bank shares the wide source mux across its
    // entries. Relay and granted older reads take priority; a displaced
    // allocation retains its source identity and prepares through the PRF.
    always_comb begin
      write_valid = bank_alloc_valid[b] && bank_addr_valid[b];
      address_index[b] = bank_alloc_index[b];
      address_value[b] = bank_addr[b];
      for (int p = 0; p < ReadPorts; p++) begin
        if (request_valid[p] && request_addr[p] && read_valid[p]
            && int'(request_index[p]) % AllocationBanks == b) begin
          write_valid = 1'b1;
          address_index[b] = request_index[p];
          address_value[b] = request_sum[p];
        end
      end
      if (relay_valid && int'(relay_index) % AllocationBanks == b) begin
        write_valid = 1'b1;
        address_index[b] = relay_index;
        address_value[b] = relay_addr;
      end
    end
    assign address_write[b] = write_valid;
    always_ff @(posedge clock) begin
      if (write_valid) begin
        words[int'(address_index[b]) / AllocationBanks] <= address_value[b];
        cacheable[int'(address_index[b]) / AllocationBanks]
            <= rapt_pkg::addr_cacheable(address_value[b]);
      end
    end
    for (genvar k = 0; k < BankEntries; k++) begin : g_read
      assign addr_storage[k*AllocationBanks+b] = words[k];
      assign cacheable_storage[k*AllocationBanks+b] = cacheable[k];
    end
  end
  for (genvar e = 0; e < Entries; e++) begin : g_address
    // Every issue path consumes a captured sum. Arbitration can delay a
    // bank's second preparation; it never changes the relay request edge.
    assign addr[e] = addr_storage[e];
    assign addr_cacheable[e] = cacheable_storage[e];
    assign addr_ready[e] = entry_valid[e] && base_ready[e] && prepared[e];
    always_ff @(posedge clock) begin
      if (bank_alloc_valid[e % AllocationBanks]
          && bank_alloc_index[e % AllocationBanks] == IndexBits'(e)) begin
        base_source[e] <= bank_sources[e % AllocationBanks][0];
        data_source[e] <= bank_sources[e % AllocationBanks][1];
        prepared[e] <= 1'b0;
      end
      if (address_write[e%AllocationBanks] && address_index[e%AllocationBanks] == IndexBits'(e))
        prepared[e] <= 1'b1;
      if (reset || flush || (retire && head == IndexBits'(e))) prepared[e] <= 1'b0;
    end
  end
  for (genvar c = 0; c < StoreValues; c++) begin : g_store_value
    always_ff @(posedge clock) begin
      if (retire && cache_owner[c] == head) cache_valid[c] <= 1'b0;
      if (cache_write[c]) begin
        cache_valid[c] <= 1'b1;
        cache_owner[c] <= cache_write_owner[c];
        cache_data[c] <= cache_write_data[c];
      end
      if (reset || flush) cache_valid[c] <= 1'b0;
    end
  end
endmodule
