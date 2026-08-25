const std = @import("std");

// Although this function looks imperative, it does not perform the build
// directly and instead it mutates the build graph (`b`) that will be then
// executed by an external runner. The functions in `std.Build` implement a DSL
// for defining build steps and express dependencies between them, allowing the
// build runner to parallelize the build automatically (and the cache system to
// know when a step doesn't need to be re-run).
pub fn build(b: *std.Build) void {
    // Standard target options allow the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});
    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});
    // It's also possible to define more custom flags to toggle optional features
    // of this build script using `b.option()`. All defined flags (including
    // target and optimize options) will be listed when running `zig build --help`
    // in this directory.

    // zv is a library-only package providing an event loop implementation
    const mod = b.addModule("zv", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_lib_tests = b.addRunArtifact(lib_tests);

    const bench_infra_mod = b.createModule(.{
        .root_source_file = b.path("src/benchmarks/infra.zig"),
        .target = target,
        .optimize = optimize,
    });
    const bench_infra_tests = b.addTest(.{ .root_module = bench_infra_mod });
    const run_bench_infra_tests = b.addRunArtifact(bench_infra_tests);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_lib_tests.step);
    test_step.dependOn(&run_bench_infra_tests.step);

    const install_docs = b.addInstallDirectory(.{
        .source_dir = lib_tests.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });

    const docs_step = b.step("docs", "Generate documentation");
    docs_step.dependOn(&install_docs.step);

    // Benchmarks comparing zv vs libev (requires libev installed on system).
    // Probe is filesystem-only at link time; a missing libev fails this step,
    // not `zig build test`.
    const benchmark_step = b.step("benchmark", "Run benchmarks comparing zv vs libev (use -- --name <name> for specific benchmark)");

    // Compile zv itself as ReleaseFast. Using the library module's optimize
    // (default Debug) would make "ReleaseFast benchmarks" measure Debug zv.
    const bench_zv = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });

    const benchmark_mod = b.createModule(.{
        .root_source_file = b.path("src/benchmarks/main.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    benchmark_mod.addImport("zv", bench_zv);

    benchmark_mod.addIncludePath(b.path("src/benchmarks"));
    benchmark_mod.addCSourceFile(.{
        .file = b.path("src/benchmarks/libev_wrapper.c"),
        .flags = &.{ "-std=c99", "-O3", "-DNDEBUG" },
    });
    benchmark_mod.linkSystemLibrary("ev", .{});
    benchmark_mod.link_libc = true;

    const benchmark_exe = b.addExecutable(.{
        .name = "benchmark",
        .root_module = benchmark_mod,
    });

    const install_benchmark = b.addInstallArtifact(benchmark_exe, .{});

    const run_benchmark = b.addRunArtifact(benchmark_exe);
    run_benchmark.step.dependOn(&install_benchmark.step);
    if (b.args) |args| {
        run_benchmark.addArgs(args);
    }

    benchmark_step.dependOn(&run_benchmark.step);
}
