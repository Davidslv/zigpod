//! Safe Flasher Tool for ZigPod
//!
//! Provides safe flashing operations with automatic backup,
//! verification, and rollback capabilities.

const std = @import("std");
const backup = @import("backup.zig");
const disk_mode = @import("disk_mode.zig");

const BackupManager = backup.BackupManager;
const BackupMetadata = backup.BackupMetadata;
const DiskModeInterface = disk_mode.DiskModeInterface;
const DeviceInfo = disk_mode.DeviceInfo;
const DiskModeError = disk_mode.DiskModeError;

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
};

/// Flash operation state
pub const FlashState = enum {
    idle,
    backing_up,
    verifying_backup,
    flashing,
    verifying_flash,
    rolling_back,
    completed,
    failed,
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

    const Self = @This();

    /// Create a new safe flasher
    pub fn init(allocator: std.mem.Allocator, backup_dir: []const u8) Self {
        return .{
            .allocator = allocator,
            .disk = DiskModeInterface.init(allocator),
            .backups = BackupManager.init(allocator, backup_dir),
        };
    }

    /// Cleanup
    pub fn deinit(self: *Self) void {
        self.disk.deinit();
        if (self.last_backup_path) |path| {
            self.allocator.free(path);
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

    /// Flash data to device (with safety checks)
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

        // Step 1: Create backup
        if (options.create_backup) {
            self.state = .backing_up;
            self.reportProgress(options.progress_callback, 0, sector_count, "Creating backup...");

            _ = try self.createBackup(start_sector, sector_count, options.backup_description);
        }

        // Step 2: Verify backup if requested
        if (options.create_backup and options.verify_backup_before_flash) {
            self.state = .verifying_backup;
            self.reportProgress(options.progress_callback, 0, 1, "Verifying backup...");

            if (self.last_backup_path) |path| {
                _ = self.backups.verifyBackup(path) catch return FlasherError.VerificationFailed;
            }
        }

        // Step 3: Set protection mode
        if (options.allow_protected_writes) {
            self.disk.enableProtectedWrites(true);
        }
        defer self.disk.enableProtectedWrites(false);

        // Step 4: Flash
        self.state = .flashing;
        self.reportProgress(options.progress_callback, 0, sector_count, "Flashing...");

        const bytes_written = self.disk.writeSectors(
            start_sector,
            @intCast(sector_count),
            data,
        ) catch |err| {
            self.state = .failed;
            return switch (err) {
                DiskModeError.ProtectedRegion => FlasherError.ProtectedRegion,
                else => FlasherError.WriteFailed,
            };
        };

        if (bytes_written < data.len) {
            self.state = .failed;
            return FlasherError.WriteFailed;
        }

        // Step 5: Verify
        if (options.verify_after_write) {
            self.state = .verifying_flash;
            self.reportProgress(options.progress_callback, 0, sector_count, "Verifying flash...");

            const verify_buffer = self.allocator.alloc(u8, data.len) catch return FlasherError.VerificationFailed;
            defer self.allocator.free(verify_buffer);

            _ = self.disk.readSectors(start_sector, @intCast(sector_count), verify_buffer) catch return FlasherError.ReadFailed;

            if (!std.mem.eql(u8, data, verify_buffer[0..data.len])) {
                self.state = .failed;
                return FlasherError.VerificationFailed;
            }
        }

        self.state = .completed;
        self.reportProgress(options.progress_callback, sector_count, sector_count, "Complete!");
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
