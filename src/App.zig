const std = @import("std");
const glfw = @import("zglfw");
const gpu = @import("zgpu");
const mach = @import("mach");

const Renderer = @import("Renderer.zig");
const Terrain = @import("Terrain.zig");

pub const mach_module = .app;
pub const mach_systems = .{.main};

gpa: std.heap.GeneralPurposeAllocator(.{}) = .{},
allocator: std.mem.Allocator,
window: *glfw.Window,

pub fn main(
    app: *@This(),
    renderer_mod: mach.Mod(Renderer),
    renderer: *Renderer,
    terrain_mod: mach.Mod(Terrain),
    terrain: *Terrain,
) !void {
    app.gpa = .{};
    app.allocator = app.gpa.allocator();

    try glfw.init();
    defer glfw.terminate();

    app.window = try glfw.Window.create(600, 600, "Platypro's Thing", null);
    defer app.window.destroy();

    renderer_mod.call(.init);
    terrain_mod.call(.init);
    try terrain.load_terrain(renderer, app, "HEIGHTMAP.png");

    while (!app.window.shouldClose()) {
        glfw.pollEvents();

        renderer_mod.call(.render_begin);
        terrain_mod.call(.draw);
        renderer_mod.call(.render_end);

        _ = renderer.gctx.present();
        app.window.swapBuffers();
    }

    terrain_mod.call(.deinit);
    renderer_mod.call(.deinit);

    _ = app.gpa.detectLeaks();
}
