//! Disk Mode USB Communication
//!
//! Handles communication with iPod in Disk Mode.
//! Provides raw sector access for backup and flash operations.

const std = @import("std");

/// USB Vendor/Product IDs for iPod
pub const UsbIds = struct {
    /// Apple vendor ID
    pub const APPLE_VID: u16 = 0x05AC;

    /// iPod in Disk Mode
    pub const IPOD_DISK_MODE: u16 = 0x1209;

    /// iPod Video 5G
    pub const IPOD_VIDEO_5G: u16 = 0x1261;

    /// iPod Classic
    pub const IPOD_CLASSIC: u16 = 0x1262;
};

/// Disk mode errors
pub const DiskModeError = error{
    DeviceNotFound,
    ConnectionFailed,
    NotInDiskMode,
    ReadFailed,
    WriteFailed,
    SeekFailed,
    InvalidSector,
    ProtectedRegion,
    Timeout,
    NotConnected,
};

/// Device information
pub const DeviceInfo = struct {
    /// Model name
    model: [64]u8 = [_]u8{0} ** 64,
    /// Serial number
    serial: [32]u8 = [_]u8{0} ** 32,
    /// Firmware version
    firmware: [16]u8 = [_]u8{0} ** 16,
    /// Total sectors
    total_sectors: u64 = 0,
    /// Sector size
    sector_size: u32 = 512,
    /// USB Product ID
    product_id: u16 = 0,

    pub fn getModel(self: *const DeviceInfo) []const u8 {
        return std.mem.sliceTo(&self.model, 0);
    }

    pub fn getSerial(self: *const DeviceInfo) []const u8 {
        return std.mem.sliceTo(&self.serial, 0);
    }

    pub fn getFirmware(self: *const DeviceInfo) []const u8 {
        return std.mem.sliceTo(&self.firmware, 0);
    }

    pub fn getTotalSize(self: *const DeviceInfo) u64 {
        return self.total_sectors * self.sector_size;
    }
};

/// Protected regions that should never be written
pub const ProtectedRegion = struct {
    name: []const u8,
    start_sector: u64,
    end_sector: u64,
};

/// iPod protected regions (boot ROM, etc.)
pub const PROTECTED_REGIONS = [_]ProtectedRegion{
    .{ .name = "Boot ROM", .start_sector = 0, .end_sector = 63 }, // First 32KB
    .{ .name = "Firmware Header", .start_sector = 64, .end_sector = 127 },
};

/// Disk Mode connection state
pub const ConnectionState = enum {
    disconnected,
    connecting,
    connected,
    disk_mode,
    failed,
};

/// Disk Mode communication interface
pub const DiskModeInterface = struct {
    /// Connection state
    state: ConnectionState = .disconnected,
    /// Device information
    device_info: DeviceInfo = .{},
    /// USB device handle (platform-specific)
    usb_handle: ?*anyopaque = null,
    /// Block device path (for mounted disk mode)
    block_device: ?[]const u8 = null,
    /// Allocator
    allocator: std.mem.Allocator,
    /// Allow writes to protected regions (dangerous!)
    allow_protected_writes: bool = false,

    const Self = @This();

    /// Create a new disk mode interface
    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
        };
    }

    /// Cleanup
    pub fn deinit(self: *Self) void {
        self.disconnect();
        if (self.block_device) |bd| {
            self.allocator.free(bd);
        }
    }

    /// Scan for devices
    pub fn scanDevices(self: *Self) ![]DeviceInfo {
        _ = self;
        // Platform-specific device enumeration would go here
        // This is a stub that returns empty list
        return &[_]DeviceInfo{};
    }

    /// Connect to device by path
    pub fn connect(self: *Self, device_path: []const u8) DiskModeError!void {
        self.state = .connecting;

        // Store device path
        self.block_device = self.allocator.dupe(u8, device_path) catch return DiskModeError.ConnectionFailed;

        // Try to open device and read info
        // This would involve SCSI INQUIRY and READ CAPACITY commands
        self.device_info = DeviceInfo{};

        // For simulation, set some defaults
        const path_ptr: [*]const u8 = device_path.ptr;
        const model_src = "iPod (Disk Mode)";
        @memcpy(self.device_info.model[0..model_src.len], model_src);

        // Derive a serial from the path
        var serial_idx: usize = 0;
        for (device_path) |c| {
            if (serial_idx >= 31) break;
            if (std.ascii.isAlphanumeric(c)) {
                self.device_info.serial[serial_idx] = c;
                serial_idx += 1;
            }
        }

        _ = path_ptr;
        self.device_info.total_sectors = 10000; // Placeholder
        self.state = .disk_mode;
    }

    /// Connect to first available device
    pub fn connectAny(self: *Self) DiskModeError!void {
        const devices = self.scanDevices() catch return DiskModeError.DeviceNotFound;
        if (devices.len == 0) return DiskModeError.DeviceNotFound;

        // Connect to first device
        // In real implementation, would use USB handle
        self.device_info = devices[0];
        self.state = .disk_mode;
    }

    /// Disconnect from device
    pub fn disconnect(self: *Self) void {
        self.state = .disconnected;
        self.usb_handle = null;
        if (self.block_device) |bd| {
            self.allocator.free(bd);
            self.block_device = null;
        }
    }

    /// Check if connected
    pub fn isConnected(self: *const Self) bool {
        return self.state == .disk_mode or self.state == .connected;
    }

    /// Check if sector is in protected region
    pub fn isProtectedSector(self: *const Self, sector: u64) bool {
        _ = self;
        for (PROTECTED_REGIONS) |region| {
            if (sector >= region.start_sector and sector <= region.end_sector) {
                return true;
            }
        }
        return false;
    }

    /// Read sectors
    pub fn readSectors(self: *Self, start_sector: u64, count: u32, buffer: []u8) DiskModeError!usize {
        if (!self.isConnected()) return DiskModeError.NotConnected;

        const required_size = @as(usize, count) * self.device_info.sector_size;
        if (buffer.len < required_size) return DiskModeError.ReadFailed;

        if (start_sector + count > self.device_info.total_sectors) {
            return DiskModeError.InvalidSector;
        }

        // Platform-specific read implementation would go here
        // Using SCSI READ(10) or READ(16) commands

        // For testing, return zeroed data
        @memset(buffer[0..required_size], 0);

        return required_size;
    }

    /// Write sectors (with protection check)
    pub fn writeSectors(self: *Self, start_sector: u64, count: u32, data: []const u8) DiskModeError!usize {
        if (!self.isConnected()) return DiskModeError.NotConnected;

        const required_size = @as(usize, count) * self.device_info.sector_size;
        if (data.len < required_size) return DiskModeError.WriteFailed;

        if (start_sector + count > self.device_info.total_sectors) {
            return DiskModeError.InvalidSector;
        }

        // Check for protected regions
        if (!self.allow_protected_writes) {
            for (0..count) |i| {
                if (self.isProtectedSector(start_sector + i)) {
                    return DiskModeError.ProtectedRegion;
                }
            }
        }

        // Platform-specific write implementation would go here
        // Using SCSI WRITE(10) or WRITE(16) commands

        return required_size;
    }

    /// Read entire device to file
    pub fn dumpToFile(self: *Self, path: []const u8, progress_callback: ?*const fn (u64, u64) void) DiskModeError!void {
        if (!self.isConnected()) return DiskModeError.NotConnected;

        const file = std.fs.cwd().createFile(path, .{}) catch return DiskModeError.WriteFailed;
        defer file.close();

        const sector_size = self.device_info.sector_size;
        const total = self.device_info.total_sectors;
        const chunk_sectors: u32 = 256; // Read 128KB at a time
        var buffer: [256 * 512]u8 = undefined;

        var sector: u64 = 0;
        while (sector < total) {
            const remaining = total - sector;
            const count: u32 = @intCast(@min(chunk_sectors, remaining));

            const bytes_read = try self.readSectors(sector, count, &buffer);
            file.writeAll(buffer[0..bytes_read]) catch return DiskModeError.WriteFailed;

            sector += count;

            if (progress_callback) |cb| {
                cb(sector, total);
            }
        }

        _ = sector_size;
    }

    /// Get device info
    pub fn getDeviceInfo(self: *const Self) ?DeviceInfo {
        if (!self.isConnected()) return null;
        return self.device_info;
    }

    /// Enable dangerous writes to protected regions
    pub fn enableProtectedWrites(self: *Self, enable: bool) void {
        self.allow_protected_writes = enable;
    }
};

/// Wait for device to enter disk mode
pub fn waitForDiskMode(timeout_ms: u32) !DeviceInfo {
    // Poll for device appearance
    var elapsed: u32 = 0;
    const poll_interval: u32 = 500;

    while (elapsed < timeout_ms) {
        // Check for device
        // In real implementation, enumerate USB devices

        std.Thread.sleep(poll_interval * 1_000_000);
        elapsed += poll_interval;
    }

    return error.Timeout;
}

/// Format device information for display
pub fn formatDeviceInfo(info: *const DeviceInfo, writer: anytype) !void {
    try writer.print("Device Information:\n", .{});
    try writer.print("  Model: {s}\n", .{info.getModel()});
    try writer.print("  Serial: {s}\n", .{info.getSerial()});
    try writer.print("  Firmware: {s}\n", .{info.getFirmware()});
    try writer.print("  Total Size: {d} MB ({d} sectors)\n", .{
        info.getTotalSize() / 1024 / 1024,
        info.total_sectors,
    });
    try writer.print("  Sector Size: {d} bytes\n", .{info.sector_size});
}

// ============================================================
// Tests
// ============================================================

test "device info create" {
    var info = DeviceInfo{};
    const model = "iPod Video";
    @memcpy(info.model[0..model.len], model);
    info.total_sectors = 100000;
    info.sector_size = 512;

    try std.testing.expectEqualStrings("iPod Video", info.getModel());
    try std.testing.expectEqual(@as(u64, 51200000), info.getTotalSize());
}

test "disk mode interface init" {
    const allocator = std.testing.allocator;
    var iface = DiskModeInterface.init(allocator);
    defer iface.deinit();

    try std.testing.expectEqual(ConnectionState.disconnected, iface.state);
    try std.testing.expect(!iface.isConnected());
}

test "protected regions" {
    const allocator = std.testing.allocator;
    var iface = DiskModeInterface.init(allocator);
    defer iface.deinit();

    // Sector 0 is protected (boot ROM)
    try std.testing.expect(iface.isProtectedSector(0));
    try std.testing.expect(iface.isProtectedSector(63));

    // Sector 1000 should not be protected
    try std.testing.expect(!iface.isProtectedSector(1000));
}

test "usb ids" {
    try std.testing.expectEqual(@as(u16, 0x05AC), UsbIds.APPLE_VID);
    try std.testing.expectEqual(@as(u16, 0x1209), UsbIds.IPOD_DISK_MODE);
}

test "not connected errors" {
    const allocator = std.testing.allocator;
    var iface = DiskModeInterface.init(allocator);
    defer iface.deinit();

    var buffer: [512]u8 = undefined;
    try std.testing.expectError(DiskModeError.NotConnected, iface.readSectors(0, 1, &buffer));
}

test "format device info" {
    var info = DeviceInfo{};
    const model = "Test iPod";
    @memcpy(info.model[0..model.len], model);
    info.total_sectors = 2000;
    info.sector_size = 512;

    var buffer: [1024]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);

    try formatDeviceInfo(&info, stream.writer());

    const output = stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "Test iPod") != null);
}
