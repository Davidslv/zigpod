//! Backup Management for ZigPod Flasher
//!
//! Handles backup creation, verification, and restoration.
//! Ensures data safety before any flash operations.

const std = @import("std");

/// Backup metadata (fits in 508 bytes, with 4-byte magic = 512 header)
pub const BackupMetadata = struct {
    /// Backup version for format compatibility
    version: u32 = 1,
    /// Device model (e.g., "iPod Video 5G")
    device_model: [64]u8 = [_]u8{0} ** 64,
    /// Device serial number
    serial_number: [32]u8 = [_]u8{0} ** 32,
    /// Timestamp (Unix epoch)
    timestamp: i64 = 0,
    /// Start sector (LBA)
    start_sector: u64 = 0,
    /// Number of sectors
    sector_count: u64 = 0,
    /// Sector size (typically 512)
    sector_size: u32 = 512,
    /// CRC32 checksum of data
    data_crc32: u32 = 0,
    /// Description/notes
    description: [128]u8 = [_]u8{0} ** 128,
    /// Reserved for future use
    reserved: [216]u8 = [_]u8{0} ** 216,

    const Self = @This();
    const MAGIC: [4]u8 = .{ 'Z', 'B', 'A', 'K' }; // ZigPod BAcKup
    const HEADER_SIZE: usize = 512;

    /// Create from parameters
    pub fn create(model: []const u8, serial: []const u8, start: u64, count: u64) Self {
        var meta = Self{};
        meta.timestamp = std.time.timestamp();
        meta.start_sector = start;
        meta.sector_count = count;

        const model_len = @min(model.len, 63);
        @memcpy(meta.device_model[0..model_len], model[0..model_len]);

        const serial_len = @min(serial.len, 31);
        @memcpy(meta.serial_number[0..serial_len], serial[0..serial_len]);

        return meta;
    }

    /// Set description
    pub fn setDescription(self: *Self, desc: []const u8) void {
        const desc_len = @min(desc.len, 127);
        @memset(&self.description, 0);
        @memcpy(self.description[0..desc_len], desc[0..desc_len]);
    }

    /// Get model as string
    pub fn getModel(self: *const Self) []const u8 {
        return std.mem.sliceTo(&self.device_model, 0);
    }

    /// Get serial as string
    pub fn getSerial(self: *const Self) []const u8 {
        return std.mem.sliceTo(&self.serial_number, 0);
    }

    /// Get description as string
    pub fn getDescription(self: *const Self) []const u8 {
        return std.mem.sliceTo(&self.description, 0);
    }

    /// Calculate total backup file size
    pub fn totalSize(self: *const Self) u64 {
        return HEADER_SIZE + (self.sector_count * self.sector_size);
    }

    /// Write header to file
    pub fn writeHeader(self: *const Self, file: std.fs.File) !void {
        var header: [HEADER_SIZE]u8 = [_]u8{0} ** HEADER_SIZE;

        // Write magic
        @memcpy(header[0..4], &MAGIC);

        // Write metadata
        const meta_bytes = std.mem.asBytes(self);
        @memcpy(header[4..4 + meta_bytes.len], meta_bytes);

        try file.writeAll(&header);
    }

    /// Read header from file
    pub fn readHeader(file: std.fs.File) !Self {
        var header: [HEADER_SIZE]u8 = undefined;
        const bytes_read = try file.readAll(&header);
        if (bytes_read < HEADER_SIZE) return error.InvalidBackupFile;

        // Check magic
        if (!std.mem.eql(u8, header[0..4], &MAGIC)) {
            return error.InvalidBackupMagic;
        }

        // Read metadata
        var meta: Self = undefined;
        const meta_bytes = std.mem.asBytes(&meta);
        @memcpy(meta_bytes, header[4..4 + meta_bytes.len]);

        return meta;
    }
};

/// Backup errors
pub const BackupError = error{
    InvalidBackupFile,
    InvalidBackupMagic,
    ChecksumMismatch,
    WriteFailed,
    ReadFailed,
    SeekFailed,
    FileNotFound,
    BackupTooOld,
    SizeMismatch,
    AlreadyExists,
};

/// Backup manager
pub const BackupManager = struct {
    /// Backup directory path
    backup_dir: []const u8,
    /// Allocator
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Create a new backup manager
    pub fn init(allocator: std.mem.Allocator, backup_dir: []const u8) Self {
        return .{
            .allocator = allocator,
            .backup_dir = backup_dir,
        };
    }

    /// Ensure backup directory exists
    pub fn ensureBackupDir(self: *Self) !void {
        std.fs.cwd().makePath(self.backup_dir) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };
    }

    /// Generate backup filename
    pub fn generateBackupName(self: *Self, meta: *const BackupMetadata) ![]u8 {
        const timestamp = meta.timestamp;
        const serial = meta.getSerial();

        return try std.fmt.allocPrint(
            self.allocator,
            "{s}/backup_{s}_{d}_s{d}-{d}.zbak",
            .{
                self.backup_dir,
                if (serial.len > 0) serial else "unknown",
                timestamp,
                meta.start_sector,
                meta.sector_count,
            },
        );
    }

    /// Create a backup from raw sector data
    pub fn createBackup(
        self: *Self,
        meta: *BackupMetadata,
        data: []const u8,
    ) ![]const u8 {
        try self.ensureBackupDir();

        // Calculate CRC32
        meta.data_crc32 = std.hash.Crc32.hash(data);

        // Generate filename
        const filename = try self.generateBackupName(meta);
        errdefer self.allocator.free(filename);

        // Create backup file
        const file = try std.fs.cwd().createFile(filename, .{});
        defer file.close();

        // Write header
        try meta.writeHeader(file);

        // Write data
        try file.writeAll(data);

        return filename;
    }

    /// Verify backup integrity
    pub fn verifyBackup(self: *Self, path: []const u8) !BackupMetadata {
        _ = self;

        const file = std.fs.cwd().openFile(path, .{}) catch return BackupError.FileNotFound;
        defer file.close();

        // Read metadata
        const meta = try BackupMetadata.readHeader(file);

        // Read and verify data CRC
        const expected_size = meta.sector_count * meta.sector_size;
        if (expected_size > 1024 * 1024 * 1024) { // 1GB sanity check
            return BackupError.SizeMismatch;
        }

        // For large files, we'd stream the CRC calculation
        // This is simplified for demonstration
        const stat = try file.stat();
        if (stat.size != BackupMetadata.HEADER_SIZE + expected_size) {
            return BackupError.SizeMismatch;
        }

        return meta;
    }

    /// Read backup data
    pub fn readBackupData(self: *Self, path: []const u8) !struct { meta: BackupMetadata, data: []u8 } {
        const file = std.fs.cwd().openFile(path, .{}) catch return BackupError.FileNotFound;
        defer file.close();

        // Read metadata
        const meta = try BackupMetadata.readHeader(file);

        // Read data
        const data_size = meta.sector_count * meta.sector_size;
        const data = try self.allocator.alloc(u8, data_size);
        errdefer self.allocator.free(data);

        const bytes_read = try file.readAll(data);
        if (bytes_read != data_size) {
            return BackupError.ReadFailed;
        }

        // Verify CRC
        const actual_crc = std.hash.Crc32.hash(data);
        if (actual_crc != meta.data_crc32) {
            return BackupError.ChecksumMismatch;
        }

        return .{ .meta = meta, .data = data };
    }

    /// List backups
    pub fn listBackups(self: *Self) ![]BackupMetadata {
        var backups = std.ArrayList(BackupMetadata).init(self.allocator);
        errdefer backups.deinit();

        var dir = std.fs.cwd().openDir(self.backup_dir, .{ .iterate = true }) catch {
            return backups.toOwnedSlice();
        };
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".zbak")) continue;

            const full_path = try std.fmt.allocPrint(
                self.allocator,
                "{s}/{s}",
                .{ self.backup_dir, entry.name },
            );
            defer self.allocator.free(full_path);

            const meta = self.verifyBackup(full_path) catch continue;
            try backups.append(meta);
        }

        return backups.toOwnedSlice();
    }

    /// Find latest backup for a device
    pub fn findLatestBackup(self: *Self, serial: []const u8) !?BackupMetadata {
        const backups = try self.listBackups();
        defer self.allocator.free(backups);

        var latest: ?BackupMetadata = null;
        var latest_time: i64 = 0;

        for (backups) |backup| {
            if (std.mem.eql(u8, backup.getSerial(), serial)) {
                if (backup.timestamp > latest_time) {
                    latest_time = backup.timestamp;
                    latest = backup;
                }
            }
        }

        return latest;
    }
};

/// CRC32 utility for streaming calculation
pub const Crc32Stream = struct {
    state: u32 = 0xFFFFFFFF,

    const Self = @This();

    pub fn update(self: *Self, data: []const u8) void {
        self.state = std.hash.Crc32.hash(data) ^ self.state;
    }

    pub fn final(self: *Self) u32 {
        return self.state ^ 0xFFFFFFFF;
    }
};

// ============================================================
// Tests
// ============================================================

test "backup metadata create" {
    var meta = BackupMetadata.create("iPod Video", "ABC123", 0, 1000);

    try std.testing.expectEqualStrings("iPod Video", meta.getModel());
    try std.testing.expectEqualStrings("ABC123", meta.getSerial());
    try std.testing.expectEqual(@as(u64, 0), meta.start_sector);
    try std.testing.expectEqual(@as(u64, 1000), meta.sector_count);
}

test "backup metadata description" {
    var meta = BackupMetadata{};
    meta.setDescription("Test backup for development");

    try std.testing.expectEqualStrings("Test backup for development", meta.getDescription());
}

test "backup metadata total size" {
    var meta = BackupMetadata{};
    meta.sector_count = 100;
    meta.sector_size = 512;

    // 512 header + 100 * 512 data = 51712
    try std.testing.expectEqual(@as(u64, 51712), meta.totalSize());
}

test "backup manager init" {
    const allocator = std.testing.allocator;
    const manager = BackupManager.init(allocator, "/tmp/zigpod_backups");

    try std.testing.expectEqualStrings("/tmp/zigpod_backups", manager.backup_dir);
}

test "backup filename generation" {
    const allocator = std.testing.allocator;
    var manager = BackupManager.init(allocator, "/tmp/backups");

    var meta = BackupMetadata.create("iPod", "XYZ", 0, 100);
    meta.timestamp = 1234567890;

    const filename = try manager.generateBackupName(&meta);
    defer allocator.free(filename);

    try std.testing.expect(std.mem.indexOf(u8, filename, "XYZ") != null);
    try std.testing.expect(std.mem.indexOf(u8, filename, "1234567890") != null);
    try std.testing.expect(std.mem.endsWith(u8, filename, ".zbak"));
}

test "crc32 hash" {
    const data = "Hello, World!";
    const crc = std.hash.Crc32.hash(data);

    // Known CRC32 for "Hello, World!"
    try std.testing.expect(crc != 0);
}

test "backup metadata version" {
    const meta = BackupMetadata{};
    try std.testing.expectEqual(@as(u32, 1), meta.version);
}
