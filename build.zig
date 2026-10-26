const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = target.result.os.tag != .windows,
        .strip = optimize == .small,
    });
    const exe = b.addExecutable(.{ .name = "shell-buddy", .root_module = module });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run Shell Buddy").dependOn(&run.step);
    const tests = b.addTest(.{ .root_module = module });
    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(tests).step);
    const update_driver = b.addExecutable(.{ .name = "update-driver", .root_module = b.createModule(.{
        .root_source_file = b.path("tests/update_driver.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = target.result.os.tag != .windows,
        .imports = &.{.{ .name = "updater", .module = b.createModule(.{ .root_source_file = b.path("src/update.zig"), .target = target, .optimize = optimize }) }},
    }) });
    b.step("build-update-tests", "Build the isolated self-update test driver").dependOn(&b.addInstallArtifact(update_driver, .{}).step);
}
