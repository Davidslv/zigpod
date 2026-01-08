//! CRC (Cyclic Redundancy Check) Calculations
//!
//! Provides various CRC algorithms commonly used in storage and communication protocols.
//! Includes CRC-32 (used in FAT32, ZIP, PNG) and CRC-16 (used in some protocols).

const std = @import("std");

// ============================================================
// CRC-32 (ISO 3309, used in Ethernet, ZIP, PNG, FAT32)
// ============================================================

/// CRC-32 polynomial (reversed/reflected)
pub const CRC32_POLYNOMIAL: u32 = 0xEDB88320;

/// CRC-32 lookup table (generated at compile time)
const crc32_table: [256]u32 = blk: {
    @setEvalBranchQuota(10000);
    var table: [256]u32 = undefined;
    for (0..256) |i| {
        var crc: u32 = @intCast(i);
        for (0..8) |_| {
            if ((crc & 1) != 0) {
                crc = (crc >> 1) ^ CRC32_POLYNOMIAL;
            } else {
                crc = crc >> 1;
            }
        }
        table[i] = crc;
    }
    break :blk table;
};

/// Calculate CRC-32 checksum
pub fn crc32(data: []const u8) u32 {
    return crc32Update(0xFFFFFFFF, data) ^ 0xFFFFFFFF;
}

/// Update running CRC-32 with more data
pub fn crc32Update(crc: u32, data: []const u8) u32 {
    var result = crc;
    for (data) |byte| {
        const index = (result ^ byte) & 0xFF;
        result = (result >> 8) ^ crc32_table[index];
    }
    return result;
}

/// Streaming CRC-32 calculator
pub const Crc32 = struct {
    crc: u32 = 0xFFFFFFFF,

    pub fn update(self: *Crc32, data: []const u8) void {
        self.crc = crc32Update(self.crc, data);
    }

    pub fn updateByte(self: *Crc32, byte: u8) void {
        const index = (self.crc ^ byte) & 0xFF;
        self.crc = (self.crc >> 8) ^ crc32_table[index];
    }

    pub fn final(self: Crc32) u32 {
        return self.crc ^ 0xFFFFFFFF;
    }

    pub fn reset(self: *Crc32) void {
        self.crc = 0xFFFFFFFF;
    }
};

// ============================================================
// CRC-16-CCITT (X.25, HDLC, Bluetooth)
// ============================================================

/// CRC-16-CCITT polynomial (reversed)
pub const CRC16_CCITT_POLYNOMIAL: u16 = 0x8408;

/// CRC-16-CCITT lookup table
const crc16_ccitt_table: [256]u16 = blk: {
    @setEvalBranchQuota(10000);
    var table: [256]u16 = undefined;
    for (0..256) |i| {
        var crc: u16 = @intCast(i);
        for (0..8) |_| {
            if ((crc & 1) != 0) {
                crc = (crc >> 1) ^ CRC16_CCITT_POLYNOMIAL;
            } else {
                crc = crc >> 1;
            }
        }
        table[i] = crc;
    }
    break :blk table;
};

/// Calculate CRC-16-CCITT checksum
pub fn crc16_ccitt(data: []const u8) u16 {
    return crc16_ccittUpdate(0xFFFF, data) ^ 0xFFFF;
}

/// Update running CRC-16-CCITT with more data
pub fn crc16_ccittUpdate(crc: u16, data: []const u8) u16 {
    var result = crc;
    for (data) |byte| {
        const index = (result ^ byte) & 0xFF;
        result = (result >> 8) ^ crc16_ccitt_table[index];
    }
    return result;
}

/// Streaming CRC-16-CCITT calculator
pub const Crc16Ccitt = struct {
    crc: u16 = 0xFFFF,

    pub fn update(self: *Crc16Ccitt, data: []const u8) void {
        self.crc = crc16_ccittUpdate(self.crc, data);
    }

    pub fn updateByte(self: *Crc16Ccitt, byte: u8) void {
        const index = (self.crc ^ byte) & 0xFF;
        self.crc = (self.crc >> 8) ^ crc16_ccitt_table[index];
    }

    pub fn final(self: Crc16Ccitt) u16 {
        return self.crc ^ 0xFFFF;
    }

    pub fn reset(self: *Crc16Ccitt) void {
        self.crc = 0xFFFF;
    }
};

// ============================================================
// CRC-16-MODBUS
// ============================================================

/// CRC-16-MODBUS polynomial (reversed)
pub const CRC16_MODBUS_POLYNOMIAL: u16 = 0xA001;

/// CRC-16-MODBUS lookup table
const crc16_modbus_table: [256]u16 = blk: {
    @setEvalBranchQuota(10000);
    var table: [256]u16 = undefined;
    for (0..256) |i| {
        var crc: u16 = @intCast(i);
        for (0..8) |_| {
            if ((crc & 1) != 0) {
                crc = (crc >> 1) ^ CRC16_MODBUS_POLYNOMIAL;
            } else {
                crc = crc >> 1;
            }
        }
        table[i] = crc;
    }
    break :blk table;
};

/// Calculate CRC-16-MODBUS checksum
pub fn crc16_modbus(data: []const u8) u16 {
    var crc: u16 = 0xFFFF;
    for (data) |byte| {
        const index = (crc ^ byte) & 0xFF;
        crc = (crc >> 8) ^ crc16_modbus_table[index];
    }
    return crc;
}

// ============================================================
// CRC-8 (Dallas/Maxim 1-Wire)
// ============================================================

/// CRC-8 polynomial
pub const CRC8_POLYNOMIAL: u8 = 0x31;

/// CRC-8 lookup table
const crc8_table: [256]u8 = blk: {
    @setEvalBranchQuota(10000);
    var table: [256]u8 = undefined;
    for (0..256) |i| {
        var crc: u8 = @intCast(i);
        for (0..8) |_| {
            if ((crc & 0x80) != 0) {
                crc = (crc << 1) ^ CRC8_POLYNOMIAL;
            } else {
                crc = crc << 1;
            }
        }
        table[i] = crc;
    }
    break :blk table;
};

/// Calculate CRC-8 checksum
pub fn crc8(data: []const u8) u8 {
    var crc: u8 = 0x00;
    for (data) |byte| {
        crc = crc8_table[crc ^ byte];
    }
    return crc;
}

// ============================================================
// Simple Checksums
// ============================================================

/// Calculate simple additive checksum (8-bit)
pub fn checksum8(data: []const u8) u8 {
    var sum: u8 = 0;
    for (data) |byte| {
        sum +%= byte;
    }
    return sum;
}

/// Calculate 16-bit checksum (sum of 16-bit words, big-endian)
pub fn checksum16(data: []const u8) u16 {
    var sum: u32 = 0;
    var i: usize = 0;

    while (i + 1 < data.len) : (i += 2) {
        const word = (@as(u16, data[i]) << 8) | data[i + 1];
        sum += word;
    }

    // Handle odd byte
    if (i < data.len) {
        sum += @as(u16, data[i]) << 8;
    }

    // Fold 32-bit sum to 16 bits
    while (sum > 0xFFFF) {
        sum = (sum & 0xFFFF) + (sum >> 16);
    }

    return @intCast(sum);
}

/// Calculate Internet checksum (RFC 1071) - used in IP, TCP, UDP
pub fn internetChecksum(data: []const u8) u16 {
    return ~checksum16(data);
}

// ============================================================
// Utility Functions
// ============================================================

/// Verify CRC-32 of data matches expected value
pub fn verifyCrc32(data: []const u8, expected: u32) bool {
    return crc32(data) == expected;
}

/// Append CRC-32 to data buffer (returns slice of 4 bytes)
pub fn appendCrc32(data: []const u8, buffer: *[4]u8) void {
    const checksum = crc32(data);
    buffer[0] = @truncate(checksum);
    buffer[1] = @truncate(checksum >> 8);
    buffer[2] = @truncate(checksum >> 16);
    buffer[3] = @truncate(checksum >> 24);
}

/// Extract CRC-32 from 4 bytes (little-endian)
pub fn extractCrc32(bytes: *const [4]u8) u32 {
    return @as(u32, bytes[0]) |
        (@as(u32, bytes[1]) << 8) |
        (@as(u32, bytes[2]) << 16) |
        (@as(u32, bytes[3]) << 24);
}

// ============================================================
// Tests
// ============================================================

test "CRC-32 known values" {
    // Test vector: "123456789"
    const data = "123456789";
    const expected: u32 = 0xCBF43926;
    try std.testing.expectEqual(expected, crc32(data));
}

test "CRC-32 empty" {
    try std.testing.expectEqual(@as(u32, 0x00000000), crc32(""));
}

test "CRC-32 streaming" {
    const data = "Hello, World!";
    const expected = crc32(data);

    var calc = Crc32{};
    calc.update("Hello");
    calc.update(", ");
    calc.update("World!");

    try std.testing.expectEqual(expected, calc.final());
}

test "CRC-32 streaming byte-by-byte" {
    const data = "Test";
    const expected = crc32(data);

    var calc = Crc32{};
    for (data) |byte| {
        calc.updateByte(byte);
    }

    try std.testing.expectEqual(expected, calc.final());
}

test "CRC-16-CCITT known values" {
    // Test vector: "123456789"
    const data = "123456789";
    const expected: u16 = 0x906E;
    try std.testing.expectEqual(expected, crc16_ccitt(data));
}

test "CRC-16-MODBUS known values" {
    // Test vector: "123456789"
    const data = "123456789";
    const expected: u16 = 0x4B37;
    try std.testing.expectEqual(expected, crc16_modbus(data));
}

test "CRC-8 known values" {
    const data = [_]u8{ 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39 }; // "123456789"
    // CRC-8 with polynomial 0x31 (MSB-first)
    const expected: u8 = 0xA2;
    try std.testing.expectEqual(expected, crc8(&data));
}

test "checksum8" {
    const data = [_]u8{ 0x01, 0x02, 0x03, 0x04 };
    try std.testing.expectEqual(@as(u8, 0x0A), checksum8(&data));
}

test "checksum16" {
    const data = [_]u8{ 0x01, 0x02, 0x03, 0x04 };
    // (0x0102 + 0x0304) = 0x0406
    try std.testing.expectEqual(@as(u16, 0x0406), checksum16(&data));
}

test "internet checksum" {
    // Example from RFC 1071
    const data = [_]u8{ 0x00, 0x01, 0xf2, 0x03, 0xf4, 0xf5, 0xf6, 0xf7 };
    // Sum = 0x01 + 0xf203 + 0xf4f5 + 0xf6f7 = 0x2ddf0
    // Folded = 0xddf0 + 0x2 = 0xddf2
    // Checksum = ~0xddf2 = 0x220d
    try std.testing.expectEqual(@as(u16, 0x220D), internetChecksum(&data));
}

test "verify and extract CRC" {
    const data = "Test data";
    const checksum = crc32(data);

    try std.testing.expect(verifyCrc32(data, checksum));
    try std.testing.expect(!verifyCrc32(data, checksum + 1));

    var buffer: [4]u8 = undefined;
    appendCrc32(data, &buffer);
    try std.testing.expectEqual(checksum, extractCrc32(&buffer));
}
