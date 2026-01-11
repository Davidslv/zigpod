# ZigPod Audiophile Vision

## Mission Statement

**ZigPod aims to be the best audiophile operating system for iPod Classic hardware.**

The primary goal is high-quality audio playback - no bloat, no compromises on sound quality. Every architectural decision should prioritize audio fidelity.

---

## Core Principles

### 1. Audio Quality First
- Bit-perfect output when possible
- No unnecessary resampling
- Proper dithering with noise shaping for bit-depth reduction
- High-resolution audio support (24-bit and beyond)

### 2. Simplicity Over Features
- Focus on doing fewer things excellently
- No feature creep
- Clean, maintainable codebase

### 3. Hardware Respect
- Utilize the WM8758 DAC's full capabilities
- Proper I2S configuration for optimal signal path
- Minimize jitter and timing issues

---

## User Preferences (January 2025)

These preferences guide development priorities:

### Codec Support
| Format | Priority | Status |
|--------|----------|--------|
| WAV (PCM) | CRITICAL | Implemented |
| AIFF | CRITICAL | Implemented |
| FLAC | HIGH | Framework exists |
| MP3 | HIGH | Framework exists |
| Opus | NOT WANTED | - |
| Vorbis | NOT WANTED | - |
| APE | NOT WANTED | - |
| WavPack | NOT WANTED | - |

**Rationale**: Focus on the formats that matter for audiophile use cases. WAV/AIFF for uncompressed, FLAC for lossless compression, MP3 for legacy library compatibility.

### Audio Features Priority

| Feature | Priority | Notes |
|---------|----------|-------|
| 24-bit+ High Resolution | HIGHLY IMPORTANT | Native 24-bit path to DAC |
| LAME/iTunes Gapless | YES | Parse encoder delay/padding metadata |
| Crossfeed DSP | YES | Reduce stereo fatigue on headphones |
| Proper Dithering | YES | TPDF or shaped dither for bit reduction |
| Noise Shaping | YES | Push quantization noise above audible range |
| Performance Optimization | AFTER WORKING | Get it working first, optimize second |

---

## Audiophile Features Roadmap

### 1. High Resolution Audio (24-bit+)

**Goal**: Preserve full dynamic range of high-resolution recordings.

**Implementation Requirements**:
- 24-bit sample path through entire pipeline
- No truncation to 16-bit until final DAC output (if required)
- Proper dithering when reducing bit depth
- Support for 88.2kHz, 96kHz, 176.4kHz, 192kHz sample rates

**WM8758 DAC Capabilities**:
- 24-bit input via I2S
- Internal 24-bit DAC
- Sample rates up to 96kHz native

### 2. Gapless Playback with Encoder Metadata

**Goal**: Seamless playback with proper handling of encoder delay.

**LAME MP3 Gapless**:
- Parse LAME header in Xing/Info frame
- Extract encoder delay (samples to skip at start)
- Extract padding (samples to skip at end)
- Typical values: ~576 sample delay, variable padding

**iTunes AAC Gapless**:
- Parse iTunSMPB atom
- Format: `00000000 XXXXXXXX YYYYYYYY ZZZZZZZZ...`
- X = encoder delay, Y = padding, Z = total samples

**Implementation**:
```
Current ZigPod approach: Dual-slot prebuffering (decode ahead)
Enhancement needed: Parse encoder metadata for sample-accurate trimming
```

### 3. Crossfeed DSP

**Goal**: Reduce listening fatigue from extreme stereo separation.

**What It Does**:
- Blends a portion of left channel into right (and vice versa)
- Applies slight delay and filtering to simulate speaker crosstalk
- Makes headphone listening more natural (speaker-like)

**Parameters to Implement**:
- Crossfeed level (percentage of bleed)
- Delay (typically 200-700 microseconds)
- High-frequency rolloff (mimics HRTF)

**Reference**: Bauer stereophonic-to-binaural DSP, bs2b library

### 4. Dithering and Noise Shaping

**Goal**: Preserve audio quality when reducing bit depth.

**Current State**: Basic truncation or rounding

**Required Improvements**:

**TPDF Dithering (Triangular Probability Density Function)**:
- Add 2 LSBs of triangular-distributed random noise
- Eliminates correlation between signal and quantization error
- Standard for professional audio

**Noise Shaping**:
- Shape quantization noise spectrum
- Push noise energy to less audible frequencies (above 10kHz)
- Popular curves: F-weighted, modified E-weighted

**When Applied**:
- 24-bit to 16-bit conversion (if DAC limited to 16-bit)
- 32-bit float to integer conversion
- Any bit-depth reduction in the pipeline

### 5. FLAC Seeking

**Goal**: Fast, sample-accurate seeking in FLAC files.

**Current State**: Framework exists but seeking incomplete

**Required Implementation**:
- Parse SEEKTABLE metadata block
- Build seek table index: sample number → byte offset
- Binary search for target sample
- Decode from nearest seek point

**Seek Table Format**:
```
For each seek point:
  - Sample number (8 bytes)
  - Byte offset from first frame (8 bytes)
  - Number of samples in frame (2 bytes)
```

---

## Rockbox vs ZigPod Audio Comparison

Analysis performed January 2025 comparing audio subsystems.

### Rockbox Strengths (To Learn From)

| Area | Rockbox Approach | ZigPod Gap |
|------|------------------|------------|
| Gapless | Metadata parsing (LAME, iTunes) | Need to implement metadata parsing |
| Dithering | TPDF implementation exists | Need proper dithering |
| Crossfeed | Full bs2b implementation | Framework only |
| Codec Maturity | 20+ years of testing | Newer, less tested |
| Seeking | Sample-accurate with seek tables | Needs completion |

### ZigPod Strengths (To Preserve)

| Area | ZigPod Approach | Notes |
|------|-----------------|-------|
| Architecture | Dual-slot prebuffering | Modern design for gapless |
| Code Quality | Clean Zig implementation | More maintainable |
| Type Safety | Compile-time guarantees | Fewer runtime bugs |
| Simplicity | Focused feature set | Easier to audit |

### Comparison: Gapless Architecture

**Rockbox**:
- Single buffer with metadata-based trimming
- Parses LAME header for encoder delay/padding
- Calculates exact sample count to play
- Mature, well-tested

**ZigPod**:
- Dual decoder slots (A/B alternating)
- Prebuffers next track during playback
- Seamless buffer handoff
- Modern approach, but needs metadata parsing

**Recommendation**: Keep ZigPod's dual-slot architecture, add Rockbox's metadata parsing.

### Comparison: DSP Pipeline

**Rockbox**:
- Full DSP chain: EQ, crossfeed, stereo width, compressor
- 32-bit fixed-point processing
- Optimized ARM assembly for critical paths
- TPDF dither available

**ZigPod**:
- 5-band EQ framework
- Bass boost, stereo widening stubs
- Needs dithering implementation
- Needs crossfeed implementation

**Recommendation**: Implement TPDF dithering and crossfeed before other DSP features.

---

## Technical Implementation Notes

### WM8758 DAC Configuration for Best Quality

```zig
// Optimal I2S configuration
const WM8758_CONFIG = .{
    .format = .i2s,           // Standard I2S
    .word_length = .bits_24,  // 24-bit samples
    .sample_rate = .sr_44100, // or 48000, 96000
    .mclk_div = .div_1,       // Full MCLK
    .bclk_div = .div_4,       // BCLK = MCLK/4
    .dac_oversample = .x128,  // 128x oversampling
    .dac_soft_mute = false,
    .dac_auto_mute = false,   // Don't mute on zeros
};

// Analog path for headphones
const ANALOG_CONFIG = .{
    .hp_volume = 0x39,        // 0dB
    .hp_mute = false,
    .hp_zc = true,            // Zero-cross for clicks
    .vmid = .r50k,            // VMID reference
    .bias = .normal,          // Normal bias current
};
```

### Audio Pipeline Data Flow

```
Storage (FAT32)
    │
    ▼
Decoder (WAV/FLAC/MP3)
    │ 24-bit PCM
    ▼
DSP Chain
    ├── Volume
    ├── EQ (5-band)
    ├── Crossfeed
    └── Stereo Width
    │ 24-bit PCM
    ▼
Dither + Noise Shape (if needed)
    │ 24-bit (or 16-bit if DAC limited)
    ▼
DMA Buffer (double-buffered)
    │
    ▼
I2S TX → WM8758 DAC → Headphones
```

### Sample Rate Handling

| Source Rate | DAC Rate | Resample? | Notes |
|-------------|----------|-----------|-------|
| 44100 Hz | 44100 Hz | No | Bit-perfect CD playback |
| 48000 Hz | 48000 Hz | No | Bit-perfect DVD audio |
| 88200 Hz | 44100 Hz | Yes | 2x downsample (simple) |
| 96000 Hz | 48000 Hz | Yes | 2x downsample (simple) |
| 176400 Hz | 44100 Hz | Yes | 4x downsample |
| 192000 Hz | 48000 Hz | Yes | 4x downsample |

**Principle**: Avoid resampling when possible. Integer ratio downsampling preferred.

---

## Quality Verification

### Test Files to Use

1. **Bit-perfect test**:
   - 1kHz sine wave, 16-bit, 44.1kHz
   - Verify no artifacts or level changes

2. **Dynamic range test**:
   - -90dB fade test tone
   - Should be audible, clean

3. **Stereo imaging test**:
   - Phase test (mono compatibility)
   - Channel identification (left/right)

4. **Gapless test**:
   - Album with continuous audio across tracks
   - Pink Floyd, classical, live albums

5. **High-res test**:
   - 24-bit/96kHz FLAC
   - Verify no truncation artifacts

### Measurement Tools

- Spectrum analyzer (FFT)
- Phase correlation meter
- True peak meter
- THD+N measurement

---

## Development Priority Order

Based on user preferences and audiophile goals:

1. **Get basic playback working on hardware** (current blocker: MBR signature issue)
2. **Implement proper dithering** (TPDF)
3. **Add LAME/iTunes gapless metadata parsing**
4. **Complete FLAC seeking**
5. **Implement crossfeed DSP**
6. **Add noise shaping options**
7. **Performance optimization** (only after everything works)

---

## References

### Technical Standards
- AES17: Measurement of digital audio equipment
- ITU-R BS.1770: Loudness measurement
- EBU R128: Loudness normalization

### Audiophile Resources
- Hydrogen Audio Wiki (hydrogenaudio.org)
- Bob Katz - Mastering Audio
- Ethan Winer - The Audio Expert

### Implementation References
- Rockbox source code (~/projects/rockbox)
- bs2b crossfeed library
- SoX resampling algorithms

---

## Document History

- **January 11, 2025**: Initial creation based on user preferences discussion
- Direction confirmed: Best audiophile operating system
- User explicitly declined: Opus, Vorbis, APE, WavPack codec support
- User explicitly requested: Gapless, crossfeed, dithering, 24-bit support
