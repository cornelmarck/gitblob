const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("gitblob", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const httpz = b.dependency("httpz", .{
        .target = target,
        .optimize = optimize,
    });

    const libgit2 = b.dependency("libgit2", .{
        .target = target,
        .optimize = optimize,
    });
    const git2 = libgit2.artifact("git2");

    mod.linkLibrary(git2);

    const exe = b.addExecutable(.{
        .name = "gitblob",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "gitblob", .module = mod },
                .{ .name = "httpz", .module = httpz.module("httpz") },
            },
        }),
    });
    exe.root_module.linkLibrary(git2);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const run_mod_tests = b.addRunArtifact(b.addTest(.{ .root_module = mod }));
    const run_exe_tests = b.addRunArtifact(b.addTest(.{ .root_module = exe.root_module }));

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
