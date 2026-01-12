# Reverse Engineering Tooling Setup

## Overview

This document describes the reverse engineering tools available for analyzing Apple firmware (osos.bin) and understanding PP5021C hardware behavior.

## Installed Tools

### Ghidra 12.0
- **Location**: `~/tools/ghidra_12.0_PUBLIC`
- **Launch**: `~/tools/ghidra_12.0_PUBLIC/ghidraRun`
- **Purpose**: Full-featured disassembler and decompiler for ARM7TDMI analysis
- **Use cases**:
  - Decompiling firmware functions
  - Creating annotated function databases
  - Cross-referencing string literals and constants
  - Analyzing control flow graphs

### radare2
- **Location**: `/opt/homebrew/bin/radare2`
- **Purpose**: Command-line disassembler and binary analysis framework
- **Use cases**:
  - Quick disassembly of specific addresses
  - Scripted analysis and batch processing
  - Hex editing and patching
  - Integration with emulator debugging

## Firmware Files

### Apple Firmware (osos.bin)
- **Location**: `/Users/davidslv/projects/zigpod/firmware/osos.bin`
- **Format**: Raw ARM7TDMI binary
- **Load address**: 0x10000000 (SDRAM)
- **Entry point**: 0x10000800
- **Version**: PP5020AF-05.00

### Key Analysis Targets

1. **COP Initialization**
   - COP_CTL register usage at 0x60007004
   - Search for patterns: `0x60007004`, `0x80000000` (sleep bit)

2. **Task Queue System (hw_accel)**
   - Hardware accelerator region at 0x60003000
   - RTOS task queue management

3. **Interrupt Handlers**
   - Vector table at firmware start
   - IRQ/FIQ handler implementations

## Analysis Workflow

### Loading Firmware in Ghidra

1. Create new project
2. File > Import File > select `osos.bin`
3. Language: ARM:LE:32:v4t (ARM7TDMI)
4. Base address: 0x10000000
5. Run Auto Analysis
6. Define entry point at 0x10000800

### Loading Firmware in radare2

```bash
r2 -a arm -b 32 -m 0x10000000 firmware/osos.bin
# Inside r2:
s 0x10000800  # seek to entry
af            # analyze function
pdf           # print disassembly
```

### Key Search Patterns

```bash
# Find COP_CTL references (0x60007004)
r2 -qc '/x 04700060' firmware/osos.bin

# Find sleep bit pattern (0x80000000)
r2 -qc '/x 00000080' firmware/osos.bin

# Find hw_accel references (0x60003000)
r2 -qc '/x 00300060' firmware/osos.bin
```

## Known Addresses

| Address | Description |
|---------|-------------|
| 0x10000800 | Firmware entry point |
| 0x60000000 | PROC_ID (CPU=0x55, COP=0xAA) |
| 0x60001010 | CPU_QUEUE (mailbox) |
| 0x60001020 | COP_QUEUE (mailbox) |
| 0x60003000 | hw_accel task queue region |
| 0x60004000 | Interrupt controller base |
| 0x60006000 | System controller base |
| 0x60007000 | CPU_CTL |
| 0x60007004 | COP_CTL |

## String Literals Found

- "COP has crashed - (0x%X)" - COP crash handler
- "PP5020AF-05.00" - Firmware version

## Next Steps

1. Create Ghidra project with full annotations
2. Map all COP-related functions
3. Document hw_accel task queue format
4. Trace RTOS scheduler behavior
