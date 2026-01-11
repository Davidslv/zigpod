//! Minimal Boot Test - Simple Main Entry
//!
//! Skip all PP5021C re-initialization since Apple bootloader already did it.
//! Just initialize BCM and call a simple main loop.

const builtin = @import("builtin");

// Only compile for ARM
comptime {
    if (builtin.cpu.arch == .arm) {
        @export(&_start, .{ .name = "_start" });
    }
}

/// Minimal entry point
fn _start() callconv(.naked) noreturn {
    // Disable IRQ/FIQ at ARM core level (safe)
    asm volatile (
        \\msr cpsr_c, #0xdf
    );

    // Set up stack in SDRAM (Apple already initialized SDRAM)
    asm volatile (
        \\ldr sp, =0x40008000
    );

    // Jump to Zig code
    asm volatile (
        \\bl _zigpod_main
    );

    // Should never reach here
    asm volatile (
        \\1: b 1b
    );
}

// BCM registers
const BCM_DATA32: *volatile u32 = @ptrFromInt(0x30000000);
const BCM_WR_ADDR32: *volatile u32 = @ptrFromInt(0x30010000);
const BCM_CONTROL: *volatile u16 = @ptrFromInt(0x30030000);

const BCMA_CMDPARAM: u32 = 0xE0000;
const BCMA_COMMAND: u32 = 0x1F8;
const BCMCMD_LCD_UPDATE: u32 = 0xFFFF0000;

// Colors (RGB565 as u32 for fillScreen - two pixels packed)
const COLOR32_BLACK: u32 = 0x00000000;
const COLOR32_WHITE: u32 = 0xFFFFFFFF;
const COLOR32_RED: u32 = 0xF800F800;
const COLOR32_GREEN: u32 = 0x07E007E0;
const COLOR32_BLUE: u32 = 0x001F001F;
const COLOR32_YELLOW: u32 = 0xFFE0FFE0;
const COLOR32_CYAN: u32 = 0x07FF07FF;
const COLOR32_MAGENTA: u32 = 0xF81FF81F;

// 5.5G PWM backlight control
const PWM_BACKLIGHT: *volatile u32 = @ptrFromInt(0x6000B004);

// Click wheel registers - from Rockbox bootloader/ipod.c
const WHEEL_CTRL: *volatile u32 = @ptrFromInt(0x7000C100);   // Control register
const WHEEL_STATUS: *volatile u32 = @ptrFromInt(0x7000C104); // Status register
const WHEEL_TX: *volatile u32 = @ptrFromInt(0x7000C120);     // TX data (send command here)
const WHEEL_DATA: *volatile u32 = @ptrFromInt(0x7000C140);   // RX data (read response here)

// GPIO B registers for click wheel serial communication
const GPIOB_ENABLE: *volatile u32 = @ptrFromInt(0x6000D020);
const GPIOB_OUTPUT_EN: *volatile u32 = @ptrFromInt(0x6000D030);
const GPIOB_OUTPUT_VAL: *volatile u32 = @ptrFromInt(0x6000D034);

// Microsecond timer for timeouts
const USEC_TIMER: *volatile u32 = @ptrFromInt(0x60005010);

// Device enable registers
const DEV_RS: *volatile u32 = @ptrFromInt(0x60006004);   // Device reset
const DEV_EN: *volatile u32 = @ptrFromInt(0x6000600C);   // Device enable
const DEV_INIT1: *volatile u32 = @ptrFromInt(0x70000010); // Device init 1

// Device bits
const DEV_OPTO: u32 = 0x00010000;      // Click wheel enable
const INIT_BUTTONS: u32 = 0x00040000;  // Button detection enable
const DEV_ATA: u32 = 0x00004000;       // ATA controller clock (was wrong: 0x04 is SYSTEM!)
const DEV_IDE0: u32 = 0x02000000;      // IDE0 interface enable

// GPO32 for IDE power control (from Rockbox pp5020.h)
const GPO32_VAL: *volatile u32 = @ptrFromInt(0x70000080);
const GPO32_EN: *volatile u32 = @ptrFromInt(0x70000084);

// GPIO ports for IDE (from Rockbox power-ipod.c)
const GPIOG_ENABLE: *volatile u32 = @ptrFromInt(0x6000D088);
const GPIOH_ENABLE: *volatile u32 = @ptrFromInt(0x6000D08C);
const GPIOI_ENABLE: *volatile u32 = @ptrFromInt(0x6000D100);
const GPIOK_ENABLE: *volatile u32 = @ptrFromInt(0x6000D108);

// ============================================================================
// ATA/IDE Registers (from Rockbox and PP5020 reference)
// ============================================================================

// IDE controller registers (from Rockbox ata-pp5020.c)
const IDE0_CFG: *volatile u32 = @ptrFromInt(0xC3000000);
const IDE0_PRI_TIMING0: *volatile u32 = @ptrFromInt(0xC3000004);
const IDE0_PRI_TIMING1: *volatile u32 = @ptrFromInt(0xC3000008);
const IDE_CFG_RESET: u32 = 0x00000001;

// PIO timing for 80MHz (from Rockbox)
const PIO_TIMING0: u32 = 0xC293;
const PIO_TIMING1: u32 = 0x80002150;

// ATA Task File registers - 4-byte aligned per Rockbox ata-target.h
const IDE_BASE: u32 = 0xC3000000;
const ATA_DATA: *volatile u16 = @ptrFromInt(IDE_BASE + 0x1E0);
const ATA_ERROR: *volatile u8 = @ptrFromInt(IDE_BASE + 0x1E4);
const ATA_NSECTOR: *volatile u8 = @ptrFromInt(IDE_BASE + 0x1E8);
const ATA_SECTOR: *volatile u8 = @ptrFromInt(IDE_BASE + 0x1EC);  // LBA[0:7]
const ATA_LCYL: *volatile u8 = @ptrFromInt(IDE_BASE + 0x1F0);    // LBA[8:15]
const ATA_HCYL: *volatile u8 = @ptrFromInt(IDE_BASE + 0x1F4);    // LBA[16:23]
const ATA_SELECT: *volatile u8 = @ptrFromInt(IDE_BASE + 0x1F8);  // Device/LBA[24:27]
const ATA_COMMAND: *volatile u8 = @ptrFromInt(IDE_BASE + 0x1FC);
const ATA_STATUS: *volatile u8 = @ptrFromInt(IDE_BASE + 0x1FC);  // Same as COMMAND
const ATA_CONTROL: *volatile u8 = @ptrFromInt(IDE_BASE + 0x3F8);

// ATA commands
const ATA_CMD_READ_SECTORS: u8 = 0x20;

// ATA status bits
const ATA_STATUS_BSY: u8 = 0x80;
const ATA_STATUS_DRDY: u8 = 0x40;
const ATA_STATUS_DRQ: u8 = 0x08;
const ATA_STATUS_ERR: u8 = 0x01;

// ATA device select
const ATA_DEV_LBA: u8 = 0xE0;  // LBA mode, device 0

// Wheel polling command (from Rockbox bootloader)
const WHEEL_CMD: u32 = 0x8000023A;

// Status bits
const WHEEL_STATUS_DATA_READY: u32 = 0x04000000;  // Bit 26 - data available
const WHEEL_STATUS_BUSY: u32 = 0x80000000;        // Bit 31 - transfer in progress
const WHEEL_STATUS_CLEAR: u32 = 0x0C000000;       // Clear bits
const WHEEL_CTRL_START: u32 = 0x80000000;         // Start transfer
const WHEEL_CTRL_ACK: u32 = 0x60000000;           // Acknowledge bits

// Button bits from wheel packet - 5.5G CONFIRMED mapping
// These are the bit positions in the data word (bits 8-12)
const BTN_SELECT: u32 = 0x00000100;  // Bit 8
const BTN_RIGHT: u32 = 0x00000200;   // Bit 9
const BTN_LEFT: u32 = 0x00000400;    // Bit 10
const BTN_PLAY: u32 = 0x00000800;    // Bit 11
const BTN_MENU: u32 = 0x00003000;    // Bit 12 OR 13 - check both!

// ============================================================================
// UART Serial Debug (dock connector, 115200 baud)
// ============================================================================
// Connect: Pin 11 = TX, Pin 13 = RX, Pin 1/2 = GND
// Use: screen /dev/tty.usbserial-XXXX 115200

const DEV_SER0: u32 = 0x00000040;  // Serial 0 enable bit in DEV_EN

const SER0_BASE: u32 = 0x70006000;
const SER0_RBR_THR: *volatile u32 = @ptrFromInt(SER0_BASE + 0x00);  // RX/TX buffer
const SER0_DLL: *volatile u32 = @ptrFromInt(SER0_BASE + 0x00);      // Divisor low (when DLAB=1)
const SER0_DLM: *volatile u32 = @ptrFromInt(SER0_BASE + 0x04);      // Divisor high (when DLAB=1)
const SER0_LCR: *volatile u32 = @ptrFromInt(SER0_BASE + 0x0C);      // Line control
const SER0_LSR: *volatile u32 = @ptrFromInt(SER0_BASE + 0x14);      // Line status

// Initialize UART for debug output
fn initUart() void {
    // Enable serial device
    DEV_EN.* |= DEV_SER0;

    // Set DLAB to access divisor registers
    SER0_LCR.* = 0x80;

    // Set baud rate: 24MHz / 115200 / 16 = 13
    SER0_DLL.* = 13;
    SER0_DLM.* = 0;

    // 8-N-1, clear DLAB
    SER0_LCR.* = 0x03;
}

// Send one character
fn uartPutChar(c: u8) void {
    // Wait for TX holding register empty (bit 5)
    while ((SER0_LSR.* & 0x20) == 0) {
        asm volatile ("nop");
    }
    SER0_RBR_THR.* = c;
}

// Send a string
fn uartPrint(s: []const u8) void {
    for (s) |c| {
        if (c == '\n') uartPutChar('\r');
        uartPutChar(c);
    }
}

// Print hex value
fn uartPrintHex(val: u32) void {
    const hex = "0123456789ABCDEF";
    uartPrint("0x");
    var i: i8 = 28;
    while (i >= 0) : (i -= 4) {
        const shift: u5 = @intCast(@as(u8, @bitCast(i)));
        uartPutChar(hex[@as(usize, (val >> shift) & 0xF)]);
    }
}

// Initialize click wheel - full sequence from Rockbox opto_i2c_init()
fn initWheel() void {
    // Step 1: Enable OPTO device
    DEV_EN.* |= DEV_OPTO;

    // Step 2: Reset the OPTO device
    DEV_RS.* |= DEV_OPTO;

    // Step 3: Wait for reset (at least 5us)
    var i: u32 = 0;
    while (i < 5000) : (i += 1) {
        asm volatile ("nop");
    }

    // Step 4: Release reset
    DEV_RS.* &= ~DEV_OPTO;

    // Step 5: Enable button detection
    DEV_INIT1.* |= INIT_BUTTONS;

    // Step 6: Configure wheel controller (from Rockbox opto_i2c_init)
    WHEEL_CTRL.* = 0xC00A1F00;
    WHEEL_STATUS.* = 0x01000000;
}

// Send configuration command to click wheel (from Rockbox bootloader)
// This is the key - we must SEND a command to GET data back!
fn wheelSendCommand(val: u32) void {
    // Disable GPIO B bit 7
    GPIOB_ENABLE.* &= ~@as(u32, 0x80);

    // Clear status
    WHEEL_STATUS.* = WHEEL_STATUS.* | WHEEL_STATUS_CLEAR;

    // Send command to TX register
    WHEEL_TX.* = val;

    // Start transfer (set bit 31)
    WHEEL_CTRL.* = WHEEL_CTRL.* | WHEEL_CTRL_START;

    // Configure GPIO B for output
    GPIOB_OUTPUT_VAL.* &= ~@as(u32, 0x10);
    GPIOB_OUTPUT_EN.* |= 0x10;

    // Wait for transfer complete (bit 31 goes low) with timeout
    var timeout: u32 = 0;
    while ((WHEEL_STATUS.* & WHEEL_STATUS_BUSY) != 0) {
        timeout += 1;
        if (timeout > 150000) break;  // ~1.5ms at 80MHz
        asm volatile ("nop");
    }

    // Clear start bit
    WHEEL_CTRL.* = WHEEL_CTRL.* & ~WHEEL_CTRL_START;

    // Restore GPIO B
    GPIOB_ENABLE.* |= 0x80;
    GPIOB_OUTPUT_VAL.* |= 0x10;
    GPIOB_OUTPUT_EN.* &= ~@as(u32, 0x10);

    // Acknowledge
    WHEEL_STATUS.* = WHEEL_STATUS.* | WHEEL_STATUS_CLEAR;
    WHEEL_CTRL.* = WHEEL_CTRL.* | WHEEL_CTRL_ACK;
}

// Poll click wheel for button/wheel data (from Rockbox bootloader)
// Returns button state (0-31) or 0 if no button pressed
fn readWheel() u8 {
    var attempts: u32 = 5;

    while (attempts > 0) {
        // Send polling command
        wheelSendCommand(WHEEL_CMD);

        // Wait for data with timeout
        var timeout: u32 = 0;
        var got_data = false;
        while (timeout < 150000) : (timeout += 1) {
            if ((WHEEL_STATUS.* & WHEEL_STATUS_DATA_READY) != 0) {
                got_data = true;
                break;
            }
            asm volatile ("nop");
        }

        if (!got_data) {
            attempts -= 1;
            continue;
        }

        // Read data
        const data = WHEEL_DATA.*;

        // Validate packet: (data & ~0x7fff0000) should equal WHEEL_CMD
        if ((data & ~@as(u32, 0x7FFF0000)) != WHEEL_CMD) {
            attempts -= 1;
            continue;
        }

        // Acknowledge
        WHEEL_CTRL.* = WHEEL_CTRL.* | WHEEL_CTRL_ACK;
        WHEEL_STATUS.* = WHEEL_STATUS.* | WHEEL_STATUS_CLEAR;

        // Extract button state: (data << 11) >> 27, then XOR with 0x1F
        const buttons = @as(u8, @truncate((data << 11) >> 27)) ^ 0x1F;
        return buttons;
    }

    return 0;  // No button pressed
}

// Extract button state from wheel packet - CORRECTED bit positions
// Buttons are in bits 8-12 of the packet:
//   Bit 8:  SELECT (center)
//   Bit 9:  RIGHT (forward)
//   Bit 10: LEFT (back)
//   Bit 11: PLAY/PAUSE
//   Bit 12: MENU
fn getButtons(packet: u32) u8 {
    var buttons: u8 = 0;
    if (packet & 0x00000100 != 0) buttons |= BTN_SELECT;  // Bit 8
    if (packet & 0x00000200 != 0) buttons |= BTN_RIGHT;   // Bit 9
    if (packet & 0x00000400 != 0) buttons |= BTN_LEFT;    // Bit 10
    if (packet & 0x00000800 != 0) buttons |= BTN_PLAY;    // Bit 11
    if (packet & 0x00001000 != 0) buttons |= BTN_MENU;    // Bit 12
    return buttons;
}

// Extract wheel position from wheel packet (0-95)
// Wheel position is in bits 16-22, bit 30 indicates touch
fn getWheelPosition(packet: u32) u8 {
    return @truncate((packet >> 16) & 0x7F);  // 7 bits, not 8
}

// Check if wheel is being touched
fn isWheelTouched(packet: u32) bool {
    return (packet & 0x40000000) != 0;  // Bit 30
}

fn bcmWriteAddr(addr: u32) void {
    BCM_WR_ADDR32.* = addr;
    while ((BCM_CONTROL.* & 0x2) == 0) {
        asm volatile ("nop");
    }
}

fn fillScreen(color: u32) void {
    bcmWriteAddr(BCMA_CMDPARAM);
    var i: u32 = 0;
    while (i < 320 * 240 / 2) : (i += 1) {
        BCM_DATA32.* = color;
    }
    bcmWriteAddr(BCMA_COMMAND);
    BCM_DATA32.* = BCMCMD_LCD_UPDATE;
    BCM_CONTROL.* = 0x31;
}

fn delay() void {
    var i: u32 = 0;
    while (i < 3000000) : (i += 1) {
        asm volatile ("nop");
    }
}

// Draw directly to BCM - no framebuffer needed
// Draws a horizontal line of colored pixels
fn drawLine(y: u16, x_start: u16, x_end: u16, color: u16) void {
    const color32: u32 = @as(u32, color) | (@as(u32, color) << 16);
    // Calculate BCM address for this line
    const line_addr = BCMA_CMDPARAM + @as(u32, y) * 320 * 2 + @as(u32, x_start) * 2;
    bcmWriteAddr(line_addr);

    var x = x_start;
    while (x < x_end) : (x += 2) {
        BCM_DATA32.* = color32;
    }
}

fn drawUI() void {
    // Colors (u16 for drawLine)
    const white: u16 = 0xFFFF;
    const dark_gray: u16 = 0x4208;
    const menu_green: u16 = 0x07E0;
    const title_blue: u16 = 0x001F;

    // First, fill entire screen black
    fillScreen(COLOR32_BLACK);

    // Draw title bar (white, top 24 lines)
    var y: u16 = 0;
    while (y < 24) : (y += 1) {
        drawLine(y, 0, 320, white);
    }

    // Draw blue "ZigPod" indicator in title bar
    y = 4;
    while (y < 20) : (y += 1) {
        drawLine(y, 10, 70, title_blue);
    }

    // Draw green battery indicator
    y = 4;
    while (y < 20) : (y += 1) {
        drawLine(y, 280, 310, menu_green);
    }

    // Draw menu item 1 (Music) - green highlight
    y = 40;
    while (y < 60) : (y += 1) {
        drawLine(y, 10, 310, menu_green);
    }

    // Draw menu item 2 (Files) - gray
    y = 65;
    while (y < 85) : (y += 1) {
        drawLine(y, 10, 310, dark_gray);
    }

    // Draw menu item 3 (Settings) - gray
    y = 90;
    while (y < 110) : (y += 1) {
        drawLine(y, 10, 310, dark_gray);
    }

    // Draw menu item 4 (Now Playing) - gray
    y = 115;
    while (y < 135) : (y += 1) {
        drawLine(y, 10, 310, dark_gray);
    }

    // Final update command
    bcmWriteAddr(BCMA_COMMAND);
    BCM_DATA32.* = BCMCMD_LCD_UPDATE;
    BCM_CONTROL.* = 0x31;
}

// Menu state
var selected_item: u8 = 0;
const MENU_ITEMS: u8 = 4;

fn drawMenuItem(index: u8, selected: bool) void {
    const y_start: u16 = 40 + @as(u16, index) * 25;
    const y_end: u16 = y_start + 20;
    const highlight: u16 = 0x07E0; // Green
    const normal: u16 = 0x4208;    // Dark gray
    const color = if (selected) highlight else normal;

    var y = y_start;
    while (y < y_end) : (y += 1) {
        drawLine(y, 10, 310, color);
    }
}

fn drawMenu() void {
    // Black background
    fillScreen(COLOR32_BLACK);

    // Title bar (blue)
    var y: u16 = 0;
    while (y < 24) : (y += 1) {
        drawLine(y, 0, 320, 0x001F);
    }

    // Battery indicator (green box top right)
    y = 4;
    while (y < 20) : (y += 1) {
        drawLine(y, 280, 310, 0x07E0);
    }

    // Draw all menu items
    var i: u8 = 0;
    while (i < MENU_ITEMS) : (i += 1) {
        drawMenuItem(i, i == selected_item);
    }

    // Update display
    bcmWriteAddr(BCMA_COMMAND);
    BCM_DATA32.* = BCMCMD_LCD_UPDATE;
    BCM_CONTROL.* = 0x31;
}

fn drawNowPlaying() void {
    fillScreen(COLOR32_BLACK);

    // Title bar (cyan)
    var y: u16 = 0;
    while (y < 24) : (y += 1) {
        drawLine(y, 0, 320, 0x07FF);
    }

    // Album art placeholder (gray box)
    y = 50;
    while (y < 150) : (y += 1) {
        drawLine(y, 110, 210, 0x8410);
    }

    // Progress bar (dark gray background)
    y = 200;
    while (y < 210) : (y += 1) {
        drawLine(y, 40, 280, 0x4208);
    }

    // Progress bar (green fill at 50%)
    y = 200;
    while (y < 210) : (y += 1) {
        drawLine(y, 40, 160, 0x07E0);
    }

    bcmWriteAddr(BCMA_COMMAND);
    BCM_DATA32.* = BCMCMD_LCD_UPDATE;
    BCM_CONTROL.* = 0x31;
}

// ============================================================================
// ATA Storage Test Functions
// ============================================================================

// Initialize ATA controller - exact sequence from Rockbox power-ipod.c + ata-pp5020.c
fn initATA() void {
    var d: u32 = 0;

    // =========================================
    // ide_power_enable(true) from power-ipod.c
    // =========================================

    // Step 1: Enable IDE power via GPO32 (clear bit 30)
    GPO32_VAL.* &= ~@as(u32, 0x40000000);

    // Wait for power (~10ms, Rockbox uses sleep(1) which is ~10ms)
    d = 0;
    while (d < 1000000) : (d += 1) asm volatile ("nop");

    // Step 2: Enable IDE0 device
    DEV_EN.* |= DEV_IDE0;

    // Step 3: Configure GPIO ports for IDE (disable GPIO, enable peripheral function)
    GPIOG_ENABLE.* = 0;
    GPIOH_ENABLE.* = 0;
    GPIOI_ENABLE.* &= ~@as(u32, 0xBF);
    GPIOK_ENABLE.* &= ~@as(u32, 0x1F);

    // Small delay
    d = 0;
    while (d < 1000) : (d += 1) asm volatile ("nop");

    // =========================================
    // ata_device_init() from ata-pp5020.c
    // =========================================

    // Step 4: Configure IDE0_CFG - set bit 5, clear bit 28 (iPod Video is < 65MHz)
    var cfg = IDE0_CFG.*;
    cfg |= 0x20;                          // Enable IDE (bit 5)
    cfg &= ~@as(u32, 0x10000000);         // Clear bit 28 (cpu < 65MHz)
    IDE0_CFG.* = cfg;

    // Step 5: Set PIO timing
    IDE0_PRI_TIMING0.* = PIO_TIMING0;     // 0xC293
    IDE0_PRI_TIMING1.* = PIO_TIMING1;     // 0x80002150

    // =========================================
    // perform_soft_reset() from ata.c
    // =========================================

    // Step 6: Select device 0 with LBA mode
    ATA_SELECT.* = 0x40;  // SELECT_LBA | device 0

    // Step 7: Assert software reset
    ATA_CONTROL.* = 0x06;  // CONTROL_nIEN | CONTROL_SRST

    // Wait >= 5us
    d = 0;
    while (d < 1000) : (d += 1) asm volatile ("nop");

    // Step 8: Clear reset, keep interrupts disabled
    ATA_CONTROL.* = 0x02;  // CONTROL_nIEN only

    // Wait > 2ms for device to come out of reset
    d = 0;
    while (d < 500000) : (d += 1) asm volatile ("nop");
}

// Wait for ATA not busy with timeout
fn ataWaitNotBusy() bool {
    var timeout: u32 = 0;
    while (timeout < 5000000) : (timeout += 1) {
        const status = ATA_STATUS.*;
        if ((status & ATA_STATUS_BSY) == 0) return true;
        asm volatile ("nop");
    }
    return false; // Timeout
}

// Wait for ATA ready (not busy + ready)
fn ataWaitReady() bool {
    var timeout: u32 = 0;
    while (timeout < 5000000) : (timeout += 1) {
        const status = ATA_STATUS.*;
        if ((status & ATA_STATUS_BSY) == 0 and (status & ATA_STATUS_DRDY) != 0) return true;
        asm volatile ("nop");
    }
    return false; // Timeout
}

// Wait for data request
fn ataWaitDrq() bool {
    var timeout: u32 = 0;
    while (timeout < 1000000) : (timeout += 1) {
        const status = ATA_STATUS.*;
        if ((status & ATA_STATUS_DRQ) != 0) return true;
        if ((status & ATA_STATUS_ERR) != 0) return false;
        asm volatile ("nop");
    }
    return false; // Timeout
}

// Show a colored bar at Y position to indicate progress
fn showDebugBar(y: u16, color: u16) void {
    var row: u16 = y;
    while (row < y + 10) : (row += 1) {
        drawLine(row, 20, 300, color);
    }
    bcmWriteAddr(BCMA_COMMAND);
    BCM_DATA32.* = BCMCMD_LCD_UPDATE;
    BCM_CONTROL.* = 0x31;
}

// Read sector 0 (MBR) and return true if signature is valid
fn testReadMBR() bool {
    // Debug: Show we started (white bar at y=50)
    showDebugBar(50, 0xFFFF);

    // Try WITHOUT init first - Apple bootloader may have left ATA ready
    // Skip initATA() and just try to read

    // Debug: Show waiting for ready (yellow bar at y=70)
    showDebugBar(70, 0xFFE0);

    // Wait for drive ready
    if (!ataWaitReady()) {
        // Debug: Ready failed (red bar at y=90)
        showDebugBar(90, 0xF800);
        return false;
    }

    // Debug: Ready OK (green bar at y=90)
    showDebugBar(90, 0x07E0);

    // Select device 0 with LBA mode
    ATA_SELECT.* = ATA_DEV_LBA;

    // Small delay
    var d: u32 = 0;
    while (d < 1000) : (d += 1) asm volatile ("nop");

    // Set LBA = 0 (sector 0)
    ATA_SECTOR.* = 0;
    ATA_LCYL.* = 0;
    ATA_HCYL.* = 0;

    // Read 1 sector
    ATA_NSECTOR.* = 1;

    // Debug: About to send command (cyan bar at y=110)
    showDebugBar(110, 0x07FF);

    // Issue READ SECTORS command
    ATA_COMMAND.* = ATA_CMD_READ_SECTORS;

    // Debug: Waiting for DRQ (magenta bar at y=130)
    showDebugBar(130, 0xF81F);

    // Wait for data
    if (!ataWaitDrq()) {
        // Debug: DRQ failed (orange bar at y=150)
        showDebugBar(150, 0xFD20);
        return false;
    }

    // Debug: DRQ OK (blue bar at y=150)
    showDebugBar(150, 0x001F);

    // Read 256 words (512 bytes) - we only need bytes 510-511
    var sector: [512]u8 = undefined;
    var i: usize = 0;
    while (i < 256) : (i += 1) {
        const word = ATA_DATA.*;
        sector[i * 2] = @truncate(word & 0xFF);
        sector[i * 2 + 1] = @truncate((word >> 8) & 0xFF);
    }

    // Debug: Read complete (purple bar at y=170)
    showDebugBar(170, 0x8010);

    // Check MBR signature (0x55AA at bytes 510-511)
    // Also check swapped order in case of endianness issue
    const sig_ok = (sector[510] == 0x55 and sector[511] == 0xAA);
    const sig_swapped = (sector[510] == 0xAA and sector[511] == 0x55);

    if (sig_ok or sig_swapped) {
        showDebugBar(190, 0x07E0);  // Green = correct signature (either order)
    } else {
        // Show byte 510 as a bar (red = high value)
        const b510_color: u16 = (@as(u16, sector[510] >> 3) << 11);  // Red channel
        showDebugBar(190, b510_color);

        // Show byte 511 as next bar (blue = high value)
        const b511_color: u16 = @as(u16, sector[511] >> 3);  // Blue channel
        showDebugBar(200, b511_color);
    }

    // Also show first bytes of sector to verify we're reading real data
    // Byte 0 should be 0xEB or 0xE9 (x86 JMP) or 0x00 for MBR
    const b0_color: u16 = (@as(u16, sector[0] >> 3) << 11);
    showDebugBar(220, b0_color);

    return sig_ok or sig_swapped;
}

// Storage test screen - shows debug bars, does NOT clear them
fn drawStorageTest() void {
    fillScreen(COLOR32_BLACK);

    // Title bar (yellow for test)
    var y: u16 = 0;
    while (y < 24) : (y += 1) {
        drawLine(y, 0, 320, 0xFFE0);
    }

    bcmWriteAddr(BCMA_COMMAND);
    BCM_DATA32.* = BCMCMD_LCD_UPDATE;
    BCM_CONTROL.* = 0x31;

    // Run the test - debug bars will show progress
    // Do NOT clear screen after - keep debug bars visible
    _ = testReadMBR();

    // Test complete - bars show where we got to
    // Final bar at y=210 shows we completed the test function
    showDebugBar(210, 0xFFFF);  // White bar = test function completed
}

const Screen = enum { menu, now_playing, storage_test };
var current_screen: Screen = .menu;
var last_buttons: u32 = 0;

export fn _zigpod_main() void {
    // Set backlight to maximum
    PWM_BACKLIGHT.* = 0x0000FFFF;

    // Initialize click wheel
    DEV_EN.* |= DEV_OPTO;
    DEV_RS.* |= DEV_OPTO;
    var i: u32 = 0;
    while (i < 5000) : (i += 1) asm volatile ("nop");
    DEV_RS.* &= ~DEV_OPTO;
    DEV_INIT1.* |= INIT_BUTTONS;
    WHEEL_CTRL.* = 0xC00A1F00;
    WHEEL_STATUS.* = 0x01000000;

    // Draw initial menu
    drawMenu();

    // Main loop
    while (true) {
        const status = WHEEL_STATUS.*;

        if ((status & 0x04000000) != 0) {
            const data = WHEEL_DATA.*;

            // Acknowledge
            WHEEL_STATUS.* = WHEEL_STATUS.* | 0x0C000000;
            WHEEL_CTRL.* = WHEEL_CTRL.* | 0x60000000;

            if ((data & 0xFF) == 0x1A) {
                const buttons = data & 0x00003F00;
                const new_press = buttons & ~last_buttons;
                last_buttons = buttons;

                if (current_screen == .menu) {
                    // RIGHT = down
                    if ((new_press & 0x00000200) != 0) {
                        if (selected_item < MENU_ITEMS - 1) {
                            selected_item += 1;
                            drawMenu();
                        }
                    }
                    // LEFT = up
                    if ((new_press & 0x00000400) != 0) {
                        if (selected_item > 0) {
                            selected_item -= 1;
                            drawMenu();
                        }
                    }
                    // SELECT or PLAY = enter
                    if ((new_press & 0x00000100) != 0 or (new_press & 0x00000800) != 0) {
                        if (selected_item == 0) {
                            // Menu item 0: Now Playing
                            current_screen = .now_playing;
                            drawNowPlaying();
                        } else if (selected_item == 1) {
                            // Menu item 1: Storage Test
                            current_screen = .storage_test;
                            drawStorageTest();
                        }
                        // Items 2 and 3 do nothing for now
                    }
                } else {
                    // MENU = back
                    if ((new_press & 0x00003000) != 0) {
                        current_screen = .menu;
                        drawMenu();
                    }
                }
            }
        }

        // Small delay
        var j: u32 = 0;
        while (j < 10000) : (j += 1) asm volatile ("nop");
    }
}
