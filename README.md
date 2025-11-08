# termicam

<p align="center">
  <img src="assets/logo.png" alt="termicam logo" width="200">
</p>

A real-time camera viewer for your terminal. Watch yourself rendered as beautiful Braille patterns, right where you code.

## What It Does

termicam captures video from your macOS camera and transforms it into live terminal graphics using Unicode Braille characters. Each character encodes a 2×4 pixel grid, giving you 8× the resolution of traditional ASCII art. The result is a surprisingly detailed sketch-like representation that updates in real-time.

The edge detection algorithm emphasizes gradients and boundaries, producing clean, high-contrast output that looks great even on small terminal windows.

## Requirements

- macOS (uses AVFoundation framework)
- Zig 0.15.1 or later
- Camera permissions for your terminal application

**Recommended:** [Ghostty terminal](https://ghostty.org) for the best rendering quality and performance.

## Quick Start

```bash
git clone <repository-url>
cd termicam
zig build run
```

On first run, macOS will prompt you to grant camera permissions. Press `Ctrl+C` to exit.

## Build Options

termicam supports several compile-time configuration options:

```bash
# Capture strategy (default: pipelined)
zig build run -Dstrategy=direct      # Simple blocking capture
zig build run -Dstrategy=pipelined   # Double-buffered background thread

# Edge detection sensitivity 0-255 (default: 2, lower = more sensitive)
zig build run -Dedge-threshold=50

# Invert output (light dots on dark vs dark dots on light)
zig build run -Dinvert=true

# Camera warmup frames for auto-exposure (default: 3)
zig build run -Dwarmup-frames=5
```

Build for release with full optimizations:

```bash
zig build -Doptimize=ReleaseFast
./zig-out/bin/termicam
```

## How It Works

termicam operates through a three-stage pipeline:

1. **Capture**: An Objective-C++ wrapper around AVFoundation pulls frames from your camera as grayscale images
2. **Convert**: Each 2×4 pixel block is analyzed for edge gradients and mapped to a Unicode Braille character (U+2800-U+28FF)
3. **Render**: ANSI escape codes position the cursor and draw the frame, with optional FPS statistics in debug builds

The pipelined capture strategy runs frame acquisition in a background thread with double buffering, allowing the main thread to process and render the previous frame while the next one is being captured. This architectural choice eliminates capture latency from the critical path.

## Development

```bash
# Run the test suite
zig build test

# Clean build artifacts
rm -rf zig-out .zig-cache
```

## Technical Notes

termicam demonstrates several systems programming patterns in Zig:

- **FFI layering**: C API boundary between Objective-C++ (AVFoundation) and Zig
- **Vtable interfaces**: Generic `Converter` and `FrameSource` abstractions enable pluggable backends
- **Zero-copy rendering**: Buffered stdout with pre-allocated buffers minimizes allocations
- **Aspect ratio preservation**: Automatic calculation maintains 1:1 pixel scaling regardless of terminal dimensions

The modular architecture separates camera capture, rendering logic, and terminal utilities into independent modules with clear dependency boundaries. Each module includes comprehensive tests.
