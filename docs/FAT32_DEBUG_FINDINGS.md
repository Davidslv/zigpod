# FAT32 Filesystem Debug Findings

## Issue Summary
The Rockbox bootloader reads directory sectors but cannot find `rockbox.ipod` file,
even though the FAT32 filesystem structure appears correct with valid LFN entries.

## Verified Correct

### 1. MBR Structure
- Partition 1: Type 0x0C (FAT32 LBA), starts at sector 1, 131071 sectors
- Boot signature: 0xAA55 at offset 0x1FE

### 2. VBR (Volume Boot Record) at Sector 1
- Bytes per sector: 512
- Sectors per cluster: 1
- Reserved sectors: 6
- Number of FATs: 2
- FAT size: 1024 sectors
- Root cluster: 2
- FSInfo sector: 1 (relative to partition)
- Boot signature: 0xAA55

### 3. FSInfo Sector
- Lead signature: 0x41615252
- Struct signature: 0x61417272
- Trail signature: 0xAA550000
- Free cluster count: 129016
- Next free cluster: 3

### 4. FAT Entries
- Cluster 0: 0x0FFFFFF8 (media type)
- Cluster 1: 0x0FFFFFFF (reserved)
- Cluster 2: 0x0FFFFFFF (root directory, end of chain)
- Cluster 3: 0x0FFFFFFF (.rockbox directory, end of chain)
- Cluster 4: 0x0FFFFFFF (rockbox.ipod file, end of chain)

### 5. Root Directory (Sector 2055 = Cluster 2)
```
Entry 0: ZIGPOD       attr=0x08 (Volume Label)
Entry 1: LFN ".rockbox" seq=0x41 checksum=0xBD
Entry 2: ROCKBO~1     attr=0x10 (Directory) cluster=3
Entry 3: LFN "rockbox.ipod" seq=0x41 checksum=0xEE
Entry 4: ROCKBO~2.IPO attr=0x20 (File) cluster=4 size=12
```

### 6. .rockbox Directory (Sector 2056 = Cluster 3)
```
Entry 0: .            attr=0x10 cluster=3 (current dir)
Entry 1: ..           attr=0x10 cluster=2 (parent dir)
Entry 2: LFN "rockbox.ipod" seq=0x41 checksum=0x4E
Entry 3: ROCKBO~1.IPO attr=0x20 (File) cluster=4 size=12
```

### 7. LFN Checksum Verification
All checksums verified using standard algorithm:
```
checksum = ((checksum >> 1) | ((checksum & 1) << 7)) + byte
```
- "ROCKBO~1   " (dir) -> 0xBD
- "ROCKBO~2IPO" (root file) -> 0xEE
- "ROCKBO~1IPO" (.rockbox file) -> 0x4E

### 8. ATA Data Transfer
- Sector reads complete: 256 words (512 bytes) per sector
- No data read errors (not_ready count = 0)
- Sectors read: 0, 0, 1, 2, 2055, 2056, 2055 (total 7)

## Observed Behavior

1. Bootloader shows "Loading Rockbox..." (button detection works)
2. MBR is read (sector 0) twice
3. VBR is read (sector 1)
4. FSInfo is read (sector 2)
5. Root directory is read (sector 2055) - finds .rockbox
6. .rockbox directory is read (sector 2056) - should find rockbox.ipod
7. Root directory is read again (sector 2055) - fallback search
8. Sector 2057 (file content) is NEVER read

## The Mystery

The FAT driver:
- Successfully finds .rockbox directory (proven by reading sector 2056)
- Parses directory entries including LFN entries
- But does NOT find rockbox.ipod in either location

### Key Evidence: LFN Works for Directories

The bootloader DOES find .rockbox directory via LFN parsing:
1. Reads root directory (sector 2055)
2. Parses LFN entry with ".rockbox" and checksum 0xBD
3. Correctly navigates to cluster 3 (sector 2056)

This proves LFN parsing is functional. The issue is specific to file lookup.

### LFN Hex Dumps (Verified Correct)

Root directory - ".rockbox" LFN entry:
```
41 2E 00 72 00 6F 00 63 00 6B 00 0F 00 BD 62 00
6F 00 78 00 00 00 FF FF FF FF 00 00 FF FF FF FF
```
- Sequence: 0x41 (last | 1)
- Checksum: 0xBD (matches "ROCKBO~1   ")
- Name: ".rockbox\0"

.rockbox directory - "rockbox.ipod" LFN entry:
```
41 72 00 6F 00 63 00 6B 00 62 00 0F 00 4E 6F 00
78 00 2E 00 69 00 70 00 6F 00 00 00 64 00 00 00
```
- Sequence: 0x41 (last | 1)
- Checksum: 0x4E (matches "ROCKBO~1IPO")
- Name: "rockbox.ipod\0"

### Checksum Verification (Python)

```python
def checksum(name):
    s = 0
    for b in name.encode('ascii'):
        s = ((s << 7) + (s >> 1) + b) & 0xFF
    return s

checksum("ROCKBO~1   ")  # 0xBD for .rockbox dir
checksum("ROCKBO~1IPO")  # 0x4E for rockbox.ipod in .rockbox
checksum("ROCKBO~2IPO")  # 0xEE for rockbox.ipod in root
```

## Analysis: Likely Emulator Issue

Since:
1. FAT32 structure is 100% correct (verified against spec)
2. LFN checksums match exactly
3. ATA returns correct data (hex dumps verified)
4. LFN works for directory lookup (.rockbox found)
5. Same structure fails for file lookup (rockbox.ipod not found)

The issue is likely in the emulator's ARM CPU execution, not the FAT32 structure.
Possible causes:
- Bug in string comparison during file lookup
- Incorrect ARM instruction emulation affecting loop iteration
- Memory access issue when processing file entries
- Difference in code path between directory vs file matching

## Potential Root Causes (Narrowed Down)

1. **Emulator CPU Bug**: ARM instruction emulation issue affecting
   string comparison or loop iteration in FAT driver

2. **Memory/Cache Issue**: Emulated memory not behaving correctly
   during file entry processing

3. **Code Path Difference**: Rockbox may use different code paths
   for matching directories vs files

## Failed Attempts

1. Using only 8.3 short names: "ROCKBOX.IPO" doesn't match "rockbox.ipod"
   because extension "IPO" != "ipod" (4 chars truncated to 3)

2. LFN entries with correct checksums: Still not found

3. Multiple test disks (test64mb.img, test_minimal.img): Same behavior

4. Verified ATA returns complete sectors (256 words each)

## Next Steps to Try

1. Add CPU instruction tracing during file lookup
2. Compare ARM register state between directory and file lookup
3. Use GDB to step through the FAT driver code in emulator
4. Test with simpler ARM firmware to validate string operations
5. Compare real iPod behavior with emulator using same disk image

## Test Files

- `test64mb.img`: Full LFN test disk
- `test_simple.img`: 8.3 only test disk
- `tools/mkfat32.zig`: FAT32 filesystem creator
- `tools/add_rockbox.zig`: Adds .rockbox directory with LFN
- `tools/add_rockbox_simple.zig`: Adds 8.3 file only

## References

- Rockbox FAT driver: `/Users/davidslv/projects/rockbox/firmware/common/fat.c`
- Rockbox bootloader: `/Users/davidslv/projects/rockbox/bootloader/ipod.c`
- FAT32 specification: Microsoft EFI FAT32 File System Specification
