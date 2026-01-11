//! Rockbox-like PP5020 Test Firmware Generator
//!
//! Generates ARM machine code that exercises PP5020 peripherals
//! similar to how Rockbox initializes the iPod Video.

const std = @import("std");

// PP5020 Register Addresses
const PROC_ID: u32 = 0x60000000;
const DEV_EN: u32 = 0x6000600C;
const USEC_TIMER: u32 = 0x60005010;
const GPIOA_ENABLE: u32 = 0x6000D000;
const GPO32_EN: u32 = 0x70000084;
const GPO32_VAL: u32 = 0x70000080;
const IDE0_CFG: u32 = 0xC3000028;

// ATA
const ATA_BASE: u32 = 0xC3000000;
const ATA_DATA: u32 = ATA_BASE + 0x1E0;
const ATA_NSECTOR: u32 = ATA_BASE + 0x1E8;
const ATA_SECTOR: u32 = ATA_BASE + 0x1EC;
const ATA_LCYL: u32 = ATA_BASE + 0x1F0;
const ATA_HCYL: u32 = ATA_BASE + 0x1F4;
const ATA_SELECT: u32 = ATA_BASE + 0x1F8;
const ATA_COMMAND: u32 = ATA_BASE + 0x1FC;

const IISCONFIG: u32 = 0x70002800;
const CPU_INT_STAT: u32 = 0x60004000;
const RESULT_BASE: u32 = 0x40000100;

const CodeGen = struct {
    code: [2048]u32 = undefined,
    pos: usize = 0,

    fn emit(self: *CodeGen, instr: u32) void {
        self.code[self.pos] = instr;
        self.pos += 1;
    }

    fn movImm(self: *CodeGen, rd: u4, imm: u32) void {
        if (imm <= 0xFF) {
            self.emit(0xE3A00000 | (@as(u32, rd) << 12) | imm);
        } else {
            const low = imm & 0xFFFF;
            const high = (imm >> 16) & 0xFFFF;
            self.emit(0xE3A00000 | (@as(u32, rd) << 12) | (low & 0xFF));
            if ((low >> 8) != 0) {
                self.emit(0xE3800C00 | (@as(u32, rd) << 12) | (@as(u32, rd) << 16) | ((low >> 8) & 0xFF));
            }
            if ((high & 0xFF) != 0) {
                self.emit(0xE3800800 | (@as(u32, rd) << 12) | (@as(u32, rd) << 16) | (high & 0xFF));
            }
            if ((high >> 8) != 0) {
                self.emit(0xE3800400 | (@as(u32, rd) << 12) | (@as(u32, rd) << 16) | ((high >> 8) & 0xFF));
            }
        }
    }

    fn ldr(self: *CodeGen, rd: u4, rn: u4) void {
        self.emit(0xE5900000 | (@as(u32, rn) << 16) | (@as(u32, rd) << 12));
    }

    fn str(self: *CodeGen, rd: u4, rn: u4) void {
        self.emit(0xE5800000 | (@as(u32, rn) << 16) | (@as(u32, rd) << 12));
    }

    fn strOff(self: *CodeGen, rd: u4, rn: u4, off: u12) void {
        self.emit(0xE5800000 | (@as(u32, rn) << 16) | (@as(u32, rd) << 12) | off);
    }

    fn orr(self: *CodeGen, rd: u4, rn: u4, rm: u4) void {
        self.emit(0xE1800000 | (@as(u32, rn) << 16) | (@as(u32, rd) << 12) | @as(u32, rm));
    }

    fn nopLoop(self: *CodeGen, count: u32) void {
        self.movImm(11, count);
        const loop = self.pos;
        self.emit(0xE2500001 | (11 << 16) | (11 << 12)); // SUBS R11, #1
        const off: i32 = @as(i32, @intCast(loop)) - @as(i32, @intCast(self.pos)) - 2;
        const off_u: u32 = @bitCast(off);
        self.emit(0x1A000000 | (off_u & 0xFFFFFF)); // BNE
    }

    fn waitAtaDrq(self: *CodeGen) void {
        self.movImm(10, ATA_COMMAND);
        const loop = self.pos;
        self.ldr(9, 10);
        self.emit(0xE3190008); // TST R9, #8
        const off: i32 = @as(i32, @intCast(loop)) - @as(i32, @intCast(self.pos)) - 2;
        const off_u: u32 = @bitCast(off);
        self.emit(0x0A000000 | (off_u & 0xFFFFFF)); // BEQ
    }

    fn infLoop(self: *CodeGen) void {
        self.emit(0xEAFFFFFE); // B .
    }
};

pub fn main() !void {
    var gen = CodeGen{};

    // R12 = result base
    gen.movImm(12, RESULT_BASE);

    // Test 1: PROC_ID
    gen.movImm(0, 0x50524F43); // "PROC"
    gen.strOff(0, 12, 0);
    gen.movImm(1, PROC_ID);
    gen.ldr(2, 1);
    gen.strOff(2, 12, 4);

    // Test 2: DEV_EN
    gen.movImm(0, 0x44455645); // "DEVE"
    gen.strOff(0, 12, 8);
    gen.movImm(1, DEV_EN);
    gen.ldr(2, 1);
    gen.strOff(2, 12, 12);
    gen.movImm(3, 0x0020002F);
    gen.orr(2, 2, 3);
    gen.str(2, 1);

    // Test 3: USEC_TIMER
    gen.movImm(0, 0x54494D45); // "TIME"
    gen.strOff(0, 12, 16);
    gen.movImm(1, USEC_TIMER);
    gen.ldr(2, 1);
    gen.strOff(2, 12, 20);
    gen.nopLoop(100);
    gen.ldr(3, 1);
    gen.strOff(3, 12, 24);

    // Test 4: GPIO
    gen.movImm(0, 0x4750494F); // "GPIO"
    gen.strOff(0, 12, 28);
    gen.movImm(1, GPIOA_ENABLE);
    gen.movImm(2, 0xFF);
    gen.str(2, 1);
    gen.ldr(3, 1);
    gen.strOff(3, 12, 32);

    // Test 5: GPO32
    gen.movImm(0, 0x47504F33); // "GPO3"
    gen.strOff(0, 12, 36);
    gen.movImm(1, GPO32_EN);
    gen.movImm(2, 0x80);
    gen.emit(0xE3822B02); // ORR R2, R2, #0x80000000
    gen.str(2, 1);
    gen.movImm(1, GPO32_VAL);
    gen.movImm(2, 0);
    gen.str(2, 1);
    gen.nopLoop(1000);

    // Test 6: IDE Config
    gen.movImm(0, 0x49444530); // "IDE0"
    gen.strOff(0, 12, 40);
    gen.movImm(1, IDE0_CFG);
    gen.movImm(2, 0x10);
    gen.emit(0xE3822801); // ORR R2, R2, #0x10000
    gen.str(2, 1);
    gen.ldr(3, 1);
    gen.strOff(3, 12, 44);

    // Test 7: ATA Status
    gen.movImm(0, 0x41544131); // "ATA1"
    gen.strOff(0, 12, 48);
    gen.movImm(1, ATA_SELECT);
    gen.movImm(2, 0xE0);
    gen.str(2, 1);
    gen.nopLoop(100);
    gen.movImm(1, ATA_COMMAND);
    gen.ldr(2, 1);
    gen.strOff(2, 12, 52);

    // Test 8: ATA Read MBR
    gen.movImm(0, 0x4D425231); // "MBR1"
    gen.strOff(0, 12, 56);
    gen.movImm(1, ATA_SECTOR);
    gen.movImm(2, 0);
    gen.str(2, 1);
    gen.movImm(1, ATA_LCYL);
    gen.str(2, 1);
    gen.movImm(1, ATA_HCYL);
    gen.str(2, 1);
    gen.movImm(1, ATA_NSECTOR);
    gen.movImm(2, 1);
    gen.str(2, 1);
    gen.movImm(1, ATA_COMMAND);
    gen.movImm(2, 0x20);
    gen.str(2, 1);
    gen.waitAtaDrq();

    // Read first 8 words of MBR
    gen.movImm(1, ATA_DATA);
    for (0..8) |i| {
        gen.ldr(2, 1);
        gen.strOff(2, 12, @intCast(60 + i * 4));
    }

    // Skip to end and read signature (248 more reads)
    for (0..248) |_| {
        gen.ldr(2, 1);
    }
    gen.ldr(2, 1);
    gen.strOff(2, 12, 92);

    // Test 9: I2S
    gen.movImm(0, 0x49325331); // "I2S1"
    gen.strOff(0, 12, 96);
    gen.movImm(1, IISCONFIG);
    gen.movImm(2, 0x800);
    gen.str(2, 1);
    gen.ldr(3, 1);
    gen.strOff(3, 12, 100);

    // Test 10: Interrupts
    gen.movImm(0, 0x494E5431); // "INT1"
    gen.strOff(0, 12, 104);
    gen.movImm(1, CPU_INT_STAT);
    gen.ldr(2, 1);
    gen.strOff(2, 12, 108);

    // Done marker
    gen.movImm(0, 0x444F4E45); // "DONE"
    gen.strOff(0, 12, 112);
    gen.movImm(0, 10);
    gen.strOff(0, 12, 116);

    gen.infLoop();

    // Output
    const stdout = std.fs.File.stdout();
    for (gen.code[0..gen.pos]) |instr| {
        const bytes: [4]u8 = @bitCast(instr);
        try stdout.writeAll(&bytes);
    }

    std.debug.print("Generated {d} instructions ({d} bytes)\n", .{ gen.pos, gen.pos * 4 });
    std.debug.print("Load at SDRAM (0x10000000) or IRAM (0x40000000)\n", .{});
}
