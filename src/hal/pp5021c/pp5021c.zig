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
const UsbEndpointType = hal_types.UsbEndpointType;
const UsbDirection = hal_types.UsbDirection;
const UsbDeviceState = hal_types.UsbDeviceState;
const UsbSetupPacket = hal_types.UsbSetupPacket;
const DmaDirection = hal_types.DmaDirection;
const DmaBurstSize = hal_types.DmaBurstSize;
const DmaRequest = hal_types.DmaRequest;
const DmaChannelState = hal_types.DmaChannelState;
const ChargingState = hal_types.ChargingState;
const PowerSource = hal_types.PowerSource;
const BatteryStatus = hal_types.BatteryStatus;

// ============================================================
// Internal State
// ============================================================

var system_initialized: bool = false;
var i2c_initialized: bool = false;
var i2s_initialized: bool = false;
var ata_initialized: bool = false;
var lcd_initialized: bool = false;
var usb_initialized: bool = false;
var usb_device_state: UsbDeviceState = .disconnected;
var usb_device_address: u7 = 0;
var dma_initialized: bool = false;
var wdt_initialized: bool = false;
var wdt_timeout_ms: u32 = 0;
var wdt_caused_last_reset: bool = false;
var rtc_initialized: bool = false;
var pmu_initialized: bool = false;

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

// Current I2S configuration
var i2s_sample_rate: u32 = 44100;

fn hwI2sInit(sample_rate: u32, format: I2sFormat, sample_size: I2sSampleSize) HalError!void {
    // Enable I2S device clock
    reg.modifyReg(reg.DEV_EN, 0, reg.DEV_I2S);
    hwDelayUs(100);

    // Reset I2S controller
    reg.writeReg(u32, reg.IISCONFIG, reg.IIS_RESET);
    hwDelayUs(100);
    reg.writeReg(u32, reg.IISCONFIG, 0);
    hwDelayUs(100);

    // Configure sample rate divider
    const divider: u32 = switch (sample_rate) {
        44100 => reg.IIS_DIV_44100,
        48000 => reg.IIS_DIV_48000,
        22050 => reg.IIS_DIV_22050,
        24000 => reg.IIS_DIV_24000,
        11025 => reg.IIS_DIV_11025,
        12000 => reg.IIS_DIV_12000,
        else => reg.IIS_DIV_44100, // Default
    };
    reg.writeReg(u32, reg.IISDIV, divider);
    i2s_sample_rate = sample_rate;

    // Build configuration register
    var config: u32 = 0;

    // Format selection
    switch (format) {
        .i2s_standard => config |= reg.IIS_FORMAT_IIS,
        .left_justified => config |= reg.IIS_FORMAT_LJUST,
        .right_justified => config |= reg.IIS_FORMAT_RJUST,
    }

    // Sample size
    switch (sample_size) {
        .bits_16 => config |= reg.IIS_SIZE_16BIT,
        .bits_24 => config |= reg.IIS_SIZE_24BIT,
        .bits_32 => config |= reg.IIS_SIZE_32BIT,
    }

    // Set as master mode (iPod generates clocks)
    config |= reg.IIS_MASTER;

    // Enable I2S
    config |= reg.IIS_ENABLE;

    reg.writeReg(u32, reg.IISCONFIG, config);

    i2s_initialized = true;
}

fn hwI2sWrite(samples: []const i16) HalError!usize {
    if (!i2s_initialized) return HalError.DeviceNotReady;

    var written: usize = 0;
    var i: usize = 0;

    while (i < samples.len) {
        // Wait for FIFO space
        const timeout_start = hwGetTicksUs();
        while (hwI2sTxFreeSlots() == 0) {
            if (hwGetTicksUs() - timeout_start > 100000) { // 100ms timeout
                return if (written > 0) written else HalError.Timeout;
            }
        }

        // Write stereo sample pair (left in upper 16 bits, right in lower)
        if (i + 1 < samples.len) {
            // Stereo: samples[i] = left, samples[i+1] = right
            const left: u32 = @bitCast(@as(i32, samples[i]));
            const right: u32 = @bitCast(@as(i32, samples[i + 1]));
            reg.writeReg(u32, reg.IISFIFO_WR, (left << 16) | (right & 0xFFFF));
            i += 2;
            written += 2;
        } else {
            // Odd sample - duplicate to both channels
            const sample: u32 = @bitCast(@as(i32, samples[i]));
            reg.writeReg(u32, reg.IISFIFO_WR, (sample << 16) | (sample & 0xFFFF));
            i += 1;
            written += 1;
        }
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
        // Enable TX FIFO and I2S
        reg.modifyReg(reg.IISCONFIG, 0, reg.IIS_TXFIFOEN | reg.IIS_ENABLE);
    } else {
        // Disable TX FIFO
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

    // Word 169 (bytes 338-339): DATA SET MANAGEMENT support
    // Bit 0 = TRIM supported
    const dsm_support = @as(u16, identify_data[338]) | (@as(u16, identify_data[339]) << 8);
    info.supports_trim = (dsm_support & 0x0001) != 0;

    // Word 217 (bytes 434-435): Nominal Media Rotation Rate
    // 0x0000 = Not reported, 0x0001 = Non-rotating (SSD), others = RPM
    info.rotation_rate = @as(u16, identify_data[434]) | (@as(u16, identify_data[435]) << 8);

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
    const width = bcmCommand(reg.BCMCMD_GET_WIDTH) catch {
        // BCM not responding - this is expected if firmware isn't loaded
        // On real hardware, the ROM bootloader loads BCM firmware
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

// Last wheel packet data for caching
var wheel_last_data: u32 = 0;
var wheel_last_read_time: u64 = 0;

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

    // Configure wheel interface
    // Set sample period and enable wheel controller
    reg.writeReg(u32, reg.WHEEL_PERIOD, reg.WHEEL_SAMPLE_RATE_MS * 1000); // Convert to us
    reg.writeReg(u32, reg.WHEEL_CFG, reg.WHEEL_CFG_ENABLE);

    // Configure hold switch GPIO as input
    hwGpioSetDirection(reg.HOLD_GPIO_PORT, reg.HOLD_GPIO_PIN, .input);

    hwDelayMs(10); // Allow wheel controller to stabilize
}

/// Read raw wheel packet from controller
fn wheelReadPacket() u32 {
    const current_time = hwGetTicksUs();

    // Rate limit reads to avoid bus congestion
    if (current_time - wheel_last_read_time < 5000) { // 5ms minimum between reads
        return wheel_last_data;
    }

    // Check if data is available
    const status = reg.readReg(u32, reg.WHEEL_STATUS);
    if ((status & reg.WHEEL_STATUS_DATA) != 0) {
        wheel_last_data = reg.readReg(u32, reg.WHEEL_DATA);
        wheel_last_read_time = current_time;
    }

    return wheel_last_data;
}

fn hwClickwheelReadButtons() u8 {
    const packet = wheelReadPacket();

    // Extract button bits from packet
    var buttons: u8 = @truncate((packet & reg.WHEEL_BUTTON_MASK) >> reg.WHEEL_BUTTON_SHIFT);

    // Read hold switch from GPIO (active low typically)
    const hold_state = hwGpioRead(reg.HOLD_GPIO_PORT, reg.HOLD_GPIO_PIN);
    if (!hold_state) {
        buttons |= 0x20; // HOLD bit
    }

    return buttons;
}

fn hwClickwheelReadPosition() u8 {
    const packet = wheelReadPacket();

    // Extract position from packet
    const position: u8 = @truncate((packet & reg.WHEEL_POSITION_MASK) >> reg.WHEEL_POSITION_SHIFT);

    // Clamp to valid range
    return if (position < reg.WHEEL_POSITIONS) position else 0;
}

fn hwGetTicks() u32 {
    // Return milliseconds since boot
    return @truncate(hwGetTicksUs() / 1000);
}

// ============================================================
// USB Functions - Device Mode Implementation
// ============================================================

/// Wait for PHY PLL to lock
fn usbWaitPhyReady() HalError!void {
    const start = hwGetTicksUs();
    while (true) {
        const phy = reg.readReg(u32, reg.USB_PHY_CTRL);
        if ((phy & reg.USB_PHY_PLL_LOCK) != 0) {
            return;
        }
        if (hwGetTicksUs() - start > reg.USB_TIMEOUT_US) {
            return HalError.Timeout;
        }
    }
}

/// Wait for endpoint transfer to complete
fn usbWaitEpDone(ep: u8) HalError!void {
    const ep_base = reg.usbEpBase(ep);
    const start = hwGetTicksUs();
    while (true) {
        const status = reg.readReg(u32, ep_base + reg.USB_EP_STAT);
        if ((status & reg.USB_EP_STAT_BUSY) == 0) {
            if ((status & reg.USB_EP_STAT_ERROR) != 0) {
                return HalError.TransferError;
            }
            return;
        }
        if (hwGetTicksUs() - start > reg.USB_TIMEOUT_US) {
            return HalError.Timeout;
        }
    }
}

fn hwUsbInit() HalError!void {
    // Enable USB clocks
    reg.modifyReg(reg.DEV_EN, 0, reg.DEV_USB0 | reg.DEV_USB1);
    hwDelayMs(10);

    // Perform soft reset
    reg.writeReg(u32, reg.USB_DEV_CTRL, reg.USB_DEV_SOFT_RESET);
    hwDelayMs(10);

    // Enable PHY
    reg.writeReg(u32, reg.USB_PHY_CTRL, reg.USB_PHY_ENABLE);
    hwDelayMs(10);

    // Wait for PHY PLL lock
    try usbWaitPhyReady();

    // Clear soft reset, enable device
    reg.writeReg(u32, reg.USB_DEV_CTRL, reg.USB_DEV_EN);
    hwDelayMs(1);

    // Clear all pending interrupts
    reg.writeReg(u32, reg.USB_INT_STAT, 0xFFFFFFFF);

    // Enable essential interrupts: reset, setup, suspend, resume
    reg.writeReg(u32, reg.USB_INT_EN, reg.USB_INT_RESET |
        reg.USB_INT_SUSPEND |
        reg.USB_INT_RESUME |
        reg.USB_INT_EP0_SETUP |
        reg.USB_INT_EP0_RX |
        reg.USB_INT_EP0_TX);

    // Set device address to 0
    reg.writeReg(u32, reg.USB_DEV_ADDR, 0);

    // Configure EP0 for control transfers
    const ep0_ctrl = reg.USB_EP_EN |
        reg.USB_EP_TYPE_CTRL |
        (@as(u32, reg.USB_EP0_MAX_PKT) << 16);
    reg.writeReg(u32, reg.USB_EP0_BASE + reg.USB_EP_CTRL, ep0_ctrl);
    reg.writeReg(u32, reg.USB_EP0_BASE + reg.USB_EP_MAXPKT, reg.USB_EP0_MAX_PKT);

    usb_initialized = true;
    usb_device_state = .powered;
    usb_device_address = 0;
}

fn hwUsbConnect() void {
    if (!usb_initialized) return;

    // Enable soft connect (pull-up on D+ line)
    reg.modifyReg(reg.USB_DEV_CTRL, 0, reg.USB_DEV_SOFT_CONN);
    usb_device_state = .attached;
}

fn hwUsbDisconnect() void {
    if (!usb_initialized) return;

    // Disable soft connect
    reg.modifyReg(reg.USB_DEV_CTRL, reg.USB_DEV_SOFT_CONN, 0);
    usb_device_state = .disconnected;
}

fn hwUsbIsConnected() bool {
    if (!usb_initialized) return false;

    // Check device control register for connection status
    const ctrl = reg.readReg(u32, reg.USB_DEV_CTRL);
    return (ctrl & reg.USB_DEV_SOFT_CONN) != 0;
}

fn hwUsbGetState() UsbDeviceState {
    return usb_device_state;
}

fn hwUsbSetAddress(addr: u7) void {
    if (!usb_initialized) return;

    reg.writeReg(u32, reg.USB_DEV_ADDR, addr);
    usb_device_address = addr;

    if (addr > 0) {
        usb_device_state = .addressed;
    } else {
        usb_device_state = .default;
    }
}

fn hwUsbConfigureEndpoint(ep: u8, ep_type: UsbEndpointType, direction: UsbDirection, max_packet_size: u16) HalError!void {
    if (!usb_initialized) return HalError.DeviceNotReady;
    if (ep >= reg.USB_NUM_ENDPOINTS) return HalError.InvalidParameter;

    const ep_base = reg.usbEpBase(ep);

    // Build control register value
    var ctrl: u32 = reg.USB_EP_EN;

    // Set endpoint type
    switch (ep_type) {
        .control => ctrl |= reg.USB_EP_TYPE_CTRL,
        .isochronous => ctrl |= reg.USB_EP_TYPE_ISO,
        .bulk => ctrl |= reg.USB_EP_TYPE_BULK,
        .interrupt => ctrl |= reg.USB_EP_TYPE_INTR,
    }

    // Set direction
    if (direction == .in) {
        ctrl |= reg.USB_EP_DIR_IN;
    }

    // Set max packet size in upper bits
    ctrl |= (@as(u32, max_packet_size) << 16);

    // Configure endpoint
    reg.writeReg(u32, ep_base + reg.USB_EP_CTRL, ctrl);
    reg.writeReg(u32, ep_base + reg.USB_EP_MAXPKT, max_packet_size);

    // Enable endpoint interrupts
    const ep_int_rx: u32 = switch (ep) {
        0 => reg.USB_INT_EP0_RX,
        1 => reg.USB_INT_EP1_RX,
        2 => reg.USB_INT_EP2_RX,
        else => 0,
    };
    const ep_int_tx: u32 = switch (ep) {
        0 => reg.USB_INT_EP0_TX,
        1 => reg.USB_INT_EP1_TX,
        2 => reg.USB_INT_EP2_TX,
        else => 0,
    };

    reg.modifyReg(reg.USB_INT_EN, 0, ep_int_rx | ep_int_tx);
}

fn hwUsbStallEndpoint(ep: u8) void {
    if (ep >= reg.USB_NUM_ENDPOINTS) return;

    const ep_base = reg.usbEpBase(ep);
    reg.modifyReg(ep_base + reg.USB_EP_CTRL, 0, reg.USB_EP_STALL);
}

fn hwUsbUnstallEndpoint(ep: u8) void {
    if (ep >= reg.USB_NUM_ENDPOINTS) return;

    const ep_base = reg.usbEpBase(ep);
    reg.modifyReg(ep_base + reg.USB_EP_CTRL, reg.USB_EP_STALL, 0);
}

fn hwUsbWriteEndpoint(ep: u8, data: []const u8) HalError!usize {
    if (!usb_initialized) return HalError.DeviceNotReady;
    if (ep >= reg.USB_NUM_ENDPOINTS) return HalError.InvalidParameter;

    const ep_base = reg.usbEpBase(ep);
    const fifo_addr = reg.usbEpFifo(ep);

    // Wait for endpoint to be ready
    try usbWaitEpDone(ep);

    // Get max packet size
    const max_pkt = reg.readReg(u16, ep_base + reg.USB_EP_MAXPKT);
    const len = @min(data.len, max_pkt);

    // Write data to FIFO (32 bits at a time)
    var i: usize = 0;
    while (i < len) {
        var word: u32 = 0;
        var j: usize = 0;
        while (j < 4 and i + j < len) : (j += 1) {
            word |= @as(u32, data[i + j]) << @truncate(j * 8);
        }
        reg.writeReg(u32, fifo_addr, word);
        i += 4;
    }

    // Set TX length and trigger transfer
    reg.writeReg(u32, ep_base + reg.USB_EP_TXLEN, @as(u32, @intCast(len)));

    return len;
}

fn hwUsbReadEndpoint(ep: u8, buffer: []u8) HalError!usize {
    if (!usb_initialized) return HalError.DeviceNotReady;
    if (ep >= reg.USB_NUM_ENDPOINTS) return HalError.InvalidParameter;

    const ep_base = reg.usbEpBase(ep);
    const fifo_addr = reg.usbEpFifo(ep);

    // Get received length
    const rx_len = reg.readReg(u32, ep_base + reg.USB_EP_RXLEN);
    const len: usize = @min(@as(usize, @truncate(rx_len)), buffer.len);

    // Read data from FIFO (32 bits at a time)
    var i: usize = 0;
    while (i < len) {
        const word = reg.readReg(u32, fifo_addr);
        var j: usize = 0;
        while (j < 4 and i + j < len) : (j += 1) {
            buffer[i + j] = @truncate((word >> @truncate(j * 8)) & 0xFF);
        }
        i += 4;
    }

    return len;
}

fn hwUsbGetInterrupts() u32 {
    return reg.readReg(u32, reg.USB_INT_STAT);
}

fn hwUsbClearInterrupts(flags: u32) void {
    // Write 1 to clear interrupts
    reg.writeReg(u32, reg.USB_INT_STAT, flags);
}

fn hwUsbReadSetup() HalError!UsbSetupPacket {
    if (!usb_initialized) return HalError.DeviceNotReady;

    const fifo_addr = reg.USB_EP0_FIFO;

    // Read 8 bytes of setup packet from EP0 FIFO
    const word0 = reg.readReg(u32, fifo_addr);
    const word1 = reg.readReg(u32, fifo_addr);

    return UsbSetupPacket{
        .bmRequestType = @truncate(word0 & 0xFF),
        .bRequest = @truncate((word0 >> 8) & 0xFF),
        .wValue = @truncate((word0 >> 16) & 0xFFFF),
        .wIndex = @truncate(word1 & 0xFFFF),
        .wLength = @truncate((word1 >> 16) & 0xFFFF),
    };
}

fn hwUsbSendZlp(ep: u8) HalError!void {
    if (!usb_initialized) return HalError.DeviceNotReady;
    if (ep >= reg.USB_NUM_ENDPOINTS) return HalError.InvalidParameter;

    const ep_base = reg.usbEpBase(ep);

    // Wait for endpoint to be ready
    try usbWaitEpDone(ep);

    // Set TX length to 0 to send ZLP
    reg.writeReg(u32, ep_base + reg.USB_EP_TXLEN, 0);
}

// ============================================================
// DMA Functions
// ============================================================

fn hwDmaInit() HalError!void {
    // Reset DMA controller
    reg.writeReg(u32, reg.DMA_MASTER_CTRL, reg.DMA_MASTER_RESET);
    hwDelayUs(10);

    // Enable DMA controller
    reg.writeReg(u32, reg.DMA_MASTER_CTRL, reg.DMA_MASTER_EN);
    hwDelayUs(10);

    dma_initialized = true;
}

fn hwDmaStart(channel: u2, ram_addr: usize, periph_addr: usize, length: u16, direction: DmaDirection, request: DmaRequest, burst: DmaBurstSize) HalError!void {
    if (!dma_initialized) return HalError.DeviceNotReady;

    const chan_base = reg.dmaChannelBase(channel);

    // Set RAM address
    reg.writeReg(u32, chan_base + reg.DMA_RAM_ADDR_OFF, @truncate(ram_addr));

    // Set peripheral address
    reg.writeReg(u32, chan_base + reg.DMA_PER_ADDR_OFF, @truncate(periph_addr));

    // Set increment mode (typically increment RAM, not peripheral for FIFO)
    reg.writeReg(u32, chan_base + reg.DMA_INCR_OFF, reg.DMA_INCR_RAM);

    // Build flags: length + request ID + burst size
    const burst_val: u32 = switch (burst) {
        .burst_1 => reg.DMA_BURST_1,
        .burst_4 => reg.DMA_BURST_4,
        .burst_8 => reg.DMA_BURST_8,
        .burst_16 => reg.DMA_BURST_16,
    };
    const flags: u32 = @as(u32, length) |
        (@as(u32, @intFromEnum(request)) << reg.DMA_FLAGS_REQ_SHIFT) |
        (burst_val << reg.DMA_FLAGS_BURST_SHIFT);
    reg.writeReg(u32, chan_base + reg.DMA_FLAGS_OFF, flags);

    // Build command: direction + start + interrupt on complete
    var cmd: u32 = reg.DMA_CMD_START | reg.DMA_CMD_INTR | reg.DMA_CMD_WAIT_REQ;
    if (direction == .ram_to_peripheral) {
        cmd |= reg.DMA_CMD_RAM_TO_PER;
    }
    reg.writeReg(u32, chan_base + reg.DMA_CMD_OFF, cmd);
}

fn hwDmaWait(channel: u2) HalError!void {
    if (!dma_initialized) return HalError.DeviceNotReady;

    const chan_base = reg.dmaChannelBase(channel);
    const start = hwGetTicksUs();

    while (true) {
        const status = reg.readReg(u32, chan_base + reg.DMA_STATUS_OFF);
        if ((status & reg.DMA_STATUS_BUSY) == 0) {
            if ((status & reg.DMA_STATUS_ERROR) != 0) {
                return HalError.TransferError;
            }
            return;
        }
        if (hwGetTicksUs() - start > reg.DMA_TIMEOUT_US) {
            return HalError.Timeout;
        }
    }
}

fn hwDmaIsBusy(channel: u2) bool {
    if (!dma_initialized) return false;

    const chan_base = reg.dmaChannelBase(channel);
    const status = reg.readReg(u32, chan_base + reg.DMA_STATUS_OFF);
    return (status & reg.DMA_STATUS_BUSY) != 0;
}

fn hwDmaGetState(channel: u2) DmaChannelState {
    if (!dma_initialized) return .idle;

    const chan_base = reg.dmaChannelBase(channel);
    const status = reg.readReg(u32, chan_base + reg.DMA_STATUS_OFF);

    if ((status & reg.DMA_STATUS_ERROR) != 0) {
        return .@"error";
    } else if ((status & reg.DMA_STATUS_DONE) != 0) {
        return .done;
    } else if ((status & reg.DMA_STATUS_BUSY) != 0) {
        return .running;
    } else {
        return .idle;
    }
}

fn hwDmaAbort(channel: u2) void {
    if (!dma_initialized) return;

    const chan_base = reg.dmaChannelBase(channel);

    // Write abort bit to status to stop transfer
    reg.writeReg(u32, chan_base + reg.DMA_STATUS_OFF, reg.DMA_STATUS_ABORT);

    // Clear command register
    reg.writeReg(u32, chan_base + reg.DMA_CMD_OFF, 0);
}

// ============================================================
// Watchdog Timer Functions
// ============================================================

fn hwWdtInit(timeout_ms: u32) HalError!void {
    // Disable watchdog first
    reg.writeReg(u32, reg.WDT_CTRL, 0);
    hwDelayUs(10);

    // Store timeout for later
    wdt_timeout_ms = timeout_ms;

    // Set timeout value (convert ms to timer ticks)
    // Timer runs at approximately 1kHz
    const timeout_ticks = timeout_ms & reg.WDT_CTRL_TIMEOUT_MASK;
    reg.writeReg(u32, reg.WDT_COUNTER, timeout_ticks);

    wdt_initialized = true;
}

fn hwWdtStart() void {
    if (!wdt_initialized) return;

    // Enable watchdog with system reset on timeout
    reg.writeReg(u32, reg.WDT_CTRL, reg.WDT_CTRL_ENABLE | reg.WDT_CTRL_RESET_EN | (wdt_timeout_ms & reg.WDT_CTRL_TIMEOUT_MASK));
}

fn hwWdtStop() void {
    // Disable watchdog
    reg.writeReg(u32, reg.WDT_CTRL, 0);
}

fn hwWdtRefresh() void {
    if (!wdt_initialized) return;

    // Write magic value to refresh register to reset counter
    reg.writeReg(u32, reg.WDT_REFRESH, reg.WDT_REFRESH_KEY);
}

fn hwWdtCausedReset() bool {
    // Check if last reset was from watchdog
    // This is typically stored in a status register that persists through reset
    return wdt_caused_last_reset;
}

// ============================================================
// RTC Functions
// ============================================================

fn hwRtcInit() HalError!void {
    // Enable RTC
    reg.modifyReg(reg.RTC_CTRL, 0, reg.RTC_CTRL_ENABLE);
    hwDelayUs(10);

    rtc_initialized = true;
}

fn hwRtcGetTime() u32 {
    // Read seconds counter
    return reg.readReg(u32, reg.RTC_SECONDS);
}

fn hwRtcSetTime(seconds: u32) void {
    // Write seconds counter
    reg.writeReg(u32, reg.RTC_SECONDS, seconds);
}

fn hwRtcSetAlarm(seconds: u32) void {
    // Set alarm time
    reg.writeReg(u32, reg.RTC_ALARM, seconds);

    // Enable alarm
    reg.modifyReg(reg.RTC_CTRL, 0, reg.RTC_CTRL_ALARM_EN);
}

fn hwRtcClearAlarm() void {
    // Disable alarm and clear interrupt flag
    reg.modifyReg(reg.RTC_CTRL, reg.RTC_CTRL_ALARM_EN | reg.RTC_CTRL_ALARM_IRQ, 0);
}

fn hwRtcAlarmTriggered() bool {
    const ctrl = reg.readReg(u32, reg.RTC_CTRL);
    return (ctrl & reg.RTC_CTRL_ALARM_IRQ) != 0;
}

// ============================================================
// PMU Functions - PCF50605 Power Management
// ============================================================

/// Read a register from the PCF50605 via I2C
fn pcfReadReg(register: u8) HalError!u8 {
    // Write register address, then read value
    var read_buf: [1]u8 = undefined;
    _ = try hwI2cWriteRead(reg.PCF50605_I2C_ADDR, &[_]u8{register}, &read_buf);
    return read_buf[0];
}

/// Write a register to the PCF50605 via I2C
fn pcfWriteReg(register: u8, value: u8) HalError!void {
    try hwI2cWrite(reg.PCF50605_I2C_ADDR, &[_]u8{ register, value });
}

/// Read ADC value from PCF50605
fn pcfReadAdc(channel: u8) HalError!u16 {
    // Configure ADC channel and start conversion
    try pcfWriteReg(reg.PCF_ADCC2, channel);
    try pcfWriteReg(reg.PCF_ADCC1, reg.PCF_ADCC1_ADCSTART | reg.PCF_ADCC1_RES_10BIT | reg.PCF_ADCC1_AVERAGE);

    // Wait for conversion (typically ~100us)
    hwDelayUs(200);

    // Read result (10-bit value split across two registers)
    const high = try pcfReadReg(reg.PCF_ADCS1);
    const low = try pcfReadReg(reg.PCF_ADCS2);

    return (@as(u16, high) << 2) | (@as(u16, low) & 0x03);
}

/// Convert ADC value to millivolts
fn adcToMillivolts(adc_value: u16) u16 {
    // 10-bit ADC with ~6V full scale range
    // mV = adc * 5860 / 1000 (approximately)
    return @truncate((@as(u32, adc_value) * reg.PCF_ADC_TO_MV_NUM) / reg.PCF_ADC_TO_MV_DEN);
}

/// Convert battery voltage to percentage
fn voltageToPercent(voltage_mv: u16) u8 {
    // Simple linear approximation between empty and full
    if (voltage_mv >= reg.PCF_BATTERY_FULL_MV) return 100;
    if (voltage_mv <= reg.PCF_BATTERY_EMPTY_MV) return 0;

    const range = reg.PCF_BATTERY_FULL_MV - reg.PCF_BATTERY_EMPTY_MV;
    const offset = voltage_mv - reg.PCF_BATTERY_EMPTY_MV;
    return @truncate((@as(u32, offset) * 100) / range);
}

fn hwPmuInit() HalError!void {
    // Ensure I2C is initialized first
    if (!i2c_initialized) {
        try hwI2cInit();
    }

    // Read chip ID to verify communication
    const id = pcfReadReg(reg.PCF_ID) catch {
        // PMU not responding - might be different chip or not present
        pmu_initialized = false;
        return HalError.DeviceNotReady;
    };

    // PCF50605 ID should be non-zero
    if (id == 0 or id == 0xFF) {
        return HalError.DeviceNotReady;
    }

    // Clear pending interrupts by reading interrupt registers
    _ = pcfReadReg(reg.PCF_INT1) catch {};
    _ = pcfReadReg(reg.PCF_INT2) catch {};
    _ = pcfReadReg(reg.PCF_INT3) catch {};

    // Configure charger for automatic operation
    pcfWriteReg(reg.PCF_MBCC1, reg.PCF_MBCC1_CHGENA | reg.PCF_MBCC1_AUTOFST | reg.PCF_MBCC1_AUTORES) catch {};

    pmu_initialized = true;
}

fn hwPmuGetBatteryStatus() BatteryStatus {
    var status = BatteryStatus{
        .voltage_mv = 0,
        .percentage = 0,
        .charging = .not_charging,
        .power_source = .battery,
        .present = false,
        .temperature_ok = true,
    };

    if (!pmu_initialized) return status;

    // Read battery voltage via ADC
    if (pcfReadAdc(reg.PCF_ADCC2_VBAT)) |adc| {
        status.voltage_mv = adcToMillivolts(adc);
        status.percentage = voltageToPercent(status.voltage_mv);
    } else |_| {}

    // Read charger status
    if (pcfReadReg(reg.PCF_MBCS1)) |mbcs1| {
        status.present = (mbcs1 & reg.PCF_MBCS1_BAT) != 0;

        // Determine power source
        if ((mbcs1 & reg.PCF_MBCS1_USB) != 0) {
            status.power_source = .usb;
        } else if ((mbcs1 & reg.PCF_MBCS1_ADP) != 0) {
            status.power_source = .adapter;
        }

        // Determine charging state
        if ((mbcs1 & reg.PCF_MBCS1_BATFUL) != 0) {
            status.charging = .charge_complete;
        } else if ((mbcs1 & reg.PCF_MBCS1_PREG) != 0) {
            status.charging = .pre_charge;
        } else if ((mbcs1 & reg.PCF_MBCS1_CCCV) != 0) {
            status.charging = .fast_charge;
        } else if ((mbcs1 & reg.PCF_MBCS1_CHGEND) != 0) {
            status.charging = .trickle_charge;
        }
    } else |_| {}

    return status;
}

fn hwPmuGetBatteryVoltage() u16 {
    if (!pmu_initialized) return 0;

    if (pcfReadAdc(reg.PCF_ADCC2_VBAT)) |adc| {
        return adcToMillivolts(adc);
    } else |_| {
        return 0;
    }
}

fn hwPmuGetBatteryPercent() u8 {
    const voltage = hwPmuGetBatteryVoltage();
    return voltageToPercent(voltage);
}

fn hwPmuIsCharging() bool {
    if (!pmu_initialized) return false;

    if (pcfReadReg(reg.PCF_MBCS1)) |mbcs1| {
        // Charging if in pre-charge or CC/CV phase
        return (mbcs1 & (reg.PCF_MBCS1_PREG | reg.PCF_MBCS1_CCCV)) != 0;
    } else |_| {
        return false;
    }
}

fn hwPmuSetCharging(enable: bool) void {
    if (!pmu_initialized) return;

    if (pcfReadReg(reg.PCF_MBCC1)) |current| {
        var new_val = current;
        if (enable) {
            new_val |= reg.PCF_MBCC1_CHGENA;
        } else {
            new_val &= ~reg.PCF_MBCC1_CHGENA;
        }
        pcfWriteReg(reg.PCF_MBCC1, new_val) catch {};
    } else |_| {}
}

fn hwPmuExternalPowerPresent() bool {
    if (!pmu_initialized) return false;

    if (pcfReadReg(reg.PCF_OOCS)) |oocs| {
        return (oocs & (reg.PCF_OOCS_USB | reg.PCF_OOCS_CHG)) != 0;
    } else |_| {
        return false;
    }
}

fn hwPmuShutdown() void {
    if (!pmu_initialized) return;

    // Write to OOCC1 to request power down
    // This depends on specific PCF50605 configuration
    pcfWriteReg(reg.PCF_OOCC1, 0x01) catch {};

    // If shutdown doesn't work, at least disable regulators
    pcfWriteReg(reg.PCF_DCDC1, 0x00) catch {};
}

fn hwPmuSetCpuVoltage(mv: u16) HalError!void {
    if (!pmu_initialized) return HalError.DeviceNotReady;

    // DCDC1 controls CPU core voltage
    // Voltage = 0.9V + (reg_value * 25mV)
    // reg_value = (mv - 900) / 25
    if (mv < 900 or mv > 1800) return HalError.InvalidParameter;

    const reg_value: u8 = @truncate((mv - 900) / 25);
    try pcfWriteReg(reg.PCF_DCDC1, reg_value | 0x80); // 0x80 = enable bit
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

    .usb_init = hwUsbInit,
    .usb_connect = hwUsbConnect,
    .usb_disconnect = hwUsbDisconnect,
    .usb_is_connected = hwUsbIsConnected,
    .usb_get_state = hwUsbGetState,
    .usb_set_address = hwUsbSetAddress,
    .usb_configure_endpoint = hwUsbConfigureEndpoint,
    .usb_stall_endpoint = hwUsbStallEndpoint,
    .usb_unstall_endpoint = hwUsbUnstallEndpoint,
    .usb_write_endpoint = hwUsbWriteEndpoint,
    .usb_read_endpoint = hwUsbReadEndpoint,
    .usb_get_interrupts = hwUsbGetInterrupts,
    .usb_clear_interrupts = hwUsbClearInterrupts,
    .usb_read_setup = hwUsbReadSetup,
    .usb_send_zlp = hwUsbSendZlp,

    .dma_init = hwDmaInit,
    .dma_start = hwDmaStart,
    .dma_wait = hwDmaWait,
    .dma_is_busy = hwDmaIsBusy,
    .dma_get_state = hwDmaGetState,
    .dma_abort = hwDmaAbort,

    .wdt_init = hwWdtInit,
    .wdt_start = hwWdtStart,
    .wdt_stop = hwWdtStop,
    .wdt_refresh = hwWdtRefresh,
    .wdt_caused_reset = hwWdtCausedReset,

    .rtc_init = hwRtcInit,
    .rtc_get_time = hwRtcGetTime,
    .rtc_set_time = hwRtcSetTime,
    .rtc_set_alarm = hwRtcSetAlarm,
    .rtc_clear_alarm = hwRtcClearAlarm,
    .rtc_alarm_triggered = hwRtcAlarmTriggered,

    .pmu_init = hwPmuInit,
    .pmu_get_battery_status = hwPmuGetBatteryStatus,
    .pmu_get_battery_voltage = hwPmuGetBatteryVoltage,
    .pmu_get_battery_percent = hwPmuGetBatteryPercent,
    .pmu_is_charging = hwPmuIsCharging,
    .pmu_set_charging = hwPmuSetCharging,
    .pmu_external_power_present = hwPmuExternalPowerPresent,
    .pmu_shutdown = hwPmuShutdown,
    .pmu_set_cpu_voltage = hwPmuSetCpuVoltage,
};
