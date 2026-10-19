const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const benchz = b.addModule("benchz", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_filters = b.option([]const []const u8, "test-filter", "Skip tests that do not match any filter") orelse &.{};

    const test_step = b.step("test", "Run unit tests");
    const unit_tests = b.addTest(.{
        .root_module = benchz,
        .filters = test_filters,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    test_step.dependOn(&run_unit_tests.step);

    const example_step = b.step("example", "Run example micro benchmarks");
    const example_exe = b.addExecutable(.{
        .name = "example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/micro_benchmarks.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{
                    .name = "benchz",
                    .module = benchz,
                },
            },
        }),
    });
    const example_install = b.addInstallArtifact(example_exe, .{});
    const example_run = b.addRunArtifact(example_exe);
    example_step.dependOn(&example_install.step);
    example_step.dependOn(&example_run.step);
    b.getInstallStep().dependOn(&example_install.step);
}
