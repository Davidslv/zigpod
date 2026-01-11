//! ZigPod Emulator - PP5021C Emulator for iPod 5th/5.5th Gen
//!
//! Usage: zigpod-emulator [options] [disk-image]
//!
//! Options:
//!   --firmware <file>   Load firmware from file
//!   --sdram <size>      SDRAM size in MB (32 or 64, default: 32)
//!   --headless          Run without display (even if SDL2 available)
//!   --debug             Enable debug output
//!   --help              Show this help

const std = @import("std");
const build_options = @import("build_options");
const core = @import("core.zig");
const ata = @import("peripherals/ata.zig");

const Emulator = core.Emulator;
const EmulatorConfig = core.EmulatorConfig;

// Conditionally import SDL frontend
const sdl_frontend = if (build_options.enable_sdl2)
    @import("frontend/sdl_frontend.zig")
else
    struct {};

/// File-backed disk for ATA
const FileDisk = struct {
    file: std.fs.File,
    sector_count: u64,

    const Self = @This();

    pub fn init(path: []const u8) !Self {
        const file = try std.fs.cwd().openFile(path, .{ .mode = .read_write });
        const stat = try file.stat();
        const sector_count = stat.size / 512;

        return .{
            .file = file,
            .sector_count = sector_count,
        };
    }

    pub fn deinit(self: *Self) void {
        self.file.close();
    }

    pub fn createBackend(self: *Self) ata.DiskBackend {
        return .{
            .context = @ptrCast(self),
            .sector_count = self.sector_count,
            .readFn = readSector,
            .writeFn = writeSector,
        };
    }

    fn readSector(ctx: *anyopaque, lba: u64, buffer: *[512]u8) bool {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.file.seekTo(lba * 512) catch return false;
        const bytes_read = self.file.readAll(buffer) catch return false;
        return bytes_read == 512;
    }

    fn writeSector(ctx: *anyopaque, lba: u64, buffer: *const [512]u8) bool {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.file.seekTo(lba * 512) catch return false;
        self.file.writeAll(buffer) catch return false;
        return true;
    }
};

/// Simple output writer using stack buffer
fn print(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    std.fs.File.stdout().writeAll(msg) catch {};
}

fn printErr(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    std.fs.File.stderr().writeAll(msg) catch {};
}

fn printUsage() void {
    const sdl_status = if (build_options.enable_sdl2) "enabled" else "disabled";
    var buf: [2048]u8 = undefined;
    const usage = std.fmt.bufPrint(&buf,
        \\ZigPod Emulator - PP5021C Emulator for iPod 5th/5.5th Gen
        \\
        \\SDL2 support: {s}
        \\
        \\Usage: zigpod-emulator [options] [disk-image]
        \\
        \\Options:
        \\  --firmware <file>   Load firmware from file (at boot ROM address 0)
        \\  --load-iram <file>  Load firmware at IRAM (0x40000000)
        \\  --load-sdram <file> Load firmware at SDRAM (0x10000000)
        \\  --sdram <size>      SDRAM size in MB (32 or 64, default: 32)
        \\  --headless          Run without display
        \\  --debug             Enable debug output
        \\  --trace <n>         Trace first n instructions
        \\  --cycles <n>        Run for n cycles then exit (headless only)
        \\  --gdb-port <port>   Enable GDB debugging on specified port
        \\  --help              Show this help
        \\
        \\Keyboard controls (with SDL2):
        \\  Enter       - Select (center button)
        \\  Escape/M    - Menu
        \\  Space/P     - Play/Pause
        \\  Right/N     - Next track
        \\  Left/B      - Previous track
        \\  Up/Down     - Scroll wheel
        \\  H           - Toggle hold switch
        \\
        \\Example:
        \\  zigpod-emulator --firmware boot.bin ipod.img
        \\
    , .{sdl_status}) catch return;
    std.fs.File.stdout().writeAll(usage) catch {};
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse arguments
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    var firmware_path: ?[]const u8 = null;
    var iram_firmware_path: ?[]const u8 = null;
    var sdram_firmware_path: ?[]const u8 = null;
    var disk_path: ?[]const u8 = null;
    var sdram_mb: usize = 32;
    var headless = false;
    var debug = false;
    var trace_count: u64 = 0;
    var max_cycles: ?u64 = null;
    var gdb_port: ?u16 = null;

    // Skip program name
    _ = args.next();

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage();
            return;
        } else if (std.mem.eql(u8, arg, "--firmware")) {
            firmware_path = args.next() orelse {
                printErr("Error: --firmware requires a file path\n", .{});
                return error.InvalidArguments;
            };
        } else if (std.mem.eql(u8, arg, "--load-iram")) {
            iram_firmware_path = args.next() orelse {
                printErr("Error: --load-iram requires a file path\n", .{});
                return error.InvalidArguments;
            };
        } else if (std.mem.eql(u8, arg, "--load-sdram")) {
            sdram_firmware_path = args.next() orelse {
                printErr("Error: --load-sdram requires a file path\n", .{});
                return error.InvalidArguments;
            };
        } else if (std.mem.eql(u8, arg, "--trace")) {
            const trace_str = args.next() orelse {
                printErr("Error: --trace requires a number\n", .{});
                return error.InvalidArguments;
            };
            trace_count = try std.fmt.parseInt(u64, trace_str, 10);
        } else if (std.mem.eql(u8, arg, "--sdram")) {
            const size_str = args.next() orelse {
                printErr("Error: --sdram requires a size\n", .{});
                return error.InvalidArguments;
            };
            sdram_mb = try std.fmt.parseInt(usize, size_str, 10);
            if (sdram_mb != 32 and sdram_mb != 64) {
                printErr("Error: --sdram must be 32 or 64\n", .{});
                return error.InvalidArguments;
            }
        } else if (std.mem.eql(u8, arg, "--headless")) {
            headless = true;
        } else if (std.mem.eql(u8, arg, "--debug")) {
            debug = true;
        } else if (std.mem.eql(u8, arg, "--cycles")) {
            const cycles_str = args.next() orelse {
                printErr("Error: --cycles requires a number\n", .{});
                return error.InvalidArguments;
            };
            max_cycles = try std.fmt.parseInt(u64, cycles_str, 10);
        } else if (std.mem.eql(u8, arg, "--gdb-port")) {
            const port_str = args.next() orelse {
                printErr("Error: --gdb-port requires a port number\n", .{});
                return error.InvalidArguments;
            };
            gdb_port = try std.fmt.parseInt(u16, port_str, 10);
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            disk_path = arg;
        } else {
            printErr("Unknown option: {s}\n", .{arg});
            return error.InvalidArguments;
        }
    }

    // Initialize emulator
    print("ZigPod Emulator starting...\n", .{});

    // Load firmware if provided (loaded as boot ROM at address 0)
    var firmware: ?[]u8 = null;
    if (firmware_path) |path| {
        print("Loading firmware: {s}\n", .{path});
        firmware = try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
        print("Loaded {d} bytes\n", .{firmware.?.len});
    }
    defer if (firmware) |fw| allocator.free(fw);

    var emu = try Emulator.init(allocator, .{
        .sdram_size = sdram_mb * 1024 * 1024,
        .cpu_freq_mhz = 80,
        .boot_rom = firmware,
    });
    defer emu.deinit();

    // Setup LCD bridge pointer now that emulator is in final memory location
    emu.setupLcdBridge();
    emu.registerPeripherals();

    // Open disk image if provided
    var disk: ?FileDisk = null;
    var disk_backend: ?ata.DiskBackend = null;

    if (disk_path) |path| {
        print("Opening disk image: {s}\n", .{path});
        disk = try FileDisk.init(path);
        disk_backend = disk.?.createBackend();
        emu.setDisk(&disk_backend.?);
        print("Disk: {d} sectors ({d} MB)\n", .{
            disk.?.sector_count,
            disk.?.sector_count * 512 / (1024 * 1024),
        });
    }
    defer if (disk) |*d| d.deinit();

    // Load SDRAM firmware if provided
    var sdram_firmware: ?[]u8 = null;
    if (sdram_firmware_path) |path| {
        print("Loading SDRAM firmware: {s}\n", .{path});
        sdram_firmware = try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
        print("Loaded {d} bytes at SDRAM (0x10000000)\n", .{sdram_firmware.?.len});
        emu.loadSdram(0, sdram_firmware.?);
    }
    defer if (sdram_firmware) |fw| allocator.free(fw);

    // Load IRAM firmware if provided
    var iram_firmware: ?[]u8 = null;
    if (iram_firmware_path) |path| {
        print("Loading IRAM firmware: {s}\n", .{path});
        iram_firmware = try std.fs.cwd().readFileAlloc(allocator, path, 96 * 1024); // IRAM is 96KB
        print("Loaded {d} bytes at IRAM (0x40000000)\n", .{iram_firmware.?.len});
        emu.loadIram(iram_firmware.?);
    }
    defer if (iram_firmware) |fw| allocator.free(fw);

    // Reset and start
    emu.reset();

    // Set PC based on where firmware was loaded
    if (iram_firmware_path != null) {
        emu.cpu.setPc(0x40000000);
        print("PC set to 0x40000000 (IRAM)\n", .{});
    } else if (sdram_firmware_path != null) {
        emu.cpu.setPc(0x10000000);
        print("PC set to 0x10000000 (SDRAM)\n", .{});
    }

    if (debug) {
        print("CPU: PC=0x{X:0>8}, Mode={s}, Thumb={}\n", .{
            emu.getPc(),
            if (emu.cpu.getMode()) |m| @tagName(m) else "unknown",
            emu.isThumb(),
        });
    }

    // Trace mode - run n instructions with detailed output
    if (trace_count > 0) {
        print("Tracing first {d} instructions:\n", .{trace_count});
        var i: u64 = 0;
        while (i < trace_count) : (i += 1) {
            const pc_before = emu.getPc();
            const is_thumb = emu.isThumb();
            const instr = if (is_thumb)
                @as(u32, emu.bus.read16(pc_before))
            else
                emu.bus.read32(pc_before);

            const cycles = emu.step();

            print("[{d:>4}] PC=0x{X:0>8} {s} instr=0x{X:0>8} R0-3: {X:0>8} {X:0>8} {X:0>8} {X:0>8} cy={d}\n", .{
                i,
                pc_before,
                if (is_thumb) "T" else "A",
                instr,
                emu.getReg(0),
                emu.getReg(1),
                emu.getReg(2),
                emu.getReg(3),
                cycles,
            });
        }
        print("Trace complete. PC now at 0x{X:0>8}\n", .{emu.getPc()});
        return;
    }

    // Enable GDB debugging if requested
    if (gdb_port) |port| {
        print("Enabling GDB debugging on port {d}...\n", .{port});
        emu.enableGdb(port) catch |err| {
            printErr("Failed to enable GDB: {}\n", .{err});
            return error.GdbInitFailed;
        };
        print("GDB stub listening on port {d}\n", .{port});
        print("Connect with: arm-none-eabi-gdb -ex 'target remote :{d}'\n", .{port});
        print("Waiting for GDB connection...\n", .{});
    }

    // Run emulator
    if (headless or !build_options.enable_sdl2) {
        // Headless mode
        if (!headless and !build_options.enable_sdl2) {
            print("SDL2 not enabled. Running in headless mode.\n", .{});
            print("Rebuild with -Dsdl2=true to enable graphical frontend.\n", .{});
        }

        if (max_cycles) |cycles| {
            print("Running for {d} cycles...\n", .{cycles});
            const actual_cycles = if (emu.isGdbEnabled())
                emu.runWithGdb(cycles)
            else
                emu.run(cycles);
            print("Executed {d} cycles\n", .{actual_cycles});
        } else {
            if (emu.isGdbEnabled()) {
                print("Running with GDB debugging (Ctrl+C in GDB to stop)...\n", .{});
            } else {
                print("Running in headless mode (Ctrl+C to stop)...\n", .{});
            }
            while (true) {
                if (emu.isGdbEnabled()) {
                    _ = emu.runWithGdb(1_000_000);
                } else {
                    _ = emu.run(1_000_000);
                }

                if (debug) {
                    print("Cycles: {d}, PC: 0x{X:0>8}\n", .{
                        emu.total_cycles,
                        emu.getPc(),
                    });
                }
            }
        }
    } else {
        // SDL2 graphical mode
        if (build_options.enable_sdl2) {
            print("Initializing SDL2 frontend...\n", .{});

            var frontend = sdl_frontend.SdlFrontend.init(allocator, &emu) catch |err| {
                printErr("Failed to initialize SDL2 frontend: {}\n", .{err});
                printErr("Falling back to headless mode.\n", .{});

                // Fallback to headless
                if (max_cycles) |cycles| {
                    _ = emu.run(cycles);
                }
                return;
            };
            defer frontend.deinit();

            print("Window: {d}x{d} (scale {d}x)\n", .{
                sdl_frontend.WINDOW_WIDTH,
                sdl_frontend.WINDOW_HEIGHT,
                sdl_frontend.SCALE,
            });
            print("Press ESC or close window to quit.\n", .{});

            // Run main loop
            frontend.run();
        }
    }

    // Print debug stats
    const lcd_stats = emu.lcd_ctrl.getDebugStats();
    print("LCD stats: {d} pixel writes, {d} updates, last_offset=0x{X:0>8}\n", .{
        lcd_stats.pixel_writes,
        lcd_stats.update_count,
        lcd_stats.last_offset,
    });
    print("Bus LCD writes: {d}\n", .{emu.bus.lcd_write_count});
    print("Bus LCD bridge writes: {d}\n", .{emu.bus.lcd_bridge_write_count});

    // LCD2 bridge debug
    const lcd_mod = @import("peripherals/lcd.zig");
    print("LCD2 bridge: total={d}, data={d}, ctrl={d}, starts={d}, last_ctrl=0x{X:0>8}\n", .{
        lcd_mod.Lcd2Bridge.debug_total_writes,
        lcd_mod.Lcd2Bridge.debug_block_data_writes,
        lcd_mod.Lcd2Bridge.debug_block_ctrl_writes,
        lcd_mod.Lcd2Bridge.debug_block_start_count,
        lcd_mod.Lcd2Bridge.debug_last_ctrl_value,
    });
    print("LCD2 pixels: written={d}, active_false={d}, remaining_zero={d}\n", .{
        lcd_mod.Lcd2Bridge.debug_pixels_written,
        lcd_mod.Lcd2Bridge.debug_block_active_false,
        lcd_mod.Lcd2Bridge.debug_pixels_remaining_zero,
    });

    // ATA debug
    const ata_mod = @import("peripherals/ata.zig");
    print("ATA: data_reads={d}, not_ready={d}, first_byte=0x{X:0>2}\n", .{
        ata_mod.AtaController.debug_data_reads,
        ata_mod.AtaController.debug_data_reads_not_ready,
        ata_mod.AtaController.debug_last_buffer_byte,
    });
    print("ATA disk: reads={d}, success={d}, null={d}, mbr_sig=0x{X:0>4}\n", .{
        ata_mod.AtaController.debug_disk_reads,
        ata_mod.AtaController.debug_disk_read_success,
        ata_mod.AtaController.debug_disk_null,
        ata_mod.AtaController.debug_mbr_sig,
    });

    // I2S debug
    const i2s_mod = @import("peripherals/i2s.zig");
    print("I2S: samples_written={d}, callbacks={d}, samples_sent={d}\n", .{
        i2s_mod.I2sController.debug_samples_written,
        i2s_mod.I2sController.debug_callbacks_triggered,
        i2s_mod.I2sController.debug_samples_sent,
    });

    // Memory dump for test verification at RESULT_BASE = 0x40000100 (IRAM)
    print("\n=== Test Results at 0x40000100 ===\n", .{});
    var offset: u32 = 0;
    while (offset < 120) : (offset += 4) {
        const val = emu.bus.read32(0x40000100 + offset);
        // Try to interpret as ASCII if looks like a marker
        if ((val >> 24) >= 0x40 and (val >> 24) <= 0x7A) {
            const bytes: [4]u8 = @bitCast(@byteSwap(val));
            print("  +{d:>3}: 0x{X:0>8} \"{s}\"\n", .{ offset, val, bytes });
        } else {
            print("  +{d:>3}: 0x{X:0>8}\n", .{ offset, val });
        }
    }
    print("=================================\n", .{});

    const result_marker = emu.bus.read32(0x40000100);
    const result_4 = emu.bus.read32(0x40000104);
    const result_8 = emu.bus.read32(0x40000108);
    const result_12 = emu.bus.read32(0x4000010C);

    if (result_marker == 0xCAFEBABE) {
        print("ATA TEST PASSED: MBR signature 0xAA55 found!\n", .{});
    } else if (result_marker == 0xDEADDEAD) {
        print("ATA TEST FAILED: MBR signature mismatch (got 0x{X:0>4})\n", .{result_4 & 0xFFFF});
    } else if (result_marker == 0xA0D10001) {
        print("AUDIO TEST: started\n", .{});
        if (result_4 == 0xA0D10002) {
            print("AUDIO TEST: I2S enabled\n", .{});
        }
        if (result_8 == 0xA0D100CE) {
            print("AUDIO TEST PASSED: {d} samples written\n", .{result_12});
        } else {
            print("AUDIO TEST: still running (or incomplete)\n", .{});
        }
    }

    if (debug) {
        print("Final state: PC=0x{X:0>8}, Cycles={d}\n", .{
            emu.getPc(),
            emu.total_cycles,
        });
    }

    print("Emulator stopped.\n", .{});
}

// Tests
test "argument parsing" {
    // Just ensure the module compiles
    _ = main;
}
