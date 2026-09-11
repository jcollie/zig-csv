// SPDX-FileCopyrightText: © 2020-2024 @_beho
// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

const std = @import("std");

pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const csv_module = b.addModule("csv", .{
        .root_source_file = b.path("src/main.zig"),
    });

    const csv_tests = b.addTest(.{
        .name = "tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/csv_tokenizer.zig"),
            .optimize = optimize,
            .target = target,
        }),
    });
    csv_tests.root_module.addImport("csv", csv_module);

    const run_test_cmd = b.addRunArtifact(csv_tests);
    run_test_cmd.has_side_effects = true;
    run_test_cmd.step.dependOn(b.getInstallStep());

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_test_cmd.step);

    // The fuzz targets are a module of their own so that the test runner and
    // the standalone driver can both reach them.
    const fuzz_module = b.createModule(.{
        .root_source_file = b.path("test/fuzz.zig"),
        .target = target,
        .optimize = optimize,
    });
    fuzz_module.addImport("csv", csv_module);

    // Runs the targets over a fixed corpus, so that they cannot rot between
    // fuzzing sessions.
    const fuzz_tests = b.addTest(.{ .name = "fuzz-tests", .root_module = fuzz_module });
    test_step.dependOn(&b.addRunArtifact(fuzz_tests).step);

    const fuzz_driver = b.addExecutable(.{
        .name = "fuzz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/fuzz.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    fuzz_driver.root_module.addImport("fuzz", fuzz_module);

    const run_fuzz = b.addRunArtifact(fuzz_driver);
    if (b.args) |args| run_fuzz.addArgs(args);
    run_fuzz.stdio = .inherit;

    const fuzz_step = b.step("fuzz", "Run the fuzzing loop (-- --iterations N --seed N --target NAME)");
    fuzz_step.dependOn(&run_fuzz.step);

    // Nothing else builds the driver, so without this it could stop
    // compiling and no test would notice.
    test_step.dependOn(&fuzz_driver.step);

    const bench_module = b.createModule(.{
        .root_source_file = b.path("tools/bench.zig"),
        .target = target,
        // Benchmarking a Debug build measures the safety checks, not the
        // tokenizer, so this one is always optimized.
        .optimize = .ReleaseFast,
    });
    bench_module.addImport("csv", csv_module);

    const bench = b.addExecutable(.{ .name = "bench", .root_module = bench_module });

    const run_bench = b.addRunArtifact(bench);
    if (b.args) |args| run_bench.addArgs(args);
    run_bench.stdio = .inherit;

    const bench_step = b.step("bench", "Run the throughput benchmarks (-- --seconds N --buffer N --case NAME)");
    bench_step.dependOn(&run_bench.step);

    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = bench_module })).step);
}
