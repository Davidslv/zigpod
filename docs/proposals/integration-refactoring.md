# ZigPod Integration Refactoring Proposal

**Date**: January 9, 2026
**Status**: In Progress
**Priority**: Critical

## Executive Summary

Despite rapid progress bringing UI/UX from 15% to 90% and adding advanced audio features (AAC-LC decoder, linear interpolation resampler, dithering), ZigPod remains a collection of impressive but poorly integrated components. This proposal addresses the core integration gaps to transform the project from a prototype into a cohesive, reliable system.

## Problem Statement

### Current State Analysis

| Component | Exists | Integrated | Tested E2E |
|-----------|--------|------------|------------|
| WAV Decoder | Yes | Partial | No |
| MP3 Decoder | Yes | No | No |
| AAC-LC Decoder | Yes | No | No |
| FLAC Decoder | Yes | No | No |
| Resampler | Yes | No | No |
| Dithering | Yes | No | No |
| Volume Control | Yes | Partial | No |
| UI Screens | Yes | Partial | No |
| Click Wheel | Yes | Yes | No |
| File Browser | Yes | Yes | No |
| Now Playing | Yes | Partial | No |
| Settings | Yes | Partial | No |

### Critical Gaps

1. **Audio Pipeline Fragmentation**
   - Decoders exist as standalone modules
   - No unified playback loop chains: decoder → resampler → dithering → volume → output
   - Format switching untested
   - Gapless playback claimed but unvalidated

2. **UI State Management**
   - Ad-hoc screen switching via `pushScreen()`/`popScreen()`
   - No formal state machine
   - Edge cases unhandled (e.g., back from nested menus)
   - No transition animations or loading states

3. **Testing Gaps**
   - 458+ unit tests but zero integration tests
   - Simulator-only validation
   - No playlist playback tests
   - No format switching tests
   - No stress tests (memory, CPU)

4. **Performance Unknown**
   - No benchmarks on target hardware
   - High-res (192kHz) claims unvalidated
   - CPU usage during playback unknown
   - Battery impact unmeasured

## Proposed Solutions

### 1. Unified Audio Pipeline

Create a single `AudioPipeline` struct that chains all components:

```
┌─────────┐   ┌───────────┐   ┌──────────┐   ┌─────────┐   ┌────────┐
│ Decoder │──▶│ Resampler │──▶│ Ditherer │──▶│ Volume  │──▶│ Output │
└─────────┘   └───────────┘   └──────────┘   └─────────┘   └────────┘
     │              │               │              │
     └──────────────┴───────────────┴──────────────┘
                         │
                  ┌──────▼──────┐
                  │ AudioEngine │
                  │  (unified)  │
                  └─────────────┘
```

**Implementation**:
- `src/audio/pipeline.zig` - Unified pipeline coordinator
- Automatic format detection and decoder selection
- Configurable resampling (bypass if native rate)
- Optional dithering (only when downsampling bit depth)
- Smooth volume ramping to prevent clicks

### 2. UI State Machine

Replace ad-hoc navigation with a formal state machine:

```
┌─────────────────────────────────────────────────────────────┐
│                      UIStateMachine                         │
├─────────────────────────────────────────────────────────────┤
│ States: boot, main_menu, music_browser, file_browser,       │
│         now_playing, settings, about, error                 │
├─────────────────────────────────────────────────────────────┤
│ Transitions:                                                │
│   boot → main_menu (on init complete)                       │
│   main_menu → music_browser (on select "Music")             │
│   main_menu → file_browser (on select "Files")              │
│   main_menu → now_playing (on select "Now Playing")         │
│   main_menu → settings (on select "Settings")               │
│   * → now_playing (on PLAY if track loaded)                 │
│   * → previous (on MENU/back)                               │
│   * → error (on fatal error)                                │
├─────────────────────────────────────────────────────────────┤
│ Guards:                                                     │
│   now_playing: requires loaded track                        │
│   back: requires stack depth > 0                            │
└─────────────────────────────────────────────────────────────┘
```

**Implementation**:
- `src/ui/state_machine.zig` - Formal state machine with guards
- Entry/exit actions for each state
- Transition logging for debugging
- Error state with recovery options

### 3. Integration Test Suite

Create comprehensive integration tests:

```
tests/
├── integration/
│   ├── audio_pipeline_test.zig    # Full decode→output chain
│   ├── playlist_playback_test.zig # Multi-track sequences
│   ├── format_switching_test.zig  # WAV→MP3→FLAC transitions
│   ├── ui_navigation_test.zig     # Menu flows
│   ├── file_to_playback_test.zig  # Browse→select→play
│   └── stress_test.zig            # Memory/CPU limits
```

**Test Scenarios**:
1. Load WAV → play → pause → resume → stop
2. Load MP3 → skip to next (FLAC) → skip to next (AAC)
3. Navigate: Main → Music → Artists → Album → Track → Now Playing → Back×4
4. Play 100 tracks sequentially without memory leak
5. Rapid button presses during playback

### 4. Performance Profiling

Add instrumentation for performance measurement:

```zig
pub const PerfMetrics = struct {
    decode_cycles: u64 = 0,
    resample_cycles: u64 = 0,
    dither_cycles: u64 = 0,
    render_cycles: u64 = 0,
    idle_cycles: u64 = 0,

    pub fn cpuUsagePercent(self: *const PerfMetrics) u8 {
        const active = self.decode_cycles + self.resample_cycles +
                       self.dither_cycles + self.render_cycles;
        const total = active + self.idle_cycles;
        return @intCast((active * 100) / total);
    }
};
```

**Metrics to Track**:
- CPU usage per component (decode, resample, render)
- Memory high-water mark
- Buffer underruns count
- Frame timing (target: 16.67ms for 60fps UI)

## Implementation Plan

### Phase 1: Audio Pipeline Unification (Priority: Critical)

| Task | File | Description |
|------|------|-------------|
| Create pipeline coordinator | `src/audio/pipeline.zig` | Unified AudioPipeline struct |
| Integrate decoders | `src/audio/pipeline.zig` | Auto-detect format, select decoder |
| Chain resampler | `src/audio/pipeline.zig` | Connect decoder output to resampler |
| Add dithering stage | `src/audio/pipeline.zig` | Apply dithering when needed |
| Volume integration | `src/audio/pipeline.zig` | Smooth volume with ramping |
| Update audio.zig | `src/audio/audio.zig` | Use pipeline instead of direct decoder |

### Phase 2: UI State Machine (Priority: High)

| Task | File | Description |
|------|------|-------------|
| Define state enum | `src/ui/state_machine.zig` | All possible UI states |
| Define transitions | `src/ui/state_machine.zig` | Valid state transitions |
| Add guards | `src/ui/state_machine.zig` | Preconditions for transitions |
| Entry/exit actions | `src/ui/state_machine.zig` | State lifecycle hooks |
| Migrate app.zig | `src/app/app.zig` | Use state machine |
| Add error state | `src/ui/state_machine.zig` | Graceful error handling |

### Phase 3: Integration Tests (Priority: High)

| Task | File | Description |
|------|------|-------------|
| Audio pipeline test | `tests/integration/audio_pipeline_test.zig` | End-to-end audio |
| Playlist test | `tests/integration/playlist_test.zig` | Multi-track playback |
| Format switching | `tests/integration/format_test.zig` | Codec transitions |
| UI navigation | `tests/integration/ui_navigation_test.zig` | Menu flows |
| File to playback | `tests/integration/file_playback_test.zig` | Full user flow |
| Stress test | `tests/integration/stress_test.zig` | Limits testing |

### Phase 4: Performance Profiling (Priority: Medium)

| Task | File | Description |
|------|------|-------------|
| Add metrics struct | `src/perf/metrics.zig` | Performance counters |
| Instrument audio | `src/audio/pipeline.zig` | Cycle counting |
| Instrument UI | `src/ui/ui.zig` | Frame timing |
| Add reporting | `src/perf/metrics.zig` | Stats output |
| Simulator display | `src/simulator/main.zig` | Show metrics in UI |

## Success Criteria

### Audio Pipeline
- [ ] Single `loadAndPlay(path)` call handles any supported format
- [ ] Seamless format switching mid-playlist
- [ ] No audible clicks on volume change
- [ ] Buffer underrun rate < 0.1%

### UI State Machine
- [ ] All navigation paths tested and working
- [ ] Back button always returns to correct screen
- [ ] PLAY shortcut works from any screen
- [ ] Error state shows meaningful message

### Integration Tests
- [ ] 100% pass rate on all integration tests
- [ ] No memory leaks after 100-track playlist
- [ ] UI responsive during playback (< 50ms input lag)

### Performance
- [ ] CPU usage < 50% during FLAC 96kHz playback
- [ ] CPU usage < 30% during MP3 320kbps playback
- [ ] UI renders at stable 60fps
- [ ] Memory usage < 4MB for audio buffers

## Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| Decoder integration breaks existing code | Medium | High | Comprehensive unit tests first |
| State machine adds complexity | Low | Medium | Keep transitions simple |
| Performance targets unachievable | Medium | High | Add fallback low-quality modes |
| Integration tests flaky | Medium | Medium | Use deterministic test data |

## Timeline

This proposal will be implemented in a single focused session:

1. **Audio Pipeline**: ~2 hours
2. **UI State Machine**: ~1.5 hours
3. **Integration Tests**: ~1.5 hours
4. **Performance Profiling**: ~1 hour

**Total**: ~6 hours of focused implementation

## Appendix: File Changes Summary

### New Files
- `src/audio/pipeline.zig`
- `src/ui/state_machine.zig`
- `src/perf/metrics.zig`
- `tests/integration/audio_pipeline_test.zig`
- `tests/integration/playlist_test.zig`
- `tests/integration/format_test.zig`
- `tests/integration/ui_navigation_test.zig`
- `tests/integration/file_playback_test.zig`
- `tests/integration/stress_test.zig`

### Modified Files
- `src/audio/audio.zig` - Use unified pipeline
- `src/app/app.zig` - Use state machine
- `src/simulator/main.zig` - Show perf metrics
- `build.zig` - Add integration test targets
