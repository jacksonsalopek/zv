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

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_lib_tests.step);

    const install_docs = b.addInstallDirectory(.{
        .source_dir = lib_tests.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });

    const docs_step = b.step("docs", "Generate documentation");
    docs_step.dependOn(&install_docs.step);

    // Benchmarks comparing zv vs libev (requires libev installed on system)
    const benchmark_step = b.step("benchmark", "Run benchmarks comparing zv vs libev (use -- --name <name> for specific benchmark)");
    
    // Check for libev availability
    const libev_check = checkLibev(b);
    if (!libev_check.available) {
        const error_step = b.addFail(libev_check.message);
        benchmark_step.dependOn(&error_step.step);
        return;
    }

    const benchmark_mod = b.createModule(.{
        .root_source_file = b.path("src/benchmarks/main.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    benchmark_mod.addImport("zv", mod);

    const benchmark_exe = b.addExecutable(.{
        .name = "benchmark",
        .root_module = benchmark_mod,
    });

    benchmark_exe.addIncludePath(b.path("src/benchmarks"));
    benchmark_exe.addCSourceFile(.{
        .file = b.path("src/benchmarks/libev_wrapper.c"),
        .flags = &.{"-std=c99"},
    });
    benchmark_exe.linkSystemLibrary("ev");
    benchmark_exe.linkLibC();

    const install_benchmark = b.addInstallArtifact(benchmark_exe, .{});

    const run_benchmark = b.addRunArtifact(benchmark_exe);
    run_benchmark.step.dependOn(&install_benchmark.step);
    if (b.args) |args| {
        run_benchmark.addArgs(args);
    }

    benchmark_step.dependOn(&run_benchmark.step);
}

const LibevCheck = struct {
    available: bool,
    message: []const u8,
};

fn checkLibev(b: *std.Build) LibevCheck {
    // Try pkg-config first
    if (std.process.Child.run(.{
        .allocator = b.allocator,
        .argv = &.{ "pkg-config", "--exists", "libev" },
    })) |result| {
        defer b.allocator.free(result.stdout);
        defer b.allocator.free(result.stderr);
        
        if (result.term.Exited == 0) {
            return .{ .available = true, .message = "" };
        }
    } else |_| {}

    // Fallback: check common library paths
    const lib_paths = &[_][]const u8{
        "/usr/lib/libev.so",
        "/usr/lib64/libev.so",
        "/usr/lib/x86_64-linux-gnu/libev.so",
        "/usr/local/lib/libev.so",
        "/opt/homebrew/lib/libev.dylib",
        "/usr/local/opt/libev/lib/libev.dylib",
    };

    for (lib_paths) |path| {
        std.fs.accessAbsolute(path, .{}) catch continue;
        return .{ .available = true, .message = "" };
    }

    // Check for header file as additional verification
    const header_paths = &[_][]const u8{
        "/usr/include/ev.h",
        "/usr/local/include/ev.h",
        "/opt/homebrew/include/ev.h",
    };

    for (header_paths) |path| {
        std.fs.accessAbsolute(path, .{}) catch continue;
        return .{ .available = true, .message = "" };
    }

    return .{
        .available = false,
        .message = getLibevErrorMessage(b, null),
    };
}

fn getLibevErrorMessage(b: *std.Build, maybe_distro: ?[]const u8) []const u8 {
    _ = maybe_distro;
    
    const base_msg = 
        \\
        \\━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        \\  ERROR: libev not found
        \\━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        \\
        \\  Benchmarks require libev to be installed on your system.
        \\
        \\  NOTE: libev is ONLY required for benchmarks. The main zv library
        \\        does not depend on libev.
        \\
        \\  Installation instructions:
        \\
        \\    Ubuntu/Debian:  sudo apt-get update && sudo apt-get install libev-dev
        \\    Fedora/RHEL:    sudo dnf install libev-devel
        \\    Arch Linux:     sudo pacman -S libev
        \\    openSUSE:       sudo zypper install libev-devel
        \\    macOS:          brew install libev
        \\
        \\  After installing libev, run:
        \\    zig build benchmark
        \\
        \\  To skip benchmarks and just build/test the library:
        \\    zig build
        \\    zig build test
        \\
        \\━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        \\
    ;

    return b.dupe(base_msg);
}
