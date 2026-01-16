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
        \\  --enable-cop        Enable COP (second core) for dual-core firmware
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
    var sdram_mb: usize = 32; // Default to 32MB for 30GB iPod 5G (Rockbox auto-detects RAM size at runtime)
    var headless = false;
    var debug = false;
    var trace_count: u64 = 0;
    var max_cycles: ?u64 = null;
    var gdb_port: ?u16 = null;
    var entry_point: ?u32 = null; // Custom entry point (e.g., 0x10000800 for Apple firmware)
    var enable_cop = false; // Enable COP (second core) for dual-core firmware

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
        } else if (std.mem.eql(u8, arg, "--entry")) {
            const entry_str = args.next() orelse {
                printErr("Error: --entry requires an address (e.g., 0x10000800)\n", .{});
                return error.InvalidArguments;
            };
            // Parse hex address (with or without 0x prefix)
            const hex_str = if (std.mem.startsWith(u8, entry_str, "0x") or std.mem.startsWith(u8, entry_str, "0X"))
                entry_str[2..]
            else
                entry_str;
            entry_point = try std.fmt.parseInt(u32, hex_str, 16);
        } else if (std.mem.eql(u8, arg, "--enable-cop")) {
            enable_cop = true;
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
    var firmware_data: ?[]const u8 = null;
    if (firmware_path) |path| {
        print("Loading firmware: {s}\n", .{path});
        firmware = try std.fs.cwd().readFileAlloc(allocator, path, 16 * 1024 * 1024);

        // Check for iPod bootloader header ("ipvd" signature at offset 4)
        var fw = firmware.?;
        if (fw.len >= 8 and fw[4] == 'i' and fw[5] == 'p' and fw[6] == 'v' and fw[7] == 'd') {
            print("Detected iPod bootloader header, skipping 8-byte header\n", .{});
            firmware_data = fw[8..];
        } else {
            firmware_data = fw;
        }
        print("Loaded {d} bytes\n", .{firmware_data.?.len});
    }
    defer if (firmware) |fw| allocator.free(fw);

    var emu = try Emulator.init(allocator, .{
        .sdram_size = sdram_mb * 1024 * 1024,
        .cpu_freq_mhz = 80,
        .boot_rom = firmware_data,
        .enable_cop = enable_cop,
    });

    if (enable_cop) {
        print("COP (second core) enabled\n", .{});
    }
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
        sdram_firmware = try std.fs.cwd().readFileAlloc(allocator, path, 16 * 1024 * 1024); // 16MB max for large firmware

        // Check for iPod firmware header (model identifier at offset 4)
        // Format: 4 bytes checksum + 4 bytes model ("ipvd", "ipod", "ip6g", etc.) + firmware data
        var fw_data = sdram_firmware.?;
        if (fw_data.len >= 8 and (std.mem.eql(u8, fw_data[4..8], "ipvd") or
            std.mem.eql(u8, fw_data[4..8], "ipod") or
            std.mem.eql(u8, fw_data[4..8], "ip3g") or
            std.mem.eql(u8, fw_data[4..8], "ip4g") or
            std.mem.eql(u8, fw_data[4..8], "ip5g") or
            std.mem.eql(u8, fw_data[4..8], "ip6g")))
        {
            print("Detected iPod firmware header (model: {s}), skipping 8-byte header\n", .{fw_data[4..8]});
            fw_data = fw_data[8..];
        }

        print("Loaded {d} bytes at SDRAM (0x10000000)\n", .{fw_data.len});
        emu.loadSdram(0, fw_data);

        // For Apple firmware (osos.bin), emulate Boot ROM initialization:
        // Copy SWI handler and other code from firmware to IRAM
        // This is what real Boot ROM does before jumping to firmware entry point
        emu.bus.initAppleFirmwareIram();

        // Initialize FAT32 disk buffer with iPod_Control directory
        // The firmware scans for this directory during boot
        emu.bus.initFat32DiskBuffer();
    }
    defer if (sdram_firmware) |fw| allocator.free(fw);

    // Load IRAM firmware if provided
    var iram_firmware: ?[]u8 = null;
    if (iram_firmware_path) |path| {
        print("Loading IRAM firmware: {s}\n", .{path});
        iram_firmware = try std.fs.cwd().readFileAlloc(allocator, path, 96 * 1024); // IRAM is 96KB

        // Check for iPod bootloader header ("ipvd" signature at offset 4)
        var fw_data = iram_firmware.?;
        if (fw_data.len >= 8 and fw_data[4] == 'i' and fw_data[5] == 'p' and fw_data[6] == 'v' and fw_data[7] == 'd') {
            print("Detected iPod bootloader header, skipping 8-byte header\n", .{});
            fw_data = fw_data[8..];
        }

        print("Loaded {d} bytes at IRAM (0x40000000)\n", .{fw_data.len});
        emu.loadIram(fw_data);

        // BOOTLOADER PATCH: The Rockbox bootloader contains a self-copy routine that
        // expects to run from ROM and copy itself to IRAM. When loaded directly to IRAM,
        // it copies itself over itself, then jumps via LDR PC at offset 0x28 which loads
        // from [0x2D4] = 0x40000024 (back into the copy loop).
        //
        // We can't patch the data at 0x2D4 because the copy loop overwrites it.
        // Instead, NOP the LDR PC instruction at 0x28 so execution falls through
        // to the real boot code at 0x2C.
        const ldr_pc_addr: u32 = 0x40000028;
        const ldr_pc_instr = emu.bus.read32(ldr_pc_addr);
        if (ldr_pc_instr == 0xE59FF2A4) { // LDR PC, [PC, #0x2A4]
            emu.bus.write32(ldr_pc_addr, 0xE1A00000); // NOP
            print("BOOTLOADER PATCH: NOP'd LDR PC at 0x{X:0>8} (was 0x{X:0>8})\n", .{ ldr_pc_addr, ldr_pc_instr });
        }
    }
    defer if (iram_firmware) |fw| allocator.free(fw);

    // Reset and start
    emu.reset();

    // Set PC based on where firmware was loaded (or custom entry point)
    if (entry_point) |ep| {
        emu.cpu.setPc(ep);
        print("CPU PC set to 0x{X:0>8} (custom entry point)\n", .{ep});
        // Also initialize COP at the same entry point if enabled
        // Both cores start at the same address; firmware checks PROC_ID to differentiate
        if (enable_cop) {
            emu.initCop(ep);
            print("COP PC set to 0x{X:0>8} (same entry point)\n", .{ep});
        }
    } else if (iram_firmware_path != null) {
        emu.cpu.setPc(0x40000000);
        print("PC set to 0x40000000 (IRAM)\n", .{});
    } else if (sdram_firmware_path != null) {
        // Apple firmware has a 0x800 byte header; entry point is at 0x10000800
        // Check for "portalplayer" signature in header to detect Apple firmware
        const is_apple_firmware = sdram_firmware != null and sdram_firmware.?.len > 0x830 and
            std.mem.eql(u8, sdram_firmware.?[0x820..0x82C], "portalplayer");

        if (is_apple_firmware) {
            emu.cpu.setPc(0x10000800);
            print("PC set to 0x10000800 (Apple firmware entry)\n", .{});
            if (enable_cop) {
                emu.initCop(0x10000800);
                print("COP PC set to 0x10000800 (Apple firmware entry)\n", .{});
            }
        } else {
            // Rockbox firmware - let crt0 configure MMAP itself
            // Rockbox is linked at DRAMORIG=0x00000000 (virtual address 0)
            // Physical SDRAM starts at 0x10000000
            //
            // IMPORTANT: Do NOT pre-enable MMAP! The crt0 code at 0x17C does:
            //   r6 = pc & 0xFF000000
            // When running from physical 0x1000017C, r6 = 0x10000000 (correct)
            // When running from virtual 0x17C, r6 = 0x00000000 (wrong!)
            //
            // So we must start from physical address 0x10000000 (the actual entry point).
            emu.bus.mmap_enabled = false;
            emu.rockbox_restart_count = 1; // Skip COP sync detection since we're loading directly
            print("MMAP disabled - crt0 will configure it\n", .{});

            // Set PC to physical entry point (0x10000000 = SDRAM start, actual crt0 entry)
            const rockbox_entry: u32 = 0x10000000;
            emu.cpu.setPc(rockbox_entry);

            // Initialize LR to 0 - Rockbox doesn't return to bootloader
            emu.cpu.regs.r[14] = 0;

            // Initialize SP (R13) to physical stack location in SDRAM
            emu.cpu.regs.r[13] = 0x11FFFFE0;

            print("PC set to physical 0x{X:0>8}\n", .{rockbox_entry});
            print("LR=0x0 (halt on invalid return), SP=0x11FFFFE0 (physical)\n", .{});
            if (enable_cop) {
                emu.initCop(rockbox_entry);
                print("COP PC set to 0x{X:0>8} (same entry point)\n", .{rockbox_entry});
            }
        }
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
            print("Final PC: 0x{X:0>8}, Mode: {s}, Thumb: {}\n", .{
                emu.getPc(),
                if (emu.cpu.getMode()) |m| @tagName(m) else "unknown",
                emu.isThumb(),
            });
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
    print("Bus SDRAM writes: {d}, IRAM writes: {d}\n", .{emu.bus.sdram_write_count, emu.bus.iram_write_count});
    print("First SDRAM write: addr=0x{X:0>8}, value=0x{X:0>8}\n", .{emu.bus.first_sdram_write_addr, emu.bus.first_sdram_write_value});

    // Peripheral access counts (for Apple firmware analysis)
    print("\n=== Peripheral Access Counts ===\n", .{});
    print("  Timers:     {d}\n", .{emu.bus.debug_timer_accesses});
    print("  GPIO:       {d}\n", .{emu.bus.debug_gpio_accesses});
    print("  I2C:        {d}\n", .{emu.bus.debug_i2c_accesses});
    print("  Sys Ctrl:   {d}\n", .{emu.bus.debug_sys_ctrl_accesses});
    print("  Int Ctrl:   {d}\n", .{emu.bus.debug_int_ctrl_accesses});
    print("  Mailbox:    {d}\n", .{emu.bus.debug_mailbox_accesses});
    print("  Dev Init:   {d}\n", .{emu.bus.debug_dev_init_accesses});

    // Device init offset histogram (show non-zero only)
    print("  Dev Init Offset Histogram:\n", .{});
    for (emu.bus.debug_dev_init_offset_counts, 0..) |count, idx| {
        if (count > 0) {
            print("    0x{X:0>2}: {d} accesses\n", .{ idx * 4, count });
        }
    }

    // Interrupt controller offset histogram (show top entries)
    print("  Int Ctrl Offset Histogram (top 10):\n", .{});
    // Find top 10 by sorting indices
    var int_indices: [64]usize = undefined;
    for (0..64) |i| {
        int_indices[i] = i;
    }
    // Simple bubble sort for top 10
    for (0..10) |i| {
        for (i + 1..64) |j| {
            if (emu.bus.debug_int_ctrl_offset_counts[int_indices[j]] > emu.bus.debug_int_ctrl_offset_counts[int_indices[i]]) {
                const tmp = int_indices[i];
                int_indices[i] = int_indices[j];
                int_indices[j] = tmp;
            }
        }
    }
    for (0..10) |i| {
        const idx = int_indices[i];
        const count = emu.bus.debug_int_ctrl_offset_counts[idx];
        if (count > 0) {
            print("    0x{X:0>3}: {d} accesses\n", .{ idx * 4, count });
        }
    }

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
    print("LCD BCM: wr_addr_count={d}, first=0x{X:0>8}, last=0x{X:0>8}\n", .{
        lcd_mod.LcdController.debug_wr_addr_count,
        lcd_mod.LcdController.debug_first_wr_addr,
        lcd_mod.LcdController.debug_last_wr_addr,
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
    print("ATA part1: type=0x{X:0>2}, lba={d}, sectors={d}\n", .{
        ata_mod.AtaController.debug_part1_type,
        ata_mod.AtaController.debug_part1_lba,
        ata_mod.AtaController.debug_part1_sectors,
    });
    print("ATA part bytes read ({d}): ", .{ata_mod.AtaController.debug_part_bytes_captured});
    for (ata_mod.AtaController.debug_part_bytes) |b| {
        print("{X:0>2} ", .{b});
    }
    print("\n", .{});
    print("ATA s0 words read: {d}, s0 loads: {d}\n", .{ ata_mod.AtaController.debug_s0_words_read, ata_mod.AtaController.debug_sector0_loads });
    print("ATA first 8 words: ", .{});
    for (ata_mod.AtaController.debug_first_8_words) |w| {
        print("{X:0>4} ", .{w});
    }
    print("\n", .{});
    print("ATA s0 key words: @1BE={X:0>4}, @1C0={X:0>4}, @1C2={X:0>4}, @1FE={X:0>4}\n", .{
        ata_mod.AtaController.debug_s0_word_at_1be,
        ata_mod.AtaController.debug_s0_word_at_1c0,
        ata_mod.AtaController.debug_s0_word_at_1c2,
        ata_mod.AtaController.debug_s0_word_at_1fe,
    });
    print("ATA part words returned: 0xE0={X:0>4}, 0xE1={X:0>4}, 0xE3={X:0>4}, 0xE4={X:0>4}, 0xE5={X:0>4}, 0xE6={X:0>4}\n", .{
        ata_mod.AtaController.debug_part_word_0xE0,
        ata_mod.AtaController.debug_part_word_0xE1,
        ata_mod.AtaController.debug_part_word_0xE3,
        ata_mod.AtaController.debug_part_word_0xE4,
        ata_mod.AtaController.debug_part_word_0xE5,
        ata_mod.AtaController.debug_part_word_0xE6,
    });
    print("ATA commands: count={d}, last_cmd=0x{X:0>2}\n", .{
        ata_mod.AtaController.debug_cmd_count,
        ata_mod.AtaController.debug_last_cmd,
    });

    // ATA->Memory write tracking
    print("ATA writes tracked: total={d}, to_sdram={d}, to_iram={d}, mbr_area={d}\n", .{
        emu.bus.debug_ata_write_count,
        emu.bus.debug_ata_writes_to_sdram,
        emu.bus.debug_ata_writes_to_iram,
        emu.bus.debug_mbr_area_writes,
    });
    print("ATA first 8 writes:\n", .{});
    for (emu.bus.debug_ata_write_addrs, 0..) |addr, idx| {
        if (addr != 0 or idx == 0) {
            print("  [{d}] 0x{X:0>8} = 0x{X:0>8}\n", .{ idx, addr, emu.bus.debug_ata_write_vals[idx] });
        }
    }
    print("MBR value writes: {d}, last: 0x{X:0>8} = 0x{X:0>8}\n", .{
        emu.bus.debug_mbr_value_writes,
        emu.bus.debug_mbr_value_last_addr,
        emu.bus.debug_mbr_value_last_val,
    });

    // Dump MBR partition table area in IRAM (at 0x4000E7FC + 0x1BE = 0x4000E9BA)
    print("=== MBR Partition Table in IRAM ===\n", .{});
    const mbr_base: u32 = 0x4000E7FC;
    const part_table_offset: u32 = 0x1BE;
    const part1_addr = mbr_base + part_table_offset;
    print("  MBR base: 0x{X:0>8}, Part1 at: 0x{X:0>8}\n", .{ mbr_base, part1_addr });
    print("  Partition 1 raw bytes: ", .{});
    var pb: u32 = 0;
    while (pb < 16) : (pb += 1) {
        print("{X:0>2} ", .{emu.bus.read8(part1_addr + pb)});
    }
    print("\n", .{});
    // Decode partition entry
    const p1_boot = emu.bus.read8(part1_addr + 0);
    const p1_type = emu.bus.read8(part1_addr + 4);
    const p1_lba = emu.bus.read32(part1_addr + 8);
    const p1_size = emu.bus.read32(part1_addr + 12);
    print("  Partition 1: boot=0x{X:0>2}, type=0x{X:0>2}, lba=0x{X:0>8}, size=0x{X:0>8}\n", .{
        p1_boot, p1_type, p1_lba, p1_size,
    });
    // Also dump boot signature area
    const boot_sig_addr = mbr_base + 0x1FE;
    print("  Boot signature at 0x{X:0>8}: 0x{X:0>4}\n", .{
        boot_sig_addr,
        emu.bus.read16(boot_sig_addr),
    });

    // Comprehensive search for MBR in IRAM
    print("=== Searching IRAM for MBR boot signature (0xAA55) ===\n", .{});
    var mbr_found: u32 = 0;
    var iram_search: u32 = 0x40000000;
    while (iram_search < 0x40017FFC) : (iram_search += 2) {
        const word = emu.bus.read16(iram_search);
        if (word == 0xAA55) {
            mbr_found += 1;
            if (mbr_found <= 5) {
                // Check if this looks like end of MBR (offset 0x1FE from start)
                const potential_mbr_start = iram_search - 0x1FE;
                const first_bytes = emu.bus.read32(potential_mbr_start);
                print("  0xAA55 at 0x{X:0>8}, potential MBR at 0x{X:0>8} (first bytes: 0x{X:0>8})\n", .{
                    iram_search, potential_mbr_start, first_bytes,
                });
                // Dump partition 1 from potential MBR
                print("    Part1 (@+0x1BE): ", .{});
                var pbi: u32 = 0;
                while (pbi < 16) : (pbi += 1) {
                    print("{X:0>2} ", .{emu.bus.read8(potential_mbr_start + 0x1BE + pbi)});
                }
                print("\n", .{});
            }
        }
    }
    print("  Total 0xAA55 found in IRAM: {d}\n", .{mbr_found});

    // Dump key regions of supposed MBR location to understand the issue
    print("=== Memory dump at 0x4000E7FC (supposed MBR) ===\n", .{});
    print("  First 32 bytes: ", .{});
    var mb: u32 = 0;
    while (mb < 32) : (mb += 1) {
        print("{X:0>2} ", .{emu.bus.read8(0x4000E7FC + mb)});
    }
    print("\n", .{});
    print("  Offset 0x1BE (partition): ", .{});
    mb = 0;
    while (mb < 16) : (mb += 1) {
        print("{X:0>2} ", .{emu.bus.read8(0x4000E7FC + 0x1BE + mb)});
    }
    print("\n", .{});
    print("  Offset 0x1FE (boot sig): ", .{});
    mb = 0;
    while (mb < 2) : (mb += 1) {
        print("{X:0>2} ", .{emu.bus.read8(0x4000E7FC + 0x1FE + mb)});
    }
    print("\n", .{});

    // Also search SDRAM for MBR
    print("=== Searching SDRAM for MBR boot signature (0xAA55) ===\n", .{});
    var sdram_mbr_found: u32 = 0;
    var sdram_search: u32 = 0x10000000;
    while (sdram_search < 0x12000000) : (sdram_search += 2) {
        const word = emu.bus.read16(sdram_search);
        if (word == 0xAA55) {
            sdram_mbr_found += 1;
            if (sdram_mbr_found <= 5) {
                const potential_mbr_start = sdram_search - 0x1FE;
                const first_bytes = emu.bus.read32(potential_mbr_start);
                print("  0xAA55 at 0x{X:0>8}, potential MBR at 0x{X:0>8} (first bytes: 0x{X:0>8})\n", .{
                    sdram_search, potential_mbr_start, first_bytes,
                });
                // If first bytes are EB 58 90 00, this is likely the MBR
                if ((first_bytes & 0xFFFF) == 0x58EB) {
                    print("    ** This looks like a valid MBR! **\n", .{});
                    print("    Part1 (@+0x1BE): ", .{});
                    var pbi: u32 = 0;
                    while (pbi < 16) : (pbi += 1) {
                        print("{X:0>2} ", .{emu.bus.read8(potential_mbr_start + 0x1BE + pbi)});
                    }
                    print("\n", .{});
                }
            }
        }
    }
    print("  Total 0xAA55 found in SDRAM: {d}\n", .{sdram_mbr_found});
    print("Region 0x11002xxx writes: {d}, first: 0x{X:0>8} = 0x{X:0>8}\n", .{
        emu.bus.debug_region_writes,
        emu.bus.debug_region_first_addr,
        emu.bus.debug_region_first_val,
    });
    print("Partition struct reads ({d}):\n", .{emu.bus.debug_part_reads});
    for (emu.bus.debug_part_read_addrs, 0..) |addr, idx| {
        if (idx < emu.bus.debug_part_reads) {
            print("  0x{X:0>8} = 0x{X:0>8}\n", .{ addr, emu.bus.debug_part_read_vals[idx] });
        }
    }
    // New tracking for partition size/type writes
    print("Partition SIZE writes ({d}): ", .{emu.bus.debug_part_size_writes});
    for (emu.bus.debug_part_size_addrs, 0..) |addr, idx| {
        if (idx < emu.bus.debug_part_size_writes and idx < 8) {
            print("0x{X:0>8} ", .{addr});
        }
    }
    print("\n", .{});
    print("Partition TYPE writes ({d}): ", .{emu.bus.debug_part_type_writes});
    for (emu.bus.debug_part_type_addrs, 0..) |addr, idx| {
        if (idx < emu.bus.debug_part_type_writes and idx < 8) {
            print("0x{X:0>8} ", .{addr});
        }
    }
    print("\n", .{});

    // Dump partition array memory to understand the layout
    print("=== Partition array memory dump ===\n", .{});
    print("part[0] area (assuming 32-bit sector_t):\n", .{});
    print("  0x11001A30: 0x{X:0>8} (start)\n", .{emu.bus.read32(0x11001A30)});
    print("  0x11001A34: 0x{X:0>8} (size)\n", .{emu.bus.read32(0x11001A34)});
    print("  0x11001A38: 0x{X:0>8} (type)\n", .{emu.bus.read32(0x11001A38)});
    print("part[0] area (assuming 64-bit sector_t):\n", .{});
    print("  0x11001A30: 0x{X:0>8} 0x{X:0>8} (start)\n", .{emu.bus.read32(0x11001A30), emu.bus.read32(0x11001A34)});
    print("  0x11001A38: 0x{X:0>8} 0x{X:0>8} (size) ← would be read here!\n", .{emu.bus.read32(0x11001A38), emu.bus.read32(0x11001A3C)});
    print("  0x11001A40: 0x{X:0>8} (type)\n", .{emu.bus.read32(0x11001A40)});
    print("part[1] area (0x11001A3C): start=0x{X:0>8}, size=0x{X:0>8}, type=0x{X:0>8}\n", .{
        emu.bus.read32(0x11001A3C),
        emu.bus.read32(0x11001A40),
        emu.bus.read32(0x11001A44),
    });
    print("part[4] area (0x11001A60): start=0x{X:0>8}, size=0x{X:0>8}, type=0x{X:0>8}\n", .{
        emu.bus.read32(0x11001A60),
        emu.bus.read32(0x11001A64),
        emu.bus.read32(0x11001A68),
    });
    // Writes to pinfo local variable area
    print("Writes to pinfo area (0x11001A60-0x11001A70): {d}\n", .{emu.bus.debug_pinfo_writes});
    for (emu.bus.debug_pinfo_write_addrs, 0..) |addr, idx| {
        if (idx < emu.bus.debug_pinfo_writes and idx < 8) {
            print("  0x{X:0>8} = 0x{X:0>8}\n", .{ addr, emu.bus.debug_pinfo_write_vals[idx] });
        }
    }
    print("Reads from part[0] area (0x11001A30-0x11001A3C): {d}\n", .{emu.bus.debug_part0_reads});
    // LFN write tracking
    print("Writes containing 0x41 byte (potential LFN): {d}\n", .{emu.bus.debug_lfn_write_count});
    for (emu.bus.debug_lfn_write_addrs, 0..) |addr, idx| {
        if (idx < emu.bus.debug_lfn_write_count and idx < 8) {
            print("  LFN write [{d}]: 0x{X:0>8} = 0x{X:0>8}\n", .{ idx, addr, emu.bus.debug_lfn_write_vals[idx] });
        }
    }
    // Sector buffer read tracking
    print("Reads from sector buffer area (0x11006F40-0x11006F80): {d}\n", .{emu.bus.debug_sector_read_count});
    print("LFN attr reads (0x0F at expected position): {d}\n", .{emu.bus.debug_lfn_attr_read_count});
    if (emu.bus.debug_sector_read_count > 0) {
        print("First 16 reads:\n", .{});
        for (emu.bus.debug_sector_read_addrs, 0..) |addr, idx| {
            if (idx < emu.bus.debug_sector_read_count and idx < 16) {
                print("  Read [{d:>2}]: 0x{X:0>8} = 0x{X:0>8}\n", .{ idx, addr, emu.bus.debug_sector_read_vals[idx] });
            }
        }
    }

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

    // Scan SDRAM for partition signature (0xAA55 at offset 0x1FE)
    print("\n=== Scanning SDRAM for MBR signature ===\n", .{});
    var found_mbr: u32 = 0;
    var scan_addr: u32 = 0x10000000;
    while (scan_addr < 0x10100000) : (scan_addr += 0x200) { // Scan first 1MB, 512-byte aligned
        const sig = emu.bus.read16(scan_addr + 0x1FE);
        if (sig == 0xAA55) {
            found_mbr += 1;
            if (found_mbr <= 3) { // Show first 3 matches
                const ptype = emu.bus.read8(scan_addr + 0x1C2);
                const plba = emu.bus.read32(scan_addr + 0x1C6);
                print("  MBR found at 0x{X:0>8}: type=0x{X:0>2}, lba={d}\n", .{ scan_addr, ptype, plba });
            }
        }
    }
    print("  Total MBR signatures found in SDRAM (aligned): {d}\n", .{found_mbr});

    // Also scan for 0xAA55 at any 2-byte aligned address around where writes happen (0x11000000)
    print("=== Scanning for 0xAA55 near 0x11000000 ===\n", .{});
    var found_sig: u32 = 0;
    scan_addr = 0x11000000;
    while (scan_addr < 0x11100000) : (scan_addr += 2) { // Scan 1MB near 0x11000000
        const sig = emu.bus.read16(scan_addr);
        if (sig == 0xAA55) {
            found_sig += 1;
            if (found_sig <= 5) {
                print("  0xAA55 at 0x{X:0>8}\n", .{scan_addr});
            }
        }
    }
    print("  Total 0xAA55 found near 0x11000000: {d}\n", .{found_sig});

    // Examine data around 0x11002D98 where we found 0xAA55
    print("=== Data around 0x11002D98 ===\n", .{});
    const sig_addr: u32 = 0x11002D98;
    // Print 32 bytes before and after
    print("  Bytes at sig-16: ", .{});
    var i: u32 = 0;
    while (i < 32) : (i += 1) {
        print("{X:0>2} ", .{emu.bus.read8(sig_addr - 16 + i)});
    }
    print("\n", .{});
    // Check if there's valid partition data 0x1FE bytes before the signature
    const possible_start = sig_addr - 0x1FE;
    print("  If sector start at 0x{X:0>8}:\n", .{possible_start});
    print("    Boot sig offset: 0x{X:0>8}\n", .{sig_addr});
    const ptype_addr = possible_start + 0x1C2;
    print("    Part type at 0x{X:0>8}: 0x{X:0>2}\n", .{ ptype_addr, emu.bus.read8(ptype_addr) });

    // Show partition entry area (16 bytes at offset 0x1BE from possible sector start)
    const part_entry_addr = possible_start + 0x1BE;
    print("  Partition entry at 0x{X:0>8}: ", .{part_entry_addr});
    i = 0;
    while (i < 16) : (i += 1) {
        print("{X:0>2} ", .{emu.bus.read8(part_entry_addr + i)});
    }
    print("\n", .{});

    // Also check sector-aligned addresses near 0x11000000
    print("=== Checking sector-aligned buffers near 0x11000000 ===\n", .{});
    var check_addr: u32 = 0x11000000;
    while (check_addr < 0x11004000) : (check_addr += 0x200) {
        const test_sig = emu.bus.read16(check_addr + 0x1FE);
        if (test_sig == 0xAA55) {
            print("  MBR at 0x{X:0>8}: type=0x{X:0>2}, lba={d}, sectors={d}\n", .{
                check_addr,
                emu.bus.read8(check_addr + 0x1C2),
                emu.bus.read32(check_addr + 0x1C6),
                emu.bus.read32(check_addr + 0x1CA),
            });
        }
    }

    // Scan ALL of SDRAM for pattern 0x55 0xAA at any byte offset
    print("=== Scanning first 64KB of SDRAM region at 0x11000000 for AA55 ===\n", .{});
    var aa55_count: u32 = 0;
    scan_addr = 0x11000000;
    while (scan_addr < 0x11010000) : (scan_addr += 2) {
        const word = emu.bus.read16(scan_addr);
        if (word == 0xAA55) {
            aa55_count += 1;
            if (aa55_count <= 10) {
                const sector_start = scan_addr - 0x1FE;
                const part_type = emu.bus.read8(sector_start + 0x1C2);
                print("  0xAA55 at 0x{X:0>8} (offset 0x{X:0>4}), implied sector start 0x{X:0>8}, part type 0x{X:0>2}\n", .{
                    scan_addr,
                    scan_addr & 0x1FF,
                    sector_start,
                    part_type,
                });
            }
        }
    }
    print("  Total 0xAA55 occurrences in first 64KB: {d}\n", .{aa55_count});

    // Search for the actual MBR partition signature bytes (0x0B at correct offset)
    print("=== Searching for partition type 0x0B in SDRAM ===\n", .{});
    var part_type_count: u32 = 0;
    scan_addr = 0x11000000;
    while (scan_addr < 0x11010000) : (scan_addr += 1) {
        if (emu.bus.read8(scan_addr) == 0x0B) {
            // Check if this might be a partition type byte
            // (followed by 0xFE for CHS end head)
            if (emu.bus.read8(scan_addr + 1) == 0xFE) {
                part_type_count += 1;
                if (part_type_count <= 5) {
                    print("  Found 0x0B,0xFE at 0x{X:0>8}\n", .{scan_addr});
                    // Show context: 8 bytes before and 8 bytes after
                    print("    Context: ", .{});
                    var ctx: u32 = 0;
                    while (ctx < 20) : (ctx += 1) {
                        const ctx_addr = scan_addr - 8 + ctx;
                        if (ctx_addr >= 0x11000000) {
                            print("{X:0>2} ", .{emu.bus.read8(ctx_addr)});
                        }
                    }
                    print("\n", .{});
                }
            }
        }
    }
    print("  Found {d} potential partition entries with 0x0B,0xFE pattern\n", .{part_type_count});

    // Scan ENTIRE used SDRAM region for AA55
    print("=== Scanning all used SDRAM (0x11000000-0x11100000) for AA55 ===\n", .{});
    var total_aa55: u32 = 0;
    scan_addr = 0x11000000;
    while (scan_addr < 0x11100000) : (scan_addr += 2) {
        if (emu.bus.read16(scan_addr) == 0xAA55) {
            total_aa55 += 1;
        }
    }
    print("  Total 0xAA55 in 1MB region: {d}\n", .{total_aa55});

    // Also scan for MBR at 512-byte aligned in this range
    print("=== Scanning for MBR near 0x11000000 ===\n", .{});
    var found_mbr2: u32 = 0;
    scan_addr = 0x11000000;
    while (scan_addr < 0x11100000) : (scan_addr += 0x200) {
        const sig = emu.bus.read16(scan_addr + 0x1FE);
        if (sig == 0xAA55) {
            found_mbr2 += 1;
            if (found_mbr2 <= 3) {
                const ptype = emu.bus.read8(scan_addr + 0x1C2);
                const plba = emu.bus.read32(scan_addr + 0x1C6);
                print("  MBR found at 0x{X:0>8}: type=0x{X:0>2}, lba={d}\n", .{ scan_addr, ptype, plba });
            }
        }
    }
    print("  Total MBR found near 0x11000000: {d}\n", .{found_mbr2});

    // Also scan IRAM
    print("\n=== Scanning IRAM for MBR signature ===\n", .{});
    var found_iram_mbr: u32 = 0;
    var iram_addr: u32 = 0x40000000;
    while (iram_addr < 0x40018000) : (iram_addr += 0x200) {
        const sig = emu.bus.read16(iram_addr + 0x1FE);
        if (sig == 0xAA55) {
            found_iram_mbr += 1;
            const ptype = emu.bus.read8(iram_addr + 0x1C2);
            const plba = emu.bus.read32(iram_addr + 0x1C6);
            print("  MBR found at 0x{X:0>8}: type=0x{X:0>2}, lba={d}\n", .{ iram_addr, ptype, plba });
        }
    }
    print("  Total MBR signatures found in IRAM: {d}\n", .{found_iram_mbr});

    // Scan IRAM for 0xAA55 at any offset
    print("=== Scanning IRAM for 0xAA55 at any offset ===\n", .{});
    var iram_aa55_count: u32 = 0;
    iram_addr = 0x40000000;
    while (iram_addr < 0x40018000) : (iram_addr += 2) {
        if (emu.bus.read16(iram_addr) == 0xAA55) {
            iram_aa55_count += 1;
            if (iram_aa55_count <= 5) {
                print("  0xAA55 at 0x{X:0>8}\n", .{iram_addr});
            }
        }
    }
    print("  Total 0xAA55 in IRAM: {d}\n", .{iram_aa55_count});

    // Scan IRAM for partition pattern 0x0B, 0xFE
    print("=== Scanning IRAM for partition type 0x0B ===\n", .{});
    var iram_part_count: u32 = 0;
    iram_addr = 0x40000000;
    while (iram_addr < 0x40018000) : (iram_addr += 1) {
        if (emu.bus.read8(iram_addr) == 0x0B and emu.bus.read8(iram_addr + 1) == 0xFE) {
            iram_part_count += 1;
            if (iram_part_count <= 5) {
                print("  Found 0x0B,0xFE at 0x{X:0>8}\n", .{iram_addr});
                // Show context
                print("    Context: ", .{});
                var ctx: u32 = 0;
                while (ctx < 20) : (ctx += 1) {
                    const ctx_addr = iram_addr - 8 + ctx;
                    if (ctx_addr >= 0x40000000 and ctx_addr < 0x40018000) {
                        print("{X:0>2} ", .{emu.bus.read8(ctx_addr)});
                    }
                }
                print("\n", .{});
            }
        }
    }
    print("  Found {d} potential partition entries in IRAM\n", .{iram_part_count});

    // Search for other MBR patterns: 0xFE0B as a 16-bit word
    print("=== Searching for 0xFE0B word (partition entry) ===\n", .{});
    var fe0b_count: u32 = 0;
    scan_addr = 0x10000000;
    while (scan_addr < 0x12000000) : (scan_addr += 2) {
        if (emu.bus.read16(scan_addr) == 0xFE0B) {
            fe0b_count += 1;
            if (fe0b_count <= 5) {
                print("  0xFE0B at 0x{X:0>8}\n", .{scan_addr});
            }
        }
    }
    iram_addr = 0x40000000;
    while (iram_addr < 0x40018000) : (iram_addr += 2) {
        if (emu.bus.read16(iram_addr) == 0xFE0B) {
            fe0b_count += 1;
            if (fe0b_count <= 10) {
                print("  0xFE0B at 0x{X:0>8} (IRAM)\n", .{iram_addr});
            }
        }
    }
    print("  Total 0xFE0B occurrences: {d}\n", .{fe0b_count});

    // Search for LBA=1 pattern (bytes 01 00 00 00)
    print("=== Searching for LBA=1 (0x00000001) pattern ===\n", .{});
    var lba1_count: u32 = 0;
    scan_addr = 0x11000000;
    while (scan_addr < 0x11100000) : (scan_addr += 4) {
        if (emu.bus.read32(scan_addr) == 0x00000001) {
            // Check if followed by sector count (0x0001FFFF or similar)
            const next_word = emu.bus.read32(scan_addr + 4);
            if (next_word > 0x1000 and next_word < 0x10000000) {
                lba1_count += 1;
                if (lba1_count <= 10) {
                    print("  LBA=1 at 0x{X:0>8}, next_word=0x{X:0>8}\n", .{ scan_addr, next_word });
                    // Show context: 32 bytes around this location
                    print("    Memory at -16: ", .{});
                    var ctx: u32 = 0;
                    while (ctx < 32) : (ctx += 1) {
                        const ctx_addr = scan_addr - 16 + ctx;
                        if (ctx_addr >= 0x11000000) {
                            print("{X:0>2} ", .{emu.bus.read8(ctx_addr)});
                        }
                    }
                    print("\n", .{});
                }
            }
        }
    }
    print("  Potential LBA=1 entries found: {d}\n", .{lba1_count});

    // Dump memory around 0x11001A30 where LBA=1 was found
    print("=== Examining partition struct at 0x11001A20 ===\n", .{});
    print("  Bytes: ", .{});
    var dump_addr: u32 = 0x11001A20;
    while (dump_addr < 0x11001A60) : (dump_addr += 1) {
        print("{X:0>2} ", .{emu.bus.read8(dump_addr)});
    }
    print("\n", .{});
    print("  As u32: ", .{});
    dump_addr = 0x11001A20;
    while (dump_addr < 0x11001A60) : (dump_addr += 4) {
        print("{X:0>8} ", .{emu.bus.read32(dump_addr)});
    }
    print("\n", .{});

    // Search for raw partition entry first 4 bytes: 00 FE FF FF
    print("=== Searching for raw partition entry (00 FE FF FF) ===\n", .{});
    var raw_part_count: u32 = 0;
    scan_addr = 0x10000000;
    while (scan_addr < 0x12000000) : (scan_addr += 1) {
        if (emu.bus.read8(scan_addr) == 0x00 and
            emu.bus.read8(scan_addr + 1) == 0xFE and
            emu.bus.read8(scan_addr + 2) == 0xFF and
            emu.bus.read8(scan_addr + 3) == 0xFF)
        {
            raw_part_count += 1;
            if (raw_part_count <= 5) {
                print("  Found at 0x{X:0>8}: ", .{scan_addr});
                var prt: u32 = 0;
                while (prt < 16) : (prt += 1) {
                    print("{X:0>2} ", .{emu.bus.read8(scan_addr + prt)});
                }
                print("\n", .{});
            }
        }
    }
    print("  Total raw partition entries found: {d}\n", .{raw_part_count});

    // Also check IRAM for the same pattern
    iram_addr = 0x40000000;
    while (iram_addr < 0x40017FFC) : (iram_addr += 1) {
        if (emu.bus.read8(iram_addr) == 0x00 and
            emu.bus.read8(iram_addr + 1) == 0xFE and
            emu.bus.read8(iram_addr + 2) == 0xFF and
            emu.bus.read8(iram_addr + 3) == 0xFF)
        {
            print("  Found in IRAM at 0x{X:0>8}: ", .{iram_addr});
            var prt: u32 = 0;
            while (prt < 16) : (prt += 1) {
                print("{X:0>2} ", .{emu.bus.read8(iram_addr + prt)});
            }
            print("\n", .{});
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

    // Dump framebuffer to PPM file for debugging
    if (lcd_stats.pixel_writes > 0) {
        const fb = emu.getFramebuffer();
        const ppm_file = std.fs.cwd().createFile("/tmp/zigpod_lcd.ppm", .{}) catch null;
        if (ppm_file) |file| {
            defer file.close();
            // PPM header
            _ = file.write("P6\n320 240\n255\n") catch {};
            // Convert RGB565 to RGB888
            var y: u32 = 0;
            while (y < 240) : (y += 1) {
                var x: u32 = 0;
                while (x < 320) : (x += 1) {
                    const fb_offset = (y * 320 + x) * 2;
                    const lo = fb[fb_offset];
                    const hi = fb[fb_offset + 1];
                    const rgb565 = @as(u16, lo) | (@as(u16, hi) << 8);
                    const r = @as(u8, @truncate((rgb565 >> 11) & 0x1F)) << 3;
                    const g = @as(u8, @truncate((rgb565 >> 5) & 0x3F)) << 2;
                    const b = @as(u8, @truncate(rgb565 & 0x1F)) << 3;
                    _ = file.write(&[_]u8{ r, g, b }) catch {};
                }
            }
            print("Framebuffer saved to /tmp/zigpod_lcd.ppm\n", .{});
        }
    }

    // Debug: Search for rockbox.ipod LFN entry in memory
    print("\n=== Searching for rockbox.ipod LFN entry in SDRAM ===\n", .{});
    // LFN entry pattern: ordinal 0x41, attr 0x0F at +11, checksum 0x4E at +13
    var lfn_found: u32 = 0;
    var search_addr: u32 = 0x11000000;
    while (search_addr < 0x11100000) : (search_addr += 1) {
        // Check for LFN entry with checksum 0x4E (rockbox.ipod in .rockbox)
        const ord = emu.bus.read8(search_addr);
        if (ord == 0x41) { // First/only LFN entry
            const attr = emu.bus.read8(search_addr + 11);
            const chksum = emu.bus.read8(search_addr + 13);
            if (attr == 0x0F and (chksum == 0x4E or chksum == 0xEE)) {
                lfn_found += 1;
                print("  LFN entry at 0x{X:0>8} (chksum=0x{X:0>2}):\n", .{ search_addr, chksum });
                // Dump entire 32-byte entry
                print("    Hex: ", .{});
                var j: u32 = 0;
                while (j < 32) : (j += 1) {
                    print("{X:0>2} ", .{emu.bus.read8(search_addr + j)});
                }
                print("\n", .{});
                // Decode characters
                print("    name1 (bytes 1-10): ", .{});
                var k: u32 = 1;
                while (k <= 9) : (k += 2) {
                    const lo = emu.bus.read8(search_addr + k);
                    const hi = emu.bus.read8(search_addr + k + 1);
                    const ch = @as(u16, lo) | (@as(u16, hi) << 8);
                    if (ch != 0 and ch != 0xFFFF and ch < 128) {
                        print("'{c}'({X:0>4}) ", .{ @as(u8, @truncate(ch)), ch });
                    } else if (ch == 0 or ch == 0xFFFF) {
                        print("\\0 ", .{});
                    }
                }
                print("\n    name2 (bytes 14-25): ", .{});
                k = 14;
                while (k <= 24) : (k += 2) {
                    const lo = emu.bus.read8(search_addr + k);
                    const hi = emu.bus.read8(search_addr + k + 1);
                    const ch = @as(u16, lo) | (@as(u16, hi) << 8);
                    const marker = if (k == 24) "**" else "";
                    if (ch != 0 and ch != 0xFFFF and ch < 128) {
                        print("{s}'{c}'({X:0>4}) ", .{ marker, @as(u8, @truncate(ch)), ch });
                    } else if (ch == 0 or ch == 0xFFFF) {
                        print("{s}\\0 ", .{marker});
                    }
                }
                print("\n    name3 (bytes 28-31): ", .{});
                k = 28;
                while (k <= 30) : (k += 2) {
                    const lo = emu.bus.read8(search_addr + k);
                    const hi = emu.bus.read8(search_addr + k + 1);
                    const ch = @as(u16, lo) | (@as(u16, hi) << 8);
                    const marker = if (k == 28) "**" else "";
                    if (ch != 0 and ch != 0xFFFF and ch < 128) {
                        print("{s}'{c}'({X:0>4}) ", .{ marker, @as(u8, @truncate(ch)), ch });
                    } else if (ch == 0 or ch == 0xFFFF) {
                        print("{s}\\0 ", .{marker});
                    }
                }
                print("\n", .{});
                // Show critical bytes
                print("    CRITICAL bytes 24-25: 0x{X:0>2} 0x{X:0>2}\n", .{
                    emu.bus.read8(search_addr + 24),
                    emu.bus.read8(search_addr + 25),
                });
                print("    CRITICAL bytes 28-31: 0x{X:0>2} 0x{X:0>2} 0x{X:0>2} 0x{X:0>2}\n", .{
                    emu.bus.read8(search_addr + 28),
                    emu.bus.read8(search_addr + 29),
                    emu.bus.read8(search_addr + 30),
                    emu.bus.read8(search_addr + 31),
                });
                // Also show the SHORT name entry that follows (at +32)
                const short_addr = search_addr + 32;
                print("    Following SHORT entry at 0x{X:0>8}:\n", .{short_addr});
                print("      Raw: ", .{});
                var s: u32 = 0;
                while (s < 32) : (s += 1) {
                    print("{X:0>2} ", .{emu.bus.read8(short_addr + s)});
                }
                print("\n", .{});
                // Extract 11-byte short name
                print("      Short name (bytes 0-10): ", .{});
                s = 0;
                while (s < 11) : (s += 1) {
                    const byte = emu.bus.read8(short_addr + s);
                    if (byte >= 0x20 and byte < 0x7F) {
                        print("{c}", .{byte});
                    } else {
                        print(".", .{});
                    }
                }
                print("\n", .{});
                // Compute expected checksum
                var computed_chksum: u32 = 0;
                s = 0;
                while (s < 11) : (s += 1) {
                    const byte = emu.bus.read8(short_addr + s);
                    // Rotate right by 1 and add byte
                    computed_chksum = (((computed_chksum >> 1) | ((computed_chksum & 1) << 7)) + byte) & 0xFF;
                }
                print("      Computed checksum: 0x{X:0>2} (expected 0x{X:0>2})\n", .{
                    @as(u8, @truncate(computed_chksum)),
                    chksum,
                });
            }
        }
    }
    print("  Total LFN entries for rockbox.ipod found: {d}\n", .{lfn_found});

    // Specifically check address 0x11006F54 where .rockbox LFN was written
    print("=== Checking address 0x11006F54 (where .rockbox LFN was written) ===\n", .{});
    print("  Raw 32 bytes: ", .{});
    var dump_idx: u32 = 0;
    while (dump_idx < 32) : (dump_idx += 1) {
        print("{X:0>2} ", .{emu.bus.read8(0x11006F54 + dump_idx)});
    }
    print("\n", .{});
    const chk_ord = emu.bus.read8(0x11006F54);
    const chk_attr = emu.bus.read8(0x11006F54 + 11);
    const chk_chksum = emu.bus.read8(0x11006F54 + 13);
    print("  ord=0x{X:0>2}, attr=0x{X:0>2}, checksum=0x{X:0>2}\n", .{ chk_ord, chk_attr, chk_chksum });
    if (chk_ord == 0x41 and chk_attr == 0x0F) {
        print("  This IS an LFN entry (chksum should be 0x4E for .rockbox/rockbox.ipod)\n", .{});
    } else {
        print("  This is NOT an LFN entry - data was OVERWRITTEN!\n", .{});
    }

    print("Emulator stopped.\n", .{});
}

// Tests
test "argument parsing" {
    // Just ensure the module compiles
    _ = main;
}
