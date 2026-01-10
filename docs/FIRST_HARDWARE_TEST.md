# ZigPod First Hardware Test - 2026-01-10

## Summary

**Result**: Black screen on boot. LCD driver initialization failed on real hardware.

**Device**: iPod Video 5th Generation (32MB RAM), "macpod" (HFS+ formatted), iFlash 256GB mod

---

## What We Did

### 1. Pre-Installation

#### Backup Firmware Partition
```bash
# Full disk backup is 238GB - too large
# Instead, backup only the firmware partition (167MB)
sudo dd if=/dev/disk10s2 of=/Users/davidslv/ipod-backups/firmware_backup.img bs=1m status=progress
```

#### Build ipodpatcher for Apple Silicon
The Rockbox ipodpatcher binary is 32-bit Intel/PowerPC only. We built from source:

```bash
# Download Rockbox source
cd tools/ipodpatcher-build
curl -L "https://github.com/Rockbox/rockbox/archive/refs/heads/master.zip" -o rockbox.zip
unzip -q rockbox.zip "rockbox-master/utils/ipodpatcher/*"

# Build for arm64
cd rockbox-master/utils/ipodpatcher
clang -o ipodpatcher -Wall -DVERSION='"5.0-zigpod"' \
    main.c ipodpatcher.c ipodio-posix.c arc4.c fat32format.c ipodpatcher-aupd.c \
    -framework IOKit -framework CoreFoundation

cp ipodpatcher /path/to/zigpod/ipodpatcher-arm64
```

#### Fix ipodpatcher Unmount Bug
The original code fails if firmware partition isn't mounted. Fixed in `ipodio-posix.c`:

```c
// Changed from returning -1 on unmount failure to:
if (res==0) {
    return 0;
} else {
    /* Partition may not be mounted - that's OK, continue anyway */
    fprintf(stderr, "[INFO] Partition not mounted (OK)\n");
    return 0;
}
```

### 2. Installation

#### Install Bootloader
```bash
# Must unmount data partition first to avoid "Resource busy"
diskutil unmount /dev/disk10s3

# Use -ab flag for raw binary (not -a which expects .ipod format)
sudo ./ipodpatcher-arm64 /dev/disk10 -ab zig-out/bin/zigpod-bootloader.bin
```

**Output:**
```
[INFO] Reading original firmware...
[INFO] Wrote 7563264 bytes to firmware partition
[INFO] Bootloader zig-out/bin/zigpod-bootloader.bin written to device.
```

#### Copy Firmware
```bash
diskutil mount /dev/disk10s3
mkdir -p /Volumes/iPod/.zigpod
cp zig-out/bin/zigpod.bin /Volumes/iPod/.zigpod/firmware.bin
diskutil eject /dev/disk10
```

### 3. Test Result

- Disconnected USB
- Held Menu + Select to reboot
- **Result: Black screen**
- Apple logo did not appear
- ZigPod splash screen did not appear

### 4. Recovery

#### Enter Disk Mode
1. Hold **Menu + Select** for 10+ seconds (hard reset)
2. Immediately hold **Select + Play** when Apple logo appears
3. Wait for "OK to disconnect" / "Do not disconnect" screen

#### Restore Original Bootloader
```bash
diskutil unmount /dev/disk10s3
sudo dd if=/Users/davidslv/ipod-backups/firmware_backup.img of=/dev/disk10s2 bs=1m status=progress
diskutil eject /dev/disk10
```

---

## Key Learnings

### ipodpatcher on Apple Silicon
- Rockbox binaries are old (PPC/i386 only)
- Must build from source for arm64 macOS
- Source location: `utils/ipodpatcher/` (not `rbutil/ipodpatcher/`)

### ipodpatcher Flags
- `-a` = expects `.ipod` format file
- `-ab` = expects raw `.bin` file (what we need)
- `-r` = read/dump firmware partition
- `-w` = write firmware partition

### Unmount Requirements
- Must unmount `/dev/disk10s3` (data partition) before writing
- Firmware partition (`s2`) is never mounted, but ipodpatcher tries to unmount it anyway

### Recovery Always Works
- Disk Mode is in ROM - hardware reset + Select+Play always works
- Firmware backup allows full recovery

---

## Files Created

| File | Purpose |
|------|---------|
| `ipodpatcher-arm64` | Native Apple Silicon ipodpatcher |
| `tools/ipodpatcher-build/` | ipodpatcher source and build |
| `ipod-backups/firmware_backup.img` | Original firmware partition backup |

---

## Next Steps

See [POSTMORTEM.md](./POSTMORTEM.md) for analysis of why ZigPod showed black screen.
