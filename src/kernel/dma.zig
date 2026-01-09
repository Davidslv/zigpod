//! DMA (Direct Memory Access) Controller
//!
//! This module provides a high-level interface to the PP5021C DMA engine.
//! The PP5021C has 4 DMA channels that can transfer data between memory
//! and peripherals without CPU intervention.
//!
//! Channel allocation:
//! - Channel 0: Audio (I2S TX) - highest priority
//! - Channel 1: Storage (IDE/ATA)
//! - Channel 2: Reserved / General purpose
//! - Channel 3: Reserved / General purpose
//!
//! For audio playback, DMA transfers samples from a ring buffer in
//! uncached SDRAM to the I2S FIFO, triggered by FIFO threshold interrupts.

const std = @import("std");
const builtin = @import("builtin");
const hal = @import("../hal/hal.zig");
const interrupts = @import("interrupts.zig");

// Hardware register access (only for ARM target)
const is_arm = builtin.cpu.arch == .arm;
const reg = if (is_arm) @import("../hal/pp5021c/registers.zig") else struct {
    pub const DMA_MASTER_CTRL: usize = 0;
    pub const DMA_MASTER_EN: u32 = 0;
    pub const DMA_MASTER_RESET: u32 = 0;
    pub const DMA_CHAN0_BASE: usize = 0;
    pub const DMA_CMD_OFF: usize = 0;
    pub const DMA_STATUS_OFF: usize = 0;
    pub const DMA_RAM_ADDR_OFF: usize = 0;
    pub const DMA_FLAGS_OFF: usize = 0;
    pub const DMA_PER_ADDR_OFF: usize = 0;
    pub const DMA_INCR_OFF: usize = 0;
    pub const DMA_CMD_START: u32 = 0;
    pub const DMA_CMD_INTR: u32 = 0;
    pub const DMA_CMD_RAM_TO_PER: u32 = 0;
    pub const DMA_CMD_WAIT_REQ: u32 = 0;
    pub const DMA_STATUS_BUSY: u32 = 0;
    pub const DMA_STATUS_DONE: u32 = 0;
    pub const DMA_STATUS_ERROR: u32 = 0;
    pub const DMA_INCR_RAM: u32 = 0;
    pub const DMA_FLAGS_REQ_SHIFT: u5 = 0;
    pub const DMA_FLAGS_BURST_SHIFT: u5 = 0;
    pub const DMA_BURST_4: u32 = 0;
    pub const DMA_REQ_IIS: u8 = 0;
    pub const DMA_REQ_IDE: u8 = 0;
    pub const CPU_INT_EN: usize = 0;
    pub const DMA_IRQ: u32 = 0;
    pub const IISFIFO_WR: usize = 0;
    pub fn readReg(comptime T: type, addr: usize) T {
        _ = addr;
        return 0;
    }
    pub fn writeReg(comptime T: type, addr: usize, value: T) void {
        _ = addr;
        _ = value;
    }
    pub fn dmaChannelBase(channel: u2) usize {
        return @as(usize, channel) * 0x20;
    }
};

// ============================================================
// DMA Channel Definitions
// ============================================================

pub const Channel = enum(u2) {
    audio = 0, // I2S audio output
    storage = 1, // IDE/ATA storage
    general_0 = 2, // General purpose
    general_1 = 3, // General purpose
};

pub const Request = enum(u5) {
    i2s = 2, // I2S audio
    ide = 7, // IDE/ATA
    sdhc = 13, // SD card (if present)
};

pub const BurstSize = enum(u3) {
    burst_1 = 0,
    burst_4 = 1,
    burst_8 = 2,
    burst_16 = 3,
};

pub const Direction = enum {
    peripheral_to_memory,
    memory_to_peripheral,
};

pub const State = enum {
    idle,
    busy,
    complete,
    error_state,
};

// ============================================================
// Memory Region Validation (Security)
// ============================================================

/// Valid memory regions for DMA access
/// These are the safe ranges where DMA can read/write
pub const MemoryRegion = struct {
    start: usize,
    end: usize,
    readable: bool,
    writable: bool,
    name: []const u8,
};

/// PP5021C Memory Map - Valid DMA regions
pub const valid_regions = [_]MemoryRegion{
    // SDRAM (main memory) - 32MB on iPod Video
    .{ .start = 0x10000000, .end = 0x12000000, .readable = true, .writable = true, .name = "SDRAM" },
    // Internal SRAM - 64KB
    .{ .start = 0x40000000, .end = 0x40010000, .readable = true, .writable = true, .name = "IRAM" },
    // Uncached SDRAM alias (for DMA buffers)
    .{ .start = 0x30000000, .end = 0x32000000, .readable = true, .writable = true, .name = "SDRAM_UNCACHED" },
    // I2S FIFO (write-only for audio output)
    .{ .start = 0x70002840, .end = 0x70002844, .readable = false, .writable = true, .name = "I2S_FIFO" },
    // IDE/ATA data register
    .{ .start = 0xC00001F0, .end = 0xC00001F8, .readable = true, .writable = true, .name = "IDE_DATA" },
};

/// Invalid/protected regions that DMA must never access
pub const protected_regions = [_]MemoryRegion{
    // BootROM - read-only, no DMA
    .{ .start = 0x00000000, .end = 0x00010000, .readable = false, .writable = false, .name = "BootROM" },
    // Security registers
    .{ .start = 0x60000000, .end = 0x60001000, .readable = false, .writable = false, .name = "SECURITY" },
    // Flash controller (sensitive)
    .{ .start = 0x20000000, .end = 0x28000000, .readable = false, .writable = false, .name = "FLASH" },
};

/// DMA validation errors
pub const ValidationError = error{
    /// RAM address is in a protected region
    InvalidRamAddress,
    /// RAM address is outside valid memory
    RamAddressOutOfBounds,
    /// Peripheral address is invalid
    InvalidPeripheralAddress,
    /// Transfer length is zero
    ZeroLength,
    /// Transfer would exceed region bounds
    TransferExceedsBounds,
    /// Write to read-only region
    WriteToReadOnly,
    /// Read from write-only region
    ReadFromWriteOnly,
};

/// Validate a memory address and length for DMA access
pub fn validateAddress(addr: usize, length: usize, is_write: bool) ValidationError!void {
    if (length == 0) return ValidationError.ZeroLength;

    // Check if in protected region
    for (protected_regions) |region| {
        if (addr >= region.start and addr < region.end) {
            return ValidationError.InvalidRamAddress;
        }
        // Also check end of transfer
        const end_addr = addr + length - 1;
        if (end_addr >= region.start and end_addr < region.end) {
            return ValidationError.InvalidRamAddress;
        }
    }

    // Check if in valid region with proper permissions
    for (valid_regions) |region| {
        if (addr >= region.start and addr < region.end) {
            // Check if transfer stays within region
            if (addr + length > region.end) {
                return ValidationError.TransferExceedsBounds;
            }

            // Check permissions
            if (is_write and !region.writable) {
                return ValidationError.WriteToReadOnly;
            }
            if (!is_write and !region.readable) {
                return ValidationError.ReadFromWriteOnly;
            }

            // Valid!
            return;
        }
    }

    // Not in any valid region
    return ValidationError.RamAddressOutOfBounds;
}

/// Validate DMA configuration before starting transfer
pub fn validateConfig(config: *const Config) ValidationError!void {
    // Determine if RAM is being written (peripheral-to-memory) or read (memory-to-peripheral)
    const ram_is_dest = config.direction == .peripheral_to_memory;

    // Validate RAM address
    try validateAddress(config.ram_addr, config.length, ram_is_dest);

    // Validate peripheral address (simplified - check common peripherals)
    var periph_valid = false;
    for (valid_regions) |region| {
        if (config.peripheral_addr >= region.start and config.peripheral_addr < region.end) {
            periph_valid = true;
            break;
        }
    }

    if (!periph_valid) {
        return ValidationError.InvalidPeripheralAddress;
    }
}

// ============================================================
// DMA Configuration
// ============================================================

pub const Config = struct {
    /// RAM buffer address (must be in uncached region for coherency)
    ram_addr: usize,
    /// Peripheral register address (e.g., I2S FIFO)
    peripheral_addr: usize,
    /// Transfer length in bytes
    length: usize,
    /// DMA request source
    request: Request,
    /// Burst size
    burst: BurstSize,
    /// Transfer direction
    direction: Direction,
    /// Generate interrupt on completion
    interrupt: bool = true,
    /// Increment RAM address
    ram_increment: bool = true,
    /// Increment peripheral address (usually false for FIFOs)
    peripheral_increment: bool = false,
};

// ============================================================
// DMA State
// ============================================================

var initialized: bool = false;

/// Callback for DMA completion interrupts
var completion_callbacks: [4]?*const fn (Channel) void = [_]?*const fn (Channel) void{null} ** 4;

// ============================================================
// DMA Initialization
// ============================================================

/// Initialize the DMA controller
pub fn init() void {
    if (!is_arm) return;

    // Reset DMA controller
    reg.writeReg(u32, reg.DMA_MASTER_CTRL, reg.DMA_MASTER_RESET);

    // Small delay for reset
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        asm volatile ("nop");
    }

    // Enable DMA controller
    reg.writeReg(u32, reg.DMA_MASTER_CTRL, reg.DMA_MASTER_EN);

    // Register DMA interrupt handler
    interrupts.register(.dma, dmaIrqHandler);

    // Enable DMA interrupt
    const int_en = reg.readReg(u32, reg.CPU_INT_EN);
    reg.writeReg(u32, reg.CPU_INT_EN, int_en | reg.DMA_IRQ);

    initialized = true;
}

/// Deinitialize DMA controller
pub fn deinit() void {
    if (!is_arm) return;

    // Stop all channels
    var ch: u2 = 0;
    while (ch < 4) : (ch += 1) {
        abort(@enumFromInt(ch));
    }

    // Disable DMA interrupt
    const int_en = reg.readReg(u32, reg.CPU_INT_EN);
    reg.writeReg(u32, reg.CPU_INT_EN, int_en & ~reg.DMA_IRQ);

    // Unregister handler
    interrupts.unregister(.dma);

    // Disable controller
    reg.writeReg(u32, reg.DMA_MASTER_CTRL, 0);

    initialized = false;
}

// ============================================================
// DMA Transfer Operations
// ============================================================

/// Configure and start a DMA transfer
pub fn start(channel: Channel, config: Config) !void {
    if (!initialized) return error.NotInitialized;

    // Security: Validate addresses before starting transfer
    try validateConfig(&config);

    const chan_base = reg.dmaChannelBase(@intFromEnum(channel));

    // Set RAM address
    reg.writeReg(u32, chan_base + reg.DMA_RAM_ADDR_OFF, @truncate(config.ram_addr));

    // Set peripheral address
    reg.writeReg(u32, chan_base + reg.DMA_PER_ADDR_OFF, @truncate(config.peripheral_addr));

    // Configure address increment
    var incr: u32 = 0;
    if (config.ram_increment) incr |= reg.DMA_INCR_RAM;
    reg.writeReg(u32, chan_base + reg.DMA_INCR_OFF, incr);

    // Configure flags (length, request source, burst size)
    const burst_val: u32 = @intFromEnum(config.burst);
    const flags: u32 = @as(u32, @truncate(config.length)) |
        (@as(u32, @intFromEnum(config.request)) << reg.DMA_FLAGS_REQ_SHIFT) |
        (burst_val << reg.DMA_FLAGS_BURST_SHIFT);
    reg.writeReg(u32, chan_base + reg.DMA_FLAGS_OFF, flags);

    // Build command register
    var cmd: u32 = reg.DMA_CMD_START | reg.DMA_CMD_WAIT_REQ;
    if (config.interrupt) cmd |= reg.DMA_CMD_INTR;
    if (config.direction == .memory_to_peripheral) cmd |= reg.DMA_CMD_RAM_TO_PER;

    // Start transfer
    reg.writeReg(u32, chan_base + reg.DMA_CMD_OFF, cmd);
}

/// Wait for DMA transfer to complete
pub fn wait(channel: Channel, timeout_us: u32) !void {
    if (!is_arm) return;

    const chan_base = reg.dmaChannelBase(@intFromEnum(channel));
    const start_time = hal.current_hal.get_ticks_us();

    while (true) {
        const status = reg.readReg(u32, chan_base + reg.DMA_STATUS_OFF);

        if ((status & reg.DMA_STATUS_BUSY) == 0) {
            // Transfer complete
            if ((status & reg.DMA_STATUS_ERROR) != 0) {
                return error.TransferError;
            }
            return;
        }

        // Check timeout
        if (hal.current_hal.get_ticks_us() - start_time > timeout_us) {
            return error.Timeout;
        }
    }
}

/// Check if DMA channel is busy
pub fn isBusy(channel: Channel) bool {
    if (!is_arm) return false;

    const chan_base = reg.dmaChannelBase(@intFromEnum(channel));
    const status = reg.readReg(u32, chan_base + reg.DMA_STATUS_OFF);
    return (status & reg.DMA_STATUS_BUSY) != 0;
}

/// Get DMA channel state
pub fn getState(channel: Channel) State {
    if (!is_arm) return .idle;

    const chan_base = reg.dmaChannelBase(@intFromEnum(channel));
    const status = reg.readReg(u32, chan_base + reg.DMA_STATUS_OFF);

    if ((status & reg.DMA_STATUS_ERROR) != 0) return .error_state;
    if ((status & reg.DMA_STATUS_DONE) != 0) return .complete;
    if ((status & reg.DMA_STATUS_BUSY) != 0) return .busy;
    return .idle;
}

/// Abort a DMA transfer
pub fn abort(channel: Channel) void {
    if (!is_arm) return;

    const chan_base = reg.dmaChannelBase(@intFromEnum(channel));

    // Clear command to stop transfer
    reg.writeReg(u32, chan_base + reg.DMA_CMD_OFF, 0);

    // Wait for busy to clear
    var timeout: u32 = 10000;
    while (timeout > 0) : (timeout -= 1) {
        const status = reg.readReg(u32, chan_base + reg.DMA_STATUS_OFF);
        if ((status & reg.DMA_STATUS_BUSY) == 0) break;
    }
}

// ============================================================
// Callback Registration
// ============================================================

/// Register a callback for DMA completion
pub fn setCompletionCallback(channel: Channel, callback: ?*const fn (Channel) void) void {
    completion_callbacks[@intFromEnum(channel)] = callback;
}

/// DMA interrupt handler
fn dmaIrqHandler() void {
    // Check each channel for completion
    var ch: u2 = 0;
    while (ch < 4) : (ch += 1) {
        const channel: Channel = @enumFromInt(ch);
        const state = getState(channel);

        if (state == .complete or state == .error_state) {
            // Call completion callback if registered
            if (completion_callbacks[ch]) |callback| {
                callback(channel);
            }
        }
    }
}

// ============================================================
// Audio-Specific DMA Functions
// ============================================================

/// Configure DMA for audio playback (I2S TX)
pub fn configureAudio(buffer: []const u8) !void {
    try start(.audio, .{
        .ram_addr = @intFromPtr(buffer.ptr),
        .peripheral_addr = reg.IISFIFO_WR,
        .length = buffer.len,
        .request = .i2s,
        .burst = .burst_4,
        .direction = .memory_to_peripheral,
        .interrupt = true,
        .ram_increment = true,
        .peripheral_increment = false,
    });
}

/// Configure DMA for storage read (IDE)
pub fn configureStorageRead(buffer: []u8, ide_data_addr: usize) !void {
    try start(.storage, .{
        .ram_addr = @intFromPtr(buffer.ptr),
        .peripheral_addr = ide_data_addr,
        .length = buffer.len,
        .request = .ide,
        .burst = .burst_4,
        .direction = .peripheral_to_memory,
        .interrupt = true,
        .ram_increment = true,
        .peripheral_increment = false,
    });
}

// ============================================================
// Tests
// ============================================================

test "channel enum values" {
    try std.testing.expectEqual(@as(u2, 0), @intFromEnum(Channel.audio));
    try std.testing.expectEqual(@as(u2, 1), @intFromEnum(Channel.storage));
}

test "config defaults" {
    const config = Config{
        .ram_addr = 0x42000000,
        .peripheral_addr = 0x70002840,
        .length = 1024,
        .request = .i2s,
        .burst = .burst_4,
        .direction = .memory_to_peripheral,
    };
    try std.testing.expect(config.interrupt == true);
    try std.testing.expect(config.ram_increment == true);
}

test "validate address - valid SDRAM" {
    // Valid SDRAM address for read
    try validateAddress(0x10000000, 1024, false);
    // Valid SDRAM address for write
    try validateAddress(0x10001000, 512, true);
}

test "validate address - valid uncached SDRAM" {
    // Uncached SDRAM region
    try validateAddress(0x30000000, 4096, true);
    try validateAddress(0x30010000, 8192, false);
}

test "validate address - valid IRAM" {
    // Internal SRAM
    try validateAddress(0x40000000, 256, true);
    try validateAddress(0x40008000, 1024, false);
}

test "validate address - zero length" {
    try std.testing.expectError(ValidationError.ZeroLength, validateAddress(0x10000000, 0, false));
}

test "validate address - protected bootrom" {
    // BootROM is protected
    try std.testing.expectError(ValidationError.InvalidRamAddress, validateAddress(0x00000000, 256, false));
    try std.testing.expectError(ValidationError.InvalidRamAddress, validateAddress(0x00008000, 512, true));
}

test "validate address - protected security region" {
    try std.testing.expectError(ValidationError.InvalidRamAddress, validateAddress(0x60000100, 16, true));
}

test "validate address - protected flash" {
    try std.testing.expectError(ValidationError.InvalidRamAddress, validateAddress(0x20000000, 4096, true));
    try std.testing.expectError(ValidationError.InvalidRamAddress, validateAddress(0x24000000, 1024, false));
}

test "validate address - transfer exceeds bounds" {
    // Try to transfer past end of IRAM (64KB ends at 0x40010000)
    try std.testing.expectError(ValidationError.TransferExceedsBounds, validateAddress(0x4000F800, 4096, true));
}

test "validate address - out of bounds" {
    // Address in unmapped region
    try std.testing.expectError(ValidationError.RamAddressOutOfBounds, validateAddress(0x80000000, 256, false));
}

test "validate config - valid audio config" {
    const config = Config{
        .ram_addr = 0x30000000, // Uncached SDRAM
        .peripheral_addr = 0x70002840, // I2S FIFO
        .length = 1024,
        .request = .i2s,
        .burst = .burst_4,
        .direction = .memory_to_peripheral,
    };
    try validateConfig(&config);
}

test "validate config - invalid ram address" {
    const config = Config{
        .ram_addr = 0x00000000, // BootROM - protected!
        .peripheral_addr = 0x70002840,
        .length = 1024,
        .request = .i2s,
        .burst = .burst_4,
        .direction = .memory_to_peripheral,
    };
    try std.testing.expectError(ValidationError.InvalidRamAddress, validateConfig(&config));
}

test "validate config - invalid peripheral" {
    const config = Config{
        .ram_addr = 0x10000000,
        .peripheral_addr = 0xDEADBEEF, // Invalid peripheral address
        .length = 1024,
        .request = .i2s,
        .burst = .burst_4,
        .direction = .memory_to_peripheral,
    };
    try std.testing.expectError(ValidationError.InvalidPeripheralAddress, validateConfig(&config));
}
