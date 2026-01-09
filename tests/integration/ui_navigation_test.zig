//! UI Navigation Integration Tests
//!
//! Tests the complete UI navigation system including:
//! - State machine transitions
//! - Menu navigation flows
//! - Back button behavior
//! - Error state handling
//!
//! These tests verify that all UI navigation components work together correctly.

const std = @import("std");
const zigpod = @import("zigpod");
const state_machine = zigpod.ui.state_machine;
const ui = zigpod.ui;

// ============================================================
// State Machine Integration Tests
// ============================================================

test "complete boot to music browser flow" {
    var sm = state_machine.StateMachine.init();

    // Boot
    try std.testing.expectEqual(state_machine.State.boot, sm.getState());

    // Boot complete -> Main Menu
    _ = sm.handleEvent(.boot_complete);
    try std.testing.expectEqual(state_machine.State.main_menu, sm.getState());

    // Select Music (index 0) -> Music Browser
    _ = sm.selectMainMenuItem(0);
    try std.testing.expectEqual(state_machine.State.music_browser, sm.getState());
    try std.testing.expectEqual(@as(u8, 1), sm.stack_depth);

    // Verify we can go back
    try std.testing.expect(sm.canGoBack());
}

test "complete boot to file browser flow" {
    var sm = state_machine.StateMachine.init();

    _ = sm.handleEvent(.boot_complete);
    _ = sm.selectMainMenuItem(2); // Files

    try std.testing.expectEqual(state_machine.State.file_browser, sm.getState());
    try std.testing.expectEqual(@as(u8, 1), sm.stack_depth);
}

test "complete boot to settings flow" {
    var sm = state_machine.StateMachine.init();

    _ = sm.handleEvent(.boot_complete);
    _ = sm.selectMainMenuItem(5); // Settings

    try std.testing.expectEqual(state_machine.State.settings, sm.getState());
}

test "play button shortcut from main menu" {
    var sm = state_machine.StateMachine.init();

    _ = sm.handleEvent(.boot_complete);
    _ = sm.handleEvent(.play_pressed);

    try std.testing.expectEqual(state_machine.State.now_playing, sm.getState());
}

test "deep navigation with multiple backs" {
    var sm = state_machine.StateMachine.init();

    _ = sm.handleEvent(.boot_complete);

    // Main Menu -> Music
    _ = sm.selectMainMenuItem(0);
    try std.testing.expectEqual(@as(u8, 1), sm.stack_depth);

    // Music -> Now Playing (via track selection)
    _ = sm.pushState(.now_playing);
    try std.testing.expectEqual(@as(u8, 2), sm.stack_depth);
    try std.testing.expectEqual(state_machine.State.now_playing, sm.getState());

    // Back to Music
    _ = sm.popState();
    try std.testing.expectEqual(state_machine.State.music_browser, sm.getState());
    try std.testing.expectEqual(@as(u8, 1), sm.stack_depth);

    // Back to Main Menu
    _ = sm.popState();
    try std.testing.expectEqual(state_machine.State.main_menu, sm.getState());
    try std.testing.expectEqual(@as(u8, 0), sm.stack_depth);

    // Can't go back from Main Menu
    try std.testing.expect(!sm.canGoBack());
}

test "error state flow" {
    var sm = state_machine.StateMachine.init();

    _ = sm.handleEvent(.boot_complete);
    _ = sm.selectMainMenuItem(0); // Music

    // Simulate error
    _ = sm.setError("Could not load file");
    try std.testing.expectEqual(state_machine.State.error_display, sm.getState());
    try std.testing.expectEqualStrings("Could not load file", sm.getErrorMessage());

    // Dismiss error -> back to previous
    _ = sm.clearError();
    try std.testing.expect(sm.getState() != state_machine.State.error_display);
}

test "error state from boot" {
    var sm = state_machine.StateMachine.init();

    // Error during boot
    _ = sm.setError("Failed to initialize");
    try std.testing.expectEqual(state_machine.State.error_display, sm.getState());
}

test "navigation history tracking" {
    var sm = state_machine.StateMachine.init();

    _ = sm.handleEvent(.boot_complete);
    _ = sm.selectMainMenuItem(0);
    _ = sm.pushState(.now_playing);
    _ = sm.popState();

    const history = sm.getHistory();
    try std.testing.expect(history.len >= 4);

    // First transition should be boot -> main_menu
    try std.testing.expectEqual(state_machine.State.boot, history[0].from);
    try std.testing.expectEqual(state_machine.State.main_menu, history[0].to);
}

test "state allows back property" {
    try std.testing.expect(!state_machine.State.boot.allowsBack());
    try std.testing.expect(!state_machine.State.main_menu.allowsBack());
    try std.testing.expect(state_machine.State.music_browser.allowsBack());
    try std.testing.expect(state_machine.State.file_browser.allowsBack());
    try std.testing.expect(state_machine.State.now_playing.allowsBack());
    try std.testing.expect(state_machine.State.settings.allowsBack());
    try std.testing.expect(state_machine.State.about.allowsBack());
}

test "state shows status bar property" {
    try std.testing.expect(!state_machine.State.boot.showsStatusBar());
    try std.testing.expect(!state_machine.State.loading.showsStatusBar());
    try std.testing.expect(state_machine.State.main_menu.showsStatusBar());
    try std.testing.expect(state_machine.State.now_playing.showsStatusBar());
}

// ============================================================
// Transition Guard Tests
// ============================================================

var guard_blocked: bool = false;
var guard_calls: u32 = 0;

fn testGuard(from: state_machine.State, to: state_machine.State, ctx: *anyopaque) bool {
    _ = ctx;
    _ = from;
    _ = to;
    guard_calls += 1;
    return !guard_blocked;
}

test "transition guard allows" {
    var sm = state_machine.StateMachine.init();
    var context: u32 = 0;

    guard_blocked = false;
    guard_calls = 0;

    sm.setGuard(testGuard);
    sm.setContext(&context);

    const result = sm.handleEvent(.boot_complete);
    try std.testing.expectEqual(state_machine.TransitionResult.success, result);
    try std.testing.expect(guard_calls > 0);
}

test "transition guard blocks" {
    var sm = state_machine.StateMachine.init();
    var context: u32 = 0;

    guard_blocked = true;
    guard_calls = 0;

    sm.setGuard(testGuard);
    sm.setContext(&context);

    const result = sm.handleEvent(.boot_complete);
    try std.testing.expectEqual(state_machine.TransitionResult.blocked, result);
    try std.testing.expectEqual(state_machine.State.boot, sm.getState());
}

// ============================================================
// Entry/Exit Action Tests
// ============================================================

var entry_state: ?state_machine.State = null;
var exit_state: ?state_machine.State = null;

fn testEntryAction(st: state_machine.State, ctx: *anyopaque) void {
    _ = ctx;
    entry_state = st;
}

fn testExitAction(st: state_machine.State, ctx: *anyopaque) void {
    _ = ctx;
    exit_state = st;
}

test "entry action called" {
    var sm = state_machine.StateMachine.init();
    var context: u32 = 0;

    entry_state = null;
    sm.setEntryAction(testEntryAction);
    sm.setContext(&context);

    _ = sm.handleEvent(.boot_complete);

    try std.testing.expectEqual(state_machine.State.main_menu, entry_state.?);
}

test "exit action called" {
    var sm = state_machine.StateMachine.init();
    var context: u32 = 0;

    exit_state = null;
    sm.setExitAction(testExitAction);
    sm.setContext(&context);

    _ = sm.handleEvent(.boot_complete);

    try std.testing.expectEqual(state_machine.State.boot, exit_state.?);
}

// ============================================================
// Invalid Transition Tests
// ============================================================

test "invalid transition from boot" {
    var sm = state_machine.StateMachine.init();

    // Can't go back from boot
    var result = sm.handleEvent(.back);
    try std.testing.expectEqual(state_machine.TransitionResult.invalid, result);

    // Can't select from boot
    result = sm.handleEvent(.select);
    try std.testing.expectEqual(state_machine.TransitionResult.invalid, result);
}

test "no change on same state transition" {
    var sm = state_machine.StateMachine.init();
    _ = sm.handleEvent(.boot_complete);

    const result = sm.transitionTo(.main_menu, .select);
    try std.testing.expectEqual(state_machine.TransitionResult.no_change, result);
}

test "invalid menu item selection" {
    var sm = state_machine.StateMachine.init();
    _ = sm.handleEvent(.boot_complete);

    // Invalid index
    const result = sm.selectMainMenuItem(99);
    try std.testing.expectEqual(state_machine.TransitionResult.invalid, result);
}

// ============================================================
// Global State Machine Tests
// ============================================================

test "global state machine access" {
    state_machine.resetGlobal();
    const sm = state_machine.getGlobal();

    try std.testing.expectEqual(state_machine.State.boot, sm.getState());

    _ = sm.handleEvent(.boot_complete);
    try std.testing.expectEqual(state_machine.State.main_menu, sm.getState());

    // Reset for other tests
    state_machine.resetGlobal();
}

// ============================================================
// Stack Overflow Protection Tests
// ============================================================

test "stack depth limit protection" {
    var sm = state_machine.StateMachine.init();
    _ = sm.handleEvent(.boot_complete);

    // Push many states
    for (0..20) |_| {
        _ = sm.pushState(.music_browser);
    }

    // Stack depth should be capped
    try std.testing.expect(sm.stack_depth <= 8);
}

// ============================================================
// State Name Tests
// ============================================================

test "state names" {
    try std.testing.expectEqualStrings("Boot", state_machine.State.boot.getName());
    try std.testing.expectEqualStrings("Main Menu", state_machine.State.main_menu.getName());
    try std.testing.expectEqualStrings("Music", state_machine.State.music_browser.getName());
    try std.testing.expectEqualStrings("Files", state_machine.State.file_browser.getName());
    try std.testing.expectEqualStrings("Now Playing", state_machine.State.now_playing.getName());
    try std.testing.expectEqualStrings("Settings", state_machine.State.settings.getName());
    try std.testing.expectEqualStrings("About", state_machine.State.about.getName());
    try std.testing.expectEqualStrings("Error", state_machine.State.error_display.getName());
}

// ============================================================
// Reset Tests
// ============================================================

test "state machine reset" {
    var sm = state_machine.StateMachine.init();

    _ = sm.handleEvent(.boot_complete);
    _ = sm.selectMainMenuItem(0);
    _ = sm.setError("Test error");

    // Reset
    sm.reset();

    try std.testing.expectEqual(state_machine.State.boot, sm.getState());
    try std.testing.expectEqual(@as(u8, 0), sm.stack_depth);
    try std.testing.expectEqual(@as(u8, 0), sm.error_len);
}
