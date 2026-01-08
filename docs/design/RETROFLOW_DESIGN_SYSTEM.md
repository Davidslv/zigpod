# RetroFlow Design System v2.0
## ZigPod Design Oracle Blueprint

> "Technology disappears. Only music remains."

---

## I. Philosophy: The Disappearing Interface

### Core Tenets

**1. Temporal Dissolution**
The interface exists only when needed, then vanishes. Every pixel serves music discovery or playback. Zero cognitive overhead - the user never "uses" ZigPod, they simply *listen*.

**2. Anticipatory Design**
The system learns patterns: 6AM = podcasts, 7PM = playlists, weekend mornings = discovery. Context shapes presentation without explicit configuration.

**3. Sensory Hierarchy**
```
Audio (primary) → Haptic (secondary) → Visual (tertiary)
```
For a music device, sound IS the interface. Visual serves audio, not vice versa.

**4. Constraint as Poetry**
320x240 pixels. 16-bit color. Click Wheel. These aren't limitations - they're the canvas that forces elegant solutions impossible on larger displays.

---

## II. Visual Language: Obsidian Foundation

### Color Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  RETROFLOW COLOR SYSTEM                                     │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  FOUNDATION LAYER (Always present)                          │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  obsidian_black   #000000  RGB(0,0,0)       Base    │   │
│  │  void_gray        #0A0A0C  RGB(10,10,12)    Depth   │   │
│  │  carbon_gray      #141418  RGB(20,20,24)    Surface │   │
│  │  slate_gray       #1E1E24  RGB(30,30,36)    Elevated│   │
│  └─────────────────────────────────────────────────────┘   │
│                                                             │
│  TYPOGRAPHY LAYER                                           │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  pure_white       #FFFFFF  RGB(255,255,255) Primary │   │
│  │  silver           #B8B8C0  RGB(184,184,192) Second  │   │
│  │  pewter           #6E6E78  RGB(110,110,120) Tertiary│   │
│  │  graphite         #3C3C44  RGB(60,60,68)    Disabled│   │
│  └─────────────────────────────────────────────────────┘   │
│                                                             │
│  ACCENT SPECTRUM                                            │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  electric_cyan    #00BFFF  RGB(0,191,255)   Primary │   │
│  │  aurora_cyan      #00D4FF  RGB(0,212,255)   Bright  │   │
│  │  deep_cyan        #0088B8  RGB(0,136,184)   Muted   │   │
│  │  ambient_amber    #FFBF00  RGB(255,191,0)   Warm    │   │
│  │  soft_amber       #CC9900  RGB(204,153,0)   Subtle  │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                             │
│  SEMANTIC STATES                                            │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  playing_pulse    Cyan @ 80% opacity, beat-synced   │   │
│  │  selection_glow   Cyan @ 15% bg, 100% border        │   │
│  │  error_red        #FF4444  Transient only           │   │
│  │  success_green    #44FF88  Confirmation flash       │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### RGB565 Implementation

```zig
// RetroFlow Color Constants - Optimized for 16-bit depth
pub const RetroFlowPalette = struct {
    // Foundation
    pub const obsidian: u16 = 0x0000;      // Pure black
    pub const void_g: u16 = 0x0841;        // rgb(10,10,12)
    pub const carbon: u16 = 0x10A2;        // rgb(20,20,24)
    pub const slate: u16 = 0x18E4;         // rgb(30,30,36)

    // Typography
    pub const pure_white: u16 = 0xFFFF;
    pub const silver: u16 = 0xBDD7;        // rgb(184,184,192)
    pub const pewter: u16 = 0x6B6F;        // rgb(110,110,120)
    pub const graphite: u16 = 0x39C8;      // rgb(60,60,68)

    // Accents
    pub const electric_cyan: u16 = 0x05FF; // rgb(0,191,255)
    pub const aurora_cyan: u16 = 0x06BF;   // rgb(0,212,255)
    pub const deep_cyan: u16 = 0x0457;     // rgb(0,136,184)
    pub const amber: u16 = 0xFDE0;         // rgb(255,191,0)
    pub const soft_amber: u16 = 0xCC80;    // rgb(204,153,0)

    // Derived
    pub const selection_bg: u16 = 0x0883;  // Cyan @ 15%
    pub const playing_glow: u16 = 0x04DC;  // Beat-reactive base
};
```

### Micro-Texture System

No gradients (expensive). Instead: **dithered depth patterns** computed at compile-time.

```zig
// Comptime-generated 2x2 dither patterns for depth
pub const DitherPatterns = struct {
    // Subtle noise for surfaces (avoids banding on LCD)
    pub const surface_noise = comptime blk: {
        var pattern: [4]u16 = undefined;
        pattern[0] = RetroFlowPalette.carbon;
        pattern[1] = RetroFlowPalette.void_g;
        pattern[2] = RetroFlowPalette.void_g;
        pattern[3] = RetroFlowPalette.carbon;
        break :blk pattern;
    };

    // Depth shadow for elevated elements
    pub const depth_shadow = comptime blk: {
        var pattern: [4]u16 = undefined;
        pattern[0] = RetroFlowPalette.obsidian;
        pattern[1] = RetroFlowPalette.void_g;
        pattern[2] = RetroFlowPalette.void_g;
        pattern[3] = RetroFlowPalette.obsidian;
        break :blk pattern;
    };
};

// Apply dither pattern to rectangle
pub fn fillDithered(x: u16, y: u16, w: u16, h: u16, pattern: *const [4]u16) void {
    var py: u16 = y;
    while (py < y + h) : (py += 1) {
        var px: u16 = x;
        while (px < x + w) : (px += 1) {
            const idx = ((py & 1) << 1) | (px & 1);
            setPixel(px, py, pattern[idx]);
        }
    }
}
```

### Typography Hierarchy

```
┌─────────────────────────────────────────────────────────────┐
│  RETROFLOW TYPOGRAPHY                                       │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  DISPLAY (Now Playing song title)                           │
│  ├── Size: 16px equivalent (2x base)                        │
│  ├── Color: pure_white                                      │
│  ├── Weight: Bold (double-stroke render)                    │
│  └── Tracking: +2% for readability                          │
│                                                             │
│  HEADING (Screen titles, artist names)                      │
│  ├── Size: 12px equivalent (1.5x base)                      │
│  ├── Color: pure_white                                      │
│  └── Weight: Medium                                         │
│                                                             │
│  BODY (List items, album names)                             │
│  ├── Size: 8px base                                         │
│  ├── Color: silver                                          │
│  └── Line height: 12px (1.5x)                               │
│                                                             │
│  CAPTION (Timestamps, counts, hints)                        │
│  ├── Size: 6px (compact font)                               │
│  ├── Color: pewter                                          │
│  └── Use: metadata, secondary info                          │
│                                                             │
│  NUMERALS (Track numbers, time)                             │
│  ├── Style: Tabular/monospace                               │
│  ├── Color: Context-dependent                               │
│  └── Feature: Fixed-width for alignment                     │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### Accessibility Modes

```zig
pub const AccessibilityMode = enum {
    standard,           // Default RetroFlow
    high_contrast,      // Pure black/white, no grays
    color_blind_safe,   // Cyan→Blue, Amber→White patterns
    large_text,         // 1.5x all typography
    reduced_motion,     // No animations, instant transitions
};

pub const HighContrastPalette = struct {
    pub const background: u16 = 0x0000;
    pub const foreground: u16 = 0xFFFF;
    pub const selection: u16 = 0xFFFF;    // Inverted
    pub const sel_text: u16 = 0x0000;
    pub const accent: u16 = 0xFFFF;       // No color reliance
};
```

---

## III. Navigation: Click Wheel Mastery

### Acceleration Curve

```
┌─────────────────────────────────────────────────────────────┐
│  WHEEL ACCELERATION MODEL                                   │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  Velocity (items/sec)                                       │
│        │                                                    │
│    40 ─┤                               ●●●● MAX             │
│        │                          ●●●●                      │
│    30 ─┤                      ●●●                           │
│        │                  ●●●                               │
│    20 ─┤              ●●●          ← Turbo zone             │
│        │          ●●●                                       │
│    10 ─┤      ●●●                  ← Speed zone             │
│        │  ●●●                                               │
│     1 ─┤●●                         ← Precision zone         │
│        └────┬────┬────┬────┬────┬──                         │
│             1    2    3    4    5   Wheel RPM               │
│                                                             │
│  Zones:                                                     │
│  • Precision (0-1 RPM): 1:1 mapping, perfect for lists <10  │
│  • Speed (1-3 RPM): 3x multiplier, alphabetic jump hints    │
│  • Turbo (3+ RPM): Index snapping (A→B→C), visual blur      │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

```zig
// Acceleration curve implementation
pub const WheelAcceleration = struct {
    last_tick: u32 = 0,
    velocity: f32 = 0,

    // Compute items to scroll based on wheel velocity
    pub fn compute(self: *@This(), current_tick: u32) u16 {
        const delta = current_tick - self.last_tick;
        self.last_tick = current_tick;

        // Calculate RPM from tick delta (lower = faster rotation)
        const rpm = if (delta > 0) 60000.0 / @as(f32, @floatFromInt(delta * 24)) else 0;

        // Smooth velocity with decay
        self.velocity = self.velocity * 0.7 + rpm * 0.3;

        // Acceleration zones
        if (self.velocity < 1.0) {
            return 1;  // Precision: one item
        } else if (self.velocity < 3.0) {
            return @intFromFloat(self.velocity * 2);  // Speed: 2-6 items
        } else {
            return @intFromFloat(@min(40, self.velocity * 4));  // Turbo: 12-40 items
        }
    }

    // Get current zone for UI feedback
    pub fn getZone(self: *const @This()) enum { precision, speed, turbo } {
        if (self.velocity < 1.0) return .precision;
        if (self.velocity < 3.0) return .speed;
        return .turbo;
    }
};
```

### Input Gesture Map

```
┌─────────────────────────────────────────────────────────────┐
│  RETROFLOW GESTURE VOCABULARY                               │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  WHEEL ROTATION                                             │
│  ├── CW slow      : Navigate down (precision)               │
│  ├── CCW slow     : Navigate up (precision)                 │
│  ├── CW fast      : Scroll with acceleration                │
│  ├── CCW fast     : Scroll with acceleration                │
│  └── While held   : Scrub through track (Now Playing)       │
│                                                             │
│  CENTER BUTTON                                              │
│  ├── Single tap   : Select / Play-Pause                     │
│  ├── Double tap   : Quick Actions menu (radial)             │
│  ├── Hold (500ms) : Context menu (current item)             │
│  └── Hold (2s)    : Lock screen                             │
│                                                             │
│  MENU BUTTON                                                │
│  ├── Single tap   : Back one level                          │
│  ├── Double tap   : Return to Now Playing                   │
│  └── Hold (1s)    : Return to Home                          │
│                                                             │
│  PLAY/PAUSE                                                 │
│  ├── Single tap   : Toggle playback                         │
│  └── Hold (1s)    : Stop and clear queue                    │
│                                                             │
│  FORWARD/BACK                                               │
│  ├── Single tap   : Next/Previous track                     │
│  ├── Hold         : Fast forward/rewind (2x→4x→8x)          │
│  └── Double tap   : Skip 30s forward/back                   │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### Radial Quick Actions Menu

Activated by double-tap center button. Appears as an overlay.

```
                    ┌─────┐
                    │Shuff│
            ┌───────┴─────┴───────┐
            │                     │
       ┌────┤                     ├────┐
       │Loop│    [Album Art]      │Love│
       └────┤                     ├────┘
            │                     │
            └───────┬─────┬───────┘
                    │Queue│
                    └─────┘

    Wheel selects, Center confirms, Menu dismisses
```

```zig
pub const RadialMenu = struct {
    pub const Action = enum {
        shuffle_toggle,
        repeat_toggle,
        add_to_favorites,
        add_to_queue,
    };

    items: [4]Action = .{
        .shuffle_toggle,   // Top
        .add_to_favorites, // Right
        .add_to_queue,     // Bottom
        .repeat_toggle,    // Left
    };
    selected: u2 = 0,

    pub fn rotateSelection(self: *@This(), clockwise: bool) void {
        if (clockwise) {
            self.selected +%= 1;
        } else {
            self.selected -%= 1;
        }
    }

    pub fn draw(self: *const @This(), center_x: u16, center_y: u16) void {
        const radius: u16 = 50;
        const positions = [4][2]i16{
            .{ 0, -radius },   // Top
            .{ radius, 0 },    // Right
            .{ 0, radius },    // Bottom
            .{ -radius, 0 },   // Left
        };

        // Draw semi-transparent overlay
        fillDithered(0, 0, 320, 240, &DitherPatterns.depth_shadow);

        // Draw options
        for (positions, 0..) |pos, i| {
            const x = @as(u16, @intCast(@as(i32, center_x) + pos[0]));
            const y = @as(u16, @intCast(@as(i32, center_y) + pos[1]));
            const is_selected = i == self.selected;

            drawRadialItem(x, y, self.items[i], is_selected);
        }
    }
};
```

---

## IV. Screen Blueprints

### 4.1 Now Playing - The Hero Screen

```
┌─────────────────────────────────────────────────────────────┐
│                    NOW PLAYING BLUEPRINT                    │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  ┌─────────────────────────────────────────────────────┐   │
│  │ 320x240 Canvas                                       │   │
│  │                                                      │   │
│  │  [0,0]──────────────────────────────────[319,0]     │   │
│  │   │                                           │      │   │
│  │   │  ┌─────────────────────────────────────┐ │      │   │
│  │   │  │     WAVEFORM VISUALIZER             │ │      │   │
│  │   │  │     (0,0) to (319,89)               │ │      │   │
│  │   │  │     Height: 90px                    │ │      │   │
│  │   │  │                                     │ │      │   │
│  │   │  │  ▁▂▃▄▅▆▇█▇▆▅▄▃▂▁▂▃▄▅▆▇█▇▆▅▄▃▂▁    │ │      │   │
│  │   │  │                                     │ │      │   │
│  │   │  │  Beat-synced, 32 bars, mirrored     │ │      │   │
│  │   │  └─────────────────────────────────────┘ │      │   │
│  │   │                                           │      │   │
│  │   │  ┌─────────────────────────────────────┐ │      │   │
│  │   │  │     TRACK INFO ZONE                 │ │      │   │
│  │   │  │     (0,90) to (319,159)             │ │      │   │
│  │   │  │                                     │ │      │   │
│  │   │  │  Song Title                         │ │ 16px │   │
│  │   │  │  Artist Name                        │ │ 12px │   │
│  │   │  │  Album • Year                       │ │ 8px  │   │
│  │   │  │                                     │ │      │   │
│  │   │  └─────────────────────────────────────┘ │      │   │
│  │   │                                           │      │   │
│  │   │  ┌─────────────────────────────────────┐ │      │   │
│  │   │  │     PROGRESS + CONTROLS             │ │      │   │
│  │   │  │     (0,160) to (319,239)            │ │      │   │
│  │   │  │                                     │ │      │   │
│  │   │  │   1:24 ━━━━━━━━○──────────── 4:32   │ │      │   │
│  │   │  │                                     │ │      │   │
│  │   │  │       ⏮    ▶/⏸    ⏭              │ │      │   │
│  │   │  │                                     │ │      │   │
│  │   │  │    🔀         ♡          🔁        │ │ State│   │
│  │   │  └─────────────────────────────────────┘ │      │   │
│  │   │                                           │      │   │
│  │  [0,239]────────────────────────────[319,239]│      │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

#### Waveform Visualizer Implementation

```zig
pub const WaveformVisualizer = struct {
    const BAR_COUNT: usize = 32;
    const MAX_HEIGHT: u16 = 70;
    const BAR_WIDTH: u16 = 8;
    const BAR_GAP: u16 = 2;

    bars: [BAR_COUNT]u8 = [_]u8{0} ** BAR_COUNT,
    targets: [BAR_COUNT]u8 = [_]u8{0} ** BAR_COUNT,

    // Energy distribution (bass heavy on sides, mids in center)
    const frequency_weights = comptime blk: {
        var weights: [BAR_COUNT]f32 = undefined;
        for (0..BAR_COUNT) |i| {
            const normalized = @as(f32, @floatFromInt(i)) / BAR_COUNT;
            const center_dist = @abs(normalized - 0.5) * 2.0;
            weights[i] = 1.0 - (center_dist * 0.4); // Center 40% louder
        }
        break :blk weights;
    };

    pub fn update(self: *@This(), audio_level: u8, beat_detected: bool) void {
        // Generate new targets based on audio
        for (&self.targets, 0..) |*target, i| {
            const base = @as(f32, @floatFromInt(audio_level));
            const weighted = base * frequency_weights[i];
            const variance = @as(f32, @floatFromInt(prng() % 30)) - 15;
            const new_target = @as(u8, @intFromFloat(@max(0, @min(100, weighted + variance))));

            // Beat detection boost
            if (beat_detected) {
                target.* = @min(100, new_target + 20);
            } else {
                target.* = new_target;
            }
        }

        // Smooth interpolation
        for (&self.bars, 0..) |*bar, i| {
            const target = self.targets[i];
            if (bar.* < target) {
                // Fast attack (8 units/frame = ~50ms to full)
                bar.* = @min(target, bar.* + 8);
            } else {
                // Slow decay (3 units/frame = ~170ms to zero)
                bar.* = bar.* -| 3;
            }
        }
    }

    pub fn draw(self: *const @This(), y_offset: u16) void {
        const total_width = BAR_COUNT * (BAR_WIDTH + BAR_GAP) - BAR_GAP;
        const start_x = (320 - total_width) / 2;
        const center_y = y_offset + MAX_HEIGHT / 2;

        // Background with subtle texture
        fillDithered(0, y_offset, 320, MAX_HEIGHT + 20, &DitherPatterns.surface_noise);

        for (self.bars, 0..) |bar_value, i| {
            const x = start_x + @as(u16, @intCast(i)) * (BAR_WIDTH + BAR_GAP);
            const height = @as(u16, bar_value) * MAX_HEIGHT / 200; // Half height (mirrored)

            // Mirror effect: bars extend up AND down from center
            const top_y = center_y - height;
            const bottom_y = center_y;

            // Main bar (upper half)
            lcd.fillRect(x, top_y, BAR_WIDTH, height, RetroFlowPalette.electric_cyan);

            // Mirror bar (lower half) - slightly dimmer
            lcd.fillRect(x, bottom_y, BAR_WIDTH, height, RetroFlowPalette.deep_cyan);

            // Glowing tip (brightest point)
            if (height > 2) {
                lcd.fillRect(x, top_y, BAR_WIDTH, 2, RetroFlowPalette.aurora_cyan);
                lcd.fillRect(x, bottom_y + height - 2, BAR_WIDTH, 2, RetroFlowPalette.deep_cyan);
            }
        }
    }
};
```

### 4.2 Home Screen - The Launchpad

```
┌─────────────────────────────────────────────────────────────┐
│                    HOME SCREEN BLUEPRINT                    │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  ┌─────────────────────────────────────────────────────┐   │
│  │                                                      │   │
│  │   ZigPod                                12:34  ●▪▪  │   │
│  │   ─────────────────────────────────────────────────  │   │
│  │                                                      │   │
│  │   ┌─────────────────────────────────────────────┐   │   │
│  │   │  NOW PLAYING (if active)                    │   │   │
│  │   │  ┌────┐                                     │   │   │
│  │   │  │ ▶  │  Here Comes the Sun                 │   │   │
│  │   │  │    │  The Beatles • Abbey Road           │   │   │
│  │   │  └────┘  ━━━━━━━━━━━○───────────            │   │   │
│  │   └─────────────────────────────────────────────┘   │   │
│  │                                                      │   │
│  │   LIBRARY                                     >     │   │
│  │   ─────────────────────────────────────────────     │   │
│  │                                                      │   │
│  │   PLAYLISTS                                   >     │   │
│  │   ─────────────────────────────────────────────     │   │
│  │                                                      │   │
│  │   ▸ SEARCH                                    >     │   │
│  │   ─────────────────────────────────────────────     │   │
│  │                                                      │   │
│  │   SETTINGS                                    >     │   │
│  │                                                      │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                             │
│  Features:                                                  │
│  • Now Playing card only appears when music active          │
│  • Selected item has subtle cyan left border                │
│  • Separator lines are 1px graphite                         │
│  • Battery indicator: ● full, ▪ partial, ○ empty           │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### 4.3 List Views - Unified Pattern

```
┌─────────────────────────────────────────────────────────────┐
│                    LIST VIEW BLUEPRINT                      │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  STANDARD LIST ITEM (40px height)                           │
│  ┌─────────────────────────────────────────────────────┐   │
│  │                                                      │   │
│  │   ┃ Primary Text                             >      │   │
│  │   ┃ Secondary text • metadata                        │   │
│  │   ─────────────────────────────────────────────────  │   │
│  │                                                      │   │
│  │   Legend:                                            │   │
│  │   ┃ = Cyan accent bar (selected only, 3px)          │   │
│  │   > = Chevron (indicates drill-down)                │   │
│  │   ─ = 1px separator (graphite color)                │   │
│  │                                                      │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                             │
│  COMPACT LIST ITEM (32px height - for songs)                │
│  ┌─────────────────────────────────────────────────────┐   │
│  │                                                      │   │
│  │   01  Song Title                            3:45    │   │
│  │   ─────────────────────────────────────────────────  │   │
│  │                                                      │   │
│  │   Legend:                                            │   │
│  │   01 = Track number (pewter, fixed width)           │   │
│  │   3:45 = Duration (pewter, right-aligned)           │   │
│  │                                                      │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                             │
│  ALBUM HEADER (80px height - for album detail)              │
│  ┌─────────────────────────────────────────────────────┐   │
│  │                                                      │   │
│  │   ┌────────┐                                        │   │
│  │   │        │  Album Name                            │   │
│  │   │  ART   │  Artist                                │   │
│  │   │  60x60 │  Year • 12 songs • 48 min              │   │
│  │   └────────┘                                        │   │
│  │   ═════════════════════════════════════════════════  │   │
│  │                                                      │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

---

## V. UX Innovations

### 5.1 Adaptive Context System

```zig
pub const ContextEngine = struct {
    // Time-based patterns (learned over 7 days)
    time_patterns: [24]ContentPreference = undefined,

    // Day-of-week patterns
    dow_patterns: [7]ContentPreference = undefined,

    // Current context
    current_hour: u8,
    current_dow: u8,
    consecutive_skips: u8 = 0,

    pub const ContentPreference = struct {
        prefer_podcasts: u8 = 50,     // 0-100 weight
        prefer_playlists: u8 = 50,
        prefer_albums: u8 = 50,
        prefer_shuffle: bool = false,
        energy_level: u8 = 50,        // Calm (0) to Energetic (100)
    };

    // Called on each track complete
    pub fn recordPlayback(self: *@This(), was_skipped: bool, played_pct: u8) void {
        if (was_skipped) {
            self.consecutive_skips += 1;
            // 3 skips = suggest different content type
            if (self.consecutive_skips >= 3) {
                self.suggestContentPivot();
            }
        } else if (played_pct > 80) {
            self.consecutive_skips = 0;
            // Reinforce current pattern
            self.reinforcePattern();
        }
    }

    // Returns suggested home screen order
    pub fn getAdaptiveHomeOrder(self: *const @This()) [5]HomeItem {
        const pref = self.time_patterns[self.current_hour];

        // Dynamic ordering based on learned preferences
        if (pref.prefer_podcasts > 70) {
            return .{ .podcasts, .now_playing, .library, .playlists, .settings };
        } else if (pref.prefer_playlists > 70) {
            return .{ .playlists, .now_playing, .library, .podcasts, .settings };
        }
        return .{ .now_playing, .library, .playlists, .podcasts, .settings };
    }
};
```

### 5.2 Low Battery Mode

```zig
pub const PowerManager = struct {
    battery_level: u8,  // 0-100

    pub const PowerMode = enum {
        normal,       // Full visuals
        eco,          // Reduced animations, dimmer
        critical,     // Essential only, extend life 15%
    };

    pub fn getMode(self: *const @This()) PowerMode {
        if (self.battery_level <= 10) return .critical;
        if (self.battery_level <= 25) return .eco;
        return .normal;
    }

    pub fn applyMode(mode: PowerMode) void {
        switch (mode) {
            .normal => {
                lcd.setBrightness(100);
                visualizer_enabled = true;
                animation_speed = 1.0;
            },
            .eco => {
                lcd.setBrightness(60);
                visualizer_enabled = true;
                animation_speed = 0.5;  // Half framerate
            },
            .critical => {
                lcd.setBrightness(30);
                visualizer_enabled = false;  // Static display
                animation_speed = 0;
                // Simplified Now Playing: text only
            },
        }
    }
};
```

### 5.3 Eyes-Free Mode (Jogging/Pocket)

```zig
pub const EyesFreeMode = struct {
    enabled: bool = false,

    // Audio feedback for all actions
    pub fn onNavigate(direction: enum { up, down }) void {
        if (!enabled) return;
        // Soft tick sound (different pitch for direction)
        audio.playSystemSound(if (direction == .up) .tick_high else .tick_low);
    }

    pub fn onSelect(item_name: []const u8) void {
        if (!enabled) return;
        // Announce selection via text-to-speech or pre-recorded
        tts.speak(item_name);
    }

    pub fn onBoundary() void {
        if (!enabled) return;
        // Double-tick at list boundaries
        audio.playSystemSound(.tick_boundary);
    }

    // Gesture: Hold Menu + rotate wheel = volume (no screen needed)
    pub fn handleBlindVolume(wheel_delta: i8) void {
        const new_vol = @as(i16, volume) + wheel_delta * 2;
        volume = @intCast(@max(0, @min(100, new_vol)));
        // Audio feedback: short tone at current volume
        audio.playVolumeFeedback(volume);
    }
};
```

### 5.4 Quick Search (Triple-Click Center)

```
┌─────────────────────────────────────────────────────────────┐
│                    QUICK SEARCH OVERLAY                     │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  ┌─────────────────────────────────────────────────────┐   │
│  │                                                      │   │
│  │      ╔═══════════════════════════════════╗          │   │
│  │      ║  A B C D E F G H I J K L M        ║          │   │
│  │      ║  N O P Q R S T U V W X Y Z        ║          │   │
│  │      ║  0 1 2 3 4 5 6 7 8 9 ⌫ ✓         ║          │   │
│  │      ╚═══════════════════════════════════╝          │   │
│  │                                                      │   │
│  │      Search: BEA_                                    │   │
│  │      ─────────────────────────────                  │   │
│  │                                                      │   │
│  │      > The Beatles           (Artist)               │   │
│  │        Beat It               (Song)                 │   │
│  │        Heartbeat             (Album)                │   │
│  │                                                      │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                             │
│  Interaction:                                               │
│  • Wheel rotates through character grid                     │
│  • Center selects character                                 │
│  • Results update live after 2+ characters                  │
│  • Select result to navigate directly                       │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

---

## VI. Animation Specifications

All animations must complete in ≤2 frames (33ms at 60fps) or use smooth interpolation.

### Allowed Transitions

| Transition | Duration | Easing | Frames |
|------------|----------|--------|--------|
| Selection highlight | Instant | None | 1 |
| Screen push/pop | 100ms | Linear | 2 |
| Progress bar | Continuous | Linear | N/A |
| Visualizer bars | 16ms | Custom curve | 1 |
| Fade out (sleep) | 500ms | Ease-out | 10 |

### Forbidden

- Sliding animations longer than 100ms
- Bounce/spring effects
- Parallax scrolling
- Alpha blending (no hardware support)
- Blur effects

---

## VII. Implementation Roadmap

### Phase 1: Foundation (Core Visual System)

```
Files to modify:
├── src/ui/theme.zig          # RetroFlow color palette
├── src/ui/draw.zig           # Dither patterns, micro-textures
└── src/demo/ui_demo.zig      # Reference implementation
```

**Tasks:**
1. Implement RetroFlowPalette constants
2. Add comptime dither pattern generation
3. Update all screens to new color system
4. Add accessibility mode toggle

### Phase 2: Navigation Evolution

```
Files to create/modify:
├── src/input/wheel.zig       # Acceleration curves
├── src/input/gestures.zig    # Multi-tap detection
└── src/ui/radial_menu.zig    # Quick actions overlay
```

**Tasks:**
1. Implement WheelAcceleration with velocity tracking
2. Add double-tap and hold gesture detection
3. Create radial menu component
4. Wire gestures to actions

### Phase 3: Now Playing Transcendence

```
Files to create/modify:
├── src/ui/visualizer.zig     # Waveform visualizer
├── src/ui/now_playing.zig    # Hero screen layout
└── src/audio/beat_detect.zig # Simple beat detection
```

**Tasks:**
1. Implement WaveformVisualizer with mirrored bars
2. Add beat detection from audio buffer
3. Create progress scrubbing with wheel
4. Add album art dithering for 16-bit

### Phase 4: Adaptive Intelligence

```
Files to create/modify:
├── src/core/context.zig      # Learning engine
├── src/core/power.zig        # Battery optimization
└── src/config/user_prefs.zig # Persistent patterns
```

**Tasks:**
1. Time-based pattern tracking
2. Low battery mode implementation
3. Eyes-free audio feedback
4. Adaptive home screen ordering

---

## VIII. Verification Protocol

### Visual Regression Tests

```zig
test "RetroFlow palette contrast ratios" {
    // WCAG AA requires 4.5:1 for normal text
    const white_on_obsidian = contrastRatio(
        RetroFlowPalette.pure_white,
        RetroFlowPalette.obsidian
    );
    try std.testing.expect(white_on_obsidian >= 21.0); // Perfect contrast

    const silver_on_carbon = contrastRatio(
        RetroFlowPalette.silver,
        RetroFlowPalette.carbon
    );
    try std.testing.expect(silver_on_carbon >= 4.5);
}

test "Dither pattern pixel alignment" {
    // Ensure patterns don't create visible moire on LCD
    const pattern = DitherPatterns.surface_noise;
    // All variations should be within 2 brightness levels
    const max_diff = maxBrightnessDelta(pattern);
    try std.testing.expect(max_diff <= 8); // ~3% brightness variation
}
```

### Performance Benchmarks

```zig
test "Now Playing render time < 50ms" {
    const start = std.time.milliTimestamp();

    var viz = WaveformVisualizer{};
    viz.update(75, true);
    viz.draw(0);
    drawNowPlayingInfo();
    drawProgressBar();
    lcd.update();

    const elapsed = std.time.milliTimestamp() - start;
    try std.testing.expect(elapsed < 50);
}

test "Full screen redraw < 16ms" {
    // Must maintain 60fps
    const start = std.time.milliTimestamp();
    redrawCurrentScreen();
    const elapsed = std.time.milliTimestamp() - start;
    try std.testing.expect(elapsed < 16);
}
```

---

## IX. Questions for Further Perfection

1. **Visualizer Depth**: Should the waveform respond to actual audio frequency bands (requires FFT, ~2KB overhead) or continue with simulated energy levels?

2. **Album Art Rendering**: Implement 4-color dithered album art thumbnails (requires image decoder) or use genre-based procedural patterns?

3. **Haptic Vocabulary**: Define specific vibration patterns for genres (e.g., bass pulse for electronic, gentle roll for classical)?

4. **Search Priority**: Should search results prioritize recently played, alphabetical, or popularity-weighted ordering?

5. **Screen Timeout Behavior**: Fade to visualizer-only mode or full black with album art silhouette?

6. **Wheel Dead Zone**: Current 0-sensitivity threshold—should there be a configurable dead zone for users with tremors?

7. **Color Blind Modes**: Implement deuteranopia, protanopia, and tritanopia variants, or single "high contrast" mode?

---

*"The best interface is no interface. The second best is one that anticipates your next thought."*

— RetroFlow Design Principles, v2.0
