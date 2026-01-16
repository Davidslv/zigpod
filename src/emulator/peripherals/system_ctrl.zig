//! PP5021C System Controller
//!
//! Implements device enable, reset, and clock control.
//!
//! Reference: Rockbox firmware/export/pp5020.h
//!
//! Registers (base 0x60006000):
//! - 0x04: DEV_RS - Device reset (write 1 to reset)
//! - 0x08: DEV_RS2 - Device reset 2
//! - 0x0C: DEV_EN - Device enable (write 1 to enable)
//! - 0x10: DEV_EN2 - Device enable 2
//! - 0x20: CLOCK_SOURCE - Clock source selection
//! - 0x34: PLL_CONTROL - PLL configuration
//! - 0x38: PLL_DIV - PLL divider
//! - 0x3C: PLL_STATUS - PLL lock status (read-only)
//! - 0x40: DEV_INIT1 - Device init 1
//! - 0x44: CACHE_PRIORITY - Cache priority configuration
//! - 0x80: CACHE_CTL - Cache control
//!
//! Additional registers for hardware identification:
//! - 0x00: Chip ID / Revision

const std = @import("std");
const bus = @import("../memory/bus.zig");

/// COP (Coprocessor) state machine
/// The PP5021C has a dual-core ARM7TDMI where COP requires explicit
/// wake/sleep management via COP_CTL register
pub const CopState = enum {
    /// COP not enabled via DEV_EN register
    disabled,
    /// COP is sleeping (PROC_SLEEP bit set in COP_CTL)
    sleeping,
    /// Wake request pending, will transition to running next cycle
    waking,
    /// COP is actively executing instructions
    running,
    /// COP halted due to error or debug
    halted,
};

/// COP initialization state machine
/// Tracks simulated COP kernel initialization progress
pub const CopInitState = enum {
    /// COP init hasn't started yet
    not_started,
    /// COP is doing simulated initialization work
    in_progress,
    /// COP init is complete, CPU can proceed
    complete,
};

/// Device enable bits (DEV_EN)
pub const Device = enum(u5) {
    timer1 = 0,
    timer2 = 1,
    i2c = 2,
    i2s = 3,
    lcd = 4,
    firewire = 5,
    usb0 = 6,
    usb1 = 7,
    ide0 = 8,
    ide1 = 9,
    cop = 24, // Second CPU core
    // ... other devices

    pub fn mask(self: Device) u32 {
        return @as(u32, 1) << @intFromEnum(self);
    }
};

/// System Controller
pub const SystemController = struct {
    /// Device reset registers
    dev_rs: u32,
    dev_rs2: u32,

    /// Device enable registers
    dev_en: u32,
    dev_en2: u32,

    /// Device init / cache registers
    dev_init1: u32,
    cache_priority: u32,

    /// Clock configuration
    clock_source: u32,
    pll_control: u32,
    pll_div: u32,
    pll_mult: u32,
    clock_status: u32,

    /// Cache control
    cache_ctl: u32,

    /// CPU control register (wake/sleep CPU)
    cpu_ctl: u32,

    /// COP control register (wake/sleep COP)
    cop_ctl: u32,

    /// COP state machine
    cop_state: CopState,

    /// Counter for COP wake requests (helps distinguish boot vs kernel wake)
    cop_wake_count: u32,

    /// Countdown for fake COP wake acknowledgment
    /// When > 0, COP_CTL reads return PROC_SLEEP=0 (COP awake/acknowledged)
    /// Simulates COP waking up, acknowledging, and going back to sleep
    cop_wake_ack_countdown: u32,

    /// Flag: Kernel initialization is complete
    /// When false: COP_CTL returns "awake" (bit 31 = 0) to let kernel init complete
    /// When true: COP_CTL returns "sleeping" (bit 31 = 1) so wake_core can exit
    kernel_init_complete: bool,

    /// Flag: Thread wakeup is pending (COP wake response simulation)
    /// Set when COP receives wake signal after kernel_init_complete
    pending_thread_wakeup: bool,

    /// Counter: Cycles until thread wakeup executes
    /// Gives firmware time to settle before we manipulate RTR queue
    thread_wakeup_countdown: u32,

    /// COP initialization state machine
    /// Simulates COP doing kernel init work while CPU waits
    cop_init_state: CopInitState,

    /// Cycles until COP init completes (simulated)
    cop_init_countdown: u32,

    /// Set when CPU tries to sleep during COP init
    cpu_waiting_for_cop_init: bool,

    /// Device reset callback (called when a device is reset)
    reset_callback: ?*const fn (Device) void,

    /// Device enable callback (called when device enable changes)
    enable_callback: ?*const fn (Device, bool) void,

    /// Is this being accessed by COP (for PROC_ID)
    is_cop_access: bool,

    const Self = @This();

    /// Register offsets (PP5020/PP5021C)
    const REG_CHIP_ID: u32 = 0x00;
    const REG_DEV_RS: u32 = 0x04;
    const REG_DEV_RS2: u32 = 0x08;
    const REG_DEV_EN: u32 = 0x0C;
    const REG_DEV_EN2: u32 = 0x10;
    const REG_CLOCK_SOURCE: u32 = 0x20;
    const REG_PLL_CONTROL: u32 = 0x34;
    const REG_PLL_DIV: u32 = 0x38;
    const REG_PLL_STATUS: u32 = 0x3C;
    const REG_DEV_INIT1: u32 = 0x40; // Unknown purpose, not the same as 0x70000010
    const REG_CACHE_PRIORITY: u32 = 0x44; // CACHE_PRIORITY register
    const REG_CACHE_CTL: u32 = 0x80;

    /// Processor control registers (base 0x60007000, offset 0x1000 from sys_ctrl)
    const REG_CPU_CTL: u32 = 0x1000; // 0x60007000
    const REG_COP_CTL: u32 = 0x1004; // 0x60007004

    /// Processor ID register (at 0x60000000 - but treated as offset 0 for convenience)
    /// Returns 0x55 for CPU, 0xAA for COP
    const PROC_ID_CPU: u32 = 0x55;
    const PROC_ID_COP: u32 = 0xAA;

    /// PP5021C Chip ID (returned by hardware)
    const CHIP_ID_PP5021C: u32 = 0x5021C;

    /// Default PLL status indicating PLL is locked and stable
    const DEFAULT_PLL_STATUS: u32 = 0x80000000; // Bit 31 = PLL locked

    /// Default COP_CTL value - bit 9 (0x200) indicates COP is sleeping/ready
    /// Rockbox startup checks this bit before proceeding
    const DEFAULT_COP_CTL: u32 = 0x80000200; // Bit 31 = sleeping, bit 9 = ready

    pub fn init() Self {
        return .{
            .dev_rs = 0,
            .dev_rs2 = 0,
            .dev_en = 0,
            .dev_en2 = 0,
            .dev_init1 = 0,
            .cache_priority = 0x3F, // Default: all priorities enabled
            .clock_source = 0,
            .pll_control = 0,
            .pll_div = 1,
            .pll_mult = 1,
            .clock_status = DEFAULT_PLL_STATUS,
            .cache_ctl = 0,
            .cpu_ctl = 0,
            .cop_ctl = DEFAULT_COP_CTL,
            .cop_state = .disabled,
            .cop_wake_count = 0,
            .cop_wake_ack_countdown = 0,
            .kernel_init_complete = false,
            .pending_thread_wakeup = false,
            .thread_wakeup_countdown = 0,
            .cop_init_state = .not_started,
            .cop_init_countdown = 0,
            .cpu_waiting_for_cop_init = false,
            .reset_callback = null,
            .enable_callback = null,
            .is_cop_access = false,
        };
    }

    /// Set whether current access is from COP (for PROC_ID)
    pub fn setCopAccess(self: *Self, is_cop: bool) void {
        self.is_cop_access = is_cop;
    }

    /// Check if COP is sleeping (waiting in WFI)
    pub fn isCopSleeping(self: *const Self) bool {
        return self.cop_state == .sleeping;
    }

    /// Check if COP is running
    pub fn isCopRunning(self: *const Self) bool {
        return self.cop_state == .running;
    }

    /// Check if COP is waking
    pub fn isCopWaking(self: *const Self) bool {
        return self.cop_state == .waking;
    }

    /// Get COP state
    pub fn getCopState(self: *const Self) CopState {
        return self.cop_state;
    }

    /// Enable COP (called when DEV_EN bit 24 is set)
    pub fn enableCop(self: *Self) void {
        if (self.cop_state == .disabled) {
            // COP starts in sleeping state when enabled
            self.cop_state = .sleeping;
            self.cop_ctl = DEFAULT_COP_CTL; // Sleep bit set
        }
    }

    /// Disable COP
    pub fn disableCop(self: *Self) void {
        self.cop_state = .disabled;
    }

    /// Wake up COP (transition from sleeping to waking)
    pub fn wakeCop(self: *Self) void {
        if (self.cop_state == .sleeping) {
            self.cop_state = .waking;
            self.cop_ctl &= ~@as(u32, 0x80000000); // Clear sleep bit
        }
    }

    /// Put COP to sleep
    pub fn sleepCop(self: *Self) void {
        if (self.cop_state == .running or self.cop_state == .waking) {
            self.cop_state = .sleeping;
            self.cop_ctl |= 0x80000000; // Set sleep bit
        }
    }

    /// Advance COP state (called each cycle)
    /// Returns true if COP should execute this cycle
    pub fn tickCopState(self: *Self) bool {
        return switch (self.cop_state) {
            .waking => {
                // Transition to running
                self.cop_state = .running;
                return true;
            },
            .running => true,
            .sleeping, .disabled, .halted => false,
        };
    }

    /// Set reset callback
    pub fn setResetCallback(self: *Self, callback: *const fn (Device) void) void {
        self.reset_callback = callback;
    }

    /// Set enable callback
    pub fn setEnableCallback(self: *Self, callback: *const fn (Device, bool) void) void {
        self.enable_callback = callback;
    }

    /// Check if device is enabled
    pub fn isEnabled(self: *const Self, device: Device) bool {
        return (self.dev_en & device.mask()) != 0;
    }

    /// Enable a device
    pub fn enableDevice(self: *Self, device: Device) void {
        const mask = device.mask();
        if ((self.dev_en & mask) == 0) {
            self.dev_en |= mask;
            if (self.enable_callback) |callback| {
                callback(device, true);
            }
        }
    }

    /// Disable a device
    pub fn disableDevice(self: *Self, device: Device) void {
        const mask = device.mask();
        if ((self.dev_en & mask) != 0) {
            self.dev_en &= ~mask;
            if (self.enable_callback) |callback| {
                callback(device, false);
            }
        }
    }

    /// Reset a device
    pub fn resetDevice(self: *Self, device: Device) void {
        if (self.reset_callback) |callback| {
            callback(device);
        }
    }

    /// Get calculated CPU frequency in MHz
    pub fn getCpuFreqMhz(self: *const Self) u32 {
        // Default to 80 MHz if PLL not configured
        if (self.pll_div == 0) return 80;

        // Calculate frequency based on PLL settings
        // Base frequency is typically 24 MHz crystal
        const base_freq: u32 = 24;
        const mult = if (self.pll_mult == 0) 1 else self.pll_mult;
        const div = if (self.pll_div == 0) 1 else self.pll_div;

        return (base_freq * mult) / div;
    }

    /// Read register
    pub fn read(self: *Self, offset: u32) u32 {
        return switch (offset) {
            REG_CHIP_ID => CHIP_ID_PP5021C,
            REG_DEV_RS => self.dev_rs,
            REG_DEV_RS2 => self.dev_rs2,
            REG_DEV_EN => self.dev_en,
            REG_DEV_EN2 => self.dev_en2,
            REG_CLOCK_SOURCE => self.clock_source,
            REG_PLL_CONTROL => self.pll_control,
            REG_PLL_DIV => self.pll_div,
            REG_PLL_STATUS => self.clock_status, // PLL locked status
            REG_DEV_INIT1 => self.dev_init1,
            REG_CACHE_PRIORITY => self.cache_priority,
            REG_CACHE_CTL => self.cache_ctl,
            REG_CPU_CTL => blk: {
                // CPU should always appear AWAKE (bit 31 = 0)
                break :blk self.cpu_ctl & ~@as(u32, 0x80000000);
            },
            // COP_CTL: ALWAYS return SLEEPING (bit 31 = 1)
            //
            // CRITICAL: Both boot sync loops AND wake_core() exit when PROC_SLEEP=1:
            // - crt0 sync loops: `while (!(COP_CTL & 0x80000000))` - exit when sleeping
            // - wake_core: `if (COP_CTL & PROC_SLEEP) return` - exit when sleeping
            //
            // By ALWAYS returning SLEEPING, all COP synchronization code exits
            // immediately. This is correct because we don't emulate COP - it's
            // effectively always "done" (sleeping). The kernel will:
            // 1. Pass all crt0 sync loops instantly (COP appears sleeping)
            // 2. Run kernel_init() including thread creation
            // 3. wake_core() returns immediately (COP sleeping = nothing to wake)
            // 4. Scheduler runs, main thread progresses to LCD init
            //
            // PREVIOUS BUG: We returned AWAKE after kernel_init, which caused
            // wake_core() to spin forever waiting for COP to go back to sleep.
            REG_COP_CTL => blk: {
                // Always return SLEEPING - COP is not emulated, it's permanently "done"
                // Value: bit 31 = 1 (SLEEPING), ready flags
                break :blk 0xC000FE00;
            },
            else => 0,
        };
    }

    /// Read PROC_ID - returns different value for CPU vs COP
    pub fn readProcId(self: *const Self) u32 {
        return if (self.is_cop_access) PROC_ID_COP else PROC_ID_CPU;
    }

    /// Mark kernel initialization as complete
    /// After this, COP_CTL will return "sleeping" (bit 31 = 1) so wake_core exits
    pub fn setKernelInitComplete(self: *Self) void {
        self.kernel_init_complete = true;
    }

    /// Check if kernel init is complete
    pub fn isKernelInitComplete(self: *const Self) bool {
        return self.kernel_init_complete;
    }

    /// Write register
    pub fn write(self: *Self, offset: u32, value: u32) void {
        switch (offset) {
            REG_DEV_RS => {
                self.dev_rs = value;
                // Trigger resets for each bit that is set
                var bits = value;
                while (bits != 0) {
                    const bit: u5 = @intCast(@ctz(bits));
                    if (self.reset_callback) |callback| {
                        callback(@enumFromInt(bit));
                    }
                    bits &= bits - 1; // Clear lowest bit
                }
            },
            REG_DEV_RS2 => {
                self.dev_rs2 = value;
            },
            REG_DEV_EN => {
                const changed = self.dev_en ^ value;
                const old_value = self.dev_en;
                self.dev_en = value;

                // Handle COP enable/disable (bit 24)
                const cop_mask = Device.cop.mask();
                if ((changed & cop_mask) != 0) {
                    if ((value & cop_mask) != 0) {
                        // COP enabled
                        self.enableCop();
                    } else {
                        // COP disabled
                        self.disableCop();
                    }
                }

                // Notify for changed devices
                if (self.enable_callback) |callback| {
                    var bits = changed;
                    while (bits != 0) {
                        const bit: u5 = @intCast(@ctz(bits));
                        const enabled = (value & (@as(u32, 1) << bit)) != 0;
                        callback(@enumFromInt(bit), enabled);
                        bits &= bits - 1;
                    }
                }
                _ = old_value;
            },
            REG_DEV_EN2 => self.dev_en2 = value,
            REG_DEV_INIT1 => self.dev_init1 = value,
            REG_CACHE_PRIORITY => self.cache_priority = value,
            REG_CLOCK_SOURCE => self.clock_source = value,
            REG_PLL_CONTROL => {
                self.pll_control = value;
                // When PLL is configured, set lock status
                self.clock_status = DEFAULT_PLL_STATUS;
            },
            REG_PLL_DIV => self.pll_div = value,
            REG_PLL_STATUS => {}, // Read-only
            REG_CACHE_CTL => self.cache_ctl = value,
            REG_CPU_CTL => {
                // CPU_CTL handles CPU sleep/wake state
                // When CPU writes 0x80000000 (PROC_SLEEP), it's putting itself to sleep
                // and waiting for COP to wake it by writing 0
                const PROC_SLEEP: u32 = 0x80000000;
                if ((value & PROC_SLEEP) != 0) {
                    // CPU trying to sleep
                    if (self.cop_init_state == .in_progress) {
                        // CPU is waiting for COP to finish init
                        // Start countdown before waking CPU
                        self.cpu_waiting_for_cop_init = true;
                        self.cop_init_countdown = 100_000; // ~100K cycles for COP to "init"
                        self.cpu_ctl = value; // Keep CPU in sleep state
                        std.debug.print("COP_INIT: CPU sleeping, waiting for simulated COP init ({} cycles)\n", .{self.cop_init_countdown});
                    } else {
                        // Normal case: immediately wake CPU (COP sync bypass)
                        self.cpu_ctl = 0; // Auto-wake
                    }
                } else {
                    self.cpu_ctl = value;
                }
            },
            REG_COP_CTL => {
                // COP_CTL handles coprocessor sleep/wake state
                // Bit 31 (PROC_SLEEP) indicates COP is sleeping
                // Writing 0 clears the sleep bit = wake request
                // Writing 0x80000000 sets the sleep bit = put to sleep
                const PROC_SLEEP: u32 = 0x80000000;

                // Debug: Log ALL writes to COP_CTL
                if (self.cop_wake_count < 10 or self.cop_wake_count % 100 == 0) {
                    std.debug.print("COP_CTL_WRITE: value=0x{X:0>8}, kernel_init={}\n", .{ value, self.kernel_init_complete });
                }

                // Store the value
                self.cop_ctl = value;

                // Handle wake request
                // In Rockbox, wake_core() writes 0 to clear sleep bit (wake the core)
                // We detect ANY write to COP_CTL as a potential wake signal
                const is_wake_request = (value & PROC_SLEEP) == 0; // Writing 0 = wake
                const is_sleep_request = (value & PROC_SLEEP) != 0; // Writing 0x80000000 = sleep

                if (is_wake_request or is_sleep_request) {
                    self.cop_wake_count += 1;
                    // Only start countdown if not already counting (prevents reset on every write)
                    if (self.cop_wake_ack_countdown == 0) {
                        // COP will appear "awake" for 5 reads then go back to sleep
                        self.cop_wake_ack_countdown = 5;
                    }
                    if (self.cop_state == .sleeping) {
                        self.cop_state = .waking;
                    }

                    // COP INIT SIMULATION: When CPU first wakes COP, start simulated init
                    // This happens during core_thread_init() when CPU does wake_core(COP)
                    if (is_wake_request) {
                        if (self.cop_wake_count <= 5 or self.cop_wake_count % 100 == 0) {
                            std.debug.print("COP_CTL_WAKE: count={}, cop_init_state={s}, kernel_init={}\n", .{
                                self.cop_wake_count, @tagName(self.cop_init_state), self.kernel_init_complete,
                            });
                        }

                        // Start COP init on first wake request (during kernel init)
                        if (self.cop_init_state == .not_started and self.cop_wake_count == 1) {
                            self.cop_init_state = .in_progress;
                            std.debug.print("COP_INIT: Starting simulated COP initialization\n", .{});
                        }

                        // NOTE: The old pending_thread_wakeup mechanism is DISABLED
                        // It directly manipulated RTR queue and caused stack corruption
                        // Instead, we rely on COP init simulation to delay CPU appropriately
                    }
                }
            },
            else => {},
        }
    }

    /// Create a peripheral handler for the memory bus
    pub fn createHandler(self: *Self) bus.PeripheralHandler {
        return .{
            .context = @ptrCast(self),
            .readFn = readWrapper,
            .writeFn = writeWrapper,
        };
    }

    fn readWrapper(ctx: *anyopaque, offset: u32) u32 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.read(offset);
    }

    fn writeWrapper(ctx: *anyopaque, offset: u32, value: u32) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.write(offset, value);
    }
};

// Tests
test "device enable/disable" {
    var sys = SystemController.init();

    // Enable IDE0
    sys.write(SystemController.REG_DEV_EN, Device.ide0.mask());
    try std.testing.expect(sys.isEnabled(.ide0));
    try std.testing.expect(!sys.isEnabled(.i2s));

    // Enable I2S
    sys.write(SystemController.REG_DEV_EN, Device.ide0.mask() | Device.i2s.mask());
    try std.testing.expect(sys.isEnabled(.ide0));
    try std.testing.expect(sys.isEnabled(.i2s));
}

test "clock status" {
    const sys = SystemController.init();

    // PLL should report locked
    const status = sys.read(SystemController.REG_PLL_STATUS);
    try std.testing.expect((status & 0x80000000) != 0);
}

test "CPU frequency calculation" {
    var sys = SystemController.init();

    // Set PLL divider directly - pll_mult defaults to 1
    // 24 * 1 / 1 = 24 MHz with defaults
    try std.testing.expectEqual(@as(u32, 24), sys.getCpuFreqMhz());

    // Manually set the internal mult/div for testing
    sys.pll_mult = 10;
    sys.pll_div = 3;
    // 24 * 10 / 3 = 80 MHz
    try std.testing.expectEqual(@as(u32, 80), sys.getCpuFreqMhz());
}
