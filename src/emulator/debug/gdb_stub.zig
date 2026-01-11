//! GDB Remote Serial Protocol Stub
//!
//! Implements the GDB Remote Serial Protocol (RSP) to allow debugging
//! firmware running in the emulator using standard GDB.
//!
//! Usage:
//!   1. Start emulator with --gdb-port 1234
//!   2. Run: arm-none-eabi-gdb firmware.elf
//!   3. In GDB: target remote :1234
//!
//! Reference: https://sourceware.org/gdb/onlinedocs/gdb/Remote-Protocol.html

const std = @import("std");
const net = std.net;

/// Callback interface for GDB debugging
pub const GdbCallbacks = struct {
    context: *anyopaque,
    readRegFn: *const fn (ctx: *anyopaque, reg: u8) u32,
    writeRegFn: *const fn (ctx: *anyopaque, reg: u8, value: u32) void,
    readMemFn: *const fn (ctx: *anyopaque, addr: u32) u8,
    writeMemFn: *const fn (ctx: *anyopaque, addr: u32, value: u8) void,
    stepFn: *const fn (ctx: *anyopaque) void,
    getPcFn: *const fn (ctx: *anyopaque) u32,

    pub fn readReg(self: *const GdbCallbacks, reg: u8) u32 {
        return self.readRegFn(self.context, reg);
    }

    pub fn writeReg(self: *const GdbCallbacks, reg: u8, value: u32) void {
        self.writeRegFn(self.context, reg, value);
    }

    pub fn readMem(self: *const GdbCallbacks, addr: u32) u8 {
        return self.readMemFn(self.context, addr);
    }

    pub fn writeMem(self: *const GdbCallbacks, addr: u32, value: u8) void {
        self.writeMemFn(self.context, addr, value);
    }

    pub fn step(self: *const GdbCallbacks) void {
        self.stepFn(self.context);
    }

    pub fn getPc(self: *const GdbCallbacks) u32 {
        return self.getPcFn(self.context);
    }
};

/// GDB Stub for ARM debugging
pub const GdbStub = struct {
    /// Network listener
    listener: ?net.Server,

    /// Current client connection
    client: ?net.Stream,

    /// Callbacks to emulator
    callbacks: GdbCallbacks,

    /// Breakpoints (up to 16)
    breakpoints: [16]?u32,
    num_breakpoints: usize,

    /// Receive buffer
    rx_buf: [4096]u8,
    rx_len: usize,

    /// Is target halted
    halted: bool,

    /// Port we're listening on
    port: u16,

    /// Continue running flag (set false to stop in GDB)
    running: bool,

    const Self = @This();

    /// Initialize GDB stub with callback interface
    pub fn init(callbacks: GdbCallbacks) Self {
        return .{
            .listener = null,
            .client = null,
            .callbacks = callbacks,
            .breakpoints = [_]?u32{null} ** 16,
            .num_breakpoints = 0,
            .rx_buf = undefined,
            .rx_len = 0,
            .halted = true,
            .port = 0,
            .running = false,
        };
    }

    /// Start listening on specified port
    pub fn listen(self: *Self, port: u16) !void {
        const address = net.Address.initIp4(.{ 127, 0, 0, 1 }, port);
        self.listener = try net.Address.listen(address, .{
            .reuse_address = true,
        });
        self.port = port;
    }

    /// Check if we have a client connected
    pub fn isConnected(self: *const Self) bool {
        return self.client != null;
    }

    /// Check if target is halted (waiting for GDB commands)
    pub fn isHalted(self: *const Self) bool {
        return self.halted;
    }

    /// Set halted state
    pub fn setHalted(self: *Self, halted: bool) void {
        self.halted = halted;
    }

    /// Accept incoming connection (non-blocking)
    pub fn acceptNonBlocking(self: *Self) bool {
        if (self.listener) |*listener| {
            const conn = listener.accept() catch return false;
            self.client = conn.stream;
            return true;
        }
        return false;
    }

    /// Close connection
    pub fn close(self: *Self) void {
        if (self.client) |client| {
            client.close();
            self.client = null;
        }
        if (self.listener) |*listener| {
            listener.deinit();
            self.listener = null;
        }
    }

    /// Poll for incoming data and process commands
    pub fn poll(self: *Self) void {
        if (self.client == null) return;

        // Check for incoming data (non-blocking)
        var buf: [256]u8 = undefined;
        const n = self.client.?.read(&buf) catch {
            self.client = null;
            return;
        };

        if (n == 0) return;

        // Append to receive buffer
        const space = self.rx_buf.len - self.rx_len;
        const to_copy = @min(n, space);
        @memcpy(self.rx_buf[self.rx_len .. self.rx_len + to_copy], buf[0..to_copy]);
        self.rx_len += to_copy;

        // Process complete packets
        self.processPackets();
    }

    /// Process buffered packets
    fn processPackets(self: *Self) void {
        while (self.rx_len > 0) {
            // Handle interrupt (Ctrl+C)
            if (self.rx_buf[0] == 0x03) {
                self.halted = true;
                self.sendPacket("S05"); // SIGTRAP
                self.consumeBytes(1);
                continue;
            }

            // Find packet start
            const start = std.mem.indexOf(u8, self.rx_buf[0..self.rx_len], "$") orelse {
                self.rx_len = 0;
                return;
            };

            // Find packet end
            const end = std.mem.indexOf(u8, self.rx_buf[start..self.rx_len], "#") orelse return;
            const end_abs = start + end;

            // Need 2 more bytes for checksum
            if (end_abs + 3 > self.rx_len) return;

            // Extract packet data (between $ and #)
            const data = self.rx_buf[start + 1 .. end_abs];

            // Send ACK
            self.sendRaw("+");

            // Process command
            self.handleCommand(data);

            // Consume packet (including $, #, and 2 checksum bytes)
            self.consumeBytes(end_abs + 3);
        }
    }

    /// Consume n bytes from receive buffer
    fn consumeBytes(self: *Self, n: usize) void {
        if (n >= self.rx_len) {
            self.rx_len = 0;
        } else {
            std.mem.copyForwards(u8, &self.rx_buf, self.rx_buf[n..self.rx_len]);
            self.rx_len -= n;
        }
    }

    /// Handle a GDB command
    fn handleCommand(self: *Self, cmd: []const u8) void {
        if (cmd.len == 0) return;

        switch (cmd[0]) {
            '?' => {
                // Halt reason
                self.sendPacket("S05"); // SIGTRAP
            },
            'g' => {
                // Read all registers (R0-R15, CPSR)
                var response: [17 * 8 + 1]u8 = undefined;
                var pos: usize = 0;
                for (0..17) |i| {
                    const val = self.callbacks.readReg(@intCast(i));
                    _ = std.fmt.bufPrint(response[pos .. pos + 8], "{x:0>8}", .{swapEndian(val)}) catch continue;
                    pos += 8;
                }
                self.sendPacket(response[0..pos]);
            },
            'G' => {
                // Write all registers
                if (cmd.len < 1 + 17 * 8) {
                    self.sendPacket("E01");
                    return;
                }
                for (0..17) |i| {
                    const hex = cmd[1 + i * 8 .. 1 + i * 8 + 8];
                    const val = std.fmt.parseInt(u32, hex, 16) catch continue;
                    self.callbacks.writeReg(@intCast(i), swapEndian(val));
                }
                self.sendPacket("OK");
            },
            'm' => {
                // Read memory: m<addr>,<length>
                const comma = std.mem.indexOf(u8, cmd, ",") orelse {
                    self.sendPacket("E01");
                    return;
                };
                const addr = std.fmt.parseInt(u32, cmd[1..comma], 16) catch {
                    self.sendPacket("E01");
                    return;
                };
                const len = std.fmt.parseInt(usize, cmd[comma + 1 ..], 16) catch {
                    self.sendPacket("E01");
                    return;
                };

                // Read memory and format as hex
                var response: [4096]u8 = undefined;
                const max_len = @min(len, response.len / 2);
                for (0..max_len) |i| {
                    const byte = self.callbacks.readMem(addr + @as(u32, @intCast(i)));
                    _ = std.fmt.bufPrint(response[i * 2 .. i * 2 + 2], "{x:0>2}", .{byte}) catch continue;
                }
                self.sendPacket(response[0 .. max_len * 2]);
            },
            'M' => {
                // Write memory: M<addr>,<length>:<data>
                const comma = std.mem.indexOf(u8, cmd, ",") orelse {
                    self.sendPacket("E01");
                    return;
                };
                const colon = std.mem.indexOf(u8, cmd, ":") orelse {
                    self.sendPacket("E01");
                    return;
                };
                const addr = std.fmt.parseInt(u32, cmd[1..comma], 16) catch {
                    self.sendPacket("E01");
                    return;
                };
                const data = cmd[colon + 1 ..];

                // Write hex data to memory
                var i: usize = 0;
                while (i + 2 <= data.len) : (i += 2) {
                    const byte = std.fmt.parseInt(u8, data[i .. i + 2], 16) catch continue;
                    self.callbacks.writeMem(addr + @as(u32, @intCast(i / 2)), byte);
                }
                self.sendPacket("OK");
            },
            's' => {
                // Single step
                self.callbacks.step();
                self.sendPacket("S05"); // SIGTRAP
            },
            'c' => {
                // Continue
                self.halted = false;
                self.running = true;
                // Response will be sent when we hit breakpoint or stop
            },
            'Z' => {
                // Set breakpoint: Z<type>,<addr>,<kind>
                if (cmd.len < 3 or cmd[1] != '0') {
                    // Only support software breakpoints (type 0)
                    self.sendPacket("");
                    return;
                }
                const comma = std.mem.indexOf(u8, cmd[2..], ",") orelse {
                    self.sendPacket("E01");
                    return;
                };
                const addr = std.fmt.parseInt(u32, cmd[3 .. 2 + comma], 16) catch {
                    self.sendPacket("E01");
                    return;
                };
                if (self.addBreakpoint(addr)) {
                    self.sendPacket("OK");
                } else {
                    self.sendPacket("E01");
                }
            },
            'z' => {
                // Remove breakpoint: z<type>,<addr>,<kind>
                if (cmd.len < 3 or cmd[1] != '0') {
                    self.sendPacket("");
                    return;
                }
                const comma = std.mem.indexOf(u8, cmd[2..], ",") orelse {
                    self.sendPacket("E01");
                    return;
                };
                const addr = std.fmt.parseInt(u32, cmd[3 .. 2 + comma], 16) catch {
                    self.sendPacket("E01");
                    return;
                };
                self.removeBreakpoint(addr);
                self.sendPacket("OK");
            },
            'q' => {
                // Query commands
                if (std.mem.startsWith(u8, cmd, "qSupported")) {
                    self.sendPacket("PacketSize=4096");
                } else if (std.mem.startsWith(u8, cmd, "qAttached")) {
                    self.sendPacket("1");
                } else if (std.mem.startsWith(u8, cmd, "qTStatus")) {
                    self.sendPacket("");
                } else if (std.mem.startsWith(u8, cmd, "qfThreadInfo")) {
                    self.sendPacket("m1");
                } else if (std.mem.startsWith(u8, cmd, "qsThreadInfo")) {
                    self.sendPacket("l");
                } else if (std.mem.startsWith(u8, cmd, "qC")) {
                    self.sendPacket("QC1");
                } else {
                    self.sendPacket("");
                }
            },
            'H' => {
                // Set thread (we only have one)
                self.sendPacket("OK");
            },
            'v' => {
                // Extended commands
                if (std.mem.startsWith(u8, cmd, "vCont?")) {
                    self.sendPacket("vCont;c;s");
                } else if (std.mem.startsWith(u8, cmd, "vCont;c")) {
                    self.halted = false;
                    self.running = true;
                } else if (std.mem.startsWith(u8, cmd, "vCont;s")) {
                    self.callbacks.step();
                    self.sendPacket("S05");
                } else {
                    self.sendPacket("");
                }
            },
            'k' => {
                // Kill - close connection
                self.close();
            },
            'D' => {
                // Detach
                self.sendPacket("OK");
                self.close();
            },
            else => {
                // Unknown command
                self.sendPacket("");
            },
        }
    }

    /// Add a breakpoint
    fn addBreakpoint(self: *Self, addr: u32) bool {
        for (&self.breakpoints) |*bp| {
            if (bp.* == null) {
                bp.* = addr;
                self.num_breakpoints += 1;
                return true;
            }
        }
        return false; // No space
    }

    /// Remove a breakpoint
    fn removeBreakpoint(self: *Self, addr: u32) void {
        for (&self.breakpoints) |*bp| {
            if (bp.* == addr) {
                bp.* = null;
                self.num_breakpoints -= 1;
                return;
            }
        }
    }

    /// Check if address is a breakpoint
    pub fn isBreakpoint(self: *Self, addr: u32) bool {
        for (self.breakpoints) |bp| {
            if (bp == addr) return true;
        }
        return false;
    }

    /// Notify GDB that we hit a breakpoint
    pub fn notifyBreakpoint(self: *Self) void {
        self.halted = true;
        self.sendPacket("S05"); // SIGTRAP
    }

    /// Send a packet with checksum
    fn sendPacket(self: *Self, data: []const u8) void {
        var checksum: u8 = 0;
        for (data) |c| {
            checksum +%= c;
        }

        var buf: [4200]u8 = undefined;
        const result = std.fmt.bufPrint(&buf, "${s}#{x:0>2}", .{ data, checksum }) catch return;
        self.sendRaw(result);
    }

    /// Send raw data
    fn sendRaw(self: *Self, data: []const u8) void {
        if (self.client) |client| {
            _ = client.write(data) catch {};
        }
    }

    /// Swap endianness (GDB uses target byte order)
    fn swapEndian(val: u32) u32 {
        return ((val & 0xFF) << 24) |
            ((val & 0xFF00) << 8) |
            ((val & 0xFF0000) >> 8) |
            ((val & 0xFF000000) >> 24);
    }

    /// Check if current PC is at a breakpoint
    pub fn checkBreakpoint(self: *Self) bool {
        const pc = self.callbacks.getPc();
        return self.isBreakpoint(pc);
    }

    /// Run one step and check for breakpoints
    /// Returns true if should continue running, false if halted
    pub fn runStep(self: *Self) bool {
        if (!self.running) return false;

        // Execute one instruction
        self.callbacks.step();

        // Check for breakpoint
        if (self.checkBreakpoint()) {
            self.running = false;
            self.halted = true;
            self.notifyBreakpoint();
            return false;
        }

        return true;
    }
};

// Tests
test "gdb stub initialization" {
    // Dummy callbacks for testing
    const TestCtx = struct {
        fn readReg(_: *anyopaque, _: u8) u32 {
            return 0;
        }
        fn writeReg(_: *anyopaque, _: u8, _: u32) void {}
        fn readMem(_: *anyopaque, _: u32) u8 {
            return 0;
        }
        fn writeMem(_: *anyopaque, _: u32, _: u8) void {}
        fn step(_: *anyopaque) void {}
        fn getPc(_: *anyopaque) u32 {
            return 0;
        }
    };

    var ctx: u8 = 0;
    var stub = GdbStub.init(.{
        .context = @ptrCast(&ctx),
        .readRegFn = TestCtx.readReg,
        .writeRegFn = TestCtx.writeReg,
        .readMemFn = TestCtx.readMem,
        .writeMemFn = TestCtx.writeMem,
        .stepFn = TestCtx.step,
        .getPcFn = TestCtx.getPc,
    });

    try std.testing.expect(stub.halted);
    try std.testing.expect(!stub.isConnected());
}
