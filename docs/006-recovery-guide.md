# ZigPod Recovery and Troubleshooting Guide

**Version**: 1.0
**Last Updated**: 2026-01-08
**Status**: CRITICAL SAFETY DOCUMENT

---

## Table of Contents

1. [Before You Start Development](#1-before-you-start-development)
2. [iPod Boot Modes](#2-ipod-boot-modes)
3. [Recovery Procedures](#3-recovery-procedures)
4. [Troubleshooting Common Issues](#4-troubleshooting-common-issues)
5. [Hardware Testing Safety](#5-hardware-testing-safety)
6. [Emergency Contacts and Resources](#6-emergency-contacts-and-resources)

---

## 1. Before You Start Development

### 1.1 Required Equipment

Before writing ANY code to real hardware:

| Item | Quantity | Purpose | Est. Cost |
|------|----------|---------|-----------|
| iPod Video 5G (working) | 2+ | Test units, one backup | $50-100 each |
| iPod Video 5G (broken) | 1 | Parts/sacrifice unit | $20-40 |
| USB Dock Cable | 2 | Connectivity | $10 |
| Computer with iTunes | 1 | Emergency restore | - |
| SD Card + iFlash | 1 | Fast, safe storage testing | $50 |
| JTAG Debugger (optional) | 1 | Advanced debugging | $60+ |

### 1.2 Pre-Development Checklist

**COMPLETE ALL ITEMS BEFORE WRITING CODE:**

- [ ] **Backup iPod available** - Never test on your only device
- [ ] **iTunes installed** - Required for emergency restore
- [ ] **Original firmware backup** - Use Rockbox Utility to dump
- [ ] **Disk Mode tested** - Verify SELECT + PLAY works
- [ ] **Diagnostic Mode tested** - Verify SELECT + REWIND works
- [ ] **USB connection verified** - Ensure computer sees iPod
- [ ] **Battery charged** - At least 50% before testing

### 1.3 Development Rules

```
┌─────────────────────────────────────────────────────────────┐
│                    GOLDEN RULES                              │
├─────────────────────────────────────────────────────────────┤
│  1. NEVER flash boot ROM - it cannot be recovered           │
│  2. ALWAYS test in emulator first                           │
│  3. ALWAYS verify Disk Mode works before testing            │
│  4. NEVER test PMU changes without Rockbox reference        │
│  5. ALWAYS have iTunes ready for restore                    │
│  6. NEVER continue if something seems wrong                 │
└─────────────────────────────────────────────────────────────┘
```

---

## 2. iPod Boot Modes

### 2.1 Normal Boot

**How it works**: iPod loads firmware from disk, boots normally.

**Entry**: Power on without holding any buttons.

### 2.2 Disk Mode

**What it is**: USB mass storage mode - iPod appears as external drive.

**Entry Method**:
1. Reset iPod (MENU + SELECT for 10 seconds)
2. When Apple logo appears, IMMEDIATELY hold SELECT + PLAY
3. Hold until "Do not disconnect" appears
4. iPod will mount as USB drive

**Use cases**:
- File system access
- Firmware file manipulation
- Emergency recovery starting point

**Screen appearance**: "Do not disconnect" or USB icon

### 2.3 Diagnostic Mode

**What it is**: Built-in hardware test suite.

**Entry Method**:
1. Reset iPod (MENU + SELECT for 10 seconds)
2. When Apple logo appears, IMMEDIATELY hold SELECT + REWIND (<<)
3. Hold until diagnostic menu appears

**Available Tests**:
- 5 IN 1 (quick hardware check)
- SDRAM test
- Flash test
- Wheel test
- Audio test
- HDD test
- USB test

**Use cases**:
- Verify hardware is functional
- Check for damage after bad flash
- Get device information

### 2.4 Apple Restore Mode

**What it is**: iTunes recovery mode for firmware restore.

**Entry Method**:
1. Connect iPod to computer with USB
2. Reset iPod (MENU + SELECT)
3. Continue holding until iTunes detects "iPod in recovery mode"

**Use cases**:
- Restore original Apple firmware
- Fix corrupted firmware
- Remove custom firmware

### 2.5 DFU Mode (iPod Classic 6G+ ONLY)

**IMPORTANT**: iPod Video 5th Generation does **NOT** have DFU mode!

DFU mode only exists on:
- iPod Nano 3rd generation and later
- iPod Classic 6th generation and later

**Do NOT attempt DFU procedures on iPod Video 5G.**

---

## 3. Recovery Procedures

### 3.1 Scenario: iPod Won't Boot (Shows Apple Logo, Then Sad iPod)

**Likely cause**: Corrupted firmware or disk issue.

**Recovery steps**:
1. Enter Disk Mode (SELECT + PLAY during reset)
2. If successful:
   - Connect to computer
   - Check if iPod mounts as drive
   - If mounted, backup important files
3. Use iTunes to restore:
   - Open iTunes
   - Select iPod in sidebar
   - Click "Restore iPod"
   - Wait for restore to complete

### 3.2 Scenario: iPod Stuck at Apple Logo

**Likely cause**: Firmware boot loop.

**Recovery steps**:
1. Perform hard reset (MENU + SELECT, 10+ seconds)
2. Immediately enter Disk Mode (SELECT + PLAY)
3. If Disk Mode works:
   - Restore via iTunes
4. If Disk Mode fails:
   - Try again (timing is critical)
   - Try with different USB cable
   - Try on different computer

### 3.3 Scenario: iPod Shows Folder/Exclamation Icon

**Likely cause**: iPod can't find firmware on disk.

**Recovery steps**:
1. Enter Disk Mode
2. Connect to iTunes
3. iTunes will offer to restore
4. If that fails, may need disk replacement

### 3.4 Scenario: iPod Won't Turn On At All

**Possible causes**:
- Dead battery
- Hardware failure
- Corrupted boot ROM (unrecoverable)

**Recovery steps**:
1. Connect to power/USB for 30+ minutes
2. Try hard reset
3. Try with known-good USB cable
4. If still dead:
   - Try different power source
   - Battery may need replacement
   - If battery replacement doesn't help, hardware may be damaged

### 3.5 Scenario: iPod Boots But Crashes in Custom Firmware

**Recovery steps**:
1. Enter Disk Mode BEFORE custom firmware loads
   - This requires perfect timing
   - Reset and immediately hold SELECT + PLAY
2. Once in Disk Mode:
   - Remove or rename custom firmware files
   - Or restore via iTunes

### 3.6 Scenario: Rockbox/Custom Bootloader Corrupted

**If dual-boot is installed**:
1. Boot while holding a specific button (varies by bootloader)
2. May boot to Apple firmware instead
3. From Apple firmware, can access Disk Mode normally

**If single-boot custom**:
1. Enter Disk Mode during very early boot
2. Replace bootloader files
3. Or restore via iTunes

---

## 4. Troubleshooting Common Issues

### 4.1 "iTunes doesn't see my iPod"

**Checklist**:
- [ ] Is iPod in Disk Mode or Recovery Mode?
- [ ] Is USB cable working? (try different cable)
- [ ] Is USB port working? (try different port)
- [ ] Is iTunes up to date?
- [ ] On macOS Catalina+: Use Finder instead of iTunes

**Solutions**:
1. Try different USB cable
2. Try different USB port (use rear ports on desktop)
3. Try different computer
4. Reset iPod while connected

### 4.2 "iPod mounts but can't be written to"

**Possible cause**: File system corruption.

**Solutions**:
1. Run disk check utility:
   - macOS: Disk Utility > First Aid
   - Windows: Right-click drive > Properties > Tools > Check
2. If check fails, iTunes restore will reformat

### 4.3 "Diagnostic mode shows errors"

**Common error meanings**:
- **SDRAM FAIL**: Memory hardware issue
- **HDD FAIL**: Hard drive dying or connection issue
- **FLASH FAIL**: Flash memory issue (less common)

**Solutions**:
- SDRAM fail: Hardware repair needed
- HDD fail: Try reseating connector, or replace drive
- Flash fail: May be repairable, may need hardware repair

### 4.4 "Custom firmware causes crashes"

**Debug approach**:
1. Identify exactly when crash occurs
2. Check if it's initialization related
3. Compare your code against Rockbox reference
4. Verify PMU values match Rockbox exactly
5. Check clock configuration

**Quick fix**:
1. Boot to Disk Mode
2. Remove custom firmware
3. Restore to known-good state

### 4.5 "Audio not working"

**Checklist**:
- [ ] Is codec initialized correctly?
- [ ] Is I2S configured?
- [ ] Are outputs unmuted?
- [ ] Is volume set?
- [ ] Is PMU providing codec power?

**Debug steps**:
1. Check I2C communication to WM8758
2. Verify register values match Rockbox
3. Check I2S FIFO status
4. Measure audio output with oscilloscope if available

---

## 5. Hardware Testing Safety

### 5.1 Safe Testing Progression

```
┌─────────────────────────────────────────────────────────────┐
│                    TESTING PROGRESSION                       │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  Level 1: Host Testing (No Hardware)                        │
│  ├── Unit tests with mocked HAL                             │
│  ├── Logic verification                                      │
│  └── No risk                                                 │
│                                                              │
│  Level 2: Simulator Testing                                  │
│  ├── Full system simulation                                  │
│  ├── Peripheral emulation                                    │
│  └── No risk                                                 │
│                                                              │
│  Level 3: JTAG Debugging (Optional)                          │
│  ├── Step-through execution                                  │
│  ├── Memory inspection                                       │
│  └── Low risk (can halt before damage)                       │
│                                                              │
│  Level 4: RAM-Only Testing                                   │
│  ├── Load code to RAM via JTAG                              │
│  ├── Don't modify flash/disk                                 │
│  └── Medium risk (can recover by reset)                      │
│                                                              │
│  Level 5: Full Hardware Testing                              │
│  ├── Flash bootloader/firmware                               │
│  ├── Modify disk contents                                    │
│  └── Higher risk (may need restore)                          │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### 5.2 Before Each Hardware Test

**Pre-Test Checklist**:
- [ ] Simulator tests pass
- [ ] Code reviewed for PMU safety
- [ ] Disk Mode entry verified
- [ ] iTunes restore tested recently
- [ ] Backup iPod available
- [ ] Battery above 50%

### 5.3 During Hardware Test

**Safety Protocol**:
1. Set a timer - don't let device run unattended
2. Monitor for:
   - Excessive heat
   - Display corruption
   - Audio noise/distortion
   - Unresponsive buttons
3. If ANYTHING seems wrong:
   - Immediately hard reset (MENU + SELECT)
   - Enter Disk Mode
   - Evaluate before continuing

### 5.4 After Hardware Test

**Post-Test Protocol**:
1. Verify device still boots normally
2. Verify Disk Mode still works
3. Run diagnostic tests
4. Document any issues encountered

---

## 6. Emergency Contacts and Resources

### 6.1 Online Resources

| Resource | URL | Use For |
|----------|-----|---------|
| Rockbox Forums | forums.rockbox.org | Community help |
| iFixit iPod Guide | ifixit.com/Device/iPod | Hardware repair |
| freemyipod.org | freemyipod.org | Recovery tools |
| r/IpodClassic | reddit.com/r/IpodClassic | Community support |

### 6.2 Recovery Tools

| Tool | Source | Purpose |
|------|--------|---------|
| iTunes | Apple | Official restore |
| Rockbox Utility | rockbox.org | Bootloader install/remove |
| ipodpatcher | Rockbox | Low-level access |
| iFlash tools | iflash.xyz | Storage mod support |

### 6.3 Hardware Repair

If software recovery fails:

1. **Battery replacement**: iFixit has guides
2. **Hard drive replacement**: Common fix, many guides available
3. **Logic board repair**: Specialist repair shops
4. **Click wheel replacement**: iFixit guide

### 6.4 When to Seek Help

Seek community help if:
- Multiple restore attempts fail
- Hardware diagnostics show errors
- Device shows unusual behavior
- You're unsure about next steps

**DO NOT** continue experimenting if you don't understand what went wrong.

---

## Appendix A: Quick Reference Card

```
┌─────────────────────────────────────────────────────────────┐
│           iPOD VIDEO 5G QUICK REFERENCE                     │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  HARD RESET:     Hold MENU + SELECT for 10 seconds          │
│                                                              │
│  DISK MODE:      During reset, hold SELECT + PLAY           │
│                  (when Apple logo appears)                   │
│                                                              │
│  DIAGNOSTIC:     During reset, hold SELECT + REWIND         │
│                  (when Apple logo appears)                   │
│                                                              │
│  RECOVERY:       Connect USB, reset, iTunes detects         │
│                                                              │
│  NO DFU MODE:    5th Gen does NOT support DFU               │
│                                                              │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  IF STUCK:                                                   │
│  1. Hard reset                                               │
│  2. Try Disk Mode                                            │
│  3. Try iTunes restore                                       │
│  4. Ask for help                                             │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

---

## Appendix B: Development Workflow Diagram

```
     ┌──────────────┐
     │ Write Code   │
     └──────┬───────┘
            │
            ▼
     ┌──────────────┐
     │ Unit Tests   │◄─────────────┐
     └──────┬───────┘              │
            │                       │
            │ Pass?                 │ Fail
            ▼                       │
     ┌──────────────┐              │
     │ Simulator    │──────────────┘
     └──────┬───────┘
            │
            │ Pass?
            ▼
     ┌──────────────┐
     │ Code Review  │──── Concerns? ──► Fix Issues
     └──────┬───────┘
            │
            │ Approved
            ▼
     ┌──────────────┐
     │ Disk Mode    │──── Fails? ──► DO NOT PROCEED
     │ Test         │
     └──────┬───────┘
            │
            │ Works
            ▼
     ┌──────────────┐
     │ Hardware     │──── Problems? ──► Hard Reset
     │ Test         │                   └──► Disk Mode
     └──────┬───────┘                       └──► Evaluate
            │
            │ Success
            ▼
     ┌──────────────┐
     │ Document     │
     │ & Commit     │
     └──────────────┘
```

---

**Document Version History**

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2026-01-08 | Initial recovery guide |
