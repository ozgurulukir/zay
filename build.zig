const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const vaxis_dep = b.dependency("vaxis", .{
        .target = target,
        .optimize = optimize,
    });
    const websocket_vendor_mod = b.createModule(.{
        .root_source_file = b.path("vendor/websocket.zig/src/websocket.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const bounded_queue_mod = b.createModule(.{
        .root_source_file = b.path("lib/bounded_queue.zig"),
        .target = target,
        .optimize = optimize,
    });
    {
        const options = b.addOptions();
        options.addOption(bool, "websocket_blocking", false);
        websocket_vendor_mod.addOptions("build", options);
    }
    const websocket_mod = b.createModule(.{
        .root_source_file = b.path("lib/websocket.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "websocket_vendor", .module = websocket_vendor_mod },
        },
    });
    const logger_mod = b.createModule(.{
        .root_source_file = b.path("lib/logger.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "bounded_queue", .module = bounded_queue_mod },
        },
    });
    const dynlib_mod = b.createModule(.{
        .root_source_file = b.path("lib/dynlib.zig"),
        .target = target,
        .optimize = optimize,
    });
    const terminal_markdown_mod = b.createModule(.{
        .root_source_file = b.path("lib/terminal_markdown.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "vaxis", .module = vaxis_dep.module("vaxis") },
        },
    });
    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
    });
    translate_c.addIncludePath(b.path("vendor/fff"));
    translate_c.addIncludePath(b.path("vendor/sqlite"));
    const c_mod = translate_c.createModule();

    // Generate the models.dev context-window catalogue at build time. A small
    // host tool reads the vendored snapshot and emits a static Zig table that
    // `compaction.zig` imports as `model_catalog`. Keeps accurate per-model
    // context windows in the binary without a runtime JSON parse; refresh by
    // re-curling vendor/models.dev/models.json and rebuilding.
    const model_catalog_gen = b.addExecutable(.{
        .name = "gen-model-catalog",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/gen_model_catalog.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const model_catalog_run = b.addRunArtifact(model_catalog_gen);
    model_catalog_run.addFileArg(b.path("vendor/models.dev/models.json"));
    const model_catalog_zig = model_catalog_run.addOutputFileArg("model_catalog.zig");
    const model_catalog_mod = b.createModule(.{
        .root_source_file = model_catalog_zig,
        .target = target,
        .optimize = optimize,
    });

    const mod = b.addModule("nova", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "bounded_queue", .module = bounded_queue_mod },
            .{ .name = "vaxis", .module = vaxis_dep.module("vaxis") },
            .{ .name = "websocket", .module = websocket_mod },
            .{ .name = "logger", .module = logger_mod },
            .{ .name = "dynlib", .module = dynlib_mod },
            .{ .name = "terminal_markdown", .module = terminal_markdown_mod },
            .{ .name = "c", .module = c_mod },
            .{ .name = "model_catalog", .module = model_catalog_mod },
        },
    });

    mod.link_libc = true;
    mod.addCSourceFile(.{
        .file = b.path("vendor/sqlite/sqlite3.c"),
        .flags = &.{
            "-DSQLITE_THREADSAFE=2",
            "-DSQLITE_DEFAULT_FOREIGN_KEYS=1",
            "-DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1",
            "-DSQLITE_OMIT_DEPRECATED",
            "-DSQLITE_OMIT_LOAD_EXTENSION",
            "-DSQLITE_DQS=0",
            "-DSQLITE_USE_URI=1",
            "-DSQLITE_ENABLE_JSON1",
            "-DSQLITE_ENABLE_FTS5",
            "-Wno-implicit-function-declaration",
            "-Wno-unused-but-set-variable",
        },
    });

    // If neither case applies to you, feel free to delete the declaration you
    // don't need and to put everything under a single module.
    const exe = b.addExecutable(.{
        .name = "nova",
        .root_module = b.createModule(.{
            // b.createModule defines a new module just like b.addModule but,
            // unlike b.addModule, it does not expose the module to consumers of
            // this package, which is why in this case we don't have to give it a name.
            .root_source_file = b.path("src/main.zig"),
            // Target and optimization levels must be explicitly wired in when
            // defining an executable or library (in the root module), and you
            // can also hardcode a specific target for an executable or library
            // definition if desireable (e.g. firmware for embedded devices).
            .target = target,
            .optimize = optimize,
            // List of modules available for import in source files part of the
            // root module.
            .imports = &.{
                // Here "nova" is the name you will use in your source code to
                // import this module (e.g. `@import("nova")`). The name is
                // repeated because you are allowed to rename your imports, which
                // can be extremely useful in case of collisions (which can happen
                // importing modules from different packages).
                .{ .name = "nova", .module = mod },
                .{ .name = "vaxis", .module = vaxis_dep.module("vaxis") },
                .{ .name = "websocket", .module = websocket_mod },
                .{ .name = "logger", .module = logger_mod },
                .{ .name = "dynlib", .module = dynlib_mod },
                .{ .name = "terminal_markdown", .module = terminal_markdown_mod },
            },
        }),
    });

    // This declares intent for the executable to be installed into the
    // install prefix when running `zig build` (i.e. when executing the default
    // step). By default the install prefix is `zig-out/` but can be overridden
    // by passing `--prefix` or `-p`.
    b.installArtifact(exe);

    // This creates a top level step. Top level steps have a name and can be
    // invoked by name when running `zig build` (e.g. `zig build run`).
    // This will evaluate the `run` step rather than the default step.
    // For a top level step to actually do something, it must depend on other
    // steps (e.g. a Run step, as we will see in a moment).
    const run_step = b.step("run", "Run the app");

    // This creates a RunArtifact step in the build graph. A RunArtifact step
    // invokes an executable compiled by Zig. Steps will only be executed by the
    // runner if invoked directly by the user (in the case of top level steps)
    // or if another step depends on it, so it's up to you to define when and
    // how this Run step will be executed. In our case we want to run it when
    // the user runs `zig build run`, so we create a dependency link.
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    // By making the run step depend on the default step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Creates an executable that will run `test` blocks from the provided module.
    // Here `mod` needs to define a target, which is why earlier we made sure to
    // set the releative field.
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    // A run step that will run the test executable.
    const run_mod_tests = b.addRunArtifact(mod_tests);

    // Creates an executable that will run `test` blocks from the executable's
    // root module. Note that test executables only test one module at a time,
    // hence why we have to create two separate ones.
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    // A run step that will run the second test executable.
    const run_exe_tests = b.addRunArtifact(exe_tests);

    // A top level step for running all tests. dependOn can be called multiple
    // times and since the two run steps do not depend on one another, this will
    // make the two of them run in parallel.
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    // Just like flags, top level steps are also listed in the `--help` menu.
    //
    // The Zig build system is entirely implemented in userland, which means
    // that it cannot hook into private compiler APIs. All compilation work
    // orchestrated by the build system will result in other Zig compiler
    // subcommands being invoked with the right flags defined. You can observe
    // these invocations when one fails (or you pass a flag to increase
    // verbosity) to validate assumptions and diagnose problems.
    //
    // Lastly, the Zig build system is relatively simple and self-contained,
    // and reading its source code will allow you to master it.
}
