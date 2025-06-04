const std = @import("std");
const mach = @import("root").mach;
const math = @import("root").math;
const Renderer = @import("root").Renderer;
const Polygon = @import("root").Polygon;
const Terrain = @import("root").Terrain;
const mods = @import("root").getModules();

pub const Mod = mach.Mod(@This());

pub const mach_module = .app;
pub const mach_systems = .{ .main, .init, .tick, .deinit };

is_initialized: bool,
window: mach.ObjectID,
surface2d: Renderer.Surface.Handle,
surface3d: Renderer.Surface.Handle,
terrain: Renderer.SceneNode.Handle,
polygon1: Polygon.Handle,
polygon2: Polygon.Handle,
base_2d_node: Renderer.SceneNode.Handle,
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

                Renderer.adopt_window(app.window);
                terrain_mod.call(.init);
                polygon_mod.call(.init);
                const app_dir = try std.fs.selfExeDirPathAlloc(core.allocator);
                defer core.allocator.free(app_dir);
                const full_heightmap_dir = try std.fs.path.join(core.allocator, &.{ app_dir, "HEIGHTMAP.png" });
                defer core.allocator.free(full_heightmap_dir);
                app.terrain = try terrain.create_terrain(core, full_heightmap_dir);
                app.surface3d = try Renderer.Surface.createWindowScene(app.window, app.terrain);
                app.surface3d.set_perspective(math.perspective(90, 1.0, 0.1, 200));

                app.polygon1 = try polygon.create_polygon(&.{
                    Polygon.Point{ 62.742857, 106.97143 },
                    Polygon.Point{ 93.085712, 65.828571 },
                    Polygon.Point{ 147.08571, 85.628572 },
                    Polygon.Point{ 122.14285, 144.77143 },
                    Polygon.Point{ 102.34286, 93.857142 },
                    Polygon.Point{ 79.199998, 130.37143 },
                    Polygon.Point{ 81.00000, 105.17143 },
                });

                app.polygon2 = try polygon.create_polygon(&.{
                    Polygon.Point{ 10.0, 10.0 },
                    Polygon.Point{ 40.0, 10.0 },
                    Polygon.Point{ 40.0, 40.0 },
                    Polygon.Point{ 10.0, 40.0 },
                });

                app.base_2d_node = try Renderer.SceneNode.create(null, null);
                try app.base_2d_node.add_child(app.polygon1.getNode());
                try app.base_2d_node.add_child(app.polygon2.getNode());
                app.surface2d = try Renderer.Surface.createWindowScene(app.window, app.base_2d_node);
                app.surface2d.set_perspective(math.Mat.projection2D(.{ .left = 0.0, .right = 200.0, .bottom = 200.0, .top = 0.0, .near = 0.1, .far = 200.0 }));

                app.draw = try Renderer.Draw.create();
            },
            .close => core.exit(),
            else => {},
        }
    }
    if (app.is_initialized) {
        const camX: f32 = 10.0 * math.std.cos(mods.renderer.elapsed_time);
        const camZ: f32 = 10.0 * math.std.sin(mods.renderer.elapsed_time);
        const cam = math.Vec3.init(camX, 6.0, camZ);
        const origin = math.Vec3.init(0.0, 0.0, 0.0);
        const up = math.Vec3.init(0.0, 1.0, 0.0);

        app.terrain.set_xform(math.lookAt(cam, origin, up));
        app.draw.begin();
        app.draw.clear(mach.gpu.Color{ .r = 0.259, .g = 0.141, .b = 0.271, .a = 1.0 });
        try app.draw.draw_surface(app.surface3d);
        try app.draw.draw_surface(app.surface2d);
        app.draw.end();

        renderer_mod.call(.update);
    }
}

pub fn deinit(renderer_mod: Renderer.Mod, terrain_mod: Terrain.Mod) void {
    terrain_mod.call(.deinit);
    renderer_mod.call(.deinit);
}
