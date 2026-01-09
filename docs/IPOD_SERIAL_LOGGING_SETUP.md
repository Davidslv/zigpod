# iPod Classic 5.5G Serial (UART) Logging Setup

A complete guide to capturing serial logs from an iPod Classic 5.5G via the 30-pin dock connector. This external setup requires no disassembly or soldering to the iPod itself.

## Overview

This setup enables monitoring of boot processes, errors, and system events from your iPod Classic 5.5G. It's particularly useful with Rockbox firmware installed, which provides verbose logging output. Stock Apple firmware outputs minimal or no logs.

**Prerequisites**: Install Rockbox via USB before proceeding if you want meaningful log output.

### Connection Chain

```
iPod Classic 5.5G ←→ 30-pin Breakout Board ←→ UART Wiring ←→ USB-to-UART Adapter ←→ USB ←→ Mac
```

| Metric | Value |
|--------|-------|
| Total Cost | ~$30–60 |
| Setup Time | 15–30 minutes |
| Difficulty | Beginner-friendly |

---

## Wiring Diagram

### Pin Reference

Pins are numbered from left to right when viewing the male plug with the notch facing up. Pin 1 is on the right end.

### Connection Table

| 30-pin Dock Pin | Signal | Connection | USB-to-UART Pin |
|-----------------|--------|------------|-----------------|
| Pin 21 | Accessory Enable | via resistor to GND | GND |
| Pin 12 | Serial TxD (iPod out) | direct | RX (Receive) |
| Pin 13 | Serial RxD (iPod in) | direct | TX (Transmit) |
| Pin 16 | GND | direct | GND |

### ASCII Wiring Diagram

```
iPod 30-pin Dock (via Breakout Board)          USB-to-UART Adapter (FT232RL @ 3.3V)
─────────────────────────────────────          ─────────────────────────────────────

Pin 21 (Accessory Enable) ───[500kΩ]─────────── GND (adapter ground)
                                                 │
Pin 12 (Serial TxD) ─────────────────────────── RX (Receive on adapter)
                                                 │
Pin 13 (Serial RxD) ─────────────────────────── TX (Transmit on adapter)
                                                 │
Pin 16 (GND) ────────────────────────────────── GND (Ground on adapter)

                                                 │
Adapter USB ────────────────────────────────── Mac USB port
```

### Resistor Selection for Pin 21

The resistor on Pin 21 enables TTL-level serial mode (3.3V):

| Resistor Value | Notes |
|----------------|-------|
| **500kΩ** | Recommended starting point; community consensus for reliable TTL serial on 5G/5.5G |
| 6.8kΩ | Alternative drawn from some accessory protocols; may work |

Start with 500kΩ if testing. Either value should work, but 500kΩ has broader community validation.

---

## Wiring Notes

- **Jumper wires**: Use female-to-male Dupont jumper wires for easy connections
- **Power**: No power wiring needed; the iPod runs on its internal battery
- **RX line (Pin 13)**: Optional if you only need to read logs (TX output). Required for sending commands
- **Voltage**: Ensure your USB-to-UART adapter is set to **3.3V mode** (not 5V)
- **Baud rate**: 19200 bps (default for Rockbox serial); adjustable to 115200 in Rockbox settings

---

## Shopping List

All parts are off-the-shelf with no custom PCBs required. Prices are approximate as of January 2026.

### 1. 30-pin Male Breakout Board (~$15–20)

Plugs directly into the iPod's dock connector and exposes all pins to headers for wiring.

| Option | Source | Notes |
|--------|--------|-------|
| **PodBreakout v1.5** | Tindie | Recommended; easy to use, pre-soldered |
| Apple 30-pin Male Plug Breakout | ElabBay | Alternative option |

### 2. USB-to-UART Adapter (~$10–20)

Converts serial signals to USB. Must support 3.3V logic levels.

| Option | Source | Notes |
|--------|--------|-------|
| **SparkFun USB to Serial Breakout - FT232RL** | SparkFun | Recommended; reliable with Mac drivers |
| FTDI FT232RL USB to Serial Adapter | Amazon | Alternative; includes Mac drivers |

**Important**: Set the jumper to 3.3V mode before use.

### 3. Resistor (~$1–5 for assorted pack)

For enabling serial mode on Pin 21.

| Specification | Source |
|---------------|--------|
| 500kΩ or 6.8kΩ, 1/4W | Amazon, Digi-Key, or any electronics supplier |

Search for "500k ohm resistor 1/4W" or buy an assorted resistor kit.

### 4. Jumper Wires (~$5 for a pack)

For connecting the breakout board to the adapter.

| Specification | Source |
|---------------|--------|
| Male-to-female Dupont wires, 10–20cm | Amazon |

Search for "dupont jumper wires 20cm".

---

## Software Setup on Mac

### Install Rockbox on iPod

Rockbox is essential for meaningful log output. Install it first via USB from [rockbox.org](https://www.rockbox.org/).

After installation, enable serial output:
1. Navigate to **System > Debug > View HW info**
2. Or enable logging in Rockbox settings
3. Enable "Serial Port" in settings for console output

### Terminal Software

Install a serial terminal application on your Mac:

#### Option 1: screen (built-in)

```bash
# Find your device
ls /dev/tty.usbserial*

# Connect (replace XXXX with your device identifier)
screen /dev/tty.usbserial-XXXX 19200
```

To exit screen: Press `Ctrl+A`, then `K`, then `Y`.

#### Option 2: minicom (via Homebrew)

```bash
# Install
brew install minicom

# Configure
minicom -s
# Set serial device to /dev/tty.usbserial-XXXX
# Set baud rate to 19200
# Save as default

# Run
minicom
```

### Baud Rate Settings

| Firmware | Default Baud Rate | Notes |
|----------|-------------------|-------|
| Rockbox | 19200 | Adjustable to 115200 in settings |
| Stock Apple | N/A | Minimal or no output expected |

---

## Testing the Setup

1. Connect all wiring as described above
2. Plug the USB-to-UART adapter into your Mac
3. Open a terminal and start your serial monitor
4. Power on the iPod

### Expected Output

| Firmware | Expected Output |
|----------|-----------------|
| Rockbox | Boot messages, debug info, errors, or interactive shell if configured |
| Stock Apple | Limited to accessory handshakes, if anything |

---

## Troubleshooting

| Issue | Solution |
|-------|----------|
| No output at all | Verify Rockbox is installed and serial is enabled in settings |
| Garbled characters | Check baud rate matches (19200 default) |
| Device not found | Run `ls /dev/tty*` to find correct device path |
| Intermittent connection | Check jumper wire connections; try different resistor value |
| Adapter not recognized | Install FTDI drivers for Mac if needed |

---

## Additional Resources

- [Rockbox Official Site](https://www.rockbox.org/) - Firmware installation and documentation
- [Rockbox Wiki](https://www.rockbox.org/wiki/) - Serial debugging documentation
- iPod modding community forums for pinout verification

---

## References

This setup is based on well-documented information from the iPod hacking and modding community, including Rockbox documentation:

- **Pinout**: Pin assignments (12/TX, 13/RX, 16/GND, 21/Enable) match confirmed hardware specs for iPod Video models (5G/5.5G)
- **Serial Enable**: Resistor on Pin 21 to GND is a standard method for enabling TTL serial mode
- **Baud Rate**: 19200 is the Rockbox default, configurable to 115200
- **Shopping List**: All items verified as available from listed vendors as of January 2026
