# ZigPod Rockbox Reference Guide

## Purpose

This document captures detailed technical findings from Rockbox source code analysis.
Use this as the authoritative reference before implementing any hardware features.

**Last Updated:** 2026-01-10

---

## 1. Click Wheel Implementation

### Register Addresses (CONFIRMED from Rockbox)

| Register | Address | Description |
|----------|---------|-------------|
| `DEV_RS` | `0x60006004` | Device Reset |
| `DEV_EN` | `0x6000600C` | Device Enable |
| `DEV_INIT1` | `0x70000010` | Device Initialization 1 |
| `WHEEL_CTRL` | `0x7000C100` | Click wheel control register |
| `WHEEL_STATUS` | `0x7000C104` | Status/interrupt register |
| `WHEEL_TX` | `0x7000C120` | TX data register |
| `WHEEL_DATA` | `0x7000C140` | RX data (read button/wheel) |

### Device Enable Bits

```
DEV_OPTO      = 0x00010000  // Click wheel optical sensor
INIT_BUTTONS  = 0x00040000  // Button detection enable
```

**IMPORTANT:** Our current code had `DEV_OPTO = 0x00800000` which is WRONG!
Rockbox uses `0x00010000`.

### Initialization Sequence (CORRECT)

```zig
pub fn clickwheel_init() void {
    // 1. Enable OPTO device
    DEV_EN.* |= 0x00010000;  // DEV_OPTO

    // 2. Reset sequence
    DEV_RS.* |= 0x00010000;
    delay_us(5);
    DEV_RS.* &= ~@as(u32, 0x00010000);

    // 3. Enable button detection
    DEV_INIT1.* |= 0x00040000;  // INIT_BUTTONS

    // 4. Configure controller
    WHEEL_CTRL.* = 0xC00A1F00;
    WHEEL_STATUS.* = 0x01000000;
}
```

### Reading Button/Wheel Data

```zig
const WheelData = struct {
    valid: bool,
    buttons: u8,
    wheel_position: u8,
    wheel_touched: bool,
};

pub fn clickwheel_read() WheelData {
    // Check data availability
    if ((WHEEL_STATUS.* & 0x04000000) == 0) {
        return .{ .valid = false, .buttons = 0, .wheel_position = 0, .wheel_touched = false };
    }

    const data = WHEEL_DATA.*;

    // Validate packet: (data & 0x800000FF) must equal 0x8000001A
    if ((data & 0x800000FF) != 0x8000001A) {
        return .{ .valid = false, .buttons = 0, .wheel_position = 0, .wheel_touched = false };
    }

    // Extract buttons from bits 8-12
    var buttons: u8 = 0;
    if (data & 0x00000100 != 0) buttons |= 0x01;  // SELECT
    if (data & 0x00000200 != 0) buttons |= 0x02;  // RIGHT
    if (data & 0x00000400 != 0) buttons |= 0x04;  // LEFT
    if (data & 0x00000800 != 0) buttons |= 0x08;  // PLAY
    if (data & 0x00001000 != 0) buttons |= 0x10;  // MENU

    // Wheel position in bits 16-22 (0-95), bit 30 indicates touch
    const wheel_touched = (data & 0x40000000) != 0;
    const wheel_pos: u8 = @truncate((data >> 16) & 0x7F);

    return .{
        .valid = true,
        .buttons = buttons,
        .wheel_position = wheel_pos,
        .wheel_touched = wheel_touched,
    };
}
```

### Button Bit Definitions

| Bit | Value | Button |
|-----|-------|--------|
| 0 | 0x01 | SELECT (center) |
| 1 | 0x02 | RIGHT (forward) |
| 2 | 0x04 | LEFT (back) |
| 3 | 0x08 | PLAY/PAUSE |
| 4 | 0x10 | MENU |

### Wheel Position

- Range: 0-95 (96 positions per rotation)
- Bit 30 of data indicates wheel is being touched
- Calculate delta with wraparound handling:

```zig
fn calculate_wheel_delta(old_pos: u8, new_pos: u8) i8 {
    var delta: i16 = @as(i16, new_pos) - @as(i16, old_pos);
    if (delta > 48) delta -= 96;
    if (delta < -48) delta += 96;
    return @intCast(delta);
}
```

### Why Our Previous Code Failed

1. **Wrong DEV_OPTO bit:** We used `0x00800000`, Rockbox uses `0x00010000`
2. **Wrong register addresses:** We had WHEEL_DATA at wrong offset
3. **Missing packet validation:** Must check `(data & 0x800000FF) == 0x8000001A`
4. **Missing WHEEL_CTRL configuration:** Need `0xC00A1F00` magic value

---

## 2. Audio/I2S Implementation

### I2S Register Addresses (CONFIRMED from Rockbox pp5020.h)

| Register | Address | Description |
|----------|---------|-------------|
| `IISDIV` | `0x60006080` | Clock divider |
| `IISCONFIG` | `0x70002800` | Main configuration |
| `IISCLK` | `0x70002808` | Clock control |
| `IISFIFO_CFG` | `0x7000280C` | FIFO configuration |
| `IISFIFO_WR` | `0x70002840` | FIFO write (32-bit) |
| `IISFIFO_RD` | `0x70002880` | FIFO read (32-bit) |

### I2C Register (for codec control)

| Register | Address | Description |
|----------|---------|-------------|
| `I2C_BASE` | `0x7000C000` | I2C controller base |

### WM8758 Codec I2C Address

```
iPod: 0x1A (7-bit address)
```

### IISCONFIG Bit Definitions

```zig
const IIS_RESET: u32     = 1 << 31;  // Reset I2S
const IIS_TXFIFOEN: u32  = 1 << 29;  // TX FIFO enable
const IIS_RXFIFOEN: u32  = 1 << 28;  // RX FIFO enable
const IIS_MASTER: u32    = 1 << 25;  // Master mode
const IIS_IRQTX: u32     = 1 << 1;   // TX interrupt
const IIS_IRQRX: u32     = 1 << 0;   // RX interrupt

// Format (bits 10-11)
const IIS_FORMAT_IIS: u32   = 0 << 10;  // Standard I2S
const IIS_FORMAT_LJUST: u32 = 2 << 10;  // Left-justified

// Size (bits 8-9)
const IIS_SIZE_16BIT: u32 = 0 << 8;

// FIFO format (bits 4-6)
const IIS_FIFO_FORMAT_LE16: u32 = 4 << 4;
const IIS_FIFO_FORMAT_LE32: u32 = 3 << 4;
```

### IISFIFO_CFG Bit Definitions

```zig
const IIS_TXCLR: u32 = 1 << 8;   // Clear TX FIFO
const IIS_RXCLR: u32 = 1 << 12;  // Clear RX FIFO
const IIS_TX_EMPTY_LVL_4: u32  = 0 << 0;  // Threshold 4
const IIS_TX_EMPTY_LVL_8: u32  = 1 << 0;  // Threshold 8
const IIS_TX_EMPTY_LVL_12: u32 = 2 << 0;  // Threshold 12
const IIS_RX_FULL_LVL_12: u32  = 2 << 2;  // RX threshold
```

### DMA Register Addresses

| Register | Address | Description |
|----------|---------|-------------|
| `DMA_MASTER_CONTROL` | `0x6000A000` | Global DMA control |
| `DMA_MASTER_STATUS` | `0x6000A004` | DMA status |
| `DMA0_BASE` | `0x6000B000` | DMA channel 0 |
| `DMA1_BASE` | `0x6000B020` | DMA channel 1 |
| `DMA2_BASE` | `0x6000B040` | DMA channel 2 |
| `DMA3_BASE` | `0x6000B060` | DMA channel 3 |

### DMA Channel Register Offsets

```zig
const DMA_CMD: u32      = 0x00;  // Command register
const DMA_STATUS: u32   = 0x04;  // Status register
const DMA_RAM_ADDR: u32 = 0x10;  // RAM address
const DMA_FLAGS: u32    = 0x14;  // Flags
const DMA_PER_ADDR: u32 = 0x18;  // Peripheral address
const DMA_INCR: u32     = 0x1C;  // Increment control
```

### DMA Command Bits

```zig
const DMA_CMD_START: u32      = 1 << 31;  // Start transfer
const DMA_CMD_INTR: u32       = 1 << 30;  // Interrupt on complete
const DMA_CMD_RAM_TO_PER: u32 = 1 << 27;  // Direction: RAM to peripheral
const DMA_CMD_SINGLE: u32     = 1 << 26;  // Single transfer (no auto-reload)
const DMA_CMD_WAIT_REQ: u32   = 1 << 24;  // Wait for DMA request
const DMA_REQ_IIS: u32        = 2 << 16;  // I2S request ID
```

### I2S Initialization Sequence (PP502x)

```zig
fn i2s_init() void {
    // 1. Soft reset
    IISCONFIG.* |= IIS_RESET;
    IISCONFIG.* &= ~IIS_RESET;

    // 2. Configure format
    IISCONFIG.* = IIS_FORMAT_IIS | IIS_SIZE_16BIT | IIS_FIFO_FORMAT_LE16;

    // 3. Set master mode (if codec is slave)
    IISCONFIG.* |= IIS_MASTER;

    // 4. Configure FIFO thresholds
    IISFIFO_CFG.* = IIS_RX_FULL_LVL_12 | IIS_TX_EMPTY_LVL_4;

    // 5. Clear FIFOs
    IISFIFO_CFG.* |= IIS_RXCLR | IIS_TXCLR;

    // 6. Enable TX FIFO
    IISCONFIG.* |= IIS_TXFIFOEN;
}
```

### WM8758 Register Map (Key Registers)

| Register | Address | Purpose |
|----------|---------|---------|
| `RESET` | `0x00` | Software reset |
| `PWRMGMT1` | `0x01` | Power (VMID, bias, PLL) |
| `PWRMGMT2` | `0x02` | Power (ADC, output enable) |
| `PWRMGMT3` | `0x03` | Power (DAC, mixer enable) |
| `AINTFCE` | `0x04` | Audio interface format |
| `CLKCTRL` | `0x06` | Clock control |
| `DACCTRL` | `0x0A` | DAC control |
| `LDACVOL` | `0x0B` | Left DAC volume |
| `RDACVOL` | `0x0C` | Right DAC volume |
| `LOUTMIX` | `0x32` | Left output mixer |
| `ROUTMIX` | `0x33` | Right output mixer |
| `LOUT1VOL` | `0x34` | Left headphone volume |
| `ROUT1VOL` | `0x35` | Right headphone volume |
| `PLLN` | `0x24` | PLL N coefficient |
| `PLLK1` | `0x25` | PLL K1 |
| `PLLK2` | `0x26` | PLL K2 |
| `PLLK3` | `0x27` | PLL K3 |

### WM8758 AINTFCE Bits

```zig
const IWL_16BIT: u16  = 0 << 5;  // 16-bit word length
const IWL_24BIT: u16  = 2 << 5;  // 24-bit word length
const FORMAT_I2S: u16 = 2 << 3;  // I2S format
const FORMAT_LJ: u16  = 1 << 3;  // Left-justified
```

### WM8758 I2C Write Protocol

```zig
fn wmcodec_write(reg: u8, data: u9) void {
    // WM8758 uses 9-bit data with 7-bit register address
    // Byte 1: (reg << 1) | (data >> 8)
    // Byte 2: data & 0xFF
    const byte1: u8 = (reg << 1) | @as(u8, @truncate(data >> 8));
    const byte2: u8 = @truncate(data);
    pp_i2c_send(0x1A, byte1, byte2);
}
```

### WM8758 Initialization Sequence

```zig
fn wm8758_init() void {
    // 1. Reset codec
    wmcodec_write(0x00, 0x000);  // RESET

    // 2. Configure power management
    wmcodec_write(0x01, 0x1EF);  // PWRMGMT1: PLL, bias, VMID
    wmcodec_write(0x02, 0x180);  // PWRMGMT2: Enable outputs
    wmcodec_write(0x03, 0x00F);  // PWRMGMT3: DAC, mixer enable

    // 3. Configure audio interface
    wmcodec_write(0x04, 0x010);  // AINTFCE: 16-bit I2S

    // 4. Configure clock
    wmcodec_write(0x06, 0x100);  // CLKCTRL: Master mode

    // 5. Configure DAC
    wmcodec_write(0x0A, 0x000);  // DACCTRL: Normal polarity

    // 6. Set output mixer
    wmcodec_write(0x32, 0x001);  // LOUTMIX: DAC to output
    wmcodec_write(0x33, 0x001);  // ROUTMIX: DAC to output

    // 7. Set volume
    wmcodec_write(0x34, 0x179);  // LOUT1VOL: 0dB
    wmcodec_write(0x35, 0x179);  // ROUT1VOL: 0dB
}
```

### Audio Playback Flow

```
1. Initialize I2S controller
2. Initialize WM8758 codec via I2C
3. Set up DMA channel for I2S
4. Load PCM data to DMA buffer
5. Start DMA transfer
6. Handle DMA complete interrupt
7. Swap buffers and continue
```

### Interrupt Numbers

```zig
const IIS_IRQ: u32 = 10;  // I2S interrupt (IRQ 10)
const DMA_IRQ: u32 = 26;  // DMA interrupt (IRQ 26)
```

---

## 3. BCM2722 Display

### Confirmed Working (from our hardware tests)

| Register | Address | Description |
|----------|---------|-------------|
| `BCM_DATA32` | `0x30000000` | Data write (32-bit) |
| `BCM_WR_ADDR32` | `0x30010000` | Write address register |
| `BCM_CONTROL` | `0x30030000` | Control register (16-bit) |

### Command Encoding

```
BCM_CMD(x) = (~x << 16) | x

For LCD update (command 0):
BCMCMD_LCD_UPDATE = 0xFFFF0000
```

### Framebuffer Layout

- Address: `BCMA_CMDPARAM = 0xE0000`
- Command: `BCMA_COMMAND = 0x1F8`
- Resolution: 320x240
- Format: RGB565 (16-bit per pixel)
- Write as 32-bit (2 pixels at once)

### Working Fill Screen

```zig
fn fillScreen(color: u32) void {
    bcmWriteAddr(0xE0000);  // CMDPARAM
    var i: u32 = 0;
    while (i < 320 * 240 / 2) : (i += 1) {
        BCM_DATA32.* = color;  // Two pixels per write
    }
    bcmWriteAddr(0x1F8);  // COMMAND
    BCM_DATA32.* = 0xFFFF0000;  // LCD_UPDATE
    BCM_CONTROL.* = 0x31;
}

fn bcmWriteAddr(addr: u32) void {
    BCM_WR_ADDR32.* = addr;
    while ((BCM_CONTROL.* & 0x2) == 0) {
        asm volatile ("nop");
    }
}
```

### Backlight (5.5G Enhancement)

```zig
const PWM_BACKLIGHT: *volatile u32 = @ptrFromInt(0x6000B004);

// Set maximum brightness
PWM_BACKLIGHT.* = 0x0000FFFF;
```

---

## 4. Boot Sequence

### What Apple Bootloader Initializes (DO NOT REINITIALIZE)

1. PLL/Clocks at 80MHz
2. SDRAM controller
3. Cache (I-cache and D-cache)
4. BCM2722 (displays Apple logo)
5. GPIO configuration
6. Power management

### Safe to Do

1. Set up our own stack pointer
2. Disable interrupts
3. Write to display
4. Initialize click wheel
5. Initialize audio codec

### ARM7TDMI Restrictions

**DO NOT USE:**
- `cpsid` / `cpsie` (ARMv6+)
- `wfi` / `wfe` (ARMv6+)
- Thumb-2 instructions
- NEON/VFP

**USE INSTEAD:**
- `msr cpsr_c, #0xdf` (disable IRQ/FIQ)
- Spin loops for waiting
- Pure ARM/Thumb-1

### Working Entry Point

```zig
fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\msr cpsr_c, #0xdf
        \\ldr sp, =0x40008000
        \\bl _zigpod_main
        \\1: b 1b
    );
}
```

---

## 5. Memory Map

### Memory Regions

| Address | Size | Description |
|---------|------|-------------|
| `0x10000000` | 96KB | IRAM (code loaded here by Apple bootloader) |
| `0x40000000` | 32-64MB | SDRAM (stack, data, audio buffers) |

### BCM2722 Display Controller

| Address | Description |
|---------|-------------|
| `0x30000000` | BCM data register (32-bit) |
| `0x30010000` | BCM write address register |
| `0x30030000` | BCM control register (16-bit) |

### Device Control

| Address | Description |
|---------|-------------|
| `0x60006004` | DEV_RS (device reset) |
| `0x6000600C` | DEV_EN (device enable) |
| `0x60006080` | IISDIV (I2S clock divider) |
| `0x6000A000` | DMA master control |
| `0x6000B000` | DMA channel 0 base |
| `0x6000B004` | PWM backlight control |

### Peripheral Controllers

| Address | Description |
|---------|-------------|
| `0x70000010` | DEV_INIT1 (device initialization) |
| `0x70002800` | I2S config (IISCONFIG) |
| `0x70002808` | I2S clock (IISCLK) |
| `0x7000280C` | I2S FIFO config |
| `0x70002840` | I2S FIFO write |
| `0x70002880` | I2S FIFO read |
| `0x7000C000` | I2C controller base |
| `0x7000C100` | Click wheel control |
| `0x7000C104` | Click wheel status |
| `0x7000C120` | Click wheel TX |
| `0x7000C140` | Click wheel data (RX) |

### Interrupt Controller

| Address | Description |
|---------|-------------|
| `0x60004000` | CPU_INT_STAT |
| `0x60004024` | CPU_INT_EN |
| `0x60004028` | CPU_INT_DIS |
| `0x60004100` | CPU_HI_INT_STAT |
| `0x60004104` | CPU_HI_INT_EN |
| `0x60004108` | CPU_HI_INT_DIS |

### Timer

| Address | Description |
|---------|-------------|
| `0x60005010` | USEC_TIMER (microsecond timer, read-only) |

---

## 6. 5.5G Specific Notes

### Hardware Differences from 5G

- PP5024 SoC (99% compatible with PP5021C/5022)
- Brighter LCD (adjust PWM)
- 64MB RAM on 80GB model
- Same BCM2722 LCD controller
- Same WM8758 audio codec

### RAM Detection

```zig
fn detect_ram_size() u32 {
    // Write test pattern at 32MB
    const test_addr_32mb: *volatile u32 = @ptrFromInt(0x42000000);
    const test_addr_0: *volatile u32 = @ptrFromInt(0x40000000);

    test_addr_32mb.* = 0xDEADBEEF;
    test_addr_0.* = 0x12345678;

    // If 32MB mirrors to 0, we have 32MB. Otherwise 64MB.
    if (test_addr_32mb.* == 0x12345678) {
        return 32 * 1024 * 1024;
    } else {
        return 64 * 1024 * 1024;
    }
}
```

---

## 7. Debugging Tips

### Safe Recovery

If device shows "Connect to iTunes":
1. Hold MENU + SELECT until reboot
2. Immediately hold SELECT + PLAY for disk mode
3. Reflash with `ipodpatcher -d` to remove bootloader

### Incremental Testing Order

1. Infinite loop (verify code runs)
2. Fill screen solid color (verify BCM)
3. Change colors (verify control flow)
4. Read click wheel (verify input)
5. Play audio (verify I2S/codec)

### Fatal Error Handler

```zig
fn fatal_error() noreturn {
    // Write disk mode magic to RAM
    const disk_magic: [*]u8 = @ptrFromInt(0x4001FF00);
    @memcpy(disk_magic[0..20], "diskmode\x00\x00hotstuff\x00\x00\x01");
    while (true) {}
}
```

---

## 8. Critical Fixes Required

### Click Wheel - WRONG VALUES IN OUR CODE

**File:** `src/kernel/minimal_boot.zig`

| Issue | Our Value | Correct Value |
|-------|-----------|---------------|
| DEV_OPTO | `0x00800000` | `0x00010000` |
| WHEEL_DATA address | `0x7000C100` | `0x7000C140` |
| WHEEL_CFG address | `0x7000C104` | Should be WHEEL_STATUS |
| Missing packet validation | None | `(data & 0x800000FF) == 0x8000001A` |
| Missing WHEEL_CTRL init | None | `0xC00A1F00` magic value |

### Required Changes to minimal_boot.zig

```zig
// WRONG - Our current definitions
const WHEEL_DATA: *volatile u32 = @ptrFromInt(0x7000C100);  // WRONG!
const WHEEL_CFG: *volatile u32 = @ptrFromInt(0x7000C104);   // WRONG NAME!
const DEV_OPTO: u32 = 0x00800000;  // WRONG!

// CORRECT - From Rockbox
const WHEEL_CTRL: *volatile u32 = @ptrFromInt(0x7000C100);
const WHEEL_STATUS: *volatile u32 = @ptrFromInt(0x7000C104);
const WHEEL_DATA: *volatile u32 = @ptrFromInt(0x7000C140);
const DEV_OPTO: u32 = 0x00010000;
const INIT_BUTTONS: u32 = 0x00040000;

// CORRECT initialization sequence
fn initWheel() void {
    // 1. Enable OPTO device
    DEV_EN.* |= DEV_OPTO;

    // 2. Reset sequence (5us minimum)
    DEV_RS.* |= DEV_OPTO;
    var i: u32 = 0;
    while (i < 500) : (i += 1) asm volatile ("nop");
    DEV_RS.* &= ~DEV_OPTO;

    // 3. Enable button detection
    DEV_INIT1.* |= INIT_BUTTONS;

    // 4. Configure controller (CRITICAL - was missing!)
    WHEEL_CTRL.* = 0xC00A1F00;
    WHEEL_STATUS.* = 0x01000000;
}

// CORRECT read function
fn readWheel() ?WheelPacket {
    // Check for data availability (bit 26)
    if ((WHEEL_STATUS.* & 0x04000000) == 0) return null;

    const data = WHEEL_DATA.*;

    // Validate packet format (CRITICAL - was missing!)
    if ((data & 0x800000FF) != 0x8000001A) return null;

    return .{
        .buttons = extractButtons(data),
        .wheel_pos = @truncate((data >> 16) & 0x7F),
        .wheel_touched = (data & 0x40000000) != 0,
    };
}
```

### Why Click Wheel Didn't Work

1. **Wrong DEV_OPTO bit** - We were enabling the wrong device
2. **Wrong WHEEL_DATA address** - We were reading from control register, not data register
3. **No packet validation** - We weren't checking if data was valid
4. **Missing WHEEL_CTRL magic** - Controller wasn't properly configured

---

## 9. Next Hardware Test Plan

### Test 1: Click Wheel (Incremental)

1. Fix register addresses and DEV_OPTO bit
2. Add proper initialization sequence with WHEEL_CTRL magic
3. Add packet validation
4. Display button state as different colors on screen
5. Display wheel position as a moving bar

### Test 2: Audio (After Click Wheel Works)

1. Initialize I2S controller (no codec yet)
2. Write sine wave data to I2S FIFO
3. Initialize WM8758 codec via I2C
4. Play sine wave through headphone jack
5. Add DMA for continuous playback

### Verification Before Flashing

- [ ] All register addresses match ROCKBOX_REFERENCE.md
- [ ] No ARMv6+ instructions (grep for cpsid, wfi, wfe)
- [ ] Uses minimal linker script
- [ ] Self-contained (no problematic imports)

---

## Sources

- Rockbox source: https://github.com/Rockbox/rockbox
- Rockbox pp5020.h: https://github.com/Rockbox/rockbox/blob/master/firmware/export/pp5020.h
- Rockbox button-clickwheel.c: https://github.com/Rockbox/rockbox/blob/master/firmware/target/arm/ipod/button-clickwheel.c
- Rockbox wm8758.c: https://github.com/Rockbox/rockbox/blob/master/firmware/drivers/audio/wm8758.c
- iPodLinux wiki: http://www.ipodlinux.org/
- Clicky emulator: https://github.com/daniel5151/clicky
- Clickwheel reverse eng: https://github.com/Gigahawk/clickwheel_reverse_eng
