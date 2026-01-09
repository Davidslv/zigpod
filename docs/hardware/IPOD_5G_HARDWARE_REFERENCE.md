# iPod Classic 5th/5.5th Generation Hardware Reference

This document provides comprehensive hardware specifications for the iPod Video (5th generation) and iPod Video Enhanced (5.5th generation), the target platform for ZigPod.

## Device Identification

| Model | Generation | Capacity | Model Number |
|-------|------------|----------|--------------|
| iPod Video | 5th Gen | 30GB/60GB | A1136 |
| iPod Video Enhanced | 5.5th Gen | 30GB/80GB | A1136 |

The 5.5th generation is visually identical to the 5th generation but has improved search functionality and a brighter screen. Both use the same SoC and are fully compatible with ZigPod.

---

## System-on-Chip: PortalPlayer PP5021C-TDF

### Overview

The PP5021C is a system-on-chip manufactured by PortalPlayer (acquired by NVIDIA in 2007). It is a lower-power variant of the PP5020 with minor changes.

### CPU Cores

| Feature | Specification |
|---------|---------------|
| Architecture | Dual ARM7TDMI |
| Clock Speed | 80 MHz (can be scaled) |
| Instruction Set | ARMv4T (ARM + Thumb) |
| Cache | 3x 32KB shared SRAM banks |
| Endianness | Little-endian |

**Note**: Both cores share memory and peripherals. ZigPod primarily uses one core; the second can be used for background audio decoding.

### Memory Map

| Region | Start Address | End Address | Size | Description |
|--------|---------------|-------------|------|-------------|
| Boot ROM | 0x00000000 | 0x0001FFFF | 128 KB | Factory boot code (read-only) |
| IRAM | 0x10000000 | 0x10017FFF | 96 KB | Fast internal SRAM |
| Peripherals | 0x60000000 | 0x6FFFFFFF | - | Memory-mapped I/O |
| Peripheral Alt | 0x70000000 | 0x7FFFFFFF | - | Alternate peripheral access |
| SDRAM | 0x40000000 | 0x41FFFFFF | 32 MB | Main system memory |
| SDRAM (NC) | 0x42000000 | 0x43FFFFFF | 32 MB | Non-cached SDRAM (for DMA) |

### Key Peripheral Registers

#### System Controller (0x60000000)

| Register | Offset | Description |
|----------|--------|-------------|
| DEV_RS | 0x0000 | Device reset control |
| DEV_RS2 | 0x0004 | Device reset control 2 |
| DEV_EN | 0x0008 | Device enable |
| DEV_EN2 | 0x000C | Device enable 2 |
| STRAP | 0x0040 | Hardware configuration straps |

#### Clock Controller (0x60006000)

| Register | Offset | Description |
|----------|--------|-------------|
| CLOCK_SOURCE | 0x0020 | Clock source selection |
| PLL_CONTROL | 0x0034 | PLL configuration |
| PLL_STATUS | 0x003C | PLL lock status |
| PLL_UNLOCK | 0x0048 | PLL unlock sequence |

#### GPIO Controller (0x6000D000)

| Register | Offset | Description |
|----------|--------|-------------|
| GPIOA_ENABLE | 0x0000 | Port A enable |
| GPIOA_OUTPUT_EN | 0x0010 | Port A output enable |
| GPIOA_OUTPUT_VAL | 0x0020 | Port A output value |
| GPIOA_INPUT_VAL | 0x0030 | Port A input value |
| GPIOA_INT_EN | 0x0040 | Port A interrupt enable |
| GPIOA_INT_LEV | 0x0050 | Port A interrupt level |
| GPIOA_INT_CLR | 0x0060 | Port A interrupt clear |
| GPIOA_INT_STAT | 0x0070 | Port A interrupt status |

Ports B through L follow the same pattern with 0x04 offset increments.

#### I2C Controller (0x7000C000)

| Register | Offset | Description |
|----------|--------|-------------|
| I2C_ADDR | 0x0000 | Target address (7-bit) |
| I2C_CTRL | 0x0004 | Control register |
| I2C_DATA0-3 | 0x000C-0x0018 | Data registers |
| I2C_STATUS | 0x001C | Status register |

#### I2S Controller (0x70002800)

| Register | Offset | Description |
|----------|--------|-------------|
| I2S_CLOCK | 0x0000 | Clock divider configuration |
| I2S_CLOCK_DIV | 0x0004 | Clock divisor |
| I2S_CONTROL | 0x0024 | Enable and format control |
| I2S_FIFO_CONTROL | 0x0028 | FIFO configuration |
| I2S_FIFO_STATUS | 0x002C | FIFO fill level |
| I2S_DATA | 0x0040 | Data write register |

#### ATA Controller (0xC3000000)

| Register | Offset | Description |
|----------|--------|-------------|
| ATA_DATA | 0x01E0 | Data register (16-bit) |
| ATA_ERROR | 0x01E4 | Error/features register |
| ATA_NSECTOR | 0x01E8 | Sector count |
| ATA_SECTOR | 0x01EC | Sector number |
| ATA_LCYL | 0x01F0 | Cylinder low |
| ATA_HCYL | 0x01F4 | Cylinder high |
| ATA_SELECT | 0x01F8 | Drive/head select |
| ATA_COMMAND | 0x01FC | Command/status register |
| ATA_CONTROL | 0x0238 | Device control |

---

## Audio Codec: Wolfson WM8758B

### Overview

The WM8758B is a high-quality stereo DAC with integrated headphone amplifier, connected via I2C (control) and I2S (audio data).

### I2C Configuration

| Parameter | Value |
|-----------|-------|
| Address | 0x1A (7-bit) |
| Speed | 400 kHz (Fast mode) |
| Register Width | 9-bit (7-bit address + 9-bit data) |

### Key Registers

| Register | Address | Description |
|----------|---------|-------------|
| R0 | 0x00 | Software reset |
| R1 | 0x01 | Power management 1 |
| R2 | 0x02 | Power management 2 |
| R3 | 0x03 | Power management 3 |
| R4 | 0x04 | Audio interface control |
| R5 | 0x05 | Companding control |
| R6 | 0x06 | Clock gen control |
| R7 | 0x07 | Additional control |
| R10 | 0x0A | Left DAC volume |
| R11 | 0x0B | Right DAC volume |
| R14 | 0x0E | ADC control |
| R18-22 | 0x12-0x16 | EQ1-EQ5 |
| R24 | 0x18 | DAC limiter 1 |
| R25 | 0x19 | DAC limiter 2 |
| R40 | 0x28 | Output control |
| R52 | 0x34 | LOUT1 volume |
| R53 | 0x35 | ROUT1 volume |
| R54 | 0x36 | LOUT2 volume |
| R55 | 0x37 | ROUT2 volume |

### Audio Format Support

| Format | Bit Depth | Sample Rates |
|--------|-----------|--------------|
| I2S | 16/20/24/32-bit | 8-96 kHz |
| Left Justified | 16/20/24/32-bit | 8-96 kHz |
| Right Justified | 16/20/24/32-bit | 8-96 kHz |
| DSP Mode | 16/20/24/32-bit | 8-96 kHz |

### Power Consumption

| State | Current |
|-------|---------|
| Playback (headphones) | ~10 mA |
| Standby | ~1 µA |

---

## Display Controller: Broadcom BCM2722

### Overview

The BCM2722 is a multimedia processor handling video decoding and LCD control. For ZigPod (audio-only), we use only the LCD controller functionality.

### LCD Specifications

| Parameter | Value |
|-----------|-------|
| Resolution | 320 x 240 pixels (QVGA) |
| Color Depth | 16-bit RGB565 |
| Interface | Parallel RGB |
| Backlight | White LED, PWM controlled |

### LCD Registers (via BCM2722)

| Register | Address | Description |
|----------|---------|-------------|
| LCD_BASE | 0x30000000 | Framebuffer base address |
| LCD_CONTROL | 0x30020000 | LCD enable and configuration |
| LCD_STATUS | 0x30020004 | LCD status |

### Backlight Control

The backlight is controlled via GPIO:
- **GPIO Port**: L
- **Pin**: 7
- **Active**: High

---

## Click Wheel: Cypress CY8C21

### Overview

The CY8C21 is a PSoC (Programmable System-on-Chip) that handles capacitive touch sensing for the click wheel.

### Communication Protocol

| Parameter | Value |
|-----------|-------|
| Interface | Serial (proprietary) |
| Data Format | 4-byte packets |
| Update Rate | ~100 Hz |

### Packet Format

```
Byte 0: Status (0x01 = touch active)
Byte 1: Button state
        Bit 0: Select (center)
        Bit 1: Menu
        Bit 2: Play/Pause
        Bit 3: Previous
        Bit 4: Next
        Bit 5: Hold switch
Byte 2: Wheel position (0-95)
Byte 3: Wheel delta (signed)
```

### Button Mapping

| Button | Physical Position | GPIO |
|--------|-------------------|------|
| Menu | Top | Clickwheel Byte 1, Bit 1 |
| Previous | Left | Clickwheel Byte 1, Bit 3 |
| Next | Right | Clickwheel Byte 1, Bit 4 |
| Play/Pause | Bottom | Clickwheel Byte 1, Bit 2 |
| Select | Center | Clickwheel Byte 1, Bit 0 |
| Hold | Left side switch | Clickwheel Byte 1, Bit 5 |

---

## Storage: ATA/IDE Interface

### Original HDD Specifications

| Model | Interface | Capacity | RPM |
|-------|-----------|----------|-----|
| Toshiba MK3008GAL | ZIF ATA-6 | 30 GB | 4200 |
| Toshiba MK6008GAH | ZIF ATA-6 | 60 GB | 4200 |
| Toshiba MK8010GAH | ZIF ATA-6 | 80 GB | 4200 |

### iFlash Adapter Compatibility

ZigPod fully supports flash storage adapters:

| Adapter | Storage Type | Detection |
|---------|--------------|-----------|
| iFlash Solo | SD/SDHC/SDXC | Model string "iFlash" |
| iFlash Quad | 4x SD cards | Model string "iFlash" |
| iFlash CF | CompactFlash | Model string varies |
| Tarkan | SD adapter | Model string "Tarkan" |

### ATA IDENTIFY Detection

| Word | Description | Flash Detection |
|------|-------------|-----------------|
| 217 | Rotation Rate | 0x0001 = Non-rotating (SSD) |
| 169 | TRIM Support | Bit 0 = TRIM supported |

---

## Power Management: PCF50605

### Overview

The PCF50605 is an integrated PMU (Power Management Unit) from NXP, handling battery charging, voltage regulation, and power sequencing.

### I2C Configuration

| Parameter | Value |
|-----------|-------|
| Address | 0x08 (7-bit) |
| Speed | 400 kHz |

### Key Registers

| Register | Address | Description |
|----------|---------|-------------|
| OOCS | 0x01 | On/off control status |
| INT1-INT3 | 0x02-0x04 | Interrupt registers |
| OOCC1 | 0x05 | On/off control config 1 |
| OOCC2 | 0x06 | On/off control config 2 |
| DCDC1-4 | 0x20-0x23 | DC-DC converter control |
| DCDEC1-2 | 0x24-0x25 | DC-DC error control |
| LDO1-3 | 0x26-0x28 | LDO regulator control |
| ADCC1-2 | 0x30-0x31 | ADC control |
| ADCS1-3 | 0x32-0x34 | ADC status |
| BVMC | 0x38 | Battery voltage monitor |
| CHGC1 | 0x40 | Charger control 1 |
| CHGC2 | 0x41 | Charger control 2 |

### Battery Specifications

| Parameter | Value |
|-----------|-------|
| Type | Li-Ion |
| Voltage | 3.7V nominal |
| Capacity | 400-850 mAh (model dependent) |
| Charge Voltage | 4.2V |
| Cutoff Voltage | 3.0V |

### Voltage Curve (Li-Ion)

| Voltage (mV) | Capacity (%) |
|--------------|--------------|
| 4200 | 100 |
| 3900 | 80 |
| 3700 | 50 |
| 3400 | 10 |
| 3000 | 0 |

---

## USB Interface

### USB Device Controller

| Parameter | Value |
|-----------|-------|
| Type | USB 2.0 High-Speed Device |
| Max Speed | 480 Mbps |
| Endpoints | EP0 (Control) + 2 bulk/interrupt |

### Apple USB IDs

| Mode | VID | PID |
|------|-----|-----|
| Disk Mode | 0x05AC | 0x1209 |
| iPod Video 5G | 0x05AC | 0x1261 |
| iPod Classic | 0x05AC | 0x1262 |

### DFU Mode

The device supports USB DFU (Device Firmware Upgrade) for firmware updates:
- DFU class: 0xFE
- DFU subclass: 0x01
- Transfer size: 4096 bytes

---

## Memory: Samsung K4M56163PG

### Specifications

| Parameter | Value |
|-----------|-------|
| Type | Mobile SDRAM |
| Density | 256 Mbit (32 MB) |
| Configuration | 4M x 16 x 4 banks |
| Speed | 166 MHz (CL3) |
| Voltage | 1.8V |

### Timing Parameters

| Parameter | Value |
|-----------|-------|
| tRCD | 18 ns |
| tRP | 18 ns |
| tRC | 60 ns |
| tRAS | 42 ns |
| CAS Latency | 3 cycles |

---

## Interrupt System

### Interrupt Sources

| IRQ | Source | Priority |
|-----|--------|----------|
| 0 | Timer 0 | High |
| 1 | Timer 1 | High |
| 4 | I2S | High |
| 5 | DMA | High |
| 6 | USB | Medium |
| 10 | GPIO | Medium |
| 12 | I2C | Low |
| 30 | ATA | Medium |

### Interrupt Controller Registers

| Register | Address | Description |
|----------|---------|-------------|
| CPU_INT_STAT | 0x60004000 | Interrupt status |
| CPU_INT_EN | 0x60004004 | Interrupt enable |
| CPU_INT_CLR | 0x60004008 | Interrupt clear |
| CPU_INT_PRIORITY | 0x6000401C | Priority configuration |
| CPU_FIQ_EN | 0x6000400C | FIQ enable |

---

## References

1. [Rockbox Source Code](https://github.com/Rockbox/rockbox) - Reference implementation
2. [iPodLoader2](https://github.com/crozone/ipodloader2) - Multi-boot loader
3. [iPod Reverse Engineering](https://github.com/Xlinka/iPodReverseEngineering) - Datasheets
4. [Rockbox Wiki - IpodHardwareInfo](https://www.rockbox.org/wiki/IpodHardwareInfo)
5. [The Apple Wiki - PP5021C](https://theapplewiki.com/wiki/PP5021C)
