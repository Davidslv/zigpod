# Contributing to ZigPod

Thank you for your interest in contributing to ZigPod! This document provides guidelines for contributing to the project.

## Getting Started

### Prerequisites

- [Zig 0.15.2](https://ziglang.org/download/) or later
- Git
- SDL2 (optional, for GUI simulator)

### Development Setup

```bash
# Clone the repository
git clone https://github.com/Davidslv/zigpod.git
cd zigpod

# Run tests to verify setup
zig build test

# Run the simulator to verify everything works
zig build sim
```

## Development Workflow

### 1. Create an Issue First

For significant changes, please open an issue to discuss your proposal before writing code. This helps:
- Ensure the change aligns with project goals
- Avoid duplicate work
- Get early feedback on your approach

### 2. Fork and Branch

```bash
# Fork on GitHub, then clone your fork
git clone https://github.com/YOUR_USERNAME/zigpod.git
cd zigpod

# Create a feature branch
git checkout -b feature/your-feature-name
```

### 3. Write Tests First

ZigPod follows test-driven development. Write tests before implementing features:

```zig
test "my new feature" {
    // Setup
    var thing = MyThing.init();

    // Action
    const result = thing.doSomething();

    // Assertion
    try std.testing.expectEqual(expected_value, result);
}
```

### 4. Implement Your Changes

Follow the coding standards below and ensure all existing tests pass.

### 5. Run All Tests

```bash
# Run complete test suite (500+ tests)
zig build test

# Tests must pass with zero failures
```

### 6. Submit a Pull Request

- Provide a clear description of the changes
- Reference any related issues
- Ensure CI checks pass

## Coding Standards

### File Organization

```
src/
├── hal/           # Hardware Abstraction Layer (mock + PP5021C)
├── kernel/        # Core OS: memory, interrupts, timer, DMA, clock
├── drivers/       # Device drivers: LCD, storage, input, audio codec
├── audio/         # Audio engine: decoders, DSP, playback
├── ui/            # User interface: menus, overlays, themes
├── library/       # Music library: iTunesDB, playlists
├── simulator/     # PP5021C emulator components
└── tools/         # JTAG, flasher, recovery utilities
```

### Code Style

Follow Zig's official style guide with these project-specific conventions:

#### Naming

```zig
// Types: PascalCase
pub const AudioDecoder = struct { ... };

// Functions/variables: camelCase
pub fn decodeFrame(buffer: []u8) !Frame { ... }
var currentPosition: u32 = 0;

// Constants: SCREAMING_SNAKE_CASE
pub const BUFFER_SIZE: usize = 8192;
pub const SAMPLE_RATE: u32 = 44100;
```

#### Comments

```zig
//! Module-level documentation
//!
//! Describes what this module does and how to use it.

/// Function documentation
/// Describes parameters and return value
pub fn processAudio(samples: []i16) void { ... }

// Single-line comment for implementation details
const x = 42; // Brief explanation if needed
```

#### Error Handling

```zig
// Use error unions for fallible operations
pub fn readFile(path: []const u8) ![]u8 {
    const file = try std.fs.openFile(path, .{});
    // ...
}

// Use optionals for "may not exist" scenarios
pub fn findTrack(id: u32) ?*Track {
    return track_map.get(id);
}
```

### Hardware Abstraction

Always use the HAL for hardware access:

```zig
// Good: Use HAL
const hal = @import("hal/hal.zig");
hal.delayMs(100);
hal.lcdSetPixel(x, y, color);

// Bad: Direct hardware access
const mmio = @as(*volatile u32, @ptrFromInt(0x70000000));
mmio.* = value;
```

### Fixed-Point Math

For embedded audio/DSP, use fixed-point arithmetic:

```zig
// Use Q15 (16-bit with 15 fractional bits) for audio samples
const sample: i16 = @intCast((value * 32767) >> 15);

// Use Q16.16 for rates/ratios
const phase_inc: u32 = (input_rate << 16) / output_rate;
```

### Memory Management

Use the kernel memory allocator for dynamic allocation:

```zig
const memory = @import("kernel/memory.zig");

// For small allocations
const ptr = memory.alloc(256) orelse return error.OutOfMemory;
defer memory.free(ptr, 256);

// For DMA-aligned buffers
const dma_ptr = memory.allocDma(4096) orelse return error.OutOfMemory;
defer memory.freeDma(dma_ptr, 4096);
```

## Testing Requirements

### All Code Must Be Tested

```zig
// Every public function should have at least one test
pub fn calculateChecksum(data: []const u8) u32 { ... }

test "calculateChecksum basic" {
    const result = calculateChecksum("test");
    try std.testing.expectEqual(@as(u32, 0xD87F7E0C), result);
}

test "calculateChecksum empty" {
    const result = calculateChecksum("");
    try std.testing.expectEqual(@as(u32, 0), result);
}
```

### Test Categories

1. **Unit tests**: Test individual functions in isolation
2. **Integration tests**: Test component interactions (see `src/tests/integration_tests.zig`)
3. **Simulator tests**: Full system tests using the simulator

### Running Specific Tests

```bash
# Run all tests
zig build test

# Tests are run automatically with verbose output
# Check for "N/N tests passed" at the end
```

## Module-Specific Guidelines

### Audio Decoders

When adding a new audio format:

1. Create `src/audio/decoders/your_format.zig`
2. Implement the decoder interface:
   ```zig
   pub const YourDecoder = struct {
       pub fn init(data: []const u8) !YourDecoder { ... }
       pub fn decode(self: *YourDecoder, output: []i16) !usize { ... }
       pub fn getSampleRate(self: *YourDecoder) u32 { ... }
       pub fn getChannels(self: *YourDecoder) u8 { ... }
   };
   ```
3. Add to `src/audio/decoders/decoders.zig` DecoderType enum
4. Add format detection in `detectFormat()`
5. Write comprehensive tests

### UI Components

UI components should:
1. Use the theme system (`ui.getTheme()`)
2. Support both light and dark themes
3. Handle variable screen sizes gracefully
4. Be testable without display hardware

### Drivers

Hardware drivers must:
1. Work with mock HAL for testing
2. Include proper error handling
3. Document register accesses
4. Include timeout handling for hardware operations

## Pull Request Checklist

Before submitting:

- [ ] All tests pass (`zig build test`)
- [ ] New code has test coverage
- [ ] Code follows style guidelines
- [ ] Documentation is updated (if applicable)
- [ ] Commit messages are clear and descriptive
- [ ] Changes are focused (one feature/fix per PR)

## Commit Message Format

```
<type>: <short summary>

<optional longer description>

Co-Authored-By: Your Name <your@email.com>
```

Types:
- `feat`: New feature
- `fix`: Bug fix
- `docs`: Documentation only
- `test`: Adding tests
- `refactor`: Code change that doesn't add features or fix bugs
- `perf`: Performance improvement
- `chore`: Build, CI, or tooling changes

Examples:
```
feat: Add AAC-LC audio decoder

Implements AAC Low Complexity profile decoding with:
- ADTS header parsing
- Spectral processing
- IMDCT filterbank

fix: Resolve click wheel acceleration overflow

Use u32 for intermediate multiplication to prevent
integer overflow when calculating acceleration curve.
```

## Getting Help

- **Issues**: Search existing issues or create a new one
- **Discussions**: Use GitHub Discussions for questions
- **Documentation**: Check the `docs/` folder

## Code of Conduct

Be respectful and constructive. We're all here to make ZigPod better!

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
