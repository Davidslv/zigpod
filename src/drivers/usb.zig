//! USB Driver
//!
//! Handles USB detection and Mass Storage Class (MSC) mode for the iPod.
//! When connected to a computer, the device can act as a USB storage device.

const std = @import("std");
const hal = @import("../hal/hal.zig");

// ============================================================
// USB Constants (PP5021C USB Controller)
// ============================================================

/// USB controller base address
const USB_BASE: u32 = 0xC5000000;

/// USB registers
const Reg = struct {
    pub const GAHBCFG: u32 = USB_BASE + 0x008; // AHB Configuration
    pub const GUSBCFG: u32 = USB_BASE + 0x00C; // USB Configuration
    pub const GRSTCTL: u32 = USB_BASE + 0x010; // Reset Control
    pub const GINTSTS: u32 = USB_BASE + 0x014; // Interrupt Status
    pub const GINTMSK: u32 = USB_BASE + 0x018; // Interrupt Mask
    pub const DCTL: u32 = USB_BASE + 0x804; // Device Control
    pub const DSTS: u32 = USB_BASE + 0x808; // Device Status
    pub const GOTGCTL: u32 = USB_BASE + 0x000; // OTG Control
    pub const GOTGINT: u32 = USB_BASE + 0x004; // OTG Interrupt
};

/// USB interrupt flags
const IntFlag = struct {
    pub const USBRST: u32 = 1 << 12; // USB Reset
    pub const ENUMDONE: u32 = 1 << 13; // Enumeration Done
    pub const SESSREQINT: u32 = 1 << 30; // Session Request
    pub const WKUPINT: u32 = 1 << 31; // Wakeup
    pub const CONIDSTSCHNG: u32 = 1 << 28; // Connector ID Status Change
    pub const DISCONNINT: u32 = 1 << 29; // Disconnect
};

// ============================================================
// USB State
// ============================================================

pub const UsbState = enum {
    disconnected,
    connecting,
    connected,
    configured,
    suspended,
    error_state,
};

pub const UsbMode = enum {
    device, // Act as USB device (default)
    host, // Act as USB host (for accessories)
};

pub const UsbSpeed = enum {
    low, // 1.5 Mbps
    full, // 12 Mbps
    high, // 480 Mbps
};

// ============================================================
// USB Driver State
// ============================================================

var state: UsbState = .disconnected;
var mode: UsbMode = .device;
var speed: UsbSpeed = .full;
var initialized: bool = false;
var msc_mode_requested: bool = false;

// Callbacks
var connect_callback: ?*const fn () void = null;
var disconnect_callback: ?*const fn () void = null;

// ============================================================
// Initialization
// ============================================================

/// Initialize USB controller
pub fn init() hal.HalError!void {
    // Soft reset the USB controller
    hal.writeReg32(Reg.GRSTCTL, 0x01);

    // Wait for reset complete
    var timeout: u32 = 1000;
    while (timeout > 0) : (timeout -= 1) {
        if ((hal.readReg32(Reg.GRSTCTL) & 0x01) == 0) break;
        hal.delayUs(10);
    }
    if (timeout == 0) return hal.HalError.Timeout;

    // Configure for device mode
    var cfg = hal.readReg32(Reg.GUSBCFG);
    cfg |= (1 << 30); // Force device mode
    cfg &= ~@as(u32, 1 << 29); // Clear force host mode
    hal.writeReg32(Reg.GUSBCFG, cfg);

    // Wait for mode switch
    hal.delayMs(50);

    // Enable global interrupts
    hal.writeReg32(Reg.GAHBCFG, 0x01);

    // Unmask relevant interrupts
    const int_mask = IntFlag.USBRST | IntFlag.ENUMDONE |
        IntFlag.DISCONNINT | IntFlag.SESSREQINT | IntFlag.WKUPINT;
    hal.writeReg32(Reg.GINTMSK, int_mask);

    // Clear any pending interrupts
    hal.writeReg32(Reg.GINTSTS, 0xFFFFFFFF);

    initialized = true;
    state = .disconnected;
}

/// Shutdown USB controller
pub fn shutdown() void {
    if (!initialized) return;

    // Disable interrupts
    hal.writeReg32(Reg.GINTMSK, 0);

    // Soft disconnect
    var dctl = hal.readReg32(Reg.DCTL);
    dctl |= (1 << 1); // Soft disconnect
    hal.writeReg32(Reg.DCTL, dctl);

    initialized = false;
    state = .disconnected;
}

// ============================================================
// Status Functions
// ============================================================

/// Check if USB cable is connected
pub fn isConnected() bool {
    if (!initialized) return false;

    // Check VBUS valid in OTG control register
    const otgctl = hal.readReg32(Reg.GOTGCTL);
    return (otgctl & (1 << 19)) != 0; // B-Session Valid
}

/// Get current USB state
pub fn getState() UsbState {
    return state;
}

/// Get current USB speed
pub fn getSpeed() UsbSpeed {
    return speed;
}

/// Check if in Mass Storage Class mode
pub fn isMscMode() bool {
    return state == .configured and msc_mode_requested;
}

// ============================================================
// Interrupt Handling
// ============================================================

/// Handle USB interrupt (called from interrupt handler)
pub fn handleInterrupt() void {
    if (!initialized) return;

    const int_status = hal.readReg32(Reg.GINTSTS);
    const int_mask = hal.readReg32(Reg.GINTMSK);
    const active = int_status & int_mask;

    if (active & IntFlag.USBRST != 0) {
        // USB Reset received
        handleReset();
        hal.writeReg32(Reg.GINTSTS, IntFlag.USBRST);
    }

    if (active & IntFlag.ENUMDONE != 0) {
        // Enumeration complete
        handleEnumDone();
        hal.writeReg32(Reg.GINTSTS, IntFlag.ENUMDONE);
    }

    if (active & IntFlag.DISCONNINT != 0) {
        // Disconnected
        handleDisconnect();
        hal.writeReg32(Reg.GINTSTS, IntFlag.DISCONNINT);
    }

    if (active & IntFlag.SESSREQINT != 0) {
        // Session request (cable connected)
        handleConnect();
        hal.writeReg32(Reg.GINTSTS, IntFlag.SESSREQINT);
    }

    if (active & IntFlag.WKUPINT != 0) {
        // Wakeup from suspend
        state = .connected;
        hal.writeReg32(Reg.GINTSTS, IntFlag.WKUPINT);
    }
}

fn handleReset() void {
    state = .connecting;
    speed = .full; // Reset to default
}

fn handleEnumDone() void {
    // Read device status to determine speed
    const dsts = hal.readReg32(Reg.DSTS);
    const enum_speed = (dsts >> 1) & 0x03;

    speed = switch (enum_speed) {
        0 => .high,
        1, 2 => .full,
        3 => .low,
        else => .full,
    };

    state = .connected;
}

fn handleConnect() void {
    state = .connecting;
    if (connect_callback) |cb| {
        cb();
    }
}

fn handleDisconnect() void {
    state = .disconnected;
    msc_mode_requested = false;
    if (disconnect_callback) |cb| {
        cb();
    }
}

// ============================================================
// Mass Storage Class
// ============================================================

/// Request to enter Mass Storage Class mode
pub fn requestMscMode() void {
    msc_mode_requested = true;
}

/// Exit Mass Storage Class mode
pub fn exitMscMode() void {
    msc_mode_requested = false;
}

// ============================================================
// Callbacks
// ============================================================

/// Set callback for USB connection
pub fn setConnectCallback(callback: *const fn () void) void {
    connect_callback = callback;
}

/// Set callback for USB disconnection
pub fn setDisconnectCallback(callback: *const fn () void) void {
    disconnect_callback = callback;
}

// ============================================================
// Polling (for non-interrupt mode)
// ============================================================

/// Poll USB status (use when interrupts not available)
pub fn poll() void {
    if (!initialized) return;

    const connected_now = isConnected();
    const was_connected = state != .disconnected;

    if (connected_now and !was_connected) {
        handleConnect();
    } else if (!connected_now and was_connected) {
        handleDisconnect();
    }
}

// ============================================================
// USB Descriptors
// ============================================================

pub const DeviceDescriptor = extern struct {
    bLength: u8 = 18,
    bDescriptorType: u8 = 1, // Device
    bcdUSB: u16 = 0x0200, // USB 2.0
    bDeviceClass: u8 = 0, // Defined in interface
    bDeviceSubClass: u8 = 0,
    bDeviceProtocol: u8 = 0,
    bMaxPacketSize0: u8 = 64,
    idVendor: u16 = 0x05AC, // Apple
    idProduct: u16 = 0x1209, // Custom product ID
    bcdDevice: u16 = 0x0100,
    iManufacturer: u8 = 1,
    iProduct: u8 = 2,
    iSerialNumber: u8 = 3,
    bNumConfigurations: u8 = 1,
};

/// ZigPod device descriptor
pub const device_descriptor = DeviceDescriptor{
    .idVendor = 0x1209, // pid.codes VID for open source
    .idProduct = 0x0001, // Assigned PID
    .iManufacturer = 1,
    .iProduct = 2,
    .iSerialNumber = 3,
};

// String descriptors
pub const manufacturer_string = "ZigPod";
pub const product_string = "ZigPod Music Player";
pub const serial_string = "00000001";

// ============================================================
// Tests
// ============================================================

test "usb state transitions" {
    state = .disconnected;
    try std.testing.expectEqual(UsbState.disconnected, getState());

    state = .connected;
    try std.testing.expectEqual(UsbState.connected, getState());
}

test "usb speed values" {
    speed = .high;
    try std.testing.expectEqual(UsbSpeed.high, getSpeed());

    speed = .full;
    try std.testing.expectEqual(UsbSpeed.full, getSpeed());
}

test "msc mode" {
    state = .configured;
    msc_mode_requested = false;
    try std.testing.expect(!isMscMode());

    msc_mode_requested = true;
    try std.testing.expect(isMscMode());

    state = .disconnected;
    try std.testing.expect(!isMscMode());
}

test "device descriptor size" {
    try std.testing.expectEqual(@as(usize, 18), @sizeOf(DeviceDescriptor));
}
