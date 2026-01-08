//! Memory Management
//!
//! This module provides memory allocation and management for ZigPod OS.
//! It implements a simple fixed-block allocator suitable for embedded systems.

const std = @import("std");
const builtin = @import("builtin");

// ============================================================
// Memory Configuration
// ============================================================

/// Size of small allocation blocks (64 bytes)
pub const SMALL_BLOCK_SIZE: usize = 64;
/// Size of medium allocation blocks (256 bytes)
pub const MEDIUM_BLOCK_SIZE: usize = 256;
/// Size of large allocation blocks (1024 bytes)
pub const LARGE_BLOCK_SIZE: usize = 1024;

/// Number of small blocks
pub const SMALL_BLOCK_COUNT: usize = 256;
/// Number of medium blocks
pub const MEDIUM_BLOCK_COUNT: usize = 128;
/// Number of large blocks
pub const LARGE_BLOCK_COUNT: usize = 64;

// ============================================================
// Fixed Block Allocator
// ============================================================

/// A simple fixed-block allocator for embedded systems
pub fn FixedBlockAllocator(comptime block_size: usize, comptime block_count: usize) type {
    return struct {
        const Self = @This();

        /// Storage for blocks
        storage: [block_count][block_size]u8 = undefined,
        /// Bitmap of free blocks (1 = free, 0 = allocated)
        free_bitmap: [block_count]bool = [_]bool{true} ** block_count,
        /// Number of free blocks
        free_count: usize = block_count,

        /// Initialize the allocator
        pub fn init() Self {
            return Self{};
        }

        /// Allocate a block
        pub fn alloc(self: *Self) ?*[block_size]u8 {
            for (&self.free_bitmap, 0..) |*is_free, i| {
                if (is_free.*) {
                    is_free.* = false;
                    self.free_count -= 1;
                    return &self.storage[i];
                }
            }
            return null;
        }

        /// Free a block
        pub fn free(self: *Self, ptr: *[block_size]u8) void {
            const base = @intFromPtr(&self.storage[0]);
            const addr = @intFromPtr(ptr);

            if (addr >= base and addr < base + block_count * block_size) {
                const index = (addr - base) / block_size;
                if (!self.free_bitmap[index]) {
                    self.free_bitmap[index] = true;
                    self.free_count += 1;
                }
            }
        }

        /// Get number of free blocks
        pub fn freeBlocks(self: *const Self) usize {
            return self.free_count;
        }

        /// Get total number of blocks
        pub fn totalBlocks(_: *const Self) usize {
            return block_count;
        }
    };
}

// ============================================================
// Global Allocators
// ============================================================

var small_allocator: FixedBlockAllocator(SMALL_BLOCK_SIZE, SMALL_BLOCK_COUNT) = undefined;
var medium_allocator: FixedBlockAllocator(MEDIUM_BLOCK_SIZE, MEDIUM_BLOCK_COUNT) = undefined;
var large_allocator: FixedBlockAllocator(LARGE_BLOCK_SIZE, LARGE_BLOCK_COUNT) = undefined;

var initialized: bool = false;

/// Initialize the memory subsystem
pub fn init() void {
    small_allocator = FixedBlockAllocator(SMALL_BLOCK_SIZE, SMALL_BLOCK_COUNT).init();
    medium_allocator = FixedBlockAllocator(MEDIUM_BLOCK_SIZE, MEDIUM_BLOCK_COUNT).init();
    large_allocator = FixedBlockAllocator(LARGE_BLOCK_SIZE, LARGE_BLOCK_COUNT).init();
    initialized = true;
}

/// Allocate memory of given size
pub fn alloc(size: usize) ?[*]u8 {
    if (!initialized) return null;

    if (size <= SMALL_BLOCK_SIZE) {
        if (small_allocator.alloc()) |block| {
            return block;
        }
    }

    if (size <= MEDIUM_BLOCK_SIZE) {
        if (medium_allocator.alloc()) |block| {
            return block;
        }
    }

    if (size <= LARGE_BLOCK_SIZE) {
        if (large_allocator.alloc()) |block| {
            return block;
        }
    }

    return null;
}

/// Free previously allocated memory
pub fn free(ptr: [*]u8, size: usize) void {
    if (!initialized) return;

    if (size <= SMALL_BLOCK_SIZE) {
        small_allocator.free(@ptrCast(ptr));
    } else if (size <= MEDIUM_BLOCK_SIZE) {
        medium_allocator.free(@ptrCast(ptr));
    } else if (size <= LARGE_BLOCK_SIZE) {
        large_allocator.free(@ptrCast(ptr));
    }
}

/// Get memory statistics
pub const MemoryStats = struct {
    small_free: usize,
    small_total: usize,
    medium_free: usize,
    medium_total: usize,
    large_free: usize,
    large_total: usize,

    pub fn totalFreeBytes(self: MemoryStats) usize {
        return self.small_free * SMALL_BLOCK_SIZE +
            self.medium_free * MEDIUM_BLOCK_SIZE +
            self.large_free * LARGE_BLOCK_SIZE;
    }

    pub fn totalBytes(self: MemoryStats) usize {
        return self.small_total * SMALL_BLOCK_SIZE +
            self.medium_total * MEDIUM_BLOCK_SIZE +
            self.large_total * LARGE_BLOCK_SIZE;
    }
};

pub fn getStats() MemoryStats {
    return MemoryStats{
        .small_free = small_allocator.freeBlocks(),
        .small_total = SMALL_BLOCK_COUNT,
        .medium_free = medium_allocator.freeBlocks(),
        .medium_total = MEDIUM_BLOCK_COUNT,
        .large_free = large_allocator.freeBlocks(),
        .large_total = LARGE_BLOCK_COUNT,
    };
}

// ============================================================
// Zig Allocator Interface
// ============================================================

/// Zig-compatible allocator interface
pub const zigpod_allocator = std.mem.Allocator{
    .ptr = undefined,
    .vtable = &.{
        .alloc = zigAlloc,
        .resize = zigResize,
        .free = zigFree,
    },
};

fn zigAlloc(_: *anyopaque, len: usize, _: u8, _: usize) ?[*]u8 {
    return alloc(len);
}

fn zigResize(_: *anyopaque, _: []u8, _: u8, _: usize, _: usize) bool {
    // Fixed block allocator doesn't support resize
    return false;
}

fn zigFree(_: *anyopaque, buf: []u8, _: u8, _: usize) void {
    free(buf.ptr, buf.len);
}

// ============================================================
// Tests
// ============================================================

test "fixed block allocator" {
    var allocator_test = FixedBlockAllocator(64, 4).init();

    // Allocate all blocks
    const b1 = allocator_test.alloc();
    const b2 = allocator_test.alloc();
    const b3 = allocator_test.alloc();
    const b4 = allocator_test.alloc();

    try std.testing.expect(b1 != null);
    try std.testing.expect(b2 != null);
    try std.testing.expect(b3 != null);
    try std.testing.expect(b4 != null);

    // Should be exhausted
    try std.testing.expect(allocator_test.alloc() == null);
    try std.testing.expectEqual(@as(usize, 0), allocator_test.freeBlocks());

    // Free one
    allocator_test.free(b2.?);
    try std.testing.expectEqual(@as(usize, 1), allocator_test.freeBlocks());

    // Can allocate again
    const b5 = allocator_test.alloc();
    try std.testing.expect(b5 != null);
    try std.testing.expectEqual(@as(usize, 0), allocator_test.freeBlocks());
}

test "memory subsystem" {
    init();

    const stats = getStats();
    try std.testing.expectEqual(SMALL_BLOCK_COUNT, stats.small_total);
    try std.testing.expectEqual(SMALL_BLOCK_COUNT, stats.small_free);

    // Allocate small
    const p1 = alloc(32);
    try std.testing.expect(p1 != null);

    const stats2 = getStats();
    try std.testing.expectEqual(SMALL_BLOCK_COUNT - 1, stats2.small_free);

    // Free it
    if (p1) |ptr| {
        free(ptr, 32);
    }

    const stats3 = getStats();
    try std.testing.expectEqual(SMALL_BLOCK_COUNT, stats3.small_free);
}
