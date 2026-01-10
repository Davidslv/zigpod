//! iPod USB Detection Tool
//!
//! Detects iPod devices connected via USB and retrieves basic information.
//! Works on macOS using system commands (ioreg, diskutil).
//!
//! Usage:
//!   zig build ipod-detect
//!   ./zig-out/bin/ipod-detect
//!
//! Or run directly:
//!   zig build run-ipod-detect

const std = @import("std");
const posix = std.posix;

// ============================================================
// Stdout helpers (Zig 0.15 compatible)
// ============================================================

fn writeStdout(data: []const u8) void {
    _ = posix.write(posix.STDOUT_FILENO, data) catch {};
}

fn print(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const result = std.fmt.bufPrint(&buf, fmt, args) catch return;
    writeStdout(result);
}

/// Apple USB Vendor ID
const APPLE_VENDOR_ID = "0x05ac";

/// Known iPod Product IDs
const IpodProductId = enum(u16) {
    // Classic iPods
    ipod_1g_2g = 0x1201,
    ipod_3g = 0x1203,
    ipod_mini_1g = 0x1205,
    ipod_4g_photo = 0x1207,
    ipod_mini_2g = 0x1209, // Also Disk Mode ID
    ipod_video_5g = 0x1209,
    ipod_nano_1g = 0x120a,
    ipod_nano_2g = 0x1260,
    ipod_classic_6g = 0x1261,
    ipod_classic_6g_120gb = 0x1262,
    ipod_classic_7g = 0x1263,

    // Disk Mode (universal)
    disk_mode = 0x1209,

    pub fn name(self: IpodProductId) []const u8 {
        return switch (self) {
            .ipod_1g_2g => "iPod 1G/2G",
            .ipod_3g => "iPod 3G",
            .ipod_mini_1g => "iPod Mini 1G",
            .ipod_4g_photo => "iPod 4G/Photo",
            .ipod_mini_2g, .ipod_video_5g, .disk_mode => "iPod Video 5G / Disk Mode",
            .ipod_nano_1g => "iPod Nano 1G",
            .ipod_nano_2g => "iPod Nano 2G",
            .ipod_classic_6g => "iPod Classic 6G",
            .ipod_classic_6g_120gb => "iPod Classic 6G 120GB",
            .ipod_classic_7g => "iPod Classic 7G",
        };
    }
};

/// Partition information
pub const PartitionInfo = struct {
    name: [64]u8 = [_]u8{0} ** 64,
    name_len: usize = 0,
    partition_type: [32]u8 = [_]u8{0} ** 32,
    type_len: usize = 0,
    size: u64 = 0,
    device: [32]u8 = [_]u8{0} ** 32,
    device_len: usize = 0,

    pub fn getName(self: *const PartitionInfo) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn getType(self: *const PartitionInfo) []const u8 {
        return self.partition_type[0..self.type_len];
    }

    pub fn getDevice(self: *const PartitionInfo) []const u8 {
        return self.device[0..self.device_len];
    }

    pub fn getSizeGB(self: *const PartitionInfo) f64 {
        return @as(f64, @floatFromInt(self.size)) / (1024.0 * 1024.0 * 1024.0);
    }

    pub fn getSizeMB(self: *const PartitionInfo) f64 {
        return @as(f64, @floatFromInt(self.size)) / (1024.0 * 1024.0);
    }
};

/// Detected iPod information
pub const IpodInfo = struct {
    /// Product name from USB
    product_name: [128]u8 = [_]u8{0} ** 128,
    product_name_len: usize = 0,

    /// Serial number
    serial: [64]u8 = [_]u8{0} ** 64,
    serial_len: usize = 0,

    /// USB Product ID
    product_id: u16 = 0,

    /// USB Vendor ID
    vendor_id: u16 = 0,

    /// Disk device path (if in Disk Mode)
    disk_path: [64]u8 = [_]u8{0} ** 64,
    disk_path_len: usize = 0,

    /// Disk size in bytes
    disk_size: u64 = 0,

    /// Block size
    block_size: u32 = 512,

    /// Is device in Disk Mode
    in_disk_mode: bool = false,

    /// USB location ID
    location_id: [32]u8 = [_]u8{0} ** 32,
    location_id_len: usize = 0,

    /// USB speed (1=Low, 2=Full, 3=High, 4=Super)
    usb_speed: u8 = 0,

    /// Partitions (up to 8)
    partitions: [8]PartitionInfo = [_]PartitionInfo{.{}} ** 8,
    partition_count: usize = 0,

    /// Firmware partition index (-1 if not found)
    firmware_partition_idx: i8 = -1,

    /// Data partition index (-1 if not found)
    data_partition_idx: i8 = -1,

    /// Mount point (if mounted)
    mount_point: [128]u8 = [_]u8{0} ** 128,
    mount_point_len: usize = 0,

    /// Disk model string
    disk_model: [64]u8 = [_]u8{0} ** 64,
    disk_model_len: usize = 0,

    /// Media type (Internal, External, etc)
    media_type: [32]u8 = [_]u8{0} ** 32,
    media_type_len: usize = 0,

    /// Is likely iFlash/SSD (based on size > 160GB or model string)
    is_flash_storage: bool = false,

    pub fn getProductName(self: *const IpodInfo) []const u8 {
        return self.product_name[0..self.product_name_len];
    }

    pub fn getSerial(self: *const IpodInfo) []const u8 {
        return self.serial[0..self.serial_len];
    }

    pub fn getDiskPath(self: *const IpodInfo) []const u8 {
        return self.disk_path[0..self.disk_path_len];
    }

    pub fn getLocationId(self: *const IpodInfo) []const u8 {
        return self.location_id[0..self.location_id_len];
    }

    pub fn getDiskSizeGB(self: *const IpodInfo) f64 {
        return @as(f64, @floatFromInt(self.disk_size)) / (1024.0 * 1024.0 * 1024.0);
    }

    pub fn getMountPoint(self: *const IpodInfo) []const u8 {
        return self.mount_point[0..self.mount_point_len];
    }

    pub fn getDiskModel(self: *const IpodInfo) []const u8 {
        return self.disk_model[0..self.disk_model_len];
    }

    pub fn getMediaType(self: *const IpodInfo) []const u8 {
        return self.media_type[0..self.media_type_len];
    }

    pub fn getUsbSpeedString(self: *const IpodInfo) []const u8 {
        return switch (self.usb_speed) {
            1 => "Low Speed (1.5 Mbps)",
            2 => "Full Speed (12 Mbps)",
            3 => "High Speed (480 Mbps)",
            4 => "Super Speed (5 Gbps)",
            else => "Unknown",
        };
    }

    pub fn getFirmwarePartition(self: *const IpodInfo) ?*const PartitionInfo {
        if (self.firmware_partition_idx >= 0 and self.firmware_partition_idx < @as(i8, @intCast(self.partition_count))) {
            return &self.partitions[@intCast(self.firmware_partition_idx)];
        }
        return null;
    }

    pub fn getDataPartition(self: *const IpodInfo) ?*const PartitionInfo {
        if (self.data_partition_idx >= 0 and self.data_partition_idx < @as(i8, @intCast(self.partition_count))) {
            return &self.partitions[@intCast(self.data_partition_idx)];
        }
        return null;
    }
};

/// Detection result
pub const DetectionResult = struct {
    found: bool = false,
    ipod: IpodInfo = .{},
    error_message: [256]u8 = [_]u8{0} ** 256,
    error_len: usize = 0,

    pub fn getError(self: *const DetectionResult) []const u8 {
        return self.error_message[0..self.error_len];
    }
};

/// Run a command and capture output
fn runCommand(allocator: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    var child = std.process.Child.init(argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    // Read stdout directly from file
    const stdout_file = child.stdout orelse return error.NoPipe;

    // Allocate buffer for output (up to 1MB)
    const max_size: usize = 1024 * 1024;
    var buffer = try allocator.alloc(u8, max_size);
    errdefer allocator.free(buffer);

    const bytes_read = try stdout_file.readAll(buffer);
    _ = try child.wait();

    // Resize to actual size
    if (bytes_read < max_size) {
        buffer = try allocator.realloc(buffer, bytes_read);
    }

    return buffer[0..bytes_read];
}

/// Parse USB devices from ioreg output
fn parseIoregForAppleDevices(allocator: std.mem.Allocator, output: []const u8) ![]IpodInfo {
    // Use fixed-size buffer for devices (max 16 Apple devices)
    var devices_buf: [16]IpodInfo = undefined;
    var device_count: usize = 0;

    // Simple line-by-line parsing looking for Apple devices
    var lines = std.mem.splitScalar(u8, output, '\n');
    var current_device: ?IpodInfo = null;
    var in_apple_device = false;

    while (lines.next()) |line| {
        // Check for new device entry
        if (std.mem.indexOf(u8, line, "+-o ") != null) {
            // Save previous device if it was an Apple iPod
            if (current_device) |dev| {
                if (in_apple_device and dev.product_id != 0 and device_count < devices_buf.len) {
                    devices_buf[device_count] = dev;
                    device_count += 1;
                }
            }
            current_device = IpodInfo{};
            in_apple_device = false;
        }

        // Look for vendor ID
        if (std.mem.indexOf(u8, line, "idVendor")) |_| {
            if (std.mem.indexOf(u8, line, "1452") != null or
                std.mem.indexOf(u8, line, "0x5ac") != null or
                std.mem.indexOf(u8, line, "0x05ac") != null)
            {
                in_apple_device = true;
            }
        }

        // Extract product ID
        if (std.mem.indexOf(u8, line, "idProduct")) |_| {
            if (current_device) |*dev| {
                // Try to extract the hex value
                if (std.mem.indexOf(u8, line, "0x")) |hex_start| {
                    const hex_end = hex_start + 6; // 0xNNNN
                    if (hex_end <= line.len) {
                        const hex_str = line[hex_start + 2 .. hex_end];
                        dev.product_id = std.fmt.parseInt(u16, hex_str, 16) catch 0;
                    }
                }
            }
        }

        // Extract product name
        if (std.mem.indexOf(u8, line, "USB Product Name")) |_| {
            if (current_device) |*dev| {
                if (std.mem.indexOf(u8, line, "\"")) |start| {
                    if (std.mem.lastIndexOf(u8, line, "\"")) |end| {
                        if (end > start + 1) {
                            const name = line[start + 1 .. end];
                            const len = @min(name.len, dev.product_name.len);
                            @memcpy(dev.product_name[0..len], name[0..len]);
                            dev.product_name_len = len;
                        }
                    }
                }
            }
        }

        // Extract serial number
        if (std.mem.indexOf(u8, line, "USB Serial Number") != null or
            std.mem.indexOf(u8, line, "kUSBSerialNumberString") != null)
        {
            if (current_device) |*dev| {
                if (std.mem.indexOf(u8, line, "\"")) |start| {
                    if (std.mem.lastIndexOf(u8, line, "\"")) |end| {
                        if (end > start + 1) {
                            const serial = line[start + 1 .. end];
                            const len = @min(serial.len, dev.serial.len);
                            @memcpy(dev.serial[0..len], serial[0..len]);
                            dev.serial_len = len;
                        }
                    }
                }
            }
        }

        // Extract location ID
        if (std.mem.indexOf(u8, line, "locationID")) |_| {
            if (current_device) |*dev| {
                if (std.mem.indexOf(u8, line, "0x")) |start| {
                    const end = @min(start + 10, line.len);
                    const loc = line[start..end];
                    const len = @min(loc.len, dev.location_id.len);
                    @memcpy(dev.location_id[0..len], loc[0..len]);
                    dev.location_id_len = len;
                }
            }
        }
    }

    // Don't forget last device
    if (current_device) |dev| {
        if (in_apple_device and dev.product_id != 0 and device_count < devices_buf.len) {
            devices_buf[device_count] = dev;
            device_count += 1;
        }
    }

    // Allocate result slice and copy devices
    if (device_count == 0) {
        return &[_]IpodInfo{};
    }

    const result = try allocator.alloc(IpodInfo, device_count);
    @memcpy(result, devices_buf[0..device_count]);
    return result;
}

/// Check if a device is likely an iPod based on product ID
fn isIpodProductId(product_id: u16) bool {
    return switch (product_id) {
        0x1201...0x1209, // Classic iPods and Disk Mode
        0x1260...0x1263, // Nano 2G, Classic 6G/7G
        => true,
        else => false,
    };
}

/// Parse a size from diskutil output (handles "256.1 GB (255923695616 Bytes)" format)
fn parseDiskutilSize(line: []const u8) u64 {
    // Look for "(NNN Bytes)" format
    if (std.mem.indexOf(u8, line, "(")) |paren_start| {
        if (std.mem.indexOf(u8, line, " Bytes")) |bytes_end| {
            if (bytes_end > paren_start) {
                const size_str = line[paren_start + 1 .. bytes_end];
                var clean_size: [32]u8 = undefined;
                var clean_len: usize = 0;
                for (size_str) |c| {
                    if (c >= '0' and c <= '9') {
                        if (clean_len < clean_size.len) {
                            clean_size[clean_len] = c;
                            clean_len += 1;
                        }
                    }
                }
                return std.fmt.parseInt(u64, clean_size[0..clean_len], 10) catch 0;
            }
        }
    }
    return 0;
}

/// Extract string value from diskutil info line (e.g., "   Device Model:      APPLE HDD")
fn extractDiskutilValue(line: []const u8) []const u8 {
    // Find the colon
    if (std.mem.indexOf(u8, line, ":")) |colon_pos| {
        var start = colon_pos + 1;
        // Skip leading whitespace
        while (start < line.len and (line[start] == ' ' or line[start] == '\t')) {
            start += 1;
        }
        // Trim trailing whitespace
        var end = line.len;
        while (end > start and (line[end - 1] == ' ' or line[end - 1] == '\t' or line[end - 1] == '\n' or line[end - 1] == '\r')) {
            end -= 1;
        }
        if (end > start) {
            return line[start..end];
        }
    }
    return "";
}

/// Find disk device for iPod in Disk Mode
fn findDiskDevice(allocator: std.mem.Allocator, info: *IpodInfo) !void {
    // Run diskutil list to find all disks
    const output = runCommand(allocator, &.{ "diskutil", "list" }) catch return;
    defer allocator.free(output);

    // Look specifically for Apple_HFS iPod partition or Apple_partition_scheme
    var lines = std.mem.splitScalar(u8, output, '\n');
    var current_disk: ?[]const u8 = null;
    var found_apple_partition_scheme = false;
    var partition_idx: usize = 0;

    while (lines.next()) |line| {
        // Track which disk we're looking at
        if (std.mem.indexOf(u8, line, "/dev/disk")) |start| {
            var end = start + 9; // "/dev/disk"
            while (end < line.len and (line[end] >= '0' and line[end] <= '9')) {
                end += 1;
            }
            current_disk = line[start..end];
            found_apple_partition_scheme = false;
            partition_idx = 0;
        }

        // Check for Apple partition map (iPod uses this)
        if (std.mem.indexOf(u8, line, "Apple_partition_scheme") != null) {
            found_apple_partition_scheme = true;
        }

        // Parse partition entries (format: "   1:   Apple_partition_map    32.3 KB   disk10s1")
        if (found_apple_partition_scheme and current_disk != null and info.partition_count < info.partitions.len) {
            // Look for partition type identifiers
            const is_partition_line = std.mem.indexOf(u8, line, "Apple_") != null or
                std.mem.indexOf(u8, line, "EFI") != null;

            if (is_partition_line) {
                var part = &info.partitions[info.partition_count];

                // Extract partition type
                if (std.mem.indexOf(u8, line, "Apple_partition_map")) |_| {
                    const t = "Apple_partition_map";
                    @memcpy(part.partition_type[0..t.len], t);
                    part.type_len = t.len;
                } else if (std.mem.indexOf(u8, line, "Apple_MDFW")) |_| {
                    const t = "Apple_MDFW";
                    @memcpy(part.partition_type[0..t.len], t);
                    part.type_len = t.len;
                    const n = "Firmware";
                    @memcpy(part.name[0..n.len], n);
                    part.name_len = n.len;
                    info.firmware_partition_idx = @intCast(info.partition_count);
                } else if (std.mem.indexOf(u8, line, "Apple_HFS")) |_| {
                    const t = "Apple_HFS";
                    @memcpy(part.partition_type[0..t.len], t);
                    part.type_len = t.len;
                    // Check if it's the iPod data partition
                    if (std.mem.indexOf(u8, line, "iPod") != null or std.mem.indexOf(u8, line, "IPOD") != null) {
                        const n = "iPod";
                        @memcpy(part.name[0..n.len], n);
                        part.name_len = n.len;
                        info.data_partition_idx = @intCast(info.partition_count);
                    }
                } else if (std.mem.indexOf(u8, line, "Apple_Free")) |_| {
                    const t = "Apple_Free";
                    @memcpy(part.partition_type[0..t.len], t);
                    part.type_len = t.len;
                }

                // Extract device path (e.g., "disk10s1" at end of line)
                var iter = std.mem.splitBackwardsScalar(u8, line, ' ');
                if (iter.next()) |last| {
                    if (std.mem.startsWith(u8, last, "disk")) {
                        const dev_path = "/dev/";
                        @memcpy(part.device[0..dev_path.len], dev_path);
                        const last_len = @min(last.len, part.device.len - dev_path.len);
                        @memcpy(part.device[dev_path.len .. dev_path.len + last_len], last[0..last_len]);
                        part.device_len = dev_path.len + last_len;
                    }
                }

                if (part.type_len > 0) {
                    info.partition_count += 1;
                }
            }
        }

        // Look for Apple_HFS iPod partition (the actual iPod data partition)
        if (std.mem.indexOf(u8, line, "Apple_HFS") != null and
            (std.mem.indexOf(u8, line, "iPod") != null or std.mem.indexOf(u8, line, "IPOD") != null))
        {
            if (current_disk) |disk| {
                const len = @min(disk.len, info.disk_path.len);
                @memcpy(info.disk_path[0..len], disk[0..len]);
                info.disk_path_len = len;
                info.in_disk_mode = true;
            }
        }
    }

    // Get detailed disk info if we found the disk
    if (info.disk_path_len > 0) {
        const disk_path = info.getDiskPath();
        const disk_info = runCommand(allocator, &.{ "diskutil", "info", disk_path }) catch return;
        defer allocator.free(disk_info);

        // Parse disk info
        var info_lines = std.mem.splitScalar(u8, disk_info, '\n');
        while (info_lines.next()) |info_line| {
            // Get disk size
            if (std.mem.indexOf(u8, info_line, "Disk Size:") != null) {
                info.disk_size = parseDiskutilSize(info_line);
            }

            // Get block size
            if (std.mem.indexOf(u8, info_line, "Device Block Size:") != null) {
                const val = extractDiskutilValue(info_line);
                // Parse "512 Bytes" format
                var iter = std.mem.splitScalar(u8, val, ' ');
                if (iter.next()) |num_str| {
                    info.block_size = std.fmt.parseInt(u32, num_str, 10) catch 512;
                }
            }

            // Get device model
            if (std.mem.indexOf(u8, info_line, "Device / Media Name:") != null) {
                const val = extractDiskutilValue(info_line);
                const vlen = @min(val.len, info.disk_model.len);
                @memcpy(info.disk_model[0..vlen], val[0..vlen]);
                info.disk_model_len = vlen;

                // Check for flash storage indicators
                if (std.mem.indexOf(u8, val, "SD") != null or
                    std.mem.indexOf(u8, val, "Flash") != null or
                    std.mem.indexOf(u8, val, "iFlash") != null or
                    std.mem.indexOf(u8, val, "SSD") != null or
                    std.mem.indexOf(u8, val, "CF") != null)
                {
                    info.is_flash_storage = true;
                }
            }

            // Get media type
            if (std.mem.indexOf(u8, info_line, "Removable Media:") != null) {
                const val = extractDiskutilValue(info_line);
                const vlen = @min(val.len, info.media_type.len);
                @memcpy(info.media_type[0..vlen], val[0..vlen]);
                info.media_type_len = vlen;
            }
        }

        // If disk is larger than 160GB, likely flash storage
        if (info.disk_size > 160 * 1024 * 1024 * 1024) {
            info.is_flash_storage = true;
        }

        // Get partition sizes
        for (info.partitions[0..info.partition_count]) |*part| {
            if (part.device_len > 0) {
                const part_info = runCommand(allocator, &.{ "diskutil", "info", part.getDevice() }) catch continue;
                defer allocator.free(part_info);

                var part_lines = std.mem.splitScalar(u8, part_info, '\n');
                while (part_lines.next()) |pline| {
                    if (std.mem.indexOf(u8, pline, "Disk Size:") != null or
                        std.mem.indexOf(u8, pline, "Total Size:") != null)
                    {
                        part.size = parseDiskutilSize(pline);
                        break;
                    }
                }
            }
        }

        // Get mount point
        const mount_output = runCommand(allocator, &.{ "mount" }) catch return;
        defer allocator.free(mount_output);

        var mount_lines = std.mem.splitScalar(u8, mount_output, '\n');
        while (mount_lines.next()) |mline| {
            // Look for our disk in mount output
            if (std.mem.indexOf(u8, mline, disk_path) != null or
                (info.partition_count > 0 and std.mem.indexOf(u8, mline, "disk") != null))
            {
                // Check for iPod mount
                if (std.mem.indexOf(u8, mline, "/Volumes/")) |vol_start| {
                    var vol_end = vol_start + 9;
                    while (vol_end < mline.len and mline[vol_end] != ' ' and mline[vol_end] != '(') {
                        vol_end += 1;
                    }
                    const mount = mline[vol_start..vol_end];
                    const mlen = @min(mount.len, info.mount_point.len);
                    @memcpy(info.mount_point[0..mlen], mount[0..mlen]);
                    info.mount_point_len = mlen;
                    break;
                }
            }
        }
    }
}

/// Detect connected iPod devices
pub fn detectIpod(allocator: std.mem.Allocator) DetectionResult {
    var result = DetectionResult{};

    // Run ioreg to get USB device tree
    const ioreg_output = runCommand(allocator, &.{ "ioreg", "-p", "IOUSB", "-l", "-w", "0" }) catch |err| {
        const msg = std.fmt.bufPrint(&result.error_message, "Failed to run ioreg: {}", .{err}) catch "Error";
        result.error_len = msg.len;
        return result;
    };
    defer allocator.free(ioreg_output);

    // Parse for Apple devices
    const devices = parseIoregForAppleDevices(allocator, ioreg_output) catch |err| {
        const msg = std.fmt.bufPrint(&result.error_message, "Failed to parse ioreg: {}", .{err}) catch "Error";
        result.error_len = msg.len;
        return result;
    };
    defer allocator.free(devices);

    // Find iPod among Apple devices
    for (devices) |*dev| {
        if (isIpodProductId(dev.product_id)) {
            result.found = true;
            result.ipod = dev.*;

            // Try to find disk device
            findDiskDevice(allocator, &result.ipod) catch {};

            break;
        }
    }

    // If not found via ioreg USB parsing, try direct ioreg search
    if (!result.found) {
        const ioreg_ipod = runCommand(allocator, &.{ "ioreg", "-r", "-c", "IOUSBHostDevice", "-l" }) catch return result;
        defer allocator.free(ioreg_ipod);

        // Find the iPod section specifically
        if (std.mem.indexOf(u8, ioreg_ipod, "\"kUSBProductString\" = \"iPod\"")) |ipod_pos| {
            result.found = true;

            // Search AFTER the iPod string for idProduct (it comes after in the output)
            // Look in the 500 bytes after the iPod string
            const search_end = @min(ipod_pos + 500, ioreg_ipod.len);
            const search_region = ioreg_ipod[ipod_pos..search_end];

            // Try "idProduct" = NNNN" format (with spaces, standard ioreg format)
            if (std.mem.indexOf(u8, search_region, "\"idProduct\" = ")) |id_pos| {
                const num_start = id_pos + 14; // length of "\"idProduct\" = "
                var num_end = num_start;
                while (num_end < search_region.len and search_region[num_end] >= '0' and search_region[num_end] <= '9') {
                    num_end += 1;
                }
                if (num_end > num_start) {
                    result.ipod.product_id = std.fmt.parseInt(u16, search_region[num_start..num_end], 10) catch 0;
                }
            }

            // Also try "idProduct\"=NNNN" format (no spaces, in USB Device Info dict)
            if (result.ipod.product_id == 0) {
                if (std.mem.indexOf(u8, search_region, "\"idProduct\"=")) |id_pos| {
                    const num_start = id_pos + 12;
                    var num_end = num_start;
                    while (num_end < search_region.len and search_region[num_end] >= '0' and search_region[num_end] <= '9') {
                        num_end += 1;
                    }
                    if (num_end > num_start) {
                        result.ipod.product_id = std.fmt.parseInt(u16, search_region[num_start..num_end], 10) catch 0;
                    }
                }
            }

            // Extract vendor ID
            if (std.mem.indexOf(u8, search_region, "\"idVendor\" = ")) |id_pos| {
                const num_start = id_pos + 13;
                var num_end = num_start;
                while (num_end < search_region.len and search_region[num_end] >= '0' and search_region[num_end] <= '9') {
                    num_end += 1;
                }
                if (num_end > num_start) {
                    result.ipod.vendor_id = std.fmt.parseInt(u16, search_region[num_start..num_end], 10) catch 0;
                }
            }

            // Extract USB speed (1=Low, 2=Full, 3=High)
            if (std.mem.indexOf(u8, search_region, "\"Device Speed\" = ")) |speed_pos| {
                const num_start = speed_pos + 17;
                if (num_start < search_region.len and search_region[num_start] >= '0' and search_region[num_start] <= '9') {
                    result.ipod.usb_speed = search_region[num_start] - '0';
                }
            }

            // Also check "USBSpeed" format
            if (result.ipod.usb_speed == 0) {
                // Search backwards in the region before iPod string
                const pre_search_start = if (ipod_pos > 500) ipod_pos - 500 else 0;
                const pre_search_region = ioreg_ipod[pre_search_start..ipod_pos];
                if (std.mem.indexOf(u8, pre_search_region, "\"USBSpeed\" = ")) |speed_pos| {
                    const num_start = speed_pos + 13;
                    if (num_start < pre_search_region.len and pre_search_region[num_start] >= '0' and pre_search_region[num_start] <= '9') {
                        result.ipod.usb_speed = pre_search_region[num_start] - '0';
                    }
                }
            }

            // Extract location ID
            if (std.mem.indexOf(u8, search_region, "\"locationID\" = ")) |loc_pos| {
                const num_start = loc_pos + 15;
                var num_end = num_start;
                while (num_end < search_region.len and search_region[num_end] >= '0' and search_region[num_end] <= '9') {
                    num_end += 1;
                }
                if (num_end > num_start) {
                    // Convert decimal to hex string for display
                    const loc_dec = std.fmt.parseInt(u32, search_region[num_start..num_end], 10) catch 0;
                    const loc_str = std.fmt.bufPrint(&result.ipod.location_id, "0x{X:0>8}", .{loc_dec}) catch "";
                    result.ipod.location_id_len = loc_str.len;
                }
            }

            // Extract serial - it appears BEFORE the iPod string in the output
            // Look in the 500 bytes before the iPod string
            const serial_search_start = if (ipod_pos > 500) ipod_pos - 500 else 0;
            const serial_search_region = ioreg_ipod[serial_search_start..ipod_pos];

            // Try "USB Serial Number" = "XXXX" format (standard ioreg format)
            if (std.mem.indexOf(u8, serial_search_region, "\"USB Serial Number\" = \"")) |serial_idx| {
                const start = serial_idx + 23;
                if (std.mem.indexOfPos(u8, serial_search_region, start, "\"")) |end| {
                    const serial = serial_search_region[start..end];
                    const len = @min(serial.len, result.ipod.serial.len);
                    @memcpy(result.ipod.serial[0..len], serial[0..len]);
                    result.ipod.serial_len = len;
                }
            }

            // Also try "kUSBSerialNumberString" format (after iPod string, in USB Device Info)
            if (result.ipod.serial_len == 0) {
                if (std.mem.indexOf(u8, search_region, "\"kUSBSerialNumberString\"=\"")) |serial_idx| {
                    const start = serial_idx + 25;
                    if (std.mem.indexOfPos(u8, search_region, start, "\"")) |end| {
                        const serial = search_region[start..end];
                        const len = @min(serial.len, result.ipod.serial.len);
                        @memcpy(result.ipod.serial[0..len], serial[0..len]);
                        result.ipod.serial_len = len;
                    }
                }
            }

            // Determine model from product ID
            const model_name: []const u8 = switch (result.ipod.product_id) {
                4617 => "iPod Video 5G/5.5G", // 0x1209
                4705 => "iPod Classic 6G", // 0x1261
                4706 => "iPod Classic 6G 120GB", // 0x1262
                4707 => "iPod Classic 7G", // 0x1263
                else => "iPod",
            };
            @memcpy(result.ipod.product_name[0..model_name.len], model_name);
            result.ipod.product_name_len = model_name.len;
        }

        // Find disk device
        findDiskDevice(allocator, &result.ipod) catch {};
    }

    // Fallback: check for disk mode directly via diskutil
    if (!result.found) {
        const disk_output = runCommand(allocator, &.{ "diskutil", "list" }) catch return result;
        defer allocator.free(disk_output);

        if (std.mem.indexOf(u8, disk_output, "Apple_HFS iPod") != null or
            std.mem.indexOf(u8, disk_output, "Apple_HFS IPOD") != null)
        {
            result.found = true;
            const name = "iPod (via diskutil)";
            @memcpy(result.ipod.product_name[0..name.len], name);
            result.ipod.product_name_len = name.len;

            findDiskDevice(allocator, &result.ipod) catch {};
        }
    }

    return result;
}

/// Print detection results (basic output)
fn printResults(result: *const DetectionResult) void {
    print("\n", .{});
    print("╔══════════════════════════════════════════════════════════╗\n", .{});
    print("║              ZigPod iPod Detection Tool                  ║\n", .{});
    print("╠══════════════════════════════════════════════════════════╣\n", .{});

    if (result.found) {
        print("║  Status: iPod DETECTED                                   ║\n", .{});
        print("╠══════════════════════════════════════════════════════════╣\n", .{});

        // Product name
        const name = result.ipod.getProductName();
        if (name.len > 0) {
            print("║  Device:     {s:<43} ║\n", .{name});
        }

        // Product ID
        if (result.ipod.product_id != 0) {
            print("║  Product ID: 0x{X:0>4}                                       ║\n", .{result.ipod.product_id});
        }

        // Serial
        const serial = result.ipod.getSerial();
        if (serial.len > 0) {
            const display_serial = if (serial.len > 40) serial[0..40] else serial;
            print("║  Serial:     {s:<43} ║\n", .{display_serial});
        }

        // Location ID
        const loc = result.ipod.getLocationId();
        if (loc.len > 0) {
            print("║  Location:   {s:<43} ║\n", .{loc});
        }

        // Disk Mode info
        if (result.ipod.in_disk_mode) {
            print("╠══════════════════════════════════════════════════════════╣\n", .{});
            print("║  Mode: DISK MODE (ready for flashing)                    ║\n", .{});

            const disk_path = result.ipod.getDiskPath();
            if (disk_path.len > 0) {
                print("║  Disk:       {s:<43} ║\n", .{disk_path});
            }

            if (result.ipod.disk_size > 0) {
                const size_gb = result.ipod.getDiskSizeGB();
                print("║  Size:       {d:.1} GB                                      ║\n", .{size_gb});
            }
        } else {
            print("╠══════════════════════════════════════════════════════════╣\n", .{});
            print("║  Mode: Normal (not in Disk Mode)                         ║\n", .{});
            print("║                                                          ║\n", .{});
            print("║  To enter Disk Mode:                                     ║\n", .{});
            print("║  1. Hold MENU + SELECT until Apple logo                  ║\n", .{});
            print("║  2. Immediately hold SELECT + PLAY                       ║\n", .{});
        }
    } else {
        print("║  Status: No iPod detected                                ║\n", .{});
        print("╠══════════════════════════════════════════════════════════╣\n", .{});
        print("║                                                          ║\n", .{});
        print("║  Make sure your iPod is:                                 ║\n", .{});
        print("║  - Connected via USB cable                               ║\n", .{});
        print("║  - Powered on                                            ║\n", .{});
        print("║  - In Disk Mode for flashing                             ║\n", .{});
        print("║                                                          ║\n", .{});
        print("║  To enter Disk Mode:                                     ║\n", .{});
        print("║  1. Hold MENU + SELECT until Apple logo                  ║\n", .{});
        print("║  2. Immediately hold SELECT + PLAY                       ║\n", .{});

        const err = result.getError();
        if (err.len > 0) {
            print("║                                                          ║\n", .{});
            print("║  Error: {s:<48} ║\n", .{err});
        }
    }

    print("╚══════════════════════════════════════════════════════════╝\n", .{});
    print("\n", .{});
}

/// Print verbose detection results (detailed for development)
fn printVerboseResults(result: *const DetectionResult) void {
    print("\n", .{});
    print("╔══════════════════════════════════════════════════════════════════════════╗\n", .{});
    print("║              ZigPod iPod Detection Tool (VERBOSE)                        ║\n", .{});
    print("╠══════════════════════════════════════════════════════════════════════════╣\n", .{});

    if (result.found) {
        print("║  Status: iPod DETECTED                                                   ║\n", .{});

        // USB Information Section
        print("╠══════════════════════════════════════════════════════════════════════════╣\n", .{});
        print("║  USB DEVICE INFORMATION                                                  ║\n", .{});
        print("╠══════════════════════════════════════════════════════════════════════════╣\n", .{});

        const name = result.ipod.getProductName();
        if (name.len > 0) {
            print("║  Device:        {s:<56} ║\n", .{name});
        }

        if (result.ipod.vendor_id != 0) {
            print("║  Vendor ID:     0x{X:0>4} (Apple Inc.)                                     ║\n", .{result.ipod.vendor_id});
        } else {
            print("║  Vendor ID:     0x05AC (Apple Inc.)                                      ║\n", .{});
        }

        if (result.ipod.product_id != 0) {
            const prod_desc: []const u8 = switch (result.ipod.product_id) {
                0x1201 => "iPod 1G/2G",
                0x1203 => "iPod 3G",
                0x1205 => "iPod Mini 1G",
                0x1207 => "iPod 4G/Photo",
                0x1209 => "iPod Video 5G/5.5G / Disk Mode",
                0x120A => "iPod Nano 1G",
                0x1260 => "iPod Nano 2G",
                0x1261 => "iPod Classic 6G",
                0x1262 => "iPod Classic 6G 120GB",
                0x1263 => "iPod Classic 7G",
                else => "Unknown iPod",
            };
            print("║  Product ID:    0x{X:0>4} ({s:<38}) ║\n", .{ result.ipod.product_id, prod_desc });
        }

        const serial = result.ipod.getSerial();
        if (serial.len > 0) {
            print("║  Serial:        {s:<56} ║\n", .{serial});
        }

        const loc = result.ipod.getLocationId();
        if (loc.len > 0) {
            print("║  Location ID:   {s:<56} ║\n", .{loc});
        }

        if (result.ipod.usb_speed != 0) {
            print("║  USB Speed:     {s:<56} ║\n", .{result.ipod.getUsbSpeedString()});
        }

        // Storage Information Section
        if (result.ipod.in_disk_mode) {
            print("╠══════════════════════════════════════════════════════════════════════════╣\n", .{});
            print("║  STORAGE INFORMATION                                                     ║\n", .{});
            print("╠══════════════════════════════════════════════════════════════════════════╣\n", .{});
            print("║  Mode:          DISK MODE (ready for ZigPod flashing)                    ║\n", .{});

            const disk_path = result.ipod.getDiskPath();
            if (disk_path.len > 0) {
                print("║  Disk Device:   {s:<56} ║\n", .{disk_path});
            }

            if (result.ipod.disk_size > 0) {
                const size_gb = result.ipod.getDiskSizeGB();
                const total_sectors = result.ipod.disk_size / result.ipod.block_size;
                print("║  Total Size:    {d:.2} GB ({d} bytes)                       ║\n", .{ size_gb, result.ipod.disk_size });
                print("║  Block Size:    {d} bytes                                            ║\n", .{result.ipod.block_size});
                print("║  Total Sectors: {d:<56} ║\n", .{total_sectors});
            }

            const model = result.ipod.getDiskModel();
            if (model.len > 0) {
                print("║  Disk Model:    {s:<56} ║\n", .{model});
            }

            const media = result.ipod.getMediaType();
            if (media.len > 0) {
                print("║  Removable:     {s:<56} ║\n", .{media});
            }

            if (result.ipod.is_flash_storage) {
                print("║  Storage Type:  Flash/SSD (iFlash or similar mod detected)              ║\n", .{});
            } else {
                print("║  Storage Type:  HDD (original mechanical drive)                         ║\n", .{});
            }

            const mount = result.ipod.getMountPoint();
            if (mount.len > 0) {
                print("║  Mount Point:   {s:<56} ║\n", .{mount});
            }

            // Partition Layout Section
            if (result.ipod.partition_count > 0) {
                print("╠══════════════════════════════════════════════════════════════════════════╣\n", .{});
                print("║  PARTITION LAYOUT                                                        ║\n", .{});
                print("╠══════════════════════════════════════════════════════════════════════════╣\n", .{});

                for (result.ipod.partitions[0..result.ipod.partition_count], 0..) |part, i| {
                    const ptype = part.getType();
                    const pname = part.getName();
                    const pdev = part.getDevice();

                    // Determine if this is firmware or data partition
                    var indicator: []const u8 = "   ";
                    if (@as(i8, @intCast(i)) == result.ipod.firmware_partition_idx) {
                        indicator = "FW ";
                    } else if (@as(i8, @intCast(i)) == result.ipod.data_partition_idx) {
                        indicator = "DAT";
                    }

                    if (part.size > 0) {
                        if (part.size < 1024 * 1024) {
                            // Show in KB for small partitions
                            const size_kb = @as(f64, @floatFromInt(part.size)) / 1024.0;
                            print("║  [{s}] {d}: {s:<20} {d:>8.1} KB  {s:<18} ║\n", .{ indicator, i + 1, ptype, size_kb, pdev });
                        } else if (part.size < 1024 * 1024 * 1024) {
                            // Show in MB
                            const size_mb = part.getSizeMB();
                            print("║  [{s}] {d}: {s:<20} {d:>8.1} MB  {s:<18} ║\n", .{ indicator, i + 1, ptype, size_mb, pdev });
                        } else {
                            // Show in GB
                            const size_gb = part.getSizeGB();
                            print("║  [{s}] {d}: {s:<20} {d:>8.2} GB  {s:<18} ║\n", .{ indicator, i + 1, ptype, size_gb, pdev });
                        }
                    } else {
                        print("║  [{s}] {d}: {s:<20} {s:<10} {s:<18} ║\n", .{ indicator, i + 1, ptype, pname, pdev });
                    }
                }

                print("║                                                                          ║\n", .{});
                print("║  Legend: [FW ] = Firmware partition (for ZigPod)                         ║\n", .{});
                print("║          [DAT] = Data partition (music/files)                            ║\n", .{});
            }

            // ZigPod Development Info
            print("╠══════════════════════════════════════════════════════════════════════════╣\n", .{});
            print("║  ZIGPOD DEVELOPMENT INFO                                                 ║\n", .{});
            print("╠══════════════════════════════════════════════════════════════════════════╣\n", .{});

            if (result.ipod.getFirmwarePartition()) |fw_part| {
                const fw_dev = fw_part.getDevice();
                print("║  Firmware Dev:  {s:<56} ║\n", .{fw_dev});
                if (fw_part.size > 0) {
                    const fw_sectors = fw_part.size / result.ipod.block_size;
                    print("║  FW Size:       {d:.2} MB ({d} sectors)                           ║\n", .{ fw_part.getSizeMB(), fw_sectors });
                }
            } else {
                print("║  Firmware Dev:  Not found (Apple_MDFW partition)                         ║\n", .{});
            }

            // PP5021 specific info
            print("║                                                                          ║\n", .{});
            print("║  Target SoC:    PP5021C (PortalPlayer)                                   ║\n", .{});
            print("║  RAM:           32 MB SDRAM                                              ║\n", .{});
            print("║  LCD:           320x240 QVGA (BCM2722)                                   ║\n", .{});
            print("║  Codec:         Wolfson WM8758                                           ║\n", .{});

            // Flash command hint
            print("║                                                                          ║\n", .{});
            print("║  To flash ZigPod:                                                        ║\n", .{});
            print("║    zigpod-flasher flash --device {s:<15} --image zigpod.bin  ║\n", .{disk_path});

        } else {
            print("╠══════════════════════════════════════════════════════════════════════════╣\n", .{});
            print("║  Mode: Normal (not in Disk Mode)                                         ║\n", .{});
            print("║                                                                          ║\n", .{});
            print("║  To enter Disk Mode for flashing:                                        ║\n", .{});
            print("║  1. Hold MENU + SELECT until Apple logo appears                          ║\n", .{});
            print("║  2. Immediately hold SELECT + PLAY                                       ║\n", .{});
            print("║  3. Wait for \"OK to disconnect\" screen                                   ║\n", .{});
        }
    } else {
        print("║  Status: No iPod detected                                                ║\n", .{});
        print("╠══════════════════════════════════════════════════════════════════════════╣\n", .{});
        print("║                                                                          ║\n", .{});
        print("║  Make sure your iPod is:                                                 ║\n", .{});
        print("║  - Connected via USB cable                                               ║\n", .{});
        print("║  - Powered on                                                            ║\n", .{});
        print("║  - In Disk Mode for flashing                                             ║\n", .{});
        print("║                                                                          ║\n", .{});
        print("║  To enter Disk Mode:                                                     ║\n", .{});
        print("║  1. Hold MENU + SELECT until Apple logo                                  ║\n", .{});
        print("║  2. Immediately hold SELECT + PLAY                                       ║\n", .{});
        print("║                                                                          ║\n", .{});
        print("║  Supported iPod models for ZigPod:                                       ║\n", .{});
        print("║  - iPod Video 5G/5.5G (0x1209) [PRIMARY TARGET]                          ║\n", .{});
        print("║  - iPod Classic 6G (0x1261)                                              ║\n", .{});
        print("║  - iPod Classic 7G (0x1263)                                              ║\n", .{});

        const err = result.getError();
        if (err.len > 0) {
            print("║                                                                          ║\n", .{});
            print("║  Error: {s:<63} ║\n", .{err});
        }
    }

    print("╚══════════════════════════════════════════════════════════════════════════╝\n", .{});
    print("\n", .{});
}

/// Watch mode - continuously check for iPod
fn watchMode(allocator: std.mem.Allocator, verbose: bool) void {
    print("\nWatching for iPod... (press Ctrl+C to stop)\n\n", .{});

    var last_found = false;
    while (true) {
        const result = detectIpod(allocator);

        if (result.found != last_found) {
            if (result.found) {
                print("iPod connected!\n", .{});
                if (verbose) {
                    printVerboseResults(&result);
                } else {
                    printResults(&result);
                }
            } else {
                print("iPod disconnected\n", .{});
            }
            last_found = result.found;
        }

        std.Thread.sleep(1 * std.time.ns_per_s);
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Parse command line options
    var watch = false;
    var verbose = false;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--watch") or std.mem.eql(u8, arg, "-w")) {
            watch = true;
        }
        if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-v")) {
            verbose = true;
        }
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            print(
                \\ZigPod iPod Detection Tool
                \\
                \\Usage: ipod-detect [OPTIONS]
                \\
                \\Options:
                \\  -v, --verbose  Show detailed device info (partition layout, USB details,
                \\                 storage type, firmware partition location, ZigPod dev info)
                \\  -w, --watch    Continuously watch for iPod connection
                \\  -h, --help     Show this help message
                \\
                \\This tool detects iPod devices connected via USB and shows
                \\their information. When an iPod is in Disk Mode, it will
                \\show the disk path needed for flashing ZigPod.
                \\
                \\Supported iPod Models:
                \\  - iPod Video 5G/5.5G (0x1209) - PRIMARY TARGET
                \\  - iPod Classic 6G (0x1261)
                \\  - iPod Classic 6G 120GB (0x1262)
                \\  - iPod Classic 7G (0x1263)
                \\
                \\Examples:
                \\  ipod-detect              Basic detection
                \\  ipod-detect -v           Detailed info for development
                \\  ipod-detect -w           Watch for iPod connection
                \\  ipod-detect -v -w        Verbose watch mode
                \\
            , .{});
            return;
        }
    }

    if (watch) {
        watchMode(allocator, verbose);
    } else {
        const result = detectIpod(allocator);
        if (verbose) {
            printVerboseResults(&result);
        } else {
            printResults(&result);
        }
    }
}

// ============================================================
// Tests
// ============================================================

test "ipod product id detection" {
    try std.testing.expect(isIpodProductId(0x1209)); // Disk Mode
    try std.testing.expect(isIpodProductId(0x1261)); // Classic 6G
    try std.testing.expect(!isIpodProductId(0x12a8)); // iPhone
    try std.testing.expect(!isIpodProductId(0x0000));
}

test "ipod info initialization" {
    const info = IpodInfo{};
    try std.testing.expectEqual(@as(usize, 0), info.product_name_len);
    try std.testing.expectEqual(@as(u16, 0), info.product_id);
    try std.testing.expect(!info.in_disk_mode);
}

test "detection result initialization" {
    const result = DetectionResult{};
    try std.testing.expect(!result.found);
    try std.testing.expectEqual(@as(usize, 0), result.error_len);
}
