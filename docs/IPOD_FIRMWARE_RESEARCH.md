# iPod Firmware Structure and Boot Process Research

This document compiles comprehensive research on iPod firmware formats, partition requirements, and boot processes for the ZigPod emulator project.

## Table of Contents
1. [Firmware Image Formats (IMG1, IMG2, IMG3)](#firmware-image-formats)
2. [Partition Requirements](#partition-requirements)
3. [Boot Process](#boot-process)
4. [Firmware Partition Structure](#firmware-partition-structure)
5. [FAT32 Filesystem Requirements](#fat32-filesystem-requirements)
6. [Rockbox Integration](#rockbox-integration)
7. [Existing Emulation Projects](#existing-emulation-projects)
8. [Sources](#sources)

---

## Firmware Image Formats

### IMG1 Format (Non-iOS iPods)

IMG1 is the primary firmware format for non-iOS iPods (Classic, Nano, Shuffle). It has two versions:
- **Version 1.0**: Used by early iOS devices and most clickwheel iPods
- **Version 2.0**: Used by Nano 4G and later

#### IMG1 Header Structure (0x54 bytes)

| Offset | Size | Field | Description |
|--------|------|-------|-------------|
| 0x00 | 4 | magic | SoC identifier (e.g., "8720" for S5L8720) |
| 0x04 | 3 | version | "1.0" or "2.0" |
| 0x07 | 1 | format | Encryption/signature format (1-4) |
| 0x08 | 4 | entrypoint | Offset to jump to within body |
| 0x0C | 4 | bodyLen | Size of image body before signature |
| 0x10 | 4 | dataLen | Size of everything except header |
| 0x14 | 4 | footerCertOffset | Offset of certificate start |
| 0x18 | 4 | footerCertLen | Certificate bundle size |
| 0x1C | 32 | salt | Random initialization data |
| 0x3C | 2 | unk1 | Unknown |
| 0x3E | 2 | unk2 | Possibly security epoch |
| 0x40 | 16 | headerSign | AES-encrypted SHA1 signature |
| 0x50 | 4 | headerLeftover | Unencrypted SHA1 remnant |

#### Encryption/Signature Formats

1. **SIGNED_ENCRYPTED (1)**: Header signed, body encrypted, no X509 signature
2. **SIGNED (2)**: Header signed, no body encryption, no X509 signature
3. **X509_SIGNED_ENCRYPTED (3)**: Header signed, body encrypted, X509 body signature (most common)
4. **X509_SIGNED (4)**: Header signed, no body encryption, X509 body signature

#### Body Padding by SoC

- S5L8900: 0x800 bytes
- S5L8720/8930: 0x600 bytes
- S5L8723/8740: 0x400 bytes

### IMG3 Format (32-bit iOS Devices)

Used on iPod Touch and other 32-bit iOS devices. Key differences from IMG1:
- Magic: ASCII_LE("Img3")
- Uses device-unique encryption keys (not global key)
- Tag-based structure for flexibility

### IMG4 Format (64-bit iOS Devices)

DER-encoded ASN.1 format used on modern 64-bit devices. Not applicable to clickwheel iPods.

---

## Partition Requirements

### Standard iPod Partition Layout

#### FAT32 (Windows) iPods - MBR Layout
```
Partition 1: Firmware partition (Type 0x00 - unusual!)
  - Starts at sector 63 (or 252 for 5.5G with 2048-byte sectors)
  - Size: ~32MB (65536 sectors)
  - Contains Apple firmware filesystem

Partition 2: Data partition (Type 0x0B or 0x0C - FAT32)
  - Contains music, photos, and user data
  - Must be FAT32 for Rockbox compatibility
```

#### HFS+ (Mac) iPods - Apple Partition Map
```
Partition 1: Apple_partition_map (63 blocks)
Partition 2: Apple_MDFW "firmware" (65536 blocks / ~32MB)
Partition 3: Apple_HFS disk (main storage)
```

### Critical MBR Requirements

The iPod MBR has peculiarities that must be respected:
- **Partition 1 Type**: Set to 0x00 (appears empty but isn't!)
- **Partition 2 Type**: 0x0B (FAT32) or 0x0C (FAT32 LBA)
- **Boot signature**: 0x55AA at offset 0x1FE

**WARNING**: The iPod MBR is described as "a horrible mix of a faulty MBR (system partition 1 has ID 0) and a faulty DBR." Using 0 as partition ID is problematic because it typically means "empty partition."

### Sector Size Variations

| iPod Model | Sector Size | Firmware Starts At |
|------------|-------------|-------------------|
| 1G-5G | 512 bytes | Block 63 |
| 5.5G (2048-byte sectors) | 2048 bytes | Block 63 (= block 252 in 512-byte terms) |
| 6G+ | Varies | Model-specific |

---

## Boot Process

### PortalPlayer-Based iPods (1G-5.5G)

1. **ROM Stage**:
   - CPU executes code from address 0x0 (flash memory)
   - Reset vector points to bootloader location
   - Performs basic hardware initialization

2. **Bootloader Stage**:
   - Loads firmware from firmware partition
   - Validates firmware header (checks "STOP" signature)
   - Loads operating system into RAM
   - Transfers control to OS

3. **Operating System**:
   - Apple's Pixo-based OS runs
   - Or alternative firmware if modified

### S5L87xx-Based iPods (Nano 3G+, Classic 6G+)

1. **BootROM Stage**:
   - Initializes from 0x20000000 (also mapped to 0x00000000)
   - Sets up stacks, PLLs, clock gates for AES/NAND/NOR/USB
   - Evaluates GPIO for boot path:
     - Load from NOR flash
     - Load from NAND flash
     - Enter DFU mode (fail-safe)

2. **Second-Stage Bootloader**:
   - Loaded as IMG1 file, signature checked and decrypted
   - EFI-based modular implementation
   - Initializes DRAM, LCD, UART, interrupts, FTL
   - Decides to boot retailOS, diagnostics, disk mode, or AUPD

3. **Operating System**:
   - retailOS (single-binary RTOS)
   - Or alternative firmware

---

## Firmware Partition Structure

### Volume Header (Block 0 of Firmware Partition)

The first 256 bytes contain the "STOP" sign text (Apple copyright notice).

At offset 0x100:
```c
struct FirmwareHeader {
    uint8_t  unknown1[4];      // 0x100
    uint32_t directoryOffset;  // 0x104 - Usually block 33
    uint8_t  unknown2[2];      // 0x108
    uint8_t  version;          // 0x10A - '2' for 1G-3G, '3' for 4G-5G
    // ... more fields
};
```

**Validation Check**: At offset 0x100, the code validates presence of `]ih[` (reverse of `[hi]`) as directory marker.

### Directory Structure (Block 33)

Directory starts at block 33 (offset 0x4200 in firmware partition).

Each directory entry is **40 bytes**:

```c
struct DirectoryEntry {
    char     type[4];      // 0x00 - Image type ("soso"=OSOS, "kbso"=OSBK, etc.)
    uint32_t id;           // 0x04 - Image identifier
    uint32_t devOffset;    // 0x08 - Starting position (little-endian)
    uint32_t length;       // 0x0C - Image size (little-endian)
    uint32_t addr;         // 0x10 - Load address
    uint32_t entryOffset;  // 0x14 - Bootloader entry point offset
    uint32_t checksum;     // 0x18 - 32-bit image checksum
    uint32_t version;      // 0x1C - Firmware version
    uint32_t loadAddr;     // 0x20 - Execution load address
};
```

### Standard Firmware Images

| Type | Name | Description |
|------|------|-------------|
| osos | OSOS | Main operating system |
| aupd | AUPD | Firmware update image |
| rsrc | RSRC | Resource filesystem |
| hibe | HIBE | Hibernate image |
| osbk | OSBK | OS backup (used for dual-boot) |
| diag | DIAG | Diagnostics mode |
| disk | DISK | Disk mode |

### File Location Addressing

- **Version 1**: Disk-relative offsets (block 0 = start of disk)
- **Version 2+**: Partition-relative offsets (block 0 = start of partition)

Example: "osos" at offset 0x4400 means block 34 from partition start.

---

## FAT32 Filesystem Requirements

### iPod-Specific Requirements

1. **Format**: Must be FAT32 (not exFAT, not NTFS)
2. **Rockbox Requirement**: Only FAT32 supported (not HFS+)
3. **Large Capacity**: GPT partitioning supported for >2TB, but individual partitions limited to 2TB due to FAT32 limits

### BPB (BIOS Parameter Block) Requirements

Standard FAT32 BPB applies with these notes:
- **Bytes Per Sector**: 512, 1024, 2048, or 4096
- **Sectors Per Cluster**: Varies with volume size
- **Number of FATs**: Typically 2
- **Root Entries**: Must be 0 for FAT32
- **Backup Boot Sector**: At sector 6 (recommended)
- **Boot Signature**: 0xAA55 at offset 510

### Volume Boot Record Validation

```
Offset 0x1FE: 0x55
Offset 0x1FF: 0xAA
```

---

## Rockbox Integration

### Installation Requirements

1. **FAT32 Required**: Rockbox does not support HFS+ formatted iPods
2. **Administrative Rights**: Needed for bootloader installation
3. **Directory Location**: `.rockbox` folder at root of data partition

### Dual-Boot Configuration

#### Standard Rockbox Bootloader
- OSOS renamed to OSBK (backup)
- Rockbox bootloader becomes new OSOS
- Hold HOLD switch at boot for Apple OS
- Hold MENU at boot for Rockbox (configurable)

#### iPodLoader2 (Alternative)
Configuration file `loader.cfg`:
```
Apple OS @ ramimg
iPodLinux @ (hd0,1)/linux.bin
Rockbox @ (hd0,1)/.rockbox/rockbox.ipod
```

### Firmware File Formats

- **.ipod**: Unencrypted firmware (8-byte header with checksum and model string)
- **.ipodx**: Encrypted firmware (model string "nn2x", 2KB hash block, encrypted data)

---

## Existing Emulation Projects

### Clicky (iPod 4G Emulator)

[GitHub: daniel5151/clicky](https://github.com/daniel5151/clicky)

- **Target**: iPod 4G (Grayscale) with PP5020 SoC
- **Language**: Rust
- **Status**: Work in progress, can boot Rockbox
- **Approach**:
  - LLE (Low Level Emulation) for complete hardware accuracy
  - HLE (High Level Emulation) bootloader option to bypass Flash ROM

Key features:
- Dual ARM7TDMI core emulation
- Custom memory interconnect
- ipodloader2 and Rockbox support
- RetailOS boot capability (incomplete)

### QEMU-iOS (iPod Touch Emulator)

[GitHub: devos50/qemu-ios](https://github.com/devos50/qemu-ios)

- **Target**: iPod Touch 1G/2G (S5L8900/S5L8720)
- **Language**: C (QEMU fork)
- **Status**: Can boot to home screen on iPhone OS 1.1

Not directly applicable to clickwheel iPods but provides valuable reference for S5L SoC emulation.

---

## Key Findings for ZigPod

### Partition/Filesystem Considerations

1. The current FAT32 implementation appears correct based on debug findings
2. The issue is likely in ARM instruction emulation, not filesystem structure
3. iPod expects partition 1 at sector 63 with type 0x00 (unusual)

### Areas Requiring Attention

1. **ARM Loop Execution**: LFN matching works for 8-char names but fails for 12-char names - suggests loop iteration bug
2. **String Comparison**: strcasecmp behavior with longer strings needs investigation
3. **Memory Bus**: Verified correct, but watch for edge cases

### Boot Process Requirements

For accurate emulation, the bootloader must:
1. Read sector 0 (MBR) to find firmware partition
2. Validate firmware header at firmware partition start
3. Check for "STOP" signature and `]ih[` directory marker
4. Parse 40-byte directory entries
5. Load and execute firmware images

---

## Sources

### Primary Documentation
- [freemyipod.org Wiki](https://freemyipod.org/wiki/Main_Page) - IMG1 format, boot process, firmware structure
- [iPodLinux Firmware Documentation](http://www.ipodlinux.org/Firmware.html) - Partition layout, directory structure
- [The Apple Wiki](https://theapplewiki.com/wiki/IPod_classic) - Device specifications

### Rockbox Resources
- [Rockbox iPod FAT32 Conversion](https://www.rockbox.org/wiki/IpodConversionToFAT32)
- [Rockbox Installation Manual](https://download.rockbox.org/daily/manual/rockbox-ipod6g/rockbox-buildch2.html)
- [ipodpatcher Source Code](https://github.com/mguentner/rockbox/blob/master/rbutil/ipodpatcher/ipodpatcher.c)

### Emulation Projects
- [Clicky iPod Emulator](https://github.com/daniel5151/clicky) - PortalPlayer emulation
- [QEMU-iOS](https://github.com/devos50/qemu-ios) - S5L SoC emulation
- [iPodLoader2](https://github.com/crozone/ipodloader2) - Multi-boot bootloader

### Hardware Research
- [wInd3x Bootrom Exploit](https://github.com/freemyipod/wInd3x) - iPod Classic/Nano exploitation
- [The Apple Wiki - PP5020](https://theapplewiki.com/wiki/PP5020) - PortalPlayer chip details
- [iFlash.xyz](https://www.iflash.xyz/) - SD card adapter compatibility

### Boot Process Details
- [freemyipod Boot Process](https://freemyipod.org/wiki/Boot_Process) - S5L87xx boot sequence
- [iPodLinux Installation](http://www.ipodlinux.org/Installation/) - Bootloader mechanics

---

*Document generated: 2026-01-12*
*Research conducted for ZigPod emulator project*
