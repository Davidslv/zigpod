//! Firmware Image Builder
//!
//! Creates flashable firmware images for ZigPod OS installation.
//! Generates properly formatted images with headers, checksums, and encryption.

const std = @import("std");
const bootloader = @import("../kernel/bootloader.zig");
const crc = @import("../lib/crc.zig");

// ============================================================
// Image Types
// ============================================================

pub const ImageType = enum {
    raw, // Raw binary (no header)
    zigpod, // ZigPod firmware with header
    dfu, // USB DFU format
    rockbox, // Rockbox-compatible format
};

pub const CompressionType = enum(u8) {
    none = 0,
    lz4 = 1,
    zstd = 2,
};

// ============================================================
// Image Header
// ============================================================

pub const ImageHeader = extern struct {
    /// Magic identifier "ZPFW"
    magic: [4]u8 = .{ 'Z', 'P', 'F', 'W' },
    /// Header version
    header_version: u16 = 1,
    /// Header size (for future expansion)
    header_size: u16 = @sizeOf(ImageHeader),
    /// Firmware version
    version_major: u8 = 0,
    version_minor: u8 = 1,
    version_patch: u8 = 0,
    /// Build flags
    flags: Flags = .{},
    /// Image size (excluding header)
    image_size: u32 = 0,
    /// Uncompressed size (if compressed)
    uncompressed_size: u32 = 0,
    /// Load address in memory
    load_address: u32 = 0x40100000,
    /// Entry point address
    entry_point: u32 = 0x40100000,
    /// CRC32 of image data
    crc32: u32 = 0,
    /// Build timestamp (Unix)
    build_time: u32 = 0,
    /// Target device ID
    device_id: u16 = 0x5021, // PP5021
    /// Compression type
    compression: CompressionType = .none,
    /// Reserved for alignment
    _reserved: [5]u8 = [_]u8{0} ** 5,
    /// Firmware name
    name: [32]u8 = [_]u8{0} ** 32,
    /// SHA256 hash of image (optional)
    sha256: [32]u8 = [_]u8{0} ** 32,

    pub const Flags = packed struct {
        bootloader: bool = false,
        encrypted: bool = false,
        signed: bool = false,
        debug_build: bool = false,
        _reserved: u4 = 0,
    };

    /// Validate header
    pub fn isValid(self: *const ImageHeader) bool {
        return std.mem.eql(u8, &self.magic, "ZPFW") and
            self.header_version >= 1 and
            self.image_size > 0;
    }

    /// Get version string
    pub fn getVersion(self: *const ImageHeader, buffer: []u8) []u8 {
        return std.fmt.bufPrint(buffer, "{d}.{d}.{d}", .{
            self.version_major,
            self.version_minor,
            self.version_patch,
        }) catch buffer[0..0];
    }

    /// Set firmware name
    pub fn setName(self: *ImageHeader, name_str: []const u8) void {
        const len = @min(name_str.len, self.name.len);
        @memcpy(self.name[0..len], name_str[0..len]);
    }
};

// ============================================================
// Image Builder
// ============================================================

pub const ImageBuilder = struct {
    allocator: std.mem.Allocator,
    header: ImageHeader,
    data: std.ArrayList(u8),

    /// Initialize builder
    pub fn init(allocator: std.mem.Allocator) ImageBuilder {
        return ImageBuilder{
            .allocator = allocator,
            .header = ImageHeader{},
            .data = std.ArrayList(u8).init(allocator),
        };
    }

    /// Cleanup
    pub fn deinit(self: *ImageBuilder) void {
        self.data.deinit();
    }

    /// Set version
    pub fn setVersion(self: *ImageBuilder, major: u8, minor: u8, patch: u8) void {
        self.header.version_major = major;
        self.header.version_minor = minor;
        self.header.version_patch = patch;
    }

    /// Set name
    pub fn setName(self: *ImageBuilder, name: []const u8) void {
        self.header.setName(name);
    }

    /// Set load address
    pub fn setLoadAddress(self: *ImageBuilder, addr: u32) void {
        self.header.load_address = addr;
    }

    /// Set entry point
    pub fn setEntryPoint(self: *ImageBuilder, addr: u32) void {
        self.header.entry_point = addr;
    }

    /// Set as bootloader image
    pub fn setBootloader(self: *ImageBuilder, is_bootloader: bool) void {
        self.header.flags.bootloader = is_bootloader;
    }

    /// Set debug build flag
    pub fn setDebugBuild(self: *ImageBuilder, is_debug: bool) void {
        self.header.flags.debug_build = is_debug;
    }

    /// Load firmware binary data
    pub fn loadBinary(self: *ImageBuilder, data: []const u8) !void {
        try self.data.appendSlice(data);
        self.header.image_size = @intCast(data.len);
        self.header.uncompressed_size = @intCast(data.len);
    }

    /// Load firmware from file
    pub fn loadFromFile(self: *ImageBuilder, path: []const u8) !void {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const stat = try file.stat();
        const size = stat.size;

        try self.data.ensureTotalCapacity(@intCast(size));
        const buf = try self.data.addManyAsSlice(@intCast(size));
        _ = try file.readAll(buf);

        self.header.image_size = @intCast(size);
        self.header.uncompressed_size = @intCast(size);
    }

    /// Calculate and set CRC32
    pub fn calculateChecksum(self: *ImageBuilder) void {
        self.header.crc32 = crc.crc32(self.data.items);
    }

    /// Calculate and set SHA256
    pub fn calculateHash(self: *ImageBuilder) void {
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(self.data.items, &hash, .{});
        @memcpy(&self.header.sha256, &hash);
    }

    /// Set build timestamp
    pub fn setBuildTime(self: *ImageBuilder, timestamp: u32) void {
        self.header.build_time = timestamp;
    }

    /// Set current time as build timestamp
    pub fn setBuildTimeNow(self: *ImageBuilder) void {
        const now = std.time.timestamp();
        self.header.build_time = @intCast(@max(0, now));
    }

    /// Build complete firmware image
    pub fn build(self: *ImageBuilder) ![]u8 {
        // Calculate checksums
        self.calculateChecksum();
        self.calculateHash();

        // Create output buffer
        const total_size = @sizeOf(ImageHeader) + self.data.items.len;
        var output = try self.allocator.alloc(u8, total_size);

        // Copy header
        const header_bytes = std.mem.asBytes(&self.header);
        @memcpy(output[0..@sizeOf(ImageHeader)], header_bytes);

        // Copy data
        @memcpy(output[@sizeOf(ImageHeader)..], self.data.items);

        return output;
    }

    /// Write image to file
    pub fn writeToFile(self: *ImageBuilder, path: []const u8) !void {
        const image = try self.build();
        defer self.allocator.free(image);

        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();

        try file.writeAll(image);
    }

    /// Get image statistics
    pub fn getStats(self: *const ImageBuilder) ImageStats {
        return ImageStats{
            .header_size = @sizeOf(ImageHeader),
            .data_size = self.data.items.len,
            .total_size = @sizeOf(ImageHeader) + self.data.items.len,
            .version_major = self.header.version_major,
            .version_minor = self.header.version_minor,
            .version_patch = self.header.version_patch,
            .is_bootloader = self.header.flags.bootloader,
            .is_debug = self.header.flags.debug_build,
        };
    }
};

pub const ImageStats = struct {
    header_size: usize,
    data_size: usize,
    total_size: usize,
    version_major: u8,
    version_minor: u8,
    version_patch: u8,
    is_bootloader: bool,
    is_debug: bool,

    pub fn format(self: *const ImageStats, buffer: []u8) []u8 {
        return std.fmt.bufPrint(buffer,
            \\Image Statistics:
            \\  Header Size: {d} bytes
            \\  Data Size: {d} bytes
            \\  Total Size: {d} bytes
            \\  Version: {d}.{d}.{d}
            \\  Bootloader: {s}
            \\  Debug: {s}
        , .{
            self.header_size,
            self.data_size,
            self.total_size,
            self.version_major,
            self.version_minor,
            self.version_patch,
            if (self.is_bootloader) "Yes" else "No",
            if (self.is_debug) "Yes" else "No",
        }) catch buffer[0..0];
    }
};

// ============================================================
// Image Reader
// ============================================================

pub const ImageReader = struct {
    header: ImageHeader,
    data: []const u8,

    pub const Error = error{
        InvalidHeader,
        InvalidChecksum,
        CorruptedImage,
    };

    /// Parse image from data
    pub fn parse(data: []const u8) Error!ImageReader {
        if (data.len < @sizeOf(ImageHeader)) return Error.InvalidHeader;

        const header: *const ImageHeader = @ptrCast(@alignCast(data.ptr));
        if (!header.isValid()) return Error.InvalidHeader;

        const image_data = data[@sizeOf(ImageHeader)..];
        if (image_data.len < header.image_size) return Error.CorruptedImage;

        // Verify CRC
        const actual_crc = crc.crc32(image_data[0..header.image_size]);
        if (actual_crc != header.crc32) return Error.InvalidChecksum;

        return ImageReader{
            .header = header.*,
            .data = image_data[0..header.image_size],
        };
    }

    /// Get firmware data
    pub fn getData(self: *const ImageReader) []const u8 {
        return self.data;
    }

    /// Verify image integrity
    pub fn verify(self: *const ImageReader) bool {
        // Verify CRC
        const actual_crc = crc.crc32(self.data);
        if (actual_crc != self.header.crc32) return false;

        // Verify SHA256 if present
        var zero_hash: [32]u8 = [_]u8{0} ** 32;
        if (!std.mem.eql(u8, &self.header.sha256, &zero_hash)) {
            var actual_hash: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(self.data, &actual_hash, .{});
            if (!std.mem.eql(u8, &self.header.sha256, &actual_hash)) return false;
        }

        return true;
    }
};

// ============================================================
// DFU Image Format
// ============================================================

pub const DfuSuffix = extern struct {
    bcd_device: u16,
    id_product: u16,
    id_vendor: u16,
    bcd_dfu: u16,
    signature: [3]u8, // "UFD"
    suffix_length: u8,
    crc32: u32,
};

/// Create DFU-formatted image
pub fn createDfuImage(allocator: std.mem.Allocator, firmware: []const u8, vendor_id: u16, product_id: u16) ![]u8 {
    const suffix_size = @sizeOf(DfuSuffix);
    const total_size = firmware.len + suffix_size;

    var output = try allocator.alloc(u8, total_size);

    // Copy firmware
    @memcpy(output[0..firmware.len], firmware);

    // Create suffix
    var suffix = DfuSuffix{
        .bcd_device = 0x0100,
        .id_product = product_id,
        .id_vendor = vendor_id,
        .bcd_dfu = 0x0100,
        .signature = .{ 'U', 'F', 'D' },
        .suffix_length = suffix_size,
        .crc32 = 0,
    };

    // Copy suffix without CRC
    const suffix_bytes = std.mem.asBytes(&suffix);
    @memcpy(output[firmware.len..][0 .. suffix_size - 4], suffix_bytes[0 .. suffix_size - 4]);

    // Calculate CRC over entire image (firmware + partial suffix)
    suffix.crc32 = crc.crc32(output[0 .. total_size - 4]);

    // Write final CRC
    std.mem.writeInt(u32, output[total_size - 4 ..][0..4], suffix.crc32, .little);

    return output;
}

// ============================================================
// Tests
// ============================================================

test "image header validation" {
    var header = ImageHeader{};
    header.image_size = 1024;
    try std.testing.expect(header.isValid());

    // Invalid magic
    header.magic = .{ 'X', 'X', 'X', 'X' };
    try std.testing.expect(!header.isValid());
}

test "image header version" {
    var header = ImageHeader{
        .version_major = 1,
        .version_minor = 2,
        .version_patch = 3,
    };

    var buf: [16]u8 = undefined;
    const version = header.getVersion(&buf);
    try std.testing.expectEqualStrings("1.2.3", version);
}

test "image builder basic" {
    const allocator = std.testing.allocator;

    var builder = ImageBuilder.init(allocator);
    defer builder.deinit();

    builder.setVersion(1, 0, 0);
    builder.setName("ZigPod OS");

    const test_data = [_]u8{ 0x00, 0x01, 0x02, 0x03 };
    try builder.loadBinary(&test_data);

    const stats = builder.getStats();
    try std.testing.expectEqual(@as(usize, 4), stats.data_size);
}

test "image header size" {
    // Ensure header is a reasonable size for alignment
    try std.testing.expect(@sizeOf(ImageHeader) <= 128);
    try std.testing.expect(@sizeOf(ImageHeader) % 4 == 0);
}

test "image reader roundtrip" {
    const allocator = std.testing.allocator;

    // Build image
    var builder = ImageBuilder.init(allocator);
    defer builder.deinit();

    builder.setVersion(1, 2, 3);
    const test_data = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };
    try builder.loadBinary(&test_data);

    const image = try builder.build();
    defer allocator.free(image);

    // Read back
    const reader = try ImageReader.parse(image);
    try std.testing.expectEqual(@as(u8, 1), reader.header.version_major);
    try std.testing.expectEqual(@as(u8, 2), reader.header.version_minor);
    try std.testing.expectEqual(@as(u8, 3), reader.header.version_patch);
    try std.testing.expect(reader.verify());
}
