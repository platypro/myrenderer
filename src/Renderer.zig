const gpu = @import("zgpu");
const glfw = @import("zglfw");
const mach = @import("mach");
const std = @import("std");
const math = @import("math.zig");

pub const mach_module = .renderer;
pub const mach_systems = .{ .init, .tick };

const App = @import("App.zig");

current_xform: math.Mat,
depth_texture_view_handle: gpu.TextureViewHandle,
gctx: *gpu.GraphicsContext,

light_sources: mach.Objects(.{}, struct {
    position: math.Vec3,
}),

pub fn init(self: *@This(), app: *App) !void {
    self.gctx = try gpu.GraphicsContext.create(
        app.allocator,
        .{
            .window = app.window,
            .fn_getTime = @ptrCast(&glfw.getTime),
            .fn_getFramebufferSize = @ptrCast(&glfw.Window.getFramebufferSize),
            .fn_getWin32Window = @ptrCast(&glfw.getWin32Window),
            .fn_getX11Display = @ptrCast(&glfw.getX11Display),
            .fn_getX11Window = @ptrCast(&glfw.getX11Window),
            .fn_getWaylandDisplay = @ptrCast(&glfw.getWaylandDisplay),
            .fn_getWaylandSurface = @ptrCast(&glfw.getWaylandWindow),
            .fn_getCocoaWindow = @ptrCast(&glfw.getCocoaWindow),
        },
        .{},
    );
    errdefer self.gctx.destroy(app.allocator);

    const depth_texture_handle = self.gctx.createTexture(.{
        .usage = .{ .render_attachment = true },
        .dimension = .tdim_2d,
        .size = .{
            .width = self.gctx.swapchain_descriptor.width,
            .height = self.gctx.swapchain_descriptor.height,
            .depth_or_array_layers = 1,
        },
        .format = .depth32_float,
        .mip_level_count = 1,
        .sample_count = 1,
    });
    self.depth_texture_view_handle = self.gctx.createTextureView(depth_texture_handle, .{});

    self.light_sources.lock();
    defer self.light_sources.unlock();
    _ = try self.light_sources.new(.{ .position = math.Vec3.init(1.0, 8.0, 1.0) });
}

pub fn tick(self: *@This()) !void {
    const camX = math.std.cos(@as(f32, @floatCast(glfw.getTime()))) * 20.0;
    const camZ = math.std.sin(@as(f32, @floatCast(glfw.getTime()))) * 20.0;
    const view = math.lookAt(
        math.Vec3.init(camX, 15.0, camZ),
        math.Vec3.init(0.0, 0.0, 0.0),
        math.Vec3.init(0.0, 1.0, 0.0),
    );
    var perspective = math.Mat.projection2D(.{ .left = -1.0, .right = 1.0, .top = 1.0, .bottom = -1.0, .near = 0.1, .far = 100.0 });
    perspective.v[2].v[3] = 1;
    self.current_xform = math.matMult(&.{ math.Mat.rotateZ(-math.std.pi / 2.0), perspective, view });
}
