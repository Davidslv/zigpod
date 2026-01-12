# Centralized Documentation: Reverse Engineering and Porting Rockbox to the iPod Classic

This document compiles and centralizes all available detailed information on how members of the Rockbox team and affiliated projects (notably freemyipod) documented the process of reverse engineering the iPod Classic (6th/6.5th/7th generations, models from 2007-2009, 80GB/120GB/160GB) and porting the Rockbox open-source firmware to it. The iPod Classic posed unique challenges due to its encrypted firmware, BootROM protections, and hardware variations (e.g., PATA vs. CE-ATA storage interfaces). This porting effort involved hardware dissection, vulnerability discovery, exploit development, and firmware adaptation. Information is drawn from official wikis, GitHub repositories, blog write-ups, forum threads, and commit logs, with factual locations provided for each resource.

The document is organized into sections for clarity, focusing on technical details, milestones, tools, and contributors. All claims are substantiated by the sourced materials.

## 1. Introduction to the Project
The Rockbox project, started in 2001, aims to provide a free, open-source firmware replacement for digital music players, enhancing features like codec support, EQ, and UI customization. The iPod Classic port began around 2007-2011, driven by community interest in bypassing Apple's restrictions. The freemyipod project (launched to reverse-engineer non-iOS iPods) played a pivotal role, overlapping with Rockbox developers. Key challenges included:
- Encrypted and signed firmware (IMG1 format).
- BootROM vulnerabilities for code execution.
- Hardware incompatibilities, e.g., the CE-ATA drive in the original 160GB model remains unsupported.

The port achieved stable status by ~2011, with Rockbox now installable via the Rockbox Utility for supported models. Early efforts are documented in proposal threads from 2007.

**Factual Location**: Rockbox main site - https://www.rockbox.org/

## 2. Hardware Reverse Engineering
Reverse engineering focused on mapping undocumented components of the Samsung S5L8702 SoC (ARM-based) and peripherals.

### Hardware Specifications for iPod Classic
- **Processor**: Samsung S5L8702 ARM SoC.
- **Storage**: PATA HDD for most models (80GB, 120GB, thin 160GB); CE-ATA for original "fat" 160GB (unsupported).
- **Memory**: SDRAM (supported).
- **Interfaces**: UART, USB, SPI (used), I2C (all supported).
- **Display/Controls**: LCD, backlight, clickwheel (all supported).
- **Audio**: Fully supported.
- **Other**: RTC (supported); Power management (partial); Piezo and accelerometer (N/A or unsupported).
- **Models**: Classic 1G (80/160GB, 2007), 2G (120GB, 2008), 3G (160GB thin, 2009).

### Hardware Specifications for iPod Video (5th/5.5th Gen) - ZigPod Target
- **Processor**: PortalPlayer PP5021C (dual ARM7TDMI cores).
- **Storage**: PATA HDD (30GB/60GB/80GB); iFlash compatible.
- **Memory**: 32MB SDRAM (30GB), 64MB SDRAM (60/80GB).
- **Interfaces**: I2C, I2S, GPIO.
- **Display**: 320x240 LCD (BCM2722 controller).
- **Audio**: WM8758 codec via I2S.
- **Click Wheel**: Capacitive touch with 5 buttons.

Efforts involved JTAG probing, GUID table analysis, and SysCfg sector dumps to identify components.

**Factual Locations**:
- freemyipod Wiki - Classic 6G Page: https://freemyipod.org/wiki/Classic_6G
- freemyipod Wiki - Status Page: https://freemyipod.org/wiki/Status

### Modes for Exploitation
The iPod operates in modes critical for porting:
- **DFU Mode**: Entered by holding Menu+Select during boot; resides in BootROM. Allows sending WTF IMG1 images for firmware upgrades. Essential for exploits, as it enables USB-based code injection without signature checks (post-exploit).
- **WTF Mode**: Entered from DFU by sending a specific IMG1; accepts verified images for booting custom firmware.
- **Disk/Normal Modes**: Used for mass storage and updates, but less relevant for initial exploitation.

**Factual Location**: freemyipod Wiki - Modes Page: https://freemyipod.org/wiki/Modes

## 3. Exploits and Tools
The core breakthrough was exploiting BootROM vulnerabilities to achieve code execution, bypass encryption, and load custom firmware.

### wInd3x BootROM Exploit
Discovered by Serge 'q3k' Bazanski in December 2021 (though earlier efforts date to 2010-2011). It targets a flaw in USB SETUP packet parsing: unchecked wIndex indexing into a handler array (length 1) for bmRequestType 0x20/0x40.
- **Affected Models**: iPod Nano 3G/4G/5G, Classic 6G; iPhone 3G (vulnerable but unexploited).
- **Discovery**: Reverse-engineered BootROM dumps (Nano 4G/5G), identifying memory layouts, USB stack, and gadgets like 'blx r0'.
- **Exploitation**:
  - Nano 4G/5G: Manipulate DFU counters to execute at 'blx r0' (offsets 0x3b0/0x37c), using polyglot payloads (valid USB + ARM code) for up to 0x800 bytes of execution. Overrides image verification vtable.
  - Nano 3G/Classic 6G: wIndex == 6 overrides 'OnImage' function pointer in State structure, bypassing decryption/verification using carved SRAM.
- **Capabilities**: Haxed DFU (unsigned images), memory dump/decrypt, CFW execution, retailOS booting.
- **Role in Rockbox Port**: Enables decrypting IMG1 files, running unsigned payloads (e.g., U-Boot), and installing bootloaders like emCORE (precursor to Rockbox bootloader). Without this, Apple's signatures block custom firmware.

**Factual Locations**:
- freemyipod Wiki - wInd3x Page: https://freemyipod.org/wiki/WInd3x
- q3k Write-up: https://q3k.org/wInd3x.html
- GitHub Repository: https://github.com/freemyipod/wInd3x (README includes build/usage: `go build ./cmd/wInd3x`; commands like `./wInd3x haxdfu` for DFU, `./wInd3x decrypt` for images).

### Other Tools
- **emCORE**: Early bootloader for installation; deprecated in favor of Rockbox's native bootloader. Used DFU exploits for setup.
- **Rockbox Utility**: Modern installer for stable builds.
- **s5late Exploit**: Complementary to wInd3x for some models.

## 4. Development History
- **2007 Proposal**: Forum threads proposed porting, discussing encryption cracking and developer recruitment. Challenges: Confirming feasibility for 160GB model.
- **2010-2011 Breakthrough**: Michael Sparmann (TheSeven) added initial port to Rockbox Git, using freemyipod exploits. Unstable release announced in forums.
- **Key Commits** (from Rockbox Git logs):
  - 2012: FS#12524 - Hardware click support (piezo driver) by Cástor Muñoz.
  - 2014: Reverted ATA commits for build fixes; upstream merges for iPod Classic.
  - Ongoing: Power-saving patches, audio measurements.
- **Milestones**: Code execution (2010), firmware decryption, full peripheral support (by 2011). Integrated into Rockbox upstream.

**Factual Locations**:
- Rockbox Git Repository: https://git.rockbox.org/cgit/rockbox.git/ (search for "ipod classic" in logs).
- Head-Fi Announcement Thread: https://www.head-fi.org/threads/ipod-classic-rockbox-its-happening.532426/ (176 pages of updates).
- Rockbox Forums Proposal: https://forums.rockbox.org/index.php/topic,12465.0.html

## 5. Installation Process
1. Enter DFU mode (hold Menu+Select).
2. Use wInd3x for haxed DFU: `./wInd3x haxdfu`.
3. Install bootloader (emCORE historically; now Rockbox Utility).
4. Load Rockbox build (e.g., daily from rockbox.org/dl.cgi?bin=ipod6g).
5. Dual-boot or replace Apple OS; risks include data loss.

Detailed manuals: Rockbox Manual for iPod Classic (PDF). Troubleshooting threads cover transfers without iTunes.

**Factual Locations**:
- Rockbox Daily Manuals: https://www.rockbox.org/manual.shtml
- iFlash Tutorial (related): https://www.iflash.xyz/howto-install-rockbox-on-the-ipod-classics/

## 6. Contributors
- **Serge 'q3k' Bazanski**: wInd3x discovery/exploit (q3k@q3k.org).
- **Michael Sparmann (TheSeven)**: Initial Rockbox port commits.
- **Cástor Muñoz**: Power-saving, click support.
- **aroldan**: Custom builds.
- **Others**: gsch (s5late), Linuxstb, Bagder (Daniel Stenberg), freemyipod team (5+ on wInd3x GitHub).

## 7. Complete List of Resources
- freemyipod Main Wiki: https://freemyipod.org/wiki/Main_Page
- Apple Wiki (supplementary): https://theapplewiki.com/wiki/IPod_classic
- Rockbox Forums Troubleshooting: https://forums.rockbox.org/index.php?topic=52181.15
- Wikipedia (context): https://en.wikipedia.org/wiki/IPodLinux (mentions freemyipod)
- All cited above.

## 8. Rockbox FAT Driver Technical Details

### LFN Assembly and Validation
The Rockbox FAT driver (`firmware/drivers/fat.c` or `firmware/common/fat.c`) handles Long File Names:
- Functions like `fatlong_parse_entry` iterate over entries in reverse order
- Check sequence byte (e.g., 0x41 for single-entry LFN with last flag 0x40)
- Validate checksum against short name's 11 bytes
- Assemble UTF-16LE characters into buffer
- If checksum mismatches or order invalid (>20 or <1), falls back to short name

### Checksum Calculation
Standard LFN checksum algorithm:
```c
unsigned char lfn_checksum(const unsigned char *p)
{
    unsigned char sum = 0;
    int i;
    for (i = 11; i; i--)
        sum = ((sum & 1) << 7) | (sum >> 1) + *p++;
    return sum;
}
```
Applied to short name bytes (upper-case, padded with spaces). No differences for files vs directories.

### Name Matching
- Uses `strcasecmp` (case-insensitive) to match requested name against parsed LFN
- Attributes checked separately (0x10 for directory)

### Bootloader Flow
In `bootloader/ipod.c`:
1. Calls `load_firmware` to open FAT partition
2. Attempts to find `/.rockbox/rockbox.ipod` first
3. Falls back to `/rockbox.ipod` in root if not found

### Compilation Notes
- Rockbox compiles much of its code with **Thumb instructions** (`-mthumb`) for size optimization on ARM7TDMI
- This is critical for emulator compatibility - the CPSR T-bit must be handled correctly

This document ensures completeness by synthesizing primary sources; for updates, check the live resources as development continues.
