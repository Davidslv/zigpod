# ZigPod Emulator - Master Plan

**Last Updated**: 2026-01-13
**Status**: IN PROGRESS - Path string construction issue

---

## GOAL

Get the iPod Video 5th Gen (PP5021C) emulator running with functional firmware that displays on LCD.

**Success Criteria**:
1. Rockbox firmware loads and displays its UI on the emulated LCD
2. OR Apple firmware boots past RTOS scheduler to display something

---

## CURRENT APPROACH: Rockbox Bootloader → rockbox.ipod

We're using the Rockbox bootloader because:
- Apple firmware gets stuck in RTOS scheduler loop (requires complex IRQ/task setup)
- Rockbox bootloader is simpler, already shows LCD output
- Once bootloader works, it can load either Rockbox OR Apple firmware

---

## WHAT WORKS (DO NOT RE-INVESTIGATE)

| Component | Status | Evidence |
|-----------|--------|----------|
| CPU emulation | Working | Bootloader executes, branches, loops work |
| Memory map | Working | IRAM, SDRAM, peripherals all accessible |
| LCD output | Working | 320x240 display renders bootloader text |
| ATA/disk | Working | Reads MBR, FAT32 boot sector, directories |
| Timers | Working | 44,758+ timer reads observed |
| Partition detection | Working | Shows "Partition 1: 0x0C 260096 sectors" |
| FAT32 structure | Working | Root dir → .rockbox dir chain works |
| ipvd header stripping | Fixed | Bootloader copies to IRAM correctly |

---

## BLOCKING ISSUE

**The bootloader finds the .rockbox directory but never reads the rockbox.ipod file.**

### Symptoms
- ATA reads: LBA 0, 2048, 2049, 6144, 6145 ✓
- LBA 6146 (rockbox.ipod data) is NEVER read
- Path buffer at 0x4000BE6C is EMPTY when open() is called
- Bootloader shows "Can't load rockbox.ipod" then falls back to Apple firmware

### Root Cause (Hypothesis)
The path string "/.rockbox/rockbox.ipod" is never constructed before the open() call. Something prevents the bootloader from reaching the code that builds this path.

---

## ACTION PLAN

### Phase 1: Understand the Control Flow
**Goal**: Find exactly where and why path construction fails

- [ ] **Step 1.1**: Disassemble code around 0x40004680 (load_firmware entry)
  - Find the sprintf/path construction call
  - Format string "/.rockbox/%s" is at 0x4000BDB4
  - Reference at 0x4000065C

- [ ] **Step 1.2**: Add trace at 0x4000065C to see if it's ever executed
  - If reached: why doesn't sprintf populate the buffer?
  - If not reached: what branch prevents it?

- [ ] **Step 1.3**: Trace backward from load_firmware to find the caller
  - Where does R2 (path buffer pointer) come from?
  - What condition controls whether path is built?

### Phase 2: Fix the Issue
**Goal**: Make the bootloader construct the path correctly

- [ ] **Step 2.1**: Based on Phase 1 findings, implement fix
  - Could be: emulator bug, missing peripheral, wrong return value

- [ ] **Step 2.2**: Verify rockbox.ipod is read
  - Should see ATA read for LBA 6146, 6147, etc.
  - Should see file data being loaded to SDRAM

### Phase 3: Boot Rockbox Main Firmware
**Goal**: Execute rockbox.ipod after loading

- [ ] **Step 3.1**: Verify checksum validation passes
- [ ] **Step 3.2**: Track jump to main firmware entry point
- [ ] **Step 3.3**: Debug any new issues in main firmware execution

---

## KEY ADDRESSES (Reference)

| Address | Purpose |
|---------|---------|
| 0x40000000 | IRAM start, bootloader entry after copy |
| 0x40004680 | load_firmware function |
| 0x40004618 | open() call site |
| 0x4000065C | sprintf format string reference |
| 0x4000BDB4 | "/.rockbox/%s" format string |
| 0x4000BE6C | Path buffer (should contain "/.rockbox/rockbox.ipod") |
| 0x4000BFC4 | "rockbox.ipod" filename constant |

---

## DISK IMAGE INFO

**File**: `ipod_proper.img` (128MB) - NOT in git (too large)

**Structure**:
- LBA 0: MBR
- LBA 1-2047: Partition 0 (firmware, type 0x00)
- LBA 2048+: Partition 1 (FAT32, type 0x0C)
  - Boot sector at 2048
  - FAT1 at 2080, FAT2 at 4112
  - Data (cluster 2) at 6144
  - Root dir at 6144
  - .rockbox dir at 6145
  - rockbox.ipod at 6146+

**rockbox.ipod**: 774,012 bytes, header checksum 0x04D7ABD6, model "ipvd"

---

## COMMANDS

```bash
# Build emulator
zig build emulator

# Run with tracing (headless)
./zig-out/bin/zigpod-emulator --firmware firmware/bootloader-ipodvideo.ipod \
  --headless --debug --cycles 20000000 ipod_proper.img

# Run with SDL2 display
zig build emulator -Dsdl2=true
./zig-out/bin/zigpod-emulator --firmware firmware/bootloader-ipodvideo.ipod \
  --debug --cycles 50000000 ipod_proper.img

# Verify disk image
xxd ipod_proper.img | head -50
```

---

## RULES FOR ALL AGENTS

1. **Read this plan first** before doing any work
2. **Do not re-verify working components** - trust the table above
3. **Focus on the blocking issue** - don't get sidetracked
4. **Document findings** in RE_JOURNAL.md with dates
5. **Commit often** with clear messages
6. **Update this plan** when phases complete or new blockers found

---

## PROGRESS LOG

| Date | Agent | Action | Result |
|------|-------|--------|--------|
| 2026-01-13 | - | Created master plan | - |

