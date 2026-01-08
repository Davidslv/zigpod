//! Theme File Loader
//!
//! Loads custom themes from /themes/ directory on FAT32 storage.
//! Theme files use a simple INI-style format that non-programmers can edit.
//!
//! File format (.THM):
//! ```
//! [theme]
//! name=My Theme
//! author=Community User
//!
//! [colors]
//! background=255,255,255
//! foreground=0,0,0
//! ...
//! ```

const std = @import("std");
const ui = @import("ui.zig");
const lcd = @import("../drivers/display/lcd.zig");
const fat32 = @import("../drivers/storage/fat32.zig");
const hal = @import("../hal/hal.zig");

// ============================================================
// Constants
// ============================================================

/// Maximum number of custom themes (beyond built-in light/dark)
pub const MAX_CUSTOM_THEMES: usize = 32;

/// Maximum theme file size
pub const MAX_THEME_FILE_SIZE: usize = 1024;

/// Theme directory name (8.3 format)
pub const THEMES_DIR_NAME = "THEMES     ";

// ============================================================
// Theme Metadata
// ============================================================

/// Theme metadata stored alongside colors
pub const ThemeMetadata = struct {
    /// Theme display name (max 31 chars + null)
    name: [32]u8 = [_]u8{0} ** 32,
    /// Author name (max 31 chars + null)
    author: [32]u8 = [_]u8{0} ** 32,
    /// Filename (8.3 format, 11 chars)
    filename: [12]u8 = [_]u8{0} ** 12,
    /// Is this slot valid/used?
    valid: bool = false,

    /// Get name as slice (up to null terminator)
    pub fn getName(self: *const ThemeMetadata) []const u8 {
        for (self.name, 0..) |c, i| {
            if (c == 0) return self.name[0..i];
        }
        return &self.name;
    }

    /// Get author as slice (up to null terminator)
    pub fn getAuthor(self: *const ThemeMetadata) []const u8 {
        for (self.author, 0..) |c, i| {
            if (c == 0) return self.author[0..i];
        }
        return &self.author;
    }
};

// ============================================================
// Custom Theme
// ============================================================

/// A custom theme with metadata and colors
pub const CustomTheme = struct {
    metadata: ThemeMetadata = .{},
    theme: ui.Theme = ui.default_theme,
};

// ============================================================
// Theme Registry
// ============================================================

/// Registry of all available themes (built-in + custom)
pub const ThemeRegistry = struct {
    /// Built-in theme indices
    pub const BUILTIN_LIGHT: u8 = 0;
    pub const BUILTIN_DARK: u8 = 1;
    pub const BUILTIN_COUNT: u8 = 2;

    /// Custom themes storage (fixed array, no allocation)
    custom_themes: [MAX_CUSTOM_THEMES]CustomTheme = [_]CustomTheme{.{}} ** MAX_CUSTOM_THEMES,

    /// Number of valid custom themes loaded
    custom_count: u8 = 0,

    /// Currently selected theme index
    selected_index: u8 = BUILTIN_LIGHT,

    /// Scan /themes/ directory and load all .THM files
    pub fn scanThemes(self: *ThemeRegistry, fs: *fat32.Fat32) hal.HalError!void {
        self.custom_count = 0;

        // Open root directory
        var root = try fs.openRootDir();

        // Search for THEMES directory
        while (try root.readEntry()) |entry| {
            if (entry.isDirectory() and isThemesDir(&entry.name)) {
                // Found themes directory, scan it
                var themes_dir = fat32.Directory{
                    .fs = fs,
                    .first_cluster = entry.getCluster(),
                    .current_cluster = entry.getCluster(),
                    .position = 0,
                };

                try self.loadThemesFromDir(&themes_dir, fs);
                break;
            }
        }
    }

    /// Load all theme files from a directory
    fn loadThemesFromDir(self: *ThemeRegistry, dir: *fat32.Directory, fs: *fat32.Fat32) hal.HalError!void {
        while (try dir.readEntry()) |entry| {
            // Skip directories and check capacity
            if (entry.isDirectory() or self.custom_count >= MAX_CUSTOM_THEMES) {
                continue;
            }

            // Check for .THM extension
            if (isThemeFile(&entry.name)) {
                // Open and read theme file
                var theme_file = fat32.File{
                    .fs = fs,
                    .first_cluster = entry.getCluster(),
                    .current_cluster = entry.getCluster(),
                    .file_size = entry.file_size,
                    .position = 0,
                };

                // Read file content (limited to MAX_THEME_FILE_SIZE)
                var buffer: [MAX_THEME_FILE_SIZE]u8 = undefined;
                const bytes_read = try theme_file.read(&buffer);

                // Parse theme file
                if (parseThemeFile(buffer[0..bytes_read])) |theme| {
                    self.custom_themes[self.custom_count] = theme;
                    // Copy filename
                    @memcpy(self.custom_themes[self.custom_count].metadata.filename[0..11], entry.name[0..11]);
                    self.custom_themes[self.custom_count].metadata.valid = true;
                    self.custom_count += 1;
                }
            }
        }
    }

    /// Get theme by index (0=light, 1=dark, 2+=custom)
    pub fn getTheme(self: *const ThemeRegistry, index: u8) ui.Theme {
        if (index == BUILTIN_LIGHT) return ui.default_theme;
        if (index == BUILTIN_DARK) return ui.dark_theme;

        const custom_idx = index - BUILTIN_COUNT;
        if (custom_idx < self.custom_count) {
            return self.custom_themes[custom_idx].theme;
        }

        return ui.default_theme;
    }

    /// Get theme name by index
    pub fn getThemeName(self: *const ThemeRegistry, index: u8) []const u8 {
        if (index == BUILTIN_LIGHT) return "Light";
        if (index == BUILTIN_DARK) return "Dark";

        const custom_idx = index - BUILTIN_COUNT;
        if (custom_idx < self.custom_count) {
            return self.custom_themes[custom_idx].metadata.getName();
        }

        return "Unknown";
    }

    /// Get theme metadata by index (null for built-in themes)
    pub fn getThemeMetadata(self: *const ThemeRegistry, index: u8) ?*const ThemeMetadata {
        if (index < BUILTIN_COUNT) return null;

        const custom_idx = index - BUILTIN_COUNT;
        if (custom_idx < self.custom_count) {
            return &self.custom_themes[custom_idx].metadata;
        }

        return null;
    }

    /// Get total number of available themes
    pub fn getThemeCount(self: *const ThemeRegistry) u8 {
        return BUILTIN_COUNT + self.custom_count;
    }

    /// Select and apply a theme by index
    pub fn selectTheme(self: *ThemeRegistry, index: u8) void {
        if (index < self.getThemeCount()) {
            self.selected_index = index;
            ui.setTheme(self.getTheme(index));
        }
    }

    /// Cycle to next theme
    pub fn nextTheme(self: *ThemeRegistry) void {
        const count = self.getThemeCount();
        self.selectTheme((self.selected_index + 1) % count);
    }

    /// Cycle to previous theme
    pub fn prevTheme(self: *ThemeRegistry) void {
        const count = self.getThemeCount();
        if (self.selected_index == 0) {
            self.selectTheme(count - 1);
        } else {
            self.selectTheme(self.selected_index - 1);
        }
    }

    /// Get currently selected index
    pub fn getSelectedIndex(self: *const ThemeRegistry) u8 {
        return self.selected_index;
    }
};

// ============================================================
// Global Registry
// ============================================================

var theme_registry: ThemeRegistry = .{};

/// Get the global theme registry
pub fn getRegistry() *ThemeRegistry {
    return &theme_registry;
}

// ============================================================
// File Detection
// ============================================================

/// Check if directory name is "THEMES" (8.3 format)
fn isThemesDir(name: *const [11]u8) bool {
    return std.mem.eql(u8, name[0..6], "THEMES");
}

/// Check if filename has .THM extension (8.3 format)
fn isThemeFile(name: *const [11]u8) bool {
    return std.mem.eql(u8, name[8..11], "THM");
}

// ============================================================
// Theme File Parser
// ============================================================

/// Parse theme file content into CustomTheme
fn parseThemeFile(data: []const u8) ?CustomTheme {
    var theme = CustomTheme{};
    var parser = ThemeParser.init(data);

    var in_colors_section = false;
    var in_theme_section = false;
    var has_name = false;

    while (parser.readLine()) |line| {
        const trimmed = trimWhitespace(line);

        // Skip empty lines and comments
        if (trimmed.len == 0) continue;
        if (trimmed[0] == '#' or trimmed[0] == ';') continue;

        // Check for section headers
        if (trimmed[0] == '[') {
            if (eqlIgnoreCase(trimmed, "[theme]")) {
                in_theme_section = true;
                in_colors_section = false;
            } else if (eqlIgnoreCase(trimmed, "[colors]")) {
                in_colors_section = true;
                in_theme_section = false;
            } else {
                // Unknown section
                in_theme_section = false;
                in_colors_section = false;
            }
            continue;
        }

        // Parse key=value pairs
        if (findChar(trimmed, '=')) |eq_pos| {
            const key = trimWhitespace(trimmed[0..eq_pos]);
            const value = trimWhitespace(trimmed[eq_pos + 1 ..]);

            if (in_theme_section) {
                if (eqlIgnoreCase(key, "name")) {
                    copyString(&theme.metadata.name, value);
                    has_name = true;
                } else if (eqlIgnoreCase(key, "author")) {
                    copyString(&theme.metadata.author, value);
                }
            } else if (in_colors_section) {
                if (parseRgbValue(value)) |color| {
                    applyColorToTheme(&theme.theme, key, color);
                }
            }
        }
    }

    // Theme must have at least a name to be valid
    if (has_name) {
        return theme;
    }

    return null;
}

/// Apply a color to the appropriate theme field
fn applyColorToTheme(theme: *ui.Theme, key: []const u8, color: lcd.Color) void {
    if (eqlIgnoreCase(key, "background")) {
        theme.background = color;
    } else if (eqlIgnoreCase(key, "foreground")) {
        theme.foreground = color;
    } else if (eqlIgnoreCase(key, "header_bg")) {
        theme.header_bg = color;
    } else if (eqlIgnoreCase(key, "header_fg")) {
        theme.header_fg = color;
    } else if (eqlIgnoreCase(key, "selected_bg")) {
        theme.selected_bg = color;
    } else if (eqlIgnoreCase(key, "selected_fg")) {
        theme.selected_fg = color;
    } else if (eqlIgnoreCase(key, "footer_bg")) {
        theme.footer_bg = color;
    } else if (eqlIgnoreCase(key, "footer_fg")) {
        theme.footer_fg = color;
    } else if (eqlIgnoreCase(key, "accent")) {
        theme.accent = color;
    } else if (eqlIgnoreCase(key, "disabled")) {
        theme.disabled = color;
    }
}

/// Parse "r,g,b" string to RGB565 color
fn parseRgbValue(str: []const u8) ?lcd.Color {
    var r: u8 = 0;
    var g: u8 = 0;
    var b: u8 = 0;
    var component: u8 = 0;
    var value: u16 = 0;
    var has_digits = false;

    for (str) |c| {
        if (c >= '0' and c <= '9') {
            value = value * 10 + (c - '0');
            has_digits = true;
        } else if (c == ',') {
            if (!has_digits) return null;
            if (component == 0) {
                r = @intCast(@min(value, 255));
            } else if (component == 1) {
                g = @intCast(@min(value, 255));
            }
            component += 1;
            value = 0;
            has_digits = false;
        } else if (c != ' ' and c != '\t') {
            // Invalid character
            return null;
        }
    }

    // Final component (blue)
    if (component == 2 and has_digits) {
        b = @intCast(@min(value, 255));
        return lcd.rgb(r, g, b);
    }

    return null;
}

// ============================================================
// Theme Parser (Line Reader)
// ============================================================

const ThemeParser = struct {
    data: []const u8,
    position: usize = 0,

    fn init(data: []const u8) ThemeParser {
        return .{ .data = data };
    }

    fn readLine(self: *ThemeParser) ?[]const u8 {
        if (self.position >= self.data.len) return null;

        const start = self.position;
        var end = start;

        // Find end of line
        while (end < self.data.len and self.data[end] != '\n' and self.data[end] != '\r') {
            end += 1;
        }

        const line = self.data[start..end];

        // Skip line ending (handle \r\n, \n, \r)
        if (end < self.data.len and self.data[end] == '\r') end += 1;
        if (end < self.data.len and self.data[end] == '\n') end += 1;

        self.position = end;
        return line;
    }
};

// ============================================================
// String Utilities
// ============================================================

fn trimWhitespace(str: []const u8) []const u8 {
    var start: usize = 0;
    var end = str.len;

    while (start < end and (str[start] == ' ' or str[start] == '\t')) {
        start += 1;
    }
    while (end > start and (str[end - 1] == ' ' or str[end - 1] == '\t')) {
        end -= 1;
    }

    return str[start..end];
}

fn findChar(str: []const u8, char: u8) ?usize {
    for (str, 0..) |c, i| {
        if (c == char) return i;
    }
    return null;
}

fn copyString(dest: []u8, src: []const u8) void {
    const len = @min(src.len, dest.len - 1);
    @memcpy(dest[0..len], src[0..len]);
    dest[len] = 0;
}

/// Case-insensitive string comparison
fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        const la = if (ca >= 'A' and ca <= 'Z') ca + 32 else ca;
        const lb = if (cb >= 'A' and cb <= 'Z') cb + 32 else cb;
        if (la != lb) return false;
    }
    return true;
}

// ============================================================
// Tests
// ============================================================

test "parse RGB value" {
    // Valid RGB
    const white = parseRgbValue("255,255,255");
    try std.testing.expect(white != null);
    try std.testing.expectEqual(lcd.rgb(255, 255, 255), white.?);

    const black = parseRgbValue("0,0,0");
    try std.testing.expect(black != null);
    try std.testing.expectEqual(lcd.rgb(0, 0, 0), black.?);

    const color = parseRgbValue("66, 133, 244");
    try std.testing.expect(color != null);
    try std.testing.expectEqual(lcd.rgb(66, 133, 244), color.?);

    // Invalid RGB
    try std.testing.expect(parseRgbValue("255,255") == null);
    try std.testing.expect(parseRgbValue("abc") == null);
    try std.testing.expect(parseRgbValue("") == null);
}

test "parse theme file" {
    const theme_data =
        \\[theme]
        \\name=Test Theme
        \\author=Test Author
        \\
        \\[colors]
        \\background=255,255,255
        \\foreground=0,0,0
        \\accent=100,150,200
    ;

    const result = parseThemeFile(theme_data);
    try std.testing.expect(result != null);

    const theme = result.?;
    try std.testing.expectEqualStrings("Test Theme", theme.metadata.getName());
    try std.testing.expectEqualStrings("Test Author", theme.metadata.getAuthor());
    try std.testing.expectEqual(lcd.rgb(255, 255, 255), theme.theme.background);
    try std.testing.expectEqual(lcd.rgb(0, 0, 0), theme.theme.foreground);
    try std.testing.expectEqual(lcd.rgb(100, 150, 200), theme.theme.accent);
}

test "parse theme file with comments" {
    const theme_data =
        \\# This is a comment
        \\[theme]
        \\name=Commented Theme
        \\; Another comment style
        \\
        \\[colors]
        \\background=128,128,128
    ;

    const result = parseThemeFile(theme_data);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("Commented Theme", result.?.metadata.getName());
}

test "theme file without name is invalid" {
    const theme_data =
        \\[theme]
        \\author=No Name
        \\
        \\[colors]
        \\background=0,0,0
    ;

    const result = parseThemeFile(theme_data);
    try std.testing.expect(result == null);
}

test "theme registry built-in themes" {
    var registry = ThemeRegistry{};

    try std.testing.expectEqual(@as(u8, 2), registry.getThemeCount());
    try std.testing.expectEqualStrings("Light", registry.getThemeName(0));
    try std.testing.expectEqualStrings("Dark", registry.getThemeName(1));

    // Built-in themes have no metadata
    try std.testing.expect(registry.getThemeMetadata(0) == null);
    try std.testing.expect(registry.getThemeMetadata(1) == null);
}

test "case insensitive key matching" {
    try std.testing.expect(eqlIgnoreCase("background", "BACKGROUND"));
    try std.testing.expect(eqlIgnoreCase("Background", "background"));
    try std.testing.expect(eqlIgnoreCase("[theme]", "[THEME]"));
    try std.testing.expect(!eqlIgnoreCase("background", "foreground"));
}

test "trim whitespace" {
    try std.testing.expectEqualStrings("hello", trimWhitespace("  hello  "));
    try std.testing.expectEqualStrings("hello", trimWhitespace("\thello\t"));
    try std.testing.expectEqualStrings("hello world", trimWhitespace("  hello world  "));
    try std.testing.expectEqualStrings("", trimWhitespace("   "));
}
