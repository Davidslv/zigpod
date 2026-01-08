//! Ring Buffer Implementation
//!
//! A generic, lock-free ring buffer for single-producer single-consumer scenarios.
//! Useful for audio buffering, inter-process communication, and streaming data.

const std = @import("std");

/// Generic ring buffer with compile-time known capacity
pub fn RingBuffer(comptime T: type, comptime capacity: usize) type {
    return struct {
        const Self = @This();

        /// The underlying buffer
        buffer: [capacity]T = undefined,
        /// Read index
        read_idx: usize = 0,
        /// Write index
        write_idx: usize = 0,

        /// Initialize an empty ring buffer
        pub fn init() Self {
            return Self{
                .buffer = undefined,
                .read_idx = 0,
                .write_idx = 0,
            };
        }

        /// Returns the maximum number of elements the buffer can hold
        pub fn getCapacity() usize {
            return capacity;
        }

        /// Returns the current number of elements in the buffer
        pub fn len(self: *const Self) usize {
            const w = self.write_idx;
            const r = self.read_idx;
            if (w >= r) {
                return w - r;
            } else {
                return capacity - r + w;
            }
        }

        /// Returns the number of free slots available
        pub fn free(self: *const Self) usize {
            return capacity - 1 - self.len();
        }

        /// Returns true if the buffer is empty
        pub fn isEmpty(self: *const Self) bool {
            return self.read_idx == self.write_idx;
        }

        /// Returns true if the buffer is full
        pub fn isFull(self: *const Self) bool {
            return self.free() == 0;
        }

        /// Clear the buffer
        pub fn clear(self: *Self) void {
            self.read_idx = 0;
            self.write_idx = 0;
        }

        /// Push a single element to the buffer
        /// Returns false if the buffer is full
        pub fn push(self: *Self, item: T) bool {
            const next_write = (self.write_idx + 1) % capacity;
            if (next_write == self.read_idx) {
                return false; // Buffer full
            }
            self.buffer[self.write_idx] = item;
            self.write_idx = next_write;
            return true;
        }

        /// Pop a single element from the buffer
        /// Returns null if the buffer is empty
        pub fn pop(self: *Self) ?T {
            if (self.isEmpty()) {
                return null;
            }
            const item = self.buffer[self.read_idx];
            self.read_idx = (self.read_idx + 1) % capacity;
            return item;
        }

        /// Peek at the next element without removing it
        pub fn peek(self: *const Self) ?T {
            if (self.isEmpty()) {
                return null;
            }
            return self.buffer[self.read_idx];
        }

        /// Peek at an element at offset from read position
        pub fn peekAt(self: *const Self, offset: usize) ?T {
            if (offset >= self.len()) {
                return null;
            }
            const idx = (self.read_idx + offset) % capacity;
            return self.buffer[idx];
        }

        /// Write multiple elements to the buffer
        /// Returns the number of elements actually written
        pub fn write(self: *Self, data: []const T) usize {
            var count: usize = 0;
            for (data) |item| {
                if (!self.push(item)) {
                    break;
                }
                count += 1;
            }
            return count;
        }

        /// Read multiple elements from the buffer
        /// Returns the number of elements actually read
        pub fn read(self: *Self, buffer: []T) usize {
            var count: usize = 0;
            while (count < buffer.len) {
                if (self.pop()) |item| {
                    buffer[count] = item;
                    count += 1;
                } else {
                    break;
                }
            }
            return count;
        }

        /// Skip elements without reading them
        pub fn skip(self: *Self, n: usize) usize {
            const to_skip = @min(n, self.len());
            self.read_idx = (self.read_idx + to_skip) % capacity;
            return to_skip;
        }

        /// Get a slice view of contiguous readable data
        /// Note: May not return all available data if it wraps around
        pub fn getReadableSlice(self: *const Self) []const T {
            if (self.isEmpty()) {
                return &[_]T{};
            }

            const r = self.read_idx;
            const w = self.write_idx;

            if (w > r) {
                return self.buffer[r..w];
            } else {
                // Data wraps around, return up to end of buffer
                return self.buffer[r..capacity];
            }
        }

        /// Get a slice view of contiguous writable space
        /// Note: May not return all free space if it wraps around
        pub fn getWritableSlice(self: *Self) []T {
            if (self.isFull()) {
                return &[_]T{};
            }

            const r = self.read_idx;
            const w = self.write_idx;

            if (r > w) {
                // Write up to just before read index
                return self.buffer[w .. r - 1];
            } else if (r == 0) {
                // Can't wrap, leave one slot empty
                return self.buffer[w .. capacity - 1];
            } else {
                // Write to end of buffer
                return self.buffer[w..capacity];
            }
        }

        /// Advance write index after writing directly to getWritableSlice()
        pub fn commitWrite(self: *Self, count: usize) void {
            self.write_idx = (self.write_idx + count) % capacity;
        }

        /// Advance read index after reading from getReadableSlice()
        pub fn commitRead(self: *Self, count: usize) void {
            self.read_idx = (self.read_idx + count) % capacity;
        }
    };
}

/// Fixed-capacity byte ring buffer (convenience alias)
pub fn ByteRingBuffer(comptime capacity: usize) type {
    return RingBuffer(u8, capacity);
}

/// Audio sample ring buffer (16-bit stereo)
pub fn AudioRingBuffer(comptime sample_capacity: usize) type {
    return RingBuffer(i16, sample_capacity);
}

// ============================================================
// Tests
// ============================================================

test "basic push and pop" {
    var rb = RingBuffer(u32, 8).init();

    try std.testing.expect(rb.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), rb.len());

    // Push some items
    try std.testing.expect(rb.push(1));
    try std.testing.expect(rb.push(2));
    try std.testing.expect(rb.push(3));

    try std.testing.expectEqual(@as(usize, 3), rb.len());
    try std.testing.expect(!rb.isEmpty());

    // Pop items
    try std.testing.expectEqual(@as(u32, 1), rb.pop().?);
    try std.testing.expectEqual(@as(u32, 2), rb.pop().?);
    try std.testing.expectEqual(@as(u32, 3), rb.pop().?);

    try std.testing.expect(rb.isEmpty());
    try std.testing.expectEqual(@as(?u32, null), rb.pop());
}

test "buffer full" {
    var rb = RingBuffer(u8, 4).init();

    // Can only hold capacity - 1 items
    try std.testing.expect(rb.push(1));
    try std.testing.expect(rb.push(2));
    try std.testing.expect(rb.push(3));
    try std.testing.expect(!rb.push(4)); // Should fail

    try std.testing.expect(rb.isFull());
    try std.testing.expectEqual(@as(usize, 3), rb.len());
    try std.testing.expectEqual(@as(usize, 0), rb.free());
}

test "wraparound" {
    var rb = RingBuffer(u8, 4).init();

    // Fill and partially empty
    _ = rb.push(1);
    _ = rb.push(2);
    _ = rb.pop();
    _ = rb.pop();

    // Now push more (should wrap around)
    try std.testing.expect(rb.push(3));
    try std.testing.expect(rb.push(4));
    try std.testing.expect(rb.push(5));

    // Read back
    try std.testing.expectEqual(@as(u8, 3), rb.pop().?);
    try std.testing.expectEqual(@as(u8, 4), rb.pop().?);
    try std.testing.expectEqual(@as(u8, 5), rb.pop().?);
}

test "bulk write and read" {
    var rb = RingBuffer(u8, 16).init();

    const data = [_]u8{ 1, 2, 3, 4, 5 };
    try std.testing.expectEqual(@as(usize, 5), rb.write(&data));

    var buf: [10]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 5), rb.read(&buf));
    try std.testing.expectEqualSlices(u8, &data, buf[0..5]);
}

test "peek operations" {
    var rb = RingBuffer(u32, 8).init();

    _ = rb.push(10);
    _ = rb.push(20);
    _ = rb.push(30);

    // Peek shouldn't consume
    try std.testing.expectEqual(@as(u32, 10), rb.peek().?);
    try std.testing.expectEqual(@as(u32, 10), rb.peek().?);

    // Peek at offset
    try std.testing.expectEqual(@as(u32, 10), rb.peekAt(0).?);
    try std.testing.expectEqual(@as(u32, 20), rb.peekAt(1).?);
    try std.testing.expectEqual(@as(u32, 30), rb.peekAt(2).?);
    try std.testing.expectEqual(@as(?u32, null), rb.peekAt(3));

    // Buffer should still have all items
    try std.testing.expectEqual(@as(usize, 3), rb.len());
}

test "clear" {
    var rb = RingBuffer(u8, 8).init();

    _ = rb.push(1);
    _ = rb.push(2);
    _ = rb.push(3);

    rb.clear();

    try std.testing.expect(rb.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), rb.len());
}

test "skip" {
    var rb = RingBuffer(u8, 8).init();

    _ = rb.push(1);
    _ = rb.push(2);
    _ = rb.push(3);
    _ = rb.push(4);
    _ = rb.push(5);

    try std.testing.expectEqual(@as(usize, 3), rb.skip(3));
    try std.testing.expectEqual(@as(u8, 4), rb.pop().?);
    try std.testing.expectEqual(@as(u8, 5), rb.pop().?);
}

test "slice access" {
    var rb = RingBuffer(u8, 8).init();

    // Write some data
    const data = [_]u8{ 1, 2, 3, 4, 5 };
    _ = rb.write(&data);

    // Get readable slice
    const readable = rb.getReadableSlice();
    try std.testing.expectEqual(@as(usize, 5), readable.len);
    try std.testing.expectEqualSlices(u8, &data, readable);

    // Commit read
    rb.commitRead(3);
    try std.testing.expectEqual(@as(usize, 2), rb.len());
}

test "byte ring buffer alias" {
    var rb = ByteRingBuffer(64).init();
    try std.testing.expect(rb.push('H'));
    try std.testing.expect(rb.push('i'));
    try std.testing.expectEqual(@as(u8, 'H'), rb.pop().?);
}
