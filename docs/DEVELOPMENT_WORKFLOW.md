# ZigPod Development Workflow Guide

## Lessons Learned (Click Wheel Debugging - 5+ Hours)

We spent too long on trial-and-error hardware testing. Here's how to do better.

---

## Problem: Slow Feedback Loop

Each hardware test cycle:
1. Build firmware (~5s)
2. Put iPod in disk mode (~30s)
3. Unmount disk (~5s)
4. Flash with ipodpatcher (~10s)
5. Eject and boot (~15s)
6. Test and observe (~30s)
7. **Total: ~2 minutes per iteration**

With complex bugs requiring 10-20 iterations = 20-40 minutes minimum.

---

## Solution 1: UART Serial Debugging (RECOMMENDED)

**The iPod has UART on the dock connector!**

### Hardware Setup
- Dock connector pin 11 = Serial TX
- Dock connector pin 13 = Serial RX
- Dock connector pin 1/2 = GND
- Baud rate: 115200, 8-N-1

### Register Addresses (PP5020/PP5022)
```zig
const DEV_EN: *volatile u32 = @ptrFromInt(0x6000600C);
const DEV_SER0: u32 = 0x00000040;  // Serial 0 enable bit

const SER0_BASE: u32 = 0x70006000;
const SER0_LCR: *volatile u32 = @ptrFromInt(SER0_BASE + 0x0C);  // Line control
const SER0_DLL: *volatile u32 = @ptrFromInt(SER0_BASE + 0x00);  // Divisor low
const SER0_DLM: *volatile u32 = @ptrFromInt(SER0_BASE + 0x04);  // Divisor high
const SER0_THR: *volatile u32 = @ptrFromInt(SER0_BASE + 0x00);  // TX holding
const SER0_LSR: *volatile u32 = @ptrFromInt(SER0_BASE + 0x14);  // Line status
```

### Initialization
```zig
fn initUart() void {
    // Enable serial device
    DEV_EN.* |= DEV_SER0;

    // Set divisor latch enable
    SER0_LCR.* = 0x80;

    // Set baud rate: 24MHz / 115200 / 16 = 13
    SER0_DLL.* = 13;
    SER0_DLM.* = 0;

    // 8-N-1, disable divisor latch
    SER0_LCR.* = 0x03;
}

fn uartPutChar(c: u8) void {
    // Wait for TX ready (bit 5 of LSR)
    while ((SER0_LSR.* & 0x20) == 0) {}
    SER0_THR.* = c;
}

fn uartPrint(s: []const u8) void {
    for (s) |c| {
        uartPutChar(c);
    }
}

fn uartPrintHex(val: u32) void {
    const hex = "0123456789ABCDEF";
    uartPrint("0x");
    var i: u5 = 28;
    while (true) : (i -= 4) {
        uartPutChar(hex[(val >> i) & 0xF]);
        if (i == 0) break;
    }
}
```

### Usage
```zig
// In your code:
uartPrint("WHEEL_DATA: ");
uartPrintHex(data);
uartPrint("\r\n");
```

### Computer Setup (macOS)
```bash
# Find the serial device
ls /dev/tty.usb*

# Connect with screen
screen /dev/tty.usbserial-XXXX 115200

# Or with minicom
minicom -D /dev/tty.usbserial-XXXX -b 115200
```

---

## Solution 2: Better Simulator Testing

### Mock Hardware Registers
Create a mock layer that simulates hardware behavior:

```zig
// src/hal/mock_registers.zig
var mock_wheel_status: u32 = 0;
var mock_wheel_data: u32 = 0;

pub fn setMockButtonPress(button: Button) void {
    mock_wheel_status = 0x04000000;  // Data ready
    mock_wheel_data = switch (button) {
        .menu => 0x8000101A,    // Note: bit 31 set + bit 12 + 0x1A
        .select => 0x8000011A,  // bit 31 + bit 8 + 0x1A
        .play => 0x8000081A,    // bit 31 + bit 11 + 0x1A
        .left => 0x8000041A,    // bit 31 + bit 10 + 0x1A
        .right => 0x8000021A,   // bit 31 + bit 9 + 0x1A
        .none => 0x8000001A,    // just signature
    };
}
```

### Test Button Logic in Unit Tests
```zig
test "MENU button detected from packet" {
    const packet: u32 = 0x8000101A;
    const buttons = getButtonState(packet);
    try std.testing.expect(buttons.menu == true);
    try std.testing.expect(buttons.select == false);
}

test "packet validation accepts valid packets" {
    try std.testing.expect(isValidPacket(0x8000001A) == true);
    try std.testing.expect(isValidPacket(0x8000101A) == true);  // MENU
}

test "packet validation rejects invalid packets" {
    try std.testing.expect(isValidPacket(0x0000001A) == false);  // No bit 31
    try std.testing.expect(isValidPacket(0x80000000) == false);  // Wrong low byte
}
```

---

## Solution 3: Systematic Code Analysis Before Hardware

### Checklist Before Any Hardware Test

1. **Read Rockbox source for the specific feature**
   - Trace the EXACT code path from register to function
   - Note any model-specific conditionals
   - Document all magic numbers

2. **Understand the packet/data format**
   - What validation is done?
   - What are the bit positions?
   - Are there error recovery mechanisms?

3. **Write unit tests for parsing logic**
   - Test with known good values
   - Test edge cases
   - Test error conditions

4. **Simulate in software first**
   - Mock the registers
   - Verify logic works

5. **Only THEN test on hardware**
   - With UART debug enabled
   - Print actual register values
   - Compare to expected values

---

## Rockbox Source Code Locations

### Click Wheel
- `firmware/target/arm/ipod/button-clickwheel.c` - Main button code
- Packet validation at lines 114-119
- Button bits at lines 121-130
- Error recovery at lines 262-269

### Audio/I2S
- `firmware/target/arm/pp/i2s-pp.c` - I2S controller
- `firmware/target/arm/pp/wmcodec-pp.c` - WM8758 codec driver
- `firmware/drivers/audio/wm8758.c` - Codec register programming

### ATA/Storage
- `firmware/target/arm/pp/ata-pp5020.c` - ATA driver
- `firmware/target/arm/pp/ata-target.h` - Hardware defines

### UART/Serial
- `firmware/target/arm/pp/uart-pp.c` - Serial driver
- SER0 on dock connector, 115200 baud

### Debug
- `firmware/target/arm/pp/debug-pp.c` - Debug screens
- Shows GPIO states, register values, ADC readings

---

## Hardware Quick Reference

### PP5022 (iPod Video 5.5G)

| Subsystem | Base Address | Enable Bit |
|-----------|--------------|------------|
| Click Wheel | 0x7000C100 | DEV_OPTO (0x10000) |
| I2C | 0x7000D000 | DEV_I2C (0x1000) |
| I2S | 0x70002800 | DEV_I2S (0x800) |
| Serial 0 | 0x70006000 | DEV_SER0 (0x40) |
| ATA/IDE | 0xC3000000 | Always on |

### DEV_EN Register (0x6000600C)
```
Bit 4:  DEV_SER0     (0x00000010) - Actually 0x40 per Rockbox
Bit 11: DEV_I2S      (0x00000800)
Bit 12: DEV_I2C      (0x00001000)
Bit 16: DEV_OPTO     (0x00010000)
```

### Click Wheel Packet Format
```
Bits 31:24 = 0x80 (signature high byte)
Bits 7:0   = 0x1A (signature low byte)
Bit 8      = SELECT
Bit 9      = RIGHT
Bit 10     = LEFT
Bit 11     = PLAY
Bit 12     = MENU
Bit 30     = Wheel touched
Bits 22:16 = Wheel position (0-95)
```

**NOTE:** On our 5.5G, MENU packets may not have bit 31 set. Check both:
- `(data & 0xFF) == 0x1A` for permissive validation
- `(data & 0x800000FF) == 0x8000001A` for strict validation

---

## Development Process Summary

```
1. Research Rockbox source thoroughly
   ↓
2. Document expected behavior
   ↓
3. Write unit tests for logic
   ↓
4. Implement with UART debug output
   ↓
5. Test on hardware with serial monitor
   ↓
6. If issues, check UART output (not just screen colors!)
   ↓
7. Iterate quickly with actual register values visible
```

---

## Files

| Purpose | Location |
|---------|----------|
| Click wheel docs | docs/CLICKWHEEL_IMPLEMENTATION.md |
| Rockbox reference | docs/ROCKBOX_REFERENCE.md |
| Hardware breakthrough | docs/HARDWARE_BREAKTHROUGH.md |
| This workflow guide | docs/DEVELOPMENT_WORKFLOW.md |
