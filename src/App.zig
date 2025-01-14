const std = @import("std");
const mach = @import("mach");
const math = @import("math.zig");

const Renderer = @import("Renderer.zig");
const Terrain = @import("Terrain.zig");
const Polygon = @import("Polygon.zig");
pub const Mod = mach.Mod(@This());

pub const mach_module = .app;
pub const mach_systems = .{ .main, .init, .tick, .deinit };

is_initialized: bool,
terrain: mach.ObjectID,
polygon: mach.ObjectID,

pub const main = mach.schedule(.{
    .{ mach.Core, .init },
    .{ Renderer, .preinit },
    .{ @This(), .init },
    .{ mach.Core, .main },
});

pub fn init(
    app: *@This(),
    app_mod: Mod,
    core: *mach.Core,
) !void {
    core.on_tick = app_mod.id.tick;
    core.on_exit = app_mod.id.deinit;

    app.is_initialized = false;
}

pub fn tick(
    app: *@This(),
    core: *mach.Core,
    // renderer: *Renderer,
    renderer_mod: Renderer.Mod,
    terrain_mod: Terrain.Mod,
    // terrain: *Terrain,
    polygon: *Polygon,
    polygon_mod: Polygon.Mod,
) !void {
    while (core.nextEvent()) |event| {
        switch (event) {
            .window_open => {
                app.is_initialized = true;
                renderer_mod.call(.init);
                terrain_mod.call(.init);
                polygon_mod.call(.init);
                // app.terrain = try terrain.create_terrain(renderer, core, "HEIGHTMAP.png");
                app.polygon = try polygon.create_polygon(&.{
                    .{ .x = math.Vec2.init(5.0, 5.0) },
                    .{ .x = math.Vec2.init(7.0, 11.0) },
                    .{ .x = math.Vec2.init(5.0, 10.0) },
                    .{ .x = math.Vec2.init(9.0, 5.0) },
                    .{ .x = math.Vec2.init(14.0, 2.0) },
                    .{ .x = math.Vec2.init(10.0, 8.0) },
                });
            },
            .close => core.exit(),
            else => {},
        }
    }
    if (app.is_initialized) {
        terrain_mod.call(.tick);
        renderer_mod.call(.draw);
    }
}

pub fn deinit(renderer_mod: Renderer.Mod, terrain_mod: Terrain.Mod) void {
    terrain_mod.call(.deinit);
    renderer_mod.call(.deinit);
}
