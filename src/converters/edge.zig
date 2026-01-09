const std = @import("std");
const common = @import("common");

const Image = common.Image;
const Converter = common.Converter;
const BRAILLE_DOT_POSITIONS = common.BRAILLE_DOT_POSITIONS;
const encodeUtf8Braille = common.encodeUtf8Braille;
const absDiff = common.absDiff;

/// Edge detection converter using gradient-based rendering
/// Places Braille dots where edges (gradients) are detected in the image
pub const EdgeConverter = struct {
    allocator: std.mem.Allocator,
    threshold: u8, // Threshold for edge detection gradient (0-255)
    invert: bool, // Invert output

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, threshold: u8, invert: bool) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .threshold = threshold,
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

    fn convertImpl(ptr: *anyopaque, image: Image, target_cols: u32, target_rows: u32, allocator: std.mem.Allocator) ![]u8 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.imageToText(image, target_cols, target_rows, allocator);
    }

    fn deinitImpl(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    /// Convert image to Braille text using edge detection
    pub fn imageToText(
        self: *Self,
        image: Image,
        target_cols: u32,
        target_rows: u32,
        allocator: std.mem.Allocator,
    ) ![]u8 {
        const output_width = target_cols;
        const output_height = target_rows;

        // Calculate scaling factors (from output space to source image space)
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

    /// Convert 2x4 pixel block to Braille character using edge detection
    fn pixelBlockToBraille(
        self: *Self,
        image: Image,
        col: u32,
        row: u32,
        scale_x: f32,
        scale_y: f32,
    ) u21 {
        var pattern: u8 = 0;

        const base_out_x = col * 2;
        const base_out_y = row * 4;

        for (BRAILLE_DOT_POSITIONS, 0..) |pos, i| {
            const out_x = base_out_x + pos[0];
            const out_y = base_out_y + pos[1];

            const src_x = @as(u32, @intFromFloat(@as(f32, @floatFromInt(out_x)) * scale_x));
            const src_y = @as(u32, @intFromFloat(@as(f32, @floatFromInt(out_y)) * scale_y));

            if (src_x < image.width and src_y < image.height) {
                if (self.shouldDrawDot(image, src_x, src_y)) {
                    pattern |= @as(u8, 1) << @intCast(i);
                }
            }
        }

        return 0x2800 + @as(u21, pattern);
    }

    /// Determine if a dot should be drawn using edge detection
    /// Places dots where gradients/edges are detected
    fn shouldDrawDot(self: *Self, image: Image, x: u32, y: u32) bool {
        const center = image.getPixel(x, y);
        const width = image.width;
        const height = image.height;

        var gradient: u32 = 0;
        var count: u32 = 0;

        // Check 4-connected neighbors
        if (x > 0) {
            gradient += absDiff(center, image.getPixel(x - 1, y));
            count += 1;
        }
        if (x + 1 < width) {
            gradient += absDiff(center, image.getPixel(x + 1, y));
            count += 1;
        }
        if (y > 0) {
            gradient += absDiff(center, image.getPixel(x, y - 1));
            count += 1;
        }
        if (y + 1 < height) {
            gradient += absDiff(center, image.getPixel(x, y + 1));
            count += 1;
        }

        const avg_gradient = gradient / count;
        const result = avg_gradient > self.threshold;
        return if (self.invert) !result else result;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "EdgeConverter basic" {
    const allocator = std.testing.allocator;

    var pixels = [_]u8{
        255, 255,
        0,   0,
        255, 255,
        0,   0,
    };

    const test_image = Image{
        .data = &pixels,
        .width = 2,
        .height = 4,
        .bytes_per_row = 2,
    };

    var conv = try EdgeConverter.init(allocator, 128, false);
    defer conv.converter().deinit();

    const result = try conv.imageToText(test_image, 1, 1, allocator);
    defer allocator.free(result);

    try std.testing.expect(result.len == 4); // 3 bytes UTF-8 + 1 newline
    try std.testing.expectEqual(@as(u8, '\n'), result[3]);
}

test "EdgeConverter edge detection" {
    const allocator = std.testing.allocator;

    var pixels = [_]u8{
        0, 0, 255, 255,
        0, 0, 255, 255,
        0, 0, 255, 255,
        0, 0, 255, 255,
    };

    const test_image = Image{
        .data = &pixels,
        .width = 4,
        .height = 4,
        .bytes_per_row = 4,
    };

    var conv = try EdgeConverter.init(allocator, 50, false);
    defer conv.converter().deinit();

    const result = try conv.imageToText(test_image, 2, 1, allocator);
    defer allocator.free(result);

    try std.testing.expectEqual(@as(usize, 7), result.len);
    try std.testing.expectEqual(@as(u8, '\n'), result[6]);
}

test "EdgeConverter invert option" {
    const allocator = std.testing.allocator;

    var pixels = [_]u8{255} ** 8;
    const test_image = Image{
        .data = &pixels,
        .width = 2,
        .height = 4,
        .bytes_per_row = 2,
    };

    var conv1 = try EdgeConverter.init(allocator, 128, false);
    defer conv1.converter().deinit();
    const result1 = try conv1.imageToText(test_image, 1, 1, allocator);
    defer allocator.free(result1);

    var conv2 = try EdgeConverter.init(allocator, 128, true);
    defer conv2.converter().deinit();
    const result2 = try conv2.imageToText(test_image, 1, 1, allocator);
    defer allocator.free(result2);

    try std.testing.expect(!std.mem.eql(u8, result1, result2));
}
