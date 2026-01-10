# ZigPod Installation Guide

This guide walks you through installing ZigPod on your iPod Video (5th/5.5th Generation).

## Overview

ZigPod uses a **dual-boot** approach that preserves your original Apple firmware. After installation:
- **Default boot**: ZigPod OS
- **Hold Menu**: Boot original Apple firmware
- **Hold Play**: Enter DFU update mode

You can always return to the original firmware, and uninstallation is straightforward.

---

## Requirements

### Hardware
- iPod Video 5th Generation (A1136) or 5.5th Generation
- USB cable (30-pin to USB-A)
- Computer (macOS, Windows, or Linux)

### Software
- [Zig 0.15.2](https://ziglang.org/download/) or later
- Git
- ipodpatcher (download links below)

---

## Step 1: Verify Your iPod

First, let's make sure your iPod is compatible and detected.

### Put iPod in Disk Mode

1. Make sure your iPod is **off** (hold Play for a few seconds)
2. Hold **Menu + Select** until you see the Apple logo (~6 seconds)
3. Immediately hold **Select + Play** when the Apple logo appears
4. Wait for "OK to disconnect" screen - you're now in Disk Mode

### Detect Your iPod

```bash
# Clone ZigPod repository
git clone https://github.com/Davidslv/zigpod.git
cd zigpod

# Build and run the detection tool
zig build ipod-detect
./zig-out/bin/ipod-detect -v
```

You should see output like:
```
╔══════════════════════════════════════════════════════════════════════════╗
║              ZigPod iPod Detection Tool (VERBOSE)                        ║
╠══════════════════════════════════════════════════════════════════════════╣
║  Status: iPod DETECTED                                                   ║
╠══════════════════════════════════════════════════════════════════════════╣
║  USB DEVICE INFORMATION                                                  ║
╠══════════════════════════════════════════════════════════════════════════╣
║  Device:        iPod Video 5G/5.5G                                       ║
║  Product ID:    0x1209 (iPod Video 5G/5.5G / Disk Mode)                  ║
║  Serial:        XXXXXXXXXXXX                                             ║
╠══════════════════════════════════════════════════════════════════════════╣
║  PARTITION LAYOUT                                                        ║
╠══════════════════════════════════════════════════════════════════════════╣
║  [   ] 1: Apple_partition_map                                            ║
║  [FW ] 2: Apple_MDFW              (Firmware partition)                   ║
║  [DAT] 3: Apple_HFS               (Data partition)                       ║
╚══════════════════════════════════════════════════════════════════════════╝
```

**Important**: Note your disk device (e.g., `/dev/disk10`). You'll need this later.

---

## Step 2: Create a Full Backup

**This step is critical.** Always backup before installing custom firmware.

### macOS

```bash
# Find your iPod disk number
diskutil list | grep -i ipod

# Create full disk backup (replace diskX with your disk number)
# This may take 10-30 minutes depending on iPod size
sudo dd if=/dev/diskX of=~/ipod_backup_$(date +%Y%m%d).img bs=1m status=progress

# Verify backup was created
ls -lh ~/ipod_backup_*.img
```

### Linux

```bash
# Find your iPod
lsblk | grep -i ipod
# or
sudo fdisk -l | grep -i apple

# Create backup (replace sdX with your device)
sudo dd if=/dev/sdX of=~/ipod_backup_$(date +%Y%m%d).img bs=1M status=progress
```

### Windows

Use [Win32 Disk Imager](https://sourceforge.net/projects/win32diskimager/) to create a full disk image.

---

## Step 3: Download ipodpatcher

ipodpatcher is the Rockbox tool for installing bootloaders on iPods.

### macOS (Apple Silicon)

The Rockbox ipodpatcher binary is 32-bit Intel only. On Apple Silicon Macs, use the pre-built arm64 version in this repo:

```bash
# Use the pre-built arm64 binary
cp tools/ipodpatcher-build/ipodpatcher-arm64 ./ipodpatcher
chmod +x ipodpatcher
```

Or build from source:

```bash
# Download Rockbox source
mkdir -p tools/ipodpatcher-build && cd tools/ipodpatcher-build
curl -L "https://github.com/Rockbox/rockbox/archive/refs/heads/master.zip" -o rockbox.zip
unzip -q rockbox.zip "rockbox-master/utils/ipodpatcher/*"
cd rockbox-master/utils/ipodpatcher

# Build for arm64
clang -o ipodpatcher -Wall -DVERSION='"5.0-zigpod"' \
    main.c ipodpatcher.c ipodio-posix.c arc4.c fat32format.c ipodpatcher-aupd.c \
    -framework IOKit -framework CoreFoundation

# Copy to project root
cp ipodpatcher ../../../ipodpatcher-arm64
cd ../../..
```

### macOS (Intel)

```bash
# Download ipodpatcher (Intel only - won't work on Apple Silicon)
curl -L -o ipodpatcher.dmg https://download.rockbox.org/bootloader/ipod/ipodpatcher/macosx/ipodpatcher.dmg
hdiutil attach ipodpatcher.dmg
cp /Volumes/ipodpatcher/ipodpatcher ./
chmod +x ipodpatcher
hdiutil detach /Volumes/ipodpatcher
```

### Linux

```bash
# 64-bit
wget https://download.rockbox.org/bootloader/ipod/ipodpatcher/linux64amd64/ipodpatcher
chmod +x ipodpatcher

# 32-bit
wget https://download.rockbox.org/bootloader/ipod/ipodpatcher/linux32x86/ipodpatcher
chmod +x ipodpatcher
```

### Windows

Download from: https://download.rockbox.org/bootloader/ipod/ipodpatcher/win32/ipodpatcher.exe

---

## Step 4: Build ZigPod

```bash
# Make sure you're in the zigpod directory
cd zigpod

# Run tests first to verify everything works
zig build test

# Build the bootloader (installs dual-boot capability)
zig build bootloader

# Build the firmware (the actual ZigPod OS)
zig build firmware

# Verify both were built
ls -la zig-out/bin/*.bin
# Should show:
#   zigpod-bootloader.bin  (~600 bytes)
#   zigpod.bin             (~15 KB)
```

---

## Step 5: Install the Bootloader

The bootloader enables dual-boot between ZigPod and the original Apple firmware.

### macOS/Linux

```bash
# Make sure iPod is in Disk Mode

# Find your iPod disk device
diskutil list | grep -A5 "external"
# Look for Apple_partition_scheme - note the disk number (e.g., disk4)

# Unmount the data partition (required to avoid "Resource busy")
diskutil unmount /dev/diskXs3  # Replace X with your disk number

# Install the ZigPod bootloader
# Use -ab flag for raw binary files
sudo ./ipodpatcher /dev/diskX -ab zig-out/bin/zigpod-bootloader.bin
```

You should see:
```
[INFO] Reading partition table from /dev/diskX
[INFO] Ipod model: Video (aka 5th Generation)
[INFO] Reading original firmware...
[INFO] Wrote XXXXXXX bytes to firmware partition
[INFO] Bootloader zig-out/bin/zigpod-bootloader.bin written to device.
```

### Windows

Run Command Prompt as Administrator:
```cmd
ipodpatcher.exe -ab zig-out\bin\zigpod-bootloader.bin
```

---

## Step 6: Copy ZigPod Firmware

The firmware file goes on the iPod's data partition.

### macOS

```bash
# iPod should auto-mount after bootloader install
# If not, unplug and replug the USB cable

# Create ZigPod directory
mkdir -p /Volumes/IPOD/.zigpod

# Copy firmware
cp zig-out/bin/zigpod.bin /Volumes/IPOD/.zigpod/firmware.bin

# Verify
ls -la /Volumes/IPOD/.zigpod/
```

### Linux

```bash
# Mount iPod if not auto-mounted
sudo mount /dev/sdX3 /mnt/ipod

# Create directory and copy
sudo mkdir -p /mnt/ipod/.zigpod
sudo cp zig-out/bin/zigpod.bin /mnt/ipod/.zigpod/firmware.bin

# Unmount
sudo umount /mnt/ipod
```

### Windows

1. Open the iPod drive in File Explorer
2. Create a folder called `.zigpod` in the root
3. Copy `zigpod.bin` into `.zigpod` and rename it to `firmware.bin`

---

## Step 7: Safely Eject and Boot

### Eject the iPod

```bash
# macOS
diskutil eject /dev/diskX

# Linux
sudo eject /dev/sdX
```

On Windows, use "Safely Remove Hardware".

### First Boot

1. Disconnect USB cable
2. Hold **Menu + Select** to reset the iPod
3. Wait for ZigPod to boot

**Expected behavior:**
- ZigPod splash screen appears
- Main menu loads within ~2 seconds
- You can navigate with the click wheel

### Boot Options

| Action | Result |
|--------|--------|
| Normal boot | ZigPod OS |
| Hold **Menu** (2 sec) | Original Apple firmware |
| Hold **Play** (2 sec) | DFU update mode |
| Hold **Menu + Select** (5 sec) | Recovery mode |

---

## Troubleshooting

### ZigPod doesn't boot / Black screen

1. Wait 30 seconds (bootloader has watchdog)
2. If still black, hold Menu + Select to reset
3. Hold Menu during reset to boot Apple firmware
4. Verify `.zigpod/firmware.bin` exists on iPod

### Automatic fallback to Apple firmware

This happens after 3 failed ZigPod boots. It's a safety feature.

1. Boot Apple firmware (it should work)
2. Connect to computer
3. Re-copy `firmware.bin` to `.zigpod/`
4. Try again

### Cannot enter Disk Mode

1. Make sure iPod has charge (>10%)
2. Hard reset: Menu + Select for 10+ seconds
3. Immediately after Apple logo: Select + Play
4. If still failing, connect to power first

### Restore from Backup

If something goes wrong:

```bash
# macOS (replace diskX with your device)
sudo dd if=~/ipod_backup_XXXXXXXX.img of=/dev/diskX bs=1m status=progress

# Linux
sudo dd if=~/ipod_backup_XXXXXXXX.img of=/dev/sdX bs=1M status=progress
```

---

## Uninstallation

To completely remove ZigPod and restore the original firmware:

```bash
# Step 1: Restore original bootloader
sudo ./ipodpatcher -u

# Step 2: Remove ZigPod files (optional)
rm -rf /Volumes/IPOD/.zigpod
```

Your iPod will now boot directly to the original Apple firmware.

---

## Updates

To update ZigPod to a newer version:

```bash
# Pull latest code
cd zigpod
git pull

# Rebuild
zig build firmware

# Copy new firmware (while in Disk Mode)
cp zig-out/bin/zigpod.bin /Volumes/IPOD/.zigpod/firmware.bin
```

No need to reinstall the bootloader unless specifically instructed.

---

## Resources

- [ZigPod Boot Process](hardware/BOOT_PROCESS.md) - Technical boot documentation
- [Rockbox ipodpatcher](https://download.rockbox.org/bootloader/ipod/ipodpatcher/) - Official download page
- [iPod Disk Mode](https://support.apple.com/en-us/102506) - Apple's guide to Disk Mode

---

## Safety Notes

1. **Always backup first** - Full disk images can restore a bricked device
2. **Keep iPod charged** - Low battery during flash can cause issues
3. **Disk Mode always works** - It's in ROM, so recovery is always possible
4. **iTunes can restore** - As a last resort, iTunes can fully restore your iPod

---

*Last updated: 2026-01-10*
