const std = @import("std");

fn register_module(b: *std.Build, root_module: *std.Build.Module, comptime name: []const u8) *std.Build.Module {
    const capitalized_name = &[_]u8{std.ascii.toUpper(name[0])} ++ name[1..];
    const root_source_file = capitalized_name ++ "/" ++ capitalized_name ++ ".zig";

    const mod = b.addModule(name, .{ .root_source_file = b.path(root_source_file) });
    root_module.addImport(name, mod);
    return mod;
}

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) !void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    const root_module = b.addModule("entry", .{
        .root_source_file = b.path("entry.zig"),
        .optimize = optimize,
        .target = target,
    });
    _ = register_module(b, root_module, "app");
    _ = register_module(b, root_module, "polygon");
    _ = register_module(b, root_module, "renderer");
    const terrain_mod = register_module(b, root_module, "terrain");

    const zigimg_dependency = b.dependency("zigimg", .{
        .target = target,
        .optimize = optimize,
    });
    terrain_mod.addImport("zigimg", zigimg_dependency.module("zigimg"));

    const mach_dep = b.dependency("mach", .{
        .target = target,
        .optimize = optimize,
        // .sysgpu_backend = .vulkan,
    });
    root_module.addImport("mach", mach_dep.module("mach"));

    const exe = b.addExecutable(.{
        .name = "myrenderer",
        .root_module = root_module,
    });

    const path = try std.fs.path.join(b.allocator, &.{ b.install_path, "HEIGHTMAP.png" });
    defer b.allocator.free(path);
    b.installFile("App/HEIGHTMAP.png", "bin/HEIGHTMAP.png");
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.setCwd(b.path("zig-out/bin"));

    // By making the run step depend on the install step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    // This is not necessary, however, if the application depends on other installed
    // files, this ensures they will be present and in the expected location.
    run_cmd.step.dependOn(b.getInstallStep());

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build run`
    // This will evaluate the `run` step rather than the default, which is "install".
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const debug_step = b.step("debug", "Debug the app");

    const uscope_dep = b.dependency("uscope", .{});
    const debug_run_step = b.addRunArtifact(uscope_dep.artifact("uscope"));

    debug_step.dependOn(&debug_run_step.step);
}
