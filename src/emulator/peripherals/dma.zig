//! PP5021C DMA Controller
//!
//! Implements the DMA controller for the PP5021C SoC.
//! The DMA controller has 4 channels for various peripherals.
//!
//! Reference: Rockbox firmware/export/pp5020.h
//!            Rockbox firmware/target/arm/pp/system-pp502x.c
//!
//! Memory Map (base 0x6000A000):
//! - 0x6000A000-0x6000AFFF: DMA master registers
//! - 0x6000B000-0x6000B01F: DMA Channel 0 (typically IDE)
//! - 0x6000B020-0x6000B03F: DMA Channel 1
//! - 0x6000B040-0x6000B05F: DMA Channel 2
//! - 0x6000B060-0x6000B07F: DMA Channel 3
//!
//! Per-channel registers:
//! - +0x00: DMA_CMD - Command/enable register
//! - +0x04: DMA_STATUS - Status register
//! - +0x08: DMA_RAM_ADDR - Memory address
//! - +0x0C: DMA_FLAGS - Transfer flags
//! - +0x10: DMA_PER_ADDR - Peripheral address
//! - +0x14: DMA_INCR - Address increment
//! - +0x18: DMA_COUNT - Transfer count

const std = @import("std");
const bus = @import("../memory/bus.zig");
const interrupt_ctrl = @import("interrupt_ctrl.zig");

/// DMA Status bits
pub const Status = struct {
    pub const ACTIVE: u32 = 1 << 0; // Transfer in progress
    pub const COMPLETE: u32 = 1 << 1; // Transfer complete
    pub const ERROR: u32 = 1 << 2; // Transfer error
    pub const FIFO_EMPTY: u32 = 1 << 4; // FIFO empty
    pub const FIFO_FULL: u32 = 1 << 5; // FIFO full
};

/// DMA Command bits
pub const Command = struct {
    pub const ENABLE: u32 = 1 << 0; // Enable channel
    pub const READ: u32 = 1 << 1; // Direction: 0=write to peripheral, 1=read from peripheral
    pub const INCR_SRC: u32 = 1 << 2; // Increment source address
    pub const INCR_DST: u32 = 1 << 3; // Increment destination address
    pub const BURST_4: u32 = 1 << 4; // 4-word burst
    pub const BURST_8: u32 = 2 << 4; // 8-word burst
    pub const INTERRUPT: u32 = 1 << 8; // Generate interrupt on completion
    pub const ABORT: u32 = 1 << 31; // Abort transfer
};

/// DMA Channel state
pub const DmaChannel = struct {
    /// Command register
    command: u32,

    /// Status register
    status: u32,

    /// RAM address
    ram_addr: u32,

    /// Transfer flags
    flags: u32,

    /// Peripheral address
    per_addr: u32,

    /// Address increment
    increment: u32,

    /// Transfer count (in bytes)
    count: u32,

    /// Bytes remaining in current transfer
    remaining: u32,

    /// Channel index
    index: u8,

    const Self = @This();

    pub fn init(index: u8) Self {
        return .{
            .command = 0,
            .status = Status.FIFO_EMPTY,
            .ram_addr = 0,
            .flags = 0,
            .per_addr = 0,
            .increment = 0,
            .count = 0,
            .remaining = 0,
            .index = index,
        };
    }

    /// Check if channel is active
    pub fn isActive(self: *const Self) bool {
        return (self.command & Command.ENABLE) != 0 and self.remaining > 0;
    }

    /// Check if transfer is read (from peripheral to memory)
    pub fn isRead(self: *const Self) bool {
        return (self.command & Command.READ) != 0;
    }

    /// Start a transfer
    pub fn start(self: *Self) void {
        if ((self.command & Command.ENABLE) != 0) {
            self.remaining = self.count;
            self.status = Status.ACTIVE;
        }
    }

    /// Abort a transfer
    pub fn abort(self: *Self) void {
        self.remaining = 0;
        self.status = Status.FIFO_EMPTY;
        self.command &= ~Command.ENABLE;
    }

    /// Complete a transfer
    pub fn complete(self: *Self) void {
        self.remaining = 0;
        self.status = Status.COMPLETE | Status.FIFO_EMPTY;
        self.command &= ~Command.ENABLE;
    }

    /// Read channel register
    pub fn read(self: *const Self, offset: u32) u32 {
        return switch (offset) {
            0x00 => self.command,
            0x04 => self.status,
            0x08 => self.ram_addr,
            0x0C => self.flags,
            0x10 => self.per_addr,
            0x14 => self.increment,
            0x18 => self.count,
            else => 0,
        };
    }

    /// Write channel register
    pub fn write(self: *Self, offset: u32, value: u32) void {
        switch (offset) {
            0x00 => {
                const old_enable = self.command & Command.ENABLE;
                self.command = value;

                // Check for abort
                if ((value & Command.ABORT) != 0) {
                    self.abort();
                    return;
                }

                // Check for new enable
                if (old_enable == 0 and (value & Command.ENABLE) != 0) {
                    self.start();
                }
            },
            0x04 => {
                // Writing to status clears bits (write-1-to-clear)
                self.status &= ~value;
            },
            0x08 => self.ram_addr = value,
            0x0C => self.flags = value,
            0x10 => self.per_addr = value,
            0x14 => self.increment = value,
            0x18 => self.count = value,
            else => {},
        }
    }
};

/// DMA Controller
pub const DmaController = struct {
    /// DMA channels
    channels: [4]DmaChannel,

    /// Master control register
    master_ctrl: u32,

    /// Master status register
    master_status: u32,

    /// Interrupt controller
    int_ctrl: ?*interrupt_ctrl.InterruptController,

    /// Memory bus for DMA transfers
    /// Note: This is set during registerPeripherals
    memory: ?*anyopaque,

    /// Memory read callback
    mem_read: ?*const fn (*anyopaque, u32) u32,

    /// Memory write callback
    mem_write: ?*const fn (*anyopaque, u32, u32) void,

    const Self = @This();

    /// Channel base addresses (offset from DMA region start 0x6000A000)
    const CHANNEL_BASE: u32 = 0x1000; // 0x6000B000 - 0x6000A000
    const CHANNEL_STRIDE: u32 = 0x20;

    pub fn init() Self {
        return .{
            .channels = .{
                DmaChannel.init(0),
                DmaChannel.init(1),
                DmaChannel.init(2),
                DmaChannel.init(3),
            },
            .master_ctrl = 0,
            .master_status = 0,
            .int_ctrl = null,
            .memory = null,
            .mem_read = null,
            .mem_write = null,
        };
    }

    /// Set interrupt controller
    pub fn setInterruptController(self: *Self, ctrl: *interrupt_ctrl.InterruptController) void {
        self.int_ctrl = ctrl;
    }

    /// Set memory callbacks for DMA transfers
    pub fn setMemoryCallbacks(
        self: *Self,
        context: *anyopaque,
        read_fn: *const fn (*anyopaque, u32) u32,
        write_fn: *const fn (*anyopaque, u32, u32) void,
    ) void {
        self.memory = context;
        self.mem_read = read_fn;
        self.mem_write = write_fn;
    }

    /// Get channel for address offset
    fn getChannel(self: *Self, offset: u32) ?*DmaChannel {
        if (offset < CHANNEL_BASE) return null;
        const channel_offset = offset - CHANNEL_BASE;
        const channel_idx = channel_offset / CHANNEL_STRIDE;
        if (channel_idx >= 4) return null;
        return &self.channels[@intCast(channel_idx)];
    }

    /// Get channel offset within channel
    fn getChannelOffset(offset: u32) u32 {
        if (offset < CHANNEL_BASE) return 0;
        return (offset - CHANNEL_BASE) % CHANNEL_STRIDE;
    }

    /// Read register
    pub fn read(self: *Self, offset: u32) u32 {
        // Master registers
        if (offset < CHANNEL_BASE) {
            return switch (offset) {
                0x00 => self.master_ctrl,
                0x04 => self.master_status,
                else => 0,
            };
        }

        // Channel registers
        if (self.getChannel(offset)) |channel| {
            return channel.read(getChannelOffset(offset));
        }

        return 0;
    }

    /// Write register
    pub fn write(self: *Self, offset: u32, value: u32) void {
        // Master registers
        if (offset < CHANNEL_BASE) {
            switch (offset) {
                0x00 => self.master_ctrl = value,
                0x04 => {
                    // Write-1-to-clear
                    self.master_status &= ~value;
                },
                else => {},
            }
            return;
        }

        // Channel registers
        if (self.getChannel(offset)) |channel| {
            channel.write(getChannelOffset(offset), value);
        }
    }

    /// Tick DMA - process one cycle of DMA transfers
    /// Returns true if any channel made progress
    pub fn tick(self: *Self, cycles: u32) bool {
        _ = cycles;
        var progress = false;

        for (&self.channels) |*channel| {
            if (channel.isActive()) {
                // In a real implementation, we'd transfer data here
                // For now, just complete the transfer instantly
                // This is a simplification - real DMA would transfer
                // data over multiple cycles

                // For simplicity, mark transfer as complete
                channel.complete();
                progress = true;

                // Generate interrupt if requested
                if ((channel.command & Command.INTERRUPT) != 0) {
                    self.master_status |= @as(u32, 1) << channel.index;
                    if (self.int_ctrl) |ctrl| {
                        ctrl.assertInterrupt(.dma);
                    }
                }
            }
        }

        return progress;
    }

    /// Perform immediate DMA transfer for ATA
    /// This is called by the ATA controller for DMA read/write
    pub fn performAtaTransfer(
        self: *Self,
        channel_idx: u8,
        ram_addr: u32,
        data: []const u8,
        to_ram: bool,
    ) bool {
        if (channel_idx >= 4) return false;
        if (self.memory == null or self.mem_write == null or self.mem_read == null) return false;

        const channel = &self.channels[channel_idx];

        if (to_ram) {
            // Write data to RAM (DMA read from peripheral)
            var i: u32 = 0;
            while (i < data.len) : (i += 4) {
                const word = if (i + 3 < data.len)
                    @as(u32, data[i]) |
                        (@as(u32, data[i + 1]) << 8) |
                        (@as(u32, data[i + 2]) << 16) |
                        (@as(u32, data[i + 3]) << 24)
                else
                    0;
                self.mem_write.?(self.memory.?, ram_addr + i, word);
            }
        } else {
            // Read data from RAM (DMA write to peripheral)
            var i: u32 = 0;
            while (i < data.len) : (i += 4) {
                const word = self.mem_read.?(self.memory.?, ram_addr + i);
                if (i < data.len) {
                    // Note: data is const, so we can't actually write to it
                    // This would need a mutable buffer in real implementation
                    _ = word;
                }
            }
        }

        // Mark channel as complete
        channel.status = Status.COMPLETE | Status.FIFO_EMPTY;

        // Generate interrupt if enabled
        if ((channel.command & Command.INTERRUPT) != 0) {
            self.master_status |= @as(u32, 1) << channel_idx;
            if (self.int_ctrl) |ctrl| {
                ctrl.assertInterrupt(.dma);
            }
        }

        return true;
    }

    /// Create a peripheral handler for the memory bus
    pub fn createHandler(self: *Self) bus.PeripheralHandler {
        return .{
            .context = @ptrCast(self),
            .readFn = readWrapper,
            .writeFn = writeWrapper,
        };
    }

    fn readWrapper(ctx: *anyopaque, offset: u32) u32 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.read(offset);
    }

    fn writeWrapper(ctx: *anyopaque, offset: u32, value: u32) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.write(offset, value);
    }
};

// Tests
test "DMA channel initialization" {
    var channel = DmaChannel.init(0);
    try std.testing.expect(!channel.isActive());
    try std.testing.expectEqual(@as(u32, Status.FIFO_EMPTY), channel.status);
}

test "DMA channel enable" {
    var channel = DmaChannel.init(0);

    // Set up transfer
    channel.write(0x08, 0x10000000); // RAM address
    channel.write(0x10, 0xC3000000); // Peripheral address (ATA)
    channel.write(0x18, 512); // Count

    // Enable channel
    channel.write(0x00, Command.ENABLE | Command.READ);

    try std.testing.expect(channel.isActive());
    try std.testing.expectEqual(@as(u32, Status.ACTIVE), channel.status);
}

test "DMA controller read/write" {
    var dma = DmaController.init();

    // Write to channel 0
    dma.write(0x1008, 0x10000000); // Channel 0 RAM address
    try std.testing.expectEqual(@as(u32, 0x10000000), dma.read(0x1008));

    // Write to channel 1
    dma.write(0x1028, 0x20000000); // Channel 1 RAM address
    try std.testing.expectEqual(@as(u32, 0x20000000), dma.read(0x1028));
}
