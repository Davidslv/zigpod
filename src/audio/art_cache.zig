//! Idle-Time Art Pre-Caching System
//!
//! This module provides background pre-caching of album art for upcoming tracks.
//! By caching art during idle periods (while audio is playing but no user input),
//! we achieve zero-latency art display when tracks change.
//!
//! # Complexity: LOW (~100 lines)
//!
//! ## How It Works
//!
//! ```
//!   ┌─────────────────────────────────────────────────────────┐
//!   │                    Main Loop                            │
//!   │                                                         │
//!   │  ┌─────────┐     ┌──────────┐     ┌─────────────────┐  │
//!   │  │ Input?  │ No  │ Playing? │ Yes │ Pre-cache next  │  │
//!   │  │         │────▶│          │────▶│ track's art     │  │
//!   │  └─────────┘     └──────────┘     └─────────────────┘  │
//!   │       │                                                 │
//!   │       │ Yes                                             │
//!   │       ▼                                                 │
//!   │  ┌─────────────┐                                       │
//!   │  │ Handle input│  (pre-caching skipped this frame)     │
//!   │  └─────────────┘                                       │
//!   └─────────────────────────────────────────────────────────┘
//! ```
//!
//! ## Design Decisions
//!
//! - Only pre-cache one track ahead (minimizes wasted work if user skips)
//! - Check idle state before starting (don't compete with user input)
//! - Use existing album_art.loadForTrack() which handles caching
//!
//! ## Memory Impact
//!
//! - No additional persistent memory (uses existing cache files)
//! - Temporary decode buffers are shared with normal art loading
//!
//! ## Integration
//!
//! Call `tickIdlePreCache()` from the main app loop when:
//! - Audio is playing
//! - No recent user input (idle for N frames)
//!

const std = @import("std");
const album_art = @import("album_art.zig");

// ============================================================
// Configuration
// ============================================================

/// Minimum idle frames before pre-caching starts
/// This prevents pre-caching from competing with user interactions
pub const IDLE_THRESHOLD_FRAMES: u32 = 60; // ~1 second at 60fps

/// Maximum tracks to pre-cache ahead
pub const LOOKAHEAD_TRACKS: usize = 2;

// ============================================================
// State
// ============================================================

/// Current pre-cache index in queue
var precache_index: usize = 0;

/// Whether pre-caching is currently active
var precache_active: bool = false;

/// Tracks that have been pre-cached this session
/// Simple ring buffer to avoid re-caching the same tracks
var cached_paths: [8][256]u8 = undefined;
var cached_lengths: [8]u8 = [_]u8{0} ** 8;
var cached_write_index: usize = 0;

// ============================================================
// Public API
// ============================================================

/// Call this from main loop when system is idle
/// Returns true if pre-caching work was done this frame
pub fn tickIdlePreCache(
    current_track_index: usize,
    queue_paths: []const []const u8,
) bool {
    // Nothing to pre-cache if queue is empty or too small
    if (queue_paths.len == 0) return false;

    // Calculate which track to pre-cache
    const target_index = current_track_index + 1 + precache_index;
    if (target_index >= queue_paths.len) {
        // Wrapped around, reset
        precache_index = 0;
        return false;
    }

    const target_path = queue_paths[target_index];

    // Check if already cached this session
    if (isAlreadyCached(target_path)) {
        // Move to next track
        precache_index = (precache_index + 1) % LOOKAHEAD_TRACKS;
        return false;
    }

    // Do the pre-caching work
    _ = album_art.loadForTrack(target_path);

    // Remember that we cached this path
    rememberCached(target_path);

    // Move to next track for next idle tick
    precache_index = (precache_index + 1) % LOOKAHEAD_TRACKS;

    return true;
}

/// Reset pre-cache state (call on queue change or track skip)
pub fn reset() void {
    precache_index = 0;
    precache_active = false;
}

/// Clear all cached path memory
pub fn clearHistory() void {
    for (&cached_lengths) |*len| {
        len.* = 0;
    }
    cached_write_index = 0;
}

// ============================================================
// Internal Functions
// ============================================================

fn isAlreadyCached(path: []const u8) bool {
    for (cached_paths, cached_lengths) |cached_path, cached_len| {
        if (cached_len == 0) continue;
        if (cached_len != path.len) continue;
        if (std.mem.eql(u8, cached_path[0..cached_len], path)) {
            return true;
        }
    }
    return false;
}

fn rememberCached(path: []const u8) void {
    if (path.len > 255) return;

    @memcpy(cached_paths[cached_write_index][0..path.len], path);
    cached_lengths[cached_write_index] = @intCast(path.len);

    cached_write_index = (cached_write_index + 1) % cached_paths.len;
}

// ============================================================
// Idle State Tracker
// ============================================================
//
// This tracks whether the system is truly idle (no recent input)
// and safe to do background work.
//

/// Frames since last user input
var idle_frame_count: u32 = 0;

/// Call when user input is detected (resets idle counter)
pub fn notifyUserInput() void {
    idle_frame_count = 0;
}

/// Call each frame to increment idle counter
pub fn tickFrame() void {
    if (idle_frame_count < std.math.maxInt(u32)) {
        idle_frame_count += 1;
    }
}

/// Check if system has been idle long enough for pre-caching
pub fn isIdleForPreCache() bool {
    return idle_frame_count >= IDLE_THRESHOLD_FRAMES;
}

// ============================================================
// Tests
// ============================================================

test "idle tracking" {
    // Start fresh
    idle_frame_count = 0;
    try std.testing.expect(!isIdleForPreCache());

    // Simulate idle frames
    for (0..IDLE_THRESHOLD_FRAMES) |_| {
        tickFrame();
    }
    try std.testing.expect(isIdleForPreCache());

    // User input resets
    notifyUserInput();
    try std.testing.expect(!isIdleForPreCache());
}

test "cache history" {
    clearHistory();

    const path1 = "/music/album1/track1.mp3";
    const path2 = "/music/album2/track2.mp3";

    try std.testing.expect(!isAlreadyCached(path1));

    rememberCached(path1);
    try std.testing.expect(isAlreadyCached(path1));
    try std.testing.expect(!isAlreadyCached(path2));

    rememberCached(path2);
    try std.testing.expect(isAlreadyCached(path1));
    try std.testing.expect(isAlreadyCached(path2));

    clearHistory();
    try std.testing.expect(!isAlreadyCached(path1));
    try std.testing.expect(!isAlreadyCached(path2));
}
