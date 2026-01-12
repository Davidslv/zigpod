//! SDL2 Audio Frontend
//!
//! Provides audio output from the emulated I2S controller.
//! Uses SDL2 audio callback for low-latency playback.

const std = @import("std");
const i2s = @import("../peripherals/i2s.zig");
const c = @cImport({
    @cInclude("SDL2/SDL.h");
});

/// Audio configuration
pub const SAMPLE_RATE: u32 = 44100;
pub const CHANNELS: u8 = 2;
pub const BUFFER_SAMPLES: u16 = 1024;

/// Audio sample ring buffer
const RING_BUFFER_SIZE: usize = 8192;

/// SDL Audio Output
pub const SdlAudio = struct {
    device_id: c.SDL_AudioDeviceID,

    /// Ring buffer for samples
    ring_buffer: [RING_BUFFER_SIZE]i16,
    write_pos: usize,
    read_pos: usize,
    sample_count: std.atomic.Value(usize),

    /// Mute state
    muted: bool,

    /// Volume (0-128)
    volume: u8,

    const Self = @This();

    /// Initialize SDL audio
    pub fn init() !Self {
        // Initialize SDL audio subsystem
        if (c.SDL_Init(c.SDL_INIT_AUDIO) != 0) {
            return error.SdlAudioInitFailed;
        }
        errdefer c.SDL_QuitSubSystem(c.SDL_INIT_AUDIO);

        var self = Self{
            .device_id = 0,
            .ring_buffer = [_]i16{0} ** RING_BUFFER_SIZE,
            .write_pos = 0,
            .read_pos = 0,
            .sample_count = std.atomic.Value(usize).init(0),
            .muted = false,
            .volume = 128,
        };

        // Set up audio spec
        var wanted: c.SDL_AudioSpec = undefined;
        wanted.freq = @intCast(SAMPLE_RATE);
        wanted.format = c.AUDIO_S16SYS;
        wanted.channels = CHANNELS;
        wanted.samples = BUFFER_SAMPLES;
        wanted.callback = audioCallback;
        wanted.userdata = @ptrCast(&self);

        var obtained: c.SDL_AudioSpec = undefined;

        // Open audio device
        self.device_id = c.SDL_OpenAudioDevice(
            null, // Use default device
            0, // Playback device
            &wanted,
            &obtained,
            0, // Don't allow changes
        );

        if (self.device_id == 0) {
            return error.AudioDeviceOpenFailed;
        }

        // Start playback
        c.SDL_PauseAudioDevice(self.device_id, 0);

        return self;
    }

    /// Deinitialize SDL audio
    pub fn deinit(self: *Self) void {
        if (self.device_id != 0) {
            c.SDL_CloseAudioDevice(self.device_id);
            self.device_id = 0;
        }
        c.SDL_QuitSubSystem(c.SDL_INIT_AUDIO);
    }

    /// Queue audio samples from I2S controller
    pub fn queueSamples(self: *Self, samples: []const i2s.AudioSample) void {
        if (self.muted) return;

        for (samples) |sample| {
            // Check if buffer has space
            const count = self.sample_count.load(.acquire);
            if (count >= RING_BUFFER_SIZE - 2) {
                // Buffer full, drop samples
                continue;
            }

            // Write left and right channels
            self.ring_buffer[self.write_pos] = sample.left;
            self.write_pos = (self.write_pos + 1) % RING_BUFFER_SIZE;

            self.ring_buffer[self.write_pos] = sample.right;
            self.write_pos = (self.write_pos + 1) % RING_BUFFER_SIZE;

            _ = self.sample_count.fetchAdd(2, .release);
        }
    }

    /// Set mute state
    pub fn setMuted(self: *Self, muted: bool) void {
        self.muted = muted;
    }

    /// Set volume (0-128)
    pub fn setVolume(self: *Self, volume: u8) void {
        self.volume = volume;
    }

    /// Audio callback (called by SDL from audio thread)
    fn audioCallback(userdata: ?*anyopaque, stream: [*c]u8, len: c_int) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(userdata));
        const samples_needed = @as(usize, @intCast(len)) / @sizeOf(i16);
        const output: [*]i16 = @ptrCast(@alignCast(stream));

        var i: usize = 0;
        while (i < samples_needed) : (i += 1) {
            const count = self.sample_count.load(.acquire);
            if (count > 0) {
                // Read from ring buffer
                var sample = self.ring_buffer[self.read_pos];
                self.read_pos = (self.read_pos + 1) % RING_BUFFER_SIZE;
                _ = self.sample_count.fetchSub(1, .release);

                // Apply volume
                sample = @intCast(@divTrunc(@as(i32, sample) * self.volume, 128));
                output[i] = sample;
            } else {
                // No samples, output silence
                output[i] = 0;
            }
        }
    }

    /// Get current buffer fill level (0.0 - 1.0)
    pub fn getBufferLevel(self: *const Self) f32 {
        const count = self.sample_count.load(.acquire);
        return @as(f32, @floatFromInt(count)) / @as(f32, RING_BUFFER_SIZE);
    }
};

/// Create audio callback for I2S controller
pub fn createAudioCallback(audio: *SdlAudio) *const fn ([]const i2s.AudioSample) void {
    const Wrapper = struct {
        var audio_ptr: *SdlAudio = undefined;

        fn callback(samples: []const i2s.AudioSample) void {
            audio_ptr.queueSamples(samples);
        }
    };

    Wrapper.audio_ptr = audio;
    return &Wrapper.callback;
}
