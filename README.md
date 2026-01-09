# dith

<p align="center">
  <img src="assets/logo.png" alt="dith logo" width="200">
</p>

A universal dithering tool for the terminal. Plug in any source, pick a mode, get beautiful Braille output.

## What You Can Do

**Dither anything to Braille art:**

```bash
# Live camera feed
dith +source=cam +mode=atkinson

# Any image file
dith +source=file +mode=blue_noise +path=photo.png
```

**5 rendering modes, each with its own character:**

| Mode | Best For |
|------|----------|
| `edge` | Line art, sketches, outlines |
| `atkinson` | High contrast, classic Mac aesthetic |
| `floyd_steinberg` | Photos, smooth gradients |
| `blue_noise` | Organic, film-grain look |
| `bayer` | Retro 8-bit, crosshatch pattern |

**Fine-tune the output:**

```bash
# Adjust sensitivity
dith +source=cam +mode=edge +threshold=50

# Invert colors
dith +source=file +mode=bayer +path=image.jpg +invert
```

## Install

```bash
git clone https://github.com/user/dith
cd dith
zig build -Doptimize=ReleaseFast
```

Binary is at `./zig-out/bin/dith`

**Requirements:** Zig 0.15.1+, macOS (for camera)

## Usage

```
dith +source=<SOURCE> +mode=<MODE> [options...]
```

### Sources

**Camera** - live feed from your webcam
```bash
dith +source=cam +mode=edge
dith +source=cam +mode=atkinson +warmup=5      # more warmup frames
dith +source=cam +mode=blue_noise +strategy=direct   # no background capture
```

**File** - PNG, JPEG, or BMP
```bash
dith +source=file +mode=floyd_steinberg +path=photo.png
dith +source=file +mode=bayer +path=~/Downloads/image.jpg +invert
```

### Options

| Option | Description | Default |
|--------|-------------|---------|
| `+threshold=N` | Sensitivity 0-255 | varies by mode |
| `+invert` | Flip black/white | off |
| `+warmup=N` | Camera warmup frames | 3 |
| `+strategy=` | `pipelined` or `direct` | pipelined |

## Examples

```bash
# Sketch-like edge detection
dith +source=file +mode=edge +path=drawing.png +threshold=5

# Classic Macintosh dithering
dith +source=file +mode=atkinson +path=photo.jpg

# Smooth photo dithering
dith +source=cam +mode=floyd_steinberg +threshold=140

# Cinematic grain
dith +source=file +mode=blue_noise +path=portrait.png

# Retro game aesthetic
dith +source=cam +mode=bayer +invert
```

## Contributing

```bash
# Run tests
zig build test

# Build debug
zig build

# Build and run
zig build run -- +source=cam +mode=edge
```

PRs welcome. The converter system is modular - adding a new dithering algorithm is straightforward.
