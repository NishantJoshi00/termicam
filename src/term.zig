const std = @import("std");
const camera = @import("camera.zig");

/// Terminal dimensions
pub const TermSize = struct {
    cols: u32,
    rows: u32,
};

/// Get current terminal size
pub fn getTermSize() !TermSize {
    // Use TIOCGWINSZ ioctl to get terminal size on Unix systems
    const c = @cImport({
        @cInclude("sys/ioctl.h");
        @cInclude("unistd.h");
    });

    var winsize: c.winsize = undefined;
    const result = c.ioctl(c.STDOUT_FILENO, c.TIOCGWINSZ, &winsize);

    if (result == -1) {
        return error.TermSizeUnavailable;
    }

    return TermSize{
        .cols = winsize.ws_col,
        .rows = winsize.ws_row,
    };
}

/// Calculate rows needed for given columns with 1:1 pixel scaling
/// Each Braille character represents 2x4 pixels
pub fn calculateBrailleRows(image: camera.Image, target_cols: u32) u32 {
    // Each Braille char = 2 pixels wide, 4 pixels tall
    const pixels_per_braille_width = 2;
    const pixels_per_braille_height = 4;

    // Calculate scale factor to fit image width to target columns
    const scale = @as(f32, @floatFromInt(image.width)) / @as(f32, @floatFromInt(target_cols * pixels_per_braille_width));

    // Apply same scale to height (1:1 pixel aspect ratio)
    const output_pixel_height = @as(f32, @floatFromInt(image.height)) / scale;

    // Convert to Braille rows
    const output_rows = @as(u32, @intFromFloat(output_pixel_height)) / pixels_per_braille_height;

    // Ensure at least 1 row
    return if (output_rows == 0) 1 else output_rows;
}

/// Clear the terminal screen
/// Accepts any writer type (typically a buffered stdout writer)
pub fn clearScreen(stdout: anytype) !void {
    // ANSI escape code to clear screen and move cursor to home
    try stdout.writeAll("\x1B[2J\x1B[H");
}

/// Move cursor to top-left
pub fn moveCursorHome() !void {
    var buffer: [32]u8 = undefined;
    var writer = std.fs.File.stdout().writer(&buffer);
    const stdout = &writer.interface;
    try stdout.writeAll("\x1B[H");
    try stdout.flush();
}

test "terminal size" {
    const size = try getTermSize();
    try std.testing.expect(size.cols > 0);
    try std.testing.expect(size.rows > 0);
}

test "calculate Braille rows" {
    const test_image = camera.Image{
        .data = &[_]u8{0} ** 100,
        .width = 1920,
        .height = 1080,
        .bytes_per_row = 1920,
    };

    const target_cols: u32 = 120;
    const rows = calculateBrailleRows(test_image, target_cols);

    // Should calculate some reasonable number of rows
    try std.testing.expect(rows > 0);
    try std.testing.expect(rows < 1000); // Sanity check
}
