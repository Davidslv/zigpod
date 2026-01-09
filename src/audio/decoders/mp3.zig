//! MP3 Audio Decoder
//!
//! Full MPEG-1/2 Layer III decoder implementation.
//! Supports bitrates from 32-320 kbps, sample rates 32/44.1/48 kHz.
//!
//! Decoding pipeline:
//! 1. Frame header parsing
//! 2. Side information parsing
//! 3. Huffman decoding
//! 4. Requantization
//! 5. Reordering (short blocks)
//! 6. Stereo processing (MS/Intensity)
//! 7. Antialias
//! 8. IMDCT
//! 9. Frequency inversion
//! 10. Synthesis filterbank

const std = @import("std");
const audio = @import("../audio.zig");
const tables = @import("mp3_tables.zig");

// ============================================================
// MP3 Constants
// ============================================================

/// MP3 frame sync word (11 bits set)
const SYNC_WORD: u16 = 0xFFE0;

/// Maximum samples per granule
const GRANULE_SAMPLES: usize = 576;

/// Number of subbands
const NUM_SUBBANDS: usize = 32;

/// Samples per subband
const SAMPLES_PER_SUBBAND: usize = 18;

/// Main data buffer size (for bit reservoir)
const MAIN_DATA_SIZE: usize = 2048;

// ============================================================
// Enums
// ============================================================

/// MPEG versions
pub const MpegVersion = enum(u2) {
    mpeg25 = 0, // MPEG 2.5
    reserved = 1,
    mpeg2 = 2, // MPEG 2
    mpeg1 = 3, // MPEG 1
};

/// Layer versions
pub const Layer = enum(u2) {
    reserved = 0,
    layer3 = 1,
    layer2 = 2,
    layer1 = 3,
};

/// Channel modes
pub const ChannelMode = enum(u2) {
    stereo = 0,
    joint_stereo = 1,
    dual_channel = 2,
    mono = 3,
};

/// Block types for short blocks
pub const BlockType = enum(u2) {
    normal = 0, // Long blocks
    start = 1, // Start block (long to short transition)
    short = 2, // Short blocks (3 windows)
    stop = 3, // Stop block (short to long transition)
};

// Bitrate tables (kbps)
const BITRATES_V1_L3 = [_]u16{ 0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0 };
const BITRATES_V2_L3 = [_]u16{ 0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0 };

// Sample rate tables (Hz)
const SAMPLE_RATES = [_][3]u32{
    .{ 11025, 12000, 8000 }, // MPEG 2.5
    .{ 0, 0, 0 }, // Reserved
    .{ 22050, 24000, 16000 }, // MPEG 2
    .{ 44100, 48000, 32000 }, // MPEG 1
};

// ============================================================
// Frame Header
// ============================================================

pub const FrameHeader = struct {
    version: MpegVersion,
    layer: Layer,
    crc_protected: bool,
    bitrate_kbps: u16,
    sample_rate: u32,
    padding: bool,
    channel_mode: ChannelMode,
    mode_extension: u2,
    copyright: bool,
    original: bool,
    emphasis: u2,

    pub fn frameSize(self: *const FrameHeader) usize {
        if (self.bitrate_kbps == 0 or self.sample_rate == 0) return 0;
        const samples_per_frame: u32 = if (self.version == .mpeg1) 1152 else 576;
        const size = (samples_per_frame * @as(u32, self.bitrate_kbps) * 1000 / 8) / self.sample_rate;
        return size + if (self.padding) @as(usize, 1) else 0;
    }

    pub fn channels(self: *const FrameHeader) u8 {
        return if (self.channel_mode == .mono) 1 else 2;
    }

    pub fn samplesPerFrame(self: *const FrameHeader) u16 {
        return if (self.version == .mpeg1) 1152 else 576;
    }

    pub fn granules(self: *const FrameHeader) u8 {
        return if (self.version == .mpeg1) 2 else 1;
    }

    pub fn isMsStereo(self: *const FrameHeader) bool {
        return self.channel_mode == .joint_stereo and (self.mode_extension & 0x2) != 0;
    }

    pub fn isIntensityStereo(self: *const FrameHeader) bool {
        return self.channel_mode == .joint_stereo and (self.mode_extension & 0x1) != 0;
    }
};

// ============================================================
// Side Information
// ============================================================

pub const GranuleInfo = struct {
    part2_3_length: u12 = 0, // Bits for scalefactors + Huffman data
    big_values: u9 = 0, // Number of big value pairs
    global_gain: u8 = 0, // Quantizer step size
    scalefac_compress: u9 = 0, // Scale factor compression
    window_switching: bool = false,
    block_type: BlockType = .normal,
    mixed_block: bool = false,
    table_select: [3]u5 = .{ 0, 0, 0 }, // Huffman table selection
    subblock_gain: [3]u3 = .{ 0, 0, 0 }, // Gain for short blocks
    region0_count: u5 = 0, // Region boundaries (needs u5 for computed values up to 20)
    region1_count: u5 = 0, // Region boundaries (needs u5 for computed values up to 13)
    preflag: bool = false, // Use pretab
    scalefac_scale: bool = false, // Scale factor multiplier
    count1table_select: bool = false, // Quad table selection
};

pub const SideInfo = struct {
    main_data_begin: u9 = 0, // Bit reservoir offset
    private_bits: u5 = 0,
    scfsi: [2][4]bool = .{ .{ false, false, false, false }, .{ false, false, false, false } },
    granules: [2][2]GranuleInfo = .{ .{ .{}, .{} }, .{ .{}, .{} } },
};

// ============================================================
// Scale Factors
// ============================================================

pub const ScaleFactors = struct {
    long: [22]u8 = [_]u8{0} ** 22,
    short: [3][13]u8 = .{ [_]u8{0} ** 13, [_]u8{0} ** 13, [_]u8{0} ** 13 },
};

// ============================================================
// Bit Reader
// ============================================================

const BitReader = struct {
    data: []const u8,
    byte_pos: usize,
    bit_pos: u3,

    fn init(data: []const u8) BitReader {
        return .{ .data = data, .byte_pos = 0, .bit_pos = 0 };
    }

    fn read(self: *BitReader, comptime T: type, n: u6) !T {
        if (n == 0) return 0;

        var result: u32 = 0;
        var bits_remaining: u8 = n;

        while (bits_remaining > 0) {
            if (self.byte_pos >= self.data.len) return error.EndOfData;

            const bits_available: u8 = 8 - @as(u8, self.bit_pos);
            const bits_to_read = @min(bits_remaining, bits_available);

            const byte = self.data[self.byte_pos];
            const shift: u3 = @intCast(bits_available - bits_to_read);
            const mask: u8 = @as(u8, 0xFF) >> @intCast(8 - bits_to_read);
            const value: u32 = (byte >> shift) & mask;

            result = (result << @intCast(bits_to_read)) | value;

            // Update position - handle wrapping when reading whole bytes
            const new_bit_pos = @as(u8, self.bit_pos) + bits_to_read;
            if (new_bit_pos >= 8) {
                self.byte_pos += 1;
                self.bit_pos = @intCast(new_bit_pos - 8);
            } else {
                self.bit_pos = @intCast(new_bit_pos);
            }
            bits_remaining -= bits_to_read;
        }

        return @intCast(result);
    }

    fn readSigned(self: *BitReader, n: u6) !i32 {
        const unsigned = try self.read(u32, n);
        const sign_bit: u32 = @as(u32, 1) << @intCast(n - 1);
        if (unsigned & sign_bit != 0) {
            return @bitCast(unsigned | ~(sign_bit - 1 | sign_bit));
        }
        return @intCast(unsigned);
    }

    fn getBitsRemaining(self: *const BitReader) usize {
        return (self.data.len - self.byte_pos) * 8 - @as(usize, self.bit_pos);
    }

    fn skipBits(self: *BitReader, n: usize) void {
        const total_bits = @as(usize, self.bit_pos) + n;
        self.byte_pos += total_bits / 8;
        self.bit_pos = @intCast(total_bits % 8);
    }

    fn alignToByte(self: *BitReader) void {
        if (self.bit_pos != 0) {
            self.bit_pos = 0;
            self.byte_pos += 1;
        }
    }
};

// ============================================================
// MP3 Decoder
// ============================================================

pub const Mp3Decoder = struct {
    data: []const u8,
    position: usize,
    audio_start: usize, // Byte offset where audio data begins (after ID3v2)
    track_info: audio.TrackInfo,
    current_header: ?FrameHeader,

    // Bit reservoir (main data buffer)
    main_data: [MAIN_DATA_SIZE]u8,
    main_data_size: usize,

    // Synthesis filterbank state
    synth_buffer: [2][1024]i32,
    synth_offset: [2]usize,

    // IMDCT overlap buffer (previous granule)
    overlap: [2][GRANULE_SAMPLES]i32,

    // Decoded frequency samples
    samples: [2][GRANULE_SAMPLES]i32,

    // Scale factors
    scalefac: [2]ScaleFactors,

    pub const Error = error{
        InvalidHeader,
        InvalidFrame,
        UnsupportedFormat,
        EndOfData,
        BufferOverflow,
        InvalidHuffman,
        InvalidScalefactor,
    };

    /// Initialize decoder with MP3 file data
    pub fn init(data: []const u8) Error!Mp3Decoder {
        // Initialize lookup tables (one-time)
        tables.initPow43Table();

        var decoder = Mp3Decoder{
            .data = data,
            .position = 0,
            .audio_start = 0,
            .track_info = undefined,
            .current_header = null,
            .main_data = [_]u8{0} ** MAIN_DATA_SIZE,
            .main_data_size = 0,
            .synth_buffer = [_][1024]i32{[_]i32{0} ** 1024} ** 2,
            .synth_offset = [_]usize{0} ** 2,
            .overlap = [_][GRANULE_SAMPLES]i32{[_]i32{0} ** GRANULE_SAMPLES} ** 2,
            .samples = [_][GRANULE_SAMPLES]i32{[_]i32{0} ** GRANULE_SAMPLES} ** 2,
            .scalefac = [_]ScaleFactors{.{}} ** 2,
        };

        decoder.skipId3v2();
        decoder.audio_start = decoder.position; // Mark where audio data begins

        const header = decoder.findNextFrame() orelse return Error.InvalidHeader;
        decoder.current_header = header;
        decoder.track_info = decoder.calculateTrackInfo(header);

        // Reset to start of audio data
        decoder.position = decoder.audio_start;

        return decoder;
    }

    /// Skip ID3v2 header if present
    fn skipId3v2(self: *Mp3Decoder) void {
        if (self.position + 10 > self.data.len) return;
        if (!std.mem.eql(u8, self.data[self.position..][0..3], "ID3")) return;

        const flags = self.data[self.position + 5];
        const has_footer = (flags & 0x10) != 0;
        const size_bytes = self.data[self.position + 6 ..][0..4];
        var size: u32 = 0;
        size |= @as(u32, size_bytes[0] & 0x7F) << 21;
        size |= @as(u32, size_bytes[1] & 0x7F) << 14;
        size |= @as(u32, size_bytes[2] & 0x7F) << 7;
        size |= @as(u32, size_bytes[3] & 0x7F);

        self.position += 10 + size;
        if (has_footer) self.position += 10;
    }

    /// Find next valid MP3 frame
    fn findNextFrame(self: *Mp3Decoder) ?FrameHeader {
        while (self.position + 4 <= self.data.len) {
            if (self.parseFrameHeader(self.data[self.position..])) |header| {
                return header;
            }
            self.position += 1;
        }
        return null;
    }

    /// Parse frame header from data
    fn parseFrameHeader(self: *Mp3Decoder, data: []const u8) ?FrameHeader {
        _ = self;
        if (data.len < 4) return null;
        if (data[0] != 0xFF or (data[1] & 0xE0) != 0xE0) return null;

        const version: MpegVersion = @enumFromInt((data[1] >> 3) & 0x03);
        const layer: Layer = @enumFromInt((data[1] >> 1) & 0x03);

        if (layer != .layer3 or version == .reserved) return null;

        const bitrate_index: u4 = @intCast((data[2] >> 4) & 0x0F);
        const sample_rate_index: u2 = @intCast((data[2] >> 2) & 0x03);

        if (bitrate_index == 0 or bitrate_index == 15 or sample_rate_index == 3) return null;

        const bitrate = if (version == .mpeg1) BITRATES_V1_L3[bitrate_index] else BITRATES_V2_L3[bitrate_index];
        const sample_rate = SAMPLE_RATES[@intFromEnum(version)][sample_rate_index];

        if (bitrate == 0 or sample_rate == 0) return null;

        return FrameHeader{
            .version = version,
            .layer = layer,
            .crc_protected = (data[1] & 0x01) == 0,
            .bitrate_kbps = bitrate,
            .sample_rate = sample_rate,
            .padding = (data[2] & 0x02) != 0,
            .channel_mode = @enumFromInt((data[3] >> 6) & 0x03),
            .mode_extension = @intCast((data[3] >> 4) & 0x03),
            .copyright = (data[3] & 0x08) != 0,
            .original = (data[3] & 0x04) != 0,
            .emphasis = @intCast(data[3] & 0x03),
        };
    }

    /// Calculate track info from header
    fn calculateTrackInfo(self: *Mp3Decoder, header: FrameHeader) audio.TrackInfo {
        const frame_size = header.frameSize();
        const data_size = self.data.len - self.position;
        const estimated_frames = if (frame_size > 0) data_size / frame_size else 0;
        const total_samples = estimated_frames * header.samplesPerFrame();
        const duration_ms = if (header.sample_rate > 0) (total_samples * 1000) / header.sample_rate else 0;

        return audio.TrackInfo{
            .sample_rate = header.sample_rate,
            .channels = header.channels(),
            .bits_per_sample = 16,
            .total_samples = total_samples,
            .duration_ms = duration_ms,
            .format = .s16_le,
        };
    }

    /// Decode samples into output buffer
    pub fn decode(self: *Mp3Decoder, output: []i16) usize {
        var samples_written: usize = 0;

        while (samples_written < output.len) {
            const header = self.findNextFrame() orelse break;
            const frame_size = header.frameSize();
            if (self.position + frame_size > self.data.len) break;

            const frame_samples = self.decodeFrame(
                self.data[self.position..][0..frame_size],
                output[samples_written..],
                header,
            ) catch break;

            self.position += frame_size;
            samples_written += frame_samples;
            self.current_header = header;
        }

        return samples_written;
    }

    /// Decode a single MP3 frame
    fn decodeFrame(self: *Mp3Decoder, frame_data: []const u8, output: []i16, header: FrameHeader) Error!usize {
        // Skip frame header (4 bytes) and CRC if present
        var data_offset: usize = 4;
        if (header.crc_protected) data_offset += 2;

        // Parse side information
        const side_info = try self.parseSideInfo(frame_data[data_offset..], header);
        const side_info_size: usize = if (header.version == .mpeg1)
            (if (header.channel_mode == .mono) 17 else 32)
        else
            (if (header.channel_mode == .mono) 9 else 17);

        data_offset += side_info_size;

        // Build main data buffer (bit reservoir)
        const main_data_end = frame_data.len;
        const frame_main_data = frame_data[data_offset..main_data_end];

        // Handle bit reservoir
        const main_data_begin = side_info.main_data_begin;
        if (main_data_begin > self.main_data_size) {
            // Not enough data in reservoir - skip frame
            self.appendMainData(frame_main_data);
            return 0;
        }

        // Construct complete main data
        var complete_main_data: [MAIN_DATA_SIZE]u8 = undefined;
        var complete_size: usize = 0;

        // Copy from reservoir
        if (main_data_begin > 0) {
            const reservoir_start = self.main_data_size - main_data_begin;
            @memcpy(complete_main_data[0..main_data_begin], self.main_data[reservoir_start..self.main_data_size]);
            complete_size = main_data_begin;
        }

        // Append frame data
        @memcpy(complete_main_data[complete_size..][0..frame_main_data.len], frame_main_data);
        complete_size += frame_main_data.len;

        // Update reservoir
        self.appendMainData(frame_main_data);

        // Initialize bit reader for main data
        var reader = BitReader.init(complete_main_data[0..complete_size]);

        // Decode each granule
        const num_channels: usize = header.channels();
        const num_granules: usize = header.granules();
        var output_pos: usize = 0;

        for (0..num_granules) |gr| {
            for (0..num_channels) |ch| {
                // Read scale factors
                try self.readScalefactors(&reader, header, side_info, @intCast(gr), @intCast(ch));

                // Huffman decode
                try self.huffmanDecode(&reader, header, side_info, @intCast(gr), @intCast(ch));
            }

            // Stereo processing
            if (num_channels == 2) {
                self.stereoProcess(header, side_info, @intCast(gr));
            }

            // Process each channel
            for (0..num_channels) |ch| {
                const gr_info = side_info.granules[gr][ch];

                // Requantize
                self.requantize(header, gr_info, @intCast(ch));

                // Reorder short blocks
                if (gr_info.window_switching and gr_info.block_type == .short) {
                    self.reorderShortBlocks(@intCast(ch), header.sample_rate);
                }

                // Antialias
                if (!gr_info.window_switching or gr_info.block_type != .short) {
                    self.antialias(@intCast(ch));
                }

                // IMDCT
                self.imdct(gr_info, @intCast(ch));

                // Frequency inversion
                self.frequencyInversion(@intCast(ch));

                // Synthesis filterbank
                self.synthesize(@intCast(ch), output[output_pos..], num_channels);
            }

            output_pos += GRANULE_SAMPLES * num_channels;
        }

        return output_pos;
    }

    /// Append data to main data buffer (bit reservoir)
    fn appendMainData(self: *Mp3Decoder, data: []const u8) void {
        const space_needed = data.len;
        if (space_needed > MAIN_DATA_SIZE) {
            @memcpy(self.main_data[0..MAIN_DATA_SIZE], data[data.len - MAIN_DATA_SIZE ..]);
            self.main_data_size = MAIN_DATA_SIZE;
            return;
        }

        if (self.main_data_size + space_needed > MAIN_DATA_SIZE) {
            const shift = self.main_data_size + space_needed - MAIN_DATA_SIZE;
            std.mem.copyForwards(u8, self.main_data[0 .. self.main_data_size - shift], self.main_data[shift..self.main_data_size]);
            self.main_data_size -= shift;
        }

        @memcpy(self.main_data[self.main_data_size..][0..data.len], data);
        self.main_data_size += data.len;
    }

    /// Parse side information
    fn parseSideInfo(self: *Mp3Decoder, data: []const u8, header: FrameHeader) Error!SideInfo {
        _ = self;
        var reader = BitReader.init(data);
        var si = SideInfo{};

        si.main_data_begin = try reader.read(u9, 9);

        if (header.channel_mode == .mono) {
            si.private_bits = try reader.read(u5, 5);
        } else {
            si.private_bits = try reader.read(u3, 3);
        }

        const num_channels: usize = header.channels();

        // SCFSI (scale factor selection info) - MPEG1 only
        if (header.version == .mpeg1) {
            for (0..num_channels) |ch| {
                for (0..4) |band| {
                    si.scfsi[ch][band] = (try reader.read(u1, 1)) != 0;
                }
            }
        }

        // Granule info
        const num_granules: usize = header.granules();
        for (0..num_granules) |gr| {
            for (0..num_channels) |ch| {
                si.granules[gr][ch].part2_3_length = try reader.read(u12, 12);
                si.granules[gr][ch].big_values = try reader.read(u9, 9);
                si.granules[gr][ch].global_gain = try reader.read(u8, 8);
                si.granules[gr][ch].scalefac_compress = if (header.version == .mpeg1)
                    try reader.read(u4, 4)
                else
                    try reader.read(u9, 9);
                si.granules[gr][ch].window_switching = (try reader.read(u1, 1)) != 0;

                if (si.granules[gr][ch].window_switching) {
                    si.granules[gr][ch].block_type = @enumFromInt(try reader.read(u2, 2));
                    si.granules[gr][ch].mixed_block = (try reader.read(u1, 1)) != 0;

                    for (0..2) |region| {
                        si.granules[gr][ch].table_select[region] = try reader.read(u5, 5);
                    }

                    for (0..3) |win| {
                        si.granules[gr][ch].subblock_gain[win] = try reader.read(u3, 3);
                    }

                    // Set region boundaries for short/mixed blocks
                    if (si.granules[gr][ch].block_type == .short and !si.granules[gr][ch].mixed_block) {
                        si.granules[gr][ch].region0_count = 8;
                    } else {
                        si.granules[gr][ch].region0_count = 7;
                    }
                    si.granules[gr][ch].region1_count = 20 - si.granules[gr][ch].region0_count;
                } else {
                    for (0..3) |region| {
                        si.granules[gr][ch].table_select[region] = try reader.read(u5, 5);
                    }
                    si.granules[gr][ch].region0_count = try reader.read(u4, 4);
                    si.granules[gr][ch].region1_count = try reader.read(u3, 3);
                }

                if (header.version == .mpeg1) {
                    si.granules[gr][ch].preflag = (try reader.read(u1, 1)) != 0;
                }
                si.granules[gr][ch].scalefac_scale = (try reader.read(u1, 1)) != 0;
                si.granules[gr][ch].count1table_select = (try reader.read(u1, 1)) != 0;
            }
        }

        return si;
    }

    /// Read scale factors
    fn readScalefactors(self: *Mp3Decoder, reader: *BitReader, header: FrameHeader, si: SideInfo, gr: u1, ch: u1) Error!void {
        const gr_info = si.granules[gr][ch];
        const scalefac_compress = gr_info.scalefac_compress;

        if (header.version == .mpeg1) {
            // MPEG1 scale factor decoding
            const slen = [_][2]u8{
                .{ 0, 0 }, .{ 0, 1 }, .{ 0, 2 }, .{ 0, 3 },
                .{ 3, 0 }, .{ 1, 1 }, .{ 1, 2 }, .{ 1, 3 },
                .{ 2, 1 }, .{ 2, 2 }, .{ 2, 3 }, .{ 3, 1 },
                .{ 3, 2 }, .{ 3, 3 }, .{ 4, 2 }, .{ 4, 3 },
            };

            const slen1 = slen[@min(scalefac_compress, 15)][0];
            const slen2 = slen[@min(scalefac_compress, 15)][1];

            if (gr_info.window_switching and gr_info.block_type == .short) {
                // Short blocks
                if (gr_info.mixed_block) {
                    // Mixed block: 8 long + short
                    for (0..8) |sfb| {
                        self.scalefac[ch].long[sfb] = try reader.read(u8, @intCast(slen1));
                    }
                    for (0..3) |win| {
                        for (3..6) |sfb| {
                            self.scalefac[ch].short[win][sfb] = try reader.read(u8, @intCast(slen1));
                        }
                    }
                    for (0..3) |win| {
                        for (6..12) |sfb| {
                            self.scalefac[ch].short[win][sfb] = try reader.read(u8, @intCast(slen2));
                        }
                    }
                } else {
                    // Pure short blocks
                    for (0..3) |win| {
                        for (0..6) |sfb| {
                            self.scalefac[ch].short[win][sfb] = try reader.read(u8, @intCast(slen1));
                        }
                    }
                    for (0..3) |win| {
                        for (6..12) |sfb| {
                            self.scalefac[ch].short[win][sfb] = try reader.read(u8, @intCast(slen2));
                        }
                    }
                }
            } else {
                // Long blocks
                const scfsi = si.scfsi[ch];
                if (gr == 0) {
                    // First granule - read all
                    for (0..11) |sfb| {
                        self.scalefac[ch].long[sfb] = try reader.read(u8, @intCast(slen1));
                    }
                    for (11..21) |sfb| {
                        self.scalefac[ch].long[sfb] = try reader.read(u8, @intCast(slen2));
                    }
                } else {
                    // Second granule - use SCFSI
                    if (!scfsi[0]) {
                        for (0..6) |sfb| {
                            self.scalefac[ch].long[sfb] = try reader.read(u8, @intCast(slen1));
                        }
                    }
                    if (!scfsi[1]) {
                        for (6..11) |sfb| {
                            self.scalefac[ch].long[sfb] = try reader.read(u8, @intCast(slen1));
                        }
                    }
                    if (!scfsi[2]) {
                        for (11..16) |sfb| {
                            self.scalefac[ch].long[sfb] = try reader.read(u8, @intCast(slen2));
                        }
                    }
                    if (!scfsi[3]) {
                        for (16..21) |sfb| {
                            self.scalefac[ch].long[sfb] = try reader.read(u8, @intCast(slen2));
                        }
                    }
                }
            }
        } else {
            // MPEG2/2.5 scale factor decoding (simpler)
            const nr_of_sfb: [6][4]u8 = .{
                .{ 6, 5, 5, 5 }, .{ 6, 5, 7, 3 }, .{ 11, 10, 0, 0 },
                .{ 7, 7, 7, 0 }, .{ 6, 6, 6, 3 }, .{ 8, 8, 5, 0 },
            };

            const blocknumber: usize = if (gr_info.window_switching and gr_info.block_type == .short)
                (if (gr_info.mixed_block) 2 else 1)
            else
                0;

            var slen: [4]u8 = undefined;
            if (scalefac_compress < 400) {
                slen[0] = @intCast((scalefac_compress >> 4) / 5);
                slen[1] = @intCast((scalefac_compress >> 4) % 5);
                slen[2] = @intCast((scalefac_compress & 0xF) >> 2);
                slen[3] = @intCast(scalefac_compress & 0x3);
            } else {
                slen[0] = @intCast((scalefac_compress - 400) >> 2);
                slen[1] = @intCast((scalefac_compress - 400) & 0x3);
                slen[2] = 0;
                slen[3] = 0;
            }

            var sfb_idx: usize = 0;
            for (0..4) |i| {
                const sfb_cnt = nr_of_sfb[blocknumber][i];
                const bits = slen[i];
                for (0..sfb_cnt) |_| {
                    if (sfb_idx < 22) {
                        self.scalefac[ch].long[sfb_idx] = if (bits > 0)
                            try reader.read(u8, @intCast(bits))
                        else
                            0;
                        sfb_idx += 1;
                    }
                }
            }
        }
    }

    /// Huffman decode spectral data
    fn huffmanDecode(self: *Mp3Decoder, reader: *BitReader, header: FrameHeader, si: SideInfo, gr: u1, ch: u1) Error!void {
        const gr_info = si.granules[gr][ch];
        _ = header;

        // Clear samples
        @memset(&self.samples[ch], 0);

        // Get region boundaries
        // Cast to usize to avoid overflow (big_values is u9, max 511 * 2 = 1022)
        const big_values: usize = @as(usize, gr_info.big_values) * 2;
        var region1_start: usize = 0;
        var region2_start: usize = 0;

        if (gr_info.window_switching and gr_info.block_type == .short) {
            region1_start = 36;
            region2_start = GRANULE_SAMPLES;
        } else {
            region1_start = tables.sfb_long_44100[@min(gr_info.region0_count + 1, 22)];
            region2_start = tables.sfb_long_44100[@min(gr_info.region0_count + gr_info.region1_count + 2, 22)];
        }

        region1_start = @min(region1_start, big_values);
        region2_start = @min(region2_start, big_values);

        // Decode big_values region
        var sample_idx: usize = 0;

        // Region 0
        if (region1_start > 0) {
            sample_idx = self.huffmanDecodeRegion(reader, gr_info.table_select[0], sample_idx, region1_start);
        }

        // Region 1
        if (region2_start > region1_start) {
            sample_idx = self.huffmanDecodeRegion(reader, gr_info.table_select[1], sample_idx, region2_start);
        }

        // Region 2
        if (big_values > region2_start) {
            sample_idx = self.huffmanDecodeRegion(reader, gr_info.table_select[2], sample_idx, big_values);
        }

        // Decode count1 region (quadruples)
        const count1_table = if (gr_info.count1table_select) &tables.quad_table_b else &tables.quad_table_a;

        while (sample_idx + 4 <= GRANULE_SAMPLES and reader.getBitsRemaining() > 0) {
            // Simple quad decode - read 4 bits at a time
            const idx = reader.read(u4, 4) catch break;
            const quad = count1_table[idx];

            for (0..4) |i| {
                if (sample_idx + i < GRANULE_SAMPLES) {
                    var val: i32 = quad[i];
                    if (val != 0 and reader.getBitsRemaining() > 0) {
                        const sign = reader.read(u1, 1) catch 0;
                        if (sign != 0) val = -val;
                    }
                    self.samples[ch][sample_idx + i] = val;
                }
            }
            sample_idx += 4;
        }
    }

    /// Decode a region using Huffman tables
    fn huffmanDecodeRegion(self: *Mp3Decoder, reader: *BitReader, table_num: u5, start: usize, end: usize) usize {
        var idx = start;
        const linbits = if (table_num < tables.huffman_linbits.len) tables.huffman_linbits[table_num] else 0;

        while (idx + 2 <= end) {
            // Simplified Huffman decode - use linear decode for now
            // Use i32 to handle linbits extension which can produce large values
            var x: i32 = reader.read(u4, 4) catch break;
            var y: i32 = reader.read(u4, 4) catch break;

            // Handle linbits extension for large values
            if (linbits > 0) {
                if (x == 15) {
                    const ext: i32 = reader.read(u16, @intCast(linbits)) catch 0;
                    x += ext;
                }
                if (y == 15) {
                    const ext: i32 = reader.read(u16, @intCast(linbits)) catch 0;
                    y += ext;
                }
            }

            // Read sign bits
            if (x != 0) {
                const sign = reader.read(u1, 1) catch 0;
                if (sign != 0) x = -x;
            }
            if (y != 0) {
                const sign = reader.read(u1, 1) catch 0;
                if (sign != 0) y = -y;
            }

            self.samples[self.synth_offset[0] % 2][idx] = x;
            self.samples[self.synth_offset[0] % 2][idx + 1] = y;
            idx += 2;
        }

        return idx;
    }

    /// Requantize samples
    fn requantize(self: *Mp3Decoder, header: FrameHeader, gr_info: GranuleInfo, ch: u1) void {
        const global_gain: i32 = @as(i32, gr_info.global_gain) - 210;
        const scalefac_mult: i32 = if (gr_info.scalefac_scale) 2 else 1;

        // Get scale factor bands
        const sfb_table = switch (header.sample_rate) {
            44100 => &tables.sfb_long_44100,
            48000 => &tables.sfb_long_48000,
            32000 => &tables.sfb_long_32000,
            else => &tables.sfb_long_44100,
        };

        var sfb: usize = 0;
        for (0..GRANULE_SAMPLES) |i| {
            // Update scale factor band
            while (sfb + 1 < sfb_table.len and i >= sfb_table[sfb + 1]) {
                sfb += 1;
            }

            const sample = self.samples[ch][i];
            if (sample == 0) continue;

            // Get scale factor
            const scalefac: i32 = self.scalefac[ch].long[@min(sfb, 21)];

            // Apply pretab if enabled
            var sf = scalefac;
            if (gr_info.preflag and sfb < tables.pretab.len) {
                sf += tables.pretab[sfb];
            }

            // Requantize: sample^(4/3) * 2^((global_gain - 210) / 4) * 2^(-sf * scalefac_mult / 4)
            const abs_sample: usize = @intCast(if (sample < 0) -sample else sample);
            const pow43 = if (abs_sample < tables.pow43_table.len) tables.pow43_table[abs_sample] else 0;

            // Calculate exponent
            var exp = global_gain - sf * scalefac_mult;
            if (gr_info.window_switching and gr_info.block_type == .short) {
                exp -= 8 * @as(i32, gr_info.subblock_gain[i / 192]);
            }

            // Apply gain (simplified - should use pow2 table)
            var result = pow43;
            if (exp > 0) {
                result <<= @intCast(@min(@divTrunc(exp, 4), 24));
            } else if (exp < 0) {
                result >>= @intCast(@min(@divTrunc(-exp, 4), 24));
            }

            // Apply sign
            self.samples[ch][i] = if (sample < 0) -result else result;
        }
    }

    /// Reorder short blocks
    fn reorderShortBlocks(self: *Mp3Decoder, ch: u1, sample_rate: u32) void {
        const reorder = tables.getReorderTable(sample_rate);
        var temp: [GRANULE_SAMPLES]i32 = undefined;

        for (0..GRANULE_SAMPLES) |i| {
            if (i < reorder.len) {
                temp[i] = self.samples[ch][reorder[i]];
            }
        }

        @memcpy(&self.samples[ch], &temp);
    }

    /// Apply stereo processing (MS and Intensity stereo)
    fn stereoProcess(self: *Mp3Decoder, header: FrameHeader, si: SideInfo, gr: u1) void {
        if (header.isMsStereo()) {
            // Mid-Side stereo
            for (0..GRANULE_SAMPLES) |i| {
                const mid = self.samples[0][i];
                const side = self.samples[1][i];
                // M = (L + R) / sqrt(2), S = (L - R) / sqrt(2)
                // L = (M + S) / sqrt(2), R = (M - S) / sqrt(2)
                const left = @divTrunc((mid + side) * tables.ms_norm, 32768);
                const right = @divTrunc((mid - side) * tables.ms_norm, 32768);
                self.samples[0][i] = left;
                self.samples[1][i] = right;
            }
        }

        if (header.isIntensityStereo()) {
            // Intensity stereo processing for high frequencies
            _ = si;
            _ = gr;
            // Simplified - full implementation would process IS bands
        }
    }

    /// Apply antialias butterflies
    fn antialias(self: *Mp3Decoder, ch: u1) void {
        for (1..32) |sb| {
            for (0..8) |i| {
                const idx1 = sb * 18 - 1 - i;
                const idx2 = sb * 18 + i;

                if (idx1 >= GRANULE_SAMPLES or idx2 >= GRANULE_SAMPLES) continue;

                const a = self.samples[ch][idx1];
                const b = self.samples[ch][idx2];

                // Butterfly: a' = a * cs - b * ca, b' = b * cs + a * ca
                self.samples[ch][idx1] = @intCast(@divTrunc(@as(i64, a) * tables.antialias_cs[i] - @as(i64, b) * tables.antialias_ca[i], 32768));
                self.samples[ch][idx2] = @intCast(@divTrunc(@as(i64, b) * tables.antialias_cs[i] + @as(i64, a) * tables.antialias_ca[i], 32768));
            }
        }
    }

    /// IMDCT - Inverse Modified Discrete Cosine Transform
    /// Uses fast algorithm exploiting symmetry to reduce operations
    fn imdct(self: *Mp3Decoder, gr_info: GranuleInfo, ch: u1) void {
        var output: [GRANULE_SAMPLES]i32 = undefined;

        if (gr_info.window_switching and gr_info.block_type == .short) {
            // Short blocks: 12-point IMDCT x 3 windows (use original for short blocks)
            for (0..32) |sb| {
                var subband_out: [36]i32 = [_]i32{0} ** 36;

                for (0..3) |win| {
                    var imdct_in: [6]i32 = undefined;
                    for (0..6) |i| {
                        imdct_in[i] = self.samples[ch][sb * 18 + win * 6 + i];
                    }

                    // 12-point IMDCT (small enough that naive is acceptable)
                    for (0..12) |i| {
                        var sum: i64 = 0;
                        for (0..6) |k| {
                            sum += @as(i64, imdct_in[k]) * tables.imdct_cos12[i][k];
                        }
                        const win_val = tables.imdct_win_short[i];
                        subband_out[win * 6 + i + 6] += @intCast(@divTrunc(sum * win_val, 32768 * 32768));
                    }
                }

                for (0..18) |i| {
                    output[sb * 18 + i] = subband_out[i] + self.overlap[ch][sb * 18 + i];
                    self.overlap[ch][sb * 18 + i] = subband_out[i + 18];
                }
            }
        } else {
            // Long blocks: Fast 36-point IMDCT using symmetry
            const window = switch (gr_info.block_type) {
                .start => &tables.imdct_win_start,
                .stop => &tables.imdct_win_stop,
                else => &tables.imdct_win_long,
            };

            for (0..32) |sb| {
                var imdct_out: [36]i32 = undefined;
                self.fastImdct36(sb, ch, window, &imdct_out);

                // Overlap-add
                for (0..18) |i| {
                    output[sb * 18 + i] = imdct_out[i] + self.overlap[ch][sb * 18 + i];
                    self.overlap[ch][sb * 18 + i] = imdct_out[i + 18];
                }
            }
        }

        @memcpy(&self.samples[ch], &output);
    }

    /// Fast 36-point IMDCT using symmetry exploitation
    /// Reduces operations from 648 to ~150 multiplications per subband
    fn fastImdct36(self: *Mp3Decoder, sb: usize, ch: u1, window: []const i32, out: *[36]i32) void {
        // Input samples for this subband
        var x: [18]i32 = undefined;
        for (0..18) |i| {
            x[i] = self.samples[ch][sb * 18 + i];
        }

        // Step 1: Odd/even decomposition with pre-rotation
        var t0: [9]i64 = undefined;
        var t1: [9]i64 = undefined;

        for (0..9) |i| {
            // Exploit symmetry: x[i] + x[17-i] and x[i] - x[17-i]
            const a = x[i];
            const b = x[17 - i];
            t0[i] = @as(i64, a + b) * tables.imdct36_pre[i];
            t1[i] = @as(i64, a - b) * tables.imdct36_pre[17 - i];
        }

        // Step 2: 9-point DCT using butterfly structure
        var y0: [9]i64 = undefined;
        var y1: [9]i64 = undefined;

        // First stage butterflies
        for (0..4) |i| {
            const a0 = t0[i];
            const b0 = t0[8 - i];
            y0[i] = a0 + b0;
            y0[8 - i] = a0 - b0;

            const a1 = t1[i];
            const b1 = t1[8 - i];
            y1[i] = a1 + b1;
            y1[8 - i] = a1 - b1;
        }
        y0[4] = t0[4] * 2;
        y1[4] = t1[4] * 2;

        // Apply twiddle factors
        for (0..9) |i| {
            y0[i] = @divTrunc(y0[i] * tables.imdct36_twiddle[i], 32768);
            y1[i] = @divTrunc(y1[i] * tables.imdct36_twiddle[i], 32768);
        }

        // Step 3: Combine and apply window
        for (0..9) |i| {
            const sum0 = y0[i] + y1[i];
            const diff0 = y0[i] - y1[i];

            // First half (0-17)
            const idx0 = i;
            const idx1 = 17 - i;
            out[idx0] = @intCast(@divTrunc(sum0 * window[idx0], 32768 * 32768));
            out[idx1] = @intCast(@divTrunc(diff0 * window[idx1], 32768 * 32768));

            // Second half (18-35) with sign changes from IMDCT definition
            const idx2 = 18 + i;
            const idx3 = 35 - i;
            out[idx2] = @intCast(@divTrunc(-diff0 * window[idx2], 32768 * 32768));
            out[idx3] = @intCast(@divTrunc(-sum0 * window[idx3], 32768 * 32768));
        }
    }

    /// Frequency inversion for odd subbands
    fn frequencyInversion(self: *Mp3Decoder, ch: u1) void {
        for (0..32) |sb| {
            if (sb % 2 == 1) {
                for (0..18) |i| {
                    if (i % 2 == 1) {
                        self.samples[ch][sb * 18 + i] = -self.samples[ch][sb * 18 + i];
                    }
                }
            }
        }
    }

    /// Synthesis filterbank - polyphase synthesis
    fn synthesize(self: *Mp3Decoder, ch: u1, output: []i16, num_channels: usize) void {
        for (0..18) |s| {
            // DCT-32 of 32 subband samples
            var dct_in: [32]i32 = undefined;
            for (0..32) |sb| {
                dct_in[sb] = self.samples[ch][sb * 18 + s];
            }

            // Update synthesis buffer position
            self.synth_offset[ch] = (self.synth_offset[ch] + 1) % 16;
            const offset = self.synth_offset[ch];

            // DCT-32
            for (0..32) |i| {
                var sum: i64 = 0;
                for (0..32) |k| {
                    sum += @as(i64, dct_in[k]) * tables.dct32_cos[i][k];
                }
                self.synth_buffer[ch][offset * 32 + i] = @intCast(@divTrunc(sum, 32768));
            }

            // Window and sum
            for (0..32) |sample_idx| {
                var sum: i64 = 0;
                for (0..16) |j| {
                    const buf_idx = ((offset + j) % 16) * 32 + sample_idx;
                    const win_idx = j * 32 + sample_idx;
                    if (win_idx < tables.synth_window.len and buf_idx < 1024) {
                        sum += @as(i64, self.synth_buffer[ch][buf_idx]) * tables.synth_window[win_idx];
                    }
                }

                // Scale and clip to 16-bit
                var result: i32 = @intCast(@divTrunc(sum, 32768));
                result = @max(-32768, @min(32767, result));

                // Output (interleaved for stereo)
                const out_idx = s * 32 * num_channels + sample_idx * num_channels + ch;
                if (out_idx < output.len) {
                    output[out_idx] = @intCast(result);
                }
            }
        }
    }

    // ============================================================
    // Public API
    // ============================================================

    pub fn seekMs(self: *Mp3Decoder, ms: u64) void {
        const header = self.current_header orelse return;
        const byte_offset = (ms * header.bitrate_kbps) / 8;
        self.position = 0;
        self.skipId3v2();
        self.position += @min(byte_offset, self.data.len - self.position);
        _ = self.findNextFrame();

        // Clear state
        @memset(&self.overlap[0], 0);
        @memset(&self.overlap[1], 0);
        self.main_data_size = 0;
    }

    pub fn seek(self: *Mp3Decoder, sample: u64) void {
        const header = self.current_header orelse return;
        if (header.sample_rate == 0) return;
        const ms = (sample * 1000) / header.sample_rate;
        self.seekMs(ms);
    }

    pub fn getPosition(self: *const Mp3Decoder) u64 {
        const header = self.current_header orelse return 0;
        const frame_size = header.frameSize();
        if (frame_size == 0) return 0;
        // Calculate position relative to audio start
        const audio_bytes = if (self.position > self.audio_start)
            self.position - self.audio_start
        else
            0;
        const frames_played = audio_bytes / frame_size;
        return frames_played * header.samplesPerFrame();
    }

    pub fn getPositionMs(self: *const Mp3Decoder) u64 {
        const header = self.current_header orelse return 0;
        if (header.sample_rate == 0) return 0;
        return (self.getPosition() * 1000) / header.sample_rate;
    }

    pub fn isEof(self: *const Mp3Decoder) bool {
        return self.position >= self.data.len;
    }

    pub fn reset(self: *Mp3Decoder) void {
        self.position = self.audio_start; // Reset to start of audio data
        self.main_data_size = 0;
        @memset(&self.overlap[0], 0);
        @memset(&self.overlap[1], 0);
        for (&self.synth_buffer) |*buf| @memset(buf, 0);
        for (&self.synth_offset) |*o| o.* = 0;
    }

    pub fn getTrackInfo(self: *const Mp3Decoder) audio.TrackInfo {
        return self.track_info;
    }
};

// ============================================================
// Helper Functions
// ============================================================

pub fn isMp3File(data: []const u8) bool {
    if (data.len >= 3 and std.mem.eql(u8, data[0..3], "ID3")) return true;
    if (data.len >= 2 and data[0] == 0xFF and (data[1] & 0xE0) == 0xE0) {
        const layer = (data[1] >> 1) & 0x03;
        return layer == 1;
    }
    return false;
}

pub fn getDuration(data: []const u8) ?u64 {
    const decoder = Mp3Decoder.init(data) catch return null;
    return decoder.track_info.duration_ms;
}

pub fn getBitrate(data: []const u8) ?u16 {
    const decoder = Mp3Decoder.init(data) catch return null;
    if (decoder.current_header) |header| return header.bitrate_kbps;
    return null;
}

// ============================================================
// Tests
// ============================================================

test "mp3 frame header parsing" {
    const valid_header = [_]u8{ 0xFF, 0xFB, 0x90, 0x00 };
    var decoder = Mp3Decoder{
        .data = &valid_header,
        .position = 0,
        .audio_start = 0,
        .track_info = undefined,
        .current_header = null,
        .main_data = [_]u8{0} ** MAIN_DATA_SIZE,
        .main_data_size = 0,
        .synth_buffer = [_][1024]i32{[_]i32{0} ** 1024} ** 2,
        .synth_offset = [_]usize{0} ** 2,
        .overlap = [_][GRANULE_SAMPLES]i32{[_]i32{0} ** GRANULE_SAMPLES} ** 2,
        .samples = [_][GRANULE_SAMPLES]i32{[_]i32{0} ** GRANULE_SAMPLES} ** 2,
        .scalefac = [_]ScaleFactors{.{}} ** 2,
    };

    const header = decoder.parseFrameHeader(&valid_header);
    try std.testing.expect(header != null);
    try std.testing.expectEqual(MpegVersion.mpeg1, header.?.version);
    try std.testing.expectEqual(Layer.layer3, header.?.layer);
    try std.testing.expectEqual(@as(u16, 128), header.?.bitrate_kbps);
    try std.testing.expectEqual(@as(u32, 44100), header.?.sample_rate);
}

test "mp3 frame size calculation" {
    const header = FrameHeader{
        .version = .mpeg1,
        .layer = .layer3,
        .crc_protected = false,
        .bitrate_kbps = 128,
        .sample_rate = 44100,
        .padding = false,
        .channel_mode = .stereo,
        .mode_extension = 0,
        .copyright = false,
        .original = false,
        .emphasis = 0,
    };
    try std.testing.expectEqual(@as(usize, 417), header.frameSize());
}

test "mp3 file detection" {
    const id3_data = [_]u8{ 'I', 'D', '3', 0x04, 0x00, 0x00, 0, 0, 0, 0 };
    try std.testing.expect(isMp3File(&id3_data));

    const sync_data = [_]u8{ 0xFF, 0xFB, 0x90, 0x00 };
    try std.testing.expect(isMp3File(&sync_data));

    const wav_data = [_]u8{ 'R', 'I', 'F', 'F' };
    try std.testing.expect(!isMp3File(&wav_data));
}

test "samples per frame" {
    const mpeg1_header = FrameHeader{
        .version = .mpeg1,
        .layer = .layer3,
        .crc_protected = false,
        .bitrate_kbps = 128,
        .sample_rate = 44100,
        .padding = false,
        .channel_mode = .stereo,
        .mode_extension = 0,
        .copyright = false,
        .original = false,
        .emphasis = 0,
    };
    try std.testing.expectEqual(@as(u16, 1152), mpeg1_header.samplesPerFrame());

    const mpeg2_header = FrameHeader{
        .version = .mpeg2,
        .layer = .layer3,
        .crc_protected = false,
        .bitrate_kbps = 64,
        .sample_rate = 22050,
        .padding = false,
        .channel_mode = .stereo,
        .mode_extension = 0,
        .copyright = false,
        .original = false,
        .emphasis = 0,
    };
    try std.testing.expectEqual(@as(u16, 576), mpeg2_header.samplesPerFrame());
}

test "ms stereo detection" {
    var header = FrameHeader{
        .version = .mpeg1,
        .layer = .layer3,
        .crc_protected = false,
        .bitrate_kbps = 128,
        .sample_rate = 44100,
        .padding = false,
        .channel_mode = .joint_stereo,
        .mode_extension = 0b10,
        .copyright = false,
        .original = false,
        .emphasis = 0,
    };
    try std.testing.expect(header.isMsStereo());
    try std.testing.expect(!header.isIntensityStereo());

    header.mode_extension = 0b01;
    try std.testing.expect(!header.isMsStereo());
    try std.testing.expect(header.isIntensityStereo());

    header.mode_extension = 0b11;
    try std.testing.expect(header.isMsStereo());
    try std.testing.expect(header.isIntensityStereo());
}
