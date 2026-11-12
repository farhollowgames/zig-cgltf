const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    _ = b.addModule("cgltf", .{
        .root_source_file = b.path("src/cgltf.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Tests default to ReleaseSafe: every sample model through every
    // accessor takes long in Debug, and ReleaseSafe keeps every assert and
    // overflow check on.
    const test_optimize = b.option(
        std.lang.Optimize,
        "test-optimize",
        "Optimize mode for the tests (default ReleaseSafe)",
    ) orelse .safe;
    const test_filters = b.option(
        []const []const u8,
        "test-filter",
        "Skip tests that do not match any filter",
    ) orelse &.{};
    const fuzz_seed = b.option(
        u64,
        "fuzz-seed",
        "Offset every fuzz test's seeds, to run other cases (default 0)",
    ) orelse 0;
    const fuzz_replay = b.option(u64, "fuzz-replay", "Run only this seed in each fuzz test");

    const cgltf_test_mod = b.createModule(.{
        .root_source_file = b.path("src/cgltf.zig"),
        .target = target,
        .optimize = test_optimize,
    });

    const test_step = b.step("test", "Run unit and differential tests");
    const unit_tests = b.addTest(.{ .root_module = cgltf_test_mod, .filters = test_filters });
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);

    const bench_step = b.step("bench", "Time the port against the original (ReleaseFast)");

    // The original and the sample models are only for the differential
    // tests and the benchmark, and never for a package that depends on
    // this one.
    if (!b.isRoot()) return;
    const samples = b.lazyDependency("gltf_sample_assets", .{}) orelse return;

    const test_options = b.addOptions();
    test_options.addOption(u64, "fuzz_seed", fuzz_seed);
    test_options.addOption(?u64, "fuzz_replay", fuzz_replay);
    test_options.addOptionPath("models", samples.path("Models"));
    test_options.addOptionPath("reference", b.path("reference/cgltf"));
    const test_options_mod = test_options.createModule();

    const differential = b.addTest(.{
        .name = "differential",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/differential.zig"),
            .target = target,
            .optimize = test_optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "cgltf", .module = cgltf_test_mod },
                .{ .name = "c", .module = upstreamHeader(b, target, test_optimize) },
                .{ .name = "test_options", .module = test_options_mod },
            },
        }),
        .filters = test_filters,
    });
    differential.root_module.linkLibrary(upstreamLibrary(b, target, "cgltf_reference"));
    test_step.dependOn(&b.addRunArtifact(differential).step);

    const bench = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/bench.zig"),
            .target = target,
            .optimize = .fast,
            .link_libc = true,
            .imports = &.{
                .{ .name = "cgltf", .module = b.createModule(.{
                    .root_source_file = b.path("src/cgltf.zig"),
                    .target = target,
                    .optimize = .fast,
                }) },
                .{ .name = "c", .module = upstreamHeader(b, target, .fast) },
                .{ .name = "test_options", .module = test_options_mod },
            },
        }),
    });
    bench.root_module.linkLibrary(upstreamLibrary(b, target, "cgltf_reference_bench"));
    const run_bench = b.addRunArtifact(bench);
    run_bench.addPassthruArgs();
    bench_step.dependOn(&run_bench.step);
    bench_step.dependOn(&b.addInstallArtifact(bench, .{}).step);
}

/// cgltf.h as Zig declarations, for the tests to call the original.
fn upstreamHeader(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
) *std.Build.Module {
    const translate = b.addTranslateC(.{
        .root_source_file = b.path("reference/cgltf/cgltf.h"),
        .target = target,
        .optimize = optimize,
    });
    return translate.createModule();
}

/// The original as a static library: cgltf.h with its implementation,
/// at -O3 (Zig's ReleaseFast gives C -O2), linked with the C library
/// whose atoi, atoll and atof it reads numbers with. Fused multiply-adds
/// are off so its floats round as written, as Zig's do.
fn upstreamLibrary(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    name: []const u8,
) *std.Build.Step.Compile {
    const library = b.addLibrary(.{
        .name = name,
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = .fast,
            .link_libc = true,
        }),
    });
    library.root_module.addIncludePath(b.path("reference/cgltf"));
    library.root_module.addCSourceFile(.{
        .file = b.path("reference/shim/cgltf.c"),
        .flags = &.{ "-O3", "-std=c99", "-ffp-contract=off", "-fno-fast-math" },
    });
    return library;
}
