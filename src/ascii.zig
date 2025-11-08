const std = @import("std");
const camera = @import("camera");

/// Generic converter interface for pluggable ASCII/Braille rendering backends
pub const Converter = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        convert: *const fn (ptr: *anyopaque, image: camera.Image, target_cols: u32, target_rows: u32, allocator: std.mem.Allocator) anyerror![]u8,
        deinit: *const fn (ptr: *anyopaque) void,
    };

    /// Convert image to text representation
    pub fn convert(self: Converter, image: camera.Image, target_cols: u32, target_rows: u32, allocator: std.mem.Allocator) ![]u8 {
        return self.vtable.convert(self.ptr, image, target_cols, target_rows, allocator);
    }

    /// Clean up converter resources
    pub fn deinit(self: Converter) void {
        self.vtable.deinit(self.ptr);
    }
};

/// Rendering algorithm selection
pub const RenderMode = enum {
    edge_detection, // Gradient-based edge detection (sharp, clean features)
    brightness, // Brightness-based with threshold (simple)
    // brightness_dithered, // Future: brightness + dithering
};

/// Braille dot positions for 2x4 grid (compile-time constant)
/// Maps each of 8 dots to their (x, y) position within the 2x4 Braille cell
const BRAILLE_DOT_POSITIONS = [8][2]u32{
    .{ 0, 0 }, // Dot 1 (bit 0x01)
    .{ 0, 1 }, // Dot 2 (bit 0x02)
    .{ 0, 2 }, // Dot 3 (bit 0x04)
    .{ 1, 0 }, // Dot 4 (bit 0x08)
    .{ 1, 1 }, // Dot 5 (bit 0x10)
    .{ 1, 2 }, // Dot 6 (bit 0x20)
    .{ 0, 3 }, // Dot 7 (bit 0x40)
    .{ 1, 3 }, // Dot 8 (bit 0x80)
};

/// Braille pattern converter (U+2800-U+28FF)
/// Each Braille character represents a 2x4 pixel grid
pub const BrailleConverter = struct {
    allocator: std.mem.Allocator,
    mode: RenderMode,
    edge_threshold: u8, // Threshold for edge detection gradient (0-255)
    invert: bool, // Invert output (light dots on dark vs dark dots on light)

    const Self = @This();

    /// Create a new Braille converter
    pub fn init(allocator: std.mem.Allocator, mode: RenderMode, edge_threshold: u8, invert: bool) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .mode = mode,
            .edge_threshold = edge_threshold,
            .invert = invert,
        };
        return self;
    }

    /// Get generic Converter interface
    pub fn converter(self: *Self) Converter {
        return .{
            .ptr = self,
            .vtable = &.{
                .convert = convertImpl,
                .deinit = deinitImpl,
            },
        };
    }

    fn convertImpl(ptr: *anyopaque, image: camera.Image, target_cols: u32, target_rows: u32, allocator: std.mem.Allocator) ![]u8 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.imageToText(image, target_cols, target_rows, allocator);
    }

    fn deinitImpl(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    /// Convert camera image to Braille text
    /// target_cols: desired width in Braille characters (terminal columns)
    /// target_rows: desired height in Braille characters (terminal rows)
    pub fn imageToText(
        self: *Self,
        image: camera.Image,
        target_cols: u32,
        target_rows: u32,
        allocator: std.mem.Allocator,
    ) ![]u8 {
        // Use target dimensions directly
        const output_width = target_cols;
        const output_height = target_rows;

        // Calculate scaling factors once per frame (from output space to source image space)
        const scale_x = @as(f32, @floatFromInt(image.width)) / @as(f32, @floatFromInt(output_width * 2));
        const scale_y = @as(f32, @floatFromInt(image.height)) / @as(f32, @floatFromInt(output_height * 4));

        // Each Braille char is 3 bytes in UTF-8, plus newline per row
        const bytes_per_row = output_width * 3 + 1;
        const total_bytes = output_height * bytes_per_row;

        var buffer = try allocator.alloc(u8, total_bytes);
        var buf_offset: usize = 0;

        var row: u32 = 0;
        while (row < output_height) : (row += 1) {
            var col: u32 = 0;
            while (col < output_width) : (col += 1) {
                const braille_char = self.pixelBlockToBraille(image, col, row, scale_x, scale_y);
                buf_offset += encodeUtf8Braille(braille_char, buffer[buf_offset..]);
            }

            buffer[buf_offset] = '\n';
            buf_offset += 1;
        }

        return buffer;
    }

    /// Convert 2x4 pixel block to Braille character
    /// col, row: position in output Braille grid
    /// scale_x, scale_y: pre-calculated scaling factors from output to source image space
    fn pixelBlockToBraille(
        self: *Self,
        image: camera.Image,
        col: u32,
        row: u32,
        scale_x: f32,
        scale_y: f32,
    ) u21 {
        // Braille pattern bit positions:
        // 1 4   (0x01 0x08)
        // 2 5   (0x02 0x10)
        // 3 6   (0x04 0x20)
        // 7 8   (0x40 0x80)

        var pattern: u8 = 0;

        for (BRAILLE_DOT_POSITIONS, 0..) |pos, i| {
            // Calculate position in output pixel space (each Braille char = 2x4 pixels)
            const out_x = col * 2 + pos[0];
            const out_y = row * 4 + pos[1];

            // Map to source image coordinates
            const src_x = @as(u32, @intFromFloat(@as(f32, @floatFromInt(out_x)) * scale_x));
            const src_y = @as(u32, @intFromFloat(@as(f32, @floatFromInt(out_y)) * scale_y));

            if (src_x < image.width and src_y < image.height) {
                const should_draw = self.shouldDrawDot(image, src_x, src_y);

                if (should_draw) {
                    pattern |= @as(u8, 1) << @intCast(i);
                }
            }
        }

        // Braille patterns start at U+2800
        return 0x2800 + @as(u21, pattern);
    }

    /// Determine if a dot should be drawn based on the selected rendering mode
    fn shouldDrawDot(self: *Self, image: camera.Image, x: u32, y: u32) bool {
        return switch (self.mode) {
            .edge_detection => self.shouldDrawDotEdge(image, x, y),
            .brightness => self.shouldDrawDotBrightness(image, x, y),
        };
    }

    /// Edge detection mode: place dot where gradients/edges are detected
    fn shouldDrawDotEdge(self: *Self, image: camera.Image, x: u32, y: u32) bool {
        // Get center pixel
        const center = image.getPixel(x, y);

        // Compute simple gradient by comparing to neighbors (4-connected)
        var gradient: u32 = 0;
        var count: u32 = 0;

        // Check left neighbor
        if (x > 0) {
            const left = image.getPixel(x - 1, y);
            gradient += absDiff(center, left);
            count += 1;
        }

        // Check right neighbor
        if (x + 1 < image.width) {
            const right = image.getPixel(x + 1, y);
            gradient += absDiff(center, right);
            count += 1;
        }

        // Check top neighbor
        if (y > 0) {
            const top = image.getPixel(x, y - 1);
            gradient += absDiff(center, top);
            count += 1;
        }

        // Check bottom neighbor
        if (y + 1 < image.height) {
            const bottom = image.getPixel(x, y + 1);
            gradient += absDiff(center, bottom);
            count += 1;
        }

        // Average gradient magnitude
        const avg_gradient = if (count > 0) gradient / count else 0;

        // Place dot if gradient exceeds threshold (edge detected)
        const result = avg_gradient > self.edge_threshold;
        return if (self.invert) !result else result;
    }

    /// Brightness mode: simple threshold
    fn shouldDrawDotBrightness(self: *Self, image: camera.Image, x: u32, y: u32) bool {
        const brightness = image.getPixel(x, y);
        const result = brightness > self.edge_threshold; // Reuse threshold
        return if (self.invert) !result else result;
    }

    /// Absolute difference between two u8 values
    fn absDiff(a: u8, b: u8) u32 {
        return if (a > b) a - b else b - a;
    }
};

/// Encode a Braille Unicode codepoint to UTF-8
/// Braille patterns (U+2800-U+28FF) always encode to 3 bytes
fn encodeUtf8Braille(codepoint: u21, buffer: []u8) usize {
    std.debug.assert(codepoint >= 0x2800 and codepoint <= 0x28FF);
    std.debug.assert(buffer.len >= 3);

    // UTF-8 encoding for 3-byte sequence (U+0800 to U+FFFF):
    // 1110xxxx 10xxxxxx 10xxxxxx
    buffer[0] = 0xE0 | @as(u8, @intCast((codepoint >> 12) & 0x0F));
    buffer[1] = 0x80 | @as(u8, @intCast((codepoint >> 6) & 0x3F));
    buffer[2] = 0x80 | @as(u8, @intCast(codepoint & 0x3F));

    return 3;
}

// Tests
test "Braille UTF-8 encoding" {
    var buffer: [3]u8 = undefined;

    // Empty pattern (all dots off)
    const bytes1 = encodeUtf8Braille(0x2800, &buffer);
    try std.testing.expectEqual(@as(usize, 3), bytes1);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xE2, 0xA0, 0x80 }, buffer[0..]);

    // Full pattern (all dots on)
    const bytes2 = encodeUtf8Braille(0x28FF, &buffer);
    try std.testing.expectEqual(@as(usize, 3), bytes2);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xE2, 0xA3, 0xBF }, buffer[0..]);
}

test "Braille converter basic" {
    const allocator = std.testing.allocator;

    // Create simple 2x4 test image
    var pixels = [_]u8{
        255, 255, // Row 0: white
        0, 0, // Row 1: black
        255, 255, // Row 2: white
        0, 0, // Row 3: black
    };

    const test_image = camera.Image{
        .data = &pixels,
        .width = 2,
        .height = 4,
        .bytes_per_row = 2,
    };

    var conv = try BrailleConverter.init(allocator, .brightness, 128, false);
    defer conv.converter().deinit();

    // Convert to 1x1 Braille character
    const result = try conv.imageToText(test_image, 1, 1, allocator);
    defer allocator.free(result);

    // Should produce one Braille character plus newline
    try std.testing.expect(result.len == 4); // 3 bytes UTF-8 + 1 newline
    try std.testing.expectEqual(@as(u8, '\n'), result[3]);
}
