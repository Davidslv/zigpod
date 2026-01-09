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
/// Size of xlarge allocation blocks (4096 bytes) - for audio buffers
pub const XLARGE_BLOCK_SIZE: usize = 4096;
/// Size of huge allocation blocks (16384 bytes) - for DMA buffers
pub const HUGE_BLOCK_SIZE: usize = 16384;

/// Number of small blocks
pub const SMALL_BLOCK_COUNT: usize = 256;
/// Number of medium blocks
pub const MEDIUM_BLOCK_COUNT: usize = 128;
/// Number of large blocks
pub const LARGE_BLOCK_COUNT: usize = 64;
/// Number of xlarge blocks
pub const XLARGE_BLOCK_COUNT: usize = 16;
/// Number of huge blocks
pub const HUGE_BLOCK_COUNT: usize = 4;

/// DMA alignment requirement (32 bytes for ARM cache line)
pub const DMA_ALIGNMENT: usize = 32;

// ============================================================
// Fixed Block Allocator
// ============================================================

/// A simple fixed-block allocator for embedded systems
/// Supports optional DMA-aligned allocation for hardware buffers
pub fn FixedBlockAllocator(comptime block_size: usize, comptime block_count: usize) type {
    // Ensure block size is aligned for DMA operations
    const aligned_block_size = if (block_size >= 256)
        ((block_size + DMA_ALIGNMENT - 1) / DMA_ALIGNMENT) * DMA_ALIGNMENT
    else
        block_size;

    return struct {
        const Self = @This();
        pub const BlockSize = aligned_block_size;
        pub const BlockCount = block_count;

        /// Storage for blocks (aligned for DMA)
        storage: [block_count]AlignedBlock align(DMA_ALIGNMENT) = undefined,
        /// Bitmap of free blocks (1 = free, 0 = allocated)
        free_bitmap: [block_count]bool = [_]bool{true} ** block_count,
        /// Number of free blocks
        free_count: usize = block_count,

        const AlignedBlock = [aligned_block_size]u8;

        /// Initialize the allocator
        pub fn init() Self {
            return Self{};
        }

        /// Allocate a block
        pub fn alloc(self: *Self) ?*AlignedBlock {
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
        pub fn free(self: *Self, ptr: *AlignedBlock) void {
            const base = @intFromPtr(&self.storage[0]);
            const addr = @intFromPtr(ptr);

            if (addr >= base and addr < base + block_count * aligned_block_size) {
                const index = (addr - base) / aligned_block_size;
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

        /// Get actual block size (may be larger due to alignment)
        pub fn blockSize(_: *const Self) usize {
            return aligned_block_size;
        }

        /// Check if address is properly aligned for DMA
        pub fn isDmaAligned(_: *const Self, ptr: anytype) bool {
            return @intFromPtr(ptr) % DMA_ALIGNMENT == 0;
        }
    };
}

// ============================================================
// Global Allocators
// ============================================================

var small_allocator: FixedBlockAllocator(SMALL_BLOCK_SIZE, SMALL_BLOCK_COUNT) = undefined;
var medium_allocator: FixedBlockAllocator(MEDIUM_BLOCK_SIZE, MEDIUM_BLOCK_COUNT) = undefined;
var large_allocator: FixedBlockAllocator(LARGE_BLOCK_SIZE, LARGE_BLOCK_COUNT) = undefined;
var xlarge_allocator: FixedBlockAllocator(XLARGE_BLOCK_SIZE, XLARGE_BLOCK_COUNT) = undefined;
var huge_allocator: FixedBlockAllocator(HUGE_BLOCK_SIZE, HUGE_BLOCK_COUNT) = undefined;

var initialized: bool = false;

/// Initialize the memory subsystem
pub fn init() void {
    small_allocator = FixedBlockAllocator(SMALL_BLOCK_SIZE, SMALL_BLOCK_COUNT).init();
    medium_allocator = FixedBlockAllocator(MEDIUM_BLOCK_SIZE, MEDIUM_BLOCK_COUNT).init();
    large_allocator = FixedBlockAllocator(LARGE_BLOCK_SIZE, LARGE_BLOCK_COUNT).init();
    xlarge_allocator = FixedBlockAllocator(XLARGE_BLOCK_SIZE, XLARGE_BLOCK_COUNT).init();
    huge_allocator = FixedBlockAllocator(HUGE_BLOCK_SIZE, HUGE_BLOCK_COUNT).init();
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

    if (size <= XLARGE_BLOCK_SIZE) {
        if (xlarge_allocator.alloc()) |block| {
            return block;
        }
    }

    if (size <= HUGE_BLOCK_SIZE) {
        if (huge_allocator.alloc()) |block| {
            return block;
        }
    }

    return null;
}

/// Allocate DMA-aligned memory of given size
/// Returns memory guaranteed to be aligned to DMA_ALIGNMENT
pub fn allocDma(size: usize) ?[*]align(DMA_ALIGNMENT) u8 {
    // Prefer larger blocks which are always DMA-aligned
    if (size <= XLARGE_BLOCK_SIZE) {
        if (xlarge_allocator.alloc()) |block| {
            const ptr: [*]u8 = block;
            return @alignCast(ptr);
        }
    }

    if (size <= HUGE_BLOCK_SIZE) {
        if (huge_allocator.alloc()) |block| {
            const ptr: [*]u8 = block;
            return @alignCast(ptr);
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
    } else if (size <= XLARGE_BLOCK_SIZE) {
        xlarge_allocator.free(@ptrCast(ptr));
    } else if (size <= HUGE_BLOCK_SIZE) {
        huge_allocator.free(@ptrCast(ptr));
    }
}

/// Free DMA-aligned memory
pub fn freeDma(ptr: [*]align(DMA_ALIGNMENT) u8, size: usize) void {
    free(@ptrCast(ptr), size);
}

/// Get maximum allocatable size
pub fn maxAllocSize() usize {
    return HUGE_BLOCK_SIZE;
}

/// Get memory statistics
pub const MemoryStats = struct {
    small_free: usize,
    small_total: usize,
    medium_free: usize,
    medium_total: usize,
    large_free: usize,
    large_total: usize,
    xlarge_free: usize,
    xlarge_total: usize,
    huge_free: usize,
    huge_total: usize,

    pub fn totalFreeBytes(self: MemoryStats) usize {
        return self.small_free * SMALL_BLOCK_SIZE +
            self.medium_free * MEDIUM_BLOCK_SIZE +
            self.large_free * LARGE_BLOCK_SIZE +
            self.xlarge_free * XLARGE_BLOCK_SIZE +
            self.huge_free * HUGE_BLOCK_SIZE;
    }

    pub fn totalBytes(self: MemoryStats) usize {
        return self.small_total * SMALL_BLOCK_SIZE +
            self.medium_total * MEDIUM_BLOCK_SIZE +
            self.large_total * LARGE_BLOCK_SIZE +
            self.xlarge_total * XLARGE_BLOCK_SIZE +
            self.huge_total * HUGE_BLOCK_SIZE;
    }

    /// Get largest available block size
    pub fn largestAvailable(self: MemoryStats) usize {
        if (self.huge_free > 0) return HUGE_BLOCK_SIZE;
        if (self.xlarge_free > 0) return XLARGE_BLOCK_SIZE;
        if (self.large_free > 0) return LARGE_BLOCK_SIZE;
        if (self.medium_free > 0) return MEDIUM_BLOCK_SIZE;
        if (self.small_free > 0) return SMALL_BLOCK_SIZE;
        return 0;
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
        .xlarge_free = xlarge_allocator.freeBlocks(),
        .xlarge_total = XLARGE_BLOCK_COUNT,
        .huge_free = huge_allocator.freeBlocks(),
        .huge_total = HUGE_BLOCK_COUNT,
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

test "xlarge allocation" {
    init();

    // Can allocate 4KB
    const p1 = alloc(4096);
    try std.testing.expect(p1 != null);

    const stats = getStats();
    try std.testing.expectEqual(XLARGE_BLOCK_COUNT - 1, stats.xlarge_free);

    // Free it
    if (p1) |ptr| {
        free(ptr, 4096);
    }

    const stats2 = getStats();
    try std.testing.expectEqual(XLARGE_BLOCK_COUNT, stats2.xlarge_free);
}

test "huge allocation" {
    init();

    // Can allocate 16KB
    const p1 = alloc(16384);
    try std.testing.expect(p1 != null);

    const stats = getStats();
    try std.testing.expectEqual(HUGE_BLOCK_COUNT - 1, stats.huge_free);

    // Free it
    if (p1) |ptr| {
        free(ptr, 16384);
    }
}

test "dma aligned allocation" {
    init();

    // Allocate DMA-aligned memory
    const p1 = allocDma(2048);
    try std.testing.expect(p1 != null);

    // Should be aligned
    if (p1) |ptr| {
        try std.testing.expect(@intFromPtr(ptr) % DMA_ALIGNMENT == 0);
        freeDma(ptr, 2048);
    }
}

test "max alloc size" {
    try std.testing.expectEqual(@as(usize, 16384), maxAllocSize());
}

test "memory stats largest available" {
    init();

    const stats = getStats();
    try std.testing.expectEqual(HUGE_BLOCK_SIZE, stats.largestAvailable());
}
