//! Persistent Crash Store
//!
//! Stores critical failure information in a reserved area of storage that
//! survives reboots. This allows post-mortem analysis of crashes that occur
//! when the device is not connected to a computer.
//!
//! Storage layout:
//!   - Uses last 64KB of iPod storage (before partition table backup)
//!   - Or uses reserved sectors if available
//!
//! Data structure:
//!   - Header with magic number and entry count
//!   - Ring buffer of crash entries
//!   - Each entry: timestamp, PC, LR, SP, CPSR, error code, message
//!
//! Recovery workflow:
//!   1. Crash occurs → crash_store.recordCrash() called from panic handler
//!   2. Data written to reserved storage area (direct ATA write, no FAT32)
//!   3. Device reboots (or user power cycles)
//!   4. On next boot, ZigPod checks for pending crashes
//!   5. When USB connected, crashes are exported to /ZIGPOD/LOGS/crashes/

const std = @import("std");
const hal = @import("../hal/hal.zig");

// ============================================================
// Configuration
// ============================================================

/// Magic number to identify valid crash store
pub const MAGIC: u32 = 0x5A504353; // "ZPCS" - ZigPod Crash Store

/// Version for format compatibility
pub const VERSION: u16 = 1;

/// Maximum crash entries stored
pub const MAX_ENTRIES: usize = 16;

/// Maximum message length per crash
pub const MAX_MESSAGE_LEN: usize = 128;

/// Size of crash store in bytes
pub const STORE_SIZE: usize = @sizeOf(CrashStore);

// ============================================================
// Crash Entry
// ============================================================

/// Single crash entry (256 bytes fixed size)
pub const CrashEntry = extern struct {
    /// Entry validity marker
    valid: u32 = 0,

    /// Boot count when crash occurred
    boot_count: u32 = 0,

    /// Timestamp (seconds since device epoch, or 0 if RTC unavailable)
    timestamp: u64 = 0,

    /// CPU Registers at crash
    pc: u32 = 0, // Program Counter
    lr: u32 = 0, // Link Register (return address)
    sp: u32 = 0, // Stack Pointer
    cpsr: u32 = 0, // Status Register

    /// Additional registers (r0-r12)
    r: [13]u32 = [_]u32{0} ** 13,

    /// Error/exception code
    error_code: u32 = 0,
    exception_type: ExceptionType = .unknown,

    /// Crash reason message
    message: [MAX_MESSAGE_LEN]u8 = [_]u8{0} ** MAX_MESSAGE_LEN,
    message_len: u8 = 0,

    /// Padding to 256 bytes (calculated: 256 - 4 - 4 - 8 - 16 - 52 - 4 - 1 - 128 - 1 = 38)
    _padding: [38]u8 = [_]u8{0} ** 38,

    pub const ExceptionType = enum(u8) {
        unknown = 0,
        undefined_instruction = 1,
        software_interrupt = 2,
        prefetch_abort = 3,
        data_abort = 4,
        reserved = 5,
        irq = 6,
        fiq = 7,
        panic = 8,
        watchdog = 9,
        assertion = 10,
        stack_overflow = 11,
        out_of_memory = 12,
        hardware_error = 13,
    };

    const VALID_MARKER: u32 = 0x56414C44; // "VALD"

    pub fn isValid(self: *const CrashEntry) bool {
        return self.valid == VALID_MARKER;
    }

    pub fn markValid(self: *CrashEntry) void {
        self.valid = VALID_MARKER;
    }

    pub fn clear(self: *CrashEntry) void {
        self.* = CrashEntry{};
    }

    pub fn setMessage(self: *CrashEntry, msg: []const u8) void {
        const len = @min(msg.len, MAX_MESSAGE_LEN);
        @memcpy(self.message[0..len], msg[0..len]);
        self.message_len = @intCast(len);
    }

    pub fn getMessage(self: *const CrashEntry) []const u8 {
        return self.message[0..self.message_len];
    }

    pub fn format(self: *const CrashEntry, writer: anytype) !void {
        try writer.print("=== Crash Entry ===\n", .{});
        try writer.print("Boot: #{d}\n", .{self.boot_count});
        try writer.print("Type: {s}\n", .{@tagName(self.exception_type)});
        try writer.print("Error: 0x{X:0>8}\n", .{self.error_code});
        try writer.print("\nRegisters:\n", .{});
        try writer.print("  PC:   0x{X:0>8}\n", .{self.pc});
        try writer.print("  LR:   0x{X:0>8}\n", .{self.lr});
        try writer.print("  SP:   0x{X:0>8}\n", .{self.sp});
        try writer.print("  CPSR: 0x{X:0>8}\n", .{self.cpsr});
        if (self.message_len > 0) {
            try writer.print("\nMessage: {s}\n", .{self.getMessage()});
        }
    }
};

// Verify size is exactly 256 bytes
comptime {
    if (@sizeOf(CrashEntry) != 256) {
        @compileError("CrashEntry must be exactly 256 bytes");
    }
}

// ============================================================
// Crash Store Header
// ============================================================

/// Store header (64 bytes)
pub const StoreHeader = extern struct {
    magic: u32 = MAGIC,
    version: u16 = VERSION,
    entry_count: u16 = 0,
    write_index: u16 = 0,
    total_crashes: u32 = 0,
    last_boot_count: u32 = 0,
    flags: u32 = 0,
    checksum: u32 = 0,
    reserved: [36]u8 = [_]u8{0} ** 36,

    pub fn isValid(self: *const StoreHeader) bool {
        return self.magic == MAGIC and self.version <= VERSION;
    }
};

// ============================================================
// Crash Store
// ============================================================

/// Complete crash store structure
pub const CrashStore = extern struct {
    header: StoreHeader,
    entries: [MAX_ENTRIES]CrashEntry,

    const Self = @This();

    pub fn init() Self {
        return Self{
            .header = StoreHeader{},
            .entries = [_]CrashEntry{CrashEntry{}} ** MAX_ENTRIES,
        };
    }

    /// Record a new crash
    pub fn record(self: *Self, entry: CrashEntry) void {
        var new_entry = entry;
        new_entry.markValid();

        self.entries[self.header.write_index] = new_entry;
        self.header.write_index = @intCast((self.header.write_index + 1) % MAX_ENTRIES);
        self.header.total_crashes += 1;

        if (self.header.entry_count < MAX_ENTRIES) {
            self.header.entry_count += 1;
        }

        self.updateChecksum();
    }

    /// Get number of valid entries
    pub fn count(self: *const Self) u16 {
        return self.header.entry_count;
    }

    /// Get entry by index (0 = oldest)
    pub fn getEntry(self: *const Self, index: usize) ?*const CrashEntry {
        if (index >= self.header.entry_count) return null;

        // Calculate actual index in ring buffer
        const start = if (self.header.entry_count >= MAX_ENTRIES)
            self.header.write_index
        else
            0;
        const actual = (start + index) % MAX_ENTRIES;
        const entry = &self.entries[actual];

        if (entry.isValid()) {
            return entry;
        }
        return null;
    }

    /// Get most recent crash
    pub fn getLatest(self: *const Self) ?*const CrashEntry {
        if (self.header.entry_count == 0) return null;
        const idx = if (self.header.write_index == 0) MAX_ENTRIES - 1 else self.header.write_index - 1;
        const entry = &self.entries[idx];
        if (entry.isValid()) return entry;
        return null;
    }

    /// Clear all entries
    pub fn clear(self: *Self) void {
        self.header.entry_count = 0;
        self.header.write_index = 0;
        for (&self.entries) |*entry| {
            entry.clear();
        }
        self.updateChecksum();
    }

    /// Check if there are unread crashes since last boot
    pub fn hasNewCrashes(self: *const Self, current_boot: u32) bool {
        if (self.header.entry_count == 0) return false;
        if (self.getLatest()) |latest| {
            return latest.boot_count < current_boot;
        }
        return false;
    }

    /// Update checksum
    pub fn updateChecksum(self: *Self) void {
        self.header.checksum = 0;
        var sum: u32 = 0;
        const bytes = std.mem.asBytes(self);
        for (bytes) |b| {
            sum = sum +% b;
        }
        self.header.checksum = sum;
    }

    /// Verify checksum
    pub fn verifyChecksum(self: *const Self) bool {
        const stored = self.header.checksum;
        var temp = self.*;
        temp.header.checksum = 0;
        var sum: u32 = 0;
        const bytes = std.mem.asBytes(&temp);
        for (bytes) |b| {
            sum = sum +% b;
        }
        return sum == stored;
    }
};

// ============================================================
// Global Instance & Disk Operations
// ============================================================

/// Reserved sector for crash store (last 128 sectors of disk)
/// This area is typically unused and survives partition operations
const CRASH_STORE_SECTOR_OFFSET: u64 = 128; // Sectors from end

var crash_store: CrashStore = CrashStore.init();
var store_loaded: bool = false;
var store_sector: u64 = 0;

/// Initialize crash store (called early in boot)
pub fn init() !void {
    if (store_loaded) return;

    // Calculate sector location
    // TODO: Get disk size from ATA IDENTIFY
    const disk_sectors: u64 = 60_000_000; // ~30GB placeholder
    store_sector = disk_sectors - CRASH_STORE_SECTOR_OFFSET;

    // Try to load existing store from disk
    loadFromDisk() catch {
        // No existing store, initialize fresh
        crash_store = CrashStore.init();
    };

    store_loaded = true;
}

/// Load crash store from disk
fn loadFromDisk() !void {
    // TODO: Direct ATA read (bypassing FAT32)
    // This ensures we can read crash data even if filesystem is corrupted

    // const sectors_needed = (STORE_SIZE + 511) / 512;
    // var buffer: [@sizeOf(CrashStore)]u8 = undefined;
    // try ata.readSectors(store_sector, sectors_needed, &buffer);
    // crash_store = @bitCast(buffer);

    // For now, just validate existing memory
    if (!crash_store.header.isValid()) {
        return error.InvalidStore;
    }
}

/// Save crash store to disk
fn saveToDisk() !void {
    crash_store.updateChecksum();

    // TODO: Direct ATA write
    // const sectors_needed = (STORE_SIZE + 511) / 512;
    // const buffer = std.mem.asBytes(&crash_store);
    // try ata.writeSectors(store_sector, sectors_needed, buffer);
}

/// Record a crash (called from panic/exception handler)
pub fn recordCrash(
    exception: CrashEntry.ExceptionType,
    pc: u32,
    lr: u32,
    sp: u32,
    cpsr: u32,
    error_code: u32,
    message: []const u8,
) void {
    var entry = CrashEntry{
        .boot_count = getBootCount(),
        .timestamp = getTimestamp(),
        .pc = pc,
        .lr = lr,
        .sp = sp,
        .cpsr = cpsr,
        .exception_type = exception,
        .error_code = error_code,
    };
    entry.setMessage(message);

    crash_store.record(entry);

    // Immediately save to disk
    saveToDisk() catch {};
}

/// Record a panic
pub fn recordPanic(pc: u32, message: []const u8) void {
    // Try to capture more registers via inline assembly
    var lr: u32 = 0;
    var sp: u32 = 0;

    // ARM assembly to get LR and SP (only on ARM targets)
    const builtin = @import("builtin");
    if (builtin.cpu.arch == .arm or builtin.cpu.arch == .thumb) {
        asm volatile (
            \\mov %[lr], lr
            \\mov %[sp], sp
            : [lr] "=r" (lr),
              [sp] "=r" (sp)
        );
    }

    recordCrash(.panic, pc, lr, sp, 0, 0, message);
}

/// Record assertion failure
pub fn recordAssertion(file: []const u8, line: u32, message: []const u8) void {
    var buf: [MAX_MESSAGE_LEN]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "{s}:{d}: {s}", .{ file, line, message }) catch message;

    var pc: u32 = 0;
    const builtin = @import("builtin");
    if (builtin.cpu.arch == .arm or builtin.cpu.arch == .thumb) {
        asm volatile ("mov %[pc], pc"
            : [pc] "=r" (pc)
        );
    }

    recordCrash(.assertion, pc, 0, 0, 0, line, msg);
}

/// Get crash store for reading
pub fn getStore() *const CrashStore {
    return &crash_store;
}

/// Check for crashes from previous boot
pub fn hasPendingCrashes() bool {
    return crash_store.hasNewCrashes(getBootCount());
}

/// Clear all crash data (after user acknowledges)
pub fn clearAll() void {
    crash_store.clear();
    saveToDisk() catch {};
}

/// Export crashes to text format
pub fn exportToText(writer: anytype) !void {
    try writer.print("=== ZigPod Crash Report ===\n", .{});
    try writer.print("Total crashes recorded: {d}\n", .{crash_store.header.total_crashes});
    try writer.print("Entries in store: {d}/{d}\n\n", .{ crash_store.count(), MAX_ENTRIES });

    var i: usize = 0;
    while (crash_store.getEntry(i)) |entry| : (i += 1) {
        try writer.print("\n--- Crash #{d} ---\n", .{i + 1});
        try entry.format(writer);
    }

    if (crash_store.count() == 0) {
        try writer.print("No crashes recorded.\n", .{});
    }
}

// ============================================================
// Helpers
// ============================================================

fn getBootCount() u32 {
    // TODO: Read from RTC backup register or telemetry
    return 1;
}

fn getTimestamp() u64 {
    // TODO: Read from RTC
    return 0;
}

// ============================================================
// Tests
// ============================================================

test "crash entry size" {
    try std.testing.expectEqual(@as(usize, 256), @sizeOf(CrashEntry));
}

test "crash store init" {
    var store = CrashStore.init();
    try std.testing.expect(store.header.isValid());
    try std.testing.expectEqual(@as(u16, 0), store.count());
}

test "record crash" {
    var store = CrashStore.init();

    var entry = CrashEntry{
        .pc = 0x40001234,
        .lr = 0x40001220,
        .exception_type = .panic,
    };
    entry.setMessage("Test crash");

    store.record(entry);

    try std.testing.expectEqual(@as(u16, 1), store.count());

    const retrieved = store.getLatest().?;
    try std.testing.expectEqual(@as(u32, 0x40001234), retrieved.pc);
    try std.testing.expect(retrieved.isValid());
}

test "crash store ring buffer" {
    var store = CrashStore.init();

    // Fill beyond capacity
    for (0..MAX_ENTRIES + 5) |i| {
        const entry = CrashEntry{
            .pc = @intCast(i),
            .exception_type = .panic,
        };
        store.record(entry);
    }

    try std.testing.expectEqual(@as(u16, MAX_ENTRIES), store.count());
    try std.testing.expectEqual(@as(u32, MAX_ENTRIES + 5), store.header.total_crashes);
}

test "crash entry format" {
    var entry = CrashEntry{
        .boot_count = 5,
        .pc = 0x40001234,
        .lr = 0x40001220,
        .sp = 0x40050000,
        .cpsr = 0x600000D3,
        .exception_type = .data_abort,
        .error_code = 0xDEAD,
    };
    entry.setMessage("Test message");

    var buf: [1024]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try entry.format(stream.writer());

    const output = stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "data_abort") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "0x40001234") != null);
}
