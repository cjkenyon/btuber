const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Version string. Prefer an explicit -Dversion=... (handy for CI), but
    // otherwise derive one from `git describe` so dev builds carry a sha and
    // tagged commits show the tag. Falls back to "unknown" if neither works.
    const version = b.option([]const u8, "version", "Override the embedded version string") orelse describeGitVersion(b);

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", version);

    const raylib_dep = b.dependency("raylib", .{
        .target = target,
        .optimize = optimize,
    });
    const raylib_artifact = raylib_dep.artifact("raylib");
    // Path to bundled miniaudio.h (used directly for microphone capture).
    const miniaudio_inc = raylib_dep.path("src/external");

    const mod = b.addModule("btuber", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "btuber", .module = mod },
        },
    });
    exe_mod.linkLibrary(raylib_artifact);
    exe_mod.addIncludePath(miniaudio_inc);
    exe_mod.addOptions("build_options", build_options);

    const exe = b.addExecutable(.{
        .name = "btuber",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}

/// Run `git describe --tags --always --dirty` to produce a version string.
/// On a tagged commit this is just the tag (e.g. `v0.1.0`); on dev builds
/// it's `<tag>-<n>-g<sha>` or just `<sha>` if there are no tags yet, with
/// `-dirty` appended when the working tree has uncommitted changes.
fn describeGitVersion(b: *std.Build) []const u8 {
    var code: u8 = undefined;
    const stdout = b.runAllowFail(
        &.{ "git", "describe", "--tags", "--always", "--dirty" },
        &code,
        .ignore,
    ) catch return "unknown";
    return std.mem.trim(u8, stdout, " \n\r\t");
}
