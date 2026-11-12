//! Differential tests: the port against the original built from
//! reference/, on the sample models, hand-made edge cases and fuzzed
//! input. Any differing field, byte, index, float bit or result fails.

comptime {
    _ = @import("samples_test.zig");
    _ = @import("edges_test.zig");
    _ = @import("functions_test.zig");
}
