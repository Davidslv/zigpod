# Rockbox Research Findings

## Date: 2026-01-10

Research into Rockbox source code to understand iPod Video boot sequence and hardware initialization.

---

## 1. Boot Sequence (bootloader/ipod.c)

### Initialization Order
```c
system_init();      // Hardware init (clocks, GPIO, memory)
kernel_init();      // Kernel/threading
lcd_init();         // LCD controller
font_init();        // Font rendering
backlight_init();   // Backlight on
ata_init();         // ATA/storage
filesystem_init();  // FAT32 filesystem
disk_mount_all();   // Mount partitions
```

### Key Insight: Firmware Loading
The Apple ROM loads the OSOS image to `DRAM_START` (0x10000000). The bootloader checks for:

1. **Hold switch or MENU** → Boot Apple firmware
   - Look for `apple_os.ipod` on FAT32 partition
   - Or check for "portalplayer" string at DRAM_START+0x20

2. **PLAY button** → Boot Linux from `/linux.bin`

3. **Default** → Boot Rockbox
   - Look for `rockbox.ipod` on FAT32 partition
   - Or check for "Rockbox\1" string at DRAM_START+0x20

**Important**: Rockbox can be appended to Apple firmware or standalone. When appended, it just jumps back to DRAM_START where Apple already loaded it.

---

## 2. PP5021C System Init (system-pp502x.c)

### iPod Video Specific Init
```c
// Bootloader init is minimal:
void system_init(void) {
    disable_all_interrupts();
    init_cache();
}

// Full firmware init sets up device enables:
DEV_EN         = 0xc2000124;  // Enable devices
DEV_EN2        = 0x00000000;
CACHE_PRIORITY = 0x0000003f;
GPO32_VAL     &= 0x00004000;
DEV_INIT1      = 0x00000000;
DEV_INIT2      = 0x40000000;

// Reset all devices
DEV_RS         = 0x3dfffef8;
DEV_RS2        = 0xffffffff;
DEV_RS         = 0x00000000;
DEV_RS2        = 0x00000000;
```

### CPU Frequency
```c
// PP5022 PLL setup for 80MHz:
PLL_CONTROL = 0x8a121403;  // 80 MHz = (20/3 * 24MHz) / 2
while (!(PLL_STATUS & 0x80000000)); // Wait for PLL lock
CLOCK_SOURCE = 0x20007777;  // Source all from PLL
```

---

## 3. iPod Video LCD (lcd-video.c)

### Critical Discovery: BCM Chip

The iPod Video uses a **Broadcom BCM2722** graphics chip for the LCD. This is NOT a simple LCD controller!

```c
// BCM Memory-mapped registers
#define BCM_DATA      (*(volatile unsigned short*)(0x30000000))
#define BCM_WR_ADDR   (*(volatile unsigned short*)(0x30010000))
#define BCM_RD_ADDR   (*(volatile unsigned short*)(0x30020000))
#define BCM_CONTROL   (*(volatile unsigned short*)(0x30030000))

// BCM internal addresses
#define BCMA_SRAM_BASE   0x0
#define BCMA_COMMAND     0x1F8
#define BCMA_STATUS      0x1FC
#define BCMA_CMDPARAM    0xE0000  // Framebuffer data goes here
```

### BCM Initialization Sequence

```c
void bcm_init(void) {
    // 1. Power up BCM
    GPO32_VAL |= 0x4000;
    sleep(HZ/20);  // 50ms

    // 2. Bootstrap stage 1
    STRAP_OPT_A &= ~0xF00;
    outl(0x1313, 0x70000040);

    // 3. Bootstrap stage 2 - handshake
    while (BCM_ALT_CONTROL & 0x80);
    while (!(BCM_ALT_CONTROL & 0x40));
    // Write bootstrap data sequence

    // 4. Bootstrap stage 3 - upload firmware
    // BCM firmware ("vmcs") is stored in iPod ROM at 0x20000000
    bcm_write_addr(BCMA_SRAM_BASE);
    lcd_write_data(flash_vmcs_offset, flash_vmcs_length);

    // 5. Start BCM
    bcm_write32(BCMA_COMMAND, 0);
    bcm_write32(0x10000C00, 0xC0000000);
    while (!(bcm_read32(0x10000C00) & 1));
    // ... more init
}
```

### LCD Update Process
```c
void lcd_update_rect(int x, int y, int width, int height) {
    // Write pixel data to BCM command parameter area
    bcmaddr = BCMA_CMDPARAM + (LCD_WIDTH*2) * y + (x << 1);
    bcm_write_addr(bcmaddr);
    lcd_write_data(addr, width * height);

    // Tell BCM to update LCD
    bcm_write32(BCMA_COMMAND, BCMCMD_LCD_UPDATE);
    BCM_CONTROL = 0x31;
}
```

---

## 4. Key Memory Addresses

| Address | Purpose |
|---------|---------|
| 0x10000000 | DRAM_START - where Apple ROM loads firmware |
| 0x20000000 | ROM_BASE - iPod flash ROM |
| 0x30000000 | BCM register base |
| 0x40000000 | SDRAM base |
| 0x60000000 | Device registers |
| 0x70000000 | PP5021C peripheral registers |

---

## 5. Why ZigPod Failed

1. **No BCM initialization** - LCD requires uploading firmware to BCM chip
2. **No system_init** - PP5021C devices not properly enabled
3. **Wrong architecture** - Tried to load firmware from filesystem, but:
   - Apple ROM already loads OSOS image to RAM
   - Should check if ZigPod is already in RAM (like Rockbox does)

---

## 6. Implementation Plan

### Option B: Single Binary (Recommended)

Combine bootloader + firmware into one binary that:

1. Gets appended to Apple firmware by ipodpatcher
2. Apple ROM loads it to DRAM_START
3. Our code runs immediately, no filesystem loading needed
4. Initialize hardware: PP5021C → BCM → LCD
5. Display splash screen
6. Continue with full ZigPod init

### Required Init Sequence

```zig
pub fn main() void {
    // 1. Disable interrupts
    disableInterrupts();

    // 2. PP5021C device init
    DEV_EN = 0xc2000124;
    // ... rest of init

    // 3. BCM power on
    GPO32_VAL |= 0x4000;
    delay(50_000); // 50ms

    // 4. BCM bootstrap
    bcmBootstrap();

    // 5. Upload BCM firmware from ROM
    uploadBcmFirmware();

    // 6. Now LCD is ready!
    lcdClear(BLACK);
    lcdDrawString(100, 100, "ZigPod OS");
    lcdUpdate();

    // 7. Continue with rest of init...
}
```

---

## 7. Files to Study Further

| File | Purpose |
|------|---------|
| `crt0-pp.S` | ARM startup code |
| `crt0-pp-bl.S` | Bootloader-specific startup |
| `backlight-nano_video.c` | Backlight control |
| `button-clickwheel.c` | Click wheel driver |
| `ata-pp5020.c` | ATA/storage driver |

---

## 8. Next Steps

1. Create new `src/kernel/init.zig` with PP5021C init sequence
2. Create `src/drivers/bcm.zig` for BCM graphics chip
3. Update LCD driver to use BCM commands
4. Build single binary firmware
5. Test on hardware

---

## References

- Rockbox source: `tools/ipodpatcher-build/rockbox-master/`
- iPod Linux wiki (archived)
- BCM2722 datasheet (if available)
