const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Main replica binary
    const exe = b.addExecutable(.{
        .name = "tigerchat",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);

    // Run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run replica");
    run_step.dependOn(&run_cmd.step);

    // Operator CLI
    const cli = b.addExecutable(.{
        .name = "tigerctl",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli/tigerctl.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(cli);

    const cli_run = b.addRunArtifact(cli);
    if (b.args) |args| cli_run.addArgs(args);
    const cli_step = b.step("tigerctl", "Run CLI");
    cli_step.dependOn(&cli_run.step);

    // Tests
    const test_step = b.step("test", "Run tests");
    const main_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(main_tests).step);
}
