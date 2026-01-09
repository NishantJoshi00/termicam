const std = @import("std");
const dith = @import("dith");
const camera = dith.camera;
const converter = dith.converter;
const term = dith.term;
const cli = dith.cli;
const image = dith.image;
const builtin = @import("builtin");

/// Generic frame source interface for pluggable capture strategies
const FrameSource = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        getNextFrame: *const fn (ptr: *anyopaque) camera.Image,
        deinit: *const fn (ptr: *anyopaque) void,
    };

    /// Get the next frame from this source
    pub fn getNextFrame(self: FrameSource) camera.Image {
        return self.vtable.getNextFrame(self.ptr);
    }

    /// Clean up frame source resources
    pub fn deinit(self: FrameSource) void {
        self.vtable.deinit(self.ptr);
    }
};

/// Direct (blocking) frame capture - original implementation
const DirectCapture = struct {
    camera: *camera.Camera,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, cam: *camera.Camera) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .camera = cam,
            .allocator = allocator,
        };
        return self;
    }

    pub fn frameSource(self: *Self) FrameSource {
        return .{
            .ptr = self,
            .vtable = &.{
                .getNextFrame = getNextFrameImpl,
                .deinit = deinitImpl,
            },
        };
    }

    fn getNextFrameImpl(ptr: *anyopaque) camera.Image {
        const self: *Self = @ptrCast(@alignCast(ptr));
        // Note: In real usage this can fail, but interface doesn't support errors
        // Caller should handle warmup/opening before using DirectCapture
        return self.camera.captureFrame() catch unreachable;
    }

    fn deinitImpl(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.allocator.destroy(self);
    }
};

/// Double-buffered frame pipeline that captures frames in background thread
/// while the main thread processes previously captured frames.
const PipelinedCapture = struct {
    camera: *camera.Camera,
    allocator: std.mem.Allocator,

    buffers: [2]OwnedImage,
    write_idx: usize,

    mutex: std.Thread.Mutex,
    capture_thread: std.Thread,
    should_stop: std.atomic.Value(bool),

    const OwnedImage = struct {
        data: []u8,
        width: u32,
        height: u32,
        bytes_per_row: u32,

        fn toImage(self: *const OwnedImage) camera.Image {
            return .{
                .data = self.data,
                .width = self.width,
                .height = self.height,
                .bytes_per_row = self.bytes_per_row,
            };
        }
    };

    const Self = @This();

    /// Initialize pipeline and start background capture thread
    pub fn init(allocator: std.mem.Allocator, cam: *camera.Camera) !*Self {
        const pipeline = try allocator.create(Self);
        errdefer allocator.destroy(pipeline);

        // Capture initial frame to determine buffer dimensions
        const initial_frame = try cam.captureFrame();
        const buf_size = initial_frame.bytes_per_row * initial_frame.height;

        // Allocate double buffers
        const buf0 = try allocator.alloc(u8, buf_size);
        errdefer allocator.free(buf0);
        const buf1 = try allocator.alloc(u8, buf_size);
        errdefer allocator.free(buf1);

        // Copy initial frame into first buffer
        @memcpy(buf0[0..initial_frame.data.len], initial_frame.data);

        pipeline.* = .{
            .camera = cam,
            .allocator = allocator,
            .buffers = .{
                .{
                    .data = buf0,
                    .width = initial_frame.width,
                    .height = initial_frame.height,
                    .bytes_per_row = initial_frame.bytes_per_row,
                },
                .{
                    .data = buf1,
                    .width = initial_frame.width,
                    .height = initial_frame.height,
                    .bytes_per_row = initial_frame.bytes_per_row,
                },
            },
            .write_idx = 0,
            .mutex = .{},
            .should_stop = std.atomic.Value(bool).init(false),
            .capture_thread = undefined,
        };

        // Start background capture thread
        pipeline.capture_thread = try std.Thread.spawn(.{}, captureLoop, .{pipeline});

        return pipeline;
    }

    /// Get FrameSource interface
    pub fn frameSource(self: *Self) FrameSource {
        return .{
            .ptr = self,
            .vtable = &.{
                .getNextFrame = getNextFrameImpl,
                .deinit = deinitImpl,
            },
        };
    }

    fn getNextFrameImpl(ptr: *anyopaque) camera.Image {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.mutex.lock();
        defer self.mutex.unlock();

        // Read from the buffer that's NOT being written to
        const read_idx = 1 - self.write_idx;
        return self.buffers[read_idx].toImage();
    }

    fn deinitImpl(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.should_stop.store(true, .release);
        self.capture_thread.join();

        self.allocator.free(self.buffers[0].data);
        self.allocator.free(self.buffers[1].data);
        self.allocator.destroy(self);
    }

    /// Background thread that continuously captures frames
    fn captureLoop(self: *Self) void {
        while (!self.should_stop.load(.acquire)) {
            // Capture frame (may fail, just continue to next iteration)
            const frame = self.camera.captureFrame() catch continue;

            self.mutex.lock();
            defer self.mutex.unlock();

            const idx = self.write_idx;
            const buf = &self.buffers[idx];

            // Copy frame data into our buffer
            @memcpy(buf.data[0..frame.data.len], frame.data);
            buf.width = frame.width;
            buf.height = frame.height;
            buf.bytes_per_row = frame.bytes_per_row;

            // Swap: this buffer is now ready, start writing to the other
            self.write_idx = 1 - self.write_idx;
        }
    }
};

/// Frame capture strategy selection
const CaptureStrategy = enum {
    direct, // Simple blocking capture (no pipelining)
    pipelined, // Double-buffered background thread
};

/// Initialize converter based on CLI mode selection
fn initConverter(mode: cli.Mode, allocator: std.mem.Allocator) !converter.Converter {
    return switch (mode) {
        .edge => |cfg| blk: {
            const conv = try converter.EdgeConverter.init(allocator, cfg.threshold, cfg.invert);
            break :blk conv.converter();
        },
        .atkinson => |cfg| blk: {
            const conv = try converter.AtkinsonConverter.init(allocator, cfg.threshold, cfg.invert);
            break :blk conv.converter();
        },
        .floyd_steinberg => |cfg| blk: {
            const conv = try converter.FloydSteinbergConverter.init(allocator, cfg.threshold, cfg.invert);
            break :blk conv.converter();
        },
        .blue_noise => |cfg| blk: {
            const conv = try converter.BlueNoiseConverter.init(allocator, cfg.threshold, cfg.invert);
            break :blk conv.converter();
        },
    };
}

pub fn main() !void {
    // Parse CLI arguments
    const args = cli.parse() catch |err| {
        cli.printErrorAndHelp(err);
        std.process.exit(1);
    } orelse {
        // Help was requested
        std.process.exit(0);
    };

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Get terminal size
    const term_size = try term.getTermSize();

    // Handle file source (static image, render once and exit)
    switch (args.source) {
        .file => |file_config| {
            var img = image.load(allocator, file_config.path) catch |err| {
                var buffer: [256]u8 = undefined;
                var writer = std.fs.File.stderr().writer(&buffer);
                const stderr = &writer.interface;
                const msg = switch (err) {
                    image.ImageError.LoadFailed => "error: failed to load image\n",
                    image.ImageError.OutOfMemory => "error: out of memory\n",
                };
                stderr.writeAll(msg) catch {};
                stderr.flush() catch {};
                std.process.exit(1);
            };
            defer img.deinit();

            // Initialize converter based on mode
            const conv = try initConverter(args.mode, allocator);
            defer conv.deinit();

            const frame = img.toImage();
            const dims = term.calculateBrailleDimensions(frame, term_size);
            const braille_text = try conv.convert(frame, dims.cols, dims.rows, allocator);
            defer allocator.free(braille_text);

            var stdout_buffer: [32768]u8 = undefined;
            var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
            const stdout = &stdout_writer.interface;

            try term.clearScreen(stdout);
            try stdout.writeAll(braille_text);
            try stdout.writeAll("\n");
            try stdout.flush();

            return;
        },
        .cam => {}, // Continue below
    }

    // Camera source
    const cam_config = args.source.cam;

    // Initialize camera
    var cam = try camera.Camera.init();
    defer cam.deinit();

    // Open camera
    try cam.open();
    defer cam.close();

    // Initialize converter based on mode
    const conv = try initConverter(args.mode, allocator);
    defer conv.deinit();

    // Warmup: Capture and discard frames to let camera auto-expose
    var i: u32 = 0;
    while (i < cam_config.warmup) : (i += 1) {
        _ = try cam.captureFrame();
    }

    // Initialize frame source based on CLI strategy configuration
    const source = switch (cam_config.strategy) {
        .direct => blk: {
            var direct = try DirectCapture.init(allocator, &cam);
            break :blk direct.frameSource();
        },
        .pipelined => blk: {
            var pipeline = try PipelinedCapture.init(allocator, &cam);
            break :blk pipeline.frameSource();
        },
    };
    defer source.deinit();

    // Setup buffered stdout writer (reused across frames)
    // Use larger buffer to accommodate full-screen Braille output (160x45 = ~22KB)
    var stdout_buffer: [32768]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    // Target 60 FPS: 1/60 second = 16.666ms = 16,666,666 nanoseconds
    const target_frame_time_ns: i128 = 16_666_666;

    // Continuous frame loop
    while (true) {
        // Start timing
        const start_time = std.time.nanoTimestamp();

        // Get next frame (captured in background thread)
        const frame = source.getNextFrame();

        // Calculate output dimensions that fit within terminal bounds
        const dims = term.calculateBrailleDimensions(frame, term_size);

        // Convert to Braille (with optional timing for debug builds)
        const convert_start = if (builtin.mode == .Debug) std.time.nanoTimestamp() else 0;
        const braille_text = try conv.convert(frame, dims.cols, dims.rows, allocator);
        const convert_end = if (builtin.mode == .Debug) std.time.nanoTimestamp() else 0;
        defer allocator.free(braille_text);

        // Clear screen right before rendering
        try term.clearScreen(stdout);

        // Print the frame
        try stdout.writeAll(braille_text);

        // Capture time after rendering (before debug output)
        const render_end = if (builtin.mode == .Debug) std.time.nanoTimestamp() else 0;

        // Print debug timing info (only in debug builds)
        if (builtin.mode == .Debug) {
            const convert_ms = @as(f64, @floatFromInt(convert_end - convert_start)) / 1_000_000.0;
            const render_ms = @as(f64, @floatFromInt(render_end - convert_end)) / 1_000_000.0;
            const total_ms = @as(f64, @floatFromInt(render_end - start_time)) / 1_000_000.0;
            const fps = 1000.0 / total_ms;
            try stdout.print("\nFPS: {d:.1} | Convert: {d:.1}ms | Render: {d:.1}ms | Total: {d:.1}ms\n", .{ fps, convert_ms, render_ms, total_ms });
        }

        try stdout.flush();

        // FPS capping: sleep for remaining time to achieve 60 FPS
        const frame_time = std.time.nanoTimestamp() - start_time;
        if (frame_time < target_frame_time_ns) {
            const sleep_time_ns = target_frame_time_ns - frame_time;
            std.Thread.sleep(@intCast(sleep_time_ns));
        }
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
