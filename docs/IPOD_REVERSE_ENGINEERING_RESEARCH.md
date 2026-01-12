# iPod Reverse Engineering Research

## Comprehensive Technical Summary for ZigPod Emulator Development

This document consolidates technical details from freemyipod.org, Rockbox wiki, q3k's wInd3x writeup, and related reverse engineering resources.

---

## 1. Hardware Overview

### 1.1 PortalPlayer Devices (iPod 4G, Photo, Mini, Video 5G, Nano 1G)

**Processors:**
- **PP5002**: 1st-3rd generation iPods (significantly slower)
- **PP5020**: Mini 1G, 4th Gen, Photo/Color models
- **PP5020E**: Color iPods (Aug 2005 onwards)
- **PP5021C-TDF**: Nano 1G and Video (5G)
- **PP5022**: Mini 2G, software-compatible with PP5020

**Architecture:** Dual-core ARM with CPU + COP (coprocessor)

**Memory:**
- SDRAM: 32MB at 0x10000000 (64MB on 60GB 5G models)
- Fast RAM/IRAM: 96KB at 0x40000000
- Cache Control: 0xf0000000
- Hardware Revision: 0x2084 (32-bit integer for runtime detection)

### 1.2 Samsung S5L-Series Devices (iPod Classic 6G, Nano 2G-7G)

**Processors:**
- **S5L8701**: Nano 2G (ARM940T, 176kB SRAM)
- **S5L8702**: Nano 3G, Classic 6G (ARM926EJ-S, ~100MHz)
- **S5L8720/S5L8730**: Nano 4G/5G

**Memory Architecture:**
- BootROM mirrored: 0x000-0x600 (interrupt vectors) and 0x20000000
- SDRAM: 256Mb Mobile DDR at 1.8V
- Utility NOR Flash: SST25VF080B (8Mb, Serial SPI)

---

## 2. Memory Maps

### 2.1 PortalPlayer PP502x Memory Map

| Peripheral | Base Address | Notes |
|------------|--------------|-------|
| SDRAM | 0x10000000 | 32-64MB |
| Fast RAM (IRAM) | 0x40000000 | 96KB |
| CPU/COP ID | 0x60000000 | CPU=0x55, COP=0xAA |
| CPU Mailbox | 0x60001000 | Inter-processor communication |
| Interrupt Controller | 0x60004000 | CPU/COP/FIQ status |
| Timer | 0x60005000 | Timer1/Timer2, usec timer |
| Device Control | 0x60006000 | Enable/reset peripherals |
| Power Management | 0x60007000 | Sleep registers |
| GPIO | 0x6000d000 | Ports A-E |
| USB | 0x6000C000 | USB controller |
| I2S Audio | 0x70002800 | Audio FIFO |
| LCD | 0x70003000 | Display controller |
| Piezo | 0x7000A000 | Piezo controller |
| I2C/Scroll Wheel | 0x7000C000 | Touch position and buttons |
| Cache Control | 0xf0000000 | |
| IDE/ATA | 0xC3000000 | Storage controller |

### 2.2 Samsung S5L8702 Memory Map

| Peripheral | Base Address |
|------------|--------------|
| MIU | 0x38100000 |
| USB OTG | 0x38400000 |
| JPEG Decoder | 0x39600000 |
| ATA | 0x38700000 |
| SPI0 | 0x3c300000 |
| USB PHY | 0x3c400000 |
| System Controller | 0x3c500000 |
| TIMER | 0x3c700000 |
| WatchDog | 0x3c800000 |
| SPI1 | 0x3ce00000 |
| GPIO | 0x3cf00000 |
| Chip ID | 0x3d100000 |
| SPI2 | 0x3d200000 |

### 2.3 S5L8702 SPI Register Details

| Offset | Register | Description |
|--------|----------|-------------|
| 0x00 | SPICTRL | Control register |
| 0x04 | SPISETUP | Mode selection (TX/RX) |
| 0x08 | SPISTATUS | Status register |
| 0x0c | SPIPIN | Pin configuration |
| 0x10 | SPITXDATA | Transmit data (bits 7:0) |
| 0x20 | SPIRXDATA | Receive data (bits 7:0) |
| 0x30 | SPICLKDIV | Clock divider (bits 10:0) |
| 0x34 | SPIRXLIMIT | RX limit register |

---

## 3. Boot Process

### 3.1 PortalPlayer Boot Sequence

1. **Flash Bootloader** (Apple firmware in ROM/NOR)
   - Loads firmware from boot partition into RAM
   - Uses address and entry point from firmware header
   - Approximately 40MB Apple firmware in boot partition

2. **Rockbox Bootloader** (alternative)
   - Stripped-down Rockbox variant
   - Loads firmware from FAT32 partition
   - Requires: LCD, button, ATA, and FAT32 drivers

### 3.2 Samsung S5L8702 Boot Sequence

1. **BootROM Stage**
   - Lives at 0x20000000, mirrored to 0x00000000 for interrupt vectors
   - Initial tasks: stack/mode setup, PLL init, clock gate activation
   - Evaluates GPIO signals to select boot path:
     - NOR flash
     - NAND flash
     - DFU mode over USB (failsafe)
   - Second-stage loader arrives as IMG1 format image
   - Signature checked, decrypted, and executed

2. **Second-Stage Bootloader (Bootloader/WTF)**
   - "Bootloader" when loaded from storage
   - "WTF" when loaded via DFU recovery mode
   - Uses EFI-like modular design
   - Initialization: DRAM, LCD, UART, interrupt controllers, FTL
   - Boot continuation based on WTF/bootloader variant, pressed keys

### 3.3 Boot Modes

| Mode | Description | Access Method |
|------|-------------|---------------|
| Normal | Boots retailOS normally | Default boot |
| Disk Mode | Mass storage device | SELECT+PLAY on newer models |
| DFU Mode | Device Firmware Upgrade | Accepts WTF IMG1 images only |
| WTF Mode | "Where's The Firmware?" | After DFU + WTF image sent |
| Diagnostic | Device information | CENTER+REWIND during Apple logo |

**USB Identification:**
- Vendor ID: 0x05ac (Apple Inc.)
- Product IDs vary by model and mode

---

## 4. Firmware Formats

### 4.1 IMG1 Format

IMG1 is the firmware image format for S5L-based iPods and early iOS devices. Also known as "8900" or "DFU image" format.

**Header Structure (0x54 bytes + padding):**

| Offset | Size | Field | Description |
|--------|------|-------|-------------|
| 0x0 | 4 | magic | SoC digits (e.g., "8720") |
| 0x4 | 3 | version | "1.0" or "2.0" |
| 0x7 | 1 | format | Encryption/signature type |
| 0x8 | 4 | entrypoint | Offset to execution point |
| 0xC | 4 | bodyLen | Image body size |
| 0x10 | 4 | dataLen | All non-header data size |
| 0x14 | 4 | footerCertOffset | Certificate bundle start |
| 0x18 | 4 | footerCertLen | Certificate bundle size |
| 0x1C | 32 | salt | Random data |
| 0x3C | 2 | unk1 | Unknown |
| 0x3E | 2 | unk2 | Possibly security epoch |
| 0x40 | 16 | headerSign | AES-encrypted SHA1 signature |
| 0x50 | 4 | headerLeftover | Unencrypted SHA1 remainder |

**Padding sizes by SoC:**
- S5L8900/S5L8702: 0x800 bytes
- S5L8720/S5L8930: 0x600 bytes
- S5L8723/S5L8740: 0x400 bytes

**Format Types:**

| Format | Header Signed | Body Encrypted | Body Signed | Notes |
|--------|---------------|----------------|-------------|-------|
| 1 (SIGNED_ENCRYPTED) | Yes | Yes | No | Not in 2.0 |
| 2 (SIGNED) | Yes | No | No | Not in 2.0 |
| 3 (X509_SIGNED_ENCRYPTED) | Yes | Yes | Yes | Most images |
| 4 (X509_SIGNED) | Yes | No | Yes | Alternative |

**Signature Verification:**
1. Header: Compute SHA1(data[0:0x40]), encrypt with GID key, compare
2. SHA1 leftover: Final 4 bytes unencrypted (verification shortcut)
3. Body (X509): Extract leaf cert public key, verify body signature

**Certificate Chain Validation:**
- Leaf cert serial: starts with `01:fb:01:fb` (production) or `01:fb:00:fb` (dev)
- Root cert SHA1 fingerprint: `61:1e:5b:66:2c:59:3a:08:ff:58:d1:4a:e2:24:52:d1:98:df:6c:60`

### 4.2 Firmware Partition Structure

**Nano 2G/3G/Classic:**
- OSOS: Main firmware image (encrypted since Nano 2G)
- AUPD: Update partition
- RSRC: Resource filesystem (unencrypted), mountable at offset 0x1E00
- Hash section (Nano 3G+): 0x1800 bytes of 0xFF

**Nano 4G+:**
- Diagnostic mode binary
- Disk mode binary
- Boot logos, error images, battery status bitmaps
- N58s bootloader file
- Recovery firmware variants

---

## 5. Storage Architecture

### 5.1 Flash Translation Layer (FTL) - Whimory

iPod Nano 2G and later use Whimory FTL with two components:

**Address Translation Hierarchy:**
1. Logical pages (lPage) - filesystem visible
2. Virtual pages (vPage) - VFL-level
3. Physical pages (pPage) - actual flash addresses
4. Hyperblocks - single logical block spanning all banks (round-robin)

**On-Flash Layout (low to high):**
1. Block 0: Device signature
2. VFL Context Blocks (4): VFL state
3. Spare Blocks: Bad block remapping
4. Virtual Blocks: User data (directly mapped)
5. Protected Region: BBT, low-level signature

### 5.2 VFL (Virtual Flash Layer)

Manages bad block handling, emulates "clean" flash to FTL.

**VFL Context Structure (840 bytes):**
- `usn` (u32): Cross-bank update sequence counter
- `ftlctrlblocks` (u16[3]): FTL context block references
- `activecxtblock` (u16): Ring buffer index
- `remaptable` (u16[0x334]): Spare to vBlock mapping
- `bbt` (u8[0x11A]): Bad block bitmap (1=good, 0=bad)
- `vflcxtblocks` (u16[4]): Ring buffer of pBlock numbers

**VFL Mounting:**
1. Search final 10% of flash for "DEVICEINFOSIGN\0\0" and "BBT\0"
2. Locate Bad Block Table
3. Scan for type 0x80 (VFL context marker)
4. Read block with highest USN
5. Verify checksums

### 5.3 FTL Context Structure (>448 bytes)

- `usn` (u32): Decremented per metadata revision
- `nextblockusn` (u32): Incremented per user data write
- `freecount` (u16): Available pages in block pool
- `swapcounter` (u16): Wear distribution (swap at 300 writes)
- `blockpool` (u16[0x14]): 20 free hyperblocks ring buffer
- `ftl_map_pages` (u32[8]): Block map vPage addresses
- `ftlctrlblocks` (u16[3]): Metadata vBlock ring buffer
- `clean_flag` (u32): Set during sync, reset on write

**Page Metadata (64 bytes spare):**

User Data (types 0x40, 0x41):
- lpn (u32): Logical page number
- usn (u32): From ftl_cxt.nextblockusn
- type (u8): 0x40 normal, 0x41 final in hyperblock
- eccmark (u8): 0xFF normal, 0x55 if error during copy
- dataecc (0x28 bytes), spareecc (0xC bytes)

Metadata (other types):
- usn (u32), idx (u16), type (u8)
- Type values: 0x43 (FTL ctx), 0x44 (block map), 0x46 (erase ctr), 0x47 (unclean), 0x80 (VFL ctx)

---

## 6. FAT32 Filesystem Requirements

### 6.1 Boot Sector / BPB Structure

**Extended Boot Record (FAT32) at offset 36:**

| Offset | Size | Field | Description |
|--------|------|-------|-------------|
| 0x024 | 4 | sectors_per_fat | Size of FAT in sectors |
| 0x028 | 2 | flags | Extended flags |
| 0x02A | 2 | fs_version | FAT version number |
| 0x02C | 4 | root_cluster | Root directory cluster (typically 2) |
| 0x030 | 2 | fsinfo_sector | FSInfo sector number |
| 0x032 | 2 | backup_boot | Backup boot sector |
| 0x040 | 1 | drive_number | Physical drive number |
| 0x042 | 1 | signature | Must be 0x28 or 0x29 |
| 0x052 | 8 | fs_type | Always "FAT32   " |

Boot sector ends with 0xAA55 signature at offset 510.

### 6.2 FSInfo Structure

| Offset | Size | Field | Value |
|--------|------|-------|-------|
| 0x0 | 4 | lead_sig | 0x41615252 |
| 0x1E4 | 4 | struct_sig | 0x61417272 |
| 0x1E8 | 4 | free_count | Free clusters (0xFFFFFFFF = unknown) |
| 0x1EC | 4 | next_free | Search hint (0xFFFFFFFF = start at 2) |
| 0x1FC | 4 | trail_sig | 0xAA550000 |

### 6.3 FAT Entry Format

FAT32 uses 32-bit entries (only lower 28 bits used):

```
unsigned int table_value = *(unsigned int*)&FAT_table[ent_offset];
table_value &= 0x0FFFFFFF;  // Mask upper 4 bits
```

**Special Values:**
- 0x0FFFFFF8 or higher: End of cluster chain
- 0x0FFFFFF7: Bad cluster
- 0: Free cluster

**Reserved Entries:**
- Index 0: Media descriptor + 0xFFFFFFF0
- Index 1: Always 0xFFFFFFFF

### 6.4 Directory Entry Format (32 bytes)

| Offset | Size | Field | Description |
|--------|------|-------|-------------|
| 0 | 11 | name | 8.3 filename (space padded) |
| 11 | 1 | attr | Attributes |
| 12 | 1 | nt_reserved | NT case flags |
| 13 | 1 | create_time_tenth | Centiseconds (0-199) |
| 14 | 2 | create_time | Hours:5, Minutes:6, Seconds:5 |
| 16 | 2 | create_date | Year:7, Month:4, Day:5 |
| 18 | 2 | access_date | Last accessed |
| 20 | 2 | cluster_high | High 16 bits of cluster |
| 22 | 2 | modify_time | Last modification time |
| 24 | 2 | modify_date | Last modification date |
| 26 | 2 | cluster_low | Low 16 bits of cluster |
| 28 | 4 | file_size | Size in bytes |

**Attribute Flags:**
- 0x01: READ_ONLY
- 0x02: HIDDEN
- 0x04: SYSTEM
- 0x08: VOLUME_ID
- 0x10: DIRECTORY
- 0x20: ARCHIVE
- 0x0F: LONG_NAME (LFN marker)

**Special First Byte Values:**
- 0x00: End of directory (no more entries)
- 0xE5: Deleted entry (skip)

### 6.5 Long Filename (LFN) Entry Format

LFN entries precede their 8.3 entry and have attr=0x0F:

| Offset | Size | Field | Description |
|--------|------|-------|-------------|
| 0 | 1 | seq | Sequence (high bit = last) |
| 1 | 10 | name1 | First 5 UTF-16 characters |
| 11 | 1 | attr | Always 0x0F |
| 12 | 1 | type | Always 0 for name |
| 13 | 1 | checksum | Checksum of 8.3 name |
| 14 | 12 | name2 | Next 6 UTF-16 characters |
| 26 | 2 | cluster | Always 0 |
| 28 | 4 | name3 | Final 2 UTF-16 characters |

**LFN Checksum Algorithm:**
```c
unsigned char checksum(unsigned char *name) {
    unsigned char sum = 0;
    for (int i = 0; i < 11; i++) {
        sum = ((sum >> 1) | ((sum & 1) << 7)) + name[i];
    }
    return sum;
}
```

### 6.6 File Lookup Process

**Step 1: Calculate Data Region Start**
```
first_data_sector = reserved_sectors + (num_fats * fat_size)
```

**Step 2: Convert Cluster to Sector**
```
first_sector_of_cluster = ((cluster - 2) * sectors_per_cluster) + first_data_sector
```

**Step 3: Directory Parsing**
1. For each 32-byte entry:
   - If first byte = 0x00: no more entries
   - If first byte = 0xE5: skip (deleted)
   - If attr = 0x0F: accumulate LFN
   - Otherwise: parse as 8.3 entry
2. Follow cluster chain via FAT for large directories

**Step 4: Cluster Chain Traversal**
```c
while (true) {
    next_cluster = fat[current_cluster] & 0x0FFFFFFF;
    if (next_cluster >= 0x0FFFFFF8) break;  // End of chain
    current_cluster = next_cluster;
}
```

---

## 7. wInd3x Exploit Details

### 7.1 Vulnerability

Bounds-checking failure in USB Class request handler of iPod Nano 3G-5G BootROM:

```c
index = (uint)req->wIndex[0];
// No bounds check!
fptr = (USBHandler *)g_State->usbHandlers[index].handlerClass;
```

The lower byte of wIndex directly indexes into usbHandlers array, allowing access to memory at offsets 0x64 + (0x1c * n) where n = 0-255.

### 7.2 Exploitation Chain

**Stage 1: Control Code Execution (Nano 4G)**
- wIndex=3 targets offset 184 (ep0_txbuf_offs)
- Value controllable via DFU transfer timing

**Stage 2: Polyglot Payload**
8-byte sequence functions as both USB SETUP packet and ARM instruction:
```
0x20 0xfe 0xff 0xea 0x03 0x00 0x00 0x00
```
- As USB: bmRequestType=0x20, bRequest=0xfe, wValue=0xffea, wIndex=0x03
- As ARM from 0x2202e300: Branch to offset +136

**Stage 3: Gadget Chaining**
- "blx r0" at address 0x3b0 serves as trampoline
- First argument (ep0_dma address) in r0 enables arbitrary code execution

**Memory Regions:**
- ep0_dma (USB buffer): 0x2202e300 (Nano 4G/5G)
- blx r0 gadget: 0x3b0 (Nano 4G), 0x37c (Nano 5G)

---

## 8. RetailOS Architecture

### 8.1 Core Design

- Single binary blob without modularity
- Based on RTXC 3.2 kernel
- UI from Pixo intellectual property
- All processes run in ARM system mode (no privilege separation)

### 8.2 Memory Layout (Nano 5G)

| Segment | Location | Size | Purpose |
|---------|----------|------|---------|
| sram.text | 0x22000000 | ~0xe27c | RTXC kernel |
| sram.bss/data | 0x22030000+ | | Runtime data |
| dram.textdata | 0x08000000 | ~0x6c3768 | Application |
| dram.frameworks | DRAM offset | | Framework APIs |
| dram.bss | DRAM offset | ~0x790a84 | Uninitialized |

### 8.3 RTXC Kernel Services

- Task: KS_alloc_task, KS_deftask, KS_execute, KS_terminate, KS_suspend
- Sync: KS_pend, KS_lock/unlock, KS_delay
- IPC: KS_receive, KS_enqueue/dequeue
- Timer: KS_alloc_timer, KS_start_timer, KS_stop_timer
- Time: KS_inqtime, KS_deftime

---

## 9. Known Issues and Quirks

### 9.1 FTL Checksum Bug

From Whimory FTL documentation: "The following line is pretty obviously a bug in Whimory" - XOR checksum uses != instead of == comparison.

### 9.2 iPod-Specific FAT32 Requirements

- Windows cannot format drives >32GB as FAT32
- iPod requires FAT32 for proper operation
- Third-party formatting tools may be necessary

### 9.3 Firmware Loading Quirks

- Firmware must be found in specific locations
- ".rockbox" directory and "rockbox.ipod" file expected
- LFN entries require correct checksums matching 8.3 short names

---

## 10. Debugging the FAT32 File Lookup Issue

Based on the existing FAT32_DEBUG_FINDINGS.md in this project:

### 10.1 Verified Working

- MBR structure with partition at sector 1
- VBR with correct FAT32 parameters
- FSInfo with valid signatures
- FAT entries for clusters 0-4
- Root directory with volume label and entries
- .rockbox directory with . and .. entries
- LFN checksums verified correct

### 10.2 Observed Behavior

- Bootloader finds .rockbox directory (8 chars) via LFN
- Bootloader does NOT find rockbox.ipod (12 chars) via LFN
- Same FAT32 structure works for directory, fails for file

### 10.3 Potential Causes

1. **ARM Emulator Bug**: Instruction emulation affecting string comparison or loop iteration
2. **Code Path Difference**: Different handling of directories vs files
3. **UTF-16 Processing**: Longer filename requires more LFN iterations

### 10.4 Key Observation

The difference between working (.rockbox, 8 chars) and non-working (rockbox.ipod, 12 chars) lookups suggests the issue may be in:
- Loop counter/branch conditions
- UTF-16 assembly loop termination
- String comparison with longer names

---

## 11. References

### 11.1 Primary Sources

- freemyipod.org wiki (Main Page, Classic_6G, Status, Modes, Boot_Process, FTL, IMG1, S5L8702, RetailOS)
- q3k.org/wInd3x.html - Detailed exploit writeup
- Rockbox wiki (IpodFAQ, IpodPort, IpodHardwareInfo, PortalPlayer, PortalPlayer502x)
- OSDev Wiki FAT32 documentation

### 11.2 Related Projects

- Rockbox (alternative firmware)
- emCORE (legacy bootloader, abandoned)
- U-Boot port (current bootloader)
- Linux kernel port (demonstrated on Nano 7G)

### 11.3 Tools

- ipodpatcher - Bootloader installation
- uefi-firmware-parser - Extract UEFI partitions from IMG1
- wInd3x exploit code
