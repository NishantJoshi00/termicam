//! By convention, root.zig is the root source file when making a library.
//! This module aggregates and re-exports all termicam submodules.

// Import all submodules
pub const camera = @import("camera");
pub const ascii = @import("ascii");
pub const term = @import("term");
