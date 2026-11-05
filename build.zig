//! Builds typebox: `zig build check` is its gate — its sources formatted, its tests run — and `zig build test` runs the
//! tests alone. It depends on Zig's standard library alone.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const typebox = b.addModule("typebox", .{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = optimize });

    const tests = b.addTest(.{ .root_module = typebox });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run typebox's tests");
    test_step.dependOn(&run_tests.step);

    const format = b.addFmt(.{ .paths = &.{ b.path("build.zig"), b.path("src") }, .check = true });
    const check_step = b.step("check", "Check typebox: its sources formatted and its tests passing");
    check_step.dependOn(&format.step);
    check_step.dependOn(&run_tests.step);
}
