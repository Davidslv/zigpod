//! ZigPod Simulator
//!
//! Interactive PP5021C iPod Video simulator with visual output.
//! Run: zig build sim -- [options]
//! Run with GUI: zig build sim -Dsdl2=true -- [options]

const std = @import("std");
const build_options = @import("build_options");
const zigpod = @import("zigpod");
const simulator = zigpod.simulator;

const SimulatorState = simulator.SimulatorState;

// Conditional SDL2 GUI and audio imports
// These are imported directly by the simulator executable, not through the library
const gui = if (build_options.enable_sdl2) @import("gui/gui.zig") else struct {
    pub const Button = enum { menu, play_pause, prev, next, select, hold };
};
const sdl_backend = if (build_options.enable_sdl2) @import("gui/sdl_backend.zig") else struct {};
const audio_player = if (build_options.enable_sdl2) @import("audio/audio_player.zig") else struct {};
const sim_ui = if (build_options.enable_sdl2) @import("gui/sim_ui.zig") else struct {
    pub const SimulatorUI = struct {
        pub fn init() @This() {
            return .{};
        }
    };
};

/// Simple output writer for Zig 0.15
const Output = struct {
    file: std.fs.File,
    buf: [4096]u8 = undefined,

    fn print(self: *Output, comptime fmt: []const u8, args: anytype) void {
        const msg = std.fmt.bufPrint(&self.buf, fmt, args) catch return;
        _ = self.file.write(msg) catch {};
    }

    fn write(self: *Output, data: []const u8) void {
        _ = self.file.write(data) catch {};
    }
};

/// Command line options
const Options = struct {
    rom_path: ?[]const u8 = null,
    disk_image: ?[]const u8 = null,
    audio_file: ?[]const u8 = null,
    audio_samples: ?[]const u8 = null,
    cycles_per_frame: u64 = 10000,
    headless: bool = false,
    debug: bool = false,
    breakpoint: ?u32 = null,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse command line arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var options = Options{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--rom") or std.mem.eql(u8, arg, "-r")) {
            i += 1;
            if (i < args.len) options.rom_path = args[i];
        } else if (std.mem.eql(u8, arg, "--disk") or std.mem.eql(u8, arg, "-d")) {
            i += 1;
            if (i < args.len) options.disk_image = args[i];
        } else if (std.mem.eql(u8, arg, "--audio") or std.mem.eql(u8, arg, "-a")) {
            i += 1;
            if (i < args.len) options.audio_file = args[i];
        } else if (std.mem.eql(u8, arg, "--audio-samples") or std.mem.eql(u8, arg, "-s")) {
            i += 1;
            if (i < args.len) options.audio_samples = args[i];
        } else if (std.mem.eql(u8, arg, "--headless")) {
            options.headless = true;
        } else if (std.mem.eql(u8, arg, "--debug")) {
            options.debug = true;
        } else if (std.mem.eql(u8, arg, "--cycles") or std.mem.eql(u8, arg, "-c")) {
            i += 1;
            if (i < args.len) {
                options.cycles_per_frame = std.fmt.parseInt(u64, args[i], 10) catch 10000;
            }
        } else if (std.mem.eql(u8, arg, "--break") or std.mem.eql(u8, arg, "-b")) {
            i += 1;
            if (i < args.len) {
                options.breakpoint = std.fmt.parseInt(u32, args[i], 0) catch null;
            }
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printHelp();
            return;
        }
    }

    // Initialize simulator
    const config = simulator.SimulatorConfig{
        .debug_logging = options.debug,
        .disk_image_path = options.disk_image,
        .audio_samples_path = options.audio_samples,
    };

    try simulator.initSimulator(allocator, config);
    defer simulator.shutdownSimulator();

    const state = simulator.getSimulatorState() orelse {
        std.debug.print("Failed to initialize simulator\n", .{});
        return;
    };

    // Load ROM if provided
    if (options.rom_path) |path| {
        const rom_data = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch |err| {
            std.debug.print("Failed to load ROM '{s}': {}\n", .{ path, err });
            return;
        };
        defer allocator.free(rom_data);

        state.loadRom(rom_data);
        std.debug.print("Loaded ROM: {s} ({d} bytes)\n", .{ path, rom_data.len });
    } else {
        // Load demo program if no ROM provided
        loadDemoProgram(state);
        std.debug.print("Loaded demo program (no ROM specified)\n", .{});
    }

    // Set breakpoint if specified
    if (options.breakpoint) |bp| {
        _ = state.addBreakpoint(bp);
        std.debug.print("Breakpoint set at 0x{X:0>8}\n", .{bp});
    }

    // Reset CPU to start execution
    state.setCpuPc(0);

    var out = Output{ .file = std.fs.File.stdout() };

    // Print banner
    out.write("\n");
    out.write("  ____  _       ____           _ \n");
    out.write(" |_  / (_) __ _|  _ \\ ___   __| |\n");
    out.write("  / /  | |/ _` | |_) / _ \\ / _` |\n");
    out.write(" / /__ | | (_| |  __/ (_) | (_| |\n");
    out.write("/____||_|\\__, |_|   \\___/ \\__,_|\n");
    out.write("         |___/   Simulator v0.1  \n");
    out.write("\n");

    if (options.headless) {
        runHeadless(state, options, &out);
    } else if (build_options.enable_sdl2) {
        runGuiMode(allocator, state, options, &out);
    } else {
        runInteractive(state, options, &out);
    }
}

/// Run simulator with SDL2 GUI
fn runGuiMode(allocator: std.mem.Allocator, state: *SimulatorState, options: Options, out: *Output) void {
    if (!build_options.enable_sdl2) return;

    out.write("Starting SDL2 GUI mode...\n");
    out.write("Controls:\n");
    out.write("  Arrow keys / Click wheel: Navigate\n");
    out.write("  Enter / Center button: Select\n");
    out.write("  M / Escape: Menu/Back\n");
    out.write("  Space: Play/Pause\n");
    out.write("  Mouse scroll: Navigate menus / Adjust volume\n");
    out.write("  Q / Close window: Quit\n\n");

    // Initialize SDL2 backend
    var backend = sdl_backend.Sdl2Backend.create(allocator);
    var gui_interface = backend.getBackend();

    gui_interface.init(.{
        .width = 320,
        .height = 240,
        .scale = 1,
        .title = "ZigPod Simulator",
    }) catch |err| {
        out.print("Failed to initialize GUI: {}\n", .{err});
        out.write("Falling back to terminal mode...\n");
        runInteractive(state, options, out);
        return;
    };
    defer gui_interface.deinit();

    // Initialize audio player
    var player = audio_player.AudioPlayer.init(allocator);
    defer player.deinit();

    // Initialize UI state
    var ui = sim_ui.SimulatorUI.init();

    // Load audio file if provided via command line (skip UI and go straight to playback)
    if (options.audio_file) |audio_path| {
        out.print("Loading audio: {s}\n", .{audio_path});
        player.loadWav(audio_path) catch |err| {
            out.print("Failed to load audio: {}\n", .{err});
        };
        const info = player.getTrackInfo();
        if (info.duration_ms > 0) {
            ui.screen = .now_playing;
            ui.audio_playing = true;
            out.print("Track: {s}\n", .{info.getTitle()});
            out.print("Duration: {d}ms, Sample rate: {d}Hz, Channels: {d}\n", .{
                info.duration_ms,
                info.sample_rate,
                info.channels,
            });
            player.play();
            out.print("Playback started\n", .{});
        }
    }

    // Main GUI loop
    var frame_count: u64 = 0;
    var running = true;
    var wheel_accum: i8 = 0;

    while (running and gui_interface.isOpen()) {
        // Process GUI events
        while (gui_interface.pollEvent()) |event| {
            switch (event.event_type) {
                .quit => {
                    running = false;
                },
                .button_press => {
                    if (event.button) |button| {
                        const ui_button = mapGuiButton(button);
                        if (ui.handleInput(ui_button, 0)) |action| {
                            handleUiAction(&ui, &player, action, allocator, out);
                        }
                    }
                },
                .button_release => {},
                .wheel_turn => {
                    // Accumulate wheel for UI navigation
                    wheel_accum += event.wheel_delta;
                    if (wheel_accum >= 3 or wheel_accum <= -3) {
                        const delta: i8 = if (wheel_accum > 0) 1 else -1;
                        wheel_accum = 0;
                        if (ui.handleInput(.none, delta)) |action| {
                            handleUiAction(&ui, &player, action, allocator, out);
                        }
                    }
                },
                .key_down => {
                    if (event.keycode == 'q') {
                        running = false;
                    } else if (event.keycode == 0x40000052) { // SDL_SCANCODE_UP
                        // Arrow up for navigation
                        if (ui.handleInput(.none, -1)) |action| {
                            handleUiAction(&ui, &player, action, allocator, out);
                        }
                    } else if (event.keycode == 0x40000051) { // SDL_SCANCODE_DOWN
                        // Arrow down for navigation
                        if (ui.handleInput(.none, 1)) |action| {
                            handleUiAction(&ui, &player, action, allocator, out);
                        }
                    }
                },
                else => {},
            }
        }

        // Check for track end and auto-advance (respects repeat mode)
        if (player.hasTrackEnded() and ui.screen == .now_playing) {
            player.clearEndedState();
            // Auto-advance respecting repeat mode
            const advance_result = ui.autoAdvance();
            switch (advance_result.result) {
                .same_track => {
                    // Repeat one - replay same track
                    if (advance_result.path) |path| {
                        out.print("Repeating track: {s}\n", .{path});
                        player.loadWav(path) catch |err| {
                            out.print("Failed to reload track: {}\n", .{err});
                        };
                        player.play();
                    }
                },
                .next_track => {
                    // Play next track (or wrapped to beginning for repeat all)
                    if (advance_result.path) |path| {
                        out.print("Auto-advancing to: {s}\n", .{path});
                        player.loadWav(path) catch |err| {
                            out.print("Failed to load next track: {}\n", .{err});
                        };
                        player.play();
                    }
                },
                .end_of_queue => {
                    out.print("Playback finished (end of queue)\n", .{});
                },
            }
        }

        // Build player info for UI
        const player_info = sim_ui.PlayerInfo{
            .title = player.getTrackInfo().getTitle(),
            .artist = player.getTrackInfo().getArtist(),
            .position_ms = player.getPositionMs(),
            .duration_ms = player.getTrackInfo().duration_ms,
            .is_playing = player.getState() == .playing,
            .volume = player.volume,
            .queue_position = ui.queue_position,
            .queue_total = ui.queue_count,
            .shuffle_enabled = ui.shuffle_enabled,
            .repeat_mode = ui.repeat_mode,
        };

        // Render UI to framebuffer
        sim_ui.render(&state.lcd_framebuffer, &ui, player_info);

        // Update GUI with LCD framebuffer
        gui_interface.updateLcd(&state.lcd_framebuffer);
        gui_interface.setWheelPosition(state.wheel_position);

        // Present frame
        gui_interface.present();
        frame_count += 1;
    }

    player.stop();

    out.print("\nSimulator exited. Frames: {d}\n", .{frame_count});
}

/// Map GUI button to UI button
fn mapGuiButton(button: gui.Button) sim_ui.Button {
    return switch (button) {
        .menu => .menu,
        .play_pause => .play_pause,
        .prev => .left,
        .next => .right,
        .select => .select,
        .repeat => .repeat,
        else => .none,
    };
}

/// Handle UI action (play file, toggle play, etc.)
fn handleUiAction(ui: *sim_ui.SimulatorUI, player: *audio_player.AudioPlayer, action: sim_ui.Action, allocator: std.mem.Allocator, out: *Output) void {
    _ = allocator;
    switch (action) {
        .toggle_play => {
            player.togglePause();
        },
        .play_file => |path| {
            out.print("Loading: {s}\n", .{path});
            player.loadWav(path) catch |err| {
                out.print("Failed to load: {}\n", .{err});
                return;
            };
            const info = player.getTrackInfo();
            if (info.duration_ms > 0) {
                ui.screen = .now_playing;
                ui.audio_playing = true;
                player.play();
                out.print("Playing: {s} ({d}ms)\n", .{ info.getTitle(), info.duration_ms });
            }
        },
        .seek_forward => {
            const pos = player.getPositionMs();
            const duration = player.getTrackInfo().duration_ms;
            if (pos + 10000 < duration) {
                player.seekMs(pos + 10000);
            }
        },
        .volume_change => |delta| {
            const current: i16 = player.volume;
            const new_vol = std.math.clamp(current + delta, 0, 100);
            player.setVolume(@intCast(new_vol));
        },
        .toggle_shuffle => {
            ui.toggleShuffle();
            if (ui.shuffle_enabled) {
                out.print("Shuffle: ON\n", .{});
            } else {
                out.print("Shuffle: OFF\n", .{});
            }
        },
        .toggle_repeat => {
            ui.toggleRepeat();
            out.print("Repeat: {s}\n", .{ui.repeat_mode.toIcon()});
        },
    }
}

/// Handle button press in audio playback mode
fn handleAudioButton(player: *audio_player.AudioPlayer, button: gui.Button) void {
    if (!build_options.enable_sdl2) return;

    switch (button) {
        .play_pause => {
            player.togglePause();
        },
        .prev => {
            // Seek back 10 seconds
            const pos = player.getPositionMs();
            if (pos > 10000) {
                player.seekMs(pos - 10000);
            } else {
                player.seekMs(0);
            }
        },
        .next => {
            // Seek forward 10 seconds
            const pos = player.getPositionMs();
            const duration = player.getTrackInfo().duration_ms;
            if (pos + 10000 < duration) {
                player.seekMs(pos + 10000);
            }
        },
        .menu => {
            // Stop playback
            player.stop();
        },
        .select => {
            // Toggle pause
            player.togglePause();
        },
        else => {},
    }
}

/// Handle button press in GUI mode
fn handleButtonPress(state: *SimulatorState, button: gui.Button, paused: *bool) void {
    if (!build_options.enable_sdl2) return;

    // Update simulator button state
    const btn_idx: u8 = @intFromEnum(button);
    const btn_bit: u8 = @as(u8, 1) << @as(u3, @truncate(btn_idx));
    state.button_state |= btn_bit;

    // Handle special buttons
    switch (button) {
        .play_pause => {
            paused.* = !paused.*;
        },
        .menu => {
            // Could trigger menu action
        },
        .select => {
            // Could trigger select action
        },
        else => {},
    }
}

fn runInteractive(state: *SimulatorState, options: Options, out: *Output) void {
    const stdin = std.fs.File.stdin();
    var running = true;
    var auto_run = false;
    var frame_count: u64 = 0;

    out.write("Commands: [r]un, [s]tep, [c]ontinue, [p]rint regs, [m]emory, [q]uit\n");
    out.write("Press Enter to step, 'r' to run continuously\n\n");

    while (running) {
        // Show prompt with PC
        out.print("PC=0x{X:0>8} > ", .{state.getCpuPc()});

        // Read command
        var buf: [64]u8 = undefined;
        const bytes_read = stdin.read(&buf) catch break;
        if (bytes_read == 0) break;

        const line = buf[0..bytes_read];
        const cmd = std.mem.trim(u8, line, " \t\r\n");

        if (cmd.len == 0) {
            // Empty line = step
            if (auto_run) {
                const result = state.run(options.cycles_per_frame);
                frame_count += 1;
                out.print("Frame {d}: {d} cycles, {d} instructions, stop: {s}\n", .{
                    frame_count,
                    result.cycles,
                    result.instructions,
                    @tagName(result.stop_reason),
                });
                if (result.stop_reason == .breakpoint or result.stop_reason == .halted) {
                    auto_run = false;
                }
            } else {
                _ = state.stepCpu();
            }
        } else if (std.mem.eql(u8, cmd, "q") or std.mem.eql(u8, cmd, "quit")) {
            running = false;
        } else if (std.mem.eql(u8, cmd, "r") or std.mem.eql(u8, cmd, "run")) {
            auto_run = true;
            out.write("Running... (press Ctrl+C to stop)\n");
        } else if (std.mem.eql(u8, cmd, "s") or std.mem.eql(u8, cmd, "step")) {
            const result = state.stepCpu();
            if (result) |r| {
                out.print("Step: status={s}, cycles={d}\n", .{ @tagName(r.status), r.cycles });
            }
        } else if (std.mem.eql(u8, cmd, "c") or std.mem.eql(u8, cmd, "continue")) {
            const result = state.run(options.cycles_per_frame);
            out.print("Ran {d} cycles, {d} instructions, stop: {s}\n", .{
                result.cycles,
                result.instructions,
                @tagName(result.stop_reason),
            });
        } else if (std.mem.eql(u8, cmd, "p") or std.mem.eql(u8, cmd, "regs")) {
            printRegisters(state, out);
        } else if (std.mem.startsWith(u8, cmd, "m ") or std.mem.startsWith(u8, cmd, "mem ")) {
            const addr_str = std.mem.trim(u8, cmd[2..], " ");
            if (std.fmt.parseInt(u32, addr_str, 0)) |addr| {
                printMemory(state, addr, out);
            } else |_| {
                out.write("Invalid address\n");
            }
        } else if (std.mem.eql(u8, cmd, "h") or std.mem.eql(u8, cmd, "help")) {
            out.write("Commands:\n");
            out.write("  r, run       - Run continuously\n");
            out.write("  s, step      - Single step\n");
            out.write("  c, continue  - Run for one frame\n");
            out.write("  p, regs      - Print registers\n");
            out.write("  m <addr>     - Print memory at address\n");
            out.write("  q, quit      - Exit\n");
        } else {
            out.print("Unknown command: '{s}' (type 'h' for help)\n", .{cmd});
        }
    }

    out.print("\nSimulator exited. Total cycles: {d}, instructions: {d}\n", .{
        state.getCpuCycles(),
        state.getCpuInstructions(),
    });
}

fn runHeadless(state: *SimulatorState, options: Options, out: *Output) void {
    out.write("Running in headless mode...\n");

    const max_cycles: u64 = 1_000_000; // 1M cycles
    const result = state.run(max_cycles);

    out.write("\nExecution complete:\n");
    out.print("  Cycles:       {d}\n", .{result.cycles});
    out.print("  Instructions: {d}\n", .{result.instructions});
    out.print("  Stop reason:  {s}\n", .{@tagName(result.stop_reason)});
    out.write("\n");

    printRegisters(state, out);

    _ = options;
}

fn printRegisters(state: *SimulatorState, out: *Output) void {
    out.write("Registers:\n");
    var i: u5 = 0;
    while (i < 16) : (i += 1) {
        const reg: u4 = @truncate(i);
        const name = switch (reg) {
            13 => "SP",
            14 => "LR",
            15 => "PC",
            else => "",
        };
        if (name.len > 0) {
            out.print("  R{d:2} ({s}): 0x{X:0>8}\n", .{ reg, name, state.getCpuReg(reg) });
        } else {
            out.print("  R{d:2}:      0x{X:0>8}\n", .{ reg, state.getCpuReg(reg) });
        }
    }
}

fn printMemory(state: *SimulatorState, addr: u32, out: *Output) void {
    out.print("Memory at 0x{X:0>8}:\n", .{addr});

    if (state.bus) |*bus| {
        var offset: u32 = 0;
        while (offset < 64) : (offset += 16) {
            out.print("  {X:0>8}:", .{addr + offset});
            var j: u32 = 0;
            while (j < 16) : (j += 4) {
                const val = bus.read32(addr + offset + j) catch 0;
                out.print(" {X:0>8}", .{val});
            }
            out.write("\n");
        }
    } else {
        out.write("  (memory bus not available)\n");
    }
}

fn loadDemoProgram(state: *SimulatorState) void {
    // Demo program that draws a colorful pattern to the LCD
    // The LCD framebuffer is at 0x40000000 (IRAM base)
    // Each pixel is 16-bit RGB565

    const program = [_]u8{
        // Initialize registers
        // R0 = framebuffer base (0x40000000)
        // MOV R0, #0x40000000  (need to build this)
        // E3A004xx where xx encodes the immediate

        // MOV R0, #1, ROR #4 -> R0 = 0x10000000
        // Then LSL by 2 -> 0x40000000
        0x01, 0x02, 0xA0, 0xE3, // MOV R0, #0x40000000 (1 rotated right by 2*2=4 bits)

        // R1 = pixel counter (0 to 320*240 = 76800)
        // MOV R1, #0
        0x00, 0x10, 0xA0, 0xE3,

        // R2 = color value
        // MOV R2, #0
        0x00, 0x20, 0xA0, 0xE3,

        // R3 = max pixels (76800 = 0x12C00)
        // MOV R3, #0x12C00 - need to build this in parts
        // MOV R3, #0x12, LSL #8 = 0x1200, then ORR #0xC00
        0x4B, 0x3C, 0xA0, 0xE3, // MOV R3, #0x12C00 (0x4B rotated by 15*2=30)

        // loop:
        // STRH R2, [R0, R1, LSL #1]  - Store halfword at framebuffer + offset*2
        // Actually simpler: STRH R2, [R0], #2  - Store and increment
        0xB2, 0x20, 0xC0, 0xE0, // STRH R2, [R0], #2

        // ADD R2, R2, #1       - Increment color
        0x01, 0x20, 0x82, 0xE2,

        // ADD R1, R1, #1       - Increment counter
        0x01, 0x10, 0x81, 0xE2,

        // CMP R1, R3           - Compare counter with max
        0x03, 0x00, 0x51, 0xE1,

        // BNE loop             - Loop if not done
        0xFA, 0xFF, 0xFF, 0x1A, // BNE -6 (back to STRH)

        // Done - infinite loop
        0xFE, 0xFF, 0xFF, 0xEA, // B .
    };

    state.loadRom(&program);

    // Also directly draw a test pattern to the LCD framebuffer for immediate visual
    // This will show something even before the CPU runs
    drawTestPattern(state);
}

/// Draw a test pattern directly to LCD for immediate visual feedback
fn drawTestPattern(state: *SimulatorState) void {
    // Draw a colorful gradient pattern
    for (0..240) |y| {
        for (0..320) |x| {
            // Create a gradient pattern
            const r: u16 = @truncate(x / 10); // 0-31
            const g: u16 = @truncate(y / 4); // 0-63
            const b: u16 = @truncate((x + y) / 18); // 0-31

            // RGB565 format: RRRRRGGG GGGBBBBB
            const color: u16 = (r << 11) | (g << 5) | b;
            state.lcd_framebuffer[y * 320 + x] = color;
        }
    }

    // Draw a white border
    for (0..320) |x| {
        state.lcd_framebuffer[x] = 0xFFFF; // Top
        state.lcd_framebuffer[239 * 320 + x] = 0xFFFF; // Bottom
    }
    for (0..240) |y| {
        state.lcd_framebuffer[y * 320] = 0xFFFF; // Left
        state.lcd_framebuffer[y * 320 + 319] = 0xFFFF; // Right
    }

    // Draw "ZigPod" text area (simple rectangle for now)
    const text_x: usize = 100;
    const text_y: usize = 100;
    const text_w: usize = 120;
    const text_h: usize = 40;

    for (text_y..text_y + text_h) |y| {
        for (text_x..text_x + text_w) |x| {
            // Dark blue background
            state.lcd_framebuffer[y * 320 + x] = 0x001F;
        }
    }

    // Draw a simple "play" triangle icon
    const icon_x: usize = 140;
    const icon_y: usize = 105;
    for (0..30) |dy| {
        const width = dy / 2;
        for (0..width) |dx| {
            if (icon_x + dx < 320 and icon_y + dy < 240) {
                state.lcd_framebuffer[(icon_y + dy) * 320 + icon_x + dx] = 0xFFFF; // White
            }
        }
    }
}

fn printHelp() void {
    const stdout = std.fs.File.stdout();
    _ = stdout.write(
        \\ZigPod Simulator - PP5021C iPod Video Emulator
        \\
        \\Usage: zigpod-sim [options]
        \\
        \\Options:
        \\  -r, --rom <file>     Load ROM/firmware binary
        \\  -d, --disk <file>    Attach disk image
        \\  -a, --audio <file>   Play WAV audio file (requires -Dsdl2=true)
        \\  -s, --audio-samples <dir>  Create mock FAT32 with files from directory
        \\  -c, --cycles <n>     Cycles per frame (default: 10000)
        \\  -b, --break <addr>   Set breakpoint at address
        \\  --headless           Run without interactive mode
        \\  --debug              Enable debug logging
        \\  -h, --help           Show this help
        \\
        \\Interactive Commands:
        \\  r, run       - Run continuously
        \\  s, step      - Single step instruction
        \\  c, continue  - Run for one frame
        \\  p, regs      - Print CPU registers
        \\  m <addr>     - Dump memory at address
        \\  l, lcd       - Show LCD display
        \\  q, quit      - Exit simulator
        \\
        \\GUI Mode (build with -Dsdl2=true):
        \\  Arrow keys   - iPod buttons (menu, play, prev, next)
        \\  Space/Enter  - Play/Pause / Select
        \\  Scroll wheel - Rotate click wheel / Adjust volume
        \\  Mouse drag   - Rotate click wheel
        \\
        \\Examples:
        \\  zigpod-sim                         # Run with demo program
        \\  zigpod-sim -r firmware.bin         # Load and run firmware
        \\  zigpod-sim -a music.wav            # Play audio (GUI mode)
        \\  zigpod-sim -r rom.bin -d disk.img  # With disk image
        \\  zigpod-sim -s ./audio-samples      # Mock FAT32 with audio files
        \\
    ) catch {};
}
