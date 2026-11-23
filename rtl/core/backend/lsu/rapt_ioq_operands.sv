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
    parameter int StoreValues = 8
) (
    input logic clock,
    input logic reset,
    input logic flush,
    input logic [Entries-1:0] entry_valid,
    input logic [Entries-1:0] is_store,
    input logic [IndexBits-1:0] head,
    input logic retire,
    input logic alloc_valid[Slots],
    input logic alloc_is_store[Slots],
    input logic [IndexBits-1:0] alloc_index[Slots],
    input logic [1:0][PhysBits-1:0] alloc_sources[Slots],
    input logic alloc_addr_valid[Slots],
    input logic [Xlen-1:0] alloc_addr[Slots],
    input logic alloc_base_ready[Slots],
    input logic [11:0] alloc_immediate[Slots],
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
  logic [ReadPorts-1:0] request_valid, request_addr, request_alloc;
  logic [IndexBits-1:0] request_index[ReadPorts];
  logic [11:0] request_imm[ReadPorts];
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

  localparam bit PowerOfTwoEntries = (Entries & (Entries - 1)) == 0;
  localparam logic [IndexBits:0] EntriesWide = (IndexBits + 1)'(Entries);
  localparam logic [IndexBits-1:0] EntriesMod = IndexBits'(Entries);

  function automatic logic [IndexBits-1:0] age_index(input logic [IndexBits-1:0] offset);
    logic [IndexBits:0] sum;
    logic [IndexBits-1:0] mod_idx;
    sum = {1'b0, head} + {1'b0, offset};
    mod_idx = sum >= EntriesWide ? (sum[IndexBits-1:0] - EntriesMod) : sum[IndexBits-1:0];
    return PowerOfTwoEntries ? (head + offset) : mod_idx;
  endfunction

  function automatic logic [IndexBits-1:0] entry_age(input logic [IndexBits-1:0] index);
    logic [IndexBits-1:0] mod_age;
    mod_age = index >= head ? (index - head) : (index + EntriesMod - head);
    return PowerOfTwoEntries ? (index - head) : mod_age;
  endfunction

  function automatic logic [Entries-1:0] age_rotate(input logic [Entries-1:0] mask);
    return Entries'({mask, mask} >> head);
  endfunction

  logic [Entries-1:0] phys_need_addr, phys_need_data;
  for (genvar e = 0; e < Entries; e++) begin : g_phys_need
    logic base_avail, data_avail;
    assign base_avail = base_ready[e] || base_wake[e];
    assign data_avail = data_source[e] != '0 && (data_ready[e] || data_wake[e]);
    assign phys_need_addr[e] = entry_valid[e] && !prepared[e] && base_avail;
    assign phys_need_data[e] = entry_valid[e] && needs_data[e] && !cached[e] && data_avail;
  end

  wire [Entries-1:0] age_need_addr = age_rotate(phys_need_addr);
  wire [Entries-1:0] age_need_data = age_rotate(phys_need_data);
  wire [Entries-1:0] age_is_store = age_rotate(is_store);

  // Decoupled Load/Store AGU arbitration (no bank contention):
  //   Port 0 (Load AGU): prioritizes oldest ready Load addr, then Store addr,
  //     then alloc-edge Load/Store addr, then store data.
  //   Port 1 (Store-Addr/Data AGU): prioritizes head store data (retirement
  //     unblock), then oldest ready Store addr, then Load addr, then younger
  //     store data, then alloc-edge Store/Load addr.
  always_comb begin
    logic [Entries-1:0] age_addr_avail, age_data_rem;
    logic [Slots-1:0] alloc_addr_rem;
    logic [StoreValues-1:0] reserved_cache;
    logic [IndexBits-1:0] cache_age[StoreValues];
    age_addr_avail = age_need_addr;
    age_data_rem = age_need_data;
    for (int s = 0; s < Slots; s++) alloc_addr_rem[s] = alloc_base_ready[s];
    reserved_cache = '0;
    request_valid = '0;
    request_addr = '0;
    request_alloc = '0;
    for (int c = 0; c < StoreValues; c++) begin
      cache_age[c] = entry_age(cache_owner[c]);
    end
    for (int p = 0; p < ReadPorts; p++) begin
      automatic logic free_space;
      automatic logic [CacheBits-1:0] free_slot;
      automatic logic [IndexBits-1:0] max_evict_age;
      automatic logic [CacheBits-1:0] evict_slot;
      automatic logic [CacheBits-1:0] port_cache_slot;
      automatic logic port_found;
      automatic logic port_is_addr;
      automatic logic port_is_alloc;
      automatic logic prefer_store;
      automatic logic [IndexBits-1:0] win_age;
      automatic logic [IndexBits-1:0] win_idx;
      automatic logic [11:0] win_imm;
      automatic logic [PhysBits-1:0] win_alloc_src;
      prefer_store = (ReadPorts >= 2) && (p == 1);
      free_space = 1'b0;
      free_slot = '0;
      for (int c = 0; c < StoreValues; c++) begin
        if (!reserved_cache[c] && !cache_valid[c]) begin
          free_space = 1'b1;
          free_slot = CacheBits'(c);
        end
      end
      max_evict_age = '0;
      evict_slot = '0;
      for (int c = 0; c < StoreValues; c++) begin
        if (!reserved_cache[c] && cache_valid[c] && cache_age[c] > max_evict_age) begin
          max_evict_age = cache_age[c];
          evict_slot = CacheBits'(c);
        end
      end
      port_cache_slot = free_space ? free_slot : evict_slot;
      port_found = 1'b0;
      port_is_addr = 1'b0;
      port_is_alloc = 1'b0;
      win_age = '0;
      win_idx = head;
      win_imm = '0;
      win_alloc_src = '0;
      // Head store data has top priority on Store-AGU (or single-port) to unblock retire.
      if ((prefer_store || ReadPorts == 1)
          && age_data_rem[0] && (free_space || IndexBits'(0) < max_evict_age)) begin
        port_found = 1'b1;
        port_is_addr = 1'b0;
        win_age = '0;
        age_data_rem[0] = 1'b0;
      end
      // Primary class address pass: Load on Port 0, Store on Port 1.
      for (int age = 0; age < Entries; age++) begin
        if (!port_found && age_addr_avail[age] && (age_is_store[age] == prefer_store)) begin
          port_found = 1'b1;
          port_is_addr = 1'b1;
          win_age = IndexBits'(age);
          age_addr_avail[age] = 1'b0;
        end
      end
      // Secondary class address fallback: keep both AGUs utilized.
      for (int age = 0; age < Entries; age++) begin
        if (!port_found && age_addr_avail[age]) begin
          port_found = 1'b1;
          port_is_addr = 1'b1;
          win_age = IndexBits'(age);
          age_addr_avail[age] = 1'b0;
        end
      end
      // Head store data fallback on Port 0 if Port 1 didn't take it.
      if (!port_found && age_data_rem[0] && (free_space || IndexBits'(0) < max_evict_age)) begin
        port_found = 1'b1;
        port_is_addr = 1'b0;
        win_age = '0;
        age_data_rem[0] = 1'b0;
      end
      for (int age = 1; age < Entries; age++) begin
        automatic logic data_cache_ok;
        data_cache_ok = free_space || IndexBits'(age) < max_evict_age;
        if (!port_found && age_data_rem[age] && data_cache_ok) begin
          port_found = 1'b1;
          port_is_addr = 1'b0;
          win_age = IndexBits'(age);
          age_data_rem[age] = 1'b0;
        end
      end
      // Idle read ports steal allocation-edge base reads (matching class first).
      for (int s = 0; s < Slots; s++) begin
        if (!port_found && alloc_addr_rem[s] && (alloc_is_store[s] == prefer_store)) begin
          port_found = 1'b1;
          port_is_addr = 1'b1;
          port_is_alloc = 1'b1;
          win_idx = alloc_index[s];
          win_imm = alloc_immediate[s];
          win_alloc_src = alloc_sources[s][0];
          alloc_addr_rem[s] = 1'b0;
        end
      end
      for (int s = 0; s < Slots; s++) begin
        if (!port_found && alloc_addr_rem[s]) begin
          port_found = 1'b1;
          port_is_addr = 1'b1;
          port_is_alloc = 1'b1;
          win_idx = alloc_index[s];
          win_imm = alloc_immediate[s];
          win_alloc_src = alloc_sources[s][0];
          alloc_addr_rem[s] = 1'b0;
        end
      end
      if (!port_is_alloc) win_idx = port_found ? age_index(win_age) : head;
      for (int c = 0; c < StoreValues; c++) begin
        if (port_found && !port_is_addr && port_cache_slot == CacheBits'(c)) begin
          reserved_cache[c] = 1'b1;
        end
      end
      request_valid[p] = port_found;
      request_addr[p] = port_found && port_is_addr;
      request_alloc[p] = port_found && port_is_alloc;
      request_index[p] = win_idx;
      request_imm[p] = win_imm;
      request_cache[p] = port_found && !port_is_addr ? port_cache_slot : '0;
      if (!port_found) begin
        read_address[p] = '0;
      end else if (port_is_alloc) begin
        read_address[p] = win_alloc_src;
      end else if (port_is_addr) begin
        read_address[p] = base_source[win_idx];
      end else begin
        read_address[p] = data_source[win_idx];
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
    wire [11:0] sum_imm = request_alloc[p] ? request_imm[p] : immediate[request_index[p]];
    assign request_sum[p] = (read_address[p] == '0 ? Xlen'(0) : read_value[p]) + Xlen'($signed(
        sum_imm
    ));
  end
  // Direct per-entry address storage: allows both Load AGU (Port 0) and
  // Store AGU (Port 1) to commit prepared addresses in the same cycle without
  // bank conflicts.
  logic [Xlen-1:0] entry_addr_q[Entries];
  logic [Entries-1:0] entry_cacheable_q;
  for (genvar e = 0; e < Entries; e++) begin : g_address
    logic entry_write;
    logic [Xlen-1:0] entry_write_val;
    always_comb begin
      entry_write = 1'b0;
      entry_write_val = '0;
      if (bank_alloc_valid[e % AllocationBanks]
          && bank_alloc_index[e % AllocationBanks] == IndexBits'(e)
          && bank_addr_valid[e % AllocationBanks]) begin
        entry_write = 1'b1;
        entry_write_val = bank_addr[e % AllocationBanks];
      end
      for (int p = 0; p < ReadPorts; p++) begin
        if (request_valid[p] && request_addr[p] && read_valid[p]
            && request_index[p] == IndexBits'(e)) begin
          entry_write = 1'b1;
          entry_write_val = request_sum[p];
        end
      end
      if (relay_valid && relay_index == IndexBits'(e)) begin
        entry_write = 1'b1;
        entry_write_val = relay_addr;
      end
    end
    assign addr_storage[e] = entry_addr_q[e];
    assign cacheable_storage[e] = entry_cacheable_q[e];
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
      if (entry_write) begin
        entry_addr_q[e] <= entry_write_val;
        entry_cacheable_q[e] <= rapt_pkg::addr_cacheable(entry_write_val);
        prepared[e] <= 1'b1;
      end
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
