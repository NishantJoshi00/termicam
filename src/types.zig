const std = @import("std");

/// Image data (grayscale)
pub const Image = struct {
    data: []const u8,
    width: u32,
    height: u32,
    bytes_per_row: u32,

    /// Get pixel value at (x, y)
    /// Inline for performance in tight rendering loops
    pub inline fn getPixel(self: Image, x: u32, y: u32) u8 {
        std.debug.assert(x < self.width);
        std.debug.assert(y < self.height);
        const offset = y * self.bytes_per_row + x;
        return self.data[offset];
    }
};

/// Supported image formats
pub const ImageFormat = enum {
    png,
    jpeg,
    bmp,
    unknown,
};
