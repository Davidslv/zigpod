# Investigation Status - FAT32 File Lookup Issue

## Current Problem
Rockbox bootloader finds `.rockbox` directory via LFN but cannot find `rockbox.ipod` file despite identical LFN structure.

## Verified Correct
- FAT32 structure (MBR, VBR, FAT tables, directory entries)
- LFN checksums (0xBD, 0x4E, 0xEE)
- ATA data transfer (256 words/sector)
- Memory bus (little-endian byte order)
- Thumb mode not used (stays in ARM mode)

## Key Observation
- `.rockbox` (8 chars): Found ✓
- `rockbox.ipod` (12 chars): Not found ✗
- Longer string requires more loop iterations

## Hypothesis
Bug in ARM executor affecting loops with more iterations, possibly in:
- Branch conditions
- Loop counters
- String comparison operations

## Files Modified
- src/emulator/cpu/arm_executor.zig (BX debug logging)
- src/emulator/peripherals/ata.zig (sector/LFN debug output)
- docs/FAT32_DEBUG_FINDINGS.md
- docs/THUMB_MODE_INVESTIGATION.md
- docs/ROCKBOX_REVERSE_ENGINEERING.md

## Test Assets
- test64mb.img: Full test disk with .rockbox and rockbox.ipod
- test_minimal.img: Minimal disk with just rockbox.ipod in root
- firmware/rockbox-bootloader.bin: Rockbox bootloader for iPod Video

## Resume Point
If research yields nothing, continue investigating:
1. ARM instruction-level tracing during directory enumeration
2. Compare loop behavior for 8-char vs 12-char names
3. Test strcasecmp with longer strings in isolation
