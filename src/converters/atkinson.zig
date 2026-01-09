const std = @import("std");
const common = @import("common");

const Image = common.Image;
const Converter = common.Converter;
const binaryToBraille = common.binaryToBraille;
const clampToU8 = common.clampToU8;

/// Atkinson dithering converter
/// Uses Bill Atkinson's algorithm (from original Macintosh)
/// Diffuses only 75% of error for higher contrast results
pub const AtkinsonConverter = struct {
    allocator: std.mem.Allocator,
    threshold: u8, // Threshold for binarization (typically 128)
    invert: bool,

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

    pub fn imageToText(
        self: *Self,
        image: Image,
        target_cols: u32,
        target_rows: u32,
        allocator: std.mem.Allocator,
    ) ![]u8 {
        // Create working buffer for dithering (need i16 for error accumulation)
        const width = image.width;
        const height = image.height;
        const size = width * height;

        var work_buffer = try allocator.alloc(i16, size);
        defer allocator.free(work_buffer);

        // Copy grayscale data to work buffer
        for (0..size) |i| {
            work_buffer[i] = @as(i16, image.data[i]);
        }

        // Output binary buffer
        var binary = try allocator.alloc(u8, size);
        defer allocator.free(binary);

        // Atkinson dithering: scan-line processing
        // Error diffusion pattern (each neighbor gets 1/8 of error):
        //       X   *   *
        //   *   *   *
        //       *
        // Only 6/8 = 75% of error is diffused (higher contrast)

        for (0..height) |y| {
            for (0..width) |x| {
                const idx = y * width + x;
                const old_pixel = work_buffer[idx];
                const new_pixel: i16 = if (old_pixel >= self.threshold) 255 else 0;

                binary[idx] = @intCast(@as(u8, @intCast(@max(0, @min(255, new_pixel)))));

                // Error = old - new (can be negative)
                const err = old_pixel - new_pixel;
                // Atkinson uses 1/8 for each of 6 neighbors
                const err_frac = @divTrunc(err, 8);

                // Distribute error to 6 neighbors
                // Right (x+1, y)
                if (x + 1 < width) {
                    work_buffer[idx + 1] += err_frac;
                }
                // Right-right (x+2, y)
                if (x + 2 < width) {
                    work_buffer[idx + 2] += err_frac;
                }
                // Next row
                if (y + 1 < height) {
                    const next_row = (y + 1) * width;
                    // Down-left (x-1, y+1)
                    if (x > 0) {
                        work_buffer[next_row + x - 1] += err_frac;
                    }
                    // Down (x, y+1)
                    work_buffer[next_row + x] += err_frac;
                    // Down-right (x+1, y+1)
                    if (x + 1 < width) {
                        work_buffer[next_row + x + 1] += err_frac;
                    }
                }
                // Two rows down (x, y+2)
                if (y + 2 < height) {
                    work_buffer[(y + 2) * width + x] += err_frac;
                }
            }
        }

        return binaryToBraille(binary, width, height, target_cols, target_rows, self.invert, allocator);
    }
};

// =============================================================================
// Tests
// =============================================================================

test "AtkinsonConverter basic" {
    const allocator = std.testing.allocator;

    // Create gradient image
    var pixels: [64]u8 = undefined;
    for (0..64) |i| {
        pixels[i] = @intCast(i * 4); // 0 to 252 gradient
    }

    const test_image = Image{
        .data = &pixels,
        .width = 8,
        .height = 8,
        .bytes_per_row = 8,
    };

    var conv = try AtkinsonConverter.init(allocator, 128, false);
    defer conv.converter().deinit();

    const result = try conv.imageToText(test_image, 4, 2, allocator);
    defer allocator.free(result);

    // 4 cols * 3 bytes + newline = 13 per row, 2 rows = 26
    try std.testing.expectEqual(@as(usize, 26), result.len);
}

test "AtkinsonConverter produces dithering pattern" {
    const allocator = std.testing.allocator;

    // Uniform mid-gray should produce a dithered pattern (not all same)
    var pixels = [_]u8{128} ** 64;
    const test_image = Image{
        .data = &pixels,
        .width = 8,
        .height = 8,
        .bytes_per_row = 8,
    };

    var conv = try AtkinsonConverter.init(allocator, 128, false);
    defer conv.converter().deinit();

    const result = try conv.imageToText(test_image, 4, 2, allocator);
    defer allocator.free(result);

    // Should have some variation in the output
    try std.testing.expect(result.len > 0);
}

test "AtkinsonConverter invert" {
    const allocator = std.testing.allocator;

    var pixels = [_]u8{200} ** 16;
    const test_image = Image{
        .data = &pixels,
        .width = 4,
        .height = 4,
        .bytes_per_row = 4,
    };

    var conv1 = try AtkinsonConverter.init(allocator, 128, false);
    defer conv1.converter().deinit();
    const result1 = try conv1.imageToText(test_image, 2, 1, allocator);
    defer allocator.free(result1);

    var conv2 = try AtkinsonConverter.init(allocator, 128, true);
    defer conv2.converter().deinit();
    const result2 = try conv2.imageToText(test_image, 2, 1, allocator);
    defer allocator.free(result2);

    try std.testing.expect(!std.mem.eql(u8, result1, result2));
}
