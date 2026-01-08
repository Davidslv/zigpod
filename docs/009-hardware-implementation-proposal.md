# ZigPod Hardware Implementation Proposal

## Document Overview

**Purpose**: Comprehensive technical proposal for implementing real hardware support in ZigPod
**Target**: Apple iPod Video 5th/5.5th Generation (PP5021C SoC)
**Estimated Effort**: 2-3 weeks
**Priority**: Critical path to functional hardware deployment

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Current State Analysis](#2-current-state-analysis)
3. [Phase 1: Boot Initialization](#3-phase-1-boot-initialization)
4. [Phase 2: Interrupt System](#4-phase-2-interrupt-system)
5. [Phase 3: DMA Engine](#5-phase-3-dma-engine)
6. [Phase 4: Audio Pipeline](#6-phase-4-audio-pipeline)
7. [Phase 5: Storage Optimization](#7-phase-5-storage-optimization)
8. [Phase 6: Power Management](#8-phase-6-power-management)
9. [Testing Strategy](#9-testing-strategy)
10. [Risk Assessment](#10-risk-assessment)
11. [Implementation Schedule](#11-implementation-schedule)
12. [References](#12-references)

---

## 1. Executive Summary

### 1.1 Current Status

ZigPod has achieved **~95% simulator completion** with comprehensive hardware abstractions, but **~60% real hardware readiness**. The codebase includes:

- Complete PP5021C register definitions (999 constants)
- Working drivers for WM8758 codec, ATA storage, LCD, Click Wheel
- Sophisticated audio pipeline with gapless playback
- Full ARM7TDMI cross-compilation support

### 1.2 Critical Gaps

| Component | Status | Impact |
|-----------|--------|--------|
| SDRAM Controller | Stub only | **Cannot boot** |
| PLL/Clock Configuration | Stub only | **Cannot boot** |
| Interrupt Vector Dispatch | Framework only | **No real-time operation** |
| DMA Integration | Not connected | **Audio will stutter** |
| Timer Interrupts | Never triggered | **No scheduling** |

### 1.3 Success Criteria

1. Device boots to main menu on real hardware
2. Audio playback without stuttering or underruns
3. Storage access at acceptable speeds
4. Battery life within 80% of original iPod firmware
5. All click wheel inputs responsive

---

## 2. Current State Analysis

### 2.1 What Works (Simulator)

```
┌─────────────────────────────────────────────────────────────┐
│                    SIMULATOR ARCHITECTURE                   │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐     │
│  │   Decoder   │───▶│ Ring Buffer │───▶│  WAV File   │     │
│  │  (MP3/FLAC) │    │   (16KB)    │    │   Output    │     │
│  └─────────────┘    └─────────────┘    └─────────────┘     │
│         │                                                   │
│         ▼                                                   │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐     │
│  │  Mock HAL   │───▶│   Mock I2S  │───▶│  Mock LCD   │     │
│  │             │    │             │    │             │     │
│  └─────────────┘    └─────────────┘    └─────────────┘     │
│                                                             │
│  ✓ Full CPU emulation (ARM7TDMI interpreter)               │
│  ✓ Memory bus simulation                                   │
│  ✓ I2C device responses (WM8758, PCF50605)                 │
│  ✓ Virtual ATA disk                                        │
│  ✓ SDL2 display output                                     │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### 2.2 What's Missing (Real Hardware)

```
┌─────────────────────────────────────────────────────────────┐
│                 REAL HARDWARE ARCHITECTURE                  │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐     │
│  │   Decoder   │───▶│ Ring Buffer │───▶│  DMA Engine │     │
│  │  (MP3/FLAC) │    │   (512KB)   │    │  (Channel 0)│     │
│  └─────────────┘    └─────────────┘    └──────┬──────┘     │
│         │                                      │            │
│         │              ┌───────────────────────┘            │
│         ▼              ▼                                    │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐     │
│  │   PP5021C   │───▶│  I2S FIFO   │───▶│   WM8758    │     │
│  │   (Real)    │    │  (16 words) │    │   (Real)    │     │
│  └─────────────┘    └─────────────┘    └─────────────┘     │
│         │                                      │            │
│         │              ┌───────────────────────┘            │
│         ▼              ▼                                    │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐     │
│  │  Interrupts │    │   Timers    │    │    IRQ      │     │
│  │  (Vectors)  │◀───│  (TIMER1)   │───▶│  Handler    │     │
│  └─────────────┘    └─────────────┘    └─────────────┘     │
│                                                             │
│  ✗ SDRAM controller initialization                         │
│  ✗ PLL clock configuration                                 │
│  ✗ Interrupt vector dispatch                               │
│  ✗ DMA channel management                                  │
│  ✗ Timer interrupt callbacks                               │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### 2.3 File Inventory

| File | Lines | Status | Notes |
|------|-------|--------|-------|
| `src/kernel/boot.zig` | 184 | Partial | Vector table defined, init stubs |
| `src/kernel/clock.zig` | ~50 | Stub | Empty functions |
| `src/kernel/sdram.zig` | ~30 | Stub | All `unreachable` |
| `src/kernel/interrupts.zig` | ~200 | Framework | Registration works, no dispatch |
| `src/hal/pp5021c.zig` | 1897 | Complete | Real register access |
| `src/hal/registers.zig` | ~2500 | Complete | 999 register constants |
| `src/audio/audio.zig` | 823 | Simulator | Polling-based, no DMA |

---

## 3. Phase 1: Boot Initialization

### 3.1 Overview

The boot sequence must initialize the PP5021C from cold start to running application code. The iPod ROM bootloader handles initial CPU setup, but we must configure:

1. PLL for CPU/peripheral clocks
2. SDRAM controller for main memory
3. Cache for performance
4. Peripheral clocks

### 3.2 PLL Configuration

**File**: `src/kernel/clock.zig`

The PP5021C has two PLLs:
- **PLL_A**: CPU clock (target: 80MHz)
- **PLL_B**: Peripheral clock (target: 24MHz for I2S)

```
┌─────────────────────────────────────────────────────────────┐
│                    PLL CONFIGURATION                        │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  Input Clock: 24MHz crystal                                 │
│                                                             │
│  PLL_A (CPU):                                               │
│  ┌──────────┐    ┌──────────┐    ┌──────────┐              │
│  │  24MHz   │───▶│  PLL_A   │───▶│  80MHz   │              │
│  │  XTAL    │    │  x3.33   │    │  CPU_CLK │              │
│  └──────────┘    └──────────┘    └──────────┘              │
│                                                             │
│  PLL_B (Peripherals):                                       │
│  ┌──────────┐    ┌──────────┐    ┌──────────┐              │
│  │  24MHz   │───▶│  PLL_B   │───▶│  Dividers│───▶ I2S     │
│  │  XTAL    │    │          │    │          │───▶ IDE     │
│  └──────────┘    └──────────┘    └──────────┘───▶ LCD     │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

**Register Sequence** (from Rockbox reference):

```zig
pub fn initPll() void {
    // 1. Switch to slow clock (24MHz direct) before PLL changes
    reg(CLK_SEL) = 0x00;

    // 2. Configure PLL_A for 80MHz
    //    Formula: Fout = Fin * (P+1) / (Q+1)
    //    80MHz = 24MHz * 10 / 3
    reg(PLL_A_CTRL) = (9 << 8) | (2 << 0);  // P=9, Q=2

    // 3. Wait for PLL lock (check status bit or delay)
    while ((reg(PLL_A_STATUS) & PLL_LOCKED) == 0) {}

    // 4. Configure PLL_B for peripheral clocks
    reg(PLL_B_CTRL) = (3 << 8) | (0 << 0);  // 96MHz base

    // 5. Wait for PLL_B lock
    while ((reg(PLL_B_STATUS) & PLL_LOCKED) == 0) {}

    // 6. Configure clock dividers
    reg(CLK_DIV_CPU) = 0;      // CPU = PLL_A / 1 = 80MHz
    reg(CLK_DIV_AHB) = 1;      // AHB = CPU / 2 = 40MHz
    reg(CLK_DIV_APB) = 3;      // APB = AHB / 4 = 10MHz

    // 7. Switch to PLL clocks
    reg(CLK_SEL) = CLK_SEL_PLL_A | CLK_SEL_PLL_B;
}
```

**Validation**:
- Read back PLL status registers
- Verify CPU performance with timing loop
- Check peripheral clock ratios

### 3.3 SDRAM Controller

**File**: `src/kernel/sdram.zig`

The PP5021C interfaces with external SDRAM (32MB or 64MB depending on model). The controller must be configured before any DRAM access.

```
┌─────────────────────────────────────────────────────────────┐
│                  SDRAM MEMORY MAP                           │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  0x00000000 ┬─────────────────────────────────────────────  │
│             │  Boot ROM (64KB) - Read only                  │
│  0x00010000 ┼─────────────────────────────────────────────  │
│             │  Reserved                                     │
│  0x10000000 ┬─────────────────────────────────────────────  │
│             │  IRAM (8KB) - Fast internal SRAM              │
│  0x10002000 ┼─────────────────────────────────────────────  │
│             │  Reserved                                     │
│  0x40000000 ┬─────────────────────────────────────────────  │
│             │  SDRAM Base (32MB/64MB)                       │
│             │  ├── 0x40001000: Code/Data start              │
│             │  ├── 0x42000000: Uncached region (DMA)        │
│             │  └── 0x43FFFFFF: SDRAM end (32MB model)       │
│  0x60000000 ┼─────────────────────────────────────────────  │
│             │  Peripherals (Memory-mapped I/O)              │
│  0x70000000 ┼─────────────────────────────────────────────  │
│             │  PP5021C Control Registers                    │
│             │                                               │
└─────────────────────────────────────────────────────────────┘
```

**Register Sequence**:

```zig
pub fn init() void {
    // 1. Enable SDRAM controller clock
    reg(DEV_EN) |= DEV_SDRAM;

    // 2. Configure SDRAM timing parameters
    //    These values are for Samsung K4S561632N (32MB)
    reg(SDRAM_CFG) = SDRAM_CFG_INIT;
    reg(SDRAM_TIMING) =
        (2 << TRAS_SHIFT) |    // tRAS = 42ns (3 cycles @ 80MHz)
        (1 << TRCD_SHIFT) |    // tRCD = 18ns (2 cycles)
        (1 << TRP_SHIFT)  |    // tRP  = 18ns (2 cycles)
        (0 << TCAS_SHIFT);     // CAS latency = 2

    // 3. Configure refresh rate
    //    Refresh every 7.8us = 624 cycles @ 80MHz
    reg(SDRAM_REFRESH) = 624;

    // 4. Issue SDRAM initialization sequence
    reg(SDRAM_CMD) = SDRAM_CMD_PRECHARGE_ALL;
    delay_us(1);

    // 5. Issue 8 auto-refresh cycles
    for (0..8) |_| {
        reg(SDRAM_CMD) = SDRAM_CMD_AUTO_REFRESH;
        delay_us(1);
    }

    // 6. Set mode register (CAS latency, burst length)
    reg(SDRAM_CMD) = SDRAM_CMD_LOAD_MODE |
                     (CAS_LATENCY_2 << 4) |
                     (BURST_LENGTH_4 << 0);

    // 7. Enable normal operation
    reg(SDRAM_CFG) |= SDRAM_CFG_ENABLE;
}
```

**Validation**:
- Write test patterns to SDRAM
- Read back and verify
- Test address line integrity (walking 1s)
- Memory bandwidth test

### 3.4 Cache Configuration

**File**: `src/kernel/cache.zig`

The ARM7TDMI has no cache, but the PP5021C has an external cache controller.

```zig
pub fn enableCache() void {
    // 1. Invalidate entire cache
    reg(CACHE_CTL) = CACHE_INVALIDATE_ALL;

    // 2. Configure cache regions
    //    Enable caching for SDRAM (0x40000000-0x43FFFFFF)
    //    Disable for I/O regions
    reg(CACHE_REGION_0) = 0x40000000 | CACHE_ENABLE | CACHE_SIZE_32MB;

    // 3. Enable cache
    reg(CACHE_CTL) = CACHE_ENABLE;
}

pub fn flushCache() void {
    // Flush all dirty lines to memory
    reg(CACHE_CTL) = CACHE_FLUSH_ALL;
    while ((reg(CACHE_STATUS) & CACHE_BUSY) != 0) {}
}

pub fn invalidateRange(addr: u32, len: u32) void {
    // Invalidate specific address range (for DMA coherency)
    var a = addr & ~@as(u32, 31);  // Align to cache line
    while (a < addr + len) {
        reg(CACHE_LINE_INVALIDATE) = a;
        a += 32;
    }
}
```

### 3.5 Boot Sequence Integration

**File**: `src/kernel/boot.zig`

Complete boot sequence:

```zig
export fn _start() callconv(.Naked) noreturn {
    // 1. Set up stack pointers (already in IRAM)
    asm volatile (
        \\  msr cpsr_c, #0xD2      // IRQ mode
        \\  ldr sp, =_irq_stack
        \\  msr cpsr_c, #0xD1      // FIQ mode
        \\  ldr sp, =_fiq_stack
        \\  msr cpsr_c, #0xD3      // Supervisor mode
        \\  ldr sp, =_stack_top
    );

    // 2. Clear BSS
    const bss_start: [*]u8 = @extern([*]u8, .{ .name = "__bss_start" });
    const bss_end: [*]u8 = @extern([*]u8, .{ .name = "__bss_end" });
    @memset(bss_start[0..(@intFromPtr(bss_end) - @intFromPtr(bss_start))], 0);

    // 3. Initialize clocks (CRITICAL)
    clock.initPll();

    // 4. Initialize SDRAM (CRITICAL)
    sdram.init();

    // 5. Copy .data from flash to RAM (if needed)
    copyDataSection();

    // 6. Enable cache
    cache.enableCache();

    // 7. Initialize interrupt controller
    interrupts.init();

    // 8. Jump to main
    main();

    // 9. Should never reach here
    while (true) {
        asm volatile ("wfi");
    }
}
```

---

## 4. Phase 2: Interrupt System

### 4.1 Overview

The PP5021C has a vectored interrupt controller with 32 interrupt sources. Real-time audio requires proper interrupt handling.

### 4.2 Interrupt Sources

```
┌─────────────────────────────────────────────────────────────┐
│                  PP5021C INTERRUPT MAP                      │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  IRQ #  │ Source          │ Priority │ Use Case             │
│  ───────┼─────────────────┼──────────┼───────────────────── │
│    0    │ TIMER1          │ High     │ Main loop tick       │
│    1    │ TIMER2          │ Medium   │ UI refresh           │
│    2    │ USB             │ Medium   │ Host communication   │
│    3    │ I2S TX          │ Critical │ Audio buffer empty   │
│    4    │ I2S RX          │ Low      │ (unused)             │
│    5    │ IDE             │ Medium   │ DMA complete         │
│    6    │ DMA             │ High     │ Transfer complete    │
│    7    │ GPIO            │ High     │ Click wheel, buttons │
│    8    │ I2C             │ Low      │ Codec control        │
│    9    │ SPI             │ Low      │ (unused)             │
│   10    │ UART            │ Low      │ Debug console        │
│   ...   │ ...             │ ...      │ ...                  │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### 4.3 Vector Table Implementation

**File**: `src/kernel/vectors.zig`

```zig
// ARM7TDMI exception vectors (placed at 0x00000000 or 0xFFFF0000)
export const vector_table linksection(".vectors") = [_]u32{
    @intFromPtr(&_start),           // Reset
    @intFromPtr(&undefinedHandler), // Undefined instruction
    @intFromPtr(&swiHandler),       // Software interrupt
    @intFromPtr(&prefetchHandler),  // Prefetch abort
    @intFromPtr(&dataAbortHandler), // Data abort
    0,                              // Reserved
    @intFromPtr(&irqHandler),       // IRQ
    @intFromPtr(&fiqHandler),       // FIQ
};

fn irqHandler() callconv(.Naked) void {
    // Save context
    asm volatile (
        \\  sub lr, lr, #4          // Adjust return address
        \\  stmfd sp!, {r0-r12, lr} // Save registers
    );

    // Read interrupt source from controller
    const irq_status = reg(INT_STATUS);

    // Dispatch to handler
    if ((irq_status & INT_TIMER1) != 0) {
        timerHandler();
        reg(INT_CLEAR) = INT_TIMER1;
    }
    if ((irq_status & INT_I2S_TX) != 0) {
        i2sHandler();
        reg(INT_CLEAR) = INT_I2S_TX;
    }
    if ((irq_status & INT_DMA) != 0) {
        dmaHandler();
        reg(INT_CLEAR) = INT_DMA;
    }
    if ((irq_status & INT_GPIO) != 0) {
        gpioHandler();
        reg(INT_CLEAR) = INT_GPIO;
    }

    // Restore context and return
    asm volatile (
        \\  ldmfd sp!, {r0-r12, pc}^ // Restore and return
    );
}
```

### 4.4 Interrupt Controller Configuration

**File**: `src/kernel/interrupts.zig`

```zig
pub fn init() void {
    // 1. Disable all interrupts during setup
    reg(INT_ENABLE) = 0;
    reg(INT_CLEAR) = 0xFFFFFFFF;

    // 2. Configure interrupt priorities
    reg(INT_PRIORITY_0) =
        (PRIORITY_HIGH << (INT_TIMER1 * 2)) |
        (PRIORITY_CRITICAL << (INT_I2S_TX * 2)) |
        (PRIORITY_HIGH << (INT_DMA * 2)) |
        (PRIORITY_HIGH << (INT_GPIO * 2));

    // 3. Enable required interrupts
    reg(INT_ENABLE) =
        INT_TIMER1 |
        INT_I2S_TX |
        INT_DMA |
        INT_GPIO;

    // 4. Enable IRQ in CPSR
    asm volatile ("msr cpsr_c, #0x13");  // Enable IRQ, Supervisor mode
}

pub fn enable(irq: u5) void {
    reg(INT_ENABLE) |= @as(u32, 1) << irq;
}

pub fn disable(irq: u5) void {
    reg(INT_ENABLE) &= ~(@as(u32, 1) << irq);
}

pub fn registerHandler(irq: u5, handler: *const fn() void) void {
    handlers[irq] = handler;
}
```

### 4.5 Timer Setup

**File**: `src/kernel/timer.zig`

```zig
pub fn init(tick_rate_hz: u32) void {
    // 1. Configure TIMER1 for periodic interrupts
    const reload_value = CPU_FREQ / tick_rate_hz;

    // 2. Stop timer during configuration
    reg(TIMER1_CTL) = 0;

    // 3. Set reload value
    reg(TIMER1_RELOAD) = reload_value;

    // 4. Start timer with interrupt enabled
    reg(TIMER1_CTL) = TIMER_ENABLE | TIMER_PERIODIC | TIMER_INT_ENABLE;
}

var tick_count: u64 = 0;
var callbacks: [8]?*const fn() void = [_]?*const fn() void{null} ** 8;

fn timerHandler() void {
    tick_count += 1;

    // Call registered callbacks
    for (callbacks) |cb| {
        if (cb) |callback| {
            callback();
        }
    }
}

pub fn getTicks() u64 {
    return tick_count;
}

pub fn delayMs(ms: u32) void {
    const target = tick_count + ms;
    while (tick_count < target) {
        asm volatile ("wfi");  // Wait for interrupt
    }
}
```

---

## 5. Phase 3: DMA Engine

### 5.1 Overview

The PP5021C has 4 DMA channels. We need:
- **Channel 0**: Audio (I2S TX) - highest priority
- **Channel 1**: Storage (IDE) - medium priority
- **Channel 2**: Reserved
- **Channel 3**: Reserved

### 5.2 DMA Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    DMA SUBSYSTEM                            │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  ┌─────────────┐         ┌─────────────┐                   │
│  │ Ring Buffer │────────▶│  DMA Ch 0   │                   │
│  │  (512KB)    │         │  (Audio)    │                   │
│  │  Uncached   │         └──────┬──────┘                   │
│  └─────────────┘                │                          │
│                                 ▼                          │
│                          ┌─────────────┐                   │
│                          │  I2S FIFO   │                   │
│                          │  (16 words) │                   │
│                          └──────┬──────┘                   │
│                                 │                          │
│                                 ▼                          │
│                          ┌─────────────┐                   │
│                          │   WM8758    │                   │
│                          │    DAC      │                   │
│                          └─────────────┘                   │
│                                                             │
│  DMA Transfer Cycle:                                        │
│  1. DMA reads from ring buffer (uncached SDRAM)            │
│  2. DMA writes to I2S FIFO                                 │
│  3. I2S shifts data to codec at sample rate                │
│  4. When half buffer consumed, interrupt fires             │
│  5. CPU refills depleted half while DMA uses other half    │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### 5.3 DMA Driver

**File**: `src/kernel/dma.zig`

```zig
pub const Channel = enum(u2) {
    audio = 0,
    storage = 1,
    reserved_2 = 2,
    reserved_3 = 3,
};

pub const Config = struct {
    src_addr: u32,
    dst_addr: u32,
    count: u32,           // Transfer count in words
    src_inc: bool,        // Increment source address
    dst_inc: bool,        // Increment destination address
    word_size: WordSize,  // 8, 16, or 32 bits
    circular: bool,       // Circular buffer mode
    half_int: bool,       // Interrupt at half transfer
    complete_int: bool,   // Interrupt on complete
};

pub const WordSize = enum(u2) {
    byte = 0,
    halfword = 1,
    word = 2,
};

pub fn configure(ch: Channel, cfg: Config) void {
    const base = DMA_BASE + @as(u32, @intFromEnum(ch)) * 0x20;

    // 1. Disable channel during configuration
    reg(base + DMA_CTL) = 0;

    // 2. Set source address
    reg(base + DMA_SRC) = cfg.src_addr;

    // 3. Set destination address
    reg(base + DMA_DST) = cfg.dst_addr;

    // 4. Set transfer count
    reg(base + DMA_COUNT) = cfg.count;

    // 5. Configure control register
    var ctl: u32 = 0;
    if (cfg.src_inc) ctl |= DMA_SRC_INC;
    if (cfg.dst_inc) ctl |= DMA_DST_INC;
    ctl |= @as(u32, @intFromEnum(cfg.word_size)) << DMA_SIZE_SHIFT;
    if (cfg.circular) ctl |= DMA_CIRCULAR;
    if (cfg.half_int) ctl |= DMA_HALF_INT;
    if (cfg.complete_int) ctl |= DMA_COMPLETE_INT;

    reg(base + DMA_CTL) = ctl;
}

pub fn start(ch: Channel) void {
    const base = DMA_BASE + @as(u32, @intFromEnum(ch)) * 0x20;
    reg(base + DMA_CTL) |= DMA_ENABLE;
}

pub fn stop(ch: Channel) void {
    const base = DMA_BASE + @as(u32, @intFromEnum(ch)) * 0x20;
    reg(base + DMA_CTL) &= ~DMA_ENABLE;
}

pub fn getRemaining(ch: Channel) u32 {
    const base = DMA_BASE + @as(u32, @intFromEnum(ch)) * 0x20;
    return reg(base + DMA_COUNT);
}

pub fn isComplete(ch: Channel) bool {
    return (reg(DMA_STATUS) & (@as(u32, 1) << (@intFromEnum(ch) + 16))) != 0;
}
```

### 5.4 Double-Buffering Strategy

```
┌─────────────────────────────────────────────────────────────┐
│                 DOUBLE BUFFER TIMING                        │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  Time ──────────────────────────────────────────────────▶   │
│                                                             │
│  Buffer A: [████████████████]                               │
│            │← DMA reading ──▶│                              │
│                                                             │
│  Buffer B: [░░░░░░░░░░░░░░░░]                               │
│            │← CPU filling ──▶│                              │
│                                                             │
│  ─────── Half-transfer interrupt ───────                    │
│                                                             │
│  Buffer A: [░░░░░░░░░░░░░░░░]                               │
│            │← CPU filling ──▶│                              │
│                                                             │
│  Buffer B: [████████████████]                               │
│            │← DMA reading ──▶│                              │
│                                                             │
│  Legend:                                                    │
│  ████ = Data being played                                   │
│  ░░░░ = Data being decoded/filled                           │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

---

## 6. Phase 4: Audio Pipeline

### 6.1 Current Architecture (Polling)

```zig
// Current implementation (simulator)
pub fn process() void {
    while (ring_buffer.available() > 0) {
        const sample = ring_buffer.read();
        i2s.write(sample);  // Blocks until FIFO has space
    }
}
```

**Problems**:
- CPU spins waiting for FIFO space
- No other work can happen during audio processing
- Glitches if any operation takes too long

### 6.2 Target Architecture (DMA + Interrupts)

**File**: `src/audio/audio_hw.zig`

```zig
const AUDIO_BUFFER_SIZE = 512 * 1024;  // 512KB
const HALF_BUFFER_SIZE = AUDIO_BUFFER_SIZE / 2;

// Audio buffer in uncached SDRAM region
var audio_buffer: [AUDIO_BUFFER_SIZE]u8 align(32) linksection(".uncached") = undefined;

var write_half: u1 = 0;  // Which half CPU is filling
var underrun_count: u32 = 0;

pub fn init() void {
    // 1. Initialize codec
    codec.init();

    // 2. Configure I2S for DMA mode
    i2s.init(.{
        .sample_rate = .rate_44100,
        .word_length = .bits_16,
        .dma_enable = true,
    });

    // 3. Configure DMA for circular audio buffer
    dma.configure(.audio, .{
        .src_addr = @intFromPtr(&audio_buffer),
        .dst_addr = I2S_TX_FIFO,
        .count = AUDIO_BUFFER_SIZE / 4,  // 32-bit words
        .src_inc = true,
        .dst_inc = false,  // Always write to same FIFO address
        .word_size = .word,
        .circular = true,
        .half_int = true,
        .complete_int = true,
    });

    // 4. Register DMA interrupt handler
    interrupts.registerHandler(.dma, dmaHandler);

    // 5. Pre-fill both halves of buffer
    fillBuffer(0);
    fillBuffer(1);

    // 6. Start DMA
    dma.start(.audio);
}

fn dmaHandler() void {
    // Determine which half just finished playing
    const finished_half = write_half;
    write_half ^= 1;  // Switch to other half

    // Schedule refill of finished half (in main loop, not ISR)
    audio_state.needs_refill = true;
    audio_state.refill_half = finished_half;
}

fn fillBuffer(half: u1) void {
    const offset = @as(usize, half) * HALF_BUFFER_SIZE;
    const dest = audio_buffer[offset..][0..HALF_BUFFER_SIZE];

    // Read samples from decoder ring buffer
    const samples_read = decoder.readSamples(dest);

    // If not enough samples, fill with silence
    if (samples_read < HALF_BUFFER_SIZE) {
        @memset(dest[samples_read..], 0);
        underrun_count += 1;
    }

    // Flush cache for this region (DMA reads from memory, not cache)
    cache.flushRange(@intFromPtr(dest.ptr), HALF_BUFFER_SIZE);
}

pub fn mainLoopTick() void {
    // Called from main loop, not ISR
    if (audio_state.needs_refill) {
        audio_state.needs_refill = false;
        fillBuffer(audio_state.refill_half);
    }
}
```

### 6.3 Sample Rate Switching

```zig
pub fn setSampleRate(rate: SampleRate) void {
    // 1. Stop DMA
    dma.stop(.audio);

    // 2. Wait for I2S FIFO to drain
    while (!i2s.isFifoEmpty()) {}

    // 3. Reconfigure I2S clock
    i2s.setSampleRate(rate);

    // 4. Reconfigure codec (if needed)
    codec.setSampleRate(rate);

    // 5. Restart DMA
    dma.start(.audio);
}
```

### 6.4 Gapless Playback Integration

The existing gapless playback architecture (dual decoder slots) integrates with DMA:

```
┌─────────────────────────────────────────────────────────────┐
│              GAPLESS PLAYBACK + DMA                         │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  ┌─────────────┐    ┌─────────────┐                        │
│  │ Decoder A   │───▶│ Slot A Buf  │──┐                     │
│  │ (Current)   │    │   (16KB)    │  │                     │
│  └─────────────┘    └─────────────┘  │                     │
│                                       ▼                     │
│  ┌─────────────┐    ┌─────────────┐  ┌─────────────┐       │
│  │ Decoder B   │───▶│ Slot B Buf  │─▶│   Mixer     │       │
│  │ (Next)      │    │   (16KB)    │  │ (Crossfade) │       │
│  └─────────────┘    └─────────────┘  └──────┬──────┘       │
│                                              │              │
│                                              ▼              │
│                                       ┌─────────────┐       │
│                                       │ DMA Buffer  │       │
│                                       │  (512KB)    │       │
│                                       └──────┬──────┘       │
│                                              │              │
│                                              ▼              │
│                                       ┌─────────────┐       │
│                                       │    DMA      │       │
│                                       │  Channel 0  │       │
│                                       └─────────────┘       │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

---

## 7. Phase 5: Storage Optimization

### 7.1 Current State

The ATA driver uses PIO (Programmed I/O) mode - CPU manually transfers each word. This is:
- Slow: ~2MB/s maximum
- CPU intensive: 100% CPU during transfers
- Blocking: No other work during read/write

### 7.2 DMA Mode Implementation

**File**: `src/storage/ata_dma.zig`

```zig
pub fn readSectorsDma(lba: u48, count: u16, buffer: []u8) !void {
    // 1. Setup DMA transfer
    dma.configure(.storage, .{
        .src_addr = IDE_DATA_REG,
        .dst_addr = @intFromPtr(buffer.ptr),
        .count = count * 512 / 4,
        .src_inc = false,
        .dst_inc = true,
        .word_size = .word,
        .circular = false,
        .complete_int = true,
    });

    // 2. Issue ATA DMA read command
    ata.selectDevice(0);
    ata.setLba(lba);
    ata.setSectorCount(count);
    ata.writeCommand(ATA_CMD_READ_DMA);

    // 3. Start DMA
    dma.start(.storage);

    // 4. Wait for completion (or yield to scheduler)
    while (!dma.isComplete(.storage)) {
        // Could yield here in a multitasking system
        asm volatile ("wfi");
    }

    // 5. Check for errors
    if (ata.hasError()) {
        return error.AtaReadError;
    }

    // 6. Invalidate cache for buffer region
    cache.invalidateRange(@intFromPtr(buffer.ptr), buffer.len);
}
```

### 7.3 Read-Ahead Cache

```zig
const CACHE_SIZE = 1024 * 1024;  // 1MB read-ahead cache
const CACHE_LINE_SIZE = 64 * 512;  // 64 sectors per cache line

var cache_buffer: [CACHE_SIZE]u8 = undefined;
var cache_tags: [CACHE_SIZE / CACHE_LINE_SIZE]?u32 = [_]?u32{null} ** (CACHE_SIZE / CACHE_LINE_SIZE);

pub fn readCached(lba: u48, count: u16, buffer: []u8) !void {
    const line_lba = @as(u32, @truncate(lba)) & ~@as(u32, 63);
    const line_idx = (line_lba / 64) % cache_tags.len;

    if (cache_tags[line_idx] == line_lba) {
        // Cache hit - copy from cache
        const offset = (@as(u32, @truncate(lba)) - line_lba) * 512;
        @memcpy(buffer, cache_buffer[line_idx * CACHE_LINE_SIZE + offset..][0..buffer.len]);
        return;
    }

    // Cache miss - read from disk
    try readSectorsDma(line_lba, 64, cache_buffer[line_idx * CACHE_LINE_SIZE..][0..CACHE_LINE_SIZE]);
    cache_tags[line_idx] = line_lba;

    // Copy requested sectors
    const offset = (@as(u32, @truncate(lba)) - line_lba) * 512;
    @memcpy(buffer, cache_buffer[line_idx * CACHE_LINE_SIZE + offset..][0..buffer.len]);
}
```

---

## 8. Phase 6: Power Management

### 8.1 Power States

```
┌─────────────────────────────────────────────────────────────┐
│                    POWER STATES                             │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  State      │ CPU    │ Display │ Audio │ Storage │ Power   │
│  ───────────┼────────┼─────────┼───────┼─────────┼──────── │
│  Active     │ 80MHz  │ On      │ On    │ Active  │ 100%    │
│  Playing    │ 30MHz  │ Dim/Off │ On    │ Spin-up │ 60%     │
│  Idle       │ 24MHz  │ Off     │ Off   │ Standby │ 20%     │
│  Sleep      │ Stop   │ Off     │ Off   │ Off     │ 5%      │
│  Deep Sleep │ Off    │ Off     │ Off   │ Off     │ <1%     │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### 8.2 Dynamic Frequency Scaling

**File**: `src/power/dvfs.zig`

```zig
pub const CpuFreq = enum {
    mhz_24,   // Low power
    mhz_30,   // Audio playback
    mhz_60,   // Normal operation
    mhz_80,   // Maximum performance
};

pub fn setCpuFreq(freq: CpuFreq) void {
    // 1. Adjust PLL divider
    const divider = switch (freq) {
        .mhz_24 => 0,  // Bypass PLL
        .mhz_30 => 2,  // PLL / 3
        .mhz_60 => 1,  // PLL / 2
        .mhz_80 => 0,  // PLL / 1
    };

    // 2. Update voltage if needed (higher freq needs higher voltage)
    const voltage = switch (freq) {
        .mhz_24 => .v1_0,
        .mhz_30 => .v1_1,
        .mhz_60 => .v1_2,
        .mhz_80 => .v1_3,
    };
    pmu.setCoreVoltage(voltage);

    // 3. Wait for voltage to stabilize
    delay_us(100);

    // 4. Change clock divider
    clock.setCpuDivider(divider);
}
```

### 8.3 Peripheral Power Gating

```zig
pub fn enablePeripheral(periph: Peripheral) void {
    reg(DEV_EN) |= @as(u32, 1) << @intFromEnum(periph);

    // Wait for peripheral to initialize
    delay_us(periph.initDelayUs());
}

pub fn disablePeripheral(periph: Peripheral) void {
    reg(DEV_EN) &= ~(@as(u32, 1) << @intFromEnum(periph));
}

pub const Peripheral = enum(u5) {
    usb = 0,
    ide = 1,
    i2s = 2,
    i2c = 3,
    gpio = 4,
    lcd = 5,
    dma = 6,
    // ...
};
```

### 8.4 Battery Monitoring

**File**: `src/power/battery.zig`

```zig
pub fn getVoltage() u16 {
    // Read from PMU ADC
    return pmu.readAdc(.battery_voltage);
}

pub fn getPercentage() u8 {
    const voltage = getVoltage();

    // Voltage to percentage curve (LiPo)
    // 4.2V = 100%, 3.7V = 50%, 3.3V = 0%
    if (voltage >= 4200) return 100;
    if (voltage <= 3300) return 0;

    return @intCast((voltage - 3300) * 100 / 900);
}

pub fn isCharging() bool {
    return pmu.isCharging();
}

pub fn getLowBatteryThreshold() u8 {
    return 10;  // Warn at 10%
}

pub fn getCriticalThreshold() u8 {
    return 5;   // Shutdown at 5%
}
```

---

## 9. Testing Strategy

### 9.1 Unit Tests (Simulator)

All existing tests continue to work:

```bash
zig build test
```

### 9.2 Hardware-in-Loop Tests

**File**: `src/tests/hw_tests.zig`

```zig
test "SDRAM read/write" {
    // Write pattern
    const test_addr: *volatile u32 = @ptrFromInt(0x40100000);
    test_addr.* = 0xDEADBEEF;

    // Read back
    const value = test_addr.*;
    try std.testing.expect(value == 0xDEADBEEF);
}

test "DMA transfer" {
    var src: [256]u32 = undefined;
    var dst: [256]u32 = undefined;

    // Fill source
    for (&src, 0..) |*s, i| s.* = @intCast(i);

    // DMA copy
    dma.configure(.reserved_2, .{
        .src_addr = @intFromPtr(&src),
        .dst_addr = @intFromPtr(&dst),
        .count = 256,
        .src_inc = true,
        .dst_inc = true,
        .word_size = .word,
    });
    dma.start(.reserved_2);
    while (!dma.isComplete(.reserved_2)) {}

    // Verify
    try std.testing.expectEqualSlices(u32, &src, &dst);
}

test "audio DMA playback" {
    // Generate 1 second of 440Hz sine wave
    audio.init();
    audio.play(test_sine_wave);

    // Let it play
    delay_ms(1000);

    // Verify no underruns
    try std.testing.expect(audio.getUnderrunCount() == 0);
}
```

### 9.3 JTAG Debugging

Use OpenOCD with FT2232H adapter:

```bash
# Connect to iPod
openocd -f interface/ftdi/ft2232h-module-swd.cfg -f target/arm7tdmi.cfg

# In another terminal
arm-none-eabi-gdb zig-out/bin/zigpod.elf
(gdb) target remote localhost:3333
(gdb) monitor reset halt
(gdb) load
(gdb) break main
(gdb) continue
```

### 9.4 Serial Console

Add UART output for debugging:

```zig
pub fn debugPrint(comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const str = std.fmt.bufPrint(&buf, fmt, args) catch return;
    uart.write(str);
}
```

---

## 10. Risk Assessment

### 10.1 High Risk Items

| Risk | Impact | Mitigation |
|------|--------|------------|
| SDRAM timing wrong | Cannot boot | Reference Rockbox, conservative timing |
| Clock config wrong | Unstable/no boot | Start with known working values |
| DMA coherency issues | Data corruption | Always flush/invalidate cache |
| Interrupt latency | Audio glitches | Keep ISRs minimal |

### 10.2 Medium Risk Items

| Risk | Impact | Mitigation |
|------|--------|------------|
| ATA DMA issues | Slow storage | Fall back to PIO mode |
| Power management bugs | Battery drain | Disable advanced features initially |
| USB enumeration | No host connect | Low priority, can skip |

### 10.3 Low Risk Items

| Risk | Impact | Mitigation |
|------|--------|------------|
| UI rendering | Cosmetic | Already working in simulator |
| Click wheel | Input issues | Well-tested code |
| FAT32 filesystem | Can't read files | Using proven implementation |

---

## 11. Implementation Schedule

### Week 1: Boot Foundation

| Day | Task | Deliverable |
|-----|------|-------------|
| 1-2 | PLL configuration | CPU running at 80MHz |
| 3-4 | SDRAM initialization | Memory test passing |
| 5 | Cache setup | Performance baseline |

### Week 2: Interrupt & DMA

| Day | Task | Deliverable |
|-----|------|-------------|
| 1-2 | Interrupt vectors | Timer tick working |
| 3-4 | DMA driver | Memory-to-memory test |
| 5 | I2S DMA integration | Audio output |

### Week 3: Integration & Testing

| Day | Task | Deliverable |
|-----|------|-------------|
| 1-2 | Audio pipeline | Gapless playback |
| 3 | Storage DMA | Faster file access |
| 4-5 | Bug fixes & optimization | Stable build |

---

## 12. References

### 12.1 Primary Sources

1. **Rockbox Source Code**
   - `bootloader/ipodvideo.c` - Boot sequence
   - `firmware/target/arm/pp/system-pp5021.c` - System init
   - `firmware/target/arm/pp/timer-pp.c` - Timer implementation

2. **PortalPlayer Documentation**
   - PP5021C datasheet (limited availability)
   - PP5021C application notes

3. **ARM Documentation**
   - ARM7TDMI Technical Reference Manual
   - ARM Architecture Reference Manual (ARMv4T)

### 12.2 Community Resources

1. **freemyipod.org** - Hardware documentation wiki
2. **iPodLinux** - Historical reference
3. **iFlash adapter** - Modern storage compatibility

### 12.3 ZigPod Internal Docs

1. `docs/004-hardware-reference.md` - PP5021C register map
2. `docs/005-safe-init-sequences.md` - Verified init code
3. `docs/006-hardware-testing-protocol.md` - Testing procedures

---

## Appendix A: Register Quick Reference

### Clock Registers

| Register | Address | Description |
|----------|---------|-------------|
| CLK_SEL | 0x60006004 | Clock source selection |
| PLL_A_CTRL | 0x60006008 | PLL A configuration |
| PLL_A_STATUS | 0x6000600C | PLL A lock status |
| CLK_DIV_CPU | 0x60006020 | CPU clock divider |

### SDRAM Registers

| Register | Address | Description |
|----------|---------|-------------|
| SDRAM_CFG | 0x60008000 | Configuration |
| SDRAM_TIMING | 0x60008004 | Timing parameters |
| SDRAM_REFRESH | 0x60008008 | Refresh rate |
| SDRAM_CMD | 0x6000800C | Command register |

### DMA Registers

| Register | Address | Description |
|----------|---------|-------------|
| DMA_CTL_0 | 0x60004000 | Channel 0 control |
| DMA_SRC_0 | 0x60004004 | Channel 0 source |
| DMA_DST_0 | 0x60004008 | Channel 0 destination |
| DMA_COUNT_0 | 0x6000400C | Channel 0 count |

### Interrupt Registers

| Register | Address | Description |
|----------|---------|-------------|
| INT_STATUS | 0x60004024 | Interrupt status |
| INT_ENABLE | 0x60004028 | Interrupt enable |
| INT_CLEAR | 0x6000402C | Interrupt clear |
| INT_PRIORITY | 0x60004030 | Priority configuration |

---

## Appendix B: Memory Map Summary

```
0x00000000 - 0x0000FFFF : Boot ROM (64KB)
0x10000000 - 0x10001FFF : IRAM (8KB, fast)
0x40000000 - 0x40000FFF : Reserved
0x40001000 - 0x41FFFFFF : SDRAM cached (code/data)
0x42000000 - 0x42FFFFFF : SDRAM uncached (DMA buffers)
0x60000000 - 0x600FFFFF : Peripheral registers
0x70000000 - 0x700FFFFF : PP5021C control registers
```

---

## Appendix C: Checklist

### Pre-Implementation

- [ ] Review Rockbox bootloader source
- [ ] Verify register addresses against hardware reference
- [ ] Set up JTAG debugging environment
- [ ] Prepare recovery USB cable

### Phase 1 Completion

- [ ] PLL locked at correct frequency
- [ ] SDRAM memory test passes
- [ ] Cache enabled and working
- [ ] Boot to main() successful

### Phase 2 Completion

- [ ] Timer interrupts firing
- [ ] GPIO interrupts for click wheel
- [ ] DMA memory-to-memory working
- [ ] No spurious interrupts

### Phase 3 Completion

- [ ] Audio DMA running
- [ ] No underruns during playback
- [ ] Sample rate switching works
- [ ] Gapless playback functional

### Final Validation

- [ ] 4+ hours continuous playback
- [ ] All audio formats working
- [ ] UI responsive during playback
- [ ] Battery life acceptable
- [ ] No crashes or lockups

---

*Document Version: 1.0*
*Last Updated: January 2026*
*Author: ZigPod Development Team*
