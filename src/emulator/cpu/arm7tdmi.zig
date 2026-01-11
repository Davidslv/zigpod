//! ARM7TDMI CPU Core
//!
//! This is the main CPU implementation that ties together:
//! - Register file with mode banking
//! - ARM (32-bit) instruction decoding and execution
//! - Thumb (16-bit) instruction decoding and execution
//! - Exception handling
//! - Interrupt processing
//!
//! Reference: ARM7TDMI Technical Reference Manual (ARM DDI 0029E)

const std = @import("std");
const registers = @import("registers.zig");
const arm_decoder = @import("arm_decoder.zig");
const arm_executor = @import("arm_executor.zig");
const thumb_executor = @import("thumb_executor.zig");
const exceptions = @import("exceptions.zig");

const RegisterFile = registers.RegisterFile;
const Mode = registers.Mode;
const PSR = registers.PSR;
const MemoryBus = arm_executor.MemoryBus;
const Exception = exceptions.Exception;

/// CPU halt reason
pub const HaltReason = enum {
    none,
    breakpoint,
    undefined_instruction,
    halt_instruction,
    debug_request,
};

/// ARM7TDMI CPU state
pub const Arm7tdmi = struct {
    /// Register file with all banked registers
    regs: RegisterFile,

    /// Total cycles executed
    total_cycles: u64,

    /// Current halt state
    halt_reason: HaltReason,

    /// IRQ line state (directly connected to peripheral)
    irq_line: bool,

    /// FIQ line state
    fiq_line: bool,

    /// Pending IRQ that will be taken after current instruction
    irq_pending: bool,

    /// Pending FIQ that will be taken after current instruction
    fiq_pending: bool,

    const Self = @This();

    /// Initialize CPU in reset state
    pub fn init() Self {
        return .{
            .regs = RegisterFile.init(),
            .total_cycles = 0,
            .halt_reason = .none,
            .irq_line = false,
            .fiq_line = false,
            .irq_pending = false,
            .fiq_pending = false,
        };
    }

    /// Reset the CPU
    pub fn reset(self: *Self) void {
        // Save old state and enter reset exception
        self.regs = RegisterFile.init();
        _ = exceptions.enterException(&self.regs, .reset);
        self.halt_reason = .none;
        self.irq_pending = false;
        self.fiq_pending = false;
    }

    /// Execute one instruction and return cycles consumed
    pub fn step(self: *Self, bus: *const MemoryBus) u32 {
        // Check for pending interrupts before executing
        self.checkInterrupts();

        // Handle FIQ (higher priority than IRQ)
        if (self.fiq_pending) {
            self.fiq_pending = false;
            const cycles = exceptions.enterException(&self.regs, .fiq);
            self.total_cycles += cycles;
            return cycles;
        }

        // Handle IRQ
        if (self.irq_pending) {
            self.irq_pending = false;
            const cycles = exceptions.enterException(&self.regs, .irq);
            self.total_cycles += cycles;
            return cycles;
        }

        // Fetch and execute instruction based on current state
        const cycles = if (self.regs.cpsr.thumb)
            self.stepThumb(bus)
        else
            self.stepArm(bus);

        self.total_cycles += cycles;
        return cycles;
    }

    /// Execute one ARM instruction
    fn stepArm(self: *Self, bus: *const MemoryBus) u32 {
        // Fetch 32-bit instruction from PC
        const pc = self.regs.r[15];
        const instruction = bus.read32(pc);

        // Advance PC before execution (ARM prefetch behavior)
        self.regs.r[15] = pc +% 4;

        // Execute instruction
        return arm_executor.execute(&self.regs, bus, instruction);
    }

    /// Execute one Thumb instruction
    fn stepThumb(self: *Self, bus: *const MemoryBus) u32 {
        // Fetch 16-bit instruction from PC
        const pc = self.regs.r[15];
        const instruction = bus.read16(pc);

        // Advance PC before execution (Thumb prefetch behavior)
        self.regs.r[15] = pc +% 2;

        // Execute instruction
        return thumb_executor.execute(&self.regs, bus, instruction);
    }

    /// Check interrupt lines and set pending flags
    fn checkInterrupts(self: *Self) void {
        // Check FIQ (highest priority)
        if (self.fiq_line and !self.regs.cpsr.fiq_disable) {
            self.fiq_pending = true;
        }

        // Check IRQ
        if (self.irq_line and !self.regs.cpsr.irq_disable) {
            self.irq_pending = true;
        }
    }

    /// Set IRQ line state (called by interrupt controller)
    pub fn setIrqLine(self: *Self, active: bool) void {
        self.irq_line = active;
    }

    /// Set FIQ line state
    pub fn setFiqLine(self: *Self, active: bool) void {
        self.fiq_line = active;
    }

    /// Force an exception (e.g., for SWI, undefined instruction)
    pub fn raiseException(self: *Self, exception: Exception) u32 {
        const cycles = exceptions.enterException(&self.regs, exception);
        self.total_cycles += cycles;
        return cycles;
    }

    /// Halt the CPU with a reason
    pub fn halt(self: *Self, reason: HaltReason) void {
        self.halt_reason = reason;
    }

    /// Check if CPU is halted
    pub fn isHalted(self: *const Self) bool {
        return self.halt_reason != .none;
    }

    /// Resume from halt
    pub fn resumeExecution(self: *Self) void {
        self.halt_reason = .none;
    }

    /// Get current processor mode
    pub fn getMode(self: *const Self) ?Mode {
        return self.regs.cpsr.getMode();
    }

    /// Check if in Thumb state
    pub fn isThumb(self: *const Self) bool {
        return self.regs.cpsr.thumb;
    }

    /// Get program counter
    pub fn getPc(self: *const Self) u32 {
        return self.regs.r[15];
    }

    /// Set program counter
    pub fn setPc(self: *Self, value: u32) void {
        self.regs.set(15, value);
    }

    /// Get register value
    pub fn getReg(self: *const Self, reg: u4) u32 {
        return self.regs.get(reg);
    }

    /// Set register value
    pub fn setReg(self: *Self, reg: u4, value: u32) void {
        self.regs.set(reg, value);
    }

    /// Get CPSR as raw value
    pub fn getCpsr(self: *const Self) u32 {
        return @bitCast(self.regs.cpsr);
    }

    /// Set CPSR from raw value
    pub fn setCpsr(self: *Self, value: u32) void {
        const new_psr: PSR = @bitCast(value);
        if (new_psr.getMode()) |new_mode| {
            const old_mode = self.regs.cpsr.getMode();
            if (old_mode != null and old_mode.? != new_mode) {
                self.regs.switchMode(new_mode);
            }
        }
        self.regs.cpsr = @bitCast(value);
    }

    /// Get SPSR for current mode
    pub fn getSpsr(self: *const Self) ?u32 {
        return self.regs.getSpsr();
    }

    /// Get stack pointer
    pub fn getSp(self: *const Self) u32 {
        return self.regs.r[13];
    }

    /// Get link register
    pub fn getLr(self: *const Self) u32 {
        return self.regs.r[14];
    }

    /// Run until halted or cycle limit reached
    pub fn run(self: *Self, bus: *const MemoryBus, max_cycles: u64) u64 {
        const start_cycles = self.total_cycles;

        while (!self.isHalted() and (self.total_cycles - start_cycles) < max_cycles) {
            _ = self.step(bus);
        }

        return self.total_cycles - start_cycles;
    }

    /// Disassemble current instruction (for debugging)
    pub fn disassembleCurrentInstruction(self: *const Self, bus: *const MemoryBus) []const u8 {
        _ = self;
        _ = bus;
        // TODO: Implement disassembly
        return "<disassembly not implemented>";
    }
};

/// Create a simple memory bus for testing
pub fn createTestBus(memory: []u8) MemoryBus {
    const Context = struct {
        mem: []u8,

        fn read8(ctx: *anyopaque, addr: u32) u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (addr < self.mem.len) {
                return self.mem[addr];
            }
            return 0;
        }

        fn read16(ctx: *anyopaque, addr: u32) u16 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (addr + 1 < self.mem.len) {
                const aligned = addr & ~@as(u32, 1);
                return @as(u16, self.mem[aligned]) |
                    (@as(u16, self.mem[aligned + 1]) << 8);
            }
            return 0;
        }

        fn read32(ctx: *anyopaque, addr: u32) u32 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (addr + 3 < self.mem.len) {
                const aligned = addr & ~@as(u32, 3);
                return @as(u32, self.mem[aligned]) |
                    (@as(u32, self.mem[aligned + 1]) << 8) |
                    (@as(u32, self.mem[aligned + 2]) << 16) |
                    (@as(u32, self.mem[aligned + 3]) << 24);
            }
            return 0;
        }

        fn write8(ctx: *anyopaque, addr: u32, value: u8) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (addr < self.mem.len) {
                self.mem[addr] = value;
            }
        }

        fn write16(ctx: *anyopaque, addr: u32, value: u16) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (addr + 1 < self.mem.len) {
                const aligned = addr & ~@as(u32, 1);
                self.mem[aligned] = @truncate(value);
                self.mem[aligned + 1] = @truncate(value >> 8);
            }
        }

        fn write32(ctx: *anyopaque, addr: u32, value: u32) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (addr + 3 < self.mem.len) {
                const aligned = addr & ~@as(u32, 3);
                self.mem[aligned] = @truncate(value);
                self.mem[aligned + 1] = @truncate(value >> 8);
                self.mem[aligned + 2] = @truncate(value >> 16);
                self.mem[aligned + 3] = @truncate(value >> 24);
            }
        }
    };

    // Note: This is for testing only. The context pointer points to stack memory.
    var ctx = Context{ .mem = memory };
    _ = &ctx;

    return .{
        .context = undefined, // Will be set by caller
        .read8Fn = Context.read8,
        .read16Fn = Context.read16,
        .read32Fn = Context.read32,
        .write8Fn = Context.write8,
        .write16Fn = Context.write16,
        .write32Fn = Context.write32,
    };
}

// Tests
test "CPU initialization" {
    const cpu = Arm7tdmi.init();

    // Should start in Supervisor mode
    try std.testing.expectEqual(Mode.supervisor, cpu.getMode().?);

    // Should start in ARM state
    try std.testing.expect(!cpu.isThumb());

    // IRQ and FIQ should be disabled after reset
    try std.testing.expect(cpu.regs.cpsr.irq_disable);
    try std.testing.expect(cpu.regs.cpsr.fiq_disable);

    // PC should be at reset vector
    try std.testing.expectEqual(@as(u32, 0), cpu.getPc());
}

test "CPU reset" {
    var cpu = Arm7tdmi.init();

    // Modify state
    cpu.setReg(0, 0x12345678);
    cpu.total_cycles = 1000;

    // Reset
    cpu.reset();

    // Check reset state
    try std.testing.expectEqual(Mode.supervisor, cpu.getMode().?);
    try std.testing.expect(!cpu.isThumb());
    try std.testing.expectEqual(@as(u32, 0), cpu.getPc());
}

test "IRQ handling" {
    var cpu = Arm7tdmi.init();

    // Enable IRQ by clearing disable flag
    cpu.regs.cpsr.irq_disable = false;
    cpu.regs.r[15] = 0x1000;

    // Set IRQ line
    cpu.setIrqLine(true);

    // Create a simple memory bus for testing
    var memory = [_]u8{0} ** 256;
    const TestContext = struct {
        mem: *[256]u8,

        fn read8(ctx: *anyopaque, addr: u32) u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (addr < 256) return self.mem[addr];
            return 0;
        }
        fn read16(ctx: *anyopaque, addr: u32) u16 {
            _ = ctx;
            _ = addr;
            return 0;
        }
        fn read32(ctx: *anyopaque, addr: u32) u32 {
            _ = ctx;
            _ = addr;
            return 0;
        }
        fn write8(ctx: *anyopaque, addr: u32, value: u8) void {
            _ = ctx;
            _ = addr;
            _ = value;
        }
        fn write16(ctx: *anyopaque, addr: u32, value: u16) void {
            _ = ctx;
            _ = addr;
            _ = value;
        }
        fn write32(ctx: *anyopaque, addr: u32, value: u32) void {
            _ = ctx;
            _ = addr;
            _ = value;
        }
    };

    var ctx = TestContext{ .mem = &memory };
    const bus = MemoryBus{
        .context = @ptrCast(&ctx),
        .read8Fn = TestContext.read8,
        .read16Fn = TestContext.read16,
        .read32Fn = TestContext.read32,
        .write8Fn = TestContext.write8,
        .write16Fn = TestContext.write16,
        .write32Fn = TestContext.write32,
    };

    // Step should handle IRQ
    _ = cpu.step(&bus);

    // Should now be in IRQ mode at IRQ vector
    try std.testing.expectEqual(Mode.irq, cpu.getMode().?);
    try std.testing.expectEqual(@as(u32, 0x18), cpu.getPc());
    try std.testing.expect(cpu.regs.cpsr.irq_disable);
}

test "mode switching preserves registers" {
    var cpu = Arm7tdmi.init();

    // Set values in Supervisor mode
    cpu.setReg(13, 0xABCD0000); // SP
    cpu.setReg(14, 0xDEAD0000); // LR

    // Switch to IRQ mode
    cpu.regs.switchMode(.irq);

    // IRQ mode should have different SP/LR
    try std.testing.expectEqual(@as(u32, 0), cpu.getReg(13));
    try std.testing.expectEqual(@as(u32, 0), cpu.getReg(14));

    // Set IRQ mode values
    cpu.setReg(13, 0x11110000);
    cpu.setReg(14, 0x22220000);

    // Switch back to Supervisor
    cpu.regs.switchMode(.supervisor);

    // Should have original Supervisor values
    try std.testing.expectEqual(@as(u32, 0xABCD0000), cpu.getReg(13));
    try std.testing.expectEqual(@as(u32, 0xDEAD0000), cpu.getReg(14));
}
