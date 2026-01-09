//! UI State Machine
//!
//! Formal state machine for UI navigation with:
//! - Defined states and transitions
//! - Guards for conditional transitions
//! - Entry/exit actions for each state
//! - Error state for graceful failure handling
//!
//! This replaces ad-hoc screen switching with a predictable, testable system.

const std = @import("std");

// ============================================================
// UI States
// ============================================================

/// All possible UI states
pub const State = enum {
    /// Initial boot/splash screen
    boot,
    /// Main menu (Music, Files, Now Playing, Settings)
    main_menu,
    /// Music library browser (Artists/Albums/Songs)
    music_browser,
    /// File system browser
    file_browser,
    /// Now Playing screen (playback control)
    now_playing,
    /// Settings menu
    settings,
    /// About screen
    about,
    /// Error state (recoverable)
    error_display,
    /// Loading state (transitional)
    loading,

    /// Get human-readable name
    pub fn getName(self: State) []const u8 {
        return switch (self) {
            .boot => "Boot",
            .main_menu => "Main Menu",
            .music_browser => "Music",
            .file_browser => "Files",
            .now_playing => "Now Playing",
            .settings => "Settings",
            .about => "About",
            .error_display => "Error",
            .loading => "Loading",
        };
    }

    /// Check if this state allows going back
    pub fn allowsBack(self: State) bool {
        return switch (self) {
            .boot, .main_menu, .error_display => false,
            else => true,
        };
    }

    /// Check if this state shows the status bar
    pub fn showsStatusBar(self: State) bool {
        return switch (self) {
            .boot, .loading => false,
            else => true,
        };
    }
};

// ============================================================
// Transition Events
// ============================================================

/// Events that trigger state transitions
pub const Event = enum {
    /// Boot completed
    boot_complete,
    /// User selected menu item
    select,
    /// User pressed back/menu
    back,
    /// User pressed play button
    play_pressed,
    /// Track loaded successfully
    track_loaded,
    /// Track load failed
    track_failed,
    /// Error occurred
    error_occurred,
    /// Error dismissed
    error_dismissed,
    /// Timeout occurred
    timeout,
};

// ============================================================
// Transition Result
// ============================================================

/// Result of a transition attempt
pub const TransitionResult = enum {
    /// Transition succeeded
    success,
    /// Transition blocked by guard
    blocked,
    /// Invalid transition (no path exists)
    invalid,
    /// Already in target state
    no_change,
};

// ============================================================
// State Machine Context
// ============================================================

/// Callback for state entry actions
pub const EntryAction = *const fn (state: State, context: *anyopaque) void;

/// Callback for state exit actions
pub const ExitAction = *const fn (state: State, context: *anyopaque) void;

/// Guard function that determines if transition is allowed
pub const TransitionGuard = *const fn (from: State, to: State, context: *anyopaque) bool;

// ============================================================
// State Machine
// ============================================================

/// UI State Machine
pub const StateMachine = struct {
    /// Current state
    current: State,
    /// Previous state (for back navigation)
    previous: State,
    /// Navigation stack for deep back navigation
    stack: [8]State,
    /// Current stack depth
    stack_depth: u8,
    /// Error message (when in error_display state)
    error_message: [128]u8,
    /// Error message length
    error_len: u8,
    /// Context pointer passed to callbacks
    context: ?*anyopaque,
    /// Entry action callback
    on_entry: ?EntryAction,
    /// Exit action callback
    on_exit: ?ExitAction,
    /// Transition guard callback
    guard: ?TransitionGuard,
    /// Transition history for debugging
    history: [16]Transition,
    /// History write index
    history_idx: u8,

    /// Transition record for history
    pub const Transition = struct {
        from: State,
        to: State,
        event: Event,
        result: TransitionResult,
    };

    /// Initialize state machine
    pub fn init() StateMachine {
        return StateMachine{
            .current = .boot,
            .previous = .boot,
            .stack = [_]State{.main_menu} ** 8,
            .stack_depth = 0,
            .error_message = [_]u8{0} ** 128,
            .error_len = 0,
            .context = null,
            .on_entry = null,
            .on_exit = null,
            .guard = null,
            .history = undefined,
            .history_idx = 0,
        };
    }

    /// Set context for callbacks
    pub fn setContext(self: *StateMachine, ctx: *anyopaque) void {
        self.context = ctx;
    }

    /// Set entry action callback
    pub fn setEntryAction(self: *StateMachine, action: EntryAction) void {
        self.on_entry = action;
    }

    /// Set exit action callback
    pub fn setExitAction(self: *StateMachine, action: ExitAction) void {
        self.on_exit = action;
    }

    /// Set transition guard
    pub fn setGuard(self: *StateMachine, g: TransitionGuard) void {
        self.guard = g;
    }

    /// Get current state
    pub fn getState(self: *const StateMachine) State {
        return self.current;
    }

    /// Get previous state
    pub fn getPrevious(self: *const StateMachine) State {
        return self.previous;
    }

    /// Get error message (if in error state)
    pub fn getErrorMessage(self: *const StateMachine) []const u8 {
        return self.error_message[0..self.error_len];
    }

    /// Check if can go back
    pub fn canGoBack(self: *const StateMachine) bool {
        return self.stack_depth > 0 and self.current.allowsBack();
    }

    /// Process an event and potentially transition
    pub fn handleEvent(self: *StateMachine, event: Event) TransitionResult {
        const target = self.getTargetState(event);
        if (target) |to| {
            return self.transitionTo(to, event);
        }
        return .invalid;
    }

    /// Get target state for an event (based on transition table)
    fn getTargetState(self: *const StateMachine, event: Event) ?State {
        return switch (self.current) {
            .boot => switch (event) {
                .boot_complete => .main_menu,
                .error_occurred => .error_display,
                else => null,
            },
            .main_menu => switch (event) {
                .select => null, // Handled by selectMenuItem
                .play_pressed => .now_playing,
                .error_occurred => .error_display,
                else => null,
            },
            .music_browser => switch (event) {
                .back => self.getBackTarget(),
                .select => null, // May stay or go to now_playing
                .track_loaded => .now_playing,
                .play_pressed => .now_playing,
                .error_occurred => .error_display,
                else => null,
            },
            .file_browser => switch (event) {
                .back => self.getBackTarget(),
                .track_loaded => .now_playing,
                .play_pressed => .now_playing,
                .error_occurred => .error_display,
                else => null,
            },
            .now_playing => switch (event) {
                .back => self.getBackTarget(),
                .error_occurred => .error_display,
                else => null,
            },
            .settings => switch (event) {
                .back => self.getBackTarget(),
                .select => .about, // For "About" menu item
                .error_occurred => .error_display,
                else => null,
            },
            .about => switch (event) {
                .back => self.getBackTarget(),
                else => null,
            },
            .error_display => switch (event) {
                .error_dismissed, .back => self.getBackTarget(),
                else => null,
            },
            .loading => switch (event) {
                .track_loaded => .now_playing,
                .track_failed => .error_display,
                .timeout => .error_display,
                else => null,
            },
        };
    }

    /// Get back target from stack
    fn getBackTarget(self: *const StateMachine) ?State {
        if (self.stack_depth > 0) {
            return self.stack[self.stack_depth - 1];
        }
        return .main_menu;
    }

    /// Transition to a specific state
    pub fn transitionTo(self: *StateMachine, to: State, event: Event) TransitionResult {
        // Already in this state?
        if (self.current == to) {
            self.recordTransition(self.current, to, event, .no_change);
            return .no_change;
        }

        // Check guard
        if (self.guard) |guard_fn| {
            if (self.context) |ctx| {
                if (!guard_fn(self.current, to, ctx)) {
                    self.recordTransition(self.current, to, event, .blocked);
                    return .blocked;
                }
            }
        }

        // Execute exit action for current state
        if (self.on_exit) |exit_fn| {
            if (self.context) |ctx| {
                exit_fn(self.current, ctx);
            }
        }

        // Update state
        self.previous = self.current;
        self.current = to;

        // Execute entry action for new state
        if (self.on_entry) |entry_fn| {
            if (self.context) |ctx| {
                entry_fn(to, ctx);
            }
        }

        self.recordTransition(self.previous, to, event, .success);
        return .success;
    }

    /// Push current state onto stack and transition
    pub fn pushState(self: *StateMachine, to: State) TransitionResult {
        if (self.stack_depth < self.stack.len) {
            self.stack[self.stack_depth] = self.current;
            self.stack_depth += 1;
        }
        return self.transitionTo(to, .select);
    }

    /// Pop state from stack and transition back
    pub fn popState(self: *StateMachine) TransitionResult {
        if (self.stack_depth > 0) {
            self.stack_depth -= 1;
            const target = self.stack[self.stack_depth];
            return self.transitionTo(target, .back);
        }
        // Default to main menu if stack is empty
        return self.transitionTo(.main_menu, .back);
    }

    /// Go back to previous state
    pub fn goBack(self: *StateMachine) TransitionResult {
        return self.handleEvent(.back);
    }

    /// Select a main menu item by index
    pub fn selectMainMenuItem(self: *StateMachine, index: usize) TransitionResult {
        if (self.current != .main_menu) return .invalid;

        const target: State = switch (index) {
            0 => .music_browser,
            1 => .file_browser, // Playlists -> file browser for now
            2 => .file_browser,
            3 => .now_playing,
            5 => .settings,
            else => return .invalid,
        };

        return self.pushState(target);
    }

    /// Set error and transition to error state
    pub fn setError(self: *StateMachine, message: []const u8) TransitionResult {
        const len = @min(message.len, self.error_message.len);
        @memcpy(self.error_message[0..len], message[0..len]);
        self.error_len = @intCast(len);
        return self.transitionTo(.error_display, .error_occurred);
    }

    /// Clear error and go back
    pub fn clearError(self: *StateMachine) TransitionResult {
        self.error_len = 0;
        return self.handleEvent(.error_dismissed);
    }

    /// Record transition in history
    fn recordTransition(
        self: *StateMachine,
        from: State,
        to: State,
        event: Event,
        result: TransitionResult,
    ) void {
        self.history[self.history_idx] = .{
            .from = from,
            .to = to,
            .event = event,
            .result = result,
        };
        self.history_idx = @intCast((self.history_idx + 1) % self.history.len);
    }

    /// Get transition history (for debugging)
    pub fn getHistory(self: *const StateMachine) []const Transition {
        // Return filled portion of history
        if (self.history_idx < self.history.len) {
            return self.history[0..self.history_idx];
        }
        return &self.history;
    }

    /// Reset to initial state
    pub fn reset(self: *StateMachine) void {
        self.current = .boot;
        self.previous = .boot;
        self.stack_depth = 0;
        self.error_len = 0;
        self.history_idx = 0;
    }
};

// ============================================================
// Global State Machine Instance
// ============================================================

var global_state_machine: StateMachine = StateMachine.init();

/// Get the global state machine
pub fn getGlobal() *StateMachine {
    return &global_state_machine;
}

/// Reset the global state machine
pub fn resetGlobal() void {
    global_state_machine.reset();
}

// ============================================================
// Tests
// ============================================================

test "state machine initialization" {
    var sm = StateMachine.init();
    try std.testing.expectEqual(State.boot, sm.getState());
    try std.testing.expectEqual(State.boot, sm.getPrevious());
    try std.testing.expectEqual(@as(u8, 0), sm.stack_depth);
}

test "boot to main menu transition" {
    var sm = StateMachine.init();
    try std.testing.expectEqual(State.boot, sm.getState());

    const result = sm.handleEvent(.boot_complete);
    try std.testing.expectEqual(TransitionResult.success, result);
    try std.testing.expectEqual(State.main_menu, sm.getState());
    try std.testing.expectEqual(State.boot, sm.getPrevious());
}

test "main menu navigation" {
    var sm = StateMachine.init();
    _ = sm.handleEvent(.boot_complete);

    // Select Music (index 0)
    var result = sm.selectMainMenuItem(0);
    try std.testing.expectEqual(TransitionResult.success, result);
    try std.testing.expectEqual(State.music_browser, sm.getState());
    try std.testing.expectEqual(@as(u8, 1), sm.stack_depth);

    // Go back
    result = sm.goBack();
    try std.testing.expectEqual(TransitionResult.success, result);
    try std.testing.expectEqual(State.main_menu, sm.getState());
    try std.testing.expectEqual(@as(u8, 0), sm.stack_depth);
}

test "deep navigation and back" {
    var sm = StateMachine.init();
    _ = sm.handleEvent(.boot_complete);

    // Navigate: Main Menu -> Music -> (simulate to now_playing)
    _ = sm.selectMainMenuItem(0); // Music
    try std.testing.expectEqual(@as(u8, 1), sm.stack_depth);

    _ = sm.pushState(.now_playing);
    try std.testing.expectEqual(@as(u8, 2), sm.stack_depth);
    try std.testing.expectEqual(State.now_playing, sm.getState());

    // Back to Music
    _ = sm.popState();
    try std.testing.expectEqual(State.music_browser, sm.getState());
    try std.testing.expectEqual(@as(u8, 1), sm.stack_depth);

    // Back to Main Menu
    _ = sm.popState();
    try std.testing.expectEqual(State.main_menu, sm.getState());
    try std.testing.expectEqual(@as(u8, 0), sm.stack_depth);
}

test "error state" {
    var sm = StateMachine.init();
    _ = sm.handleEvent(.boot_complete);
    _ = sm.selectMainMenuItem(0);

    // Trigger error
    const result = sm.setError("File not found");
    try std.testing.expectEqual(TransitionResult.success, result);
    try std.testing.expectEqual(State.error_display, sm.getState());
    try std.testing.expectEqualStrings("File not found", sm.getErrorMessage());

    // Clear error
    _ = sm.clearError();
    try std.testing.expectEqual(State.main_menu, sm.getState());
}

test "play pressed from main menu" {
    var sm = StateMachine.init();
    _ = sm.handleEvent(.boot_complete);

    const result = sm.handleEvent(.play_pressed);
    try std.testing.expectEqual(TransitionResult.success, result);
    try std.testing.expectEqual(State.now_playing, sm.getState());
}

test "state name" {
    try std.testing.expectEqualStrings("Main Menu", State.main_menu.getName());
    try std.testing.expectEqualStrings("Now Playing", State.now_playing.getName());
    try std.testing.expectEqualStrings("Music", State.music_browser.getName());
}

test "allows back" {
    try std.testing.expect(!State.boot.allowsBack());
    try std.testing.expect(!State.main_menu.allowsBack());
    try std.testing.expect(State.music_browser.allowsBack());
    try std.testing.expect(State.now_playing.allowsBack());
}

test "no change on same state" {
    var sm = StateMachine.init();
    _ = sm.handleEvent(.boot_complete);

    // Try to go to main_menu when already there
    const result = sm.transitionTo(.main_menu, .select);
    try std.testing.expectEqual(TransitionResult.no_change, result);
}

test "invalid transition" {
    var sm = StateMachine.init();

    // Try back from boot (invalid)
    const result = sm.handleEvent(.back);
    try std.testing.expectEqual(TransitionResult.invalid, result);
    try std.testing.expectEqual(State.boot, sm.getState());
}

test "transition history" {
    var sm = StateMachine.init();

    _ = sm.handleEvent(.boot_complete);
    _ = sm.selectMainMenuItem(0);
    _ = sm.goBack();

    const history = sm.getHistory();
    try std.testing.expect(history.len >= 3);
}

test "global state machine" {
    resetGlobal();
    const sm = getGlobal();
    try std.testing.expectEqual(State.boot, sm.getState());
}
