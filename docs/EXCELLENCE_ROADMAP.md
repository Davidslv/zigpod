# ZigPod Excellence Roadmap

**Status**: In Progress
**Target**: Overall Assessment 9/10
**Current Score**: 5.5/10
**Last Updated**: 2026-01-09

---

## Executive Summary

This document tracks ZigPod's journey from a promising prototype (5.5/10) to a shippable, audiophile-quality iPod OS (9/10). Every decision is documented, every fix is justified, and progress is measured against the Supreme Architect's exacting standards.

---

## Assessment Breakdown

| Domain | Current | Target | Status |
|--------|---------|--------|--------|
| Architecture | 8/10 | 9/10 | In Progress |
| Audio Core | 7/10 | 9/10 | In Progress |
| UI/UX | 8/10 | 9/10 | In Progress |
| Testing | 5/10 | 9/10 | Pending |
| Error Handling | 3/10 | 9/10 | Pending |
| Hardware Ready | 2/10 | 8/10 | Pending |
| **OVERALL** | **5.5/10** | **9/10** | **In Progress** |

---

## Critical Issues (P0) - Ship Blockers

### Issue #1: Pipeline Decoder Stubs [CRITICAL]
**Status**: [ ] Not Started
**Files**: `src/audio/pipeline.zig:135,165,195,225`
**Impact**: FLAC/MP3/AAC/AIFF files produce silence through unified pipeline

**Problem Analysis**:
The unified audio pipeline has wrapper structs for each decoder format, but the `decode()` methods are TODO stubs that return 0 (no samples). The actual working decoders exist in `src/audio/decoders/` but are not wired to the pipeline.

**Decision**: Integrate existing decoders into pipeline wrappers rather than duplicating code.

**Implementation Plan**:
1. Import actual decoder modules into pipeline.zig
2. Replace stub wrappers with real decoder delegation
3. Handle format-specific initialization
4. Add format-to-decoder routing in pipeline init
5. Test with actual audio files

**Verification**:
- [ ] FLAC file produces audio through pipeline
- [ ] MP3 file produces audio through pipeline
- [ ] AAC file produces audio through pipeline
- [ ] AIFF file produces audio through pipeline
- [ ] Integration tests pass

---

### Issue #2: system_info.zig Broken API [CRITICAL]
**Status**: [ ] Not Started
**Files**: `src/ui/system_info.zig:183,196,199`
**Impact**: Application crashes if user navigates to System Info screen

**Problem Analysis**:
The System Info screen calls `lcd.drawText()` which does not exist in the LCD driver API. The correct function is `lcd.drawString()`.

**Decision**: Replace all `lcd.drawText()` calls with `lcd.drawString()` matching the correct signature.

**Implementation Plan**:
1. Identify all incorrect API calls
2. Replace with correct LCD driver API
3. Verify signature matches: `drawString(x, y, text, color)`

**Verification**:
- [ ] System Info screen renders without crash
- [ ] All text displays correctly
- [ ] Build succeeds with no warnings

---

### Issue #3: Hardcoded Audio Constants [HIGH]
**Status**: [ ] Not Started
**Files**: `src/audio/audio.zig:42-52`, `src/audio/dsp.zig:23`
**Impact**: Gapless timing breaks at non-44.1kHz rates, EQ coefficients incorrect

**Problem Analysis**:
```zig
// Current: Fixed values that assume 44.1kHz
pub const DEFAULT_SAMPLE_RATE: u32 = 44100;
pub const GAPLESS_THRESHOLD: u64 = 88200;  // Should be ~2 seconds at ANY rate
```

The gapless threshold of 88200 samples equals exactly 2 seconds at 44.1kHz, but:
- At 48kHz: 88200 samples = 1.84 seconds (early trigger)
- At 96kHz: 88200 samples = 0.92 seconds (very early trigger)

**Decision**: Make threshold configurable and calculate from sample rate at runtime.

**Implementation Plan**:
1. Create AudioConfig struct with runtime sample rate
2. Calculate GAPLESS_THRESHOLD dynamically
3. Pass sample rate to DSP coefficient calculations
4. Update EQ band coefficient generation

**Verification**:
- [ ] Gapless works correctly at 44.1kHz
- [ ] Gapless works correctly at 48kHz
- [ ] EQ center frequencies correct at any sample rate
- [ ] Unit tests validate calculations

---

### Issue #4: Silent Error Handling (66 instances) [HIGH]
**Status**: [ ] Not Started
**Files**: Multiple (app.zig, settings.zig, ui components)
**Impact**: Hardware failures go undetected, users see frozen UI

**Problem Analysis**:
```zig
// This pattern appears 66 times across the codebase:
audio.setVolumeMono(self.volume) catch {};  // Error silently ignored
lcd.init() catch {};  // Display init failure ignored
clickwheel.poll() catch return;  // Input loss ignored
```

**Decision**: Implement tiered error handling strategy:
1. **Critical errors** (hardware init): Propagate and show error screen
2. **Recoverable errors** (volume set): Log and use fallback
3. **Transient errors** (poll): Retry or skip frame

**Implementation Plan**:
1. Create error state tracking in app state
2. Define error severity levels
3. Audit each empty catch block
4. Replace with appropriate handling per severity
5. Add error indicator to status bar

**Verification**:
- [ ] No empty `catch {}` blocks remain
- [ ] Error state visible in UI when appropriate
- [ ] Graceful degradation on recoverable errors
- [ ] Clear error messages for critical failures

---

## High Priority Issues (P1) - Quality Essentials

### Issue #5: No Frame Rate Limiting [MEDIUM]
**Status**: [ ] Not Started
**Files**: `src/app/app.zig` (main loop)
**Impact**: 100% CPU usage when idle, battery drain

**Decision**: Add 60fps frame limiting with sleep when idle.

**Implementation Plan**:
1. Track frame timing
2. Calculate remaining time in 16.67ms frame
3. Sleep for remaining time
4. Skip frames if running behind

---

### Issue #6: Missing Hardware Driver Tests [HIGH]
**Status**: [ ] Not Started
**Files**: `src/drivers/*`, `tests/`
**Impact**: Cannot validate hardware interaction safety

**Decision**: Create comprehensive test suite for all hardware drivers using mock HAL.

**Implementation Plan**:
1. GPIO driver tests
2. I2C driver tests
3. USB driver tests
4. PMU (power management) tests
5. ATA storage tests

---

### Issue #7: No Performance Benchmarks [MEDIUM]
**Status**: [ ] Not Started
**Impact**: Cannot validate performance claims, no regression detection

**Decision**: Create benchmark suite for critical paths.

**Implementation Plan**:
1. Decoder throughput benchmarks
2. DSP chain CPU measurement
3. UI render timing
4. Memory allocation tracking

---

## Architecture Decisions Log

### ADR-001: Pipeline Decoder Integration Strategy
**Date**: 2026-01-09
**Status**: Accepted
**Context**: Pipeline has stub decoders, real decoders exist separately
**Decision**: Wire existing decoders into pipeline rather than duplicate
**Rationale**:
- Decoders already tested and working
- Avoids code duplication
- Single source of truth for decoder logic
- Easier to maintain

### ADR-002: Error Handling Strategy
**Date**: 2026-01-09
**Status**: Accepted
**Context**: 66 empty catch blocks throughout codebase
**Decision**: Tiered error handling based on severity
**Rationale**:
- Critical errors must propagate (device safety)
- Recoverable errors should degrade gracefully
- Transient errors can be retried
- Users need visibility into system health

### ADR-003: Sample Rate Configuration
**Date**: 2026-01-09
**Status**: Accepted
**Context**: Hardcoded 44.1kHz assumptions break at other rates
**Decision**: Runtime-configurable sample rate with derived constants
**Rationale**:
- Wolfson DAC supports multiple rates
- High-res audio requires 48/96/192kHz
- EQ coefficients must match actual rate
- Gapless threshold must be time-based, not sample-based

---

## Progress Tracking

### Completed
- [x] Initial codebase assessment
- [x] Critical issues identified
- [x] Excellence roadmap created

### In Progress
- [ ] Pipeline decoder integration
- [ ] system_info.zig API fix
- [ ] Sample rate configuration

### Pending
- [ ] Error handling audit
- [ ] Frame rate limiting
- [ ] Hardware driver tests
- [ ] Performance benchmarks
- [ ] Final assessment

---

## Verification Checklist

Before declaring 9/10:

### Audio Quality
- [ ] All 5 formats decode correctly (WAV, FLAC, MP3, AAC, AIFF)
- [ ] Gapless playback works at 44.1/48/96kHz
- [ ] EQ coefficients calculated correctly per sample rate
- [ ] No audible artifacts during playback
- [ ] Volume ramping prevents clicks

### UI/UX
- [ ] All screens render without crash
- [ ] Error states display meaningful messages
- [ ] Frame rate stable at 60fps
- [ ] Battery indicator accurate

### Testing
- [ ] All existing tests pass
- [ ] Hardware driver tests added
- [ ] Integration tests comprehensive
- [ ] No empty catch blocks

### Performance
- [ ] CPU usage < 50% during FLAC playback
- [ ] CPU usage < 30% during MP3 playback
- [ ] UI idle at < 5% CPU
- [ ] Memory usage stable over time

---

## References

- **Supreme Architect Persona**: `/docs/system-prompts/personas/09-supreme-architect.md`
- **Audio Engineer Persona**: `/docs/system-prompts/personas/05-audio-engineer.md`
- **Zig Expert Persona**: `/docs/system-prompts/personas/06-zig-language-expert.md`
- **QA Engineer Persona**: `/docs/system-prompts/personas/01-embedded-qa-engineer.md`
- **Integration Proposal**: `/docs/proposals/integration-refactoring.md`
