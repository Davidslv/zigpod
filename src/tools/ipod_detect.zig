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

    /// Disk device path (if in Disk Mode)
    disk_path: [64]u8 = [_]u8{0} ** 64,
    disk_path_len: usize = 0,

    /// Disk size in bytes
    disk_size: u64 = 0,

    /// Is device in Disk Mode
    in_disk_mode: bool = false,

    /// USB location ID
    location_id: [32]u8 = [_]u8{0} ** 32,
    location_id_len: usize = 0,

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

/// Find disk device for iPod in Disk Mode
fn findDiskDevice(allocator: std.mem.Allocator, info: *IpodInfo) !void {
    // Run diskutil list to find external disks
    const output = runCommand(allocator, &.{ "diskutil", "list", "external" }) catch return;
    defer allocator.free(output);

    // Look for iPod-like devices (usually shows as "Apple iPod" or just appears as external)
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        // Look for disk identifier like /dev/disk2
        if (std.mem.indexOf(u8, line, "/dev/disk")) |start| {
            // Extract disk path
            var end = start + 9; // "/dev/disk"
            while (end < line.len and (line[end] >= '0' and line[end] <= '9')) {
                end += 1;
            }

            const disk_path = line[start..end];
            const len = @min(disk_path.len, info.disk_path.len);
            @memcpy(info.disk_path[0..len], disk_path[0..len]);
            info.disk_path_len = len;
            info.in_disk_mode = true;

            // Get disk size
            const disk_info = runCommand(allocator, &.{ "diskutil", "info", disk_path }) catch continue;
            defer allocator.free(disk_info);

            // Parse size from "Disk Size:" line
            var info_lines = std.mem.splitScalar(u8, disk_info, '\n');
            while (info_lines.next()) |info_line| {
                if (std.mem.indexOf(u8, info_line, "Disk Size:")) |_| {
                    // Extract byte count in parentheses
                    if (std.mem.indexOf(u8, info_line, "(")) |paren_start| {
                        if (std.mem.indexOf(u8, info_line, " Bytes")) |bytes_end| {
                            if (bytes_end > paren_start) {
                                const size_str = info_line[paren_start + 1 .. bytes_end];
                                // Remove commas
                                var clean_size: [32]u8 = undefined;
                                var clean_len: usize = 0;
                                for (size_str) |c| {
                                    if (c >= '0' and c <= '9') {
                                        clean_size[clean_len] = c;
                                        clean_len += 1;
                                    }
                                }
                                info.disk_size = std.fmt.parseInt(u64, clean_size[0..clean_len], 10) catch 0;
                            }
                        }
                    }
                }

                // Also check for "iPod" in device info to confirm
                if (std.mem.indexOf(u8, info_line, "iPod") != null) {
                    info.in_disk_mode = true;
                }
            }

            break;
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

    // If not found via ioreg, check for disk mode directly
    if (!result.found) {
        // Check diskutil for iPod
        const disk_output = runCommand(allocator, &.{ "diskutil", "list" }) catch return result;
        defer allocator.free(disk_output);

        if (std.mem.indexOf(u8, disk_output, "iPod") != null or
            std.mem.indexOf(u8, disk_output, "IPOD") != null)
        {
            result.found = true;
            const name = "iPod (Disk Mode)";
            @memcpy(result.ipod.product_name[0..name.len], name);
            result.ipod.product_name_len = name.len;
            result.ipod.in_disk_mode = true;

            findDiskDevice(allocator, &result.ipod) catch {};
        }
    }

    return result;
}

/// Print detection results
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

/// Watch mode - continuously check for iPod
fn watchMode(allocator: std.mem.Allocator) void {
    print("\nWatching for iPod... (press Ctrl+C to stop)\n\n", .{});

    var last_found = false;
    while (true) {
        const result = detectIpod(allocator);

        if (result.found != last_found) {
            if (result.found) {
                print("iPod connected!\n", .{});
                printResults(&result);
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

    // Check for watch mode
    var watch = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--watch") or std.mem.eql(u8, arg, "-w")) {
            watch = true;
        }
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            print(
                \\ZigPod iPod Detection Tool
                \\
                \\Usage: ipod-detect [OPTIONS]
                \\
                \\Options:
                \\  -w, --watch    Continuously watch for iPod connection
                \\  -h, --help     Show this help message
                \\
                \\This tool detects iPod devices connected via USB and shows
                \\their information. When an iPod is in Disk Mode, it will
                \\show the disk path needed for flashing ZigPod.
                \\
            , .{});
            return;
        }
    }

    if (watch) {
        watchMode(allocator);
    } else {
        const result = detectIpod(allocator);
        printResults(&result);
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
