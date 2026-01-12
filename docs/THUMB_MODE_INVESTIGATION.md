# Thumb Mode Investigation Results

## Hypothesis
The FAT32 file lookup might fail because the Rockbox bootloader uses Thumb instructions
for string comparison/LFN parsing, and the emulator might not handle Thumb mode correctly.

## Investigation Method
1. Searched bootloader binary for BX (Branch and Exchange) instructions
2. Found BX instructions at offsets: 0x350, 0x470, 0x480, 0x4A0, 0x4B0
3. Added debug logging to emulator's BX handler to log mode switches
4. Ran emulator with bootloader and FAT32 test disk

## Results

**NO Thumb mode switches occurred during FAT operations.**

The bootloader stays entirely in ARM mode during:
- MBR reading
- VBR/FAT parsing
- Root directory enumeration (finding .rockbox)
- .rockbox directory enumeration (trying to find rockbox.ipod)
- Fallback root directory search

## Conclusion

**Thumb mode is NOT the root cause of the file lookup failure.**

The BX instructions in the bootloader binary target ARM addresses (bit 0 = 0),
not Thumb addresses. The FAT driver code runs entirely in 32-bit ARM mode.

## What This Rules Out
- Thumb instruction decoding bugs
- Thumb/ARM mode switching issues
- 16-bit vs 32-bit instruction fetch problems

## Next Investigation Areas
Since Thumb mode is ruled out, focus on:
1. ARM instruction bugs in specific operations used by strcasecmp/LFN parsing
2. Memory load/store issues for UTF-16 characters (LDRH/STRH)
3. Loop condition/branch handling in directory enumeration
4. Possible off-by-one errors in string comparison

## Test Output
```
ATA: READ LBA=2055 (ROOT DIR) - finds .rockbox ✓
ATA: READ LBA=2056 (.ROCKBOX DIR) - should find rockbox.ipod ✗
ATA: READ LBA=2055 (ROOT DIR) - fallback, should find rockbox.ipod ✗
```
No "BX: Mode switch" messages appeared.
