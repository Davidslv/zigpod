//! PP5021C Register Definitions
//!
//! This file contains all hardware register addresses and bit definitions
//! for the PortalPlayer PP5021C SoC used in iPod Video 5th Generation.
//!
//! Sources:
//! - Rockbox firmware/export/pp5020.h
//! - docs/004-hardware-reference.md

const std = @import("std");

// ============================================================
// Volatile Register Access Helper
// ============================================================

/// Read from a memory-mapped register
pub inline fn readReg(comptime T: type, addr: usize) T {
    return @as(*volatile T, @ptrFromInt(addr)).*;
}

/// Write to a memory-mapped register
pub inline fn writeReg(comptime T: type, addr: usize, value: T) void {
    @as(*volatile T, @ptrFromInt(addr)).* = value;
}

/// Modify register with mask
pub inline fn modifyReg(addr: usize, clear_mask: u32, set_mask: u32) void {
    const val = readReg(u32, addr);
    writeReg(u32, addr, (val & ~clear_mask) | set_mask);
}

// ============================================================
// Memory Map Constants
// ============================================================

pub const DRAM_START: usize = 0x40000000;
pub const DRAM_SIZE_32MB: usize = 32 * 1024 * 1024;
pub const DRAM_SIZE_64MB: usize = 64 * 1024 * 1024;

pub const IRAM_START: usize = 0x10000000;
pub const IRAM_SIZE: usize = 8 * 1024;

pub const ROM_START: usize = 0x00000000;
pub const ROM_SIZE: usize = 128 * 1024;

// ============================================================
// Processor Control
// ============================================================

pub const CPU_CTL: usize = 0x60007000;
pub const COP_CTL: usize = 0x60007004;

// CPU/COP control bits
pub const PROC_SLEEP: u32 = 0x80000000;
pub const PROC_WAIT_CNT: u32 = 0x40000000;
pub const PROC_WAKE_INT: u32 = 0x20000000;
pub const PROC_CNT_CLKS: u32 = 0x08000000;
pub const PROC_CNT_USEC: u32 = 0x02000000;
pub const PROC_CNT_MSEC: u32 = 0x01000000;
pub const PROC_CNT_SEC: u32 = 0x00800000;

// Processor identification
pub const CPU_ID: u8 = 0x55;
pub const COP_ID: u8 = 0xAA;

// ============================================================
// Mailbox (Inter-processor Communication)
// ============================================================

pub const MBX_MSG_STAT: usize = 0x60001000;
pub const MBX_MSG_SET: usize = 0x60001004;
pub const MBX_MSG_CLR: usize = 0x60001008;
pub const CPU_QUEUE: usize = 0x60001010;
pub const COP_QUEUE: usize = 0x60001020;

// ============================================================
// Interrupt Controller
// ============================================================

// CPU interrupt registers
pub const CPU_INT_STAT: usize = 0x60004000;
pub const CPU_INT_EN: usize = 0x60004004;
pub const CPU_INT_CLR: usize = 0x60004008;
pub const CPU_INT_PRIO: usize = 0x6000400C;
pub const CPU_HI_INT_STAT: usize = 0x60004100;
pub const CPU_HI_INT_EN: usize = 0x60004104;
pub const CPU_HI_INT_CLR: usize = 0x60004108;

// COP interrupt registers
pub const COP_INT_STAT: usize = 0x60004010;
pub const COP_INT_EN: usize = 0x60004014;
pub const COP_INT_CLR: usize = 0x60004018;
pub const COP_INT_PRIO: usize = 0x6000401C;
pub const COP_HI_INT_STAT: usize = 0x60004110;
pub const COP_HI_INT_EN: usize = 0x60004114;
pub const COP_HI_INT_CLR: usize = 0x60004118;

// Interrupt source bits
pub const TIMER1_IRQ: u32 = 1 << 0;
pub const TIMER2_IRQ: u32 = 1 << 1;
pub const MAILBOX_IRQ: u32 = 1 << 2;
pub const IIS_IRQ: u32 = 1 << 4;
pub const USB_IRQ: u32 = 1 << 5;
pub const IDE_IRQ: u32 = 1 << 6;
pub const FIREWIRE_IRQ: u32 = 1 << 7;
pub const DMA_IRQ: u32 = 1 << 8;
pub const GPIO0_IRQ: u32 = 1 << 9;
pub const GPIO1_IRQ: u32 = 1 << 10;
pub const GPIO2_IRQ: u32 = 1 << 11;
pub const SER0_IRQ: u32 = 1 << 12;
pub const SER1_IRQ: u32 = 1 << 13;
pub const I2C_IRQ: u32 = 1 << 14;

// ============================================================
// Timers
// ============================================================

pub const TIMER1_CFG: usize = 0x60005000;
pub const TIMER1_VAL: usize = 0x60005004;
pub const TIMER2_CFG: usize = 0x60005008;
pub const TIMER2_VAL: usize = 0x6000500C;
pub const USEC_TIMER: usize = 0x60005010;
pub const RTC: usize = 0x60005014;

pub const TIMER_FREQ: u32 = 1_000_000; // 1 MHz

// ============================================================
// Device Enable / Clock Control
// ============================================================

pub const DEV_RS: usize = 0x60006004;
pub const DEV_RS2: usize = 0x60006008;
pub const DEV_EN: usize = 0x6000600C;
pub const DEV_EN2: usize = 0x60006010;

// Device enable bits
pub const DEV_EXTCLOCKS: u32 = 0x00000002;
pub const DEV_SYSTEM: u32 = 0x00000004;
pub const DEV_USB0: u32 = 0x00000008;
pub const DEV_USB1: u32 = 0x00000010;
pub const DEV_I2S: u32 = 0x00000800;
pub const DEV_I2C: u32 = 0x00001000;
pub const DEV_ATA: u32 = 0x00004000;
pub const DEV_LCD: u32 = 0x00010000;
pub const DEV_OPTO: u32 = 0x00800000; // Click wheel

// Clock control
pub const CLOCK_SOURCE: usize = 0x60006020;
pub const MLCD_SCLK_DIV: usize = 0x6000602C;
pub const PLL_CONTROL: usize = 0x60006034;
pub const PLL_STATUS: usize = 0x6000603C;
pub const ADC_CLOCK_SRC: usize = 0x60006094;
pub const CLCD_CLOCK_SRC: usize = 0x600060A0;

// Clock source values
pub const CLOCK_32KHZ: u32 = 0x20002222;
pub const CLOCK_PLL: u32 = 0x20007777;

// PLL control bits
pub const PLL_ENABLE: u32 = 0x80000000;
pub const PLL_LOCK: u32 = 0x80000000;

// ============================================================
// GPIO
// ============================================================

pub const GPIO_BASE: usize = 0x6000D000;

// GPIO port offsets (multiply port number by 0x20)
pub const GPIO_PORT_OFFSET: usize = 0x20;

// Per-port register offsets
pub const GPIO_ENABLE_OFF: usize = 0x00;
pub const GPIO_INT_EN_OFF: usize = 0x04;
pub const GPIO_INT_LEV_OFF: usize = 0x08;
pub const GPIO_INT_CLR_OFF: usize = 0x0C;
pub const GPIO_OUTPUT_EN_OFF: usize = 0x10;
pub const GPIO_OUTPUT_VAL_OFF: usize = 0x14;
pub const GPIO_INPUT_VAL_OFF: usize = 0x18;
pub const GPIO_INT_STAT_OFF: usize = 0x1C;

/// Calculate GPIO register address
pub inline fn gpioReg(port: u4, offset: usize) usize {
    return GPIO_BASE + (@as(usize, port) * GPIO_PORT_OFFSET) + offset;
}

// GPIO port identifiers
pub const GPIO_PORT_A: u4 = 0;
pub const GPIO_PORT_B: u4 = 1;
pub const GPIO_PORT_C: u4 = 2;
pub const GPIO_PORT_D: u4 = 3;
pub const GPIO_PORT_E: u4 = 4;
pub const GPIO_PORT_F: u4 = 5;
pub const GPIO_PORT_G: u4 = 6;
pub const GPIO_PORT_H: u4 = 7;
pub const GPIO_PORT_I: u4 = 8;
pub const GPIO_PORT_J: u4 = 9;
pub const GPIO_PORT_K: u4 = 10;
pub const GPIO_PORT_L: u4 = 11;

// ============================================================
// I2C Controller
// ============================================================

pub const I2C_BASE: usize = 0x7000C000;

pub const I2C_CTRL: usize = I2C_BASE + 0x00;
pub const I2C_ADDR: usize = I2C_BASE + 0x04;
pub const I2C_DATA0: usize = I2C_BASE + 0x0C;
pub const I2C_DATA1: usize = I2C_BASE + 0x10;
pub const I2C_DATA2: usize = I2C_BASE + 0x14;
pub const I2C_DATA3: usize = I2C_BASE + 0x18;
pub const I2C_STATUS: usize = I2C_BASE + 0x1C;

/// Get I2C data register address
pub inline fn i2cDataReg(index: u2) usize {
    return I2C_DATA0 + (@as(usize, index) * 4);
}

// I2C control bits
pub const I2C_SEND: u8 = 0x80;
pub const I2C_BUSY: u8 = 0x40;
pub const I2C_READ_BIT: u8 = 0x01;

// ============================================================
// I2S Audio Interface
// ============================================================
//
// The PP5021C has an I2S controller for digital audio output
// to external codecs (WM8758 in iPod Video/Classic).

pub const IISDIV: usize = 0x60006080;
pub const IISCONFIG: usize = 0x70002800;
pub const IISCLKDIV: usize = 0x70002804;
pub const IISSTATUS: usize = 0x70002808;
pub const IISFIFO_CFG: usize = 0x7000280C;
pub const IISFIFO_WR: usize = 0x70002840;
pub const IISFIFO_RD: usize = 0x70002880;

// I2S Clock divider register
pub const IISDIV_BASE: usize = 0x60006080;

// IISCONFIG bits
pub const IIS_RESET: u32 = 0x80000000;
pub const IIS_ENABLE: u32 = 0x40000000;
pub const IIS_TXFIFOEN: u32 = 0x20000000;
pub const IIS_RXFIFOEN: u32 = 0x10000000;
pub const IIS_MASTER: u32 = 0x00001000;
pub const IIS_SLAVE: u32 = 0x00000000;
pub const IIS_IRQTX_EMPTY: u32 = 0x00000400;
pub const IIS_IRQTX: u32 = 0x00000200;
pub const IIS_IRQRX: u32 = 0x00000100;
pub const IIS_DMA_TX_EN: u32 = 0x00000080;
pub const IIS_DMA_RX_EN: u32 = 0x00000040;

// I2S format configuration
pub const IIS_FORMAT_MASK: u32 = 0x00C00000;
pub const IIS_FORMAT_IIS: u32 = 0x00000000;    // Standard I2S
pub const IIS_FORMAT_LJUST: u32 = 0x00400000;  // Left justified
pub const IIS_FORMAT_RJUST: u32 = 0x00800000;  // Right justified
pub const IIS_FORMAT_DSP: u32 = 0x00C00000;    // DSP mode

// Sample size configuration
pub const IIS_SIZE_MASK: u32 = 0x00060000;
pub const IIS_SIZE_16BIT: u32 = 0x00000000;
pub const IIS_SIZE_24BIT: u32 = 0x00020000;
pub const IIS_SIZE_32BIT: u32 = 0x00040000;

// FIFO status masks
pub const IIS_TX_FREE_MASK: u32 = 0x0001E000;
pub const IIS_TX_FREE_SHIFT: u5 = 13;
pub const IIS_RX_FULL_MASK: u32 = 0x00780000;
pub const IIS_RX_FULL_SHIFT: u5 = 19;
pub const IIS_TX_EMPTY: u32 = 0x00000010;
pub const IIS_RX_FULL: u32 = 0x00000020;

// FIFO depths
pub const IIS_TX_FIFO_DEPTH: usize = 16;  // 16 stereo samples
pub const IIS_RX_FIFO_DEPTH: usize = 16;

// Sample rate dividers (for MCLK = 11.2896MHz or 12.288MHz)
// Divider = MCLK / (sample_rate * 256)
pub const IIS_DIV_44100: u32 = 1;   // 11.2896MHz / (44100 * 256) = ~1
pub const IIS_DIV_48000: u32 = 1;   // 12.288MHz / (48000 * 256) = ~1
pub const IIS_DIV_22050: u32 = 2;
pub const IIS_DIV_24000: u32 = 2;
pub const IIS_DIV_11025: u32 = 4;
pub const IIS_DIV_12000: u32 = 4;

// ============================================================
// IDE/ATA Controller
// ============================================================

// IDE controller configuration registers
pub const IDE0_CFG: usize = 0xC3000000;
pub const IDE0_CNTRLR: usize = 0xC3000004;
pub const IDE0_STAT: usize = 0xC300000C;
pub const IDE1_CFG: usize = 0xC3000010;
pub const IDE1_CNTRLR: usize = 0xC3000014;
pub const IDE1_STAT: usize = 0xC300001C;

// ATA Task File Registers (memory-mapped)
// Based on Rockbox firmware/target/arm/pp/ata-target.h
pub const ATA_IOBASE: usize = 0xC30001E0;
pub const ATA_CONTROL: usize = 0xC30003F6;

// Task file register offsets from ATA_IOBASE
pub const ATA_DATA: usize = ATA_IOBASE + 0x00; // 16-bit data register
pub const ATA_ERROR: usize = ATA_IOBASE + 0x01; // Error register (read)
pub const ATA_FEATURES: usize = ATA_IOBASE + 0x01; // Features register (write)
pub const ATA_NSECTOR: usize = ATA_IOBASE + 0x02; // Sector count
pub const ATA_SECTOR: usize = ATA_IOBASE + 0x03; // Sector number / LBA[0:7]
pub const ATA_LCYL: usize = ATA_IOBASE + 0x04; // Cylinder low / LBA[8:15]
pub const ATA_HCYL: usize = ATA_IOBASE + 0x05; // Cylinder high / LBA[16:23]
pub const ATA_SELECT: usize = ATA_IOBASE + 0x06; // Device/head / LBA[24:27]
pub const ATA_COMMAND: usize = ATA_IOBASE + 0x07; // Command register (write)
pub const ATA_STATUS: usize = ATA_IOBASE + 0x07; // Status register (read)
pub const ATA_ALTSTATUS: usize = ATA_CONTROL; // Alternate status (read)

// ATA Commands
pub const ATA_CMD_IDENTIFY: u8 = 0xEC;
pub const ATA_CMD_READ_SECTORS: u8 = 0x20;
pub const ATA_CMD_READ_SECTORS_EXT: u8 = 0x24;
pub const ATA_CMD_WRITE_SECTORS: u8 = 0x30;
pub const ATA_CMD_WRITE_SECTORS_EXT: u8 = 0x34;
pub const ATA_CMD_READ_DMA: u8 = 0xC8;
pub const ATA_CMD_READ_DMA_EXT: u8 = 0x25;
pub const ATA_CMD_WRITE_DMA: u8 = 0xCA;
pub const ATA_CMD_WRITE_DMA_EXT: u8 = 0x35;
pub const ATA_CMD_STANDBY_IMMEDIATE: u8 = 0xE0;
pub const ATA_CMD_IDLE_IMMEDIATE: u8 = 0xE1;
pub const ATA_CMD_FLUSH_CACHE: u8 = 0xE7;
pub const ATA_CMD_FLUSH_CACHE_EXT: u8 = 0xEA;
pub const ATA_CMD_SET_FEATURES: u8 = 0xEF;
pub const ATA_CMD_SLEEP: u8 = 0xE6;

// ATA Status bits
pub const ATA_STATUS_BSY: u8 = 0x80; // Busy
pub const ATA_STATUS_DRDY: u8 = 0x40; // Drive ready
pub const ATA_STATUS_DF: u8 = 0x20; // Drive fault
pub const ATA_STATUS_DSC: u8 = 0x10; // Seek complete
pub const ATA_STATUS_DRQ: u8 = 0x08; // Data request
pub const ATA_STATUS_CORR: u8 = 0x04; // Corrected data
pub const ATA_STATUS_IDX: u8 = 0x02; // Index
pub const ATA_STATUS_ERR: u8 = 0x01; // Error

// ATA Error register bits
pub const ATA_ERROR_BBK: u8 = 0x80; // Bad block
pub const ATA_ERROR_UNC: u8 = 0x40; // Uncorrectable data
pub const ATA_ERROR_MC: u8 = 0x20; // Media changed
pub const ATA_ERROR_IDNF: u8 = 0x10; // ID not found
pub const ATA_ERROR_MCR: u8 = 0x08; // Media change request
pub const ATA_ERROR_ABRT: u8 = 0x04; // Aborted command
pub const ATA_ERROR_TK0NF: u8 = 0x02; // Track 0 not found
pub const ATA_ERROR_AMNF: u8 = 0x01; // Address mark not found

// ATA Device/Head register bits
pub const ATA_DEV_LBA: u8 = 0x40; // LBA mode
pub const ATA_DEV_DEV: u8 = 0x10; // Device select (0 = master, 1 = slave)
pub const ATA_DEV_HEAD_MASK: u8 = 0x0F; // Head number / LBA[24:27]

// ATA Control register bits
pub const ATA_CTL_SRST: u8 = 0x04; // Software reset
pub const ATA_CTL_NIEN: u8 = 0x02; // Disable interrupts

// IDE controller configuration bits
pub const IDE_CFG_INTRQ: u32 = 0x00000200;
pub const IDE_CFG_RESET: u32 = 0x00000001;

// Timing constants
pub const ATA_TIMEOUT_BSY_US: u32 = 5_000_000; // 5 seconds for BSY clear
pub const ATA_TIMEOUT_DRQ_US: u32 = 1_000_000; // 1 second for DRQ
pub const ATA_SECTOR_SIZE: usize = 512;

// ============================================================
// LCD Controller (BCM2722)
// ============================================================
//
// The BCM2722 is a Broadcom VideoCore GPU used for LCD control.
// It communicates via a serial interface and requires firmware
// to be loaded before use.
//
// Based on Rockbox firmware/target/arm/ipod/video/lcd-video.c

// BCM2722 Register Addresses (memory-mapped serial interface)
pub const BCM_DATA: usize = 0x30000000;
pub const BCM_WR_ADDR: usize = 0x30010000;
pub const BCM_RD_ADDR: usize = 0x30020000;
pub const BCM_CONTROL: usize = 0x30030000;

pub const BCM_ALT_DATA: usize = 0x30040000;
pub const BCM_ALT_WR_ADDR: usize = 0x30050000;
pub const BCM_ALT_RD_ADDR: usize = 0x30060000;
pub const BCM_ALT_CONTROL: usize = 0x30070000;

// BCM Control register bits
pub const BCM_CTRL_WRITE_READY: u32 = 0x02;
pub const BCM_CTRL_READ_READY: u32 = 0x01;

// BCM command encoding - commands are sent as 32-bit values
// with inverted bits in upper 16 bits for error checking
pub inline fn bcmCmd(x: u16) u32 {
    return (~@as(u32, x) << 16) | x;
}

// BCM Commands (from Rockbox)
pub const BCMCMD_LCD_UPDATE: u32 = bcmCmd(0x00);      // Full screen update
pub const BCMCMD_SELFTEST: u32 = bcmCmd(0x01);        // Self test
pub const BCMCMD_GET_WIDTH: u32 = bcmCmd(0x02);       // Get LCD width
pub const BCMCMD_GET_HEIGHT: u32 = bcmCmd(0x03);      // Get LCD height
pub const BCMCMD_FINALIZE: u32 = bcmCmd(0x04);        // Finalize transfer
pub const BCMCMD_LCD_UPDATERECT: u32 = bcmCmd(0x05);  // Partial update
pub const BCMCMD_LCD_SLEEP: u32 = bcmCmd(0x08);       // Enter sleep mode
pub const BCMCMD_LCD_WAKE: u32 = bcmCmd(0x09);        // Wake from sleep
pub const BCMCMD_LCD_POWER: u32 = bcmCmd(0x0A);       // Power control
pub const BCMCMD_GETMEMADDR: u32 = bcmCmd(0x0B);      // Get memory address
pub const BCMCMD_SETMEMADDR: u32 = bcmCmd(0x0C);      // Set memory address

// BCM Address constants for commands
pub const BCM_WR_CMD: u32 = 0x80000000;               // Write command address
pub const BCM_RD_CMD: u32 = 0x80000000;               // Read command address

// Timing constants
pub const BCM_INIT_DELAY_US: u32 = 10000;             // 10ms init delay
pub const BCM_CMD_TIMEOUT_US: u32 = 1_000_000;        // 1 second timeout

// LCD dimensions
pub const LCD_WIDTH: u16 = 320;
pub const LCD_HEIGHT: u16 = 240;
pub const LCD_BPP: u8 = 16;
pub const LCD_STRIDE: usize = LCD_WIDTH * 2;          // Bytes per line
pub const LCD_FRAMEBUFFER_SIZE: usize = @as(usize, LCD_WIDTH) * LCD_HEIGHT * 2;

// Backlight control (via GPIO)
// iPod Video/Classic uses PWM for backlight brightness
pub const BACKLIGHT_GPIO_PORT: u4 = GPIO_PORT_B;
pub const BACKLIGHT_GPIO_PIN: u5 = 3;

// GPIO Output Enable for LCD
pub const LCD_GPIO_PORT: u4 = GPIO_PORT_I;
pub const LCD_ENABLE_PIN: u5 = 7;
pub const LCD_RESET_PIN: u5 = 5;

// ============================================================
// Click Wheel Controller
// ============================================================
//
// The iPod click wheel uses a capacitive sensor with an optical
// encoder for position tracking. On PP5020/PP5021C, it communicates
// via a dedicated serial interface.
//
// Based on Rockbox firmware/target/arm/ipod/button-clickwheel.c

// Click wheel controller registers
pub const WHEEL_BASE: usize = 0x7000C100;
pub const WHEEL_DATA: usize = WHEEL_BASE + 0x00;      // Wheel packet data
pub const WHEEL_CFG: usize = WHEEL_BASE + 0x04;       // Configuration
pub const WHEEL_PERIOD: usize = WHEEL_BASE + 0x08;    // Sample period
pub const WHEEL_STATUS: usize = WHEEL_BASE + 0x0C;    // Status register

// Wheel data packet format (32-bit):
// Bits 31-24: Touch status (0xFF = touched, 0x00 = not touched)
// Bits 23-16: Button state
// Bits 15-8:  Wheel position (0-95)
// Bits 7-0:   Checksum/reserved

pub const WHEEL_TOUCH_MASK: u32 = 0xFF000000;
pub const WHEEL_TOUCH_SHIFT: u5 = 24;
pub const WHEEL_BUTTON_MASK: u32 = 0x00FF0000;
pub const WHEEL_BUTTON_SHIFT: u5 = 16;
pub const WHEEL_POSITION_MASK: u32 = 0x0000FF00;
pub const WHEEL_POSITION_SHIFT: u5 = 8;

// Button bits in wheel packet
pub const WHEEL_BTN_SELECT: u8 = 0x01;
pub const WHEEL_BTN_RIGHT: u8 = 0x02;
pub const WHEEL_BTN_LEFT: u8 = 0x04;
pub const WHEEL_BTN_PLAY: u8 = 0x08;
pub const WHEEL_BTN_MENU: u8 = 0x10;

// Hold switch is read from GPIO
pub const HOLD_GPIO_PORT: u4 = GPIO_PORT_G;
pub const HOLD_GPIO_PIN: u5 = 0;

// Wheel configuration bits
pub const WHEEL_CFG_ENABLE: u32 = 0x80000000;
pub const WHEEL_CFG_RATE_MASK: u32 = 0x0000FF00;
pub const WHEEL_CFG_INT_EN: u32 = 0x00000001;

// Wheel status bits
pub const WHEEL_STATUS_READY: u32 = 0x80000000;
pub const WHEEL_STATUS_DATA: u32 = 0x00000001;

// Wheel constants
pub const WHEEL_POSITIONS: u8 = 96;               // 0-95 positions
pub const WHEEL_SAMPLE_RATE_MS: u32 = 10;         // 10ms sample period

// ============================================================
// USB Controller
// ============================================================
//
// The PP5021C has an integrated USB 2.0 Full Speed controller.
// Based on Rockbox firmware/target/arm/pp/usb-drv-pp.c
//
// The USB controller supports:
// - Device mode (peripheral)
// - 3 endpoints (EP0 control + 2 bulk/interrupt)
// - Full Speed (12 Mbps)

pub const USB_BASE: usize = 0xC5000000;
pub const USB_NUM_ENDPOINTS: u8 = 3;

// USB Core Registers
pub const USB_DEV_CTRL: usize = USB_BASE + 0x00;       // Device control
pub const USB_DEV_INFO: usize = USB_BASE + 0x04;       // Device info
pub const USB_PHY_CTRL: usize = USB_BASE + 0x08;       // PHY control
pub const USB_INT_STAT: usize = USB_BASE + 0x10;       // Interrupt status
pub const USB_INT_EN: usize = USB_BASE + 0x14;         // Interrupt enable
pub const USB_FRAME_NUM: usize = USB_BASE + 0x18;      // Frame number
pub const USB_DEV_ADDR: usize = USB_BASE + 0x1C;       // Device address
pub const USB_TESTMODE: usize = USB_BASE + 0x20;       // Test mode

// USB Endpoint Control Registers (per endpoint)
// EP0 is at offset 0x40, EP1 at 0x60, EP2 at 0x80
pub const USB_EP0_BASE: usize = USB_BASE + 0x40;
pub const USB_EP1_BASE: usize = USB_BASE + 0x60;
pub const USB_EP2_BASE: usize = USB_BASE + 0x80;

// Per-endpoint register offsets
pub const USB_EP_CTRL: usize = 0x00;      // Endpoint control
pub const USB_EP_STAT: usize = 0x04;      // Endpoint status
pub const USB_EP_TXLEN: usize = 0x08;     // TX packet length
pub const USB_EP_RXLEN: usize = 0x0C;     // RX packet length
pub const USB_EP_MAXPKT: usize = 0x10;    // Max packet size
pub const USB_EP_BUFADDR: usize = 0x14;   // Buffer address

// USB FIFO Registers
pub const USB_FIFO_BASE: usize = USB_BASE + 0x100;
pub const USB_EP0_FIFO: usize = USB_FIFO_BASE + 0x00;
pub const USB_EP1_FIFO: usize = USB_FIFO_BASE + 0x40;
pub const USB_EP2_FIFO: usize = USB_FIFO_BASE + 0x80;

/// Get endpoint base address
pub inline fn usbEpBase(ep: u8) usize {
    return switch (ep) {
        0 => USB_EP0_BASE,
        1 => USB_EP1_BASE,
        2 => USB_EP2_BASE,
        else => USB_EP0_BASE,
    };
}

/// Get endpoint FIFO address
pub inline fn usbEpFifo(ep: u8) usize {
    return switch (ep) {
        0 => USB_EP0_FIFO,
        1 => USB_EP1_FIFO,
        2 => USB_EP2_FIFO,
        else => USB_EP0_FIFO,
    };
}

// USB Device Control bits
pub const USB_DEV_EN: u32 = 0x80000000;             // Device enable
pub const USB_DEV_SOFT_RESET: u32 = 0x40000000;    // Soft reset
pub const USB_DEV_SOFT_CONN: u32 = 0x20000000;     // Soft connect
pub const USB_DEV_HIGH_SPEED: u32 = 0x10000000;    // High speed enable
pub const USB_DEV_REMOTE_WAKE: u32 = 0x08000000;   // Remote wakeup enable

// USB PHY Control bits
pub const USB_PHY_ENABLE: u32 = 0x80000000;         // PHY enable
pub const USB_PHY_SUSPEND: u32 = 0x40000000;        // PHY suspend
pub const USB_PHY_PLL_LOCK: u32 = 0x00000001;       // PLL locked

// USB Interrupt bits
pub const USB_INT_RESET: u32 = 0x80000000;          // Bus reset
pub const USB_INT_SUSPEND: u32 = 0x40000000;        // Suspend
pub const USB_INT_RESUME: u32 = 0x20000000;         // Resume
pub const USB_INT_SOF: u32 = 0x10000000;            // Start of frame
pub const USB_INT_EP0_SETUP: u32 = 0x08000000;      // EP0 setup packet
pub const USB_INT_EP0_RX: u32 = 0x04000000;         // EP0 RX complete
pub const USB_INT_EP0_TX: u32 = 0x02000000;         // EP0 TX complete
pub const USB_INT_EP1_RX: u32 = 0x01000000;         // EP1 RX complete
pub const USB_INT_EP1_TX: u32 = 0x00800000;         // EP1 TX complete
pub const USB_INT_EP2_RX: u32 = 0x00400000;         // EP2 RX complete
pub const USB_INT_EP2_TX: u32 = 0x00200000;         // EP2 TX complete

// USB Endpoint Control bits
pub const USB_EP_EN: u32 = 0x80000000;              // Endpoint enable
pub const USB_EP_TYPE_MASK: u32 = 0x60000000;       // Endpoint type
pub const USB_EP_TYPE_CTRL: u32 = 0x00000000;       // Control
pub const USB_EP_TYPE_ISO: u32 = 0x20000000;        // Isochronous
pub const USB_EP_TYPE_BULK: u32 = 0x40000000;       // Bulk
pub const USB_EP_TYPE_INTR: u32 = 0x60000000;       // Interrupt
pub const USB_EP_DIR_IN: u32 = 0x10000000;          // Direction IN
pub const USB_EP_DIR_OUT: u32 = 0x00000000;         // Direction OUT
pub const USB_EP_STALL: u32 = 0x08000000;           // Stall endpoint
pub const USB_EP_NAK: u32 = 0x04000000;             // NAK endpoint

// USB Endpoint Status bits
pub const USB_EP_STAT_BUSY: u32 = 0x80000000;       // Busy
pub const USB_EP_STAT_DONE: u32 = 0x40000000;       // Transfer done
pub const USB_EP_STAT_ERROR: u32 = 0x20000000;      // Error
pub const USB_EP_STAT_STALL: u32 = 0x10000000;      // Stalled

// USB max packet sizes
pub const USB_EP0_MAX_PKT: u16 = 64;                // Control endpoint
pub const USB_BULK_MAX_PKT: u16 = 512;              // Bulk endpoint (FS: 64, HS: 512)
pub const USB_INTR_MAX_PKT: u16 = 64;               // Interrupt endpoint

// USB Standard Request Types
pub const USB_REQ_TYPE_STANDARD: u8 = 0x00;
pub const USB_REQ_TYPE_CLASS: u8 = 0x20;
pub const USB_REQ_TYPE_VENDOR: u8 = 0x40;
pub const USB_REQ_TYPE_DEVICE: u8 = 0x00;
pub const USB_REQ_TYPE_INTERFACE: u8 = 0x01;
pub const USB_REQ_TYPE_ENDPOINT: u8 = 0x02;
pub const USB_REQ_TYPE_DIR_OUT: u8 = 0x00;
pub const USB_REQ_TYPE_DIR_IN: u8 = 0x80;

// USB Standard Requests
pub const USB_REQ_GET_STATUS: u8 = 0x00;
pub const USB_REQ_CLEAR_FEATURE: u8 = 0x01;
pub const USB_REQ_SET_FEATURE: u8 = 0x03;
pub const USB_REQ_SET_ADDRESS: u8 = 0x05;
pub const USB_REQ_GET_DESCRIPTOR: u8 = 0x06;
pub const USB_REQ_SET_DESCRIPTOR: u8 = 0x07;
pub const USB_REQ_GET_CONFIGURATION: u8 = 0x08;
pub const USB_REQ_SET_CONFIGURATION: u8 = 0x09;
pub const USB_REQ_GET_INTERFACE: u8 = 0x0A;
pub const USB_REQ_SET_INTERFACE: u8 = 0x0B;
pub const USB_REQ_SYNCH_FRAME: u8 = 0x0C;

// USB Descriptor Types
pub const USB_DESC_DEVICE: u8 = 0x01;
pub const USB_DESC_CONFIGURATION: u8 = 0x02;
pub const USB_DESC_STRING: u8 = 0x03;
pub const USB_DESC_INTERFACE: u8 = 0x04;
pub const USB_DESC_ENDPOINT: u8 = 0x05;
pub const USB_DESC_QUALIFIER: u8 = 0x06;

// USB Timeouts
pub const USB_TIMEOUT_US: u32 = 1_000_000;          // 1 second timeout

// ============================================================
// DMA Engine
// ============================================================

pub const DMA_MASTER_CTRL: usize = 0x6000A000;
pub const DMA_MASTER_STATUS: usize = 0x6000A004;
pub const DMA_REQ_STATUS: usize = 0x6000A008;

// DMA channel base addresses
pub const DMA_CHAN0_BASE: usize = 0x6000B000;
pub const DMA_CHAN1_BASE: usize = 0x6000B020;
pub const DMA_CHAN2_BASE: usize = 0x6000B040;
pub const DMA_CHAN3_BASE: usize = 0x6000B060;

// Per-channel register offsets
pub const DMA_CMD_OFF: usize = 0x00;
pub const DMA_STATUS_OFF: usize = 0x04;
pub const DMA_RAM_ADDR_OFF: usize = 0x08;
pub const DMA_FLAGS_OFF: usize = 0x0C;
pub const DMA_PER_ADDR_OFF: usize = 0x10;
pub const DMA_INCR_OFF: usize = 0x14;

// DMA command bits
pub const DMA_CMD_START: u32 = 0x80000000;
pub const DMA_CMD_INTR: u32 = 0x40000000;
pub const DMA_CMD_SLEEP_WAIT: u32 = 0x20000000;
pub const DMA_CMD_RAM_TO_PER: u32 = 0x10000000;
pub const DMA_CMD_SINGLE: u32 = 0x08000000;
pub const DMA_CMD_WAIT_REQ: u32 = 0x01000000;

// DMA request IDs
pub const DMA_REQ_IIS: u8 = 2;
pub const DMA_REQ_IDE: u8 = 7;
pub const DMA_REQ_SDHC: u8 = 13;

// DMA status bits
pub const DMA_STATUS_BUSY: u32 = 0x80000000;
pub const DMA_STATUS_DONE: u32 = 0x40000000;
pub const DMA_STATUS_ERROR: u32 = 0x20000000;
pub const DMA_STATUS_ABORT: u32 = 0x10000000;

// DMA flags bits
pub const DMA_FLAGS_LENGTH_MASK: u32 = 0x0000FFFF;
pub const DMA_FLAGS_REQ_MASK: u32 = 0x001F0000;
pub const DMA_FLAGS_REQ_SHIFT: u5 = 16;
pub const DMA_FLAGS_BURST_MASK: u32 = 0x07000000;
pub const DMA_FLAGS_BURST_SHIFT: u5 = 24;

// DMA burst sizes
pub const DMA_BURST_1: u32 = 0;
pub const DMA_BURST_4: u32 = 1;
pub const DMA_BURST_8: u32 = 2;
pub const DMA_BURST_16: u32 = 3;

// DMA increment modes
pub const DMA_INCR_RAM: u32 = 0x00000001; // Increment RAM address
pub const DMA_INCR_PER: u32 = 0x00000002; // Increment peripheral address
pub const DMA_INCR_BOTH: u32 = 0x00000003; // Increment both

// DMA master control bits
pub const DMA_MASTER_EN: u32 = 0x80000000;
pub const DMA_MASTER_RESET: u32 = 0x40000000;

// DMA channel count
pub const DMA_NUM_CHANNELS: u8 = 4;

/// Get DMA channel base address
pub inline fn dmaChannelBase(channel: u2) usize {
    return DMA_CHAN0_BASE + (@as(usize, channel) * 0x20);
}

// DMA timeout
pub const DMA_TIMEOUT_US: u32 = 5_000_000; // 5 seconds

// ============================================================
// Watchdog Timer
// ============================================================
//
// The PP5021C has a watchdog timer that can reset the system
// if not periodically refreshed.

pub const WDT_BASE: usize = 0x60006100;
pub const WDT_CTRL: usize = WDT_BASE + 0x00;
pub const WDT_COUNTER: usize = WDT_BASE + 0x04;
pub const WDT_REFRESH: usize = WDT_BASE + 0x08;

// Watchdog control bits
pub const WDT_CTRL_ENABLE: u32 = 0x80000000;
pub const WDT_CTRL_RESET_EN: u32 = 0x40000000; // Enable system reset on timeout
pub const WDT_CTRL_IRQ_EN: u32 = 0x20000000; // Enable interrupt on timeout
pub const WDT_CTRL_TIMEOUT_MASK: u32 = 0x0000FFFF;

// Watchdog refresh magic value
pub const WDT_REFRESH_KEY: u32 = 0x5AA55AA5;

// Watchdog timeout values (approximate, in timer ticks)
pub const WDT_TIMEOUT_1S: u32 = 1000;
pub const WDT_TIMEOUT_5S: u32 = 5000;
pub const WDT_TIMEOUT_10S: u32 = 10000;
pub const WDT_TIMEOUT_30S: u32 = 30000;

// ============================================================
// Real-Time Clock (RTC)
// ============================================================
//
// The PP5021C RTC provides seconds counter and alarm functionality.
// The RTC is battery-backed and runs when the device is off.

pub const RTC_BASE: usize = 0x60005014;
pub const RTC_SECONDS: usize = RTC_BASE;          // Current seconds since epoch
pub const RTC_ALARM: usize = RTC_BASE + 0x04;     // Alarm seconds
pub const RTC_CTRL: usize = RTC_BASE + 0x08;      // Control register

// RTC control bits
pub const RTC_CTRL_ENABLE: u32 = 0x80000000;
pub const RTC_CTRL_ALARM_EN: u32 = 0x40000000;
pub const RTC_CTRL_ALARM_IRQ: u32 = 0x20000000;   // Alarm interrupt pending
pub const RTC_CTRL_TICK_IRQ: u32 = 0x10000000;    // 1Hz tick interrupt pending
pub const RTC_CTRL_TICK_EN: u32 = 0x08000000;     // Enable 1Hz tick interrupt

// RTC epoch (Unix time base: Jan 1, 1970)
pub const RTC_UNIX_EPOCH: u32 = 0;

// ============================================================
// PCF50605 Power Management Unit (PMU)
// ============================================================
//
// The PCF50605 is an I2C-based PMU that handles:
// - Battery charging and monitoring
// - Multiple voltage regulators (LDOs, DC-DCs)
// - Power sequencing
// - GPIO expander
// - ADC for battery/temperature monitoring
//
// I2C Address: 0x08 (7-bit)
// Based on Rockbox firmware/drivers/pcf50605.c

pub const PCF50605_I2C_ADDR: u7 = 0x08;

// PCF50605 Register Addresses
pub const PCF_ID: u8 = 0x00;           // Chip ID
pub const PCF_OOCS: u8 = 0x01;         // On/Off Control Status
pub const PCF_INT1: u8 = 0x02;         // Interrupt Status 1
pub const PCF_INT2: u8 = 0x03;         // Interrupt Status 2
pub const PCF_INT3: u8 = 0x04;         // Interrupt Status 3
pub const PCF_INT1M: u8 = 0x05;        // Interrupt Mask 1
pub const PCF_INT2M: u8 = 0x06;        // Interrupt Mask 2
pub const PCF_INT3M: u8 = 0x07;        // Interrupt Mask 3
pub const PCF_OOCC1: u8 = 0x08;        // On/Off Control Config 1
pub const PCF_OOCC2: u8 = 0x09;        // On/Off Control Config 2
pub const PCF_RTCSC: u8 = 0x0A;        // RTC Seconds
pub const PCF_RTCMN: u8 = 0x0B;        // RTC Minutes
pub const PCF_RTCHR: u8 = 0x0C;        // RTC Hours
pub const PCF_RTCWD: u8 = 0x0D;        // RTC Weekday
pub const PCF_RTCDT: u8 = 0x0E;        // RTC Day
pub const PCF_RTCMT: u8 = 0x0F;        // RTC Month
pub const PCF_RTCYR: u8 = 0x10;        // RTC Year
pub const PCF_RTCSCA: u8 = 0x11;       // RTC Alarm Seconds
pub const PCF_RTCMNA: u8 = 0x12;       // RTC Alarm Minutes
pub const PCF_RTCHRA: u8 = 0x13;       // RTC Alarm Hours
pub const PCF_RTCWDA: u8 = 0x14;       // RTC Alarm Weekday
pub const PCF_RTCDTA: u8 = 0x15;       // RTC Alarm Day
pub const PCF_RTCMTA: u8 = 0x16;       // RTC Alarm Month
pub const PCF_RTCYRA: u8 = 0x17;       // RTC Alarm Year
pub const PCF_PSSC: u8 = 0x18;         // Power Sequencer Control
pub const PCF_PWROKM: u8 = 0x19;       // PWROK Mask
pub const PCF_PWROKS: u8 = 0x1A;       // PWROK Status

// Voltage Regulators
pub const PCF_DCDC1: u8 = 0x1B;        // DC-DC1 Control (core voltage)
pub const PCF_DCDC2: u8 = 0x1C;        // DC-DC2 Control
pub const PCF_DCDC3: u8 = 0x1D;        // DC-DC3 Control
pub const PCF_DCDC4: u8 = 0x1E;        // DC-DC4 Control
pub const PCF_DCDEC1: u8 = 0x1F;       // DC-DC Extended Control 1
pub const PCF_DCDEC2: u8 = 0x20;       // DC-DC Extended Control 2
pub const PCF_DCUDC1: u8 = 0x21;       // DC-DC User Defined Control 1
pub const PCF_DCUDC2: u8 = 0x22;       // DC-DC User Defined Control 2
pub const PCF_IOREGC: u8 = 0x23;       // I/O Regulator Control
pub const PCF_D1REGC1: u8 = 0x24;      // D1 Regulator Control 1
pub const PCF_D2REGC1: u8 = 0x25;      // D2 Regulator Control 1
pub const PCF_D3REGC1: u8 = 0x26;      // D3 Regulator Control 1
pub const PCF_LPREGC1: u8 = 0x27;      // LP Regulator Control 1
pub const PCF_LPREGC2: u8 = 0x28;      // LP Regulator Control 2

// GPIO Control
pub const PCF_GPIOCTL: u8 = 0x29;      // GPIO Control
pub const PCF_GPIO1C1: u8 = 0x2A;      // GPIO1 Config 1
pub const PCF_GPIO1C2: u8 = 0x2B;      // GPIO1 Config 2
pub const PCF_GPIO2C1: u8 = 0x2C;      // GPIO2 Config 1
pub const PCF_GPIOS: u8 = 0x2D;        // GPIO Status

// Charger Control
pub const PCF_MBCC1: u8 = 0x2E;        // Main Battery Charger Control 1
pub const PCF_MBCC2: u8 = 0x2F;        // Main Battery Charger Control 2
pub const PCF_MBCC3: u8 = 0x30;        // Main Battery Charger Control 3
pub const PCF_MBCS1: u8 = 0x31;        // Main Battery Charger Status 1
pub const PCF_MBCS2: u8 = 0x32;        // Main Battery Charger Status 2
pub const PCF_MBCS3: u8 = 0x33;        // Main Battery Charger Status 3

// ADC Control
pub const PCF_ADCC1: u8 = 0x34;        // ADC Control 1
pub const PCF_ADCC2: u8 = 0x35;        // ADC Control 2
pub const PCF_ADCS1: u8 = 0x36;        // ADC Status 1 (high byte)
pub const PCF_ADCS2: u8 = 0x37;        // ADC Status 2 (low byte)
pub const PCF_ADCS3: u8 = 0x38;        // ADC Status 3

// Backup Battery
pub const PCF_BBCC: u8 = 0x39;         // Backup Battery Charger Control

// OOCS (On/Off Control Status) bits
pub const PCF_OOCS_ONKEY: u8 = 0x01;   // On key pressed
pub const PCF_OOCS_USB: u8 = 0x04;     // USB connected
pub const PCF_OOCS_CHG: u8 = 0x08;     // Charger connected
pub const PCF_OOCS_BATOK: u8 = 0x10;   // Battery OK
pub const PCF_OOCS_RECKEY: u8 = 0x20;  // Recording key

// INT1 (Interrupt 1) bits
pub const PCF_INT1_ONKEY: u8 = 0x01;   // On key change
pub const PCF_INT1_EXTONR: u8 = 0x02;  // External power on rising
pub const PCF_INT1_EXTONF: u8 = 0x04;  // External power on falling
pub const PCF_INT1_EXTON2R: u8 = 0x08; // External power 2 on rising
pub const PCF_INT1_EXTON2F: u8 = 0x10; // External power 2 on falling
pub const PCF_INT1_ALARM: u8 = 0x40;   // RTC alarm
pub const PCF_INT1_SECOND: u8 = 0x80;  // RTC second tick

// INT2 (Interrupt 2) bits
pub const PCF_INT2_CHGWD: u8 = 0x01;   // Charger watchdog
pub const PCF_INT2_CHGEVT: u8 = 0x02;  // Charger event
pub const PCF_INT2_VMAX: u8 = 0x04;    // Voltage max reached
pub const PCF_INT2_CHGERR: u8 = 0x08;  // Charger error
pub const PCF_INT2_CHGRES: u8 = 0x10;  // Charger resume
pub const PCF_INT2_THLIMON: u8 = 0x20; // Thermal limit on
pub const PCF_INT2_THLIMOFF: u8 = 0x40;// Thermal limit off
pub const PCF_INT2_BATFUL: u8 = 0x80;  // Battery full

// MBCC1 (Main Battery Charger Control 1) bits
pub const PCF_MBCC1_CHGENA: u8 = 0x01; // Charger enable
pub const PCF_MBCC1_AUTOFST: u8 = 0x02;// Auto fast charge
pub const PCF_MBCC1_AUTORES: u8 = 0x04;// Auto resume

// MBCS1 (Main Battery Charger Status 1) bits
pub const PCF_MBCS1_PREG: u8 = 0x01;   // Pre-charge phase
pub const PCF_MBCS1_CCCV: u8 = 0x02;   // CC/CV phase
pub const PCF_MBCS1_VBAT: u8 = 0x04;   // VBAT comparator
pub const PCF_MBCS1_BAT: u8 = 0x08;    // Battery present
pub const PCF_MBCS1_USB: u8 = 0x10;    // USB power present
pub const PCF_MBCS1_ADP: u8 = 0x20;    // Adapter power present
pub const PCF_MBCS1_CHGEND: u8 = 0x40; // Charge end
pub const PCF_MBCS1_BATFUL: u8 = 0x80; // Battery full

// ADCC1 (ADC Control 1) bits
pub const PCF_ADCC1_ADCSTART: u8 = 0x01;// Start conversion
pub const PCF_ADCC1_RES_10BIT: u8 = 0x02;// 10-bit resolution
pub const PCF_ADCC1_AVERAGE: u8 = 0x04; // Average 4 samples

// ADC Channel selection (in ADCC2)
pub const PCF_ADCC2_VBAT: u8 = 0x00;   // Battery voltage
pub const PCF_ADCC2_VBATREF: u8 = 0x01;// Battery reference
pub const PCF_ADCC2_ADCIN1: u8 = 0x02; // ADC input 1
pub const PCF_ADCC2_ADCIN2: u8 = 0x03; // ADC input 2
pub const PCF_ADCC2_BATTEMP: u8 = 0x04;// Battery temperature
pub const PCF_ADCC2_SUBTR: u8 = 0x08;  // Subtract mode

// Battery voltage thresholds (in mV)
pub const PCF_BATTERY_FULL_MV: u16 = 4100;
pub const PCF_BATTERY_LOW_MV: u16 = 3400;
pub const PCF_BATTERY_CRITICAL_MV: u16 = 3200;
pub const PCF_BATTERY_EMPTY_MV: u16 = 3000;

// ADC conversion factor: 10-bit ADC, VBAT = ADC * 6 / 1024 * 1000 mV
// Simplified: mV = ADC * 5860 / 1000 (approximately)
pub const PCF_ADC_TO_MV_NUM: u32 = 5860;
pub const PCF_ADC_TO_MV_DEN: u32 = 1000;

// ============================================================
// Cache Controller
// ============================================================

pub const CACHE_CTL: usize = 0x6000C000;
pub const CACHE_MASK: usize = 0x6000C004;
pub const CACHE_OPERATION: usize = 0x6000C008;
pub const CACHE_FLUSH_MASK: usize = 0x6000C00C;

// Cache control bits
pub const CACHE_CTL_ENABLE: u32 = 0x80000000;
pub const CACHE_CTL_RUN: u32 = 0x40000000;
pub const CACHE_CTL_INIT: u32 = 0x20000000;
pub const CACHE_CTL_VECT_REMAP: u32 = 0x10000000;
pub const CACHE_CTL_READY: u32 = 0x00000002;
pub const CACHE_CTL_BUSY: u32 = 0x00000001;

// Cache operations
pub const CACHE_OP_FLUSH: u32 = 0x01;
pub const CACHE_OP_INVALIDATE: u32 = 0x02;

// Cache alignment
pub const CACHEALIGN_SIZE: usize = 16;

// ============================================================
// Device Initialization
// ============================================================

pub const PP_VER1: usize = 0x70000000;
pub const PP_VER2: usize = 0x70000004;
pub const STRAP_OPT_A: usize = 0x70000010;
pub const DEV_INIT1: usize = 0x70000020;
pub const DEV_INIT2: usize = 0x70000024;
pub const GPO32_VAL: usize = 0x70000080;
pub const GPO32_EN: usize = 0x70000084;

pub const INIT_BUTTONS: u32 = 0x00000008;

// ============================================================
// Tests
// ============================================================

test "register address calculations" {
    // Verify GPIO register calculation
    try std.testing.expectEqual(@as(usize, 0x6000D000), gpioReg(0, GPIO_ENABLE_OFF));
    try std.testing.expectEqual(@as(usize, 0x6000D020), gpioReg(1, GPIO_ENABLE_OFF));
    try std.testing.expectEqual(@as(usize, 0x6000D034), gpioReg(1, GPIO_OUTPUT_VAL_OFF));

    // Verify I2C data register calculation
    try std.testing.expectEqual(@as(usize, 0x7000C00C), i2cDataReg(0));
    try std.testing.expectEqual(@as(usize, 0x7000C010), i2cDataReg(1));

    // Verify BCM command encoding
    try std.testing.expectEqual(@as(u32, 0xFFFF0000), bcmCmd(0x00));
    try std.testing.expectEqual(@as(u32, 0xFFFA0005), bcmCmd(0x05));
}
