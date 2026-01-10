# iPod Click Wheel Implementation Guide

## Overview

This document describes the complete, **hardware-verified** click wheel implementation for iPod Video 5th Generation (5G) and 5.5G models using the PP5020/PP5022/PP5024 SoC.

**Status:** All 5 buttons working on real hardware (January 2026)

---

## Hardware Background

The iPod click wheel is an optical touch sensor connected via a serial-like interface to the PortalPlayer SoC. It provides:
- 5 hardware buttons (SELECT, MENU, PLAY, LEFT, RIGHT)
- Touch-sensitive wheel with 96 positions per rotation
- Combined button + wheel data in single packets

---

## Register Map

### Click Wheel Controller Registers

| Register | Address | Description |
|----------|---------|-------------|
| `WHEEL_CTRL` | `0x7000C100` | Control register |
| `WHEEL_STATUS` | `0x7000C104` | Status and interrupt flags |
| `WHEEL_TX` | `0x7000C120` | Transmit data (for polling mode) |
| `WHEEL_DATA` | `0x7000C140` | Receive data (button/wheel state) |

### Device Control Registers

| Register | Address | Description |
|----------|---------|-------------|
| `DEV_EN` | `0x6000600C` | Device enable |
| `DEV_RS` | `0x60006004` | Device reset |
| `DEV_INIT1` | `0x70000010` | Device initialization |

### Important Constants

```zig
const DEV_OPTO: u32 = 0x00010000;       // Click wheel device enable bit
const INIT_BUTTONS: u32 = 0x00040000;   // Button detection enable bit

const WHEEL_STATUS_DATA_READY: u32 = 0x04000000;  // Bit 26 - data available
const WHEEL_STATUS_CLEAR: u32 = 0x0C000000;       // Acknowledge bits
const WHEEL_CTRL_ACK: u32 = 0x60000000;           // Control acknowledge bits

// CRITICAL: Packet validation - only check lower byte!
// MENU button packets do NOT have bit 31 set, so full signature check fails!
const WHEEL_PACKET_VALID_BYTE: u8 = 0x1A;         // Valid packet signature (lower byte only)
```

---

## Button Bit Mapping

### iPod 5.5G (PP5024) - HARDWARE VERIFIED

| Bit | Mask | Button |
|-----|------|--------|
| 8 | `0x00000100` | SELECT (center) |
| 9 | `0x00000200` | RIGHT (forward) |
| 10 | `0x00000400` | LEFT (back/rewind) |
| 11 | `0x00000800` | PLAY/PAUSE |
| 12 | `0x00001000` | MENU (alternative) |
| 13 | `0x00002000` | MENU (primary) |

**CRITICAL:** MENU can appear on bit 12 OR bit 13. Check BOTH for reliable detection!

### Zig Constants

```zig
const BTN_SELECT: u32 = 0x00000100;  // Bit 8
const BTN_RIGHT: u32 = 0x00000200;   // Bit 9
const BTN_LEFT: u32 = 0x00000400;    // Bit 10
const BTN_PLAY: u32 = 0x00000800;    // Bit 11
const BTN_MENU: u32 = 0x00003000;    // Bit 12 OR 13 - check both!
```

---

## Initialization Sequence

The Apple bootloader does NOT fully initialize the click wheel. We must:

```zig
fn initWheel() void {
    // Step 1: Enable OPTO device (click wheel)
    const DEV_EN: *volatile u32 = @ptrFromInt(0x6000600C);
    const DEV_RS: *volatile u32 = @ptrFromInt(0x60006004);
    const DEV_INIT1: *volatile u32 = @ptrFromInt(0x70000010);
    const WHEEL_CTRL: *volatile u32 = @ptrFromInt(0x7000C100);
    const WHEEL_STATUS: *volatile u32 = @ptrFromInt(0x7000C104);

    DEV_EN.* |= 0x00010000;  // DEV_OPTO

    // Step 2: Reset the device
    DEV_RS.* |= 0x00010000;

    // Step 3: Wait for reset (minimum 5 microseconds)
    var i: u32 = 0;
    while (i < 5000) : (i += 1) {
        asm volatile ("nop");
    }

    // Step 4: Release reset
    DEV_RS.* &= ~@as(u32, 0x00010000);

    // Step 5: Enable button detection
    DEV_INIT1.* |= 0x00040000;  // INIT_BUTTONS

    // Step 6: Configure controller
    WHEEL_CTRL.* = 0xC00A1F00;
    WHEEL_STATUS.* = 0x01000000;
}
```

---

## Reading Button State

### Simple Polling (VERIFIED WORKING)

```zig
fn readButtons() u32 {
    const WHEEL_STATUS: *volatile u32 = @ptrFromInt(0x7000C104);
    const WHEEL_DATA: *volatile u32 = @ptrFromInt(0x7000C140);
    const WHEEL_CTRL: *volatile u32 = @ptrFromInt(0x7000C100);

    // Check if data is available (bit 26)
    if ((WHEEL_STATUS.* & 0x04000000) == 0) {
        return 0;  // No data
    }

    // Read the data
    const data = WHEEL_DATA.*;

    // CRITICAL: Acknowledge the read
    WHEEL_STATUS.* = WHEEL_STATUS.* | 0x0C000000;
    WHEEL_CTRL.* = WHEEL_CTRL.* | 0x60000000;

    // Validate packet format - ONLY check lower byte!
    // MENU packets do NOT have bit 31 set, so full signature check fails!
    if ((data & 0xFF) != 0x1A) {
        return 0;  // Invalid packet
    }

    return data;
}

fn getButtonState(data: u32) struct { select: bool, menu: bool, play: bool, left: bool, right: bool } {
    return .{
        .select = (data & 0x00000100) != 0,
        .right = (data & 0x00000200) != 0,
        .left = (data & 0x00000400) != 0,
        .play = (data & 0x00000800) != 0,
        .menu = (data & 0x00003000) != 0,  // Check BOTH bit 12 and 13!
    };
}
```

---

## Wheel Position

The wheel position is encoded in bits 16-22 of the data packet:

```zig
fn getWheelPosition(data: u32) u8 {
    return @truncate((data >> 16) & 0x7F);  // 0-95
}

fn isWheelTouched(data: u32) bool {
    return (data & 0x40000000) != 0;  // Bit 30
}
```

### Calculating Wheel Movement

```zig
fn calculateWheelDelta(old_pos: u8, new_pos: u8) i8 {
    var delta: i16 = @as(i16, new_pos) - @as(i16, old_pos);

    // Handle wraparound (wheel is circular with 96 positions)
    if (delta > 48) delta -= 96;
    if (delta < -48) delta += 96;

    return @intCast(delta);
}
```

---

## Complete Working Example

```zig
const WHEEL_CTRL: *volatile u32 = @ptrFromInt(0x7000C100);
const WHEEL_STATUS: *volatile u32 = @ptrFromInt(0x7000C104);
const WHEEL_DATA: *volatile u32 = @ptrFromInt(0x7000C140);
const DEV_EN: *volatile u32 = @ptrFromInt(0x6000600C);
const DEV_RS: *volatile u32 = @ptrFromInt(0x60006004);
const DEV_INIT1: *volatile u32 = @ptrFromInt(0x70000010);

const BTN_SELECT: u32 = 0x00000100;
const BTN_RIGHT: u32 = 0x00000200;
const BTN_LEFT: u32 = 0x00000400;
const BTN_PLAY: u32 = 0x00000800;
const BTN_MENU: u32 = 0x00003000;  // Bit 12 OR 13!

pub fn init() void {
    DEV_EN.* |= 0x00010000;
    DEV_RS.* |= 0x00010000;
    var i: u32 = 0;
    while (i < 5000) : (i += 1) asm volatile ("nop");
    DEV_RS.* &= ~@as(u32, 0x00010000);
    DEV_INIT1.* |= 0x00040000;
    WHEEL_CTRL.* = 0xC00A1F00;
    WHEEL_STATUS.* = 0x01000000;
}

pub fn poll() ?u32 {
    if ((WHEEL_STATUS.* & 0x04000000) == 0) return null;

    const data = WHEEL_DATA.*;

    WHEEL_STATUS.* |= 0x0C000000;
    WHEEL_CTRL.* |= 0x60000000;

    // CRITICAL: Only check lower byte! MENU packets don't have bit 31 set!
    if ((data & 0xFF) != 0x1A) return null;

    return data;
}

pub fn main() void {
    init();

    while (true) {
        if (poll()) |data| {
            if ((data & BTN_MENU) != 0) {
                // Menu pressed (check both bit 12 and 13)
            } else if ((data & BTN_SELECT) != 0) {
                // Select pressed
            } else if ((data & BTN_PLAY) != 0) {
                // Play pressed
            } else if ((data & BTN_LEFT) != 0) {
                // Left pressed
            } else if ((data & BTN_RIGHT) != 0) {
                // Right pressed
            }
        }
    }
}
```

---

## What We Learned (Debugging Journey)

### Initial Failures

1. **Wrong register addresses** - Early code used incorrect offsets
2. **Wrong DEV_OPTO bit** - Used `0x00800000` instead of `0x00010000`
3. **Wrong button bit for MENU** - Initially used only bit 12 or only bit 13
4. **Wrong packet validation** - Used `(data & 0x800000FF) == 0x8000001A` which fails for MENU!
5. **No acknowledgment** - Didn't clear status after reading
6. **Complex GPIO manipulation** - Unnecessary for simple polling

### Critical Discovery: MENU Packet Format

**MENU button packets do NOT have bit 31 set!**

- Other buttons: packet format `0x8000xxxx` (bit 31 set)
- MENU button: packet format `0x0000xxxx` (bit 31 NOT set)

This means validation must only check the lower byte:
```zig
// WRONG - fails for MENU button!
if ((data & 0x800000FF) == 0x8000001A) { ... }

// CORRECT - works for all buttons including MENU
if ((data & 0xFF) == 0x1A) { ... }
```

### What Works

1. Simple initialization (enable device, reset, configure)
2. Direct register reads (no command sending needed)
3. Acknowledge after each read
4. **Lower-byte-only packet validation** (`(data & 0xFF) == 0x1A`)
5. Checking BOTH bit 12 and bit 13 for MENU

### What Doesn't Work

1. Passive waiting without proper init
2. Reading from wrong register (0x7000C100 instead of 0x7000C140)
3. Bootloader-style polling with GPIO manipulation (crashes on 5.5G)
4. Full signature validation `0x8000001A` (fails for MENU)

---

## Differences from Rockbox Documentation

| Aspect | Rockbox Docs | 5.5G Reality |
|--------|--------------|--------------|
| MENU button | Bit 12 (0x1000) | Bit 12 OR 13 - check both! |
| Packet validation | `0x8000001A` full | Lower byte only `0x1A` |
| MENU packet format | Same as others | NO bit 31 set! |
| Polling | Send command first | Direct read works |
| GPIO manipulation | Required | Not needed |

---

## Hardware Test Results

**Device:** iPod Video 5.5G (80GB, PP5024)
**Date:** January 2026

| Button | Expected | Result |
|--------|----------|--------|
| SELECT | White | WHITE |
| MENU | Red | RED |
| PLAY | Green | GREEN |
| LEFT | Blue | BLUE |
| RIGHT | Yellow | YELLOW |

All 5 buttons confirmed working.

---

## Files

| File | Purpose |
|------|---------|
| `src/kernel/minimal_boot.zig` | Working implementation |
| `docs/ROCKBOX_REFERENCE.md` | Full register reference |
| `docs/HARDWARE_BREAKTHROUGH.md` | Display implementation |

---

## References

- Rockbox source: https://github.com/Rockbox/rockbox
- Rockbox button-clickwheel.c
- Rockbox bootloader/ipod.c
- iPodLinux wiki
- ZigPod hardware testing (this project)
