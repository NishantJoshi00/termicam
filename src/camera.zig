const std = @import("std");

// Import C API
const c = @cImport({
    @cInclude("camera_wrapper.h");
});

/// Error types for camera operations
pub const CameraError = error{
    InitFailed,
    NoDevice,
    PermissionDenied,
    SessionError,
    CaptureFailed,
    NotOpen,
    AlreadyOpen,
    Unknown,
};

/// Image data captured from camera (grayscale)
pub const Image = struct {
    data: []const u8,
    width: u32,
    height: u32,
    bytes_per_row: u32,

    /// Get pixel value at (x, y)
    pub fn getPixel(self: Image, x: u32, y: u32) u8 {
        std.debug.assert(x < self.width);
        std.debug.assert(y < self.height);
        const offset = y * self.bytes_per_row + x;
        return self.data[offset];
    }
};

/// Camera handle for capturing images
pub const Camera = struct {
    handle: c.CameraHandle,

    /// Create a new camera instance
    pub fn init() !Camera {
        const handle = c.camera_create();
        if (handle == null) {
            return CameraError.InitFailed;
        }
        return Camera{ .handle = handle };
    }

    /// Destroy the camera and free resources
    pub fn deinit(self: *Camera) void {
        c.camera_destroy(self.handle);
        self.handle = null;
    }

    /// Open the camera and start the capture session
    pub fn open(self: *Camera) !void {
        const result = c.camera_open(self.handle);
        try cameraErrorFromC(result);
    }

    /// Close the camera and stop the capture session
    pub fn close(self: *Camera) void {
        c.camera_close(self.handle);
    }

    /// Capture a single frame from the camera
    /// The returned image is valid until the next capture or close
    pub fn captureFrame(self: *Camera) !Image {
        var c_image: c.CameraImage = undefined;
        const result = c.camera_capture_frame(self.handle, &c_image);
        try cameraErrorFromC(result);

        return Image{
            .data = c_image.data[0..(c_image.bytes_per_row * c_image.height)],
            .width = c_image.width,
            .height = c_image.height,
            .bytes_per_row = c_image.bytes_per_row,
        };
    }

    /// Check if the camera is currently open
    pub fn isOpen(self: *Camera) bool {
        return c.camera_is_open(self.handle);
    }
};

/// Convert C error code to Zig error
fn cameraErrorFromC(code: c.CameraError) !void {
    switch (code) {
        c.CAMERA_OK => return,
        c.CAMERA_ERROR_INIT => return CameraError.InitFailed,
        c.CAMERA_ERROR_NO_DEVICE => return CameraError.NoDevice,
        c.CAMERA_ERROR_PERMISSION => return CameraError.PermissionDenied,
        c.CAMERA_ERROR_SESSION => return CameraError.SessionError,
        c.CAMERA_ERROR_CAPTURE => return CameraError.CaptureFailed,
        c.CAMERA_ERROR_NOT_OPEN => return CameraError.NotOpen,
        c.CAMERA_ERROR_ALREADY_OPEN => return CameraError.AlreadyOpen,
        else => return CameraError.Unknown,
    }
}

test "camera creation" {
    var camera = try Camera.init();
    defer camera.deinit();
    try std.testing.expect(camera.handle != null);
}
