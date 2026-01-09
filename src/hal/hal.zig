//! Hardware Abstraction Layer (HAL) Interface
//!
//! This module provides a unified interface to all hardware peripherals.
//! The actual implementation is selected at compile time based on the target:
//! - ARM freestanding: Real PP5021C hardware
//! - Other targets: Mock implementations for testing
//!
//! This design enables Test-Driven Development (TDD) by allowing all code
//! to be tested on the host machine before deployment to real hardware.

const std = @import("std");
const builtin = @import("builtin");

// Select implementation based on target
const is_hardware = builtin.cpu.arch == .arm and builtin.os.tag == .freestanding;

/// Real hardware implementation
pub const pp5021c = @import("pp5021c/pp5021c.zig");

/// Mock implementation for testing
pub const mock = @import("mock/mock.zig");

// ============================================================
// HAL Interface Types
// ============================================================

/// Error types that can occur during HAL operations
pub const HalError = error{
    /// I2C/peripheral timeout
    Timeout,
    /// Device not responding or not ready
    DeviceNotReady,
    /// Data transfer error
    TransferError,
    /// Invalid parameter passed to function
    InvalidParameter,
    /// Operation not supported
    NotSupported,
    /// Bus arbitration lost
    ArbitrationLost,
    /// NACK received
    Nack,
    /// Buffer overflow
    BufferOverflow,
    /// Hardware error
    HardwareError,
    /// I/O error (disk, storage, etc.)
    IOError,
    /// Device error (generic device failure)
    DeviceError,
};

/// GPIO pin direction
pub const GpioDirection = enum {
    input,
    output,
};

/// GPIO interrupt trigger mode
pub const GpioInterruptMode = enum {
    none,
    rising_edge,
    falling_edge,
    both_edges,
    high_level,
    low_level,
};

/// I2S audio format
pub const I2sFormat = enum {
    i2s_standard,
    left_justified,
    right_justified,
};

/// I2S sample size
pub const I2sSampleSize = enum {
    bits_16,
    bits_24,
    bits_32,
};

/// ATA/IDE device information
pub const AtaDeviceInfo = struct {
    model: [40]u8,
    serial: [20]u8,
    firmware: [8]u8,
    total_sectors: u64,
    sector_size: u16,
    supports_lba48: bool,
    supports_dma: bool,
    /// Word 217: Nominal Media Rotation Rate
    /// 0x0000 = Not reported, 0x0001 = Non-rotating (SSD/Flash), 0x0401+ = RPM
    rotation_rate: u16 = 1,
    /// Word 169 bit 0: TRIM supported
    supports_trim: bool = false,
};

/// USB endpoint type
pub const UsbEndpointType = enum {
    control,
    isochronous,
    bulk,
    interrupt,
};

/// USB endpoint direction
pub const UsbDirection = enum {
    out, // Host to device
    in, // Device to host
};

/// USB device state
pub const UsbDeviceState = enum {
    disconnected,
    attached,
    powered,
    default,
    addressed,
    configured,
    suspended,
};

/// USB setup packet (8 bytes)
pub const UsbSetupPacket = struct {
    bmRequestType: u8,
    bRequest: u8,
    wValue: u16,
    wIndex: u16,
    wLength: u16,

    /// Check if request direction is device-to-host
    pub fn isDirectionIn(self: UsbSetupPacket) bool {
        return (self.bmRequestType & 0x80) != 0;
    }

    /// Get request type
    pub fn getRequestType(self: UsbSetupPacket) u8 {
        return self.bmRequestType & 0x60;
    }

    /// Get recipient
    pub fn getRecipient(self: UsbSetupPacket) u8 {
        return self.bmRequestType & 0x1F;
    }
};

/// DMA transfer direction
pub const DmaDirection = enum {
    peripheral_to_ram,
    ram_to_peripheral,
};

/// DMA burst size
pub const DmaBurstSize = enum {
    burst_1,
    burst_4,
    burst_8,
    burst_16,
};

/// DMA peripheral request ID
pub const DmaRequest = enum(u8) {
    i2s = 2,
    ide = 7,
    sdhc = 13,
};

/// DMA channel state
pub const DmaChannelState = enum {
    idle,
    running,
    done,
    @"error",
};

/// Battery charging state
pub const ChargingState = enum {
    not_charging,
    pre_charge,
    fast_charge,
    trickle_charge,
    charge_complete,
    charge_error,
};

/// Power source
pub const PowerSource = enum {
    battery,
    usb,
    adapter,
};

/// Battery status information
pub const BatteryStatus = struct {
    voltage_mv: u16, // Battery voltage in millivolts
    percentage: u8, // Estimated charge percentage (0-100)
    charging: ChargingState, // Current charging state
    power_source: PowerSource, // Current power source
    present: bool, // Battery detected
    temperature_ok: bool, // Temperature within limits
};

// ============================================================
// HAL Interface Structure
// ============================================================

/// The HAL interface provides function pointers for all hardware operations.
/// This allows the implementation to be swapped at runtime (for testing)
/// or compile time (for firmware).
pub const Hal = struct {
    // --------------------------------------------------------
    // System Control
    // --------------------------------------------------------

    /// Initialize the entire system
    system_init: *const fn () HalError!void,

    /// Get current system tick count (microseconds)
    get_ticks_us: *const fn () u64,

    /// Delay for specified microseconds
    delay_us: *const fn (us: u32) void,

    /// Delay for specified milliseconds
    delay_ms: *const fn (ms: u32) void,

    /// Enter low-power sleep mode
    sleep: *const fn () void,

    /// Perform system reset
    reset: *const fn () noreturn,

    // --------------------------------------------------------
    // GPIO Operations
    // --------------------------------------------------------

    /// Set GPIO pin direction
    gpio_set_direction: *const fn (port: u4, pin: u5, direction: GpioDirection) void,

    /// Write to GPIO pin
    gpio_write: *const fn (port: u4, pin: u5, value: bool) void,

    /// Read from GPIO pin
    gpio_read: *const fn (port: u4, pin: u5) bool,

    /// Configure GPIO interrupt
    gpio_set_interrupt: *const fn (port: u4, pin: u5, mode: GpioInterruptMode) void,

    // --------------------------------------------------------
    // I2C Operations
    // --------------------------------------------------------

    /// Initialize I2C bus
    i2c_init: *const fn () HalError!void,

    /// Write bytes to I2C device
    i2c_write: *const fn (addr: u7, data: []const u8) HalError!void,

    /// Read bytes from I2C device
    i2c_read: *const fn (addr: u7, buffer: []u8) HalError!usize,

    /// Write then read (combined transaction)
    i2c_write_read: *const fn (addr: u7, write_data: []const u8, read_buffer: []u8) HalError!usize,

    // --------------------------------------------------------
    // I2S Audio Operations
    // --------------------------------------------------------

    /// Initialize I2S interface
    i2s_init: *const fn (sample_rate: u32, format: I2sFormat, sample_size: I2sSampleSize) HalError!void,

    /// Write audio samples to I2S FIFO
    i2s_write: *const fn (samples: []const i16) HalError!usize,

    /// Check if I2S TX FIFO has space
    i2s_tx_ready: *const fn () bool,

    /// Get number of free slots in TX FIFO
    i2s_tx_free_slots: *const fn () usize,

    /// Enable/disable I2S
    i2s_enable: *const fn (enable: bool) void,

    // --------------------------------------------------------
    // Timer Operations
    // --------------------------------------------------------

    /// Configure and start a timer
    timer_start: *const fn (timer_id: u2, period_us: u32, callback: ?*const fn () void) HalError!void,

    /// Stop a timer
    timer_stop: *const fn (timer_id: u2) void,

    // --------------------------------------------------------
    // ATA/IDE Operations
    // --------------------------------------------------------

    /// Initialize ATA controller
    ata_init: *const fn () HalError!void,

    /// Get device information
    ata_identify: *const fn () HalError!AtaDeviceInfo,

    /// Read sectors from storage
    ata_read_sectors: *const fn (lba: u64, count: u16, buffer: []u8) HalError!void,

    /// Write sectors to storage
    ata_write_sectors: *const fn (lba: u64, count: u16, data: []const u8) HalError!void,

    /// Flush write cache
    ata_flush: *const fn () HalError!void,

    /// Put drive in standby mode
    ata_standby: *const fn () HalError!void,

    // --------------------------------------------------------
    // LCD Operations
    // --------------------------------------------------------

    /// Initialize LCD controller
    lcd_init: *const fn () HalError!void,

    /// Write pixel to framebuffer
    lcd_write_pixel: *const fn (x: u16, y: u16, color: u16) void,

    /// Fill rectangle with color
    lcd_fill_rect: *const fn (x: u16, y: u16, width: u16, height: u16, color: u16) void,

    /// Update display from framebuffer
    lcd_update: *const fn (framebuffer: []const u8) HalError!void,

    /// Update rectangular region of display
    lcd_update_rect: *const fn (x: u16, y: u16, width: u16, height: u16, framebuffer: []const u8) HalError!void,

    /// Set backlight on/off
    lcd_set_backlight: *const fn (on: bool) void,

    /// Enter LCD sleep mode
    lcd_sleep: *const fn () void,

    /// Wake LCD from sleep
    lcd_wake: *const fn () HalError!void,

    // --------------------------------------------------------
    // Click Wheel Operations
    // --------------------------------------------------------

    /// Initialize click wheel
    clickwheel_init: *const fn () HalError!void,

    /// Read button state
    clickwheel_read_buttons: *const fn () u8,

    /// Read wheel position (0-95)
    clickwheel_read_position: *const fn () u8,

    /// Get current tick count (milliseconds)
    get_ticks: *const fn () u32,

    // --------------------------------------------------------
    // Cache Operations
    // --------------------------------------------------------

    /// Invalidate instruction cache
    cache_invalidate_icache: *const fn () void,

    /// Invalidate data cache
    cache_invalidate_dcache: *const fn () void,

    /// Flush data cache (write back)
    cache_flush_dcache: *const fn () void,

    /// Enable/disable cache
    cache_enable: *const fn (enable: bool) void,

    // --------------------------------------------------------
    // Interrupt Control
    // --------------------------------------------------------

    /// Enable global interrupts
    irq_enable: *const fn () void,

    /// Disable global interrupts
    irq_disable: *const fn () void,

    /// Check if interrupts are enabled
    irq_enabled: *const fn () bool,

    /// Register interrupt handler
    irq_register: *const fn (irq: u8, handler: *const fn () void) void,

    // --------------------------------------------------------
    // USB Operations
    // --------------------------------------------------------

    /// Initialize USB controller in device mode
    usb_init: *const fn () HalError!void,

    /// Connect USB (enable pull-up)
    usb_connect: *const fn () void,

    /// Disconnect USB (disable pull-up)
    usb_disconnect: *const fn () void,

    /// Check if USB cable is connected
    usb_is_connected: *const fn () bool,

    /// Get current device state
    usb_get_state: *const fn () UsbDeviceState,

    /// Set device address (after SET_ADDRESS request)
    usb_set_address: *const fn (addr: u7) void,

    /// Configure endpoint
    usb_configure_endpoint: *const fn (ep: u8, ep_type: UsbEndpointType, direction: UsbDirection, max_packet_size: u16) HalError!void,

    /// Stall endpoint
    usb_stall_endpoint: *const fn (ep: u8) void,

    /// Unstall endpoint
    usb_unstall_endpoint: *const fn (ep: u8) void,

    /// Write data to endpoint (IN transfer)
    usb_write_endpoint: *const fn (ep: u8, data: []const u8) HalError!usize,

    /// Read data from endpoint (OUT transfer)
    usb_read_endpoint: *const fn (ep: u8, buffer: []u8) HalError!usize,

    /// Get pending interrupt flags
    usb_get_interrupts: *const fn () u32,

    /// Clear interrupt flags
    usb_clear_interrupts: *const fn (flags: u32) void,

    /// Read setup packet from EP0
    usb_read_setup: *const fn () HalError!UsbSetupPacket,

    /// Send ZLP (zero-length packet) on endpoint
    usb_send_zlp: *const fn (ep: u8) HalError!void,

    // --------------------------------------------------------
    // DMA Operations
    // --------------------------------------------------------

    /// Initialize DMA controller
    dma_init: *const fn () HalError!void,

    /// Start a DMA transfer
    dma_start: *const fn (channel: u2, ram_addr: usize, periph_addr: usize, length: u16, direction: DmaDirection, request: DmaRequest, burst: DmaBurstSize) HalError!void,

    /// Wait for DMA transfer to complete
    dma_wait: *const fn (channel: u2) HalError!void,

    /// Check if DMA channel is busy
    dma_is_busy: *const fn (channel: u2) bool,

    /// Get DMA channel state
    dma_get_state: *const fn (channel: u2) DmaChannelState,

    /// Abort a DMA transfer
    dma_abort: *const fn (channel: u2) void,

    // --------------------------------------------------------
    // Watchdog Timer Operations
    // --------------------------------------------------------

    /// Initialize watchdog timer
    wdt_init: *const fn (timeout_ms: u32) HalError!void,

    /// Start watchdog timer
    wdt_start: *const fn () void,

    /// Stop watchdog timer
    wdt_stop: *const fn () void,

    /// Refresh watchdog (prevent reset)
    wdt_refresh: *const fn () void,

    /// Check if last reset was from watchdog
    wdt_caused_reset: *const fn () bool,

    // --------------------------------------------------------
    // RTC Operations
    // --------------------------------------------------------

    /// Initialize RTC
    rtc_init: *const fn () HalError!void,

    /// Get current time (seconds since Unix epoch)
    rtc_get_time: *const fn () u32,

    /// Set current time (seconds since Unix epoch)
    rtc_set_time: *const fn (seconds: u32) void,

    /// Set alarm time (seconds since Unix epoch)
    rtc_set_alarm: *const fn (seconds: u32) void,

    /// Clear alarm
    rtc_clear_alarm: *const fn () void,

    /// Check if alarm has triggered
    rtc_alarm_triggered: *const fn () bool,

    // --------------------------------------------------------
    // Power Management (PMU) Operations
    // --------------------------------------------------------

    /// Initialize PMU
    pmu_init: *const fn () HalError!void,

    /// Get battery status
    pmu_get_battery_status: *const fn () BatteryStatus,

    /// Get battery voltage in millivolts
    pmu_get_battery_voltage: *const fn () u16,

    /// Get estimated battery percentage (0-100)
    pmu_get_battery_percent: *const fn () u8,

    /// Check if charging
    pmu_is_charging: *const fn () bool,

    /// Enable/disable charging
    pmu_set_charging: *const fn (enable: bool) void,

    /// Check if external power is connected
    pmu_external_power_present: *const fn () bool,

    /// Request system shutdown
    pmu_shutdown: *const fn () void,

    /// Set CPU voltage (for power saving)
    pmu_set_cpu_voltage: *const fn (mv: u16) HalError!void,
};

// ============================================================
// Default HAL Instance
// ============================================================

/// Get the default HAL instance for the current target
pub fn getHal() *const Hal {
    if (is_hardware) {
        return &pp5021c.hal;
    } else {
        return &mock.hal;
    }
}

/// Global HAL instance - use this for all hardware access
pub var current_hal: *const Hal = undefined;

/// Initialize the HAL with the appropriate implementation
pub fn init() void {
    current_hal = getHal();
}

// ============================================================
// Convenience Functions
// ============================================================

/// Delay for specified microseconds using current HAL
pub inline fn delayUs(us: u32) void {
    current_hal.delay_us(us);
}

/// Delay for specified milliseconds using current HAL
pub inline fn delayMs(ms: u32) void {
    current_hal.delay_ms(ms);
}

/// Get current system time in microseconds
pub inline fn getTicksUs() u64 {
    return current_hal.get_ticks_us();
}

/// Enter low power sleep mode
pub inline fn sleep() void {
    current_hal.sleep();
}

/// Perform system reset
pub inline fn systemReset() noreturn {
    current_hal.reset();
}

/// Read a 32-bit register
pub inline fn readReg32(addr: u32) u32 {
    const ptr: *volatile u32 = @ptrFromInt(addr);
    return ptr.*;
}

/// Write a 32-bit register
pub inline fn writeReg32(addr: u32, value: u32) void {
    const ptr: *volatile u32 = @ptrFromInt(addr);
    ptr.* = value;
}

// ============================================================
// Click Wheel Convenience Functions
// ============================================================

/// Read click wheel button state
pub inline fn clickwheelReadButtons() u8 {
    return current_hal.clickwheel_read_buttons();
}

// ============================================================
// Watchdog Timer Convenience Functions
// ============================================================

/// Initialize watchdog timer with specified timeout
pub inline fn wdtInit(timeout_ms: u32) HalError!void {
    return current_hal.wdt_init(timeout_ms);
}

/// Start watchdog timer
pub inline fn wdtStart() void {
    current_hal.wdt_start();
}

/// Stop watchdog timer
pub inline fn wdtStop() void {
    current_hal.wdt_stop();
}

/// Refresh watchdog (prevent reset)
pub inline fn wdtRefresh() void {
    current_hal.wdt_refresh();
}

// ============================================================
// Power Management Convenience Functions
// ============================================================

/// Get battery percentage (0-100)
pub inline fn pmuGetBatteryPercent() u8 {
    return current_hal.pmu_get_battery_percent();
}

/// Get battery voltage in millivolts
pub inline fn pmuGetBatteryVoltage() u16 {
    return current_hal.pmu_get_battery_voltage();
}

/// Check if device is charging
pub inline fn pmuIsCharging() bool {
    return current_hal.pmu_is_charging();
}

/// Check if external power is connected
pub inline fn pmuExternalPowerPresent() bool {
    return current_hal.pmu_external_power_present();
}

// ============================================================
// Flash Memory Operations
// ============================================================

/// Write data to flash memory at specified address
/// This is a low-level function for firmware updates
pub fn flashWrite(address: u32, data: []const u8) HalError!void {
    // Flash write requires erasing before writing
    // The actual implementation handles sector-aligned operations

    // For PP5021C, flash is accessed through the ATA interface
    // Convert address to sector and use ATA write
    const sector_size: u32 = 512;
    const start_sector = address / sector_size;
    const sectors_needed = (data.len + sector_size - 1) / sector_size;

    // Write data sector by sector
    var offset: usize = 0;
    var current_sector = start_sector;

    while (offset < data.len) : ({
        offset += sector_size;
        current_sector += 1;
    }) {
        const remaining = data.len - offset;
        const write_len = @min(remaining, sector_size);

        // Prepare sector buffer (pad with 0xFF if partial)
        var sector_buf: [512]u8 = [_]u8{0xFF} ** 512;
        @memcpy(sector_buf[0..write_len], data[offset..][0..write_len]);

        try current_hal.ata_write_sectors(current_sector, 1, &sector_buf);
    }

    // Flush to ensure data is written
    try current_hal.ata_flush();

    _ = sectors_needed;
}

/// Read data from flash memory at specified address
pub fn flashRead(address: u32, buffer: []u8) HalError!void {
    const sector_size: u32 = 512;
    const start_sector = address / sector_size;
    const offset_in_sector = address % sector_size;

    // Read first sector
    var sector_buf: [512]u8 = undefined;
    try current_hal.ata_read_sectors(start_sector, 1, &sector_buf);

    // Copy requested portion
    const first_copy = @min(buffer.len, sector_size - offset_in_sector);
    @memcpy(buffer[0..first_copy], sector_buf[offset_in_sector..][0..first_copy]);

    // If more data needed, read additional sectors
    var remaining = buffer.len - first_copy;
    var current_sector = start_sector + 1;
    var buf_offset = first_copy;

    while (remaining > 0) : ({
        remaining -= @min(remaining, sector_size);
        current_sector += 1;
        buf_offset += sector_size;
    }) {
        try current_hal.ata_read_sectors(current_sector, 1, &sector_buf);
        const copy_len = @min(remaining, sector_size);
        @memcpy(buffer[buf_offset..][0..copy_len], sector_buf[0..copy_len]);
    }
}

// ============================================================
// Tests
// ============================================================

test "HAL initialization" {
    init();
    try std.testing.expect(current_hal == &mock.hal);
}

test "HAL type sizes" {
    // Ensure our types are the expected sizes
    try std.testing.expectEqual(@as(usize, 1), @sizeOf(GpioDirection));
    try std.testing.expectEqual(@as(usize, 1), @sizeOf(GpioInterruptMode));
}
