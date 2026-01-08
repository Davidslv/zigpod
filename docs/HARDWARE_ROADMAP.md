# ZigPod Hardware Roadmap

This document outlines what's needed to run ZigPod on real iPod Classic (6th/7th gen) hardware.

## Target Hardware: iPod Classic

- **SoC**: PortalPlayer PP5021C (ARM7TDMI @ 80MHz)
- **RAM**: 32MB SDRAM (64MB on 160GB models)
- **Storage**: 80GB/120GB/160GB 1.8" PATA hard drive
- **Display**: 320x240 LCD via BCM2722 controller
- **Audio**: Wolfson WM8758 codec via I2S
- **Input**: Click wheel (capacitive) + 5 buttons
- **Power**: PCF50605 PMU, Li-ion battery
- **USB**: Integrated controller for sync/charge

---

## Current Implementation Status

### Complete (Ready for Hardware)

| Component | Location | Notes |
|-----------|----------|-------|
| Boot code | `src/kernel/boot.zig` | ARM vectors, stack init, BSS clear |
| Bootloader | `src/kernel/bootloader.zig` | Dual-boot, recovery mode |
| Interrupt framework | `src/kernel/interrupts.zig` | Registration, enable/disable |
| Memory allocator | `src/kernel/memory.zig` | Fixed-block allocator |
| GPIO driver | `src/hal/pp5021c/` | Read, write, direction, interrupts |
| I2C driver | `src/hal/pp5021c/` | Init, read, write transactions |
| Timer driver | `src/hal/pp5021c/` | Basic timer operations |
| Linker script | `linker/pp5021c.ld` | Memory regions, sections |
| Audio decoders | `src/audio/decoders/` | WAV, MP3, FLAC, AIFF |
| UI framework | `src/ui/` | Screens, menus, file browser |

### Partially Complete (Need Hardware Implementation)

| Component | Location | What's Done | What's Missing |
|-----------|----------|-------------|----------------|
| ATA storage | `src/hal/pp5021c/` | Structure | PIO read/write |
| LCD display | `src/drivers/display/` | Framebuffer ops | BCM2722 init |
| Audio output | `src/drivers/audio/` | Codec registers | I2S DMA streaming |
| Click wheel | `src/hal/pp5021c/` | Constants | Position/button read |
| Power mgmt | `src/drivers/power.zig` | Framework | Battery monitoring |

### Not Started

| Component | Priority | Complexity |
|-----------|----------|------------|
| USB device mode | High | High |
| DMA controller | Medium | Medium |
| Watchdog timer | Low | Low |
| RTC | Low | Low |

---

## Implementation Phases

### Phase 1: Minimal Boot
**Goal**: Boot to main(), display something on screen

1. **ATA Driver** - Read sectors from hard drive
   - PIO mode read (simpler, slower)
   - IDENTIFY DEVICE command
   - Error handling and timeouts

2. **LCD Initialization** - Display boot screen
   - BCM2722 firmware loading
   - Display enable sequence
   - Framebuffer transfer

3. **Click Wheel** - Basic input
   - Button state reading
   - Wheel position tracking

### Phase 2: Music Playback
**Goal**: Browse files and play audio

4. **FAT32 File Access** - Read music files
   - Directory traversal
   - File reading
   - Long filename support

5. **Audio Pipeline** - Sound output
   - I2S configuration
   - WM8758 codec setup
   - DMA streaming
   - Buffer management

6. **DMA Controller** - Efficient transfers
   - ATA DMA for disk reads
   - I2S DMA for audio output

### Phase 3: Full Functionality
**Goal**: Complete iPod replacement

7. **USB Mass Storage** - File transfer
   - Device enumeration
   - SCSI commands
   - Bulk transfers

8. **Power Management** - Battery life
   - PCF50605 PMU driver
   - Battery level monitoring
   - Sleep modes

9. **Settings Persistence** - User preferences
   - Configuration storage
   - Volume, EQ, preferences

---

## Hardware Register Map

### PP5021C Base Addresses

```
0x60000000  GPIO ports
0x6000C000  I2C controller
0x60005000  Timer registers
0x70000000  CPU control
0x70008000  Cache control
0xC0000000  ATA controller
0xC8000000  LCD controller
```

### ATA Controller Registers (0xC0000000)

```
Offset  Name            Description
0x00    ATA_CONTROL     Control register
0x04    ATA_STATUS      Status register
0x08    ATA_COMMAND     Command register
0x0C    ATA_ERROR       Error register
0x10    ATA_NSECTOR     Sector count
0x14    ATA_SECTOR      Sector number (LBA 0-7)
0x18    ATA_LCYL        Cylinder low (LBA 8-15)
0x1C    ATA_HCYL        Cylinder high (LBA 16-23)
0x20    ATA_SELECT      Drive/head select (LBA 24-27)
0x24    ATA_DATA        Data register (16-bit)
0x40    ATA_CFG         Configuration register
```

### ATA Commands

```
0x20    READ SECTORS (PIO)
0x24    READ SECTORS EXT (48-bit LBA)
0x30    WRITE SECTORS (PIO)
0x34    WRITE SECTORS EXT (48-bit LBA)
0xC8    READ DMA
0xCA    WRITE DMA
0xE0    STANDBY IMMEDIATE
0xE7    FLUSH CACHE
0xEC    IDENTIFY DEVICE
```

### ATA Status Bits

```
Bit 7   BSY     Busy
Bit 6   DRDY    Drive ready
Bit 5   DF      Drive fault
Bit 4   DSC     Seek complete
Bit 3   DRQ     Data request
Bit 2   CORR    Corrected data
Bit 1   IDX     Index
Bit 0   ERR     Error
```

---

## Testing Strategy

### 1. Simulator Testing
- Test drivers against simulator before hardware
- Verify register access patterns
- Check timing assumptions

### 2. JTAG Debugging
- Use FT2232H adapter with custom dock cable
- Read/write memory directly
- Step through boot code
- Verify register values

### 3. RAM-Only Testing
- Load code to RAM via JTAG
- Test without touching flash
- Safe iteration cycle

### 4. Flash Testing (Sacrificial Device)
- Full firmware flash
- Test on dedicated test device
- Always backup first

---

## References

- [Rockbox iPod Port](https://www.rockbox.org/wiki/IpodPort)
- [iPod Linux Project](http://ipodlinux.org/)
- [FreePod Documentation](https://freemyipod.org/)
- [PP5021C Datasheet](Various reverse-engineered docs)
- [ATA/ATAPI-6 Specification](T13 standards)

---

## File Structure

```
src/
├── kernel/
│   ├── boot.zig          # ARM startup code
│   ├── bootloader.zig    # Dual-boot support
│   ├── interrupts.zig    # IRQ management
│   └── memory.zig        # Memory allocator
├── hal/
│   └── pp5021c/
│       ├── pp5021c.zig   # HAL implementation
│       └── registers.zig # Hardware registers
├── drivers/
│   ├── storage/
│   │   ├── ata.zig       # ATA disk driver
│   │   └── fat32.zig     # Filesystem
│   ├── display/
│   │   └── lcd.zig       # BCM2722 LCD
│   ├── audio/
│   │   ├── codec.zig     # WM8758 driver
│   │   └── i2s.zig       # I2S interface
│   └── input/
│       └── clickwheel.zig
├── audio/
│   ├── audio.zig         # Audio engine
│   └── decoders/         # Format decoders
└── ui/
    ├── ui.zig            # UI manager
    └── now_playing.zig   # Screens
```
