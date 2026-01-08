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

    // Audio data
    audio_data: []const u8 = &[_]u8{},
    audio_offset: usize = 0,
    data_start: usize = 0, // Offset to PCM data in file

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
    }

    /// Load a WAV file for playback
    pub fn loadWav(self: *Self, path: []const u8) !void {
        self.stop();

        // Read the file
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const stat = try file.stat();
        const file_size = stat.size;

        // Allocate buffer for file data
        const data = try self.allocator.alloc(u8, file_size);
        errdefer self.allocator.free(data);

        const bytes_read = try file.readAll(data);
        if (bytes_read != file_size) {
            self.allocator.free(data);
            return error.ReadError;
        }

        // Parse WAV header
        if (!self.parseWavHeader(data)) {
            self.allocator.free(data);
            return error.InvalidFormat;
        }

        // Free old data if any
        if (self.audio_data.len > 0) {
            self.allocator.free(@constCast(self.audio_data));
        }

        self.audio_data = data;
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

    fn parseWavHeader(self: *Self, data: []const u8) bool {
        if (data.len < 44) return false;

        // Check RIFF header
        if (!std.mem.eql(u8, data[0..4], "RIFF")) return false;
        if (!std.mem.eql(u8, data[8..12], "WAVE")) return false;

        // Find fmt chunk
        var offset: usize = 12;
        while (offset + 8 < data.len) {
            const chunk_id = data[offset..][0..4];
            const chunk_size = std.mem.readInt(u32, data[offset + 4 ..][0..4], .little);

            if (std.mem.eql(u8, chunk_id, "fmt ")) {
                if (chunk_size < 16) return false;

                const audio_format = std.mem.readInt(u16, data[offset + 8 ..][0..2], .little);
                if (audio_format != 1) return false; // Only PCM supported

                self.track_info.channels = std.mem.readInt(u16, data[offset + 10 ..][0..2], .little);
                self.track_info.sample_rate = std.mem.readInt(u32, data[offset + 12 ..][0..4], .little);
                self.track_info.bits_per_sample = std.mem.readInt(u16, data[offset + 22 ..][0..2], .little);
            } else if (std.mem.eql(u8, chunk_id, "data")) {
                self.data_start = offset + 8;
                const data_size = chunk_size;

                // Calculate duration
                const bytes_per_sample = self.track_info.bits_per_sample / 8;
                const samples = data_size / (bytes_per_sample * self.track_info.channels);
                self.track_info.duration_ms = (@as(u64, samples) * 1000) / self.track_info.sample_rate;

                return true;
            }

            offset += 8 + chunk_size;
            if (chunk_size % 2 != 0) offset += 1; // Padding
        }

        return false;
    }

    fn initSdlAudio(self: *Self) !void {
        // Initialize SDL audio subsystem if not already done
        if (c.SDL_WasInit(c.SDL_INIT_AUDIO) == 0) {
            if (c.SDL_InitSubSystem(c.SDL_INIT_AUDIO) < 0) {
                return error.AudioInitFailed;
            }
        }

        // Always use standard output rate (44100 Hz) for compatibility
        // We'll resample high sample rate files in the callback
        self.output_sample_rate = 44100;

        var desired: c.SDL_AudioSpec = std.mem.zeroes(c.SDL_AudioSpec);
        desired.freq = @intCast(self.output_sample_rate);
        desired.format = c.AUDIO_S16LSB; // Always output 16-bit
        desired.channels = @intCast(self.track_info.channels);
        desired.samples = 2048; // Buffer size
        desired.callback = audioCallback;
        desired.userdata = self;

        self.audio_device = c.SDL_OpenAudioDevice(null, 0, &desired, &self.audio_spec, 0);
        if (self.audio_device == 0) {
            return error.AudioInitFailed;
        }

        std.debug.print("Output sample rate: {d}Hz (source: {d}Hz)\n", .{ self.output_sample_rate, self.track_info.sample_rate });
    }

    // Debug counter for callback invocations
    var callback_count: u32 = 0;

    fn audioCallback(userdata: ?*anyopaque, stream: [*c]u8, len: c_int) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(userdata orelse {
            std.debug.print("Audio callback: userdata is null!\n", .{});
            return;
        }));

        callback_count += 1;
        if (callback_count <= 5 or callback_count % 100 == 0) {
            std.debug.print("Audio callback #{d}: len={d}, state={any}, data_len={d}, offset={d}, bits={d}\n", .{ callback_count, len, self.state, self.audio_data.len, self.audio_offset, self.track_info.bits_per_sample });
        }

        const output_samples: [*]i16 = @ptrCast(@alignCast(stream));
        const num_output_samples: usize = @intCast(@divTrunc(len, 2)); // 16-bit samples
        const channels: usize = @intCast(self.track_info.channels);
        const num_output_frames = num_output_samples / channels;

        if (self.state != .playing or self.audio_data.len == 0) {
            @memset(stream[0..@intCast(len)], 0);
            return;
        }

        const source_rate = self.track_info.sample_rate;
        const output_rate = self.output_sample_rate;
        const bytes_per_sample: usize = self.track_info.bits_per_sample / 8;
        const frame_size = bytes_per_sample * channels;

        // Calculate data boundaries
        const data_start = self.data_start;
        const data_end = self.audio_data.len;
        const total_source_frames = (data_end - data_start) / frame_size;

        // Current position in source frames (with sub-sample precision via audio_offset)
        const source_frame: usize = self.audio_offset / frame_size;

        // Resample ratio
        const ratio: f64 = @as(f64, @floatFromInt(source_rate)) / @as(f64, @floatFromInt(output_rate));

        var out_idx: usize = 0;
        while (out_idx < num_output_frames) : (out_idx += 1) {
            // Calculate which source frame to read
            const target_frame: usize = source_frame + @as(usize, @intFromFloat(@as(f64, @floatFromInt(out_idx)) * ratio));

            if (target_frame >= total_source_frames) {
                // End of track - fill rest with silence
                const remaining = (num_output_frames - out_idx) * channels;
                for (0..remaining) |i| {
                    output_samples[out_idx * channels + i] = 0;
                }
                self.state = .stopped;
                break;
            }

            // Read source samples (handle 16-bit and 24-bit)
            const src_offset = data_start + target_frame * frame_size;
            for (0..channels) |ch| {
                const sample_offset = src_offset + ch * bytes_per_sample;
                if (sample_offset + bytes_per_sample <= self.audio_data.len) {
                    var sample: i16 = 0;

                    if (bytes_per_sample == 3) {
                        // 24-bit audio: read 3 bytes, convert to 16-bit
                        // 24-bit samples are stored as little-endian signed integers
                        // We take the upper 16 bits for quality
                        const b0 = self.audio_data[sample_offset]; // LSB (discard for 16-bit)
                        const b1 = self.audio_data[sample_offset + 1];
                        const b2 = self.audio_data[sample_offset + 2]; // MSB

                        // Combine middle and high bytes to get 16-bit sample
                        // This effectively divides by 256 (right shift by 8)
                        _ = b0; // Discard least significant byte
                        sample = @bitCast((@as(u16, b2) << 8) | @as(u16, b1));
                    } else {
                        // 16-bit audio
                        sample = std.mem.readInt(i16, self.audio_data[sample_offset..][0..2], .little);
                    }

                    // Apply volume
                    if (self.volume < 100) {
                        const scaled = @divTrunc(@as(i32, sample) * self.volume, 100);
                        sample = @intCast(std.math.clamp(scaled, -32768, 32767));
                    }

                    output_samples[out_idx * channels + ch] = sample;
                } else {
                    output_samples[out_idx * channels + ch] = 0;
                }
            }
        }

        // Advance source position by how many source frames we consumed
        const frames_consumed: usize = @intFromFloat(@as(f64, @floatFromInt(num_output_frames)) * ratio);
        self.audio_offset += frames_consumed * frame_size;

        // Update position in milliseconds
        const frames_played = self.audio_offset / frame_size;
        self.position_ms = (@as(u64, frames_played) * 1000) / source_rate;
    }

    /// Start or resume playback
    pub fn play(self: *Self) void {
        if (self.audio_data.len == 0) return;

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
        const bytes_per_sample = self.track_info.bits_per_sample / 8;
        const bytes_per_ms = (self.track_info.sample_rate * bytes_per_sample * self.track_info.channels) / 1000;
        const target_offset = position * bytes_per_ms;
        const max_offset = self.audio_data.len - self.data_start;

        self.audio_offset = @min(target_offset, max_offset);
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
