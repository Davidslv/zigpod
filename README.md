# ZigPod OS

A custom operating system for the Apple iPod Classic 5th Generation (2005), written entirely in Zig.

## Project Status

**Phase**: Documentation & Research Complete

The project has completed comprehensive hardware research and documentation. All critical hardware information has been verified against the Rockbox source code and is ready for implementation.

## Documentation

| Document | Description |
|----------|-------------|
| [001-zigpod.md](docs/001-zigpod.md) | Project vision and AI development guidelines |
| [002-plan.md](docs/002-plan.md) | High-level project plan |
| [003-implementation-plan.md](docs/003-implementation-plan.md) | Detailed implementation phases |
| [004-hardware-reference.md](docs/004-hardware-reference.md) | **Complete hardware reference** (registers, memory map, peripherals) |
| [005-safe-init-sequences.md](docs/005-safe-init-sequences.md) | **Verified safe initialization sequences** |
| [006-recovery-guide.md](docs/006-recovery-guide.md) | **Recovery procedures and safety guide** |

## Target Hardware

| Component | Specification |
|-----------|---------------|
| SoC | PortalPlayer PP5021C |
| CPU | Dual ARM7TDMI @ 80 MHz |
| RAM | 32MB / 64MB SDRAM |
| Display | 320x240 QVGA LCD |
| Audio | Wolfson WM8758 codec |
| Storage | 30-80GB HDD (or SD via iFlash) |
| PMU | Philips PCF50605 |

## Key Features (Planned)

- **Efficiency**: Target 25-30 hours audio playback (matching Apple firmware)
- **Audio Quality**: Bit-perfect playback, FLAC/AIFF/WAV support
- **Safety**: Zero-bricking philosophy, simulation-first development
- **Modern**: Written in Zig for safety and performance

## Research Sources

All hardware documentation has been verified from:

- [Rockbox Source Code](https://github.com/Rockbox/rockbox) - Primary reference
- [iPodLoader2](https://github.com/crozone/ipodloader2) - Bootloader reference
- [WM8758 Datasheet](https://www.alldatasheet.com/view.jsp?Searchword=WM8758) - Audio codec
- [freemyipod.org](https://freemyipod.org) - Recovery procedures

## Safety First

**Before developing for real hardware, read:**

1. [Safe Initialization Sequences](docs/005-safe-init-sequences.md)
2. [Recovery Guide](docs/006-recovery-guide.md)

**Golden Rules:**
- NEVER flash the boot ROM
- ALWAYS test in emulator/simulator first
- ALWAYS have a backup iPod
- ALWAYS verify Disk Mode works before testing

## License

TBD

## Contributing

This project is in early stages. Contributions welcome after initial implementation is complete.
