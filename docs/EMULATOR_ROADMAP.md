# PP5021C Emulator Roadmap

## Current Status

The emulator successfully runs the Rockbox bootloader through its initial stages:
1. Loads firmware at SDRAM (0x10000000)
2. Copies code to IRAM (0x40000000)
3. Jumps to IRAM and begins peripheral initialization
4. **Blocks** at cache control register polling (0x6000C000)

## What Works

| Component | Status | Notes |
|-----------|--------|-------|
| ARM7TDMI core | Working | Full ARM + Thumb instruction set |
| Cycle counting | Accurate | Data proc, load/store, branch timings |
| Memory bus | Working | SDRAM, IRAM, peripheral dispatch |
| Register banking | Working | Mode switching with banked SP/LR |
| Exceptions | Working | Reset, IRQ, FIQ vectors |
| Basic peripherals | Stub | Store/retrieve register values |

## Blocking Issues

### 1. Cache Controller (0x6000C000)

The bootloader polls this address waiting for cache operations to complete.

**Solution**: Implement cache control register that always returns "ready" status.

```zig
// Add to peripherals/cache_ctrl.zig
const CACHE_CTRL_BASE: u32 = 0x6000C000;

pub const CacheController = struct {
    fn read(offset: u32) u32 {
        return switch (offset) {
            0x00 => 0x01, // Cache ready/idle
            else => 0,
        };
    }
};
```

### 2. Click Wheel Initialization

After cache init, the bootloader checks button states via click wheel registers.

**Current**: Click wheel returns 0 (no buttons pressed).
**Issue**: Bootloader may enter boot selection loop.

### 3. LCD Controller

Bootloader attempts to display splash screen.

**Current**: Framebuffer writes work but no actual display command processing.
**Issue**: BCM2722 command protocol not implemented.

## Phase 1: Unblock Boot Sequence

### Tasks

1. **Implement cache controller stub**
   - Add 0x6000C000 region to memory map
   - Return ready status on all reads
   - Ignore writes (or log for debugging)

2. **Implement PP5020-specific registers**
   - 0x60007000: CPU identification
   - 0x6000603C: PLL status (return locked)
   - 0x60006044: Clock status

3. **Enhance I2C controller**
   - Complete WM8758 codec identification
   - Complete PCF50605 PMU responses

### Expected Outcome
Bootloader reaches button check phase.

## Phase 2: User Interaction

### Tasks

1. **Click wheel enhancement**
   - Proper button state reporting
   - Wheel position tracking
   - Data ready interrupt generation

2. **SDL input integration**
   - Map keyboard to buttons
   - Mouse for wheel rotation

3. **Timer interrupts**
   - Generate timer IRQs
   - Connect to interrupt controller

### Expected Outcome
Bootloader responds to button presses.

## Phase 3: Display Output

### Tasks

1. **BCM2722 LCD controller**
   - Command interpretation
   - Framebuffer update triggers
   - Window/region support

2. **SDL display**
   - RGB565 to RGBA32 conversion
   - 60fps refresh cycle
   - Scale to window size

### Expected Outcome
Visual feedback from bootloader.

## Phase 4: Storage Access

### Tasks

1. **Complete ATA controller**
   - DMA support
   - Multi-sector transfers
   - Proper interrupt generation

2. **FAT32 filesystem**
   - Bootloader loads rockbox.ipod from disk
   - Configuration files

### Expected Outcome
Bootloader can load main Rockbox firmware.

## Phase 5: Audio Output

### Tasks

1. **I2S controller**
   - FIFO implementation
   - DMA integration
   - Sample rate configuration

2. **WM8758 codec emulation**
   - Volume control
   - Sample format conversion

3. **SDL audio**
   - Ring buffer
   - Low-latency playback

### Expected Outcome
Audio playback works.

## Phase 6: Full Integration

### Tasks

1. **COP (second core)**
   - Synchronization primitives
   - Separate register file

2. **Performance optimization**
   - Dynarec (optional)
   - Cached translations

3. **Debugging tools**
   - GDB stub
   - Memory inspector
   - Breakpoints

### Expected Outcome
Complete Rockbox functionality.

## Testing Strategy

### Unit Tests
- Each peripheral has Zig tests
- Instruction decoder tests
- Memory access tests

### Integration Tests
- LCD test firmware (red/green screen)
- Thumb mode test
- ATA read test

### Validation
- Compare emulator behavior with real hardware
- Trace comparison for known firmware

## Next Immediate Steps

1. Add cache controller region (0x6000C000)
2. Implement PLL status register (0x6000603C)
3. Test bootloader progression
4. Add more trace output for debugging

## Reference Documentation

- ARM7TDMI Technical Reference Manual (ARM DDI 0029E)
- Rockbox source: `firmware/export/pp5020.h`
- Rockbox bootloader: `bootloader/ipod.c`
- PP5020 Complete Reference: `docs/hardware/PP5020_COMPLETE_REFERENCE.md`
