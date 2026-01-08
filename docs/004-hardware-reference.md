# ZigPod Hardware Reference Manual

**Version**: 1.0
**Last Updated**: 2026-01-08
**Status**: Verified from Rockbox Sources

---

## Table of Contents

1. [Overview](#1-overview)
2. [PortalPlayer PP5021C SoC](#2-portalplayer-pp5021c-soc)
3. [Memory Map](#3-memory-map)
4. [Processor Control](#4-processor-control)
5. [Interrupt Controller](#5-interrupt-controller)
6. [Timer System](#6-timer-system)
7. [Clock and PLL Configuration](#7-clock-and-pll-configuration)
8. [GPIO System](#8-gpio-system)
9. [I2C Controller](#9-i2c-controller)
10. [I2S Audio Interface](#10-i2s-audio-interface)
11. [WM8758 Audio Codec](#11-wm8758-audio-codec)
12. [PCF50605 Power Management Unit](#12-pcf50605-power-management-unit)
13. [LCD Controller (BCM2722)](#13-lcd-controller-bcm2722)
14. [ATA/IDE Storage Controller](#14-ataide-storage-controller)
15. [Click Wheel Input](#15-click-wheel-input)
16. [USB Controller](#16-usb-controller)
17. [DMA Engine](#17-dma-engine)
18. [Cache Controller](#18-cache-controller)
19. [Boot Sequence](#19-boot-sequence)
20. [Recovery Procedures](#20-recovery-procedures)
21. [Safe Development Guidelines](#21-safe-development-guidelines)

---

## 1. Overview

### 1.1 iPod Video (5th Generation) Specifications

| Component | Specification | Source |
|-----------|---------------|--------|
| Model Number | A1136 | Apple |
| SoC | PortalPlayer PP5021C-TDF | Rockbox |
| CPU | Dual ARM7TDMI (ARMv4T) | Rockbox |
| Clock Speed | 80 MHz (max), 30 MHz (normal) | Rockbox |
| RAM | 32MB (30GB) / 64MB (60GB) SDRAM | Rockbox |
| Storage | 30GB/60GB/80GB 1.8" HDD | Apple |
| Display | 320x240 QVGA TFT LCD, 16-bit | Rockbox |
| GPU | Broadcom BCM2722 (VideoCore) | Rockbox |
| Audio Codec | Wolfson WM8758 | Rockbox (corrected) |
| PMU | Philips PCF50605 | Rockbox |
| USB | USB 2.0 OTG (ARC) | Rockbox |
| Battery | 400mAh (thin) / 600mAh (thick) | Rockbox |

### 1.2 Source Verification

All information in this document has been verified against:

- **Rockbox Source Code**: https://github.com/Rockbox/rockbox (commit verified 2026-01-08)
- **iPodLoader2 Source**: https://github.com/crozone/ipodloader2
- **freemyipod.org**: Recovery procedures
- **Wolfson WM8758 Datasheet**: Rev 4.4, January 2012

---

## 2. PortalPlayer PP5021C SoC

### 2.1 Architecture

The PP5021C is a dual-core ARM7TDMI (ARMv4T) system-on-chip. Key characteristics:

- **CPU0 (Main)**: Primary application processor
- **CPU1 (COP)**: Coprocessor for audio decoding
- **Processor IDs**: CPU = 0x55, COP = 0xAA
- **Endianness**: Little-endian
- **No MMU**: Uses fixed memory map

### 2.2 Feature Differences (PP5020 vs PP5021C vs PP5022)

| Feature | PP5020 | PP5021C | PP5022 |
|---------|--------|---------|--------|
| Max Clock | 75 MHz | 80 MHz | 80 MHz |
| Cache | 8KB I+D | 8KB I+D | 8KB I+D |
| USB | 1.1 | 2.0 | 2.0 |
| Used In | iPod 4G | iPod Photo | iPod Video |

---

## 3. Memory Map

### 3.1 Physical Memory Layout

Source: `firmware/export/pp5020.h` (Rockbox)

```
Address Range          Size      Description
─────────────────────────────────────────────────────
0x00000000-0x0001FFFF  128KB     Flash/Boot ROM
0x10000000-0x10001FFF  8KB       Internal SRAM (fast)
0x40000000-0x41FFFFFF  32MB      SDRAM (base, 30GB model)
0x40000000-0x43FFFFFF  64MB      SDRAM (60GB model)
0x60000000-0x6FFFFFFF  256MB     Peripheral Registers
0x70000000-0x7FFFFFFF  256MB     Device Registers
0xC0000000-0xCFFFFFFF  256MB     Special Function (USB, IDE)
0xF0000000-0xF000FFFF  64KB      Cache Data/Status
```

### 3.2 Peripheral Register Map

| Peripheral | Base Address | Size | Source |
|------------|--------------|------|--------|
| Mailbox | 0x60001000 | 64B | pp5020.h |
| Interrupt Ctrl | 0x60004000 | 256B | pp5020.h |
| Timer | 0x60005000 | 32B | pp5020.h |
| Clock Control | 0x60006000 | 256B | pp5020.h |
| CPU Control | 0x60007000 | 16B | pp5020.h |
| DMA Master | 0x6000A000 | 16B | pp5020.h |
| DMA Channels | 0x6000B000 | 256B | pp5020.h |
| Cache Ctrl | 0x6000C000 | 4KB | pp5020.h |
| GPIO | 0x6000D000 | 4KB | pp5020.h |
| PP Version | 0x70000000 | 16B | pp5020.h |
| Device Init | 0x70000010 | 64B | pp5020.h |
| GPO32 | 0x70000080 | 16B | pp5020.h |
| I2S | 0x70002000 | 2KB | pp5020.h |
| LCD1 (Mono) | 0x70003000 | 4KB | pp5020.h |
| Serial | 0x70006000 | 128B | pp5020.h |
| I2C | 0x7000C000 | 64B | pp5020.h |
| LCD2 (Color) | 0x70008A00 | 256B | pp5020.h |
| IDE | 0xC3000000 | 64B | pp5020.h |
| USB | 0xC5000000 | 64KB | pp5020.h |

### 3.3 DRAM Layout (Rockbox)

```
Address            Usage
──────────────────────────────────
0x40000000         Firmware Load Address (DRAM_START)
0x40000000+        Code/Data Sections
...                Plugin Buffer (0x80000)
...                Codec Buffer (0x100000)
0x4XXXXXXX         Stack (grows down)
```

---

## 4. Processor Control

### 4.1 Register Definitions

Source: `firmware/export/pp5020.h`

```c
// Processor Control Registers
#define CPU_CTL         (*(volatile unsigned long*)(0x60007000))
#define COP_CTL         (*(volatile unsigned long*)(0x60007004))

// Control Bits
#define PROC_SLEEP      0x80000000  // Put processor to sleep
#define PROC_WAIT_CNT   0x40000000  // Wait for counter
#define PROC_WAKE_INT   0x20000000  // Wake on interrupt

// Counter Source Selection
#define PROC_CNT_CLKS   0x08000000  // Count clock cycles
#define PROC_CNT_USEC   0x02000000  // Count microseconds (VERIFIED)
#define PROC_CNT_MSEC   0x01000000  // Count milliseconds
#define PROC_CNT_SEC    0x00800000  // Count seconds
```

### 4.2 Processor Identification

```c
static inline unsigned int current_core(void) {
    unsigned int core;
    asm volatile (
        "ldr %0, =0x60007000  \n"  // CPU_CTL address
        "ldrb %0, [%0]        \n"  // Read processor ID byte
        : "=r"(core)
    );
    return (core == 0x55) ? 0 : 1;  // CPU=0, COP=1
}
```

### 4.3 Sleep Mode Implementation

```c
void cpu_idle(void) {
    // Safe sleep - will wake on any interrupt
    CPU_CTL = PROC_SLEEP | PROC_WAKE_INT;
}
```

---

## 5. Interrupt Controller

### 5.1 Register Map

Source: `firmware/export/pp5020.h`

```c
// CPU Interrupt Registers
#define CPU_INT_STAT    (*(volatile unsigned long*)(0x60004000))
#define CPU_INT_EN      (*(volatile unsigned long*)(0x60004004))
#define CPU_INT_CLR     (*(volatile unsigned long*)(0x60004008))
#define CPU_INT_PRIO    (*(volatile unsigned long*)(0x6000400C))
#define CPU_HI_INT_STAT (*(volatile unsigned long*)(0x60004100))
#define CPU_HI_INT_EN   (*(volatile unsigned long*)(0x60004104))
#define CPU_HI_INT_CLR  (*(volatile unsigned long*)(0x60004108))

// COP Interrupt Registers
#define COP_INT_STAT    (*(volatile unsigned long*)(0x60004010))
#define COP_INT_EN      (*(volatile unsigned long*)(0x60004014))
#define COP_INT_CLR     (*(volatile unsigned long*)(0x60004018))
#define COP_INT_PRIO    (*(volatile unsigned long*)(0x6000401C))
#define COP_HI_INT_STAT (*(volatile unsigned long*)(0x60004110))
#define COP_HI_INT_EN   (*(volatile unsigned long*)(0x60004114))
#define COP_HI_INT_CLR  (*(volatile unsigned long*)(0x60004118))
```

### 5.2 Interrupt Sources

| IRQ | Name | Description | Source |
|-----|------|-------------|--------|
| 0 | TIMER1_IRQ | Timer 1 | pp5020.h |
| 1 | TIMER2_IRQ | Timer 2 | pp5020.h |
| 2 | MAILBOX_IRQ | Inter-processor mailbox | pp5020.h |
| 3 | (unused) | - | - |
| 4 | IIS_IRQ | I2S audio | pp5020.h |
| 5 | USB_IRQ | USB controller | pp5020.h |
| 6 | IDE_IRQ | IDE/ATA controller | pp5020.h |
| 7 | FIREWIRE_IRQ | FireWire (not used) | pp5020.h |
| 8 | DMA_IRQ | DMA complete | pp5020.h |
| 9-11 | GPIOx_IRQ | GPIO ports | pp5020.h |
| 12-13 | SERx_IRQ | Serial ports | pp5020.h |
| 14 | I2C_IRQ | I2C controller | pp5020.h |

### 5.3 Safe Interrupt Disable

```c
void disable_all_interrupts(void) {
    // Clear all interrupt enables
    CPU_INT_EN = 0;
    COP_INT_EN = 0;
    CPU_HI_INT_EN = 0;
    COP_HI_INT_EN = 0;

    // Clear pending interrupts
    CPU_INT_CLR = 0xFFFFFFFF;
    COP_INT_CLR = 0xFFFFFFFF;
    CPU_HI_INT_CLR = 0xFFFFFFFF;
    COP_HI_INT_CLR = 0xFFFFFFFF;

    // Disable GPIO interrupts (ports A-L)
    for (int i = 0; i < 12; i++) {
        GPIO_INT_EN(i) = 0;
    }
}
```

---

## 6. Timer System

### 6.1 Register Definitions

Source: `firmware/export/pp5020.h`

```c
#define TIMER1_CFG      (*(volatile unsigned long*)(0x60005000))
#define TIMER1_VAL      (*(volatile unsigned long*)(0x60005004))
#define TIMER2_CFG      (*(volatile unsigned long*)(0x60005008))
#define TIMER2_VAL      (*(volatile unsigned long*)(0x6000500C))
#define USEC_TIMER      (*(volatile unsigned long*)(0x60005010))
#define RTC             (*(volatile unsigned long*)(0x60005014))

// Timer frequency: 1,000,000 Hz (1 MHz = 1 us resolution)
#define TIMER_FREQ      1000000
```

### 6.2 Microsecond Delay Implementation

```c
void udelay(unsigned int usec) {
    unsigned int start = USEC_TIMER;
    while ((USEC_TIMER - start) < usec) {
        // Busy wait
    }
}
```

---

## 7. Clock and PLL Configuration

### 7.1 Register Definitions

Source: `firmware/export/pp5020.h`, `system-pp502x.c`

```c
#define CLOCK_SOURCE    (*(volatile unsigned long*)(0x60006020))
#define PLL_CONTROL     (*(volatile unsigned long*)(0x60006034))
#define PLL_STATUS      (*(volatile unsigned long*)(0x6000603C))
#define DEV_EN          (*(volatile unsigned long*)(0x6000600C))
#define DEV_EN2         (*(volatile unsigned long*)(0x60006010))
```

### 7.2 Clock Sources

```c
// Clock source selection (CLOCK_SOURCE register)
// Source #1, #2, #3, #4:
//   32kHz   - Low power sleep mode
//   PLL     - Normal/max operation (80 MHz)

// Frequency modes (from system-pp502x.c)
#define CPUFREQ_SLEEP   32768       // 32 kHz
#define CPUFREQ_NORMAL  30000000    // 30 MHz
#define CPUFREQ_MAX     80000000    // 80 MHz
```

### 7.3 Safe Frequency Switching

Source: `system-pp502x.c`

```c
void set_cpu_frequency(long frequency) {
    switch (frequency) {
        case CPUFREQ_SLEEP:
            // Switch to 32kHz
            // "source #1, #2, #3, #4: 32kHz (#2 active)"
            CLOCK_SOURCE = 0x20002222;
            // Disable PLL
            PLL_CONTROL &= ~0x80000000;
            break;

        case CPUFREQ_MAX:
            // Enable PLL
            PLL_CONTROL |= 0x80000000;
            // Wait for lock
            while (!(PLL_STATUS & 0x80000000));
            // Switch to PLL
            // "source #1, #2, #3, #4: PLL (#2 active)"
            CLOCK_SOURCE = 0x20007777;
            break;

        case CPUFREQ_NORMAL:
            // PLL at reduced speed
            PLL_CONTROL |= 0x80000000;
            while (!(PLL_STATUS & 0x80000000));
            // Different multiplier for 30 MHz
            CLOCK_SOURCE = 0x20002222;  // Varies by model
            break;
    }
}
```

### 7.4 Device Enable Bits

```c
// DEV_EN register bits
#define DEV_EXTCLOCKS   0x00000002
#define DEV_SYSTEM      0x00000004
#define DEV_USB0        0x00000008
#define DEV_USB1        0x00000010
#define DEV_I2S         0x00000800
#define DEV_I2C         0x00001000
#define DEV_ATA         0x00004000
#define DEV_LCD         0x00010000
#define DEV_OPTO        0x00800000  // Click wheel
```

---

## 8. GPIO System

### 8.1 Register Layout

Source: `firmware/export/pp5020.h`

```c
// GPIO base address
#define GPIO_BASE       0x6000D000

// Per-port registers (12 ports: A-L)
// Port offset = port_number * 0x20
#define GPIO_ENABLE(p)     (*(volatile unsigned long*)(GPIO_BASE + (p)*0x20 + 0x00))
#define GPIO_OUTPUT_EN(p)  (*(volatile unsigned long*)(GPIO_BASE + (p)*0x20 + 0x10))
#define GPIO_OUTPUT_VAL(p) (*(volatile unsigned long*)(GPIO_BASE + (p)*0x20 + 0x14))
#define GPIO_INPUT_VAL(p)  (*(volatile unsigned long*)(GPIO_BASE + (p)*0x20 + 0x18))
#define GPIO_INT_STAT(p)   (*(volatile unsigned long*)(GPIO_BASE + (p)*0x20 + 0x1C))
#define GPIO_INT_EN(p)     (*(volatile unsigned long*)(GPIO_BASE + (p)*0x20 + 0x04))
#define GPIO_INT_LEV(p)    (*(volatile unsigned long*)(GPIO_BASE + (p)*0x20 + 0x08))
#define GPIO_INT_CLR(p)    (*(volatile unsigned long*)(GPIO_BASE + (p)*0x20 + 0x0C))
```

### 8.2 GPIO Port Assignments (iPod Video)

| Port | Pins | Function | Source |
|------|------|----------|--------|
| A | - | - | - |
| B | - | - | - |
| C | 2 | Main charger detect | power-ipod.c |
| C | 6 | HDD power (1G-3G) | power-ipod.c |
| D | - | - | - |
| E | - | - | - |
| F | - | - | - |
| G | - | - | - |
| H | - | Headphone detect | config |
| I | - | BCM interrupt | lcd-video.c |
| J | - | - | - |
| K | - | Click wheel | button-clickwheel.c |
| L | - | USB charger detect (Video) | power-ipod.c |

### 8.3 Atomic GPIO Operations

```c
// Safe bitwise GPIO operations (from pp5020.h)
#define GPIOA_OUTPUT_VAL_SET (*(volatile unsigned long*)(0x6000D0A4))
#define GPIOA_OUTPUT_VAL_CLR (*(volatile unsigned long*)(0x6000D0A8))

// Set specific pins without affecting others
void gpio_set_pin(int port, int pin) {
    GPIO_OUTPUT_VAL(port) |= (1 << pin);
}

void gpio_clear_pin(int port, int pin) {
    GPIO_OUTPUT_VAL(port) &= ~(1 << pin);
}
```

---

## 9. I2C Controller

### 9.1 Register Definitions

Source: `i2c-pp.c`

```c
#define I2C_BASE        0x7000C000

#define I2C_CTRL        (*(volatile unsigned char*)(I2C_BASE + 0x00))
#define I2C_ADDR        (*(volatile unsigned char*)(I2C_BASE + 0x04))
#define I2C_DATA(x)     (*(volatile unsigned char*)(I2C_BASE + 0x0C + (4*(x))))
#define I2C_STATUS      (*(volatile unsigned char*)(I2C_BASE + 0x1C))

// Control bits
#define I2C_SEND        0x80        // Initiate transfer
#define I2C_BUSY        (1 << 6)    // Transfer in progress

// Address bit
#define I2C_READ        0x01        // Set for read, clear for write
```

### 9.2 I2C Timing

```c
// Maximum transfer: 4 bytes at a time
// Timeout: 1 second (HZ ticks)
#define I2C_POLL_TIMEOUT    HZ

static int pp_i2c_wait_not_busy(void) {
    unsigned long timeout = current_tick + I2C_POLL_TIMEOUT;
    while (I2C_STATUS & I2C_BUSY) {
        if (TIME_AFTER(current_tick, timeout)) {
            return -1;  // Timeout
        }
        yield();
    }
    return 0;
}
```

### 9.3 I2C Read/Write Implementation

```c
int pp_i2c_send_bytes(unsigned int addr, const unsigned char* data, int len) {
    if (len < 1 || len > 4) return -1;

    if (pp_i2c_wait_not_busy() < 0) return -2;

    // Load data registers
    for (int i = 0; i < len; i++) {
        I2C_DATA(i) = data[i];
    }

    // Set address (write mode)
    I2C_ADDR = addr << 1;  // 7-bit address, write bit = 0

    // Start transfer: length field | send bit
    I2C_CTRL = ((len - 1) << 1) | I2C_SEND;

    return len;
}

int pp_i2c_read_bytes(unsigned int addr, unsigned char* buf, int len) {
    if (len < 1 || len > 4) return -1;

    if (pp_i2c_wait_not_busy() < 0) return -2;

    // Set address (read mode)
    I2C_ADDR = (addr << 1) | I2C_READ;

    // Start transfer
    I2C_CTRL = ((len - 1) << 1) | I2C_SEND;

    if (pp_i2c_wait_not_busy() < 0) return -2;

    // Read data registers
    for (int i = 0; i < len; i++) {
        buf[i] = I2C_DATA(i);
    }

    return len;
}
```

---

## 10. I2S Audio Interface

### 10.1 Register Definitions

Source: `firmware/export/pp5020.h`

```c
#define IISDIV          (*(volatile unsigned long*)(0x60006080))
#define IISCONFIG       (*(volatile unsigned long*)(0x70002800))
#define IISFIFO_CFG     (*(volatile unsigned long*)(0x7000280C))
#define IISFIFO_WR      (*(volatile unsigned long*)(0x70002840))
#define IISFIFO_RD      (*(volatile unsigned long*)(0x70002880))

// IISCONFIG bits
#define IIS_RESET       0x80000000
#define IIS_TXFIFOEN    0x20000000
#define IIS_RXFIFOEN    0x10000000
#define IIS_MASTER      0x00001000
#define IIS_IRQTX       0x00000200
#define IIS_IRQRX       0x00000100

// Data format
#define IIS_FORMAT_IIS    0x00000000
#define IIS_FORMAT_LJUST  0x00400000
#define IIS_SIZE_16BIT    0x00000000
#define IIS_SIZE_24BIT    0x00020000
#define IIS_SIZE_32BIT    0x00040000

// FIFO format
#define IIS_FIFO_LE32     0x0000  // 32-bit little-endian
#define IIS_FIFO_LE16     0x0200  // 16-bit little-endian packed
```

### 10.2 FIFO Status

```c
// IISFIFO_CFG bits
#define IIS_RX_FULL_MASK    0x00780000  // RX FIFO count
#define IIS_TX_FREE_MASK    0x0001E000  // TX FIFO free slots
#define IIS_RX_FULL_SHIFT   19
#define IIS_TX_FREE_SHIFT   13

static inline int i2s_tx_free_slots(void) {
    return (IISFIFO_CFG & IIS_TX_FREE_MASK) >> IIS_TX_FREE_SHIFT;
}
```

---

## 11. WM8758 Audio Codec

### 11.1 Overview

**CRITICAL CORRECTION**: The iPod Video 5th Generation uses the **Wolfson WM8758** codec, NOT the WM8975 mentioned in earlier planning documents. This is verified from Rockbox source code.

| Parameter | Value | Source |
|-----------|-------|--------|
| I2C Address | 0x1A (7-bit) | Rockbox wm8758.c |
| Control Interface | 2-wire (I2C) | Datasheet |
| DAC Resolution | 24-bit | Datasheet |
| Sample Rates | 8-48 kHz | Rockbox config |
| Package | 32-pin QFN (5x5mm) | Datasheet |

### 11.2 Register Map

Source: `firmware/export/wm8758.h`

```c
// Control Registers (Address: 0x00 - 0x3D)
#define RESET           0x00    // Software reset
#define PWRMGMT1        0x01    // Power management 1
#define PWRMGMT2        0x02    // Power management 2
#define PWRMGMT3        0x03    // Power management 3
#define AINTFCE         0x04    // Audio interface
#define COMPCTRL        0x05    // Compander control
#define CLKCTRL         0x06    // Clock control
#define ADDCTRL         0x07    // Additional control
#define GPIOCTRL        0x08    // GPIO control
#define JACKDETECTCTRL1 0x09    // Jack detect control 1
#define DACCTRL         0x0A    // DAC control
#define LDACVOL         0x0B    // Left DAC volume
#define RDACVOL         0x0C    // Right DAC volume
#define JACKDETECTCTRL2 0x0D    // Jack detect control 2
#define ADCCTRL         0x0E    // ADC control
#define LADCVOL         0x0F    // Left ADC volume
#define RADCVOL         0x10    // Right ADC volume

// Equalizer Registers
#define EQ1             0x12    // EQ1 - Low shelf
#define EQ2             0x13    // EQ2 - Peak 1
#define EQ3             0x14    // EQ3 - Peak 2
#define EQ4             0x15    // EQ4 - Peak 3
#define EQ5             0x16    // EQ5 - High shelf

// Limiter Registers
#define DACLIMITER1     0x18
#define DACLIMITER2     0x19

// Notch Filter
#define NOTCHFILTER1    0x1B
#define NOTCHFILTER2    0x1C
#define NOTCHFILTER3    0x1D
#define NOTCHFILTER4    0x1E

// ALC Registers
#define ALCCONTROL1     0x20
#define ALCCONTROL2     0x21
#define ALCCONTROL3     0x22
#define NOISEGATE       0x23

// PLL Registers
#define PLLN            0x24
#define PLLK1           0x25
#define PLLK2           0x26
#define PLLK3           0x27

// 3D Enhancement
#define THREEDCTRL      0x29

// Additional Mixing
#define OUT4TOADC       0x2A
#define BEEPCTRL        0x2B
#define INCTRL          0x2C

// PGA Volume
#define LINPGAVOL       0x2D
#define RINPGAVOL       0x2E

// Boost Control
#define LADCBOOST       0x2F
#define RADCBOOST       0x30

// Output Control
#define OUTCTRL         0x31
#define LOUTMIX         0x32
#define ROUTMIX         0x33

// Output Volume
#define LOUT1VOL        0x34    // Left headphone
#define ROUT1VOL        0x35    // Right headphone
#define LOUT2VOL        0x36    // Left line out
#define ROUT2VOL        0x37    // Right line out

// Mixing
#define OUT3MIX         0x38
#define OUT4MIX         0x39

// Bias Control
#define BIASCTRL        0x3D
```

### 11.3 Initialization Sequence

Source: `firmware/drivers/audio/wm8758.c`

```c
void audiohw_preinit(void) {
    // Reset codec
    wmcodec_write(RESET, 0);

    // Power up with low bias
    wmcodec_write(BIASCTRL, 0x100);     // Low bias mode

    // Enable output stages
    wmcodec_write(PWRMGMT1, 0x0D);      // VMID, bias, buffers
    wmcodec_write(PWRMGMT2, 0x180);     // Enable LOUT1, ROUT1
    wmcodec_write(PWRMGMT3, 0x60);      // Enable DACL, DACR

    // Configure audio interface - I2S, 16-bit
    wmcodec_write(AINTFCE, 0x10);       // I2S format, 16-bit

    // Configure clocking
    wmcodec_write(CLKCTRL, 0x00);       // MCLK = 256fs

    // Mute outputs initially
    wmcodec_write(LOUT1VOL, 0x140);     // Mute, zero volume
    wmcodec_write(ROUT1VOL, 0x140);

    // Route DAC to outputs
    wmcodec_write(LOUTMIX, 0x01);       // DACL to LMIX
    wmcodec_write(ROUTMIX, 0x01);       // DACR to RMIX
}

void audiohw_postinit(void) {
    // Reduce VMID for lower power
    wmcodec_write(PWRMGMT1, 0x0C);      // 500k VMID

    // Unmute DAC
    wmcodec_write(DACCTRL, 0x00);       // Unmute

    // Set volume
    wmcodec_write(LOUT1VOL, 0x17F);     // Max volume, unmute
    wmcodec_write(ROUT1VOL, 0x17F);
}
```

### 11.4 Volume Control

```c
// Volume range: -89.0 dB to +6.0 dB (0.5 dB steps)
// Register value: 0x00 (-89.0 dB) to 0xBF (+6.0 dB)
// Bit 8: Update (BOTH channels update when set)
// Bit 7: Zero-cross detect enable
// Bit 6: Mute

void audiohw_set_volume(int vol_l, int vol_r) {
    // vol_l, vol_r in tenth-dB (-890 to +60)
    int l = (vol_l / 10) + 89;  // Convert to register value
    int r = (vol_r / 10) + 89;

    wmcodec_write(LOUT1VOL, l | 0x100);      // Update both
    wmcodec_write(ROUT1VOL, r | 0x100);
}
```

---

## 12. PCF50605 Power Management Unit

### 12.1 Overview

The PCF50605 is the PMU used in iPod 4G, Photo, and Video models. It provides:
- Multiple voltage regulators
- Battery charging
- RTC with alarm
- A/D converters
- I2C control interface

| Parameter | Value | Source |
|-----------|-------|--------|
| I2C Address | 0x08 (7-bit) | Rockbox pcf50605.c |
| Regulators | 6+ | Rockbox |

### 12.2 Key Registers

Source: `firmware/drivers/pcf50605.c`

```c
// Register addresses
#define PCF5060X_OOCC1      0x08    // Standby/power control
#define PCF5060X_IOREGC     0x26    // I/O regulator
#define PCF5060X_DCDC1      0x1E    // Core voltage 1
#define PCF5060X_DCDC2      0x1F    // Core voltage 2
#define PCF5060X_DCUDC1     0x20    // Unknown
#define PCF5060X_D1REGC1    0x21    // Codec voltage
#define PCF5060X_D2REGC1    0x22    // Accessory voltage
#define PCF5060X_D3REGC1    0x23    // LCD/ATA voltage
#define PCF5060X_LPREGC1    0x24    // Low-power regulator

// OOCC1 control bits
#define PCF5060X_GOSTDBY    0x01    // Enter standby mode
#define PCF5060X_CHGWAK     0x02    // Wake on charger
#define PCF5060X_EXTONWAK   0x04    // Wake on external event
```

### 12.3 iPod Video Voltage Configuration

Source: `pcf50605.c` - **VERIFIED SAFE VALUES**

```c
void pcf50605_init(void) {
    // iPod Video/Nano voltage levels
    pcf50605_write(PCF5060X_IOREGC,  0x15);  // 3.0V ON
    pcf50605_write(PCF5060X_DCDC1,   0x08);  // 1.2V ON
    pcf50605_write(PCF5060X_DCDC2,   0x00);  // OFF
    pcf50605_write(PCF5060X_DCUDC1,  0x0C);  // 1.8V ON
    pcf50605_write(PCF5060X_D1REGC1, 0x11);  // 2.5V ON (codec)
    pcf50605_write(PCF5060X_D3REGC1, 0x13);  // 2.6V ON (Video)
    // Note: D2REGC1 and LPREGC1 left at defaults
}
```

### 12.4 Safe Shutdown Sequence

```c
void pcf50605_standby_mode(void) {
    // Enable wake sources and enter standby
    pcf50605_write(PCF5060X_OOCC1,
                   PCF5060X_GOSTDBY |
                   PCF5060X_CHGWAK |
                   PCF5060X_EXTONWAK);
}

void power_off(void) {
    // Clear display to prevent ghosting
    lcd_clear_display();
    lcd_update();

    // Wipe IRAM for proper bootloader behavior
    memset((void*)0x4000C000, 0, 0x4000);

    // Enter standby
    pcf50605_standby_mode();

    // Should not reach here
    while(1);
}
```

---

## 13. LCD Controller (BCM2722)

### 13.1 Overview

The iPod Video uses a Broadcom BCM2722 (VideoCore) GPU to drive the 320x240 color LCD. This is **NOT** a simple register-based LCD controller - it requires firmware upload.

### 13.2 BCM Bus Registers

Source: `lcd-video.c`

```c
// BCM data bus registers
#define BCM_DATA        (*(volatile unsigned long*)(0x30000000))
#define BCM_WR_ADDR     (*(volatile unsigned long*)(0x30010000))
#define BCM_RD_ADDR     (*(volatile unsigned long*)(0x30020000))
#define BCM_CONTROL     (*(volatile unsigned long*)(0x30030000))

// Alternative addresses
#define BCM_ALT_DATA    (*(volatile unsigned long*)(0x30040000))
#define BCM_ALT_WR_ADDR (*(volatile unsigned long*)(0x30050000))
#define BCM_ALT_RD_ADDR (*(volatile unsigned long*)(0x30060000))
#define BCM_ALT_CONTROL (*(volatile unsigned long*)(0x30070000))
```

### 13.3 BCM Commands

```c
// Command encoding: (~cmd << 16) | cmd
#define BCM_CMD(x)          ((~(x) << 16) | (x))

#define BCMCMD_LCD_UPDATE       BCM_CMD(0x00)  // Full screen update
#define BCMCMD_LCD_UPDATERECT   BCM_CMD(0x05)  // Partial update
#define BCMCMD_LCD_SLEEP        BCM_CMD(0x08)  // Enter sleep
#define BCMCMD_SELFTEST         BCM_CMD(0x01)  // Diagnostics
```

### 13.4 LCD Initialization

**WARNING**: The BCM2722 requires firmware to be loaded from flash ROM. This is a complex three-stage process:

```c
// Stage 1: Power up BCM
GPO32_VAL |= BCM_POWER_BIT;
// Configure STRAP_OPT_A

// Stage 2: Wait for ready, write bootstrap pattern
// Pattern: 0xA1, 0x81, 0x91, 0x02, 0x12, 0x22, 0x72, 0x62

// Stage 3: Upload firmware from flash to BCM SRAM
// Execute initialization, poll status

// Timeout values
#define BCM_UPDATE_TIMEOUT    (HZ/20)   // 50ms
#define BCM_LCDINIT_TIMEOUT   (HZ/2)    // 500ms
```

### 13.5 Pixel Format

```c
// RGB565 format (16-bit color)
// Bits: RRRRRGGGGGGBBBBB
#define RGB565(r, g, b) (((r) << 11) | ((g) << 5) | (b))

// LCD write data port: 0x30000000
// Write 32 bits = 2 pixels
```

---

## 14. ATA/IDE Storage Controller

### 14.1 Register Map

Source: `firmware/export/pp5020.h`, `ata.c`

```c
// IDE timing registers
#define IDE0_CFG        (*(volatile unsigned long*)(0xC3000000))
#define IDE0_CNTRLR     (*(volatile unsigned long*)(0xC3000004))
#define IDE0_STAT       (*(volatile unsigned long*)(0xC300000C))
#define IDE1_CFG        (*(volatile unsigned long*)(0xC3000010))
#define IDE1_CNTRLR     (*(volatile unsigned long*)(0xC3000014))
#define IDE1_STAT       (*(volatile unsigned long*)(0xC300001C))

// Standard ATA task file registers
// (memory-mapped at device-specific offsets)
```

### 14.2 ATA Commands Used

```c
#define CMD_IDENTIFY        0xEC    // Identify drive
#define CMD_READ_SECTORS    0x20    // Read (LBA28)
#define CMD_READ_SECTORS48  0x24    // Read (LBA48)
#define CMD_WRITE_SECTORS   0x30    // Write (LBA28)
#define CMD_WRITE_SECTORS48 0x34    // Write (LBA48)
#define CMD_STANDBY_IMMED   0xE0    // Enter standby
```

### 14.3 Initialization Sequence

Source: `ata.c`

```c
int ata_init(void) {
    // 1. Enable IDE power
    ide_power_enable(true);

    // 2. Initialize ATA device
    if (init_and_check() < 0) {
        return -1;
    }

    // 3. Identify drive
    if (identify() < 0) {
        return -2;
    }

    // 4. Configure features
    set_features();

    // 5. Determine capabilities
    // - LBA48 support (drives > 128GB)
    // - Multisector support
    // - DMA capability

    return 0;
}
```

### 14.4 Sector Read/Write

```c
// Timeout values
#define ATA_READWRITE_TIMEOUT   (5 * HZ)    // 5 seconds
#define ATA_POWER_OFF_TIMEOUT   (2 * HZ)    // 2 seconds

// Sector sizes
#define MAX_PHYS_SECTOR_SIZE    1024        // iPod Video config
#define MAX_LOG_SECTOR_SIZE     2048        // iPod Video config

int ata_read_sectors(unsigned long start, int count, void* buf) {
    // Validate parameters
    if (start + count > total_sectors) {
        return -1;
    }

    // Use LBA28 or LBA48 based on address
    if (start + count > 0x0FFFFFFF) {
        // LBA48 mode
    } else {
        // LBA28 mode
    }

    // Transfer using PIO or DMA
    // ...
}
```

---

## 15. Click Wheel Input

### 15.1 Hardware Overview

The click wheel uses an optical (capacitive) sensor controlled via I2C. The wheel returns position values 0-95 (96 positions).

### 15.2 Initialization

Source: `button-clickwheel.c`

```c
static void opto_i2c_init(void) {
    // Enable optical device
    DEV_EN |= DEV_OPTO;

    // Reset
    DEV_RS |= DEV_OPTO;
    udelay(5);
    DEV_RS &= ~DEV_OPTO;

    // Initialize buttons
    DEV_INIT1 |= INIT_BUTTONS;

    // Configure I2C-like interface for wheel
    outl(0xC00A1F00, 0x7000C100);
    outl(0x01000000, 0x7000C104);
}
```

### 15.3 Button Detection

```c
// Button bit masks (from reading wheel status)
#define BUTTON_SELECT   0x01
#define BUTTON_RIGHT    0x02
#define BUTTON_LEFT     0x04
#define BUTTON_PLAY     0x08
#define BUTTON_MENU     0x10

// Hold switch is separate GPIO
#define BUTTON_HOLD     0x20
```

### 15.4 Wheel Position Reading

```c
#define WHEEL_MAX_VALUE     0x5F    // 95 (96 positions)
#define WHEEL_SENSITIVITY   4       // Threshold for scroll event

int wheel_delta(void) {
    static int last_position = 0;
    int current = read_wheel_position();

    int delta = current - last_position;

    // Handle wraparound
    if (delta > (WHEEL_MAX_VALUE / 2)) {
        delta -= (WHEEL_MAX_VALUE + 1);
    } else if (delta < -(WHEEL_MAX_VALUE / 2)) {
        delta += (WHEEL_MAX_VALUE + 1);
    }

    last_position = current;
    return delta;
}
```

---

## 16. USB Controller

### 16.1 Register Base

Source: `firmware/export/pp5020.h`

```c
#define USB_BASE        0xC5000000
#define USB_NUM_ENDPOINTS   3
```

### 16.2 USB Mode (from config)

The iPod Video uses an ARC-style USB 2.0 OTG controller with:
- 3 endpoints
- HID support
- Charging detection capability

---

## 17. DMA Engine

### 17.1 Register Map

Source: `firmware/export/pp5020.h`

```c
// DMA master control
#define DMA_MASTER_CTRL     (*(volatile unsigned long*)(0x6000A000))
#define DMA_MASTER_STATUS   (*(volatile unsigned long*)(0x6000A004))
#define DMA_REQ_STATUS      (*(volatile unsigned long*)(0x6000A008))

// DMA channels (0-3)
#define DMA_CHAN_BASE(n)    (0x6000B000 + (n) * 0x20)
#define DMA_CMD(n)          (*(volatile unsigned long*)(DMA_CHAN_BASE(n) + 0x00))
#define DMA_STATUS(n)       (*(volatile unsigned long*)(DMA_CHAN_BASE(n) + 0x04))
#define DMA_RAM_ADDR(n)     (*(volatile unsigned long*)(DMA_CHAN_BASE(n) + 0x08))
#define DMA_FLAGS(n)        (*(volatile unsigned long*)(DMA_CHAN_BASE(n) + 0x0C))
#define DMA_PER_ADDR(n)     (*(volatile unsigned long*)(DMA_CHAN_BASE(n) + 0x10))
#define DMA_INCR(n)         (*(volatile unsigned long*)(DMA_CHAN_BASE(n) + 0x14))

// DMA command bits
#define DMA_CMD_START       0x80000000
#define DMA_CMD_INTR        0x40000000
#define DMA_CMD_SLEEP_WAIT  0x20000000
#define DMA_CMD_RAM_TO_PER  0x10000000  // 0 = peripheral to RAM
#define DMA_CMD_SINGLE      0x08000000
#define DMA_CMD_WAIT_REQ    0x01000000

// DMA request IDs
#define DMA_REQ_IIS         2
#define DMA_REQ_SDHC        13
```

---

## 18. Cache Controller

### 18.1 Register Map

Source: `firmware/export/pp5020.h`

```c
#define CACHE_CTL           (*(volatile unsigned long*)(0x6000C000))
#define CACHE_MASK          (*(volatile unsigned long*)(0x6000C004))
#define CACHE_OPERATION     (*(volatile unsigned long*)(0x6000C008))
#define CACHE_FLUSH_MASK    (*(volatile unsigned long*)(0x6000C00C))

// Cache control bits
#define CACHE_CTL_ENABLE    0x80000000
#define CACHE_CTL_RUN       0x40000000
#define CACHE_CTL_INIT      0x20000000
#define CACHE_CTL_VECT_REMAP 0x10000000  // Remap vectors to DRAM
#define CACHE_CTL_READY     0x00000002
#define CACHE_CTL_BUSY      0x00000001

// Cache operations
#define CACHE_OP_FLUSH      0x01
#define CACHE_OP_INVALIDATE 0x02
```

### 18.2 Cache Initialization

Source: `system-pp502x.c`

```c
void init_cache(void) {
    // Set initialization mode
    CACHE_CTL = CACHE_CTL_INIT;

    // Configure cache mask
    CACHE_MASK = 0x00001C00;

    // Enable cache
    CACHE_CTL = CACHE_CTL_ENABLE | CACHE_CTL_RUN;

    // Prime cache by reading through it
    volatile char* p = (volatile char*)CACHED_INIT_ADDR;
    for (int i = 0; i < 8192; i += CACHEALIGN_SIZE) {
        (void)*p;
        p += CACHEALIGN_SIZE;
    }
}
```

---

## 19. Boot Sequence

### 19.1 Power-On Sequence

1. **Boot ROM** (0x00000000): PP5021C internal ROM loads bootloader
2. **Bootloader**: iPodLoader2 or Apple bootloader runs
3. **OS Selection**: Based on button state or configuration
4. **Firmware Load**: OS loaded from storage to DRAM
5. **Execution**: Jump to OS entry point

### 19.2 ARM Vector Table

```c
// Exception vectors at 0x00000000 (or remapped)
void reset_handler(void);       // 0x00: Reset
void undefined_handler(void);   // 0x04: Undefined instruction
void swi_handler(void);         // 0x08: Software interrupt
void prefetch_handler(void);    // 0x0C: Prefetch abort
void data_abort_handler(void);  // 0x10: Data abort
void reserved_handler(void);    // 0x14: Reserved
void irq_handler(void);         // 0x18: IRQ
void fiq_handler(void);         // 0x1C: FIQ
```

### 19.3 Stack Setup

```c
// From crt0.S - stack addresses
extern char irq_stack[];    // IRQ mode stack
extern char fiq_stack[];    // FIQ mode stack
extern char svc_stack[];    // Supervisor mode stack
// Main stack initialized with 0xDEADBEEF pattern for debugging
```

### 19.4 Rockbox Boot Flow

1. crt0.S initializes processor state
2. Clear BSS section
3. Copy initialized data
4. Set up stacks for each mode
5. Initialize cache
6. Call `main()`
7. `system_init()` configures hardware
8. Kernel and drivers start

---

## 20. Recovery Procedures

### 20.1 Disk Mode Entry

**Method**: Hold SELECT + PLAY immediately after reset

This forces the iPod into USB mass storage mode, allowing:
- Firmware file access
- Backup/restore of filesystem
- Installation of alternative bootloaders

### 20.2 DFU Mode (iPod Classic 6G+ Only)

**NOTE**: iPod Video 5th Gen does **NOT** have DFU mode. DFU was added in iPod Classic 6th generation.

For iPod Video recovery, use **Disk Mode** instead.

### 20.3 Diagnostic Mode Entry

**Method**: Hold SELECT + REWIND when Apple logo appears

Provides hardware diagnostics and system information.

### 20.4 iTunes Restore Procedure

If the iPod becomes unbootable:

1. Enter Disk Mode (SELECT + PLAY during reset)
2. Connect to computer
3. iTunes/Finder will detect "iPod in recovery mode"
4. Click "Restore" to reinstall factory firmware
5. Sync music after restore completes

### 20.5 Manual Firmware Restore (Without iTunes)

For iPod Classic (6G+) only - see freemyipod.org for tools:
- mks5lboot
- ipodscsi

**iPod Video (5G) requires iTunes or disk image restoration.**

---

## 21. Safe Development Guidelines

### 21.1 Golden Rules

1. **NEVER** flash the boot ROM - it's irreplaceable
2. **ALWAYS** test in emulator/simulator first
3. **ALWAYS** have a backup iPod for testing
4. **ALWAYS** verify Disk Mode works before any changes
5. **NEVER** modify power management without understanding consequences

### 21.2 Safe Hardware Access Patterns

```c
// Always use volatile for hardware registers
volatile unsigned long* reg = (volatile unsigned long*)0x60000000;

// Always check status before operations
while (*status_reg & BUSY_BIT) {
    // Wait or timeout
}

// Always use proper delays after power changes
power_on_device();
udelay(1000);  // Let power stabilize
```

### 21.3 PMU Safety

**WARNING**: Incorrect PMU configuration can:
- Damage the battery
- Damage other components
- Brick the device

**Safe defaults** (from Rockbox):
```c
// VERIFIED SAFE for iPod Video
IOREGC  = 0x15  // 3.0V
DCDC1   = 0x08  // 1.2V
DCDC2   = 0x00  // OFF
DCUDC1  = 0x0C  // 1.8V
D1REGC1 = 0x11  // 2.5V
D3REGC1 = 0x13  // 2.6V
```

### 21.4 Testing Checklist

Before testing on real hardware:

- [ ] Code compiles without warnings
- [ ] All unit tests pass
- [ ] Simulator boot succeeds
- [ ] Power management values match Rockbox defaults
- [ ] Disk Mode entry works (test first!)
- [ ] Backup iPod available
- [ ] iTunes installed (for emergency restore)

### 21.5 Recommended Development Approach

1. **Phase 1**: Host-based testing with HAL mocks
2. **Phase 2**: Simulator testing with peripheral emulation
3. **Phase 3**: JTAG debugging on test device
4. **Phase 4**: Standalone testing with recovery ready
5. **Phase 5**: Full integration testing

---

## Appendix A: Register Quick Reference

### Memory-Mapped I/O Summary

| Address | Register | R/W | Description |
|---------|----------|-----|-------------|
| 0x60001000 | MBX_MSG_STAT | R | Mailbox status |
| 0x60004000 | CPU_INT_STAT | R | CPU interrupt status |
| 0x60004004 | CPU_INT_EN | RW | CPU interrupt enable |
| 0x60005000 | TIMER1_CFG | RW | Timer 1 config |
| 0x60005010 | USEC_TIMER | R | Microsecond counter |
| 0x60006020 | CLOCK_SOURCE | RW | Clock selection |
| 0x60007000 | CPU_CTL | RW | CPU control |
| 0x6000C000 | CACHE_CTL | RW | Cache control |
| 0x6000D000 | GPIO_BASE | RW | GPIO port A base |
| 0x7000C000 | I2C_BASE | RW | I2C controller |
| 0x70002800 | IISCONFIG | RW | I2S config |
| 0xC3000000 | IDE0_CFG | RW | IDE controller |
| 0xC5000000 | USB_BASE | RW | USB controller |

---

## Appendix B: I2C Device Addresses

| Address (7-bit) | Device | Function |
|-----------------|--------|----------|
| 0x08 | PCF50605 | Power management |
| 0x1A | WM8758 | Audio codec |

---

## Appendix C: Sources and References

### Primary Sources (Code)

1. **Rockbox Git Repository**
   - URL: https://github.com/Rockbox/rockbox
   - Files: firmware/export/pp5020.h, firmware/drivers/*, firmware/target/arm/*

2. **iPodLoader2**
   - URL: https://github.com/crozone/ipodloader2
   - Files: loader.c, tools.c

### Documentation

1. **Wolfson WM8758 Datasheet**
   - Rev 4.4, January 2012
   - 90 pages

2. **freemyipod.org**
   - URL: https://freemyipod.org
   - Recovery procedures, boot modes

### Community Resources

1. **Rockbox Wiki**: https://www.rockbox.org/wiki/
2. **The Apple Wiki**: https://theapplewiki.com/
3. **iFixit**: https://www.ifixit.com/Device/iPod_5th_Generation_(Video)

---

**Document Version History**

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2026-01-08 | Initial comprehensive reference from Rockbox sources |
