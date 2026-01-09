const std = @import("std");
const types = @import("types");

pub const Image = types.Image;

// =============================================================================
// Braille Constants
// =============================================================================

/// Braille dot positions for 2x4 grid (compile-time constant)
/// Maps each of 8 dots to their (x, y) position within the 2x4 Braille cell
pub const BRAILLE_DOT_POSITIONS = [8][2]u32{
    .{ 0, 0 }, // Dot 1 (bit 0x01)
    .{ 0, 1 }, // Dot 2 (bit 0x02)
    .{ 0, 2 }, // Dot 3 (bit 0x04)
    .{ 1, 0 }, // Dot 4 (bit 0x08)
    .{ 1, 1 }, // Dot 5 (bit 0x10)
    .{ 1, 2 }, // Dot 6 (bit 0x20)
    .{ 0, 3 }, // Dot 7 (bit 0x40)
    .{ 1, 3 }, // Dot 8 (bit 0x80)
};

/// Braille pattern bit positions layout:
/// 1 4   (0x01 0x08)
/// 2 5   (0x02 0x10)
/// 3 6   (0x04 0x20)
/// 7 8   (0x40 0x80)

// =============================================================================
// UTF-8 Encoding
// =============================================================================

/// Encode a Braille Unicode codepoint to UTF-8
/// Braille patterns (U+2800-U+28FF) always encode to 3 bytes
/// Inline for performance as this is called for every character
pub inline fn encodeUtf8Braille(codepoint: u21, buffer: []u8) usize {
    std.debug.assert(codepoint >= 0x2800 and codepoint <= 0x28FF);
    std.debug.assert(buffer.len >= 3);

    // UTF-8 encoding for 3-byte sequence (U+0800 to U+FFFF):
    // 1110xxxx 10xxxxxx 10xxxxxx
    buffer[0] = 0xE0 | @as(u8, @intCast((codepoint >> 12) & 0x0F));
    buffer[1] = 0x80 | @as(u8, @intCast((codepoint >> 6) & 0x3F));
    buffer[2] = 0x80 | @as(u8, @intCast(codepoint & 0x3F));

    return 3;
}

// =============================================================================
// Converter Interface
// =============================================================================

/// Generic converter interface for pluggable rendering backends
pub const Converter = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        convert: *const fn (ptr: *anyopaque, image: Image, target_cols: u32, target_rows: u32, allocator: std.mem.Allocator) anyerror![]u8,
        deinit: *const fn (ptr: *anyopaque) void,
    };

    /// Convert image to text representation
    pub fn convert(self: Converter, image: Image, target_cols: u32, target_rows: u32, allocator: std.mem.Allocator) ![]u8 {
        return self.vtable.convert(self.ptr, image, target_cols, target_rows, allocator);
    }

    /// Clean up converter resources
    pub fn deinit(self: Converter) void {
        self.vtable.deinit(self.ptr);
    }
};

// =============================================================================
// Shared Utilities
// =============================================================================

/// Absolute difference between two u8 values
/// Uses branchless implementation for better performance in hot loops
pub inline fn absDiff(a: u8, b: u8) u32 {
    const diff: i32 = @as(i32, a) - @as(i32, b);
    return @abs(diff);
}

/// Clamp i32 to u8 range (0-255)
pub inline fn clampToU8(value: i32) u8 {
    if (value < 0) return 0;
    if (value > 255) return 255;
    return @intCast(value);
}

/// Convert binary buffer to Braille text output
/// binary_data: width x height buffer where 0 = off, non-zero = on
/// Each Braille character represents a 2x4 pixel grid
pub fn binaryToBraille(
    binary_data: []const u8,
    width: u32,
    height: u32,
    target_cols: u32,
    target_rows: u32,
    invert: bool,
    allocator: std.mem.Allocator,
) ![]u8 {
    // Calculate scaling factors
    const scale_x = @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(target_cols * 2));
    const scale_y = @as(f32, @floatFromInt(height)) / @as(f32, @floatFromInt(target_rows * 4));

    // Each Braille char is 3 bytes in UTF-8, plus newline per row
    const bytes_per_row = target_cols * 3 + 1;
    const total_bytes = target_rows * bytes_per_row;

    var buffer = try allocator.alloc(u8, total_bytes);
    var buf_offset: usize = 0;

    var row: u32 = 0;
    while (row < target_rows) : (row += 1) {
        var col: u32 = 0;
        while (col < target_cols) : (col += 1) {
            var pattern: u8 = 0;

            const base_out_x = col * 2;
            const base_out_y = row * 4;

            for (BRAILLE_DOT_POSITIONS, 0..) |pos, i| {
                const out_x = base_out_x + pos[0];
                const out_y = base_out_y + pos[1];

                const src_x = @as(u32, @intFromFloat(@as(f32, @floatFromInt(out_x)) * scale_x));
                const src_y = @as(u32, @intFromFloat(@as(f32, @floatFromInt(out_y)) * scale_y));

                if (src_x < width and src_y < height) {
                    const idx = src_y * width + src_x;
                    var is_set = binary_data[idx] != 0;
                    if (invert) is_set = !is_set;
                    if (is_set) {
                        pattern |= @as(u8, 1) << @intCast(i);
                    }
                }
            }

            const braille_char: u21 = 0x2800 + @as(u21, pattern);
            buf_offset += encodeUtf8Braille(braille_char, buffer[buf_offset..]);
        }

        buffer[buf_offset] = '\n';
        buf_offset += 1;
    }

    return buffer;
}

// =============================================================================
// Tests
// =============================================================================

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

test "absDiff utility" {
    try std.testing.expectEqual(@as(u32, 10), absDiff(20, 10));
    try std.testing.expectEqual(@as(u32, 10), absDiff(10, 20));
    try std.testing.expectEqual(@as(u32, 0), absDiff(50, 50));
    try std.testing.expectEqual(@as(u32, 255), absDiff(255, 0));
}

test "clampToU8" {
    try std.testing.expectEqual(@as(u8, 0), clampToU8(-100));
    try std.testing.expectEqual(@as(u8, 0), clampToU8(0));
    try std.testing.expectEqual(@as(u8, 128), clampToU8(128));
    try std.testing.expectEqual(@as(u8, 255), clampToU8(255));
    try std.testing.expectEqual(@as(u8, 255), clampToU8(300));
}
