# ZigPod Audio System Architecture

This document describes the audio playback system architecture, including the interrupt-driven DMA pipeline for gapless audio output.

## Overview

The ZigPod audio system provides high-quality audio playback with:
- **Interrupt-driven DMA output** for glitch-free playback
- **Double-buffered architecture** for seamless buffer transitions
- **Gapless playback** between tracks
- **DSP processing** (EQ, bass boost, stereo widening, volume ramping)
- **Multiple decoder support** (WAV, MP3 implemented; FLAC, AAC planned)
- **ID3 tag parsing** for MP3 metadata (title, artist, album)

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           ZigPod Audio System                               │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌─────────────┐     ┌─────────────┐     ┌─────────────┐                   │
│  │   File      │     │   Decoder   │     │   Decoder   │                   │
│  │   System    │────►│   (WAV)     │     │   (MP3)     │                   │
│  │   (FAT32)   │     └──────┬──────┘     └──────┬──────┘                   │
│  └─────────────┘            │                   │                          │
│                             └─────────┬─────────┘                          │
│                                       ▼                                    │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                        Audio Engine                                  │   │
│  │  ┌─────────────────────────────────────────────────────────────┐    │   │
│  │  │                     Decoder Slots                            │    │   │
│  │  │  ┌──────────────┐              ┌──────────────┐             │    │   │
│  │  │  │   Slot 0     │              │   Slot 1     │             │    │   │
│  │  │  │ (active)     │              │ (next track) │             │    │   │
│  │  │  │ Ring Buffer  │              │ Ring Buffer  │             │    │   │
│  │  │  └──────┬───────┘              └──────────────┘             │    │   │
│  │  └─────────┼───────────────────────────────────────────────────┘    │   │
│  │            ▼                                                        │   │
│  │  ┌─────────────────────────────────────────────────────────────┐    │   │
│  │  │                     DSP Chain                                │    │   │
│  │  │  [Equalizer] → [Bass Boost] → [Stereo Width] → [Volume]     │    │   │
│  │  └─────────────────────────────────┬───────────────────────────┘    │   │
│  └────────────────────────────────────┼────────────────────────────────┘   │
│                                       ▼                                    │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                      DMA Audio Pipeline                              │   │
│  │                                                                      │   │
│  │   ┌──────────────┐    ┌──────────────┐    ┌──────────────┐         │   │
│  │   │  DMA Buffer  │    │     DMA      │    │    I2S TX    │         │   │
│  │   │      A       │───►│  Channel 0   │───►│    FIFO      │──► DAC  │   │
│  │   │   (8 KB)     │    │              │    │              │         │   │
│  │   └──────────────┘    └──────────────┘    └──────────────┘         │   │
│  │          ▲                    │                                     │   │
│  │          │ (refill)           │ (FIQ on complete)                   │   │
│  │          │                    ▼                                     │   │
│  │   ┌──────────────┐    ┌──────────────┐                             │   │
│  │   │  DMA Buffer  │◄───│  FIQ Handler │                             │   │
│  │   │      B       │    │  (swap buf)  │                             │   │
│  │   │   (8 KB)     │    └──────────────┘                             │   │
│  │   └──────────────┘                                                  │   │
│  │                                                                      │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Components

### 1. Audio Engine (`src/audio/audio.zig`)

The main entry point for audio playback. Responsibilities:
- File loading and format detection
- Decoder management (WAV, MP3, etc.)
- Playback control (play, pause, stop, seek)
- Volume control (hardware codec + DSP)
- Gapless playback coordination

**Key Functions:**
```zig
pub fn loadFile(path: []const u8) LoadError!void
pub fn play(callback: DecodeCallback, track_info: TrackInfo) HalError!void
pub fn stop() void
pub fn pause() void
pub fn resumePlayback() void
pub fn setVolume(left_db: i16, right_db: i16) HalError!void
pub fn process() HalError!void  // Call from main loop
```

### 2. DMA Audio Pipeline (`src/audio/dma_pipeline.zig`)

Provides interrupt-driven audio output using DMA with double-buffering.

**Architecture:**
- Two 8KB buffers (2048 stereo samples each)
- At 44.1kHz: ~46ms per buffer, ~92ms total latency tolerance
- FIQ (Fast Interrupt) for lowest latency buffer swapping
- Main loop handles buffer refill (not in interrupt context)

**Key Features:**
- **Double Buffering**: While one buffer plays via DMA, the other is being refilled
- **FIQ Handler**: Swaps buffers instantly when DMA completes, sets refill flag
- **Main Loop Processing**: Refills buffers marked by FIQ (heavy work outside interrupt)
- **Graceful Degradation**: Falls back to polling mode if DMA fails

**Configuration Constants:**
```zig
pub const BUFFER_SAMPLES: usize = 2048;  // ~46ms at 44.1kHz
pub const BUFFER_BYTES: usize = BUFFER_SAMPLES * 2 * @sizeOf(i16);  // 8KB
pub const NUM_BUFFERS: usize = 2;  // Double buffering
pub const AUDIO_DMA_CHANNEL: u2 = 0;
```

**Buffer Timing:**
| Sample Rate | Buffer Duration | Total Latency |
|-------------|-----------------|---------------|
| 44.1 kHz    | 46.4 ms         | 92.8 ms       |
| 48.0 kHz    | 42.7 ms         | 85.4 ms       |
| 96.0 kHz    | 21.3 ms         | 42.6 ms       |

### 3. Interrupt Controller (`src/hal/pp5021c/interrupts.zig`)

Low-level interrupt controller access for the PP5021C SoC.

**Features:**
- IRQ/FIQ routing configuration
- Critical sections with nesting support
- Interrupt statistics tracking
- Source enable/disable

**Audio-specific Functions:**
```zig
pub fn configureAudioFiq() void     // Route I2S+DMA to FIQ
pub fn routeToFiq(source: IrqSource) void
pub fn enableSource(source: IrqSource) void
pub fn enterCritical() void         // Disable IRQ, save state
pub fn exitCritical() void          // Restore IRQ state
```

### 4. Boot FIQ Handler (`src/kernel/boot.zig`)

The ARM FIQ entry point that dispatches to the DMA pipeline.

```zig
export fn handleFiq() void {
    const status = reg.readReg(u32, reg.CPU_INT_STAT);

    // Check if this is an audio-related interrupt (DMA or I2S)
    const audio_mask = reg.DMA_IRQ | reg.IIS_IRQ;
    if ((status & audio_mask) != 0) {
        dma_pipeline.handleAudioFiq();
        return;
    }
    // Handle other FIQ sources...
}
```

## Data Flow

### Playback Start Sequence

```
1. User selects file in UI
         │
         ▼
2. audio.loadFile(path)
   - Read file from FAT32
   - Detect format (WAV/MP3/etc)
   - Initialize decoder
         │
         ▼
3. audio.play(callback, track_info)
   - Configure I2S sample rate
   - Set up decoder slot
   - Pre-fill decoder ring buffer
   - Start DMA pipeline
         │
         ▼
4. dma_pipeline.start(dmaFillCallback)
   - Pre-fill both DMA buffers
   - Configure DMA channel for I2S TX
   - Enable FIQ for DMA/I2S
   - Start first DMA transfer
         │
         ▼
5. Main loop: audio.process()
   - Fill decoder slot buffer from decoder
   - Call dma_pipeline.process()
     - Check for buffers needing refill
     - Fill from decoder slot via callback
```

### FIQ Handler Flow (Time-Critical)

```
DMA Transfer Complete Interrupt
         │
         ▼
fiqHandler_arm (boot.zig)
   - Save registers (r0-r7, lr)
   - Call handleFiq()
         │
         ▼
handleFiq() (boot.zig)
   - Read interrupt status
   - Check DMA_IRQ | IIS_IRQ
         │
         ▼
handleAudioFiq() (dma_pipeline.zig)
   - Clear interrupt sources
   - Update samples_played counter
   - Mark current buffer for refill
   - Swap active_buffer (0↔1)
   - Start DMA on next buffer
   - Return (< 10µs total)
         │
         ▼
   - Restore registers
   - Return from FIQ
```

### Main Loop Processing (Non-Time-Critical)

```
Main Loop Iteration
         │
         ▼
audio.process()
   - Fill decoder slot ring buffer
         │
         ▼
dma_pipeline.process()
   - For each buffer:
     - If buffer_needs_refill[i]:
       - Enter critical section
       - Clear refill flag
       - Exit critical section
       - Call fill_callback(buffer)
         - Read from decoder slot
         - Apply DSP processing
```

## Memory Layout

### DMA Buffers

```
SDRAM (Cached):     0x10000000 - 0x12000000
SDRAM (Uncached):   0x30000000 - 0x32000000  ← DMA buffers here

DMA Buffer A:  0x30xxxxxx (8KB, 32-byte aligned)
DMA Buffer B:  0x30xxxxxx + 0x2000 (8KB, 32-byte aligned)
```

DMA buffers use the uncached memory alias to ensure coherency between CPU writes and DMA reads.

## Gapless Playback

The audio engine supports gapless playback between tracks using dual decoder slots:

1. **Slot 0 (Active)**: Currently playing track
2. **Slot 1 (Next)**: Pre-buffered next track

**Gapless Transition:**
```
1. Track nears end (remaining < threshold)
2. Request next track from playlist
3. Load next track into Slot 1
4. Pre-fill Slot 1 buffer
5. When Slot 0 buffer empties:
   - Switch active_slot to 1
   - Clear Slot 0
   - Seamless transition, no gap
```

**Storage-Aware Pre-buffering:**
- HDD: 2000ms pre-buffer (handle seek latency)
- Flash (iFlash): 500ms pre-buffer (faster access)

## Error Handling

### Buffer Underrun

If the main loop can't keep up with buffer refills:
1. FIQ marks buffer for refill
2. Main loop doesn't refill in time
3. DMA starts playing unfilled buffer
4. `buffer_underruns` counter increments
5. Silence is output (zeros in buffer)

**Mitigation:**
- Large buffers (46ms each) provide tolerance
- High-priority audio processing in main loop
- Storage pre-fetching reduces I/O latency

### DMA Failure

If DMA initialization or transfer fails:
1. `dma_pipeline.start()` returns error
2. Audio engine logs warning
3. Falls back to polling-based I2S writes
4. Playback continues (with higher CPU usage)

## Performance Characteristics

| Metric | Value |
|--------|-------|
| FIQ Latency | < 10µs |
| Buffer Refill Time | ~1-5ms |
| CPU Usage (DMA mode) | < 30% |
| CPU Usage (Polling mode) | ~50% |
| Maximum Bitrate | 1411 kbps (CD quality) |

## API Reference

### DMA Pipeline

```zig
// Initialization
pub fn init() void
pub fn deinit() void

// Playback Control
pub fn start(callback: FillCallback) !void
pub fn stop() void
pub fn pause() void
pub fn unpause() void

// Status
pub fn isRunning() bool
pub fn isPaused() bool

// Main Loop
pub fn process() void  // Call regularly from main loop

// Statistics
pub fn getSamplesPlayed() u64
pub fn getPositionMs() u64
pub fn getUnderrunCount() u32
pub fn getFiqCount() u32
pub fn resetStats() void
```

### Audio Engine (DMA-related)

```zig
// DMA Mode Control
pub fn setDmaMode(enabled: bool) void  // Before init()
pub fn isDmaMode() bool
pub fn isDmaRunning() bool
pub fn getDmaPositionMs() u64
pub fn getDmaStats() struct { fiq_count: u32, underruns: u32, samples_played: u64 }
```

## Files Reference

| File | Purpose |
|------|---------|
| `src/audio/audio.zig` | Audio engine, playback control |
| `src/audio/dma_pipeline.zig` | DMA double-buffering, FIQ handler |
| `src/audio/dsp.zig` | DSP effects chain |
| `src/audio/decoders/wav.zig` | WAV decoder |
| `src/audio/decoders/mp3.zig` | MP3 decoder (native Zig) |
| `src/audio/decoders/mp3_tables.zig` | MP3 decoder lookup tables |
| `src/audio/decoders/id3.zig` | ID3v1/ID3v2 tag parser |
| `src/hal/pp5021c/interrupts.zig` | Interrupt controller |
| `src/kernel/boot.zig` | FIQ entry point |
| `src/drivers/audio/i2s.zig` | I2S driver |
| `src/drivers/audio/codec.zig` | WM8758 codec driver |

## MP3 Decoder

The MP3 decoder is a native Zig implementation supporting MPEG-1/2/2.5 Layer III audio.

### Features

- **Full MPEG Layer III support**: MPEG-1 (44.1/48/32 kHz), MPEG-2 (22.05/24/16 kHz), MPEG-2.5 (11.025/12/8 kHz)
- **All bitrates**: 32-320 kbps for MPEG-1, 8-160 kbps for MPEG-2/2.5
- **Stereo modes**: Stereo, Joint Stereo (MS/Intensity), Dual Channel, Mono
- **Bit reservoir**: Full support for MP3's bit reservoir for VBR efficiency
- **Fast IMDCT**: Optimized 36-point IMDCT using symmetry exploitation

### Decoding Pipeline

```
┌─────────────┐    ┌─────────────┐    ┌─────────────┐    ┌─────────────┐
│   Frame     │───►│    Side     │───►│   Huffman   │───►│ Requantize  │
│   Header    │    │    Info     │    │   Decode    │    │             │
└─────────────┘    └─────────────┘    └─────────────┘    └──────┬──────┘
                                                                │
┌─────────────┐    ┌─────────────┐    ┌─────────────┐    ┌──────▼──────┐
│  Synthesis  │◄───│   IMDCT +   │◄───│  Antialias  │◄───│   Stereo    │
│  Filterbank │    │   Window    │    │             │    │  Process    │
└──────┬──────┘    └─────────────┘    └─────────────┘    └─────────────┘
       │
       ▼
┌─────────────┐
│  16-bit PCM │
│   Output    │
└─────────────┘
```

### ID3 Tag Parsing

The ID3 parser (`src/audio/decoders/id3.zig`) extracts metadata from MP3 files:

**Supported Tag Versions:**
- ID3v1 (128 bytes at end of file)
- ID3v1.1 (with track number)
- ID3v2.2, ID3v2.3, ID3v2.4 (at beginning of file)

**Extracted Metadata:**
| Field | ID3v2 Frame | Description |
|-------|-------------|-------------|
| Title | TIT2/TT2 | Track title |
| Artist | TPE1/TP1 | Artist name |
| Album | TALB/TAL | Album name |
| Year | TYER/TDRC | Release year |
| Track | TRCK/TRK | Track number |

**Text Encodings Supported:**
- ISO-8859-1 (Latin-1)
- UTF-16 with BOM
- UTF-16BE
- UTF-8

### Usage

```zig
const audio = @import("audio/audio.zig");

// Load and play MP3 file (metadata auto-extracted)
try audio.loadFile("/MUSIC/song.mp3");

// Get extracted metadata
const info = audio.getLoadedTrackInfo();
const title = info.getTitle();   // From ID3 or filename
const artist = info.getArtist(); // From ID3 or "Unknown Artist"
const album = info.getAlbum();   // From ID3 or "Unknown Album"
```

### Performance

| Metric | Value |
|--------|-------|
| Decode Time (per frame) | ~2-3ms |
| Memory Usage | ~12 KB |
| Supported Bitrates | 32-320 kbps |
| CPU Usage (128kbps MP3) | ~15-20% |

## Testing

Run audio system tests:
```bash
zig build test
```

Test in simulator:
```bash
zig build sim
./zig-out/bin/zigpod-sim
```

## Troubleshooting

### No Audio Output
1. Check codec initialization in logs
2. Verify I2S sample rate matches track
3. Check DMA is running: `audio.isDmaRunning()`
4. Check for underruns: `audio.getUnderrunCount()`

### Audio Glitches/Clicks
1. Check underrun count - if increasing, main loop is too slow
2. Reduce DSP processing if enabled
3. Check storage I/O latency (use flash for lower latency)

### High CPU Usage
1. Verify DMA mode is active (not polling fallback)
2. Check decoder efficiency
3. Profile main loop processing time
