const std = @import("std");
const termicam = @import("termicam");
const camera = @import("camera.zig");
const ascii = @import("ascii.zig");
const term = @import("term.zig");
const builtin = @import("builtin");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Get terminal size
    const term_size = try term.getTermSize();

    // Initialize camera
    var cam = try camera.Camera.init();
    defer cam.deinit();

    // Open camera
    try cam.open();
    defer cam.close();

    // Initialize Braille converter with edge detection
    var converter = try ascii.BrailleConverter.init(allocator, .edge_detection, 2, false);
    defer converter.converter().deinit();

    // Warmup: Capture and discard a few frames to let camera auto-expose
    var i: u32 = 0;
    while (i < 3) : (i += 1) {
        _ = try cam.captureFrame();
    }

    // Setup buffered stdout writer (reused across frames)
    var stdout_buffer: [8192]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    // Continuous frame loop
    while (true) {
        // Start timing
        const start_time = std.time.nanoTimestamp();

        // Capture frame
        const frame = try cam.captureFrame();
        const capture_time = std.time.nanoTimestamp();

        // Calculate output dimensions
        const output_cols = term_size.cols;
        const output_rows = term.calculateBrailleRows(frame, output_cols);

        // Convert to Braille
        const convert_start = std.time.nanoTimestamp();
        const braille_text = try converter.imageToText(frame, output_cols, output_rows, allocator);
        const convert_end = std.time.nanoTimestamp();
        defer allocator.free(braille_text);

        // Clear screen right before rendering
        try term.clearScreen(stdout);

        // Print the frame
        try stdout.writeAll(braille_text);

        // Print debug timing info (only in debug builds)
        if (builtin.mode == .Debug) {
            const capture_ms = @as(f64, @floatFromInt(capture_time - start_time)) / 1_000_000.0;
            const convert_ms = @as(f64, @floatFromInt(convert_end - convert_start)) / 1_000_000.0;
            const total_ms = @as(f64, @floatFromInt(convert_end - start_time)) / 1_000_000.0;
            const fps = 1000.0 / total_ms;
            try stdout.print("\nFPS: {d:.1} | Capture: {d:.1}ms | Convert: {d:.1}ms | Total: {d:.1}ms\n", .{ fps, capture_ms, convert_ms, total_ms });
        }

        try stdout.flush();
    }
}

test "simple test" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(i32) = .empty;
    defer list.deinit(gpa); // Try commenting this out and see if zig detects the memory leak!
    try list.append(gpa, 42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}

test "fuzz example" {
    const Context = struct {
        fn testOne(context: @This(), input: []const u8) anyerror!void {
            _ = context;
            // Try passing `--fuzz` to `zig build test` and see if it manages to fail this test case!
            try std.testing.expect(!std.mem.eql(u8, "canyoufindme", input));
        }
    };
    try std.testing.fuzz(Context{}, Context.testOne, .{});
}
