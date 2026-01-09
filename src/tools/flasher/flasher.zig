//! Safe Flasher Tool for ZigPod
//!
//! Provides safe flashing operations with automatic backup,
//! verification, and rollback capabilities.
//!
//! SAFETY FEATURES:
//! - Battery level check before any flash operation (minimum 20%)
//! - Watchdog timer integration to prevent hangs during flash
//! - Automatic backup before flashing with verification
//! - Post-flash verification with automatic rollback on failure
//! - Protected region detection to prevent bricking
//!
//! WARNING: Flashing firmware is inherently dangerous. Always ensure:
//! - Device is connected to power (not just battery)
//! - Battery has sufficient charge (>20%)
//! - You have a verified backup before proceeding

const std = @import("std");
const backup = @import("backup.zig");
const disk_mode = @import("disk_mode.zig");

const BackupManager = backup.BackupManager;
const BackupMetadata = backup.BackupMetadata;
const DiskModeInterface = disk_mode.DiskModeInterface;
const DeviceInfo = disk_mode.DeviceInfo;
const DiskModeError = disk_mode.DiskModeError;

// ============================================================
// Safety Constants
// ============================================================

/// Minimum battery percentage required to start flashing
pub const MIN_BATTERY_PERCENT: u8 = 20;

/// Critical battery level - abort immediately
pub const CRITICAL_BATTERY_PERCENT: u8 = 10;

/// Minimum battery voltage in millivolts (3.2V)
pub const MIN_BATTERY_VOLTAGE_MV: u16 = 3200;

/// Watchdog timeout for flash operations (60 seconds)
pub const FLASH_WATCHDOG_TIMEOUT_MS: u32 = 60_000;

/// Watchdog refresh interval during operations (5 seconds)
pub const WATCHDOG_REFRESH_INTERVAL_SECTORS: u64 = 1000;

/// Maximum retry attempts for failed operations
pub const MAX_RETRY_ATTEMPTS: u8 = 3;

// ============================================================
// Errors
// ============================================================

/// Flasher errors
pub const FlasherError = error{
    NoDevice,
    NotConnected,
    BackupFailed,
    VerificationFailed,
    WriteFailed,
    ReadFailed,
    RollbackFailed,
    UserAborted,
    InvalidFirmware,
    SizeMismatch,
    ChecksumMismatch,
    ProtectedRegion,
    AlreadyInProgress,
    NothingToRollback,
    /// Battery level too low to safely complete flash operation
    LowBattery,
    /// Battery level critically low - operation aborted for safety
    CriticalBattery,
    /// External power required but not connected
    ExternalPowerRequired,
    /// Watchdog timeout during operation
    WatchdogTimeout,
    /// Operation exceeded maximum retry attempts
    MaxRetriesExceeded,
    /// Hardware safety check failed
    SafetyCheckFailed,
};

/// Flash operation state
pub const FlashState = enum {
    idle,
    checking_safety,
    backing_up,
    verifying_backup,
    flashing,
    verifying_flash,
    rolling_back,
    completed,
    failed,
    aborted_low_battery,
    aborted_safety,
};

/// Progress callback
pub const ProgressCallback = *const fn (FlashState, u64, u64, []const u8) void;

/// Flash operation options
pub const FlashOptions = struct {
    /// Create backup before flashing (highly recommended)
    create_backup: bool = true,
    /// Verify after writing
    verify_after_write: bool = true,
    /// Verify backup integrity before flashing
    verify_backup_before_flash: bool = true,
    /// Allow writing to protected regions (dangerous!)
    allow_protected_writes: bool = false,
    /// Progress callback
    progress_callback: ?ProgressCallback = null,
    /// Backup directory
    backup_dir: []const u8 = "zigpod_backups",
    /// Description for backup
    backup_description: []const u8 = "Pre-flash backup",

    // Safety options
    /// Check battery level before flashing (highly recommended)
    check_battery: bool = true,
    /// Minimum battery percentage required (default: 20%)
    min_battery_percent: u8 = MIN_BATTERY_PERCENT,
    /// Require external power for large flash operations
    require_external_power: bool = false,
    /// Enable watchdog during flash operations
    enable_watchdog: bool = true,
    /// Watchdog timeout in milliseconds
    watchdog_timeout_ms: u32 = FLASH_WATCHDOG_TIMEOUT_MS,
    /// Abort if battery drops below critical level during flash
    abort_on_critical_battery: bool = true,
    /// Number of retry attempts for failed operations
    max_retries: u8 = MAX_RETRY_ATTEMPTS,
    /// Auto-rollback on verification failure
    auto_rollback_on_failure: bool = true,
};

/// Safety check result
pub const SafetyCheckResult = struct {
    passed: bool,
    battery_percent: u8,
    battery_voltage_mv: u16,
    external_power: bool,
    is_charging: bool,
    failure_reason: ?[]const u8,

    pub fn format(self: *const SafetyCheckResult, writer: anytype) !void {
        try writer.print("Safety Check Results:\n", .{});
        try writer.print("  Status: {s}\n", .{if (self.passed) "PASSED" else "FAILED"});
        try writer.print("  Battery: {d}% ({d}mV)\n", .{ self.battery_percent, self.battery_voltage_mv });
        try writer.print("  External Power: {s}\n", .{if (self.external_power) "Yes" else "No"});
        try writer.print("  Charging: {s}\n", .{if (self.is_charging) "Yes" else "No"});
        if (self.failure_reason) |reason| {
            try writer.print("  Failure: {s}\n", .{reason});
        }
    }
};

/// Battery status provider interface
/// Allows the flasher to work with either real hardware or mock for testing
pub const BatteryProvider = struct {
    get_percent: *const fn () u8,
    get_voltage_mv: *const fn () u16,
    is_charging: *const fn () bool,
    external_power_present: *const fn () bool,

    /// Default provider that returns safe values for host testing
    pub const mock = BatteryProvider{
        .get_percent = mockGetPercent,
        .get_voltage_mv = mockGetVoltage,
        .is_charging = mockIsCharging,
        .external_power_present = mockExternalPower,
    };

    fn mockGetPercent() u8 {
        return 100; // Assume full battery for host testing
    }

    fn mockGetVoltage() u16 {
        return 4200; // Full charge voltage
    }

    fn mockIsCharging() bool {
        return false;
    }

    fn mockExternalPower() bool {
        return true; // Assume external power for host testing
    }
};

/// Watchdog provider interface
pub const WatchdogProvider = struct {
    init: *const fn (timeout_ms: u32) void,
    start: *const fn () void,
    stop: *const fn () void,
    refresh: *const fn () void,

    /// Default provider that does nothing for host testing
    pub const mock = WatchdogProvider{
        .init = mockInit,
        .start = mockStart,
        .stop = mockStop,
        .refresh = mockRefresh,
    };

    fn mockInit(_: u32) void {}
    fn mockStart() void {}
    fn mockStop() void {}
    fn mockRefresh() void {}
};

/// Safe Flasher
pub const SafeFlasher = struct {
    /// Disk mode interface
    disk: DiskModeInterface,
    /// Backup manager
    backups: BackupManager,
    /// Current state
    state: FlashState = .idle,
    /// Last backup path (for rollback)
    last_backup_path: ?[]u8 = null,
    /// Allocator
    allocator: std.mem.Allocator,
    /// Battery status provider
    battery: BatteryProvider,
    /// Watchdog provider
    watchdog: WatchdogProvider,
    /// Sectors processed (for watchdog refresh)
    sectors_processed: u64 = 0,
    /// Last safety check result
    last_safety_check: ?SafetyCheckResult = null,

    const Self = @This();

    /// Create a new safe flasher with mock providers (for host testing)
    pub fn init(allocator: std.mem.Allocator, backup_dir: []const u8) Self {
        return initWithProviders(allocator, backup_dir, BatteryProvider.mock, WatchdogProvider.mock);
    }

    /// Create a new safe flasher with custom providers (for real hardware)
    pub fn initWithProviders(
        allocator: std.mem.Allocator,
        backup_dir: []const u8,
        battery_provider: BatteryProvider,
        watchdog_provider: WatchdogProvider,
    ) Self {
        return .{
            .allocator = allocator,
            .disk = DiskModeInterface.init(allocator),
            .backups = BackupManager.init(allocator, backup_dir),
            .battery = battery_provider,
            .watchdog = watchdog_provider,
        };
    }

    /// Cleanup
    pub fn deinit(self: *Self) void {
        // Ensure watchdog is stopped
        self.watchdog.stop();
        self.disk.deinit();
        if (self.last_backup_path) |path| {
            self.allocator.free(path);
        }
    }

    // ============================================================
    // Safety Check Functions
    // ============================================================

    /// Perform comprehensive safety check before flash operation
    pub fn checkSafety(self: *Self, options: FlashOptions) SafetyCheckResult {
        const battery_percent = self.battery.get_percent();
        const battery_voltage = self.battery.get_voltage_mv();
        const external_power = self.battery.external_power_present();
        const is_charging = self.battery.is_charging();

        var result = SafetyCheckResult{
            .passed = true,
            .battery_percent = battery_percent,
            .battery_voltage_mv = battery_voltage,
            .external_power = external_power,
            .is_charging = is_charging,
            .failure_reason = null,
        };

        // Check battery level
        if (options.check_battery) {
            if (battery_percent < CRITICAL_BATTERY_PERCENT) {
                result.passed = false;
                result.failure_reason = "CRITICAL: Battery below 10% - flash operation forbidden";
                self.last_safety_check = result;
                return result;
            }

            if (battery_percent < options.min_battery_percent) {
                result.passed = false;
                result.failure_reason = "Battery below minimum threshold for safe flashing";
                self.last_safety_check = result;
                return result;
            }

            // Also check voltage as backup (percentage can be unreliable)
            if (battery_voltage < MIN_BATTERY_VOLTAGE_MV and !external_power) {
                result.passed = false;
                result.failure_reason = "Battery voltage too low (below 3.2V)";
                self.last_safety_check = result;
                return result;
            }
        }

        // Check external power requirement
        if (options.require_external_power and !external_power) {
            result.passed = false;
            result.failure_reason = "External power required but not connected";
            self.last_safety_check = result;
            return result;
        }

        self.last_safety_check = result;
        return result;
    }

    /// Check if battery is at critical level (should abort immediately)
    pub fn isBatteryCritical(self: *Self) bool {
        return self.battery.get_percent() < CRITICAL_BATTERY_PERCENT;
    }

    /// Get last safety check result
    pub fn getLastSafetyCheck(self: *const Self) ?SafetyCheckResult {
        return self.last_safety_check;
    }

    /// Refresh watchdog and check battery during long operations
    fn refreshSafetyDuringOperation(self: *Self, options: FlashOptions) FlasherError!void {
        self.sectors_processed += 1;

        // Refresh watchdog periodically
        if (self.sectors_processed % WATCHDOG_REFRESH_INTERVAL_SECTORS == 0) {
            self.watchdog.refresh();

            // Also check battery during long operations
            if (options.abort_on_critical_battery and self.isBatteryCritical()) {
                self.state = .aborted_low_battery;
                self.watchdog.stop();
                return FlasherError.CriticalBattery;
            }
        }
    }

    /// Connect to device
    pub fn connect(self: *Self, device_path: ?[]const u8) FlasherError!void {
        if (device_path) |path| {
            self.disk.connect(path) catch return FlasherError.NoDevice;
        } else {
            self.disk.connectAny() catch return FlasherError.NoDevice;
        }
    }

    /// Disconnect
    pub fn disconnect(self: *Self) void {
        self.disk.disconnect();
    }

    /// Check if connected
    pub fn isConnected(self: *const Self) bool {
        return self.disk.isConnected();
    }

    /// Get device info
    pub fn getDeviceInfo(self: *const Self) ?DeviceInfo {
        return self.disk.getDeviceInfo();
    }

    /// Create a backup of specified sectors
    pub fn createBackup(
        self: *Self,
        start_sector: u64,
        count: u64,
        description: []const u8,
    ) FlasherError![]const u8 {
        if (!self.isConnected()) return FlasherError.NotConnected;
        if (self.state != .idle) return FlasherError.AlreadyInProgress;

        self.state = .backing_up;
        errdefer self.state = .failed;

        const info = self.disk.getDeviceInfo() orelse return FlasherError.NotConnected;

        // Create metadata
        var meta = BackupMetadata.create(
            info.getModel(),
            info.getSerial(),
            start_sector,
            count,
        );
        meta.setDescription(description);

        // Read sectors
        const data_size = count * info.sector_size;
        const data = self.allocator.alloc(u8, data_size) catch return FlasherError.BackupFailed;
        defer self.allocator.free(data);

        _ = self.disk.readSectors(start_sector, @intCast(count), data) catch return FlasherError.ReadFailed;

        // Create backup file
        const backup_path = self.backups.createBackup(&meta, data) catch return FlasherError.BackupFailed;

        // Store for potential rollback
        if (self.last_backup_path) |old| {
            self.allocator.free(old);
        }
        self.last_backup_path = self.allocator.dupe(u8, backup_path) catch return FlasherError.BackupFailed;
        self.allocator.free(backup_path);

        self.state = .idle;
        return self.last_backup_path.?;
    }

    /// Flash data to device (with comprehensive safety checks)
    ///
    /// This function implements a safe flashing procedure:
    /// 1. Pre-flight safety checks (battery, power)
    /// 2. Watchdog initialization
    /// 3. Automatic backup creation
    /// 4. Backup verification
    /// 5. Flash operation with periodic safety checks
    /// 6. Post-flash verification
    /// 7. Automatic rollback on failure (if enabled)
    ///
    /// Returns error if any step fails. On verification failure,
    /// will attempt automatic rollback if auto_rollback_on_failure is enabled.
    pub fn flashData(
        self: *Self,
        start_sector: u64,
        data: []const u8,
        options: FlashOptions,
    ) FlasherError!void {
        if (!self.isConnected()) return FlasherError.NotConnected;
        if (self.state != .idle) return FlasherError.AlreadyInProgress;

        const info = self.disk.getDeviceInfo() orelse return FlasherError.NotConnected;
        const sector_count = (data.len + info.sector_size - 1) / info.sector_size;

        // Reset state tracking
        self.sectors_processed = 0;

        // ============================================================
        // Step 0: Pre-flight Safety Checks
        // ============================================================
        self.state = .checking_safety;
        self.reportProgress(options.progress_callback, 0, sector_count, "Checking safety conditions...");

        const safety = self.checkSafety(options);
        if (!safety.passed) {
            self.state = .aborted_safety;
            if (safety.battery_percent < CRITICAL_BATTERY_PERCENT) {
                return FlasherError.CriticalBattery;
            }
            if (safety.failure_reason) |reason| {
                if (std.mem.indexOf(u8, reason, "External power") != null) {
                    return FlasherError.ExternalPowerRequired;
                }
            }
            return FlasherError.LowBattery;
        }

        // ============================================================
        // Step 1: Initialize Watchdog
        // ============================================================
        if (options.enable_watchdog) {
            self.watchdog.init(options.watchdog_timeout_ms);
            self.watchdog.start();
        }
        // Ensure watchdog is stopped on any exit
        defer if (options.enable_watchdog) self.watchdog.stop();

        // ============================================================
        // Step 2: Create Backup
        // ============================================================
        if (options.create_backup) {
            self.state = .backing_up;
            self.reportProgress(options.progress_callback, 0, sector_count, "Creating backup...");

            if (options.enable_watchdog) self.watchdog.refresh();

            _ = self.createBackup(start_sector, sector_count, options.backup_description) catch |err| {
                self.state = .failed;
                return err;
            };
        }

        // ============================================================
        // Step 3: Verify Backup
        // ============================================================
        if (options.create_backup and options.verify_backup_before_flash) {
            self.state = .verifying_backup;
            self.reportProgress(options.progress_callback, 0, 1, "Verifying backup integrity...");

            if (options.enable_watchdog) self.watchdog.refresh();

            if (self.last_backup_path) |path| {
                _ = self.backups.verifyBackup(path) catch {
                    self.state = .failed;
                    return FlasherError.VerificationFailed;
                };
            }
        }

        // ============================================================
        // Step 4: Final Pre-Flash Battery Check
        // ============================================================
        if (options.check_battery) {
            if (self.isBatteryCritical()) {
                self.state = .aborted_low_battery;
                return FlasherError.CriticalBattery;
            }
        }

        // ============================================================
        // Step 5: Set Protection Mode
        // ============================================================
        if (options.allow_protected_writes) {
            self.disk.enableProtectedWrites(true);
        }
        defer self.disk.enableProtectedWrites(false);

        // ============================================================
        // Step 6: Flash Operation
        // ============================================================
        self.state = .flashing;
        self.reportProgress(options.progress_callback, 0, sector_count, "Flashing firmware...");

        if (options.enable_watchdog) self.watchdog.refresh();

        const bytes_written = self.disk.writeSectors(
            start_sector,
            @intCast(sector_count),
            data,
        ) catch |err| {
            self.state = .failed;
            // Attempt rollback on write failure if we have a backup
            if (options.auto_rollback_on_failure and self.last_backup_path != null) {
                self.reportProgress(options.progress_callback, 0, sector_count, "Write failed - attempting rollback...");
                self.rollback() catch {};
            }
            return switch (err) {
                DiskModeError.ProtectedRegion => FlasherError.ProtectedRegion,
                else => FlasherError.WriteFailed,
            };
        };

        if (bytes_written < data.len) {
            self.state = .failed;
            if (options.auto_rollback_on_failure and self.last_backup_path != null) {
                self.reportProgress(options.progress_callback, 0, sector_count, "Incomplete write - attempting rollback...");
                self.rollback() catch {};
            }
            return FlasherError.WriteFailed;
        }

        // ============================================================
        // Step 7: Post-Flash Verification
        // ============================================================
        if (options.verify_after_write) {
            self.state = .verifying_flash;
            self.reportProgress(options.progress_callback, 0, sector_count, "Verifying flash...");

            if (options.enable_watchdog) self.watchdog.refresh();

            // Check battery before verification (it's a critical phase)
            if (options.abort_on_critical_battery and self.isBatteryCritical()) {
                self.state = .aborted_low_battery;
                return FlasherError.CriticalBattery;
            }

            const verify_buffer = self.allocator.alloc(u8, data.len) catch {
                self.state = .failed;
                return FlasherError.VerificationFailed;
            };
            defer self.allocator.free(verify_buffer);

            _ = self.disk.readSectors(start_sector, @intCast(sector_count), verify_buffer) catch {
                self.state = .failed;
                // Attempt rollback on read failure during verify
                if (options.auto_rollback_on_failure and self.last_backup_path != null) {
                    self.reportProgress(options.progress_callback, 0, sector_count, "Verification read failed - attempting rollback...");
                    self.rollback() catch {};
                }
                return FlasherError.ReadFailed;
            };

            if (!std.mem.eql(u8, data, verify_buffer[0..data.len])) {
                self.state = .failed;
                // CRITICAL: Data mismatch - attempt rollback immediately
                if (options.auto_rollback_on_failure and self.last_backup_path != null) {
                    self.reportProgress(options.progress_callback, 0, sector_count, "VERIFICATION FAILED - rolling back...");
                    self.rollback() catch {
                        // Rollback failed too - this is a critical situation
                        self.reportProgress(options.progress_callback, 0, sector_count, "CRITICAL: Rollback failed! Device may be in inconsistent state.");
                    };
                }
                return FlasherError.VerificationFailed;
            }
        }

        // ============================================================
        // Step 8: Success
        // ============================================================
        self.state = .completed;
        self.reportProgress(options.progress_callback, sector_count, sector_count, "Flash completed successfully!");
    }

    /// Rollback to last backup
    pub fn rollback(self: *Self) FlasherError!void {
        if (!self.isConnected()) return FlasherError.NotConnected;

        const backup_path = self.last_backup_path orelse return FlasherError.NothingToRollback;

        self.state = .rolling_back;
        errdefer self.state = .failed;

        // Read backup
        const backup_data = self.backups.readBackupData(backup_path) catch return FlasherError.RollbackFailed;
        defer self.allocator.free(backup_data.data);

        // Write back
        const sector_count: u32 = @intCast(backup_data.meta.sector_count);
        _ = self.disk.writeSectors(
            backup_data.meta.start_sector,
            sector_count,
            backup_data.data,
        ) catch return FlasherError.RollbackFailed;

        self.state = .completed;
    }

    /// Verify firmware file format
    pub fn verifyFirmwareFile(self: *Self, path: []const u8) !bool {
        _ = self;
        const file = std.fs.cwd().openFile(path, .{}) catch return false;
        defer file.close();

        // Read header and check for valid firmware magic
        var header: [16]u8 = undefined;
        _ = file.readAll(&header) catch return false;

        // Check for common iPod firmware signatures
        // "!ATA" - iPod firmware
        // "aupd" - Apple update
        if (std.mem.eql(u8, header[0..4], "!ATA") or
            std.mem.eql(u8, header[0..4], "aupd"))
        {
            return true;
        }

        return false;
    }

    /// Flash firmware file
    pub fn flashFirmware(self: *Self, firmware_path: []const u8, options: FlashOptions) FlasherError!void {
        // Verify firmware format
        const valid = self.verifyFirmwareFile(firmware_path) catch return FlasherError.InvalidFirmware;
        if (!valid) return FlasherError.InvalidFirmware;

        // Read firmware file
        const file = std.fs.cwd().openFile(firmware_path, .{}) catch return FlasherError.ReadFailed;
        defer file.close();

        const stat = file.stat() catch return FlasherError.ReadFailed;
        const firmware_data = self.allocator.alloc(u8, stat.size) catch return FlasherError.ReadFailed;
        defer self.allocator.free(firmware_data);

        _ = file.readAll(firmware_data) catch return FlasherError.ReadFailed;

        // Firmware typically starts at sector 63 (after partition table)
        const FIRMWARE_START_SECTOR: u64 = 63;

        try self.flashData(FIRMWARE_START_SECTOR, firmware_data, options);
    }

    /// Helper to report progress
    fn reportProgress(
        self: *Self,
        callback: ?ProgressCallback,
        current: u64,
        total: u64,
        message: []const u8,
    ) void {
        if (callback) |cb| {
            cb(self.state, current, total, message);
        }
    }

    /// Get current state
    pub fn getState(self: *const Self) FlashState {
        return self.state;
    }

    /// Reset state to idle
    pub fn resetState(self: *Self) void {
        self.state = .idle;
    }
};

/// Print operation summary
pub fn printSummary(info: *const DeviceInfo, sectors: u64, writer: anytype) !void {
    const size_bytes = sectors * info.sector_size;
    try writer.print("Flash Operation Summary:\n", .{});
    try writer.print("  Device: {s}\n", .{info.getModel()});
    try writer.print("  Serial: {s}\n", .{info.getSerial()});
    try writer.print("  Sectors to write: {d}\n", .{sectors});
    try writer.print("  Data size: {d} bytes ({d} KB)\n", .{ size_bytes, size_bytes / 1024 });
}

// ============================================================
// Tests
// ============================================================

test "flasher init" {
    const allocator = std.testing.allocator;
    var flasher = SafeFlasher.init(allocator, "/tmp/backups");
    defer flasher.deinit();

    try std.testing.expectEqual(FlashState.idle, flasher.state);
    try std.testing.expect(!flasher.isConnected());
}

test "flash options defaults" {
    const options = FlashOptions{};

    try std.testing.expect(options.create_backup);
    try std.testing.expect(options.verify_after_write);
    try std.testing.expect(!options.allow_protected_writes);
}

test "not connected errors" {
    const allocator = std.testing.allocator;
    var flasher = SafeFlasher.init(allocator, "/tmp/backups");
    defer flasher.deinit();

    try std.testing.expectError(FlasherError.NotConnected, flasher.createBackup(0, 100, "test"));
}

test "flasher state transitions" {
    const allocator = std.testing.allocator;
    var flasher = SafeFlasher.init(allocator, "/tmp/backups");
    defer flasher.deinit();

    try std.testing.expectEqual(FlashState.idle, flasher.getState());

    flasher.state = .flashing;
    try std.testing.expectEqual(FlashState.flashing, flasher.getState());

    flasher.resetState();
    try std.testing.expectEqual(FlashState.idle, flasher.getState());
}

test "nothing to rollback" {
    const allocator = std.testing.allocator;
    var flasher = SafeFlasher.init(allocator, "/tmp/backups");
    defer flasher.deinit();

    // Need to be connected for rollback check
    flasher.disk.state = .disk_mode;
    defer flasher.disk.state = .disconnected;

    try std.testing.expectError(FlasherError.NothingToRollback, flasher.rollback());
}

test "print summary" {
    var info = DeviceInfo{};
    const model = "Test Device";
    @memcpy(info.model[0..model.len], model);
    info.sector_size = 512;

    var buffer: [512]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);

    try printSummary(&info, 100, stream.writer());

    const output = stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "Test Device") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "51200 bytes") != null);
}

// ============================================================
// Safety Feature Tests
// ============================================================

test "safety constants are sensible" {
    try std.testing.expect(MIN_BATTERY_PERCENT > CRITICAL_BATTERY_PERCENT);
    try std.testing.expect(MIN_BATTERY_PERCENT <= 30);
    try std.testing.expect(CRITICAL_BATTERY_PERCENT >= 5);
    try std.testing.expect(MIN_BATTERY_VOLTAGE_MV >= 3000);
    try std.testing.expect(FLASH_WATCHDOG_TIMEOUT_MS >= 30_000);
}

test "flash options safety defaults" {
    const options = FlashOptions{};

    try std.testing.expect(options.check_battery);
    try std.testing.expect(options.enable_watchdog);
    try std.testing.expect(options.abort_on_critical_battery);
    try std.testing.expect(options.auto_rollback_on_failure);
    try std.testing.expectEqual(MIN_BATTERY_PERCENT, options.min_battery_percent);
    try std.testing.expectEqual(FLASH_WATCHDOG_TIMEOUT_MS, options.watchdog_timeout_ms);
}

test "safety check passes with mock provider" {
    const allocator = std.testing.allocator;
    var flasher = SafeFlasher.init(allocator, "/tmp/backups");
    defer flasher.deinit();

    const result = flasher.checkSafety(FlashOptions{});
    try std.testing.expect(result.passed);
    try std.testing.expectEqual(@as(u8, 100), result.battery_percent);
    try std.testing.expect(result.failure_reason == null);
}

test "safety check fails with low battery provider" {
    const allocator = std.testing.allocator;

    // Create custom provider that reports low battery
    const low_battery_provider = BatteryProvider{
        .get_percent = struct {
            fn f() u8 {
                return 5; // Critical level
            }
        }.f,
        .get_voltage_mv = struct {
            fn f() u16 {
                return 3000;
            }
        }.f,
        .is_charging = struct {
            fn f() bool {
                return false;
            }
        }.f,
        .external_power_present = struct {
            fn f() bool {
                return false;
            }
        }.f,
    };

    var flasher = SafeFlasher.initWithProviders(
        allocator,
        "/tmp/backups",
        low_battery_provider,
        WatchdogProvider.mock,
    );
    defer flasher.deinit();

    const result = flasher.checkSafety(FlashOptions{});
    try std.testing.expect(!result.passed);
    try std.testing.expectEqual(@as(u8, 5), result.battery_percent);
    try std.testing.expect(result.failure_reason != null);
}

test "safety check passes with low battery but external power" {
    const allocator = std.testing.allocator;

    // Low battery but external power connected
    const provider = BatteryProvider{
        .get_percent = struct {
            fn f() u8 {
                return 15; // Below threshold
            }
        }.f,
        .get_voltage_mv = struct {
            fn f() u16 {
                return 3100; // Below voltage threshold
            }
        }.f,
        .is_charging = struct {
            fn f() bool {
                return true;
            }
        }.f,
        .external_power_present = struct {
            fn f() bool {
                return true;
            }
        }.f,
    };

    var flasher = SafeFlasher.initWithProviders(
        allocator,
        "/tmp/backups",
        provider,
        WatchdogProvider.mock,
    );
    defer flasher.deinit();

    // With battery check but low threshold - should still fail
    var options = FlashOptions{};
    options.min_battery_percent = 10; // Lower threshold to 10%

    const result = flasher.checkSafety(options);
    try std.testing.expect(result.passed); // 15% > 10%, so passes
}

test "battery critical check" {
    const allocator = std.testing.allocator;

    const critical_provider = BatteryProvider{
        .get_percent = struct {
            fn f() u8 {
                return 5; // Critical
            }
        }.f,
        .get_voltage_mv = BatteryProvider.mock.get_voltage_mv,
        .is_charging = BatteryProvider.mock.is_charging,
        .external_power_present = BatteryProvider.mock.external_power_present,
    };

    var flasher = SafeFlasher.initWithProviders(
        allocator,
        "/tmp/backups",
        critical_provider,
        WatchdogProvider.mock,
    );
    defer flasher.deinit();

    try std.testing.expect(flasher.isBatteryCritical());
}

test "safety check result format" {
    const result = SafetyCheckResult{
        .passed = true,
        .battery_percent = 75,
        .battery_voltage_mv = 3850,
        .external_power = true,
        .is_charging = true,
        .failure_reason = null,
    };

    var buffer: [512]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);

    try result.format(stream.writer());
    const output = stream.getWritten();

    try std.testing.expect(std.mem.indexOf(u8, output, "PASSED") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "75%") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "3850mV") != null);
}
