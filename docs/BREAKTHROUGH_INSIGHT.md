# Breakthrough Insight: LFN Character Iteration Bug Hypothesis

**Date:** 2026-01-08 (Research), 2026-01-12 (Documented)
**Status:** Hypothesis - Requires Verification
**Priority:** CRITICAL

---

## Executive Summary

Through comprehensive research of the Rockbox FAT32 driver and comparison of working vs non-working filename lookups, we have identified a **specific byte access pattern** that is the most likely root cause of the `rockbox.ipod` file lookup failure.

**The Key Insight:**
The `longent_char_next()` function's `case 26` branch handles the transition from byte 24 to byte 28 (skipping the cluster field at bytes 26-27). This code path is **ONLY exercised for filenames with 11+ characters**.

---

## The Evidence

### What Works vs What Fails

| Filename | Length | Characters Used | Fields Accessed | Status |
|----------|--------|-----------------|-----------------|--------|
| `.rockbox` | 8 chars | 1-8 | name1 (5) + partial name2 (3) | ✓ Found |
| `rockbox.ipod` | 12 chars | 1-12 | name1 (5) + full name2 (6) + name3 (1) | ✗ NOT Found |

### LFN Entry Structure (32 bytes)

```
Offset  Field       Size    Characters
------  ----------  -----   ----------
0       ldir_ord    1       -
1-10    name1       10      chars 1-5 (UTF-16LE)
11      ldir_attr   1       - (always 0x0F)
12      ldir_type   1       -
13      ldir_chksum 1       -
14-25   name2       12      chars 6-11 (UTF-16LE)
26-27   fstcluslo   2       - (always 0x0000)
28-31   name3       4       chars 12-13 (UTF-16LE)
```

### Critical Byte Offsets

For an **8-character name** (`.rockbox`):
- Chars 1-5: bytes 1, 3, 5, 7, 9 (name1) ✓
- Chars 6-8: bytes 14, 16, 18 (partial name2) ✓
- NULL terminator at byte 20
- **Never reads bytes 24-25 or 28-31**

For a **12-character name** (`rockbox.ipod`):
- Chars 1-5: bytes 1, 3, 5, 7, 9 (name1) ✓
- Chars 6-11: bytes 14, 16, 18, 20, 22, **24** (full name2) ← **CRITICAL**
- Char 12: byte **28** (name3) ← **CRITICAL**
- NULL terminator at byte 30

### The `longent_char_next()` Function

```c
// From Rockbox firmware/common/fat.c
static inline unsigned int longent_char_next(unsigned int i)
{
    switch (i += 2)  // Advance by 2 bytes (UTF-16)
    {
    case 26: i -= 1; /* Skip cluster field: 24→28 NOT 24→26 */
    /* Fall-Through */
    case 11: i += 3; /* Skip attr/type/chksum: 9→14 NOT 9→11 */
    }
    return i < 31 ? i : 0;
}
```

The `case 26` branch is **ONLY executed** when:
1. The previous iteration was at byte 24 (char 11 of name2)
2. Adding 2 gives 26
3. The function then subtracts 1 and adds 3 (net: skip from 24 to 28)

**This code path is never exercised for names ≤10 characters!**

---

## Emulator Bug Hypothesis

The most likely bug locations in the ARM emulator are:

### 1. Memory Read at Bytes 24-25

If the emulator has a bug reading the 12th byte position of name2 (bytes 24-25), it would:
- Affect only names with 11+ characters
- Return wrong UTF-16 character data
- Cause string mismatch in `strcasecmp()`

### 2. Memory Read at Bytes 28-31

If the emulator has a bug reading name3 (bytes 28-31), it would:
- Affect only names with 12+ characters
- Return wrong UTF-16 character data
- Cause string mismatch

### 3. Loop Counter/Branch Bug

If the emulator has a subtle bug in how it handles the `switch` statement or loop counter increment:
- The byte offset calculation could be wrong
- Characters 11-13 would be read from wrong locations

---

## Verification Steps

### Step 1: Add Byte-Level LFN Tracing

Add debug output in the emulator's ATA peripheral to trace exact byte offsets being read during LFN parsing:

```zig
// In ATA read handler
if (sector_is_directory) {
    log.debug("LFN byte access: offset={d}, value=0x{X:0>2}", .{offset, data[offset]});
}
```

### Step 2: Compare Byte Access Patterns

Run the emulator with both names and compare:
- Which byte offsets are accessed for `.rockbox` (8 chars)
- Which byte offsets are accessed for `rockbox.ipod` (12 chars)
- Look for differences in access pattern

### Step 3: Test Name Length Boundary

Create test files with names of specific lengths:
- 10 characters: Should work (doesn't need case 26)
- 11 characters: Boundary case (first to use case 26)
- 12 characters: Should fail (needs bytes 24-25 AND 28-31)

### Step 4: Verify UTF-16 Byte Order

Check that the emulator correctly handles little-endian UTF-16:
- Char at bytes 24-25 should be: `byte[24] | (byte[25] << 8)`
- If byte order is wrong, ASCII chars > 0 would become garbage

---

## Rockbox Silent Failure Behavior

**CRITICAL:** The Rockbox FAT driver silently falls back to short names on ANY LFN parsing failure:

```c
// In fat_readdir():
if (!fatlong_parse_finish(&lnparse, ent, entry)) {
    // NO WARNING LOGGED!
    strcpy(entry->name, entry->shortname);
    rc = 2; // Name is OEM charset
}
```

This means:
1. LFN checksum mismatch → Silent fallback to short name
2. LFN sequence break → Silent fallback to short name
3. UTF-8 overflow → Silent fallback to short name
4. **Any emulator bug causing wrong bytes → Silent fallback to short name**

The bootloader then searches for "rockbox.ipod" using case-insensitive string comparison, but the parsed name is the 8.3 short name "ROCKBO~1.IPO" which doesn't match.

---

## Action Items

1. **Instrument the emulator** with byte-level LFN access tracing
2. **Test boundary cases** (10, 11, 12 character filenames)
3. **Verify UTF-16LE byte order** in memory reads
4. **Check ARM loop/branch emulation** for the character iteration function
5. **Add explicit LFN debug logging** to the ATA peripheral

---

## Files Modified/Created for Investigation

- `src/emulator/cpu/arm_executor.zig` - BX debug logging added
- `src/emulator/peripherals/ata.zig` - Sector/LFN debug output
- `docs/FAT32_DEBUG_FINDINGS.md` - Full investigation status
- `docs/THUMB_MODE_INVESTIGATION.md` - Ruled out Thumb mode
- `docs/chapters/ch03-rockbox/02-lfn-parsing.md` - LFN parsing details

---

## Related Documentation

- [LFN Parsing Details](./chapters/ch03-rockbox/02-lfn-parsing.md)
- [FAT32 Debug Findings](./FAT32_DEBUG_FINDINGS.md)
- [Investigation Status](./INVESTIGATION_STATUS.md)
- [Rockbox fat.c source](../../../rockbox/firmware/common/fat.c)

---

*This insight was discovered through systematic elimination of other hypotheses (Thumb mode, memory bus, checksum errors) and careful analysis of the code paths that differ between 8-character and 12-character filenames.*
