# Chapter 3.2: LFN (Long Filename) Parsing in Rockbox

## Overview

This document details how Rockbox parses FAT32 Long File Name (LFN) entries, based on analysis of `/Users/davidslv/projects/rockbox/firmware/common/fat.c`.

## LFN Entry Structure

Each LFN entry is 32 bytes with characters spread across three fields:

```c
struct ldir_entry {
    uint8_t  ldir_ord;          //  0: Sequence number (0x41 for single entry)
    uint8_t  ldir_name1[10];    //  1-10: Characters 1-5 (UTF-16LE)
    uint8_t  ldir_attr;         // 11: Attribute (always 0x0F)
    uint8_t  ldir_type;         // 12: Type (always 0x00)
    uint8_t  ldir_chksum;       // 13: Checksum of short name
    uint8_t  ldir_name2[12];    // 14-25: Characters 6-11 (UTF-16LE)
    uint16_t ldir_fstcluslo;    // 26-27: Always 0x0000
    uint8_t  ldir_name3[4];     // 28-31: Characters 12-13 (UTF-16LE)
};
```

## Character Byte Offsets

| Char # | Byte Offset | Field |
|--------|-------------|-------|
| 1-5    | 1-10        | name1 |
| 6-11   | 14-25       | name2 |
| 12-13  | 28-31       | name3 |

## Checksum Algorithm

```c
static uint8_t shortname_checksum(const unsigned char *shortname)
{
    uint8_t chksum = 0;
    for (unsigned int i = 0; i < 11; i++)
        chksum = (chksum << 7) + (chksum >> 1) + shortname[i];
    return chksum;
}
```

This is equivalent to: `chksum = rotate_right(chksum, 1) + byte`

## LFN Detection

```c
#define ATTR_LONG_NAME      0x0F  // RO|HID|SYS|VOL
#define ATTR_LONG_NAME_MASK 0x3F  // RO|HID|SYS|VOL|DIR|ARC

#define IS_LDIR_ATTR(attr) \
    (((attr) & ATTR_LONG_NAME_MASK) == ATTR_LONG_NAME)
```

Entry is LFN if `(attr & 0x3F) == 0x0F`.

## Parsing Flow

### Step 1: Parse LFN Entries (`fatlong_parse_entry`)

```c
static bool fatlong_parse_entry(struct fatlong_parse_state *lnparse,
                                const union raw_dirent *ent,
                                struct fat_direntry *fatent)
{
    int ord = ent->ldir_ord;

    if (ord & 0x40)  // FATLONG_ORD_F_LAST - first physical entry
    {
        ord &= ~0x40;  // Remove flag
        if (ord == 0 || ord > 20)  // Invalid ordinal
            return invalid;
        lnparse->ord_max = ord;
        lnparse->ord = ord;
        lnparse->chksum = ent->ldir_chksum;
    }
    else
    {
        // Must be sequential: ord == previous_ord - 1
        if (ord != lnparse->ord - 1)
            return invalid;
    }

    // Store 13 UTF-16 characters from this entry
    uint16_t *ucsp = fatent->ucssegs[ord - 1 + 5];
    // ... read chars from name1, name2, name3 ...
}
```

### Step 2: Finalize LFN (`fatlong_parse_finish`)

```c
static bool fatlong_parse_finish(struct fatlong_parse_state *lnparse,
                                 const union raw_dirent *ent,
                                 struct fat_direntry *fatent)
{
    // FAILURE CONDITIONS:
    if (lnparse->ord_max <= 0)
        return false;  // No valid LFN entries

    if (lnparse->ord != 1)
        return false;  // Sequence incomplete

    if (lnparse->chksum != shortname_checksum(ent->name))
        return false;  // CHECKSUM MISMATCH - SILENT FAILURE!

    // Convert UTF-16 to UTF-8
    for (each segment) {
        for (each char) {
            p = utf8encode(ucc, p);
            if (p - name > 255)
                return false;  // UTF-8 overflow
        }
    }

    return true;
}
```

## Silent Failure Behavior

**CRITICAL**: When LFN parsing fails, Rockbox silently falls back to the short name:

```c
// In fat_readdir():
if (!fatlong_parse_finish(&lnparse, ent, entry))
{
    // NO WARNING LOGGED!
    strcpy(entry->name, entry->shortname);
    rc = 2; // Name is OEM charset
}
```

This means:
1. If checksum doesn't match → silently use short name
2. If sequence is broken → silently use short name
3. If UTF-8 overflow → silently use short name

## String Comparison

After parsing, filename comparison uses:

```c
if (!strcasecmp(compname, dir_fatent.name))
    break;  // Found!
```

This is **case-insensitive** comparison.

## Comparison: 8-char vs 12-char Names

### `.rockbox` (8 characters)

```
Entry bytes:
41 2E 00 72 00 6F 00 63 00 6B 00 0F 00 BD 62 00
6F 00 78 00 00 00 FF FF FF FF 00 00 FF FF FF FF
```

- name1 (bytes 1-10): `.`, `r`, `o`, `c`, `k`
- name2 (bytes 14-25): `b`, `o`, `x`, `\0`, padding...
- name3 (bytes 28-31): padding (0xFFFF)

**Only uses 8 chars, stops at null in name2.**

### `rockbox.ipod` (12 characters)

```
Entry bytes:
41 72 00 6F 00 63 00 6B 00 62 00 0F 00 4E 6F 00
78 00 2E 00 69 00 70 00 6F 00 00 00 64 00 00 00
```

- name1 (bytes 1-10): `r`, `o`, `c`, `k`, `b`
- name2 (bytes 14-25): `o`, `x`, `.`, `i`, `p`, `o` (ALL 6 chars used!)
- name3 (bytes 28-31): `d`, `\0`

**Uses full name2 (bytes 24-25) and extends into name3 (bytes 28-31).**

## Potential Bug Location

The difference is that 12-char names require reading:
- **Bytes 24-25**: Last character of name2 field
- **Bytes 28-31**: name3 field

If there's an emulator bug in:
1. Memory access at these specific offsets
2. The character iteration loop `longent_char_next()` handling the 26→28 transition
3. UTF-16LE byte order when reading chars 11-13

Then 8-char names would work but 12-char names would fail.

## Character Iteration Function

```c
static inline unsigned int longent_char_next(unsigned int i)
{
    switch (i += 2)  // Advance by 2 bytes
    {
    case 26: i -= 1; /* Skip cluster field: 24→28 NOT 24→26 */
    /* Fall-Through */
    case 11: i += 3; /* Skip attr/type/chksum: 9→14 NOT 9→11 */
    }
    return i < 31 ? i : 0;
}
```

The `case 26` branch is critical for 12-char names - it skips from byte 24 to byte 28 (over the cluster field at bytes 26-27).
