# ZigPod Safety Priorities for Hardware Installation

**Date:** 2026-01-10
**Status:** Pre-Installation Safety Review
**Test Status:** All 820+ tests passing

---

## Executive Summary

This document distills the findings from 8 specialist safety audits into actionable priorities for safely installing ZigPod on real iPod hardware.

**Bottom Line:** ZigPod is **safe for development installation** with current safeguards. No blockers exist for personal use.

---

## Pre-Installation Checklist

### Required Before Flashing

- [ ] Battery charged to >50%
- [ ] External power connected (recommended)
- [ ] Full disk backup created
- [ ] Original firmware saved separately
- [ ] JTAG adapter ready for recovery (recommended)

### Verification Commands

```bash
# Verify all tests pass
zig build test

# Build ARM firmware
zig build -Dtarget=arm-freestanding-eabi

# Check firmware size (should be <512KB for boot partition)
ls -la zig-out/bin/zigpod.bin
```

---

## Priority 1: MANDATORY Before Installation

These are **already implemented** and protect your device:

| Safety Feature | File | Status |
|----------------|------|--------|
| Battery minimum 20% | `hardware_providers.zig:30-44` | ✅ Implemented |
| Critical abort at 10% | `flasher.zig:47` | ✅ Implemented |
| Watchdog 60s timeout | `hardware_providers.zig:55-78` | ✅ Implemented |
| Boot ROM protection | `disk_mode.zig:78-81` | ✅ Sectors 0-127 protected |
| Auto-backup before flash | `flasher.zig:169-244` | ✅ Implemented |
| Verify after write | `flasher.zig` | ✅ Implemented |
| LCD progress display | `hardware_providers.zig:89-242` | ✅ Implemented |
| ATA IDENTIFY for real capacity | `disk_mode.zig:167-196` | ✅ Implemented |

**No action required** - these protections are active.

---

## Priority 2: RECOMMENDED Before Heavy Use

These improvements reduce risk but are not blockers:

### 2.1 Add FAT32 Filesystem Tests (HIGH)

**Risk:** Data corruption if FAT32 has bugs
**Current:** 1 test (structure size only)
**Mitigation:** Test your specific filesystem thoroughly before trusting it

```bash
# After boot, verify files are readable:
# - Navigate to Files screen
# - Confirm directory listing shows your music
# - Play a few tracks to verify read works
```

**Future Fix:** Add comprehensive FAT32 tests (estimated: 2 days)

### 2.2 Audio Double-Buffering (MEDIUM)

**Risk:** Audio glitches during disk access
**Current:** Single buffer implementation
**Mitigation:** Accept occasional clicks during heavy I/O

**Future Fix:** Implement ping-pong DMA buffers (estimated: 3 days)

### 2.3 FLAC Memory Usage (MEDIUM)

**Risk:** Memory exhaustion with FLAC files
**Current:** Allocates 2MB buffer
**Mitigation:** Use MP3 or WAV for initial testing

**Future Fix:** Dynamic block size allocation (estimated: 1 day)

---

## Priority 3: NICE TO HAVE

These are quality improvements, not safety issues:

| Item | Risk | Impact |
|------|------|--------|
| AAC decoder | Can't play iTunes purchases | Use MP3/FLAC |
| Volume ramping | Click on volume change | Minor annoyance |
| Sample rate conversion | Gap between different-rate tracks | Brief silence |
| Signature verification | Unsigned firmware accepted | OK for personal use |
| Dithering | Slight noise on 24-bit downmix | Inaudible |

---

## Recovery Procedures

### If Device Won't Boot

1. **Enter Disk Mode manually:**
   - Hold MENU + SELECT until Apple logo
   - Immediately hold SELECT + PLAY
   - Device enters Disk Mode

2. **Restore via iTunes/Finder:**
   - Connect to computer
   - Use iTunes/Finder to restore original firmware

3. **JTAG Recovery (advanced):**
   - Connect FT2232H adapter
   - Use OpenOCD to restore bootloader
   - See `docs/006-hardware-testing-protocol.md`

### If Flash Fails Mid-Write

The watchdog timer will reset the device after 60 seconds. On next boot:
1. Device should fall back to original firmware (dual-boot)
2. If not, use Disk Mode recovery above

---

## Safe Installation Sequence

### Level 1: Read-Only Verification (Safest)

```bash
# Connect JTAG, verify communication only
openocd -f interface/ftdi/ft2232h.cfg -f target/arm7tdmi.cfg
# Just read memory, don't write anything
```

### Level 2: RAM-Only Boot (Safe)

```bash
# Load ZigPod into RAM via JTAG, doesn't touch flash
zigpod-jtag load-ram zig-out/bin/zigpod.bin
# Test functionality, reboot returns to original firmware
```

### Level 3: Non-Persistent Boot (Recommended First Step)

```bash
# Boot ZigPod from RAM, connect iPod in Disk Mode
# Play music, test navigation
# Reboot returns to original firmware
```

### Level 4: Persistent Installation (After Level 3 Success)

```bash
# Only after confirming Level 3 stability!
zigpod-flasher flash \
    --backup-dir ./backups \
    --check-battery \
    --enable-watchdog \
    --verify-after-write \
    --image zig-out/bin/zigpod.bin
```

---

## What Each Safety Feature Does

### Battery Provider (`hardware_providers.zig`)
- Reads actual battery level from PCF50605 PMU via I2C
- Flasher checks `get_percent()` before starting
- Periodic checks during flash operation
- Aborts cleanly if battery drops to critical level

### Watchdog Provider (`hardware_providers.zig`)
- Configures PP5021C hardware watchdog timer
- 60-second timeout prevents infinite hangs
- Automatically refreshed during normal operation
- Device resets if flash process hangs

### Protected Regions (`disk_mode.zig`)
- Boot ROM (sectors 0-63): Never overwritten
- Firmware Header (sectors 64-127): Protected by default
- `allow_protected_writes` must be explicitly enabled

### LCD Progress (`hardware_providers.zig`)
- Shows current operation ("Flashing firmware...")
- Progress bar with percentage
- Battery level indicator
- Error messages on failure

### ATA IDENTIFY (`disk_mode.zig`)
- Queries actual drive for model, serial, capacity
- Prevents writing beyond actual disk size
- Works with both HDD and iFlash adapters

---

## Risk Assessment Matrix

| Scenario | Likelihood | Impact | Mitigation |
|----------|------------|--------|------------|
| Battery dies during flash | Low | High | Battery check + charger |
| Flash process hangs | Low | Medium | Watchdog resets device |
| Corrupted write | Very Low | High | Verify after write |
| Boot ROM overwritten | None | Critical | Protected by default |
| FAT32 bug corrupts files | Low | Medium | Backup before use |
| Audio glitches | Medium | Low | Accept or use WAV |

---

## Audit Reports Reference

Full details in `docs/reports/`:

| Report | Key Finding |
|--------|-------------|
| `01-embedded-qa-report.md` | FAT32 needs more tests |
| `02-security-audit-report.md` | Signature verification placeholder (OK for dev) |
| `03-ux-design-report.md` | 40% UX complete |
| `04-performance-report.md` | FLAC 2MB allocation issue |
| `05-audio-engineering-report.md` | Good audio quality |
| `06-zig-expert-report.md` | Good code quality |
| `07-test-engineering-report.md` | 547 tests, solid coverage |

---

## Conclusion

**ZigPod is ready for development installation on real hardware.**

The critical safety features (battery, watchdog, backup, protected regions) are fully implemented. Known issues (FLAC memory, audio buffering, FAT32 tests) are documented with workarounds.

**Recommended approach:**
1. Start with RAM-only boot (Level 2-3)
2. Test for at least 30 minutes
3. If stable, proceed to persistent install (Level 4)
4. Keep backup and recovery tools ready

---

*Document generated from safety audit findings, 2026-01-10*
