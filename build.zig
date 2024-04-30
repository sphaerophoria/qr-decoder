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

fn setupBinarizationDebug(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    libqr: *std.Build.Module,
    test_step: *std.Build.Step,
) void {
    const generate_embedded_resources = b.addExecutable(.{
        .name = "generate_embedded_resources",
        .root_source_file = .{ .path = "tools/generate_embedded_resources.zig" },
        .target = b.host,
    });

    const generate_embedded_resources_step = b.addRunArtifact(generate_embedded_resources);
    generate_embedded_resources_step.addDirectoryArg(b.path("src/binarization_debug/res"));
    const output = generate_embedded_resources_step.addOutputFileArg("resources.zig");
    _ = generate_embedded_resources_step.addDepFileOutputArg("deps.d");

    const exe = b.addExecutable(.{
        .name = "binarization-debug",
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = .{ .path = "src/binarization_debug/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    exe.root_module.addImport("libqr", libqr);
    exe.root_module.addAnonymousImport("resources", .{ .root_source_file = output });
    exe.linkLibC();
    b.installArtifact(exe);

    const unit_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/binarization_debug/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    unit_tests.root_module.addImport("libqr", libqr);
    unit_tests.root_module.addAnonymousImport("resources", .{ .root_source_file = output });
    unit_tests.linkLibC();

    const run_unit_tests = b.addRunArtifact(unit_tests);

    test_step.dependOn(&run_unit_tests.step);
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const test_step = b.step("test", "Run unit tests");
    const libqr = setupLibQr(b, target, optimize, test_step);
    setupQrAnnotator(b, target, optimize, libqr, test_step);
    setupBinarizationDebug(b, target, optimize, libqr, test_step);
}
