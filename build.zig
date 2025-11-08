const std = @import("std");

/// Configure build-time options for the termicam executable
fn configureBuildOptions(b: *std.Build) *std.Build.Step.Options {
    const options = b.addOptions();

    // Capture strategy: direct (blocking) or pipelined (double-buffered)
    const strategy = b.option(
        enum { direct, pipelined },
        "strategy",
        "Frame capture strategy: direct or pipelined (default: pipelined)",
    ) orelse .pipelined;
    options.addOption(@TypeOf(strategy), "capture_strategy", strategy);

    // Edge detection threshold (0-255, lower = more sensitive)
    const edge_threshold = b.option(
        u8,
        "edge-threshold",
        "Edge detection sensitivity threshold 0-255 (default: 2)",
    ) orelse 2;
    options.addOption(u8, "edge_threshold", edge_threshold);

    // Invert Braille pattern (light on dark vs dark on light)
    const invert = b.option(
        bool,
        "invert",
        "Invert Braille output (default: false)",
    ) orelse false;
    options.addOption(bool, "invert", invert);

    // Camera warmup frames to discard for auto-exposure
    const warmup_frames = b.option(
        u32,
        "warmup-frames",
        "Number of warmup frames for camera auto-exposure (default: 3)",
    ) orelse 3;
    options.addOption(u32, "warmup_frames", warmup_frames);

    return options;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

    // Base module: camera (no dependencies)
    const camera_mod = b.addModule("camera", .{
        .root_source_file = b.path("src/camera.zig"),
        .target = target,
    });
    camera_mod.addIncludePath(b.path("deps"));
    camera_mod.addCSourceFile(.{
        .file = b.path("deps/camera_wrapper.mm"),
        .flags = &[_][]const u8{ "-ObjC++", "-fno-objc-arc" },
    });

    camera_mod.link_libcpp = true;

    camera_mod.linkFramework("AVFoundation", .{});
    camera_mod.linkFramework("CoreMedia", .{});
    camera_mod.linkFramework("CoreVideo", .{});
    camera_mod.linkFramework("Foundation", .{});

    // ASCII module (depends on camera)
    const ascii_mod = b.addModule("ascii", .{
        .root_source_file = b.path("src/ascii.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "camera", .module = camera_mod },
        },
    });

    // Terminal module (depends on camera)
    const term_mod = b.addModule("term", .{
        .root_source_file = b.path("src/term.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "camera", .module = camera_mod },
        },
    });

    // Main library module: termicam (aggregates all submodules)
    const mod = b.addModule("termicam", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "camera", .module = camera_mod },
            .{ .name = "ascii", .module = ascii_mod },
            .{ .name = "term", .module = term_mod },
        },
    });

    // Configure build-time options
    const options = configureBuildOptions(b);

    const exe = b.addExecutable(.{
        .name = "termicam",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),

            .target = target,
            .optimize = optimize,

            .imports = &.{
                .{ .name = "termicam", .module = mod },
                .{ .name = "build_options", .module = options.createModule() },
            },
        }),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Camera module tests
    const camera_tests = b.addTest(.{
        .root_module = camera_mod,
    });
    const run_camera_tests = b.addRunArtifact(camera_tests);

    // ASCII module tests
    const ascii_tests = b.addTest(.{
        .root_module = ascii_mod,
    });
    const run_ascii_tests = b.addRunArtifact(ascii_tests);

    // Terminal module tests
    const term_tests = b.addTest(.{
        .root_module = term_mod,
    });
    const run_term_tests = b.addRunArtifact(term_tests);

    // Main termicam module tests
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_camera_tests.step);
    test_step.dependOn(&run_ascii_tests.step);
    test_step.dependOn(&run_term_tests.step);
    test_step.dependOn(&run_mod_tests.step);
}
