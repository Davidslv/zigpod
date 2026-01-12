# ZigPod Technical Documentation - Chapter Index

This directory contains comprehensive technical documentation for the ZigPod iPod emulator project, organized by topic.

## Chapters

### Chapter 1: Hardware Reference
- **1.1** [PP5020/PP5021 SoC Architecture](./ch01-hardware/01-pp5020-architecture.md)
- **1.2** [Memory Map and Register Reference](./ch01-hardware/02-memory-map.md)
- **1.3** [ATA/IDE Controller](./ch01-hardware/03-ata-controller.md)
- **1.4** [Interrupt System](./ch01-hardware/04-interrupts.md)

### Chapter 2: Boot Process
- **2.1** [iPod Boot Sequence](./ch02-boot/01-boot-sequence.md)
- **2.2** [Partition Requirements](./ch02-boot/02-partitions.md)
- **2.3** [Firmware Formats (IMG1/IMG2/IMG3)](./ch02-boot/03-firmware-formats.md)

### Chapter 3: Rockbox Integration
- **3.1** [FAT32 Driver Implementation](./ch03-rockbox/01-fat-driver.md)
- **3.2** [LFN (Long Filename) Parsing](./ch03-rockbox/02-lfn-parsing.md)
- **3.3** [Bootloader Architecture](./ch03-rockbox/03-bootloader.md)
- **3.4** [Build Configuration](./ch03-rockbox/04-build-config.md)

### Chapter 4: Reverse Engineering Resources
- **4.1** [freemyipod Wiki Summary](./ch04-research/01-freemyipod.md)
- **4.2** [wInd3x Exploit Analysis](./ch04-research/02-wind3x.md)
- **4.3** [Key Contributors and Projects](./ch04-research/03-contributors.md)

### Chapter 5: Debugging and Investigation
- **5.1** [FAT32 Debug Findings](./ch05-debug/01-fat32-findings.md)
- **5.2** [Thumb Mode Investigation](./ch05-debug/02-thumb-mode.md)
- **5.3** [Current Investigation Status](./ch05-debug/03-status.md)

## Quick Reference

| Document | Purpose |
|----------|---------|
| [INVESTIGATION_STATUS.md](../INVESTIGATION_STATUS.md) | Current debugging state |
| [FAT32_DEBUG_FINDINGS.md](../FAT32_DEBUG_FINDINGS.md) | FAT32 investigation details |
| [ROCKBOX_REVERSE_ENGINEERING.md](../ROCKBOX_REVERSE_ENGINEERING.md) | Comprehensive Rockbox RE docs |

## Key Findings Summary

### Breakthrough Insight: Silent LFN Failure

The Rockbox FAT driver has **silent failure conditions** when parsing LFN entries:

```c
// In fat_readdir() - when LFN parsing fails, it silently falls back:
if (!fatlong_parse_finish(&lnparse, ent, entry)) {
    // NO WARNING - just uses short name
    strcpy(entry->name, entry->shortname);
}
```

This means if LFN parsing fails (checksum mismatch, sequence break, UTF-8 overflow), the driver silently uses the short name instead.

### Critical Observation

- `.rockbox` (8 chars, directory): Found via LFN ✓
- `rockbox.ipod` (12 chars, file): NOT found via LFN ✗

Both use identical LFN structure. The difference is string length:
- 8-char name uses name1 (5 chars) + partial name2 (3 chars)
- 12-char name uses name1 (5 chars) + full name2 (6 chars) + name3 (1 char)

The longer name requires reading bytes 24-25 (last char of name2) and bytes 28-31 (name3), which might expose an emulator bug.
