# ZigPod Safe Initialization Sequences

**Version**: 1.0
**Last Updated**: 2026-01-08
**Status**: Verified from Rockbox Sources
**CRITICAL**: Follow these sequences exactly to avoid hardware damage

---

## Table of Contents

1. [Overview](#1-overview)
2. [Power-On Reset Sequence](#2-power-on-reset-sequence)
3. [Clock Initialization](#3-clock-initialization)
4. [Memory Initialization](#4-memory-initialization)
5. [PMU Configuration](#5-pmu-configuration)
6. [Audio Codec Initialization](#6-audio-codec-initialization)
7. [LCD Initialization](#7-lcd-initialization)
8. [Storage Initialization](#8-storage-initialization)
9. [Safe Shutdown Sequence](#9-safe-shutdown-sequence)
10. [Emergency Recovery](#10-emergency-recovery)

---

## 1. Overview

### 1.1 Why Order Matters

The iPod Video hardware has strict initialization dependencies:

```
┌─────────────────────────────────────────────────────────────┐
│                    INITIALIZATION ORDER                      │
├─────────────────────────────────────────────────────────────┤
│  1. CPU/Clock Setup         Must be first                   │
│  2. PMU Voltage Rails        Powers all other components    │
│  3. Memory (SDRAM)           Required for code execution    │
│  4. Cache                    Performance, can be deferred   │
│  5. I2C Bus                  Required for PMU/codec control │
│  6. Audio Codec              After I2C and PMU stable       │
│  7. Storage (ATA)            After PMU provides power       │
│  8. LCD/BCM                  Complex, requires firmware     │
│  9. Click Wheel              After basic I/O ready          │
│  10. USB                     Optional, for connectivity     │
└─────────────────────────────────────────────────────────────┘
```

### 1.2 Critical Timing Requirements

| Operation | Minimum Delay | Maximum | Source |
|-----------|--------------|---------|--------|
| PMU register write | 1 ms | - | PCF50605 |
| PMU voltage settle | 5 ms | 50 ms | PCF50605 |
| I2C transaction | - | 1 s timeout | Rockbox |
| ATA reset | 50 ms | 31 s | ATA spec |
| BCM firmware load | - | 500 ms | Rockbox |
| Codec PLL lock | 10 ms | 100 ms | WM8758 |

---

## 2. Power-On Reset Sequence

### 2.1 CPU State After Reset

When the PP5021C comes out of reset:

```c
// Initial CPU state
// - Supervisor mode
// - IRQ/FIQ disabled
// - Cache disabled
// - PC = 0x00000000 (boot ROM)
```

### 2.2 Vector Table Setup

**VERIFIED from Rockbox crt0.S**:

```asm
.section .vectors, "ax"
.global _start
_start:
    b   reset_handler       @ 0x00: Reset
    b   undef_handler       @ 0x04: Undefined instruction
    b   swi_handler         @ 0x08: Software interrupt
    b   prefetch_handler    @ 0x0C: Prefetch abort
    b   data_abort_handler  @ 0x10: Data abort
    b   reserved_handler    @ 0x14: Reserved
    b   irq_handler         @ 0x18: IRQ
    b   fiq_handler         @ 0x1C: FIQ
```

### 2.3 Mode and Stack Setup

```c
// From Rockbox crt0.S - VERIFIED SAFE
void setup_stacks(void) {
    // Enter IRQ mode, set stack
    __asm__("msr cpsr_c, #0xD2");  // IRQ mode, I/F disabled
    __asm__("ldr sp, =irq_stack");

    // Enter FIQ mode, set stack
    __asm__("msr cpsr_c, #0xD1");  // FIQ mode, I/F disabled
    __asm__("ldr sp, =fiq_stack");

    // Enter Supervisor mode for main execution
    __asm__("msr cpsr_c, #0xD3");  // SVC mode, I/F disabled
    __asm__("ldr sp, =svc_stack");
}
```

---

## 3. Clock Initialization

### 3.1 Safe Boot Clock Configuration

**CRITICAL**: Start with slow, safe clocks before enabling PLL.

```c
// Step 1: Ensure we're on a stable clock source
// Use 32kHz until PLL is configured and locked
void clock_safe_init(void) {
    // Start with 32kHz clock source
    CLOCK_SOURCE = 0x20002222;  // All sources = 32kHz

    // Small delay for stability
    volatile int i;
    for (i = 0; i < 1000; i++);
}
```

### 3.2 PLL Enable Sequence

**VERIFIED from Rockbox system-pp502x.c**:

```c
void clock_enable_pll(void) {
    // Step 1: Configure PLL (device-specific multipliers)
    // PP5022 uses different values than PP5020

    // Step 2: Enable PLL
    PLL_CONTROL |= 0x80000000;

    // Step 3: CRITICAL - Wait for PLL lock
    // Timeout after ~100ms
    int timeout = 10000;
    while (!(PLL_STATUS & 0x80000000)) {
        if (--timeout == 0) {
            // PLL failed to lock - stay on 32kHz
            return;
        }
        udelay(10);
    }

    // Step 4: Switch to PLL only after lock confirmed
    CLOCK_SOURCE = 0x20007777;  // All sources = PLL
}
```

### 3.3 Device Enable Sequence

```c
// Enable required devices - ORDER MATTERS
void enable_devices(void) {
    // Step 1: Enable core system devices
    DEV_EN = DEV_SYSTEM | DEV_EXTCLOCKS;

    // Step 2: Enable I2C (needed for PMU/codec)
    DEV_EN |= DEV_I2C;
    udelay(100);

    // Step 3: Enable audio subsystem
    DEV_EN |= DEV_I2S;

    // Step 4: Enable storage
    DEV_EN |= DEV_ATA;

    // Step 5: Enable display
    DEV_EN |= DEV_LCD;

    // Step 6: Enable click wheel
    DEV_EN |= DEV_OPTO;
}
```

---

## 4. Memory Initialization

### 4.1 BSS Section Clear

**MUST be done before using any global variables**:

```c
extern char __bss_start[];
extern char __bss_end[];

void clear_bss(void) {
    char* p = __bss_start;
    while (p < __bss_end) {
        *p++ = 0;
    }
}
```

### 4.2 Cache Initialization

**VERIFIED from Rockbox**:

```c
void init_cache(void) {
    // Step 1: Put cache in init mode
    CACHE_CTL = CACHE_CTL_INIT;

    // Step 2: Configure cache mask
    // This determines which memory regions are cached
    CACHE_MASK = 0x00001C00;

    // Step 3: Enable and run cache
    CACHE_CTL = CACHE_CTL_ENABLE | CACHE_CTL_RUN;

    // Step 4: Prime cache by reading through cacheable region
    // This ensures cache is properly warmed up
    volatile unsigned char* p = (volatile unsigned char*)0x40000000;
    for (int i = 0; i < 8192; i += 16) {  // 16 = CACHEALIGN_SIZE
        (void)*p;
        p += 16;
    }

    // Step 5: Optionally remap vectors to DRAM
    // CACHE_CTL |= CACHE_CTL_VECT_REMAP;
}
```

---

## 5. PMU Configuration

### 5.1 I2C Initialization for PMU Access

```c
void i2c_init_for_pmu(void) {
    // Ensure I2C device is enabled
    DEV_EN |= DEV_I2C;

    // Wait for I2C to be ready
    udelay(100);

    // Configure I2C timing (if needed)
    // Default timing usually works
}
```

### 5.2 PCF50605 Safe Voltage Configuration

**CRITICAL - These values are VERIFIED SAFE from Rockbox**:

```c
#define PCF50605_ADDR   0x08    // 7-bit I2C address

// VERIFIED SAFE VOLTAGE VALUES FOR IPOD VIDEO
// DO NOT MODIFY WITHOUT UNDERSTANDING CONSEQUENCES
static const struct {
    uint8_t reg;
    uint8_t value;
    const char* description;
} pmu_init_sequence[] = {
    { 0x26, 0x15, "IOREGC: 3.0V ON (I/O supply)" },
    { 0x1E, 0x08, "DCDC1: 1.2V ON (core)" },
    { 0x1F, 0x00, "DCDC2: OFF" },
    { 0x20, 0x0C, "DCUDC1: 1.8V ON" },
    { 0x21, 0x11, "D1REGC1: 2.5V ON (codec)" },
    { 0x23, 0x13, "D3REGC1: 2.6V ON (LCD/ATA)" },
    // D2REGC1 and LPREGC1 left at defaults
};

void pmu_init(void) {
    for (int i = 0; i < sizeof(pmu_init_sequence)/sizeof(pmu_init_sequence[0]); i++) {
        // Write register
        uint8_t data[2] = { pmu_init_sequence[i].reg, pmu_init_sequence[i].value };
        i2c_write(PCF50605_ADDR, data, 2);

        // CRITICAL: Wait for voltage to settle
        udelay(5000);  // 5ms between changes
    }

    // Final settling time
    udelay(10000);  // 10ms total settling
}
```

### 5.3 PMU Register Safety Rules

```c
// NEVER do these:
// - Don't set DCDC1 > 1.5V (core voltage)
// - Don't disable IOREGC while system running
// - Don't change multiple rails simultaneously
// - Don't skip settling delays

// ALWAYS do these:
// - Verify I2C communication before changing voltages
// - Use known-good values from Rockbox
// - Add settling delays after each change
// - Have recovery path if configuration fails
```

---

## 6. Audio Codec Initialization

### 6.1 Pre-Initialization Checks

```c
bool codec_sanity_check(void) {
    // Step 1: Verify I2C communication
    uint8_t test_read;
    if (i2c_read(WM8758_ADDR, &test_read, 1) < 0) {
        return false;  // I2C not working
    }

    // Step 2: Verify PMU codec voltage is stable
    // D1REGC1 should be at 2.5V
    // (Read back from PMU if supported)

    return true;
}
```

### 6.2 WM8758 Safe Initialization

**VERIFIED from Rockbox wm8758.c**:

```c
#define WM8758_ADDR     0x1A    // 7-bit I2C address

// Write to WM8758 register (9-bit data, 7-bit address)
void wmcodec_write(uint8_t reg, uint16_t data) {
    // WM8758 uses 16-bit I2C writes:
    // Byte 1: [A6:A0][D8]
    // Byte 2: [D7:D0]
    uint8_t buf[2];
    buf[0] = (reg << 1) | ((data >> 8) & 0x01);
    buf[1] = data & 0xFF;
    i2c_write(WM8758_ADDR, buf, 2);
}

void audiohw_preinit(void) {
    // Step 1: Software reset
    wmcodec_write(0x00, 0x000);  // RESET register
    udelay(10000);  // 10ms after reset

    // Step 2: Configure power management
    wmcodec_write(0x3D, 0x100);  // BIASCTRL: Low bias mode
    wmcodec_write(0x01, 0x00D);  // PWRMGMT1: VMID, bias, buffers
    udelay(5000);

    wmcodec_write(0x02, 0x180);  // PWRMGMT2: Enable outputs
    wmcodec_write(0x03, 0x060);  // PWRMGMT3: Enable DAC

    // Step 3: Configure audio interface
    wmcodec_write(0x04, 0x010);  // AINTFCE: I2S, 16-bit

    // Step 4: Mute outputs initially
    wmcodec_write(0x34, 0x140);  // LOUT1VOL: Muted
    wmcodec_write(0x35, 0x140);  // ROUT1VOL: Muted

    // Step 5: Configure mixer routing
    wmcodec_write(0x32, 0x001);  // LOUTMIX: DAC to output
    wmcodec_write(0x33, 0x001);  // ROUTMIX: DAC to output
}

void audiohw_postinit(void) {
    // Step 1: Reduce VMID impedance
    wmcodec_write(0x01, 0x00C);  // 500k VMID

    // Step 2: Unmute DAC
    wmcodec_write(0x0A, 0x000);  // DACCTRL: Unmute

    // Step 3: Set initial volume (moderate level)
    wmcodec_write(0x34, 0x150);  // LOUT1VOL: ~-30dB
    wmcodec_write(0x35, 0x150);  // ROUT1VOL: ~-30dB
}
```

### 6.3 I2S Configuration

```c
void i2s_init(void) {
    // Step 1: Reset I2S
    IISCONFIG = IIS_RESET;
    udelay(100);
    IISCONFIG = 0;

    // Step 2: Configure format
    // I2S standard, 16-bit, master mode
    IISCONFIG = IIS_FORMAT_IIS | IIS_SIZE_16BIT | IIS_MASTER;

    // Step 3: Enable TX FIFO
    IISCONFIG |= IIS_TXFIFOEN;

    // Step 4: Configure sample rate divider
    // For 44100 Hz with 80 MHz clock
    IISDIV = /* calculated value */;
}
```

---

## 7. LCD Initialization

### 7.1 BCM Power-Up Sequence

**WARNING**: BCM2722 initialization is complex and requires firmware.

```c
// LCD initialization is complex due to BCM2722 GPU
// It requires:
// 1. Power up BCM via GPO32
// 2. Wait for BCM ready signals
// 3. Upload bootstrap pattern
// 4. Load firmware from flash to BCM SRAM
// 5. Execute initialization commands

void lcd_init_device(void) {
    // Step 1: Configure GPIO for BCM
    // (Enable specific pins for BCM communication)

    // Step 2: Power up BCM
    GPO32_VAL |= BCM_POWER_BIT;
    udelay(1000);

    // Step 3: Configure STRAP options
    // (Device-specific)

    // Step 4: Wait for BCM ready (up to 500ms)
    int timeout = 50;
    while (!(bcm_ready()) && timeout-- > 0) {
        udelay(10000);
    }

    if (timeout <= 0) {
        // BCM failed to initialize
        return;
    }

    // Step 5: Send bootstrap pattern
    // 0xA1, 0x81, 0x91, 0x02, 0x12, 0x22, 0x72, 0x62
    bcm_write_bootstrap();

    // Step 6: Upload firmware from flash
    bcm_upload_firmware();

    // Step 7: Initialize display parameters
    bcm_init_display(320, 240, 16);  // Width, Height, BPP
}
```

### 7.2 Safe LCD Update

```c
void lcd_update(void) {
    // Check BCM is ready before update
    if (!(BCM_CONTROL & BCM_READY)) {
        return;
    }

    // Send update command
    BCM_WR_ADDR = framebuffer_address;
    BCM_CONTROL = BCMCMD_LCD_UPDATE;

    // Wait for completion (with timeout)
    int timeout = 1000;
    while ((BCM_CONTROL & BCM_BUSY) && timeout-- > 0) {
        udelay(50);
    }
}
```

---

## 8. Storage Initialization

### 8.1 IDE Power Sequence

```c
void ide_power_enable(bool enable) {
    if (enable) {
        // Enable IDE power via GPIO
        // (Port and pin are device-specific)
        GPIO_OUTPUT_VAL(IDE_POWER_PORT) |= (1 << IDE_POWER_PIN);

        // Enable ATA controller
        DEV_EN |= DEV_ATA;

        // CRITICAL: Wait for drive spinup
        udelay(50000);  // 50ms minimum
    } else {
        // Disable ATA controller first
        DEV_EN &= ~DEV_ATA;

        // Then cut power
        GPIO_OUTPUT_VAL(IDE_POWER_PORT) &= ~(1 << IDE_POWER_PIN);
    }
}
```

### 8.2 ATA Initialization Sequence

**VERIFIED from Rockbox ata.c**:

```c
int ata_init(void) {
    // Step 1: Power on drive
    ide_power_enable(true);

    // Step 2: Wait for drive ready (may take seconds)
    int timeout = 3100;  // 31 seconds max per ATA spec
    while (timeout-- > 0) {
        uint8_t status = ata_read_status();
        if (!(status & ATA_STATUS_BSY)) {
            break;
        }
        udelay(10000);  // 10ms per check
    }

    if (timeout <= 0) {
        return -1;  // Drive not responding
    }

    // Step 3: Software reset
    ata_soft_reset();
    udelay(50000);  // 50ms after reset

    // Step 4: Identify drive
    if (ata_identify() < 0) {
        return -2;
    }

    // Step 5: Configure transfer mode
    ata_set_pio_mode(4);  // PIO Mode 4

    return 0;
}
```

### 8.3 Safe Sector Access

```c
int ata_read_sectors(uint32_t lba, uint16_t count, void* buffer) {
    // Validate parameters
    if (lba + count > drive_total_sectors) {
        return -1;  // Out of bounds
    }

    // Check drive is ready
    if (!ata_wait_ready(5000)) {  // 5 second timeout
        return -2;  // Drive not ready
    }

    // Select LBA mode
    // Use LBA48 for addresses > 28 bits
    if (lba > 0x0FFFFFFF || count > 256) {
        return ata_read_sectors_lba48(lba, count, buffer);
    } else {
        return ata_read_sectors_lba28(lba, count, buffer);
    }
}
```

---

## 9. Safe Shutdown Sequence

### 9.1 Complete Shutdown Procedure

```c
void system_shutdown(void) {
    // Step 1: Stop audio playback
    audio_stop();
    i2s_disable();

    // Step 2: Mute codec outputs
    wmcodec_write(0x34, 0x140);  // Mute left
    wmcodec_write(0x35, 0x140);  // Mute right

    // Step 3: Power down codec
    wmcodec_write(0x03, 0x000);  // Disable DAC
    wmcodec_write(0x02, 0x000);  // Disable outputs
    wmcodec_write(0x01, 0x000);  // Disable VMID

    // Step 4: Park disk heads
    ata_sleep();
    udelay(100000);  // 100ms for heads to park

    // Step 5: Power off IDE
    ide_power_enable(false);

    // Step 6: Clear display (prevent ghosting)
    lcd_clear_display();
    lcd_update();

    // Step 7: Put LCD to sleep
    bcm_sleep();

    // Step 8: Clear IRAM (for bootloader)
    memset((void*)0x4000C000, 0, 0x4000);

    // Step 9: Enter PMU standby
    pcf50605_standby_mode();

    // Should not reach here
    while(1);
}
```

### 9.2 PMU Standby Mode

```c
void pcf50605_standby_mode(void) {
    // Configure wake sources and enter standby
    // GOSTDBY: Enter standby
    // CHGWAK: Wake on charger connect
    // EXTONWAK: Wake on button press
    uint8_t data[2] = { 0x08, 0x07 };  // OOCC1 register
    i2c_write(PCF50605_ADDR, data, 2);

    // Device will power off after this write
}
```

---

## 10. Emergency Recovery

### 10.1 If Initialization Fails

```c
void emergency_recovery(void) {
    // Step 1: Disable all interrupts
    __asm__("cpsid if");  // Disable IRQ and FIQ

    // Step 2: Reset to safe clock
    CLOCK_SOURCE = 0x20002222;  // 32kHz

    // Step 3: Try to enter disk mode
    // Write magic value to memory
    *(volatile uint32_t*)0x40017F00 = 0x0000DEAD;

    // Step 4: Trigger reset
    // (Device-specific reset mechanism)

    // If reset doesn't work, infinite loop
    while(1);
}
```

### 10.2 Disk Mode Entry from Code

```c
void enter_disk_mode(void) {
    // Clear IRAM
    memset((void*)0x4000C000, 0, 0x4000);

    // Set disk mode flag in IRAM
    *(volatile uint32_t*)0x4001FF00 = 0x44495343;  // "DISC"

    // Soft reset to bootloader
    soft_reset();
}
```

### 10.3 User Recovery Instructions

If the device becomes unresponsive:

1. **Toggle HOLD switch** - may trigger reset detection
2. **Hard reset**: Hold MENU + SELECT for 10 seconds
3. **Disk Mode**: While resetting, hold SELECT + PLAY
4. **Diagnostic Mode**: While resetting, hold SELECT + REWIND
5. **iTunes Restore**: Connect to computer, use iTunes to restore

---

## Appendix: Initialization Checklist

### Pre-Boot Checklist

- [ ] Vector table at correct address
- [ ] Stack pointers set for all modes
- [ ] BSS section cleared
- [ ] Clock source stable (32kHz or PLL locked)

### PMU Checklist

- [ ] I2C communication verified
- [ ] Voltage values match Rockbox defaults
- [ ] Settling delays after each change
- [ ] No simultaneous rail changes

### Audio Checklist

- [ ] Codec reset performed
- [ ] Power management in correct order
- [ ] Outputs muted before enabling
- [ ] I2S configured before unmuting

### Storage Checklist

- [ ] IDE power stable before access
- [ ] Drive ready status checked
- [ ] Proper timeout handling
- [ ] LBA mode selected correctly

### LCD Checklist

- [ ] BCM powered and ready
- [ ] Bootstrap pattern sent
- [ ] Firmware loaded
- [ ] Frame buffer address valid

---

**Document Version History**

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2026-01-08 | Initial safe initialization guide |
