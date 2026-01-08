//! PP5021C Hardware Implementation
//!
//! This module provides the actual hardware implementation of the HAL
//! for the PortalPlayer PP5021C SoC used in iPod Video 5th Generation.
//!
//! WARNING: This code directly accesses hardware registers. Only use on
//! actual iPod hardware. Use mock implementation for testing.

const std = @import("std");
const reg = @import("registers.zig");
const hal_types = @import("../hal.zig");
const Hal = hal_types.Hal;
const HalError = hal_types.HalError;
const GpioDirection = hal_types.GpioDirection;
const GpioInterruptMode = hal_types.GpioInterruptMode;
const I2sFormat = hal_types.I2sFormat;
const I2sSampleSize = hal_types.I2sSampleSize;
const AtaDeviceInfo = hal_types.AtaDeviceInfo;

// ============================================================
// Internal State
// ============================================================

var system_initialized: bool = false;
var i2c_initialized: bool = false;
var i2s_initialized: bool = false;
var ata_initialized: bool = false;
var lcd_initialized: bool = false;

// ============================================================
// System Functions
// ============================================================

fn hwSystemInit() HalError!void {
    // Disable all interrupts first
    hwIrqDisable();
    reg.writeReg(u32, reg.CPU_INT_EN, 0);
    reg.writeReg(u32, reg.COP_INT_EN, 0);
    reg.writeReg(u32, reg.CPU_HI_INT_EN, 0);
    reg.writeReg(u32, reg.COP_HI_INT_EN, 0);

    // Clear pending interrupts
    reg.writeReg(u32, reg.CPU_INT_CLR, 0xFFFFFFFF);
    reg.writeReg(u32, reg.COP_INT_CLR, 0xFFFFFFFF);
    reg.writeReg(u32, reg.CPU_HI_INT_CLR, 0xFFFFFFFF);
    reg.writeReg(u32, reg.COP_HI_INT_CLR, 0xFFFFFFFF);

    // Disable GPIO interrupts on all ports
    var port: u4 = 0;
    while (port < 12) : (port += 1) {
        reg.writeReg(u32, reg.gpioReg(port, reg.GPIO_INT_EN_OFF), 0);
    }

    // Enable required device clocks
    var dev_en = reg.readReg(u32, reg.DEV_EN);
    dev_en |= reg.DEV_SYSTEM | reg.DEV_EXTCLOCKS | reg.DEV_I2C;
    reg.writeReg(u32, reg.DEV_EN, dev_en);

    // Small delay for clocks to stabilize
    hwDelayUs(100);

    system_initialized = true;
}

fn hwGetTicksUs() u64 {
    return reg.readReg(u32, reg.USEC_TIMER);
}

fn hwDelayUs(us: u32) void {
    const start = reg.readReg(u32, reg.USEC_TIMER);
    while (reg.readReg(u32, reg.USEC_TIMER) -% start < us) {
        // Busy wait - could add yield here
    }
}

fn hwDelayMs(ms: u32) void {
    var i: u32 = 0;
    while (i < ms) : (i += 1) {
        hwDelayUs(1000);
    }
}

fn hwSleep() void {
    // Enter sleep mode, wake on interrupt
    reg.writeReg(u32, reg.CPU_CTL, reg.PROC_SLEEP | reg.PROC_WAKE_INT);
}

fn hwReset() noreturn {
    // Trigger system reset
    // This typically involves writing to a reset register or watchdog
    // For now, just hang
    while (true) {
        hwSleep();
    }
}

// ============================================================
// GPIO Functions
// ============================================================

fn hwGpioSetDirection(port: u4, pin: u5, direction: GpioDirection) void {
    if (port >= 12 or pin >= 32) return;

    const pin_mask = @as(u32, 1) << pin;

    // Enable GPIO function
    reg.modifyReg(reg.gpioReg(port, reg.GPIO_ENABLE_OFF), 0, pin_mask);

    // Set direction
    if (direction == .output) {
        reg.modifyReg(reg.gpioReg(port, reg.GPIO_OUTPUT_EN_OFF), 0, pin_mask);
    } else {
        reg.modifyReg(reg.gpioReg(port, reg.GPIO_OUTPUT_EN_OFF), pin_mask, 0);
    }
}

fn hwGpioWrite(port: u4, pin: u5, value: bool) void {
    if (port >= 12 or pin >= 32) return;

    const pin_mask = @as(u32, 1) << pin;
    if (value) {
        reg.modifyReg(reg.gpioReg(port, reg.GPIO_OUTPUT_VAL_OFF), 0, pin_mask);
    } else {
        reg.modifyReg(reg.gpioReg(port, reg.GPIO_OUTPUT_VAL_OFF), pin_mask, 0);
    }
}

fn hwGpioRead(port: u4, pin: u5) bool {
    if (port >= 12 or pin >= 32) return false;

    const pin_mask = @as(u32, 1) << pin;
    const val = reg.readReg(u32, reg.gpioReg(port, reg.GPIO_INPUT_VAL_OFF));
    return (val & pin_mask) != 0;
}

fn hwGpioSetInterrupt(port: u4, pin: u5, mode: GpioInterruptMode) void {
    if (port >= 12 or pin >= 32) return;

    const pin_mask = @as(u32, 1) << pin;

    if (mode == .none) {
        reg.modifyReg(reg.gpioReg(port, reg.GPIO_INT_EN_OFF), pin_mask, 0);
    } else {
        // Configure level/edge sensitivity
        const level_mode = (mode == .high_level or mode == .low_level);
        if (level_mode) {
            reg.modifyReg(reg.gpioReg(port, reg.GPIO_INT_LEV_OFF), 0, pin_mask);
        } else {
            reg.modifyReg(reg.gpioReg(port, reg.GPIO_INT_LEV_OFF), pin_mask, 0);
        }

        // Enable interrupt
        reg.modifyReg(reg.gpioReg(port, reg.GPIO_INT_EN_OFF), 0, pin_mask);
    }
}

// ============================================================
// I2C Functions
// ============================================================

const I2C_TIMEOUT_US: u32 = 1_000_000; // 1 second

fn i2cWaitNotBusy() HalError!void {
    const start = hwGetTicksUs();
    while (true) {
        const status = reg.readReg(u8, reg.I2C_STATUS);
        if ((status & reg.I2C_BUSY) == 0) {
            return;
        }
        if (hwGetTicksUs() - start > I2C_TIMEOUT_US) {
            return HalError.Timeout;
        }
    }
}

fn hwI2cInit() HalError!void {
    // Enable I2C device
    reg.modifyReg(reg.DEV_EN, 0, reg.DEV_I2C);
    hwDelayUs(100);
    i2c_initialized = true;
}

fn hwI2cWrite(addr: u7, data: []const u8) HalError!void {
    if (!i2c_initialized) return HalError.DeviceNotReady;
    if (data.len == 0 or data.len > 4) return HalError.InvalidParameter;

    try i2cWaitNotBusy();

    // Write data to registers
    var i: usize = 0;
    while (i < data.len and i < 4) : (i += 1) {
        reg.writeReg(u8, reg.i2cDataReg(@truncate(i)), data[i]);
    }

    // Set address (7-bit address shifted left, write mode)
    reg.writeReg(u8, reg.I2C_ADDR, @as(u8, addr) << 1);

    // Start transfer
    const ctrl = @as(u8, @truncate((data.len - 1) << 1)) | reg.I2C_SEND;
    reg.writeReg(u8, reg.I2C_CTRL, ctrl);

    // Wait for completion
    try i2cWaitNotBusy();
}

fn hwI2cRead(addr: u7, buffer: []u8) HalError!usize {
    if (!i2c_initialized) return HalError.DeviceNotReady;
    if (buffer.len == 0 or buffer.len > 4) return HalError.InvalidParameter;

    try i2cWaitNotBusy();

    // Set address (7-bit address shifted left, read mode)
    reg.writeReg(u8, reg.I2C_ADDR, (@as(u8, addr) << 1) | reg.I2C_READ_BIT);

    // Start transfer
    const ctrl = @as(u8, @truncate((buffer.len - 1) << 1)) | reg.I2C_SEND;
    reg.writeReg(u8, reg.I2C_CTRL, ctrl);

    // Wait for completion
    try i2cWaitNotBusy();

    // Read data from registers
    var i: usize = 0;
    while (i < buffer.len and i < 4) : (i += 1) {
        buffer[i] = reg.readReg(u8, reg.i2cDataReg(@truncate(i)));
    }

    return buffer.len;
}

fn hwI2cWriteRead(addr: u7, write_data: []const u8, read_buffer: []u8) HalError!usize {
    try hwI2cWrite(addr, write_data);
    return try hwI2cRead(addr, read_buffer);
}

// ============================================================
// I2S Functions
// ============================================================

fn hwI2sInit(sample_rate: u32, format: I2sFormat, sample_size: I2sSampleSize) HalError!void {
    _ = sample_rate; // TODO: Configure sample rate divider

    // Reset I2S
    reg.writeReg(u32, reg.IISCONFIG, reg.IIS_RESET);
    hwDelayUs(100);
    reg.writeReg(u32, reg.IISCONFIG, 0);

    // Configure format
    var config: u32 = 0;

    switch (format) {
        .i2s_standard => config |= reg.IIS_FORMAT_IIS,
        .left_justified => config |= reg.IIS_FORMAT_LJUST,
        .right_justified => {}, // Default
    }

    switch (sample_size) {
        .bits_16 => config |= reg.IIS_SIZE_16BIT,
        .bits_24 => config |= reg.IIS_SIZE_24BIT,
        .bits_32 => config |= reg.IIS_SIZE_32BIT,
    }

    // Set as master
    config |= reg.IIS_MASTER;

    reg.writeReg(u32, reg.IISCONFIG, config);

    i2s_initialized = true;
}

fn hwI2sWrite(samples: []const i16) HalError!usize {
    if (!i2s_initialized) return HalError.DeviceNotReady;

    var written: usize = 0;
    for (samples) |sample| {
        // Wait for FIFO space
        while (hwI2sTxFreeSlots() == 0) {}

        // Write sample (both channels, same value for mono)
        const sample32 = @as(u32, @bitCast(@as(i32, sample)));
        reg.writeReg(u32, reg.IISFIFO_WR, (sample32 << 16) | (sample32 & 0xFFFF));
        written += 1;
    }

    return written;
}

fn hwI2sTxReady() bool {
    return hwI2sTxFreeSlots() > 0;
}

fn hwI2sTxFreeSlots() usize {
    const cfg = reg.readReg(u32, reg.IISFIFO_CFG);
    return (cfg & reg.IIS_TX_FREE_MASK) >> reg.IIS_TX_FREE_SHIFT;
}

fn hwI2sEnable(enable: bool) void {
    if (enable) {
        reg.modifyReg(reg.IISCONFIG, 0, reg.IIS_TXFIFOEN);
    } else {
        reg.modifyReg(reg.IISCONFIG, reg.IIS_TXFIFOEN, 0);
    }
}

// ============================================================
// Timer Functions
// ============================================================

fn hwTimerStart(timer_id: u2, period_us: u32, callback: ?*const fn () void) HalError!void {
    _ = callback; // TODO: Store callback for interrupt handler

    const cfg_reg = if (timer_id == 0) reg.TIMER1_CFG else reg.TIMER2_CFG;
    const val_reg = if (timer_id == 0) reg.TIMER1_VAL else reg.TIMER2_VAL;

    reg.writeReg(u32, val_reg, period_us);
    reg.writeReg(u32, cfg_reg, 0x80000000); // Enable timer
}

fn hwTimerStop(timer_id: u2) void {
    const cfg_reg = if (timer_id == 0) reg.TIMER1_CFG else reg.TIMER2_CFG;
    reg.writeReg(u32, cfg_reg, 0);
}

// ============================================================
// ATA Functions - PIO Mode Implementation
// ============================================================

// ATA drive state
var ata_supports_lba48: bool = false;
var ata_total_sectors: u64 = 0;

/// Wait for BSY flag to clear with timeout
fn ataWaitNotBusy() HalError!void {
    const start = hwGetTicksUs();
    while (true) {
        const status = reg.readReg(u8, reg.ATA_ALTSTATUS);
        if ((status & reg.ATA_STATUS_BSY) == 0) {
            return;
        }
        if (hwGetTicksUs() - start > reg.ATA_TIMEOUT_BSY_US) {
            return HalError.Timeout;
        }
    }
}

/// Wait for DRDY flag to be set
fn ataWaitReady() HalError!void {
    const start = hwGetTicksUs();
    while (true) {
        const status = reg.readReg(u8, reg.ATA_ALTSTATUS);
        if ((status & reg.ATA_STATUS_BSY) == 0 and (status & reg.ATA_STATUS_DRDY) != 0) {
            return;
        }
        if (hwGetTicksUs() - start > reg.ATA_TIMEOUT_BSY_US) {
            return HalError.Timeout;
        }
    }
}

/// Wait for DRQ flag to be set (data ready)
fn ataWaitDrq() HalError!void {
    const start = hwGetTicksUs();
    while (true) {
        const status = reg.readReg(u8, reg.ATA_ALTSTATUS);
        if ((status & reg.ATA_STATUS_BSY) == 0) {
            if ((status & reg.ATA_STATUS_DRQ) != 0) {
                return;
            }
            if ((status & reg.ATA_STATUS_ERR) != 0) {
                return HalError.IOError;
            }
        }
        if (hwGetTicksUs() - start > reg.ATA_TIMEOUT_DRQ_US) {
            return HalError.Timeout;
        }
    }
}

/// Check for errors after command completion
fn ataCheckError() HalError!void {
    const status = reg.readReg(u8, reg.ATA_STATUS);
    if ((status & reg.ATA_STATUS_ERR) != 0) {
        return HalError.IOError;
    }
    if ((status & reg.ATA_STATUS_DF) != 0) {
        return HalError.DeviceError;
    }
}

/// Perform software reset of ATA controller
fn ataReset() void {
    // Set SRST bit
    reg.writeReg(u8, reg.ATA_CONTROL, reg.ATA_CTL_SRST | reg.ATA_CTL_NIEN);
    hwDelayUs(5);
    // Clear SRST bit
    reg.writeReg(u8, reg.ATA_CONTROL, reg.ATA_CTL_NIEN);
    hwDelayMs(2);
}

/// Setup LBA28 address in task file registers
fn ataSetupLba28(lba: u32, count: u8) void {
    reg.writeReg(u8, reg.ATA_NSECTOR, count);
    reg.writeReg(u8, reg.ATA_SECTOR, @truncate(lba & 0xFF));
    reg.writeReg(u8, reg.ATA_LCYL, @truncate((lba >> 8) & 0xFF));
    reg.writeReg(u8, reg.ATA_HCYL, @truncate((lba >> 16) & 0xFF));
    reg.writeReg(u8, reg.ATA_SELECT, reg.ATA_DEV_LBA | @as(u8, @truncate((lba >> 24) & 0x0F)));
}

/// Setup LBA48 address in task file registers
fn ataSetupLba48(lba: u64, count: u16) void {
    // Write high bytes first (for LBA48)
    reg.writeReg(u8, reg.ATA_NSECTOR, @truncate((count >> 8) & 0xFF));
    reg.writeReg(u8, reg.ATA_SECTOR, @truncate((lba >> 24) & 0xFF));
    reg.writeReg(u8, reg.ATA_LCYL, @truncate((lba >> 32) & 0xFF));
    reg.writeReg(u8, reg.ATA_HCYL, @truncate((lba >> 40) & 0xFF));

    // Write low bytes
    reg.writeReg(u8, reg.ATA_NSECTOR, @truncate(count & 0xFF));
    reg.writeReg(u8, reg.ATA_SECTOR, @truncate(lba & 0xFF));
    reg.writeReg(u8, reg.ATA_LCYL, @truncate((lba >> 8) & 0xFF));
    reg.writeReg(u8, reg.ATA_HCYL, @truncate((lba >> 16) & 0xFF));

    // Select device with LBA mode
    reg.writeReg(u8, reg.ATA_SELECT, reg.ATA_DEV_LBA);
}

/// Read one sector (256 words) from data register
fn ataReadSectorData(buffer: []u8) void {
    const words = @min(buffer.len / 2, 256);
    var i: usize = 0;
    while (i < words) : (i += 1) {
        const word = reg.readReg(u16, reg.ATA_DATA);
        buffer[i * 2] = @truncate(word & 0xFF);
        buffer[i * 2 + 1] = @truncate((word >> 8) & 0xFF);
    }
}

/// Write one sector (256 words) to data register
fn ataWriteSectorData(data: []const u8) void {
    const words = @min(data.len / 2, 256);
    var i: usize = 0;
    while (i < words) : (i += 1) {
        const word: u16 = @as(u16, data[i * 2]) | (@as(u16, data[i * 2 + 1]) << 8);
        reg.writeReg(u16, reg.ATA_DATA, word);
    }
}

fn hwAtaInit() HalError!void {
    // Enable ATA controller clock
    reg.modifyReg(reg.DEV_EN, 0, reg.DEV_ATA);
    hwDelayMs(10);

    // Reset IDE controller
    var cfg = reg.readReg(u32, reg.IDE0_CFG);
    cfg |= reg.IDE_CFG_RESET;
    reg.writeReg(u32, reg.IDE0_CFG, cfg);
    hwDelayMs(1);
    cfg &= ~reg.IDE_CFG_RESET;
    reg.writeReg(u32, reg.IDE0_CFG, cfg);
    hwDelayMs(10);

    // Perform software reset
    ataReset();

    // Wait for drive to be ready
    ataWaitNotBusy() catch |err| {
        return err;
    };

    // Disable interrupts (we use polling)
    reg.writeReg(u8, reg.ATA_CONTROL, reg.ATA_CTL_NIEN);

    ata_initialized = true;
}

fn hwAtaIdentify() HalError!AtaDeviceInfo {
    if (!ata_initialized) return HalError.DeviceNotReady;

    try ataWaitReady();

    // Select device 0 (master)
    reg.writeReg(u8, reg.ATA_SELECT, reg.ATA_DEV_LBA);
    hwDelayUs(1);

    // Issue IDENTIFY command
    reg.writeReg(u8, reg.ATA_COMMAND, reg.ATA_CMD_IDENTIFY);

    // Wait for data
    try ataWaitDrq();

    // Read 512 bytes of identify data
    var identify_data: [512]u8 = undefined;
    ataReadSectorData(&identify_data);

    // Check for errors
    try ataCheckError();

    // Parse identify data
    var info = AtaDeviceInfo{
        .model = [_]u8{' '} ** 40,
        .serial = [_]u8{' '} ** 20,
        .firmware = [_]u8{' '} ** 8,
        .total_sectors = 0,
        .sector_size = 512,
        .supports_lba48 = false,
        .supports_dma = false,
    };

    // Serial number: words 10-19 (bytes 20-39), byte-swapped
    var i: usize = 0;
    while (i < 20) : (i += 2) {
        info.serial[i] = identify_data[20 + i + 1];
        info.serial[i + 1] = identify_data[20 + i];
    }

    // Firmware revision: words 23-26 (bytes 46-53), byte-swapped
    i = 0;
    while (i < 8) : (i += 2) {
        info.firmware[i] = identify_data[46 + i + 1];
        info.firmware[i + 1] = identify_data[46 + i];
    }

    // Model number: words 27-46 (bytes 54-93), byte-swapped
    i = 0;
    while (i < 40) : (i += 2) {
        info.model[i] = identify_data[54 + i + 1];
        info.model[i + 1] = identify_data[54 + i];
    }

    // Capabilities: word 49 (bytes 98-99)
    const capabilities = @as(u16, identify_data[98]) | (@as(u16, identify_data[99]) << 8);
    info.supports_dma = (capabilities & 0x0100) != 0; // DMA supported

    // Command set support: word 83 (bytes 166-167)
    const cmd_set = @as(u16, identify_data[166]) | (@as(u16, identify_data[167]) << 8);
    info.supports_lba48 = (cmd_set & 0x0400) != 0; // 48-bit LBA supported

    // Total sectors (LBA28): words 60-61 (bytes 120-123)
    const lba28_sectors = @as(u32, identify_data[120]) |
        (@as(u32, identify_data[121]) << 8) |
        (@as(u32, identify_data[122]) << 16) |
        (@as(u32, identify_data[123]) << 24);

    if (info.supports_lba48) {
        // Total sectors (LBA48): words 100-103 (bytes 200-207)
        const lba48_sectors = @as(u64, identify_data[200]) |
            (@as(u64, identify_data[201]) << 8) |
            (@as(u64, identify_data[202]) << 16) |
            (@as(u64, identify_data[203]) << 24) |
            (@as(u64, identify_data[204]) << 32) |
            (@as(u64, identify_data[205]) << 40) |
            (@as(u64, identify_data[206]) << 48) |
            (@as(u64, identify_data[207]) << 56);
        info.total_sectors = lba48_sectors;
    } else {
        info.total_sectors = lba28_sectors;
    }

    // Store for internal use
    ata_supports_lba48 = info.supports_lba48;
    ata_total_sectors = info.total_sectors;

    return info;
}

fn hwAtaReadSectors(lba: u64, count: u16, buffer: []u8) HalError!void {
    if (!ata_initialized) return HalError.DeviceNotReady;
    if (count == 0) return;
    if (buffer.len < @as(usize, count) * reg.ATA_SECTOR_SIZE) return HalError.InvalidParameter;

    try ataWaitReady();

    const use_lba48 = ata_supports_lba48 and (lba >= 0x10000000 or count > 256);

    if (use_lba48) {
        ataSetupLba48(lba, count);
        reg.writeReg(u8, reg.ATA_COMMAND, reg.ATA_CMD_READ_SECTORS_EXT);
    } else {
        if (lba >= 0x10000000) return HalError.InvalidParameter;
        if (count > 256) return HalError.InvalidParameter;
        const count8: u8 = if (count == 256) 0 else @truncate(count);
        ataSetupLba28(@truncate(lba), count8);
        reg.writeReg(u8, reg.ATA_COMMAND, reg.ATA_CMD_READ_SECTORS);
    }

    // Read each sector
    var sector: u16 = 0;
    while (sector < count) : (sector += 1) {
        try ataWaitDrq();

        const offset = @as(usize, sector) * reg.ATA_SECTOR_SIZE;
        ataReadSectorData(buffer[offset..][0..reg.ATA_SECTOR_SIZE]);
    }

    // Check final status
    try ataWaitNotBusy();
    try ataCheckError();
}

fn hwAtaWriteSectors(lba: u64, count: u16, data: []const u8) HalError!void {
    if (!ata_initialized) return HalError.DeviceNotReady;
    if (count == 0) return;
    if (data.len < @as(usize, count) * reg.ATA_SECTOR_SIZE) return HalError.InvalidParameter;

    try ataWaitReady();

    const use_lba48 = ata_supports_lba48 and (lba >= 0x10000000 or count > 256);

    if (use_lba48) {
        ataSetupLba48(lba, count);
        reg.writeReg(u8, reg.ATA_COMMAND, reg.ATA_CMD_WRITE_SECTORS_EXT);
    } else {
        if (lba >= 0x10000000) return HalError.InvalidParameter;
        if (count > 256) return HalError.InvalidParameter;
        const count8: u8 = if (count == 256) 0 else @truncate(count);
        ataSetupLba28(@truncate(lba), count8);
        reg.writeReg(u8, reg.ATA_COMMAND, reg.ATA_CMD_WRITE_SECTORS);
    }

    // Write each sector
    var sector: u16 = 0;
    while (sector < count) : (sector += 1) {
        try ataWaitDrq();

        const offset = @as(usize, sector) * reg.ATA_SECTOR_SIZE;
        ataWriteSectorData(data[offset..][0..reg.ATA_SECTOR_SIZE]);
    }

    // Wait for command completion
    try ataWaitNotBusy();
    try ataCheckError();
}

fn hwAtaFlush() HalError!void {
    if (!ata_initialized) return HalError.DeviceNotReady;

    try ataWaitReady();

    // Use extended flush for LBA48 drives
    if (ata_supports_lba48) {
        reg.writeReg(u8, reg.ATA_COMMAND, reg.ATA_CMD_FLUSH_CACHE_EXT);
    } else {
        reg.writeReg(u8, reg.ATA_COMMAND, reg.ATA_CMD_FLUSH_CACHE);
    }

    // Flush can take a while
    const start = hwGetTicksUs();
    while (true) {
        const status = reg.readReg(u8, reg.ATA_ALTSTATUS);
        if ((status & reg.ATA_STATUS_BSY) == 0) {
            break;
        }
        if (hwGetTicksUs() - start > 30_000_000) { // 30 second timeout for flush
            return HalError.Timeout;
        }
    }

    try ataCheckError();
}

fn hwAtaStandby() HalError!void {
    if (!ata_initialized) return HalError.DeviceNotReady;

    try ataWaitReady();

    reg.writeReg(u8, reg.ATA_COMMAND, reg.ATA_CMD_STANDBY_IMMEDIATE);

    try ataWaitNotBusy();
    try ataCheckError();
}

// ============================================================
// LCD Functions - BCM2722 VideoCore Implementation
// ============================================================

// BCM state tracking
var bcm_framebuffer_addr: u32 = 0;

/// Wait for BCM to be ready to accept a write
fn bcmWaitWriteReady() HalError!void {
    const start = hwGetTicksUs();
    while (true) {
        const ctrl = reg.readReg(u32, reg.BCM_CONTROL);
        if ((ctrl & reg.BCM_CTRL_WRITE_READY) != 0) {
            return;
        }
        if (hwGetTicksUs() - start > reg.BCM_CMD_TIMEOUT_US) {
            return HalError.Timeout;
        }
    }
}

/// Wait for BCM to have data ready for reading
fn bcmWaitReadReady() HalError!void {
    const start = hwGetTicksUs();
    while (true) {
        const ctrl = reg.readReg(u32, reg.BCM_CONTROL);
        if ((ctrl & reg.BCM_CTRL_READ_READY) != 0) {
            return;
        }
        if (hwGetTicksUs() - start > reg.BCM_CMD_TIMEOUT_US) {
            return HalError.Timeout;
        }
    }
}

/// Write a 32-bit value to BCM at specified address
fn bcmWrite32(addr: u32, value: u32) HalError!void {
    try bcmWaitWriteReady();
    reg.writeReg(u32, reg.BCM_WR_ADDR, addr);
    try bcmWaitWriteReady();
    reg.writeReg(u32, reg.BCM_DATA, value);
}

/// Read a 32-bit value from BCM at specified address
fn bcmRead32(addr: u32) HalError!u32 {
    try bcmWaitWriteReady();
    reg.writeReg(u32, reg.BCM_RD_ADDR, addr);
    try bcmWaitReadReady();
    return reg.readReg(u32, reg.BCM_DATA);
}

/// Send a command to the BCM
fn bcmSendCommand(cmd: u32) HalError!void {
    try bcmWrite32(reg.BCM_WR_CMD, cmd);
}

/// Send a command and get response
fn bcmCommand(cmd: u32) HalError!u32 {
    try bcmSendCommand(cmd);
    return try bcmRead32(reg.BCM_RD_CMD);
}

fn hwLcdInit() HalError!void {
    // Enable LCD device clock
    reg.modifyReg(reg.DEV_EN, 0, reg.DEV_LCD);
    hwDelayMs(10);

    // Setup LCD GPIO pins
    hwGpioSetDirection(reg.LCD_GPIO_PORT, reg.LCD_ENABLE_PIN, .output);
    hwGpioSetDirection(reg.LCD_GPIO_PORT, reg.LCD_RESET_PIN, .output);

    // Reset sequence
    hwGpioWrite(reg.LCD_GPIO_PORT, reg.LCD_RESET_PIN, false);
    hwDelayMs(10);
    hwGpioWrite(reg.LCD_GPIO_PORT, reg.LCD_RESET_PIN, true);
    hwDelayMs(50);

    // Enable LCD
    hwGpioWrite(reg.LCD_GPIO_PORT, reg.LCD_ENABLE_PIN, true);
    hwDelayMs(reg.BCM_INIT_DELAY_US / 1000);

    // Verify BCM is responding by getting dimensions
    const width = bcmCommand(reg.BCMCMD_GET_WIDTH) catch |err| {
        // BCM not responding - this is expected if firmware isn't loaded
        // On real hardware, the ROM bootloader loads BCM firmware
        _ = err;
        lcd_initialized = true;
        return;
    };

    const height = bcmCommand(reg.BCMCMD_GET_HEIGHT) catch {
        lcd_initialized = true;
        return;
    };

    // Verify dimensions match expected
    if (width != reg.LCD_WIDTH or height != reg.LCD_HEIGHT) {
        // Dimensions mismatch - BCM may be misconfigured
        // Continue anyway, firmware may configure it
    }

    // Get framebuffer memory address from BCM
    bcm_framebuffer_addr = bcmCommand(reg.BCMCMD_GETMEMADDR) catch 0;

    // Wake the display
    bcmSendCommand(reg.BCMCMD_LCD_WAKE) catch {};
    hwDelayMs(10);

    // Power on
    bcmSendCommand(reg.BCMCMD_LCD_POWER) catch {};
    hwDelayMs(10);

    lcd_initialized = true;
}

fn hwLcdWritePixel(x: u16, y: u16, color: u16) void {
    if (!lcd_initialized) return;
    if (x >= reg.LCD_WIDTH or y >= reg.LCD_HEIGHT) return;

    // Calculate framebuffer offset
    const offset = (@as(u32, y) * reg.LCD_WIDTH + x) * 2;

    if (bcm_framebuffer_addr != 0) {
        // Write directly to BCM framebuffer memory
        bcmWrite32(bcm_framebuffer_addr + offset, color) catch {};
    }
}

fn hwLcdFillRect(x: u16, y: u16, width: u16, height: u16, color: u16) void {
    var py = y;
    while (py < y + height and py < reg.LCD_HEIGHT) : (py += 1) {
        var px = x;
        while (px < x + width and px < reg.LCD_WIDTH) : (px += 1) {
            hwLcdWritePixel(px, py, color);
        }
    }
}

fn hwLcdUpdate(framebuffer: []const u8) HalError!void {
    if (!lcd_initialized) return HalError.DeviceNotReady;

    // Send update command
    try bcmSendCommand(reg.BCMCMD_LCD_UPDATE);

    // Transfer framebuffer data
    // The BCM expects RGB565 data in 32-bit words
    const words = framebuffer.len / 4;
    var i: usize = 0;
    while (i < words) : (i += 1) {
        const offset = i * 4;
        const word: u32 = @as(u32, framebuffer[offset]) |
            (@as(u32, framebuffer[offset + 1]) << 8) |
            (@as(u32, framebuffer[offset + 2]) << 16) |
            (@as(u32, framebuffer[offset + 3]) << 24);

        try bcmWaitWriteReady();
        reg.writeReg(u32, reg.BCM_DATA, word);
    }

    // Finalize transfer
    try bcmSendCommand(reg.BCMCMD_FINALIZE);
}

fn hwLcdUpdateRect(x: u16, y: u16, width: u16, height: u16, framebuffer: []const u8) HalError!void {
    if (!lcd_initialized) return HalError.DeviceNotReady;

    // Clamp to screen bounds
    const x_end = @min(x + width, reg.LCD_WIDTH);
    const y_end = @min(y + height, reg.LCD_HEIGHT);
    const actual_width = x_end - x;
    const actual_height = y_end - y;

    if (actual_width == 0 or actual_height == 0) return;

    // Send update rect command with coordinates
    try bcmSendCommand(reg.BCMCMD_LCD_UPDATERECT);

    // Send rectangle coordinates as 32-bit values
    try bcmWrite32(reg.BCM_WR_CMD, @as(u32, x));
    try bcmWrite32(reg.BCM_WR_CMD, @as(u32, y));
    try bcmWrite32(reg.BCM_WR_CMD, @as(u32, actual_width));
    try bcmWrite32(reg.BCM_WR_CMD, @as(u32, actual_height));

    // Transfer only the rectangular region
    var py: u16 = y;
    while (py < y_end) : (py += 1) {
        var px: u16 = x;
        while (px < x_end) : (px += 2) {
            // Read 2 pixels (4 bytes) at a time
            const offset = (@as(usize, py) * reg.LCD_WIDTH + px) * 2;
            if (offset + 3 < framebuffer.len) {
                const word: u32 = @as(u32, framebuffer[offset]) |
                    (@as(u32, framebuffer[offset + 1]) << 8) |
                    (@as(u32, framebuffer[offset + 2]) << 16) |
                    (@as(u32, framebuffer[offset + 3]) << 24);

                try bcmWaitWriteReady();
                reg.writeReg(u32, reg.BCM_DATA, word);
            }
        }
    }

    // Finalize transfer
    try bcmSendCommand(reg.BCMCMD_FINALIZE);
}

fn hwLcdSetBacklight(on: bool) void {
    // Configure backlight GPIO as output
    hwGpioSetDirection(reg.BACKLIGHT_GPIO_PORT, reg.BACKLIGHT_GPIO_PIN, .output);

    // Set backlight state
    // Note: Real implementation would use PWM for brightness control
    hwGpioWrite(reg.BACKLIGHT_GPIO_PORT, reg.BACKLIGHT_GPIO_PIN, on);
}

fn hwLcdSleep() void {
    if (!lcd_initialized) return;

    // Send sleep command to BCM
    bcmSendCommand(reg.BCMCMD_LCD_SLEEP) catch {};

    // Turn off backlight
    hwLcdSetBacklight(false);
}

fn hwLcdWake() HalError!void {
    if (!lcd_initialized) return HalError.DeviceNotReady;

    // Wake command
    try bcmSendCommand(reg.BCMCMD_LCD_WAKE);
    hwDelayMs(10);

    // Turn on backlight
    hwLcdSetBacklight(true);
}

// ============================================================
// Click Wheel Functions
// ============================================================

fn hwClickwheelInit() HalError!void {
    // Enable optical device (click wheel)
    var dev_en = reg.readReg(u32, reg.DEV_EN);
    dev_en |= reg.DEV_OPTO;
    reg.writeReg(u32, reg.DEV_EN, dev_en);

    // Reset optical device
    var dev_rs = reg.readReg(u32, reg.DEV_RS);
    dev_rs |= reg.DEV_OPTO;
    reg.writeReg(u32, reg.DEV_RS, dev_rs);
    hwDelayUs(5);
    dev_rs &= ~reg.DEV_OPTO;
    reg.writeReg(u32, reg.DEV_RS, dev_rs);

    // Initialize buttons
    var dev_init = reg.readReg(u32, reg.DEV_INIT1);
    dev_init |= reg.INIT_BUTTONS;
    reg.writeReg(u32, reg.DEV_INIT1, dev_init);

    // Configure wheel interface (from Rockbox button-clickwheel.c)
    reg.writeReg(u32, 0x7000C100, 0xC00A1F00);
    reg.writeReg(u32, 0x7000C104, 0x01000000);
}

fn hwClickwheelReadButtons() u8 {
    // Read button state from GPIO or dedicated register
    // The exact implementation depends on the iPod model
    // For iPod Video, buttons are read via a specific interface
    // TODO: Implement actual button reading
    return 0;
}

fn hwClickwheelReadPosition() u8 {
    // Read wheel position (0-95)
    // TODO: Implement actual wheel position reading
    return 0;
}

fn hwGetTicks() u32 {
    // Return milliseconds since boot
    return @truncate(hwGetTicksUs() / 1000);
}

// ============================================================
// Cache Functions
// ============================================================

fn hwCacheInvalidateIcache() void {
    // ARM7TDMI cache invalidation
    asm volatile ("mcr p15, 0, %[zero], c7, c5, 0"
        :
        : [zero] "r" (@as(u32, 0)),
    );
}

fn hwCacheInvalidateDcache() void {
    // ARM7TDMI doesn't have separate D-cache control
    hwCacheInvalidateIcache();
}

fn hwCacheFlushDcache() void {
    // Flush via cache controller
    reg.writeReg(u32, reg.CACHE_OPERATION, reg.CACHE_OP_FLUSH);
    while ((reg.readReg(u32, reg.CACHE_CTL) & reg.CACHE_CTL_BUSY) != 0) {}
}

fn hwCacheEnable(enable: bool) void {
    if (enable) {
        // Initialize cache
        reg.writeReg(u32, reg.CACHE_CTL, reg.CACHE_CTL_INIT);
        reg.writeReg(u32, reg.CACHE_MASK, 0x00001C00);
        reg.writeReg(u32, reg.CACHE_CTL, reg.CACHE_CTL_ENABLE | reg.CACHE_CTL_RUN);
    } else {
        reg.writeReg(u32, reg.CACHE_CTL, 0);
    }
}

// ============================================================
// Interrupt Functions
// ============================================================

fn hwIrqEnable() void {
    asm volatile ("cpsie i");
}

fn hwIrqDisable() void {
    asm volatile ("cpsid i");
}

fn hwIrqEnabled() bool {
    var cpsr: u32 = undefined;
    asm volatile ("mrs %[cpsr], cpsr"
        : [cpsr] "=r" (cpsr),
    );
    return (cpsr & 0x80) == 0; // IRQ bit is 0 when enabled
}

var irq_handlers: [32]?*const fn () void = [_]?*const fn () void{null} ** 32;

fn hwIrqRegister(irq: u8, handler: *const fn () void) void {
    if (irq < 32) {
        irq_handlers[irq] = handler;
    }
}

// ============================================================
// HAL Instance
// ============================================================

pub const hal = Hal{
    .system_init = hwSystemInit,
    .get_ticks_us = hwGetTicksUs,
    .delay_us = hwDelayUs,
    .delay_ms = hwDelayMs,
    .sleep = hwSleep,
    .reset = hwReset,

    .gpio_set_direction = hwGpioSetDirection,
    .gpio_write = hwGpioWrite,
    .gpio_read = hwGpioRead,
    .gpio_set_interrupt = hwGpioSetInterrupt,

    .i2c_init = hwI2cInit,
    .i2c_write = hwI2cWrite,
    .i2c_read = hwI2cRead,
    .i2c_write_read = hwI2cWriteRead,

    .i2s_init = hwI2sInit,
    .i2s_write = hwI2sWrite,
    .i2s_tx_ready = hwI2sTxReady,
    .i2s_tx_free_slots = hwI2sTxFreeSlots,
    .i2s_enable = hwI2sEnable,

    .timer_start = hwTimerStart,
    .timer_stop = hwTimerStop,

    .ata_init = hwAtaInit,
    .ata_identify = hwAtaIdentify,
    .ata_read_sectors = hwAtaReadSectors,
    .ata_write_sectors = hwAtaWriteSectors,
    .ata_flush = hwAtaFlush,
    .ata_standby = hwAtaStandby,

    .lcd_init = hwLcdInit,
    .lcd_write_pixel = hwLcdWritePixel,
    .lcd_fill_rect = hwLcdFillRect,
    .lcd_update = hwLcdUpdate,
    .lcd_update_rect = hwLcdUpdateRect,
    .lcd_set_backlight = hwLcdSetBacklight,
    .lcd_sleep = hwLcdSleep,
    .lcd_wake = hwLcdWake,

    .clickwheel_init = hwClickwheelInit,
    .clickwheel_read_buttons = hwClickwheelReadButtons,
    .clickwheel_read_position = hwClickwheelReadPosition,
    .get_ticks = hwGetTicks,

    .cache_invalidate_icache = hwCacheInvalidateIcache,
    .cache_invalidate_dcache = hwCacheInvalidateDcache,
    .cache_flush_dcache = hwCacheFlushDcache,
    .cache_enable = hwCacheEnable,

    .irq_enable = hwIrqEnable,
    .irq_disable = hwIrqDisable,
    .irq_enabled = hwIrqEnabled,
    .irq_register = hwIrqRegister,
};
