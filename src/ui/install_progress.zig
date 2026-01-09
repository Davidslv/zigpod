//! Installation Progress UI
//!
//! Provides visual feedback during firmware installation and updates.
//! Shows progress, current operation, warnings, and allows abort.
//!
//! Used by:
//!   - Flasher tool during firmware writes
//!   - DFU mode during USB firmware updates
//!   - Recovery mode during restore operations

const std = @import("std");
const hal = @import("../hal/hal.zig");
const lcd = @import("../drivers/display/lcd.zig");
const ui = @import("ui.zig");

// ============================================================
// Installation State
// ============================================================

/// Installation phases
pub const InstallPhase = enum {
    idle,
    preparing,
    checking_safety,
    backing_up,
    erasing,
    flashing,
    verifying,
    finalizing,
    rolling_back,
    complete,
    failed,
    aborted,

    pub fn toString(self: InstallPhase) []const u8 {
        return switch (self) {
            .idle => "Ready",
            .preparing => "Preparing...",
            .checking_safety => "Safety Check...",
            .backing_up => "Backing Up...",
            .erasing => "Erasing...",
            .flashing => "Flashing...",
            .verifying => "Verifying...",
            .finalizing => "Finalizing...",
            .rolling_back => "Rolling Back...",
            .complete => "Complete!",
            .failed => "Failed",
            .aborted => "Aborted",
        };
    }

    pub fn isActive(self: InstallPhase) bool {
        return switch (self) {
            .preparing, .checking_safety, .backing_up, .erasing, .flashing, .verifying, .finalizing, .rolling_back => true,
            else => false,
        };
    }

    pub fn isTerminal(self: InstallPhase) bool {
        return switch (self) {
            .complete, .failed, .aborted => true,
            else => false,
        };
    }
};

/// Warning types during installation
pub const Warning = enum {
    none,
    low_battery,
    critical_battery,
    no_backup,
    signature_skip,
    slow_write,
    retry_in_progress,

    pub fn toString(self: Warning) []const u8 {
        return switch (self) {
            .none => "",
            .low_battery => "Warning: Battery low",
            .critical_battery => "CRITICAL: Battery very low!",
            .no_backup => "Warning: No backup created",
            .signature_skip => "Warning: Signature skipped",
            .slow_write => "Warning: Slow write speed",
            .retry_in_progress => "Retrying operation...",
        };
    }

    pub fn getColor(self: Warning) lcd.Color {
        return switch (self) {
            .none => lcd.rgb(200, 200, 200),
            .low_battery, .no_backup, .signature_skip, .slow_write => lcd.rgb(255, 200, 0), // Yellow
            .critical_battery => lcd.rgb(255, 50, 50), // Red
            .retry_in_progress => lcd.rgb(100, 150, 255), // Blue
        };
    }
};

/// Installation progress state
pub const InstallProgress = struct {
    /// Current phase
    phase: InstallPhase = .idle,
    /// Overall progress (0-100)
    progress: u8 = 0,
    /// Phase-specific progress (0-100)
    phase_progress: u8 = 0,
    /// Current warning
    warning: Warning = .none,
    /// Status message
    status_message: [64]u8 = [_]u8{0} ** 64,
    status_len: u8 = 0,
    /// Error message (if failed)
    error_message: [64]u8 = [_]u8{0} ** 64,
    error_len: u8 = 0,
    /// Firmware name being installed
    firmware_name: [32]u8 = [_]u8{0} ** 32,
    firmware_name_len: u8 = 0,
    /// Firmware version
    firmware_version: [16]u8 = [_]u8{0} ** 16,
    version_len: u8 = 0,
    /// Total size in bytes
    total_bytes: u32 = 0,
    /// Bytes processed
    processed_bytes: u32 = 0,
    /// Battery percent at start
    initial_battery: u8 = 0,
    /// Current battery percent
    current_battery: u8 = 0,
    /// Elapsed time in seconds
    elapsed_seconds: u32 = 0,
    /// Estimated remaining seconds
    remaining_seconds: u32 = 0,
    /// Can abort current operation
    can_abort: bool = true,
    /// Needs redraw
    needs_redraw: bool = true,

    const Self = @This();

    /// Initialize for new installation
    pub fn init(self: *Self) void {
        self.* = Self{};
        self.initial_battery = hal.pmuGetBatteryPercent();
        self.current_battery = self.initial_battery;
    }

    /// Set firmware info
    pub fn setFirmwareInfo(self: *Self, name: []const u8, version: []const u8, size: u32) void {
        const name_len = @min(name.len, self.firmware_name.len);
        @memcpy(self.firmware_name[0..name_len], name[0..name_len]);
        self.firmware_name_len = @intCast(name_len);

        const ver_len = @min(version.len, self.firmware_version.len);
        @memcpy(self.firmware_version[0..ver_len], version[0..ver_len]);
        self.version_len = @intCast(ver_len);

        self.total_bytes = size;
        self.needs_redraw = true;
    }

    /// Update phase
    pub fn setPhase(self: *Self, phase: InstallPhase) void {
        self.phase = phase;
        self.phase_progress = 0;
        self.needs_redraw = true;

        // Update overall progress based on phase
        self.progress = switch (phase) {
            .idle => 0,
            .preparing => 5,
            .checking_safety => 10,
            .backing_up => 20,
            .erasing => 30,
            .flashing => 40 + (self.phase_progress * 50 / 100), // 40-90%
            .verifying => 90,
            .finalizing => 95,
            .rolling_back => self.progress, // Keep current during rollback
            .complete => 100,
            .failed => self.progress,
            .aborted => self.progress,
        };
    }

    /// Update progress within current phase
    pub fn updateProgress(self: *Self, phase_progress: u8, bytes_processed: u32) void {
        self.phase_progress = phase_progress;
        self.processed_bytes = bytes_processed;
        self.needs_redraw = true;

        // Update overall progress for flashing phase
        if (self.phase == .flashing) {
            self.progress = 40 + (phase_progress * 50 / 100);
        }

        // Update time estimate
        if (bytes_processed > 0 and self.elapsed_seconds > 0) {
            const bytes_per_sec = bytes_processed / self.elapsed_seconds;
            if (bytes_per_sec > 0) {
                const remaining_bytes = self.total_bytes -| bytes_processed;
                self.remaining_seconds = remaining_bytes / bytes_per_sec;
            }
        }
    }

    /// Set status message
    pub fn setStatus(self: *Self, msg: []const u8) void {
        const len = @min(msg.len, self.status_message.len);
        @memcpy(self.status_message[0..len], msg[0..len]);
        self.status_len = @intCast(len);
        self.needs_redraw = true;
    }

    /// Set error message
    pub fn setError(self: *Self, msg: []const u8) void {
        const len = @min(msg.len, self.error_message.len);
        @memcpy(self.error_message[0..len], msg[0..len]);
        self.error_len = @intCast(len);
        self.phase = .failed;
        self.needs_redraw = true;
    }

    /// Set warning
    pub fn setWarning(self: *Self, warning: Warning) void {
        self.warning = warning;
        self.needs_redraw = true;
    }

    /// Update battery level
    pub fn updateBattery(self: *Self, percent: u8) void {
        self.current_battery = percent;

        // Set warning based on battery
        if (percent < 10) {
            self.warning = .critical_battery;
        } else if (percent < 20) {
            self.warning = .low_battery;
        } else if (self.warning == .low_battery or self.warning == .critical_battery) {
            self.warning = .none;
        }

        self.needs_redraw = true;
    }

    /// Tick elapsed time (call every second)
    pub fn tick(self: *Self) void {
        if (self.phase.isActive()) {
            self.elapsed_seconds += 1;
            self.needs_redraw = true;
        }
    }

    /// Get status message
    pub fn getStatus(self: *const Self) []const u8 {
        return self.status_message[0..self.status_len];
    }

    /// Get error message
    pub fn getError(self: *const Self) []const u8 {
        return self.error_message[0..self.error_len];
    }

    /// Get firmware name
    pub fn getFirmwareName(self: *const Self) []const u8 {
        return self.firmware_name[0..self.firmware_name_len];
    }

    /// Get firmware version
    pub fn getFirmwareVersion(self: *const Self) []const u8 {
        return self.firmware_version[0..self.version_len];
    }
};

// ============================================================
// Global Instance
// ============================================================

var install_progress: InstallProgress = InstallProgress{};

/// Get installation progress state
pub fn getProgress() *InstallProgress {
    return &install_progress;
}

/// Reset for new installation
pub fn reset() void {
    install_progress.init();
}

// ============================================================
// Drawing Functions
// ============================================================

/// Draw the full installation progress screen
pub fn draw() void {
    const theme = ui.getTheme();
    const p = &install_progress;

    // Clear screen
    lcd.clear(theme.background);

    // Header
    drawHeader();

    // Firmware info
    drawFirmwareInfo();

    // Progress section
    drawProgressSection();

    // Status/Warning area
    drawStatusArea();

    // Footer with controls
    drawFooter();

    p.needs_redraw = false;
}

/// Draw header with title and battery
fn drawHeader() void {
    const theme = ui.getTheme();
    const p = &install_progress;

    // Background
    lcd.fillRect(0, 0, ui.SCREEN_WIDTH, ui.HEADER_HEIGHT, theme.header_bg);

    // Title based on phase
    const title = if (p.phase == .idle)
        "Firmware Install"
    else if (p.phase.isTerminal())
        "Installation Complete"
    else
        "Installing Firmware";

    lcd.drawString(10, 8, title, theme.header_fg, theme.header_bg);

    // Battery indicator
    ui.drawBatteryIcon(
        ui.SCREEN_WIDTH - 45,
        5,
        p.current_battery,
        p.current_battery < 20,
    );

    // Separator
    lcd.drawHLine(0, ui.HEADER_HEIGHT - 1, ui.SCREEN_WIDTH, theme.disabled);
}

/// Draw firmware information
fn drawFirmwareInfo() void {
    const theme = ui.getTheme();
    const p = &install_progress;
    const y_start: u16 = ui.HEADER_HEIGHT + 10;

    const name = p.getFirmwareName();
    const version = p.getFirmwareVersion();

    if (name.len > 0) {
        lcd.drawString(20, y_start, "Firmware:", theme.disabled, null);
        lcd.drawString(100, y_start, name, theme.foreground, null);
    }

    if (version.len > 0) {
        lcd.drawString(20, y_start + 14, "Version:", theme.disabled, null);
        lcd.drawString(100, y_start + 14, version, theme.foreground, null);
    }

    // Size info
    if (p.total_bytes > 0) {
        var buf: [32]u8 = undefined;
        const size_kb = p.total_bytes / 1024;
        const size_str = formatSize(size_kb, &buf);
        lcd.drawString(20, y_start + 28, "Size:", theme.disabled, null);
        lcd.drawString(100, y_start + 28, size_str, theme.foreground, null);
    }
}

/// Draw progress section
fn drawProgressSection() void {
    const theme = ui.getTheme();
    const p = &install_progress;
    const y_start: u16 = 90;

    // Phase label
    const phase_str = p.phase.toString();
    lcd.drawStringCentered(y_start, phase_str, theme.foreground, null);

    // Main progress bar
    const bar_x: u16 = 20;
    const bar_y: u16 = y_start + 20;
    const bar_width: u16 = ui.SCREEN_WIDTH - 40;
    const bar_height: u16 = 20;

    // Progress bar color based on state
    const bar_color = if (p.phase == .failed)
        lcd.rgb(255, 80, 80)
    else if (p.phase == .rolling_back)
        lcd.rgb(255, 165, 0)
    else if (p.phase == .complete)
        lcd.rgb(80, 200, 80)
    else
        theme.accent;

    lcd.drawProgressBar(bar_x, bar_y, bar_width, bar_height, p.progress, bar_color, theme.disabled);

    // Progress percentage
    var percent_buf: [8]u8 = undefined;
    const percent_str = formatPercent(p.progress, &percent_buf);
    lcd.drawStringCentered(bar_y + bar_height + 5, percent_str, theme.foreground, null);

    // Bytes processed (for flashing phase)
    if (p.phase == .flashing and p.total_bytes > 0) {
        var buf: [48]u8 = undefined;
        const processed_kb = p.processed_bytes / 1024;
        const total_kb = p.total_bytes / 1024;
        const bytes_str = formatBytesProgress(processed_kb, total_kb, &buf);
        lcd.drawStringCentered(bar_y + bar_height + 20, bytes_str, theme.disabled, null);
    }

    // Time estimate
    if (p.remaining_seconds > 0 and p.phase.isActive()) {
        var time_buf: [32]u8 = undefined;
        const time_str = formatTimeRemaining(p.remaining_seconds, &time_buf);
        lcd.drawStringCentered(bar_y + bar_height + 35, time_str, theme.disabled, null);
    }
}

/// Draw status/warning area
fn drawStatusArea() void {
    const theme = ui.getTheme();
    const p = &install_progress;
    const y_start: u16 = 175;

    // Warning (if any)
    if (p.warning != .none) {
        const warning_color = p.warning.getColor();
        const warning_str = p.warning.toString();
        lcd.drawStringCentered(y_start, warning_str, warning_color, null);
    }

    // Error message (if failed)
    if (p.phase == .failed) {
        const error_str = p.getError();
        if (error_str.len > 0) {
            lcd.drawStringCentered(y_start + 15, error_str, lcd.rgb(255, 80, 80), null);
        }
    }

    // Status message
    const status = p.getStatus();
    if (status.len > 0) {
        const status_y = if (p.warning != .none) y_start + 15 else y_start;
        lcd.drawStringCentered(status_y, status, theme.disabled, null);
    }
}

/// Draw footer with controls
fn drawFooter() void {
    const theme = ui.getTheme();
    const p = &install_progress;
    const y = ui.SCREEN_HEIGHT - ui.FOOTER_HEIGHT;

    // Background
    lcd.fillRect(0, y, ui.SCREEN_WIDTH, ui.FOOTER_HEIGHT, theme.footer_bg);
    lcd.drawHLine(0, y, ui.SCREEN_WIDTH, theme.disabled);

    // Control hint based on state
    const hint = if (p.phase == .complete)
        "Press SELECT to continue"
    else if (p.phase == .failed)
        "Press SELECT to retry / MENU to exit"
    else if (p.phase == .aborted)
        "Press SELECT to restart / MENU to exit"
    else if (p.can_abort and p.phase.isActive())
        "Hold MENU to abort"
    else
        "Please wait...";

    lcd.drawStringCentered(y + 6, hint, theme.footer_fg, theme.footer_bg);
}

// ============================================================
// Helper Functions
// ============================================================

/// Format size in KB/MB
fn formatSize(kb: u32, buf: []u8) []const u8 {
    if (kb >= 1024) {
        const mb = kb / 1024;
        const remainder = (kb % 1024) * 10 / 1024;
        return std.fmt.bufPrint(buf, "{d}.{d} MB", .{ mb, remainder }) catch "? MB";
    } else {
        return std.fmt.bufPrint(buf, "{d} KB", .{kb}) catch "? KB";
    }
}

/// Format percentage
fn formatPercent(percent: u8, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "{d}%", .{percent}) catch "?%";
}

/// Format bytes progress (e.g., "1234 / 5678 KB")
fn formatBytesProgress(processed: u32, total: u32, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "{d} / {d} KB", .{ processed, total }) catch "? / ? KB";
}

/// Format time remaining
fn formatTimeRemaining(seconds: u32, buf: []u8) []const u8 {
    if (seconds >= 60) {
        const mins = seconds / 60;
        const secs = seconds % 60;
        return std.fmt.bufPrint(buf, "~{d}:{d:0>2} remaining", .{ mins, secs }) catch "? remaining";
    } else {
        return std.fmt.bufPrint(buf, "~{d}s remaining", .{seconds}) catch "? remaining";
    }
}

// ============================================================
// Integration Functions
// ============================================================

/// Start installation (call before beginning)
pub fn startInstall(name: []const u8, version: []const u8, size: u32) void {
    reset();
    install_progress.setFirmwareInfo(name, version, size);
    install_progress.setPhase(.preparing);
    draw();
}

/// Update installation progress (call periodically)
pub fn update(phase: InstallPhase, progress: u8, bytes: u32, status: ?[]const u8) void {
    if (install_progress.phase != phase) {
        install_progress.setPhase(phase);
    }
    install_progress.updateProgress(progress, bytes);
    if (status) |s| {
        install_progress.setStatus(s);
    }
    install_progress.updateBattery(hal.pmuGetBatteryPercent());

    if (install_progress.needs_redraw) {
        draw();
    }
}

/// Complete installation successfully
pub fn complete() void {
    install_progress.setPhase(.complete);
    install_progress.setStatus("Installation successful!");
    draw();
}

/// Fail installation with error message
pub fn fail(error_msg: []const u8) void {
    install_progress.setError(error_msg);
    draw();
}

/// Abort installation
pub fn abort() void {
    install_progress.phase = .aborted;
    install_progress.setStatus("Installation aborted by user");
    draw();
}

/// Check if user is holding abort button
pub fn checkAbort() bool {
    const buttons = hal.clickwheelReadButtons();
    // Menu button held for abort
    return (buttons & 0x01) != 0;
}

// ============================================================
// Tests
// ============================================================

test "install phase strings" {
    try std.testing.expectEqualStrings("Flashing...", InstallPhase.flashing.toString());
    try std.testing.expectEqualStrings("Complete!", InstallPhase.complete.toString());
}

test "install phase active" {
    try std.testing.expect(InstallPhase.flashing.isActive());
    try std.testing.expect(InstallPhase.backing_up.isActive());
    try std.testing.expect(!InstallPhase.idle.isActive());
    try std.testing.expect(!InstallPhase.complete.isActive());
}

test "install phase terminal" {
    try std.testing.expect(InstallPhase.complete.isTerminal());
    try std.testing.expect(InstallPhase.failed.isTerminal());
    try std.testing.expect(InstallPhase.aborted.isTerminal());
    try std.testing.expect(!InstallPhase.flashing.isTerminal());
}

test "warning colors" {
    try std.testing.expectEqual(lcd.rgb(255, 200, 0), Warning.low_battery.getColor());
    try std.testing.expectEqual(lcd.rgb(255, 50, 50), Warning.critical_battery.getColor());
}

test "install progress init" {
    var progress = InstallProgress{};
    progress.init();
    try std.testing.expectEqual(InstallPhase.idle, progress.phase);
    try std.testing.expectEqual(@as(u8, 0), progress.progress);
}

test "install progress phase update" {
    var progress = InstallProgress{};
    progress.init();

    progress.setPhase(.flashing);
    try std.testing.expectEqual(InstallPhase.flashing, progress.phase);
    try std.testing.expectEqual(@as(u8, 40), progress.progress);

    progress.setPhase(.complete);
    try std.testing.expectEqual(@as(u8, 100), progress.progress);
}

test "install progress messages" {
    var progress = InstallProgress{};
    progress.init();

    progress.setStatus("Testing status");
    try std.testing.expectEqualStrings("Testing status", progress.getStatus());

    progress.setError("Test error");
    try std.testing.expectEqualStrings("Test error", progress.getError());
    try std.testing.expectEqual(InstallPhase.failed, progress.phase);
}

test "install progress firmware info" {
    var progress = InstallProgress{};
    progress.init();

    progress.setFirmwareInfo("ZigPod", "1.0.0", 1024 * 1024);
    try std.testing.expectEqualStrings("ZigPod", progress.getFirmwareName());
    try std.testing.expectEqualStrings("1.0.0", progress.getFirmwareVersion());
    try std.testing.expectEqual(@as(u32, 1024 * 1024), progress.total_bytes);
}

test "format size" {
    var buf: [32]u8 = undefined;

    const small = formatSize(512, &buf);
    try std.testing.expect(std.mem.indexOf(u8, small, "512 KB") != null);

    const large = formatSize(2048, &buf);
    try std.testing.expect(std.mem.indexOf(u8, large, "2") != null);
    try std.testing.expect(std.mem.indexOf(u8, large, "MB") != null);
}

test "format time remaining" {
    var buf: [32]u8 = undefined;

    const short = formatTimeRemaining(45, &buf);
    try std.testing.expect(std.mem.indexOf(u8, short, "45") != null);

    const long = formatTimeRemaining(125, &buf);
    try std.testing.expect(std.mem.indexOf(u8, long, "2:05") != null);
}
