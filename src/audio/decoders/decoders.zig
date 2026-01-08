//! Audio Decoders
//!
//! This module exports all supported audio decoders.

pub const wav = @import("wav.zig");
pub const flac = @import("flac.zig");

/// Audio decoder type for runtime codec selection
pub const DecoderType = enum {
    wav,
    flac,
    unknown,
};

/// Detect audio format from file data
pub fn detectFormat(data: []const u8) DecoderType {
    if (wav.isWavFile(data)) return .wav;
    if (flac.isFlacFile(data)) return .flac;
    return .unknown;
}

/// Get file extension for decoder type
pub fn getExtension(decoder_type: DecoderType) []const u8 {
    return switch (decoder_type) {
        .wav => ".wav",
        .flac => ".flac",
        .unknown => "",
    };
}

/// Check if file extension is supported
pub fn isSupportedExtension(ext: []const u8) bool {
    const lower = blk: {
        var buf: [8]u8 = undefined;
        const len = @min(ext.len, buf.len);
        for (ext[0..len], 0..) |c, i| {
            buf[i] = if (c >= 'A' and c <= 'Z') c + 32 else c;
        }
        break :blk buf[0..len];
    };

    return std.mem.eql(u8, lower, ".wav") or
        std.mem.eql(u8, lower, ".flac") or
        std.mem.eql(u8, lower, ".fla");
}

const std = @import("std");

test "detect format - wav" {
    const wav_data = [_]u8{ 'R', 'I', 'F', 'F', 0, 0, 0, 0, 'W', 'A', 'V', 'E' };
    try std.testing.expectEqual(DecoderType.wav, detectFormat(&wav_data));
}

test "detect format - flac" {
    const flac_data = [_]u8{ 'f', 'L', 'a', 'C', 0, 0, 0, 0 };
    try std.testing.expectEqual(DecoderType.flac, detectFormat(&flac_data));
}

test "detect format - unknown" {
    const unknown_data = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 };
    try std.testing.expectEqual(DecoderType.unknown, detectFormat(&unknown_data));
}

test "supported extensions" {
    try std.testing.expect(isSupportedExtension(".wav"));
    try std.testing.expect(isSupportedExtension(".WAV"));
    try std.testing.expect(isSupportedExtension(".flac"));
    try std.testing.expect(!isSupportedExtension(".mp3"));
}
