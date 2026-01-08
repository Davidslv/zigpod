//! Mock HAL Implementation
//!
//! This module provides mock implementations of all HAL functions for testing
//! on the host machine. It simulates hardware behavior and records operations
//! for verification in tests.

const std = @import("std");
const hal_types = @import("../hal.zig");
const Hal = hal_types.Hal;
const HalError = hal_types.HalError;
const GpioDirection = hal_types.GpioDirection;
const GpioInterruptMode = hal_types.GpioInterruptMode;
const I2sFormat = hal_types.I2sFormat;
const I2sSampleSize = hal_types.I2sSampleSize;
const AtaDeviceInfo = hal_types.AtaDeviceInfo;
const UsbEndpointType = hal_types.UsbEndpointType;
const UsbDirection = hal_types.UsbDirection;
const UsbDeviceState = hal_types.UsbDeviceState;
const UsbSetupPacket = hal_types.UsbSetupPacket;
const DmaDirection = hal_types.DmaDirection;
const DmaBurstSize = hal_types.DmaBurstSize;
const DmaRequest = hal_types.DmaRequest;
const DmaChannelState = hal_types.DmaChannelState;

// ============================================================
// Mock State
// ============================================================

/// Mock system state for testing
pub const MockState = struct {
    // Time tracking
    tick_counter: u64 = 0,
    time_base: i128 = 0,

    // GPIO state (12 ports, 32 pins each)
    gpio_direction: [12][32]GpioDirection = [_][32]GpioDirection{[_]GpioDirection{.input} ** 32} ** 12,
    gpio_output: [12][32]bool = [_][32]bool{[_]bool{false} ** 32} ** 12,
    gpio_input: [12][32]bool = [_][32]bool{[_]bool{false} ** 32} ** 12,

    // I2C state
    i2c_initialized: bool = false,
    i2c_devices: std.AutoHashMap(u7, I2cDevice) = undefined,

    // I2S state
    i2s_initialized: bool = false,
    i2s_enabled: bool = false,
    i2s_sample_rate: u32 = 44100,
    i2s_buffer: std.ArrayList(i16) = undefined,

    // ATA state
    ata_initialized: bool = false,
    ata_storage: []u8 = undefined,
    ata_sector_size: u16 = 512,

    // LCD state
    lcd_initialized: bool = false,
    lcd_backlight: u8 = 16,
    lcd_sleeping: bool = false,
    framebuffer: [320 * 240]u16 = [_]u16{0} ** (320 * 240),

    // Cache state
    cache_enabled: bool = false,

    // Interrupt state
    irq_enabled: bool = false,
    irq_handlers: [32]?*const fn () void = [_]?*const fn () void{null} ** 32,

    // USB state
    usb_initialized: bool = false,
    usb_connected: bool = false,
    usb_state: UsbDeviceState = .disconnected,
    usb_address: u7 = 0,
    usb_pending_setup: ?UsbSetupPacket = null,
    usb_ep_data: [3]std.ArrayList(u8) = undefined,

    // DMA state
    dma_initialized: bool = false,
    dma_channel_state: [4]DmaChannelState = [_]DmaChannelState{.idle} ** 4,

    // Watchdog state
    wdt_initialized: bool = false,
    wdt_enabled: bool = false,
    wdt_timeout_ms: u32 = 0,

    // RTC state
    rtc_initialized: bool = false,
    rtc_time: u32 = 0,
    rtc_alarm: u32 = 0,
    rtc_alarm_enabled: bool = false,
    rtc_alarm_triggered: bool = false,

    // Allocator for dynamic allocations
    allocator: std.mem.Allocator = undefined,

    /// I2C device simulation
    pub const I2cDevice = struct {
        registers: std.AutoHashMap(u8, u8),
        write_log: std.ArrayList([]const u8),
    };

    /// Initialize mock state with allocator
    pub fn init(allocator: std.mem.Allocator) MockState {
        var state = MockState{};
        state.allocator = allocator;
        state.i2c_devices = std.AutoHashMap(u7, I2cDevice).init(allocator);
        state.i2s_buffer = .{};
        state.time_base = std.time.nanoTimestamp();
        return state;
    }

    /// Cleanup mock state
    pub fn deinit(self: *MockState) void {
        var it = self.i2c_devices.valueIterator();
        while (it.next()) |device| {
            device.registers.deinit();
            for (device.write_log.items) |item| {
                self.allocator.free(item);
            }
            device.write_log.deinit(self.allocator);
        }
        self.i2c_devices.deinit();
        self.i2s_buffer.deinit(self.allocator);
    }

    /// Add a mock I2C device
    pub fn addI2cDevice(self: *MockState, addr: u7) !void {
        const device = I2cDevice{
            .registers = std.AutoHashMap(u8, u8).init(self.allocator),
            .write_log = .{},
        };
        try self.i2c_devices.put(addr, device);
    }

    /// Set I2C device register value
    pub fn setI2cRegister(self: *MockState, addr: u7, reg: u8, value: u8) !void {
        if (self.i2c_devices.getPtr(addr)) |device| {
            try device.registers.put(reg, value);
        }
    }

    /// Get I2C device register value
    pub fn getI2cRegister(self: *MockState, addr: u7, reg: u8) ?u8 {
        if (self.i2c_devices.get(addr)) |device| {
            return device.registers.get(reg);
        }
        return null;
    }
};

/// Global mock state - initialized lazily
var mock_state: ?MockState = null;

/// Get or initialize mock state
fn getState() *MockState {
    if (mock_state == null) {
        mock_state = MockState.init(std.heap.page_allocator);
    }
    return &mock_state.?;
}

/// Reset mock state for testing
pub fn resetState() void {
    if (mock_state) |*state| {
        state.deinit();
    }
    mock_state = MockState.init(std.heap.page_allocator);
}

// ============================================================
// Mock HAL Implementation
// ============================================================

fn mockSystemInit() HalError!void {
    const state = getState();
    state.tick_counter = 0;
    state.time_base = std.time.nanoTimestamp();
}

fn mockGetTicksUs() u64 {
    const state = getState();
    const now = std.time.nanoTimestamp();
    const elapsed_ns = now - state.time_base;
    return @intCast(@divFloor(elapsed_ns, 1000));
}

fn mockDelayUs(us: u32) void {
    std.Thread.sleep(@as(u64, us) * 1000);
}

fn mockDelayMs(ms: u32) void {
    std.Thread.sleep(@as(u64, ms) * 1_000_000);
}

fn mockSleep() void {
    // No-op in mock
}

fn mockReset() noreturn {
    @panic("Mock reset called");
}

// GPIO functions
fn mockGpioSetDirection(port: u4, pin: u5, direction: GpioDirection) void {
    const state = getState();
    if (port < 12 and pin < 32) {
        state.gpio_direction[port][pin] = direction;
    }
}

fn mockGpioWrite(port: u4, pin: u5, value: bool) void {
    const state = getState();
    if (port < 12 and pin < 32) {
        state.gpio_output[port][pin] = value;
    }
}

fn mockGpioRead(port: u4, pin: u5) bool {
    const state = getState();
    if (port < 12 and pin < 32) {
        // Return input value if input, output value if output
        if (state.gpio_direction[port][pin] == .input) {
            return state.gpio_input[port][pin];
        } else {
            return state.gpio_output[port][pin];
        }
    }
    return false;
}

fn mockGpioSetInterrupt(port: u4, pin: u5, mode: GpioInterruptMode) void {
    _ = port;
    _ = pin;
    _ = mode;
    // Mock implementation - just record the setting
}

// I2C functions
fn mockI2cInit() HalError!void {
    const state = getState();
    state.i2c_initialized = true;
}

fn mockI2cWrite(addr: u7, data: []const u8) HalError!void {
    const state = getState();
    if (!state.i2c_initialized) {
        return HalError.DeviceNotReady;
    }
    if (state.i2c_devices.getPtr(addr)) |device| {
        // If data has at least 2 bytes, treat first as register address
        if (data.len >= 2) {
            device.registers.put(data[0], data[1]) catch return HalError.HardwareError;
        }
        // Log the write
        const copy = state.allocator.dupe(u8, data) catch return HalError.HardwareError;
        device.write_log.append(state.allocator, copy) catch return HalError.HardwareError;
    } else {
        return HalError.Nack;
    }
}

fn mockI2cRead(addr: u7, buffer: []u8) HalError!usize {
    const state = getState();
    if (!state.i2c_initialized) {
        return HalError.DeviceNotReady;
    }
    if (state.i2c_devices.get(addr)) |_| {
        // Return zeros for mock reads
        @memset(buffer, 0);
        return buffer.len;
    }
    return HalError.Nack;
}

fn mockI2cWriteRead(addr: u7, write_data: []const u8, read_buffer: []u8) HalError!usize {
    try mockI2cWrite(addr, write_data);
    return try mockI2cRead(addr, read_buffer);
}

// I2S functions
fn mockI2sInit(sample_rate: u32, format: I2sFormat, sample_size: I2sSampleSize) HalError!void {
    _ = format;
    _ = sample_size;
    const state = getState();
    state.i2s_initialized = true;
    state.i2s_sample_rate = sample_rate;
}

fn mockI2sWrite(samples: []const i16) HalError!usize {
    const state = getState();
    if (!state.i2s_initialized or !state.i2s_enabled) {
        return HalError.DeviceNotReady;
    }
    state.i2s_buffer.appendSlice(state.allocator, samples) catch return HalError.BufferOverflow;
    return samples.len;
}

fn mockI2sTxReady() bool {
    const state = getState();
    return state.i2s_initialized and state.i2s_enabled;
}

fn mockI2sTxFreeSlots() usize {
    return 256; // Mock always has space
}

fn mockI2sEnable(enable: bool) void {
    const state = getState();
    state.i2s_enabled = enable;
}

// Timer functions
fn mockTimerStart(timer_id: u2, period_us: u32, callback: ?*const fn () void) HalError!void {
    _ = timer_id;
    _ = period_us;
    _ = callback;
    // Mock implementation - timers don't actually fire
}

fn mockTimerStop(timer_id: u2) void {
    _ = timer_id;
}

// ATA functions
fn mockAtaInit() HalError!void {
    const state = getState();
    state.ata_initialized = true;
    // Allocate 1MB of mock storage
    state.ata_storage = state.allocator.alloc(u8, 1024 * 1024) catch return HalError.HardwareError;
    @memset(state.ata_storage, 0);
}

fn mockAtaIdentify() HalError!AtaDeviceInfo {
    const state = getState();
    if (!state.ata_initialized) {
        return HalError.DeviceNotReady;
    }
    var info = AtaDeviceInfo{
        .model = undefined,
        .serial = undefined,
        .firmware = undefined,
        .total_sectors = state.ata_storage.len / state.ata_sector_size,
        .sector_size = state.ata_sector_size,
        .supports_lba48 = true,
        .supports_dma = false,
    };
    @memcpy(info.model[0..9], "MOCK DISK");
    @memset(info.model[9..], ' ');
    @memcpy(info.serial[0..8], "12345678");
    @memset(info.serial[8..], ' ');
    @memcpy(info.firmware[0..4], "1.00");
    @memset(info.firmware[4..], ' ');
    return info;
}

fn mockAtaReadSectors(lba: u64, count: u16, buffer: []u8) HalError!void {
    const state = getState();
    if (!state.ata_initialized) {
        return HalError.DeviceNotReady;
    }
    const offset = lba * state.ata_sector_size;
    const len = @as(usize, count) * state.ata_sector_size;
    if (offset + len > state.ata_storage.len) {
        return HalError.InvalidParameter;
    }
    if (buffer.len < len) {
        return HalError.InvalidParameter;
    }
    @memcpy(buffer[0..len], state.ata_storage[offset..][0..len]);
}

fn mockAtaWriteSectors(lba: u64, count: u16, data: []const u8) HalError!void {
    const state = getState();
    if (!state.ata_initialized) {
        return HalError.DeviceNotReady;
    }
    const offset = lba * state.ata_sector_size;
    const len = @as(usize, count) * state.ata_sector_size;
    if (offset + len > state.ata_storage.len) {
        return HalError.InvalidParameter;
    }
    if (data.len < len) {
        return HalError.InvalidParameter;
    }
    @memcpy(state.ata_storage[offset..][0..len], data[0..len]);
}

fn mockAtaFlush() HalError!void {
    // No-op in mock
}

fn mockAtaStandby() HalError!void {
    // No-op in mock
}

// LCD functions
fn mockLcdInit() HalError!void {
    const state = getState();
    state.lcd_initialized = true;
    state.lcd_sleeping = false;
    @memset(&state.framebuffer, 0);
}

fn mockLcdWritePixel(x: u16, y: u16, color: u16) void {
    const state = getState();
    if (x < 320 and y < 240) {
        state.framebuffer[@as(usize, y) * 320 + x] = color;
    }
}

fn mockLcdFillRect(x: u16, y: u16, width: u16, height: u16, color: u16) void {
    const state = getState();
    var py: u16 = y;
    while (py < y + height and py < 240) : (py += 1) {
        var px: u16 = x;
        while (px < x + width and px < 320) : (px += 1) {
            state.framebuffer[@as(usize, py) * 320 + px] = color;
        }
    }
}

fn mockLcdUpdate(framebuffer: []const u8) HalError!void {
    const state = getState();
    if (!state.lcd_initialized) {
        return HalError.DeviceNotReady;
    }
    // Copy framebuffer data
    const pixel_count = @min(framebuffer.len / 2, state.framebuffer.len);
    for (0..pixel_count) |i| {
        const offset = i * 2;
        if (offset + 1 < framebuffer.len) {
            state.framebuffer[i] = @as(u16, framebuffer[offset]) | (@as(u16, framebuffer[offset + 1]) << 8);
        }
    }
}

fn mockLcdUpdateRect(x: u16, y: u16, width: u16, height: u16, framebuffer: []const u8) HalError!void {
    const state = getState();
    if (!state.lcd_initialized) {
        return HalError.DeviceNotReady;
    }
    _ = x;
    _ = y;
    _ = width;
    _ = height;
    _ = framebuffer;
    // Mock: just mark as updated (actual rect update logic would copy relevant pixels)
}

fn mockLcdSetBacklight(on: bool) void {
    const state = getState();
    state.lcd_backlight = if (on) 32 else 0;
}

fn mockLcdSleep() void {
    const state = getState();
    state.lcd_sleeping = true;
}

fn mockLcdWake() HalError!void {
    const state = getState();
    state.lcd_sleeping = false;
}

// Click wheel functions
fn mockClickwheelInit() HalError!void {
    // Mock: wheel is always ready
}

fn mockClickwheelReadButtons() u8 {
    // Mock: no buttons pressed by default
    return 0;
}

fn mockClickwheelReadPosition() u8 {
    // Mock: position at 0
    return 0;
}

fn mockGetTicks() u32 {
    const state = getState();
    const now = std.time.nanoTimestamp();
    const elapsed_ns = now - state.time_base;
    return @intCast(@divFloor(elapsed_ns, 1_000_000)); // Convert to milliseconds
}

// Cache functions
fn mockCacheInvalidateIcache() void {
    // No-op in mock
}

fn mockCacheInvalidateDcache() void {
    // No-op in mock
}

fn mockCacheFlushDcache() void {
    // No-op in mock
}

fn mockCacheEnable(enable: bool) void {
    const state = getState();
    state.cache_enabled = enable;
}

// Interrupt functions
fn mockIrqEnable() void {
    const state = getState();
    state.irq_enabled = true;
}

fn mockIrqDisable() void {
    const state = getState();
    state.irq_enabled = false;
}

fn mockIrqEnabled() bool {
    const state = getState();
    return state.irq_enabled;
}

fn mockIrqRegister(irq: u8, handler: *const fn () void) void {
    const state = getState();
    if (irq < 32) {
        state.irq_handlers[irq] = handler;
    }
}

// USB functions
fn mockUsbInit() HalError!void {
    const state = getState();
    state.usb_initialized = true;
    state.usb_state = .powered;
    state.usb_address = 0;
}

fn mockUsbConnect() void {
    const state = getState();
    state.usb_connected = true;
    state.usb_state = .attached;
}

fn mockUsbDisconnect() void {
    const state = getState();
    state.usb_connected = false;
    state.usb_state = .disconnected;
}

fn mockUsbIsConnected() bool {
    const state = getState();
    return state.usb_connected;
}

fn mockUsbGetState() UsbDeviceState {
    const state = getState();
    return state.usb_state;
}

fn mockUsbSetAddress(addr: u7) void {
    const state = getState();
    state.usb_address = addr;
    if (addr > 0) {
        state.usb_state = .addressed;
    } else {
        state.usb_state = .default;
    }
}

fn mockUsbConfigureEndpoint(ep: u8, ep_type: UsbEndpointType, direction: UsbDirection, max_packet_size: u16) HalError!void {
    _ = ep;
    _ = ep_type;
    _ = direction;
    _ = max_packet_size;
    // Mock: just accept the configuration
}

fn mockUsbStallEndpoint(ep: u8) void {
    _ = ep;
    // Mock: no-op
}

fn mockUsbUnstallEndpoint(ep: u8) void {
    _ = ep;
    // Mock: no-op
}

fn mockUsbWriteEndpoint(ep: u8, data: []const u8) HalError!usize {
    _ = ep;
    // Mock: just return the length
    return data.len;
}

fn mockUsbReadEndpoint(ep: u8, buffer: []u8) HalError!usize {
    _ = ep;
    // Mock: return empty
    @memset(buffer, 0);
    return 0;
}

fn mockUsbGetInterrupts() u32 {
    return 0; // Mock: no pending interrupts
}

fn mockUsbClearInterrupts(flags: u32) void {
    _ = flags;
    // Mock: no-op
}

fn mockUsbReadSetup() HalError!UsbSetupPacket {
    const state = getState();
    if (state.usb_pending_setup) |setup| {
        state.usb_pending_setup = null;
        return setup;
    }
    // Return a default GET_DESCRIPTOR request
    return UsbSetupPacket{
        .bmRequestType = 0x80,
        .bRequest = 0x06,
        .wValue = 0x0100,
        .wIndex = 0,
        .wLength = 18,
    };
}

fn mockUsbSendZlp(ep: u8) HalError!void {
    _ = ep;
    // Mock: no-op
}

// DMA functions
fn mockDmaInit() HalError!void {
    const state = getState();
    state.dma_initialized = true;
    for (&state.dma_channel_state) |*ch| {
        ch.* = .idle;
    }
}

fn mockDmaStart(channel: u2, ram_addr: usize, periph_addr: usize, length: u16, direction: DmaDirection, request: DmaRequest, burst: DmaBurstSize) HalError!void {
    _ = ram_addr;
    _ = periph_addr;
    _ = length;
    _ = direction;
    _ = request;
    _ = burst;
    const state = getState();
    if (!state.dma_initialized) return HalError.DeviceNotReady;
    // Mock: immediately complete the transfer
    state.dma_channel_state[channel] = .done;
}

fn mockDmaWait(channel: u2) HalError!void {
    const state = getState();
    if (!state.dma_initialized) return HalError.DeviceNotReady;
    // Mock: already complete
    _ = channel;
}

fn mockDmaIsBusy(channel: u2) bool {
    const state = getState();
    return state.dma_channel_state[channel] == .running;
}

fn mockDmaGetState(channel: u2) DmaChannelState {
    const state = getState();
    return state.dma_channel_state[channel];
}

fn mockDmaAbort(channel: u2) void {
    const state = getState();
    state.dma_channel_state[channel] = .idle;
}

// Watchdog functions
fn mockWdtInit(timeout_ms: u32) HalError!void {
    const state = getState();
    state.wdt_initialized = true;
    state.wdt_timeout_ms = timeout_ms;
    state.wdt_enabled = false;
}

fn mockWdtStart() void {
    const state = getState();
    state.wdt_enabled = true;
}

fn mockWdtStop() void {
    const state = getState();
    state.wdt_enabled = false;
}

fn mockWdtRefresh() void {
    // Mock: no-op (just pretend we refreshed)
}

fn mockWdtCausedReset() bool {
    return false; // Mock: never caused reset
}

// RTC functions
fn mockRtcInit() HalError!void {
    const state = getState();
    state.rtc_initialized = true;
    // Set to current Unix time
    state.rtc_time = @truncate(@as(u64, @intCast(@divFloor(std.time.timestamp(), 1))));
}

fn mockRtcGetTime() u32 {
    const state = getState();
    return state.rtc_time;
}

fn mockRtcSetTime(seconds: u32) void {
    const state = getState();
    state.rtc_time = seconds;
}

fn mockRtcSetAlarm(seconds: u32) void {
    const state = getState();
    state.rtc_alarm = seconds;
    state.rtc_alarm_enabled = true;
}

fn mockRtcClearAlarm() void {
    const state = getState();
    state.rtc_alarm_enabled = false;
    state.rtc_alarm_triggered = false;
}

fn mockRtcAlarmTriggered() bool {
    const state = getState();
    return state.rtc_alarm_triggered;
}

// ============================================================
// HAL Instance
// ============================================================

/// Mock HAL instance
pub const hal = Hal{
    .system_init = mockSystemInit,
    .get_ticks_us = mockGetTicksUs,
    .delay_us = mockDelayUs,
    .delay_ms = mockDelayMs,
    .sleep = mockSleep,
    .reset = mockReset,

    .gpio_set_direction = mockGpioSetDirection,
    .gpio_write = mockGpioWrite,
    .gpio_read = mockGpioRead,
    .gpio_set_interrupt = mockGpioSetInterrupt,

    .i2c_init = mockI2cInit,
    .i2c_write = mockI2cWrite,
    .i2c_read = mockI2cRead,
    .i2c_write_read = mockI2cWriteRead,

    .i2s_init = mockI2sInit,
    .i2s_write = mockI2sWrite,
    .i2s_tx_ready = mockI2sTxReady,
    .i2s_tx_free_slots = mockI2sTxFreeSlots,
    .i2s_enable = mockI2sEnable,

    .timer_start = mockTimerStart,
    .timer_stop = mockTimerStop,

    .ata_init = mockAtaInit,
    .ata_identify = mockAtaIdentify,
    .ata_read_sectors = mockAtaReadSectors,
    .ata_write_sectors = mockAtaWriteSectors,
    .ata_flush = mockAtaFlush,
    .ata_standby = mockAtaStandby,

    .lcd_init = mockLcdInit,
    .lcd_write_pixel = mockLcdWritePixel,
    .lcd_fill_rect = mockLcdFillRect,
    .lcd_update = mockLcdUpdate,
    .lcd_update_rect = mockLcdUpdateRect,
    .lcd_set_backlight = mockLcdSetBacklight,
    .lcd_sleep = mockLcdSleep,
    .lcd_wake = mockLcdWake,

    .clickwheel_init = mockClickwheelInit,
    .clickwheel_read_buttons = mockClickwheelReadButtons,
    .clickwheel_read_position = mockClickwheelReadPosition,
    .get_ticks = mockGetTicks,

    .cache_invalidate_icache = mockCacheInvalidateIcache,
    .cache_invalidate_dcache = mockCacheInvalidateDcache,
    .cache_flush_dcache = mockCacheFlushDcache,
    .cache_enable = mockCacheEnable,

    .irq_enable = mockIrqEnable,
    .irq_disable = mockIrqDisable,
    .irq_enabled = mockIrqEnabled,
    .irq_register = mockIrqRegister,

    .usb_init = mockUsbInit,
    .usb_connect = mockUsbConnect,
    .usb_disconnect = mockUsbDisconnect,
    .usb_is_connected = mockUsbIsConnected,
    .usb_get_state = mockUsbGetState,
    .usb_set_address = mockUsbSetAddress,
    .usb_configure_endpoint = mockUsbConfigureEndpoint,
    .usb_stall_endpoint = mockUsbStallEndpoint,
    .usb_unstall_endpoint = mockUsbUnstallEndpoint,
    .usb_write_endpoint = mockUsbWriteEndpoint,
    .usb_read_endpoint = mockUsbReadEndpoint,
    .usb_get_interrupts = mockUsbGetInterrupts,
    .usb_clear_interrupts = mockUsbClearInterrupts,
    .usb_read_setup = mockUsbReadSetup,
    .usb_send_zlp = mockUsbSendZlp,

    .dma_init = mockDmaInit,
    .dma_start = mockDmaStart,
    .dma_wait = mockDmaWait,
    .dma_is_busy = mockDmaIsBusy,
    .dma_get_state = mockDmaGetState,
    .dma_abort = mockDmaAbort,

    .wdt_init = mockWdtInit,
    .wdt_start = mockWdtStart,
    .wdt_stop = mockWdtStop,
    .wdt_refresh = mockWdtRefresh,
    .wdt_caused_reset = mockWdtCausedReset,

    .rtc_init = mockRtcInit,
    .rtc_get_time = mockRtcGetTime,
    .rtc_set_time = mockRtcSetTime,
    .rtc_set_alarm = mockRtcSetAlarm,
    .rtc_clear_alarm = mockRtcClearAlarm,
    .rtc_alarm_triggered = mockRtcAlarmTriggered,
};

// ============================================================
// Tests
// ============================================================

test "mock GPIO operations" {
    resetState();
    const state = getState();

    // Test GPIO direction
    mockGpioSetDirection(0, 5, .output);
    try std.testing.expectEqual(GpioDirection.output, state.gpio_direction[0][5]);

    // Test GPIO write/read
    mockGpioWrite(0, 5, true);
    try std.testing.expect(mockGpioRead(0, 5));

    mockGpioWrite(0, 5, false);
    try std.testing.expect(!mockGpioRead(0, 5));
}

test "mock I2C operations" {
    resetState();
    const state = getState();

    // Initialize I2C
    try mockI2cInit();
    try std.testing.expect(state.i2c_initialized);

    // Add mock device
    try state.addI2cDevice(0x1A);

    // Write to device
    try mockI2cWrite(0x1A, &[_]u8{ 0x00, 0x55 });

    // Verify register was set
    try std.testing.expectEqual(@as(?u8, 0x55), state.getI2cRegister(0x1A, 0x00));

    // Test NACK for non-existent device
    try std.testing.expectError(HalError.Nack, mockI2cWrite(0x50, &[_]u8{0x00}));
}

test "mock LCD operations" {
    resetState();
    const state = getState();

    // Initialize LCD
    try mockLcdInit();
    try std.testing.expect(state.lcd_initialized);

    // Write pixel
    mockLcdWritePixel(100, 50, 0xF800); // Red
    try std.testing.expectEqual(@as(u16, 0xF800), state.framebuffer[50 * 320 + 100]);

    // Fill rectangle
    mockLcdFillRect(0, 0, 10, 10, 0x07E0); // Green
    try std.testing.expectEqual(@as(u16, 0x07E0), state.framebuffer[0]);
    try std.testing.expectEqual(@as(u16, 0x07E0), state.framebuffer[9 * 320 + 9]);

    // Backlight
    mockLcdSetBacklight(true);
    try std.testing.expectEqual(@as(u8, 32), state.lcd_backlight);
}

test "mock ATA operations" {
    resetState();
    const state = getState();

    // Initialize ATA
    try mockAtaInit();
    try std.testing.expect(state.ata_initialized);

    // Identify
    const info = try mockAtaIdentify();
    try std.testing.expect(info.total_sectors > 0);
    try std.testing.expectEqual(@as(u16, 512), info.sector_size);

    // Write and read back
    var write_data: [512]u8 = undefined;
    for (&write_data, 0..) |*b, i| {
        b.* = @truncate(i);
    }
    try mockAtaWriteSectors(0, 1, &write_data);

    var read_data: [512]u8 = undefined;
    try mockAtaReadSectors(0, 1, &read_data);
    try std.testing.expectEqualSlices(u8, &write_data, &read_data);
}
