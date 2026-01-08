//! ARM7TDMI CPU Emulator
//!
//! Complete ARM7TDMI processor emulation including:
//! - Instruction fetch, decode, execute cycle
//! - Exception handling
//! - Interrupt processing
//! - Memory bus interface

const std = @import("std");
const registers = @import("registers.zig");
const decoder = @import("decoder.zig");
const executor = @import("executor.zig");
const exceptions = @import("exceptions.zig");

pub const RegisterFile = registers.RegisterFile;
pub const Psr = registers.Psr;
pub const Mode = registers.Mode;
pub const Instruction = decoder.Instruction;
pub const MemoryBus = executor.MemoryBus;
pub const MemoryError = executor.MemoryError;
pub const Exception = exceptions.Exception;
pub const ExceptionHandler = exceptions.ExceptionHandler;

/// CPU state
pub const CpuState = enum {
    running,
    halted, // WFI - waiting for interrupt
    stopped, // Breakpoint or error
};

/// ARM7TDMI CPU Emulator
pub const Arm7Tdmi = struct {
    /// CPU registers
    regs: RegisterFile,

    /// Exception handler configuration
    exception_handler: ExceptionHandler,

    /// Current CPU state
    state: CpuState,

    /// Total cycles executed
    cycles: u64,

    /// Instructions executed
    instructions: u64,

    /// IRQ line state
    irq_pending: bool,

    /// FIQ line state
    fiq_pending: bool,

    /// Memory bus (set by caller)
    memory: ?*MemoryBus,

    /// Breakpoints (max 16)
    breakpoints: [16]?u32,
    breakpoint_count: u8,

    const Self = @This();

    /// Create a new ARM7TDMI emulator
    pub fn init() Self {
        return .{
            .regs = RegisterFile.init(),
            .exception_handler = ExceptionHandler.init(),
            .state = .running,
            .cycles = 0,
            .instructions = 0,
            .irq_pending = false,
            .fiq_pending = false,
            .memory = null,
            .breakpoints = [_]?u32{null} ** 16,
            .breakpoint_count = 0,
        };
    }

    /// Reset the CPU to initial state
    pub fn reset(self: *Self) void {
        self.regs = RegisterFile.init();
        self.state = .running;
        self.irq_pending = false;
        self.fiq_pending = false;

        // Raise reset exception
        if (self.state == .running) {
            _ = self.exception_handler.raiseException(&self.regs, .reset);
        }
    }

    /// Set the memory bus
    pub fn setMemory(self: *Self, memory: *MemoryBus) void {
        self.memory = memory;
    }

    /// Assert IRQ line
    pub fn assertIrq(self: *Self, active: bool) void {
        self.irq_pending = active;
        if (active and self.state == .halted) {
            self.state = .running;
        }
    }

    /// Assert FIQ line
    pub fn assertFiq(self: *Self, active: bool) void {
        self.fiq_pending = active;
        if (active and self.state == .halted) {
            self.state = .running;
        }
    }

    /// Add a breakpoint
    pub fn addBreakpoint(self: *Self, addr: u32) bool {
        if (self.breakpoint_count >= 16) return false;

        // Check if already exists
        for (self.breakpoints) |bp| {
            if (bp == addr) return true;
        }

        self.breakpoints[self.breakpoint_count] = addr;
        self.breakpoint_count += 1;
        return true;
    }

    /// Remove a breakpoint
    pub fn removeBreakpoint(self: *Self, addr: u32) bool {
        for (&self.breakpoints, 0..) |*bp, i| {
            if (bp.* == addr) {
                bp.* = null;
                // Shift remaining breakpoints
                if (i < self.breakpoint_count - 1) {
                    for (i..self.breakpoint_count - 1) |j| {
                        self.breakpoints[j] = self.breakpoints[j + 1];
                    }
                }
                self.breakpoints[self.breakpoint_count - 1] = null;
                self.breakpoint_count -= 1;
                return true;
            }
        }
        return false;
    }

    /// Check if address is a breakpoint
    fn isBreakpoint(self: *const Self, addr: u32) bool {
        for (self.breakpoints[0..self.breakpoint_count]) |bp| {
            if (bp == addr) return true;
        }
        return false;
    }

    /// Execute one instruction
    pub fn step(self: *Self) StepResult {
        if (self.memory == null) {
            return .{ .status = .error_no_memory, .cycles = 0 };
        }

        const memory = self.memory.?;

        // Check for pending interrupts
        if (self.checkInterrupts()) {
            return .{ .status = .interrupt_taken, .cycles = 3 };
        }

        // Handle halted state
        if (self.state == .halted) {
            return .{ .status = .halted, .cycles = 1 };
        }

        // Check breakpoint
        const pc = self.regs.getPC();
        if (self.isBreakpoint(pc)) {
            self.state = .stopped;
            return .{ .status = .breakpoint, .cycles = 0 };
        }

        // Fetch instruction
        const raw_instruction = memory.read32(pc) catch {
            // Prefetch abort
            _ = self.exception_handler.raiseException(&self.regs, .prefetch_abort);
            return .{ .status = .prefetch_abort, .cycles = 3 };
        };

        // Decode instruction
        const instruction = decoder.decode(raw_instruction);

        // Execute instruction
        const exec_result = executor.execute(instruction, &self.regs, memory) catch |err| {
            return switch (err) {
                error.MemoryFault => blk: {
                    // Data abort
                    _ = self.exception_handler.raiseException(&self.regs, .data_abort);
                    break :blk .{ .status = .data_abort, .cycles = 3 };
                },
                error.UndefinedInstruction => blk: {
                    _ = self.exception_handler.raiseException(&self.regs, .undefined_instruction);
                    break :blk .{ .status = .undefined_instruction, .cycles = 3 };
                },
                else => .{ .status = .execution_error, .cycles = 1 },
            };
        };

        // Handle exception from execution (e.g., SWI)
        if (exec_result.exception) |exc| {
            switch (exc) {
                .software_interrupt => {
                    _ = self.exception_handler.raiseException(&self.regs, .software_interrupt);
                },
                .undefined_instruction => {
                    _ = self.exception_handler.raiseException(&self.regs, .undefined_instruction);
                },
                else => {},
            }
        }

        self.cycles += exec_result.cycles;
        self.instructions += 1;

        return .{ .status = .ok, .cycles = exec_result.cycles };
    }

    /// Execute multiple cycles
    pub fn run(self: *Self, max_cycles: u64) RunResult {
        var cycles_run: u64 = 0;
        var instructions_run: u64 = 0;

        while (cycles_run < max_cycles) {
            const result = self.step();

            cycles_run += result.cycles;
            if (result.status == .ok) {
                instructions_run += 1;
            }

            // Stop on certain conditions
            switch (result.status) {
                .ok, .interrupt_taken => continue,
                .halted => {
                    // In halted state, consume remaining cycles
                    cycles_run = max_cycles;
                    break;
                },
                .breakpoint => break,
                else => break,
            }
        }

        return .{
            .cycles = cycles_run,
            .instructions = instructions_run,
            .stop_reason = self.state,
        };
    }

    /// Check and handle pending interrupts
    fn checkInterrupts(self: *Self) bool {
        // FIQ has higher priority
        if (self.fiq_pending and self.regs.fiqEnabled()) {
            _ = self.exception_handler.raiseException(&self.regs, .fiq);
            return true;
        }

        if (self.irq_pending and self.regs.irqEnabled()) {
            _ = self.exception_handler.raiseException(&self.regs, .irq);
            return true;
        }

        return false;
    }

    /// Get current PC
    pub fn getPC(self: *const Self) u32 {
        return self.regs.getPC();
    }

    /// Set PC (for debugging/testing)
    pub fn setPC(self: *Self, value: u32) void {
        self.regs.setPC(value);
    }

    /// Get register value
    pub fn getReg(self: *const Self, reg: u4) u32 {
        return self.regs.get(reg);
    }

    /// Set register value
    pub fn setReg(self: *Self, reg: u4, value: u32) void {
        self.regs.set(reg, value);
    }

    /// Get CPSR
    pub fn getCPSR(self: *const Self) u32 {
        return self.regs.cpsr.toU32();
    }

    /// Get current mode
    pub fn getMode(self: *const Self) Mode {
        return self.regs.getMode();
    }
};

/// Result of a single step
pub const StepResult = struct {
    status: StepStatus,
    cycles: u32,
};

pub const StepStatus = enum {
    ok,
    halted,
    breakpoint,
    interrupt_taken,
    prefetch_abort,
    data_abort,
    undefined_instruction,
    execution_error,
    error_no_memory,
};

/// Result of running for multiple cycles
pub const RunResult = struct {
    cycles: u64,
    instructions: u64,
    stop_reason: CpuState,
};

// ============================================================
// Tests
// ============================================================

// Simple memory for testing
const TestMemory = struct {
    data: [4096]u8,

    fn read32(ctx: *anyopaque, addr: u32) MemoryError!u32 {
        const self: *TestMemory = @ptrCast(@alignCast(ctx));
        if (addr >= self.data.len - 3) return error.UnmappedAddress;
        return std.mem.readInt(u32, self.data[addr..][0..4], .little);
    }

    fn read16(ctx: *anyopaque, addr: u32) MemoryError!u16 {
        const self: *TestMemory = @ptrCast(@alignCast(ctx));
        if (addr >= self.data.len - 1) return error.UnmappedAddress;
        return std.mem.readInt(u16, self.data[addr..][0..2], .little);
    }

    fn read8(ctx: *anyopaque, addr: u32) MemoryError!u8 {
        const self: *TestMemory = @ptrCast(@alignCast(ctx));
        if (addr >= self.data.len) return error.UnmappedAddress;
        return self.data[addr];
    }

    fn write32(ctx: *anyopaque, addr: u32, value: u32) MemoryError!void {
        const self: *TestMemory = @ptrCast(@alignCast(ctx));
        if (addr >= self.data.len - 3) return error.UnmappedAddress;
        std.mem.writeInt(u32, self.data[addr..][0..4], value, .little);
    }

    fn write16(ctx: *anyopaque, addr: u32, value: u16) MemoryError!void {
        const self: *TestMemory = @ptrCast(@alignCast(ctx));
        if (addr >= self.data.len - 1) return error.UnmappedAddress;
        std.mem.writeInt(u16, self.data[addr..][0..2], value, .little);
    }

    fn write8(ctx: *anyopaque, addr: u32, value: u8) MemoryError!void {
        const self: *TestMemory = @ptrCast(@alignCast(ctx));
        if (addr >= self.data.len) return error.UnmappedAddress;
        self.data[addr] = value;
    }

    fn bus(self: *TestMemory) MemoryBus {
        return .{
            .context = self,
            .read32Fn = read32,
            .read16Fn = read16,
            .read8Fn = read8,
            .write32Fn = write32,
            .write16Fn = write16,
            .write8Fn = write8,
        };
    }
};

test "CPU initialization" {
    const cpu = Arm7Tdmi.init();

    // Should start in supervisor mode
    try std.testing.expectEqual(Mode.supervisor, cpu.getMode());

    // Should be at PC = 0 (after reset exception, actually at reset vector)
    try std.testing.expectEqual(CpuState.running, cpu.state);
}

test "CPU step without memory" {
    var cpu = Arm7Tdmi.init();
    cpu.setPC(0);

    const result = cpu.step();
    try std.testing.expectEqual(StepStatus.error_no_memory, result.status);
}

test "CPU simple execution" {
    var cpu = Arm7Tdmi.init();
    var mem = TestMemory{ .data = [_]u8{0} ** 4096 };
    var bus = mem.bus();
    cpu.setMemory(&bus);

    // Write MOV R0, #42 at address 0
    // E3A0002A
    std.mem.writeInt(u32, mem.data[0..4], 0xE3A0002A, .little);
    cpu.setPC(0);

    const result = cpu.step();
    try std.testing.expectEqual(StepStatus.ok, result.status);
    try std.testing.expectEqual(@as(u32, 42), cpu.getReg(0));
}

test "CPU sequence execution" {
    var cpu = Arm7Tdmi.init();
    var mem = TestMemory{ .data = [_]u8{0} ** 4096 };
    var bus = mem.bus();
    cpu.setMemory(&bus);

    // Write a sequence:
    // 0x00: MOV R0, #10     (E3A0000A)
    // 0x04: MOV R1, #20     (E3A01014)
    // 0x08: ADD R2, R0, R1  (E0802001)
    std.mem.writeInt(u32, mem.data[0x00..][0..4], 0xE3A0000A, .little);
    std.mem.writeInt(u32, mem.data[0x04..][0..4], 0xE3A01014, .little);
    std.mem.writeInt(u32, mem.data[0x08..][0..4], 0xE0802001, .little);
    cpu.setPC(0);

    // Execute 3 instructions
    _ = cpu.step();
    try std.testing.expectEqual(@as(u32, 10), cpu.getReg(0));

    _ = cpu.step();
    try std.testing.expectEqual(@as(u32, 20), cpu.getReg(1));

    _ = cpu.step();
    try std.testing.expectEqual(@as(u32, 30), cpu.getReg(2));
}

test "CPU run for cycles" {
    var cpu = Arm7Tdmi.init();
    var mem = TestMemory{ .data = [_]u8{0} ** 4096 };
    var bus = mem.bus();
    cpu.setMemory(&bus);

    // Fill memory with NOPs (MOV R0, R0 = E1A00000)
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        std.mem.writeInt(u32, mem.data[i * 4 ..][0..4], 0xE1A00000, .little);
    }
    cpu.setPC(0);

    const result = cpu.run(10);
    try std.testing.expect(result.instructions > 0);
    try std.testing.expect(result.cycles >= result.instructions);
}

test "CPU breakpoint" {
    var cpu = Arm7Tdmi.init();
    var mem = TestMemory{ .data = [_]u8{0} ** 4096 };
    var bus = mem.bus();
    cpu.setMemory(&bus);

    // Fill with NOPs
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        std.mem.writeInt(u32, mem.data[i * 4 ..][0..4], 0xE1A00000, .little);
    }
    cpu.setPC(0);

    // Set breakpoint at address 0x10 (4th instruction)
    try std.testing.expect(cpu.addBreakpoint(0x10));

    // Run until breakpoint
    const result = cpu.run(100);
    try std.testing.expectEqual(CpuState.stopped, result.stop_reason);
    try std.testing.expectEqual(@as(u32, 0x10), cpu.getPC());
}

test "CPU IRQ handling" {
    var cpu = Arm7Tdmi.init();
    var mem = TestMemory{ .data = [_]u8{0} ** 4096 };
    var bus = mem.bus();
    cpu.setMemory(&bus);

    // Switch to user mode with IRQ enabled
    cpu.regs.switchMode(.user);
    cpu.regs.cpsr.irq_disable = false;
    cpu.setPC(0x100);

    // Write a NOP at 0x100
    std.mem.writeInt(u32, mem.data[0x100..][0..4], 0xE1A00000, .little);

    // Write a NOP at IRQ vector (0x18)
    std.mem.writeInt(u32, mem.data[0x18..][0..4], 0xE1A00000, .little);

    // Assert IRQ
    cpu.assertIrq(true);

    // Step should take interrupt
    const result = cpu.step();
    try std.testing.expectEqual(StepStatus.interrupt_taken, result.status);

    // Should now be at IRQ vector
    try std.testing.expectEqual(@as(u32, 0x18), cpu.getPC());

    // Should be in IRQ mode
    try std.testing.expectEqual(Mode.irq, cpu.getMode());
}

test "CPU cycles count" {
    var cpu = Arm7Tdmi.init();
    var mem = TestMemory{ .data = [_]u8{0} ** 4096 };
    var bus = mem.bus();
    cpu.setMemory(&bus);

    // Write MOV R0, #0
    std.mem.writeInt(u32, mem.data[0..4], 0xE3A00000, .little);
    cpu.setPC(0);

    const cycles_before = cpu.cycles;
    _ = cpu.step();
    try std.testing.expect(cpu.cycles > cycles_before);
}
