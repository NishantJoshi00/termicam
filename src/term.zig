const std = @import("std");
const camera = @import("camera");

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
    // Skip test if not running in a real terminal
    const size = getTermSize() catch |err| {
        if (err == error.TermSizeUnavailable) return error.SkipZigTest;
        return err;
    };
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

test "calculate Braille rows maintains aspect ratio" {
    // Square image 400x400
    const square_image = camera.Image{
        .data = &[_]u8{0} ** 100,
        .width = 400,
        .height = 400,
        .bytes_per_row = 400,
    };

    const cols: u32 = 40; // 40 cols * 2 = 80 pixels wide
    const rows = calculateBrailleRows(square_image, cols);

    // For a square image scaled to 40 cols (80 pixels wide):
    // Scale factor = 400 / 80 = 5
    // Height in output pixels = 400 / 5 = 80
    // Height in Braille rows = 80 / 4 = 20
    try std.testing.expectEqual(@as(u32, 20), rows);
}

test "calculate Braille rows wide image" {
    // Wide image 1600x800 (2:1 aspect ratio)
    const wide_image = camera.Image{
        .data = &[_]u8{0} ** 100,
        .width = 1600,
        .height = 800,
        .bytes_per_row = 1600,
    };

    const cols: u32 = 80; // 80 cols * 2 = 160 pixels wide
    const rows = calculateBrailleRows(wide_image, cols);

    // Scale factor = 1600 / 160 = 10
    // Height in output pixels = 800 / 10 = 80
    // Height in Braille rows = 80 / 4 = 20
    try std.testing.expectEqual(@as(u32, 20), rows);
}

test "calculate Braille rows tall image" {
    // Tall image 800x1600 (1:2 aspect ratio)
    const tall_image = camera.Image{
        .data = &[_]u8{0} ** 100,
        .width = 800,
        .height = 1600,
        .bytes_per_row = 800,
    };

    const cols: u32 = 40; // 40 cols * 2 = 80 pixels wide
    const rows = calculateBrailleRows(tall_image, cols);

    // Scale factor = 800 / 80 = 10
    // Height in output pixels = 1600 / 10 = 160
    // Height in Braille rows = 160 / 4 = 40
    try std.testing.expectEqual(@as(u32, 40), rows);
}

test "calculate Braille rows minimum output" {
    // Very small image
    const tiny_image = camera.Image{
        .data = &[_]u8{0} ** 100,
        .width = 10,
        .height = 5,
        .bytes_per_row = 10,
    };

    const cols: u32 = 100;
    const rows = calculateBrailleRows(tiny_image, cols);

    // Should always return at least 1 row
    try std.testing.expect(rows >= 1);
}

test "calculate Braille rows common resolutions" {
    // Test with 1080p (1920x1080) fitting to 160 cols
    const hd_image = camera.Image{
        .data = &[_]u8{0} ** 100,
        .width = 1920,
        .height = 1080,
        .bytes_per_row = 1920,
    };

    const cols: u32 = 160; // 160 cols * 2 = 320 pixels wide
    const rows = calculateBrailleRows(hd_image, cols);

    // Scale factor = 1920 / 320 = 6
    // Height in output pixels = 1080 / 6 = 180
    // Height in Braille rows = 180 / 4 = 45
    try std.testing.expectEqual(@as(u32, 45), rows);
}
