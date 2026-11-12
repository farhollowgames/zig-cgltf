//! Seeded fuzzing: each case gets its own seed, printed when it fails.
//! `-Dfuzz-seed=N` runs other cases; `-Dfuzz-replay=S` runs only seed S.

const std = @import("std");
const test_options = @import("test_options");

/// Runs `cases` cases of `case`, each with a generator seeded from the
/// test's name, the case's number and `-Dfuzz-seed`.
pub fn run(comptime name: []const u8, cases: usize, comptime case: fn (std.Random) anyerror!void) !void {
    const base = std.hash.Wyhash.hash(0, name) +% test_options.fuzz_seed *% 0x9E3779B97F4A7C15;
    if (test_options.fuzz_replay) |seed| return runSeed(name, seed, case);
    for (0..cases) |i| try runSeed(name, base +% i, case);
}

fn runSeed(comptime name: []const u8, seed: u64, comptime case: fn (std.Random) anyerror!void) !void {
    var prng: std.Random.DefaultPrng = .init(seed);
    case(prng.random()) catch |err| {
        std.debug.print("fuzz {s}: seed {d} failed (rerun with -Dfuzz-replay={d})\n", .{ name, seed, seed });
        return err;
    };
}
