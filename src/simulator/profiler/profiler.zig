//! Performance Profiler
//!
//! Provides profiling and instrumentation for the PP5021C simulator.
//! Tracks instruction counts, memory access patterns, and execution hotspots.

const std = @import("std");

/// Memory access type
pub const AccessType = enum {
    read,
    write,
    execute,
};

/// Memory access record
pub const MemoryAccess = struct {
    address: u32,
    size: u8, // 1, 2, or 4 bytes
    access_type: AccessType,
    timestamp: u64,
    pc: u32, // Instruction that caused this access
};

/// Instruction profile entry
pub const InstructionProfile = struct {
    count: u64 = 0,
    total_cycles: u64 = 0,
    min_cycles: u32 = std.math.maxInt(u32),
    max_cycles: u32 = 0,

    pub fn record(self: *InstructionProfile, cycles: u32) void {
        self.count += 1;
        self.total_cycles += cycles;
        self.min_cycles = @min(self.min_cycles, cycles);
        self.max_cycles = @max(self.max_cycles, cycles);
    }

    pub fn avgCycles(self: *const InstructionProfile) f64 {
        if (self.count == 0) return 0.0;
        return @as(f64, @floatFromInt(self.total_cycles)) / @as(f64, @floatFromInt(self.count));
    }
};

/// Execution hotspot
pub const Hotspot = struct {
    address: u32,
    count: u64,
};

/// Profile statistics
pub const ProfileStats = struct {
    total_instructions: u64 = 0,
    total_cycles: u64 = 0,
    total_memory_reads: u64 = 0,
    total_memory_writes: u64 = 0,
    start_time_ns: i128 = 0,
    end_time_ns: i128 = 0,

    pub fn duration_ms(self: *const ProfileStats) f64 {
        const ns = self.end_time_ns - self.start_time_ns;
        return @as(f64, @floatFromInt(ns)) / 1_000_000.0;
    }

    pub fn instructions_per_second(self: *const ProfileStats) f64 {
        const dur = self.duration_ms();
        if (dur == 0) return 0;
        return @as(f64, @floatFromInt(self.total_instructions)) / (dur / 1000.0);
    }

    pub fn avg_cycles_per_instruction(self: *const ProfileStats) f64 {
        if (self.total_instructions == 0) return 0;
        return @as(f64, @floatFromInt(self.total_cycles)) / @as(f64, @floatFromInt(self.total_instructions));
    }
};

/// Performance Profiler
pub const Profiler = struct {
    /// Instruction counts by opcode (256 entries for first byte)
    instruction_counts: [256]InstructionProfile = [_]InstructionProfile{.{}} ** 256,

    /// PC execution counts (sampled hotspots)
    pc_counts: std.AutoHashMap(u32, u64),

    /// Memory access log (circular buffer)
    memory_log: std.ArrayList(MemoryAccess),
    memory_log_max_size: usize = 10000,

    /// Overall statistics
    stats: ProfileStats = .{},

    /// Memory region access counts
    region_reads: [16]u64 = [_]u64{0} ** 16, // Each 256MB region
    region_writes: [16]u64 = [_]u64{0} ** 16,

    /// Sampling rate (1 = record all, N = record 1 in N)
    sampling_rate: u32 = 1,
    sample_counter: u32 = 0,

    /// Enabled
    enabled: bool = true,

    /// Allocator
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Create a new profiler
    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .pc_counts = std.AutoHashMap(u32, u64).init(allocator),
            .memory_log = .{},
            .allocator = allocator,
        };
    }

    /// Cleanup
    pub fn deinit(self: *Self) void {
        self.pc_counts.deinit();
        self.memory_log.deinit(self.allocator);
    }

    /// Start profiling session
    pub fn start(self: *Self) void {
        self.stats.start_time_ns = std.time.nanoTimestamp();
        self.enabled = true;
    }

    /// Stop profiling session
    pub fn stop(self: *Self) void {
        self.stats.end_time_ns = std.time.nanoTimestamp();
        self.enabled = false;
    }

    /// Reset all counters
    pub fn reset(self: *Self) void {
        self.instruction_counts = [_]InstructionProfile{.{}} ** 256;
        self.pc_counts.clearRetainingCapacity();
        self.memory_log.clearRetainingCapacity();
        self.stats = .{};
        self.region_reads = [_]u64{0} ** 16;
        self.region_writes = [_]u64{0} ** 16;
        self.sample_counter = 0;
    }

    /// Record instruction execution
    pub fn recordInstruction(self: *Self, pc: u32, opcode_byte: u8, cycles: u32) void {
        if (!self.enabled) return;

        self.stats.total_instructions += 1;
        self.stats.total_cycles += cycles;

        // Record by opcode
        self.instruction_counts[opcode_byte].record(cycles);

        // Sample PC hotspots
        self.sample_counter += 1;
        if (self.sample_counter >= self.sampling_rate) {
            self.sample_counter = 0;

            const result = self.pc_counts.getOrPut(pc) catch return;
            if (result.found_existing) {
                result.value_ptr.* += 1;
            } else {
                result.value_ptr.* = 1;
            }
        }
    }

    /// Record memory access
    pub fn recordMemoryAccess(self: *Self, address: u32, size: u8, access_type: AccessType, pc: u32) void {
        if (!self.enabled) return;

        // Update region counts
        const region = address >> 28; // Top 4 bits = 16 regions of 256MB
        if (access_type == .read) {
            self.stats.total_memory_reads += 1;
            self.region_reads[region] += 1;
        } else if (access_type == .write) {
            self.stats.total_memory_writes += 1;
            self.region_writes[region] += 1;
        }

        // Log to circular buffer (sampled)
        if (self.memory_log.items.len < self.memory_log_max_size) {
            self.memory_log.append(self.allocator, .{
                .address = address,
                .size = size,
                .access_type = access_type,
                .timestamp = self.stats.total_cycles,
                .pc = pc,
            }) catch {};
        }
    }

    /// Get top N hotspots by execution count
    pub fn getHotspots(self: *Self, allocator: std.mem.Allocator, n: usize) ![]Hotspot {
        var hotspots = std.ArrayList(Hotspot){};
        errdefer hotspots.deinit(allocator);

        var iter = self.pc_counts.iterator();
        while (iter.next()) |entry| {
            try hotspots.append(allocator, .{
                .address = entry.key_ptr.*,
                .count = entry.value_ptr.*,
            });
        }

        // Sort by count descending
        std.mem.sort(Hotspot, hotspots.items, {}, struct {
            fn lessThan(_: void, a: Hotspot, b: Hotspot) bool {
                return a.count > b.count;
            }
        }.lessThan);

        // Return top N
        const result_len = @min(n, hotspots.items.len);
        const result = try allocator.dupe(Hotspot, hotspots.items[0..result_len]);
        hotspots.deinit(allocator);
        return result;
    }

    /// Get statistics
    pub fn getStats(self: *const Self) ProfileStats {
        return self.stats;
    }

    /// Write report to writer
    pub fn writeReport(self: *Self, writer: anytype) !void {
        try writer.print("=== Profiler Report ===\n\n", .{});

        try writer.print("Overall Statistics:\n", .{});
        try writer.print("  Total instructions: {}\n", .{self.stats.total_instructions});
        try writer.print("  Total cycles: {}\n", .{self.stats.total_cycles});
        try writer.print("  Duration: {d:.2}ms\n", .{self.stats.duration_ms()});
        try writer.print("  Instructions/sec: {d:.0}\n", .{self.stats.instructions_per_second()});
        try writer.print("  Avg cycles/inst: {d:.2}\n\n", .{self.stats.avg_cycles_per_instruction()});

        try writer.print("Memory Access:\n", .{});
        try writer.print("  Total reads: {}\n", .{self.stats.total_memory_reads});
        try writer.print("  Total writes: {}\n\n", .{self.stats.total_memory_writes});

        // Top opcodes by count
        try writer.print("Top 10 Opcodes by Count:\n", .{});
        var opcode_list: [256]struct { opcode: u8, profile: InstructionProfile } = undefined;
        for (0..256) |i| {
            opcode_list[i] = .{
                .opcode = @intCast(i),
                .profile = self.instruction_counts[i],
            };
        }
        std.mem.sort(@TypeOf(opcode_list[0]), &opcode_list, {}, struct {
            fn lessThan(_: void, a: anytype, b: anytype) bool {
                return a.profile.count > b.profile.count;
            }
        }.lessThan);

        for (0..10) |i| {
            if (opcode_list[i].profile.count > 0) {
                try writer.print("  0x{X:0>2}: {} executions, avg {d:.1} cycles\n", .{
                    opcode_list[i].opcode,
                    opcode_list[i].profile.count,
                    opcode_list[i].profile.avgCycles(),
                });
            }
        }

        // Memory region breakdown
        try writer.print("\nMemory Region Access:\n", .{});
        for (0..16) |i| {
            if (self.region_reads[i] > 0 or self.region_writes[i] > 0) {
                try writer.print("  0x{X}0000000: {} reads, {} writes\n", .{
                    i,
                    self.region_reads[i],
                    self.region_writes[i],
                });
            }
        }
    }

    /// Export to Chrome trace format (JSON)
    pub fn exportChromeTrace(self: *Self, writer: anytype) !void {
        try writer.writeAll("{\"traceEvents\":[");

        var first = true;
        for (self.memory_log.items) |access| {
            if (!first) try writer.writeAll(",");
            first = false;

            const name = switch (access.access_type) {
                .read => "mem_read",
                .write => "mem_write",
                .execute => "execute",
            };

            try writer.print(
                \\{{"name":"{s}","cat":"memory","ph":"i","ts":{},"pid":1,"tid":1,"args":{{"addr":"0x{X:0>8}","pc":"0x{X:0>8}"}}}}
            , .{ name, access.timestamp, access.address, access.pc });
        }

        try writer.writeAll("]}");
    }
};

// ============================================================
// Tests
// ============================================================

test "profiler init" {
    const allocator = std.testing.allocator;
    var profiler = Profiler.init(allocator);
    defer profiler.deinit();

    try std.testing.expect(profiler.enabled);
    try std.testing.expectEqual(@as(u64, 0), profiler.stats.total_instructions);
}

test "instruction recording" {
    const allocator = std.testing.allocator;
    var profiler = Profiler.init(allocator);
    defer profiler.deinit();

    profiler.start();

    // Record some instructions
    profiler.recordInstruction(0x1000, 0xE0, 3); // ADD-like
    profiler.recordInstruction(0x1004, 0xE0, 2);
    profiler.recordInstruction(0x1008, 0xE5, 4); // LDR-like

    try std.testing.expectEqual(@as(u64, 3), profiler.stats.total_instructions);
    try std.testing.expectEqual(@as(u64, 9), profiler.stats.total_cycles);
    try std.testing.expectEqual(@as(u64, 2), profiler.instruction_counts[0xE0].count);
    try std.testing.expectEqual(@as(u64, 1), profiler.instruction_counts[0xE5].count);
}

test "memory access recording" {
    const allocator = std.testing.allocator;
    var profiler = Profiler.init(allocator);
    defer profiler.deinit();

    profiler.start();

    profiler.recordMemoryAccess(0x40000000, 4, .read, 0x1000); // DRAM read
    profiler.recordMemoryAccess(0x40000004, 4, .write, 0x1004); // DRAM write
    profiler.recordMemoryAccess(0x60000000, 4, .read, 0x1008); // Peripheral read

    try std.testing.expectEqual(@as(u64, 2), profiler.stats.total_memory_reads);
    try std.testing.expectEqual(@as(u64, 1), profiler.stats.total_memory_writes);
    try std.testing.expect(profiler.region_reads[4] > 0); // 0x4 region
    try std.testing.expect(profiler.region_reads[6] > 0); // 0x6 region
}

test "hotspot detection" {
    const allocator = std.testing.allocator;
    var profiler = Profiler.init(allocator);
    defer profiler.deinit();

    profiler.start();

    // Execute loop at 0x2000 many times
    for (0..100) |_| {
        profiler.recordInstruction(0x2000, 0xE0, 1);
        profiler.recordInstruction(0x2004, 0xE0, 1);
    }
    // Execute other code once
    profiler.recordInstruction(0x3000, 0xE0, 1);

    const hotspots = try profiler.getHotspots(allocator, 5);
    defer allocator.free(hotspots);

    try std.testing.expect(hotspots.len >= 2);
    try std.testing.expect(hotspots[0].count >= 100);
}

test "instruction profile stats" {
    var profile = InstructionProfile{};

    profile.record(3);
    profile.record(5);
    profile.record(4);

    try std.testing.expectEqual(@as(u64, 3), profile.count);
    try std.testing.expectEqual(@as(u64, 12), profile.total_cycles);
    try std.testing.expectEqual(@as(u32, 3), profile.min_cycles);
    try std.testing.expectEqual(@as(u32, 5), profile.max_cycles);
    try std.testing.expectApproxEqAbs(@as(f64, 4.0), profile.avgCycles(), 0.01);
}

test "profile stats calculations" {
    var stats = ProfileStats{};
    stats.total_instructions = 1000;
    stats.total_cycles = 3500;
    stats.start_time_ns = 0;
    stats.end_time_ns = 1_000_000; // 1ms

    try std.testing.expectApproxEqAbs(@as(f64, 1.0), stats.duration_ms(), 0.01);
    try std.testing.expectApproxEqAbs(@as(f64, 1_000_000.0), stats.instructions_per_second(), 1.0);
    try std.testing.expectApproxEqAbs(@as(f64, 3.5), stats.avg_cycles_per_instruction(), 0.01);
}

test "profiler reset" {
    const allocator = std.testing.allocator;
    var profiler = Profiler.init(allocator);
    defer profiler.deinit();

    profiler.start();
    profiler.recordInstruction(0x1000, 0xE0, 3);
    profiler.recordMemoryAccess(0x40000000, 4, .read, 0x1000);

    try std.testing.expect(profiler.stats.total_instructions > 0);

    profiler.reset();

    try std.testing.expectEqual(@as(u64, 0), profiler.stats.total_instructions);
    try std.testing.expectEqual(@as(u64, 0), profiler.stats.total_memory_reads);
}

test "profiler disabled" {
    const allocator = std.testing.allocator;
    var profiler = Profiler.init(allocator);
    defer profiler.deinit();

    profiler.enabled = false;

    profiler.recordInstruction(0x1000, 0xE0, 3);

    try std.testing.expectEqual(@as(u64, 0), profiler.stats.total_instructions);
}
