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
}
