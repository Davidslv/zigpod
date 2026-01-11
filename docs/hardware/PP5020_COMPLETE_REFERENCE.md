# PP5020/PP5022/PP5024 Complete Hardware Reference

## Purpose

This is the **authoritative** hardware reference for ZigPod development, extracted from Rockbox source code analysis. Use this document before implementing ANY hardware feature.

**Target**: iPod Video 5th/5.5th Generation (PP5021C/PP5024 SoC)
**Vision**: The ultimate audiophile music player - high-quality audio, no bloat

---

## Table of Contents

1. [Memory Map](#1-memory-map)
2. [CPU & System Control](#2-cpu--system-control)
3. [Interrupt Controller](#3-interrupt-controller)
4. [Timers](#4-timers)
5. [GPIO](#5-gpio)
6. [Click Wheel](#6-click-wheel)
7. [LCD/Display (BCM2722)](#7-lcddisplay-bcm2722)
8. [Audio System (I2S + WM8758)](#8-audio-system-i2s--wm8758)
9. [DMA Engine](#9-dma-engine)
10. [Storage (ATA/IDE)](#10-storage-ataice)
11. [Power Management (PCF50605)](#11-power-management-pcf50605)
12. [UART/Serial](#12-uartserial)
13. [I2C](#13-i2c)
14. [Cache Control](#14-cache-control)
15. [Boot Sequence](#15-boot-sequence)

---

## 1. Memory Map

### Physical Memory Regions

| Address Range | Size | Description |
|---------------|------|-------------|
| `0x00000000-0x000FFFFF` | 1MB | Flash/ROM (remapped) |
| `0x10000000-0x10017FFF` | 96KB | IRAM (Internal RAM) |
| `0x40000000-0x41FFFFFF` | 32MB | SDRAM (30GB model) |
| `0x40000000-0x43FFFFFF` | 64MB | SDRAM (60/80GB model) |

### Memory-Mapped I/O Regions

| Address Range | Description |
|---------------|-------------|
| `0x30000000-0x30070000` | BCM2722 LCD Controller |
| `0x60000000-0x60007FFF` | System Control |
| `0x6000A000-0x6000BFFF` | DMA Engine |
| `0x6000D000-0x6000D1FF` | GPIO Ports A-L |
| `0x70000000-0x70000FFF` | Device Initialization |
| `0x70002800-0x700028FF` | I2S Controller |
| `0x70006000-0x7000607F` | UART (Serial 0 & 1) |
| `0x7000C000-0x7000C0FF` | I2C Controller |
| `0x7000C100-0x7000C1FF` | Click Wheel Controller |
| `0xC3000000-0xC30001FF` | IDE/ATA Controller |
| `0xC5000000-0xC5FFFFFF` | USB Controller |

---

## 2. CPU & System Control

### Processor Identification

| Register | Address | Description |
|----------|---------|-------------|
| `PROCESSOR_ID` | `0x60000000` | CPU/COP identification |
| `CPU_CTL` | `0x60007000` | CPU control register |
| `COP_CTL` | `0x60007004` | COP control register |

```zig
const PROC_ID_CPU: u8 = 0x55;  // Main CPU identifier
const PROC_ID_COP: u8 = 0xAA;  // Coprocessor identifier
```

### Processor Control Flags

```zig
const PROC_SLEEP: u32     = 0x80000000;  // Put processor to sleep
const PROC_WAIT_CNT: u32  = 0x40000000;  // Wait for counter
const PROC_WAKE_INT: u32  = 0x20000000;  // Wake on interrupt
const PROC_CNT_USEC: u32  = 0x02000000;  // Count microseconds
const PROC_CNT_MSEC: u32  = 0x01000000;  // Count milliseconds
const PROC_WAKE: u32      = 0x00000000;  // Wake processor
```

### Device Enable/Reset

| Register | Address | Description |
|----------|---------|-------------|
| `DEV_RS` | `0x60006004` | Device Reset |
| `DEV_RS2` | `0x60006008` | Device Reset 2 |
| `DEV_EN` | `0x6000600C` | Device Enable |
| `DEV_EN2` | `0x60006010` | Device Enable 2 |

### Device Enable Bits (DEV_EN)

```zig
const DEV_EXTCLOCKS: u32 = 0x00000002;  // External clocks
const DEV_SYSTEM: u32    = 0x00000004;  // System
const DEV_USB0: u32      = 0x00000008;  // USB 0
const DEV_SER0: u32      = 0x00000040;  // Serial 0 (UART)
const DEV_SER1: u32      = 0x00000080;  // Serial 1
const DEV_I2S: u32       = 0x00000800;  // I2S Audio
const DEV_I2C: u32       = 0x00001000;  // I2C
const DEV_ATA: u32       = 0x00004000;  // ATA/IDE
const DEV_OPTO: u32      = 0x00010000;  // Click Wheel (CRITICAL!)
const DEV_PWM: u32       = 0x00020000;  // PWM (backlight)
const DEV_USB1: u32      = 0x00400000;  // USB 1
const DEV_FIREWIRE: u32  = 0x00800000;  // FireWire
const DEV_IDE0: u32      = 0x02000000;  // IDE 0
const DEV_LCD: u32       = 0x04000000;  // LCD
```

### Clock Control

| Register | Address | Description |
|----------|---------|-------------|
| `CLOCK_SOURCE` | `0x60006020` | Clock source selection |
| `PLL_CONTROL` | `0x60006034` | PLL configuration |
| `PLL_STATUS` | `0x6000603C` | PLL status |

### Device Initialization

| Register | Address | Description |
|----------|---------|-------------|
| `PP_VER1` | `0x70000000` | PP version 1 |
| `PP_VER2` | `0x70000004` | PP version 2 |
| `DEV_INIT1` | `0x70000010` | Device init 1 |
| `DEV_INIT2` | `0x70000020` | Device init 2 |

```zig
const INIT_BUTTONS: u32 = 0x00040000;  // Enable button detection
const INIT_PLL: u32     = 0x40000000;  // PLL initialized
const INIT_USB: u32     = 0x80000000;  // USB initialized
```

---

## 3. Interrupt Controller

### CPU Interrupt Registers

| Register | Address | Description |
|----------|---------|-------------|
| `CPU_INT_STAT` | `0x60004000` | Interrupt status |
| `CPU_FIQ_STAT` | `0x60004008` | FIQ status |
| `CPU_INT_EN_STAT` | `0x60004020` | Enable status |
| `CPU_INT_EN` | `0x60004024` | Enable interrupts |
| `CPU_INT_DIS` | `0x60004028` | Disable interrupts |
| `CPU_INT_PRIORITY` | `0x6000402C` | Priority |

### High-Priority Interrupt Registers

| Register | Address | Description |
|----------|---------|-------------|
| `CPU_HI_INT_STAT` | `0x60004100` | HI status |
| `CPU_HI_INT_EN` | `0x60004124` | HI enable |
| `CPU_HI_INT_DIS` | `0x60004128` | HI disable |

### IRQ Numbers

| IRQ | Number | Mask |
|-----|--------|------|
| TIMER1 | 0 | `0x00000001` |
| TIMER2 | 1 | `0x00000002` |
| MAILBOX | 4 | `0x00000010` |
| I2S | 10 | `0x00000400` |
| USB | 20 | `0x00100000` |
| IDE | 23 | `0x00800000` |
| FIREWIRE | 25 | `0x02000000` |
| DMA | 26 | `0x04000000` |
| HI_IRQ | 30 | `0x40000000` |

### High-Priority IRQ Numbers (GPIO)

| IRQ | Number | Mask |
|-----|--------|------|
| GPIO0 | 32 | `0x00000001` |
| GPIO1 | 33 | `0x00000002` |
| GPIO2 | 34 | `0x00000004` |
| SER0 | 36 | `0x00000010` |
| SER1 | 37 | `0x00000020` |
| I2C | 40 | `0x00000100` |

---

## 4. Timers

### Timer Registers

| Register | Address | Description |
|----------|---------|-------------|
| `TIMER1_CFG` | `0x60005000` | Timer 1 config |
| `TIMER1_VAL` | `0x60005004` | Timer 1 value |
| `TIMER2_CFG` | `0x60005008` | Timer 2 config |
| `TIMER2_VAL` | `0x6000500C` | Timer 2 value |
| `USEC_TIMER` | `0x60005010` | Microsecond timer (RO) |
| `RTC` | `0x60005014` | Real-time clock |

### Timer Configuration

```zig
// Timer frequency is 1MHz (TIMER_FREQ = 1000000)
// To set a timer for N cycles:
// TIMER2_CFG = 0xC0000000 | (cycles - 1)

fn configureTimer(cycles: u32) void {
    TIMER2_CFG.* = 0xC0000000 | (cycles - 1);
}

// Read current microseconds
fn getMicroseconds() u32 {
    return USEC_TIMER.*;
}
```

---

## 5. GPIO

### GPIO Base Address

`GPIO_BASE_ADDR = 0x6000D000`

### GPIO Port Register Offsets

For each port (A-L), registers are at:
- `ENABLE`: Base + 0x00 + (port * 4)
- `OUTPUT_EN`: Base + 0x10 + (port * 4)
- `OUTPUT_VAL`: Base + 0x20 + (port * 4)
- `INPUT_VAL`: Base + 0x30 + (port * 4)
- `INT_STAT`: Base + 0x40 + (port * 4)
- `INT_EN`: Base + 0x50 + (port * 4)
- `INT_LEV`: Base + 0x60 + (port * 4)
- `INT_CLR`: Base + 0x70 + (port * 4)

### GPIO Port A (Example)

| Register | Address |
|----------|---------|
| `GPIOA_ENABLE` | `0x6000D000` |
| `GPIOA_OUTPUT_EN` | `0x6000D010` |
| `GPIOA_OUTPUT_VAL` | `0x6000D020` |
| `GPIOA_INPUT_VAL` | `0x6000D030` |

### GPIO Port B (Click Wheel related)

| Register | Address |
|----------|---------|
| `GPIOB_ENABLE` | `0x6000D004` |
| `GPIOB_OUTPUT_EN` | `0x6000D014` |
| `GPIOB_OUTPUT_VAL` | `0x6000D024` |
| `GPIOB_INPUT_VAL` | `0x6000D034` |

### Extended GPIO (32-bit)

| Register | Address |
|----------|---------|
| `GPO32_VAL` | `0x70000080` |
| `GPO32_ENABLE` | `0x70000084` |

---

## 6. Click Wheel

### Register Addresses

| Register | Address | Description |
|----------|---------|-------------|
| `WHEEL_CTRL` | `0x7000C100` | Control register |
| `WHEEL_STATUS` | `0x7000C104` | Status register |
| `WHEEL_TX` | `0x7000C120` | Transmit data |
| `WHEEL_DATA` | `0x7000C140` | Receive data (buttons/wheel) |

### Initialization Sequence

```zig
pub fn clickwheelInit() void {
    // 1. Enable OPTO device (CRITICAL: use 0x00010000, NOT 0x00800000!)
    DEV_EN.* |= 0x00010000;  // DEV_OPTO

    // 2. Reset sequence
    DEV_RS.* |= 0x00010000;

    // 3. Wait minimum 5 microseconds
    var i: u32 = 0;
    while (i < 500) : (i += 1) {
        asm volatile ("nop");
    }

    // 4. Release reset
    DEV_RS.* &= ~@as(u32, 0x00010000);

    // 5. Enable button detection
    DEV_INIT1.* |= 0x00040000;  // INIT_BUTTONS

    // 6. Configure controller (CRITICAL magic values!)
    WHEEL_CTRL.* = 0xC00A1F00;
    WHEEL_STATUS.* = 0x01000000;
}
```

### Reading Buttons and Wheel

```zig
pub fn clickwheelRead() ?WheelPacket {
    // Check for data availability (bit 26)
    if ((WHEEL_STATUS.* & 0x04000000) == 0) {
        return null;
    }

    const data = WHEEL_DATA.*;

    // Acknowledge read (CRITICAL!)
    WHEEL_STATUS.* |= 0x0C000000;
    WHEEL_CTRL.* |= 0x60000000;

    // Validate packet
    // IMPORTANT: On 5.5G, MENU packets may NOT have bit 31 set!
    // Use permissive validation - only check lower byte
    if ((data & 0xFF) != 0x1A) {
        return null;
    }

    return WheelPacket{
        .buttons = extractButtons(data),
        .wheel_pos = @truncate((data >> 16) & 0x7F),
        .wheel_touched = (data & 0x40000000) != 0,
    };
}
```

### Button Bit Mapping (iPod 5.5G VERIFIED)

| Bit | Mask | Button |
|-----|------|--------|
| 8 | `0x00000100` | SELECT (center) |
| 9 | `0x00000200` | RIGHT (forward) |
| 10 | `0x00000400` | LEFT (back) |
| 11 | `0x00000800` | PLAY/PAUSE |
| 12 | `0x00001000` | MENU (alternative) |
| 13 | `0x00002000` | MENU (primary) |

**CRITICAL**: Check BOTH bit 12 AND bit 13 for MENU button!

```zig
const BTN_SELECT: u32 = 0x00000100;
const BTN_RIGHT: u32  = 0x00000200;
const BTN_LEFT: u32   = 0x00000400;
const BTN_PLAY: u32   = 0x00000800;
const BTN_MENU: u32   = 0x00003000;  // Bit 12 OR 13!
```

### Wheel Position

- Range: 0-95 (96 positions per rotation)
- Bit 30 indicates wheel is being touched
- Handle wraparound for delta calculation:

```zig
fn calculateWheelDelta(old_pos: u8, new_pos: u8) i8 {
    var delta: i16 = @as(i16, new_pos) - @as(i16, old_pos);
    if (delta > 48) delta -= 96;
    if (delta < -48) delta += 96;
    return @intCast(delta);
}
```

---

## 7. LCD/Display (BCM2722)

### BCM Register Addresses

| Register | Address | Description |
|----------|---------|-------------|
| `BCM_DATA16` | `0x30000000` | 16-bit data write |
| `BCM_DATA32` | `0x30000000` | 32-bit data write |
| `BCM_WR_ADDR16` | `0x30010000` | 16-bit write address |
| `BCM_WR_ADDR32` | `0x30010000` | 32-bit write address |
| `BCM_RD_ADDR` | `0x30020000` | Read address |
| `BCM_CONTROL` | `0x30030000` | Control register |

### BCM Internal Addresses

| Address | Description |
|---------|-------------|
| `0x00000` | SRAM base |
| `0x000E0000` | Command parameters (framebuffer) |
| `0x000001F8` | Command register |
| `0x000001FC` | Status register |

### Command Encoding

```zig
// BCM commands use inverted upper 16 bits
fn bcmCmd(x: u16) u32 {
    return (~@as(u32, x) << 16) | @as(u32, x);
}

const BCM_CMD_LCD_UPDATE: u32 = 0xFFFF0000;  // bcmCmd(0)
const BCM_CMD_LCD_SLEEP: u32  = bcmCmd(8);
```

### LCD Update Sequence

```zig
fn updateLcd(framebuffer: []const u16) void {
    // 1. Set write address to parameter region
    bcmWriteAddr(0xE0000);

    // 2. Write framebuffer data (320x240 pixels, RGB565)
    // Write 2 pixels at a time (32-bit)
    var i: usize = 0;
    while (i < framebuffer.len) : (i += 2) {
        const pixel0: u32 = framebuffer[i];
        const pixel1: u32 = if (i + 1 < framebuffer.len) framebuffer[i + 1] else 0;
        BCM_DATA32.* = pixel0 | (pixel1 << 16);
    }

    // 3. Set write address to command register
    bcmWriteAddr(0x1F8);

    // 4. Send LCD_UPDATE command
    BCM_DATA32.* = BCM_CMD_LCD_UPDATE;

    // 5. Trigger update
    BCM_CONTROL.* = 0x31;
}

fn bcmWriteAddr(addr: u32) void {
    BCM_WR_ADDR32.* = addr;
    // Wait for ready (bit 1)
    while ((BCM_CONTROL.* & 0x2) == 0) {
        asm volatile ("nop");
    }
}
```

### Backlight Control (PWM)

```zig
const PWM_BACKLIGHT: *volatile u32 = @ptrFromInt(0x6000B004);

fn setBacklight(brightness: u16) void {
    PWM_BACKLIGHT.* = brightness;  // 0x0000 = off, 0xFFFF = max
}
```

### Display Specifications

- Resolution: 320x240 (QVGA)
- Color format: RGB565 (16-bit)
- Bits per pixel: 16
- Framebuffer size: 320 * 240 * 2 = 153,600 bytes

---

## 8. Audio System (I2S + WM8758)

### I2S Register Addresses

| Register | Address | Description |
|----------|---------|-------------|
| `IISDIV` | `0x60006080` | Clock divider |
| `IISCONFIG` | `0x70002800` | Main configuration |
| `IISCLK` | `0x70002808` | Clock control |
| `IISFIFO_CFG` | `0x7000280C` | FIFO configuration |
| `IISFIFO_WR` | `0x70002840` | FIFO write (32-bit) |
| `IISFIFO_RD` | `0x70002880` | FIFO read |

### I2S Configuration Bits

```zig
const IIS_RESET: u32     = 0x80000000;  // Software reset
const IIS_TXFIFOEN: u32  = 0x20000000;  // TX FIFO enable
const IIS_RXFIFOEN: u32  = 0x10000000;  // RX FIFO enable
const IIS_MASTER: u32    = 0x02000000;  // Master mode
const IIS_IRQTX: u32     = 0x00000002;  // TX interrupt
const IIS_IRQRX: u32     = 0x00000001;  // RX interrupt

// Format (bits 10-11)
const IIS_FORMAT_IIS: u32   = 0x00000000;  // Standard I2S
const IIS_FORMAT_LJUST: u32 = 0x00000800;  // Left-justified

// Size (bits 8-9)
const IIS_SIZE_16BIT: u32 = 0x00000000;

// FIFO format (bits 4-6)
const IIS_FIFO_FORMAT_LE16: u32   = 0x00000040;
const IIS_FIFO_FORMAT_LE16_2: u32 = 0x00000070;
const IIS_FIFO_FORMAT_LE32: u32   = 0x00000030;
```

### I2S FIFO Configuration

```zig
const IIS_RXCLR: u32 = 0x00001000;  // Clear RX FIFO
const IIS_TXCLR: u32 = 0x00000100;  // Clear TX FIFO

const IIS_RX_FULL_LVL_4: u32  = 0x00000010;
const IIS_RX_FULL_LVL_8: u32  = 0x00000020;
const IIS_RX_FULL_LVL_12: u32 = 0x00000030;

const IIS_TX_EMPTY_LVL_4: u32  = 0x00000001;
const IIS_TX_EMPTY_LVL_8: u32  = 0x00000002;
const IIS_TX_EMPTY_LVL_12: u32 = 0x00000003;
```

### I2S Initialization

```zig
fn i2sInit() void {
    // 1. Enable I2S device
    DEV_EN.* |= DEV_I2S;

    // 2. Software reset
    IISCONFIG.* |= IIS_RESET;
    IISCONFIG.* &= ~IIS_RESET;

    // 3. Configure format: I2S, 16-bit, LE16
    IISCONFIG.* = IIS_FORMAT_IIS | IIS_SIZE_16BIT | IIS_FIFO_FORMAT_LE16_2;

    // 4. Set master mode
    IISCONFIG.* |= IIS_MASTER;

    // 5. Configure clock (for 44.1kHz)
    IISCLK.* = 33;
    IISDIV.* = 7;

    // 6. Configure FIFO thresholds
    IISFIFO_CFG.* = IIS_RX_FULL_LVL_12 | IIS_TX_EMPTY_LVL_4;

    // 7. Clear FIFOs
    IISFIFO_CFG.* |= IIS_RXCLR | IIS_TXCLR;

    // 8. Enable TX FIFO
    IISCONFIG.* |= IIS_TXFIFOEN;
}
```

### WM8758 Codec (I2C Address: 0x1A)

#### Key Registers

| Register | Address | Purpose |
|----------|---------|---------|
| `RESET` | `0x00` | Software reset |
| `PWRMGMT1` | `0x01` | Power (VMID, bias, PLL) |
| `PWRMGMT2` | `0x02` | Power (ADC, output) |
| `PWRMGMT3` | `0x03` | Power (DAC, mixer) |
| `AINTFCE` | `0x04` | Audio interface format |
| `CLKCTRL` | `0x06` | Clock control |
| `DACCTRL` | `0x0A` | DAC control |
| `LDACVOL` | `0x0B` | Left DAC volume |
| `RDACVOL` | `0x0C` | Right DAC volume |
| `LOUTMIX` | `0x32` | Left output mixer |
| `ROUTMIX` | `0x33` | Right output mixer |
| `LOUT1VOL` | `0x34` | Left headphone volume |
| `ROUT1VOL` | `0x35` | Right headphone volume |

#### I2C Write Protocol

```zig
// WM8758 uses 9-bit data with 7-bit register address
fn wmcodecWrite(reg: u8, data: u9) void {
    const byte1: u8 = (reg << 1) | @as(u8, @truncate(data >> 8));
    const byte2: u8 = @truncate(data);
    i2cWrite(0x1A, &[_]u8{ byte1, byte2 });
}
```

#### Codec Initialization for Audiophile Playback

```zig
fn wm8758Init() void {
    // 1. Reset codec
    wmcodecWrite(0x00, 0x000);

    // 2. Power management - enable all needed for playback
    wmcodecWrite(0x01, 0x1EF);  // PWRMGMT1: PLL, bias, VMID
    wmcodecWrite(0x02, 0x180);  // PWRMGMT2: Enable outputs
    wmcodecWrite(0x03, 0x00F);  // PWRMGMT3: DAC, mixer enable

    // 3. Audio interface: 16-bit I2S
    wmcodecWrite(0x04, 0x010);

    // 4. Clock: Master mode
    wmcodecWrite(0x06, 0x100);

    // 5. DAC: Normal polarity, no soft mute
    wmcodecWrite(0x0A, 0x000);

    // 6. Output mixer: DAC to output
    wmcodecWrite(0x32, 0x001);  // LOUTMIX
    wmcodecWrite(0x33, 0x001);  // ROUTMIX

    // 7. Volume: 0dB (for bit-perfect output)
    wmcodecWrite(0x34, 0x179);  // LOUT1VOL
    wmcodecWrite(0x35, 0x179);  // ROUT1VOL
}
```

---

## 9. DMA Engine

### DMA Master Registers

| Register | Address | Description |
|----------|---------|-------------|
| `DMA_MASTER_CONTROL` | `0x6000A000` | Global enable |
| `DMA_MASTER_STATUS` | `0x6000A004` | Status |
| `DMA_REQ_STATUS` | `0x6000A008` | Request status |

### DMA Channel Base Addresses

| Channel | Base Address |
|---------|--------------|
| DMA0 | `0x6000B000` |
| DMA1 | `0x6000B020` |
| DMA2 | `0x6000B040` |
| DMA3 | `0x6000B060` |

### DMA Channel Register Offsets

| Offset | Register | Description |
|--------|----------|-------------|
| `0x00` | `CMD` | Command |
| `0x04` | `STATUS` | Status |
| `0x10` | `RAM_ADDR` | RAM address |
| `0x14` | `FLAGS` | Flags |
| `0x18` | `PER_ADDR` | Peripheral address |
| `0x1C` | `INCR` | Increment control |

### DMA Command Register Bits

```zig
const DMA_CMD_SIZE: u32       = 0x0000FFFF;  // Transfer size
const DMA_CMD_REQ_ID: u32     = 0x000F0000;  // Request ID
const DMA_CMD_WAIT_REQ: u32   = 0x01000000;  // Wait for request
const DMA_CMD_SINGLE: u32     = 0x04000000;  // Single transfer
const DMA_CMD_RAM_TO_PER: u32 = 0x08000000;  // RAM to peripheral
const DMA_CMD_INTR: u32       = 0x40000000;  // Interrupt on complete
const DMA_CMD_START: u32      = 0x80000000;  // Start transfer
```

### DMA Request IDs

```zig
const DMA_REQ_IIS: u32  = 2;   // I2S audio
const DMA_REQ_SDHC: u32 = 13;  // SD card
```

### Audio DMA Setup

```zig
fn setupAudioDma(buffer: []const i16) void {
    // 1. Enable DMA master
    DMA_MASTER_CONTROL.* = 0x80000000;

    // 2. Configure DMA channel 0 for I2S
    const size: u32 = @intCast(buffer.len * 2);  // bytes

    DMA0_RAM_ADDR.* = @intFromPtr(buffer.ptr);
    DMA0_PER_ADDR.* = 0x70002840;  // IISFIFO_WR
    DMA0_INCR.* = 0x20000000;  // 32-bit width

    // 3. Start transfer
    DMA0_CMD.* = DMA_CMD_START | DMA_CMD_INTR |
                 DMA_CMD_RAM_TO_PER | DMA_CMD_WAIT_REQ |
                 (DMA_REQ_IIS << 16) | (size & 0xFFFF);
}
```

---

## 10. Storage (ATA/IDE)

### IDE Register Addresses

| Register | Address | Description |
|----------|---------|-------------|
| `IDE0_PRI_TIMING0` | `0xC3000000` | Primary timing 0 |
| `IDE0_PRI_TIMING1` | `0xC3000004` | Primary timing 1 |
| `IDE0_CFG` | `0xC3000028` | Configuration |
| `IDE0_CNTRLR_STAT` | `0xC30001E0` | Controller status |

### ATA Task File (Rockbox ata-target.h verified)

**IMPORTANT**: PP5020/PP5022 uses 4-byte aligned registers!

Base: `IDE_BASE = 0xC3000000`

| Register | Address | Description |
|----------|---------|-------------|
| `ATA_DATA` | `0xC30001E0` | 16-bit data register |
| `ATA_ERROR` | `0xC30001E4` | Error (read) / Features (write) |
| `ATA_NSECTOR` | `0xC30001E8` | Sector count |
| `ATA_SECTOR` | `0xC30001EC` | LBA[0:7] |
| `ATA_LCYL` | `0xC30001F0` | LBA[8:15] |
| `ATA_HCYL` | `0xC30001F4` | LBA[16:23] |
| `ATA_SELECT` | `0xC30001F8` | Device/Head / LBA[24:27] |
| `ATA_COMMAND` | `0xC30001FC` | Command (write) / Status (read) |
| `ATA_CONTROL` | `0xC30003F8` | Control / Alt Status |

### PIO Timing Values (80MHz)

```zig
const pio_timings = [_]u32{
    0xC293,  // PIO 0
    0x43A2,  // PIO 1
    0x2291,  // PIO 2
    0x1251,  // PIO 3
    0x0221,  // PIO 4
};
```

---

## 11. Power Management (PCF50605)

### I2C Address

```zig
const PCF50605_ADDR: u7 = 0x08;
```

### Key Registers

| Register | Address | Description |
|----------|---------|-------------|
| `OOCC1` | - | Operation control |
| `IOREGC` | - | I/O voltage |
| `DCDC1` | - | Core voltage 1 |
| `DCDC2` | - | Core voltage 2 |
| `D1REGC1` | - | Codec voltage |
| `D3REGC1` | - | LCD voltage |
| `LPREGC1` | - | Low power regulator |

### Standby Mode

```zig
fn pcf50605Standby() void {
    // Configure wakeup sources before entering standby
    // CHGWAK or EXTONWAK must be set to allow wakeup
    pcf50605Write(OOCC1, standby_config);
}
```

---

## 12. UART/Serial

### Serial Port 0 Registers

| Register | Address | Description |
|----------|---------|-------------|
| `SER0_RBR/THR/DLL` | `0x70006000` | RX/TX/Divisor Low |
| `SER0_IER/DLM` | `0x70006004` | Interrupt Enable/Divisor High |
| `SER0_FCR/IIR` | `0x70006008` | FIFO Control/ID |
| `SER0_LCR` | `0x7000600C` | Line Control |
| `SER0_MCR` | `0x70006010` | Modem Control |
| `SER0_LSR` | `0x70006014` | Line Status |
| `SER0_MSR` | `0x70006018` | Modem Status |

### iPod Dock Connector UART Pins

| Pin | Function |
|-----|----------|
| 1, 2 | GND |
| 11 | Serial TX (from iPod) |
| 13 | Serial RX (to iPod) |

### UART Initialization

```zig
fn uartInit() void {
    // 1. Enable serial device
    DEV_EN.* |= DEV_SER0;

    // 2. Reset
    DEV_RS.* |= DEV_SER0;
    // Wait
    DEV_RS.* &= ~DEV_SER0;

    // 3. Set divisor latch enable
    SER0_LCR.* = 0x80;

    // 4. Set baud rate: 24MHz / 115200 / 16 = 13
    SER0_DLL.* = 13;
    SER0_DLM.* = 0;

    // 5. 8-N-1, disable divisor latch
    SER0_LCR.* = 0x03;

    // 6. Enable and reset FIFOs
    SER0_FCR.* = 0x07;
}

fn uartPutChar(c: u8) void {
    // Wait for TX ready (bit 5 of LSR)
    while ((SER0_LSR.* & 0x20) == 0) {}
    SER0_THR.* = c;
}
```

---

## 13. I2C

### I2C Base Address

```zig
const I2C_BASE: u32 = 0x7000C000;
```

### I2C Usage

I2C is used for:
- WM8758 audio codec (address 0x1A)
- PCF50605 PMU (address 0x08)

---

## 14. Cache Control

### Cache Registers

| Register | Address | Description |
|----------|---------|-------------|
| `CACHE_CTL` | `0x6000C000` | Cache control |
| `CACHE_MASK` | `0xF000F040` | Cache mask |
| `CACHE_OPERATION` | `0xF000F044` | Cache operation |
| `CACHE_FLUSH_MASK` | `0xF000F048` | Flush mask |

### Cache Control Bits

```zig
const CACHE_CTL_DISABLE: u16    = 0x0000;
const CACHE_CTL_ENABLE: u16     = 0x0001;
const CACHE_CTL_RUN: u16        = 0x0002;
const CACHE_CTL_INIT: u16       = 0x0004;
const CACHE_CTL_VECT_REMAP: u16 = 0x0010;
const CACHE_CTL_READY: u16      = 0x4000;
const CACHE_CTL_BUSY: u16       = 0x8000;

const CACHE_OP_FLUSH: u16      = 0x0002;
const CACHE_OP_INVALIDATE: u16 = 0x0004;
```

---

## 15. Boot Sequence

### What Apple Bootloader Initializes (DO NOT REINITIALIZE)

1. PLL/Clocks at 80MHz
2. SDRAM controller
3. Cache (I-cache and D-cache)
4. BCM2722 LCD controller
5. GPIO configuration
6. Basic power management

### What ZigPod Must Initialize

1. Click wheel (`DEV_OPTO`, `INIT_BUTTONS`, `WHEEL_CTRL`)
2. Audio codec via I2C
3. I2S controller
4. DMA for audio
5. Interrupt handlers
6. Application-specific GPIO

### Safe Entry Point

```zig
export fn _start() callconv(.naked) noreturn {
    asm volatile (
        // Disable IRQ and FIQ
        \\msr cpsr_c, #0xdf
        // Set up stack in SDRAM
        \\ldr sp, =0x40008000
        // Call main
        \\bl _zigpod_main
        // Infinite loop on return
        \\1: b 1b
    );
}
```

### ARM7TDMI Restrictions

**DO NOT USE** (ARMv6+ instructions):
- `cpsid` / `cpsie`
- `wfi` / `wfe`
- Thumb-2 instructions
- NEON/VFP

**USE INSTEAD**:
- `msr cpsr_c, #0xdf` (disable IRQ/FIQ)
- Spin loops for waiting
- Pure ARM or Thumb-1 instructions

---

## Appendix A: RGB565 Color Format

```zig
fn rgb565(r: u8, g: u8, b: u8) u16 {
    return (@as(u16, r >> 3) << 11) |
           (@as(u16, g >> 2) << 5) |
           (@as(u16, b >> 3));
}

// Common colors
const COLOR_BLACK: u16   = 0x0000;
const COLOR_WHITE: u16   = 0xFFFF;
const COLOR_RED: u16     = 0xF800;
const COLOR_GREEN: u16   = 0x07E0;
const COLOR_BLUE: u16    = 0x001F;
```

---

## Appendix B: Verified Working Code Snippets

### Fill Screen with Color

```zig
fn fillScreen(color: u32) void {
    // color is two RGB565 pixels packed (same color)
    bcmWriteAddr(0xE0000);
    var i: u32 = 0;
    while (i < 320 * 240 / 2) : (i += 1) {
        BCM_DATA32.* = color;
    }
    bcmWriteAddr(0x1F8);
    BCM_DATA32.* = 0xFFFF0000;  // LCD_UPDATE command
    BCM_CONTROL.* = 0x31;
}
```

### Read Button State

```zig
fn getButtonState() u8 {
    if ((WHEEL_STATUS.* & 0x04000000) == 0) return 0;

    const data = WHEEL_DATA.*;
    WHEEL_STATUS.* |= 0x0C000000;
    WHEEL_CTRL.* |= 0x60000000;

    if ((data & 0xFF) != 0x1A) return 0;

    var buttons: u8 = 0;
    if (data & BTN_SELECT != 0) buttons |= 0x01;
    if (data & BTN_RIGHT != 0) buttons |= 0x02;
    if (data & BTN_LEFT != 0) buttons |= 0x04;
    if (data & BTN_PLAY != 0) buttons |= 0x08;
    if (data & BTN_MENU != 0) buttons |= 0x10;

    return buttons;
}
```

---

## References

- Rockbox source: https://github.com/Rockbox/rockbox
- Rockbox pp5020.h: firmware/export/pp5020.h
- Rockbox button-clickwheel.c: firmware/target/arm/ipod/button-clickwheel.c
- Rockbox lcd-video.c: firmware/target/arm/ipod/video/lcd-video.c
- Rockbox wm8758.c: firmware/drivers/audio/wm8758.c
- Rockbox i2s-pp.c: firmware/target/arm/pp/i2s-pp.c
- Rockbox pcm-pp.c: firmware/target/arm/pp/pcm-pp.c

---

**Document Version**: 1.0
**Last Updated**: 2026-01-10
**Status**: Authoritative reference for ZigPod development
