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
        \\  --firmware <file>   Load firmware from file into IRAM
        \\  --sdram <size>      SDRAM size in MB (32 or 64, default: 32)
        \\  --headless          Run without display
        \\  --debug             Enable debug output
        \\  --cycles <n>        Run for n cycles then exit (headless only)
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
    var disk_path: ?[]const u8 = null;
    var sdram_mb: usize = 32;
    var headless = false;
    var debug = false;
    var max_cycles: ?u64 = null;

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

    // Reset and start
    emu.reset();

    if (debug) {
        print("CPU: PC=0x{X:0>8}, Mode={s}, Thumb={}\n", .{
            emu.getPc(),
            if (emu.cpu.getMode()) |m| @tagName(m) else "unknown",
            emu.isThumb(),
        });
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
            const actual_cycles = emu.run(cycles);
            print("Executed {d} cycles\n", .{actual_cycles});
        } else {
            print("Running in headless mode (Ctrl+C to stop)...\n", .{});
            while (true) {
                _ = emu.run(1_000_000);

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
