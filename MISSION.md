# ZigPod Mission Statement

## What We're Building

**ZigPod is the audiophile's operating system for iPod Classic.**

A from-scratch firmware written in Zig, focused exclusively on delivering the highest quality music playback experience. Nothing else.

## Core Principles

### 1. Audio Quality Above All

- Bit-perfect output to the Wolfson WM8758 DAC
- Support for audiophile formats: FLAC, WAV, AIFF, MP3 at full resolution
- **High resolution priority**: 24-bit audio is highly important
- No resampling unless absolutely necessary
- Clean signal path with minimal processing

**Audiophile Features** (decided January 2025):
- TPDF dithering with noise shaping
- LAME/iTunes gapless metadata parsing
- Crossfeed DSP for headphone listening
- Sample-accurate FLAC seeking

### 2. No Bloat

- No video playback
- No games
- No photos
- No podcasts
- No apps

Just music. Done right.

### 3. Efficiency

- Match or exceed Apple's 25-30 hour battery life
- Sub-second boot time
- Minimal CPU usage during playback (<15%)
- Aggressive power management

### 4. Simplicity

- Clean, intuitive interface
- Fast navigation through large libraries
- One purpose, executed perfectly

## Target Hardware

iPod Video 5th Generation (2005) and 5.5th Generation (2006)
- PortalPlayer PP5021C/PP5024 SoC
- Wolfson WM8758 DAC
- 320x240 LCD
- Click wheel with 5 buttons
- 30-80GB storage (HDD or flash mod)

## What Success Looks Like

An audiophile picks up their iPod Classic running ZigPod. They navigate to an album, press play, and hear their music exactly as it was mastered. The battery lasts all day. The interface stays out of the way. The device does one thing, and does it better than anything else.

## Non-Goals

- Rockbox compatibility
- Plugin system
- Skinning/themes beyond basics
- Feature parity with Apple firmware
- Support for other iPod models (6G/7G use different SoC)

## The Standard

Every decision should be measured against: **Does this make the music sound better or the experience simpler?**

If the answer is no, we don't need it.

---

*See [docs/AUDIOPHILE_VISION.md](docs/AUDIOPHILE_VISION.md) for detailed technical implementation plans.*
