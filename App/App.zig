const std = @import("std");
const mach = @import("root").mach;
const math = @import("root").math;
const Renderer = @import("root").Renderer;
const Polygon = @import("root").Polygon;
const Terrain = @import("root").Terrain;

pub const Mod = mach.Mod(@This());

pub const mach_module = .app;
pub const mach_systems = .{ .main, .init, .tick, .deinit };

is_initialized: bool,
window: mach.ObjectID,
surface2d: Renderer.Surface.Handle,
surface3d: Renderer.Surface.Handle,
terrain: Renderer.Node.Handle,
polygon1: Polygon.Handle,
polygon2: Polygon.Handle,
draw: Renderer.Draw.Handle,

pub const main = mach.schedule(.{
    .{ mach.Core, .init },
    .{ Renderer, .init },
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
    app.window = try core.windows.new(.{ .title = "Platypro's Thing", .width = 1280, .height = 720 });
}

pub fn tick(
    app: *@This(),
    core: *mach.Core,
    renderer: *Renderer,
    renderer_mod: Renderer.Mod,
    terrain: *Terrain,
    terrain_mod: Terrain.Mod,
    polygon: *Polygon,
    polygon_mod: Polygon.Mod,
) !void {
    while (core.nextEvent()) |event| {
        switch (event) {
            .window_open => {
                app.is_initialized = true;

                renderer.adopt_window(app.window);
                terrain_mod.call(.init);
                polygon_mod.call(.init);
                app.terrain = try terrain.create_terrain(renderer, core, "HEIGHTMAP.png");
                app.surface3d = try Renderer.Surface.createFromWindow(renderer, app.terrain, app.window);
                app.surface3d.set_perspective(renderer, math.perspective(90, 1.0, 0.1, 200));

                app.polygon1 = try polygon.create_polygon(&.{
                    Polygon.Point{ 62.742857, 106.97143 },
                    Polygon.Point{ 93.085712, 65.828571 },
                    Polygon.Point{ 147.08571, 85.628572 },
                    Polygon.Point{ 122.14285, 144.77143 },
                    Polygon.Point{ 102.34286, 93.857142 },
                    Polygon.Point{ 79.199998, 130.37143 },
                    Polygon.Point{ 81.00000, 105.17143 },
                });

                // app.polygon2 = try polygon.create_polygon(&.{
                //     Polygon.Point{ 10.0, 10.0 },
                //     Polygon.Point{ 40.0, 10.0 },
                //     Polygon.Point{ 40.0, 40.0 },
                //     Polygon.Point{ 10.0, 40.0 },
                // });

                const base_node = try Renderer.Node.create(renderer, .{});
                try renderer.nodes.addChild(base_node.id, app.polygon1.getNode(polygon).id);
                // try renderer.nodes.addChild(base_node.id, app.polygon2.getNode(polygon).id);
                app.surface2d = try Renderer.Surface.createFromWindow(renderer, base_node, app.window);
                app.surface2d.set_perspective(renderer, math.Mat.projection2D(.{ .left = 0.0, .right = 200.0, .bottom = 200.0, .top = 0.0, .near = 0.1, .far = 200.0 }));

                app.draw = try Renderer.Draw.create(renderer);
            },
            .close => core.exit(),
            else => {},
        }
    }
    if (app.is_initialized) {
        app.draw.begin(renderer);
        app.draw.clear(renderer, mach.gpu.Color{ .r = 0.259, .g = 0.141, .b = 0.271, .a = 1.0 });
        try app.draw.draw_surface(renderer, app.surface3d);
        try app.draw.draw_surface(renderer, app.surface2d);
        app.draw.end(renderer);

        renderer_mod.call(.update);
    }
}

pub fn deinit(renderer_mod: Renderer.Mod, terrain_mod: Terrain.Mod) void {
    terrain_mod.call(.deinit);
    renderer_mod.call(.deinit);
}
