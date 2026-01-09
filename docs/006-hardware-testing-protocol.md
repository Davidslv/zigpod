# Hardware Testing Protocol

This document defines the hardware validation system for ZigPod, ensuring safe testing on real iPod Classic devices.

## Overview

Hardware validation is essential before deploying ZigPod firmware to actual devices. This protocol establishes a layered approach that minimizes risk while maximizing testing coverage.

**Golden Rule**: Never write to flash storage without a verified backup and recovery plan.

---

## Important: JTAG Not Available on iPod Classic 5.5G

**The 30-pin dock connector does NOT expose JTAG signals.** The dock handles:
- USB data/sync
- Charging
- Analog audio line-out
- Accessory protocols

JTAG (CPU debug interface) is NOT routed to any accessible pins on the iPod Classic 5.5G. This means:
- ❌ No live CPU debugging/stepping
- ❌ No memory inspection during execution
- ❌ No register dumps while running
- ✅ USB Disk Mode access only
- ✅ Persistent logging to disk
- ✅ Post-mortem crash analysis

**All debugging must use USB Disk Mode and persistent logs.**

---

## USB-Based Debugging Workflow

Since JTAG isn't available, ZigPod uses disk-based telemetry for debugging.

### Log Files Location

When running ZigPod, logs are written to:
```
/ZIGPOD/
└── LOGS/
    ├── telemetry.bin    # Binary event buffer (for zigpod-telemetry tool)
    ├── crash.log        # Human-readable crash info (if crash occurred)
    ├── boot.log         # Boot sequence log
    └── session.txt      # Runtime text log
```

### Debugging Workflow

**Step 1: Run ZigPod on Hardware**
```
1. Install ZigPod firmware
2. Boot into ZigPod
3. Use the device, trigger the issue
4. Observe any error indicators in status bar
```

**Step 2: Extract Logs via USB**
```bash
# Force reboot into Apple firmware
# Hold Menu + Select for 8 seconds

# Connect USB cable
# iPod mounts as disk

# Copy log files
cp /Volumes/IPOD/ZIGPOD/LOGS/* ~/zigpod-debug/

# Or if using Linux
cp /media/ipod/ZIGPOD/LOGS/* ~/zigpod-debug/
```

**Step 3: Analyze Logs**
```bash
# Parse telemetry
./zigpod-telemetry analyze ~/zigpod-debug/telemetry.bin

# View crash log (if exists)
cat ~/zigpod-debug/crash.log

# View session log
cat ~/zigpod-debug/session.txt
```

**Step 4: Share for Troubleshooting**
```
When reporting issues, include:
1. Output of: zigpod-telemetry analyze telemetry.bin
2. Contents of crash.log (if exists)
3. Last 100 lines of session.txt
4. Steps to reproduce the issue
```

### What Gets Logged

| Category | Events Captured |
|----------|-----------------|
| **Boot** | Start, complete, boot count |
| **Audio** | Init, play, stop, underruns, decode errors |
| **Storage** | ATA reads, timeouts, FAT32 errors |
| **UI** | Screen changes, button presses |
| **Power** | Battery level, charging, sleep |
| **Errors** | All error codes with context |
| **Crashes** | PC, LR, SP registers, panic message |

### Crash Log Example

If ZigPod crashes, `crash.log` contains:
```
=== ZIGPOD CRASH LOG ===

Boot: #7

Registers:
  PC:   0x40001234
  LR:   0x40001220
  SP:   0x40050FF0
  CPSR: 0x600000D3

Message: Division by zero in audio_decode

To debug:
  1. Note the PC address above
  2. Run: arm-none-eabi-addr2line -e zigpod.elf 0x40001234
  3. This shows the source file and line

Telemetry saved to: /ZIGPOD/LOGS/telemetry.bin
```

### Converting PC Address to Source Line

```bash
# If you have the ELF file with debug symbols
arm-none-eabi-addr2line -e zig-out/bin/zigpod.elf 0x40001234

# Output example:
# /Users/you/zigpod/src/audio/dsp.zig:156
```

---

## Real-Time Logging via USB CDC

When the iPod is connected to a computer AND running ZigPod, you can stream
logs in real-time over USB. The iPod appears as a virtual serial port.

### Connecting to the Debug Console

**macOS:**
```bash
# Find the device
ls /dev/tty.usbmodem*

# Connect (115200 baud)
screen /dev/tty.usbmodem* 115200

# Or use the ZigPod tool
./zigpod-serial --port /dev/tty.usbmodem*
```

**Linux:**
```bash
# Find the device
ls /dev/ttyACM*

# Connect
screen /dev/ttyACM0 115200

# Or use minicom
minicom -D /dev/ttyACM0 -b 115200
```

**Windows:**
- Open Device Manager, find the COM port
- Use PuTTY with that COM port at 115200 baud

### Debug Console Commands

Once connected, you can type commands:

| Command | Description |
|---------|-------------|
| `help` | Show available commands |
| `status` | Show system status |
| `battery` | Show battery info |
| `audio` | Show audio engine status |
| `errors` | Show error log |
| `clear` | Clear error state |
| `reboot` | Reboot device |

### Log Output Format

```
[    1234] INFO  [AUD] Audio engine started at 44100Hz
[    1235] DEBUG [STO] Reading sector 12345
[    1240] WARN  [PWR] Battery low: 15%
[    1250] ERROR [AUD] Buffer underrun detected
```

Format: `[timestamp_ms] LEVEL [CATEGORY] Message`

### Log Levels

| Level | Description | Destinations |
|-------|-------------|--------------|
| TRACE | Verbose debug | CDC only (if enabled) |
| DEBUG | Detailed info | CDC + Disk |
| INFO | Normal events | CDC + Disk |
| WARN | Potential issues | CDC + Disk + Telemetry |
| ERROR | Failures | CDC + Disk + Telemetry |
| FATAL | Unrecoverable | CDC + Disk + Crash Store |

---

## Persistent Crash Store

Critical failures are stored in a reserved area of the disk that survives
reboots. This allows post-mortem analysis of crashes that occur when not
connected to a computer.

### What Gets Stored

Each crash entry contains:
- Boot count when crash occurred
- CPU registers (PC, LR, SP, CPSR, R0-R12)
- Exception type (panic, data abort, undefined instruction, etc.)
- Error code
- Human-readable message
- Timestamp (if RTC available)

### Crash Recovery Workflow

1. **Crash occurs** → Crash handler saves state to reserved disk area
2. **Device reboots** (or user power cycles)
3. **Next boot** → ZigPod detects pending crashes, shows warning
4. **Connect USB** → Access crash logs via /ZIGPOD/LOGS/crashes/
5. **Analyze** → Use crash report with `addr2line` to find source location

### Viewing Crash History

When connected via USB CDC:
```
> errors
=== ZigPod Crash Report ===
Total crashes recorded: 2
Entries in store: 2/16

--- Crash #1 ---
Boot: #5
Type: data_abort
Error: 0x00000000

Registers:
  PC:   0x40001234
  LR:   0x40001220
  SP:   0x40050000
  CPSR: 0x600000D3

Message: Invalid memory access in audio_decode
```

### Exporting Crash Data

Via USB Disk Mode:
```bash
# Copy crash store binary
cp /Volumes/IPOD/ZIGPOD/LOGS/crashes.bin ~/debug/

# Parse with tool
./zigpod-crash-parser ~/debug/crashes.bin
```

---

## Validation Levels

### Level 1: Read-Only Testing

**Risk**: None
**Requirements**: JTAG adapter, iPod in Disk Mode
**Recovery**: Not needed (no modifications made)

Read-only testing validates the JTAG connection and allows exploration of hardware state without any risk of damage.

**Operations**:
- Memory dumps via JTAG
- CPU register reads
- Peripheral register inspection
- Flash content verification
- Hardware identification

**Tools**:
```bash
# Connect and identify device
zigpod-jtag identify

# Dump memory region
zigpod-jtag dump --addr 0x40000000 --size 0x18000 --output iram.bin

# Read CPU registers
zigpod-jtag regs

# Read peripheral state
zigpod-jtag peek 0x60006000  # GPIO registers
zigpod-jtag peek 0x60007000  # I2C registers
```

**Verification Checklist**:
- [ ] JTAG connects successfully
- [ ] Device ID matches expected PP5021C
- [ ] Can read IRAM (0x40000000-0x40018000)
- [ ] Can read DRAM (0x10000000-0x12000000)
- [ ] CPU halts and resumes correctly
- [ ] Register reads return sane values

---

### Level 2: RAM-Only Testing

**Risk**: Low (device reset clears all changes)
**Requirements**: JTAG adapter, working device
**Recovery**: Power cycle device

RAM-only testing loads code and data into RAM without modifying persistent storage. All changes are lost on power cycle.

**Operations**:
- Load test programs to IRAM
- Execute from RAM via JTAG
- Hardware interaction tests
- Driver validation
- Audio output testing

**Tools**:
```bash
# Load test program to IRAM
zigpod-jtag load --addr 0x40000000 --file test_program.bin

# Execute from address
zigpod-jtag run --addr 0x40000100

# Load and run with watchdog
zigpod-jtag test --file led_blink.bin --timeout 10s
```

**Test Programs**:
1. **LED/Backlight Test**: Toggle LCD backlight to verify GPIO control
2. **Button Test**: Read click wheel and verify button mapping
3. **Audio Test**: Output test tone to verify I2S and codec setup
4. **Display Test**: Draw patterns to verify LCD controller
5. **ATA Test**: Read disk sectors (read-only) to verify ATA timing

**Verification Checklist**:
- [ ] Test program loads successfully
- [ ] CPU executes from IRAM
- [ ] GPIO control works (backlight toggles)
- [ ] Click wheel input detected
- [ ] Audio output produces correct tone
- [ ] LCD displays test pattern
- [ ] ATA read returns valid data

---

### Level 3: Non-Persistent Boot

**Risk**: Medium (requires working bootloader)
**Requirements**: JTAG adapter, Disk Mode access
**Recovery**: Power cycle, then Disk Mode boot

Non-persistent testing boots custom firmware from RAM without modifying the flash bootloader. The original firmware remains intact.

**Operations**:
- Boot full ZigPod OS from RAM
- Full system integration testing
- File system access (read-only recommended)
- Audio playback testing
- UI/UX validation

**Procedure**:
1. Put device in Disk Mode
2. Connect via JTAG
3. Halt CPU
4. Load ZigPod image to DRAM (0x10000000)
5. Set PC to entry point
6. Resume execution

```bash
# Full boot from RAM
zigpod-jtag boot --image zigpod-ram.bin --entry 0x10000100

# Boot with serial console
zigpod-jtag boot --image zigpod-ram.bin --console
```

**Verification Checklist**:
- [ ] ZigPod boots successfully
- [ ] UI renders correctly
- [ ] Music library scans
- [ ] Audio playback works
- [ ] Button navigation functional
- [ ] Device doesn't hang or crash
- [ ] Power management works

---

### Level 4: Persistent Installation

**Risk**: High (modifies device storage)
**Requirements**: Verified backup, sacrificial device first
**Recovery**: iTunes/Finder restore, or backup restore

Persistent installation writes ZigPod to the device's flash storage. This is the final deployment step.

**CRITICAL REQUIREMENTS**:
1. **Complete Level 1-3 testing on this specific device**
2. **Full backup created and verified**
3. **Restore procedure tested on another device**
4. **Sacrificial device tested first (if available)**

**Pre-Installation Checklist**:
- [ ] Full iTunesDB backup created
- [ ] Backup checksum recorded
- [ ] Backup restore tested on same/different device
- [ ] Level 3 boot successful on this device
- [ ] All hardware tests pass
- [ ] Emergency restore procedure documented

**Installation Procedure**:
```bash
# 1. Create comprehensive backup
zigpod-flasher backup --device /dev/disk2 --output backup-$(date +%Y%m%d).img

# 2. Verify backup
zigpod-flasher verify --backup backup-20250108.img

# 3. Install ZigPod (requires confirmation)
zigpod-flasher install --image zigpod-1.0.bin --device /dev/disk2

# 4. Post-install verification
zigpod-flasher check --device /dev/disk2
```

**Post-Installation Checklist**:
- [ ] Device boots into ZigPod
- [ ] Original music library accessible
- [ ] Audio playback working
- [ ] All buttons functional
- [ ] Battery status correct
- [ ] No crashes during 1-hour test

---

## Safety Features

### Automatic Backup

The flasher tool automatically creates a backup before any write operation:

```zig
// From src/tools/flasher/flasher.zig
pub fn install(self: *Flasher, image: []const u8) !void {
    // Always backup first
    try self.backup.create();

    // Verify backup integrity
    try self.backup.verify();

    // Proceed with installation
    try self.writeImage(image);
}
```

### Checksum Verification

All operations include checksum verification:

- Pre-flash: Image CRC32 verified
- Post-flash: Written data verified against source
- Backup: SHA256 hash stored with backup

### Protected Regions

The flasher refuses to modify protected regions:

| Region | Address | Protection |
|--------|---------|------------|
| Boot ROM | 0x00000000-0x0000FFFF | Never modify |
| Apple bootloader | Sector 0-63 | Requires explicit override |
| Partition table | LBA 0 | Checksum verified before write |

### Abort with Rollback

If any error occurs during installation, the flasher automatically attempts rollback:

```bash
# Installation with automatic rollback on error
zigpod-flasher install --image zigpod.bin --auto-rollback

# If interrupted, restore from backup
zigpod-flasher restore --backup backup-20250108.img
```

---

## Hardware Requirements

### JTAG Adapter

Recommended: FT2232H-based adapter

**Pinout** (iPod 30-pin connector):

| Pin | Signal | FT2232H Pin |
|-----|--------|-------------|
| 11 | TCK | ADBUS0 |
| 13 | TDI | ADBUS1 |
| 15 | TDO | ADBUS2 |
| 17 | TMS | ADBUS3 |
| 23 | SRST | ADBUS4 |
| 29 | GND | GND |

### Custom Dock Connector

A custom dock connector cable is required for JTAG access. The standard 30-pin connector includes JTAG signals but requires breakout to standard 0.1" header.

**Cable Assembly**:
1. 30-pin dock connector (salvaged or purchased)
2. 2x5 0.1" header for standard ARM JTAG
3. Ribbon cable (6" max for signal integrity)

---

## Recovery Procedures

### Method 1: Disk Mode USB Restore

If the device still enters Disk Mode:

```bash
# Connect device in Disk Mode (hold Menu+Select, then Menu+Play)

# Restore from backup
zigpod-flasher restore --backup backup.img

# Or use iTunes/Finder restore
# (This restores original Apple firmware)
```

### Method 2: iTunes/Finder Restore

Full restore to factory firmware:

1. Connect device to computer
2. Put device in recovery mode (Menu+Select for 8s, then Select+Play)
3. iTunes/Finder will detect "iPod in recovery mode"
4. Click "Restore" to reinstall original firmware

**Note**: This erases all music and settings but restores device to working state.

---

## Testing Protocol Summary

| Level | Risk | Persistence | Recovery | Use Case |
|-------|------|-------------|----------|----------|
| 1. Read-Only | None | None | N/A | Initial validation |
| 2. RAM-Only | Low | Until reset | Power cycle | Driver testing |
| 3. Non-Persistent | Medium | Until reset | Power cycle | Integration testing |
| 4. Persistent | High | Permanent | Restore backup | Deployment |

**Recommended Progression**:
1. Complete Level 1 on all test devices
2. Complete Level 2-3 on primary test device
3. Complete Level 4 on sacrificial device first
4. If successful, proceed to valuable devices

---

## Emergency Contacts

If you encounter an unrecoverable situation:

1. **iPod Linux Forums**: Community support for iPod hacking
2. **Rockbox Forums**: Alternative firmware community with recovery experience
3. **Apple Support**: Last resort for hardware issues

---

## Changelog

- **v1.0** (2025-01-08): Initial protocol documentation
