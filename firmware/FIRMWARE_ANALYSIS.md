# iPod Firmware Analysis Report

## Executive Summary

This document provides a comprehensive technical analysis of the iPod firmware extracted from a connected device. The firmware is **unencrypted** and contains readable ARM32 code, making it suitable for reverse engineering and emulation purposes.

| Property | Value |
|----------|-------|
| **Total Size** | 160 MB (167,772,160 bytes) |
| **Encryption** | None (firmware is unencrypted) |
| **Architecture** | ARM32 (ARMv5TE) |
| **SoC** | PortalPlayer PP5020/PP5022 |
| **GPU** | Broadcom VideoCore 02 |
| **Build System** | M25Firmware-153 |
| **Bootloader Date** | 2003.10.30 (Build 04) |
| **Copyright** | 2001-2008 Apple Inc. |

---

## 1. Extraction Methodology

### 1.1 Tools Used

| Tool | Purpose |
|------|---------|
| `diskutil list` | Identify connected iPod and partition layout |
| `dd` | Extract raw firmware partition |
| `xxd` | Hex dump analysis |
| `strings` | Extract readable text strings |
| `binwalk` | Identify embedded files and signatures |
| `python3` | Custom parsing scripts for header analysis |

### 1.2 Extraction Process

The iPod appears as an external disk with Apple partition scheme:

```
/dev/disk10 (external, physical):
   #:  TYPE               NAME      SIZE       IDENTIFIER
   0:  Apple_partition_scheme       *255.9 GB  disk10
   1:  Apple_partition_map          127.0 KB   disk10s1
   2:  Apple_MDFW                   167.8 MB   disk10s2  <-- Firmware
   3:  Apple_HFS          iPod      255.7 GB   disk10s3  <-- User Data
```

**Extraction command:**
```bash
sudo dd if=/dev/disk10s2 of=firmware/ipod_firmware.bin bs=1m status=progress
```

The `Apple_MDFW` (Media Device Firmware) partition contains the complete firmware image. This is a **read-only operation** that does not modify the iPod.

---

## 2. Firmware Structure

### 2.1 High-Level Layout

```
Offset        Size      Section
──────────────────────────────────────────────────────────
0x00000000    256 B     Apple Warning Header ("STOP" sign)
0x00000100    256 B     Master Header ([hi] signature)
0x00000200    16 KB     Padding (zeros)
0x00004200    1.5 KB    Image Directory Table
0x00004800    7.21 MB   osos - Main Operating System
0x00743000    5.00 MB   rsrc - Resources (graphics, strings)
0x00C44000    1.03 MB   aupd - Firmware Updater
0x00D4B800    32.00 MB  hibe - Hibernate Image
0x02D4C000    114.7 MB  Unused (zeros)
```

### 2.2 Apple Warning Header (0x00 - 0xFF)

The firmware begins with an ASCII art "STOP" sign warning:

```
{{~~  /-----\
{{~~ /       \
{{~~|         |
{{~~| S T O P |
{{~~|         |
{{~~ \       /
{{~~  \-----/
Copyright(C) 2001 Apple Computer, Inc.
```

This is a visual deterrent for users who might accidentally view the raw firmware.

### 2.3 Master Header (0x100)

```c
struct MasterHeader {
    char     magic[4];      // "]ih[" (reversed "[hi]")
    uint32_t header_size;   // 0x00004000 (16KB total header area)
    uint32_t version;       // 0x0003010C
    uint8_t  padding[244];  // zeros
};
```

The `]ih[` signature indicates a valid iPod firmware image. The bytes are stored in reverse order.

### 2.4 Image Directory Table (0x4200)

The image table contains entries describing each firmware component:

```c
struct ImageEntry {
    char     magic[4];      // "!ATA" signature
    char     type[4];       // Image type (reversed)
    uint32_t version;       // Version/flags
    uint32_t offset;        // Offset in file
    uint32_t size;          // Size in bytes
    uint32_t load_addr;     // RAM load address
    uint32_t entry_point;   // Execution entry point
    uint32_t checksum;      // CRC32 checksum
    uint32_t dev_id;        // Device ID (0xB012)
    uint32_t padding;       // 0xFFFFFFFF
};
```

#### Parsed Image Entries:

| Type | Reversed | Offset | Size | Load Address | Description |
|------|----------|--------|------|--------------|-------------|
| `soso` | osos | 0x4800 | 7.21 MB | 0x10000000 | Main Operating System |
| `crsr` | rsrc | 0x743000 | 5.00 MB | 0x00000000 | Resources |
| `dpua` | aupd | 0xC44000 | 1.03 MB | 0x10000000 | Firmware Updater |
| `ebih` | hibe | 0xD4B800 | 32.00 MB | 0x10000000 | Hibernate Image |

---

## 3. Bootloader Analysis

### 3.1 PortalPlayer Bootloader

Located at offset 0x5000, the bootloader contains PortalPlayer initialization code:

```
portalplayer
PP5020AF-05.00-PP07-05.00-PP07-05.00-DT
2003.10.30
(Build 04)
Digital Media Platform
Copyright(c) 1999 - 2003 PortalPlayer, Inc.  All rights reserved.
```

**Key Information:**
- **Chip**: PP5020AF (PortalPlayer 5020, variant AF)
- **Version**: 05.00
- **Build Date**: October 30, 2003
- **Build Number**: 04

### 3.2 ARM Exception Vectors

The bootloader starts with ARM exception vector branches at 0x5000:

```
00005000: 7a00 00ea  b   reset_handler      ; Reset
00005004: 6700 00ea  b   undefined_handler  ; Undefined instruction
00005008: dcf0 9fe5  ldr pc, =swi_handler  ; Software interrupt
0000500c: 6b00 00ea  b   prefetch_handler   ; Prefetch abort
00005010: 7000 00ea  b   data_handler       ; Data abort
00005014: feff ffea  b   .                  ; Reserved (infinite loop)
00005018: 5800 00ea  b   irq_handler        ; IRQ
0000501c: 4e00 00ea  b   fiq_handler        ; FIQ
```

---

## 4. Operating System Analysis

### 4.1 OS Image (osos)

- **Offset**: 0x4800
- **Size**: 7,561,216 bytes (7.21 MB)
- **Load Address**: 0x10000000 (SDRAM)
- **Checksum**: 0x2C7C48F3

### 4.2 Entropy Analysis

| Region | Entropy | Interpretation |
|--------|---------|----------------|
| Bootloader (0x5000) | 6.00 | Executable ARM code |
| OS Start (0x4800) | 7.39 | Compressed/obfuscated header |
| OS +64KB | 5.91 | Executable ARM code |
| OS +256KB | 6.17 | Executable ARM code |
| OS +1MB | 5.97 | Executable ARM code |

The OS image has a compressed header but the main code sections are uncompressed ARM32 instructions.

### 4.3 Compression

The firmware references zlib compression:
```
ZLIB
zlib compression
```

Some data sections are zlib-compressed but can be decompressed for analysis.

### 4.4 Build Information

From embedded debug paths:
```
c:\bwa\M25Firmware-153\srcroot\Firmware\BootLoader\btMm.c
```

- **Build Environment**: Windows (c:\bwa\)
- **Codename**: M25 (iPod Classic internal name)
- **Build Number**: 153

---

## 5. Resources Analysis

### 5.1 Resource Image (rsrc/crsr)

- **Offset**: 0x743000
- **Size**: 5,244,928 bytes (5.00 MB)
- **Entry Point**: 0x600 (resource table offset)

### 5.2 Embedded Assets

| Type | Count | First Occurrence |
|------|-------|------------------|
| BMP Images | 92 | 0xBAB6D |
| JPEG Images | 65 | 0x4B9573 |
| RIFF/WAV Audio | 6 | 0xDA7E0 |

### 5.3 Localization

The firmware contains localized strings for 15+ languages:
- English, German, French, Spanish, Italian
- Dutch, Swedish, Norwegian, Danish, Finnish
- Czech, Hungarian, Turkish, Polish
- Japanese, Korean, Chinese (Simplified & Traditional)
- Russian, Portuguese

---

## 6. Hardware Support

### 6.1 Identified Hardware

| Component | Details |
|-----------|---------|
| **SoC** | PortalPlayer PP5020A / PP5022A |
| **CPU** | Dual ARM7TDMI cores |
| **GPU** | Broadcom VideoCore 02 |
| **Display Driver** | LcdDriverVC02, DisplayDriverVC02 |
| **Audio** | ACELP.net codec (VoiceAge) |
| **Storage** | ATA interface, iFlash compatible |

### 6.2 Driver References

```
SDRAM Driver
iPodApp SDRAM Code
!ATAcrsr
!ATAsoso
Hub Driver trace
Audio engine
FireWire
```

### 6.3 Display

The firmware includes VideoCore GPU drivers:
```
Apple VCO2 OpenGL Engine
LcdDriverSpHw
LcdDriverVC02
DisplayDriverVC02
```

---

## 7. Security Analysis

### 7.1 Encryption Status

**The firmware is NOT encrypted.** Evidence:

1. Readable ASCII strings throughout
2. Identifiable ARM instruction patterns
3. Clear header structures
4. Embedded graphics in standard formats

### 7.2 DRM Components

The firmware contains FairPlay DRM for protected content:

```
AES S-Box (multiple instances)
HeaderKey
EncryptedBlocks
AppleDRM
AppleDRMVersion
AppleVideoDRM
```

These are for decrypting purchased music/video, not firmware protection.

### 7.3 Checksums

Each image entry includes a CRC32 checksum for integrity verification:

| Image | Checksum |
|-------|----------|
| osos | 0x2C7C48F3 |
| rsrc | 0x18319BAB |
| aupd | 0x0B19DB1C |
| hibe | 0x00000000 |

---

## 8. Memory Map

Based on load addresses and string references:

| Address Range | Size | Description |
|---------------|------|-------------|
| 0x00000000 | 96 KB | Internal SRAM (fast memory) |
| 0x10000000 | 32+ MB | SDRAM (main memory) |
| 0x40000000 | - | Peripheral registers |
| 0xC0000000 | - | Cache control |

---

## 9. Version Information

### 9.1 Firmware Version

| Field | Value |
|-------|-------|
| Copyright | 2001-2008 Apple Inc. |
| Bootloader | PP5020AF-05.00 Build 04 |
| Build Date | 2003.10.30 (bootloader) |
| Internal Build | M25Firmware-153 |

### 9.2 Component Versions

From embedded strings:
```
BuildID
VisibleBuildID
FireWireVersion
MinITunesVersion
GamesPlatformVersion
```

---

## 10. Emulation Considerations

### 10.1 Key Components to Emulate

1. **Dual ARM7TDMI cores** - Main and COP processors
2. **Memory subsystem** - SRAM, SDRAM, memory-mapped I/O
3. **PortalPlayer peripherals** - Timers, DMA, interrupt controller
4. **Broadcom VideoCore** - Display output, hardware acceleration
5. **ATA/Storage interface** - Hard drive / flash storage
6. **Audio subsystem** - DAC, I2S, audio DMA

### 10.2 Boot Sequence

1. ROM bootloader loads from 0x0
2. Reads firmware partition header
3. Validates checksums
4. Copies osos to 0x10000000
5. Jumps to entry point
6. Main OS initializes hardware
7. Loads resources
8. Displays UI

### 10.3 Useful Offsets

| Purpose | Offset |
|---------|--------|
| ARM vectors | 0x5000 |
| OS entry | 0x4800 + header |
| String tables | 0x2B0000+ |
| Graphics | 0xBAB6D+ |
| Audio samples | 0xDA7E0+ |

---

## 11. Tools and Commands Reference

### 11.1 Extraction

```bash
# List connected devices
diskutil list

# Extract firmware (requires sudo)
sudo dd if=/dev/disk10s2 of=ipod_firmware.bin bs=1m status=progress
```

### 11.2 Analysis

```bash
# View hex dump
xxd -s 0x4200 -l 512 ipod_firmware.bin

# Extract strings
strings -n 10 ipod_firmware.bin | grep -i "keyword"

# Find file signatures
binwalk ipod_firmware.bin

# Calculate entropy
python3 -c "
import math
from collections import Counter
with open('ipod_firmware.bin', 'rb') as f:
    f.seek(0x4800)
    data = f.read(4096)
    entropy = -sum(p * math.log2(p) for p in
        [c/len(data) for c in Counter(data).values()])
    print(f'Entropy: {entropy:.2f}')
"
```

### 11.3 Parsing Image Table

```python
import struct

with open('ipod_firmware.bin', 'rb') as f:
    f.seek(0x4200)
    for i in range(4):
        entry = f.read(40)
        magic = entry[0:4]
        if magic != b'!ATA':
            break
        img_type = entry[4:8].decode('ascii')[::-1]  # Reverse
        offset = struct.unpack('<I', entry[12:16])[0]
        size = struct.unpack('<I', entry[16:20])[0]
        print(f"{img_type}: offset=0x{offset:X}, size={size:,}")
```

---

## 12. References

- [Rockbox iPod Documentation](https://www.rockbox.org/wiki/IpodPort)
- [iPod Linux Project](http://www.ipodlinux.org/)
- [FreePod Project](http://www.freemyipod.org/)
- PortalPlayer PP5020/PP5022 datasheets (if available)

---

## Appendix A: File Signatures

| Offset | Signature | Description |
|--------|-----------|-------------|
| 0x0000 | `{{~~` | Apple warning header |
| 0x0100 | `]ih[` | Master header (reversed [hi]) |
| 0x4200 | `!ATA` | Image table entry |
| 0x5020 | `portalplayer` | Bootloader identification |

---

## Appendix B: Known Image Types

| Raw | Reversed | Full Name |
|-----|----------|-----------|
| soso | osos | Operating System |
| crsr | rsrc | Resources |
| dpua | aupd | Apple Update |
| ebih | hibe | Hibernate Image |
| toor | root | Root filesystem (some models) |
| lenk | knle | Kernel (some models) |

---

*Report generated: January 2026*
*Firmware source: iPod Classic (extracted from connected device)*
