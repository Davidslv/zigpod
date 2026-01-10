//! Simulator Audio Player
//!
//! Plays audio files through SDL2 and renders a Now Playing UI.
//! Supports WAV files for testing the simulator.

const std = @import("std");
const c = @cImport({
    @cInclude("SDL2/SDL.h");
});

// ============================================================
// Audio Player State
// ============================================================

pub const PlayState = enum {
    stopped,
    playing,
    paused,
};

pub const TrackInfo = struct {
    title: [64]u8 = [_]u8{0} ** 64,
    title_len: usize = 0,
    artist: [64]u8 = [_]u8{0} ** 64,
    artist_len: usize = 0,
    duration_ms: u64 = 0,
    sample_rate: u32 = 44100,
    channels: u16 = 2,
    bits_per_sample: u16 = 16,

    pub fn getTitle(self: *const TrackInfo) []const u8 {
        return self.title[0..self.title_len];
    }

    pub fn getArtist(self: *const TrackInfo) []const u8 {
        return self.artist[0..self.artist_len];
    }

    pub fn setTitle(self: *TrackInfo, title: []const u8) void {
        const len = @min(title.len, 63);
        @memcpy(self.title[0..len], title[0..len]);
        self.title_len = len;
    }

    pub fn setArtist(self: *TrackInfo, artist: []const u8) void {
        const len = @min(artist.len, 63);
        @memcpy(self.artist[0..len], artist[0..len]);
        self.artist_len = len;
    }
};

/// Audio player for the simulator
pub const AudioPlayer = struct {
    state: PlayState = .stopped,
    track_info: TrackInfo = .{},
    position_ms: u64 = 0,
    volume: u8 = 100, // 0-100 (100 = no volume scaling, cleanest playback)

    // Audio data (pre-converted to 44100Hz 16-bit stereo)
    converted_data: []u8 = &[_]u8{},
    audio_offset: usize = 0,
    total_samples: usize = 0, // Total samples in converted data

    // SDL2 audio
    audio_device: c.SDL_AudioDeviceID = 0,
    audio_spec: c.SDL_AudioSpec = undefined,
    output_sample_rate: u32 = 44100, // Standard output rate

    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.stop();
        if (self.audio_device != 0) {
            c.SDL_CloseAudioDevice(self.audio_device);
            self.audio_device = 0;
        }
        if (self.converted_data.len > 0) {
            self.allocator.free(self.converted_data);
        }
    }

    /// Load a WAV file for playback using SDL2's conversion
    pub fn loadWav(self: *Self, path: []const u8) !void {
        self.stop();

        // Convert path to null-terminated string for SDL
        var path_buf: [512]u8 = undefined;
        if (path.len >= path_buf.len) return error.PathTooLong;
        @memcpy(path_buf[0..path.len], path);
        path_buf[path.len] = 0;

        // Use SDL to load the WAV file
        var wav_spec: c.SDL_AudioSpec = undefined;
        var wav_buffer: [*c]u8 = undefined;
        var wav_length: u32 = undefined;

        if (c.SDL_LoadWAV(&path_buf, &wav_spec, &wav_buffer, &wav_length) == null) {
            std.debug.print("SDL_LoadWAV failed: {s}\n", .{c.SDL_GetError()});
            return error.InvalidFormat;
        }
        defer c.SDL_FreeWAV(wav_buffer);

        // Store original track info
        self.track_info.sample_rate = @intCast(wav_spec.freq);
        self.track_info.channels = wav_spec.channels;
        self.track_info.bits_per_sample = switch (wav_spec.format) {
            c.AUDIO_S16LSB, c.AUDIO_S16MSB, c.AUDIO_U16LSB, c.AUDIO_U16MSB => 16,
            c.AUDIO_S32LSB, c.AUDIO_S32MSB => 32,
            c.AUDIO_F32LSB, c.AUDIO_F32MSB => 32,
            c.AUDIO_S8, c.AUDIO_U8 => 8,
            else => 16,
        };

        std.debug.print("Loaded WAV: {d}Hz, {d}-bit, {d} channels, {d} bytes\n", .{
            wav_spec.freq, self.track_info.bits_per_sample, wav_spec.channels, wav_length,
        });

        // Build audio converter to target format (44100Hz, 16-bit signed, stereo)
        var cvt: c.SDL_AudioCVT = undefined;
        const build_result = c.SDL_BuildAudioCVT(
            &cvt,
            wav_spec.format,
            wav_spec.channels,
            wav_spec.freq,
            c.AUDIO_S16LSB,
            2, // stereo output
            44100,
        );

        if (build_result < 0) {
            std.debug.print("SDL_BuildAudioCVT failed: {s}\n", .{c.SDL_GetError()});
            return error.ConversionFailed;
        }

        // Free old data
        if (self.converted_data.len > 0) {
            self.allocator.free(self.converted_data);
        }

        if (build_result == 0) {
            // No conversion needed
            self.converted_data = try self.allocator.alloc(u8, wav_length);
            @memcpy(self.converted_data, wav_buffer[0..wav_length]);
            std.debug.print("No conversion needed\n", .{});
        } else {
            // Conversion needed
            const conv_buf_size: usize = @intCast(@as(u64, wav_length) * @as(u64, @intCast(cvt.len_mult)));
            self.converted_data = try self.allocator.alloc(u8, conv_buf_size);
            @memcpy(self.converted_data[0..wav_length], wav_buffer[0..wav_length]);

            cvt.len = @intCast(wav_length);
            cvt.buf = self.converted_data.ptr;

            std.debug.print("Converting audio: len_mult={d}, len_ratio={d:.2}\n", .{ cvt.len_mult, cvt.len_ratio });

            if (c.SDL_ConvertAudio(&cvt) < 0) {
                std.debug.print("SDL_ConvertAudio failed: {s}\n", .{c.SDL_GetError()});
                self.allocator.free(self.converted_data);
                self.converted_data = &[_]u8{};
                return error.ConversionFailed;
            }

            // Shrink to actual converted size
            const actual_size: usize = @intCast(cvt.len_cvt);
            if (actual_size < self.converted_data.len) {
                self.converted_data = self.allocator.realloc(self.converted_data, actual_size) catch self.converted_data;
            }

            std.debug.print("Converted to {d} bytes (44100Hz 16-bit stereo)\n", .{actual_size});
        }

        // Calculate total samples and duration
        self.total_samples = self.converted_data.len / 4; // 4 bytes per stereo sample (16-bit * 2 channels)
        self.track_info.duration_ms = (@as(u64, self.total_samples) * 1000) / 44100;
        self.audio_offset = 0;
        self.position_ms = 0;

        // Extract filename as title
        const basename = std.fs.path.basename(path);
        self.track_info.setTitle(basename);
        self.track_info.setArtist("Unknown Artist");

        // Initialize SDL audio if not already done
        if (self.audio_device == 0) {
            try self.initSdlAudio();
        }
    }

    fn initSdlAudio(self: *Self) !void {
        // Initialize SDL audio subsystem if not already done
        if (c.SDL_WasInit(c.SDL_INIT_AUDIO) == 0) {
            if (c.SDL_InitSubSystem(c.SDL_INIT_AUDIO) < 0) {
                return error.AudioInitFailed;
            }
        }

        self.output_sample_rate = 44100;

        var desired: c.SDL_AudioSpec = std.mem.zeroes(c.SDL_AudioSpec);
        desired.freq = 44100;
        desired.format = c.AUDIO_S16LSB;
        desired.channels = 2; // Stereo (we pre-convert to stereo)
        desired.samples = 2048;
        desired.callback = audioCallback;
        desired.userdata = self;

        self.audio_device = c.SDL_OpenAudioDevice(null, 0, &desired, &self.audio_spec, 0);
        if (self.audio_device == 0) {
            std.debug.print("SDL_OpenAudioDevice failed: {s}\n", .{c.SDL_GetError()});
            return error.AudioInitFailed;
        }

        std.debug.print("Audio device opened: {d}Hz stereo\n", .{self.audio_spec.freq});
    }

    fn audioCallback(userdata: ?*anyopaque, stream: [*c]u8, len: c_int) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(userdata orelse {
            @memset(stream[0..@intCast(len)], 0);
            return;
        }));

        const output: []u8 = stream[0..@intCast(len)];

        if (self.state != .playing or self.converted_data.len == 0) {
            @memset(output, 0);
            return;
        }

        const bytes_remaining = self.converted_data.len - self.audio_offset;
        const bytes_to_copy = @min(bytes_remaining, output.len);

        if (bytes_to_copy > 0) {
            // Copy pre-converted audio data directly
            @memcpy(output[0..bytes_to_copy], self.converted_data[self.audio_offset..][0..bytes_to_copy]);

            // Apply volume if not 100%
            if (self.volume < 100) {
                const samples: [*]i16 = @ptrCast(@alignCast(output.ptr));
                const num_samples = bytes_to_copy / 2;
                for (0..num_samples) |i| {
                    const scaled = @divTrunc(@as(i32, samples[i]) * self.volume, 100);
                    samples[i] = @intCast(std.math.clamp(scaled, -32768, 32767));
                }
            }

            self.audio_offset += bytes_to_copy;
        }

        // Fill remaining with silence if we hit end of track
        if (bytes_to_copy < output.len) {
            @memset(output[bytes_to_copy..], 0);
            self.state = .stopped;
        }

        // Update position
        const samples_played = self.audio_offset / 4; // 4 bytes per stereo sample
        self.position_ms = (samples_played * 1000) / 44100;
    }

    /// Start or resume playback
    pub fn play(self: *Self) void {
        if (self.converted_data.len == 0) return;

        self.state = .playing;
        if (self.audio_device != 0) {
            c.SDL_PauseAudioDevice(self.audio_device, 0);
        }
    }

    /// Pause playback
    pub fn pause(self: *Self) void {
        self.state = .paused;
        if (self.audio_device != 0) {
            c.SDL_PauseAudioDevice(self.audio_device, 1);
        }
    }

    /// Toggle play/pause
    pub fn togglePause(self: *Self) void {
        if (self.state == .playing) {
            self.pause();
        } else {
            self.play();
        }
    }

    /// Stop playback
    pub fn stop(self: *Self) void {
        self.state = .stopped;
        self.audio_offset = 0;
        self.position_ms = 0;
        if (self.audio_device != 0) {
            c.SDL_PauseAudioDevice(self.audio_device, 1);
        }
    }

    /// Seek to position (milliseconds)
    pub fn seekMs(self: *Self, position: u64) void {
        // Converted data is 44100Hz, 16-bit stereo = 4 bytes per sample
        const bytes_per_ms = (44100 * 4) / 1000; // ~176 bytes per ms
        const target_offset = position * bytes_per_ms;

        self.audio_offset = @min(target_offset, self.converted_data.len);
        self.position_ms = position;
    }

    /// Set volume (0-100)
    pub fn setVolume(self: *Self, vol: u8) void {
        self.volume = @min(vol, 100);
    }

    /// Get current state
    pub fn getState(self: *const Self) PlayState {
        return self.state;
    }

    /// Get position in milliseconds
    pub fn getPositionMs(self: *const Self) u64 {
        return self.position_ms;
    }

    /// Get track info
    pub fn getTrackInfo(self: *const Self) *const TrackInfo {
        return &self.track_info;
    }

    /// Get progress as percentage (0-100)
    pub fn getProgressPercent(self: *const Self) u8 {
        if (self.track_info.duration_ms == 0) return 0;
        return @intCast((self.position_ms * 100) / self.track_info.duration_ms);
    }

    /// Check if track finished playing (reached end)
    pub fn hasTrackEnded(self: *const Self) bool {
        // Track ended if we were playing, are now stopped, and reached near the end
        return self.state == .stopped and
            self.converted_data.len > 0 and
            self.audio_offset >= self.converted_data.len - 4096; // Within last buffer
    }

    /// Reset the ended state (call after handling track end)
    pub fn clearEndedState(self: *Self) void {
        self.audio_offset = 0;
        self.position_ms = 0;
    }
};

// ============================================================
// Now Playing UI Renderer
// ============================================================

/// Render "Now Playing" screen to LCD framebuffer
pub fn renderNowPlaying(framebuffer: []u16, player: *const AudioPlayer) void {
    const WIDTH: usize = 320;
    const HEIGHT: usize = 240;

    // Background - dark gradient
    for (0..HEIGHT) |y| {
        for (0..WIDTH) |x| {
            const gray: u16 = @truncate(20 + y / 12);
            framebuffer[y * WIDTH + x] = rgb565(gray, gray, gray + 5);
        }
    }

    // Title bar
    drawRect(framebuffer, 0, 0, WIDTH, 30, rgb565(40, 40, 50));

    // "Now Playing" text (simple block letters)
    drawText(framebuffer, 10, 8, "Now Playing", rgb565(200, 200, 220));

    // Album art placeholder (centered square)
    const art_size: usize = 120;
    const art_x = (WIDTH - art_size) / 2;
    const art_y: usize = 45;
    drawRect(framebuffer, art_x, art_y, art_size, art_size, rgb565(60, 60, 80));
    // Draw music note icon
    drawMusicNote(framebuffer, art_x + art_size / 2, art_y + art_size / 2);

    // Track info
    const info = player.getTrackInfo();
    const title_y: usize = 175;
    drawTextCentered(framebuffer, title_y, info.getTitle(), rgb565(255, 255, 255));
    drawTextCentered(framebuffer, title_y + 15, info.getArtist(), rgb565(150, 150, 160));

    // Progress bar
    const bar_y: usize = 205;
    const bar_x: usize = 20;
    const bar_w: usize = WIDTH - 40;
    const bar_h: usize = 6;
    drawRect(framebuffer, bar_x, bar_y, bar_w, bar_h, rgb565(50, 50, 60));

    const progress = player.getProgressPercent();
    const filled_w = (bar_w * progress) / 100;
    if (filled_w > 0) {
        drawRect(framebuffer, bar_x, bar_y, filled_w, bar_h, rgb565(80, 140, 255));
    }

    // Time display
    var pos_buf: [16]u8 = undefined;
    var dur_buf: [16]u8 = undefined;
    const pos_str = formatTime(player.getPositionMs(), &pos_buf);
    const dur_str = formatTime(info.duration_ms, &dur_buf);

    drawText(framebuffer, bar_x, bar_y + 10, pos_str, rgb565(150, 150, 160));
    drawTextRight(framebuffer, bar_x + bar_w, bar_y + 10, dur_str, rgb565(150, 150, 160));

    // Play/Pause indicator
    const state = player.getState();
    if (state == .playing) {
        // Pause bars
        drawRect(framebuffer, WIDTH / 2 - 12, 225, 6, 12, rgb565(255, 255, 255));
        drawRect(framebuffer, WIDTH / 2 + 6, 225, 6, 12, rgb565(255, 255, 255));
    } else {
        // Play triangle
        drawPlayIcon(framebuffer, WIDTH / 2, 231);
    }
}

// ============================================================
// Drawing Helpers
// ============================================================

fn rgb565(r: u16, g: u16, b: u16) u16 {
    return ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3);
}

fn drawRect(framebuffer: []u16, x: usize, y: usize, w: usize, h: usize, color: u16) void {
    const WIDTH: usize = 320;
    for (y..y + h) |py| {
        if (py >= 240) break;
        for (x..x + w) |px| {
            if (px >= 320) break;
            framebuffer[py * WIDTH + px] = color;
        }
    }
}

fn drawMusicNote(framebuffer: []u16, cx: usize, cy: usize) void {
    const color = rgb565(200, 200, 220);
    const WIDTH: usize = 320;

    // Note head (circle)
    for (0..8) |dy| {
        for (0..10) |dx| {
            const px = cx - 5 + dx;
            const py = cy + 15 - 4 + dy;
            if (px < 320 and py < 240) {
                framebuffer[py * WIDTH + px] = color;
            }
        }
    }

    // Note stem
    for (0..35) |dy| {
        const px = cx + 4;
        const py = cy - 15 + dy;
        if (px < 320 and py < 240) {
            framebuffer[py * WIDTH + px] = color;
            framebuffer[py * WIDTH + px + 1] = color;
        }
    }

    // Flag
    for (0..8) |i| {
        const px = cx + 6 + i;
        const py = cy - 15 + i;
        if (px < 320 and py < 240) {
            framebuffer[py * WIDTH + px] = color;
        }
    }
}

fn drawPlayIcon(framebuffer: []u16, cx: usize, cy: usize) void {
    const color = rgb565(255, 255, 255);
    const WIDTH: usize = 320;

    // Triangle pointing right
    for (0..12) |i| {
        const width = 12 - i;
        for (0..width) |j| {
            const px = cx - 6 + j;
            const py = cy - 6 + i;
            if (px < 320 and py < 240) {
                framebuffer[py * WIDTH + px] = color;
            }
        }
    }
}

// Simple 5x7 font for basic ASCII
const FONT_WIDTH = 5;
const FONT_HEIGHT = 7;

fn drawChar(framebuffer: []u16, x: usize, y: usize, char: u8, color: u16) void {
    const WIDTH: usize = 320;
    // Very simple bitmap font - just basic shapes
    const patterns = getCharPattern(char);
    for (0..FONT_HEIGHT) |row| {
        for (0..FONT_WIDTH) |col| {
            if ((patterns[row] >> @intCast(FONT_WIDTH - 1 - col)) & 1 == 1) {
                const px = x + col;
                const py = y + row;
                if (px < 320 and py < 240) {
                    framebuffer[py * WIDTH + px] = color;
                }
            }
        }
    }
}

fn getCharPattern(char: u8) [7]u8 {
    return switch (char) {
        'N' => .{ 0x11, 0x19, 0x15, 0x13, 0x11, 0x11, 0x11 },
        'o' => .{ 0x00, 0x00, 0x0E, 0x11, 0x11, 0x11, 0x0E },
        'w' => .{ 0x00, 0x00, 0x11, 0x11, 0x15, 0x15, 0x0A },
        'P' => .{ 0x1E, 0x11, 0x11, 0x1E, 0x10, 0x10, 0x10 },
        'l' => .{ 0x0C, 0x04, 0x04, 0x04, 0x04, 0x04, 0x0E },
        'a' => .{ 0x00, 0x00, 0x0E, 0x01, 0x0F, 0x11, 0x0F },
        'y' => .{ 0x00, 0x00, 0x11, 0x11, 0x0F, 0x01, 0x0E },
        'i' => .{ 0x04, 0x00, 0x0C, 0x04, 0x04, 0x04, 0x0E },
        'n' => .{ 0x00, 0x00, 0x16, 0x19, 0x11, 0x11, 0x11 },
        'g' => .{ 0x00, 0x00, 0x0F, 0x11, 0x0F, 0x01, 0x0E },
        ' ' => .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 },
        '0' => .{ 0x0E, 0x11, 0x13, 0x15, 0x19, 0x11, 0x0E },
        '1' => .{ 0x04, 0x0C, 0x04, 0x04, 0x04, 0x04, 0x0E },
        '2' => .{ 0x0E, 0x11, 0x01, 0x02, 0x04, 0x08, 0x1F },
        '3' => .{ 0x1F, 0x02, 0x04, 0x02, 0x01, 0x11, 0x0E },
        '4' => .{ 0x02, 0x06, 0x0A, 0x12, 0x1F, 0x02, 0x02 },
        '5' => .{ 0x1F, 0x10, 0x1E, 0x01, 0x01, 0x11, 0x0E },
        '6' => .{ 0x06, 0x08, 0x10, 0x1E, 0x11, 0x11, 0x0E },
        '7' => .{ 0x1F, 0x01, 0x02, 0x04, 0x08, 0x08, 0x08 },
        '8' => .{ 0x0E, 0x11, 0x11, 0x0E, 0x11, 0x11, 0x0E },
        '9' => .{ 0x0E, 0x11, 0x11, 0x0F, 0x01, 0x02, 0x0C },
        ':' => .{ 0x00, 0x0C, 0x0C, 0x00, 0x0C, 0x0C, 0x00 },
        '.' => .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x0C, 0x0C },
        '-' => .{ 0x00, 0x00, 0x00, 0x1F, 0x00, 0x00, 0x00 },
        'U' => .{ 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E },
        'k' => .{ 0x10, 0x10, 0x12, 0x14, 0x18, 0x14, 0x12 },
        else => .{ 0x0E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E }, // Default: 'O'
    };
}

fn drawText(framebuffer: []u16, x: usize, y: usize, text: []const u8, color: u16) void {
    var cx = x;
    for (text) |char| {
        drawChar(framebuffer, cx, y, char, color);
        cx += FONT_WIDTH + 1;
    }
}

fn drawTextCentered(framebuffer: []u16, y: usize, text: []const u8, color: u16) void {
    const text_width = text.len * (FONT_WIDTH + 1);
    const x = (320 - text_width) / 2;
    drawText(framebuffer, x, y, text, color);
}

fn drawTextRight(framebuffer: []u16, x: usize, y: usize, text: []const u8, color: u16) void {
    const text_width = text.len * (FONT_WIDTH + 1);
    const start_x = if (x >= text_width) x - text_width else 0;
    drawText(framebuffer, start_x, y, text, color);
}

fn formatTime(ms: u64, buf: []u8) []const u8 {
    const secs = ms / 1000;
    const mins = secs / 60;
    const remaining_secs = secs % 60;
    return std.fmt.bufPrint(buf, "{d}:{d:0>2}", .{ mins, remaining_secs }) catch "0:00";
}
