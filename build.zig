const std = @import("std");

fn addDepsForLibQr(b: *std.Build, module: anytype) void {
    module.addIncludePath(b.path("src/libqr"));
    module.addCSourceFile(.{
        .file = b.path("src/libqr/stb_image_impl.c"),
        .flags = &[_][]const u8{},
    });
}

fn setupLibQr(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    test_step: *std.Build.Step,
) *std.Build.Module {
    const libqr = b.addModule("libqr", .{
        .root_source_file = .{ .path = "src/libqr/libqr.zig" },
        .target = target,
        .optimize = optimize,
    });
    addDepsForLibQr(b, libqr);

    const libqr_unit_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/libqr/libqr.zig" },
        .target = target,
        .optimize = optimize,
    });
    addDepsForLibQr(b, libqr_unit_tests);
    libqr_unit_tests.linkLibC();

    const run_libqr_unit_tests = b.addRunArtifact(libqr_unit_tests);
    test_step.dependOn(&run_libqr_unit_tests.step);

    return libqr;
}

fn setupQrAnnotator(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    libqr: *std.Build.Module,
    test_step: *std.Build.Step,
) void {
    const exe = b.addExecutable(.{
        .name = "qr-annotator",
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = .{ .path = "src/qr_annotator/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("libqr", libqr);
    exe.linkLibC();
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const main_unit_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/qr_annotator/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    main_unit_tests.root_module.addImport("libqr", libqr);
    main_unit_tests.linkLibC();

    const run_main_unit_tests = b.addRunArtifact(main_unit_tests);

    test_step.dependOn(&run_main_unit_tests.step);
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const test_step = b.step("test", "Run unit tests");
    const libqr = setupLibQr(b, target, optimize, test_step);
    setupQrAnnotator(b, target, optimize, libqr, test_step);
}
