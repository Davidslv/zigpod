# Apple iPod Firmware (osos.bin) Deep Analysis

**Analyzed:** January 12, 2026
**Firmware Size:** 7,561,216 bytes (7.21 MB)
**Target:** iPod Classic (PP5020/PP5022 SoC)

## 1. Binary Structure

### Header Layout
```
Offset      Description
0x000       Compressed/encrypted header
0x800       ARM exception vectors (8 x 4 bytes)
0x820       PortalPlayer identification string
0x840       Version strings
0x1000      Main code entry point
```

### Exception Vectors (at 0x800)
```arm
0x800:  b   0x9F0       ; Reset handler
0x804:  b   0x9A8       ; Undefined instruction
0x808:  ldr pc, [pc, #220]  ; SWI (Software interrupt)
0x80C:  b   0x9C0       ; Prefetch abort
0x810:  b   0x9D8       ; Data abort
0x814:  b   0x814       ; Reserved (infinite loop)
0x818:  b   0x980       ; IRQ handler
0x81C:  b   0x95C       ; FIQ handler
```

### PortalPlayer Header (at 0x820)
```
"portalplayer.0.0"
"PP5020AF-05.00-PP07-05.00-PP07-05.00-DT"
"2003.10.30 (Build 04)"
"Digital Media Platform"
"Copyright(c) 1999 - 2003 PortalPlayer, Inc."
```

## 2. Boot Sequence Analysis

### Reset Handler (0x9F0-0xA5C)
```arm
0x9F0:  mov ip, r0              ; Save boot parameter
0x9F4:  mov fp, #0x700          ; Stack setup
0x9F8:  mov r8, r2              ; Save parameters
0x9FC:  mov r9, r3

; Initialize some hardware registers
0xA00:  ldr r0, =0xXXXXXXXX     ; Load peripheral address
0xA04:  ldr r1, =0xXXXXXXXX     ; Load config value
0xA08:  str r1, [r0]            ; Write to peripheral

; CPU Core Detection (CRITICAL!)
0xA40:  mov r0, #0x60000000     ; Processor ID register base
0xA44:  ldrb r2, [r0]           ; Read core ID
0xA48:  cmp r2, #0x55           ; Compare with 0x55 (CPU = 0x55, COP = 0xAA)
0xA4C:  beq 0xA5C               ; Branch if CPU core
```

### Detected Hardware Register Accesses
| Address | Peripheral | Usage in Firmware |
|---------|------------|-------------------|
| 0x60000000 | Processor ID | Core identification (0x55=CPU, 0xAA=COP) |
| 0x60004000 | Interrupt Controller | IRQ/FIQ management |
| 0x60005000 | Timers | System tick, delays |
| 0x40000000 | IRAM | Fast code execution |

## 3. RTOS Task Inventory

### Core System Tasks
| Task Name | Description |
|-----------|-------------|
| HostOSTask | Main operating system task |
| DiskMgrTask | Disk management |
| ATAWorkLoopTask | ATA disk I/O |
| ATAWorkLoopIRQTask | ATA interrupt handler |
| BacklightTask | Display backlight control |
| HoldSwitchTask | Hold switch detection |
| AlarmTask | Alarm/timer management |
| EventManager | System event handling |

### Audio/Media Tasks
| Task Name | Description |
|-----------|-------------|
| USBAudioTask | USB audio output |
| MP3ExampleTask | MP3 playback |
| AudioCodecs | Audio codec management |
| Channel AudioPrompt | Audio notification sounds |
| Channel DiskReaderTask | Audio streaming from disk |

### USB/Connectivity Tasks
| Task Name | Description |
|-----------|-------------|
| FirewireTask | Firewire connectivity |
| USB Secondary Interrupt Task | USB interrupt handling |
| Hub Driver | USB hub support |
| CIapIncomingProcessThread | iPod Accessory Protocol (incoming) |
| CIapOutgoingProcessThread | iPod Accessory Protocol (outgoing) |

### Display/UI Tasks
| Task Name | Description |
|-----------|-------------|
| 13LcdDriverSpHw | LCD driver (SP hardware) |
| 13LcdDriverVC02 | LCD driver (VideoCore) |
| 16iMADisplayDriver | Display management |
| 17DisplayDriverVC02 | VideoCore display driver |
| ArtworkLoadTask | Album artwork loading |

### Accessory Tasks
| Task Name | Description |
|-----------|-------------|
| AccessoryDetectTask | Accessory detection |
| HPhoneDetTask | Headphone detection |
| ICAPTPCameraIOTask | Camera I/O (PTP) |
| ICAType4CameraDriver | Camera driver |

## 4. Hardware Driver References

### Display Controllers
- LCD Module detection at boot
- SP hardware variant
- VideoCore VC02 variant
- iMA display driver

### Audio System
- Wolfson codec detected ("Wolfson Active")
- I2C communication for codec control
- I2S for digital audio
- Error messages: "I2C write Error", "I2C read Error %02x"

### Storage
- ATA driver with IRQ support
- Workloop pattern for disk I/O
- Disk manager for filesystem

### Codec Support
- MP3 decoder (`@mp3dec_sync`)
- AAC decoder (`@mp4_aacdec_sync`)
- WAV files (RIFF headers)
- Video codecs (VideoCodecs)

## 5. Memory Architecture

### Memory Regions Used
```
0x10000000  SDRAM base (firmware load address)
0x40000000  IRAM base (fast RAM)
0x60000000  Peripheral registers
0x70000000  Device registers
```

### Memory Management
- Heap management with corruption detection
- Stack overflow protection
- Out-of-memory handling
- Bad_alloc exceptions

## 6. File System Support

### Detected Features
- FAT filesystem support
- Directory operations
- Async file I/O
- File size handling (MaxFileSizeInGB)
- Firmware update from filesystem (AutoRebootAfterFirmwareUpdate)

### Special Files
- APPLEBOOT partition marker
- .link file handling
- Profile files

## 7. Error Handling

### Detected Error Strings
- "Heap memory corrupted"
- "Out of Memory!"
- "Stack overflow"
- "Out of heap memory"
- "Illegal address"
- "Bad link, file not found"

## 8. Emulator Compatibility Assessment

### Already Implemented (Compatible)
- Processor ID register (0x60000000)
- Interrupt controller (0x60004000)
- Timer system (0x60005000)
- IRAM (0x40000000)
- SDRAM (0x10000000)
- ATA controller (0xC3000000)
- I2S audio (0x70002800)
- I2C controller (0x7000C000)
- LCD controller (0x30000000)

### May Need Verification
- FIQ handler implementation
- Dual-core (CPU/COP) synchronization
- DMA controller behavior
- Cache controller timing

### Not Implemented (May Cause Issues)
- VideoCore VC02 (if used for display)
- Firewire controller
- USB hub driver
- Camera/PTP support

## 9. Boot Requirements

Based on the analysis, to boot the Apple firmware the emulator needs:

1. **Exception vectors at SDRAM + 0x800**
   - Entry point should be 0x10000800, not 0x10000000

2. **CPU Core ID at 0x60000000**
   - Must return 0x55 for CPU core
   - Must return 0xAA for COP core

3. **Working timer system**
   - Required for RTOS scheduling

4. **Interrupt controller**
   - Required for IRQ/FIQ handling

5. **ATA controller**
   - For loading resources from disk

## 10. Comparison with Rockbox

| Feature | Apple Firmware | Rockbox Bootloader |
|---------|----------------|-------------------|
| Size | 7.2 MB | 51 KB |
| RTOS | Yes (complex) | No (single-threaded) |
| Display | Multiple drivers | Single LCD path |
| Audio | Full codec stack | Basic I2S |
| USB | Full stack | Minimal |
| Boot complexity | High | Low |

The Apple firmware is significantly more complex and has more hardware requirements than the Rockbox bootloader.

---

*Analysis performed using arm-none-eabi-objdump and radare2*
