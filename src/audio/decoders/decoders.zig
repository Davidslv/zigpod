//! Audio Decoders
//!
//! This module exports all supported audio decoders.

pub const wav = @import("wav.zig");
pub const flac = @import("flac.zig");
pub const mp3 = @import("mp3.zig");
pub const aiff = @import("aiff.zig");
pub const aac = @import("aac.zig");

/// Audio decoder type for runtime codec selection
pub const DecoderType = enum {
    wav,
    flac,
    mp3,
    aiff,
    aac,
    m4a,
    unknown,
};

/// Detect audio format from file data
pub fn detectFormat(data: []const u8) DecoderType {
    if (wav.isWavFile(data)) return .wav;
    if (flac.isFlacFile(data)) return .flac;
    if (aiff.isAiffFile(data)) return .aiff;
    if (mp3.isMp3File(data)) return .mp3;
    if (aac.isAacFile(data)) {
        // Check if it's M4A container or raw ADTS
        if (data.len >= 8 and std.mem.eql(u8, data[4..8], "ftyp")) {
            return .m4a;
        }
        return .aac;
    }
    return .unknown;
}

/// Get file extension for decoder type
pub fn getExtension(decoder_type: DecoderType) []const u8 {
    return switch (decoder_type) {
        .wav => ".wav",
        .flac => ".flac",
        .mp3 => ".mp3",
        .aiff => ".aiff",
        .aac => ".aac",
        .m4a => ".m4a",
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
        std.mem.eql(u8, lower, ".fla") or
        std.mem.eql(u8, lower, ".mp3") or
        std.mem.eql(u8, lower, ".aiff") or
        std.mem.eql(u8, lower, ".aif") or
        std.mem.eql(u8, lower, ".aac") or
        std.mem.eql(u8, lower, ".m4a") or
        std.mem.eql(u8, lower, ".mp4");
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

test "detect format - mp3" {
    const mp3_id3 = [_]u8{ 'I', 'D', '3', 0x04, 0x00, 0x00, 0, 0, 0, 0 };
    try std.testing.expectEqual(DecoderType.mp3, detectFormat(&mp3_id3));

    const mp3_sync = [_]u8{ 0xFF, 0xFB, 0x90, 0x00 };
    try std.testing.expectEqual(DecoderType.mp3, detectFormat(&mp3_sync));
}

test "detect format - aiff" {
    const aiff_data = [_]u8{ 'F', 'O', 'R', 'M', 0, 0, 0, 0, 'A', 'I', 'F', 'F' };
    try std.testing.expectEqual(DecoderType.aiff, detectFormat(&aiff_data));

    const aifc_data = [_]u8{ 'F', 'O', 'R', 'M', 0, 0, 0, 0, 'A', 'I', 'F', 'C' };
    try std.testing.expectEqual(DecoderType.aiff, detectFormat(&aifc_data));
}

test "detect format - aac adts" {
    // ADTS sync word 0xFFF
    const adts_data = [_]u8{ 0xFF, 0xF1, 0x50, 0x80, 0x00, 0x1F, 0xFC };
    try std.testing.expectEqual(DecoderType.aac, detectFormat(&adts_data));
}

test "detect format - m4a container" {
    // M4A/MP4 ftyp box
    const m4a_data = [_]u8{ 0x00, 0x00, 0x00, 0x20, 'f', 't', 'y', 'p', 'M', '4', 'A', ' ' };
    try std.testing.expectEqual(DecoderType.m4a, detectFormat(&m4a_data));
}

test "supported extensions" {
    try std.testing.expect(isSupportedExtension(".wav"));
    try std.testing.expect(isSupportedExtension(".WAV"));
    try std.testing.expect(isSupportedExtension(".flac"));
    try std.testing.expect(isSupportedExtension(".mp3"));
    try std.testing.expect(isSupportedExtension(".MP3"));
    try std.testing.expect(isSupportedExtension(".aiff"));
    try std.testing.expect(isSupportedExtension(".aif"));
    try std.testing.expect(isSupportedExtension(".AIFF"));
    try std.testing.expect(isSupportedExtension(".aac"));
    try std.testing.expect(isSupportedExtension(".m4a"));
    try std.testing.expect(isSupportedExtension(".mp4"));
    try std.testing.expect(!isSupportedExtension(".ogg"));
}
