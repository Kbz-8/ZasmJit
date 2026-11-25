const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const asmjit = b.dependency("asmjit", .{});
    const asmjit_root = asmjit.path("");

    switch (target.result.cpu.arch) {
        .x86, .x86_64, .aarch64 => {},
        else => return error.UnsupportedArch,
    }

    const native = b.addLibrary(.{
        .name = "zasmjit",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = true,
            .pic = true,
        }),
    });

    native.root_module.addIncludePath(asmjit_root);
    native.root_module.addIncludePath(b.path("src/c"));
    native.root_module.addCMacro("ASMJIT_STATIC", "1");
    native.root_module.addCMacro("ASMJIT_NO_FOREIGN", "1");
    native.root_module.addCSourceFiles(.{
        .root = asmjit_root,
        .files = @import("src/sources.zig").files,
        .flags = &.{ "-std=c++20", "-fno-exceptions", "-fno-rtti" },
    });

    native.root_module.addCSourceFile(.{
        .file = b.path("src/c/bridge.cpp"),
        .flags = &.{ "-std=c++20", "-fno-exceptions", "-fno-rtti" },
    });

    if (target.result.os.tag == .linux)
        native.root_module.linkSystemLibrary("pthread", .{});

    const mod = b.addModule("asmjit", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    mod.linkLibrary(native);
    b.installArtifact(native);

    const unit = b.addTest(.{ .root_module = mod });
    const run_tests = b.addRunArtifact(unit);
    b.step("test", "Run bindings and JIT execution tests").dependOn(&run_tests.step);

    const example = b.addExecutable(.{
        .name = "ujit-example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/add.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "asmjit", .module = mod }},
        }),
    });
    const run_example = b.addRunArtifact(example);
    b.step("example", "Generate and execute a UJIT function").dependOn(&run_example.step);
    const compile_check = b.step("check", "Compile library, tests, and example without running");
    compile_check.dependOn(&unit.step);
    compile_check.dependOn(&example.step);

    const generate = b.addSystemCommand(&.{"python3"});
    generate.addFileArg(b.path("tools/generate.py"));
    generate.addDirectoryArg(asmjit_root);
    b.step("generate", "Regenerate bindings from the fetched AsmJit headers (requires Python 3)").dependOn(&generate.step);
}
