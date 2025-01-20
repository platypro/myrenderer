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
polygon1: mach.ObjectID,
polygon2: mach.ObjectID,

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
                app.polygon1 = try polygon.create_polygon(&.{
                    math.Vec2.init(62.742857, 106.97143),
                    math.Vec2.init(93.085712, 65.828571),
                    math.Vec2.init(147.08571, 85.628572),
                    math.Vec2.init(122.14285, 144.77143),
                    math.Vec2.init(102.34286, 93.857142),
                    math.Vec2.init(79.199998, 130.37143),
                    math.Vec2.init(81.00000, 105.17143),
                });

                app.polygon2 = try polygon.create_polygon(&.{
                    math.Vec2.init(10.0, 10.0),
                    math.Vec2.init(40.0, 10.0),
                    math.Vec2.init(40.0, 40.0),
                    math.Vec2.init(10.0, 40.0),
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
