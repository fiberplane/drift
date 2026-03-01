const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Dependencies
    const clap_dep = b.dependency("clap", .{});

    // Build tree-sitter C library from vendor sources
    const ts_module = buildTreeSitter(b, target, optimize);

    // Root module
    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "clap", .module = clap_dep.module("clap") },
            .{ .name = "tree_sitter", .module = ts_module },
        },
    });
    linkGrammars(b, root_module);

    // Executable
    const exe = b.addExecutable(.{
        .name = "drift",
        .root_module = root_module,
    });
    b.installArtifact(exe);

    // Run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run drift");
    run_step.dependOn(&run_cmd.step);

    // Tests — build options for integration tests
    const test_options = b.addOptions();
    test_options.addOption([]const u8, "drift_bin", b.getInstallPath(.bin, "drift"));

    // Helpers module for integration tests
    const helpers_module = b.createModule(.{
        .root_source_file = b.path("test/helpers.zig"),
        .target = target,
        .optimize = optimize,
    });
    helpers_module.addOptions("build_options", test_options);

    const test_module = b.createModule(.{
        .root_source_file = b.path("tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "clap", .module = clap_dep.module("clap") },
            .{ .name = "tree_sitter", .module = ts_module },
            .{ .name = "helpers", .module = helpers_module },
        },
    });
    linkGrammars(b, test_module);

    const unit_tests = b.addTest(.{
        .root_module = test_module,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    // Ensure drift binary is built before tests run
    run_unit_tests.step.dependOn(b.getInstallStep());
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}

fn buildTreeSitter(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    // Build the tree-sitter C library as a static library
    const ts_c_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    ts_c_module.addCSourceFile(.{
        .file = b.path("vendor/tree-sitter/lib/src/lib.c"),
        .flags = &.{"-std=c11"},
    });

    ts_c_module.addIncludePath(b.path("vendor/tree-sitter/lib/include"));
    ts_c_module.addIncludePath(b.path("vendor/tree-sitter/lib/src"));

    ts_c_module.addCMacro("_POSIX_C_SOURCE", "200112L");
    ts_c_module.addCMacro("_DEFAULT_SOURCE", "");

    const ts_c_lib = b.addLibrary(.{
        .name = "tree-sitter",
        .linkage = .static,
        .root_module = ts_c_module,
    });

    // Build options for zig-tree-sitter (wasm disabled)
    const options = b.addOptions();
    options.addOption(bool, "enable_wasm", false);

    // Create the Zig tree_sitter module from vendor sources
    const ts_zig_module = b.createModule(.{
        .root_source_file = b.path("vendor/zig-tree-sitter/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    ts_zig_module.linkLibrary(ts_c_lib);
    ts_zig_module.addOptions("build", options);

    return ts_zig_module;
}

fn linkGrammars(b: *std.Build, module: *std.Build.Module) void {
    // Tree-sitter headers needed by grammar C sources
    module.addIncludePath(b.path("vendor/tree-sitter/lib/include"));

    const grammars = [_]struct {
        dep_name: []const u8,
        parser_path: []const u8,
        scanner_path: ?[]const u8,
    }{
        .{
            .dep_name = "tree_sitter_typescript",
            .parser_path = "typescript/src/parser.c",
            .scanner_path = "typescript/src/scanner.c",
        },
        .{
            .dep_name = "tree_sitter_python",
            .parser_path = "src/parser.c",
            .scanner_path = "src/scanner.c",
        },
        .{
            .dep_name = "tree_sitter_rust",
            .parser_path = "src/parser.c",
            .scanner_path = "src/scanner.c",
        },
        .{
            .dep_name = "tree_sitter_go",
            .parser_path = "src/parser.c",
            .scanner_path = null,
        },
        .{
            .dep_name = "tree_sitter_zig",
            .parser_path = "src/parser.c",
            .scanner_path = null,
        },
        .{
            .dep_name = "tree_sitter_java",
            .parser_path = "src/parser.c",
            .scanner_path = null,
        },
    };

    for (grammars) |grammar| {
        const dep = b.lazyDependency(grammar.dep_name, .{}) orelse continue;

        module.addCSourceFile(.{
            .file = dep.path(grammar.parser_path),
            .flags = &.{"-std=c11"},
        });

        if (grammar.scanner_path) |scanner| {
            module.addCSourceFile(.{
                .file = dep.path(scanner),
                .flags = &.{"-std=c11"},
            });
        }
    }
}
